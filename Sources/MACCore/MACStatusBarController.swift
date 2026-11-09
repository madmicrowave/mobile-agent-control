import AppKit
import SwiftUI

@MainActor
public final class MACStatusBarController: NSObject, NSMenuDelegate, NSWindowDelegate {
    public let appState: MACAppState
    public let statusItem: NSStatusItem
    public let menu: NSMenu

    public private(set) var statusHeaderItem: NSMenuItem!
    public private(set) var startMenuItem: NSMenuItem!
    public private(set) var restartMenuItem: NSMenuItem!
    public private(set) var stopMenuItem: NSMenuItem!
    public private(set) var settingsMenuItem: NSMenuItem!
    public private(set) var tutorialMenuItem: NSMenuItem!
    public private(set) var launchAtLoginMenuItem: NSMenuItem!
    public private(set) var quitMenuItem: NSMenuItem!

    private var settingsWindow: NSWindow?
    private let passwordProvider: @MainActor (Bool) -> String?

    public init(
        appState: MACAppState,
        passwordProvider: (@MainActor (Bool) -> String?)? = nil
    ) {
        self.appState = appState
        self.passwordProvider = passwordProvider ?? { isRestart in
            PasswordPromptPanel.promptForSessionPassword(isRestart: isRestart)
        }
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.menu = NSMenu(title: "MAC")
        super.init()

        self.menu.autoenablesItems = false
        self.menu.delegate = self

        installStandardApplicationMenu()
        configureStatusBarButton()
        buildMenuItems()
        refreshUI()

        self.appState.onStateChanged = { [weak self] in
            self?.refreshUI()
        }
        self.appState.onRequestOpenSettings = { [weak self] tab in
            self?.openSettings(tab: tab)
        }
    }

    private func configureStatusBarButton() {
        guard let button = statusItem.button else { return }
        if let iconImage = loadMenuBarIcon() {
            iconImage.isTemplate = true
            button.image = iconImage
            button.imagePosition = .imageOnly
        } else {
            button.title = "MAC"
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

        settingsMenuItem = NSMenuItem(title: "Settings...", action: #selector(handleSettingsClicked), keyEquivalent: ",")
        settingsMenuItem.target = self
        menu.addItem(settingsMenuItem)

        tutorialMenuItem = NSMenuItem(title: "Tutorial...", action: #selector(handleTutorialClicked), keyEquivalent: "")
        tutorialMenuItem.target = self
        menu.addItem(tutorialMenuItem)

        launchAtLoginMenuItem = NSMenuItem(
            title: "Start Automatically at Login",
            action: #selector(handleToggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchAtLoginMenuItem.target = self
        menu.addItem(launchAtLoginMenuItem)

        menu.addItem(.separator())

        quitMenuItem = NSMenuItem(title: "Quit MAC", action: #selector(handleQuitClicked), keyEquivalent: "q")
        quitMenuItem.target = self
        menu.addItem(quitMenuItem)

        statusItem.menu = menu
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        refreshUI()
    }

    public func refreshUI() {
        statusHeaderItem.title = appState.status.statusMenuTitle

        let active = appState.status.isRunningOrStarting
        startMenuItem.isEnabled = !active
        restartMenuItem.isEnabled = active
        stopMenuItem.isEnabled = active

        launchAtLoginMenuItem.state = appState.launchAtLogin ? .on : .off

        if let button = statusItem.button {
            if button.image != nil {
                button.title = ""
                button.imagePosition = .imageOnly
            } else {
                button.title = "MAC"
            }
            switch appState.status {
            case .running(let username):
                if let u = username, !u.isEmpty {
                    button.toolTip = "MAC — Running (@\(u)) · Mac Sleep Prevented"
                } else {
                    button.toolTip = "MAC — Running · Mac Sleep Prevented"
                }
            case .starting:
                button.toolTip = "MAC — Starting..."
            case .error(let msg):
                button.toolTip = "MAC — Error: \(msg)"
            case .stopped:
                button.toolTip = "MAC — Mobile Agent Control (Stopped)"
            }
        }
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

    @objc public func handleSettingsClicked() {
        openSettings(tab: nil)
    }

    @objc public func handleTutorialClicked() {
        openSettings(tab: .tutorial)
    }

    @objc public func handleToggleLaunchAtLogin() {
        appState.toggleLaunchAtLogin(!appState.launchAtLogin)
    }

    @objc public func handleQuitClicked() {
        appState.stopBot(silent: true)
        NSApp.terminate(nil)
    }

    public func openSettings(tab: MACSettingsTab? = nil) {
        if settingsWindow?.isVisible != true {
            appState.reloadConfigFromDisk()
        }
        if let tab = tab {
            appState.selectedTab = tab
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
            window.title = "MAC — Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 960, height: 680))
            window.minSize = NSSize(width: 900, height: 620)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.settingsWindow = window
        }

        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func installStandardApplicationMenu() {
        let mainMenu = NSMenu()

        // 1. App Menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: "MAC")
        let prefsItem = NSMenuItem(title: "Settings...", action: #selector(handleSettingsClicked), keyEquivalent: ",")
        prefsItem.target = self
        appMenu.addItem(prefsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        appMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit MAC", action: #selector(handleQuitClicked), keyEquivalent: "q")
        quitItem.target = self
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu

        // 2. Edit Menu (essential so Cmd+C / Cmd+V / Cmd+A / Cmd+Z work in menu bar apps)
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
