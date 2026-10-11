import Foundation
import Synchronization

/// Bounded async pool — one bad job is logged and swallowed so drain continues.
///
/// `enqueue` / `schedule` bump outstanding work **synchronously** so a sync
/// caller (test hooks) cannot race `drain` the way a fire-and-forget `Task`
/// wrapping an actor hop would.
package final class JobPool: Sendable {
  /// Clamped concurrency (1…16).
  package let concurrency: Int

  private struct State {
    var queue: [@Sendable () async -> Void] = []
    var active = 0
    /// Queued + running (+ accepted but not yet finished).
    var outstanding = 0
    var waiters: [CheckedContinuation<Void, Never>] = []
  }

  private let state = Mutex(State())

  package init(_ concurrency: Int) {
    self.concurrency = max(1, min(concurrency, 16))
  }

  /// Schedules a job from a sync context (Dart/Go `Enqueue` parity).
  package func schedule(_ job: @escaping @Sendable () async throws -> Void) {
    enqueue(job)
  }

  /// Same as `schedule` — kept for call sites that historically awaited.
  package func enqueue(_ job: @escaping @Sendable () async throws -> Void) {
    let wrapped: @Sendable () async -> Void = {
      do {
        try await job()
      } catch {
        // Swallow — callers own handling inside the job. Debug so a bad
        // attachment is diagnosable without polluting default info runs.
        logDebug("Tracera: upload job failed: \(error)")
      }
    }
    let toStart: [@Sendable () async -> Void] = state.withLock { s in
      s.outstanding += 1
      s.queue.append(wrapped)
      return takeRunnableLocked(&s)
    }
    for job in toStart {
      start(job)
    }
  }

  /// Waits until every scheduled job finished.
  package func drain() async {
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
      let resumeNow = state.withLock { s -> Bool in
        if s.outstanding == 0 {
          return true
        }
        s.waiters.append(cont)
        return false
      }
      if resumeNow {
        cont.resume()
      }
    }
  }

  private func takeRunnableLocked(_ s: inout State) -> [@Sendable () async -> Void] {
    var out: [@Sendable () async -> Void] = []
    while s.active < concurrency, !s.queue.isEmpty {
      let job = s.queue.removeFirst()
      s.active += 1
      out.append(job)
    }
    return out
  }

  private func start(_ job: @escaping @Sendable () async -> Void) {
    Task {
      await job()
      let (more, waiters): ([@Sendable () async -> Void], [CheckedContinuation<Void, Never>]) =
        state.withLock { s in
          s.active -= 1
          s.outstanding -= 1
          let more = takeRunnableLocked(&s)
          if s.outstanding == 0 {
            let pending = s.waiters
            s.waiters.removeAll()
            return (more, pending)
          }
          return (more, [])
        }
      for w in waiters { w.resume() }
      for next in more {
        start(next)
      }
    }
  }
}
