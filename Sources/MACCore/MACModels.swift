import Foundation

public struct MACModelOption: Identifiable, Equatable, Hashable {
    public let id: String
    public let label: String
    public let tiered: Bool

    public init(id: String, label: String, tiered: Bool = true) {
        self.id = id
        self.label = label
        self.tiered = tiered
    }

    public static let allOptions: [MACModelOption] = [
        MACModelOption(id: "gemini-3.8-flash", label: "Gemini 3.8 Flash", tiered: true),
        MACModelOption(id: "gemini-4-argon", label: "Gemini 4 Argon", tiered: true),
        MACModelOption(id: "gemini-4-carbon", label: "Gemini 4 Carbon", tiered: true),
        MACModelOption(id: "claude-opus-5-5", label: "Claude Opus 5.5", tiered: true),
        MACModelOption(id: "claude-sonnet-5-5", label: "Claude Sonnet 5.5", tiered: true),
        MACModelOption(id: "gpt-oss-120b-medium", label: "GPT-OSS 120B", tiered: false)
    ]

    public static let validLevels: [String] = ["low", "medium", "high"]

    public static func normalizeFamilyAndLevel(rawModel: String, rawLevel: String) -> (family: String, level: String, modelId: String, displayLabel: String) {
        let cleanLevelRaw = rawLevel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let mappedLevel = (cleanLevelRaw == "xhigh" || cleanLevelRaw == "max") ? "high" : cleanLevelRaw
        var level = validLevels.contains(mappedLevel) ? mappedLevel : ""

        let trimmedModel = rawModel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var baseFamily = trimmedModel
        for suffix in ["-low", "-medium", "-high"] where trimmedModel.hasSuffix(suffix) {
            baseFamily = String(trimmedModel.dropLast(suffix.count))
            if level.isEmpty {
                level = String(suffix.dropFirst())
            }
            break
        }

        let hyphenated = baseFamily.replacingOccurrences(of: " ", with: "-")
        if let opt = allOptions.first(where: { $0.id == baseFamily || $0.id == trimmedModel || $0.id == hyphenated }) {
            let effLevel = level.isEmpty ? "high" : level
            if opt.tiered {
                let fullId = "\(opt.id)-\(effLevel)"
                return (opt.id, effLevel, fullId, "\(opt.label) (\(effLevel))")
            } else {
                return (opt.id, effLevel, opt.id, opt.label)
            }
        }

        let fallbackOpt = allOptions[0]
        let effLevel = level.isEmpty ? "high" : level
        if trimmedModel.isEmpty {
            return (fallbackOpt.id, effLevel, "\(fallbackOpt.id)-\(effLevel)", "\(fallbackOpt.label) (\(effLevel))")
        }
        return (trimmedModel, effLevel, trimmedModel, "\(trimmedModel) (\(effLevel))")
    }
}

public struct MACRepo: Identifiable, Codable, Equatable {
    public var id: String { "\(name)::\(path)" }
    public var name: String
    public var path: String
    public var jenkinsJob: String
    public var prodJenkinsJob: String
    public var branch: String
    public var deployEnabled: Bool

    public init(
        name: String,
        path: String,
        jenkinsJob: String = "",
        prodJenkinsJob: String = "",
        branch: String = "",
        deployEnabled: Bool = false
    ) {
        self.name = name
        self.path = path
        self.jenkinsJob = jenkinsJob
        self.prodJenkinsJob = prodJenkinsJob
        self.branch = branch
        self.deployEnabled = deployEnabled
    }

    enum CodingKeys: String, CodingKey {
        case name, path, jenkinsJob, prodJenkinsJob, branch, deployEnabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        self.jenkinsJob = try c.decodeIfPresent(String.self, forKey: .jenkinsJob) ?? ""
        self.prodJenkinsJob = try c.decodeIfPresent(String.self, forKey: .prodJenkinsJob) ?? ""
        self.branch = try c.decodeIfPresent(String.self, forKey: .branch) ?? ""
        self.deployEnabled = try c.decodeIfPresent(Bool.self, forKey: .deployEnabled) ?? !self.jenkinsJob.isEmpty
    }
}

