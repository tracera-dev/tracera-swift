import CryptoKit
import Foundation

#if canImport(Darwin)
  import Darwin
#endif

/// How old a lock file may get before it is treated as left behind.
private let handoffLockStaleAfter: TimeInterval = 90
/// How long a `.id` file may sit before the next claim creates a fresh run.
private let handoffIdStaleAfter: TimeInterval = 24 * 60 * 60
/// Wait for the peer lock (Dart/JS parity — covers `createRun` / `finishRun` hold).
private let handoffLockWaitAttempts = 2_400
private let handoffLockWaitSleepNs: UInt64 = 25_000_000

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

/// True when `pid` still exists (signal 0). EPERM ⇒ process exists.
func processAlive(_ pid: Int) -> Bool {
  guard pid > 0 else { return false }
  #if canImport(Darwin)
    let r = kill(pid_t(pid), 0)
    if r == 0 { return true }
    if errno == EPERM { return true }
    return false
  #else
    return false
  #endif
}

private struct HandoffState {
  var runId: Int
  var refs: Int
  var claimed: Int
  var pids: [Int]
  var hasPidLine: Bool
}

private func parsePids(_ line: String?) -> [Int] {
  guard let line, !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
  var out: [Int] = []
  for part in line.split(separator: ",") {
    let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
    if let n = Int(trimmed), n > 0 { out.append(n) }
  }
  return out
}

private func livePids(_ pids: [Int]) -> [Int] {
  pids.filter { processAlive($0) }
}

private func removeOnePid(_ pids: [Int], pid: Int) -> [Int] {
  guard let idx = pids.firstIndex(of: pid) else { return pids }
  var next = pids
  next.remove(at: idx)
  return next
}

private func holdForLatePeers(claimed: Int, env: [String: String]) -> Bool {
  let expected = peerCount(env)
  return expected > 0 && claimed < expected
}

private func shouldAttachExisting(_ state: HandoffState, live: [Int], env: [String: String]) -> Bool {
  if !live.isEmpty { return true }
  return holdForLatePeers(claimed: state.claimed, env: env)
}

private func resolvedSelfPid(_ override: Int?) -> Int {
  override ?? Int(ProcessInfo.processInfo.processIdentifier)
}

package func claimPeerRun(
  projectId: Int,
  runTitle: String,
  createRun: () async throws -> Int,
  env: [String: String] = envMap(),
  pid: Int? = nil
) async throws -> Int {
  let paths = handoffPaths(projectId: projectId, runTitle: runTitle, env: env)
  try FileManager.default.createDirectory(
    atPath: (paths.idPath as NSString).deletingLastPathComponent,
    withIntermediateDirectories: true
  )

  let me = resolvedSelfPid(pid)
  for _ in 0..<handoffLockWaitAttempts {
    if tryTakeLock(paths.lockPath) {
      defer { try? FileManager.default.removeItem(atPath: paths.lockPath) }
      if let existing = readState(paths.idPath) {
        if isIdStale(paths.idPath) {
          try? FileManager.default.removeItem(atPath: paths.idPath)
        } else {
          let live = existing.hasPidLine ? livePids(existing.pids) : []
          if shouldAttachExisting(existing, live: live, env: env) {
            let pids = live + [me]
            try writeState(
              paths.idPath,
              runId: existing.runId,
              refs: pids.count,
              claimed: existing.claimed + 1,
              pids: pids
            )
            return existing.runId
          }
          try? FileManager.default.removeItem(atPath: paths.idPath)
        }
      }
      let runId = try await createRun()
      try writeState(paths.idPath, runId: runId, refs: 1, claimed: 1, pids: [me])
      return runId
    }
    try? await Task.sleep(nanoseconds: handoffLockWaitSleepNs)
  }
  throw ConfigError.message("peer handoff lock timeout")
}

/// - Parameter allowFinish: when false, decrement refs but never call `finish`
///   or delete `.id` (soft-disable / unsent results — leave the run open).
package func releasePeerRun(
  projectId: Int,
  runTitle: String,
  finish: (Int) async throws -> Void,
  env: [String: String] = envMap(),
  allowFinish: Bool = true,
  pid: Int? = nil
) async throws -> Bool {
  let paths = handoffPaths(projectId: projectId, runTitle: runTitle, env: env)
  let me = resolvedSelfPid(pid)

  for _ in 0..<handoffLockWaitAttempts {
    if tryTakeLock(paths.lockPath) {
      defer { try? FileManager.default.removeItem(atPath: paths.lockPath) }
      guard var state = readState(paths.idPath) else { return false }
      let withoutSelf =
        state.hasPidLine
        ? removeOnePid(livePids(state.pids), pid: me)
        : []
      state.refs = state.hasPidLine ? withoutSelf.count : max(0, state.refs - 1)
      state.pids = state.hasPidLine ? withoutSelf : []
      state.hasPidLine = true
      let hold = peerCount(env) > 0 && state.claimed < peerCount(env)
      if state.refs == 0 && !hold && allowFinish {
        try await finish(state.runId)
        try? FileManager.default.removeItem(atPath: paths.idPath)
        return true
      }
      try writeState(
        paths.idPath,
        runId: state.runId,
        refs: state.refs,
        claimed: state.claimed,
        pids: state.pids
      )
      return false
    }
    try? await Task.sleep(nanoseconds: handoffLockWaitSleepNs)
  }
  throw ConfigError.message("peer handoff lock timeout")
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
  let hasPidLine = lines.count > 3
  let pids = hasPidLine ? parsePids(String(lines[3])) : []
  return HandoffState(
    runId: runId,
    refs: refs,
    claimed: claimed,
    pids: pids,
    hasPidLine: hasPidLine
  )
}

private func writeState(
  _ path: String,
  runId: Int,
  refs: Int,
  claimed: Int,
  pids: [Int]
) throws {
  let pidLine = pids.map(String.init).joined(separator: ",")
  let text = "\(runId)\n\(refs)\n\(claimed)\n\(pidLine)\n"
  let tmp = path + ".tmp"
  try text.write(toFile: tmp, atomically: true, encoding: .utf8)
  try? FileManager.default.removeItem(atPath: path)
  try FileManager.default.moveItem(atPath: tmp, toPath: path)
}

private func isIdStale(_ path: String) -> Bool {
  // Stat failure → not stale (Dart parity). Transient errors must not drop a live `.id`.
  guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
    let modified = attrs[.modificationDate] as? Date
  else { return false }
  return Date().timeIntervalSince(modified) > handoffIdStaleAfter
}

private func isLockStale(_ path: String) -> Bool {
  guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
    let modified = attrs[.modificationDate] as? Date
  else { return false }
  return Date().timeIntervalSince(modified) > handoffLockStaleAfter
}
