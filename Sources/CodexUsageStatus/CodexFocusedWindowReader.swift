import AppKit
import ApplicationServices

enum CodexFocusedWindowReader {
    static func focusedWindowBounds(for application: NSRunningApplication) -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        var rawWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &rawWindow) == .success,
              let rawWindow, CFGetTypeID(rawWindow) == AXUIElementGetTypeID() else { return nil }
        let windowElement = unsafeBitCast(rawWindow, to: AXUIElement.self)
        var rawPosition: CFTypeRef?
        var rawSize: CFTypeRef?
        guard AXUIElementCopyAttributeValue(windowElement, kAXPositionAttribute as CFString, &rawPosition) == .success,
              AXUIElementCopyAttributeValue(windowElement, kAXSizeAttribute as CFString, &rawSize) == .success else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard let positionValue = rawPosition, let sizeValue = rawSize,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        let positionAX = unsafeBitCast(positionValue, to: AXValue.self)
        let sizeAX = unsafeBitCast(sizeValue, to: AXValue.self)
        guard AXValueGetType(positionAX) == .cgPoint, AXValueGetType(sizeAX) == .cgSize,
              AXValueGetValue(positionAX, .cgPoint, &position), AXValueGetValue(sizeAX, .cgSize, &size),
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: position, size: size)
    }
}
