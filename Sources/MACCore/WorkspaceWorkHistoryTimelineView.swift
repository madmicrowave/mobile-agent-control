import SwiftUI
import AppKit

public final class WorkspaceTimelineVM: ObservableObject {
    public static let defaultHistoryLimit: Int = 100
    public static let allowedLimits: [Int] = [100, 500, 1000, 3000]

    @Published public var items: [MACTimelineItem] = []
    @Published public var searchText: String = ""
    @Published public var filterStatus: String = "all"
    @Published public var isReloading: Bool = false
    @Published public var expandedItemIds: Set<String> = []
    @Published public var expandedFileItemIds: Set<String> = []
    @Published public var previewingFile: FilePreviewItem?
    @Published public var historyLimit: Int

    public init() {
        let stored = UserDefaults.standard.integer(forKey: "MACWorkHistoryLimit")
        self.historyLimit = Self.allowedLimits.contains(stored) ? stored : Self.defaultHistoryLimit
    }

    public func setHistoryLimit(_ newLimit: Int) {
        let val = Self.allowedLimits.contains(newLimit) ? newLimit : Self.defaultHistoryLimit
        self.historyLimit = val
        UserDefaults.standard.set(val, forKey: "MACWorkHistoryLimit")
    }

    public func openFilePreview(file: String, workspace: MACWorkspace) {
        self.previewingFile = FilePreviewItem(relativePath: file, workspace: workspace)
    }

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
                                workspace: workspace,
                                isFirst: index == 0,
                                isLast: index == filteredItems.count - 1,
                                isMessageExpanded: vm.expandedItemIds.contains(item.id),
                                isFilesExpanded: vm.expandedFileItemIds.contains(item.id),
                                onToggleMessageExpand: {
                                    vm.toggleMessageExpand(item.id)
                                },
                                onToggleFilesExpand: {
                                    vm.toggleFilesExpand(item.id)
                                },
                                onViewFile: { file in
                                    vm.openFilePreview(file: file, workspace: workspace)
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 24)
                }
            }
        }
        .sheet(item: $vm.previewingFile) { preview in
            MACFilePreviewSheet(preview: preview, workspace: workspace)
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
        HStack(spacing: 8) {
            // Stats pills (compact T / A / S with hover tooltips)
            HStack(spacing: 6) {
                statPill(short: "T", full: "Total", count: vm.items.count, color: .secondary)

                if activeCount > 0 {
                    statPill(short: "A", full: "Active", count: activeCount, color: .blue)
                }
                statPill(short: "S", full: "Success", count: successCount, color: .green)
                if failedCount > 0 {
                    statPill(short: "F", full: "Failed / Reverted", count: failedCount, color: .red)
                }
            }
            .lineLimit(1)
            .fixedSize()

            // Buffer limit menu aligned left directly beside stats pills
            bufferLimitMenu

            Spacer()

            // Refresh button (same height: 26 as filter input)
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
                .font(.system(size: 11.5, weight: .medium))
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .frame(height: 26)
            .disabled(vm.isReloading)
            .help("Refresh work history now (auto-refreshes in \(vm.autoRefreshSecondsRemaining)s)")

            // Search filter field (same height: 26 as refresh button)
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
            .frame(width: 200, height: 26)
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

    private func statPill(short: String, full: String, count: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(short)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .lineLimit(1)
            Text("\(count)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(color)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .frame(height: 26)
        .background(color.opacity(0.08))
        .cornerRadius(6)
        .fixedSize()
        .help(full)
    }

    private var formattedHistoryLimit: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: vm.historyLimit)) ?? "\(vm.historyLimit)"
    }

    private var bufferLimitMenu: some View {
        Menu {
            let currentLimit = vm.historyLimit
            Button(currentLimit == 100 ? "✓ 100 messages (default)" : "100 messages (default)") {
                vm.setHistoryLimit(100)
                reloadTimeline()
            }
            Button(currentLimit == 500 ? "✓ 500 messages" : "500 messages") {
                vm.setHistoryLimit(500)
                reloadTimeline()
            }
            Button(currentLimit == 1000 ? "✓ 1,000 messages" : "1,000 messages") {
                vm.setHistoryLimit(1000)
                reloadTimeline()
            }
            Button(currentLimit == 3000 ? "✓ 3,000 messages" : "3,000 messages") {
                vm.setHistoryLimit(3000)
                reloadTimeline()
            }
        } label: {
            HStack(spacing: 5) {
                Text("Buffer: \(vm.items.count) / \(formattedHistoryLimit)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                if vm.items.count >= vm.historyLimit && !vm.items.isEmpty {
                    Text("(Full)")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundColor(.orange)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8))
            }
            .foregroundColor(.secondary)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Work history buffer limit (persisted across sessions)")
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
        let limit = vm.historyLimit
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = MACWorkspaceTimelineReader.loadTimeline(workspace: workspace, dataDir: dataDir, limit: limit)
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
    let workspace: MACWorkspace
    let isFirst: Bool
    let isLast: Bool
    let isMessageExpanded: Bool
    let isFilesExpanded: Bool
    let onToggleMessageExpand: () -> Void
    let onToggleFilesExpand: () -> Void
    let onViewFile: (String) -> Void

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
                // Top row: User, Date, Files badge, Result, Elapsed Time
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

                    // Files pill if present
                    if !item.files.isEmpty {
                        Button {
                            onToggleFilesExpand()
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "doc.text")
                                    .font(.system(size: 9))
                                Text("\(item.files.count) file\(item.files.count == 1 ? "" : "s")")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.primary.opacity(0.06))
                            .cornerRadius(5)
                            .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Toggle files list (\(item.files.count) files)")
                    }

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
                                HStack(spacing: 6) {
                                    Image(systemName: fileIcon(for: file))
                                        .font(.system(size: 9.5))
                                        .foregroundColor(.secondary)
                                    Text(file)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)

                                    Spacer()

                                    // View file button (in-app viewer)
                                    Button {
                                        onViewFile(file)
                                    } label: {
                                        HStack(spacing: 3) {
                                            Image(systemName: "eye")
                                                .font(.system(size: 9.5))
                                            Text("View")
                                                .font(.system(size: 10.5, weight: .medium))
                                        }
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2.5)
                                        .background(Color.primary.opacity(0.06))
                                        .cornerRadius(4)
                                    }
                                    .buttonStyle(.plain)
                                    .help("View file content right here")

                                    // Open in Default App
                                    Button {
                                        openInDefaultApp(relativePath: file)
                                    } label: {
                                        Image(systemName: "arrow.up.right.square")
                                            .font(.system(size: 10.5))
                                            .foregroundColor(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Open in default editor or viewer")

                                    // Reveal in Finder if file exists on disk
                                    Button {
                                        revealFile(relativePath: file)
                                    } label: {
                                        Image(systemName: "folder")
                                            .font(.system(size: 10.5))
                                            .foregroundColor(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Show in Finder")
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
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

    private func fileIcon(for file: String) -> String {
        let ext = URL(fileURLWithPath: file).pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "js", "mjs", "cjs", "jsx", "ts", "tsx": return "curlybraces"
        case "html", "htm": return "chevron.left.forwardslash.chevron.right"
        case "css", "scss", "sass", "less": return "paintpalette"
        case "json", "yaml", "yml", "xml", "plist": return "slider.horizontal.3"
        case "md", "txt", "rtf": return "doc.plaintext"
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "ico": return "photo"
        case "sh", "bash", "zsh": return "terminal"
        default: return "doc.text"
        }
    }

    private func resolvePath(relativePath: String) -> String? {
        MACWorkspaceTimelineReader.resolveFilePath(file: relativePath, workspace: workspace)
    }

    private func openInDefaultApp(relativePath: String) {
        if let resolved = resolvePath(relativePath: relativePath) {
            NSWorkspace.shared.open(URL(fileURLWithPath: resolved))
        } else {
            let full = URL(fileURLWithPath: workspace.path).appendingPathComponent(relativePath).path
            if FileManager.default.fileExists(atPath: full) {
                NSWorkspace.shared.open(URL(fileURLWithPath: full))
            }
        }
    }

    private func revealFile(relativePath: String) {
        if let resolved = resolvePath(relativePath: relativePath) {
            NSWorkspace.shared.selectFile(resolved, inFileViewerRootedAtPath: "")
        } else {
            let fullPath = URL(fileURLWithPath: workspace.path).appendingPathComponent(relativePath).path
            if FileManager.default.fileExists(atPath: fullPath) {
                NSWorkspace.shared.selectFile(fullPath, inFileViewerRootedAtPath: workspace.path)
            } else if FileManager.default.fileExists(atPath: workspace.path) {
                NSWorkspace.shared.selectFile(workspace.path, inFileViewerRootedAtPath: "")
            }
        }
    }
}

// MARK: - File Preview Models & Sheet

public struct FilePreviewItem: Identifiable, Equatable {
    public let id: String
    public let fileName: String
    public let relativePath: String
    public let absolutePath: String?
    public let fileExists: Bool
    public let content: String?
    public let fileSizeFormatted: String
    public let lineCount: Int?
    public let isImage: Bool
    public let error: String?

    public init(relativePath: String, workspace: MACWorkspace) {
        self.id = relativePath
        self.relativePath = relativePath
        self.fileName = URL(fileURLWithPath: relativePath).lastPathComponent

        let resolved = MACWorkspaceTimelineReader.resolveFilePath(file: relativePath, workspace: workspace)
        self.absolutePath = resolved

        let fm = FileManager.default
        if let resolved, fm.fileExists(atPath: resolved) {
            self.fileExists = true
            let ext = URL(fileURLWithPath: resolved).pathExtension.lowercased()
            let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "ico", "icns", "tiff"]
            self.isImage = imageExtensions.contains(ext)

            if let attrs = try? fm.attributesOfItem(atPath: resolved),
               let sizeNum = attrs[.size] as? NSNumber {
                let formatter = ByteCountFormatter()
                formatter.countStyle = .file
                self.fileSizeFormatted = formatter.string(fromByteCount: sizeNum.int64Value)
            } else {
                self.fileSizeFormatted = ""
            }

            if !self.isImage {
                if let data = try? Data(contentsOf: URL(fileURLWithPath: resolved)),
                   data.count <= 2 * 1024 * 1024,
                   let str = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) ?? String(data: data, encoding: .isoLatin1) {
                    self.content = str
                    self.lineCount = str.components(separatedBy: "\n").count
                    self.error = nil
                } else if let data = try? Data(contentsOf: URL(fileURLWithPath: resolved)), data.count > 2 * 1024 * 1024 {
                    self.content = nil
                    self.lineCount = nil
                    self.error = "File is larger than 2 MB. Use 'Open in Default App' to view."
                } else {
                    self.content = nil
                    self.lineCount = nil
                    self.error = "Binary file cannot be displayed as text."
                }
            } else {
                self.content = nil
                self.lineCount = nil
                self.error = nil
            }
        } else {
            self.fileExists = false
            self.isImage = false
            self.fileSizeFormatted = ""
            self.content = nil
            self.lineCount = nil
            self.error = "File not found on disk at the resolved path."
        }
    }
}

