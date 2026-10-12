import Testing
import Tracera

/// Thrown by ``skip(_:)`` so ``runTraceraScoped`` can finish the case as
/// Skipped. Used instead of ``Test/cancel(_:sourceLocation:)`` so the adapter
/// builds on Xcode 16 / Swift Testing before the cancellation API.
struct TraceraSkipError: Error, Sendable {
  let reason: String
}

/// Marks the bound result **Skipped** with `reason` as the result comment, then
/// ends the scoped body via ``TraceraSkipError`` (Tracera reports Skipped;
/// Swift Testing has no mid-test skip API on Xcode 16).
public func skip(_ reason: String) throws -> Never {
  getContext()?.markSkipped(reason)
  throw TraceraSkipError(reason: reason)
}
