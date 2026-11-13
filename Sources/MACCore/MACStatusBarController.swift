import AppKit
import SwiftUI

@MainActor
public final class MACStatusBarController: NSObject, NSMenuDelegate, NSWindowDelegate {
    public static let domonkFactoryURL = URL(string: "https://domonk.com")!
    public static let domonkFactoryName = "DOMONK Factory"

    public let appState: MACAppState
    public let statusItem: NSStatusItem
    public let menu: NSMenu

    public private(set) var statusHeaderItem: NSMenuItem!
    public private(set) var openAppMenuItem: NSMenuItem!
    public private(set) var startMenuItem: NSMenuItem!
    public private(set) var restartMenuItem: NSMenuItem!
    public private(set) var stopMenuItem: NSMenuItem!
    public private(set) var launchAtLoginMenuItem: NSMenuItem!
    public private(set) var aboutMenuItem: NSMenuItem!
    public private(set) var quitMenuItem: NSMenuItem!
    public private(set) var settingsWindow: NSWindow?
    public private(set) var aboutWindow: NSWindow?
    public private(set) var effectiveActivationPolicy: NSApplication.ActivationPolicy = .accessory
    public let isHeadlessTestMode: Bool

    private let passwordProvider: @MainActor (Bool) -> String?

    public init(
        appState: MACAppState,
        isHeadlessTestMode: Bool = ProcessInfo.processInfo.environment["MAC_HEADLESS_TEST"] == "1",
        passwordProvider: (@MainActor (Bool) -> String?)? = nil
    ) {
        self.appState = appState
        self.isHeadlessTestMode = isHeadlessTestMode
        self.passwordProvider = passwordProvider ?? { isRestart in
            PasswordPromptPanel.promptForSessionPassword(isRestart: isRestart)
        }
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.menu = NSMenu(title: "MAC")
        super.init()

        self.menu.autoenablesItems = false
        self.menu.delegate = self

        applyApplicationDockIcon()
        installStandardApplicationMenu()
        configureStatusBarButton()
        buildMenuItems()
        refreshUI()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        self.appState.onStateChanged = { [weak self] in
            self?.refreshUI()
        }
        self.appState.onRequestOpenSettings = { [weak self] tab in
            self?.openApp(tab: tab)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Only real `.app` bundles (`mac.app`) may promote `NSApp` to `.regular` in the macOS Dock.
    /// Bare CLI / test executables (`MACAppTests`) must never call `NSApp.setActivationPolicy(.regular)`,
    /// otherwise macOS Dock creates ghost `exec` tiles at the bottom of the screen.
    private var canPromoteToRegularDockIcon: Bool {
        !isHeadlessTestMode && Bundle.main.bundleURL.pathExtension.lowercased() == "app"
    }

    private func applyEffectiveActivationPolicy(_ policy: NSApplication.ActivationPolicy) {
        effectiveActivationPolicy = policy
        if policy == .regular {
            if canPromoteToRegularDockIcon {
                NSApp.setActivationPolicy(.regular)
            }
        } else {
            NSApp.setActivationPolicy(policy)
        }
    }

    private func applyApplicationDockIcon() {
        guard !isHeadlessTestMode else { return }
        if let appIcon = loadAppIconImage() {
            NSApp.applicationIconImage = appIcon
        }
    }

    public func loadAppIconImage() -> NSImage? {
        if let bundledURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let img = NSImage(contentsOf: bundledURL) {
            return img
        }
        let repoIconPath = appState.runtimeRootURL.appendingPathComponent("Resources/AppIcon.icns").path
        if FileManager.default.fileExists(atPath: repoIconPath),
           let img = NSImage(contentsOfFile: repoIconPath) {
            return img
        }
        return NSApp.applicationIconImage
    }

    private func configureStatusBarButton() {
        guard let button = statusItem.button else { return }
        if let iconImage = loadMenuBarIcon() {
            iconImage.isTemplate = true
            button.image = iconImage
            button.imagePosition = .imageOnly
        } else {
            button.title = "AI MAC"
        }
    }

    private func loadMenuBarIcon() -> NSImage? {
        if let bundledURL = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
           let img = NSImage(contentsOf: bundledURL) {
            return img
        }
        let repoIconPath = appState.runtimeRootURL.appendingPathComponent("Resources/MenuBarIcon.png").path
        if FileManager.default.fileExists(atPath: repoIconPath),
           let img = NSImage(contentsOfFile: repoIconPath) {
            return img
        }
        if let sf = NSImage(systemSymbolName: "iphone.gen3.radiowaves.left.and.right", accessibilityDescription: "MAC")
            ?? NSImage(systemSymbolName: "terminal.fill", accessibilityDescription: "MAC") {
            return sf
        }
        return nil
    }

    private func buildMenuItems() {
        statusHeaderItem = NSMenuItem(title: appState.status.statusMenuTitle, action: nil, keyEquivalent: "")
        statusHeaderItem.isEnabled = false
        menu.addItem(statusHeaderItem)

        menu.addItem(.separator())

        openAppMenuItem = NSMenuItem(title: "Open App", action: #selector(handleOpenAppClicked), keyEquivalent: "")
        openAppMenuItem.target = self
        menu.addItem(openAppMenuItem)

        menu.addItem(.separator())

        startMenuItem = NSMenuItem(title: "Start...", action: #selector(handleStartClicked), keyEquivalent: "")
        startMenuItem.target = self
        menu.addItem(startMenuItem)

        restartMenuItem = NSMenuItem(title: "Restart...", action: #selector(handleRestartClicked), keyEquivalent: "")
        restartMenuItem.target = self
        menu.addItem(restartMenuItem)

        stopMenuItem = NSMenuItem(title: "Stop", action: #selector(handleStopClicked), keyEquivalent: "")
        stopMenuItem.target = self
        menu.addItem(stopMenuItem)

        menu.addItem(.separator())

        launchAtLoginMenuItem = NSMenuItem(
            title: "Start Automatically at Login",
            action: #selector(handleToggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchAtLoginMenuItem.target = self
        menu.addItem(launchAtLoginMenuItem)

        aboutMenuItem = NSMenuItem(title: "About", action: #selector(handleAboutClicked), keyEquivalent: "")
        aboutMenuItem.target = self
        menu.addItem(aboutMenuItem)

        menu.addItem(.separator())

        quitMenuItem = NSMenuItem(title: "Quit AI MAC", action: #selector(handleQuitClicked), keyEquivalent: "q")
        quitMenuItem.target = self
        menu.addItem(quitMenuItem)

        statusItem.menu = menu
    }

    // MARK: - NSMenuDelegate

    public func menuNeedsUpdate(_ menu: NSMenu) {
        refreshMenuItems()
    }

    public func menuWillOpen(_ menu: NSMenu) {
        refreshMenuItems()
    }

    /// Multi-monitor confinement: ensures the dropdown menu is strictly confined to the display
    /// where the user clicked the status bar icon, preventing macOS from accidentally spawning
    /// the menu on a different display or space in multi-screen setups.
    public func confinementRect(for menu: NSMenu, on screen: NSScreen?) -> NSRect {
        let mouseLocation = NSEvent.mouseLocation
        if let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) {
            return targetScreen.visibleFrame
        }
        if let screen = screen {
            return screen.visibleFrame
        }
        if let buttonScreen = statusItem.button?.window?.screen {
            return buttonScreen.visibleFrame
        }
        return .zero
    }

    @objc private func handleScreenParametersChanged() {
        refreshUI()
    }

    /// Updates only the menu item labels and enable/disable states.
    /// Does not mutate `statusItem.button` to avoid invalidating WindowServer clone coordinates.
    public func refreshMenuItems() {
        statusHeaderItem.title = appState.status.statusMenuTitle

        let active = appState.status.isRunningOrStarting
        startMenuItem.isEnabled = !active
        restartMenuItem.isEnabled = active
        stopMenuItem.isEnabled = active

        launchAtLoginMenuItem.state = appState.launchAtLogin ? .on : .off
    }

    /// Updates the status bar button icon, title, and tooltip.
    public func refreshStatusButton() {
        guard let button = statusItem.button else { return }
        if button.image != nil {
            button.title = ""
            button.imagePosition = .imageOnly
        } else {
            button.title = "MAC"
        }
        switch appState.status {
        case .running(let username):
            if let u = username, !u.isEmpty {
                button.toolTip = "AI MAC — Running (@\(u)) · Mac Sleep Prevented"
            } else {
                button.toolTip = "AI MAC — Running · Mac Sleep Prevented"
            }
        case .starting:
            button.toolTip = "AI MAC — Starting..."
        case .error(let msg):
            button.toolTip = "AI MAC — Error: \(msg)"
        case .stopped:
            button.toolTip = "AI MAC — Mobile Agent Control (Stopped)"
        }
    }

    public func refreshUI() {
        refreshMenuItems()
        refreshStatusButton()
    }

    @objc public func handleOpenAppClicked() {
        openApp(tab: nil)
    }

    @objc public func handleStartClicked() {
        guard let password = passwordProvider(false) else { return }
        appState.startBot(sessionPassword: password)
    }

    @objc public func handleRestartClicked() {
        guard let password = passwordProvider(true) else { return }
        appState.restartBot(sessionPassword: password)
    }

    @objc public func handleStopClicked() {
        appState.stopBot()
    }

    @objc public func handleToggleLaunchAtLogin() {
        appState.toggleLaunchAtLogin(!appState.launchAtLogin)
    }

    @objc public func handleAboutClicked() {
        openAbout()
    }

    @objc public func handleQuitClicked() {
        appState.stopBot(silent: true)
        NSApp.terminate(nil)
    }

    public func openSettings(tab: MACSettingsTab? = nil) {
        openApp(tab: tab)
    }

    public func openApp(tab: MACSettingsTab? = nil) {
        if settingsWindow?.isVisible != true {
            appState.reloadConfigFromDisk()
        }
        if let tab = tab {
            appState.selectedTab = tab
        }

        // Show MAC in the bottom macOS Dock while the main app window is open
        applyApplicationDockIcon()
        applyEffectiveActivationPolicy(.regular)
        if !isHeadlessTestMode {
            installStandardApplicationMenu()
        }

        if settingsWindow == nil {
            let rootView = MACSettingsRootView(
                appState: appState,
                onStartRequested: { [weak self] in self?.handleStartClicked() },
                onRestartRequested: { [weak self] in self?.handleRestartClicked() },
                onStopRequested: { [weak self] in self?.handleStopClicked() }
            )
            let hostingController = NSHostingController(rootView: rootView)
            let window = NSWindow(contentViewController: hostingController)
            window.title = "AI MAC — Mobile Agent Control"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 980, height: 700))
            window.minSize = NSSize(width: 800, height: 640)
            // Standard application window level (.normal) so it behaves as a regular app
            // and goes under other apps when they are focused
            window.level = .normal
            window.hidesOnDeactivate = false
            window.collectionBehavior = [.moveToActiveSpace]
            window.isReleasedWhenClosed = false
            window.delegate = self
            if isHeadlessTestMode {
                window.setFrameOrigin(NSPoint(x: -12000, y: -12000))
            } else {
                window.center()
            }
            self.settingsWindow = window
        }

        settingsWindow?.level = .normal
        settingsWindow?.hidesOnDeactivate = false
        if isHeadlessTestMode {
            settingsWindow?.orderBack(nil)
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Closes the main app window when 'x' (or Cmd+W) is clicked while keeping MAC running
    /// in the top menu bar next to the clock with NO icon in the bottom Dock.
    public func closeAppWindowToMenuBar() {
        settingsWindow?.orderOut(nil)
        applyEffectiveActivationPolicy(.accessory)
    }

    public func openAbout() {
        if aboutWindow == nil {
            let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "3.2.4"
            let aboutView = MACAboutView(
                appIcon: loadAppIconImage(),
                version: version,
                onOpenWebsite: {
                    NSWorkspace.shared.open(Self.domonkFactoryURL)
                }
            )
            let hosting = NSHostingController(rootView: aboutView)
            let win = NSWindow(contentViewController: hosting)
            win.title = "About MAC — \(Self.domonkFactoryName)"
            win.styleMask = [.titled, .closable]
            win.setContentSize(NSSize(width: 400, height: 300))
            win.level = .modalPanel
            win.hidesOnDeactivate = false
            win.isReleasedWhenClosed = false
            win.delegate = self
            if isHeadlessTestMode {
                win.setFrameOrigin(NSPoint(x: -12000, y: -12000))
            } else {
                win.center()
            }
            self.aboutWindow = win
        } else if !isHeadlessTestMode {
            aboutWindow?.center()
        }

        if isHeadlessTestMode {
            aboutWindow?.orderBack(nil)
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        aboutWindow?.orderFrontRegardless()
        aboutWindow?.makeKeyAndOrderFront(nil)
    }

    public func removeStatusItem() {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    // MARK: - NSWindowDelegate

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === settingsWindow {
            closeAppWindowToMenuBar()
            return false
        }
        if sender === aboutWindow {
            aboutWindow?.orderOut(nil)
            return false
        }
        return true
    }

    public func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === settingsWindow {
            applyEffectiveActivationPolicy(.accessory)
        }
    }

    private func installStandardApplicationMenu() {
        let mainMenu = NSMenu()

        // 1. App Menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: "MAC")
        let aboutItem = NSMenuItem(title: "About MAC", action: #selector(handleAboutClicked), keyEquivalent: "")
        aboutItem.target = self
        appMenu.addItem(aboutItem)
        appMenu.addItem(.separator())
        let openItem = NSMenuItem(title: "Open App", action: #selector(handleOpenAppClicked), keyEquivalent: ",")
        openItem.target = self
        appMenu.addItem(openItem)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        appMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit AI MAC", action: #selector(handleQuitClicked), keyEquivalent: "q")
        quitItem.target = self
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu

        // 2. Edit Menu (essential so Cmd+C / Cmd+V / Cmd+A / Cmd+Z work in text fields)
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }
}

private struct MACAboutView: View {
    let appIcon: NSImage?
    let version: String
    let onOpenWebsite: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            if let appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 72, height: 72)
                    .cornerRadius(16)
            } else {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(.system(size: 46, weight: .bold))
                    .foregroundColor(.accentColor)
            }

            VStack(spacing: 4) {
                Text("AI MAC — Mobile Agent Control")
                    .font(.system(size: 16, weight: .bold))
                Text("Version \(version)")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                Text("Control local AI coding Workspaces, Git & Jenkins CI/CD via Telegram")
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            Divider()

            VStack(spacing: 8) {
                Text("DOMONK Factory")
                    .font(.system(size: 14, weight: .bold))

                Button {
                    onOpenWebsite()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "globe")
                        Text(verbatim: "https://domonk.com")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .font(.system(size: 12.5, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .fixedSize()
            }
        }
        .padding(22)
        .frame(width: 400, height: 300)
    }
}
