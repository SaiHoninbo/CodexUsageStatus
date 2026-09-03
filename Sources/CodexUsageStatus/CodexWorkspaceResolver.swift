import AppKit
import ApplicationServices
import Foundation

struct CodexWorkspaceResolution: Equatable {
    let processID: pid_t?
    let workspaceURL: URL?
    let reason: String
    let windowSignature: String?

    var isKnown: Bool { workspaceURL != nil }
}

/// Uses only public Accessibility window/document metadata. Any ambiguity is
/// deliberately reported as unknown; it never falls back to a previous or
/// largest window workspace.
final class CodexWorkspaceResolver {
    private let gitService: GitWorkspaceService

    init(gitService: GitWorkspaceService = GitWorkspaceService()) {
        self.gitService = gitService
    }

    func resolve(frontmostApplication: NSRunningApplication?) async -> CodexWorkspaceResolution {
        guard let app = frontmostApplication, Self.isCodexApplication(app) else {
            return CodexWorkspaceResolution(processID: frontmostApplication?.processIdentifier, workspaceURL: nil, reason: "Codex 不在前景", windowSignature: nil)
        }
        guard AXIsProcessTrusted() else {
            return CodexWorkspaceResolution(processID: app.processIdentifier, workspaceURL: nil, reason: "需要輔助功能權限才能判定工作區", windowSignature: nil)
        }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var rawWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &rawWindow) == .success,
              let rawWindow else {
            return CodexWorkspaceResolution(processID: app.processIdentifier, workspaceURL: nil, reason: "無法取得 Codex focused window", windowSignature: nil)
        }
        // kAXFocusedWindowAttribute is defined to return an AXUIElement.
        // Check the CoreFoundation type before bridging; ambiguity fails closed.
        guard CFGetTypeID(rawWindow) == AXUIElementGetTypeID() else {
            return CodexWorkspaceResolution(processID: app.processIdentifier, workspaceURL: nil, reason: "無法驗證 Codex focused window", windowSignature: nil)
        }
        let focusedWindow = unsafeBitCast(rawWindow, to: AXUIElement.self)
        let signature = windowSignature(from: focusedWindow)
        guard let candidate = candidateURL(from: focusedWindow) else {
            return CodexWorkspaceResolution(processID: app.processIdentifier, workspaceURL: nil, reason: "focused window 沒有公開 workspace metadata", windowSignature: signature)
        }

        // Keep the public-metadata probe bounded.  A failed Git invocation must
        // not make the HUD wait through an unbounded parent-directory search.
        var current = candidate
        for _ in 0..<4 {
            if let root = await gitService.repositoryRoot(for: current, timeout: 1.0) {
                return CodexWorkspaceResolution(processID: app.processIdentifier, workspaceURL: root, reason: "resolved from focused window document", windowSignature: signature)
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return CodexWorkspaceResolution(processID: app.processIdentifier, workspaceURL: nil, reason: "focused document 不是 Git workspace", windowSignature: signature)
    }

    static func isCodexApplication(_ app: NSRunningApplication) -> Bool {
        CodexApplicationPolicy.isCodexApplication(app)
    }

    /// Returns the bounds of the focused Codex window in Quartz screen
    /// coordinates.  This is intentionally optional: if Accessibility cannot
    /// provide both position and size, callers must fail closed instead of
    /// selecting a different (for example, largest) Codex window.
    static func focusedWindowBounds(for application: NSRunningApplication) -> CGRect? {
        guard Self.isCodexApplication(application), AXIsProcessTrusted() else { return nil }
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

    func focusedWindowSignature(for application: NSRunningApplication) -> String? {
        guard Self.isCodexApplication(application), AXIsProcessTrusted() else { return nil }
        let axApp = AXUIElementCreateApplication(application.processIdentifier)
        var rawWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &rawWindow) == .success,
              let rawWindow,
              CFGetTypeID(rawWindow) == AXUIElementGetTypeID() else { return nil }
        let focusedWindow = unsafeBitCast(rawWindow, to: AXUIElement.self)
        return windowSignature(from: focusedWindow)
    }

    private func windowSignature(from window: AXUIElement) -> String? {
        var pieces: [String] = []
        for attribute in [kAXDocumentAttribute as CFString, kAXTitleAttribute as CFString, kAXPositionAttribute as CFString, kAXSizeAttribute as CFString] {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, attribute, &value) == .success,
                  let value else { continue }
            if let string = value as? String {
                pieces.append(string)
            } else if let url = value as? URL {
                pieces.append(url.standardizedFileURL.path)
            } else if let geometry = geometrySignature(value) {
                pieces.append(geometry)
            }
        }
        return pieces.isEmpty ? nil : pieces.joined(separator: "|")
    }

    private func geometrySignature(_ value: CFTypeRef) -> String? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        switch AXValueGetType(axValue) {
        case .cgPoint:
            var point = CGPoint.zero
            guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
            return "x\(point.x.rounded())y\(point.y.rounded())"
        case .cgSize:
            var size = CGSize.zero
            guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
            return "w\(size.width.rounded())h\(size.height.rounded())"
        default:
            return nil
        }
    }

    private func candidateURL(from window: AXUIElement) -> URL? {
        for attribute in [kAXDocumentAttribute as CFString, kAXURLAttribute as CFString] {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, attribute, &value) == .success, let value else { continue }
            if let url = value as? URL, let validated = validate(url) { return validated }
            if let string = value as? String {
                let url = string.hasPrefix("file://") ? URL(string: string) : URL(fileURLWithPath: string)
                if let url, let validated = validate(url) { return validated }
            }
        }
        return nil
    }

    private func validate(_ url: URL) -> URL? {
        let fileURL = url.isFileURL ? url : URL(fileURLWithPath: url.path)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return fileURL.standardizedFileURL.resolvingSymlinksInPath()
    }
}
