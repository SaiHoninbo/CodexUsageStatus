import AppKit
import ApplicationServices
import CoreGraphics

@MainActor
enum ClipboardPasteService {
    private static var lastPermissionPromptAt: Date?
    private static var activeTemporaryOperationToken: UUID?
    private static var completedTemporaryOperationTokens = Set<UUID>()

    /// Exposed for the HUD and core tests.  The lock is process-wide because
    /// NSPasteboard.general is shared by every HUD instance and menu action.
    static var isTemporaryOperationInFlight: Bool {
        activeTemporaryOperationToken != nil
    }

    static func pasteToCodex(processID: pid_t?) {
        performPaste(
            processID: processID,
            submitAfterPaste: false,
            completion: nil
        )
    }

    /// Pastes the current clipboard into Codex and submits it with one Return
    /// key event. The optional completion is called exactly once for the
    /// submit flow, after Return succeeds or the guarded flow aborts.
    static func pasteAndSubmitToCodex(
        processID: pid_t?,
        completion: @escaping (Bool) -> Void = { _ in }
    ) {
        performPaste(
            processID: processID,
            submitAfterPaste: true,
            completion: completion
        )
    }

    /// Seeds the Codex composer with a temporary prompt without changing the
    /// semantics of the normal user-clipboard paste APIs above.  A complete
    /// pasteboard snapshot is restored only while this operation still owns
    /// the prepared text and no external clipboard change was observed.
    static func pasteTemporaryTextToCodex(
        _ shortcut: CodexPromptShortcut,
        processID: pid_t?,
        completion: @escaping (Bool) -> Void = { _ in }
    ) {
        guard ClipboardTemporaryOperationPolicy.canStart(
            isOperationInFlight: activeTemporaryOperationToken != nil
        ) else {
            completion(false)
            return
        }

        guard let target = processID.flatMap(NSRunningApplication.init)
                ?? NSWorkspace.shared.runningApplications.first(where: isCodexApplication) else {
            completion(false)
            return
        }

        guard isEventPostingAuthorized() else {
            promptForAccessibilityPermissionIfNeeded()
            completion(false)
            return
        }

        let pasteboard = NSPasteboard.general
        guard let snapshot = PasteboardSnapshot.capture(from: pasteboard) else {
            completion(false)
            return
        }
        let initialChangeCount = pasteboard.changeCount

        let token = UUID()
        activeTemporaryOperationToken = token
        target.activate(options: [.activateAllWindows])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
            guard isTemporaryOperationOwned(by: token),
                  isTargetFrontmost(target),
                  pasteboard.changeCount == initialChangeCount else {
                finishTemporaryOperation(
                    token: token,
                    snapshot: snapshot,
                    preparedChangeCount: nil,
                    expectedText: shortcut.text,
                    completion: completion,
                    success: false
                )
                return
            }

            let beforeChangeCount = pasteboard.changeCount
            let clearedChangeCount = pasteboard.clearContents()
            guard pasteboard.pasteboardItems?.isEmpty ?? true else {
                finishTemporaryOperation(
                    token: token,
                    snapshot: snapshot,
                    preparedChangeCount: clearedChangeCount,
                    expectedText: shortcut.text,
                    completion: completion,
                    success: false
                )
                return
            }
            guard pasteboard.setString(shortcut.text, forType: .string) else {
                finishTemporaryOperation(
                    token: token,
                    snapshot: snapshot,
                    preparedChangeCount: pasteboard.changeCount,
                    expectedText: shortcut.text,
                    completion: completion,
                    success: false
                )
                return
            }

            let preparedChangeCount = pasteboard.changeCount
            guard preparedTextWriteIsValid(
                expectedText: shortcut.text,
                observedText: pasteboard.string(forType: .string),
                beforeChangeCount: beforeChangeCount,
                afterChangeCount: preparedChangeCount
            ),
            preparedChangeCount == clearedChangeCount
                || preparedChangeCount == clearedChangeCount + 1 else {
                finishTemporaryOperation(
                    token: token,
                    snapshot: snapshot,
                    preparedChangeCount: preparedChangeCount,
                    expectedText: shortcut.text,
                    completion: completion,
                    success: false
                )
                return
            }

            guard isTargetFrontmost(target),
                  pasteboard.changeCount == preparedChangeCount,
                  pasteboard.string(forType: .string) == shortcut.text,
                  postKey(keyCode: 9, flags: .maskCommand) else {
                finishTemporaryOperation(
                    token: token,
                    snapshot: snapshot,
                    preparedChangeCount: preparedChangeCount,
                    expectedText: shortcut.text,
                    completion: completion,
                    success: false
                )
                return
            }

            guard shortcut.submitAfterPaste else {
                // Allow the asynchronous Cmd-V event to be consumed before
                // restoring the user's full clipboard snapshot.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    finishTemporaryOperation(
                        token: token,
                        snapshot: snapshot,
                        preparedChangeCount: preparedChangeCount,
                        expectedText: shortcut.text,
                        completion: completion,
                        success: true
                    )
                }
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                guard isTemporaryOperationOwned(by: token),
                      !target.isTerminated,
                      isTargetFrontmost(target),
                      pasteboard.changeCount == preparedChangeCount,
                      pasteboard.string(forType: .string) == shortcut.text,
                      postKey(keyCode: 36) else {
                    finishTemporaryOperation(
                        token: token,
                        snapshot: snapshot,
                        preparedChangeCount: preparedChangeCount,
                        expectedText: shortcut.text,
                        completion: completion,
                        success: false
                    )
                    return
                }

