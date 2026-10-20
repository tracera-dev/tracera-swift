import Foundation
import Tracera
import XCTest

private let installLock = NSLock()
private nonisolated(unsafe) var installed = false
/// True while the first caller is inside `beginReporting` — other callers wait
/// so overlapping `install()` cannot open two owned runs.
private nonisolated(unsafe) var installing = false
private let installWaiters = DispatchSemaphore(value: 0)
private nonisolated(unsafe) var installWaiterCount = 0
private nonisolated(unsafe) var atexitRegistered = false
private nonisolated(unsafe) var screenshotMode: ScreenshotMode = .off
private nonisolated(unsafe) var hierarchyMode: HierarchyMode = .off
private nonisolated(unsafe) var logMode: LogMode = .off
private nonisolated(unsafe) var reporter = createReporterState()
private nonisolated(unsafe) var observer: TraceraXCTestObserver?

/// Opens reporting for this UI-test process. Call once (for example in
/// `setUp` of the first case, or a principal class).
///
/// - Parameters:
///   - screenshots: automatic PNG policy (default `.off`).
///   - hierarchy: automatic accessibility / window dump policy (default `.off`).
///   - logs: automatic unified-log dump policy (default `.off`; attaches
///     `device-log.txt` — test-process / host unified log, not a remote device).
public func install(
  screenshots: ScreenshotMode = .off,
  hierarchy: HierarchyMode = .off,
  logs: LogMode = .off
) {
  installLock.lock()
  screenshotMode = screenshots
  hierarchyMode = hierarchy
  logMode = logs
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

  // Mid-body testCase(out-of-scope) → XCTSkip (Observer finish + shouldReport drop).
  setAttachScopeSkipHandler { reason in
    throw XCTSkip(reason)
  }

  let obs = TraceraXCTestObserver(
    reporter: reporter,
    screenshotMode: { screenshotMode },
    hierarchyMode: { hierarchyMode },
    logMode: { logMode }
  )
  obs.installHostResolver()
  observer = obs
  XCTestObservationCenter.shared.addTestObserver(obs)

  if !atexitRegistered {
    atexitRegistered = true
    // Preferred finish path is `testBundleDidFinish` (blocks until drain).
    // `atexit` covers runners that tear down without delivering that callback.
    atexit {
      observer?.finishReporting()
    }
  }
  installLock.unlock()

  let sem = DispatchSemaphore(value: 0)
  Task.detached(priority: .userInitiated) {
    await beginReporting(reporter)
    sem.signal()
    // Always complete the handshake here — even after the caller timed out —
    // so `installing` stays true until this Task finishes and a second
    // `beginReporting` cannot open another owned run.
    completeInstallHandshake()
  }
  if sem.wait(timeout: .now() + 60) != .success {
    // Leave `installing` true until `completeInstallHandshake`. Do not clear
    // the host resolver — the in-flight beginReporting may still succeed.
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
