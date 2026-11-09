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

// MARK: - Root Settings View

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
                case .manageWorkspaces:
                    ManageWorkspacesTabView(appState: appState)
                case .addWorkspace:
                    AddWorkspaceTabView(appState: appState)
                case .manageJenkins:
                    ManageJenkinsTabView(appState: appState)
                case .telegramData:
                    TelegramDataTabView(appState: appState)
                case .tutorial:
                    TutorialTabView(appState: appState)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 920, minHeight: 640)
    }

    private var tabNavigationBar: some View {
        HStack(spacing: 6) {
            tabItemButton(.manageWorkspaces, title: "Manage Workspaces", icon: "folder.badge.gearshape")
            tabItemButton(.addWorkspace, title: "Add Workspace", icon: "plus.rectangle.on.folder")
            tabItemButton(.manageJenkins, title: "Manage Jenkins", icon: "server.rack")
            tabItemButton(.telegramData, title: "Telegram Data", icon: "paperplane.fill")
            tabItemButton(.tutorial, title: "Tutorial", icon: "book.fill")
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
                                        draft.id = MACPathUtils.slugifyWorkspaceId(newVal)
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

                // 2. AI Model & Effort Level (Zero clipping, flush-left dropdown, single-line CLI badge in header)
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

                // 3. Environments & Jenkins Jobs (Zero overlap between label and segmented picker)
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

                // 4. Per-Repository Mapping (Always 100% full width even when 0 repos!)
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
                            vm.showDeleteConfirm = true
                        } label: {
                            Label("Delete Workspace", systemImage: "trash")
                        }
                        .fixedSize()
                        .confirmationDialog(
                            "Remove workspace '\(draft.label)' from MAC?",
                            isPresented: $vm.showDeleteConfirm,
                            titleVisibility: .visible
                        ) {
                            Button("Delete Workspace", role: .destructive) {
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
        .onChange(of: draft.id) { _, _ in
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

// MARK: - Tab 1: Manage Workspaces

private final class ManageWorkspacesVM: ObservableObject {
    @Published var editingDraft: MACWorkspace = MACWorkspace()
}

private struct ManageWorkspacesTabView: View {
    @ObservedObject var appState: MACAppState
    @StateObject private var vm = ManageWorkspacesVM()

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Left Sidebar (Clean crisp custom list without NSSplitView/Vibrancy quirks)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Workspaces (\(appState.config.workspaces.count))")
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button {
                        appState.selectedTab = .addWorkspace
                    } label: {
                        Label("Add", systemImage: "plus")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .controlSize(.small)
                    .fixedSize()
                }
                .padding(.horizontal, 6)
                .padding(.top, 2)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(appState.config.workspaces) { ws in
                            let isSelected = (appState.selectedWorkspaceId == ws.id)
                            Button {
                                appState.selectedWorkspaceId = ws.id
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Text(ws.label)
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundColor(isSelected ? .white : .primary)
                                            .lineLimit(1)
                                        Spacer(minLength: 4)
                                        Text(ws.environmentMode == "multi" ? "Multi" : "Single")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundColor(isSelected ? .white : (ws.environmentMode == "multi" ? .purple : .blue))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(
                                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                                    .fill(isSelected ? Color.white.opacity(0.22) : (ws.environmentMode == "multi" ? Color.purple : Color.blue).opacity(0.16))
                                            )
                                            .fixedSize()
                                    }

                                    Text(ws.displayModelSummary)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(isSelected ? Color.white.opacity(0.88) : .secondary)
                                        .lineLimit(1)

                                    Text(ws.path)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(isSelected ? Color.white.opacity(0.75) : .secondary)
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
                                        .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.09), lineWidth: 1)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.bottom, 8)
                }
            }
            .frame(width: 245)
            .frame(maxHeight: .infinity)
            .padding(.trailing, 10)

            Divider()

            // Right Detail Editor
            Group {
                if let selId = appState.selectedWorkspaceId,
                   appState.config.workspaces.contains(where: { $0.id == selId }) {
                    WorkspaceEditorFormView(
                        draft: $vm.editingDraft,
                        isNewWorkspace: false,
                        onSave: {
                            saveSelectedWorkspace(originalId: selId)
                        },
                        onDelete: {
                            deleteSelectedWorkspace(id: selId)
                        }
                    )
                    .padding(.leading, 14)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 36))
                            .foregroundColor(.secondary)
                        Text("No Workspace Selected")
                            .font(.headline)
                        Button("Add New Workspace") {
                            appState.selectedTab = .addWorkspace
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            syncDraftFromSelection()
        }
        .onChange(of: appState.selectedWorkspaceId) { _, _ in
            syncDraftFromSelection()
        }
    }

    private func syncDraftFromSelection() {
        if appState.selectedWorkspaceId == nil {
            appState.selectedWorkspaceId = appState.config.workspaces.first?.id
        }
        if let selId = appState.selectedWorkspaceId,
           let found = appState.config.workspaces.first(where: { $0.id == selId }) {
            vm.editingDraft = found
        }
    }

    private func saveSelectedWorkspace(originalId: String) {
        var normalized = vm.editingDraft
        normalized.label = normalized.label.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.id = normalized.id.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.id.isEmpty {
            normalized.id = MACPathUtils.slugifyWorkspaceId(normalized.label)
        }
        normalized.path = MACPathUtils.expandPath(normalized.path)
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

        if let idx = appState.config.workspaces.firstIndex(where: { $0.id == originalId }) {
            appState.config.workspaces[idx] = normalized
            appState.selectedWorkspaceId = normalized.id
            appState.saveConfigToDisk(banner: "Saved workspace '\(normalized.label)' (immediately active in Telegram).")
        }
    }

    private func deleteSelectedWorkspace(id: String) {
        let removedLabel = appState.config.workspaces.first(where: { $0.id == id })?.label ?? id
        appState.config.workspaces.removeAll { $0.id == id }
        appState.selectedWorkspaceId = appState.config.workspaces.first?.id
        appState.saveConfigToDisk(banner: "Removed workspace '\(removedLabel)'.")
    }
}

