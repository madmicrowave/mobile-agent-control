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

        // Ensure Cmd+V, Cmd+C, Cmd+A work reliably across all text fields
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "v" {
                if NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) {
                    return nil
                }
            }
            return event
        }

        // Unfocus any focused text input when clicking outside of inputs
        MACOutsideClickUnfocusMonitor.installIfNeeded()

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
        refreshStatusButton()
    }

    /// Generates a status bar icon.
    /// When started (running), renders a vibrant green dot directly in front of the "AI MAC" pill badge.
    /// When starting, renders a yellow dot in front of the badge.
    /// When error, renders a red dot in front of the badge.
    /// When stopped, renders the clean template badge with no dot.
    public func statusBarIconImage(for status: MACBotRunStatus) -> NSImage? {
        let dotColor: NSColor?
        switch status {
        case .running:
            dotColor = NSColor(calibratedRed: 0.20, green: 0.82, blue: 0.38, alpha: 1.0)
        case .starting:
            dotColor = NSColor(calibratedRed: 1.00, green: 0.80, blue: 0.00, alpha: 1.0)
        case .error:
            dotColor = NSColor(calibratedRed: 1.00, green: 0.27, blue: 0.23, alpha: 1.0)
        case .stopped:
            dotColor = nil
        }

        let dotDiameter: CGFloat = 6.0
        let spacing: CGFloat = 5.0
        let pillWidth: CGFloat = 42.0
        let pillHeight: CGFloat = 16.0
        let hasDot = (dotColor != nil)
        let totalWidth: CGFloat = hasDot ? (dotDiameter + spacing + pillWidth) : pillWidth

        let img = NSImage(size: NSSize(width: totalWidth, height: pillHeight), flipped: false) { rect in
            let pillX: CGFloat
            if let dot = dotColor {
                let dotY = (pillHeight - dotDiameter) / 2.0
                let dotRect = NSRect(x: 0.5, y: dotY, width: dotDiameter, height: dotDiameter)
                let dotPath = NSBezierPath(ovalIn: dotRect)
                dot.setFill()
                dotPath.fill()
                pillX = dotDiameter + spacing
            } else {
                pillX = 0.0
            }

            let isDark: Bool
            if hasDot {
                if let match = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) {
                    isDark = (match == .darkAqua)
                } else {
                    isDark = (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
                }
            } else {
                isDark = false
            }

            let pillRect = NSRect(x: pillX + 0.75, y: 1.0, width: pillWidth - 1.5, height: pillHeight - 2.0)
            let pillPath = NSBezierPath(roundedRect: pillRect, xRadius: 4.2, yRadius: 4.2)

            let pillBgColor = (hasDot && isDark) ? NSColor(white: 0.90, alpha: 1.0) : (hasDot ? NSColor(white: 0.12, alpha: 1.0) : NSColor.black)
            let textColor = (hasDot && isDark) ? NSColor(white: 0.10, alpha: 1.0) : (hasDot ? NSColor.white : NSColor.clear)

            pillBgColor.setFill()
            pillPath.fill()

            let aiFont = NSFont.systemFont(ofSize: 5.8, weight: .black)
            let macFont = NSFont.systemFont(ofSize: 9.0, weight: .black)
            let aiVerticalOffset = (macFont.capHeight - aiFont.capHeight) / 2.0

            let aiAttrs: [NSAttributedString.Key: Any] = [
                .font: aiFont,
                .foregroundColor: textColor,
                .baselineOffset: aiVerticalOffset,
                .kern: 0.1
            ]
            let macAttrs: [NSAttributedString.Key: Any] = [
                .font: macFont,
                .foregroundColor: textColor,
                .kern: -0.3
            ]

            let attrStr = NSMutableAttributedString(string: "AI ", attributes: aiAttrs)
            attrStr.append(NSAttributedString(string: "MAC", attributes: macAttrs))
            let textSize = attrStr.size()

            let textRect = NSRect(
                x: pillX + (pillWidth - textSize.width) / 2.0,
                y: (pillHeight - textSize.height) / 2.0 + 0.2,
                width: textSize.width,
                height: textSize.height
            )

            if !hasDot {
                NSGraphicsContext.current?.compositingOperation = .clear
            }
            attrStr.draw(in: textRect)

            return true
        }

        img.isTemplate = !hasDot
        return img
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
            title: "Launch at Startup",
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

    /// Multi-monitor target screen discovery: uses `NSMouseInRect` with edge-tolerance expansion
    /// to accurately resolve which display the user clicked next to the clock/menu bar.
    public func targetScreenForMenu(at mouseLocation: NSPoint = NSEvent.mouseLocation) -> NSScreen? {
        if let directMatch = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) {
            return directMatch
        }
        if let nearMatch = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame.insetBy(dx: -4, dy: -4), false) }) {
            return nearMatch
        }
        if let buttonScreen = statusItem.button?.window?.screen {
            return buttonScreen
        }
        return NSScreen.main
    }

    /// Multi-monitor confinement: ensures the dropdown menu is strictly confined to the display
    /// where the user clicked the status bar icon, preventing macOS from accidentally spawning
    /// the menu on a different display or space in multi-screen setups.
    public func confinementRect(for menu: NSMenu, on screen: NSScreen?) -> NSRect {
        if let targetScreen = targetScreenForMenu() {
            return targetScreen.visibleFrame
        }
        if let screen = screen {
            return screen.visibleFrame
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
        if let icon = statusBarIconImage(for: appState.status) {
            button.image = icon
            button.imagePosition = .imageOnly
            button.title = ""
        } else {
            button.image = nil
            button.title = "AI MAC"
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
        appState.stopBotForAppTermination()
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

    @objc private func handleExportConfigClicked() {
        MACConfigExportImportManager.exportConfig(appState: appState)
    }

    @objc private func handleImportConfigClicked() {
        MACConfigExportImportManager.importConfig(appState: appState)
    }

    private func installStandardApplicationMenu() {
        let mainMenu = NSMenu()

        // 1. App Menu (AI MAC)
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: "AI MAC")

        let attrTitle = NSMutableAttributedString(
            string: "AI ",
            attributes: [
                .foregroundColor: NSColor.systemBlue,
                .font: NSFont.boldSystemFont(ofSize: 11)
            ]
        )
        attrTitle.append(NSAttributedString(
            string: "MAC",
            attributes: [
                .foregroundColor: NSColor.labelColor,
                .font: NSFont.boldSystemFont(ofSize: 13.5)
            ]
        ))
        appMenuItem.attributedTitle = attrTitle
        appMenuItem.title = "AI MAC"

        let aboutItem = NSMenuItem(title: "About AI MAC", action: #selector(handleAboutClicked), keyEquivalent: "")
        aboutItem.target = self
        appMenu.addItem(aboutItem)
        appMenu.addItem(.separator())

        let exportItem = NSMenuItem(title: "Export...", action: #selector(handleExportConfigClicked), keyEquivalent: "e")
        exportItem.target = self
        appMenu.addItem(exportItem)

        let importItem = NSMenuItem(title: "Import...", action: #selector(handleImportConfigClicked), keyEquivalent: "i")
        importItem.target = self
        appMenu.addItem(importItem)

        appMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit AI MAC", action: #selector(handleQuitClicked), keyEquivalent: "q")
        quitItem.target = self
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu

        // 2. Hidden standard Edit menu for system-wide shortcuts (Cmd+C, Cmd+V, Cmd+X, Cmd+A, Cmd+Z)
        // Kept hidden so "Edit" does not appear in the top menu bar, but AppKit routes paste/copy/cut/select-all.
        let editMenuItem = NSMenuItem()
        editMenuItem.title = "Edit"
        editMenuItem.isHidden = true
        let editMenu = NSMenu(title: "Edit")

        let undoItem = NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        let cutItem = NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        let copyItem = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        let pasteItem = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let selectAllItem = NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        editMenu.addItem(undoItem)
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        editMenu.addItem(cutItem)
        editMenu.addItem(copyItem)
        editMenu.addItem(pasteItem)
        editMenu.addItem(selectAllItem)

        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

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
