import SwiftUI
import AppKit

public final class WorkspaceTimelineVM: ObservableObject {
    @Published public var items: [MACTimelineItem] = []
    @Published public var searchText: String = ""
    @Published public var filterStatus: String = "all"
    @Published public var isReloading: Bool = false
    @Published public var expandedItemIds: Set<String> = []
    @Published public var expandedFileItemIds: Set<String> = []

    public init() {}

    public func toggleMessageExpand(_ id: String) {
        if expandedItemIds.contains(id) {
            expandedItemIds.remove(id)
        } else {
            expandedItemIds.insert(id)
        }
    }

    public func toggleFilesExpand(_ id: String) {
        if expandedFileItemIds.contains(id) {
            expandedFileItemIds.remove(id)
        } else {
            expandedFileItemIds.insert(id)
        }
    }

    @Published public var autoRefreshSecondsRemaining: Int = 60
    private var timer: Timer?

    public func resetCountdown() {
        autoRefreshSecondsRemaining = 60
    }

    public func tick(onRefresh: () -> Void) {
        if autoRefreshSecondsRemaining > 1 {
            autoRefreshSecondsRemaining -= 1
        } else {
            autoRefreshSecondsRemaining = 60
            onRefresh()
        }
    }

    public func startAutoRefresh(onRefresh: @escaping () -> Void) {
        stopAutoRefresh()
        autoRefreshSecondsRemaining = 60
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.tick(onRefresh: onRefresh)
            }
        }
    }

    public func stopAutoRefresh() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        timer?.invalidate()
    }
}

public struct WorkspaceWorkHistoryTimelineView: View {
    public let workspace: MACWorkspace
    public let dataDir: URL

    @StateObject private var vm = WorkspaceTimelineVM()

    public init(workspace: MACWorkspace, dataDir: URL) {
        self.workspace = workspace
        self.dataDir = dataDir
    }

    private var filteredItems: [MACTimelineItem] {
        vm.items.filter { item in
            if !vm.searchText.isEmpty {
                let q = vm.searchText.lowercased()
                let matchesPrompt = item.message.lowercased().contains(q)
                let matchesUser = item.user.lowercased().contains(q)
                let matchesFiles = item.files.contains(where: { $0.lowercased().contains(q) })
                let matchesResult = item.resultLabel.lowercased().contains(q)
                if !matchesPrompt && !matchesUser && !matchesFiles && !matchesResult {
                    return false
                }
            }
            if vm.filterStatus == "success" {
                return item.isSuccess && item.status == .success
            } else if vm.filterStatus == "failed" {
                return !item.isSuccess || item.status == .failed || item.status == .discarded
            } else if vm.filterStatus == "active" {
                return item.status == .working || (item.status != .success && item.status != .failed && item.status != .discarded)
            }
            return true
        }
    }

    private var successCount: Int {
        vm.items.filter { $0.status == .success }.count
    }

    private var failedCount: Int {
        vm.items.filter { $0.status == .failed || $0.status == .discarded }.count
    }

    private var activeCount: Int {
        vm.items.filter {
            if case .working = $0.status { return true }
            if case .queued = $0.status { return true }
            return false
        }.count
    }

    public var body: some View {
        VStack(spacing: 12) {
            // Header stats & filter bar
            headerBar

            Divider()

            // Main timeline list or empty state
            if vm.items.isEmpty {
                emptyStateView
            } else if filteredItems.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                    Text("No Matching History Items")
                        .font(.headline)
                    Text("Try clearing your search query or filter selection.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 40)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(filteredItems.enumerated()), id: \.element.id) { index, item in
                            TimelineItemRow(
                                item: item,
                                workspacePath: workspace.path,
                                isFirst: index == 0,
                                isLast: index == filteredItems.count - 1,
                                isMessageExpanded: vm.expandedItemIds.contains(item.id),
                                isFilesExpanded: vm.expandedFileItemIds.contains(item.id),
                                onToggleMessageExpand: {
                                    vm.toggleMessageExpand(item.id)
                                },
                                onToggleFilesExpand: {
                                    vm.toggleFilesExpand(item.id)
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 24)
                }
            }
        }
        .onAppear {
            reloadTimeline()
            vm.startAutoRefresh {
                reloadTimeline()
            }
        }
        .onDisappear {
            vm.stopAutoRefresh()
        }
        .onChange(of: workspace.id) { _, _ in
            vm.resetCountdown()
            reloadTimeline()
        }
    }

