import Foundation
import Tracera

#if canImport(OSLog)
  import OSLog
#endif

/// Device / host log dump policy (default off).
///
/// On macOS uses `/usr/bin/log show`; elsewhere best-effort `OSLogStore` for
/// the current process. Attaches `device-log.txt`.
public enum LogMode: Sendable {
  /// Do not dump logs automatically.
  case off
  /// Attach `device-log.txt` when a test fails.
  case onFailure
  /// Attach after every finished test.
  case always
}

func shouldCaptureLog(mode: LogMode, failed: Bool) -> Bool {
  switch mode {
  case .off: return false
  case .onFailure: return failed
  case .always: return true
  }
}

/// Dump recent logs and attach as UTF-8 `device-log.txt`.
@discardableResult
public func attachDeviceLog(fileName: String = "device-log.txt", since: Date? = nil) -> Bool {
  guard let ctx = getContext() else { return false }
  return captureDeviceLog(
    fileName: fileName,
    since: since ?? Date().addingTimeInterval(-60),
    into: ctx
  )
}

@discardableResult
func captureDeviceLog(fileName: String, since: Date, into ctx: TestContext) -> Bool {
  // Prefer a real dump; keep a short marker so e2e / onFailure still see a file
  // when the host cannot read unified logs (permission / process scope).
  let text =
    deviceLogText(since: since)
    ?? "Tracera device-log: no unified log dump available in this test process.\n"
  guard let data = text.data(using: .utf8), !data.isEmpty else { return false }
  let lower = fileName.lowercased()
  let name = lower.hasSuffix(".txt") ? fileName : "\(fileName).txt"
  // Path-only staging — keep large dumps out of the process map.
  return attachStagedBytes(data, fileName: name, mimeType: "text/plain", into: ctx)
}

private let maxLogBytes = 256 * 1024

private func deviceLogText(since: Date) -> String? {
  #if os(macOS)
    if let text = runLogShow(since: since) { return text }
  #endif
  #if canImport(OSLog)
    if #available(iOS 15.0, macOS 12.0, tvOS 15.0, *) {
      if let text = osLogStoreText(since: since) { return text }
    }
  #endif
  return nil
}

#if os(macOS)
  private func runLogShow(since: Date) -> String? {
    let elapsed = max(5, Int(Date().timeIntervalSince(since)) + 2)
    let window = min(elapsed, 120)
    let pid = ProcessInfo.processInfo.processIdentifier
    if let text = runLogShowOnce(window: window, predicate: "processIdentifier == \(pid)") {
      return text
    }
    // Predicate can be empty for short windows — do not dump the whole system.
    return nil
  }

  private func runLogShowOnce(window: Int, predicate: String?) -> String? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/log")
    var args = [
      "show",
      "--last", "\(window)s",
      "--style", "compact",
      "--info",
    ]
    if let predicate {
      args.append(contentsOf: ["--predicate", predicate])
    }
    proc.arguments = args
    let out = Pipe()
    proc.standardOutput = out
    proc.standardError = Pipe()
    do {
      try proc.run()
    } catch {
      return nil
    }

    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      proc.waitUntilExit()
      group.leave()
    }
    if group.wait(timeout: .now() + 3) == .timedOut {
      proc.terminate()
    }

    var data = out.fileHandleForReading.readDataToEndOfFile()
    if data.count > maxLogBytes {
      data = Data(data.suffix(maxLogBytes))
    }
    guard let text = String(data: data, encoding: .utf8) else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : text
  }
#endif

#if canImport(OSLog)
  @available(iOS 15.0, macOS 12.0, tvOS 15.0, *)
  private func osLogStoreText(since: Date) -> String? {
    do {
      let store = try OSLogStore(scope: .currentProcessIdentifier)
      let position = store.position(date: since)
      let entries = try store.getEntries(at: position)
      var lines: [String] = []
      var bytes = 0
      for entry in entries {
        guard let log = entry as? OSLogEntryLog else { continue }
        let line = "\(log.date) \(log.composedMessage)"
        bytes += line.utf8.count + 1
        if bytes > maxLogBytes { break }
        lines.append(line)
      }
      return lines.isEmpty ? nil : lines.joined(separator: "\n")
    } catch {
      return nil
    }
  }
#endif
