import AppKit
import ApplicationServices
import Foundation

/// Reads only the focused Codex window bounds.  Repository and Git
/// resolution deliberately do not live here; the HUD needs geometry, not a
/// direct Git client.
enum CodexFocusedWindowReader {
    static func focusedWindowBounds(for application: NSRunningApplication) -> CGRect? {
        guard CodexApplicationPolicy.isCodexApplication(application), AXIsProcessTrusted() else { return nil }
        let axApp = AXUIElementCreateApplication(application.processIdentifier)
        var rawWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &rawWindow) == .success,
              let rawWindow,
              CFGetTypeID(rawWindow) == AXUIElementGetTypeID() else { return nil }
        let window = unsafeBitCast(rawWindow, to: AXUIElement.self)
        var rawPosition: CFTypeRef?
        var rawSize: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &rawPosition) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &rawSize) == .success,
              let rawPosition, let rawSize,
              CFGetTypeID(rawPosition) == AXValueGetTypeID(),
              CFGetTypeID(rawSize) == AXValueGetTypeID() else { return nil }
        let positionValue = unsafeBitCast(rawPosition, to: AXValue.self)
        let sizeValue = unsafeBitCast(rawSize, to: AXValue.self)
        guard AXValueGetType(positionValue) == .cgPoint, AXValueGetType(sizeValue) == .cgSize else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &point), AXValueGetValue(sizeValue, .cgSize, &size),
              size.width >= 300, size.height >= 200 else { return nil }
        return CGRect(origin: point, size: size)
    }
}
