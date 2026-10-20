# TraceraTesting

Tracera Autotest adapter for [Swift Testing](https://developer.apple.com/xcode/swift-testing/).

**Tested on Swift 6.1–6.4** (macOS 15–27 / Xcode 16.3–27).

```swift
// Package.swift
.package(url: "https://github.com/tracera-dev/tracera-swift.git", from: "1.0.0"),
// …
.product(name: "TraceraTesting", package: "tracera-swift"),
```

How-to: [Swift Testing](https://tracera.dev/docs/swift-testing). Shared env / run mode: [Autotest adapters](https://tracera.dev/docs/adapters#environment).

## Bind

Preferred declarative bind:

```swift
@Test("checkout", .traceraId(42))
func checkout() {
  // …
}

@Test("login as {user}", .traceraId(42), arguments: ["alice", "bob"])
func login(user: String) {
  // …
}

// Keep the Swift Testing display name; report a templated `autotestName`:
@Test("login", .traceraId(42, name: "login as {user}"), arguments: ["alice", "bob"])
func loginNamed(user: String) {
  // …
}
```

When the id is not a compile-time constant, open a pin with `.tracera` and bind imperatively:

```swift
@Test("checkout", .tracera)
func checkout() throws {
  try Tracera.testCase(42)
  // try Tracera.testCase(42, "e2e/checkout")
}
```

A test that never binds reports nothing.

## Skip

Use `skip("reason")` so the reason is added to the result as `comment`:

```swift
@Test("checkout", .traceraId(42))
func checkout() throws {
  try skip("needs a seeded account")
}
```

## Steps

Use `Tracera.step("…") { … }` (sync or `async`). Steps inside `setup` / `teardown` go to **Setup** / **Teardown**; other steps go to **Test**.

```swift
@Test("checkout", .traceraId(10))
func checkout() {
  setup("open shop") {}
  Tracera.step("add item") {
    Tracera.step("nested leaf") {}
  }
  teardown("close shop") {}
}
```

## Comments, errors, and attachments

`Tracera.comment`, `Tracera.error`, and attachments are added to the open step, or to the result when no step is open. `Tracera.attachmentFile` takes a file path; `Tracera.attachmentBytes` takes a name and bytes (MIME type is optional). Attachments upload when the result is reported. Shared placement and `Tracera.error` rules: [Autotest adapters](https://tracera.dev/docs/adapters#comments-errors-and-attachments).

```swift
Tracera.comment("result-level note")
Tracera.error("result-level error")
Tracera.attachmentFile("Fixtures/screenshot.png")
Tracera.step("open login") {
  Tracera.comment("step note")
  Tracera.attachmentBytes("body.json", data: Data(#"{"ok":true}"#.utf8), mimeType: "application/json")
}
```

If you start a `Task` and call Tracera APIs there, call `getContext()` in the test first and run the worker with `runWithContext` — otherwise those calls are not reported:

```swift
let ctx = getContext()
Task {
  await runWithContext(ctx) {
    Tracera.step("worker") { /* ... */ }
  }
}
```

## Parameterized

Each `arguments` row is a separate case. Put placeholders such as `{user}` or `{0}` in the `@Test("…")` title, or in `.traceraId(…, name:)`, so each row gets its own `autotestName`. A static `name:` with no placeholders is the same on every row:

```swift
@Test("login as {user}", .traceraId(7), arguments: ["alice", "bob"])
func login(user: String) {
  Tracera.step("sign in") { /* ... */ }
}

@Test("login", .traceraId(7, name: "login as {user}"), arguments: ["alice", "bob"])
func loginNamed(user: String) {
  Tracera.step("sign in") { /* ... */ }
}
```
