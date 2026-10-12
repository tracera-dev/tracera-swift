import Foundation

package let maxTextChars = 65_536

private let csiRe = try! NSRegularExpression(pattern: #"\u001b\[[0-9;?]*[ -/]*[@-~]"#)
private let oscRe = try! NSRegularExpression(pattern: #"\u001b\][^\u0007]*(?:\u0007|\u001b\\)"#)
private let skipWrapper = try! NSRegularExpression(pattern: #"^(?:skipped)\s*:\s*"#, options: .caseInsensitive)

package func stripAnsi(_ text: String) -> String {
  var out = text
  out = oscRe.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "")
  out = csiRe.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "")
  return out
}

package func joinMessageStack(_ message: String?, _ stack: String?) -> String {
  let m = (message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
  let s = (stack ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
  if m.isEmpty && s.isEmpty { return "" }
  if s.isEmpty { return m }
  if m.isEmpty { return s }
  if s == m || s.hasPrefix(m) || s.contains(m) { return s }
  return "\(m)\n\(s)"
}

package func captureStack(skipFrames: Int = 2) -> String {
  let frames = Thread.callStackSymbols
  guard frames.count > skipFrames else { return frames.joined(separator: "\n") }
  return frames.dropFirst(skipFrames).joined(separator: "\n")
}

package func formatFailureText(_ error: Any?, stack: String? = nil) -> String {
  if error == nil {
    // Caller passed no error — do not invent a stack-only failure text.
    guard let stack else { return "" }
    return stripAnsi(stack).trimmingCharacters(in: .whitespacesAndNewlines)
  }
  let captured = stack ?? captureStack()
  if let text = error as? String {
    return stripAnsi(joinMessageStack(text, captured))
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
  if let err = error as? Error {
    let message = errorMessage(err)
    return stripAnsi(joinMessageStack(message, captured))
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
  return stripAnsi(joinMessageStack(String(describing: error!), captured))
    .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func errorMessage(_ error: Error) -> String {
  if let localized = error as? LocalizedError, let desc = localized.errorDescription, !desc.isEmpty {
    return desc
  }
  let ns = error as NSError
  if !ns.localizedDescription.isEmpty,
    ns.localizedDescription != "The operation couldn’t be completed. (\(ns.domain) error \(ns.code).)"
  {
    return ns.localizedDescription
  }
  return String(describing: error)
}

package func normalizeSkipReason(_ reason: String?) -> String {
  let text = (reason ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
  if text.isEmpty { return "" }
  let range = NSRange(text.startIndex..., in: text)
  return skipWrapper.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    .trimmingCharacters(in: .whitespacesAndNewlines)
}

package func appendText(_ prev: String, _ next: String?) -> String {
  let text = (next ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
  if text.isEmpty { return prev }
  if prev.isEmpty { return String(text.prefix(maxTextChars)) }
  if prev.hasSuffix(text) { return prev }
  let joined = "\(prev)\n\n\(text)"
  return String(joined.prefix(maxTextChars))
}
