import Foundation

/// JSON-safe string for bind / step title placeholders (parity with JS/Python/JVM/.NET).
package func represent(_ value: Any?) -> String {
  guard let value else { return "null" }
  switch value {
  case let b as Bool: return b ? "true" : "false"
  case let i as Int: return String(i)
  case let i as Int64: return String(i)
  case let d as Double:
    if d.isNaN || d.isInfinite { return String(describing: d) }
    if d.rounded() == d { return String(Int(d)) }
    return String(d)
  case let s as String: return s
  case let u as UUID: return u.uuidString.lowercased()
  case let url as URL: return url.path
  case let arr as [Any]:
    let inner = arr.prefix(32).map { represent($0) }.joined(separator: ", ")
    return "[\(inner)\(arr.count > 32 ? ", …" : "")]"
  case let dict as [String: Any]:
    let keys = dict.keys.sorted().prefix(32)
    let inner = keys.map { "\($0): \(represent(dict[$0]!))" }.joined(separator: ", ")
    return "{\(inner)\(dict.count > 32 ? ", …" : "")}"
  default:
    return String(describing: value)
  }
}

package func formatTemplate(_ template: String, params: [String: Any]) -> String {
  if template.isEmpty { return template }
  var missing = false
  let pattern = try! NSRegularExpression(pattern: #"\{([^{}]*)\}"#)
  let ns = template as NSString
  let matches = pattern.matches(in: template, range: NSRange(location: 0, length: ns.length))
  var out = ""
  var cursor = 0
  for match in matches {
    let full = match.range
    out += ns.substring(with: NSRange(location: cursor, length: full.location - cursor))
    let keyRange = match.range(at: 1)
    let key = ns.substring(with: keyRange)
    if key.isEmpty {
      missing = true
      out += ns.substring(with: full)
    } else if let value = resolveParam(key, params: params) {
      out += represent(value)
    } else {
      missing = true
      out += ns.substring(with: full)
    }
    cursor = full.location + full.length
  }
  out += ns.substring(from: cursor)
  if missing { return template }
  return String(out.prefix(128))
}

private func resolveParam(_ key: String, params: [String: Any]) -> Any? {
  if let direct = params[key] { return direct }
  if key.contains(".") {
    let parts = key.split(separator: ".", maxSplits: 1).map(String.init)
    guard parts.count == 2, let root = params[parts[0]] else { return nil }
    if let dict = root as? [String: Any] { return dict[parts[1]] }
    return Mirror(reflecting: root).children.first(where: { $0.label == parts[1] })?.value
  }
  return nil
}

/// Formats a declarative bind name from named / positional params.
package func formatBindName(_ template: String, params: [String: Any]) -> String {
  formatTemplate(template, params: params)
}
