import Foundation

/// Caps match `scripts/quality/represent-contract.json` (JS / Python / JVM / .NET).
private let maxDepth = 4
private let maxItems = 8
private let maxLeaf = 96
private let maxOut = 240

/// JSON-safe string for bind / step title placeholders (parity with JS/Python/JVM/.NET).
package func represent(_ value: Any?) -> String {
  guard let value else { return "null" }
  return clip(representInner(value, depth: 0), maxOut)
}

/// `str.format`-like replace (JS/Python/JVM/.NET parity). Missing key → original template.
package func formatTemplate(
  _ template: String,
  args: [Any] = [],
  kwargs: [String: Any] = [:]
) -> String {
  if template.isEmpty || !template.contains("{") { return template }
  var missing = false
  var auto = 0
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
      if auto >= args.count {
        missing = true
        out += ns.substring(with: full)
      } else {
        out += represent(args[auto])
        auto += 1
      }
    } else {
      switch resolveField(key, args: args, kwargs: kwargs) {
      case .missing:
        missing = true
        out += ns.substring(with: full)
      case .ok(let value):
        out += represent(value)
      }
    }
    cursor = full.location + full.length
  }
  out += ns.substring(from: cursor)
  if missing { return template }
  return String(out.prefix(128))
}

private enum FieldResult {
  case missing
  case ok(Any?)
}

/// Root from kwargs, else positional `0`/`1`/… in `args`; dotted path walkable.
private func resolveField(_ key: String, args: [Any], kwargs: [String: Any]) -> FieldResult {
  let parts = key.split(separator: ".").map(String.init)
  guard let root = parts.first, !root.isEmpty else { return .missing }

  let rootVal: Any?
  if kwargs.keys.contains(root) {
    rootVal = kwargs[root]
  } else if let idx = argIndex(root), idx >= 0, idx < args.count {
    rootVal = args[idx]
  } else {
    return .missing
  }

  if parts.count == 1 { return .ok(rootVal) }

  var cur: Any? = rootVal
  for part in parts.dropFirst() {
    guard let c = cur, !(c is NSNull) else { return .missing }
    if let dict = c as? [String: Any] {
      guard dict.keys.contains(part) else { return .missing }
      cur = dict[part]
    } else if let dict = c as? NSDictionary {
      guard dict.object(forKey: part) != nil else { return .missing }
      cur = dict[part]
    } else if let child = Mirror(reflecting: c).children.first(where: { $0.label == part }) {
      cur = child.value
    } else {
      return .missing
    }
  }
  return .ok(cur)
}

/// `0` / `12` — positional root. Leading zeros are not an index.
private func argIndex(_ token: String) -> Int? {
  guard token == "0" || (token.first != "0" && token.allSatisfy(\.isNumber)) else {
    return nil
  }
  return Int(token)
}

/// Formats a declarative bind name from named / positional params (`{0}` / `{param}`).
package func formatBindName(_ template: String, params: [String: Any]) -> String {
  formatTemplate(template, args: [], kwargs: params)
}

private func clip(_ text: String, _ limit: Int) -> String {
  if text.count <= limit { return text }
  if limit <= 1 { return "…" }
  return String(text.prefix(limit - 1)) + "…"
}

private func representInner(_ value: Any, depth: Int) -> String {
  if depth > maxDepth { return "…" }

  // NSNull from JSON
  if value is NSNull { return "null" }

  // Exact Swift Bool only — `NSNumber(1) as? Bool` bridges to `true` and must not win.
  if type(of: value) == Bool.self {
    return (value as! Bool) ? "true" : "false"
  }

  if let s = value as? String {
    return clip(s, maxLeaf)
  }
  if let u = value as? UUID {
    return u.uuidString.lowercased()
  }
  if let url = value as? URL {
    return clip(url.path, maxLeaf)
  }

  // NSNumber before Int/Double — JSON and ObjC bridge often yield NSNumber.
  // Only CFBoolean is bool (`NSNumber(1)` must stay "1", not "true").
  if let num = value as? NSNumber {
    if CFGetTypeID(num as CFTypeRef) == CFBooleanGetTypeID() {
      return num.boolValue ? "true" : "false"
    }
    let objCType = String(cString: num.objCType)
    if objCType == "d" || objCType == "f" {
      let d = num.doubleValue
      if d.isNaN || d.isInfinite { return String(describing: d) }
      if d.rounded() == d { return String(Int(d)) }
      return String(d)
    }
    return num.stringValue
  }

  if let i = value as? Int { return String(i) }
  if let i = value as? Int64 { return String(i) }
  if let i = value as? UInt { return String(i) }
  if let d = value as? Double {
    if d.isNaN || d.isInfinite { return String(describing: d) }
    if d.rounded() == d { return String(Int(d)) }
    return String(d)
  }
  if let f = value as? Float {
    return representInner(Double(f), depth: depth)
  }

  if let arr = asAnyArray(value) {
    let limit = min(arr.count, maxItems)
    var parts: [String] = []
    for i in 0..<limit {
      parts.append(representInner(arr[i], depth: depth + 1))
    }
    let more = arr.count > maxItems ? ", …" : ""
    return "[\(parts.joined(separator: ", "))\(more)]"
  }

  if let dict = asStringKeyedDict(value) {
    let keys = dict.keys.sorted().prefix(maxItems)
    var parts: [String] = []
    for k in keys {
      parts.append("\(k): \(representInner(dict[k]!, depth: depth + 1))")
    }
    let more = dict.count > maxItems ? ", …" : ""
    return "{\(parts.joined(separator: ", "))\(more)}"
  }

  let text = String(describing: value)
  return clip(text, maxLeaf)
}

private func asAnyArray(_ value: Any) -> [Any]? {
  if let arr = value as? [Any] { return arr }
  if let arr = value as? NSArray { return arr.map { $0 as Any } }
  if let arr = value as? [Int] { return arr.map { $0 as Any } }
  if let arr = value as? [String] { return arr.map { $0 as Any } }
  if let arr = value as? [Double] { return arr.map { $0 as Any } }
  let mirror = Mirror(reflecting: value)
  guard mirror.displayStyle == .collection else { return nil }
  return mirror.children.map(\.value)
}

private func asStringKeyedDict(_ value: Any) -> [String: Any]? {
  if let dict = value as? [String: Any] { return dict }
  if let dict = value as? NSDictionary {
    var out: [String: Any] = [:]
    for (k, v) in dict {
      guard let key = k as? String else { continue }
      out[key] = v
    }
    return out
  }
  return nil
}
