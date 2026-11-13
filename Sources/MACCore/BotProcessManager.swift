import Foundation
import Combine

public enum MACBotRunStatus: Equatable {
    case stopped
    case starting
    case running(botUsername: String?)
    case error(String)

    public var isRunningOrStarting: Bool {
        switch self {
        case .starting, .running:
            return true
        case .stopped, .error:
            return false
        }
    }

    public var statusMenuTitle: String {
        switch self {
        case .stopped:
            return "⚪ MAC — Stopped"
        case .starting:
            return "🟡 MAC — Starting..."
        case .running(let username):
            if let u = username, !u.isEmpty {
                return "🟢 Running (@\(u)) · Awake"
            }
            return "🟢 Running · Awake"
        case .error(let msg):
            let short = msg.count > 44 ? String(msg.prefix(44)) + "…" : msg
            return "🔴 Error: \(short)"
        }
    }
}

public enum MACSettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case workspaces = "Workspaces"
    case tutorial = "Tutorial"
    case liveActivity = "Live App Logs"

    public var id: String { rawValue }
}

@MainActor
public final class MACAppState: ObservableObject {
    @Published public var config: MACConfig
    @Published public var status: MACBotRunStatus = .stopped {
        didSet { onStateChanged?() }
    }
    @Published public var isSleepPrevented: Bool = false {
        didSet { onStateChanged?() }
    }
    @Published public var launchAtLogin: Bool = false {
        didSet { onStateChanged?() }
    }
    @Published public var selectedTab: MACSettingsTab = .general
    @Published public var selectedWorkspaceId: String?
    @Published public var logLines: [String] = []
    @Published public var statusBannerMessage: String?
    @Published public var activeStage: String = "Idle"
    @Published public var activeStageDetail: String = "Ready for Telegram requests"
    @Published public var isTaskRunning: Bool = false
    @Published public var activeWorkspaceName: String?
    @Published public var activeModelName: String?

    public let configStore: MACConfigFileStore
    public let runtimeRootURL: URL
    public let botScriptURL: URL
    public let sleepPreventer: SleepPreventer
    public let launchAtLoginManager: LaunchAtLoginManager

    public var onStateChanged: (() -> Void)?
    public var onRequestOpenSettings: ((MACSettingsTab) -> Void)?

    private var botProcess: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var currentProcessToken = UUID()

    public init(
        dataDir: URL? = nil,
        runtimeRootURL: URL? = nil,
        sleepPreventer: SleepPreventer = SleepPreventer(),
        launchAtLoginManager: LaunchAtLoginManager = LaunchAtLoginManager()
    ) {
        let resolved = Self.resolveRuntimeAndDataDirs(explicitDataDir: dataDir, explicitRuntimeRoot: runtimeRootURL)
        self.runtimeRootURL = resolved.runtimeRoot
        self.botScriptURL = resolved.botScript
        self.configStore = MACConfigFileStore(dataDir: resolved.dataDir)
        self.sleepPreventer = sleepPreventer
        self.launchAtLoginManager = launchAtLoginManager

        let loaded = self.configStore.load()
        self.config = loaded
        self.selectedWorkspaceId = loaded.workspaces.first?.id

        self.launchAtLoginManager.ensureDefaultEnabledOnFirstLaunch()
        self.launchAtLogin = self.launchAtLoginManager.isEnabled
    }

