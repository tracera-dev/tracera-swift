# TraceraXCUITest

Tracera Autotest adapter for XCTest / XCUITest.

**Requires Swift ≥ 6**, **macOS ≥ 15** (or **iOS ≥ 18**), and **Xcode ≥ 16**, plus the XCTest / XCUIAutomation frameworks.

```swift
// Package.swift (or Xcode package product)
.package(url: "https://github.com/tracera-dev/tracera-swift.git", from: "0.1.0"),
// …
.product(name: "TraceraXCUITest", package: "tracera-swift"),
```

How-to: [XCUITest](https://tracera.dev/docs/xcuitest). Shared env / run mode: [Autotest adapters](https://tracera.dev/docs/adapters).

Subclass **`TraceraXCTestCase`** and call **`install()`** once (for example in `class setUp`). Without `install()`, nothing is reported. Media capture defaults to off — pass modes only when you want automatic screenshots / hierarchy / logs (see Screenshots):

```swift
import XCTest
import Tracera
import TraceraXCUITest

final class CheckoutUITests: TraceraXCTestCase {
  override class func setUp() {
    install()
  }
  // …
}
```

When you override `setUp` / `tearDown`, call `super.setUp()` at the **end** of `setUp` and `super.tearDown()` at the **start** of `tearDown` so steps land in **Setup** / **Test** / **Teardown**.

## Bind

Bind with `Tracera.testCase` at the start of each test method:

```swift
func testCheckout() {
  Tracera.testCase(42)
  // Tracera.testCase(42, "e2e/checkout")
  // …
}
```

If `name` is omitted, `autotestName` takes the value of the XCTest test name. You can bind in `setUp` instead when several methods share one case id. A test that never binds reports nothing.

## Skip

Use `XCTSkip` / `XCTSkipIf` so the result is reported as **Skipped**. Optional: set a result `comment` with `Tracera.comment` before calling skip.

## Steps

Use `Tracera.step("…") { }` or `await Tracera.step("…") { }`. Steps inside `setUp` / `tearDown` go to the result’s **Setup** / **Teardown**; steps inside the test go to **Test**.

```swift
override func setUp() {
  Tracera.step("launch app") { }
  super.setUp()
}

func testCheckout() throws {
  Tracera.testCase(10)
  try Tracera.step("tap checkout") {
    try Tracera.step("nested leaf") { }
  }
}

override func tearDown() {
  super.tearDown()
  Tracera.step("terminate app") { }
}
```

If you already have your own `XCTestCase` base class (Swift allows only one superclass), call `enterTest()` at the end of `setUp` and `enterTeardown()` at the start of `tearDown` instead of subclassing `TraceraXCTestCase`.

## Comments, errors, and attachments

`Tracera.comment`, `Tracera.error`, and the attachment helpers attach to the open step, or to the result when no step is open. Shared placement and `Tracera.error` rules: https://tracera.dev/docs/adapters.

`Tracera.attachmentFile` takes a file path; `Tracera.attachmentBytes` takes a name and bytes (MIME type is optional). Attachments upload when the result is reported.

```swift
Tracera.comment("result-level note")
Tracera.error("result-level error")
Tracera.attachmentFile("Fixtures/screenshot.png")
Tracera.step("open login") {
  Tracera.comment("step note")
  Tracera.attachmentBytes("body.json", data: Data(#"{"ok":true}"#.utf8), mimeType: "application/json")
}
```

If you start a `Task` and call Tracera APIs there, save the context on the test task first and run the worker with `runWithContext` — otherwise those calls are not reported:

```swift
let ctx = getContext()
Task {
  await runWithContext(ctx) {
    Tracera.step("worker") { /* ... */ }
  }
}
```

## Screenshots and media

`install()` is required for reporting (see above). Use its parameters to attach media at the **end** of each test (default `.off`): `screenshots:` — `.onFailure` / `.onSuccess` / `.always` (iOS/tvOS: `XCUIScreen`; macOS: ScreenCaptureKit when screen recording is allowed); `hierarchy:` → `window-hierarchy.txt`; `logs:` → `device-log.txt` (unified log / `OSLogStore`).

```swift
override class func setUp() {
  install(screenshots: .onFailure, hierarchy: .onFailure, logs: .onFailure)
}
```

To capture a screenshot, hierarchy, or device log at a chosen moment (for example after a tap), call manually:

```swift
Tracera.step("after login") {
  screenshot()
  attachHierarchy()
  attachDeviceLog()
}
```

XCTest does not expose `XCTAttachment` payloads to observers — use `Tracera.attachmentFile` / `Tracera.attachmentBytes` for intentional dumps.
