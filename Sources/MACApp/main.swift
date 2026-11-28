import AppKit

@MainActor
final class MACAppDelegate: NSObject, NSApplicationDelegate {
    private var appState: MACAppState!
    private var statusBarController: MACStatusBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        ProcessInfo.processInfo.disableAutomaticTermination("AI MAC Menu Bar Controller")
        ProcessInfo.processInfo.disableSuddenTermination()

        appState = MACAppState()
        statusBarController = MACStatusBarController(appState: appState)

        // If Telegram Bot Token hasn't been configured yet on first run, open General tab;
        // otherwise automatically resume the bot if it was active prior to app restart.
        if appState.config.telegramBotToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            statusBarController.openApp(tab: .general)
        } else {
            _ = appState.autoStartIfPreviouslyRunning()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusBarController?.openApp(tab: nil)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState?.stopBotForAppTermination()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = MainActor.assumeIsolated { MACAppDelegate() }
app.delegate = delegate
app.run()
