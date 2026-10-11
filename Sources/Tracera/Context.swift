import Foundation

/// Lifecycle bucket a step lands in.
public enum StepSection: String, Sendable, CaseIterable {
  case setup
  case test
  case teardown
}

/// References an uploaded blob on a step or on the result.
public struct AttachmentMeta: Sendable {
  public var attachmentId: String
  public var fileName: String?
  public var mimeType: String?

  public init(attachmentId: String, fileName: String? = nil, mimeType: String? = nil) {
    self.attachmentId = attachmentId
    self.fileName = fileName
    self.mimeType = mimeType
  }

  package func toWire() -> [String: Any] {
    var out: [String: Any] = ["attachmentId": attachmentId]
    if let fileName, !fileName.isEmpty { out["fileName"] = fileName }
    if let mimeType, !mimeType.isEmpty { out["mimeType"] = mimeType }
    return out
  }
}

private final class StepNode: @unchecked Sendable {
  let id: Int
  weak var parent: StepNode?
  let parentId: Int?
  let section: StepSection
  var action: String
  var expectation: String
  var result: String = "NotSet"
  var errorMessage: String = ""
  var comment: String = ""
  var attachments: [[String: Any]] = []
  var children: [StepNode] = []

  init(id: Int, section: StepSection, action: String, expectation: String, parent: StepNode?) {
    self.id = id
    self.section = section
    self.action = action
    self.expectation = expectation
    self.parent = parent
    self.parentId = parent?.id
  }
}

private let maxAttachments = 10

private func truncate(_ value: String, _ max: Int) -> String {
  String(value.prefix(max))
}

private func emptyPmDoc(_ text: String) -> [String: Any] {
  if text.isEmpty {
    return ["type": "doc", "content": [["type": "paragraph"]]]
  }
  return [
    "type": "doc",
    "content": [[
      "type": "paragraph",
      "content": [["type": "text", "text": text]],
    ]],
  ]
}

/// Active test pin: bind, section, step tree and extras.
public final class TestContext: @unchecked Sendable {
  public var testCaseId: Int
  /// Current lifecycle section. Mutate only via plugin `setPhase` (runners).
  public internal(set) var section: StepSection = .test

  private var _autotestName: String
  private var resultError = ""
  private var resultComment = ""
  private var nextStepId = 1
  private var hasFailedStep = false
  private var hasStepError = false
  private var stepStack: [StepNode] = []
  private var roots: [StepSection: [StepNode]] = [
    .setup: [], .test: [], .teardown: [],
  ]
  private var resultAttachments: [[String: Any]] = []
  private let lock = NSLock()

  package init(testCaseId: Int, autotestName: String, section: StepSection = .test) {
    self.testCaseId = testCaseId
    self._autotestName = truncate(autotestName, 128)
    self.section = section
  }

  public var autotestName: String {
    get {
      lock.lock(); defer { lock.unlock() }
      return _autotestName
    }
    set {
      lock.lock(); defer { lock.unlock() }
      _autotestName = truncate(newValue, 128)
    }
  }

  package var resultCommentText: String {
    lock.lock(); defer { lock.unlock() }
    return resultComment
  }

  package var payloadHasFailedStep: Bool {
    lock.lock(); defer { lock.unlock() }
    return hasFailedStep
  }

  package var payloadHasStepError: Bool {
    lock.lock(); defer { lock.unlock() }
    return hasStepError
  }

  package func setTestCaseId(_ id: Int) {
    lock.lock(); defer { lock.unlock() }
    testCaseId = id
  }

  package func recordFailure(_ text: String) {
    lock.lock(); defer { lock.unlock() }
    let cleaned = stripAnsi(text).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { return }
    if let current = stepStack.last {
      current.result = "Failed"
      current.errorMessage = appendText(current.errorMessage, cleaned)
      hasFailedStep = true
      hasStepError = true
    } else {
      resultError = appendText(resultError, cleaned)
    }
  }

  package func markSkipped(_ reason: String) {
    lock.lock()
    let cleaned = normalizeSkipReason(reason)
    if !cleaned.isEmpty {
      resultComment = appendText(resultComment, cleaned)
    }
    var pendingIds: [String] = []
    func collect(_ nodes: [StepNode]) {
      for node in nodes {
        for att in node.attachments {
          if let id = att["attachmentId"] as? String, id.hasPrefix("pending:") {
            pendingIds.append(id)
          }
        }
        collect(node.children)
      }
    }
    for section in StepSection.allCases {
      collect(roots[section] ?? [])
    }
    for att in resultAttachments {
      if let id = att["attachmentId"] as? String, id.hasPrefix("pending:") {
        pendingIds.append(id)
      }
    }
    lock.unlock()
    pendingIds.forEach { PendingBlobs.discard(id: $0) }
  }

  package func addComment(_ text: String) {
    lock.lock(); defer { lock.unlock() }
    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { return }
    if let current = stepStack.last {
      current.comment = appendText(current.comment, cleaned)
    } else {
      resultComment = appendText(resultComment, cleaned)
    }
  }

  package func addError(_ text: String) {
    lock.lock(); defer { lock.unlock() }
    let cleaned = stripAnsi(text).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { return }
    if let current = stepStack.last {
      current.errorMessage = appendText(current.errorMessage, cleaned)
      hasStepError = true
    } else {
      resultError = appendText(resultError, cleaned)
    }
  }

  package func addAttachment(_ meta: AttachmentMeta) {
    lock.lock(); defer { lock.unlock() }
    let wire = meta.toWire()
    if let current = stepStack.last {
      if current.attachments.count < maxAttachments {
        current.attachments.append(wire)
      }
    } else if resultAttachments.count < maxAttachments {
      resultAttachments.append(wire)
    }
  }

