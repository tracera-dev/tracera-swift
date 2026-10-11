import Foundation

package enum ConfigError: Error, CustomStringConvertible, Sendable {
  case message(String)

  package var description: String {
    switch self {
    case .message(let text): return text
    }
  }
}

package struct Config: Sendable {
  package let baseURL: String
  package let token: String
  package let projectId: Int
  package let testRunId: Int
  package let runTitle: String
  package let requireReport: Bool
  package let flushMaxItems: Int
  package let flushMaxMs: Int
  package let uploadConcurrency: Int

  package init(
    baseURL: String,
    token: String,
    projectId: Int,
    testRunId: Int = 0,
    runTitle: String = "",
    requireReport: Bool = false,
    flushMaxItems: Int = 50,
    flushMaxMs: Int = 1000,
    uploadConcurrency: Int = 4
  ) {
    self.baseURL = baseURL
    self.token = token
    self.projectId = projectId
    self.testRunId = testRunId
    self.runTitle = runTitle
    self.requireReport = requireReport
    self.flushMaxItems = flushMaxItems
    self.flushMaxMs = flushMaxMs
    self.uploadConcurrency = uploadConcurrency
  }
}

package func parseBool(_ raw: String?, fallback: Bool) -> Bool {
  switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
  case "true", "1": return true
  case "false", "0": return false
  default: return fallback
  }
}

package func parseStrictInt(_ raw: String?) -> Int? {
  let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  guard !trimmed.isEmpty else { return nil }
  guard trimmed.range(of: #"^[+-]?\d+$"#, options: .regularExpression) != nil else {
    return nil
  }
  return Int(trimmed)
}

private func parsePositiveInt(_ raw: String?, fallback: Int) -> Int {
  guard let parsed = parseStrictInt(raw), parsed > 0 else { return fallback }
  return parsed
}

package func loadConfig(_ env: [String: String]) throws -> Config {
  let baseURL = trimRightSlashes(env["TRACERA_BASE_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
  let token = env["TRACERA_AUTOTEST_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  if baseURL.isEmpty { throw ConfigError.message("TRACERA_BASE_URL is required") }
  if token.isEmpty { throw ConfigError.message("TRACERA_AUTOTEST_TOKEN is required") }

  guard let projectId = parseStrictInt(env["TRACERA_PROJECT_ID"]), projectId >= 1 else {
    throw ConfigError.message("TRACERA_PROJECT_ID must be a positive integer")
  }

  var testRunId = 0
  let rawRunId = env["TRACERA_TEST_RUN_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  if !rawRunId.isEmpty {
    guard let parsed = parseStrictInt(rawRunId), parsed >= 1 else {
      throw ConfigError.message("TRACERA_TEST_RUN_ID must be a positive integer when set")
    }
    testRunId = parsed
  }

  let runTitle = env["TRACERA_RUN_TITLE"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  if runTitle.count > 128 {
    throw ConfigError.message("TRACERA_RUN_TITLE must be at most 128 characters")
  }

  var flushMaxItems = parsePositiveInt(env["TRACERA_FLUSH_MAX_ITEMS"], fallback: 50)
  if flushMaxItems > 50 { flushMaxItems = 50 }
  let flushMaxMs = parsePositiveInt(env["TRACERA_FLUSH_MAX_MS"], fallback: 1000)
  var uploadConcurrency = parsePositiveInt(env["TRACERA_UPLOAD_CONCURRENCY"], fallback: 4)
  if uploadConcurrency > 16 { uploadConcurrency = 16 }

  return Config(
    baseURL: baseURL,
    token: token,
    projectId: projectId,
    testRunId: testRunId,
    runTitle: runTitle,
    requireReport: parseBool(env["TRACERA_REQUIRE_REPORT"], fallback: false),
    flushMaxItems: flushMaxItems,
    flushMaxMs: flushMaxMs,
    uploadConcurrency: uploadConcurrency
  )
}

private func trimRightSlashes(_ value: String) -> String {
  var end = value.endIndex
  while end > value.startIndex {
    let prev = value.index(before: end)
    if value[prev] != "/" { break }
    end = prev
  }
  return String(value[..<end])
}
