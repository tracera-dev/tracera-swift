import Foundation

/// Attach execution filter — allow-list from attach-scope GET.
package struct AttachScope: Sendable {
  package let rootTestCaseIds: [Int]
}

/// Shared runner skip reason for out-of-attach-scope bound cases.
public let attachOutOfScopeReason = "Tracera: case not in attach scope"

/// Thrown by ``Tracera/testCase(_:_:)`` when a bound id is out of attach scope
/// and no runner skip handler is installed (Go panic / Dart `StateError` parity).
public struct AttachScopeSkipError: Error, Sendable {
  /// Human-readable skip reason (defaults to ``attachOutOfScopeReason``).
  public let message: String
  /// Creates an out-of-scope abort with an optional custom reason.
  public init(_ message: String = attachOutOfScopeReason) {
    self.message = message
  }
}

/// Runner-registered abort for out-of-attach-scope imperative bind
/// (Testing → ``AttachScopeSkipError``; XCUITest → `XCTSkip`). Must not return.
package var attachScopeSkipHandler: ((String) throws -> Never)?

private let lock = NSLock()
private var allowedRoots: Set<Int>?
private var executionSkipLogged = Set<Int>()

package func resetAttachFilterForTests() {
  lock.lock()
  defer { lock.unlock() }
  allowedRoots = nil
  executionSkipLogged.removeAll()
  attachScopeSkipHandler = nil
}

/// Installs the runner skip callback used by ``Tracera/testCase(_:_:)``.
package func setAttachScopeSkipHandler(_ fn: ((String) throws -> Never)?) {
  attachScopeSkipHandler = fn
}

package func setAttachFilter(_ scope: AttachScope?) {
  lock.lock()
  defer { lock.unlock() }
  allowedRoots = scope.map { Set($0.rootTestCaseIds) }
  executionSkipLogged.removeAll()
}

/// Bound id allowed to run+report. Unbound (`<= 0`) always true. Plugin/runner only.
package func isAllowed(_ testCaseId: Int) -> Bool {
  if testCaseId <= 0 { return true }
  lock.lock()
  let roots = allowedRoots
  lock.unlock()
  guard let roots else { return true }
  return roots.contains(testCaseId)
}

package func logAttachSkipExecution(testCaseId: Int) {
  lock.lock()
  executionSkipLogged.insert(testCaseId)
  lock.unlock()
  logDebug("Tracera: skip execution — case \(testCaseId) not in attach scope")
  // Clear name + abort flag so finish paths cannot upload Unknown / prior bind.
  getContext()?.markAttachScopeAbort()
}

/// Report-path belt log; suppressed when execution-skip already logged.
package func logAttachSkipReport(testCaseId: Int, label: String? = nil) {
  lock.lock()
  let had = executionSkipLogged.remove(testCaseId) != nil
  lock.unlock()
  if had { return }
  let name = (label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
  logDebug(
    "Tracera: skip report — case \(testCaseId) not in attach scope (\(name.isEmpty ? "bound" : name))"
  )
}

package func shouldReport(testCaseId: Int, autotestName: String) -> Bool {
  if testCaseId > 0 { return isAllowed(testCaseId) }
  return !autotestName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

/// Parses attach-scope JSON; non-object / nil → `nil` (fail-open, do not filter).
/// Empty object → empty allow-list (intentional filter with no roots).
package func parseAttachScope(json: [String: Any]?) -> AttachScope? {
  guard let json else { return nil }
  let roots =
    (json["rootTestCaseIds"] as? [Any])?.compactMap { attachScopeId($0) } ?? []
  return AttachScope(rootTestCaseIds: roots)
}

/// Coerce a JSON / in-memory id — `NSNumber` (JSONSerialization) **or** Swift `Int`.
private func attachScopeId(_ value: Any) -> Int? {
  // JSONSerialization booleans are NSNumber/CFBoolean and also bridge to Int (1/0).
  // Reject those before any numeric cast.
  if let n = value as? NSNumber, CFGetTypeID(n as CFTypeRef) == CFBooleanGetTypeID() {
    return nil
  }
  if let i = value as? Int { return i }
  if let i = value as? Int64 { return Int(i) }
  if let n = value as? NSNumber {
    return n.intValue
  }
  return nil
}

private func cachePath(projectId: Int, testRunId: Int) -> URL {
  let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    .appendingPathComponent("tracera-attach-scope", isDirectory: true)
  return base.appendingPathComponent("p\(projectId)-r\(testRunId).json")
}

package func readAttachScopeCache(projectId: Int, testRunId: Int) -> AttachScope? {
  let url = cachePath(projectId: projectId, testRunId: testRunId)
  guard let data = try? Data(contentsOf: url),
    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  else {
    return nil
  }
  return parseAttachScope(json: json)
}

package func writeAttachScopeCache(projectId: Int, testRunId: Int, scope: AttachScope) {
  let url = cachePath(projectId: projectId, testRunId: testRunId)
  do {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let payload: [String: Any] = ["rootTestCaseIds": scope.rootTestCaseIds]
    let data = try JSONSerialization.data(withJSONObject: payload)
    let tmp = url.appendingPathExtension("tmp")
    try data.write(to: tmp, options: .atomic)
    _ = try? FileManager.default.removeItem(at: url)
    try FileManager.default.moveItem(at: tmp, to: url)
  } catch {
    // cache is optional
  }
}
