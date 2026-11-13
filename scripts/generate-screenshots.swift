import AppKit
import SwiftUI
import Combine

@main
struct ScreenshotGenerator {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .darkAqua)

        let projectRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let assetsDir = projectRoot.appendingPathComponent("assets")
        try? FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("mac-preview-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let sampleConfig = MACConfig(
            agyBin: "~/.local/bin/agy",
            aiderBin: "aider",
            agentEngine: "agy",
            openaiApiKey: "sk-proj-••••••••••••••••••••••••••••••••",
            anthropicApiKey: "sk-ant-••••••••••••••••••••••••••••••••",
            deepseekApiKey: "sk-dsk-••••••••••••••••••••••••••••••••",
            qwenApiKey: "",
            customApiBaseUrl: "",
            customApiKey: "",
            defaultModel: "gemini-2.0-flash",
            defaultModelLevel: "high",
            skipPermissions: true,
            jenkins: MACJenkinsConfig(
                baseUrl: "https://jenkins.acme.dev",
                username: "deploy-bot",
                apiToken: "••••••••••••••••••••••••••••••••••••••••",
                jobPrefix: "",
                insecureTls: false,
                pollIntervalMs: 3000,
                buildTimeoutMs: 1_500_000
            ),
            github: MACGitHubConfig(
                token: "ghp_••••••••••••••••••••••••••••••••",
                owner: "acme"
            ),
            googleCloud: MACGoogleCloudConfig(
                projectId: "acme-cloud-prod",
                serviceAccountKey: "",
                region: "us-central1"
            ),
            workspaces: [
                MACWorkspace(
                    id: "saas-platform",
                    label: "SAAS PLATFORM",
                    path: "/Users/dev/code/saas-platform",
                    extraDirs: [],
                    liveUrl: "https://staging.acme.dev",
                    model: "gemini-2.0-flash",
                    modelLevel: "high",
                    engine: "agy",
                    environmentMode: "multi",
                    ciProvider: "jenkins",
                    jenkinsJobs: ["STAGING/saas-platform/web-app", "STAGING/saas-platform/core-api"],
                    prodJenkinsJobs: ["PROD/saas-platform/web-app"],
                    repos: [
                        MACRepo(
                            name: "saas-platform",
                            path: "/Users/dev/code/saas-platform",
                            jenkinsJob: "STAGING/saas-platform/web-app",
                            prodJenkinsJob: "PROD/saas-platform/web-app",
                            branch: "main",
                            deployEnabled: true,
                            ciProvider: "jenkins"
                        )
                    ]
                ),
                MACWorkspace(
                    id: "macos-open-source",
                    label: "MACOS OPEN SOURCE",
                    path: "/Users/dev/code/macos-open-source",
                    extraDirs: [],
                    liveUrl: "",
                    model: "claude-opus-3.5",
                    modelLevel: "high",
                    engine: "aider",
                    environmentMode: "single",
                    ciProvider: "none",
                    jenkinsJobs: [],
                    prodJenkinsJobs: [],
                    repos: [
                        MACRepo(
                            name: "macos-open-source",
                            path: "/Users/dev/code/macos-open-source",
                            branch: "master",
                            deployEnabled: false,
                            ciProvider: "none"
                        )
                    ]
                ),
                MACWorkspace(
                    id: "crypto-gateway",
                    label: "CRYPTO GATEWAY",
                    path: "/Users/dev/code/crypto-gateway",
                    extraDirs: [],
                    liveUrl: "",
                    model: "gemini-4-argon",
                    modelLevel: "medium",
                    engine: "direct-api",
                    environmentMode: "single",
                    ciProvider: "github",
                    githubRepo: "acme/crypto-gateway",
                    githubWorkflow: "deploy.yml",
                    jenkinsJobs: [],
                    prodJenkinsJobs: [],
                    repos: [
                        MACRepo(
                            name: "crypto-gateway",
                            path: "/Users/dev/code/crypto-gateway",
                            branch: "main",
                            deployEnabled: true,
                            ciProvider: "github",
                            githubRepo: "acme/crypto-gateway",
                            githubWorkflow: "deploy.yml"
                        )
                    ]
                )
            ],
            telegramBotToken: "••••••••••••••••••••••••••••••••••••••••",
            telegramApiBaseUrl: "https://api.telegram.org",
            allowedUserIds: ["102938475"],
            defaultHistoryCount: 20
        )

        let appState = MACAppState(dataDir: URL(fileURLWithPath: "/Users/dev/Library/Application Support/MACData"))
        appState.config = sampleConfig
        appState.status = .running(botUsername: "acme_mac_bot")
        appState.isSleepPrevented = true
        appState.launchAtLogin = true

        func renderTab(tab: MACSettingsTab, size: NSSize, outFile: URL) {
            appState.selectedTab = tab
            if tab == .workspaces {
                appState.selectedWorkspaceId = "saas-platform"
            }

            let rootView = MACSettingsRootView(
                appState: appState,
                onStartRequested: {},
                onRestartRequested: {},
                onStopRequested: {}
            )
            .preferredColorScheme(.dark)

            let hosting = NSHostingController(rootView: rootView)
            let window = NSWindow(contentViewController: hosting)
            window.appearance = NSAppearance(named: .darkAqua)
            window.setContentSize(size)
            window.setFrame(NSRect(origin: .zero, size: size), display: true)

            let deadline = Date().addingTimeInterval(0.5)
            while Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }

            let contentView = window.contentView!
            contentView.layoutSubtreeIfNeeded()

            let scale: CGFloat = 2.0
            let pixelWidth = Int(size.width * scale)
            let pixelHeight = Int(size.height * scale)

            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixelWidth,
                pixelsHigh: pixelHeight,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )!
            rep.size = size
            contentView.cacheDisplay(in: contentView.bounds, to: rep)

            if let pngData = rep.representation(using: .png, properties: [:]) {
                do {
                    try pngData.write(to: outFile)
                    print("Generated \(outFile.path) (\(pixelWidth)x\(pixelHeight) px @ \(Int(size.width))x\(Int(size.height)) pt)")
                } catch {
                    fputs("Failed to write \(outFile.path): \(error)\n", stderr)
                }
            }
        }

        let genOut = assetsDir.appendingPathComponent("macos-general-tab.png")
        let workOut = assetsDir.appendingPathComponent("macos-workspaces-tab.png")

        renderTab(tab: .general, size: NSSize(width: 800, height: 1180), outFile: genOut)
        renderTab(tab: .workspaces, size: NSSize(width: 800, height: 1300), outFile: workOut)
    }
}