    public static func resolveRuntimeAndDataDirs(
        explicitDataDir: URL? = nil,
        explicitRuntimeRoot: URL? = nil
    ) -> (runtimeRoot: URL, botScript: URL, dataDir: URL) {
        let env = ProcessInfo.processInfo.environment
        let fm = FileManager.default

        var resolvedRuntime: URL? = explicitRuntimeRoot
        if resolvedRuntime == nil, let envRoot = env["MAC_RUNTIME_ROOT"], !envRoot.isEmpty {
            resolvedRuntime = URL(fileURLWithPath: envRoot, isDirectory: true)
        }

        // 1) Check if MAC.app sits directly inside the repo directory (<repo>/MAC.app)
        if resolvedRuntime == nil {
            let bundleParent = Bundle.main.bundleURL.deletingLastPathComponent()
            if fm.fileExists(atPath: bundleParent.appendingPathComponent("src/bot.mjs").path) {
                resolvedRuntime = bundleParent
            }
        }

        // 2) Check embedded runtime inside MAC.app/Contents/Resources/runtime/src/bot.mjs
        let embeddedRuntime = Bundle.main.resourceURL?.appendingPathComponent("runtime", isDirectory: true)
        let infoPlistProjectRoot = (Bundle.main.object(forInfoDictionaryKey: "MACDefaultProjectRoot") as? String)
            .map { URL(fileURLWithPath: $0, isDirectory: true) }

        if resolvedRuntime == nil {
            if let proj = infoPlistProjectRoot,
               fm.fileExists(atPath: proj.appendingPathComponent("src/bot.mjs").path) {
                resolvedRuntime = proj
            } else if let emb = embeddedRuntime,
                      fm.fileExists(atPath: emb.appendingPathComponent("src/bot.mjs").path) {
                resolvedRuntime = emb
            }
        }

        let finalRuntime = resolvedRuntime ?? URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        let finalBotScript = finalRuntime.appendingPathComponent("src/bot.mjs")

        var resolvedData: URL? = explicitDataDir
        if resolvedData == nil, let envData = env["MAC_DATA_DIR"], !envData.isEmpty {
            resolvedData = URL(fileURLWithPath: envData, isDirectory: true)
        }
        if resolvedData == nil {
            let bundleParentData = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("data", isDirectory: true)
            if fm.fileExists(atPath: bundleParentData.appendingPathComponent("config.json").path) {
                resolvedData = bundleParentData
            } else if let proj = infoPlistProjectRoot,
                      fm.fileExists(atPath: proj.appendingPathComponent("data/config.json").path) {
                resolvedData = proj.appendingPathComponent("data", isDirectory: true)
            } else {
                resolvedData = fm.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Support/MAC/data", isDirectory: true)
            }
        }

        return (finalRuntime, finalBotScript, resolvedData!)
    }

    public static func resolveNodeExecutable() -> String? {
        let env = ProcessInfo.processInfo.environment
        let fm = FileManager.default
        if let custom = env["MAC_NODE_BIN"], fm.isExecutableFile(atPath: custom) {
            return custom
        }

        var candidates = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/opt/local/bin/node",
            "/usr/bin/node"
        ]

