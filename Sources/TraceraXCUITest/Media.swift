import Foundation
import Tracera
import XCTest

#if os(macOS)
  import AppKit
  import CoreGraphics
  import ScreenCaptureKit
#endif

#if canImport(XCUIAutomation) && !os(macOS)
  import XCUIAutomation
#endif

/// Screenshot capture policy for XCUITest (default off).
public enum ScreenshotMode: Sendable {
  /// Do not capture screenshots automatically.
  case off
  /// Capture a PNG when a test fails.
  case onFailure
  /// Capture when the test passes.
  case onSuccess
  /// Capture after every finished test.
  case always
}

/// Window / accessibility hierarchy dump policy (default off).
public enum HierarchyMode: Sendable {
  /// Do not dump hierarchy automatically.
  case off
  /// Attach `window-hierarchy.txt` when a test fails.
  case onFailure
  /// Attach after every finished test.
  case always
}

func shouldCaptureScreenshot(mode: ScreenshotMode, failed: Bool) -> Bool {
  switch mode {
  case .off: return false
  case .onFailure: return failed
  case .onSuccess: return !failed
  case .always: return true
  }
}

func shouldCaptureHierarchy(mode: HierarchyMode, failed: Bool) -> Bool {
  switch mode {
  case .off: return false
  case .onFailure: return failed
  case .always: return true
  }
}

/// Capture a PNG and attach it to the open step (or result).
///
/// Opt-in — prefer `install(screenshots:)`. On **iOS** / **tvOS** uses
/// `XCUIScreen`. On **macOS** uses ScreenCaptureKit when screen-recording
/// permission is granted (otherwise returns `false`).
@discardableResult
public func screenshot(fileName: String = "screenshot.png") -> Bool {
  guard let ctx = getContext() else { return false }
  return captureScreenshot(fileName: fileName, into: ctx)
}

/// Dump a best-effort window / accessibility hierarchy and attach it as UTF-8
/// text. Returns `false` when unavailable.
///
/// Content is UTF-8 text — file name defaults to `window-hierarchy.txt`.
/// On macOS uses `CGWindowListCopyWindowInfo`; on iOS / tvOS uses
/// `XCUIApplication.debugDescription`.
@discardableResult
public func attachHierarchy(fileName: String = "window-hierarchy.txt") -> Bool {
  guard let ctx = getContext() else { return false }
  return captureHierarchy(fileName: fileName, into: ctx)
}

@discardableResult
func captureScreenshot(fileName: String, into ctx: TestContext) -> Bool {
  let data = screenshotPNGData()
  guard let data, !data.isEmpty else { return false }
  let name = fileName.lowercased().hasSuffix(".png") ? fileName : "\(fileName).png"
  // Path-only staging — large PNGs must not sit in PendingBlobs as Data.
  return attachStagedBytes(data, fileName: name, mimeType: "image/png", into: ctx)
}

@discardableResult
func captureHierarchy(fileName: String, into ctx: TestContext) -> Bool {
  guard let text = hierarchyText(), let data = text.data(using: .utf8), !data.isEmpty else {
    return false
  }
  let lower = fileName.lowercased()
  let name =
    lower.hasSuffix(".txt") || lower.hasSuffix(".xml") ? fileName : "\(fileName).txt"
  return attachStagedBytes(data, fileName: name, mimeType: "text/plain", into: ctx)
}

private func screenshotPNGData() -> Data? {
  #if os(macOS)
    return macScreenshotPNG()
  #elseif canImport(XCUIAutomation)
    return xcuiScreenshotPNG()
  #else
    return nil
  #endif
}

private func hierarchyText() -> String? {
  #if os(macOS)
    return macWindowListText()
  #elseif canImport(XCUIAutomation)
    return xcuiHierarchyText()
  #else
    return nil
  #endif
}

#if canImport(XCUIAutomation) && !os(macOS)
  private func xcuiScreenshotPNG() -> Data? {
    let work: () -> Data? = {
      let shot = XCUIScreen.main.screenshot()
      return shot.pngRepresentation
    }
    if Thread.isMainThread {
      return work()
    }
    var captured: Data?
    DispatchQueue.main.sync { captured = work() }
    return captured
  }

  private func xcuiHierarchyText() -> String? {
    let work: () -> String? = {
      let raw = XCUIApplication().debugDescription
      let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : raw
    }
    if Thread.isMainThread {
      return work()
    }
    var captured: String?
    DispatchQueue.main.sync { captured = work() }
    return captured
  }
#endif

#if os(macOS)
  private func macScreenshotPNG() -> Data? {
    if #available(macOS 14.0, *) {
      return scScreenshotPNG()
    }
    return nil
  }

  @available(macOS 14.0, *)
  private func scScreenshotPNG() -> Data? {
    final class Box: @unchecked Sendable {
      var data: Data?
    }
    let box = Box()
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
      defer { sem.signal() }
      do {
        let content = try await SCShareableContent.excludingDesktopWindows(
          false,
          onScreenWindowsOnly: true
        )
        guard let display = content.displays.first else { return }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(
          contentFilter: filter,
          configuration: config
        )
        let rep = NSBitmapImageRep(cgImage: image)
        box.data = rep.representation(using: .png, properties: [:])
      } catch {
        box.data = nil
      }
    }
    _ = sem.wait(timeout: .now() + 15)
    return box.data
  }

  private func macWindowListText() -> String? {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard
      let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]],
      !info.isEmpty
    else {
      return nil
    }
    var lines: [String] = []
    for w in info.prefix(50) {
      let owner = w[kCGWindowOwnerName as String] as? String ?? ""
      let name = w[kCGWindowName as String] as? String ?? ""
      let layer = w[kCGWindowLayer as String] as? Int ?? 0
      lines.append("\(owner) | \(name) | layer=\(layer)")
    }
    let joined = lines.joined(separator: "\n")
    return joined.isEmpty ? nil : joined
  }
#endif
