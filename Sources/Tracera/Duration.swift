import Foundation

/// Converts wall-clock milliseconds to `TestResult.durationMinutes`: one
/// decimal, half-up (same formula as every other language adapter).
package func durationMinutesFromMs(_ ms: Double) -> Double {
  if ms.isNaN || ms.isInfinite || ms <= 0 { return 0 }
  let tenths = (ms / 60_000) * 10
  return floor(tenths + 0.5) / 10
}

package func durationMinutesFrom(elapsed: TimeInterval) -> Double {
  durationMinutesFromMs(elapsed * 1000)
}
