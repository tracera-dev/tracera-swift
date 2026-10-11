import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#endif

/// How old a lock file may get before it is treated as left behind.
private let handoffLockStaleAfter: TimeInterval = 90
/// How long a `.id` file may sit before the next claim creates a fresh run.
private let handoffIdStaleAfter: TimeInterval = 24 * 60 * 60

/// Override in unit tests (process TempDir is shared).
nonisolated(unsafe) package var handoffTempDir: () -> String = {
  FileManager.default.temporaryDirectory.path
}

package struct HandoffPaths: Sendable {
  package let idPath: String
  package let lockPath: String
}

package func peerWorkerLabel(_ env: [String: String]) -> String {
  let raw = (env["TRACERA_PEER_WORKER"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
  guard !raw.isEmpty else { return "" }
  return "swift peer worker (\(raw))"
}

package func peerWorkerLabelFor(_ label: String?) -> String {
  let raw = (label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
  guard !raw.isEmpty else { return "" }
  return "swift peer worker (\(raw))"
}

package func ciLaunchId(_ env: [String: String]) -> String {
  let githubRun = (env["GITHUB_RUN_ID"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
  if !githubRun.isEmpty {
    let attempt = (env["GITHUB_RUN_ATTEMPT"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return "github:\(githubRun).\(attempt.isEmpty ? "1" : attempt)"
  }
  let pipeline = (env["CI_PIPELINE_ID"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
  if !pipeline.isEmpty { return "gitlab:\(pipeline)" }
  let buildkite = (env["BUILDKITE_BUILD_ID"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
  if !buildkite.isEmpty { return "buildkite:\(buildkite)" }
  let circle = (env["CIRCLE_BUILD_NUM"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
  if !circle.isEmpty { return "circle:\(circle)" }
  let azdo = (env["BUILD_BUILDID"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
  if !azdo.isEmpty { return "azdo:\(azdo)" }
  let travis = (env["TRAVIS_BUILD_ID"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
  if !travis.isEmpty { return "travis:\(travis)" }
  return ""
}

package func handoffLaunchKey(_ env: [String: String]) -> String {
  let explicit = (env["TRACERA_HANDOFF_KEY"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
  if !explicit.isEmpty { return explicit }
  return ciLaunchId(env)
}

/// sha256 over `projectId\0runTitle[\0launchKey]`, first 16 hex chars — lockstep with other langs.
package func handoffDigest(projectId: Int, runTitle: String, env: [String: String] = envMap()) -> String {
  let launch = handoffLaunchKey(env)
  var payload = "\(projectId)\u{0000}\(runTitle)"
  if !launch.isEmpty { payload += "\u{0000}\(launch)" }
  let digest = SHA256.hash(data: Data(payload.utf8))
  let hex = digest.map { String(format: "%02x", $0) }.joined()
  return String(hex.prefix(16))
}

package func handoffPaths(projectId: Int, runTitle: String, env: [String: String] = envMap()) -> HandoffPaths {
  let digest = handoffDigest(projectId: projectId, runTitle: runTitle, env: env)
  let stem = (handoffTempDir() as NSString).appendingPathComponent("tracera-handoff")
  let base = (stem as NSString).appendingPathComponent("run-\(projectId)-\(digest)")
  return HandoffPaths(idPath: base + ".id", lockPath: base + ".lock")
}

private func peerCount(_ env: [String: String]) -> Int {
  guard let n = parseStrictInt(env["TRACERA_PEER_COUNT"]), n > 0 else { return 0 }
  return n
}

package func claimPeerRun(
  projectId: Int,
  runTitle: String,
  createRun: () async throws -> Int,
  env: [String: String] = envMap()
) async throws -> Int {
  let paths = handoffPaths(projectId: projectId, runTitle: runTitle, env: env)
  try FileManager.default.createDirectory(
    atPath: (paths.idPath as NSString).deletingLastPathComponent,
    withIntermediateDirectories: true
  )

  for _ in 0..<200 {
    if tryTakeLock(paths.lockPath) {
      defer { try? FileManager.default.removeItem(atPath: paths.lockPath) }
      if let existing = readState(paths.idPath), !isIdStale(paths.idPath) {
        writeState(paths.idPath, runId: existing.runId, refs: existing.refs + 1, claimed: existing.claimed + 1)
        return existing.runId
      }
      let runId = try await createRun()
      writeState(paths.idPath, runId: runId, refs: 1, claimed: 1)
      return runId
    }
    try? await Task.sleep(nanoseconds: 25_000_000)
  }
  throw ConfigError.message("peer handoff lock timeout")
}

package func releasePeerRun(
  projectId: Int,
  runTitle: String,
  finish: (Int) async throws -> Void,
  env: [String: String] = envMap()
) async throws -> Bool {
  let paths = handoffPaths(projectId: projectId, runTitle: runTitle, env: env)

  for _ in 0..<200 {
    if tryTakeLock(paths.lockPath) {
      defer { try? FileManager.default.removeItem(atPath: paths.lockPath) }
      guard var state = readState(paths.idPath) else { return false }
      state.refs = max(0, state.refs - 1)
      let hold = peerCount(env) > 0 && state.claimed < peerCount(env)
      if state.refs == 0 && !hold {
        try await finish(state.runId)
        try? FileManager.default.removeItem(atPath: paths.idPath)
        return true
      }
      writeState(paths.idPath, runId: state.runId, refs: state.refs, claimed: state.claimed)
      return false
    }
    try? await Task.sleep(nanoseconds: 25_000_000)
  }
  return false
}

private struct HandoffState {
  var runId: Int
  var refs: Int
  var claimed: Int
}

/// Exclusive create (`O_CREAT|O_EXCL`) — `FileManager.createFile` is not exclusive
/// on Darwin and would let two peers both “hold” the lock.
package func tryTakeHandoffLock(_ lockPath: String) -> Bool {
  if exclusiveCreate(lockPath) { return true }
  // Stale lock left by a crashed holder.
  if isLockStale(lockPath) {
    try? FileManager.default.removeItem(atPath: lockPath)
    return exclusiveCreate(lockPath)
  }
  return false
}

private func tryTakeLock(_ lockPath: String) -> Bool {
  tryTakeHandoffLock(lockPath)
}

private func exclusiveCreate(_ path: String) -> Bool {
  #if canImport(Darwin)
  let fd = open(path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
  if fd >= 0 {
    close(fd)
    return true
  }
  return false
  #else
  // Non-Darwin fallback — best effort only.
  return FileManager.default.createFile(atPath: path, contents: Data(), attributes: nil)
  #endif
}

private func readState(_ path: String) -> HandoffState? {
  guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
  let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map {
    $0.trimmingCharacters(in: .whitespacesAndNewlines)
  }
  guard !lines.isEmpty, let runId = Int(lines[0]), runId > 0 else { return nil }
  var refs = 1
  if lines.count > 1, let r = Int(lines[1]), r >= 0 { refs = r }
  var claimed = max(refs, 1)
  if lines.count > 2, let c = Int(lines[2]), c >= 0 { claimed = c }
  return HandoffState(runId: runId, refs: refs, claimed: claimed)
}

private func writeState(_ path: String, runId: Int, refs: Int, claimed: Int) {
  let text = "\(runId)\n\(refs)\n\(claimed)\n"
  let tmp = path + ".tmp"
  try? text.write(toFile: tmp, atomically: true, encoding: .utf8)
  try? FileManager.default.removeItem(atPath: path)
  try? FileManager.default.moveItem(atPath: tmp, toPath: path)
}

private func isIdStale(_ path: String) -> Bool {
  guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
        let modified = attrs[.modificationDate] as? Date
  else { return true }
  return Date().timeIntervalSince(modified) > handoffIdStaleAfter
}

private func isLockStale(_ path: String) -> Bool {
  guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
        let modified = attrs[.modificationDate] as? Date
  else { return true }
  return Date().timeIntervalSince(modified) > handoffLockStaleAfter
}
