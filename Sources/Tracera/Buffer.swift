import Foundation

package actor ResultBuffer {
  private let session: Session
  private var items: [[String: Any]] = []
  private var idleTask: Task<Void, Never>?
  /// Serializes flushes so overlapping enqueue / idle / endReporting do not
  /// POST the same rows twice or race soft-disable counters.
  private var flushing = false
  private var flushWaiters: [CheckedContinuation<Void, Never>] = []

  package init(session: Session) {
    self.session = session
  }

  package func enqueue(_ item: PendingResult) {
    guard session.reportingEnabled else {
      discardPendingBlobs(item.payload)
      session.noteUnsentResults(1)
      return
    }
    guard let payload = item.payload ?? item.ctx.map({ $0.snapshotPayload() }) else { return }
    var wire = payload
    wire["durationMinutes"] = item.durationMinutes
    wire["result"] = item.result
    if let env = item.envVars { wire["envVars"] = env }
    if wire["__traceraTransportToken"] == nil {
      wire["__traceraTransportToken"] = UUID().uuidString
    }
    items.append(wire)
    if items.count >= session.config.flushMaxItems {
      // Detached — do not inherit XCTest / Testing cancellation of a failing case.
      Task.detached { await self.flush() }
    } else {
      scheduleIdleFlush()
    }
  }

  package func pendingCount() -> Int { items.count }

  /// Uploads buffered results. Retries once when items remain (Dart/Go parity).
  package func flush() async {
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
      flushWaiters.append(cont)
      if !flushing {
        flushing = true
        Task { await self.runFlushLoop() }
      }
    }
  }

  private func runFlushLoop() async {
    while true {
      await flushPass()
      let waiters = flushWaiters
      flushWaiters.removeAll()
      for waiter in waiters {
        waiter.resume()
      }
      if flushWaiters.isEmpty {
        flushing = false
        return
      }
    }
  }

  private func flushPass() async {
    await flushOnce(cancelIdle: true)
    if session.reportingEnabled, !items.isEmpty {
      await flushOnce(cancelIdle: true)
    }
  }

  private func flushOnce(cancelIdle: Bool) async {
    if cancelIdle {
      idleTask?.cancel()
      idleTask = nil
    } else {
      idleTask = nil
    }
    guard session.reportingEnabled else { return }
    guard !items.isEmpty else { return }

    var retryLater: [[String: Any]] = []
    while session.reportingEnabled, !items.isEmpty {
      let limit = max(1, session.config.flushMaxItems)
      let batch = Array(items.prefix(limit))
      items.removeFirst(batch.count)
      let requeued = await session.uploadBatch(batch)
      if !requeued.isEmpty {
        retryLater.append(contentsOf: requeued)
        break
      }
    }
    if !retryLater.isEmpty {
      items.insert(contentsOf: retryLater, at: 0)
    }
  }

  private func scheduleIdleFlush() {
    idleTask?.cancel()
    let ms = session.config.flushMaxMs
    idleTask = Task.detached {
      try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
      guard !Task.isCancelled else { return }
      await self.flush()
    }
  }
}