public struct MACWorkspace: Identifiable, Codable, Equatable {
    public var id: String
    public var label: String
    public var path: String
    public var extraDirs: [String]
    public var liveUrl: String
    public var model: String
    public var modelLevel: String
    public var environmentMode: String // "single" or "multi"
    public var jenkinsJobs: [String]
    public var prodJenkinsJobs: [String]
    public var repos: [MACRepo]

    public init(
        id: String = "",
        label: String = "",
        path: String = "",
        extraDirs: [String] = [],
        liveUrl: String = "",
        model: String = "gemini-3.8-flash-high",
        modelLevel: String = "high",
        environmentMode: String = "single",
        jenkinsJobs: [String] = [],
        prodJenkinsJobs: [String] = [],
        repos: [MACRepo] = []
    ) {
        self.id = id
        self.label = label
        self.path = path
        self.extraDirs = extraDirs
        self.liveUrl = liveUrl
        self.model = model
        self.modelLevel = modelLevel
        self.environmentMode = environmentMode
        self.jenkinsJobs = jenkinsJobs
        self.prodJenkinsJobs = prodJenkinsJobs
        self.repos = repos
    }

    enum CodingKeys: String, CodingKey {
        case id, label, name, path, extraDirs, liveUrl, model, modelLevel, environmentMode, jenkinsJobs, prodJenkinsJobs, repos
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawId = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        let rawLabel = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        let legacyName = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        let wsPath = try c.decodeIfPresent(String.self, forKey: .path) ?? ""

        let effectiveLabel = !rawLabel.isEmpty ? rawLabel : (!legacyName.isEmpty ? legacyName : rawId)
        let effectiveId = !rawId.isEmpty ? rawId : MACPathUtils.slugifyWorkspaceId(effectiveLabel.isEmpty ? URL(fileURLWithPath: wsPath).lastPathComponent : effectiveLabel)

        self.id = effectiveId
        self.label = effectiveLabel.isEmpty ? effectiveId : effectiveLabel
        self.path = wsPath
        self.extraDirs = try c.decodeIfPresent([String].self, forKey: .extraDirs) ?? []
        self.liveUrl = try c.decodeIfPresent(String.self, forKey: .liveUrl) ?? ""
        self.model = try c.decodeIfPresent(String.self, forKey: .model) ?? "gemini-3.8-flash-high"
        self.modelLevel = try c.decodeIfPresent(String.self, forKey: .modelLevel) ?? "high"
        self.jenkinsJobs = try c.decodeIfPresent([String].self, forKey: .jenkinsJobs) ?? []
        self.prodJenkinsJobs = try c.decodeIfPresent([String].self, forKey: .prodJenkinsJobs) ?? []
        self.repos = try c.decodeIfPresent([MACRepo].self, forKey: .repos) ?? []

        let rawEnv = (try c.decodeIfPresent(String.self, forKey: .environmentMode) ?? "").lowercased()
        let hasProd = !self.prodJenkinsJobs.isEmpty || self.repos.contains(where: { !$0.prodJenkinsJob.isEmpty })
        self.environmentMode = (rawEnv == "multi" || hasProd) ? "multi" : "single"
        if self.environmentMode == "single" {
            self.prodJenkinsJobs = []
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(label, forKey: .label)
        try c.encode(path, forKey: .path)
        try c.encode(extraDirs, forKey: .extraDirs)
        try c.encode(liveUrl, forKey: .liveUrl)
        try c.encode(model, forKey: .model)
        try c.encode(modelLevel, forKey: .modelLevel)
        try c.encode(environmentMode, forKey: .environmentMode)
        try c.encode(jenkinsJobs, forKey: .jenkinsJobs)
        try c.encode(environmentMode == "multi" ? prodJenkinsJobs : [], forKey: .prodJenkinsJobs)
        try c.encode(repos, forKey: .repos)
    }

    public var displayModelSummary: String {
        MACModelOption.normalizeFamilyAndLevel(rawModel: model, rawLevel: modelLevel).displayLabel
    }
}

public struct MACJenkinsConfig: Codable, Equatable {
    public var baseUrl: String
    public var username: String
    public var apiToken: String
    public var jobPrefix: String
    public var insecureTls: Bool
    public var pollIntervalMs: Int
    public var buildTimeoutMs: Int

