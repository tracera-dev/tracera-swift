import Tracera
import XCTest

/// Preferred XCTest / XCUITest base class: maps stock `setUp` / `tearDown` to
/// Tracera **Setup** / **Test** / **Teardown** without `enterTest` /
/// `enterTeardown` homework.
///
/// Contract (same as classic XCTest base-class hooks):
/// - Call `super.setUp()` at the **end** of your override (after Setup steps).
/// - Call `super.tearDown()` / `super.tearDownWithError()` at the **start** of
///   your override (before Teardown steps).
///
/// Plain `XCTestCase` subclasses can still use `enterTest()` / `enterTeardown()`;
/// new suites should inherit this type instead.
open class TraceraXCTestCase: XCTestCase {
  /// Re-assert Setup before XCTest runs `setUp` (observer also starts in Setup).
  open override func invokeTest() {
    setPhase(.setup)
    super.invokeTest()
  }

  open override func setUp() {
    super.setUp()
    // Enter Test only from `setUp` after the subclass calls `super` at the end.
    // Do **not** flip the phase in `setUpWithError` — on Apple XCTest that
    // method runs *before* `setUp`, which would put Setup steps into Test.
    setPhase(.test)
  }

  open override func tearDown() {
    setPhase(.teardown)
    super.tearDown()
  }

  open override func tearDownWithError() throws {
    setPhase(.teardown)
    try super.tearDownWithError()
  }
}
