import Foundation
import Testing
import Tracera

private let installLock = NSLock()
private nonisolated(unsafe) var installed = false
/// True while the first caller is inside `beginReporting` — other callers wait
/// so suite `init` + trait `install()` cannot open two owned runs.
private nonisolated(unsafe) var installing = false
private let installWaiters = DispatchSemaphore(value: 0)
private nonisolated(unsafe) var installWaiterCount = 0
private nonisolated(unsafe) var atexitRegistered = false
private nonisolated(unsafe) var reporter = createReporterState()
private nonisolated(unsafe) var activeByID: [String: ActiveTest] = [:]
private let activeLock = NSLock()
private nonisolated(unsafe) var finishedReporting = false

private struct ActiveTest {
  var ctx: TestContext
  var started: Date
  var result: String = "Passed"
}

/// Opens reporting for this process. Call once per test target (like Dart
/// `installTracera()`). Safe to call more than once.
public func install() {
  installLock.lock()
  if installed {
    installLock.unlock()
    return
  }
  if installing {
    installWaiterCount += 1
    installLock.unlock()
    _ = installWaiters.wait(timeout: .now() + 60)
    return
  }
  installing = true

  if let peer = ProcessInfo.processInfo.environment["TRACERA_PEER_WORKER"],
    !peer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  {
    reporter.peerWorker = peer
  }

  // Prefer host resolver over process fallback under in-process overlap
  // (Swift Testing may schedule concurrent cases; TaskLocal still wins).
  resolveHostContext = { resolveActiveContext() }
  // Mid-body testCase(out-of-scope) → AttachScopeSkipError (ScopeRun discards).
  setAttachScopeSkipHandler { reason in
    throw AttachScopeSkipError(reason)
  }

  if !atexitRegistered {
    atexitRegistered = true
    // Swift Testing has no public bundle-finish observer. Drain on process exit
    // with a detached task so the cooperative pool can still run during teardown
    // (plain `Task { }` can stall if atexit races the executor shutdown).
    atexit {
      finishInstalledSync()
    }
  }
  installLock.unlock()

  let ready = DispatchSemaphore(value: 0)
  // Detached — same reason as atexit: plain Task can stall on the test executor.
  Task.detached(priority: .userInitiated) {
    await beginReporting(reporter)
    ready.signal()
    // Always complete the handshake here — even after the caller timed out —
    // so `installing` stays true until this Task finishes and a second
    // `beginReporting` cannot open another owned run.
    completeInstallHandshake()
  }
  if ready.wait(timeout: .now() + 60) != .success {
    // Leave `installing` true until `completeInstallHandshake`. Do not clear
    // `resolveHostContext` — the in-flight beginReporting may still succeed.
    logError("Tracera: install timed out waiting for beginReporting")
  }
}

/// Marks install finished and wakes waiters. Called only from the beginReporting Task.
private func completeInstallHandshake() {
  installLock.lock()
  installed = true
  installing = false
  let wake = installWaiterCount
  installWaiterCount = 0
  installLock.unlock()
  for _ in 0..<wake {
    installWaiters.signal()
  }
}

func activeTestID(test: Test, testCase: Test.Case?) -> String {
  let casePart = testCase.map { String(describing: $0) } ?? "0"
  return "\(String(describing: test.id)):\(casePart)"
}

private func resolveActiveContext() -> TestContext? {
  guard let test = Test.current else { return nil }
  let activeId = activeTestID(test: test, testCase: Test.Case.current)
  activeLock.lock()
  let ctx = activeByID[activeId]?.ctx
  activeLock.unlock()
  return ctx
}

private func finishInstalledSync() {
  installLock.lock()
  if finishedReporting {
    installLock.unlock()
    return
  }
  finishedReporting = true
  installLock.unlock()
  resolveHostContext = nil

  let group = DispatchGroup()
  group.enter()
  Task.detached(priority: .userInitiated) {
    await endReporting(reporter)
    group.leave()
  }
  _ = group.wait(timeout: .now() + 120)
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

  if state.ctx.isAttachScopeAbort {
    discardPendingBlobs(state.ctx.snapshotPayload())
    return
  }

  let item = PendingResult(ctx: state.ctx)
  item.payload = state.ctx.snapshotPayload()
  item.durationMinutes = durationMinutesFrom(elapsed: Date().timeIntervalSince(state.started))
  // Skip wins over incidental cancel/issue noise after `markSkipped` — do not
  // promote Skipped → Failed.
  var result = state.result
  if state.ctx.isSkipped {
    result = "Skipped"
  } else if state.ctx.payloadHasFailedStep || state.ctx.hasResultError {
    result = "Failed"
  }
  item.result = result
  // No SWIFT_TESTING_VERSION — toolchain-bundled; omit when peer is unresolved.
  item.envVars = mergeEnvVars()
  enqueueResult(reporter, item)
}

/// Drop pin without uploading (attach-scope abort — declarative early-return parity).
func discardActive(id: String) {
  activeLock.lock()
  let state = activeByID.removeValue(forKey: id)
  activeLock.unlock()
  guard let state else { return }
  clearContext(state.ctx)
  discardPendingBlobs(state.ctx.snapshotPayload())
}
