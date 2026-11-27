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
        "Live Logs"
    ], "Expected 4 tabs in exact order: General, Workspaces, Tutorial, Live Logs")
    expect(appState.selectedTab == .general, "Expected General as default first tab")
    expect(controller.openAppMenuItem.title == "Open App", "Menu has Open App")
    expect(controller.startMenuItem.title == "Start...", "Menu has Start...")
    expect(controller.restartMenuItem.title == "Restart...", "Menu has Restart...")
    expect(controller.stopMenuItem.title == "Stop", "Menu has Stop")
    expect(controller.aboutMenuItem.title == "About", "Menu has About")
    expect(controller.startMenuItem.isEnabled && !controller.stopMenuItem.isEnabled, "Initial menu enabled state")
    expect(controller.effectiveActivationPolicy == .accessory, "Expected initial effectiveActivationPolicy == .accessory (no Dock icon)")
    expect(NSApp.activationPolicy() == .accessory, "Expected test runner NSApp.activationPolicy() == .accessory")

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

    print("✓ MACConfigCrypto AES-GCM encryption & decryption round trip passed")
}

private func testWorkspaceDetailTabsAndTimelineHistory() throws {
    // 1. Verify 2 tabs exist with Settings as default
    expect(WorkspaceDetailTab.allCases.map(\.rawValue) == ["Settings", "Work History"], "Expected 2 tabs: Settings and Work History")
    expect(WorkspaceDetailTab.settings.rawValue == "Settings", "Settings tab title")
    expect(WorkspaceDetailTab.history.rawValue == "Work History", "Work History tab title")

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
              "user": "@maksimsge",
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

    expect(items.count == 4, "Expected 4 timeline items (1 working + 1 queued + 2 history), got \\(items.count)")
    expect(items[0].status == .working, "First item is active working turn")
    expect(items[0].user == "@maksimsge", "User is @maksimsge")
    expect(items[0].message == "Fix payment expiration redirect bug", "Prompt matches")
    expect(items[0].files.contains("src/routes/payment.ts"), "Files extracted from commits")
    expect(items[0].resultLabel == "Working...", "Result label is Working...")

    expect(items[1].status == .queued(1), "Second item is queued #1")
    expect(items[1].message == "Update footer copyright year to 2026", "Queued prompt matches")

    expect(items[2].status == .success, "Third item is success")
    expect(items[2].resultLabel == "Success", "Third item result is Success")
    expect(items[2].elapsedTime == "2m 30s", "Elapsed time calculated accurately as 2m 30s, got \\(items[2].elapsedTime)")
    expect(items[2].files.count == 2, "Files count is 2")

    expect(items[3].status == .failed, "Fourth item is failed/reverted")
    expect(items[3].resultLabel == "Reverted", "Fourth item result is Reverted")

    print("✓ Workspace 2-tab layout (Settings & Work History) & Timeline history loader passed")
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

    // 2. Test Multi-Job mapping on MACRepo
    let repo = MACRepo(
        name: "test-repo",
        path: "/Users/test/code/test-repo",
        jenkinsJobs: ["Job/Staging/api", "Job/Staging/worker"],
        prodJenkinsJobs: ["Job/Prod/api", "Job/Prod/worker"]
    )
    expect(repo.jenkinsJobs.count == 2, "Expected 2 staging jobs")
    expect(repo.prodJenkinsJobs.count == 2, "Expected 2 prod jobs")
    expect(repo.jenkinsJob.contains("Job/Staging/api"), "jenkinsJob legacy string contains first job")
    expect(repo.deployEnabled == true, "Deploy enabled automatically when jobs present")

    // Test JSON roundtrip
    let encoder = JSONEncoder()
    let data = try encoder.encode(repo)
    let decoder = JSONDecoder()
    let decoded = try decoder.decode(MACRepo.self, from: data)
    expect(decoded.jenkinsJobs == ["Job/Staging/api", "Job/Staging/worker"], "Decoded jenkinsJobs match")
    expect(decoded.prodJenkinsJobs == ["Job/Prod/api", "Job/Prod/worker"], "Decoded prodJenkinsJobs match")

    print("✓ Git remote web URL conversion & multi-job repo mapping passed")
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
            try testConfigExportImportAndCrypto()
            try testWorkspaceDetailTabsAndTimelineHistory()
            try testSleepPreventerAndLaunchAgent()
            try MainActor.assumeIsolated {
                try testMenuBarControllerAndBotLifecycle()
                try testResourceMonitorAndMetrics()
            }
            print("✅ All MAC macOS native app tests passed!")
        } catch {
            fputs("❌ Unexpected error in tests: \(error)\n", stderr)
            exit(1)
        }
    }
}
