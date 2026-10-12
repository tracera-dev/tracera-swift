import Foundation
import Tracera

/// Writes bytes to an adapter-owned temp file and registers a path-only pending
/// blob (`ephemeral: true`). Keeps large XCUITest screenshots / dumps out of
/// the process map until upload, then unlinks after resolve/discard.
@discardableResult
func attachStagedBytes(
  _ data: Data,
  fileName: String,
  mimeType: String,
  into ctx: TestContext
) -> Bool {
  guard !data.isEmpty else { return false }
  guard let path = writeMediaTemp(data: data, fileName: fileName) else { return false }
  return ctx.addPendingAttachment(
    fileName: fileName,
    mimeType: mimeType,
    path: path,
    data: nil,
    ephemeral: true
  )
}

func writeMediaTemp(data: Data, fileName: String) -> String? {
  let dir = FileManager.default.temporaryDirectory
    .appendingPathComponent("tracera-media", isDirectory: true)
  do {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  } catch {
    return nil
  }
  let safe =
    fileName
    .replacingOccurrences(of: "/", with: "_")
    .replacingOccurrences(of: "\\", with: "_")
  let url = dir.appendingPathComponent("\(UUID().uuidString.lowercased())-\(safe)")
  do {
    try data.write(to: url, options: .atomic)
    return url.path
  } catch {
    return nil
  }
}
