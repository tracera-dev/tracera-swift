// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "tracera-swift",
  platforms: [
    // Mutex (Synchronization) + Swift Testing floor — Xcode 16 / Swift 6.
    .macOS(.v15),
    .iOS(.v18),
    .tvOS(.v18),
    .watchOS(.v11),
  ],
  products: [
    .library(name: "Tracera", targets: ["Tracera"]),
    .library(name: "TraceraTesting", targets: ["TraceraTesting"]),
    .library(name: "TraceraXCUITest", targets: ["TraceraXCUITest"]),
  ],
  targets: [
    .target(
      name: "Tracera",
      path: "Sources/Tracera",
      swiftSettings: [
        // Payload dictionaries (`[String: Any]`) are not Sendable; keep
        // race-safe via actors / single-owner Tasks (parity with Dart/Go).
        .swiftLanguageMode(.v5)
      ]
    ),
    .target(
      name: "TraceraTesting",
      dependencies: ["Tracera"],
      path: "Sources/TraceraTesting"
    ),
    .target(
      name: "TraceraXCUITest",
      dependencies: ["Tracera"],
      path: "Sources/TraceraXCUITest",
      swiftSettings: [
        .swiftLanguageMode(.v5)
      ]
    ),
  ]
)
