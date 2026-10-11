# Tracera

Tracera Autotest adapter core for Swift (HTTP, flush, log, dotenv, Env, TaskLocal context).

**Requires Swift ≥ 6** (macOS 15 / Xcode 16).

```swift
// Package.swift
.package(url: "https://github.com/tracera-dev/tracera-swift.git", from: "0.1.0"),
// …
.product(name: "Tracera", package: "tracera-swift"),
```

```swift
import Tracera
```

Pick a runner product unless you are writing a custom integration: `TraceraTesting` (Swift Testing) or `TraceraXCUITest` (XCTest / XCUITest).

## Bind

Declarative bind lives on the runner (`.traceraId` trait). Inside a running test you can also rebind imperatively:

```swift
Tracera.testCase(42)                    // id only — the runner supplies the name
Tracera.testCase(42, "checkout flow")   // id + reported result name
```

## Skip

Use the runner’s skip API so the reason becomes the result `comment`. Stock skip helpers that hide the message from reporters need the runner path (documented on that runner).

## Steps

Use `Tracera.step("…") { … }` (sync or `async`). Steps nest; a thrown error inside a step marks it Failed with the captured text before propagating:

```swift
Tracera.step("open the cart") {
  Tracera.step("add an item") { /* ... */ }
}
```

Async bodies keep the step open until the future settles:

```swift
try await Tracera.step("load cart") {
  try await load()
}
```

Setup / Teardown sections are owned by the runner (`TraceraTesting` / `TraceraXCUITest`).

## Comments, errors, and attachments

`Tracera.comment`, `Tracera.error` and the attachment helpers land on the open step, or on the result when no step is open. `Tracera.error` only adds error text — it does not fail the test; the runner marks **Failed**.

Attach a file from disk with `Tracera.attachmentFile` (uploaded when the result is reported — the file must still exist then) or in-memory bytes with `Tracera.attachmentBytes` (the bytes are copied). The MIME type is optional. Up to ten attachments land on a step, and ten more on the result.

```swift
Tracera.step("charge the card") {
  Tracera.comment("sandbox gateway")
  Tracera.error("retried once")
  Tracera.attachmentFile("Fixtures/receipt.pdf")
  Tracera.attachmentBytes("response.json", data: body, mimeType: "application/json")
}
```

`Tracera.attachment` takes a blob that is already uploaded — reach for it only when you hold a Tracera attachment id.

Tasks and detached work do not inherit the active test. Capture the context and pin it in the worker:

```swift
let ctx = getContext()
Task {
  await runWithContext(ctx) {
    Tracera.step("worker") { /* ... */ }
  }
}
```

## Parameterized

Bind name templates (`{param}` / `{0}`) live on the Swift Testing runner. See that product’s README.

## Several test processes

Usual case: one process, one test run — nothing extra to set.

Only when **you** start several OS processes and want them in the **same** run: give each a different `TRACERA_PEER_WORKER` for that launch. The first process opens the run; the last closes it. You do not create the run by hand.

Environment variables, run modes and `.env` lookup: [Autotest adapters](https://tracera.dev/docs/adapters).

## License

Apache-2.0. Copyright 2026 Tracera.
