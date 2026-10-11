import Foundation
import Testing
import Tracera

private let installLock = NSLock()
private nonisolated(unsafe) var installed = false
private nonisolated(unsafe) var reporter = createReporterState()
private nonisolated(unsafe) var activeByID: [String: ActiveTest] = [:]
private let activeLock = NSLock()

private struct ActiveTest {
  var ctx: TestContext
  var started: Date
  var result: String = "Passed"
}

/// Opens reporting for this process. Call once per test target (like Dart
/// `installTracera()`). Safe to call more than once.
public func install() {
  installLock.lock()
  defer { installLock.unlock() }
  guard !installed else { return }
  installed = true

  if let peer = ProcessInfo.processInfo.environment["TRACERA_PEER_WORKER"],
     !peer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
    reporter.peerWorker = peer
  }

  let ready = DispatchSemaphore(value: 0)
  Task {
    await beginReporting(reporter)
    ready.signal()
  }
  _ = ready.wait(timeout: .now() + 60)

  atexit {
    let sem = DispatchSemaphore(value: 0)
    Task {
      await finishInstalled()
      sem.signal()
    }
    _ = sem.wait(timeout: .now() + 120)
  }
}

private func finishInstalled() async {
  await endReporting(reporter)
}

func beginActive(id: String, ctx: TestContext) {
  activeLock.lock()
  activeByID[id] = ActiveTest(ctx: ctx, started: Date())
  activeLock.unlock()
  installContext(ctx)
}

func markActiveFailed(id: String) {
  activeLock.lock()
  activeByID[id]?.result = "Failed"
  activeLock.unlock()
}

func markActiveSkipped(id: String, reason: String) {
  activeLock.lock()
  if var state = activeByID[id] {
    state.result = "Skipped"
    state.ctx.markSkipped(reason)
    activeByID[id] = state
  }
  activeLock.unlock()
}

func endActive(id: String) {
  activeLock.lock()
  let state = activeByID.removeValue(forKey: id)
  activeLock.unlock()
  guard let state else { return }
  clearContext(state.ctx)

  let item = PendingResult(ctx: state.ctx)
  item.payload = state.ctx.snapshotPayload()
  item.durationMinutes = durationMinutesFrom(elapsed: Date().timeIntervalSince(state.started))
  var result = state.result
  if state.ctx.payloadHasFailedStep { result = "Failed" }
  item.result = result
  // No SWIFT_TESTING_VERSION — toolchain-bundled; omit when peer is unresolved.
  item.envVars = mergeEnvVars()
  enqueueResult(reporter, item)
}