    private var headerBar: some View {
        HStack(spacing: 10) {
            // Stats pills
            HStack(spacing: 6) {
                statPill(label: "Total", count: vm.items.count, color: .secondary)

                if activeCount > 0 {
                    statPill(label: "Active", count: activeCount, color: .blue)
                }
                statPill(label: "Success", count: successCount, color: .green)
                if failedCount > 0 {
                    statPill(label: "Failed/Reverted", count: failedCount, color: .red)
                }
            }

            Spacer()

            // Refresh button (placed before filter, with 60s countdown counter)
            Button {
                vm.resetCountdown()
                reloadTimeline()
            } label: {
                HStack(spacing: 4) {
                    if vm.isReloading {
                        ProgressView().controlSize(.mini)
                        Text("Refreshing...")
                    } else {
                        Image(systemName: "arrow.clockwise")
                        Text("Refresh (\(vm.autoRefreshSecondsRemaining)s)")
                    }
                }
                .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(vm.isReloading)
            .help("Refresh work history now (auto-refreshes in \(vm.autoRefreshSecondsRemaining)s)")

            // Search filter field
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 11))
                TextField("Search messages, files, users...", text: $vm.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
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
            .padding(.vertical, 5)
            .frame(width: 200)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            )
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
    }

    private func statPill(label: String, count: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
            Text("\(count)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.08))
        .cornerRadius(6)
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 40))
                .foregroundColor(.secondary)

            Text("No Work History Yet")
                .font(.system(size: 15, weight: .bold))

            Text("Prompts, agent executions, modified files, and queued requests for \"\(workspace.label)\" will appear here in an interactive timeline as they run.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            Button {
                reloadTimeline()
            } label: {
                Label("Check for Updates", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 48)
    }

    private func reloadTimeline() {
        vm.isReloading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = MACWorkspaceTimelineReader.loadTimeline(workspace: workspace, dataDir: dataDir)
            DispatchQueue.main.async {
                self.vm.items = loaded
                self.vm.isReloading = false
            }
        }
    }
}

// MARK: - Single Timeline Row with Vertical Line & Node

private struct TimelineItemRow: View {
    let item: MACTimelineItem
    let workspacePath: String
    let isFirst: Bool
    let isLast: Bool
    let isMessageExpanded: Bool
    let isFilesExpanded: Bool
    let onToggleMessageExpand: () -> Void
    let onToggleFilesExpand: () -> Void

    private var nodeColor: Color {
        switch item.status {
        case .working: return .blue
        case .queued: return .purple
        case .success: return .green
        case .failed: return .red
        case .discarded: return .orange
        }
    }

    private var nodeIcon: String {
        switch item.status {
        case .working: return "hourglass"
        case .queued: return "tray.and.arrow.down.fill"
        case .success: return "checkmark"
        case .failed: return "xmark"
        case .discarded: return "trash.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Left: Timeline vertical line & circular node
            VStack(spacing: 0) {
                // Top line segment
                Rectangle()
                    .fill(isFirst ? Color.clear : Color.primary.opacity(0.18))
                    .frame(width: 2, height: 14)

                // Circle node
                ZStack {
                    Circle()
                        .fill(nodeColor.opacity(0.15))
                        .frame(width: 26, height: 26)

                    Circle()
                        .strokeBorder(nodeColor, lineWidth: 1.5)
                        .frame(width: 26, height: 26)

                    if case .working = item.status {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: nodeIcon)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(nodeColor)
                    }
                }

                // Bottom line segment
                Rectangle()
                    .fill(isLast ? Color.clear : Color.primary.opacity(0.18))
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: 28)

            // Right: Content card
            VStack(alignment: .leading, spacing: 8) {
                // Top row: User, Date, Result, Elapsed Time
                HStack(alignment: .center, spacing: 8) {
                    // User badge
                    HStack(spacing: 4) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.accentColor)
                        Text(item.user)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.primary)
                    }