// MARK: - Tab 2: Add New Workspace

private final class AddWorkspaceVM: ObservableObject {
    @Published var newWorkspace = MACWorkspace()
}

private struct AddWorkspaceTabView: View {
    @ObservedObject var appState: MACAppState
    @StateObject private var vm = AddWorkspaceVM()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add New Workspace")
                        .font(.system(size: 15, weight: .bold))
                    Text("Configure folder path, extra --add-dir paths, AI model & level, and Single vs Multi (Staging → Prod) Jenkins jobs.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Reset Form") {
                    resetForm()
                }
                .fixedSize()
            }

            Divider()

            WorkspaceEditorFormView(
                draft: $vm.newWorkspace,
                isNewWorkspace: true,
                onSave: createWorkspace,
                onDelete: nil
            )
        }
    }

    private func createWorkspace() {
        var created = vm.newWorkspace
        created.label = created.label.trimmingCharacters(in: .whitespacesAndNewlines)
        created.path = MACPathUtils.expandPath(created.path)
        let baseSlug = MACPathUtils.slugifyWorkspaceId(created.id.isEmpty ? created.label : created.id)
        var uniqueId = baseSlug
        var counter = 2
        while appState.config.workspaces.contains(where: { $0.id == uniqueId }) {
            uniqueId = "\(baseSlug)-\(counter)"
            counter += 1
        }
        created.id = uniqueId

        if created.repos.isEmpty {
            created.repos = MACPathUtils.discoverGitRepos(
                at: created.path,
                existingRepos: [],
                stagingJobs: created.jenkinsJobs,
                prodJobs: created.prodJenkinsJobs
            )
        }
        for repo in created.repos where repo.deployEnabled {
            let j = repo.jenkinsJob.trimmingCharacters(in: .whitespacesAndNewlines)
            if !j.isEmpty && !created.jenkinsJobs.contains(j) {
                created.jenkinsJobs.append(j)
            }
            if created.environmentMode == "multi" {
                let pj = repo.prodJenkinsJob.trimmingCharacters(in: .whitespacesAndNewlines)
                if !pj.isEmpty && !created.prodJenkinsJobs.contains(pj) {
                    created.prodJenkinsJobs.append(pj)
                }
            }
        }

        appState.config.workspaces.append(created)
        appState.selectedWorkspaceId = created.id
        appState.saveConfigToDisk(banner: "Added workspace '\(created.label)' — ready in Telegram!")
        resetForm()
        appState.selectedTab = .manageWorkspaces
    }

    private func resetForm() {
        vm.newWorkspace = MACWorkspace()
    }
}

// MARK: - Tab 3: Manage Jenkins

private final class ManageJenkinsVM: ObservableObject {
    @Published var draft: MACJenkinsConfig = MACJenkinsConfig()
    @Published var showToken: Bool = false
    @Published var isTesting: Bool = false
    @Published var testResultMessage: String?
    @Published var testSucceeded: Bool = false
    @Published var timeoutMinutes: Int = 25
}

