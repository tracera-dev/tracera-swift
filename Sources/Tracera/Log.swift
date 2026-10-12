import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

/// Verbosity of the adapter's own log lines (`TRACERA_LOG_LEVEL`).
package enum LogLevel: Int, Comparable, Sendable {
  case error = 0
  case warn = 1
  case info = 2
  case debug = 3

  package static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

private let levelLock = NSLock()
private nonisolated(unsafe) var currentLevel: LogLevel = parseLogLevel(
  ProcessInfo.processInfo.environment["TRACERA_LOG_LEVEL"]
)

private let ansiGray = "\u{001B}[90m"
private let ansiRed = "\u{001B}[31m"
private let ansiYellow = "\u{001B}[33m"
private let ansiCyan = "\u{001B}[36m"
private let ansiMagenta = "\u{001B}[35m"
private let ansiGreen = "\u{001B}[32m"
private let ansiBold = "\u{001B}[1m"
private let ansiReset = "\u{001B}[0m"

package func parseLogLevel(_ raw: String?) -> LogLevel {
  switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
  case "error": return .error
  case "warn": return .warn
  case "debug": return .debug
  default: return .info
  }
}

/// Applies `TRACERA_LOG_LEVEL` (`error` | `warn` | `info` | `debug`).
package func setLogLevel(_ raw: String?) {
  levelLock.lock()
  currentLevel = parseLogLevel(raw)
  levelLock.unlock()
}

/// The level the adapter currently logs at.
package func logLevel() -> LogLevel {
  levelLock.lock()
  defer { levelLock.unlock() }
  return currentLevel
}

/// `2026-10-02T19:30:00.000Z` — ISO 8601 UTC with milliseconds.
package func logTimestamp(_ date: Date = Date()) -> String {
  // Round to whole ms first so Double sub-seconds (e.g. 0.007) match JS/Python.
  let msTotal = Int64((date.timeIntervalSince1970 * 1000.0).rounded())
  let sec = TimeInterval(msTotal / 1000)
  // Always non-negative 0…999 even for pre-epoch instants.
  let ms = Int(((msTotal % 1000) + 1000) % 1000)
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(secondsFromGMT: 0)!
  let c = calendar.dateComponents(
    [.year, .month, .day, .hour, .minute, .second],
    from: Date(timeIntervalSince1970: sec)
  )
  return String(
    format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
    c.year ?? 0,
    c.month ?? 0,
    c.day ?? 0,
    c.hour ?? 0,
    c.minute ?? 0,
    c.second ?? 0,
    ms
  )
}

private func levelLabel(_ level: LogLevel) -> String {
  switch level {
  case .error: return "ERROR"
  case .warn: return "WARN "
  case .info: return "INFO "
  case .debug: return "DEBUG"
  }
}

private func levelColor(_ level: LogLevel) -> String {
  switch level {
  case .error: return ansiRed
  case .warn: return ansiYellow
  case .info: return ansiCyan
  case .debug: return ansiMagenta
  }
}

/// Formats one log line exactly as emit writes it (unit-test seam; no ANSI).
package func formatLogLine(_ level: LogLevel, _ message: String, now: Date = Date()) -> String {
  let lines = message.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
  let first = lines.first ?? ""
  let head = "\(logTimestamp(now)) \(levelLabel(level)) \(first)"
  if lines.count <= 1 { return head }
  return head + "\n" + lines.dropFirst().joined(separator: "\n")
}

private func useColor(fd: Int32) -> Bool {
  let env = ProcessInfo.processInfo.environment
  if let no = env["NO_COLOR"], !no.isEmpty { return false }
  if let force = env["FORCE_COLOR"], !force.isEmpty { return true }
  return isatty(fd) != 0
}

private func paint(fd: Int32, color: String, text: String) -> String {
  useColor(fd: fd) ? "\(color)\(text)\(ansiReset)" : text
}

private func writeStream(fd: Int32, handle: FileHandle, _ line: String) {
  var out = line
  if !out.hasSuffix("\n") { out += "\n" }
  if let data = out.data(using: .utf8) {
    handle.write(data)
  }
}

private func emit(_ level: LogLevel, _ message: String) {
  levelLock.lock()
  let threshold = currentLevel
  levelLock.unlock()
  guard level.rawValue <= threshold.rawValue else { return }

  let isError = level == .error
  let fd: Int32 = isError ? STDERR_FILENO : STDOUT_FILENO
  let handle = isError ? FileHandle.standardError : FileHandle.standardOutput
  let lines = message.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
  let first = lines.first ?? ""
  let head =
    "\(paint(fd: fd, color: ansiGray, text: logTimestamp())) "
    + "\(paint(fd: fd, color: levelColor(level), text: levelLabel(level))) "
    + first
  let body = lines.count > 1 ? "\n" + lines.dropFirst().joined(separator: "\n") : ""
  writeStream(fd: fd, handle: handle, head + body)
}

package func logError(_ message: String) { emit(.error, message) }
package func logWarn(_ message: String) { emit(.warn, message) }
package func logDebug(_ message: String) { emit(.debug, message) }

/// Green run link — always printed (ignores `TRACERA_LOG_LEVEL`).
package func logLink(_ url: String) {
  let fd = STDOUT_FILENO
  let handle = FileHandle.standardOutput
  let line =
    "\(paint(fd: fd, color: ansiGray, text: logTimestamp())) "
    + "\(paint(fd: fd, color: ansiBold + ansiGreen, text: "Tracera: \(url)"))"
  writeStream(fd: fd, handle: handle, line)
}
