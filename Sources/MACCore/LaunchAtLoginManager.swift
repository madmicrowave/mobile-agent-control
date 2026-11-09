import Foundation

public final class LaunchAtLoginManager {
    public static let agentLabel = "com.domonk.mac"

    public let launchAgentsDirectory: URL
    public let executablePathProvider: () -> String

    public var plistURL: URL {
        launchAgentsDirectory.appendingPathComponent("\(Self.agentLabel).plist")
    }

    public init(
        launchAgentsDirectory: URL? = nil,
        executablePathProvider: @escaping () -> String = LaunchAtLoginManager.defaultExecutablePath
    ) {
        self.launchAgentsDirectory = launchAgentsDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        self.executablePathProvider = executablePathProvider
    }

    public static func defaultExecutablePath() -> String {
        if Bundle.main.bundleURL.pathExtension == "app",
           let bundleExec = Bundle.main.executableURL?.path,
           FileManager.default.isExecutableFile(atPath: bundleExec) {
            return bundleExec
        }
        let candidates = [
            "/Applications/mac.app/Contents/MacOS/MAC",
            "/Applications/MAC.app/Contents/MacOS/MAC"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        if let bundleExec = Bundle.main.executableURL?.path,
           FileManager.default.isExecutableFile(atPath: bundleExec) {
            return bundleExec
        }
        return "/Applications/mac.app/Contents/MacOS/MAC"
    }

    public var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    @discardableResult
    public func setEnabled(_ enabled: Bool) throws -> Bool {
        let fm = FileManager.default
        if enabled {
            try fm.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true)
            let execPath = executablePathProvider()
            let plistDict: [String: Any] = [
                "Label": Self.agentLabel,
                "ProgramArguments": [execPath],
                "RunAtLoad": true,
                "KeepAlive": false,
                "ProcessType": "Interactive"
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: plistDict, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
            return true
        } else {
            if fm.fileExists(atPath: plistURL.path) {
                try fm.removeItem(at: plistURL)
            }
            return false
        }
    }

    public func ensureDefaultEnabledOnFirstLaunch(defaults: UserDefaults = .standard) {
        if ProcessInfo.processInfo.environment["MAC_DISABLE_AUTO_LAUNCH_AGENT"] == "1" {
            return
        }
        let key = "com.domonk.mac.didConfigureDefaultLaunchAtLogin"
        if !defaults.bool(forKey: key) {
            _ = try? setEnabled(true)
            defaults.set(true, forKey: key)
        } else if isEnabled {
            // Refresh executable path in case MAC.app moved to /Applications
            _ = try? setEnabled(true)
        }
    }
}
