import Foundation
import Tracera
import XCTest

final class TraceraXCTestObserver: NSObject, XCTestObservation {
  private let reporter: ReporterState
  private let screenshotMode: () -> ScreenshotMode
  private let hierarchyMode: () -> HierarchyMode
  private let logMode: () -> LogMode
  private var active: [ObjectIdentifier: Active] = [:]
  private let lock = NSLock()
  private var finishedReporting = false

  private struct Active {
    var ctx: TestContext
    var started: Date
    var logStart: Date
    var result: String = "Passed"
  }

  init(
    reporter: ReporterState,
    screenshotMode: @escaping () -> ScreenshotMode,
    hierarchyMode: @escaping () -> HierarchyMode,
    logMode: @escaping () -> LogMode
  ) {
    self.reporter = reporter
    self.screenshotMode = screenshotMode
    self.hierarchyMode = hierarchyMode
    self.logMode = logMode
  }

  /// Thread-local pin so overlapping XCTest cases do not cross-wire via the
  /// process fallback (Dart `resolveHostContext` pattern).
  private static let tlsKey = "tracera.xcuitest.ctx"

  func installHostResolver() {
    resolveHostContext = { [weak self] in
      if let tls = Thread.current.threadDictionary[Self.tlsKey] as? TestContext {
        return tls
      }
      // Serial fallback only — never cross-wire when more than one case is active.
      guard let self else { return nil }
      self.lock.lock()
      defer { self.lock.unlock() }
      if self.active.count == 1 { return self.active.values.first?.ctx }
      return nil
    }
  }

  func testCaseWillStart(_ testCase: XCTestCase) {
    let now = Date()
    // Start in Setup so stock `setUp` / `TraceraXCTestCase` work before `enterTest`.
    let ctx = createTestContext(
      testCaseId: 0,
      autotestName: testCase.name,
      section: .setup
    )
    lock.lock()
    active[ObjectIdentifier(testCase)] = Active(ctx: ctx, started: now, logStart: now)
    lock.unlock()
    Thread.current.threadDictionary[Self.tlsKey] = ctx
    installContext(ctx)
  }

  func testCase(_ testCase: XCTestCase, didRecord issue: XCTIssue) {
    // `XCTIssue.isFailure` is Xcode 26+; Xcode 16 only has `type`.
    switch issue.type {
    case .assertionFailure, .thrownError, .uncaughtException, .system:
      break
    default:
      return
    }
    lock.lock()
    guard var state = active[ObjectIdentifier(testCase)] else {
      lock.unlock()
      return
    }
    var stack = captureStack(skipFrames: 1)
    if let location = issue.sourceCodeContext.location {
      let path = location.fileURL.path
      if !path.isEmpty {
        stack = "\(path):\(location.lineNumber)\n\(stack)"
      }
    }
    let description = issue.compactDescription
    state.ctx.recordFailure(formatFailureText(description, stack: stack))
    state.result = "Failed"
    active[ObjectIdentifier(testCase)] = state
    lock.unlock()
  }

  func testCaseDidFinish(_ testCase: XCTestCase) {
    lock.lock()
    guard let state = active.removeValue(forKey: ObjectIdentifier(testCase)) else {
      lock.unlock()
      return
    }
    lock.unlock()

    if Thread.current.threadDictionary[Self.tlsKey] as? TestContext === state.ctx {
      Thread.current.threadDictionary[Self.tlsKey] = nil
    }

    // Out-of-attach-scope imperative bind — no card (name cleared; Go Cleanup-after parity).
    if state.ctx.isAttachScopeAbort {
      clearContext(state.ctx)
      discardPendingBlobs(state.ctx.snapshotPayload())
      return
    }

    var result = state.result
    if testCase.testRun?.hasSucceeded == false { result = "Failed" }
    if state.ctx.payloadHasFailedStep || state.ctx.hasResultFailure { result = "Failed" }
    // Prefer our `skip(_:)` pin; stock `hasBeenSkipped` must not override a
    // real failure (XCTest may mark setUp throws as both failed and skipped).
    if state.ctx.isSkipped {
      result = "Skipped"
    } else if testCase.testRun?.hasBeenSkipped == true, result != "Failed" {
      result = "Skipped"
      // Empty still discards pending blobs when no reason was recorded.
      state.ctx.markSkipped("")
    }

    let failed = result == "Failed" || state.ctx.payloadHasFailedStep
    if shouldCaptureScreenshot(mode: screenshotMode(), failed: failed) {
      let name = failed ? "failure.png" : "screenshot.png"
      _ = captureScreenshot(fileName: name, into: state.ctx)
    }
    if shouldCaptureHierarchy(mode: hierarchyMode(), failed: failed) {
      _ = captureHierarchy(fileName: "window-hierarchy.txt", into: state.ctx)
    }
    if shouldCaptureLog(mode: logMode(), failed: failed) {
      _ = captureDeviceLog(fileName: "device-log.txt", since: state.logStart, into: state.ctx)
    }

    clearContext(state.ctx)
    let item = PendingResult(ctx: state.ctx)
    item.payload = state.ctx.snapshotPayload()
    item.durationMinutes = durationMinutesFrom(elapsed: Date().timeIntervalSince(state.started))
    item.result = result
    // No XCUI_TEST_VERSION — omit when peer version is unresolved.
    item.envVars = mergeEnvVars()
    enqueueResult(reporter, item)
  }

  func testBundleDidFinish(_ testBundle: Bundle) {
    finishReporting()
  }

  /// Drain uploads and finish the run. Idempotent — `atexit` is a backstop when
  /// the observation center does not deliver `testBundleDidFinish`.
  func finishReporting() {
    lock.lock()
    if finishedReporting {
      lock.unlock()
      return
    }
    finishedReporting = true
    lock.unlock()
    resolveHostContext = nil
    let group = DispatchGroup()
    group.enter()
    let state = reporter
    // Detached so atexit still drains if the cooperative pool is shutting down.
    Task.detached(priority: .userInitiated) {
      await endReporting(state)
      group.leave()
    }
    _ = group.wait(timeout: .now() + 120)
  }
}

/// Escape hatch for plain `XCTestCase`: call at the end of `setUp`.
/// Prefer subclassing ``TraceraXCTestCase`` instead.
public func enterTest() { setPhase(.test) }

/// Escape hatch for plain `XCTestCase`: call at the start of `tearDown`.
/// Prefer subclassing ``TraceraXCTestCase`` instead.
public func enterTeardown() { setPhase(.teardown) }