    public init(
        baseUrl: String = "",
        username: String = "",
        apiToken: String = "",
        jobPrefix: String = "",
        insecureTls: Bool = false,
        pollIntervalMs: Int = 3000,
        buildTimeoutMs: Int = 1_500_000
    ) {
        self.baseUrl = baseUrl
        self.username = username
        self.apiToken = apiToken
        self.jobPrefix = jobPrefix
        self.insecureTls = insecureTls
        self.pollIntervalMs = pollIntervalMs
        self.buildTimeoutMs = buildTimeoutMs
    }

    enum CodingKeys: String, CodingKey {
        case baseUrl, username, apiToken, jobPrefix, insecureTls, pollIntervalMs, buildTimeoutMs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.baseUrl = try c.decodeIfPresent(String.self, forKey: .baseUrl) ?? ""
        self.username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        self.apiToken = try c.decodeIfPresent(String.self, forKey: .apiToken) ?? ""
        self.jobPrefix = try c.decodeIfPresent(String.self, forKey: .jobPrefix) ?? ""
        self.insecureTls = try c.decodeIfPresent(Bool.self, forKey: .insecureTls) ?? false
        self.pollIntervalMs = try c.decodeIfPresent(Int.self, forKey: .pollIntervalMs) ?? 3000
        self.buildTimeoutMs = try c.decodeIfPresent(Int.self, forKey: .buildTimeoutMs) ?? 1_500_000
    }
}

public struct MACConfig: Codable, Equatable {
    public var agyBin: String
    public var defaultModel: String
    public var defaultModelLevel: String
    public var skipPermissions: Bool
    public var jenkins: MACJenkinsConfig
    public var workspaces: [MACWorkspace]
    public var telegramBotToken: String
    public var telegramApiBaseUrl: String
    public var allowedUserIds: [String]
    public var defaultHistoryCount: Int
    public var antigravityBrainDir: String

    public init(
        agyBin: String = MACPathUtils.defaultAgyBin(),
        defaultModel: String = "gemini-3.8-flash-high",
        defaultModelLevel: String = "high",
        skipPermissions: Bool = true,
        jenkins: MACJenkinsConfig = MACJenkinsConfig(),
        workspaces: [MACWorkspace] = [],
        telegramBotToken: String = "",
        telegramApiBaseUrl: String = "https://api.telegram.org",
        allowedUserIds: [String] = [],
        defaultHistoryCount: Int = 20,
        antigravityBrainDir: String = MACPathUtils.defaultBrainDir()
    ) {
        self.agyBin = agyBin
        self.defaultModel = defaultModel
        self.defaultModelLevel = defaultModelLevel
        self.skipPermissions = skipPermissions
        self.jenkins = jenkins
        self.workspaces = workspaces
        self.telegramBotToken = telegramBotToken
        self.telegramApiBaseUrl = telegramApiBaseUrl
        self.allowedUserIds = allowedUserIds
        self.defaultHistoryCount = defaultHistoryCount
        self.antigravityBrainDir = antigravityBrainDir
    }

    enum CodingKeys: String, CodingKey {
        case agyBin, defaultModel, defaultModelLevel, skipPermissions, jenkins, workspaces
        case telegramBotToken, telegramApiBaseUrl, allowedUserIds, defaultHistoryCount, antigravityBrainDir
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.agyBin = try c.decodeIfPresent(String.self, forKey: .agyBin) ?? MACPathUtils.defaultAgyBin()
        self.defaultModel = try c.decodeIfPresent(String.self, forKey: .defaultModel) ?? "gemini-3.8-flash-high"
        self.defaultModelLevel = try c.decodeIfPresent(String.self, forKey: .defaultModelLevel) ?? "high"
        self.skipPermissions = try c.decodeIfPresent(Bool.self, forKey: .skipPermissions) ?? true
        self.jenkins = try c.decodeIfPresent(MACJenkinsConfig.self, forKey: .jenkins) ?? MACJenkinsConfig()
        self.workspaces = try c.decodeIfPresent([MACWorkspace].self, forKey: .workspaces) ?? []
        self.telegramBotToken = try c.decodeIfPresent(String.self, forKey: .telegramBotToken) ?? ""
        self.telegramApiBaseUrl = try c.decodeIfPresent(String.self, forKey: .telegramApiBaseUrl) ?? "https://api.telegram.org"
        self.allowedUserIds = try c.decodeIfPresent([String].self, forKey: .allowedUserIds) ?? []
        self.defaultHistoryCount = try c.decodeIfPresent(Int.self, forKey: .defaultHistoryCount) ?? 20
        let decodedBrainDir = (try c.decodeIfPresent(String.self, forKey: .antigravityBrainDir) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if decodedBrainDir.isEmpty || decodedBrainDir == MACPathUtils.legacyDesktopBrainDir() {
            self.antigravityBrainDir = MACPathUtils.defaultBrainDir()
        } else {
            self.antigravityBrainDir = decodedBrainDir
        }
    }
}

public enum MACPathUtils {
    public static func defaultAgyBin() -> String {
        let local = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/agy").path
        return FileManager.default.fileExists(atPath: local) ? local : "agy"
    }

