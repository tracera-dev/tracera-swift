import Foundation
import Testing
import Tracera

/// Shared trait body: TaskLocal pin, thrown errors → Failed, ``skip`` → Skipped.
///
/// `#expect` failures are recorded by Swift Testing itself; on Xcode 16 there is
/// no ``IssueHandlingTrait`` to mirror them into Tracera — prefer `throw` (or
/// ``Tracera/error``) when the result must be Failed in Tracera.
func runTraceraScoped(
  ctx: TestContext,
  activeId: String,
  test: Test,
  testCase: Test.Case?,
  function: @Sendable () async throws -> Void
) async throws {
  // `test` / `testCase` kept for call-site symmetry with `TestScoping.provideScope`.
  _ = test
  _ = testCase
  try await runWithContext(ctx) {
    setPhase(.test)
    do {
      try await function()
      if ctx.payloadHasFailedStep || ctx.hasResultFailure {
        markActiveFailed(id: activeId)
      }
    } catch is AttachScopeSkipError {
      // Out-of-attach-scope imperative bind — discard like declarative early return
      // (no card). Do not rethrow — Testing would mark Failed.
      discardActive(id: activeId)
      return
    } catch let skip as TraceraSkipError {
      // `skip(_:)` already called `markSkipped(reason)` when a context was pinned;
      // empty reason avoids appending the comment twice (CancellationError path).
      markActiveSkipped(id: activeId, reason: ctx.isSkipped ? "" : skip.reason)
      endActive(id: activeId)
      // Do not rethrow — Testing would mark Failed; Tracera already has Skipped.
      return
    } catch is CancellationError {
      // Bare `CancellationError` (e.g. e2e guards) — not ``skip``.
      if ctx.isSkipped {
        markActiveSkipped(id: activeId, reason: "")
      } else {
        ctx.recordFailure(formatFailureText(CancellationError()))
        markActiveFailed(id: activeId)
      }
      endActive(id: activeId)
      throw CancellationError()
    } catch {
      // Step path already recorded via `Tracera.step`; only fill result when empty.
      if !ctx.payloadHasStepError && !ctx.hasResultError {
        ctx.recordFailure(formatFailureText(error))
      }
      markActiveFailed(id: activeId)
      endActive(id: activeId)
      throw error
    }
  }
}

/// Prefer `Issue.sourceLocation` (customer `#expect` site) over `Thread.callStackSymbols`
/// captured inside this trait — those frames are adapter noise and fail `.swift:` e2e.
func failureText(for issue: Issue) -> String {
  let location = sourceLocationLine(issue.sourceLocation)
  if let err = issue.error {
    if let location {
      return formatFailureText(err, stack: location)
    }
    return formatFailureText(err)
  }
  let message = String(describing: issue)
  // No Error → do not invent adapter stack frames; location alone is enough.
  return formatFailureText(message, stack: location ?? "")
}

private func sourceLocationLine(_ location: SourceLocation?) -> String? {
  guard let location else { return nil }
  let path = sourceFilePath(location).trimmingCharacters(in: .whitespacesAndNewlines)
  if !path.isEmpty {
    return "\(path):\(location.line)"
  }
  let name = location.fileName.trimmingCharacters(in: .whitespacesAndNewlines)
  if !name.isEmpty {
    return "\(name):\(location.line)"
  }
  return nil
}

/// Xcode 16 exposes ``SourceLocation/_filePath``; newer Toolchains use `filePath`.
private func sourceFilePath(_ location: SourceLocation) -> String {
  for child in Mirror(reflecting: location).children {
    guard child.label == "filePath" || child.label == "_filePath" else { continue }
    if let s = child.value as? String { return s }
  }
  return location.fileName
}
