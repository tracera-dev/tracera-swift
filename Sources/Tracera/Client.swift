import Foundation

package let httpTimeout: TimeInterval = 10
package let httpUploadTimeout: TimeInterval = 300
package let uploadMaxAttempts = 3
package let uploadRetryBaseMs = 200

package struct AppCapabilities: Decodable, Sendable {
  package var autotestCreateRun = false
  package var autotestFinishRun = false
  package var autotestResultsBatch = false
  package var testResultEnvVars = false
  package var autotestBlobsBatch = false
}

package struct AppConfig: Decodable, Sendable {
  package var publicAppUrl: String
  package var version: String
  package var capabilities: AppCapabilities?
}

package struct BlobUploadResult: Decodable, Sendable {
  package var id: String
  package var fileName: String
  package var mimeType: String
  package var sizeBytes: Int64?
}

package final class Client: @unchecked Sendable {
  private let config: Config
  private let session: URLSession
  private nonisolated(unsafe) var cachedApp: AppConfig?

  package init(_ config: Config) {
    self.config = config
    let conf = URLSessionConfiguration.ephemeral
    conf.timeoutIntervalForRequest = httpTimeout
    conf.timeoutIntervalForResource = httpUploadTimeout
    conf.httpMaximumConnectionsPerHost = 16
    self.session = URLSession(configuration: conf)
  }

  package func close() {
    session.invalidateAndCancel()
  }

  package func getAppConfig() async throws -> AppConfig {
    if let cached = cachedApp { return cached }
    let data = try await request(path: "/app-config", method: "GET", body: nil, json: true)
    let app = try JSONDecoder().decode(AppConfig.self, from: data)
    cachedApp = app
    return app
  }

  package func ensureCompatible(_ app: AppConfig) throws {
    guard isVersionAtLeast(app.version, minTraceraVersion) else {
      throw ConfigError.message(
        "Tracera server \(app.version) is below minimum \(minTraceraVersion)"
      )
    }
    let caps = app.capabilities
    guard caps?.autotestCreateRun == true,
      caps?.autotestFinishRun == true,
      caps?.autotestResultsBatch == true,
      caps?.testResultEnvVars == true
    else {
      throw ConfigError.message(
        "server missing required API capabilities (create/finish run, results batch, or result envVars)"
      )
    }
  }

  package func createRun() async throws -> Int {
    var body: [String: Any] = [:]
    if !config.runTitle.isEmpty { body["title"] = config.runTitle }
    let data = try await request(
      path: "/projects/\(config.projectId)/test-runs/autotest",
      method: "POST",
      body: body,
      json: true
    )
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    guard let id = json?["id"] as? Int ?? (json?["id"] as? NSNumber)?.intValue else {
      throw ConfigError.message("create_run reply missing id")
    }
    return id
  }

  package func finishRun(_ testRunId: Int) async throws {
    _ = try await request(
      path: "/projects/\(config.projectId)/test-runs/\(testRunId)/autotest/finish",
      method: "POST",
      body: nil,
      json: true
    )
  }

  package func postResultsBatch(testRunId: Int, items: [[String: Any]]) async throws -> [String: Any] {
    let data = try await request(
      path: "/test-results/batch",
      method: "POST",
      body: ["testRunId": testRunId, "items": items],
      json: true
    )
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
  }

  package func uploadBlob(fileName: String, mimeType: String, path: String?, data: Data?) async throws
    -> BlobUploadResult
  {
    try await uploadBlob(
      BlobFile(fileName: fileName, mimeType: mimeType, path: path, data: data)
    )
  }

  package func uploadBlob(_ file: BlobFile) async throws -> BlobUploadResult {
    var lastError: Error = ConfigError.message("upload failed")
    for attempt in 0..<uploadMaxAttempts {
      do {
        return try await uploadBlobOnce(file)
      } catch {
        lastError = error
        if attempt + 1 >= uploadMaxAttempts || !isRetryableUploadError(error) {
          throw error
        }
        let delayMs = uploadRetryBaseMs * (1 << attempt)
        let cause = uploadRetryCause("\(error)")
        logDebug(
          "Tracera: attachment upload (\(file.fileName)) failed (\(cause)) — retry \(attempt + 1)/\(uploadMaxAttempts - 1) in \(delayMs)ms"
        )
        let delay = UInt64(delayMs) * 1_000_000
        try? await Task.sleep(nanoseconds: delay)
      }
    }
    throw lastError
  }

  /// Uploads attachments with bounded concurrency (config `uploadConcurrency`).
  package func uploadBlobs(_ files: [BlobFile]) async throws -> [BlobUploadResult?] {
    if files.isEmpty { return [] }
    let limit = max(1, min(config.uploadConcurrency, files.count))
    var out = [BlobUploadResult?](repeating: nil, count: files.count)
    var errors = [Error?](repeating: nil, count: files.count)
    await withTaskGroup(of: (Int, Result<BlobUploadResult, Error>).self) { group in
      var next = 0
      func addWorker() {
        guard next < files.count else { return }
        let index = next
        next += 1
        let file = files[index]
        group.addTask {
          do {
            return (index, .success(try await self.uploadBlob(file)))
          } catch {
            return (index, .failure(error))
          }
        }
      }
      for _ in 0..<limit { addWorker() }
      for await (index, result) in group {
        switch result {
        case .success(let blob): out[index] = blob
        case .failure(let error): errors[index] = error
        }
        addWorker()
      }
    }
    for error in errors {
      if let error { throw error }
    }
    return out
  }

  private func uploadBlobOnce(_ file: BlobFile) async throws -> BlobUploadResult {
    let multipart = try openMultipart(
      fileName: file.fileName,
      mimeType: file.mimeType,
      path: file.path,
      data: file.data
    )
    let url = URL(string: config.baseURL + "/projects/\(config.projectId)/blobs")!
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
    req.setValue(multipart.contentType, forHTTPHeaderField: "Content-Type")
    req.setValue("\(multipart.length)", forHTTPHeaderField: "Content-Length")
    req.timeoutInterval = httpUploadTimeout

    let respData: Data
    let resp: URLResponse
    switch multipart.source {
    case .data(let body):
      req.httpBody = body
      (respData, resp) = try await session.data(for: req)
    case .stream(let source):
      // Custom InputStream subclasses are unreliable as `httpBodyStream`.
      // Pump through a bound pair so URLSession reads a real CF stream while
      // we still stream head+file+tail (no full-size `.multipart` temp).
      var input: InputStream?
      var output: OutputStream?
      Stream.getBoundStreams(withBufferSize: 256 * 1024, inputStream: &input, outputStream: &output)
      guard let input, let output else {
        throw ConfigError.message("attachment upload failed: could not open bound stream")
      }
      let pump = Task.detached {
        pumpMultipart(from: source, into: output)
      }
      req.httpBodyStream = input
      do {
        (respData, resp) = try await session.data(for: req)
      } catch {
        pump.cancel()
        throw error
      }
      _ = await pump.result
    }
    try throwIfHTTPError(resp, data: respData)
    return try JSONDecoder().decode(BlobUploadResult.self, from: respData)
  }

  package func runUrl(testRunId: Int, publicAppUrl: String) -> String {
    let base = publicAppUrl.hasSuffix("/") ? String(publicAppUrl.dropLast()) : publicAppUrl
    return "\(base)/project/\(config.projectId)/test-runs/\(testRunId)"
  }

  private func request(path: String, method: String, body: [String: Any]?, json: Bool) async throws -> Data {
    let url = URL(string: config.baseURL + path)!
    var req = URLRequest(url: url)
    req.httpMethod = method
    req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
    if json {
      req.setValue("application/json", forHTTPHeaderField: "Accept")
      if let body {
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
      }
    }
    req.timeoutInterval = httpTimeout
    let (data, resp) = try await session.data(for: req)
    try throwIfHTTPError(resp, data: data)
    return data
  }
}

