import AppKit

@MainActor
final class MACAppDelegate: NSObject, NSApplicationDelegate {
    private var appState: MACAppState!
    private var statusBarController: MACStatusBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        appState = MACAppState()
        statusBarController = MACStatusBarController(appState: appState)

        // If Telegram Bot Token hasn't been configured yet on first run, open General tab
        if appState.config.telegramBotToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            statusBarController.openApp(tab: .general)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusBarController?.openApp(tab: nil)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState?.stopBot(silent: true)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = MainActor.assumeIsolated { MACAppDelegate() }
app.delegate = delegate
app.run()
