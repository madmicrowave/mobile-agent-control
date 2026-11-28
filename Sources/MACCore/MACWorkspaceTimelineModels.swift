import Foundation

public enum MACTimelineStatus: Equatable, Hashable {
    case working
    case queued(Int)
    case success
    case failed
    case discarded

    public var title: String {
        switch self {
        case .working: return "Working..."
        case .queued(let pos): return "Queued (#\(pos))"
        case .success: return "Success"
        case .failed: return "Failed"
        case .discarded: return "Discarded"
        }
    }

    public var systemImage: String {
        switch self {
        case .working: return "hourglass"
        case .queued: return "tray.and.arrow.down.fill"
        case .success: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .discarded: return "trash.fill"
        }
    }
}

public struct MACTimelineCommit: Identifiable, Equatable, Hashable {
    public let id: String
    public let repoName: String
    public let branch: String
    public let shortSha: String
    public let commitMessage: String
    public let changedFiles: [String]

    public init(
        id: String = UUID().uuidString,
        repoName: String,
        branch: String,
        shortSha: String,
        commitMessage: String,
        changedFiles: [String] = []
    ) {
        self.id = id
        self.repoName = repoName
        self.branch = branch
        self.shortSha = shortSha
        self.commitMessage = commitMessage
        self.changedFiles = changedFiles
    }
}

public struct MACTimelineAttachment: Identifiable, Equatable, Hashable {
    public let id: String
    public let path: String
    public let fileName: String
    public let displayName: String

    public init(path: String, fileName: String? = nil, displayName: String? = nil) {
        self.path = path
        let base = fileName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedFileName = (base?.isEmpty == false) ? base! : URL(fileURLWithPath: path).lastPathComponent
        self.fileName = resolvedFileName
        let disp = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayName = (disp?.isEmpty == false) ? disp! : resolvedFileName
        self.id = path
    }
}

public struct MACTimelineItem: Identifiable, Equatable {
    public let id: String
    public let status: MACTimelineStatus
    public let user: String
    public let message: String
    public let files: [String]
    public let attachments: [MACTimelineAttachment]
    public let date: Date?
    public let formattedDate: String
    public let resultLabel: String
    public let isSuccess: Bool
    public let elapsedTime: String
    public let commits: [MACTimelineCommit]
    public let outcome: String?

    public var totalFileCount: Int {
        attachments.count + files.count
    }

    public init(
        id: String = UUID().uuidString,
        status: MACTimelineStatus,
        user: String,
        message: String,
        files: [String] = [],
        attachments: [MACTimelineAttachment] = [],
        date: Date? = nil,
        formattedDate: String,
        resultLabel: String,
        isSuccess: Bool,
        elapsedTime: String,
        commits: [MACTimelineCommit] = [],
        outcome: String? = nil
    ) {
        self.id = id
        self.status = status
        self.user = user
        self.message = message
        self.files = files
        self.attachments = attachments
        self.date = date
        self.formattedDate = formattedDate
        self.resultLabel = resultLabel
        self.isSuccess = isSuccess
        self.elapsedTime = elapsedTime
        self.commits = commits
        self.outcome = outcome
    }
}

public enum MACWorkspaceTimelineReader {
    private static let isoFormatterWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoFormatterStandard: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func parseDate(_ string: String?) -> Date? {
        guard let s = string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return isoFormatterWithFraction.date(from: s) ?? isoFormatterStandard.date(from: s)
    }

