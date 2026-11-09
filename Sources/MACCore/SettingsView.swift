import AppKit
import Combine
import SwiftUI

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
                HStack {
                    Text(banner)
                        .font(.system(size: 12.5, weight: .medium))
                    Spacer()
                    Button("Dismiss") {
                        appState.statusBannerMessage = nil
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11.5))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(Color.accentColor.opacity(0.10))
                Divider()
            }

            TabView(selection: $appState.selectedTab) {
                ManageWorkspacesTabView(appState: appState)
                    .tabItem {
                        Label("Manage Workspaces", systemImage: "folder.badge.gearshape")
                    }
                    .tag(MACSettingsTab.manageWorkspaces)

                AddWorkspaceTabView(appState: appState)
                    .tabItem {
                        Label("Add Workspace", systemImage: "plus.rectangle.on.folder")
                    }
                    .tag(MACSettingsTab.addWorkspace)

                ManageJenkinsTabView(appState: appState)
                    .tabItem {
                        Label("Manage Jenkins", systemImage: "server.rack")
                    }
                    .tag(MACSettingsTab.manageJenkins)

                TelegramDataTabView(appState: appState)
                    .tabItem {
                        Label("Telegram Data", systemImage: "paperplane.fill")
                    }
                    .tag(MACSettingsTab.telegramData)

                TutorialTabView(appState: appState)
                    .tabItem {
                        Label("Tutorial", systemImage: "book.fill")
                    }
                    .tag(MACSettingsTab.tutorial)
            }
            .padding(14)
        }
        .frame(minWidth: 940, minHeight: 650)
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("MAC — Mobile Agent Control")
                        .font(.system(size: 15, weight: .bold))
                    Text(appState.status.statusMenuTitle)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(statusBadgeColor.opacity(0.15))
                        .cornerRadius(6)
                }
                Text("Data directory: \(appState.configStore.dataDir.path)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if appState.status.isRunningOrStarting {
                Button("Restart...") {
                    onRestartRequested()
                }
                Button("Stop") {
                    onStopRequested()
                }
                .tint(.red)
            } else {
                Button("Start...") {
                    onStartRequested()
                }
                .buttonStyle(.borderedProminent)
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 1. Identity & Paths
                GroupBox(label: Label("Workspace Name & Paths", systemImage: "folder")) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
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
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Workspace ID")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                TextField("e.g. crypto-fusion", text: $draft.id)
                                    .textFieldStyle(.roundedBorder)
                            }
                            .frame(width: 200)
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
                                Button("Scan Git Repos") {
                                    rescanRepos()
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Extra Allowed Paths (--add-dir, optional)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            if !draft.extraDirs.isEmpty {
                                ForEach(Array(draft.extraDirs.enumerated()), id: \.offset) { idx, dirPath in
                                    HStack {
                                        Text(dirPath)
                                            .font(.system(size: 12, design: .monospaced))
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer()
                                        Button(role: .destructive) {
                                            draft.extraDirs.remove(at: idx)
                                        } label: {
                                            Image(systemName: "trash")
                                        }
                                        .buttonStyle(.borderless)
                                    }
                                    .padding(.vertical, 2)
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
                                Button("Browse Extra...") {
                                    if let chosen = chooseDirectory(initialPath: draft.path) {
                                        if !draft.extraDirs.contains(chosen) {
                                            draft.extraDirs.append(chosen)
                                        }
                                    }
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Live Staging URL (optional, shown after Jenkins build)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField("https://staging.example.com", text: $draft.liveUrl)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    .padding(8)
                }

                // 2. AI Model & Level
                GroupBox(label: Label("AI Model & Effort Level", systemImage: "brain")) {
                    HStack(spacing: 20) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("AI Model Family")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Picker("", selection: $vm.selectedModelFamily) {
                                ForEach(MACModelOption.allOptions) { opt in
                                    Text(opt.label).tag(opt.id)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 240)
                            .onChange(of: vm.selectedModelFamily) { _, _ in syncModelFields() }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Effort Level")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Picker("", selection: $vm.selectedModelLevel) {
                                ForEach(MACModelOption.validLevels, id: \.self) { lvl in
                                    Text(lvl).tag(lvl)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 220)
                            .onChange(of: vm.selectedModelLevel) { _, _ in syncModelFields() }
                        }

                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Effective CLI Model ID")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(draft.model)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        }
                    }
                    .padding(8)
                }

                // 3. Environments & Jenkins Jobs (Staging vs Multi Staging -> Prod)
                GroupBox(label: Label("Environments & Jenkins CI/CD Jobs", systemImage: "shippingbox")) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 16) {
                            Text("Environment Mode:")
                                .font(.system(size: 12.5, weight: .medium))
                            Picker("", selection: $draft.environmentMode) {
                                Text("Single (Staging / Default)").tag("single")
                                Text("Multi (Staging → Production)").tag("multi")
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 340)
                            Spacer()
                        }

                        Divider()

                        // Staging Jenkins Jobs
                        VStack(alignment: .leading, spacing: 6) {
                            Text(draft.environmentMode == "multi" ? "Staging Jenkins Jobs" : "Jenkins Jobs (Staging / Default)")
                                .font(.system(size: 12.5, weight: .semibold))
                            if !draft.jenkinsJobs.isEmpty {
                                ForEach(Array(draft.jenkinsJobs.enumerated()), id: \.offset) { idx, job in
                                    HStack {
                                        Text(job)
                                            .font(.system(size: 12, design: .monospaced))
                                        Spacer()
                                        Button(role: .destructive) {
                                            draft.jenkinsJobs.remove(at: idx)
                                        } label: {
                                            Image(systemName: "minus.circle.fill")
                                        }
                                        .buttonStyle(.borderless)
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
                            }
                        }

                        // Production Jenkins Jobs (Multi mode)
                        if draft.environmentMode == "multi" {
                            Divider()
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Production Jenkins Jobs (triggered when clicking '🚀 Yes, deploy on prod')")
                                    .font(.system(size: 12.5, weight: .semibold))
                                if !draft.prodJenkinsJobs.isEmpty {
                                    ForEach(Array(draft.prodJenkinsJobs.enumerated()), id: \.offset) { idx, job in
                                        HStack {
                                            Text(job)
                                                .font(.system(size: 12, design: .monospaced))
                                            Spacer()
                                            Button(role: .destructive) {
                                                draft.prodJenkinsJobs.remove(at: idx)
                                            } label: {
                                                Image(systemName: "minus.circle.fill")
                                            }
                                            .buttonStyle(.borderless)
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
                                }
                            }
                        }
                    }
                    .padding(8)
                }

                // 4. Per-Repository Mapping
                GroupBox(label: Label("Git Repositories in Workspace (\(draft.repos.count))", systemImage: "point.3.connected.trianglepath.dotted")) {
                    VStack(alignment: .leading, spacing: 8) {
                        if draft.repos.isEmpty {
                            Text("No Git repositories scanned yet. Pick a Workspace Folder Path and click 'Scan Git Repos'.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.vertical, 6)
                        } else {
                            ForEach($draft.repos) { $repo in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 10) {
                                        Toggle("Deploy", isOn: $repo.deployEnabled)
                                            .toggleStyle(.checkbox)
                                            .frame(width: 70, alignment: .leading)
                                        Text(repo.name)
                                            .font(.system(size: 12.5, weight: .semibold))
                                            .frame(width: 155, alignment: .leading)
                                        TextField("Branch (blank = current)", text: $repo.branch)
                                            .textFieldStyle(.roundedBorder)
                                            .frame(width: 150)
                                        Text(repo.path)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer()
                                    }
                                    HStack(spacing: 10) {
                                        Spacer().frame(width: 70)
                                        TextField("Staging Jenkins Job (e.g. HS-1/project/service)", text: $repo.jenkinsJob)
                                            .textFieldStyle(.roundedBorder)
                                            .onChange(of: repo.jenkinsJob) { _, val in
                                                if !val.trimmingCharacters(in: .whitespaces).isEmpty && !repo.deployEnabled {
                                                    repo.deployEnabled = true
                                                }
                                            }
                                        if draft.environmentMode == "multi" {
                                            TextField("Production Jenkins Job", text: $repo.prodJenkinsJob)
                                                .textFieldStyle(.roundedBorder)
                                        }
                                    }
                                }
                                .padding(6)
                                .background(Color.secondary.opacity(0.06))
                                .cornerRadius(6)
                            }
                        }
                    }
                    .padding(8)
                }

                // 5. Save / Delete Action Row
                HStack {
                    if let onDelete = onDelete {
                        Button(role: .destructive) {
                            vm.showDeleteConfirm = true
                        } label: {
                            Label("Delete Workspace", systemImage: "trash")
                        }
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
                    .disabled(draft.label.trimmingCharacters(in: .whitespaces).isEmpty || draft.path.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.bottom, 8)
            }
            .padding(.trailing, 6)
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
        HSplitView {
            // Left Sidebar
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Workspaces (\(appState.config.workspaces.count))")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button {
                        appState.selectedTab = .addWorkspace
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("Add New Workspace")
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)

                List(selection: $appState.selectedWorkspaceId) {
                    ForEach(appState.config.workspaces) { ws in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(ws.label)
                                    .font(.system(size: 13, weight: .semibold))
                                Spacer()
                                Text(ws.environmentMode == "multi" ? "Multi" : "Single")
                                    .font(.system(size: 10, weight: .bold))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background((ws.environmentMode == "multi" ? Color.purple : Color.blue).opacity(0.18))
                                    .cornerRadius(4)
                            }
                            Text(ws.displayModelSummary)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            Text(ws.path)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .padding(.vertical, 3)
                        .tag(Optional(ws.id))
                    }
                }
                .listStyle(.sidebar)
            }
            .frame(minWidth: 230, idealWidth: 255, maxWidth: 300)

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
                    .padding(.leading, 12)
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
                        .font(.headline)
                    Text("Configure folder path, extra --add-dir paths, AI model & level, and Single vs Multi (Staging → Prod) Jenkins jobs.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Reset Form") {
                    resetForm()
                }
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
            VStack(alignment: .leading, spacing: 16) {
                GroupBox(label: Label("Jenkins Server & Credentials", systemImage: "server.rack")) {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Jenkins Base URL")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField("https://jenkins.example.com", text: $vm.draft.baseUrl)
                                .textFieldStyle(.roundedBorder)
                        }

                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Jenkins Username")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                TextField("tech", text: $vm.draft.username)
                                    .textFieldStyle(.roundedBorder)
                            }
                            .frame(width: 240)

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Jenkins API Token")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                HStack {
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
                                }
                            }
                        }

                        HStack(spacing: 20) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Default Job Folder Prefix (optional)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                TextField("Leave blank if jobs include full folder path", text: $vm.draft.jobPrefix)
                                    .textFieldStyle(.roundedBorder)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Build Timeout (minutes)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Stepper("\(vm.timeoutMinutes) min", value: $vm.timeoutMinutes, in: 5...120, step: 5)
                                    .frame(width: 150)
                            }
                        }

                        Toggle("Allow self-signed / insecure TLS certificates", isOn: $vm.draft.insecureTls)
                    }
                    .padding(10)
                }

                if let msg = vm.testResultMessage {
                    HStack {
                        Image(systemName: vm.testSucceeded ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(vm.testSucceeded ? .green : .red)
                        Text(msg)
                            .font(.system(size: 12.5, weight: .medium))
                        Spacer()
                    }
                    .padding(10)
                    .background((vm.testSucceeded ? Color.green : Color.red).opacity(0.12))
                    .cornerRadius(8)
                }

                HStack(spacing: 12) {
                    Button {
                        runConnectionTest()
                    } label: {
                        if vm.isTesting {
                            ProgressView().controlSize(.small)
                            Text("Testing...")
                        } else {
                            Label("Test Jenkins Connection", systemImage: "network")
                        }
                    }
                    .disabled(vm.isTesting || vm.draft.baseUrl.trimmingCharacters(in: .whitespaces).isEmpty)

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
                }
            }
            .padding(4)
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
                GroupBox(label: Label("Telegram Bot Credentials & Access Control", systemImage: "paperplane.fill")) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Configure your @BotFather API token and who can control your Workspaces on Telegram.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button("How to get Token & User ID? Open Tutorial →") {
                                appState.selectedTab = .tutorial
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                        }

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
                                Button {
                                    verifyBotToken()
                                } label: {
                                    if vm.isVerifyingToken {
                                        ProgressView().controlSize(.small)
                                        Text("Verifying...")
                                    } else {
                                        Label("Verify Token", systemImage: "checkmark.shield")
                                    }
                                }
                                .disabled(vm.isVerifyingToken || vm.botToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
                            .padding(8)
                            .background((vm.tokenCheckSucceeded ? Color.green : Color.red).opacity(0.12))
                            .cornerRadius(6)
                        }

                        HStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Allowed Telegram User IDs (comma-separated numeric IDs, blank = anyone with session password)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                TextField("e.g. 652545688", text: $vm.allowedUsersText)
                                    .textFieldStyle(.roundedBorder)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Latest Messages Count (X)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Stepper("\(vm.historyCount) messages", value: $vm.historyCount, in: 1...50)
                                    .frame(width: 160)
                            }
                        }

                        HStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Telegram API Base URL")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                TextField("https://api.telegram.org", text: $vm.telegramApiBaseUrl)
                                    .textFieldStyle(.roundedBorder)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Antigravity CLI Binary Path (agy)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                TextField("/Users/you/.local/bin/agy", text: $vm.agyBinPath)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }

                        Divider()

                        HStack(spacing: 24) {
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
                                Text(appState.isSleepPrevented ? "Mac Sleep Prevented (Active)" : "Sleep Prevention Standby (Active when Started)")
                                    .font(.caption)
                                    .foregroundColor(appState.isSleepPrevented ? .primary : .secondary)
                            }
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
                        }
                    }
                    .padding(8)
                }

                GroupBox(label: Label("Live Bot Activity Log", systemImage: "terminal")) {
                    VStack(alignment: .leading, spacing: 6) {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                if appState.logLines.isEmpty {
                                    Text("Bot is currently stopped. Click 'Start...' in the MAC menu bar icon (or top-right) and enter a session password.")
                                        .font(.system(size: 11.5, design: .monospaced))
                                        .foregroundColor(.secondary)
                                } else {
                                    ForEach(Array(appState.logLines.enumerated()), id: \.offset) { _, line in
                                        Text(line)
                                            .font(.system(size: 11.5, design: .monospaced))
                                            .textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                            .padding(6)
                        }
                        .frame(minHeight: 150, maxHeight: 220)
                        .background(Color.black.opacity(0.05))
                        .cornerRadius(6)

                        HStack {
                            Button("Copy Logs") {
                                let pb = NSPasteboard.general
                                pb.clearContents()
                                pb.setString(appState.logLines.joined(separator: "\n"), forType: .string)
                            }
                            .disabled(appState.logLines.isEmpty)

                            Button("Clear Logs") {
                                appState.clearLogs()
                            }
                            .disabled(appState.logLines.isEmpty)

                            Spacer()
                        }
                    }
                    .padding(6)
                }
            }
            .padding(.trailing, 4)
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
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Quick Setup & Telegram Workspace Control Guide")
                            .font(.system(size: 16, weight: .bold))
                        Text("Follow these 5 quick steps to control your local macOS Workspaces, Git branches, and Staging → Prod Jenkins builds from Telegram.")
                            .font(.system(size: 12.5))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(.bottom, 2)

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

                GroupBox(label: Label("Telegram Controls & Slash Commands Cheat Sheet", systemImage: "command.square.fill")) {
                    VStack(alignment: .leading, spacing: 6) {
                        commandRow("/start", "Authenticate your session and open the Workspace selector")
                        commandRow("🔀 Switch Workspace  (/workspaces)", "Switch between your configured Workspaces without losing pending state")
                        commandRow("⚙️ Settings  (/settings, /model)", "Switch AI Model, effort level (low/medium/high), or view 📜 Last Messages")
                        commandRow("🆕 New Chat  (/newchat)", "Start a brand-new Antigravity conversation in the active Workspace")
                        commandRow("/history", "Read the latest X user & agent messages from the active conversation")
                        commandRow("/lock", "Lock your Telegram session immediately until you re-enter the password")
                    }
                    .padding(8)
                }
            }
            .padding(.trailing, 6)
            .padding(.bottom, 8)
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
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
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

                    Spacer()

                    if let actionTitle = actionTitle, let urlStr = actionURL, let url = URL(string: urlStr) {
                        Button(actionTitle) {
                            NSWorkspace.shared.open(url)
                        }
                        .controlSize(.small)
                    }
                    if let secondaryTitle = secondaryTitle, let secondaryAction = secondaryAction {
                        Button(secondaryTitle) {
                            secondaryAction()
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(bullets.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .top, spacing: 7) {
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
            }
            .padding(6)
        }
    }

    private func commandRow(_ cmd: String, _ desc: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(cmd)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .frame(width: 255, alignment: .leading)
            Text(desc)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer()
        }
    }
}
