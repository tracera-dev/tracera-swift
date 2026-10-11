import Testing
import Tracera

/// Marks the bound result **Skipped** with `reason` as the result comment, then
/// throws `CancellationError` so Swift Testing records a skip.
public func skip(_ reason: String) throws -> Never {
  getContext()?.markSkipped(reason)
  throw CancellationError()
}
