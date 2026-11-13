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

private struct MACEngineTabButton: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let isConfigured: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(isSelected ? .white : .secondary)

                Text(title)
                    .font(.system(size: 12.5, weight: isSelected ? .bold : .medium))

                if isConfigured {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundColor(isSelected ? .white : .green)
                }
            }
            .foregroundColor(isSelected ? .white : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.10), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct MACSubtabButton: View {
    let title: String
    let isSelected: Bool
    let isConfigured: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 11.5, weight: isSelected ? .bold : .medium))

                if isConfigured {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(isSelected ? .white : .green)
                }
            }
            .foregroundColor(isSelected ? .white : .primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.09), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Root App Window View (4 Tabs: General, Workspaces, Tutorial, Live Logs)

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
        .frame(minWidth: 800, minHeight: 640)
    }

    private var tabNavigationBar: some View {
        HStack(spacing: 6) {
            tabItemButton(.general, title: "General", icon: "gearshape.2.fill")
            tabItemButton(.workspaces, title: "Workspaces", icon: "folder.badge.gearshape")
            tabItemButton(.tutorial, title: "Tutorial", icon: "book.fill")
            tabItemButton(.liveActivity, title: "Live Logs", icon: "terminal.fill")
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
                    HStack(alignment: .center, spacing: 8) {
                        Text("AI")
                            .font(.system(size: 12.5, weight: .black))
                            .foregroundColor(.accentColor)
                        Text("MAC")
                            .font(.system(size: 15.5, weight: .black))
                        Text("— Mobile Agent Control")
                            .font(.system(size: 15, weight: .bold))
                    }
                    .fixedSize()
                    Text(appState.status.statusMenuTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(statusBadgeColor.opacity(0.16))
                        .cornerRadius(6)
                }
                Text("Data directory: \((appState.configStore.dataDir.path as NSString).abbreviatingWithTildeInPath)")
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
    // 1. CI/CD (Tabs: Jenkins, GitHub, Google Cloud)
    @Published var selectedCiTab: String = "jenkins" // "jenkins", "github", "google"

    // Jenkins
    @Published var jenkinsDraft: MACJenkinsConfig = MACJenkinsConfig()
    @Published var showJenkinsToken: Bool = false
    @Published var timeoutMinutes: Int = 25
    @Published var isTestingJenkins: Bool = false
    @Published var jenkinsTestMessage: String?
    @Published var jenkinsTestSucceeded: Bool = false

    // GitHub
    @Published var githubDraft: MACGitHubConfig = MACGitHubConfig()
    @Published var showGitHubToken: Bool = false
    @Published var isTestingGitHub: Bool = false
    @Published var githubTestMessage: String?
    @Published var githubTestSucceeded: Bool = false

    // Google Cloud
    @Published var googleCloudDraft: MACGoogleCloudConfig = MACGoogleCloudConfig()
    @Published var showGcpKey: Bool = false
    @Published var isTestingGoogleCloud: Bool = false
    @Published var googleCloudTestMessage: String?
    @Published var googleCloudTestSucceeded: Bool = false

    var isJenkinsConfigured: Bool {
        !jenkinsDraft.baseUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isGitHubConfigured: Bool {
        !githubDraft.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isGoogleCloudConfigured: Bool {
        !googleCloudDraft.projectId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // 2. Telegram
    @Published var botToken: String = ""
    @Published var showBotToken: Bool = false
    @Published var telegramApiBaseUrl: String = "https://api.telegram.org"
    @Published var allowedUsersText: String = ""
    @Published var historyCount: Int = 20
    @Published var isVerifyingToken: Bool = false
    @Published var tokenCheckMessage: String?
    @Published var tokenCheckSucceeded: Bool = false

    // 3. AI Agent Runners & Models (Tabs: AGY CLI, Aider CLI, Direct API)
    @Published var agyBinPath: String = ""
    @Published var aiderBinPath: String = "aider"
    @Published var agentEngine: String = "agy"
    @Published var selectedEngineTab: String = "agy" // "agy", "aider", "direct-api"
    @Published var selectedDirectApiSubtab: String = "deepseek" // "deepseek", "openai", "anthropic", "qwen", "custom"
    @Published var defaultModelFamily: String = "gemini-3.8-flash"
    @Published var defaultModelLevel: String = "high"

    // Direct API Keys & Endpoints
    @Published var deepseekApiKey: String = ""
    @Published var showDeepseekKey: Bool = false
    @Published var openaiApiKey: String = ""
    @Published var showOpenaiKey: Bool = false
    @Published var anthropicApiKey: String = ""
    @Published var showAnthropicKey: Bool = false
    @Published var qwenApiKey: String = ""
    @Published var showQwenKey: Bool = false
    @Published var customApiBaseUrl: String = ""
    @Published var customApiKey: String = ""
    @Published var showCustomKey: Bool = false

    var isAgyConfigured: Bool {
        MACPathUtils.isExecutableAvailable(agyBinPath)
    }

    var isAiderConfigured: Bool {
        MACPathUtils.isExecutableAvailable(aiderBinPath)
    }

    var isDirectApiConfigured: Bool {
        isDeepSeekConfigured || isOpenAIConfigured || isAnthropicConfigured || isQwenConfigured || isCustomConfigured
    }

    var isDeepSeekConfigured: Bool {
        !deepseekApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isOpenAIConfigured: Bool {
        !openaiApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isAnthropicConfigured: Bool {
        !anthropicApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isQwenConfigured: Bool {
        !qwenApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isCustomConfigured: Bool {
        !customApiBaseUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !customApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

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
                // Section 1: AI Engines & Models
                aiEnginesSectionCard

                // Section 2: Telegram
                telegramSectionCard

                // Section 3: CI/CD Deployment (Jenkins, GitHub, Google Cloud)
                ciCdSectionCard

                // Unified Save Row
                HStack {
                    Spacer()
                    Button("Save") {
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

    private var ciCdSectionCard: some View {
        MACSectionCard(title: "CI/CD Deployment", systemImage: "shippingbox.fill") {
            if vm.selectedCiTab == "jenkins" {
                Button {
                    runJenkinsConnectionTest()
                } label: {
                    HStack(spacing: 5) {
                        if vm.isTestingJenkins {
                            ProgressView().controlSize(.small)
                            Text("Testing...")
                        } else {
                            Image(systemName: "network")
                            Text("Test Jenkins")
                        }
                    }
                }
                .controlSize(.small)
                .disabled(vm.isTestingJenkins || vm.jenkinsDraft.baseUrl.trimmingCharacters(in: .whitespaces).isEmpty)
                .fixedSize()
            } else if vm.selectedCiTab == "github" {
                Button {
                    runGitHubConnectionTest()
                } label: {
                    HStack(spacing: 5) {
                        if vm.isTestingGitHub {
                            ProgressView().controlSize(.small)
                            Text("Testing...")
                        } else {
                            Image(systemName: "network")
                            Text("Test Github")
                        }
                    }
                }
                .controlSize(.small)
                .disabled(vm.isTestingGitHub || vm.githubDraft.token.trimmingCharacters(in: .whitespaces).isEmpty)
                .fixedSize()
            } else {
                Button {
                    runGoogleCloudConnectionTest()
                } label: {
                    HStack(spacing: 5) {
                        if vm.isTestingGoogleCloud {
                            ProgressView().controlSize(.small)
                            Text("Testing...")
                        } else {
                            Image(systemName: "network")
                            Text("Test Google Cloud")
                        }
                    }
                }
                .controlSize(.small)
                .disabled(vm.isTestingGoogleCloud || vm.googleCloudDraft.projectId.trimmingCharacters(in: .whitespaces).isEmpty)
                .fixedSize()
            }
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                Text("CI/CD Provider Tabs")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack(spacing: 6) {
                    MACEngineTabButton(
                        title: "Jenkins",
                        systemImage: "server.rack",
                        isSelected: vm.selectedCiTab == "jenkins",
                        isConfigured: vm.isJenkinsConfigured
                    ) {
                        vm.selectedCiTab = "jenkins"
                    }

                    MACEngineTabButton(
                        title: "GitHub",
                        systemImage: "arrow.triangle.pull",
                        isSelected: vm.selectedCiTab == "github",
                        isConfigured: vm.isGitHubConfigured
                    ) {
                        vm.selectedCiTab = "github"
                    }

                    MACEngineTabButton(
                        title: "Google Cloud",
                        systemImage: "cloud.fill",
                        isSelected: vm.selectedCiTab == "google",
                        isConfigured: vm.isGoogleCloudConfigured
                    ) {
                        vm.selectedCiTab = "google"
                    }
                }
            }

            switch vm.selectedCiTab {
            case "jenkins":
                jenkinsTabContent
            case "github":
                githubTabContent
            default:
                googleCloudTabContent
            }
        }
    }

    private var jenkinsTabContent: some View {
        VStack(alignment: .leading, spacing: 10) {
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

    private var githubTabContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("GitHub Personal Access Token (PAT)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack(spacing: 8) {
                    if vm.showGitHubToken {
                        TextField("ghp_... or github_pat_...", text: $vm.githubDraft.token)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("ghp_... or github_pat_...", text: $vm.githubDraft.token)
                            .textFieldStyle(.roundedBorder)
                    }
                    Button(vm.showGitHubToken ? "Hide" : "Show") {
                        vm.showGitHubToken.toggle()
                    }
                    .fixedSize()
                }
                Text("Requires 'repo' or 'workflow' scope to trigger workflow_dispatch events.")
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Default GitHub Owner / Organization (optional)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("e.g. your-org or github-username", text: $vm.githubDraft.owner)
                    .textFieldStyle(.roundedBorder)
                Text("Default owner prefix when repository name is specified without owner.")
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
            }

            if let msg = vm.githubTestMessage {
                HStack(spacing: 8) {
                    Image(systemName: vm.githubTestSucceeded ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(vm.githubTestSucceeded ? .green : .red)
                    Text(msg)
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background((vm.githubTestSucceeded ? Color.green : Color.red).opacity(0.12))
                .cornerRadius(6)
            }
        }
    }

    private var googleCloudTabContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Google Cloud Project ID")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("my-gcp-project-12345", text: $vm.googleCloudDraft.projectId)
                        .textFieldStyle(.roundedBorder)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 4) {
                    Text("GCP Region")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("us-central1", text: $vm.googleCloudDraft.region)
                        .textFieldStyle(.roundedBorder)
                }
                .frame(width: 180, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Service Account Key / Access Token")
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack(spacing: 8) {
                    if vm.showGcpKey {
                        TextField("Service Account Key JSON or OAuth Token", text: $vm.googleCloudDraft.serviceAccountKey)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("Service Account Key JSON or OAuth Token", text: $vm.googleCloudDraft.serviceAccountKey)
                            .textFieldStyle(.roundedBorder)
                    }
                    Button(vm.showGcpKey ? "Hide" : "Show") {
                        vm.showGcpKey.toggle()
                    }
                    .fixedSize()
                }
                Text("Optional if gcloud CLI is already authenticated locally.")
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
            }

            if let msg = vm.googleCloudTestMessage {
                HStack(spacing: 8) {
                    Image(systemName: vm.googleCloudTestSucceeded ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(vm.googleCloudTestSucceeded ? .green : .red)
                    Text(msg)
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background((vm.googleCloudTestSucceeded ? Color.green : Color.red).opacity(0.12))
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

    private var aiEnginesSectionCard: some View {
        MACSectionCard(title: "AI Engines & Models", systemImage: "cpu.fill") {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Default AI Model")
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
                    Text("Default Effort")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    MACSegmentedPicker(options: levelOptions, selection: $vm.defaultModelLevel)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("AI Engine Tabs")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack(spacing: 6) {
                    MACEngineTabButton(
                        title: "AGY CLI",
                        systemImage: "terminal.fill",
                        isSelected: vm.selectedEngineTab == "agy",
                        isConfigured: vm.isAgyConfigured
                    ) {
                        vm.selectedEngineTab = "agy"
                        vm.agentEngine = "agy"
                    }

                    MACEngineTabButton(
                        title: "Aider CLI",
                        systemImage: "chevron.left.forwardslash.chevron.right",
                        isSelected: vm.selectedEngineTab == "aider",
                        isConfigured: vm.isAiderConfigured
                    ) {
                        vm.selectedEngineTab = "aider"
                        vm.agentEngine = "aider"
                    }

                    MACEngineTabButton(
                        title: "Direct API",
                        systemImage: "key.fill",
                        isSelected: vm.selectedEngineTab == "direct-api",
                        isConfigured: vm.isDirectApiConfigured
                    ) {
                        vm.selectedEngineTab = "direct-api"
                        vm.agentEngine = "direct-api"
                    }
                }
            }

            switch vm.selectedEngineTab {
            case "agy":
                agyTabContent
            case "aider":
                aiderTabContent
            default:
                directApiTabContent
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

    private var agyTabContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Google Antigravity CLI (agy)")
                    .font(.system(size: 13, weight: .bold))
                Spacer()
                Text(vm.isAgyConfigured ? "Configured ✓" : "Path Required")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(vm.isAgyConfigured ? .green : .orange)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background((vm.isAgyConfigured ? Color.green : Color.orange).opacity(0.12))
                    .cornerRadius(5)
            }

            Text("Executes coding tasks using the local Google Antigravity (agy) CLI. Native support for Gemini 3.8 Flash, Gemini 4 Argon, Gemini 4 Carbon, and Claude Opus / Sonnet 5.5.")
                .font(.caption)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Antigravity Binary Path (agy)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack(spacing: 8) {
                    TextField("/Users/you/.local/bin/agy", text: $vm.agyBinPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse...") {
                        if let chosen = chooseExecutableFile(initialPath: vm.agyBinPath, prompt: "Select agy Binary") {
                            vm.agyBinPath = chosen
                        }
                    }
                    .fixedSize()
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }

    private var aiderTabContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Aider CLI (Terminal Coding Assistant)")
                    .font(.system(size: 13, weight: .bold))
                Spacer()
                Text(vm.isAiderConfigured ? "Configured ✓" : "Not Installed")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(vm.isAiderConfigured ? .green : .secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background((vm.isAiderConfigured ? Color.green : Color.primary).opacity(0.12))
                    .cornerRadius(5)
            }

            Text("Runs non-interactive headless agent turns via the Aider CLI in your terminal. If installed, specify its path below or install via: pip install aider-chat")
                .font(.caption)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Aider Binary Path")
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack(spacing: 8) {
                    TextField("e.g. /usr/local/bin/aider (or pip install aider-chat)", text: $vm.aiderBinPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse...") {
                        if let chosen = chooseExecutableFile(initialPath: vm.aiderBinPath, prompt: "Select aider Binary") {
                            vm.aiderBinPath = chosen
                        }
                    }
                    .fixedSize()
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }

    private var directApiTabContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Direct API Integration (Zero Local CLI Dependencies)")
                    .font(.system(size: 13, weight: .bold))
                Spacer()
                Text(vm.isDirectApiConfigured ? "API Ready ✓" : "No Keys Configured")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(vm.isDirectApiConfigured ? .green : .secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background((vm.isDirectApiConfigured ? Color.green : Color.primary).opacity(0.12))
                    .cornerRadius(5)
            }

            Text("Connects directly to LLM providers via HTTP API. Includes autonomous tool execution (read/edit/write files and run shell commands in the workspace).")
                .font(.caption)
                .foregroundColor(.secondary)

            // Subtabs: DeepSeek, OpenAI, Anthropic, Qwen, Custom / Local
            HStack(spacing: 6) {
                MACSubtabButton(
                    title: "DeepSeek",
                    isSelected: vm.selectedDirectApiSubtab == "deepseek",
                    isConfigured: vm.isDeepSeekConfigured
                ) {
                    vm.selectedDirectApiSubtab = "deepseek"
                }

                MACSubtabButton(
                    title: "OpenAI",
                    isSelected: vm.selectedDirectApiSubtab == "openai",
                    isConfigured: vm.isOpenAIConfigured
                ) {
                    vm.selectedDirectApiSubtab = "openai"
                }

                MACSubtabButton(
                    title: "Anthropic",
                    isSelected: vm.selectedDirectApiSubtab == "anthropic",
                    isConfigured: vm.isAnthropicConfigured
                ) {
                    vm.selectedDirectApiSubtab = "anthropic"
                }

                MACSubtabButton(
                    title: "Qwen",
                    isSelected: vm.selectedDirectApiSubtab == "qwen",
                    isConfigured: vm.isQwenConfigured
                ) {
                    vm.selectedDirectApiSubtab = "qwen"
                }

                MACSubtabButton(
                    title: "Custom / Local",
                    isSelected: vm.selectedDirectApiSubtab == "custom",
                    isConfigured: vm.isCustomConfigured
                ) {
                    vm.selectedDirectApiSubtab = "custom"
                }
            }

            // Subtab Content
            Group {
                switch vm.selectedDirectApiSubtab {
                case "deepseek":
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("DeepSeek API (DeepSeek-V3 & DeepSeek-R1)")
                                .font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Text(vm.isDeepSeekConfigured ? "Configured ✓" : "Key Required")
                                .font(.caption2)
                                .foregroundColor(vm.isDeepSeekConfigured ? .green : .secondary)
                        }
                        HStack(spacing: 6) {
                            if vm.showDeepseekKey {
                                TextField("sk-...", text: $vm.deepseekApiKey)
                                    .textFieldStyle(.roundedBorder)
                            } else {
                                SecureField("sk-...", text: $vm.deepseekApiKey)
                                    .textFieldStyle(.roundedBorder)
                            }
                            Button(vm.showDeepseekKey ? "Hide" : "Show") {
                                vm.showDeepseekKey.toggle()
                            }
                            .fixedSize()
                        }
                        Text("Default endpoint: https://api.deepseek.com/chat/completions")
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                    }

                case "openai":
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("OpenAI API (GPT-4o, o3-mini, o1)")
                                .font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Text(vm.isOpenAIConfigured ? "Configured ✓" : "Key Required")
                                .font(.caption2)
                                .foregroundColor(vm.isOpenAIConfigured ? .green : .secondary)
                        }
                        HStack(spacing: 6) {
                            if vm.showOpenaiKey {
                                TextField("sk-proj-...", text: $vm.openaiApiKey)
                                    .textFieldStyle(.roundedBorder)
                            } else {
                                SecureField("sk-proj-...", text: $vm.openaiApiKey)
                                    .textFieldStyle(.roundedBorder)
                            }
                            Button(vm.showOpenaiKey ? "Hide" : "Show") {
                                vm.showOpenaiKey.toggle()
                            }
                            .fixedSize()
                        }
                        Text("Default endpoint: https://api.openai.com/v1/chat/completions")
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                    }

                case "anthropic":
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Anthropic Claude API (Claude 3.7 Sonnet & 3.5 Sonnet)")
                                .font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Text(vm.isAnthropicConfigured ? "Configured ✓" : "Key Required")
                                .font(.caption2)
                                .foregroundColor(vm.isAnthropicConfigured ? .green : .secondary)
                        }
                        HStack(spacing: 6) {
                            if vm.showAnthropicKey {
                                TextField("sk-ant-...", text: $vm.anthropicApiKey)
                                    .textFieldStyle(.roundedBorder)
                            } else {
                                SecureField("sk-ant-...", text: $vm.anthropicApiKey)
                                    .textFieldStyle(.roundedBorder)
                            }
                            Button(vm.showAnthropicKey ? "Hide" : "Show") {
                                vm.showAnthropicKey.toggle()
                            }
                            .fixedSize()
                        }
                        Text("Default endpoint: https://api.anthropic.com/v1/messages")
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                    }

                case "qwen":
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Qwen API (Qwen 2.5 Coder 32B & Qwen 2.5 72B)")
                                .font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Text(vm.isQwenConfigured ? "Configured ✓" : "Key Required")
                                .font(.caption2)
                                .foregroundColor(vm.isQwenConfigured ? .green : .secondary)
                        }
                        HStack(spacing: 6) {
                            if vm.showQwenKey {
                                TextField("sk-...", text: $vm.qwenApiKey)
                                    .textFieldStyle(.roundedBorder)
                            } else {
                                SecureField("sk-...", text: $vm.qwenApiKey)
                                    .textFieldStyle(.roundedBorder)
                            }
                            Button(vm.showQwenKey ? "Hide" : "Show") {
                                vm.showQwenKey.toggle()
                            }
                            .fixedSize()
                        }
                        Text("Compatible with DashScope / OpenRouter API endpoints")
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                    }

                default:
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Custom / Local Endpoint (Ollama, LM Studio, vLLM, OpenRouter)")
                                .font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Text(vm.isCustomConfigured ? "Configured ✓" : "Optional")
                                .font(.caption2)
                                .foregroundColor(vm.isCustomConfigured ? .green : .secondary)
                        }
                        TextField("http://localhost:11434/v1 or https://openrouter.ai/api/v1", text: $vm.customApiBaseUrl)
                            .textFieldStyle(.roundedBorder)
                        HStack(spacing: 6) {
                            if vm.showCustomKey {
                                TextField("API Key (optional, blank for local models)", text: $vm.customApiKey)
                                    .textFieldStyle(.roundedBorder)
                            } else {
                                SecureField("API Key (optional, blank for local models)", text: $vm.customApiKey)
                                    .textFieldStyle(.roundedBorder)
                            }
                            Button(vm.showCustomKey ? "Hide" : "Show") {
                                vm.showCustomKey.toggle()
                            }
                            .fixedSize()
                        }
                        Text("Connect 100% private local models (Ollama, LM Studio, vLLM, Jan) via http://localhost:11434/v1 with zero API key required.")
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.025)))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }

    private func loadFromAppState() {
        vm.jenkinsDraft = appState.config.jenkins
        vm.timeoutMinutes = max(5, vm.jenkinsDraft.buildTimeoutMs / 60_000)
        vm.githubDraft = appState.config.github
        vm.googleCloudDraft = appState.config.googleCloud

        vm.botToken = appState.config.telegramBotToken
        vm.telegramApiBaseUrl = appState.config.telegramApiBaseUrl
        vm.allowedUsersText = appState.config.allowedUserIds.joined(separator: ", ")
        vm.historyCount = appState.config.defaultHistoryCount

        vm.agyBinPath = appState.config.agyBin
        vm.aiderBinPath = appState.config.aiderBin
        let loadedEngine = (appState.config.agentEngine == "auto" || appState.config.agentEngine.isEmpty) ? "agy" : appState.config.agentEngine
        vm.agentEngine = loadedEngine
        vm.selectedEngineTab = ["agy", "aider", "direct-api"].contains(loadedEngine) ? loadedEngine : "agy"
        vm.deepseekApiKey = appState.config.deepseekApiKey
        vm.openaiApiKey = appState.config.openaiApiKey
        vm.anthropicApiKey = appState.config.anthropicApiKey
        vm.qwenApiKey = appState.config.qwenApiKey
        vm.customApiBaseUrl = appState.config.customApiBaseUrl
        vm.customApiKey = appState.config.customApiKey

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

        var updatedGithub = vm.githubDraft
        updatedGithub.token = updatedGithub.token.trimmingCharacters(in: .whitespacesAndNewlines)
        updatedGithub.owner = updatedGithub.owner.trimmingCharacters(in: .whitespacesAndNewlines)
        appState.config.github = updatedGithub

        var updatedGcp = vm.googleCloudDraft
        updatedGcp.projectId = updatedGcp.projectId.trimmingCharacters(in: .whitespacesAndNewlines)
        updatedGcp.serviceAccountKey = updatedGcp.serviceAccountKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanRegion = updatedGcp.region.trimmingCharacters(in: .whitespacesAndNewlines)
        updatedGcp.region = cleanRegion.isEmpty ? "us-central1" : cleanRegion
        appState.config.googleCloud = updatedGcp

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
        let cleanAider = MACPathUtils.expandPath(vm.aiderBinPath)
        if !cleanAider.isEmpty {
            appState.config.aiderBin = cleanAider
            vm.aiderBinPath = cleanAider
        }
        appState.config.agentEngine = vm.agentEngine
        appState.config.deepseekApiKey = vm.deepseekApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        appState.config.openaiApiKey = vm.openaiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        appState.config.anthropicApiKey = vm.anthropicApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        appState.config.qwenApiKey = vm.qwenApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        appState.config.customApiBaseUrl = vm.customApiBaseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        appState.config.customApiKey = vm.customApiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        let normModel = MACModelOption.normalizeFamilyAndLevel(
            rawModel: vm.defaultModelFamily,
            rawLevel: vm.defaultModelLevel
        )
        appState.config.defaultModel = normModel.modelId
        appState.config.defaultModelLevel = normModel.level

        appState.saveConfigToDisk(banner: "Saved General settings (CI/CD Deploy, Telegram, AI Engines & Models).")
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

    private func runGitHubConnectionTest() {
        vm.isTestingGitHub = true
        vm.githubTestMessage = nil
        let snapshot = vm.githubDraft
        let viewModel = vm
        Task {
            let res = await GitHubConnectionTester.testConnection(config: snapshot)
            await MainActor.run {
                viewModel.isTestingGitHub = false
                switch res {
                case .success(let info):
                    viewModel.githubTestSucceeded = true
                    viewModel.githubTestMessage = info
                case .failure(let err):
                    viewModel.githubTestSucceeded = false
                    viewModel.githubTestMessage = err.localizedDescription
                }
            }
        }
    }

    private func runGoogleCloudConnectionTest() {
        vm.isTestingGoogleCloud = true
        vm.googleCloudTestMessage = nil
        let snapshot = vm.googleCloudDraft
        let viewModel = vm
        Task {
            let res = await GoogleCloudConnectionTester.testConnection(config: snapshot)
            await MainActor.run {
                viewModel.isTestingGoogleCloud = false
                switch res {
                case .success(let info):
                    viewModel.googleCloudTestSucceeded = true
                    viewModel.googleCloudTestMessage = info
                case .failure(let err):
                    viewModel.googleCloudTestSucceeded = false
                    viewModel.googleCloudTestMessage = err.localizedDescription
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

    private func chooseExecutableFile(initialPath: String, prompt: String = "Select Binary") -> String? {
        let panel = NSOpenPanel()
        panel.level = .modalPanel
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
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

        let engineTag: String = {
            let e = entry.draft.engine.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if e == "aider" { return "AIDER" }
            if e == "direct-api" { return "API" }
            return "AGY"
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

                    HStack(spacing: 4) {
                        Text(engineTag)
                            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                            .foregroundColor(isSelected ? .white : .secondary)
                            .padding(.horizontal, 4.5)
                            .padding(.vertical, 1.5)
                            .background(
                                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                                    .fill(isSelected ? Color.white.opacity(0.18) : Color.primary.opacity(0.07))
                            )

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
        let eng = normalized.engine.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        normalized.engine = (eng.isEmpty || eng == "auto") ? "agy" : eng

        let slugSource = !normalized.label.isEmpty
            ? normalized.label
            : (!normalized.id.isEmpty ? normalized.id : (normalized.path.isEmpty ? "workspace" : URL(fileURLWithPath: normalized.path).lastPathComponent))
        let rawSlug = MACPathUtils.slugifyWorkspaceId(slugSource)
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
        if normalized.ciProvider.isEmpty {
            if !normalized.jenkinsJobs.isEmpty || normalized.repos.contains(where: { !$0.jenkinsJob.isEmpty }) {
                normalized.ciProvider = "jenkins"
            } else if !normalized.githubRepo.isEmpty || !normalized.githubWorkflow.isEmpty || normalized.repos.contains(where: { !$0.githubWorkflow.isEmpty }) {
                normalized.ciProvider = "github"
            } else if !normalized.gcpTrigger.isEmpty || normalized.repos.contains(where: { !$0.gcpTrigger.isEmpty }) {
                normalized.ciProvider = "google"
            } else {
                normalized.ciProvider = "none"
            }
        }
        for repo in normalized.repos where repo.deployEnabled {
            if normalized.ciProvider == "jenkins" {
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
            } else if normalized.ciProvider == "github" {
                if normalized.githubWorkflow.isEmpty && !repo.githubWorkflow.isEmpty {
                    normalized.githubWorkflow = repo.githubWorkflow
                }
                if normalized.prodGithubWorkflow.isEmpty && !repo.prodGithubWorkflow.isEmpty {
                    normalized.prodGithubWorkflow = repo.prodGithubWorkflow
                }
            } else if normalized.ciProvider == "google" {
                if normalized.gcpTrigger.isEmpty && !repo.gcpTrigger.isEmpty {
                    normalized.gcpTrigger = repo.gcpTrigger
                }
                if normalized.prodGcpTrigger.isEmpty && !repo.prodGcpTrigger.isEmpty {
                    normalized.prodGcpTrigger = repo.prodGcpTrigger
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
    @Published var lastSelectedCiProvider: String = "jenkins"
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

    private var workspaceEngineOptions: [MACSegmentedOption<String>] {
        [
            MACSegmentedOption(id: "agy", title: "AGY CLI", value: "agy"),
            MACSegmentedOption(id: "aider", title: "Aider CLI", value: "aider"),
            MACSegmentedOption(id: "direct-api", title: "Direct API", value: "direct-api")
        ]
    }

    private var envModeOptions: [MACSegmentedOption<String>] {
        [
            MACSegmentedOption(id: "single", title: "Single (Staging / Default)", value: "single"),
            MACSegmentedOption(id: "multi", title: "Multi (Staging → Production)", value: "multi")
        ]
    }

    private var ciProviderOptions: [MACSegmentedOption<String>] {
        [
            MACSegmentedOption(id: "jenkins", title: "Jenkins", value: "jenkins"),
            MACSegmentedOption(id: "github", title: "GitHub", value: "github"),
            MACSegmentedOption(id: "google", title: "Google Cloud", value: "google")
        ]
    }

    private var isGitOnlyBinding: Binding<Bool> {
        Binding<Bool>(
            get: {
                draft.ciProvider == "none"
            },
            set: { isGitOnly in
                if isGitOnly {
                    if draft.ciProvider != "none" {
                        vm.lastSelectedCiProvider = draft.ciProvider
                    }
                    draft.ciProvider = "none"
                } else {
                    let restore = (vm.lastSelectedCiProvider.isEmpty || vm.lastSelectedCiProvider == "none") ? "jenkins" : vm.lastSelectedCiProvider
                    draft.ciProvider = restore
                }
            }
        )
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
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Workspace Label (shown in Telegram)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("e.g. CRYPTO FUSION", text: $draft.label)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: draft.label) { _, newVal in
                                let trimmed = newVal.trimmingCharacters(in: .whitespacesAndNewlines)
                                if isNewWorkspace || draft.id.isEmpty {
                                    draft.id = trimmed.isEmpty ? "" : MACPathUtils.slugifyWorkspaceId(trimmed)
                                }
                            }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

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
                                        if isNewWorkspace || draft.id.isEmpty {
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

                // 2. AI Execution Engine & Model
                MACSectionCard(title: "AI Engine & Model", systemImage: "cpu.fill") {
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
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Execution Engine for this Workspace")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(draft.engine == "aider" ? "Aider CLI" : (draft.engine == "direct-api" ? "Direct API" : "Antigravity CLI (agy)"))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }

                            MACSegmentedPicker(
                                options: workspaceEngineOptions,
                                selection: Binding(
                                    get: {
                                        let eng = draft.engine.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                                        return (eng.isEmpty || eng == "auto") ? "agy" : eng
                                    },
                                    set: { draft.engine = $0 }
                                )
                            )
                            .frame(maxWidth: 440, alignment: .leading)
                        }

                        Divider()

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
                }

                // 3. Environments & CI/CD Deployment
                MACSectionCard(title: "Environments & CI/CD Deployment", systemImage: "shippingbox.fill") {
                    Toggle("Git-only", isOn: isGitOnlyBinding)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12))
                } content: {
                    if draft.ciProvider == "none" {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle")
                                .foregroundColor(.accentColor)
                            Text("Git-only mode: changes are committed and pushed directly to Git remotes without external CI runner dispatches.")
                                .font(.system(size: 11.5))
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("CI/CD Provider")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            MACSegmentedPicker(options: ciProviderOptions, selection: $draft.ciProvider)
                                .frame(maxWidth: 420, alignment: .leading)
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Environment Mode")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            MACSegmentedPicker(options: envModeOptions, selection: $draft.environmentMode)
                                .frame(maxWidth: 440, alignment: .leading)
                        }

                    if draft.ciProvider == "jenkins" {
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
                    } else if draft.ciProvider == "github" {
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            Text(draft.environmentMode == "multi" ? "GitHub Workflows (Staging & Production)" : "GitHub Workflow")
                                .font(.system(size: 12.5, weight: .semibold))

                            VStack(alignment: .leading, spacing: 4) {
                                Text("GitHub Repository (owner/repo or slug, optional if remote configured)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                TextField("e.g. acme/service or leave blank to detect from git remote", text: $draft.githubRepo)
                                    .textFieldStyle(.roundedBorder)
                            }

                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(draft.environmentMode == "multi" ? "Staging Workflow File" : "Workflow File")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    TextField("deploy.yml or ci.yml", text: $draft.githubWorkflow)
                                        .textFieldStyle(.roundedBorder)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                if draft.environmentMode == "multi" {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Production Workflow File")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        TextField("deploy-prod.yml", text: $draft.prodGithubWorkflow)
                                            .textFieldStyle(.roundedBorder)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    } else if draft.ciProvider == "google" {
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            Text(draft.environmentMode == "multi" ? "Google Cloud Build Triggers (Staging & Production)" : "Google Cloud Build Trigger")
                                .font(.system(size: 12.5, weight: .semibold))

                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(draft.environmentMode == "multi" ? "Staging Trigger ID / Name" : "Trigger ID / Name")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    TextField("staging-deploy-trigger", text: $draft.gcpTrigger)
                                        .textFieldStyle(.roundedBorder)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                if draft.environmentMode == "multi" {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Production Trigger ID / Name")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        TextField("prod-deploy-trigger", text: $draft.prodGcpTrigger)
                                            .textFieldStyle(.roundedBorder)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    }
                }
            }

                // 4. Per-Repository Mapping
                MACSectionCard(title: "Git Repositories in Workspace (\(draft.repos.count))", systemImage: "point.3.connected.trianglepath.dotted") {
                    Button("Re-Scan") {
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

                                        if draft.ciProvider == "jenkins" {
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
                                        } else if draft.ciProvider == "github" {
                                            TextField("Workflow (e.g. deploy.yml)", text: $repo.githubWorkflow)
                                                .textFieldStyle(.roundedBorder)
                                                .frame(maxWidth: .infinity)
                                                .onChange(of: repo.githubWorkflow) { _, val in
                                                    if !val.trimmingCharacters(in: .whitespaces).isEmpty && !repo.deployEnabled {
                                                        repo.deployEnabled = true
                                                    }
                                                }

                                            if draft.environmentMode == "multi" {
                                                TextField("Prod Workflow", text: $repo.prodGithubWorkflow)
                                                    .textFieldStyle(.roundedBorder)
                                                    .frame(maxWidth: .infinity)
                                            }
                                        } else if draft.ciProvider == "google" {
                                            TextField("GCP Trigger ID", text: $repo.gcpTrigger)
                                                .textFieldStyle(.roundedBorder)
                                                .frame(maxWidth: .infinity)
                                                .onChange(of: repo.gcpTrigger) { _, val in
                                                    if !val.trimmingCharacters(in: .whitespaces).isEmpty && !repo.deployEnabled {
                                                        repo.deployEnabled = true
                                                    }
                                                }

                                            if draft.environmentMode == "multi" {
                                                TextField("Prod Trigger ID", text: $repo.prodGcpTrigger)
                                                    .textFieldStyle(.roundedBorder)
                                                    .frame(maxWidth: .infinity)
                                            }
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
                                isNewWorkspace ? "Remove Draft" : "Delete",
                                systemImage: "trash"
                            )
                        }
                        .fixedSize()
                        .confirmationDialog(
                            "Remove workspace '\(draft.label.isEmpty ? "New Workspace" : draft.label)' from MAC?",
                            isPresented: $vm.showDeleteConfirm,
                            titleVisibility: .visible
                        ) {
                            Button(isNewWorkspace ? "Remove Draft" : "Delete", role: .destructive) {
                                onDelete()
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("This only removes the workspace entry from MAC configuration; your code files on disk are untouched.")
                        }
                    }

                    Spacer()

                    Button(isNewWorkspace ? "Create" : "Save") {
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
        if draft.ciProvider != "none" && !draft.ciProvider.isEmpty {
            vm.lastSelectedCiProvider = draft.ciProvider
        }
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
                        "Click 'Verify Token' and 'Save'."
                    ],
                    actionTitle: "Open @BotFather",
                    actionURL: "https://t.me/BotFather",
                    secondaryTitle: "General →",
                    secondaryAction: { appState.selectedTab = .general }
                )

                tutorialStepCard(
                    stepNumber: "2",
                    title: "Lock Down Allowed Telegram User IDs",
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
                    title: "Configure AI Engines (Tabs & Checkmarks) & Workspaces",
                    icon: "folder.fill.badge.gearshape",
                    accent: .purple,
                    bullets: [
                        "In General → AI Engines & Models, switch between tabs: AGY CLI, Aider CLI, or Direct API (with subtabs for DeepSeek, OpenAI, Anthropic, Qwen, and Custom / Local). Each tab displays a live configured indicator.",
                        "Connect Personal Local Models: Under Direct API → Custom / Local, connect private local models (Ollama, LM Studio, vLLM, LocalAI, Jan) via http://localhost:11434/v1 — 100% offline and air-gapped with zero API keys required!",
                        "Open the 'Workspaces' tab, click '+' in the left sidebar to add a Workspace, enter a Label, and click 'Browse...' to select your project folder.",
                        "Select your Workspace's AI Engine (AGY CLI [default], Aider CLI, or Direct API), 1-click 'Scan Git Repos', and pick your AI Model (Gemini, Claude, DeepSeek, OpenAI, Qwen, or Local).",
                        "Optional CI/CD: Choose 'Single' or 'Multi (Staging → Production)' to promote verified Staging builds straight to Production from Telegram, with credentials in General → Jenkins."
                    ],
                    actionTitle: nil,
                    actionURL: nil,
                    secondaryTitle: "Workspaces →",
                    secondaryAction: { appState.selectedTab = .workspaces }
                )

                tutorialStepCard(
                    stepNumber: "4",
                    title: "Click MAC in Menu Bar → Start... + Session Password",
                    icon: "menubar.rectangle",
                    accent: .green,
                    bullets: [
                        "Click the 'MAC' menu bar icon and choose 'Start...' (or 'Open App' to open this window in the bottom Dock; clicking ✕ closes the window back to the menu bar with no Dock icon).",
                        "Enter a fresh session password for this run. Passwords live strictly in RAM (never written to disk) and stay valid until you click 'Restart...' or 'Stop'.",
                        "While running, mac.app automatically prevents your MacBook from sleeping and streams live events in the 'Live Logs' tab."
                    ],
                    actionTitle: nil,
                    actionURL: nil,
                    secondaryTitle: "Live Logs →",
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
                        commandRow("🔀 Workspace  (/workspaces)", "Switch between your configured Workspaces without losing pending state")
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
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label(actionTitle, systemImage: "link")
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

// MARK: - Tab 4: Live Logs (Real-Time Colored Telemetry, Process Loaders & Stages)

private enum MACLogCategory: String, CaseIterable, Identifiable {
    case all = "All"
    case telegram = "Telegram"
    case agent = "AI Agent"
    case cicd = "CI/CD"
    case git = "Git"
    case system = "MAC"
    case errors = "Errors"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .all: return "list.bullet"
        case .telegram: return "paperplane.fill"
        case .agent: return "cpu.fill"
        case .cicd: return "shippingbox.fill"
        case .git: return "point.3.connected.trianglepath.dotted"
        case .system: return "apple.logo"
        case .errors: return "exclamationmark.triangle.fill"
        }
    }

    var badgeColor: Color {
        switch self {
        case .all: return .accentColor
        case .telegram: return .cyan
        case .agent: return .purple
        case .cicd: return .blue
        case .git: return .mint
        case .system: return .secondary
        case .errors: return .red
        }
    }
}

private struct MACParsedLogLine: Identifiable {
    let id: Int
    let rawText: String
    let source: MACLogCategory
    let badgeLabel: String
    let badgeColor: Color
    let icon: String
    let lineNumber: String
    let messageText: String
    let messageColor: Color
    let isLoading: Bool
}

private final class LiveActivityTabVM: ObservableObject {
    @Published var selectedCategories: Set<MACLogCategory> = [.all]
    @Published var searchText: String = ""
    @Published var autoScroll: Bool = true

    func toggleCategory(_ cat: MACLogCategory) {
        if cat == .all {
            selectedCategories = [.all]
            return
        }

        if selectedCategories.contains(.all) {
            selectedCategories = [cat]
        } else {
            if selectedCategories.contains(cat) {
                selectedCategories.remove(cat)
                if selectedCategories.isEmpty {
                    selectedCategories = [.all]
                }
            } else {
                selectedCategories.insert(cat)
            }
        }
    }

    func isCategorySelected(_ cat: MACLogCategory) -> Bool {
        if cat == .all {
            return selectedCategories.contains(.all)
        }
        return selectedCategories.contains(cat)
    }
}

private struct LiveActivityTabView: View {
    @ObservedObject var appState: MACAppState
    @StateObject private var vm = LiveActivityTabVM()

    private var parsedLines: [MACParsedLogLine] {
        appState.logLines.enumerated().map { idx, line in
            parseLogLine(line, index: idx)
        }
    }

    private var filteredLines: [MACParsedLogLine] {
        let isAll = vm.selectedCategories.contains(.all) || vm.selectedCategories.isEmpty
        return parsedLines.filter { item in
            let matchesCategory: Bool
            if isAll {
                matchesCategory = true
            } else {
                matchesCategory = vm.selectedCategories.contains(item.source)
            }

            if !matchesCategory { return false }

            if !vm.searchText.isEmpty {
                return item.rawText.localizedCaseInsensitiveContains(vm.searchText)
            }
            return true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerBar
            filterAndControlsBar
            logConsoleBox
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var formattedBufferLimit: String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: appState.maxLogLines)) ?? "\(appState.maxLogLines)"
    }

    private var headerBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.accentColor)

            Text("Live Logs")
                .font(.system(size: 14.5, weight: .bold))

            Menu {
                Button("Buffer limit: 1,000 lines") {
                    appState.maxLogLines = 1000
                    appState.trimLogsToMax()
                }
                Button("Buffer limit: 3,000 lines (default)") {
                    appState.maxLogLines = 3000
                    appState.trimLogsToMax()
                }
                Button("Buffer limit: 5,000 lines") {
                    appState.maxLogLines = 5000
                    appState.trimLogsToMax()
                }
                Button("Buffer limit: 10,000 lines") {
                    appState.maxLogLines = 10000
                    appState.trimLogsToMax()
                }
            } label: {
                HStack(spacing: 4) {
                    Text("Buffer: \(formattedBufferLimit)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8))
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.06))
                .cornerRadius(5)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()

            if appState.isTaskRunning {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(appState.activeStage)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(.accentColor)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.12))
                .cornerRadius(6)
            }
        }
    }

    private var filterAndControlsBar: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(MACLogCategory.allCases) { cat in
                        let isSelected = vm.isCategorySelected(cat)
                        Button {
                            vm.toggleCategory(cat)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: cat.icon)
                                    .font(.system(size: 10.5, weight: .semibold))
                                Text(cat.rawValue)
                                    .font(.system(size: 11.5, weight: isSelected ? .bold : .medium))
                                    .lineLimit(1)
                                Text("(\(countForCategory(cat)))")
                                    .font(.system(size: 10, design: .monospaced))
                                    .opacity(0.7)
                                    .lineLimit(1)
                            }
                            .lineLimit(1)
                            .fixedSize()
                            .foregroundColor(isSelected ? .white : .primary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(isSelected ? cat.badgeColor : Color.primary.opacity(0.05))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(isSelected ? cat.badgeColor : Color.primary.opacity(0.08), lineWidth: 1)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .fixedSize()
                    }
                }
                .padding(.vertical, 1)
            }

            Spacer(minLength: 6)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 11))
                TextField("Filter logs...", text: $vm.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .frame(width: 105)
                if !vm.searchText.isEmpty {
                    Button {
                        vm.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.04))
            .cornerRadius(6)
            .fixedSize()

            Toggle(isOn: $vm.autoScroll) {
                Text("Auto-scroll")
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                    .fixedSize()
            }
            .toggleStyle(.checkbox)
            .fixedSize()

            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                let textToCopy = filteredLines.map(\.rawText).joined(separator: "\n")
                pb.setString(textToCopy, forType: .string)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
                    .lineLimit(1)
            }
            .controlSize(.small)
            .disabled(filteredLines.isEmpty)
            .fixedSize()

            Button {
                appState.clearLogs()
            } label: {
                Label("Clear", systemImage: "trash")
                    .lineLimit(1)
            }
            .controlSize(.small)
            .disabled(appState.logLines.isEmpty)
            .fixedSize()
        }
    }

    private var logConsoleBox: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    if appState.logLines.isEmpty {
                        VStack(spacing: 8) {
                            HStack(spacing: 8) {
                                Image(systemName: "info.circle")
                                    .foregroundColor(.secondary)
                                Text("Bot is currently stopped. Click 'Start...' in the MAC menu bar icon (or top-right) and enter a session password to begin streaming live Telegram, AI turns & CI/CD logs.")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 8)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else if filteredLines.isEmpty {
                        let catLabel = vm.selectedCategories.contains(.all) ? "All" : vm.selectedCategories.map(\.rawValue).sorted().joined(separator: ", ")
                        Text("No logs matching '\(catLabel)' or search filter '\(vm.searchText)'.")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(filteredLines) { item in
                            logRow(for: item)
                                .id(item.id)
                        }
                    }
                }
                .padding(10)
            }
            .onChange(of: appState.logLines.count) { _, newCount in
                if vm.autoScroll && newCount > 0 {
                    proxy.scrollTo(newCount - 1, anchor: .bottom)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(red: 0.05, green: 0.07, blue: 0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    private func logRow(for item: MACParsedLogLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // Source Badge
            HStack(spacing: 3) {
                Image(systemName: item.icon)
                    .font(.system(size: 8.5))
                Text(item.badgeLabel)
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(item.badgeColor.opacity(0.85))
            .cornerRadius(4)
            .frame(width: 66, alignment: .center)

            // Index / line number
            Text(item.lineNumber)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.55))
                .frame(width: 28, alignment: .trailing)

            // Message text
            Text(item.messageText)
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundColor(item.messageColor)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if item.isLoading {
                ProgressView()
                    .controlSize(.mini)
                    .padding(.trailing, 4)
            }
        }
        .padding(.vertical, 1.5)
        .padding(.horizontal, 4)
    }

    private func countForCategory(_ cat: MACLogCategory) -> Int {
        if cat == .all { return appState.logLines.count }
        return parsedLines.filter { $0.source == cat }.count
    }

    private func parseLogLine(_ line: String, index: Int) -> MACParsedLogLine {
        let lower = line.lowercased()
        let isError = line.contains("❌") || line.contains("🔴") || lower.contains("error:") || lower.contains("failed") || lower.contains("fatal") || line.contains("⛔")
        let isSuccess = line.contains("✅") || lower.contains("success") || lower.contains("restored")
        let isWarning = line.contains("⚠️") || lower.contains("conflict") || lower.contains("retrying") || lower.contains("wait")
        let isLoading = lower.contains("...") || lower.contains("in progress") || lower.contains("running") || lower.contains("polling") || lower.contains("dispatching") || lower.contains("triggering")

        // Determine category
        let category: MACLogCategory
        let badgeLabel: String
        let badgeColor: Color
        let icon: String

        if isError {
            category = .errors
            badgeLabel = "ERR"
            badgeColor = .red
            icon = "exclamationmark.triangle.fill"
        } else if line.contains("[telegram]") || lower.contains("@botfather") || line.contains("Telegram Bot") || lower.contains("long-polling") {
            category = .telegram
            badgeLabel = "TG"
            badgeColor = .cyan
            icon = "paperplane.fill"
        } else if line.contains("[agent]") || line.contains("[stage]") || line.contains("[tool]") || lower.contains("agy") || lower.contains("gemini") || lower.contains("claude") || lower.contains("deepseek") || lower.contains("model:") || lower.contains("agent runner") {
            category = .agent
            badgeLabel = line.contains("[tool]") ? "TOOL" : "AGENT"
            badgeColor = line.contains("[tool]") ? Color(red: 0.88, green: 0.38, blue: 0.95) : .purple
            icon = line.contains("[tool]") ? "wrench.and.screwdriver.fill" : "cpu.fill"
        } else if line.contains("[jenkins]") || line.contains("[github]") || line.contains("[gcp]") || line.contains("[ci]") || line.contains("Jenkins") || lower.contains("build #") || lower.contains("ci/cd") {
            category = .cicd
            badgeLabel = line.contains("[github]") ? "GH" : (line.contains("[gcp]") ? "GCP" : "JENKINS")
            badgeColor = isSuccess ? .green : (isError ? .red : .blue)
            icon = "shippingbox.fill"
        } else if line.contains("[git]") || lower.contains("commit") || lower.contains("push") || lower.contains("branch") || lower.contains("git:") {
            category = .git
            badgeLabel = "GIT"
            badgeColor = .mint
            icon = "point.3.connected.trianglepath.dotted"
        } else if line.contains("[MAC]") || lower.contains("sleep") || lower.contains("session auth") || lower.contains("login item") {
            category = .system
            badgeLabel = "MAC"
            badgeColor = isSuccess ? .green : .secondary
            icon = "apple.logo"
        } else {
            category = .system
            badgeLabel = "LOG"
            badgeColor = .secondary.opacity(0.8)
            icon = "terminal"
        }

        // Determine message color
        let msgColor: Color
        if isError {
            msgColor = Color(red: 1.0, green: 0.45, blue: 0.45)
        } else if isSuccess {
            msgColor = Color(red: 0.4, green: 0.9, blue: 0.5)
        } else if isWarning {
            msgColor = Color(red: 1.0, green: 0.78, blue: 0.3)
        } else if category == .telegram {
            msgColor = Color(red: 0.5, green: 0.85, blue: 1.0)
        } else if category == .agent {
            msgColor = Color(red: 0.85, green: 0.72, blue: 1.0)
        } else if category == .cicd {
            msgColor = Color(red: 0.65, green: 0.82, blue: 1.0)
        } else if category == .git {
            msgColor = Color(red: 0.55, green: 0.92, blue: 0.82)
        } else if line.contains("===") || line.contains("---") {
            msgColor = Color.secondary.opacity(0.65)
        } else {
            msgColor = Color.primary.opacity(0.88)
        }

        var cleanMsg = line
        if cleanMsg.hasPrefix("[MAC] ") {
            cleanMsg = String(cleanMsg.dropFirst(6))
        } else if cleanMsg.hasPrefix("[bot] ") {
            cleanMsg = String(cleanMsg.dropFirst(6))
        } else if cleanMsg.hasPrefix("[telegram] ") {
            cleanMsg = String(cleanMsg.dropFirst(11))
        } else if cleanMsg.hasPrefix("[agent] ") {
            cleanMsg = String(cleanMsg.dropFirst(8))
        } else if cleanMsg.hasPrefix("[git] ") {
            cleanMsg = String(cleanMsg.dropFirst(6))
        } else if cleanMsg.hasPrefix("[jenkins] ") {
            cleanMsg = String(cleanMsg.dropFirst(10))
        } else if cleanMsg.hasPrefix("[stage] ") {
            cleanMsg = String(cleanMsg.dropFirst(8))
        }

        return MACParsedLogLine(
            id: index,
            rawText: line,
            source: category,
            badgeLabel: badgeLabel,
            badgeColor: badgeColor,
            icon: icon,
            lineNumber: String(format: "%03d", index + 1),
            messageText: cleanMsg,
            messageColor: msgColor,
            isLoading: isLoading
        )
    }
}
