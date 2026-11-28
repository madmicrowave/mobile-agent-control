import AppKit
import Foundation
import SwiftUI

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

    // Test discovery of git repos in extraDirs
    let tempExtra = FileManager.default.temporaryDirectory.appendingPathComponent("mac-extra-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempExtra) }
    let extraJenkinsRepo = tempExtra.appendingPathComponent("jenkins", isDirectory: true)
    try FileManager.default.createDirectory(at: extraJenkinsRepo.appendingPathComponent(".git"), withIntermediateDirectories: true)

    let reposWithExtra = MACPathUtils.discoverGitRepos(
        at: tempRoot.path,
        extraDirs: [extraJenkinsRepo.path],
        stagingJobs: ["HS-1/crypto-fusion/merchant", "HS-1/crypto-fusion/client", "HS-1/crypto-fusion/jenkins"],
        prodJobs: ["PROD/crypto-fusion/merchant", "PROD/crypto-fusion/client", "PROD/crypto-fusion/jenkins"]
    )
    expect(reposWithExtra.count == 3, "Expected 3 discovered Git repos including extraDirs, got \(reposWithExtra.count)")
    let jenkins = reposWithExtra.first(where: { $0.name == "jenkins" })
    expect(jenkins != nil, "Expected extraDirs repo 'jenkins' to be discovered")
    expect(jenkins?.path == (extraJenkinsRepo.path as NSString).standardizingPath, "Expected matching path for extraDirs repo")
    expect(jenkins?.jenkinsJob == "HS-1/crypto-fusion/jenkins", "Expected matched staging job for extraDirs repo")

    // Verify hasGitRepository detects level-1 subdirectory repos without requiring .git at workspace root
    expect(MACPathUtils.hasGitRepository(at: tempRoot.path, maxSubdirectoryLevels: 2) == true, "Expected level-1 subdirectory repos to pass hasGitRepository")

    // Verify 2-level subdirectory discovery & validation when .git is not at root or level 1
    let tempTwoLevel = FileManager.default.temporaryDirectory.appendingPathComponent("mac-ws-2lvl-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempTwoLevel) }
    let nestedWebRepo = tempTwoLevel.appendingPathComponent("packages/web-portal", isDirectory: true)
    let nestedApiRepo = tempTwoLevel.appendingPathComponent("services/api-core", isDirectory: true)
    try FileManager.default.createDirectory(at: nestedWebRepo.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: nestedApiRepo.appendingPathComponent(".git"), withIntermediateDirectories: true)

    expect(MACPathUtils.hasGitRepository(at: tempTwoLevel.path, maxSubdirectoryLevels: 1) == false, "No .git at root or level 1")
    expect(MACPathUtils.hasGitRepository(at: tempTwoLevel.path, maxSubdirectoryLevels: 2) == true, "Must detect .git at 2nd subdirectory level")

    let twoLevelRepos = MACPathUtils.discoverGitRepos(at: tempTwoLevel.path)
    expect(twoLevelRepos.count == 2, "Expected 2 repos discovered at 2nd subdirectory level, got \(twoLevelRepos.count)")
    expect(twoLevelRepos.contains(where: { $0.name == "web-portal" }), "Expected level-2 repo 'web-portal'")
    expect(twoLevelRepos.contains(where: { $0.name == "api-core" }), "Expected level-2 repo 'api-core'")

    // Empty folder with no .git up to 2 levels returns false
    let emptyFolder = FileManager.default.temporaryDirectory.appendingPathComponent("mac-empty-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: emptyFolder) }
    try FileManager.default.createDirectory(at: emptyFolder.appendingPathComponent("sub1/sub2"), withIntermediateDirectories: true)
    expect(MACPathUtils.hasGitRepository(at: emptyFolder.path, maxSubdirectoryLevels: 2) == false, "Empty folder without .git must return false")

    print("✓ Job list parsing & Git repository auto-discovery (1-level, 2-level & extraDirs) passed")
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
                prodLiveUrl: "https://payment-book.com",
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
        suspendedUsers: [
            MACSuspendedUser(
                userId: "998877",
                username: "badguy",
                firstName: "Bad Guy",
                suspendedAt: "2026-11-18T00:00:00Z",
                failedAttempts: 5,
                reason: "Exceeded 5 failed password attempts"
            )
        ],
        defaultHistoryCount: 20
    )
    try store.save(cfg)

    let perms = (try FileManager.default.attributesOfItem(atPath: store.configFileURL.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
    expect((perms & 0o777) == 0o600, "Expected 0600 permissions on config.json, got \(String(perms, radix: 8))")

    let reloaded = store.load()
    expect(reloaded.telegramBotToken == "123456:TEST_TOKEN", "Bot token round-trip")
    expect(reloaded.jenkins.baseUrl == "https://jenkins.local", "Jenkins URL round-trip")
    expect(reloaded.suspendedUsers.count == 1 && reloaded.suspendedUsers[0].userId == "998877", "Suspended users round-trip")
    expect(reloaded.workspaces.count == 1, "Workspace count round-trip")
    expect(reloaded.workspaces[0].environmentMode == "multi", "Multi environment mode preserved")
    expect(reloaded.workspaces[0].prodJenkinsJobs == ["PROD/pb/gate"], "Prod Jenkins jobs preserved")
    expect(reloaded.workspaces[0].prodLiveUrl == "https://payment-book.com", "Prod Live URL preserved")
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

    // Directory paths (like /opt/homebrew/bin or /usr/local/bin) must NOT be considered executable binaries
    expect(
        MACPathUtils.isExecutableAvailable("/opt/homebrew/bin") == false,
        "Directory path /opt/homebrew/bin must not be treated as executable binary"
    )
    expect(
        MACPathUtils.isExecutableAvailable("/usr/local/bin") == false,
        "Directory path /usr/local/bin must not be treated as executable binary"
    )

    // Uninstalled / non-resolvable default CLI paths must return empty string
    if !MACPathUtils.isExecutableAvailable("codex") {
        expect(MACPathUtils.defaultCodexBin() == "", "Uninstalled codex must return empty string")
    }
    if !MACPathUtils.isExecutableAvailable("cloud-code") {
        expect(MACPathUtils.defaultCloudCodeBin() == "", "Uninstalled cloud-code must return empty string")
    }

    // Corrupted or invalid directory paths in config.json must be cleaned up to empty string on load
    var dirInCfg = singleReloaded
    dirInCfg.aiderBin = "/opt/homebrew/bin"
    dirInCfg.codexBin = "codex"
    dirInCfg.cloudCodeBin = "cloud-code"
    try store.save(dirInCfg)
    let cleanedReloaded = store.load()
    expect(cleanedReloaded.aiderBin == "", "Invalid directory aiderBin must reset to empty string")
    if !MACPathUtils.isExecutableAvailable("codex") {
        expect(cleanedReloaded.codexBin == "", "Uninstalled codex must reset to empty string")
    }
    if !MACPathUtils.isExecutableAvailable("cloud-code") {
        expect(cleanedReloaded.cloudCodeBin == "", "Uninstalled cloud-code must reset to empty string")
    }
    print("✓ MACConfigFileStore atomic 0600 save/load round-trip & CLI brain dir migration passed")
}

private func testEngineModelFilteringAndEngineConfiguration() throws {
    let agyModels = MACModelOption.options(forEngine: "agy").map(\.id)
    expect(agyModels.contains("gemini-3.8-flash"), "AGY supports gemini-3.8-flash")
    expect(agyModels.contains("gemini-4-neon"), "AGY supports gemini-4-neon")
    expect(agyModels.contains("gemini-4-hydrogen"), "AGY supports gemini-4-hydrogen")
    expect(agyModels.contains("claude-opus-5-5"), "AGY supports claude-opus-5-5")
    expect(!agyModels.contains("openai-codex"), "AGY must not list openai-codex")
    expect(!agyModels.contains("gpt-oss-120b-medium"), "AGY must not list gpt-oss-120b-medium")

    let (neonFam, neonLvl, _, _) = MACModelOption.normalizeFamilyAndLevel(rawModel: "gemini-4-neon", rawLevel: "extra high")
    expect(neonFam == "gemini-4-neon" && neonLvl == "xhigh", "extra high maps to xhigh for neon")

    let (normFam, normLvl, _, _) = MACModelOption.normalizeFamilyAndLevel(rawModel: "gemini-4-hydrogen-xhigh", rawLevel: "")
    expect(normFam == "gemini-4-hydrogen" && normLvl == "xhigh", "hydrogen-xhigh suffix resolves to xhigh")

    let neonLevels = MACModelOption.supportedLevels(forModel: "gemini-4-neon")
    expect(neonLevels == ["low", "medium", "high", "xhigh"], "gemini-4-neon supports extra high (xhigh)")

    let flashLevels = MACModelOption.supportedLevels(forModel: "gemini-3.8-flash")
    expect(flashLevels == ["low", "medium", "high"], "gemini-3.8-flash must NOT have xhigh")

    let (flashFam, flashLvl, _, _) = MACModelOption.normalizeFamilyAndLevel(rawModel: "gemini-3.8-flash", rawLevel: "extra high")
    expect(flashFam == "gemini-3.8-flash" && flashLvl == "high", "extra high automatically falls back to high for models without xhigh")

    let codexModels = MACModelOption.options(forEngine: "codex").map(\.id)
    expect(codexModels.contains("openai-codex"), "Codex supports openai-codex")
    expect(codexModels.contains("o3-mini"), "Codex supports o3-mini")
    expect(!codexModels.contains("gemini-3.8-flash"), "Codex must not list gemini-3.8-flash")

    let aiderModels = MACModelOption.options(forEngine: "aider").map(\.id)
    expect(aiderModels.contains("claude-3-7-sonnet"), "Aider supports claude-3-7-sonnet")
    expect(aiderModels.contains("deepseek-reasoner"), "Aider supports deepseek-reasoner")
    expect(!aiderModels.contains("gemini-3.8-flash"), "Aider must not list gemini-3.8-flash")

    let directApiModels = MACModelOption.options(forEngine: "direct-api").map(\.id)
    expect(directApiModels.contains("deepseek-chat"), "Direct API supports deepseek-chat")
    expect(directApiModels.contains("gpt-oss-120b-medium"), "Direct API supports gpt-oss-120b-medium")
    expect(!directApiModels.contains("gemini-3.8-flash"), "Direct API must not list gemini-3.8-flash")

    var cfg = MACConfig()
    cfg.deepseekApiKey = "sk-test"
    expect(cfg.isDirectApiConfigured, "isDirectApiConfigured true when deepseekApiKey is set")
    expect(cfg.isEngineConfigured("direct-api"), "isEngineConfigured true for direct-api")

    cfg.deepseekApiKey = ""
    expect(!cfg.isDirectApiConfigured, "isDirectApiConfigured false when no keys are set")
    expect(!cfg.isEngineConfigured("direct-api"), "isEngineConfigured false for direct-api")

    print("✓ Execution Engine model filtering and engine configuration checks passed")
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
    let keepAlive = plist?["KeepAlive"] as? [String: Any]
    expect(keepAlive?["SuccessfulExit"] as? Bool == false, "LaunchAgent KeepAlive SuccessfulExit=false check")
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
        "Settings",
        "Workspaces",
        "Tutorial",
        "Logbook"
    ], "Expected 4 tabs in exact order: Settings, Workspaces, Tutorial, Logbook")
    expect(appState.selectedTab == .general, "Expected Settings as default first tab")
    expect(controller.openAppMenuItem.title == "Open App", "Menu has Open App")
    expect(controller.startMenuItem.title == "Start...", "Menu has Start...")
    expect(controller.restartMenuItem.title == "Restart...", "Menu has Restart...")
    expect(controller.stopMenuItem.title == "Stop", "Menu has Stop")
    expect(controller.aboutMenuItem.title == "About", "Menu has About")
    expect(controller.startMenuItem.isEnabled && !controller.stopMenuItem.isEnabled, "Initial menu enabled state")
    expect(controller.effectiveActivationPolicy == .accessory, "Expected initial effectiveActivationPolicy == .accessory (no Dock icon)")
    expect(NSApp.activationPolicy() == .accessory, "Expected test runner NSApp.activationPolicy() == .accessory")

    // Verify initial stopped status icon in menu bar
    let initialStoppedImg = controller.statusBarIconImage(for: .stopped)
    expect(initialStoppedImg != nil, "Expected stopped menu bar image present")
    expect(initialStoppedImg?.size.width == 42.0, "Expected stopped icon width 42 pt (pill badge)")
    expect(initialStoppedImg?.isTemplate == true, "Expected stopped icon to be monochrome template")

    // Verify Settings tracks .regular for mac.app while NEVER promoting the bare MACAppTests binary into the macOS Dock!
    controller.handleOpenAppClicked()
    expect(controller.settingsWindow != nil, "Main app window created")
    expect(controller.settingsWindow?.isVisible == true, "Main app window visible")
    expect(controller.effectiveActivationPolicy == .regular, "Expected effectiveActivationPolicy == .regular when Settings is active")
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

    // Verify menu bar button has green dot when running (started)
    let runningImg = controller.statusBarIconImage(for: appState.status)
    expect(runningImg != nil, "Expected running status image present")
    expect(runningImg?.size.width == 53.0, "Expected running icon width 53 pt with green dot in front")
    expect(runningImg?.isTemplate == false, "Expected running icon to NOT be template so green color is preserved")
    expect(controller.statusItem.button?.image?.size.width == 53.0, "Status bar button image updated to 53 pt with green dot")

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

    // Verify that log lines containing "Fatal startup error:" inside code or diffs do not erroneously flip .running to .error
    appState.processLogChunkForTesting("let reason = rawLine.components(separatedBy: \"Fatal startup error:\").last?.trimmingCharacters(in: .whitespaces) ?? \"Startup failed\"\n")
    expect(appState.status == .running(botUsername: "mac_unit_bot"), "Code diff containing 'Fatal startup error:' must not change status to error while running")

    // Verify accidental echo while running is ignored
    appState.processLogChunkForTesting("[bot] Fatal startup error: something bad\n")
    expect(appState.status == .running(botUsername: "mac_unit_bot"), "Echoed fatal startup error line must not change status to error when bot is already running")

    // Trigger Stop
    controller.handleStopClicked()
    expect(appState.status == .stopped, "Expected status == .stopped after Stop")
    expect(!appState.isSleepPrevented, "Expected sleep prevention released after Stop")
    expect(controller.startMenuItem.isEnabled && !controller.stopMenuItem.isEnabled, "Stopped menu item states")

    // When stopped/starting, non-prefixed lines must not trigger error
    appState.processLogChunkForTesting("+ let err = \"Fatal startup error: not a real error\"\n")
    expect(appState.status == .stopped, "Non-prefixed diff line must not trigger error during startup/stopped")

    // Genuine startup error with prefix triggers .error
    appState.processLogChunkForTesting("[bot] Fatal startup error: Invalid Telegram bot token\n")
    if case .error(let reason) = appState.status {
        expect(reason == "Invalid Telegram bot token", "Expected extracted error reason, got \(reason)")
    } else {
        expect(false, "Expected .error status after genuine startup error, got \(appState.status)")
    }
    appState.status = .stopped

    // Multi-monitor display confinement & safe menu update verification
    let confinement = controller.confinementRect(for: controller.menu, on: NSScreen.main)
    expect(confinement != .zero, "Expected non-zero confinementRect for status menu on multi-display setup")

    // Test top boundary near clock on every available screen (including edge coordinates)
    for screen in NSScreen.screens {
        let topClockEdge = NSPoint(x: screen.frame.maxX - 10, y: screen.frame.maxY)
        let resolvedScreen = controller.targetScreenForMenu(at: topClockEdge)
        expect(resolvedScreen == screen, "Expected top-edge menu click on screen \(screen.frame) to resolve to itself")

        let overshootPoint = NSPoint(x: screen.frame.maxX - 10, y: screen.frame.maxY + 2)
        let resolvedOvershoot = controller.targetScreenForMenu(at: overshootPoint)
        expect(resolvedOvershoot != nil, "Expected tolerance-handled click above screen top boundary to resolve to a display")
    }

    // Verify log revision tracking, buffer limits, batch logs, and clearLogs behavior
    let initialCount = appState.logLines.count
    let initialRev = appState.logRevision
    appState.appendLog("Sample log line 1")
    expect(appState.logRevision == initialRev + 1, "appendLog increments logRevision")
    expect(appState.logLines.count == initialCount + 1, "logLines holds appended line")

    // Test buffer limit enforcement and trimming
    let origLimit = appState.maxLogLines
    appState.maxLogLines = 5
    for i in 1...10 {
        appState.appendLog("Overflow test line \(i)")
    }
    expect(appState.logLines.count == 5, "Expected logLines capped at maxLogLines (5), got \(appState.logLines.count)")
    expect(appState.logLines.last == "Overflow test line 10", "Latest line is preserved")
    expect(appState.logLines.first == "Overflow test line 6", "Oldest excess lines trimmed")
    expect(appState.logStartSequence > 0, "logStartSequence tracks trimmed offset")

    // Test batch appendLogs
    let revBeforeBatch = appState.logRevision
    appState.appendLogs(["Batch line 1", "Batch line 2", "Batch line 3"])
    expect(appState.logRevision == revBeforeBatch + 1, "appendLogs increments logRevision once for batch")
    expect(appState.logLines.count == 5, "Buffer remains capped at 5 after batch append")
    expect(appState.logLines.last == "Batch line 3", "Latest batch item preserved")

    appState.clearLogs()
    expect(appState.logRevision == revBeforeBatch + 2, "clearLogs increments logRevision")
    expect(appState.logLines.isEmpty, "clearLogs clears all logLines")
    expect(appState.logStartSequence == 0, "clearLogs resets sequence offset")

    // Restore original buffer limit
    appState.maxLogLines = origLimit
    expect(!appState.status.isRunningOrStarting, "Stopped bot state reflects isRunningOrStarting == false")

    controller.menuNeedsUpdate(controller.menu)
    controller.menuWillOpen(controller.menu)
    expect(controller.startMenuItem.isEnabled, "Menu update reflects current stopped state")
    print("✓ MACStatusBarController Start / Restart / Stop + Password Prompt + Sleep Prevention passed")
}

@MainActor
func testResourceMonitorAndMetrics() throws {
    let metricsMB = MACProcessMetrics(cpuPercent: 12.34, memoryMB: 48.5)
    expect(metricsMB.formattedCPU == "12.3%", "formattedCPU formats 1 decimal place")
    expect(metricsMB.formattedMemory == "48.5 MB", "formattedMemory formats in MB")

    let metricsGB = MACProcessMetrics(cpuPercent: -2.0, memoryMB: 1536.0)
    expect(metricsGB.formattedCPU == "0.0%", "formattedCPU clamps negative values to 0.0%")
    expect(metricsGB.formattedMemory == "1.50 GB", "formattedMemory formats in GB when >= 1024 MB")

    let monitor = MACResourceMonitor()
    monitor.sample(botPid: nil)
    expect(monitor.appMetrics.memoryMB > 0.0, "App host process resident memory should be > 0 MB")
    expect(monitor.botMetrics.memoryMB == 0.0, "Bot memory is 0 when stopped")
    expect(monitor.agentMetrics.memoryMB == 0.0, "Agent memory is 0 when no bot process running")
    expect(monitor.activeAgentProcessCount == 0, "No active agent subprocesses when bot is nil")

    // Start & Stop cycle
    monitor.start { nil }
    monitor.stop()

    // Test child process discovery under a parent process
    let childProc = Process()
    childProc.executableURL = URL(fileURLWithPath: "/bin/sleep")
    childProc.arguments = ["2"]
    try childProc.run()
    monitor.sample(botPid: getpid())
    expect(monitor.activeAgentProcessCount >= 1, "Child process correctly discovered without byte-division truncation")
    expect(monitor.agentMetrics.memoryMB > 0.0, "Child process resident memory reported")
    childProc.terminate()

    print("✓ MACResourceMonitor process sampling and metrics formatting passed")
}

@MainActor
private func testConfigExportImportAndCrypto() throws {
    let plainData = "{\"telegramBotToken\":\"12345:TOKEN\",\"agentEngine\":\"agy\"}".data(using: .utf8)!
    let password = "superSecretPassword123"

    let encryptedPayload = try MACConfigCrypto.encrypt(data: plainData, password: password)
    expect(encryptedPayload.count > 44, "Encrypted payload must contain salt, nonce, ciphertext, and tag")

    let decryptedData = try MACConfigCrypto.decrypt(data: encryptedPayload, password: password)
    expect(decryptedData == plainData, "Decrypted data must match original plaintext")

    // Wrong password must throw
    var wrongPasswordThrew = false
    do {
        _ = try MACConfigCrypto.decrypt(data: encryptedPayload, password: "wrongPassword")
    } catch {
        wrongPasswordThrew = true
    }
    expect(wrongPasswordThrew, "Decryption with wrong password must fail")

    // Verify message history payload structure in export
    let sampleExportDict: [String: Any] = [
        "format": "ai-mac-config",
        "version": 1,
        "exportedAt": "2026-11-27T04:40:00Z",
        "config": ["defaultModel": "gemini-3.8-flash"],
        "messageHistory": [
            "workspaces": [
                "pb": [
                    "history": [["id": "turn-1", "prompt": "Hello world"]]
                ]
            ]
        ]
    ]
    let jsonExportData = try JSONSerialization.data(withJSONObject: sampleExportDict)
    let encExport = try MACConfigCrypto.encrypt(data: jsonExportData, password: "pw")
    let decExport = try MACConfigCrypto.decrypt(data: encExport, password: "pw")
    let parsedDec = try JSONSerialization.jsonObject(with: decExport) as? [String: Any]
    expect(parsedDec?["format"] as? String == "ai-mac-config", "Export format must be ai-mac-config")
    let histObj = parsedDec?["messageHistory"] as? [String: Any]
    expect(histObj != nil, "messageHistory must be present when included")

    // Verify MACExportAccessoryView rendering, flipped coords, intrinsic sizes, and toggle states
    let accessory = MACExportAccessoryView()
    expect(accessory.isFlipped == true, "Accessory view must be flipped for proper top-to-bottom layout")
    expect(accessory.wantsLayer == true, "Accessory view must be layer-backed")
    expect(!accessory.historyCheckbox.isHidden && accessory.historyCheckbox.state == .off, "History checkbox visible and initially unchecked")
    expect(!accessory.encryptCheckbox.isHidden && accessory.encryptCheckbox.state == .off, "Encrypt checkbox visible and initially unchecked")
    expect(accessory.passwordField.isHidden && accessory.confirmField.isHidden, "Password fields initially hidden")
    expect(accessory.intrinsicContentSize.height == 60, "Initial unencrypted accessory height is 60 pt")

    accessory.encryptCheckbox.state = .on
    accessory.handleCheckboxChanged()
    expect(!accessory.passwordField.isHidden && !accessory.confirmField.isHidden, "Password fields visible when encrypt checked")
    expect(accessory.intrinsicContentSize.height == 122, "Encrypted accessory height is 122 pt")

    accessory.encryptCheckbox.state = .off
    accessory.handleCheckboxChanged()
    expect(accessory.passwordField.isHidden && accessory.confirmField.isHidden, "Password fields hidden when encrypt unchecked")
    expect(accessory.intrinsicContentSize.height == 60, "Accessory height returns to 60 pt when unencrypted")

    accessory.layout()
    expect(accessory.historyCheckbox.frame.width > 0 && accessory.historyCheckbox.frame.height > 0, "History checkbox frame non-zero after layout")
    expect(accessory.encryptCheckbox.frame.width > 0 && accessory.encryptCheckbox.frame.height > 0, "Encrypt checkbox frame non-zero after layout")

    print("✓ MACConfigCrypto AES-GCM encryption & MACExportAccessoryView Auto Layout passed")
}

private func testWorkspaceDetailTabsAndTimelineHistory() throws {
    // 1. Verify 5 tabs exist with General as default and Work History as latest tab
    expect(
        WorkspaceDetailTab.allCases.map(\.rawValue) == ["General", "AI Engine & Model", "CI/CD", "Repositories", "Work History"],
        "Expected 5 tabs: General, AI Engine & Model, CI/CD, Repositories, Work History"
    )
    expect(WorkspaceDetailTab.general.rawValue == "General", "General tab title")
    expect(WorkspaceDetailTab.aiEngineModel.rawValue == "AI Engine & Model", "AI Engine & Model tab title")
    expect(WorkspaceDetailTab.cicd.rawValue == "CI/CD", "CI/CD tab title")
    expect(WorkspaceDetailTab.repositories.rawValue == "Repositories", "Repositories tab title")
    expect(WorkspaceDetailTab.history.rawValue == "Work History", "Work History tab title")
    expect(WorkspaceDetailTab.general.showsDeleteWorkspaceButton == true, "Delete button visible in General tab")
    expect(WorkspaceDetailTab.aiEngineModel.showsDeleteWorkspaceButton == false, "Delete button hidden in AI Engine & Model tab")
    expect(WorkspaceDetailTab.cicd.showsDeleteWorkspaceButton == false, "Delete button hidden in CI/CD tab")
    expect(WorkspaceDetailTab.repositories.showsDeleteWorkspaceButton == false, "Delete button hidden in Repositories tab")
    expect(WorkspaceDetailTab.history.showsDeleteWorkspaceButton == false, "Delete button hidden in Work History tab")

    // 2. Test Timeline loader from sample state.json
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("mac-timeline-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let sampleStateJSON = """
    {
      "workspaces": {
        "payment-book": {
          "activeTurn": {
            "id": "turn-active-123",
            "createdAt": "2026-11-26T22:00:00.000Z",
            "prompt": "Fix payment expiration redirect bug",
            "user": "@maksimsge",
            "commits": [
              {
                "repoName": "backend",
                "branch": "master",
                "shortSha": "abc1234",
                "commitMessage": "fix: redirect to payment page",
                "changedFiles": ["src/routes/payment.ts", "src/services/pay.ts"]
              }
            ]
          },
          "messageQueue": [
            {
              "id": "q-1",
              "queueNumber": 1,
              "text": "Update footer copyright year to 2026",
              "user": "@maksimsge",
              "queuedAt": "2026-11-26T22:05:00.000Z",
              "photos": [
                {
                  "path": "/tmp/payment-book/uploads/queued-shot.jpg",
                  "fileName": "queued-shot.jpg",
                  "originalName": "footer-spec.jpg"
                }
              ]
            },
            {
              "id": "q-2",
              "queueNumber": 2,
              "text": "Second later queued request",
              "user": "@maksimsge",
              "queuedAt": "2026-11-26T22:10:00.000Z",
              "photos": []
            }
          ],
          "history": [
            {
              "id": "turn-hist-1",
              "createdAt": "2026-11-26T21:00:00.000Z",
              "finishedAt": "2026-11-26T21:02:30.000Z",
              "prompt": "Add dark mode toggle to navigation bar",
              "user": "@maksimsge",
              "outcome": "CONFIRMED",
              "attachments": [
                {
                  "path": "/tmp/payment-book/uploads/nav-mockup.png",
                  "fileName": "nav-mockup.png",
                  "originalName": "nav-mockup.png"
                }
              ],
              "commits": [
                {
                  "repoName": "frontend",
                  "branch": "master",
                  "shortSha": "def5678",
                  "commitMessage": "feat: dark mode toggle",
                  "changedFiles": ["src/components/Nav.tsx", "src/styles/theme.css"]
                }
              ]
            },
            {
              "id": "turn-hist-2",
              "createdAt": "2026-11-26T20:00:00.000Z",
              "finishedAt": "2026-11-26T20:01:00.000Z",
              "prompt": "Revert bad commit",
              "user": "User",
              "outcome": "REVERTED"
            }
          ]
        }
      }
    }
    """
    let stateFile = tempDir.appendingPathComponent("state.json")
    try sampleStateJSON.write(to: stateFile, atomically: true, encoding: .utf8)

    let ws = MACWorkspace(id: "payment-book", label: "PAYMENT BOOK", path: "/tmp/payment-book")
    let items = MACWorkspaceTimelineReader.loadTimeline(workspace: ws, dataDir: tempDir)

    expect(items.count == 5, "Expected 5 timeline items (2 queued + 1 working + 2 history), got \(items.count)")
    // Queued messages must be before working messages as they will execute later
    expect(items[0].status == .queued(2), "First item is latest queued message (#2, will execute later)")
    expect(items[0].message == "Second later queued request", "Queued #2 prompt matches")

    expect(items[1].status == .queued(1), "Second item is earlier queued message (#1)")
    expect(items[1].message == "Update footer copyright year to 2026", "Queued #1 prompt matches")
    expect(items[1].attachments.count == 1, "Queued #1 parsed dictionary photo attachment")
    expect(items[1].attachments[0].displayName == "footer-spec.jpg", "Queued #1 attachment displayName matches")

    expect(items[2].status == .working, "Third item is active working turn (executing now)")
    expect(items[2].user == "@maksimsge", "User is @maksimsge")
    expect(items[2].message == "Fix payment expiration redirect bug", "Prompt matches")
    expect(items[2].files.contains("src/routes/payment.ts"), "Files extracted from commits")
    expect(items[2].resultLabel == "Working...", "Result label is Working...")

    expect(items[3].status == .success, "Fourth item is success history")
    expect(items[3].resultLabel == "Success", "Fourth item result is Success")
    expect(items[3].elapsedTime == "2m 30s", "Elapsed time calculated accurately as 2m 30s, got \(items[3].elapsedTime)")
    expect(items[3].files.count == 2, "Files count is 2")
    expect(items[3].attachments.count == 1, "History item parsed attached file")
    expect(items[3].totalFileCount == 3, "Total file count combines 1 attachment + 2 modified files")

    expect(items[4].status == .failed, "Fifth item is failed/reverted")
    expect(items[4].resultLabel == "Reverted", "Fifth item result is Reverted")
    expect(items[4].user == "@maksimsge", "Generic 'User' must be resolved to real username '@maksimsge'")

    // Test limit parameter on history
    let limitedItems = MACWorkspaceTimelineReader.loadTimeline(workspace: ws, dataDir: tempDir, limit: 1)
    expect(limitedItems.count == 4, "Expected 4 items with limit 1 (1 working + 2 queued + 1 history), got \(limitedItems.count)")

    // Test working-agent status detection (green dot vs gray dot in Workspaces sidebar)
    let workingStateJSON = """
    {
      "workspaces": {
        "pb": {
          "phase": "RUNNING_AGENT",
          "activeTurn": { "id": "t-1", "prompt": "Working now" }
        },
        "ai-portfolio": {
          "phase": "AWAITING_COMMIT_CHOICE",
          "activeTurn": { "id": "t-2", "prompt": "Finished waiting commit" }
        },
        "dai": {
          "phase": "IDLE"
        }
      }
    }
    """
    let workingDir = tempDir.appendingPathComponent("working-dot-check", isDirectory: true)
    try FileManager.default.createDirectory(at: workingDir, withIntermediateDirectories: true)
    try workingStateJSON.write(to: workingDir.appendingPathComponent("state.json"), atomically: true, encoding: .utf8)

    let wsWorking = MACWorkspace(id: "payment-book", label: "PAYMENT BOOK", path: "/Users/test/code/domonk/pb")
    let wsAwaitingCommit = MACWorkspace(id: "ai-portfolio", label: "AI Portfolio", path: "/Users/test/code/domonk/madmicrowave")
    let wsIdle = MACWorkspace(id: "dai", label: "DAI", path: "/Users/test/code/domonk/factory")

    let activeIds = MACWorkspaceTimelineReader.workingWorkspaceIds(
        workspaces: [wsWorking, wsAwaitingCommit, wsIdle],
        dataDir: workingDir
    )
    expect(activeIds == Set(["payment-book"]), "Only RUNNING_AGENT workspace should show green working dot, got \(activeIds)")
    expect(MACWorkspaceTimelineReader.isAgentWorking(workspace: wsWorking, dataDir: workingDir) == true, "RUNNING_AGENT workspace is working (green dot)")
    expect(MACWorkspaceTimelineReader.isAgentWorking(workspace: wsAwaitingCommit, dataDir: workingDir) == false, "AWAITING_COMMIT_CHOICE workspace is not working (gray dot)")
    expect(MACWorkspaceTimelineReader.isAgentWorking(workspace: wsIdle, dataDir: workingDir) == false, "IDLE workspace is not working (gray dot)")

    // 3. Test WorkspaceTimelineVM auto-refresh countdown, tick, and reset behavior, plus historyLimit buffer options
    let timelineVM = WorkspaceTimelineVM()
    expect(timelineVM.autoRefreshSecondsRemaining == 60, "Initial countdown is 60s")
    expect(timelineVM.historyLimit == 100, "Default history limit is 100")
    expect(WorkspaceTimelineVM.allowedLimits == [100, 500, 1000, 3000], "Allowed history buffer limits are 100, 500, 1000, 3000")

    timelineVM.setHistoryLimit(500)
    expect(timelineVM.historyLimit == 500, "History limit updated to 500")
    expect(UserDefaults.standard.integer(forKey: "MACWorkHistoryLimit") == 500, "Persisted 500 to UserDefaults")

    timelineVM.setHistoryLimit(3000)
    expect(timelineVM.historyLimit == 3000, "History limit updated to 3000")

    timelineVM.setHistoryLimit(9999)
    expect(timelineVM.historyLimit == 100, "Disallowed limit falls back to default 100")

    timelineVM.setHistoryLimit(100)
    expect(timelineVM.historyLimit == 100, "History limit reset to 100")

    var refreshTriggered = false
    timelineVM.tick { refreshTriggered = true }
    expect(timelineVM.autoRefreshSecondsRemaining == 59, "First tick decrements to 59s")
    expect(!refreshTriggered, "Refresh not triggered yet at 59s")

    timelineVM.resetCountdown()
    expect(timelineVM.autoRefreshSecondsRemaining == 60, "resetCountdown resets back to 60s")
    expect(timelineVM.formattedAutoRefreshCountdown == "60", "60s formatted as 60")

    timelineVM.autoRefreshSecondsRemaining = 9
    expect(timelineVM.formattedAutoRefreshCountdown == "09", "9s zero-padded as 09")
    timelineVM.autoRefreshSecondsRemaining = 3
    expect(timelineVM.formattedAutoRefreshCountdown == "03", "3s zero-padded as 03")
    timelineVM.autoRefreshSecondsRemaining = 2
    expect(timelineVM.formattedAutoRefreshCountdown == "02", "2s zero-padded as 02")
    timelineVM.autoRefreshSecondsRemaining = 1
    expect(timelineVM.formattedAutoRefreshCountdown == "01", "1s zero-padded as 01")
    timelineVM.tick { refreshTriggered = true }
    expect(timelineVM.autoRefreshSecondsRemaining == 60, "Tick from 1 resets countdown to 60s")
    expect(timelineVM.formattedAutoRefreshCountdown == "60", "Reset countdown formatted as 60")
    expect(refreshTriggered, "Automatic refresh triggered when counter reaches 0")

    timelineVM.startAutoRefresh {}
    timelineVM.stopAutoRefresh()

    // 4. Test File resolution and FilePreviewItem
    let testRepoDir = tempDir.appendingPathComponent("backend", isDirectory: true)
    let testFileDir = testRepoDir.appendingPathComponent("src/routes", isDirectory: true)
    try FileManager.default.createDirectory(at: testFileDir, withIntermediateDirectories: true)
    let testFile = testFileDir.appendingPathComponent("payment.ts")
    try "export const payment = () => 'ok';\n".write(to: testFile, atomically: true, encoding: .utf8)

    let testRepo = MACRepo(name: "backend", path: testRepoDir.path)
    let wsWithRepo = MACWorkspace(id: "payment-book", label: "PAYMENT BOOK", path: tempDir.path, repos: [testRepo])

    let resolved = MACWorkspaceTimelineReader.resolveFilePath(file: "src/routes/payment.ts", workspace: wsWithRepo)
    expect(resolved == testFile.path, "Expected resolveFilePath to locate file inside repo directory")

    let previewItem = FilePreviewItem(relativePath: "src/routes/payment.ts", workspace: wsWithRepo)
    expect(previewItem.fileExists == true, "previewItem fileExists is true")
    expect(previewItem.content?.contains("export const payment") == true, "previewItem read content matches")
    expect(previewItem.fileName == "payment.ts", "previewItem fileName matches")
    expect(previewItem.isImage == false, "payment.ts is not image")

    print("✓ Workspace 2-tab layout (Settings & Work History) & Timeline 60s auto-refresh passed")
}

private func testGitRemoteWebURLAndMultiJobMapping() throws {
    // 1. Test Git remote URL conversions
    let githubSSH = "git@github.com:madmicrowave/mobile-agent-control.git"
    let githubHTTPS = "https://github.com/madmicrowave/mobile-agent-control.git"
    let gitlabSSH = "git@gitlab.com:org/subgroup/repo.git"
    let bitbucketSSH = "git@bitbucket.org:org/repo.git"
    let plainWeb = "https://github.com/madmicrowave/mobile-agent-control"

    expect(MACPathUtils.convertGitRemoteToWebURL(githubSSH)?.absoluteString == "https://github.com/madmicrowave/mobile-agent-control", "GitHub SSH conversion failed")
    expect(MACPathUtils.convertGitRemoteToWebURL(githubHTTPS)?.absoluteString == "https://github.com/madmicrowave/mobile-agent-control", "GitHub HTTPS conversion failed")
    expect(MACPathUtils.convertGitRemoteToWebURL(gitlabSSH)?.absoluteString == "https://gitlab.com/org/subgroup/repo", "GitLab SSH conversion failed")
    expect(MACPathUtils.convertGitRemoteToWebURL(bitbucketSSH)?.absoluteString == "https://bitbucket.org/org/repo", "Bitbucket SSH conversion failed")
    expect(MACPathUtils.convertGitRemoteToWebURL(plainWeb)?.absoluteString == "https://github.com/madmicrowave/mobile-agent-control", "Plain web URL conversion failed")

    // 2. Test Multi-Job mapping, CLI commands, and noOrigin on MACRepo
    let defaultRepo = MACRepo(name: "default-repo", path: "/test")
    expect(defaultRepo.noOrigin == false, "noOrigin default is false")

    let repo = MACRepo(
        name: "test-repo",
        path: "/Users/test/code/test-repo",
        jenkinsJobs: ["Job/Staging/api", "Job/Staging/worker"],
        prodJenkinsJobs: ["Job/Prod/api", "Job/Prod/worker"],
        stagingCommand: "bash build_staging.sh --arg=ooo",
        prodCommand: "bash deploy_prod.sh --arg=prod",
        noOrigin: true
    )
    expect(repo.jenkinsJobs.count == 2, "Expected 2 staging jobs")
    expect(repo.prodJenkinsJobs.count == 2, "Expected 2 prod jobs")
    expect(repo.jenkinsJob.contains("Job/Staging/api"), "jenkinsJob legacy string contains first job")
    expect(repo.deployEnabled == true, "Deploy enabled automatically when jobs present")
    expect(repo.stagingCommand == "bash build_staging.sh --arg=ooo", "Staging command set")
    expect(repo.prodCommand == "bash deploy_prod.sh --arg=prod", "Prod command set")
    expect(repo.noOrigin == true, "noOrigin flag set to true")

    // Test JSON roundtrip
    let encoder = JSONEncoder()
    let data = try encoder.encode(repo)
    let decoder = JSONDecoder()
    let decoded = try decoder.decode(MACRepo.self, from: data)
    expect(decoded.jenkinsJobs == ["Job/Staging/api", "Job/Staging/worker"], "Decoded jenkinsJobs match")
    expect(decoded.prodJenkinsJobs == ["Job/Prod/api", "Job/Prod/worker"], "Decoded prodJenkinsJobs match")
    expect(decoded.stagingCommand == "bash build_staging.sh --arg=ooo", "Decoded staging command matches")
    expect(decoded.prodCommand == "bash deploy_prod.sh --arg=prod", "Decoded prod command matches")
    expect(decoded.noOrigin == true, "Decoded noOrigin matches")

    // Test sanitizeJobList
    let rawDirtyJobs = ["Job/Staging/api, Job/Staging/worker", "Job/Staging/extra", "Job/Staging/api"]
    let sanitized = MACPathUtils.sanitizeJobList(rawDirtyJobs)
    expect(sanitized == ["Job/Staging/api", "Job/Staging/worker", "Job/Staging/extra"], "sanitizeJobList flattens comma separated entries and removes duplicates")

    // Test workspace decoding sanitization
    let wsJson = """
    {
        "id": "test-ws",
        "path": "/Users/test/code/test-ws",
        "jenkinsJobs": ["Job/A, Job/B", "Job/C"],
        "prodJenkinsJobs": ["Job/ProdA, Job/ProdB"]
    }
    """.data(using: .utf8)!
    let decodedWs = try decoder.decode(MACWorkspace.self, from: wsJson)
    expect(decodedWs.jenkinsJobs == ["Job/A", "Job/B", "Job/C"], "Workspace jenkinsJobs properly sanitized on decode")
    expect(decodedWs.prodJenkinsJobs == ["Job/ProdA", "Job/ProdB"], "Workspace prodJenkinsJobs properly sanitized on decode")

    print("✓ Git remote web URL conversion & multi-job repo mapping passed")
}

@MainActor
private func testAutoStartPersistenceAndBotWatchdogRecovery() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("mac-watchdog-test-\(UUID().uuidString)", isDirectory: true)
    let runtimeDir = tempDir.appendingPathComponent("runtime", isDirectory: true)
    let srcDir = runtimeDir.appendingPathComponent("src", isDirectory: true)
    let dataDir = tempDir.appendingPathComponent("data", isDirectory: true)
    let launchDir = tempDir.appendingPathComponent("LaunchAgents", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

    let crashMarkerPath = dataDir.appendingPathComponent("crash-once.flag").path
    let argsRecordPath = dataDir.appendingPathComponent("last-args.txt").path

    let mockWatchdogScript = """
    import fs from 'node:fs';
    import readline from 'node:readline';
    const rl = readline.createInterface({ input: process.stdin });
    rl.once('line', (pw) => {
      if (!pw || !pw.trim()) process.exit(2);
      fs.writeFileSync(\( String(reflecting: argsRecordPath) ), process.argv.slice(2).join(' '), 'utf8');
      console.log('  Telegram Bot    : @mac_watchdog_bot (https://t.me/mac_watchdog_bot)');
      console.log('  Long-polling active. Open your bot in Telegram and send /start');
      if (fs.existsSync(\( String(reflecting: crashMarkerPath) ))) {
        fs.unlinkSync(\( String(reflecting: crashMarkerPath) ));
        setTimeout(() => process.exit(1), 120);
        return;
      }
      setInterval(() => {}, 1000);
    });
    process.on('SIGTERM', () => process.exit(0));
    """
    try mockWatchdogScript.write(to: srcDir.appendingPathComponent("bot.mjs"), atomically: true, encoding: .utf8)
    try "1".write(toFile: crashMarkerPath, atomically: true, encoding: .utf8)

    let store = MACConfigFileStore(dataDir: dataDir)
    try store.save(MACConfig(telegramBotToken: "888888:WATCHDOG_TOKEN"))

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
    appState.watchdogBaseDelaySeconds = 0.12

    // 1. Start bot -> runs, then crashes once after 120ms -> watchdog auto-restarts it with --preserve-sessions!
    appState.startBot(sessionPassword: "auto-secret-xyz")
    expect(appState.hasSavedAutoStartSession == true, "Encrypted auto-start session saved on startBot")

    let encBytes = try Data(contentsOf: MACBotAutoStartStore.fileURL(dataDir: dataDir))
    let encRawStr = String(data: encBytes, encoding: .utf8) ?? ""
    expect(!encRawStr.contains("auto-secret-xyz"), "Session password must be encrypted, never plaintext on disk")

    // Wait for crash marker to be consumed AND watchdog to bring bot back to .running
    let recoveryDeadline = Date().addingTimeInterval(5.0)
    var sawWatchdogLog = false
    while Date() < recoveryDeadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        if appState.logLines.contains(where: { $0.contains("auto-restarting") }) {
            sawWatchdogLog = true
        }
        if sawWatchdogLog,
           !FileManager.default.fileExists(atPath: crashMarkerPath),
           appState.status == .running(botUsername: "mac_watchdog_bot") {
            break
        }
    }
    expect(sawWatchdogLog, "Expected watchdog auto-restart log after unexpected exit")
    expect(appState.status == .running(botUsername: "mac_watchdog_bot"), "Expected bot back in .running after watchdog recovery, got \(appState.status)")
    let recordedArgs = (try? String(contentsOfFile: argsRecordPath, encoding: .utf8)) ?? ""
    expect(recordedArgs.contains("--preserve-sessions"), "Watchdog restart should pass --preserve-sessions")

    // 2. Simulate app termination (relaunch / update / reboot) -> preserves auto-start state
    appState.stopBotForAppTermination()
    expect(appState.status == .stopped, "Bot process stopped for app termination")
    expect(appState.hasSavedAutoStartSession == true, "Auto-start session preserved across app termination")

    // 3. New MACAppState on relaunch auto-starts immediately without manual prompt
    let relaunchedState = MACAppState(
        dataDir: dataDir,
        runtimeRootURL: runtimeDir,
        sleepPreventer: SleepPreventer(),
        launchAtLoginManager: launchMgr
    )
    let didAutoStart = relaunchedState.autoStartIfPreviouslyRunning()
    expect(didAutoStart == true, "Expected autoStartIfPreviouslyRunning() to start bot on app relaunch")

    let relaunchDeadline = Date().addingTimeInterval(4.0)
    while Date() < relaunchDeadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        if relaunchedState.status == .running(botUsername: "mac_watchdog_bot") {
            break
        }
    }
    expect(relaunchedState.status == .running(botUsername: "mac_watchdog_bot"), "Relaunched appState must reach .running")

    // 4. Explicit Stop clears auto-start session so subsequent launch stays stopped
    relaunchedState.stopBot()
    expect(relaunchedState.hasSavedAutoStartSession == false, "Explicit Stop must clear auto-start session")

    let stoppedState = MACAppState(
        dataDir: dataDir,
        runtimeRootURL: runtimeDir,
        sleepPreventer: SleepPreventer(),
        launchAtLoginManager: launchMgr
    )
    expect(stoppedState.autoStartIfPreviouslyRunning() == false, "Should NOT auto-start after explicit user Stop")
    print("✓ Auto-start persistence & watchdog crash recovery passed")
}

@MainActor
private func testFilterPlaceholderStabilityAndClickOutsideUnfocus() throws {
    let win = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
    win.contentView = root

    let filterView = MACSearchFilterContainerView(placeholder: "Search messages, files, users...")
    filterView.translatesAutoresizingMaskIntoConstraints = true
    filterView.frame = NSRect(x: 20, y: 240, width: 215, height: 26)
    root.addSubview(filterView)

    let normalInput = NSTextField(frame: NSRect(x: 20, y: 180, width: 200, height: 24))
    normalInput.isEditable = true
    root.addSubview(normalInput)

    root.layoutSubtreeIfNeeded()
    let placeholderFrameBeforeFocus = filterView.placeholderLabel.frame
    expect(!filterView.placeholderLabel.isHidden, "Placeholder visible when empty")
    expect(filterView.clearButton.isHidden, "Clear button hidden when empty")

    // Focus filter input -> placeholder must NOT move by even 0.01pt
    _ = win.makeFirstResponder(filterView.inputField)
    root.layoutSubtreeIfNeeded()
    let placeholderFrameDuringFocus = filterView.placeholderLabel.frame
    expect(
        placeholderFrameBeforeFocus == placeholderFrameDuringFocus,
        "Filter placeholder frame must remain identical on focus (before: \(placeholderFrameBeforeFocus), after: \(placeholderFrameDuringFocus))"
    )
    expect(!filterView.placeholderLabel.isHidden, "Placeholder stays visible while focused and empty")

    // Typing hides placeholder cleanly and shows clear button without shifting input frame
    let inputFrameBeforeType = filterView.inputField.frame
    filterView.updateText("deploy")
    root.layoutSubtreeIfNeeded()
    expect(filterView.placeholderLabel.isHidden, "Placeholder hidden when filter text is non-empty")
    expect(!filterView.clearButton.isHidden, "Clear button visible when filter text is non-empty")
    expect(filterView.inputField.frame == inputFrameBeforeType, "Input frame stays fixed when clear button appears")

    // Clicking inside focused filter field or normal editable text field must NOT unfocus
    expect(
        !MACOutsideClickUnfocusMonitor.shouldUnfocusFirstResponder(
            in: win,
            clickLocationInWindow: NSPoint(x: 80, y: 252)
        ),
        "Clicking inside focused filter must keep focus"
    )
    expect(
        !MACOutsideClickUnfocusMonitor.shouldUnfocusFirstResponder(
            in: win,
            clickLocationInWindow: NSPoint(x: 80, y: 192)
        ),
        "Clicking into another editable text field must allow direct focus transition"
    )

    // Clicking outside on empty background must unfocus the focused field
    expect(
        MACOutsideClickUnfocusMonitor.shouldUnfocusFirstResponder(
            in: win,
            clickLocationInWindow: NSPoint(x: 400, y: 50)
        ),
        "Clicking outside inputs must unfocus focused field"
    )
    win.makeFirstResponder(nil)
    expect(filterView.inputField.currentEditor() == nil, "Filter input unfocused after outside click")

    // Also test focusing normalInput and clicking outside
    _ = win.makeFirstResponder(normalInput)
    expect(normalInput.currentEditor() != nil, "normalInput focused")
    expect(
        MACOutsideClickUnfocusMonitor.shouldUnfocusFirstResponder(
            in: win,
            clickLocationInWindow: NSPoint(x: 420, y: 60)
        ),
        "Clicking outside normalInput must unfocus it"
    )
    win.makeFirstResponder(nil)
    expect(normalInput.currentEditor() == nil, "normalInput unfocused after outside click")

    print("✓ Refresh 2-digit counter, zero-jump Filter placeholder & click-outside unfocus passed")
}

@MainActor
private func testLogbookMultiRowSelectionAndSmartAutoScroll() throws {
    let win = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 700, height: 140),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    let console = MACLogbookConsoleContainerView(frame: NSRect(x: 0, y: 0, width: 700, height: 140))
    win.contentView = console
    console.layoutSubtreeIfNeeded()

    var entries: [MACLogbookConsoleEntry] = (1...30).map { i in
        MACLogbookConsoleEntry(
            id: UInt64(i),
            badgeLabel: "AGENT",
            badgeColor: .systemPurple,
            lineNumber: String(format: "%03d", i),
            workspaceName: "MAC OS",
            messageText: "Log row number \(i) — detailed telemetry output line",
            messageColor: .white
        )
    }

    var observedAutoScroll: Bool = true
    console.onAutoScrollChanged = { val in
        observedAutoScroll = val
    }

    console.updateContent(entries: entries, emptyMessage: "Empty", scrollTrigger: 0)
    console.layoutSubtreeIfNeeded()

    expect(console.textView.isSelectable && !console.textView.isEditable, "Logbook textView must be selectable and read-only")
    expect(console.isAutoScrollEnabled && observedAutoScroll, "Auto-scroll initially enabled at bottom")
    expect(console.isScrolledToBottom(), "Console initially scrolled to latest log at bottom")

    // Multi-row selection across multiple log rows
    let fullStr = console.textView.string as NSString
    let row1Range = fullStr.range(of: "Log row number 1")
    let row4Range = fullStr.range(of: "Log row number 4")
    expect(row1Range.location != NSNotFound && row4Range.location != NSNotFound, "Expected multiple rows rendered in single NSTextView")
    let multiRowSelection = NSRange(
        location: row1Range.location,
        length: (row4Range.location + row4Range.length) - row1Range.location
    )
    console.textView.setSelectedRange(multiRowSelection)
    let selectedSubstring = fullStr.substring(with: console.textView.selectedRange())
    expect(selectedSubstring.contains("Log row number 1") && selectedSubstring.contains("Log row number 4"), "Multi-row selection spans rows 1 through 4")

    // Simulate user scrolling UP -> autoScroll must disable immediately
    console.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 0))
    console.scrollView.reflectScrolledClipView(console.scrollView.contentView)
    console.handleUserScroll(scrollingDeltaY: 24.0)

    expect(!console.isAutoScrollEnabled && !observedAutoScroll, "Scrolling up must disable autoScroll")
    expect(!console.isScrolledToBottom(), "Console is no longer at bottom after scrolling up")

    // Append new logs while scrolled up -> must NOT auto-scroll to end, and must preserve multi-row selection
    entries.append(MACLogbookConsoleEntry(
        id: 31,
        badgeLabel: "TG",
        badgeColor: .systemCyan,
        lineNumber: "031",
        workspaceName: "MAC OS",
        messageText: "Newly arrived log line 31 while user is scrolled up",
        messageColor: .white
    ))
    console.updateContent(entries: entries, emptyMessage: "Empty", scrollTrigger: 0)
    expect(!console.isScrolledToBottom(), "Appending logs while scrolled up must NOT jump to bottom")
    expect(console.scrollView.contentView.bounds.origin.y == 0, "Scroll offset stays locked at top while scrolled up")
    expect(console.textView.selectedRange() == multiRowSelection, "Active multi-row selection preserved when new logs arrive")

    // Clicking "Latest" (incrementing scrollTrigger) -> enables autoScroll and scrolls to latest log
    console.updateContent(entries: entries, emptyMessage: "Empty", scrollTrigger: 1)
    expect(console.isAutoScrollEnabled && observedAutoScroll, "Clicking Latest re-enables autoScroll")
    expect(console.isScrolledToBottom(), "Clicking Latest scrolls console to latest log at bottom")

    print("✓ Logbook multi-row selection & smart auto-scroll behavior passed")
}

@MainActor
private func testWorkHistoryQueuedMessageEditAndDelete() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("mac-queue-edit-delete-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let ws = MACWorkspace(
        id: "mac-os",
        label: "MAC OS",
        path: "/tmp/mac-os",
        repos: []
    )

    // Write current test PID to bot.pid so MACWorkspaceTimelineQueueManager also verifies live queue-actions IPC files
    let pidPayload: [String: Any] = [
        "pid": Int(getpid()),
        "mode": "background",
        "startedAt": "2026-11-28T12:00:00Z"
    ]
    let pidData = try JSONSerialization.data(withJSONObject: pidPayload, options: [.prettyPrinted])
    try pidData.write(to: tempDir.appendingPathComponent("bot.pid"))

    let initialState: [String: Any] = [
        "workspaces": [
            "mac-os": [
                "phase": "RUNNING_AGENT",
                "isAgentRunning": true,
                "activeTurn": [
                    "id": "turn-active-1",
                    "prompt": "Currently running turn",
                    "user": "@tester",
                    "createdAt": "2026-11-28T12:00:00Z"
                ],
                "messageQueue": [
                    [
                        "id": "q_1",
                        "queueNumber": 1,
                        "text": "Queued task one original",
                        "user": "@tester",
                        "chatId": 12345,
                        "queueMessageId": 501,
                        "userMessageId": 500,
                        "queuedAt": "2026-11-28T12:01:00Z"
                    ],
                    [
                        "id": "q_2",
                        "queueNumber": 2,
                        "text": "Queued task two original",
                        "user": "@tester",
                        "chatId": 12345,
                        "queueMessageId": 503,
                        "userMessageId": 502,
                        "queuedAt": "2026-11-28T12:02:00Z"
                    ]
                ],
                "history": [
                    [
                        "id": "hist-1",
                        "prompt": "Completed historical task",
                        "user": "@tester",
                        "outcome": "CONFIRMED",
                        "createdAt": "2026-11-28T11:50:00Z",
                        "finishedAt": "2026-11-28T11:55:00Z"
                    ]
                ]
            ]
        ]
    ]
    let stateData = try JSONSerialization.data(withJSONObject: initialState, options: [.prettyPrinted])
    try stateData.write(to: tempDir.appendingPathComponent("state.json"))

    let vm = WorkspaceTimelineVM()
    vm.items = MACWorkspaceTimelineReader.loadTimeline(workspace: ws, dataDir: tempDir)
    expect(vm.items.count == 4, "Expected 2 queued + 1 working + 1 history item")

    // Verify ONLY queued items have isQueued == true (working & history items must NOT allow edit/delete)
    let workingItem = vm.items.first(where: { $0.id == "turn-active-1" })!
    let historyItem = vm.items.first(where: { $0.id == "hist-1" })!
    let q1Item = vm.items.first(where: { $0.id == "q_1" })!
    let q2Item = vm.items.first(where: { $0.id == "q_2" })!

    expect(q1Item.isQueued && q2Item.isQueued, "Queued items must report isQueued == true")
    expect(!workingItem.isQueued && !historyItem.isQueued, "Working and completed items must report isQueued == false")

    // Non-queued items must ignore edit/delete requests
    vm.beginEditingQueuedItem(workingItem)
    expect(vm.editingItemId == nil, "Must not enter edit mode for working item")
    expect(
        !vm.deleteQueuedItem(historyItem, workspace: ws, dataDir: tempDir, syncTelegramWhenBotStopped: false),
        "Must not delete completed history item"
    )

    // Edit queued message q_2 via VM
    vm.beginEditingQueuedItem(q2Item)
    expect(vm.editingItemId == "q_2", "Entered edit mode for q_2")
    expect(vm.editingDraftText == "Queued task two original", "Pre-populated draft text from q_2")
    vm.editingDraftText = "Queued task two UPDATED from Work History"
    let savedEdit = vm.saveEditedQueuedItem(workspace: ws, dataDir: tempDir, syncTelegramWhenBotStopped: false)
    expect(savedEdit, "Editing queued item q_2 must succeed")
    expect(vm.editingItemId == nil, "Edit mode exits cleanly after save")

    let updatedQ2 = vm.items.first(where: { $0.id == "q_2" })!
    expect(updatedQ2.message == "Queued task two UPDATED from Work History", "Updated message persisted in timeline")
    expect(updatedQ2.isEdited, "Edited queued item marks isEdited == true")

    // Delete queued message q_1 via VM -> q_2 must renumber from #2 to #1
    let deletedQ1 = vm.deleteQueuedItem(q1Item, workspace: ws, dataDir: tempDir, syncTelegramWhenBotStopped: false)
    expect(deletedQ1, "Deleting queued item q_1 must succeed")
    expect(!vm.items.contains(where: { $0.id == "q_1" }), "Deleted queued item q_1 removed from timeline")

    let renumberedQ2 = vm.items.first(where: { $0.id == "q_2" })!
    expect(renumberedQ2.status == .queued(1), "Remaining queued item q_2 renumbered to Queued (#1)")
    expect(renumberedQ2.resultLabel == "Queued (#1)", "Remaining queued item label updated to Queued (#1)")

    // Verify 2 IPC action files (edit + delete) were written to queue-actions/ for live bot sync
    let actionsDir = tempDir.appendingPathComponent("queue-actions", isDirectory: true)
    let actionFiles = (try? FileManager.default.contentsOfDirectory(atPath: actionsDir.path))?.filter { $0.hasSuffix(".json") } ?? []
    expect(actionFiles.count == 2, "Expected 2 queue-actions JSON files written for live bot sync")

    print("✓ Work History queued-only edit & delete with Telegram queue-actions sync passed")
}

@MainActor
private func testAutoSaveStatusPillAndAutoApproveCommitsPersistence() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("mac-autosave-autoapprove-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    // 1. Verify MACWorkspace.autoApproveCommits defaults to false and persists round-trip in config.json
    let defaultWs = MACWorkspace(id: "ws-default", label: "Default WS", path: "/tmp/ws-default")
    expect(defaultWs.autoApproveCommits == false, "autoApproveCommits must default to false")

    var autoWs = MACWorkspace(
        id: "ws-auto",
        label: "Auto WS",
        path: "/tmp/ws-auto",
        ciProvider: "jenkins",
        autoApproveCommits: true
    )
    expect(autoWs.autoApproveCommits == true, "autoApproveCommits initialized to true")

    let store = MACConfigFileStore(dataDir: tempDir)
    var cfg = store.load()
    cfg.workspaces = [defaultWs, autoWs]
    try store.save(cfg)

    let reloaded = store.load()
    expect(reloaded.workspaces.count == 2, "Expected 2 persisted workspaces")
    expect(reloaded.workspaces[0].autoApproveCommits == false, "First workspace autoApproveCommits == false")
    expect(reloaded.workspaces[1].autoApproveCommits == true, "Second workspace autoApproveCommits == true")

    autoWs.autoApproveCommits = false
    cfg.workspaces = [defaultWs, autoWs]
    try store.save(cfg)
    expect(store.load().workspaces[1].autoApproveCommits == false, "Toggling autoApproveCommits back to false persists")

    // 2. Verify MACAutoSaveStatusPill maintains constant width between .saving loader and .saved OK state
    let savingHost = NSHostingView(rootView: MACAutoSaveStatusPill(state: .saving))
    let savedHost = NSHostingView(rootView: MACAutoSaveStatusPill(state: .saved))
    let savingWidth = savingHost.fittingSize.width
    let savedWidth = savedHost.fittingSize.width
    expect(
        abs(savingWidth - savedWidth) < 0.5,
        "MACAutoSaveStatusPill width must not jump between .saving (\(savingWidth)) and .saved (\(savedWidth))"
    )

    print("✓ Auto-save loader-to-OK status pill & autoApproveCommits persistence passed")
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
            try testGitRemoteWebURLAndMultiJobMapping()
            try testConfigStoreRoundTrip()
            try testEngineModelFilteringAndEngineConfiguration()
            try testWorkspaceDetailTabsAndTimelineHistory()
            try testSleepPreventerAndLaunchAgent()
            try MainActor.assumeIsolated {
                try testConfigExportImportAndCrypto()
                try testMenuBarControllerAndBotLifecycle()
                try testAutoStartPersistenceAndBotWatchdogRecovery()
                try testResourceMonitorAndMetrics()
                try testFilterPlaceholderStabilityAndClickOutsideUnfocus()
                try testLogbookMultiRowSelectionAndSmartAutoScroll()
                try testWorkHistoryQueuedMessageEditAndDelete()
                try testAutoSaveStatusPillAndAutoApproveCommitsPersistence()
            }
            print("✅ All MAC macOS native app tests passed!")
        } catch {
            fputs("❌ Unexpected error in tests: \(error)\n", stderr)
            exit(1)
        }
    }
}
