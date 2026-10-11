import Foundation

private let secretKeyRe = try! NSRegularExpression(
  pattern: #"(?i)(password|passwd|secret|token|api[_-]?key|authorization|private[_-]?key|credential|access[_-]?key)"#
)

private let allowExact: Set<String> = [
  "CI", "BROWSER", "TEST_ENV", "RUNNER_OS", "RUNNER_ARCH",
]

private let allowPrefix = [
  "GITHUB_", "GITLAB_", "RUNNER_", "CIRCLE_", "BUILDKITE_",
]

/// Harness noise an allowed prefix would otherwise let through.
private let denyExact: Set<String> = [
  "GINKGO_EDITOR_INTEGRATION",
  "GINKGO_PARALLEL_PROTOCOL",
  "GINKGO_PRESERVE_CACHE",
  "GINKGO_PRUNE_STACK",
  "GINKGO_TIME_FORMAT",
  "GODOG_FEATURES",
  "GODOG_SEED",
  "GODOG_TESTED_PACKAGE",
]

private let maxKeyChars = 128
private let maxValueChars = 4096
private let maxKeys = 100

/// Collects a safe CI/runner subset for TestResult.envVars (allowlist-first).
/// Pass `nil` to read the process environment.
package func snapshotEnvVars(_ env: [String: String]? = nil) -> [String: String] {
  let source = env ?? envMap()
  var out: [String: String] = [:]
  for (rawKey, value) in source {
    if value.isEmpty { continue }
    let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
    if key.isEmpty || key.count > maxKeyChars || value.count > maxValueChars { continue }
    if key.hasPrefix("TRACERA_") || denyExact.contains(key) { continue }
    let range = NSRange(key.startIndex..., in: key)
    if secretKeyRe.firstMatch(in: key, options: [], range: range) != nil { continue }
    var allowed = allowExact.contains(key)
    if !allowed {
      allowed = allowPrefix.contains(where: { key.hasPrefix($0) })
    }
    guard allowed else { continue }
    out[key] = value
    if out.count >= maxKeys { break }
  }
  return out
}

package func osLabel() -> String {
  #if os(macOS)
  return "macOS"
  #elseif os(Windows)
  return "Windows"
  #elseif os(Linux)
  return "Linux"
  #else
  return "unknown"
  #endif
}

package func archLabel() -> String {
  #if arch(arm64)
  return "arm64"
  #elseif arch(x86_64)
  return "x86_64"
  #else
  return "unknown"
  #endif
}

package func swiftVersionLabel(_ env: [String: String] = envMap()) -> String {
  let raw = (env["SWIFT_VERSION"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
  return raw.isEmpty ? "6" : raw
}

/// Synthetic Env keys (`OS` / `ARCH` / `SWIFT_VERSION`) plus runner extras.
package func buildEnvVarsExtra(_ extra: [String: String] = [:]) -> [String: String] {
  var out: [String: String] = [
    "OS": osLabel(),
    "ARCH": archLabel(),
    "SWIFT_VERSION": swiftVersionLabel(),
  ]
  for (k, v) in extra where !v.isEmpty { out[k] = v }
  return out
}

/// Merge allowlisted CI snapshot with synthetic / runner extras.
package func mergeEnvVars(extra: [String: String] = [:], env: [String: String]? = nil) -> [String: String] {
  var out = snapshotEnvVars(env)
  for (k, v) in buildEnvVarsExtra(extra) {
    out[k] = v
  }
  return out
}
