import Foundation

package actor ResultBuffer {
  private let session: Session
  private var items: [[String: Any]] = []
  private var flushTask: Task<Void, Never>?

  package init(session: Session) {
    self.session = session
  }

  package func enqueue(_ item: PendingResult) {
    guard let payload = item.payload ?? item.ctx.map({ $0.snapshotPayload() }) else { return }
    var wire = payload
    wire["durationMinutes"] = item.durationMinutes
    wire["result"] = item.result
    if let env = item.envVars { wire["envVars"] = env }
    items.append(wire)
    if items.count >= session.config.flushMaxItems {
      Task { await flush() }
    } else {
      scheduleIdleFlush()
    }
  }

  package func pendingCount() -> Int { items.count }

  /// Uploads buffered results. Retries once when items remain (Dart/Go parity).
  package func flush() async {
    await flushOnce()
    if session.reportingEnabled, !items.isEmpty {
      await flushOnce()
    }
  }

  private func flushOnce() async {
    let batch = items
    items = []
    flushTask?.cancel()
    flushTask = nil
    guard !batch.isEmpty else { return }
    let requeued = await session.uploadBatch(batch)
    if !requeued.isEmpty {
      items.insert(contentsOf: requeued, at: 0)
    }
  }

  private func scheduleIdleFlush() {
    flushTask?.cancel()
    let ms = session.config.flushMaxMs
    flushTask = Task {
      try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
      guard !Task.isCancelled else { return }
      await flush()
    }
  }
}