    public static func formatRelativeDate(_ date: Date?) -> String {
        guard let date else { return "Unknown date" }
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    public static func formatDuration(from start: Date?, to end: Date?) -> String {
        guard let start, let end else { return "—" }
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        if seconds < 60 {
            return "\(seconds)s"
        }
        let minutes = seconds / 60
        let remSeconds = seconds % 60
        if minutes < 60 {
            return remSeconds > 0 ? "\(minutes)m \(remSeconds)s" : "\(minutes)m"
        }
        let hours = minutes / 60
        let remMinutes = minutes % 60
        return remMinutes > 0 ? "\(hours)h \(remMinutes)m" : "\(hours)h"
    }

    public static func loadTimeline(workspace: MACWorkspace, dataDir: URL, limit: Int = 100) -> [MACTimelineItem] {
        let stateURL = dataDir.appendingPathComponent("state.json")
        guard let rawData = try? Data(contentsOf: stateURL),
              let json = (try? JSONSerialization.jsonObject(with: rawData)) as? [String: Any],
              let workspacesDict = json["workspaces"] as? [String: Any] else {
            return []
        }

        // Detect default fallback user from userSessions if available
        var fallbackUser = "User"
        if let sessions = json["userSessions"] as? [String: Any], let firstUserId = sessions.keys.first {
            fallbackUser = "User (\(firstUserId))"
        }

        // Match workspace by ID and aliases (e.g. "payment-book" vs "pb", "ai-portfolio" vs "microwave")
        let targetId = workspace.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let targetPath = workspace.path.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let targetBase = URL(fileURLWithPath: workspace.path).lastPathComponent.lowercased()

        var matchedWorkspaceDicts: [[String: Any]] = []
        var seenKeys = Set<String>()

        for (key, val) in workspacesDict {
            guard let dict = val as? [String: Any] else { continue }
            let lowerKey = key.lowercased()
            let isExact = lowerKey == targetId
            let isPathMatch = !targetPath.isEmpty && (targetPath.hasSuffix("/" + lowerKey) || targetBase == lowerKey)
            let isSlugMatch = !targetId.isEmpty && (targetId.contains(lowerKey) || lowerKey.contains(targetId))

            if isExact || isPathMatch || isSlugMatch {
                if seenKeys.insert(lowerKey).inserted {
                    matchedWorkspaceDicts.append(dict)
                }
            }
        }

        if matchedWorkspaceDicts.isEmpty, let exact = workspacesDict[workspace.id] as? [String: Any] {
            matchedWorkspaceDicts.append(exact)
        }

        // Helper to check if a user string is a real username (not nil, empty, or generic "User" / "User (...)")
        func isRealUsername(_ u: String?) -> Bool {
            guard let trimmed = u?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
                return false
            }
            if trimmed == "User" || trimmed.hasPrefix("User (") {
                return false
            }
            return true
        }

        // 1. Detect real username across matched workspaces, all workspaces, and userSessions
        var detectedUsername: String?

        // Check matched workspaces first
        for wsObj in matchedWorkspaceDicts {
            if let act = wsObj["activeTurn"] as? [String: Any],
               let u = act["user"] as? String ?? act["userName"] as? String,
               isRealUsername(u) {
                detectedUsername = u.trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
            if let queue = wsObj["messageQueue"] as? [[String: Any]] {
                for q in queue {
                    if let u = q["user"] as? String ?? q["userName"] as? String, isRealUsername(u) {
                        detectedUsername = u.trimmingCharacters(in: .whitespacesAndNewlines)
                        break
                    }
                }
                if detectedUsername != nil { break }
            }
            if let hist = wsObj["history"] as? [[String: Any]] {
                for h in hist {
                    if let u = h["user"] as? String ?? h["userName"] as? String, isRealUsername(u) {
                        detectedUsername = u.trimmingCharacters(in: .whitespacesAndNewlines)
                        break
                    }
                }
                if detectedUsername != nil { break }
            }
        }

        // Check all other workspaces in state.json if still nil
        if detectedUsername == nil {
            for (_, val) in workspacesDict {
                guard let wsObj = val as? [String: Any] else { continue }
                if let act = wsObj["activeTurn"] as? [String: Any],
                   let u = act["user"] as? String ?? act["userName"] as? String,
                   isRealUsername(u) {
                    detectedUsername = u.trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
                if let queue = wsObj["messageQueue"] as? [[String: Any]] {
                    for q in queue {
                        if let u = q["user"] as? String ?? q["userName"] as? String, isRealUsername(u) {
                            detectedUsername = u.trimmingCharacters(in: .whitespacesAndNewlines)
                            break
                        }
                    }
                    if detectedUsername != nil { break }
                }
                if let hist = wsObj["history"] as? [[String: Any]] {
                    for h in hist {
                        if let u = h["user"] as? String ?? h["userName"] as? String, isRealUsername(u) {
                            detectedUsername = u.trimmingCharacters(in: .whitespacesAndNewlines)
                            break
                        }
                    }
                    if detectedUsername != nil { break }
                }
            }
        }

        // Check userSessions in state.json if still nil
        if detectedUsername == nil, let sessions = json["userSessions"] as? [String: Any] {
            for (_, sVal) in sessions {
                guard let sObj = sVal as? [String: Any] else { continue }
                if let u = sObj["username"] as? String ?? sObj["userName"] as? String ?? sObj["user"] as? String,
                   isRealUsername(u) {
                    detectedUsername = u.trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
            }
        }

        // Helper to resolve user for an item
        func resolveUser(_ raw: String?) -> String {
            if isRealUsername(raw), let u = raw?.trimmingCharacters(in: .whitespacesAndNewlines) {
                return u
            }
            if let detected = detectedUsername {
                return detected
            }
            if let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
                return trimmed
            }
            return fallbackUser
        }

        var workingItems: [MACTimelineItem] = []
        var queuedItems: [MACTimelineItem] = []
        var historyItems: [MACTimelineItem] = []
        var seenTurnIds = Set<String>()

        let uploadsDir = dataDir.appendingPathComponent("uploads", isDirectory: true)
        let fm = FileManager.default

        func parseAttachments(_ rawValues: [Any?]) -> [MACTimelineAttachment] {
            var seen = Set<String>()
            var result: [MACTimelineAttachment] = []
            for raw in rawValues {
                if let strList = raw as? [String] {
                    for s in strList {
                        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { continue }
                        let base = URL(fileURLWithPath: trimmed).lastPathComponent
                        var resolvedPath = trimmed
                        if !fm.fileExists(atPath: resolvedPath) {
                            let inUploads = uploadsDir.appendingPathComponent(base).path
                            if fm.fileExists(atPath: inUploads) {
                                resolvedPath = inUploads
                            }
                        }
                        if seen.insert(resolvedPath).inserted {
                            result.append(MACTimelineAttachment(path: resolvedPath, fileName: base, displayName: base))
                        }
                    }
                } else if let dictList = raw as? [[String: Any]] {
                    for dict in dictList {
                        let rawPath = (dict["path"] as? String ?? dict["fileName"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !rawPath.isEmpty else { continue }
                        let fName = (dict["fileName"] as? String ?? URL(fileURLWithPath: rawPath).lastPathComponent).trimmingCharacters(in: .whitespacesAndNewlines)
                        let origName = (dict["originalName"] as? String ?? fName).trimmingCharacters(in: .whitespacesAndNewlines)
                        var resolvedPath = rawPath
                        if !fm.fileExists(atPath: resolvedPath) {
                            let inUploads = uploadsDir.appendingPathComponent(fName).path
                            if fm.fileExists(atPath: inUploads) {
                                resolvedPath = inUploads
                            }
                        }
                        if seen.insert(resolvedPath).inserted {
                            result.append(MACTimelineAttachment(path: resolvedPath, fileName: fName, displayName: origName))
                        }
                    }
                }
            }
            return result
        }

        // Index existing files in data/uploads/<wsPrefix>-[queued-]<timestampMs>-<hex>.<ext>
        // so legacy history items created before attachments were explicitly saved in state.json
        // can also recover their uploaded screenshots/files.
        struct IndexedUpload {
            let path: String
            let fileName: String
            let timestampMs: Int64
        }
        var legacyUploads: [IndexedUpload] = []
        if let uploadNames = try? fm.contentsOfDirectory(atPath: uploadsDir.path) {
            let candidatePrefixes = Array(seenKeys) + [targetId, targetBase].filter { !$0.isEmpty }
            for uName in uploadNames where !uName.hasPrefix(".") {
                let lowerName = uName.lowercased()
                var matchedPrefix: String?
                for pref in candidatePrefixes where !pref.isEmpty {
                    if lowerName.hasPrefix(pref + "-") {
                        if matchedPrefix == nil || pref.count > matchedPrefix!.count {
                            matchedPrefix = pref
                        }
                    }
                }
                guard let pref = matchedPrefix else { continue }
                var rest = String(lowerName.dropFirst(pref.count + 1))
                if rest.hasPrefix("queued-") {
                    rest = String(rest.dropFirst("queued-".count))
                }
                let parts = rest.split(separator: "-")
                if let firstPart = parts.first, let ts = Int64(firstPart) {
                    legacyUploads.append(IndexedUpload(
                        path: uploadsDir.appendingPathComponent(uName).path,
                        fileName: uName,
                        timestampMs: ts
                    ))
                }
            }
            legacyUploads.sort { $0.timestampMs < $1.timestampMs }
        }
        var claimedLegacyUploadPaths = Set<String>()

        for wsObj in matchedWorkspaceDicts {
            // 1. Currently working on message (activeTurn)
            if let activeTurn = wsObj["activeTurn"] as? [String: Any] {
                let turnId = activeTurn["id"] as? String ?? "active-\(UUID().uuidString)"
                if seenTurnIds.insert(turnId).inserted {
                    let prompt = (activeTurn["prompt"] as? String ?? activeTurn["promptText"] as? String ?? "(Running Agent Task)").trimmingCharacters(in: .whitespacesAndNewlines)
                    let user = resolveUser(activeTurn["user"] as? String ?? activeTurn["userName"] as? String)
                    let createdDate = parseDate(activeTurn["createdAt"] as? String)
                    let elapsed = formatDuration(from: createdDate, to: Date()) + " (running)"

                    var files: [String] = []
                    var commits: [MACTimelineCommit] = []
                    if let rawCommits = activeTurn["commits"] as? [[String: Any]] {
                        for c in rawCommits {
                            let repo = c["repoName"] as? String ?? ""
                            let branch = c["branch"] as? String ?? ""
                            let sha = c["shortSha"] as? String ?? ""
                            let msg = c["commitMessage"] as? String ?? ""
                            let cFiles = c["changedFiles"] as? [String] ?? []
                            files.append(contentsOf: cFiles)
                            commits.append(MACTimelineCommit(repoName: repo, branch: branch, shortSha: sha, commitMessage: msg, changedFiles: cFiles))
                        }
                    }
                    if let fList = activeTurn["files"] as? [String] {
                        files.append(contentsOf: fList)
                    }
                    if let cList = activeTurn["changedFiles"] as? [String] {
                        files.append(contentsOf: cList)
                    }
                    if let deltas = wsObj["pendingDeltas"] as? [[String: Any]] {
                        for d in deltas {
                            if let dFiles = d["changedFiles"] as? [String] {
                                files.append(contentsOf: dFiles)
                            }
                        }
                    }

                    let attachments = parseAttachments([
                        activeTurn["attachments"],
                        activeTurn["photos"],
                        wsObj["pendingPhotos"]
                    ])
                    for att in attachments {
                        claimedLegacyUploadPaths.insert(att.path)
                    }

                    workingItems.append(MACTimelineItem(
                        id: turnId,
                        status: .working,
                        user: user,
                        message: prompt,
                        files: Array(NSOrderedSet(array: files)) as? [String] ?? files,
                        attachments: attachments,
                        date: createdDate,
                        formattedDate: formatRelativeDate(createdDate),
                        resultLabel: "Working...",
                        isSuccess: true,
                        elapsedTime: elapsed,
                        commits: commits,
                        outcome: "WORKING"
                    ))
                }
            }

            // 2. Queued messages (messageQueue)
            if let queue = wsObj["messageQueue"] as? [[String: Any]] {
                for entry in queue {
                    let qId = entry["id"] as? String ?? UUID().uuidString
                    if seenTurnIds.insert(qId).inserted {
                        let qPos = entry["queueNumber"] as? Int ?? (queuedItems.count + 1)
                        let text = (entry["text"] as? String ?? "(Queued Message)").trimmingCharacters(in: .whitespacesAndNewlines)
                        let user = resolveUser(entry["user"] as? String ?? entry["userName"] as? String)
                        let queuedDate = parseDate(entry["queuedAt"] as? String)
                        let elapsed = "waiting " + formatDuration(from: queuedDate, to: Date())
                        let attachments = parseAttachments([entry["attachments"], entry["photos"]])
                        for att in attachments {
                            claimedLegacyUploadPaths.insert(att.path)
                        }
                        let qFiles = entry["files"] as? [String] ?? []

                        queuedItems.append(MACTimelineItem(
                            id: qId,
                            status: .queued(qPos),
                            user: user,
                            message: text,
                            files: qFiles,
                            attachments: attachments,
                            date: queuedDate,
                            formattedDate: formatRelativeDate(queuedDate),
                            resultLabel: "Queued (#\(qPos))",
                            isSuccess: true,
                            elapsedTime: elapsed,
                            commits: [],
                            outcome: "QUEUED"
                        ))
                    }
                }
            }

            // 3. Worked messages (history)
            if let historyList = wsObj["history"] as? [[String: Any]] {
                for item in historyList {
                    let hId = item["id"] as? String ?? UUID().uuidString
                    if seenTurnIds.insert(hId).inserted {
                        let prompt = (item["prompt"] as? String ?? "(Task prompt)").trimmingCharacters(in: .whitespacesAndNewlines)
                        let user = resolveUser(item["user"] as? String ?? item["userName"] as? String)
                        let outcome = item["outcome"] as? String ?? "CONFIRMED"
                        let createdDate = parseDate(item["createdAt"] as? String)
                        let finishedDate = parseDate(item["finishedAt"] as? String)
                        let elapsed = formatDuration(from: createdDate, to: finishedDate)

                        var files: [String] = []
                        var commits: [MACTimelineCommit] = []
                        if let rawCommits = item["commits"] as? [[String: Any]] {
                            for c in rawCommits {
                                let repo = c["repoName"] as? String ?? ""
                                let branch = c["branch"] as? String ?? ""
                                let sha = c["shortSha"] as? String ?? ""
                                let msg = c["commitMessage"] as? String ?? ""
                                let cFiles = c["changedFiles"] as? [String] ?? []
                                files.append(contentsOf: cFiles)
                                commits.append(MACTimelineCommit(repoName: repo, branch: branch, shortSha: sha, commitMessage: msg, changedFiles: cFiles))
                            }
                        }
                        if let fList = item["files"] as? [String] {
                            files.append(contentsOf: fList)
                        }
                        if let cList = item["changedFiles"] as? [String] {
                            files.append(contentsOf: cList)
                        }

                        var attachments = parseAttachments([item["attachments"], item["photos"]])
                        for att in attachments {
                            claimedLegacyUploadPaths.insert(att.path)
                        }
                        if attachments.isEmpty && item["attachments"] == nil && item["photos"] == nil,
                           let createdMs = createdDate.map({ Int64($0.timeIntervalSince1970 * 1000.0) }) {
                            // Recover legacy uploaded files created right before/at turn start (within 90s before to 5s after)
                            for up in legacyUploads where !claimedLegacyUploadPaths.contains(up.path) {
                                let diff = createdMs - up.timestampMs
                                if diff >= -5_000 && diff <= 90_000 {
                                    claimedLegacyUploadPaths.insert(up.path)
                                    attachments.append(MACTimelineAttachment(path: up.path, fileName: up.fileName, displayName: up.fileName))
                                }
                            }
                        }

                        let upperOutcome = outcome.uppercased()
                        let status: MACTimelineStatus
                        let resultLabel: String
                        let isSuccess: Bool

                        if ["CONFIRMED", "CONFIRMED_PROD_DEPLOYED", "CONFIRMED_SKIPPED_PROD", "DEPLOYED_IN_PARALLEL"].contains(upperOutcome) {
                            status = .success
                            resultLabel = "Success"
                            isSuccess = true
                        } else if upperOutcome == "NO_CHANGES" {
                            status = .success
                            resultLabel = "Success (No changes)"
                            isSuccess = true
                        } else if upperOutcome.contains("REVERT") {
                            status = .failed
                            resultLabel = "Reverted"
                            isSuccess = false
                        } else if upperOutcome.contains("DISCARD") {
                            status = .discarded
                            resultLabel = "Discarded"
                            isSuccess = false
                        } else if upperOutcome.contains("FAIL") || upperOutcome.contains("ERR") {
                            status = .failed
                            resultLabel = "Failed"
                            isSuccess = false
                        } else {
                            status = .success
                            resultLabel = outcome.capitalized
                            isSuccess = true
                        }

                        historyItems.append(MACTimelineItem(
                            id: hId,
                            status: status,
                            user: user,
                            message: prompt,
                            files: Array(NSOrderedSet(array: files)) as? [String] ?? files,
                            attachments: attachments,
                            date: finishedDate ?? createdDate,
                            formattedDate: formatRelativeDate(finishedDate ?? createdDate),
                            resultLabel: resultLabel,
                            isSuccess: isSuccess,
                            elapsedTime: elapsed,
                            commits: commits,
                            outcome: outcome
                        ))
                    }
                }
            }
        }

        // 1. Sort currently running items by date descending (most recent first)
        workingItems.sort { (a, b) -> Bool in
            guard let da = a.date, let db = b.date else { return false }
            return da > db
        }

        // 2. Sort queued items by date descending (latest queued message on top)
        queuedItems.sort { (a, b) -> Bool in
            if let da = a.date, let db = b.date, da != db {
                return da > db
            }
            if case .queued(let posA) = a.status, case .queued(let posB) = b.status {
                return posA > posB
            }
            return false
        }

        // 3. Sort worked messages by date descending (most recent first)
        historyItems.sort { (a, b) -> Bool in
            guard let da = a.date, let db = b.date else { return false }
            return da > db
        }

        let effectiveLimit = limit > 0 ? limit : 100
        let limitedHistory = historyItems.count > effectiveLimit ? Array(historyItems.prefix(effectiveLimit)) : historyItems

        // Return ordered timeline: Queued (latest on top, will execute later) -> Currently Working -> Worked Messages (latest on top)
        return queuedItems + workingItems + limitedHistory
    }

    public static func resolveFilePath(file: String, workspace: MACWorkspace) -> String? {
        let fm = FileManager.default
        let expandedWs = MACPathUtils.expandPath(workspace.path)

        // 1. Direct absolute path
        if file.hasPrefix("/") && fm.fileExists(atPath: file) {
            return file
        }

        // 2. Direct inside workspace root
        let directWs = URL(fileURLWithPath: expandedWs).appendingPathComponent(file).path
        if fm.fileExists(atPath: directWs) {
            return directWs
        }

        // 3. Check inside each repo
        for repo in workspace.repos {
            let repoPath = MACPathUtils.expandPath(repo.path)
            let directRepo = URL(fileURLWithPath: repoPath).appendingPathComponent(file).path
            if fm.fileExists(atPath: directRepo) {
                return directRepo
            }
            let repoPrefix = repo.name + "/"
            if file.hasPrefix(repoPrefix) {
                let stripped = String(file.dropFirst(repoPrefix.count))
                let strippedPath = URL(fileURLWithPath: repoPath).appendingPathComponent(stripped).path
                if fm.fileExists(atPath: strippedPath) {
                    return strippedPath
                }
            }
        }

        // 4. Check extra dirs
        for extra in workspace.extraDirs {
            let extraPath = MACPathUtils.expandPath(extra)
            let directExtra = URL(fileURLWithPath: extraPath).appendingPathComponent(file).path
            if fm.fileExists(atPath: directExtra) {
                return directExtra
            }
            for repo in workspace.repos {
                let repoPrefix = repo.name + "/"
                if file.hasPrefix(repoPrefix) {
                    let stripped = String(file.dropFirst(repoPrefix.count))
                    let strippedExtra = URL(fileURLWithPath: extraPath).appendingPathComponent(stripped).path
                    if fm.fileExists(atPath: strippedExtra) {
                        return strippedExtra
                    }
                }
            }
        }

        return nil
    }

    private static func runGitOutput(repoPath: String, args: [String]) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: "/usr/bin/git"), fm.fileExists(atPath: repoPath) else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["-C", repoPath] + args
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do {
            try proc.run()
        } catch {
            return nil
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0, !data.isEmpty, data.count <= 2 * 1024 * 1024 else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    private static func resolveCommitTarget(
        file: String,
        commits: [MACTimelineCommit],
        workspace: MACWorkspace
    ) -> (repoPath: String, relFile: String, shas: [String])? {
        guard !commits.isEmpty else { return nil }
        let matchingCommits = commits.filter { c in
            guard !c.shortSha.isEmpty else { return false }
            if c.changedFiles.contains(file) { return true }
            if !c.repoName.isEmpty && file.hasPrefix(c.repoName + "/") {
                let stripped = String(file.dropFirst(c.repoName.count + 1))
                if c.changedFiles.contains(stripped) { return true }
            }
            return false
        }
        let candidateCommits = matchingCommits.isEmpty ? commits.filter { !$0.shortSha.isEmpty } : matchingCommits
        guard let first = candidateCommits.first else { return nil }

        let expandedWs = MACPathUtils.expandPath(workspace.path)
        var repoPath = expandedWs
        if !first.repoName.isEmpty,
           let matchedRepo = workspace.repos.first(where: { $0.name == first.repoName }) {
            repoPath = MACPathUtils.expandPath(matchedRepo.path)
        } else if let firstRepo = workspace.repos.first {
            repoPath = MACPathUtils.expandPath(firstRepo.path)
        }

        var relFile = file
        if !first.repoName.isEmpty && relFile.hasPrefix(first.repoName + "/") {
            relFile = String(relFile.dropFirst(first.repoName.count + 1))
        }
        let shas = candidateCommits.map(\.shortSha)
        return (repoPath, relFile, shas)
    }

    public static func loadCommitDiff(
        file: String,
        commits: [MACTimelineCommit],
        workspace: MACWorkspace
    ) -> String? {
        guard let target = resolveCommitTarget(file: file, commits: commits, workspace: workspace) else {
            return nil
        }
        var chunks: [String] = []
        for sha in target.shas {
            if let out = runGitOutput(
                repoPath: target.repoPath,
                args: ["show", "--no-color", "--format=commit %h — %s", sha, "--", target.relFile]
            )?.trimmingCharacters(in: .whitespacesAndNewlines), !out.isEmpty {
                chunks.append(out)
            }
        }
        return chunks.isEmpty ? nil : chunks.joined(separator: "\n\n")
    }

    public static func loadCommittedFileContent(
        file: String,
        commits: [MACTimelineCommit],
        workspace: MACWorkspace
    ) -> String? {
        guard let target = resolveCommitTarget(file: file, commits: commits, workspace: workspace),
              let latestSha = target.shas.last else {
            return nil
        }
        return runGitOutput(repoPath: target.repoPath, args: ["show", "\(latestSha):\(target.relFile)"])
    }
}