private func throwIfHTTPError(_ resp: URLResponse, data: Data) throws {
  guard let http = resp as? HTTPURLResponse else {
    throw ConfigError.message("invalid HTTP response")
  }
  guard (200..<300).contains(http.statusCode) else {
    let text = String(data: data, encoding: .utf8) ?? ""
    throw ConfigError.message("HTTP \(http.statusCode): \(text.prefix(200))")
  }
}

/// Whether an upload failure is worth retrying (JS/Go/Dart parity).
///
/// Missing/unreadable path and non-429 4xx fail immediately; 5xx / 429 /
/// transient network errors retry up to ``uploadMaxAttempts``.
package func isRetryableUploadError(_ error: Error) -> Bool {
  if error is CancellationError { return false }
  if isMissingPathError(error) { return false }
  let ns = error as NSError
  if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return false }
  let message = "\(error)"
  if message.range(of: #"HTTP 5\d\d"#, options: .regularExpression) != nil { return true }
  if message.contains("HTTP 429") { return true }
  if message.range(
    of: #"connection reset|timeout|timed out|EOF|network|broken pipe|aborted"#,
    options: [.regularExpression, .caseInsensitive]
  ) != nil {
    return true
  }
  if message.range(of: #"HTTP 4\d\d"#, options: .regularExpression) != nil { return false }
  return true
}

private func isMissingPathError(_ error: Error) -> Bool {
  var current: NSError? = error as NSError
  var seen = Set<ObjectIdentifier>()
  while let ns = current {
    let id = ObjectIdentifier(ns)
    if seen.contains(id) { break }
    seen.insert(id)
    if ns.domain == NSPOSIXErrorDomain && (ns.code == Int(ENOENT) || ns.code == Int(EACCES)) {
      return true
    }
    if ns.domain == NSCocoaErrorDomain
      && (ns.code == NSFileReadNoSuchFileError || ns.code == NSFileReadNoPermissionError)
    {
      return true
    }
    current = ns.userInfo[NSUnderlyingErrorKey] as? NSError
  }
  return false
}

/// Copies a path multipart `InputStream` into a bound `OutputStream` for URLSession.
private func pumpMultipart(from source: InputStream, into output: OutputStream) {
  source.open()
  output.open()
  defer {
    source.close()
    output.close()
  }
  let bufSize = 64 * 1024
  let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
  defer { buf.deallocate() }
  while source.hasBytesAvailable {
    if Task.isCancelled { return }
    let n = source.read(buf, maxLength: bufSize)
    if n < 0 { return }
    if n == 0 { break }
    var offset = 0
    while offset < n {
      if Task.isCancelled { return }
      let written = output.write(buf + offset, maxLength: n - offset)
      if written <= 0 { return }
      offset += written
    }
  }
}

/// Drop `… failed: ` prefix so retry lines do not repeat the label (JS/Python/JVM parity).
private func uploadRetryCause(_ message: String) -> String {
  if let range = message.range(of: " failed: ") {
    return String(message[range.upperBound...])
  }
  return message
}

package func isVersionAtLeast(_ version: String, _ minimum: String) -> Bool {
  func parts(_ v: String) -> [Int] {
    v.split(separator: "-")[0]
      .split(separator: ".")
      .prefix(3)
      .map { Int($0) ?? 0 }
  }
  let a = parts(version)
  let b = parts(minimum)
  for i in 0..<3 {
    let av = i < a.count ? a[i] : 0
    let bv = i < b.count ? b[i] : 0
    if av != bv { return av > bv }
  }
  return true
}
