import SwiftUI

@main
struct CodexUsageStatusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            // SwiftUI requires a Settings scene for the app-settings command
            // infrastructure. The command is replaced below, and this proxy
            // immediately routes any legacy Settings invocation to the
            // status-item popover before closing its own window. No product
            // controls live here.
            SettingsCommandProxyView {
                appDelegate.showProductSettings()
            }
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("設定…") {
                    appDelegate.showProductSettings()
                }
                .keyboardShortcut(",", modifiers: [.command])
            }
        }
    }
}

private struct SettingsCommandProxyView: View {
    let route: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .opacity(0)
            .onAppear {
                let proxyWindow = NSApp.keyWindow
                route()
                // Close only the proxy Settings window on the next run-loop
                // turn. The product settings surface is the popover opened by
                // `route`, never this scene.
                DispatchQueue.main.async {
                    proxyWindow?.close()
                }
            }
    }
}
