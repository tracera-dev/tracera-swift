import Foundation

/// Customer surface of the Tracera Autotest adapters for Swift: bind, steps,
/// comments, errors, attachments and context pinning.
///
/// Runner wiring lives in the `TraceraTesting` / `TraceraXCUITest` products.
/// Use ``step(_:body:)`` for nested steps (sync or async).
///
/// Customer how-to: https://tracera.dev/docs/adapters
public enum Tracera {
  /// Binds the running test to a Tracera test case id, with an optional result name.
  ///
  /// Out-of-attach-scope bound ids abort execution (Go/Dart/JS parity): the runner
  /// skip handler runs, or ``AttachScopeSkipError`` is thrown. Call with `try`.
  /// Declarative ``Trait/traceraId(_:name:)`` skips before the body instead.
  public static func testCase(_ testCaseId: Int, _ name: String? = nil) throws {
    if testCaseId > 0 && !isAllowed(testCaseId) {
      logAttachSkipExecution(testCaseId: testCaseId)
      // Do not bind (Go parity). Clear name so Observer finish cannot upload Unknown.
      if let ctx = getContext() {
        ctx.markAttachScopeAbort()
      }
      if let handler = attachScopeSkipHandler {
        try handler(attachOutOfScopeReason)
      }
      throw AttachScopeSkipError()
    }
    guard let ctx = getContext() else { return }
    ctx.setTestCaseId(testCaseId)
    if let name, !name.isEmpty { ctx.autotestName = name }
  }

  /// Records `body` as a reported step. Steps nest; thrown errors fail the step
  /// and keep propagating.
  @discardableResult
  public static func step<T>(_ title: String, body: () throws -> T) rethrows -> T {
    guard let ctx = getContext() else { return try body() }
    _ = ctx.beginStep(title: title)
    do {
      let value = try body()
      ctx.endStep(failed: false)
      return value
    } catch {
      // Mid-test `skip` / attach abort marks the context then throws a runner-local
      // error (`TraceraSkipError` / `XCTSkip` / ``AttachScopeSkipError``) — close
      // without fail. Bare `CancellationError` keeps the same non-fail close.
      if ctx.isSkipped || ctx.isAttachScopeAbort || error is CancellationError
        || error is AttachScopeSkipError
      {
        ctx.endStep(failed: false)
      } else {
        ctx.endStep(failed: true, errorMessage: formatFailureText(error))
      }
      throw error
    }
  }

  /// Async step — stays open until the future settles.
  @discardableResult
  public static func step<T>(_ title: String, body: () async throws -> T) async rethrows -> T {
    guard let ctx = getContext() else { return try await body() }
    _ = ctx.beginStep(title: title)
    do {
      let value = try await body()
      ctx.endStep(failed: false)
      return value
    } catch {
      if ctx.isSkipped || ctx.isAttachScopeAbort || error is CancellationError
        || error is AttachScopeSkipError
      {
        ctx.endStep(failed: false)
      } else {
        ctx.endStep(failed: true, errorMessage: formatFailureText(error))
      }
      throw error
    }
  }

  /// Adds text to the open step, or to the result when no step is open.
  public static func comment(_ text: String) {
    getContext()?.addComment(text)
  }

  /// Soft error on the open step or result — does not by itself fail the test.
  public static func error(_ text: String) {
    getContext()?.addError(text)
  }

  /// Attaches a blob that is already uploaded (you hold its Tracera id).
  public static func attachment(_ meta: AttachmentMeta) {
    getContext()?.addAttachment(meta)
  }

  /// Attaches a file from disk to the open step or result.
  public static func attachmentFile(_ path: String, mimeType: String? = nil) {
    // Soft: empty path must not register a pending slot (Go/Dart parity).
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let name = URL(fileURLWithPath: trimmed).lastPathComponent
    let mime = mimeType ?? guessMimeType(fileName: name)
    getContext()?.addPendingAttachment(fileName: name, mimeType: mime, path: trimmed, data: nil)
  }

  /// Attaches in-memory bytes to the open step or result.
  public static func attachmentBytes(_ fileName: String, data: Data, mimeType: String? = nil) {
    // Soft: empty body — no slot (JS/Python/JVM/.NET unified attachment parity).
    guard !data.isEmpty else { return }
    let mime = mimeType ?? guessMimeType(fileName: fileName)
    getContext()?.addPendingAttachment(fileName: fileName, mimeType: mime, path: nil, data: data)
  }
}
