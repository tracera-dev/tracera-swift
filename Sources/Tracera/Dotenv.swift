import Darwin
import Foundation

private let dotenvMaxDepth = 64
private let dotenvKeyRe = try! NSRegularExpression(pattern: #"^[A-Za-z_][A-Za-z0-9_]*$"#)

/// Live process environment (`environ` / `setenv`), not the cached
/// `ProcessInfo.environment` snapshot — unit tests and late `setenv` must win.
package func envMap() -> [String: String] {
  var out: [String: String] = [:]
  var ptr = environ
  while let cstr = ptr.pointee {
    ptr = ptr.advanced(by: 1)
    let entry = String(cString: cstr)
    guard let eq = entry.firstIndex(of: "=") else { continue }
    let key = String(entry[..<eq])
    let value = String(entry[entry.index(after: eq)...])
    out[key] = value
  }
  return out
}

package func parseDotenv(_ text: String) -> [String: String] {
  var out: [String: String] = [:]
  for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
    var line = String(rawLine)
    if line.hasSuffix("\r") { line.removeLast() }
    line = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if line.isEmpty || line.hasPrefix("#") { continue }
    var body = line
    if body.hasPrefix("export ") {
      body = String(body.dropFirst("export ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard let eq = body.firstIndex(of: "=") else { continue }
    let key = String(body[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
    let keyRange = NSRange(key.startIndex..., in: key)
    guard dotenvKeyRe.firstMatch(in: key, range: keyRange) != nil else { continue }
    var value = String(body[body.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
    if value.count >= 2 {
      let first = value.first!
      let last = value.last!
      if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
        value = String(value.dropFirst().dropLast())
      }
    }
    out[key] = value
  }
  return out
}

package func findNearestDotenv(cwd: String) -> String? {
  var dir = URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL
  let root = URL(fileURLWithPath: "/", isDirectory: true).standardizedFileURL
  // `homeDirectoryForCurrentUser` is unavailable on iOS — use NSHomeDirectory.
  let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).standardizedFileURL
  for _ in 0..<dotenvMaxDepth {
    // Never read `~/.env` or `/.env` (JS/Dart parity).
    if dir.path == root.path || dir.path == home.path { return nil }
    let candidate = dir.appendingPathComponent(".env")
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir),
      !isDir.boolValue,
      FileManager.default.isReadableFile(atPath: candidate.path)
    {
      return candidate.path
    }
    let parent = dir.deletingLastPathComponent().standardizedFileURL
    if parent.path == dir.path { break }
    dir = parent
  }
  return nil
}

/// Process env first; nearest `.env` fills missing/empty `TRACERA_*` only.
package func mergeEnvWithDotenv(
  _ processEnv: [String: String] = envMap(),
  cwd: String = FileManager.default.currentDirectoryPath
) -> [String: String] {
  var out = processEnv
  guard let path = findNearestDotenv(cwd: cwd),
    let data = try? String(contentsOfFile: path, encoding: .utf8)
  else { return out }
  for (key, value) in parseDotenv(data) where key.hasPrefix("TRACERA_") {
    let existing = out[key] ?? ""
    if existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      out[key] = value
    }
  }
  return out
}