    public static func defaultBrainDir() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity-cli/brain").path
    }

    public static func legacyDesktopBrainDir() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity/brain").path
    }

    public static func expandPath(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) {
            s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !s.isEmpty else { return "" }
        if s == "~" {
            return FileManager.default.homeDirectoryForCurrentUser.path
        }
        if s.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(s.dropFirst(2))).standardizedFileURL.path
        }
        return URL(fileURLWithPath: s).standardizedFileURL.path
    }

    public static func slugifyWorkspaceId(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let replaced = lowered.replacingOccurrences(
            of: "[^a-z0-9]+",
            with: "-",
            options: .regularExpression
        )
        let trimmed = replaced.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "workspace" : trimmed
    }

    /// Parses comma-separated, newline-separated, or quoted Jenkins job strings
    /// e.g. `'HS-1/crypto-fusion/merchant', 'HS-1/crypto-fusion/client'` -> `["HS-1/crypto-fusion/merchant", "HS-1/crypto-fusion/client"]`
    public static func parseJobList(_ raw: String) -> [String] {
        let parts = raw.components(separatedBy: CharacterSet(charactersIn: ",;\n\r"))
        var result: [String] = []
        for part in parts {
            var item = part.trimmingCharacters(in: .whitespacesAndNewlines)
            while (item.hasPrefix("'") && item.hasSuffix("'")) || (item.hasPrefix("\"") && item.hasSuffix("\"")) {
                item = String(item.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            item = normalizeJenkinsJobInput(item)
            if !item.isEmpty && !result.contains(item) {
                result.append(item)
            }
        }
        return result
    }

    /// Converts full Jenkins job URLs like `https://jenkins.../job/Folder/job/App/` into `Folder/App`
    public static func normalizeJenkinsJobInput(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }
        if let url = URL(string: s), s.lowercased().hasPrefix("http"), url.path.contains("/job/") {
            let segments = url.path.components(separatedBy: "/job/").dropFirst()
            let cleaned = segments.compactMap { seg -> String? in
                let firstPart = seg.split(separator: "/").first.map(String.init) ?? seg
                return firstPart.removingPercentEncoding ?? firstPart
            }.filter { !$0.isEmpty }
            if !cleaned.isEmpty {
                return cleaned.joined(separator: "/")
            }
        }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    public static func parseJenkinsfileJobName(_ content: String) -> String? {
        let pattern = #"(?m)^\s*(?:def\s+)?name\s*=\s*['"]([^'"]+)['"]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        guard let match = regex.firstMatch(in: content, range: range),
              let capRange = Range(match.range(at: 1), in: content) else {
            return nil
        }
        return String(content[capRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Scans `workspacePath` (and its immediate subdirectories) for `.git` repositories and matches Jenkins jobs.
    public static func discoverGitRepos(
        at workspacePath: String,
        existingRepos: [MACRepo] = [],
        stagingJobs: [String] = [],
        prodJobs: [String] = []
    ) -> [MACRepo] {
        let rootPath = expandPath(workspacePath)
        guard !rootPath.isEmpty else { return existingRepos }
        let fm = FileManager.default
        var existingByName: [String: MACRepo] = [:]
        for r in existingRepos {
            existingByName[r.name] = r
        }

        var discovered: [MACRepo] = []

        func inspectDir(_ dirPath: String, repoName: String) {
            let gitPath = (dirPath as NSString).appendingPathComponent(".git")
            guard fm.fileExists(atPath: gitPath) else { return }

            var detectedJob = ""
            let jfPath = (dirPath as NSString).appendingPathComponent("Jenkinsfile")
            if let content = try? String(contentsOfFile: jfPath, encoding: .utf8),
               let parsed = parseJenkinsfileJobName(content) {
                detectedJob = parsed
            }

            if let prev = existingByName[repoName] {
                var updated = prev
                updated.path = dirPath
                if updated.jenkinsJob.isEmpty, let matched = bestMatchingJob(forRepo: repoName, workspacePath: rootPath, jobs: stagingJobs) {
                    updated.jenkinsJob = matched
                    updated.deployEnabled = true
                }
                if updated.prodJenkinsJob.isEmpty, let matchedProd = bestMatchingJob(forRepo: repoName, workspacePath: rootPath, jobs: prodJobs) {
                    updated.prodJenkinsJob = matchedProd
                }
                discovered.append(updated)
                return
            }

            let matchedStaging = bestMatchingJob(forRepo: repoName, workspacePath: rootPath, jobs: stagingJobs) ?? detectedJob
            let matchedProd = bestMatchingJob(forRepo: repoName, workspacePath: rootPath, jobs: prodJobs) ?? ""
            discovered.append(
                MACRepo(
                    name: repoName,
                    path: dirPath,
                    jenkinsJob: matchedStaging,
                    prodJenkinsJob: matchedProd,
                    branch: "",
                    deployEnabled: !matchedStaging.isEmpty
                )
            )
        }

        let rootName = URL(fileURLWithPath: rootPath).lastPathComponent
        inspectDir(rootPath, repoName: rootName)

        if let children = try? fm.contentsOfDirectory(atPath: rootPath).sorted() {
            for child in children where !child.hasPrefix(".") {
                let childPath = (rootPath as NSString).appendingPathComponent(child)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: childPath, isDirectory: &isDir), isDir.boolValue {
                    inspectDir(childPath, repoName: child)
                }
            }
        }

        return discovered
    }

    public static func bestMatchingJob(forRepo repoName: String, workspacePath: String, jobs: [String]) -> String? {
        guard !jobs.isEmpty else { return nil }
        if jobs.count == 1 && repoName == URL(fileURLWithPath: workspacePath).lastPathComponent {
            return jobs[0]
        }

        let normRepo = repoName.lowercased().replacingOccurrences(of: "_", with: "-")
        for job in jobs {
            let leaf = (job.split(separator: "/").last.map(String.init) ?? job).lowercased()
            let suffix = leaf.replacingOccurrences(
                of: #"^[a-z0-9.-]+\.[a-z]{2,}-"#,
                with: "",
                options: .regularExpression
            ).replacingOccurrences(of: "_", with: "-")

            if suffix == normRepo || leaf == normRepo {
                return job
            }
            if normRepo == "dashboard-\(suffix)" || normRepo == "microservices-\(suffix)" || normRepo == "http-\(suffix)" {
                return job
            }
            if (suffix == "core" || suffix == "gate") && (normRepo == URL(fileURLWithPath: workspacePath).lastPathComponent.lowercased() || normRepo.contains("fusion") || normRepo.contains("payment-book")) {
                return job
            }
        }
        return nil
    }
}

public final class MACConfigFileStore {
    public let dataDir: URL
    public var configFileURL: URL { dataDir.appendingPathComponent("config.json") }

    public init(dataDir: URL) {
        self.dataDir = dataDir
    }

    public func load() -> MACConfig {
        let fm = FileManager.default
        try? fm.createDirectory(at: dataDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let data = try? Data(contentsOf: configFileURL),
              let decoded = try? JSONDecoder().decode(MACConfig.self, from: data) else {
            return MACConfig()
        }
        return decoded
    }

    public func save(_ config: MACConfig) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dataDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        let encodedData = try encoder.encode(config)

        // Preserve any custom top-level keys if an existing config.json exists
        var finalData = encodedData
        if let existingRaw = try? Data(contentsOf: configFileURL),
           var existingDict = (try? JSONSerialization.jsonObject(with: existingRaw)) as? [String: Any],
           let newDict = (try? JSONSerialization.jsonObject(with: encodedData)) as? [String: Any] {
            for (k, v) in newDict {
                existingDict[k] = v
            }
            if let merged = try? JSONSerialization.data(withJSONObject: existingDict, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
                finalData = merged
            }
        }

        let tmpURL = dataDir.appendingPathComponent("config.json.mac.tmp")
        try finalData.write(to: tmpURL, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmpURL.path)
        if fm.fileExists(atPath: configFileURL.path) {
            _ = try fm.replaceItemAt(configFileURL, withItemAt: tmpURL)
        } else {
            try fm.moveItem(at: tmpURL, to: configFileURL)
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configFileURL.path)
    }
}

private final class InsecureTLSDelegate: NSObject, URLSessionDelegate {
    let allowInsecure: Bool
    init(allowInsecure: Bool) {
        self.allowInsecure = allowInsecure
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if allowInsecure,
           challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

public enum JenkinsConnectionTester {
    public static func testConnection(config: MACJenkinsConfig) async -> Result<String, Error> {
        let trimmedUrl = config.baseUrl.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmedUrl.isEmpty, let apiURL = URL(string: "\(trimmedUrl)/api/json?tree=nodeDescription,numExecutors") else {
            return .failure(NSError(domain: "MACJenkins", code: 1, userInfo: [NSLocalizedDescriptionKey: "Enter a valid Jenkins Base URL (e.g. https://jenkins.example.com)."]))
        }

        var req = URLRequest(url: apiURL, timeoutInterval: 12.0)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        if !config.username.isEmpty || !config.apiToken.isEmpty {
            let authRaw = "\(config.username):\(config.apiToken)"
            if let authData = authRaw.data(using: .utf8) {
                req.setValue("Basic \(authData.base64EncodedString())", forHTTPHeaderField: "Authorization")
            }
        }

        let session = URLSession(
            configuration: .ephemeral,
            delegate: InsecureTLSDelegate(allowInsecure: config.insecureTls),
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }

        do {
            let (_, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return .failure(NSError(domain: "MACJenkins", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid response from Jenkins server."]))
            }
            let version = http.value(forHTTPHeaderField: "X-Jenkins") ?? "OK"
            if (200...299).contains(http.statusCode) {
                let userNote = config.username.isEmpty ? "anonymous" : config.username
                return .success("Connected to Jenkins \(version) as \(userNote)")
            } else if http.statusCode == 401 || http.statusCode == 403 {
                return .failure(NSError(domain: "MACJenkins", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Authentication failed (HTTP \(http.statusCode)). Verify username and API token."]))
            } else {
                return .failure(NSError(domain: "MACJenkins", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Jenkins returned HTTP \(http.statusCode)."]))
            }
        } catch {
            return .failure(error)
        }
    }
}

public enum TelegramTokenTester {
    public static func verifyToken(token: String, apiBaseUrl: String = "https://api.telegram.org") async -> Result<String, Error> {
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanToken.isEmpty else {
            return .failure(NSError(domain: "MACTelegram", code: 1, userInfo: [NSLocalizedDescriptionKey: "Enter a Telegram Bot Token from @BotFather first."]))
        }
        let base = apiBaseUrl.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let effectiveBase = base.isEmpty ? "https://api.telegram.org" : base
        guard let url = URL(string: "\(effectiveBase)/bot\(cleanToken)/getMe") else {
            return .failure(NSError(domain: "MACTelegram", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid Telegram API URL or token format."]))
        }

        var req = URLRequest(url: url, timeoutInterval: 10.0)
        req.httpMethod = "GET"

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return .failure(NSError(domain: "MACTelegram", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid response from Telegram API."]))
            }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if http.statusCode == 200,
               (json?["ok"] as? Bool) == true,
               let result = json?["result"] as? [String: Any] {
                let username = (result["username"] as? String) ?? "bot"
                let firstName = (result["first_name"] as? String) ?? username
                return .success("Verified @\(username) (\(firstName)) — ready to start!")
            }
            let desc = (json?["description"] as? String) ?? "HTTP \(http.statusCode)"
            return .failure(NSError(domain: "MACTelegram", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Telegram rejected token: \(desc)"]))
        } catch {
            return .failure(error)
        }
    }
}