        // Check ~/.nvm/versions/node/*/bin/node
        let nvmDir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".nvm/versions/node")
        if let versions = try? fm.contentsOfDirectory(atPath: nvmDir.path).sorted().reversed() {
            for v in versions {
                candidates.insert(nvmDir.appendingPathComponent("\(v)/bin/node").path, at: 0)
            }
        }

        for path in candidates where fm.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    public func reloadConfigFromDisk() {
        let fresh = configStore.load()
        self.config = fresh
        if let sel = selectedWorkspaceId, !fresh.workspaces.contains(where: { $0.id == sel }) {
            selectedWorkspaceId = fresh.workspaces.first?.id
        } else if selectedWorkspaceId == nil {
            selectedWorkspaceId = fresh.workspaces.first?.id
        }
    }

    @discardableResult
    public func saveConfigToDisk(_ updated: MACConfig? = nil, banner: String = "Saved configuration.") -> Bool {
        if let updated = updated {
            self.config = updated
        }
        do {
            try configStore.save(self.config)
            self.statusBannerMessage = "✅ \(banner)"
            return true
        } catch {
            self.statusBannerMessage = "❌ Failed to save config: \(error.localizedDescription)"
            return false
        }
    }

    public func toggleLaunchAtLogin(_ enabled: Bool) {
        do {
            try launchAtLoginManager.setEnabled(enabled)
            launchAtLogin = launchAtLoginManager.isEnabled
            statusBannerMessage = enabled
                ? "✅ MAC will start automatically when you log in to macOS."
                : "ℹ️ Disabled automatic launch at login."
        } catch {
            statusBannerMessage = "❌ Could not update Login Item: \(error.localizedDescription)"
            launchAtLogin = launchAtLoginManager.isEnabled
        }
    }

    public func startBot(sessionPassword: String) {
        let cleanPassword = sessionPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPassword.isEmpty else {
            status = .error("Session password cannot be empty.")
            return
        }

        reloadConfigFromDisk()
        if config.telegramBotToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            status = .error("Telegram Bot Token is not configured.")
            appendLog("[MAC] ⚠️ Set your Telegram Bot Token in General → Telegram before starting.")
            onRequestOpenSettings?(.general)
            return
        }

        guard let nodeBin = Self.resolveNodeExecutable() else {
            status = .error("Node.js 20+ not found on this Mac.")
            appendLog("[MAC] ❌ Node.js binary not found (/opt/homebrew/bin/node or /usr/local/bin/node).")
            return
        }

        guard FileManager.default.fileExists(atPath: botScriptURL.path) else {
            status = .error("Bot runtime script missing.")
            appendLog("[MAC] ❌ Missing runtime script at \(botScriptURL.path)")
            return
        }

        terminateRunningProcessSync()
        stopExternalOrphanBotProcesses()

        let token = UUID()
        currentProcessToken = token
        status = .starting
        appendLog("[MAC] 🚀 Starting Telegram Bot controller (Mac sleep prevention active)...")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: nodeBin)
        proc.arguments = [botScriptURL.path, "--data-dir", configStore.dataDir.path]
        proc.currentDirectoryURL = runtimeRootURL

        var childEnv = ProcessInfo.processInfo.environment
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        let extraPaths = [
            "\(homePath)/.local/bin",
            "\(homePath)/.gemini/bin",
            (nodeBin as NSString).deletingLastPathComponent,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        let existingPath = childEnv["PATH"] ?? ""
        let mergedPath = (extraPaths + existingPath.split(separator: ":").map(String.init))
            .reduce(into: [String]()) { acc, item in
                if !item.isEmpty && !acc.contains(item) { acc.append(item) }
            }
            .joined(separator: ":")

        childEnv["HOME"] = homePath
        childEnv["PATH"] = mergedPath
        childEnv["MAC_DATA_DIR"] = configStore.dataDir.path
        childEnv["GIT_TERMINAL_PROMPT"] = "0"
        if childEnv["SSH_AUTH_SOCK"] == nil, let sock = Self.queryLaunchctlEnv("SSH_AUTH_SOCK") {
            childEnv["SSH_AUTH_SOCK"] = sock
        }
        proc.environment = childEnv

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                self?.handleBotOutput(str, token: token)
            }
        }

        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                self?.handleBotOutput(str, token: token)
            }
        }

        proc.terminationHandler = { [weak self] finishedProc in
            Task { @MainActor [weak self] in
                guard let self = self, self.currentProcessToken == token else { return }
                self.cleanupPipes()
                self.botProcess = nil
                self.sleepPreventer.release()
                self.isSleepPrevented = false
                let code = finishedProc.terminationStatus
                if case .stopped = self.status {
                    return
                }
                if code == 0 || code == 15 || code == 2 {
                    self.status = .stopped
                    self.appendLog("[MAC] ⚪ Bot stopped.")
                } else {
                    self.status = .error("Exited with code \(code)")
                    self.appendLog("[MAC] ❌ Bot exited unexpectedly (code \(code)).")
                }
            }
        }

        do {
            try proc.run()
            self.botProcess = proc
            self.stdoutPipe = outPipe
            self.stderrPipe = errPipe

            if let pwData = "\(cleanPassword)\n".data(using: .utf8) {
                try? inPipe.fileHandleForWriting.write(contentsOf: pwData)
            }
            try? inPipe.fileHandleForWriting.close()

            self.isSleepPrevented = self.sleepPreventer.acquire(forPid: proc.processIdentifier)
        } catch {
            cleanupPipes()
            sleepPreventer.release()
            isSleepPrevented = false
            status = .error(error.localizedDescription)
            appendLog("[MAC] ❌ Failed to start bot: \(error.localizedDescription)")
        }
    }

    public func restartBot(sessionPassword: String) {
        appendLog("[MAC] 🔄 Restarting bot with new session password...")
        stopBot(silent: true)
        startBot(sessionPassword: sessionPassword)
    }

    public func stopBot(silent: Bool = false) {
        currentProcessToken = UUID()
        terminateRunningProcessSync()
        stopExternalOrphanBotProcesses()
        sleepPreventer.release()
        isSleepPrevented = false
        status = .stopped
        isTaskRunning = false
        activeStage = "Stopped"
        activeStageDetail = "Bot stopped"
        if !silent {
            appendLog("[MAC] ⏹ Bot stopped. Mac sleep allowed again.")
        }
    }

    private func terminateRunningProcessSync() {
        cleanupPipes()
        guard let proc = botProcess else { return }
        botProcess = nil
        if proc.isRunning {
            proc.terminate()
            let deadline = Date().addingTimeInterval(0.8)
            while proc.isRunning && Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
            }
        }
    }

    private func stopExternalOrphanBotProcesses() {
        // Check pidFile in dataDir first
        let pidFile = configStore.dataDir.appendingPathComponent("bot.pid")
        if let raw = try? Data(contentsOf: pidFile),
           let obj = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
           let oldPid = obj["pid"] as? Int32,
           oldPid > 0,
           oldPid != getpid() {
            kill(oldPid, SIGTERM)
        }
    }

    private func cleanupPipes() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        stderrPipe = nil
    }

    private func handleBotOutput(_ chunk: String, token: UUID) {
        guard token == currentProcessToken else { return }
        let lines = chunk.components(separatedBy: .newlines)
        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            // Strip raw password stars prompt noise
            if trimmed.contains("Enter session password for this bot run:") { continue }
            appendLog(rawLine)
            updateStageFromLogLine(rawLine)

            if let range = rawLine.range(of: #"Telegram Bot\s*:\s*@([A-Za-z0-9_]+)"#, options: .regularExpression) {
                let sub = String(rawLine[range])
                let username = sub.components(separatedBy: "@").last?.trimmingCharacters(in: .whitespaces)
                status = .running(botUsername: username)
            } else if rawLine.contains("Long-polling active") {
                if case .running = status {
                    // keep username
                } else {
                    status = .running(botUsername: nil)
                }
            } else if rawLine.contains("Fatal startup error:") {
                let reason = rawLine.components(separatedBy: "Fatal startup error:").last?.trimmingCharacters(in: .whitespaces) ?? "Startup failed"
                status = .error(reason)
            }
        }
    }

    public func appendLog(_ line: String) {
        logLines.append(line)
        if logLines.count > 400 {
            logLines.removeFirst(logLines.count - 400)
        }
    }

    public func clearLogs() {
        logLines.removeAll()
    }

    private func updateStageFromLogLine(_ line: String) {
        if line.contains("[stage]") {
            let stageText = line.replacingOccurrences(of: #".*\[stage\]\s*"#, with: "", options: .regularExpression)
            activeStage = stageText
            isTaskRunning = true
        } else if line.contains("[agent]") && (line.contains("Executing") || line.contains("Starting") || line.contains("Running")) {
            activeStage = "AI Agent Executing"
            isTaskRunning = true
            activeStageDetail = line.replacingOccurrences(of: #".*\[agent\]\s*"#, with: "", options: .regularExpression)
        } else if line.contains("[agent]") && line.contains("Tool execution:") {
            activeStage = "Executing AI Tools"
            isTaskRunning = true
            activeStageDetail = line.replacingOccurrences(of: #".*Tool execution:\s*"#, with: "", options: .regularExpression)
        } else if line.contains("[agent]") && (line.contains("completed") || line.contains("finished")) {
            activeStage = "Agent Turn Complete"
            isTaskRunning = false
            activeStageDetail = "Turn changes applied"
        } else if line.contains("[git]") && (line.contains("Staging") || line.contains("Created commit")) {
            activeStage = "Git Commit"
            isTaskRunning = true
            activeStageDetail = line.replacingOccurrences(of: #".*\[git\]\s*"#, with: "", options: .regularExpression)
        } else if line.contains("[git]") && line.contains("Pushing") {
            activeStage = "Git Push"
            isTaskRunning = true
            activeStageDetail = "Pushing changes to remote branch"
        } else if line.contains("[jenkins]") && (line.contains("Build triggered") || line.contains("in progress")) {
            activeStage = "Jenkins CI Deploying"
            isTaskRunning = true
            activeStageDetail = line.replacingOccurrences(of: #".*\[jenkins\]\s*"#, with: "", options: .regularExpression)
        } else if line.contains("[jenkins]") && (line.contains("SUCCESSFUL") || line.contains("SUCCESS")) {
            activeStage = "CI/CD Build Succeeded"
            isTaskRunning = false
            activeStageDetail = "Deployment complete"
        } else if line.contains("[jenkins]") && (line.contains("FAILED") || line.contains("FAILURE")) {
            activeStage = "CI/CD Build Failed"
            isTaskRunning = false
            activeStageDetail = "Build failed"
        } else if line.contains("Long-polling active") || line.contains("Telegram connection restored") {
            activeStage = "Ready & Polling Telegram"
            isTaskRunning = false
            activeStageDetail = "Listening for remote commands"
        } else if line.contains("[telegram] 📩 Received") {
            activeStage = "Processing Telegram Request"
            isTaskRunning = true
            activeStageDetail = line.replacingOccurrences(of: #".*\[telegram\]\s*"#, with: "", options: .regularExpression)
        } else if line.contains("[workspace] 📁 Workspace selected:") {
            let ws = line.replacingOccurrences(of: #".*Workspace selected:\s*"#, with: "", options: .regularExpression)
            activeWorkspaceName = ws
        }
    }

    private static func queryLaunchctlEnv(_ name: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = ["getenv", name]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let val = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return val.isEmpty ? nil : val
        } catch {
            return nil
        }
    }
}

