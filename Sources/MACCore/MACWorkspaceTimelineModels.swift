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

public struct MACTimelineItem: Identifiable, Equatable {
    public let id: String
    public let status: MACTimelineStatus
    public let user: String
    public let message: String
    public let files: [String]
    public let date: Date?
    public let formattedDate: String
    public let resultLabel: String
    public let isSuccess: Bool
    public let elapsedTime: String
    public let commits: [MACTimelineCommit]
    public let outcome: String?

    public init(
        id: String = UUID().uuidString,
        status: MACTimelineStatus,
        user: String,
        message: String,
        files: [String] = [],
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

    public static func loadTimeline(workspace: MACWorkspace, dataDir: URL) -> [MACTimelineItem] {
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

        var workingItems: [MACTimelineItem] = []
        var queuedItems: [MACTimelineItem] = []
        var historyItems: [MACTimelineItem] = []
        var seenTurnIds = Set<String>()

        for wsObj in matchedWorkspaceDicts {
            // 1. Currently working on message (activeTurn)
            if let activeTurn = wsObj["activeTurn"] as? [String: Any] {
                let turnId = activeTurn["id"] as? String ?? "active-\(UUID().uuidString)"
                if seenTurnIds.insert(turnId).inserted {
                    let prompt = (activeTurn["prompt"] as? String ?? activeTurn["promptText"] as? String ?? "(Running Agent Task)").trimmingCharacters(in: .whitespacesAndNewlines)
                    let user = activeTurn["user"] as? String ?? activeTurn["userName"] as? String ?? fallbackUser
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

                    workingItems.append(MACTimelineItem(
                        id: turnId,
                        status: .working,
                        user: user,
                        message: prompt,
                        files: Array(NSOrderedSet(array: files)) as? [String] ?? files,
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
                        let user = entry["user"] as? String ?? fallbackUser
                        let queuedDate = parseDate(entry["queuedAt"] as? String)
                        let elapsed = "waiting " + formatDuration(from: queuedDate, to: Date())
                        let photos = entry["photos"] as? [String] ?? []

                        queuedItems.append(MACTimelineItem(
                            id: qId,
                            status: .queued(qPos),
                            user: user,
                            message: text,
                            files: photos,
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
                        let user = item["user"] as? String ?? item["userName"] as? String ?? fallbackUser
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
                        if let extraFiles = item["changedFiles"] as? [String] ?? item["files"] as? [String] {
                            files.append(contentsOf: extraFiles)
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

        // Return ordered timeline: Currently Working (on top) -> Queued (latest on top) -> Worked Messages (latest on top)
        return workingItems + queuedItems + historyItems
    }
}
