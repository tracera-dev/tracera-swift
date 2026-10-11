import Foundation

/// Uploads `pending:…` slots on a result payload (result-level + every step)
/// and rewrites them in place with real attachment ids.
///
/// Returns upload error messages; the caller decides whether the result is
/// still worth reporting (`TRACERA_REQUIRE_REPORT`).
package func resolvePendingAttachments(
  client: Client,
  payload: inout [String: Any]
) async -> [String] {
  var pairs: [(path: AttachmentPath, blob: PendingBlob)] = []

  func collect(from list: [[String: Any]], at path: AttachmentPath.Owner) {
    for (index, meta) in list.enumerated() {
      guard let id = meta["attachmentId"] as? String, id.hasPrefix("pending:") else { continue }
      guard let blob = PendingBlobs.take(id: id) else { continue }
      pairs.append((AttachmentPath(owner: path, index: index), blob))
    }
  }

  collect(from: payload["attachments"] as? [[String: Any]] ?? [], at: .result)
  for section in ["setup", "test", "teardown"] {
    let steps = payload[section] as? [[String: Any]] ?? []
    for (stepIndex, step) in steps.enumerated() {
      let atts = step["attachments"] as? [[String: Any]] ?? []
      collect(from: atts, at: .step(section: section, stepIndex: stepIndex))
    }
  }

  guard !pairs.isEmpty else { return [] }
  defer {
    for pair in pairs {
      PendingBlobs.unlinkEphemeral(pair.blob)
    }
  }

  let files = pairs.map {
    BlobFile(
      fileName: $0.blob.fileName,
      mimeType: $0.blob.mimeType,
      path: $0.blob.path,
      data: $0.blob.data
    )
  }

  let uploaded: [BlobUploadResult?]
  do {
    uploaded = try await client.uploadBlobs(files)
  } catch {
    let text = "\(error)"
    logError(text.hasPrefix("Tracera:") ? text : "Tracera: \(text)")
    return [text]
  }

  var errors: [String] = []
  for (i, pair) in pairs.enumerated() {
    let result = i < uploaded.count ? uploaded[i] : nil
    guard let result, !result.id.isEmpty else {
      errors.append("attachment upload missing result at index \(i)")
      rewriteAttachment(in: &payload, path: pair.path, id: "", fileName: nil, mimeType: nil)
      continue
    }
    rewriteAttachment(
      in: &payload,
      path: pair.path,
      id: result.id,
      fileName: result.fileName,
      mimeType: result.mimeType
    )
  }
  return errors
}

/// Reports false when the result must be dropped (`TRACERA_REQUIRE_REPORT`).
package func resolveResultAttachments(session: Session, payload: inout [String: Any]) async -> Bool {
  let errs = await resolvePendingAttachments(client: session.client, payload: &payload)
  guard let first = errs.first else { return true }
  session.setLastError(first)
  if session.config.requireReport {
    session.noteFailedReport(1)
    session.noteUnsentResults(1)
    return false
  }
  return true
}

private struct AttachmentPath {
  enum Owner {
    case result
    case step(section: String, stepIndex: Int)
  }

  var owner: Owner
  var index: Int
}

private func rewriteAttachment(
  in payload: inout [String: Any],
  path: AttachmentPath,
  id: String,
  fileName: String?,
  mimeType: String?
) {
  switch path.owner {
  case .result:
    var list = payload["attachments"] as? [[String: Any]] ?? []
    guard path.index < list.count else { return }
    list[path.index]["attachmentId"] = id
    if let fileName { list[path.index]["fileName"] = fileName }
    if let mimeType { list[path.index]["mimeType"] = mimeType }
    payload["attachments"] = list
  case .step(let section, let stepIndex):
    var steps = payload[section] as? [[String: Any]] ?? []
    guard stepIndex < steps.count else { return }
    var step = steps[stepIndex]
    var list = step["attachments"] as? [[String: Any]] ?? []
    guard path.index < list.count else { return }
    list[path.index]["attachmentId"] = id
    if let fileName { list[path.index]["fileName"] = fileName }
    if let mimeType { list[path.index]["mimeType"] = mimeType }
    step["attachments"] = list
    steps[stepIndex] = step
    payload[section] = steps
  }
}

package struct BlobFile: Sendable {
  package var fileName: String
  package var mimeType: String
  package var path: String?
  package var data: Data?
}
