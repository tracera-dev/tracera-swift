import Testing
import Tracera

/// Runs `body` as a **Setup** step (title = `title`).
@discardableResult
public func setup<T>(_ title: String, body: () throws -> T) rethrows -> T {
  setPhase(.setup)
  defer { setPhase(.test) }
  return try Tracera.step(title, body: body)
}

/// Async **Setup** step — stays open until the future settles.
@discardableResult
public func setup<T>(_ title: String, body: () async throws -> T) async rethrows -> T {
  setPhase(.setup)
  defer { setPhase(.test) }
  return try await Tracera.step(title, body: body)
}

/// Runs `body` as a **Teardown** step (title = `title`).
@discardableResult
public func teardown<T>(_ title: String, body: () throws -> T) rethrows -> T {
  setPhase(.teardown)
  defer { setPhase(.test) }
  return try Tracera.step(title, body: body)
}

/// Async **Teardown** step — stays open until the future settles.
@discardableResult
public func teardown<T>(_ title: String, body: () async throws -> T) async rethrows -> T {
  setPhase(.teardown)
  defer { setPhase(.test) }
  return try await Tracera.step(title, body: body)
}