private struct ManageJenkinsTabView: View {
    @ObservedObject var appState: MACAppState
    @StateObject private var vm = ManageJenkinsVM()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                MACSectionCard(title: "Jenkins Server & Credentials", systemImage: "server.rack") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Jenkins Base URL")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField(text: $vm.draft.baseUrl, prompt: Text(verbatim: "https://jenkins.example.com")) {}
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Jenkins Username")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField("tech", text: $vm.draft.username)
                                .textFieldStyle(.roundedBorder)
                        }
                        .frame(width: 240, alignment: .leading)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Jenkins API Token")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            HStack(spacing: 8) {
                                if vm.showToken {
                                    TextField("API Token", text: $vm.draft.apiToken)
                                        .textFieldStyle(.roundedBorder)
                                } else {
                                    SecureField("API Token", text: $vm.draft.apiToken)
                                        .textFieldStyle(.roundedBorder)
                                }
                                Button(vm.showToken ? "Hide" : "Show") {
                                    vm.showToken.toggle()
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
                            TextField("Leave blank if jobs include full folder path", text: $vm.draft.jobPrefix)
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

                    Toggle("Allow self-signed / insecure TLS certificates", isOn: $vm.draft.insecureTls)
                }

                if let msg = vm.testResultMessage {
                    HStack(spacing: 8) {
                        Image(systemName: vm.testSucceeded ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(vm.testSucceeded ? .green : .red)
                        Text(msg)
                            .font(.system(size: 12.5, weight: .medium))
                        Spacer()
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background((vm.testSucceeded ? Color.green : Color.red).opacity(0.12))
                    .cornerRadius(8)
                }

                HStack(spacing: 12) {
                    Button {
                        runConnectionTest()
                    } label: {
                        HStack(spacing: 6) {
                            if vm.isTesting {
                                ProgressView().controlSize(.small)
                                Text("Testing...")
                            } else {
                                Image(systemName: "network")
                                Text("Test Jenkins Connection")
                            }
                        }
                    }
                    .disabled(vm.isTesting || vm.draft.baseUrl.trimmingCharacters(in: .whitespaces).isEmpty)
                    .fixedSize()

                    Spacer()

                    Button("Save Jenkins Settings") {
                        var updated = vm.draft
                        updated.baseUrl = updated.baseUrl.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        updated.username = updated.username.trimmingCharacters(in: .whitespacesAndNewlines)
                        updated.apiToken = updated.apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
                        updated.buildTimeoutMs = vm.timeoutMinutes * 60 * 1000
                        appState.config.jenkins = updated
                        appState.saveConfigToDisk(banner: "Saved Jenkins configuration.")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .fixedSize()
                }
            }
            .padding(.trailing, 6)
        }
        .onAppear {
            vm.draft = appState.config.jenkins
            vm.timeoutMinutes = max(5, vm.draft.buildTimeoutMs / 60_000)
        }
    }

    private func runConnectionTest() {
        vm.isTesting = true
        vm.testResultMessage = nil
        let snapshot = vm.draft
        let viewModel = vm
        Task {
            let res = await JenkinsConnectionTester.testConnection(config: snapshot)
            await MainActor.run {
                viewModel.isTesting = false
                switch res {
                case .success(let info):
                    viewModel.testSucceeded = true
                    viewModel.testResultMessage = info
                case .failure(let err):
                    viewModel.testSucceeded = false
                    viewModel.testResultMessage = err.localizedDescription
                }
            }
        }
    }
}

// MARK: - Tab 4: Telegram Data & Startup

private final class TelegramDataVM: ObservableObject {
    @Published var botToken: String = ""
    @Published var showBotToken: Bool = false
    @Published var telegramApiBaseUrl: String = "https://api.telegram.org"
    @Published var allowedUsersText: String = ""
    @Published var historyCount: Int = 20
    @Published var agyBinPath: String = ""
    @Published var isVerifyingToken: Bool = false
    @Published var tokenCheckMessage: String?
    @Published var tokenCheckSucceeded: Bool = false
}