  @discardableResult
  package func addPendingAttachment(
    fileName: String,
    mimeType: String,
    path: String?,
    data: Data?,
    ephemeral: Bool = false
  ) -> Bool {
    let slot = "pending:\(UUID().uuidString.lowercased())"
    let wire: [String: Any] = [
      "attachmentId": slot,
      "fileName": fileName,
      "mimeType": mimeType,
    ]
    lock.lock()
    // Register the body only once the slot is accepted, so a dropped
    // attachment cannot leave an orphan blob behind (Dart/Go parity).
    let accepted: Bool
    if let current = stepStack.last {
      if current.attachments.count < maxAttachments {
        current.attachments.append(wire)
        accepted = true
      } else {
        accepted = false
      }
    } else if resultAttachments.count < maxAttachments {
      resultAttachments.append(wire)
      accepted = true
    } else {
      accepted = false
    }
    lock.unlock()
    guard accepted else {
      // Cap drop — do not leave an orphan adapter temp on disk.
      if ephemeral, let path, !path.isEmpty {
        try? FileManager.default.removeItem(atPath: path)
      }
      return false
    }
    PendingBlobs.register(
      id: slot,
      fileName: fileName,
      mimeType: mimeType,
      path: path,
      data: data,
      ephemeral: ephemeral
    )
    return true
  }

  package func beginStep(title: String) -> Int {
    lock.lock(); defer { lock.unlock() }
    let id = nextStepId
    nextStepId += 1
    let parent = stepStack.last
    let node = StepNode(
      id: id,
      section: section,
      action: title,
      expectation: "",
      parent: parent
    )
    if let parent {
      parent.children.append(node)
    } else {
      roots[section, default: []].append(node)
    }
    stepStack.append(node)
    return id
  }

  package func endStep(failed: Bool, errorMessage: String? = nil) {
    lock.lock(); defer { lock.unlock() }
    guard let node = stepStack.popLast() else { return }
    if failed {
      node.result = "Failed"
      hasFailedStep = true
      if let errorMessage, !errorMessage.isEmpty {
        node.errorMessage = appendText(node.errorMessage, errorMessage)
        hasStepError = true
      }
    } else if node.result == "NotSet" {
      node.result = "Passed"
    }
  }

  package func snapshotPayload() -> [String: Any] {
    lock.lock(); defer { lock.unlock() }
    /// Flat preorder (parent then children) — same wire shape as JS/Go/Dart.
    func flatten(_ nodes: [StepNode]) -> [[String: Any]] {
      var out: [[String: Any]] = []
      for node in nodes {
        var row: [String: Any] = [
          "id": node.id,
          "action": emptyPmDoc(node.action),
          "expectation": emptyPmDoc(node.expectation),
          "result": node.result,
          "attachments": node.attachments,
        ]
        if let parentId = node.parentId { row["parentId"] = parentId }
        if !node.errorMessage.isEmpty { row["errorMessage"] = node.errorMessage }
        if !node.comment.isEmpty { row["comment"] = node.comment }
        out.append(row)
        out.append(contentsOf: flatten(node.children))
      }
      return out
    }

    var payload: [String: Any] = [
      "testCaseId": testCaseId,
      "autotestName": _autotestName,
      "setup": flatten(roots[.setup] ?? []),
      "test": flatten(roots[.test] ?? []),
      "teardown": flatten(roots[.teardown] ?? []),
      "attachments": resultAttachments,
      "hasFailedStep": hasFailedStep,
      "hasStepError": hasStepError,
    ]
    if !resultError.isEmpty { payload["errorMessage"] = resultError }
    if !resultComment.isEmpty { payload["comment"] = resultComment }
    return payload
  }
}

package func createTestContext(
  testCaseId: Int,
  autotestName: String,
  section: StepSection = .test
) -> TestContext {
  TestContext(testCaseId: testCaseId, autotestName: autotestName, section: section)
}

// MARK: - TaskLocal pin

private enum ContextStorage {
  @TaskLocal static var taskContext: TestContext?
  nonisolated(unsafe) static var processContext: TestContext?
  static let lock = NSLock()
}

package func installContext(_ ctx: TestContext?) {
  ContextStorage.lock.lock()
  ContextStorage.processContext = ctx
  ContextStorage.lock.unlock()
}

package func clearContext(_ ctx: TestContext?) {
  ContextStorage.lock.lock()
  if let ctx, ContextStorage.processContext === ctx {
    ContextStorage.processContext = nil
  } else if ctx == nil {
    ContextStorage.processContext = nil
  }
  ContextStorage.lock.unlock()
}

/// Returns the pin for the current task, or the process fallback.
public func getContext() -> TestContext? {
  if let ctx = ContextStorage.taskContext { return ctx }
  ContextStorage.lock.lock()
  let process = ContextStorage.processContext
  ContextStorage.lock.unlock()
  return process
}

/// Pins `ctx` while `body` runs on the current task (async continuations inherit).
public func runWithContext<T>(_ ctx: TestContext?, _ body: () throws -> T) rethrows -> T {
  try ContextStorage.$taskContext.withValue(ctx, operation: body)
}

/// Async variant — keeps the pin across awaits inside `body`.
public func runWithContext<T>(_ ctx: TestContext?, _ body: () async throws -> T) async rethrows -> T {
  try await ContextStorage.$taskContext.withValue(ctx, operation: body)
}

package func setPhase(_ section: StepSection) {
  getContext()?.section = section
}
