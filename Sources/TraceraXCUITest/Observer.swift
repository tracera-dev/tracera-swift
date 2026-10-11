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
    installContext(ctx)
  }

  func testCase(_ testCase: XCTestCase, didFailWithDescription description: String, inFile filePath: String?, atLine lineNumber: Int) {
    lock.lock()
    guard var state = active[ObjectIdentifier(testCase)] else {
      lock.unlock()
      return
    }
    var stack = captureStack(skipFrames: 1)
    if let filePath, !filePath.isEmpty {
      stack = "\(filePath):\(lineNumber)\n\(stack)"
    }
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

    var result = state.result
    if testCase.testRun?.hasSucceeded == false { result = "Failed" }
    if state.ctx.payloadHasFailedStep { result = "Failed" }
    if testCase.testRun?.hasBeenSkipped == true {
      result = "Skipped"
      if state.ctx.resultCommentText.isEmpty {
        state.ctx.markSkipped("skipped")
      }
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
}

/// Escape hatch for plain `XCTestCase`: call at the end of `setUp`.
/// Prefer subclassing ``TraceraXCTestCase`` instead.
public func enterTest() { setPhase(.test) }

/// Escape hatch for plain `XCTestCase`: call at the start of `tearDown`.
/// Prefer subclassing ``TraceraXCTestCase`` instead.
public func enterTeardown() { setPhase(.teardown) }
