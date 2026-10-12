import Tracera
import XCTest

/// Marks the bound result **Skipped** with `reason` as the result comment, then
/// throws ``XCTSkip`` so XCTest records a skip.
///
/// Prefer this over bare `throw XCTSkip(…)`: XCTest does not expose the skip
/// message to observers, so stock `XCTSkip` alone cannot fill the result comment.
public func skip(_ reason: String) throws -> Never {
  getContext()?.markSkipped(reason)
  throw XCTSkip(reason)
}