private struct TelegramDataTabView: View {
    @ObservedObject var appState: MACAppState
    @StateObject private var vm = TelegramDataVM()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                MACSectionCard(title: "Telegram Bot Credentials & Access Control", systemImage: "paperplane.fill") {
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

                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Telegram API Base URL")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField(text: $vm.telegramApiBaseUrl, prompt: Text(verbatim: "https://api.telegram.org")) {}
                                .textFieldStyle(.roundedBorder)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Antigravity CLI Binary Path (agy)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField("/Users/you/.local/bin/agy", text: $vm.agyBinPath)
                                .textFieldStyle(.roundedBorder)
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

                    HStack {
                        Spacer()
                        Button("Save Telegram Data & Startup Settings") {
                            appState.config.telegramBotToken = vm.botToken.trimmingCharacters(in: .whitespacesAndNewlines)
                            let cleanBaseUrl = vm.telegramApiBaseUrl.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                            appState.config.telegramApiBaseUrl = cleanBaseUrl.isEmpty ? "https://api.telegram.org" : cleanBaseUrl
                            appState.config.allowedUserIds = vm.allowedUsersText
                                .components(separatedBy: CharacterSet(charactersIn: ", \n\t"))
                                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                .filter { !$0.isEmpty }
                            appState.config.defaultHistoryCount = vm.historyCount
                            let cleanAgy = vm.agyBinPath.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !cleanAgy.isEmpty {
                                appState.config.agyBin = cleanAgy
                            }
                            appState.saveConfigToDisk(banner: "Saved Telegram Data & Startup settings.")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .fixedSize()
                    }
                }

                MACSectionCard(title: "Live Bot Activity Log", systemImage: "terminal") {
                    HStack(spacing: 8) {
                        Button("Copy Logs") {
                            let pb = NSPasteboard.general
                            pb.clearContents()
                            pb.setString(appState.logLines.joined(separator: "\n"), forType: .string)
                        }
                        .controlSize(.small)
                        .disabled(appState.logLines.isEmpty)
                        .fixedSize()

                        Button("Clear Logs") {
                            appState.clearLogs()
                        }
                        .controlSize(.small)
                        .disabled(appState.logLines.isEmpty)
                        .fixedSize()
                    }
                } content: {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            if appState.logLines.isEmpty {
                                Text("Bot is currently stopped. Click 'Start...' in the MAC menu bar icon (or top-right) and enter a session password.")
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                ForEach(Array(appState.logLines.enumerated()), id: \.offset) { _, line in
                                    Text(line)
                                        .font(.system(size: 11.5, design: .monospaced))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .padding(8)
                    }
                    .frame(minHeight: 150, maxHeight: 220)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.06))
                    .cornerRadius(6)
                }
            }
            .padding(.trailing, 6)
        }
        .onAppear {
            vm.botToken = appState.config.telegramBotToken
            vm.telegramApiBaseUrl = appState.config.telegramApiBaseUrl
            vm.allowedUsersText = appState.config.allowedUserIds.joined(separator: ", ")
            vm.historyCount = appState.config.defaultHistoryCount
            vm.agyBinPath = appState.config.agyBin
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
}

// MARK: - Tab 5: Step-by-Step Setup & Workflow Tutorial

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
                        "Copy the HTTP API Token (looks like 123456789:ABC-DEF...) and paste it into Settings → Telegram Data.",
                        "Click 'Verify Token' and 'Save Telegram Data & Startup Settings'."
                    ],
                    actionTitle: "Open @BotFather",
                    actionURL: "https://t.me/BotFather",
                    secondaryTitle: "Go to Telegram Data →",
                    secondaryAction: { appState.selectedTab = .telegramData }
                )

                tutorialStepCard(
                    stepNumber: "2",
                    title: "Lock Down Allowed Telegram User IDs (Recommended)",
                    icon: "lock.shield.fill",
                    accent: .indigo,
                    bullets: [
                        "Open @userinfobot in Telegram and tap Start — it replies with your numeric Telegram User ID (e.g. 652545688).",
                        "Paste your numeric ID into 'Allowed Telegram User IDs' in the Telegram Data tab (comma-separate multiple IDs if needed).",
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
                        "Open the 'Add Workspace' tab, choose a Workspace Label (shown as a button in Telegram), and click 'Browse...' to pick your project or monorepo folder.",
                        "Click 'Scan Git Repos' to auto-detect single or multi-repo Git folders, and choose the Workspace's default AI Model (Gemini 3.8 Flash, Gemini 4 Argon, Claude Opus 5.5) and effort level (low / medium / high).",
                        "Optional CI/CD: Choose 'Single' (Staging/default Jenkins jobs) or 'Multi (Staging → Production)' to promote verified Staging builds straight to Production from Telegram, and add your server credentials in 'Manage Jenkins'."
                    ],
                    actionTitle: nil,
                    actionURL: nil,
                    secondaryTitle: "Add a Workspace →",
                    secondaryAction: { appState.selectedTab = .addWorkspace }
                )

                tutorialStepCard(
                    stepNumber: "4",
                    title: "Click MAC Next to Your Clock → Start... + Session Password",
                    icon: "menubar.rectangle",
                    accent: .green,
                    bullets: [
                        "Click the bold 'MAC' badge next to your macOS menu bar clock and choose 'Start...'.",
                        "Enter a fresh session password for this run. Passwords live strictly in RAM (never written to disk) and stay valid until you click 'Restart...' or 'Stop'.",
                        "While running, mac.app automatically prevents your MacBook from sleeping so long AI turns and Jenkins builds never drop offline. Clicking 'Stop' restores normal Mac sleep."
                    ],
                    actionTitle: nil,
                    actionURL: nil,
                    secondaryTitle: nil,
                    secondaryAction: nil
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
