import Tracera

/// Runs `body` as steps in the Setup section.
///
/// Swift Testing has no stock `beforeEach`; use this (or `init` that calls it
/// after bind) so per-test preparation lands in Setup — same role as Go
/// `tracera.Setup` for gotest.
public func setup(_ title: String = "setup", _ body: () throws -> Void) rethrows {
  let previous = getContext()?.section ?? .test
  setPhase(.setup)
  defer { setPhase(previous) }
  try Tracera.step(title, body: body)
}

/// Async Setup section helper — see ``setup(_:_:)-7gq0i``.
public func setup(_ title: String = "setup", _ body: () async throws -> Void) async rethrows {
  let previous = getContext()?.section ?? .test
  setPhase(.setup)
  defer { setPhase(previous) }
  try await Tracera.step(title, body: body)
}

/// Runs `body` as steps in the Teardown section.
public func teardown(_ title: String = "teardown", _ body: () throws -> Void) rethrows {
  let previous = getContext()?.section ?? .test
  setPhase(.teardown)
  defer { setPhase(previous) }
  try Tracera.step(title, body: body)
}

/// Async Teardown section helper — see ``teardown(_:_:)-8kq1p``.
public func teardown(_ title: String = "teardown", _ body: () async throws -> Void) async rethrows {
  let previous = getContext()?.section ?? .test
  setPhase(.teardown)
  defer { setPhase(previous) }
  try await Tracera.step(title, body: body)
}
