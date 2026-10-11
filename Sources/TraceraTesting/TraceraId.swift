import Foundation
import Testing
import Tracera

/// Declarative bind for Swift Testing — preferred over mid-body `Tracera.testCase`.
///
/// ```swift
/// @Test("login", .traceraId(101))
/// @Test("login as {user}", .traceraId(101), arguments: ["alice", "bob"])
/// func login(user: String) { … }
/// ```
public struct TraceraIdTrait: TestTrait, SuiteTrait, TestScoping, Sendable {
  public let testCaseId: Int
  public let nameTemplate: String?

  public init(_ testCaseId: Int, name: String? = nil) {
    self.testCaseId = testCaseId
    self.nameTemplate = name
  }

  public func provideScope(
    for test: Test,
    testCase: Test.Case?,
    performing function: @Sendable () async throws -> Void
  ) async throws {
    install()

    let params = bindParams(from: testCase, test: test)
    // Explicit `name:` wins; otherwise expand placeholders in `@Test("…")`
    // (`Test.displayName`). Missing keys leave the template unchanged.
    let template = resolvedBindTemplate(nameTemplate: nameTemplate, test: test)
    let displayName = formatBindName(template, params: params)

    let ctx = createTestContext(testCaseId: testCaseId, autotestName: displayName)
    let activeId = "\(String(describing: test.id)):\(testCase.map { String(describing: $0) } ?? "0")"
    beginActive(id: activeId, ctx: ctx)

    try await runWithContext(ctx) {
      setPhase(.test)
      do {
        try await function()
        if ctx.payloadHasFailedStep {
          markActiveFailed(id: activeId)
        }
      } catch is CancellationError {
        // `skip(_:)` already wrote the reason onto the context; keep it.
        if ctx.resultCommentText.isEmpty {
          markActiveSkipped(id: activeId, reason: "cancelled")
        } else {
          markActiveSkipped(id: activeId, reason: ctx.resultCommentText)
        }
        endActive(id: activeId)
        throw CancellationError()
      } catch {
        ctx.recordFailure(formatFailureText(error))
        markActiveFailed(id: activeId)
        endActive(id: activeId)
        throw error
      }
    }

    endActive(id: activeId)
  }
}

extension Trait where Self == TraceraIdTrait {
  /// Binds the test to a Tracera test case id.
  ///
  /// Optional `name` overrides the `@Test("…")` display name. Both support
  /// `{param}` / `{0}` placeholders from Swift Testing arguments; when `name`
  /// is omitted, placeholders in the display name are expanded the same way.
  public static func traceraId(_ testCaseId: Int, name: String? = nil) -> Self {
    TraceraIdTrait(testCaseId, name: name)
  }
}

/// Bind name template: explicit `name:` → `@Test("…")` display name → function name.
func resolvedBindTemplate(nameTemplate: String?, test: Test) -> String {
  if let nameTemplate, !nameTemplate.isEmpty {
    return nameTemplate
  }
  if let displayName = test.displayName, !displayName.isEmpty {
    return displayName
  }
  return String(describing: test.name)
}

/// Collect `{0}` / `{param}` / `{firstName}` values from a Swift Testing case.
///
/// `Test.Case` stores args under `_kind.parameterized.arguments` as
/// `Test.Case.Argument` (`value` + `parameter.firstName`) — not a flat
/// `[Any]` on the case itself.
func bindParams(from testCase: Test.Case?, test: Test) -> [String: Any] {
  var params: [String: Any] = [:]
  let arguments = collectCaseArguments(from: testCase)
  let namesFromTest = parameterFirstNames(from: test)

  for (index, arg) in arguments.enumerated() {
    let value = arg.value
    params["\(index)"] = value
    let name = arg.firstName ?? (index < namesFromTest.count ? namesFromTest[index] : nil)
    if let name, !name.isEmpty {
      params[name] = value
    }
  }
  if let first = params["0"] {
    params["param"] = first
    params["param_id"] = represent(first)
  }
  return params
}

private struct CaseArgument {
  var value: Any
  var firstName: String?
}

private func collectCaseArguments(from testCase: Test.Case?) -> [CaseArgument] {
  guard let testCase else { return [] }
  var found: [Any] = []
  collectArguments(from: testCase, into: &found)
  return found.map(parseCaseArgument)
}

private func collectArguments(from value: Any, into out: inout [Any]) {
  if !out.isEmpty { return }
  let mirror = Mirror(reflecting: value)
  for child in mirror.children {
    if child.label == "arguments" {
      let argsMirror = Mirror(reflecting: child.value)
      if argsMirror.displayStyle == .collection || argsMirror.displayStyle == .set {
        for arg in argsMirror.children {
          out.append(arg.value)
        }
        if !out.isEmpty { return }
      }
      if let arr = child.value as? [Any] {
        out.append(contentsOf: arr)
        if !out.isEmpty { return }
      }
    }
  }
  for child in mirror.children {
    collectArguments(from: child.value, into: &out)
    if !out.isEmpty { return }
  }
}

private func parseCaseArgument(_ raw: Any) -> CaseArgument {
  let mirror = Mirror(reflecting: raw)
  var value: Any = raw
  var firstName: String?
  for child in mirror.children {
    switch child.label {
    case "value", "wrappedValue":
      value = unwrapBoxed(child.value)
    case "parameter":
      firstName = parameterFirstName(from: child.value) ?? firstName
    default:
      break
    }
  }
  return CaseArgument(value: unwrapBoxed(value), firstName: firstName)
}

private func parameterFirstNames(from test: Test) -> [String] {
  var names: [String] = []
  collectParameterNames(from: test, into: &names)
  return names
}

private func collectParameterNames(from value: Any, into names: inout [String]) {
  if !names.isEmpty { return }
  let mirror = Mirror(reflecting: value)
  for child in mirror.children {
    if child.label == "parameters" {
      let listMirror = Mirror(reflecting: unwrapOptional(child.value) ?? child.value)
      if listMirror.displayStyle == .collection {
        for p in listMirror.children {
          if let name = parameterFirstName(from: p.value) {
            names.append(name)
          }
        }
        if !names.isEmpty { return }
      }
    }
  }
  for child in mirror.children {
    collectParameterNames(from: child.value, into: &names)
    if !names.isEmpty { return }
  }
}

private func parameterFirstName(from value: Any) -> String? {
  for child in Mirror(reflecting: value).children {
    if child.label == "firstName", let s = child.value as? String, !s.isEmpty {
      return s
    }
  }
  return nil
}

private func unwrapOptional(_ value: Any) -> Any? {
  let mirror = Mirror(reflecting: value)
  guard mirror.displayStyle == .optional else { return nil }
  return mirror.children.first?.value
}

private func unwrapBoxed(_ value: Any) -> Any {
  if let inner = unwrapOptional(value) {
    return unwrapBoxed(inner)
  }
  let mirror = Mirror(reflecting: value)
  // Only peel known wrapper boxes — not every Mirror child named coincidentally.
  let typeName = String(describing: type(of: value))
  let looksBoxed =
    typeName.contains("Argument")
    || typeName.contains("Expression")
    || typeName.contains("__")
  if looksBoxed {
    for child in mirror.children {
      if child.label == "value" || child.label == "wrappedValue" {
        return unwrapBoxed(child.value)
      }
    }
  }
  return value
}