final class FilePreviewSheetState: ObservableObject {
    @Published var copiedPath: Bool = false
    @Published var copiedContent: Bool = false

    func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        copiedPath = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.copiedPath = false
        }
    }

    func copyContent(_ content: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
        copiedContent = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.copiedContent = false
        }
    }
}

public struct MACFilePreviewSheet: View {
    public let preview: FilePreviewItem
    public let workspace: MACWorkspace
    @Environment(\.dismiss) private var dismiss
    @StateObject private var sheetState = FilePreviewSheetState()

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: preview.isImage ? "photo.fill" : "doc.text.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(preview.fileName)
                            .font(.system(size: 14, weight: .bold))
                            .lineLimit(1)

                        if !preview.fileSizeFormatted.isEmpty {
                            Text(preview.fileSizeFormatted)
                                .font(.system(size: 10, design: .monospaced))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Color.primary.opacity(0.06))
                                .cornerRadius(4)
                                .foregroundColor(.secondary)
                        }

                        if let lines = preview.lineCount {
                            Text("\(lines) lines")
                                .font(.system(size: 10, design: .monospaced))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Color.primary.opacity(0.06))
                                .cornerRadius(4)
                                .foregroundColor(.secondary)
                        }
                    }

                    Text(preview.absolutePath ?? preview.relativePath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                Spacer()

                // Actions
                if preview.fileExists, let abs = preview.absolutePath {
                    Button {
                        NSWorkspace.shared.open(URL(fileURLWithPath: abs))
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.right.square")
                            Text("Open in App")
                        }
                        .font(.system(size: 11.5, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Open with default editor or viewer")

                    Button {
                        NSWorkspace.shared.selectFile(abs, inFileViewerRootedAtPath: "")
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "folder")
                            Text("Finder")
                        }
                        .font(.system(size: 11.5, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Show file in Finder")
                }

                Button {
                    sheetState.copyPath(preview.absolutePath ?? preview.relativePath)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: sheetState.copiedPath ? "checkmark" : "doc.on.doc")
                        Text(sheetState.copiedPath ? "Copied" : "Copy Path")
                    }
                    .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if let content = preview.content, !content.isEmpty {
                    Button {
                        sheetState.copyContent(content)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: sheetState.copiedContent ? "checkmark" : "doc.on.clipboard")
                            Text(sheetState.copiedContent ? "Copied" : "Copy Content")
                        }
                        .font(.system(size: 11.5, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Divider().frame(height: 18)

                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Body Content
            if preview.isImage, let abs = preview.absolutePath, let nsImg = NSImage(contentsOfFile: abs) {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: nsImg)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(20)
                }
                .background(Color.primary.opacity(0.02))
            } else if let content = preview.content {
                ScrollView([.horizontal, .vertical]) {
                    Text(content)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
                .background(Color(NSColor.textBackgroundColor))
            } else if let err = preview.error {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 32))
                        .foregroundColor(.orange)
                    Text(err)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                    if let abs = preview.absolutePath {
                        Text(abs)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            } else {
                Text("No preview available.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 700, idealWidth: 850, minHeight: 480, idealHeight: 600)
    }
}
