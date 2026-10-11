import Foundation
import Testing
import Tracera

/// Opens a Tracera pin for the test without binding a case id.
/// Prefer ``Trait/traceraId(_:name:)`` when the id is a compile-time constant;
/// use this + ``Tracera/testCase(_:_:)`` when the id comes from the environment
/// (e2e) or is chosen mid-body.
public struct TraceraScopeTrait: TestTrait, SuiteTrait, TestScoping, Sendable {
  public init() {}

  public func provideScope(
    for test: Test,
    testCase: Test.Case?,
    performing function: @Sendable () async throws -> Void
  ) async throws {
    install()

    let params = bindParams(from: testCase, test: test)
    let template = resolvedBindTemplate(nameTemplate: nil, test: test)
    let displayName = formatBindName(template, params: params)
    let ctx = createTestContext(testCaseId: 0, autotestName: displayName)
    let activeId = "\(String(describing: test.id)):\(testCase.map { String(describing: $0) } ?? "0")"
    beginActive(id: activeId, ctx: ctx)

    try await runWithContext(ctx) {
      setPhase(.test)
      do {
        try await function()
        if ctx.payloadHasFailedStep {
          markActiveFailed(id: activeId)
        }
      } catch is CancellationError {
        if ctx.resultCommentText.isEmpty {
          markActiveSkipped(id: activeId, reason: "cancelled")
        } else {
          markActiveSkipped(id: activeId, reason: ctx.resultCommentText)
        }
        endActive(id: activeId)
        throw CancellationError()
      } catch {
        ctx.recordFailure(formatFailureText(error))
        markActiveFailed(id: activeId)
        endActive(id: activeId)
        throw error
      }
    }

    endActive(id: activeId)
  }
}

extension Trait where Self == TraceraScopeTrait {
  /// Opens reporting for the test; bind with ``Tracera/testCase(_:_:)``.
  public static var tracera: Self { TraceraScopeTrait() }
}