                finishTemporaryOperation(
                    token: token,
                    snapshot: snapshot,
                    preparedChangeCount: preparedChangeCount,
                    expectedText: shortcut.text,
                    completion: completion,
                    success: true
                )
            }
        }
    }

    /// `setString` is allowed to leave NSPasteboard.changeCount unchanged on
    /// macOS.  Exact readback is the semantic guard; the counter only needs
    /// to be monotonic so an unrelated write can never look like our prepare.
    static func preparedTextWriteIsValid(
        expectedText: String,
        observedText: String?,
        beforeChangeCount: Int,
        afterChangeCount: Int
    ) -> Bool {
        ClipboardTemporaryOperationPolicy.preparedTextWriteIsValid(
            expectedText: expectedText,
            observedText: observedText,
            beforeChangeCount: beforeChangeCount,
            afterChangeCount: afterChangeCount
        )
    }

    private static func isTemporaryOperationOwned(by token: UUID) -> Bool {
        activeTemporaryOperationToken == token
    }

    @discardableResult
    private static func finishTemporaryOperation(
        token: UUID,
        snapshot: PasteboardSnapshot,
        preparedChangeCount: Int?,
        expectedText: String,
        completion: @escaping (Bool) -> Void,
        success: Bool
    ) -> Bool {
        guard activeTemporaryOperationToken == token else {
            if completedTemporaryOperationTokens.insert(token).inserted {
                completion(false)
            }
            return false
        }

        var finalSuccess = success
        if let preparedChangeCount {
            let pasteboard = NSPasteboard.general
            let unchanged = pasteboard.changeCount == preparedChangeCount
            if unchanged {
                // On a failure after clearContents (including setString
                // returning false or a readback mismatch), restore whenever
                // the clipboard is still ours.  On success require the exact
                // expected text before restoring.
                let mayRestore = !success || ClipboardTemporaryOperationPolicy.canRestore(
                    expectedText: expectedText,
                    observedText: pasteboard.string(forType: .string),
                    preparedChangeCount: preparedChangeCount,
                    currentChangeCount: pasteboard.changeCount
                )
                if mayRestore {
                    finalSuccess = snapshot.restore(to: pasteboard) && finalSuccess
                } else {
                    finalSuccess = false
                }
            } else {
                // The user changed the clipboard after preparation.  Do not
                // overwrite their newer content with our old snapshot.
                finalSuccess = false
            }
        }
        completedTemporaryOperationTokens.insert(token)
        if completedTemporaryOperationTokens.count > 64 {
            completedTemporaryOperationTokens.removeAll(keepingCapacity: true)
        }
        activeTemporaryOperationToken = nil
        completion(finalSuccess)
        return finalSuccess
    }

    private struct PasteboardSnapshot {
        struct Item {
            let representations: [(type: NSPasteboard.PasteboardType, data: Data)]
        }

        let items: [Item]

        static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot? {
            guard let pasteboardItems = pasteboard.pasteboardItems else {
                return PasteboardSnapshot(items: [])
            }

            var items: [Item] = []
            items.reserveCapacity(pasteboardItems.count)
            for pasteboardItem in pasteboardItems {
                var representations: [(type: NSPasteboard.PasteboardType, data: Data)] = []
                representations.reserveCapacity(pasteboardItem.types.count)
                for type in pasteboardItem.types {
                    guard let data = pasteboardItem.data(forType: type) else {
                        return nil
                    }
                    representations.append((type: type, data: data))
                }
                guard !representations.isEmpty else { return nil }
                items.append(Item(representations: representations))
            }
            return PasteboardSnapshot(items: items)
        }

        func restore(to pasteboard: NSPasteboard) -> Bool {
            pasteboard.clearContents()
            let restoredItems: [NSPasteboardItem] = items.map { item in
                let pasteboardItem = NSPasteboardItem()
                for representation in item.representations {
                    pasteboardItem.setData(representation.data, forType: representation.type)
                }
                return pasteboardItem
            }
            guard !restoredItems.isEmpty else { return true }
            if pasteboard.writeObjects(restoredItems) { return true }
            // A transient pasteboard provider failure should not leave the
            // user's clipboard empty. Retry the complete item set once; if
            // this also fails the operation reports failure without ever
            // attempting to restore over newer external content.
            pasteboard.clearContents()
            return pasteboard.writeObjects(restoredItems)
        }
    }

    private static func performPaste(
        processID: pid_t?,
        submitAfterPaste: Bool,
        completion: ((Bool) -> Void)?
    ) {
        guard NSPasteboard.general.canReadObject(forClasses: [NSString.self, NSImage.self], options: nil) else {
            showAlert(
                title: "剪貼簿沒有可貼上的內容",
                message: "請先複製文字或圖片，再按一次貼上。"
            )
            completion?(false)
            return
        }

        guard let target = processID.flatMap(NSRunningApplication.init)
                ?? NSWorkspace.shared.runningApplications.first(where: isCodexApplication) else {
            showAlert(
                title: "找不到 Codex",
                message: "請先開啟 Codex，再使用剪貼簿貼上。"
            )
            completion?(false)
            return
        }

        guard isEventPostingAuthorized() else {
            promptForAccessibilityPermissionIfNeeded()
            completion?(false)
            return
        }

        // The HUD is a non-activating panel. Activate Codex first and then
        // post the shortcut to the active session, so the restored text field
        // receives it even when the original Codex process/window was rebuilt.
        target.activate(options: [.activateAllWindows])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
            guard isTargetFrontmost(target) else {
                target.activate(options: [.activateAllWindows])
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    guard isTargetFrontmost(target) else {
                        showAlert(
                            title: "無法貼上剪貼簿內容",
                            message: "Codex 沒有保持在前景，為安全起見沒有貼上或送出。"
                        )
                        completion?(false)
                        return
                    }
                    finishPaste(
                        to: target,
                        submitAfterPaste: submitAfterPaste,
                        completion: completion
                    )
                }
                return
            }
            finishPaste(
                to: target,
                submitAfterPaste: submitAfterPaste,
                completion: completion
            )
        }
    }

    private static func finishPaste(
        to target: NSRunningApplication,
        submitAfterPaste: Bool,
        completion: ((Bool) -> Void)?
    ) {
        guard postKey(keyCode: 9, flags: .maskCommand) else {
            showAlert(
                title: "無法貼上剪貼簿內容",
                message: "目前無法建立鍵盤事件。請重新開啟 CodexUsageStatus 後再試一次。"
            )
            completion?(false)
            return
        }

        guard submitAfterPaste else { return }

        // Cmd-V is asynchronous for rich content such as an image. Leave a
        // small settling window before sending Return, and re-check focus so
        // an intervening app cannot receive the submit key.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            guard !target.isTerminated, isTargetFrontmost(target) else {
                showAlert(
                    title: "貼上完成，但尚未送出",
                    message: "Codex 已不是前景視窗，為安全起見沒有發送 Enter。"
                )
                completion?(false)
                return
            }

            guard postKey(keyCode: 36) else {
                showAlert(
                    title: "無法送出貼上的內容",
                    message: "目前無法建立 Enter 鍵盤事件。請重新開啟 CodexUsageStatus 後再試一次。"
                )
                completion?(false)
                return
            }
            completion?(true)
        }
    }

    private static func isTargetFrontmost(_ target: NSRunningApplication) -> Bool {
        guard !target.isTerminated,
              let frontmost = NSWorkspace.shared.frontmostApplication else {
            return false
        }
        return frontmost.processIdentifier == target.processIdentifier
            && isCodexApplication(frontmost)
    }

    private static func postKey(
        keyCode: CGKeyCode,
        flags: CGEventFlags = []
    ) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return false
        }
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private static func isEventPostingAuthorized() -> Bool {
        AXIsProcessTrusted() || CGPreflightPostEventAccess()
    }

    private static func promptForAccessibilityPermissionIfNeeded() {
        let now = Date()
        // A click can arrive again while the user is still reading Settings.
        // Avoid presenting a stack of identical modal alerts.
        if let lastPermissionPromptAt,
           now.timeIntervalSince(lastPermissionPromptAt) < 12 {
            return
        }
        lastPermissionPromptAt = now

        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        _ = CGRequestPostEventAccess()

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "需要輔助功能權限"
        alert.informativeText = "要替你把剪貼簿貼到 Codex，請在「系統設定 → 隱私權與安全性 → 輔助功能」允許目前正在使用的 CodexUsageStatus.app。若清單裡已有同名舊項目，請先移除舊項目，再從目前這個 App 加入；更新或搬移 App 後，完成設定要完全退出並重新開啟一次。"
        alert.addButton(withTitle: "開啟輔助功能設定")
        alert.addButton(withTitle: "稍後")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openAccessibilitySettings()
        }
    }

    private static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private static func isCodexApplication(_ application: NSRunningApplication) -> Bool {
        let bundleID = application.bundleIdentifier?.lowercased() ?? ""
        let name = application.localizedName?.lowercased() ?? ""
        let path = application.bundleURL?.path.lowercased() ?? ""
        return bundleID == "com.openai.codex"
            || bundleID.contains("chatgpt")
            || name.contains("chatgpt")
            || path.contains("/chatgpt.app")
    }

    private static func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}