                    Text("•")
                        .foregroundColor(.secondary.opacity(0.5))

                    // Date
                    HStack(spacing: 4) {
                        Image(systemName: "calendar")
                            .font(.system(size: 10))
                        Text(item.formattedDate)
                            .font(.system(size: 11))
                    }
                    .foregroundColor(.secondary)

                    Spacer()

                    // Result badge
                    resultBadge

                    // Elapsed Time pill
                    HStack(spacing: 3) {
                        Image(systemName: "stopwatch")
                            .font(.system(size: 9))
                        Text(item.elapsedTime)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.06))
                    .cornerRadius(5)
                    .foregroundColor(.secondary)
                }

                // Message Text
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.message)
                        .font(.system(size: 12.5))
                        .lineLimit(isMessageExpanded ? nil : 4)
                        .textSelection(.enabled)
                        .foregroundColor(.primary)

                    if item.message.count > 180 {
                        Button {
                            onToggleMessageExpand()
                        } label: {
                            Text(isMessageExpanded ? "Show less" : "Show full message...")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.035))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )

                // Files section
                if !item.files.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.on.doc.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            Text("Files (\(item.files.count)):")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.secondary)

                            Spacer()

                            if item.files.count > 3 {
                                Button {
                                    onToggleFilesExpand()
                                } label: {
                                    Text(isFilesExpanded ? "Show fewer" : "Show all \(item.files.count) files")
                                        .font(.system(size: 10.5, weight: .medium))
                                        .foregroundColor(.accentColor)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        let displayedFiles = isFilesExpanded ? item.files : Array(item.files.prefix(3))
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(displayedFiles, id: \.self) { file in
                                HStack(spacing: 5) {
                                    Image(systemName: "doc.text")
                                        .font(.system(size: 9.5))
                                        .foregroundColor(.secondary)
                                    Text(file)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()

                                    // Reveal in Finder if file exists on disk
                                    if !workspacePath.isEmpty {
                                        Button {
                                            revealFile(relativePath: file)
                                        } label: {
                                            Image(systemName: "arrow.up.right.square")
                                                .font(.system(size: 10))
                                                .foregroundColor(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                        .help("Show in Finder")
                                    }
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.primary.opacity(0.03))
                                .cornerRadius(4)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.02))
                    .cornerRadius(6)
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 9))
                        Text("Files: None modified")
                            .font(.system(size: 10.5))
                    }
                    .foregroundColor(.secondary.opacity(0.7))
                }

                // Commits section (if present)
                if !item.commits.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)

                        ForEach(item.commits.prefix(2)) { c in
                            HStack(spacing: 4) {
                                Text(c.branch)
                                    .font(.system(size: 10.5, weight: .semibold))
                                Text("@\(c.shortSha)")
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.04))
                            .cornerRadius(4)
                        }

                        if item.commits.count > 2 {
                            Text("+\(item.commits.count - 2) more")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.02))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(nodeColor.opacity(0.2), lineWidth: 1)
            )
            .padding(.bottom, 12)
        }
    }

    private var resultBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: item.status.systemImage)
                .font(.system(size: 10, weight: .bold))
            Text(item.resultLabel)
                .font(.system(size: 11, weight: .bold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(nodeColor.opacity(0.12))
        .foregroundColor(nodeColor)
        .cornerRadius(6)
    }

    private func revealFile(relativePath: String) {
        let fullPath = URL(fileURLWithPath: workspacePath).appendingPathComponent(relativePath).path
        if FileManager.default.fileExists(atPath: fullPath) {
            NSWorkspace.shared.selectFile(fullPath, inFileViewerRootedAtPath: workspacePath)
        } else if FileManager.default.fileExists(atPath: workspacePath) {
            NSWorkspace.shared.selectFile(workspacePath, inFileViewerRootedAtPath: "")
        }
    }
}
