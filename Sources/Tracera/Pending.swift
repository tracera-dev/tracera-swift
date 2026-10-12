import Foundation

package struct PendingBlob: Sendable {
  package var fileName: String
  package var mimeType: String
  package var path: String?
  package var data: Data?
  /// When true, `path` is adapter-owned temp — unlink on discard / after upload.
  package var ephemeral: Bool
}

package enum PendingBlobs {
  private static let lock = NSLock()
  private nonisolated(unsafe) static var store: [String: PendingBlob] = [:]

  package static func register(
    id: String,
    fileName: String,
    mimeType: String,
    path: String?,
    data: Data?,
    ephemeral: Bool = false
  ) {
    lock.lock()
    defer { lock.unlock() }
    // Path-only when a path is present — never keep data+path.
    if let path, !path.isEmpty {
      store[id] = PendingBlob(
        fileName: fileName,
        mimeType: mimeType,
        path: path,
        data: nil,
        ephemeral: ephemeral
      )
    } else {
      store[id] = PendingBlob(
        fileName: fileName,
        mimeType: mimeType,
        path: nil,
        data: data,
        ephemeral: false
      )
    }
  }

  package static func take(id: String) -> PendingBlob? {
    lock.lock()
    defer { lock.unlock() }
    return store.removeValue(forKey: id)
  }

  package static func discard(id: String) {
    if let blob = take(id: id) {
      unlinkEphemeral(blob)
    }
  }

  package static func discardPendingFromPayload(_ payload: [String: Any]?) {
    guard let payload else { return }
    for id in collectPendingIds(payload) {
      discard(id: id)
    }
  }

  /// Unlink an adapter-owned temp path (after upload or on discard).
  package static func unlinkEphemeral(_ blob: PendingBlob) {
    guard blob.ephemeral, let path = blob.path, !path.isEmpty else { return }
    try? FileManager.default.removeItem(atPath: path)
  }

  /// Test / diagnostics — number of bodies still held.
  package static var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return store.count
  }

  /// Test isolation — drop every pending body (and ephemeral temps).
  package static func clearAll() {
    lock.lock()
    let blobs = Array(store.values)
    store.removeAll()
    lock.unlock()
    for blob in blobs {
      unlinkEphemeral(blob)
    }
  }

  /// Peek without taking (tests).
  package static func peek(id: String) -> PendingBlob? {
    lock.lock()
    defer { lock.unlock() }
    return store[id]
  }
}

package func discardPendingBlobs(_ payload: [String: Any]?) {
  PendingBlobs.discardPendingFromPayload(payload)
}

private func collectPendingIds(_ value: Any) -> [String] {
  var out: [String] = []
  if let dict = value as? [String: Any] {
    if let id = dict["attachmentId"] as? String, id.hasPrefix("pending:") {
      out.append(id)
    }
    for v in dict.values { out.append(contentsOf: collectPendingIds(v)) }
  } else if let arr = value as? [Any] {
    for v in arr { out.append(contentsOf: collectPendingIds(v)) }
  }
  return out
}

package final class PendingResult: @unchecked Sendable {
  package var ctx: TestContext?
  package var payload: [String: Any]?
  package var durationMinutes: Double = 0
  package var result: String = "Passed"
  package var envVars: [String: String]?

  package init(ctx: TestContext?) {
    self.ctx = ctx
  }
}
