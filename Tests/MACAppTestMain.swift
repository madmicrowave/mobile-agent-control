import AppKit
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String, file: StaticString = #file, line: UInt = #line) {
    if !condition() {
        fputs("❌ Test failure (\(file):\(line)): \(message)\n", stderr)
        exit(1)
    }
}

private func testJobParsingAndRepoDiscovery() throws {
    let parsed = MACPathUtils.parseJobList(
        "'HS-1/crypto-fusion/merchant', 'HS-1/crypto-fusion/client',\n\"https://jenkins.example.com/job/PROD/job/crypto-fusion/job/core/\""
    )
    expect(parsed == [
        "HS-1/crypto-fusion/merchant",
        "HS-1/crypto-fusion/client",
        "PROD/crypto-fusion/core"
    ], "Expected parseJobList to strip quotes and normalize Jenkins URLs, got: \(parsed)")

    let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("mac-ws-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let merchantRepo = tempRoot.appendingPathComponent("dashboard-merchant", isDirectory: true)
    let clientRepo = tempRoot.appendingPathComponent("client", isDirectory: true)
    try FileManager.default.createDirectory(at: merchantRepo.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: clientRepo.appendingPathComponent(".git"), withIntermediateDirectories: true)

    let repos = MACPathUtils.discoverGitRepos(
        at: tempRoot.path,
        stagingJobs: ["HS-1/crypto-fusion/merchant", "HS-1/crypto-fusion/client"],
        prodJobs: ["PROD/crypto-fusion/merchant", "PROD/crypto-fusion/client"]
    )
    expect(repos.count == 2, "Expected 2 discovered Git repos, got \(repos.count)")
    let client = repos.first(where: { $0.name == "client" })
    let merchant = repos.first(where: { $0.name == "dashboard-merchant" })
    expect(client?.jenkinsJob == "HS-1/crypto-fusion/client", "Expected client staging job match")
    expect(client?.prodJenkinsJob == "PROD/crypto-fusion/client", "Expected client prod job match")
    expect(merchant?.jenkinsJob == "HS-1/crypto-fusion/merchant", "Expected dashboard-merchant staging job match")
    print("✓ Job list parsing & Git repository auto-discovery passed")
}

private func testConfigStoreRoundTrip() throws {
    let tempDataDir = FileManager.default.temporaryDirectory.appendingPathComponent("mac-cfg-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDataDir) }

    let store = MACConfigFileStore(dataDir: tempDataDir)
    var cfg = MACConfig(
        agyBin: "/Users/test/.local/bin/agy",
        defaultModel: "gemini-3.8-flash-high",
        defaultModelLevel: "high",
        jenkins: MACJenkinsConfig(baseUrl: "https://jenkins.local", username: "tech", apiToken: "secret-tok"),
        workspaces: [
            MACWorkspace(
                id: "payment-book",
                label: "PAYMENT BOOK",
                path: "/Users/test/code/payment_book",
                extraDirs: ["/Users/test/code/shared"],
                liveUrl: "https://staging.payment-book.com",
                model: "gemini-3.8-flash-medium",
                modelLevel: "medium",
                environmentMode: "multi",
                jenkinsJobs: ["HS-1/pb/gate"],
                prodJenkinsJobs: ["PROD/pb/gate"],
                repos: [
                    MACRepo(name: "gate", path: "/Users/test/code/payment_book/gate", jenkinsJob: "HS-1/pb/gate", prodJenkinsJob: "PROD/pb/gate", deployEnabled: true)
                ]
            )
        ],
        telegramBotToken: "123456:TEST_TOKEN",
        allowedUserIds: ["652545688"],
        defaultHistoryCount: 20
    )
    try store.save(cfg)

    let perms = (try FileManager.default.attributesOfItem(atPath: store.configFileURL.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
    expect((perms & 0o777) == 0o600, "Expected 0600 permissions on config.json, got \(String(perms, radix: 8))")

    let reloaded = store.load()
    expect(reloaded.telegramBotToken == "123456:TEST_TOKEN", "Bot token round-trip")
    expect(reloaded.jenkins.baseUrl == "https://jenkins.local", "Jenkins URL round-trip")
    expect(reloaded.workspaces.count == 1, "Workspace count round-trip")
    expect(reloaded.workspaces[0].environmentMode == "multi", "Multi environment mode preserved")
    expect(reloaded.workspaces[0].prodJenkinsJobs == ["PROD/pb/gate"], "Prod Jenkins jobs preserved")
    expect(reloaded.workspaces[0].extraDirs == ["/Users/test/code/shared"], "Extra paths preserved")

    // Switching to single mode clears prodJenkinsJobs on encode
    cfg.workspaces[0].environmentMode = "single"
    try store.save(cfg)
    let singleReloaded = store.load()
    expect(singleReloaded.workspaces[0].prodJenkinsJobs.isEmpty, "Single mode clears prodJenkinsJobs")
    expect(
        MACPathUtils.defaultBrainDir().hasSuffix(".gemini/antigravity-cli/brain"),
        "Expected defaultBrainDir to point to .gemini/antigravity-cli/brain, got \(MACPathUtils.defaultBrainDir())"
    )
    expect(
        singleReloaded.antigravityBrainDir == MACPathUtils.defaultBrainDir(),
        "Expected saved config to use CLI brain dir"
    )

    // Legacy Desktop IDE brain dir (.gemini/antigravity/brain) auto-migrates to CLI brain dir on load
    var legacyJsonCfg = singleReloaded
    legacyJsonCfg.antigravityBrainDir = MACPathUtils.legacyDesktopBrainDir()
    try store.save(legacyJsonCfg)
    let migratedReloaded = store.load()
    expect(
        migratedReloaded.antigravityBrainDir == MACPathUtils.defaultBrainDir(),
        "Expected legacy Desktop IDE brain dir to auto-migrate to .gemini/antigravity-cli/brain, got \(migratedReloaded.antigravityBrainDir)"
    )
    print("✓ MACConfigFileStore atomic 0600 save/load round-trip & CLI brain dir migration passed")
}

private func testSleepPreventerAndLaunchAgent() throws {
    let preventer = SleepPreventer()
    expect(!preventer.isPreventingSleep, "Initially not preventing sleep")
    let acquired = preventer.acquire(reason: "MAC Unit Test Awake Check")
    expect(acquired && preventer.isPreventingSleep, "Expected SleepPreventer.acquire() to prevent Mac sleep")
    preventer.release()
    // Give caffeinate child a moment to exit after terminate()
    Thread.sleep(forTimeInterval: 0.1)
    expect(!preventer.isPreventingSleep, "Expected SleepPreventer.release() to allow Mac sleep again")

    let tempLaunchDir = FileManager.default.temporaryDirectory.appendingPathComponent("mac-la-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempLaunchDir) }

    let manager = LaunchAtLoginManager(
        launchAgentsDirectory: tempLaunchDir,
        executablePathProvider: { "/Applications/MAC.app/Contents/MacOS/MAC" }
    )
    expect(!manager.isEnabled, "Launch agent initially absent")
    try manager.setEnabled(true)
    expect(manager.isEnabled, "Launch agent enabled")
    let plistData = try Data(contentsOf: manager.plistURL)
    let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
    expect(plist?["Label"] as? String == "com.domonk.mac", "LaunchAgent Label check")
    expect(plist?["RunAtLoad"] as? Bool == true, "LaunchAgent RunAtLoad check")
    try manager.setEnabled(false)
    expect(!manager.isEnabled, "Launch agent removed when disabled")
    print("✓ SleepPreventer & LaunchAtLoginManager passed")
}

@MainActor
private func testMenuBarControllerAndBotLifecycle() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("mac-app-test-\(UUID().uuidString)", isDirectory: true)
    let runtimeDir = tempDir.appendingPathComponent("runtime", isDirectory: true)
    let srcDir = runtimeDir.appendingPathComponent("src", isDirectory: true)
    let dataDir = tempDir.appendingPathComponent("data", isDirectory: true)
    let launchDir = tempDir.appendingPathComponent("LaunchAgents", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

    // Write a lightweight mock bot.mjs that reads the session password from stdin,
    // emits the startup banner with @mac_unit_bot, and stays alive until SIGTERM.
    let mockBotScript = """
    import readline from 'node:readline';
    const rl = readline.createInterface({ input: process.stdin });
    rl.once('line', (pw) => {
      if (!pw || !pw.trim()) process.exit(2);
      console.log('  Telegram Bot    : @mac_unit_bot (https://t.me/mac_unit_bot)');
      console.log('  Long-polling active. Open your bot in Telegram and send /start');
      setInterval(() => {}, 1000);
    });
    process.on('SIGTERM', () => process.exit(0));
    """
    try mockBotScript.write(to: srcDir.appendingPathComponent("bot.mjs"), atomically: true, encoding: .utf8)

    let store = MACConfigFileStore(dataDir: dataDir)
    try store.save(MACConfig(telegramBotToken: "999999:MOCK_TOKEN"))

    let launchMgr = LaunchAtLoginManager(
        launchAgentsDirectory: launchDir,
        executablePathProvider: { "/Applications/MAC.app/Contents/MacOS/MAC" }
    )
    let appState = MACAppState(
        dataDir: dataDir,
        runtimeRootURL: runtimeDir,
        sleepPreventer: SleepPreventer(),
        launchAtLoginManager: launchMgr
    )

    var promptedPasswords: [(Bool, String)] = []
    let controller = MACStatusBarController(
        appState: appState,
        isHeadlessTestMode: true,
        passwordProvider: { isRestart in
            let pw = isRestart ? "restart-pass-456" : "start-pass-123"
            promptedPasswords.append((isRestart, pw))
            return pw
        }
    )
    defer {
        controller.removeStatusItem()
    }

    expect(MACSettingsTab.allCases.map(\.rawValue) == [
        "General",
        "Workspaces",
        "Tutorial",
        "Live Bot Activity"
    ], "Expected 4 tabs in exact order: General, Workspaces, Tutorial, Live Bot Activity")
    expect(appState.selectedTab == .general, "Expected General as default first tab")
    expect(controller.openAppMenuItem.title == "Open App", "Menu has Open App")
    expect(controller.startMenuItem.title == "Start...", "Menu has Start...")
    expect(controller.restartMenuItem.title == "Restart...", "Menu has Restart...")
    expect(controller.stopMenuItem.title == "Stop", "Menu has Stop")
    expect(controller.aboutMenuItem.title == "About", "Menu has About")
    expect(controller.startMenuItem.isEnabled && !controller.stopMenuItem.isEnabled, "Initial menu enabled state")
    expect(controller.effectiveActivationPolicy == .accessory, "Expected initial effectiveActivationPolicy == .accessory (no Dock icon)")
    expect(NSApp.activationPolicy() == .accessory, "Expected test runner NSApp.activationPolicy() == .accessory")

    // Verify Open App tracks .regular for mac.app while NEVER promoting the bare MACAppTests binary into the macOS Dock!
    controller.handleOpenAppClicked()
    expect(controller.settingsWindow != nil, "Main app window created")
    expect(controller.settingsWindow?.isVisible == true, "Main app window visible")
    expect(controller.effectiveActivationPolicy == .regular, "Expected effectiveActivationPolicy == .regular when Open App is active")
    expect(NSApp.activationPolicy() == .accessory, "Bare MACAppTests binary must NEVER appear in the macOS Dock")
    expect(controller.settingsWindow?.level == .normal, "Expected window level == .normal so it behaves as a regular application and goes under when other apps are focused")
    expect(controller.settingsWindow?.hidesOnDeactivate == false, "Expected window hidesOnDeactivate == false")

    if let win = controller.settingsWindow {
        let shouldClose = controller.windowShouldClose(win)
        expect(shouldClose == false, "windowShouldClose intercepts close to keep menu bar alive")
    }
    expect(controller.settingsWindow?.isVisible == false, "Main app window hidden after clicking 'x'")
    expect(controller.effectiveActivationPolicy == .accessory, "Expected effectiveActivationPolicy == .accessory (no Dock icon) after clicking 'x'")
    expect(controller.statusItem.isVisible, "Expected menu bar icon next to clock to remain visible after clicking 'x'")

    // Verify About opens DOMONK Factory window with https://domonk.com link
    controller.handleAboutClicked()
    expect(controller.aboutWindow != nil && controller.aboutWindow?.isVisible == true, "Expected About window to open")
    expect(controller.aboutWindow?.title.contains("DOMONK Factory") == true, "Expected About window title to include DOMONK Factory")
    expect(MACStatusBarController.domonkFactoryURL.absoluteString == "https://domonk.com", "Expected DOMONK Factory link https://domonk.com")
    if let aboutWin = controller.aboutWindow {
        _ = controller.windowShouldClose(aboutWin)
    }

    // Trigger Start...
    controller.handleStartClicked()
    let startDeadline = Date().addingTimeInterval(4.0)
    while Date() < startDeadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        if case .running(let username) = appState.status, username == "mac_unit_bot" {
            break
        }
    }

    expect(appState.status == .running(botUsername: "mac_unit_bot"), "Expected bot to reach .running(@mac_unit_bot), got \(appState.status)")
    expect(appState.isSleepPrevented, "Expected Mac sleep prevention active while running")
    expect(!controller.startMenuItem.isEnabled && controller.restartMenuItem.isEnabled && controller.stopMenuItem.isEnabled, "Running menu item states")
    expect(promptedPasswords.count == 1 && promptedPasswords[0].0 == false, "Start prompted for password")

    // Verify opening and closing ('x') the app window while running keeps the bot turned on in menu bar with no Dock icon
    controller.openApp(tab: .liveActivity)
    expect(controller.effectiveActivationPolicy == .regular, "Dock icon policy active while window open")
    expect(NSApp.activationPolicy() == .accessory, "Bare MACAppTests binary stays hidden from macOS Dock")
    controller.closeAppWindowToMenuBar()
    expect(controller.effectiveActivationPolicy == .accessory, "Dock icon policy removed when window closed")
    expect(appState.status == .running(botUsername: "mac_unit_bot"), "Bot stays turned on in menu bar after window close")
    expect(appState.isSleepPrevented, "Sleep prevention stays active after window close")

    // Trigger Restart...
    controller.handleRestartClicked()
    let restartDeadline = Date().addingTimeInterval(4.0)
    while Date() < restartDeadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        if case .running(let username) = appState.status, username == "mac_unit_bot" {
            break
        }
    }
    expect(appState.status == .running(botUsername: "mac_unit_bot"), "Expected bot running after Restart...")
    expect(promptedPasswords.count == 2 && promptedPasswords[1].0 == true, "Restart prompted for new password")

    // Trigger Stop
    controller.handleStopClicked()
    expect(appState.status == .stopped, "Expected status == .stopped after Stop")
    expect(!appState.isSleepPrevented, "Expected sleep prevention released after Stop")
    expect(controller.startMenuItem.isEnabled && !controller.stopMenuItem.isEnabled, "Stopped menu item states")
    print("✓ MACStatusBarController Start / Restart / Stop + Password Prompt + Sleep Prevention passed")
}

@main
struct MACAppTests {
    static func main() {
        setenv("MAC_DISABLE_AUTO_LAUNCH_AGENT", "1", 1)
        setenv("MAC_HEADLESS_TEST", "1", 1)
        let _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.accessory)

        do {
            try testJobParsingAndRepoDiscovery()
            try testConfigStoreRoundTrip()
            try testSleepPreventerAndLaunchAgent()
            try MainActor.assumeIsolated {
                try testMenuBarControllerAndBotLifecycle()
            }
            print("✅ All MAC macOS native app tests passed!")
        } catch {
            fputs("❌ Unexpected error in tests: \(error)\n", stderr)
            exit(1)
        }
    }
}
