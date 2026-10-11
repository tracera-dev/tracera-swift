import Foundation
import Tracera
import XCTest

private let installLock = NSLock()
private nonisolated(unsafe) var installed = false
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
///     `device-log.txt`).
public func install(
  screenshots: ScreenshotMode = .off,
  hierarchy: HierarchyMode = .off,
  logs: LogMode = .off
) {
  installLock.lock()
  defer { installLock.unlock() }
  screenshotMode = screenshots
  hierarchyMode = hierarchy
  logMode = logs
  guard !installed else { return }
  installed = true

  if let peer = ProcessInfo.processInfo.environment["TRACERA_PEER_WORKER"],
     !peer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
    reporter.peerWorker = peer
  }

  let obs = TraceraXCTestObserver(
    reporter: reporter,
    screenshotMode: { screenshotMode },
    hierarchyMode: { hierarchyMode },
    logMode: { logMode }
  )
  observer = obs
  XCTestObservationCenter.shared.addTestObserver(obs)

  let sem = DispatchSemaphore(value: 0)
  Task {
    await beginReporting(reporter)
    sem.signal()
  }
  _ = sem.wait(timeout: .now() + 60)

  atexit {
    let done = DispatchSemaphore(value: 0)
    Task {
      await endReporting(reporter)
      done.signal()
    }
    _ = done.wait(timeout: .now() + 120)
  }
}
