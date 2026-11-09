import AppKit
import Combine
import SwiftUI

// MARK: - Reusable Layout & Control Primitives (Zero AppKit Picker/GroupBox Glitches)

private struct MACSectionCard<Trailing: View, Content: View>: View {
    let title: String
    let systemImage: String
    let trailing: Trailing
    let content: Content

    init(
        title: String,
        systemImage: String,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.accentColor)
                Text(title)
                    .font(.system(size: 13.5, weight: .bold))
                Spacer(minLength: 8)
                trailing
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        )
    }
}

extension MACSectionCard where Trailing == EmptyView {
    init(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) {
        self.init(title: title, systemImage: systemImage, trailing: { EmptyView() }, content: content)
    }
}

private struct MACSegmentedOption<Value: Equatable>: Identifiable {
    let id: String
    let title: String
    let value: Value
}

private struct MACSegmentedPicker<Value: Equatable>: View {
    let options: [MACSegmentedOption<Value>]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 3) {
            ForEach(options) { option in
                let isSelected = (selection == option.value)
                Button {
                    selection = option.value
                } label: {
                    Text(option.title)
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                        .foregroundColor(isSelected ? .white : .primary)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isSelected ? Color.accentColor : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }
}

// MARK: - Root App Window View (4 Tabs: General, Workspaces, Tutorial, Live Bot Activity)

public struct MACSettingsRootView: View {
    @ObservedObject public var appState: MACAppState
    public var onStartRequested: () -> Void
    public var onRestartRequested: () -> Void
    public var onStopRequested: () -> Void

    public init(
        appState: MACAppState,
        onStartRequested: @escaping () -> Void,
        onRestartRequested: @escaping () -> Void,
        onStopRequested: @escaping () -> Void
    ) {
        self.appState = appState
        self.onStartRequested = onStartRequested
        self.onRestartRequested = onRestartRequested
        self.onStopRequested = onStopRequested
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            if let banner = appState.statusBannerMessage {
                HStack(spacing: 10) {
                    Text(banner)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(2)
                    Spacer()
                    Button("Dismiss") {
                        appState.statusBannerMessage = nil
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11.5, weight: .semibold))
                    .fixedSize()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.12))
                Divider()
            }

            tabNavigationBar
            Divider()

            Group {
                switch appState.selectedTab {
                case .general:
                    GeneralTabView(appState: appState)
                case .workspaces:
                    WorkspacesTabView(appState: appState)
                case .tutorial:
                    TutorialTabView(appState: appState)
                case .liveActivity:
                    LiveActivityTabView(appState: appState)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 920, minHeight: 640)
    }

    private var tabNavigationBar: some View {
        HStack(spacing: 6) {
            tabItemButton(.general, title: "General", icon: "gearshape.2.fill")
            tabItemButton(.workspaces, title: "Workspaces", icon: "folder.badge.gearshape")
            tabItemButton(.tutorial, title: "Tutorial", icon: "book.fill")
            tabItemButton(.liveActivity, title: "Live Bot Activity", icon: "terminal.fill")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.025))
    }

    private func tabItemButton(_ tab: MACSettingsTab, title: String, icon: String) -> some View {
        let isSelected = (appState.selectedTab == tab)
        return Button {
            appState.selectedTab = tab
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
            }
            .foregroundColor(isSelected ? .white : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.10), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("MAC — Mobile Agent Control")
                        .font(.system(size: 15, weight: .bold))
                        .fixedSize()
                    Text(appState.status.statusMenuTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(statusBadgeColor.opacity(0.16))
                        .cornerRadius(6)
                }
                Text("Data directory: \(appState.configStore.dataDir.path)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            HStack(spacing: 8) {
                if appState.status.isRunningOrStarting {
                    Button("Restart...") {
                        onRestartRequested()
                    }
                    .fixedSize()

                    Button("Stop") {
                        onStopRequested()
                    }
                    .tint(.red)
                    .fixedSize()
                } else {
                    Button("Start...") {
                        onStartRequested()
                    }
                    .buttonStyle(.borderedProminent)
                    .fixedSize()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var statusBadgeColor: Color {
        switch appState.status {
        case .running: return .green
        case .starting: return .orange
        case .stopped: return .secondary
        case .error: return .red
        }
    }
}

// MARK: - Tab 1: General (3 Sections: Jenkins / Telegram / AGY)

private final class GeneralTabVM: ObservableObject {
    // 1. Jenkins
    @Published var jenkinsDraft: MACJenkinsConfig = MACJenkinsConfig()
    @Published var showJenkinsToken: Bool = false
    @Published var timeoutMinutes: Int = 25
    @Published var isTestingJenkins: Bool = false
    @Published var jenkinsTestMessage: String?
    @Published var jenkinsTestSucceeded: Bool = false

    // 2. Telegram
    @Published var botToken: String = ""
    @Published var showBotToken: Bool = false
    @Published var telegramApiBaseUrl: String = "https://api.telegram.org"
    @Published var allowedUsersText: String = ""
    @Published var historyCount: Int = 20
    @Published var isVerifyingToken: Bool = false
    @Published var tokenCheckMessage: String?
    @Published var tokenCheckSucceeded: Bool = false

    // 3. AGY
    @Published var agyBinPath: String = ""
    @Published var defaultModelFamily: String = "gemini-3.8-flash"
    @Published var defaultModelLevel: String = "high"

    var effectiveDefaultModelId: String {
        MACModelOption.normalizeFamilyAndLevel(rawModel: defaultModelFamily, rawLevel: defaultModelLevel).modelId
    }

    var selectedDefaultModelLabel: String {
        MACModelOption.allOptions.first(where: { $0.id == defaultModelFamily })?.label ?? defaultModelFamily
    }
}

private struct GeneralTabView: View {
    @ObservedObject var appState: MACAppState
    @StateObject private var vm = GeneralTabVM()

    private var levelOptions: [MACSegmentedOption<String>] {
        MACModelOption.validLevels.map { MACSegmentedOption(id: $0, title: $0, value: $0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Section 1: Jenkins
                jenkinsSectionCard

                // Section 2: Telegram
                telegramSectionCard

                // Section 3: AGY
                agySectionCard

                // Unified Save Row
                HStack {
                    Spacer()
                    Button("Save General Settings") {
                        saveAllGeneralSettings()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .fixedSize()
                }
                .padding(.top, 2)
                .padding(.bottom, 10)
            }
            .padding(.trailing, 8)
        }
        .onAppear {
            loadFromAppState()
        }
    }

    private var jenkinsSectionCard: some View {
        MACSectionCard(title: "Jenkins", systemImage: "server.rack") {
            Button {
                runJenkinsConnectionTest()
            } label: {
                HStack(spacing: 5) {
                    if vm.isTestingJenkins {
                        ProgressView().controlSize(.small)
                        Text("Testing...")
                    } else {
                        Image(systemName: "network")
                        Text("Test Jenkins Connection")
                    }
                }
            }
            .controlSize(.small)
            .disabled(vm.isTestingJenkins || vm.jenkinsDraft.baseUrl.trimmingCharacters(in: .whitespaces).isEmpty)
            .fixedSize()
        } content: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Jenkins Base URL")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField(text: $vm.jenkinsDraft.baseUrl, prompt: Text(verbatim: "https://jenkins.example.com")) {}
                    .textFieldStyle(.roundedBorder)
            }

            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Jenkins Username")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("tech", text: $vm.jenkinsDraft.username)
                        .textFieldStyle(.roundedBorder)
                }
                .frame(width: 240, alignment: .leading)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Jenkins API Token")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    HStack(spacing: 8) {
                        if vm.showJenkinsToken {
                            TextField("API Token", text: $vm.jenkinsDraft.apiToken)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            SecureField("API Token", text: $vm.jenkinsDraft.apiToken)
                                .textFieldStyle(.roundedBorder)
                        }
                        Button(vm.showJenkinsToken ? "Hide" : "Show") {
                            vm.showJenkinsToken.toggle()
                        }
                        .fixedSize()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Default Job Folder Prefix (optional)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("Leave blank if jobs include full folder path", text: $vm.jenkinsDraft.jobPrefix)
                        .textFieldStyle(.roundedBorder)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Build Timeout")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    HStack(spacing: 8) {
                        Text("\(vm.timeoutMinutes) min")
                            .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                            .frame(width: 62, alignment: .leading)
                        Stepper("", value: $vm.timeoutMinutes, in: 5...120, step: 5)
                            .labelsHidden()
                            .fixedSize()
                    }
                    .padding(.vertical, 2)
                }
                .frame(width: 140, alignment: .leading)
            }

            Toggle("Allow self-signed / insecure TLS certificates", isOn: $vm.jenkinsDraft.insecureTls)

            if let msg = vm.jenkinsTestMessage {
                HStack(spacing: 8) {
                    Image(systemName: vm.jenkinsTestSucceeded ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(vm.jenkinsTestSucceeded ? .green : .red)
                    Text(msg)
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background((vm.jenkinsTestSucceeded ? Color.green : Color.red).opacity(0.12))
                .cornerRadius(6)
            }
        }
    }

    private var telegramSectionCard: some View {
        MACSectionCard(title: "Telegram", systemImage: "paperplane.fill") {
            Button("How to get Token & User ID? Open Tutorial →") {
                appState.selectedTab = .tutorial
            }
            .buttonStyle(.link)
            .font(.system(size: 12, weight: .semibold))
            .fixedSize()
        } content: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Telegram Bot Token (@BotFather)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack(spacing: 8) {
                    if vm.showBotToken {
                        TextField("123456:ABC-DEF...", text: $vm.botToken)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("123456:ABC-DEF...", text: $vm.botToken)
                            .textFieldStyle(.roundedBorder)
                    }
                    Button(vm.showBotToken ? "Hide" : "Show") {
                        vm.showBotToken.toggle()
                    }
                    .fixedSize()

                    Button {
                        verifyBotToken()
                    } label: {
                        HStack(spacing: 5) {
                            if vm.isVerifyingToken {
                                ProgressView().controlSize(.small)
                                Text("Verifying...")
                            } else {
                                Image(systemName: "checkmark.shield")
                                Text("Verify Token")
                            }
                        }
                    }
                    .disabled(vm.isVerifyingToken || vm.botToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .fixedSize()
                }
            }

            if let msg = vm.tokenCheckMessage {
                HStack(spacing: 8) {
                    Image(systemName: vm.tokenCheckSucceeded ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(vm.tokenCheckSucceeded ? .green : .red)
                    Text(msg)
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background((vm.tokenCheckSucceeded ? Color.green : Color.red).opacity(0.12))
                .cornerRadius(6)
            }

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Allowed Telegram User IDs (comma-separated numeric IDs, blank = anyone with session password)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("e.g. 652545688", text: $vm.allowedUsersText)
                        .textFieldStyle(.roundedBorder)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Latest Messages (X)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    HStack(spacing: 8) {
                        Text("\(vm.historyCount) msgs")
                            .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                            .frame(width: 64, alignment: .leading)
                        Stepper("", value: $vm.historyCount, in: 1...50)
                            .labelsHidden()
                            .fixedSize()
                    }
                    .padding(.vertical, 2)
                }
                .frame(width: 145, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Telegram API Base URL")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField(text: $vm.telegramApiBaseUrl, prompt: Text(verbatim: "https://api.telegram.org")) {}
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var agySectionCard: some View {
        MACSectionCard(title: "AGY", systemImage: "cpu.fill") {
            HStack(spacing: 6) {
                Text("Default CLI ID:")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Text(vm.effectiveDefaultModelId)
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.14))
                    .cornerRadius(5)
            }
            .fixedSize()
        } content: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Antigravity CLI Binary Path (agy)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack(spacing: 8) {
                    TextField("/Users/you/.local/bin/agy", text: $vm.agyBinPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse...") {
                        if let chosen = chooseExecutableFile(initialPath: vm.agyBinPath) {
                            vm.agyBinPath = chosen
                        }
                    }
                    .fixedSize()
                }
            }

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Default AI Model Family (for new Workspaces)")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Menu {
                        ForEach(MACModelOption.allOptions) { opt in
                            Button {
                                vm.defaultModelFamily = opt.id
                            } label: {
                                if vm.defaultModelFamily == opt.id {
                                    Label(opt.label, systemImage: "checkmark")
                                } else {
                                    Text(opt.label)
                                }
                            }
                        }
                    } label: {
                        HStack {
                            Text(vm.selectedDefaultModelLabel)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.primary.opacity(0.07))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(Color.primary.opacity(0.14), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Default Effort Level")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    MACSegmentedPicker(options: levelOptions, selection: $vm.defaultModelLevel)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack(spacing: 16) {
                Toggle(
                    "Start mac.app automatically when macOS starts (Login Item)",
                    isOn: Binding(
                        get: { appState.launchAtLogin },
                        set: { appState.toggleLaunchAtLogin($0) }
                    )
                )

                Spacer()

                HStack(spacing: 6) {
                    Image(systemName: appState.isSleepPrevented ? "bolt.fill" : "powersleep")
                        .foregroundColor(appState.isSleepPrevented ? .green : .secondary)
                    Text(appState.isSleepPrevented ? "Mac Sleep Prevented (Active)" : "Sleep Prevention Standby")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(appState.isSleepPrevented ? .primary : .secondary)
                }
                .fixedSize()
            }
        }
    }

    private func loadFromAppState() {
        vm.jenkinsDraft = appState.config.jenkins
        vm.timeoutMinutes = max(5, vm.jenkinsDraft.buildTimeoutMs / 60_000)

        vm.botToken = appState.config.telegramBotToken
        vm.telegramApiBaseUrl = appState.config.telegramApiBaseUrl
        vm.allowedUsersText = appState.config.allowedUserIds.joined(separator: ", ")
        vm.historyCount = appState.config.defaultHistoryCount

        vm.agyBinPath = appState.config.agyBin
        let norm = MACModelOption.normalizeFamilyAndLevel(
            rawModel: appState.config.defaultModel,
            rawLevel: appState.config.defaultModelLevel
        )
        vm.defaultModelFamily = MACModelOption.allOptions.contains(where: { $0.id == norm.family }) ? norm.family : "gemini-3.8-flash"
        vm.defaultModelLevel = norm.level
    }

    private func saveAllGeneralSettings() {
        var updatedJenkins = vm.jenkinsDraft
        updatedJenkins.baseUrl = updatedJenkins.baseUrl
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        updatedJenkins.username = updatedJenkins.username.trimmingCharacters(in: .whitespacesAndNewlines)
        updatedJenkins.apiToken = updatedJenkins.apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        updatedJenkins.buildTimeoutMs = vm.timeoutMinutes * 60 * 1000
        appState.config.jenkins = updatedJenkins

        appState.config.telegramBotToken = vm.botToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanBaseUrl = vm.telegramApiBaseUrl
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        appState.config.telegramApiBaseUrl = cleanBaseUrl.isEmpty ? "https://api.telegram.org" : cleanBaseUrl
        appState.config.allowedUserIds = vm.allowedUsersText
            .components(separatedBy: CharacterSet(charactersIn: ", \n\t"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        appState.config.defaultHistoryCount = vm.historyCount

        let cleanAgy = MACPathUtils.expandPath(vm.agyBinPath)
        if !cleanAgy.isEmpty {
            appState.config.agyBin = cleanAgy
            vm.agyBinPath = cleanAgy
        }
        let normModel = MACModelOption.normalizeFamilyAndLevel(
            rawModel: vm.defaultModelFamily,
            rawLevel: vm.defaultModelLevel
        )
        appState.config.defaultModel = normModel.modelId
        appState.config.defaultModelLevel = normModel.level

        appState.saveConfigToDisk(banner: "Saved General settings (Jenkins, Telegram & AGY).")
    }

    private func runJenkinsConnectionTest() {
        vm.isTestingJenkins = true
        vm.jenkinsTestMessage = nil
        let snapshot = vm.jenkinsDraft
        let viewModel = vm
        Task {
            let res = await JenkinsConnectionTester.testConnection(config: snapshot)
            await MainActor.run {
                viewModel.isTestingJenkins = false
                switch res {
                case .success(let info):
                    viewModel.jenkinsTestSucceeded = true
                    viewModel.jenkinsTestMessage = info
                case .failure(let err):
                    viewModel.jenkinsTestSucceeded = false
                    viewModel.jenkinsTestMessage = err.localizedDescription
                }
            }
        }
    }

    private func verifyBotToken() {
        vm.isVerifyingToken = true
        vm.tokenCheckMessage = nil
        let tokenSnapshot = vm.botToken
        let baseUrlSnapshot = vm.telegramApiBaseUrl
        let viewModel = vm
        Task {
            let res = await TelegramTokenTester.verifyToken(token: tokenSnapshot, apiBaseUrl: baseUrlSnapshot)
            await MainActor.run {
                viewModel.isVerifyingToken = false
                switch res {
                case .success(let msg):
                    viewModel.tokenCheckSucceeded = true
                    viewModel.tokenCheckMessage = msg
                case .failure(let err):
                    viewModel.tokenCheckSucceeded = false
                    viewModel.tokenCheckMessage = err.localizedDescription
                }
            }
        }
    }

    private func chooseExecutableFile(initialPath: String) -> String? {
        let panel = NSOpenPanel()
        panel.level = .modalPanel
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select agy Binary"
        let expanded = MACPathUtils.expandPath(initialPath)
        if !expanded.isEmpty {
            let parent = URL(fileURLWithPath: expanded).deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: parent.path) {
                panel.directoryURL = parent
            }
        }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

// MARK: - Tab 2: Workspaces (Combined Manage + Inline '+' Empty Record Creation)

private struct WorkspaceSidebarEntry: Identifiable, Equatable {
    let uid: UUID
    var isNewUnsaved: Bool
    var originalSavedId: String?
    var draft: MACWorkspace

    var id: UUID { uid }
}

private final class WorkspacesTabVM: ObservableObject {
    @Published var entries: [WorkspaceSidebarEntry] = []
    @Published var selectedUID: UUID?
    private var didBootstrap: Bool = false

    func syncFromConfig(_ config: MACConfig, preferredWorkspaceId: String?) {
        let unsavedEntries = entries.filter { $0.isNewUnsaved }
        var rebuilt: [WorkspaceSidebarEntry] = config.workspaces.map { ws in
            if let existing = entries.first(where: { !$0.isNewUnsaved && $0.originalSavedId == ws.id }) {
                return WorkspaceSidebarEntry(
                    uid: existing.uid,
                    isNewUnsaved: false,
                    originalSavedId: ws.id,
                    draft: didBootstrap ? existing.draft : ws
                )
            }
            return WorkspaceSidebarEntry(uid: UUID(), isNewUnsaved: false, originalSavedId: ws.id, draft: ws)
        }
        rebuilt.append(contentsOf: unsavedEntries)
        entries = rebuilt
        didBootstrap = true

        if let sel = selectedUID, entries.contains(where: { $0.uid == sel }) {
            return
        }
        if let prefId = preferredWorkspaceId,
           let match = entries.first(where: { !$0.isNewUnsaved && $0.originalSavedId == prefId }) {
            selectedUID = match.uid
        } else {
            selectedUID = entries.first?.uid
        }
    }

    @discardableResult
    func addBlankWorkspaceEntry(defaultModel: String, defaultLevel: String) -> UUID {
        let norm = MACModelOption.normalizeFamilyAndLevel(rawModel: defaultModel, rawLevel: defaultLevel)
        let blank = MACWorkspace(
            id: "",
            label: "",
            path: "",
            extraDirs: [],
            liveUrl: "",
            model: norm.modelId,
            modelLevel: norm.level,
            environmentMode: "single",
            jenkinsJobs: [],
            prodJenkinsJobs: [],
            repos: []
        )
        let newEntry = WorkspaceSidebarEntry(
            uid: UUID(),
            isNewUnsaved: true,
            originalSavedId: nil,
            draft: blank
        )
        entries.append(newEntry)
        selectedUID = newEntry.uid
        return newEntry.uid
    }
}

private struct WorkspacesTabView: View {
    @ObservedObject var appState: MACAppState
    @StateObject private var vm = WorkspacesTabVM()

    private var selectedIndex: Int? {
        guard let sel = vm.selectedUID else { return nil }
        return vm.entries.firstIndex(where: { $0.uid == sel })
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Left Sidebar: Saved Workspaces + Any Newly Added (+) Empty Record(s)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("Workspaces (\(vm.entries.count))")
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button {
                        _ = vm.addBlankWorkspaceEntry(
                            defaultModel: appState.config.defaultModel,
                            defaultLevel: appState.config.defaultModelLevel
                        )
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 12.5, weight: .bold))
                            .frame(width: 26, height: 22)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("Add new Workspace")
                    .fixedSize()
                }
                .padding(.horizontal, 6)
                .padding(.top, 2)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(vm.entries) { entry in
                                sidebarCard(for: entry)
                                    .id(entry.uid)
                            }
                        }
                        .padding(.horizontal, 4)
                        .padding(.bottom, 8)
                    }
                    .onChange(of: vm.entries.count) { _, _ in
                        if let sel = vm.selectedUID {
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo(sel, anchor: .bottom)
                            }
                        }
                    }
                }
            }
            .frame(width: 255)
            .frame(maxHeight: .infinity)
            .padding(.trailing, 10)

            Divider()

            // Right Detail Editor (Same Form for Editing & Newly Added '+' Empty Record)
            Group {
                if let idx = selectedIndex {
                    let entry = vm.entries[idx]
                    WorkspaceEditorFormView(
                        draft: $vm.entries[idx].draft,
                        isNewWorkspace: entry.isNewUnsaved,
                        onSave: {
                            saveWorkspaceEntry(at: idx)
                        },
                        onDelete: {
                            deleteWorkspaceEntry(uid: entry.uid)
                        }
                    )
                    .id(entry.uid)
                    .padding(.leading, 14)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 36))
                            .foregroundColor(.secondary)
                        Text("No Workspaces Configured Yet")
                            .font(.headline)
                        Text("Click '+' to add a new Workspace record and configure its folder path, AI model, and Jenkins jobs.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 360)
                        Button {
                            _ = vm.addBlankWorkspaceEntry(
                                defaultModel: appState.config.defaultModel,
                                defaultLevel: appState.config.defaultModelLevel
                            )
                        } label: {
                            Label("Add Workspace", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .fixedSize()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            vm.syncFromConfig(appState.config, preferredWorkspaceId: appState.selectedWorkspaceId)
        }
    }

    private func sidebarCard(for entry: WorkspaceSidebarEntry) -> some View {
        let isSelected = (vm.selectedUID == entry.uid)
        let trimmedLabel = entry.draft.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPath = entry.draft.path.trimmingCharacters(in: .whitespacesAndNewlines)
        let isLabelEmpty = trimmedLabel.isEmpty
        let isPathEmpty = trimmedPath.isEmpty

        let badgeText: String = {
            if entry.isNewUnsaved && isLabelEmpty && isPathEmpty {
                return "New"
            }
            return entry.draft.environmentMode == "multi" ? "Multi" : "Single"
        }()

        let badgeTint: Color = {
            if entry.isNewUnsaved && isLabelEmpty && isPathEmpty {
                return .orange
            }
            return entry.draft.environmentMode == "multi" ? .purple : .blue
        }()

        return Button {
            vm.selectedUID = entry.uid
            if let savedId = entry.originalSavedId {
                appState.selectedWorkspaceId = savedId
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(isLabelEmpty ? "New Workspace (empty)" : trimmedLabel)
                        .font(.system(size: 13, weight: isLabelEmpty ? .medium : .bold))
                        .italic(isLabelEmpty)
                        .foregroundColor(
                            isSelected
                                ? (isLabelEmpty ? Color.white.opacity(0.85) : .white)
                                : (isLabelEmpty ? .secondary : .primary)
                        )
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    Text(badgeText)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(isSelected ? .white : badgeTint)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(isSelected ? Color.white.opacity(0.22) : badgeTint.opacity(0.16))
                        )
                        .fixedSize()
                }

                Text(entry.draft.displayModelSummary)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isSelected ? Color.white.opacity(0.88) : .secondary)
                    .lineLimit(1)

                Text(isPathEmpty ? "No folder path entered yet" : trimmedPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(isSelected ? Color.white.opacity(0.75) : .secondary.opacity(isPathEmpty ? 0.75 : 1.0))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        isSelected
                            ? Color.accentColor
                            : (entry.isNewUnsaved ? Color.orange.opacity(0.45) : Color.primary.opacity(0.09)),
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func saveWorkspaceEntry(at idx: Int) {
        guard vm.entries.indices.contains(idx) else { return }
        var normalized = vm.entries[idx].draft
        let wasNewUnsaved = vm.entries[idx].isNewUnsaved
        let originalId = vm.entries[idx].originalSavedId

        normalized.label = normalized.label.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.path = MACPathUtils.expandPath(normalized.path)

        let rawSlug = MACPathUtils.slugifyWorkspaceId(
            normalized.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? normalized.label : normalized.id
        )
        var uniqueId = rawSlug
        var counter = 2
        while appState.config.workspaces.contains(where: { $0.id == uniqueId && $0.id != originalId }) {
            uniqueId = "\(rawSlug)-\(counter)"
            counter += 1
        }
        normalized.id = uniqueId

        if normalized.repos.isEmpty {
            normalized.repos = MACPathUtils.discoverGitRepos(
                at: normalized.path,
                existingRepos: [],
                stagingJobs: normalized.jenkinsJobs,
                prodJobs: normalized.prodJenkinsJobs
            )
        }
        for repo in normalized.repos where repo.deployEnabled {
            let j = repo.jenkinsJob.trimmingCharacters(in: .whitespacesAndNewlines)
            if !j.isEmpty && !normalized.jenkinsJobs.contains(j) {
                normalized.jenkinsJobs.append(j)
            }
            if normalized.environmentMode == "multi" {
                let pj = repo.prodJenkinsJob.trimmingCharacters(in: .whitespacesAndNewlines)
                if !pj.isEmpty && !normalized.prodJenkinsJobs.contains(pj) {
                    normalized.prodJenkinsJobs.append(pj)
                }
            }
        }

        if wasNewUnsaved {
            appState.config.workspaces.append(normalized)
        } else if let origId = originalId,
                  let configIdx = appState.config.workspaces.firstIndex(where: { $0.id == origId }) {
            appState.config.workspaces[configIdx] = normalized
        } else {
            appState.config.workspaces.append(normalized)
        }

        vm.entries[idx].draft = normalized
        vm.entries[idx].isNewUnsaved = false
        vm.entries[idx].originalSavedId = normalized.id
        appState.selectedWorkspaceId = normalized.id

        let bannerMsg = wasNewUnsaved
            ? "Added workspace '\(normalized.label)' — ready in Telegram!"
            : "Saved workspace '\(normalized.label)' (immediately active in Telegram)."
        appState.saveConfigToDisk(banner: bannerMsg)
    }

    private func deleteWorkspaceEntry(uid: UUID) {
        guard let idx = vm.entries.firstIndex(where: { $0.uid == uid }) else { return }
        let target = vm.entries[idx]
        vm.entries.remove(at: idx)

        if !target.isNewUnsaved, let origId = target.originalSavedId {
            let removedLabel = target.draft.label.isEmpty ? origId : target.draft.label
            appState.config.workspaces.removeAll { $0.id == origId }
            appState.selectedWorkspaceId = appState.config.workspaces.first?.id
            appState.saveConfigToDisk(banner: "Removed workspace '\(removedLabel)'.")
        }

        if vm.entries.indices.contains(idx) {
            vm.selectedUID = vm.entries[idx].uid
        } else {
            vm.selectedUID = vm.entries.last?.uid
        }
        if let sel = vm.selectedUID,
           let selEntry = vm.entries.first(where: { $0.uid == sel }),
           let savedId = selEntry.originalSavedId {
            appState.selectedWorkspaceId = savedId
        }
    }
}

// MARK: - Shared Workspace Editor Form

private final class WorkspaceEditorFormVM: ObservableObject {
    @Published var selectedModelFamily: String = "gemini-3.8-flash"
    @Published var selectedModelLevel: String = "high"
    @Published var stagingJobInput: String = ""
    @Published var prodJobInput: String = ""
    @Published var extraDirInput: String = ""
    @Published var showDeleteConfirm: Bool = false
}

private struct WorkspaceEditorFormView: View {
    @Binding var draft: MACWorkspace
    let isNewWorkspace: Bool
    let onSave: () -> Void
    let onDelete: (() -> Void)?

    @StateObject private var vm = WorkspaceEditorFormVM()

    private var selectedModelDisplayTitle: String {
        MACModelOption.allOptions.first(where: { $0.id == vm.selectedModelFamily })?.label ?? vm.selectedModelFamily
    }

    private var levelOptions: [MACSegmentedOption<String>] {
        MACModelOption.validLevels.map { MACSegmentedOption(id: $0, title: $0, value: $0) }
    }

    private var envModeOptions: [MACSegmentedOption<String>] {
        [
            MACSegmentedOption(id: "single", title: "Single (Staging / Default)", value: "single"),
            MACSegmentedOption(id: "multi", title: "Multi (Staging → Production)", value: "multi")
        ]
    }

    private var isCompletelyEmptyUnsaved: Bool {
        isNewWorkspace
            && draft.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draft.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // 1. Identity & Paths
                MACSectionCard(title: "Workspace Name & Paths", systemImage: "folder.fill") {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Workspace Label (shown in Telegram)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField("e.g. CRYPTO FUSION", text: $draft.label)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: draft.label) { _, newVal in
                                    if isNewWorkspace {
                                        let trimmed = newVal.trimmingCharacters(in: .whitespacesAndNewlines)
                                        draft.id = trimmed.isEmpty ? "" : MACPathUtils.slugifyWorkspaceId(trimmed)
                                    }
                                }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Workspace ID")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField("e.g. crypto-fusion", text: $draft.id)
                                .textFieldStyle(.roundedBorder)
                        }
                        .frame(width: 190, alignment: .leading)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Workspace Root Folder Path")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        HStack(spacing: 8) {
                            TextField("/Users/you/code/my-workspace", text: $draft.path)
                                .textFieldStyle(.roundedBorder)
                            Button("Browse...") {
                                if let chosen = chooseDirectory(initialPath: draft.path) {
                                    draft.path = chosen
                                    if draft.label.trimmingCharacters(in: .whitespaces).isEmpty {
                                        let base = URL(fileURLWithPath: chosen).lastPathComponent
                                        draft.label = base.uppercased()
                                        if isNewWorkspace {
                                            draft.id = MACPathUtils.slugifyWorkspaceId(base)
                                        }
                                    }
                                    rescanRepos()
                                }
                            }
                            .fixedSize()

                            Button("Scan Git Repos") {
                                rescanRepos()
                            }
                            .fixedSize()
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Extra Allowed Paths (--add-dir, optional)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        if !draft.extraDirs.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(draft.extraDirs.enumerated()), id: \.offset) { idx, dirPath in
                                    HStack(spacing: 8) {
                                        Image(systemName: "folder")
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                        Text(dirPath)
                                            .font(.system(size: 12, design: .monospaced))
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer()
                                        Button(role: .destructive) {
                                            draft.extraDirs.remove(at: idx)
                                        } label: {
                                            Image(systemName: "minus.circle.fill")
                                        }
                                        .buttonStyle(.borderless)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.primary.opacity(0.04))
                                    .cornerRadius(6)
                                }
                            }
                        }
                        HStack(spacing: 8) {
                            TextField("Optional extra folder path...", text: $vm.extraDirInput)
                                .textFieldStyle(.roundedBorder)
                            Button("Add Path") {
                                let p = MACPathUtils.expandPath(vm.extraDirInput)
                                if !p.isEmpty && !draft.extraDirs.contains(p) {
                                    draft.extraDirs.append(p)
                                }
                                vm.extraDirInput = ""
                            }
                            .disabled(vm.extraDirInput.trimmingCharacters(in: .whitespaces).isEmpty)
                            .fixedSize()

                            Button("Browse Extra...") {
                                if let chosen = chooseDirectory(initialPath: draft.path) {
                                    if !draft.extraDirs.contains(chosen) {
                                        draft.extraDirs.append(chosen)
                                    }
                                }
                            }
                            .fixedSize()
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Live Staging URL (optional, shown after Jenkins build)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField(text: $draft.liveUrl, prompt: Text(verbatim: "https://staging.example.com")) {}
                            .textFieldStyle(.roundedBorder)
                    }
                }

                // 2. AI Model & Effort Level
                MACSectionCard(title: "AI Model & Effort Level", systemImage: "brain") {
                    HStack(spacing: 6) {
                        Text("CLI ID:")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                        Text(draft.model)
                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.14))
                            .cornerRadius(5)
                    }
                    .fixedSize()
                } content: {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("AI Model Family")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Menu {
                                ForEach(MACModelOption.allOptions) { opt in
                                    Button {
                                        vm.selectedModelFamily = opt.id
                                        syncModelFields()
                                    } label: {
                                        if vm.selectedModelFamily == opt.id {
                                            Label(opt.label, systemImage: "checkmark")
                                        } else {
                                            Text(opt.label)
                                        }
                                    }
                                }
                            } label: {
                                HStack {
                                    Text(selectedModelDisplayTitle)
                                        .font(.system(size: 12.5, weight: .medium))
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                    Spacer()
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(.secondary)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(Color.primary.opacity(0.07))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .stroke(Color.primary.opacity(0.14), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Effort Level")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            MACSegmentedPicker(options: levelOptions, selection: $vm.selectedModelLevel)
                                .onChange(of: vm.selectedModelLevel) { _, _ in
                                    syncModelFields()
                                }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                // 3. Environments & Jenkins Jobs
                MACSectionCard(title: "Environments & Jenkins CI/CD Jobs", systemImage: "shippingbox.fill") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Environment Mode")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        MACSegmentedPicker(options: envModeOptions, selection: $draft.environmentMode)
                            .frame(maxWidth: 440, alignment: .leading)
                    }

                    Divider()

                    // Staging Jenkins Jobs
                    VStack(alignment: .leading, spacing: 6) {
                        Text(draft.environmentMode == "multi" ? "Staging Jenkins Jobs" : "Jenkins Jobs (Staging / Default)")
                            .font(.system(size: 12.5, weight: .semibold))

                        if !draft.jenkinsJobs.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(draft.jenkinsJobs.enumerated()), id: \.offset) { idx, job in
                                    HStack(spacing: 8) {
                                        Image(systemName: "hammer.fill")
                                            .font(.system(size: 11))
                                            .foregroundColor(.accentColor)
                                        Text(job)
                                            .font(.system(size: 12, design: .monospaced))
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer()
                                        Button(role: .destructive) {
                                            draft.jenkinsJobs.remove(at: idx)
                                        } label: {
                                            Image(systemName: "minus.circle.fill")
                                        }
                                        .buttonStyle(.borderless)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.primary.opacity(0.04))
                                    .cornerRadius(6)
                                }
                            }
                        }

                        HStack(spacing: 8) {
                            TextField("Job path, URL, or comma list e.g. 'HS-1/app/api', 'HS-1/app/web'", text: $vm.stagingJobInput)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { addStagingJobsFromInput() }
                            Button("Add Staging Job(s)") {
                                addStagingJobsFromInput()
                            }
                            .disabled(vm.stagingJobInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .fixedSize()
                        }
                    }

                    // Production Jenkins Jobs (Multi mode)
                    if draft.environmentMode == "multi" {
                        Divider()
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Production Jenkins Jobs (triggered on '🚀 Yes, deploy on prod')")
                                .font(.system(size: 12.5, weight: .semibold))

                            if !draft.prodJenkinsJobs.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(Array(draft.prodJenkinsJobs.enumerated()), id: \.offset) { idx, job in
                                        HStack(spacing: 8) {
                                            Image(systemName: "bolt.horizontal.circle.fill")
                                                .font(.system(size: 11))
                                                .foregroundColor(.purple)
                                            Text(job)
                                                .font(.system(size: 12, design: .monospaced))
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                            Spacer()
                                            Button(role: .destructive) {
                                                draft.prodJenkinsJobs.remove(at: idx)
                                            } label: {
                                                Image(systemName: "minus.circle.fill")
                                            }
                                            .buttonStyle(.borderless)
                                        }
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.primary.opacity(0.04))
                                        .cornerRadius(6)
                                    }
                                }
                            }

                            HStack(spacing: 8) {
                                TextField("Prod job path, URL, or comma list e.g. 'PROD/app/api', 'PROD/app/web'", text: $vm.prodJobInput)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit { addProdJobsFromInput() }
                                Button("Add Prod Job(s)") {
                                    addProdJobsFromInput()
                                }
                                .disabled(vm.prodJobInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                .fixedSize()
                            }
                        }
                    }
                }

                // 4. Per-Repository Mapping
                MACSectionCard(title: "Git Repositories in Workspace (\(draft.repos.count))", systemImage: "point.3.connected.trianglepath.dotted") {
                    Button("Re-Scan Folder") {
                        rescanRepos()
                    }
                    .controlSize(.small)
                    .disabled(draft.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .fixedSize()
                } content: {
                    if draft.repos.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle")
                                .foregroundColor(.secondary)
                            Text("No Git repositories scanned yet. Pick a Workspace Root Folder Path above and click 'Scan Git Repos'.")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach($draft.repos) { $repo in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 10) {
                                        Toggle("Deploy", isOn: $repo.deployEnabled)
                                            .toggleStyle(.checkbox)
                                            .fixedSize()

                                        Text(repo.name)
                                            .font(.system(size: 12.5, weight: .semibold))
                                            .lineLimit(1)

                                        Spacer(minLength: 8)

                                        Text(repo.path)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }

                                    HStack(spacing: 8) {
                                        TextField("Branch (default = current)", text: $repo.branch)
                                            .textFieldStyle(.roundedBorder)
                                            .frame(width: 155)

                                        TextField("Staging Jenkins Job (e.g. HS-1/project/service)", text: $repo.jenkinsJob)
                                            .textFieldStyle(.roundedBorder)
                                            .frame(maxWidth: .infinity)
                                            .onChange(of: repo.jenkinsJob) { _, val in
                                                if !val.trimmingCharacters(in: .whitespaces).isEmpty && !repo.deployEnabled {
                                                    repo.deployEnabled = true
                                                }
                                            }

                                        if draft.environmentMode == "multi" {
                                            TextField("Production Jenkins Job", text: $repo.prodJenkinsJob)
                                                .textFieldStyle(.roundedBorder)
                                                .frame(maxWidth: .infinity)
                                        }
                                    }
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.primary.opacity(0.04))
                                .cornerRadius(8)
                            }
                        }
                    }
                }

                // 5. Save / Delete Action Row
                HStack {
                    if let onDelete = onDelete {
                        Button(role: .destructive) {
                            if isCompletelyEmptyUnsaved {
                                onDelete()
                            } else {
                                vm.showDeleteConfirm = true
                            }
                        } label: {
                            Label(
                                isNewWorkspace ? "Remove Draft" : "Delete Workspace",
                                systemImage: "trash"
                            )
                        }
                        .fixedSize()
                        .confirmationDialog(
                            "Remove workspace '\(draft.label.isEmpty ? "New Workspace" : draft.label)' from MAC?",
                            isPresented: $vm.showDeleteConfirm,
                            titleVisibility: .visible
                        ) {
                            Button(isNewWorkspace ? "Remove Draft" : "Delete Workspace", role: .destructive) {
                                onDelete()
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("This only removes the workspace entry from MAC configuration; your code files on disk are untouched.")
                        }
                    }

                    Spacer()

                    Button(isNewWorkspace ? "Create Workspace" : "Save Workspace Changes") {
                        commitPendingJobInputs()
                        syncModelFields()
                        onSave()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(draft.label.trimmingCharacters(in: .whitespaces).isEmpty || draft.path.trimmingCharacters(in: .whitespaces).isEmpty)
                    .fixedSize()
                }
                .padding(.top, 2)
                .padding(.bottom, 10)
            }
            .padding(.trailing, 8)
        }
        .onAppear {
            loadFromDraft()
        }
    }

    private func loadFromDraft() {
        let norm = MACModelOption.normalizeFamilyAndLevel(rawModel: draft.model, rawLevel: draft.modelLevel)
        vm.selectedModelFamily = MACModelOption.allOptions.contains(where: { $0.id == norm.family }) ? norm.family : "gemini-3.8-flash"
        vm.selectedModelLevel = norm.level
        draft.model = norm.modelId
        draft.modelLevel = norm.level
    }

    private func syncModelFields() {
        let norm = MACModelOption.normalizeFamilyAndLevel(rawModel: vm.selectedModelFamily, rawLevel: vm.selectedModelLevel)
        draft.model = norm.modelId
        draft.modelLevel = norm.level
    }

    private func addStagingJobsFromInput() {
        let parsed = MACPathUtils.parseJobList(vm.stagingJobInput)
        for j in parsed where !draft.jenkinsJobs.contains(j) {
            draft.jenkinsJobs.append(j)
        }
        vm.stagingJobInput = ""
        autoMatchJobsToRepos()
    }

    private func addProdJobsFromInput() {
        let parsed = MACPathUtils.parseJobList(vm.prodJobInput)
        for j in parsed where !draft.prodJenkinsJobs.contains(j) {
            draft.prodJenkinsJobs.append(j)
        }
        vm.prodJobInput = ""
        autoMatchJobsToRepos()
    }

    private func commitPendingJobInputs() {
        if !vm.stagingJobInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            addStagingJobsFromInput()
        }
        if draft.environmentMode == "multi" && !vm.prodJobInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            addProdJobsFromInput()
        }
    }

    private func rescanRepos() {
        let cleanPath = MACPathUtils.expandPath(draft.path)
        guard !cleanPath.isEmpty else { return }
        draft.path = cleanPath
        draft.repos = MACPathUtils.discoverGitRepos(
            at: cleanPath,
            existingRepos: draft.repos,
            stagingJobs: draft.jenkinsJobs,
            prodJobs: draft.prodJenkinsJobs
        )
    }

    private func autoMatchJobsToRepos() {
        guard !draft.path.isEmpty else { return }
        if draft.repos.isEmpty {
            rescanRepos()
            return
        }
        for idx in draft.repos.indices {
            if draft.repos[idx].jenkinsJob.isEmpty,
               let matched = MACPathUtils.bestMatchingJob(forRepo: draft.repos[idx].name, workspacePath: draft.path, jobs: draft.jenkinsJobs) {
                draft.repos[idx].jenkinsJob = matched
                draft.repos[idx].deployEnabled = true
            }
            if draft.environmentMode == "multi",
               draft.repos[idx].prodJenkinsJob.isEmpty,
               let matchedProd = MACPathUtils.bestMatchingJob(forRepo: draft.repos[idx].name, workspacePath: draft.path, jobs: draft.prodJenkinsJobs) {
                draft.repos[idx].prodJenkinsJob = matchedProd
            }
        }
    }

    private func chooseDirectory(initialPath: String) -> String? {
        let panel = NSOpenPanel()
        panel.level = .modalPanel
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Select Folder"
        let expanded = MACPathUtils.expandPath(initialPath)
        if !expanded.isEmpty, FileManager.default.fileExists(atPath: expanded) {
            panel.directoryURL = URL(fileURLWithPath: expanded)
        }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

// MARK: - Tab 3: Step-by-Step Setup & Workflow Tutorial

private struct TutorialTabView: View {
    @ObservedObject var appState: MACAppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Quick Setup & Telegram Workspace Control Guide")
                        .font(.system(size: 15.5, weight: .bold))
                    Text("Follow these 5 quick steps to control your local macOS Workspaces, Git branches, and Staging → Prod Jenkins builds from Telegram.")
                        .font(.system(size: 12.5))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                tutorialStepCard(
                    stepNumber: "1",
                    title: "Create Your Telegram Bot (@BotFather — 30 seconds)",
                    icon: "paperplane.circle.fill",
                    accent: .blue,
                    bullets: [
                        "Open @BotFather in Telegram and send /newbot.",
                        "Pick any display name (e.g. My Mac Agent) and a username ending in 'bot' (e.g. my_mac_agent_bot).",
                        "Copy the HTTP API Token (looks like 123456789:ABC-DEF...) and paste it into General → Telegram.",
                        "Click 'Verify Token' and 'Save General Settings'."
                    ],
                    actionTitle: "Open @BotFather",
                    actionURL: "https://t.me/BotFather",
                    secondaryTitle: "Go to General →",
                    secondaryAction: { appState.selectedTab = .general }
                )

                tutorialStepCard(
                    stepNumber: "2",
                    title: "Lock Down Allowed Telegram User IDs (Recommended)",
                    icon: "lock.shield.fill",
                    accent: .indigo,
                    bullets: [
                        "Open @userinfobot in Telegram and tap Start — it replies with your numeric Telegram User ID (e.g. 652545688).",
                        "Paste your numeric ID into 'Allowed Telegram User IDs' inside General → Telegram (comma-separate multiple IDs if needed).",
                        "Even if someone guesses your bot's @username, unauthorized User IDs are silently ignored."
                    ],
                    actionTitle: "Open @userinfobot",
                    actionURL: "https://t.me/userinfobot",
                    secondaryTitle: nil,
                    secondaryAction: nil
                )

                tutorialStepCard(
                    stepNumber: "3",
                    title: "Add Workspaces & Optional Staging → Production Jenkins Jobs",
                    icon: "folder.fill.badge.gearshape",
                    accent: .purple,
                    bullets: [
                        "Open the 'Workspaces' tab, click '+' in the left sidebar to create a new Workspace record, enter a Workspace Label, and click 'Browse...' to pick your project folder.",
                        "Click 'Scan Git Repos' to auto-detect single or multi-repo Git folders, and choose the Workspace's AI Model (Gemini 3.8 Flash, Gemini 4 Argon, Claude Opus 5.5) and effort level (low / medium / high).",
                        "Optional CI/CD: Choose 'Single' or 'Multi (Staging → Production)' to promote verified Staging builds straight to Production from Telegram, and save your server credentials in General → Jenkins."
                    ],
                    actionTitle: nil,
                    actionURL: nil,
                    secondaryTitle: "Open Workspaces →",
                    secondaryAction: { appState.selectedTab = .workspaces }
                )

                tutorialStepCard(
                    stepNumber: "4",
                    title: "Click MAC Next to Your Clock → Start... + Session Password",
                    icon: "menubar.rectangle",
                    accent: .green,
                    bullets: [
                        "Click the bold 'MAC' badge next to your macOS menu bar clock and choose 'Start...' (or 'Open App' to open this window in the bottom Dock; clicking ✕ closes the window back to the menu bar with no Dock icon).",
                        "Enter a fresh session password for this run. Passwords live strictly in RAM (never written to disk) and stay valid until you click 'Restart...' or 'Stop'.",
                        "While running, mac.app automatically prevents your MacBook from sleeping and streams live events in the 'Live Bot Activity' tab."
                    ],
                    actionTitle: nil,
                    actionURL: nil,
                    secondaryTitle: "Live Bot Activity →",
                    secondaryAction: { appState.selectedTab = .liveActivity }
                )

                tutorialStepCard(
                    stepNumber: "5",
                    title: "Control Your Workspaces From Telegram on Your Phone",
                    icon: "iphone.radiowaves.left.and.right",
                    accent: .teal,
                    bullets: [
                        "Open your bot in Telegram, send /start, and reply once with your current session password (your password message is auto-deleted immediately from chat).",
                        "Tap a Workspace ('•' marks your active Workspace and 'Same Chat •' continues your active Antigravity Desktop conversation automatically).",
                        "Type coding instructions or attach up to 5 UI screenshots at once — Antigravity (agy) edits your local code and sends back a formatted summary + modified files (M / A / D).",
                        "Tap ✅ Yes or 🌿 Custom Branch to commit & push (or ❌ No to discard changes), run Staging Jenkins, verify your live preview URL, and tap 🚀 Yes, deploy on prod, ✅ Yes (skip prod deploy), or ↩️ Revert (Bad Commit)."
                    ],
                    actionTitle: nil,
                    actionURL: nil,
                    secondaryTitle: nil,
                    secondaryAction: nil
                )

                MACSectionCard(title: "Telegram Controls & Slash Commands Cheat Sheet", systemImage: "command.square.fill") {
                    VStack(alignment: .leading, spacing: 8) {
                        commandRow("/start", "Authenticate your session and open the Workspace selector")
                        commandRow("🔀 Switch Workspace  (/workspaces)", "Switch between your configured Workspaces without losing pending state")
                        commandRow("⚙️ Settings  (/settings, /model)", "Switch AI Model, effort level (low/medium/high), or view 📜 Last Messages")
                        commandRow("🆕 New Chat  (/newchat)", "Start a brand-new Antigravity conversation in the active Workspace")
                        commandRow("/history", "Read the latest X user & agent messages from the active conversation")
                        commandRow("/lock", "Lock your Telegram session immediately until you re-enter the password")
                    }
                }
            }
            .padding(.trailing, 8)
            .padding(.bottom, 10)
        }
    }

    private func tutorialStepCard(
        stepNumber: String,
        title: String,
        icon: String,
        accent: Color,
        bullets: [String],
        actionTitle: String?,
        actionURL: String?,
        secondaryTitle: String?,
        secondaryAction: (() -> Void)?
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(stepNumber)
                    .font(.system(size: 13, weight: .black, design: .rounded))
                    .foregroundColor(.white)
                    .frame(width: 24, height: 24)
                    .background(accent)
                    .clipShape(Circle())

                Image(systemName: icon)
                    .foregroundColor(accent)
                    .font(.system(size: 15, weight: .semibold))

                Text(title)
                    .font(.system(size: 13.5, weight: .bold))

                Spacer(minLength: 8)

                if let actionTitle = actionTitle, let urlStr = actionURL, let url = URL(string: urlStr) {
                    Button(actionTitle) {
                        NSWorkspace.shared.open(url)
                    }
                    .controlSize(.small)
                    .fixedSize()
                }
                if let secondaryTitle = secondaryTitle, let secondaryAction = secondaryAction {
                    Button(secondaryTitle) {
                        secondaryAction()
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .fixedSize()
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(bullets.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•")
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundColor(accent)
                        Text(line)
                            .font(.system(size: 12.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.leading, 34)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        )
    }

    private func commandRow(_ cmd: String, _ desc: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(cmd)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .frame(width: 265, alignment: .leading)
            Text(desc)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer()
        }
    }
}

// MARK: - Tab 4: Live Bot Activity (Dedicated Tab After Tutorial)

private struct LiveActivityTabView: View {
    @ObservedObject var appState: MACAppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.accentColor)

                Text("Live Bot Activity")
                    .font(.system(size: 14.5, weight: .bold))

                Text("\(appState.logLines.count) lines")
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06))
                    .cornerRadius(5)

                Spacer()

                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(appState.logLines.joined(separator: "\n"), forType: .string)
                } label: {
                    Label("Copy Logs", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
                .disabled(appState.logLines.isEmpty)
                .fixedSize()

                Button {
                    appState.clearLogs()
                } label: {
                    Label("Clear Logs", systemImage: "trash")
                }
                .controlSize(.small)
                .disabled(appState.logLines.isEmpty)
                .fixedSize()
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        if appState.logLines.isEmpty {
                            Text("Bot is currently stopped. Click 'Start...' in the MAC menu bar icon (or top-right) and enter a session password to begin streaming live Telegram & CI/CD activity.")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 6)
                        } else {
                            ForEach(Array(appState.logLines.enumerated()), id: \.offset) { idx, line in
                                Text(line)
                                    .font(.system(size: 12, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(idx)
                            }
                        }
                    }
                    .padding(12)
                }
                .onChange(of: appState.logLines.count) { _, newCount in
                    if newCount > 0 {
                        proxy.scrollTo(newCount - 1, anchor: .bottom)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black.opacity(0.22))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
