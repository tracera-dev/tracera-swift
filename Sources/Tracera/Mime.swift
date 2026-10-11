import Foundation

private let mimeByExt: [String: String] = [
  "png": "image/png",
  "jpg": "image/jpeg",
  "jpeg": "image/jpeg",
  "gif": "image/gif",
  "webp": "image/webp",
  "txt": "text/plain",
  "log": "text/plain",
  "json": "application/json",
  "html": "text/html",
  "xml": "application/xml",
  "pdf": "application/pdf",
  "zip": "application/zip",
  "webm": "video/webm",
  "mp4": "video/mp4",
  "mov": "video/quicktime",
]

package func guessMimeType(fileName: String) -> String {
  let ext = (fileName as NSString).pathExtension.lowercased()
  return mimeByExt[ext] ?? "application/octet-stream"
}
