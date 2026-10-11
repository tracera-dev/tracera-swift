import Foundation

package let consecutiveBatchFailLimit = 2

package final class Session: @unchecked Sendable {
  package let client: Client
  package let config: Config
  package let testRunId: Int
  package let ownedByAdapter: Bool
  package let peerHandoff: Bool
  package private(set) var reportingEnabled = true
  package private(set) var publicAppUrl = ""
  private let lock = NSLock()
  private nonisolated(unsafe) var consecutiveBatchFails = 0
  private nonisolated(unsafe) var _lastError = ""
  private nonisolated(unsafe) var _failedReport = 0
  private nonisolated(unsafe) var _unsentResults = 0

  package init(
    client: Client,
    config: Config,
    testRunId: Int,
    ownedByAdapter: Bool,
    peerHandoff: Bool
  ) {
    self.client = client
    self.config = config
    self.testRunId = testRunId
    self.ownedByAdapter = ownedByAdapter
    self.peerHandoff = peerHandoff
  }

  package func setPublicAppUrl(_ url: String) {
    publicAppUrl = url
  }

  package var lastError: String {
    lock.lock(); defer { lock.unlock() }
    return _lastError
  }

  package var failedReport: Int {
    lock.lock(); defer { lock.unlock() }
    return _failedReport
  }

  package var unsentResults: Int {
    lock.lock(); defer { lock.unlock() }
    return _unsentResults
  }

  package func setLastError(_ message: String) {
    lock.lock(); defer { lock.unlock() }
    _lastError = message
  }

  package func noteFailedReport(_ n: Int) {
    lock.lock(); defer { lock.unlock() }
    _failedReport += n
  }

  package func clearOneFailedReport() {
    lock.lock(); defer { lock.unlock() }
    if _failedReport > 0 { _failedReport -= 1 }
  }

  package func noteUnsentResults(_ n: Int) {
    lock.lock(); defer { lock.unlock() }
    _unsentResults += n
  }

  /// Uploads a prepared batch. Returns items to requeue after a transport failure.
  ///
  /// Attachments must already be resolved (pool job in `enqueueResult`); this
  /// only shapes the wire payload and POSTs the batch.
  @discardableResult
  package func uploadBatch(_ rawItems: [[String: Any]]) async -> [[String: Any]] {
    guard reportingEnabled else {
      rawItems.forEach { discardPendingBlobs($0) }
      return []
    }
    var wireItems: [[String: Any]] = []
    for item in rawItems {
      if let prepared = prepareItem(item) {
        wireItems.append(prepared)
      }
    }
    guard !wireItems.isEmpty else { return [] }
    logDebug("Tracera: sent \(wireItems.count) result(s)")
    do {
      let res = try await client.postResultsBatch(testRunId: testRunId, items: wireItems)
      consecutiveBatchFails = 0
      // Undo batch-level transport failure counts if a prior attempt requeued these.
      for _ in 0..<wireItems.count { clearOneFailedReport() }
      if let rows = res["results"] as? [[String: Any]] {
        for row in rows {
          let ok = row["ok"] as? Bool ?? true
          guard !ok else { continue }
          let reason = (row["error"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "item_failed"
          let index = row["index"] as? Int ?? -1
          let casePart: String
          if index >= 0, index < wireItems.count {
            let caseId = wireItems[index]["testCaseId"] as? Int ?? 0
            casePart = "testCaseId=\(caseId)"
          } else {
            casePart = "batch index \(index)"
          }
          setLastError(reason)
          noteFailedReport(1)
          logError("Tracera: server rejected result (\(casePart)): \(reason)")
        }
      }
      return []
    } catch {
      consecutiveBatchFails += 1
      setLastError("\(error)")
      noteFailedReport(wireItems.count)
      logError("Tracera: \(error) — requeued")
      if consecutiveBatchFails >= consecutiveBatchFailLimit {
        reportingEnabled = false
        logError(
          "Tracera: stopped reporting after \(consecutiveBatchFailLimit) failed batch uploads"
        )
      }
      return wireItems
    }
  }

  private func prepareItem(_ payload: [String: Any]) -> [String: Any]? {
    var out = payload
    let testCaseId = payload["testCaseId"] as? Int ?? 0
    guard testCaseId > 0 else {
      discardPendingBlobs(payload)
      return nil
    }
    out["isAutomated"] = true
    out["testRunId"] = testRunId
    out["testCaseId"] = testCaseId

    // Drop any leftover pending slots (should already be resolved on the pool).
    out["setup"] = scrubPendingSteps(payload["setup"] as? [[String: Any]] ?? [])
    out["test"] = scrubPendingSteps(payload["test"] as? [[String: Any]] ?? [])
    out["teardown"] = scrubPendingSteps(payload["teardown"] as? [[String: Any]] ?? [])
    out["attachments"] = scrubPendingAttachments(payload["attachments"] as? [[String: Any]] ?? [])

    let hasStepError = payload["hasStepError"] as? Bool ?? false
    if hasStepError {
      out.removeValue(forKey: "errorMessage")
    }
    out.removeValue(forKey: "hasFailedStep")
    out.removeValue(forKey: "hasStepError")

    if (out["result"] as? String) == "Skipped" {
      out["setup"] = [[String: Any]]()
      out["test"] = [[String: Any]]()
      out["teardown"] = [[String: Any]]()
      out.removeValue(forKey: "errorMessage")
    }
    return out
  }

  private func scrubPendingSteps(_ steps: [[String: Any]]) -> [[String: Any]] {
    steps.map { step in
      var copy = step
      copy["attachments"] = scrubPendingAttachments(step["attachments"] as? [[String: Any]] ?? [])
      return copy
    }
  }

  private func scrubPendingAttachments(_ list: [[String: Any]]) -> [[String: Any]] {
    list.compactMap { att in
      guard let id = att["attachmentId"] as? String else { return nil }
      if id.hasPrefix("pending:") {
        PendingBlobs.discard(id: id)
        return nil
      }
      if id.isEmpty { return nil }
      return att
    }
  }
}

package final class ReporterState: @unchecked Sendable {
  package var softDisabled = false
  package var peerWorker: String?
  package var session: Session?
  package var buffer: ResultBuffer?
  package var uploadPool: JobPool?

  package init() {}
}

package func createReporterState() -> ReporterState { ReporterState() }

package func failRequired(_ message: String) -> Never {
  let text = message.hasPrefix("Tracera:") ? message : "Tracera: \(message)"
  logError(text)
  Foundation.exit(1)
}

package func beginReporting(_ state: ReporterState) async {
  let env = mergeEnvWithDotenv()
  setLogLevel(env["TRACERA_LOG_LEVEL"])
  let requireReport = parseBool(env["TRACERA_REQUIRE_REPORT"], fallback: false)

  let config: Config
  do {
    config = try loadConfig(env)
  } catch {
    let message = "Tracera: \(error)"
    if requireReport { failRequired(message) }
    logWarn("\(message) — stopped reporting")
    state.softDisabled = true
    return
  }

  let client = Client(config)
  let app: AppConfig
  do {
    app = try await client.getAppConfig()
    try client.ensureCompatible(app)
  } catch {
    if config.requireReport { failRequired("Tracera: \(error)") }
    logWarn("Tracera: \(error) — stopped reporting")
    state.softDisabled = true
    client.close()
    return
  }

  var peerLabel = peerWorkerLabelFor(state.peerWorker)
  if peerLabel.isEmpty { peerLabel = peerWorkerLabel(env) }

  var testRunId = config.testRunId
  var owned = false
  var peerHandoff = false
  do {
    if testRunId > 0 {
      // attach
    } else if !peerLabel.isEmpty {
      logDebug("Tracera: \(peerLabel) — sharing one test run with its peers")
      testRunId = try await claimPeerRun(
        projectId: config.projectId,
        runTitle: config.runTitle,
        createRun: { try await client.createRun() },
        env: env
      )
      peerHandoff = true
    } else {
      testRunId = try await client.createRun()
      owned = true
    }
  } catch {
    if config.requireReport { failRequired("Tracera: \(error)") }
    logWarn("Tracera: \(error) — stopped reporting")
    state.softDisabled = true
    client.close()
    return
  }

  let session = Session(
    client: client,
    config: config,
    testRunId: testRunId,
    ownedByAdapter: owned,
    peerHandoff: peerHandoff
  )
  session.setPublicAppUrl(app.publicAppUrl)
  state.session = session
  state.buffer = ResultBuffer(session: session)
  state.uploadPool = JobPool(config.uploadConcurrency)
  logDebug(
    owned
      ? "Tracera: created test run #\(testRunId)"
      : "Tracera: using existing test run #\(testRunId)"
  )
}

/// Resolves the result's pending attachments and buffers it for upload.
///
/// With an upload pool armed the work runs there (Dart/Go parity), so the test
/// never waits on a blob; `endReporting` drains the pool before the final flush.
package func enqueueResult(_ state: ReporterState?, _ item: PendingResult?) {
  guard let item else { return }
  if item.payload == nil, let ctx = item.ctx {
    item.payload = ctx.snapshotPayload()
  }
  let session = state?.session
  let buffer = state?.buffer
  let testCaseId = item.ctx?.testCaseId ?? (item.payload?["testCaseId"] as? Int ?? 0)
  if testCaseId <= 0 {
    let label = (item.ctx?.autotestName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    logDebug("Tracera: skip report — no testCaseId (\(label.isEmpty ? "unbound" : label))")
    discardPendingBlobs(item.payload)
    return
  }
  if state == nil || state?.softDisabled == true || session == nil || buffer == nil {
    discardPendingBlobs(item.payload)
    return
  }

  let report: @Sendable () async throws -> Void = { [item, session, buffer] in
    guard let session, session.reportingEnabled else {
      discardPendingBlobs(item.payload)
      return
    }
    guard var payload = item.payload else { return }
    guard await resolveResultAttachments(session: session, payload: &payload) else {
      return
    }
    item.payload = payload
    if let buffer {
      await buffer.enqueue(item)
    }
  }

  if let pool = state?.uploadPool {
    // Synchronous schedule — outstanding work is visible to drain immediately.
    pool.schedule(report)
  } else {
    Task {
      do { try await report() } catch {
        logDebug("Tracera: upload job failed: \(error)")
      }
    }
  }
}

package func endReporting(_ state: ReporterState) async {
  if let pool = state.uploadPool {
    await pool.drain()
  }
  if let buffer = state.buffer {
    await buffer.flush()
  }
  // Blobs still registered here belong to results nobody reported.
  PendingBlobs.clearAll()

  guard let session = state.session else { return }

  let left = await (state.buffer?.pendingCount() ?? 0) + session.unsentResults
  if left > 0 {
    logError("Tracera: \(left) result(s) not uploaded — leaving test run open")
  } else if session.peerHandoff {
    let env = mergeEnvWithDotenv()
    do {
      _ = try await releasePeerRun(
        projectId: session.config.projectId,
        runTitle: session.config.runTitle,
        finish: { id in try await session.client.finishRun(id) },
        env: env
      )
    } catch {
      session.setLastError("\(error)")
      session.noteFailedReport(1)
      logError("Tracera: peer finish failed: \(error)")
    }
  } else if session.ownedByAdapter && session.reportingEnabled {
    do {
      try await session.client.finishRun(session.testRunId)
    } catch {
      let text = "\(error)"
      session.setLastError(text)
      session.noteFailedReport(1)
      logError(text.hasPrefix("Tracera:") ? text : "Tracera: \(text)")
    }
  }

  let url = session.client.runUrl(testRunId: session.testRunId, publicAppUrl: session.publicAppUrl)
  if session.reportingEnabled {
    logLink(url)
  }

  if session.config.requireReport && session.failedReport > 0 {
    failRequired(
      "Tracera: exiting — \(session.failedReport) result(s) could not be reported (TRACERA_REQUIRE_REPORT)"
    )
  }
  session.client.close()
}
