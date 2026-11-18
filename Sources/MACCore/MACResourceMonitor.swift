import Foundation
import Darwin

public struct MACProcessMetrics: Equatable {
    public var cpuPercent: Double
    public var memoryMB: Double

    public init(cpuPercent: Double = 0.0, memoryMB: Double = 0.0) {
        self.cpuPercent = cpuPercent
        self.memoryMB = memoryMB
    }

    public var formattedCPU: String {
        String(format: "%.1f%%", max(0.0, cpuPercent))
    }

    public var formattedMemory: String {
        if memoryMB >= 1024.0 {
            return String(format: "%.2f GB", memoryMB / 1024.0)
        }
        return String(format: "%.1f MB", max(0.0, memoryMB))
    }
}

@MainActor
public final class MACResourceMonitor: ObservableObject {
    @Published public private(set) var appMetrics = MACProcessMetrics()
    @Published public private(set) var botMetrics = MACProcessMetrics()
    @Published public private(set) var agentMetrics = MACProcessMetrics()
    @Published public private(set) var activeAgentProcessCount: Int = 0

    private var previousAppCPUTime: UInt64 = 0
    private var previousBotCPUTime: UInt64 = 0
    private var previousAgentCPUTime: UInt64 = 0
    private var previousSampleTime: Date = Date()
    private var timer: Timer?

    public init() {}

    deinit {
        timer?.invalidate()
    }

    public func start(botPidProvider: @escaping () -> pid_t?) {
        stop()
        sample(botPid: botPidProvider())
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.sample(botPid: botPidProvider())
            }
        }
        if let t = timer {
            RunLoop.main.add(t, forMode: .common)
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    public func sample(botPid: pid_t?) {
        let now = Date()
        let elapsed = max(0.1, now.timeIntervalSince(previousSampleTime))
        previousSampleTime = now

        // 1. MAC App (Host Process)
        if let (appRAM, appCPU) = queryProcess(pid: getpid()) {
            var cpuRate: Double = 0.0
            if previousAppCPUTime > 0 && appCPU >= previousAppCPUTime {
                let deltaNano = Double(appCPU - previousAppCPUTime)
                cpuRate = min(800.0, max(0.0, (deltaNano / (elapsed * 1_000_000_000.0)) * 100.0))
            }
            previousAppCPUTime = appCPU
            appMetrics = MACProcessMetrics(cpuPercent: cpuRate, memoryMB: appRAM)
        }

        // 2. Bot Process (Node.js runtime)
        guard let bPid = botPid, bPid > 0, let (botRAM, botCPU) = queryProcess(pid: bPid) else {
            botMetrics = MACProcessMetrics()
            agentMetrics = MACProcessMetrics()
            activeAgentProcessCount = 0
            previousBotCPUTime = 0
            previousAgentCPUTime = 0
            return
        }

        var botCPURate: Double = 0.0
        if previousBotCPUTime > 0 && botCPU >= previousBotCPUTime {
            let deltaNano = Double(botCPU - previousBotCPUTime)
            botCPURate = min(800.0, max(0.0, (deltaNano / (elapsed * 1_000_000_000.0)) * 100.0))
        }
        previousBotCPUTime = botCPU
        botMetrics = MACProcessMetrics(cpuPercent: botCPURate, memoryMB: botRAM)

        // 3. Agent Child Process Tree (Processes spawned by bot, e.g. agy, aider, codex, git, etc.)
        let childPids = getDescendantPids(parentPid: bPid)
        activeAgentProcessCount = childPids.count
        var totalAgentRAM: Double = 0.0
        var totalAgentCPUTime: UInt64 = 0

        for cPid in childPids {
            if let (cRAM, cCPU) = queryProcess(pid: cPid) {
                totalAgentRAM += cRAM
                totalAgentCPUTime += cCPU
            }
        }

        var agentCPURate: Double = 0.0
        if previousAgentCPUTime > 0 && totalAgentCPUTime >= previousAgentCPUTime {
            let deltaNano = Double(totalAgentCPUTime - previousAgentCPUTime)
            agentCPURate = min(1600.0, max(0.0, (deltaNano / (elapsed * 1_000_000_000.0)) * 100.0))
        }
        previousAgentCPUTime = totalAgentCPUTime
        agentMetrics = MACProcessMetrics(cpuPercent: agentCPURate, memoryMB: totalAgentRAM)
    }

    private func queryProcess(pid: pid_t) -> (ramMB: Double, cpuTimeNano: UInt64)? {
        guard pid > 0 else { return nil }
        var info = proc_taskinfo()
        let size = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(MemoryLayout<proc_taskinfo>.size))
        guard size == MemoryLayout<proc_taskinfo>.size else { return nil }
        let ram = Double(info.pti_resident_size) / 1024.0 / 1024.0
        let cpuTime = info.pti_total_user + info.pti_total_system
        return (ram, cpuTime)
    }

    private func getChildPids(parentPid: pid_t) -> [pid_t] {
        guard parentPid > 0 else { return [] }
        let bufSize = 128
        var pids = [pid_t](repeating: 0, count: bufSize)
        let bytesUsed = proc_listchildpids(parentPid, &pids, Int32(MemoryLayout<pid_t>.size * bufSize))
        guard bytesUsed > 0 else { return [] }
        let count = Int(bytesUsed) / MemoryLayout<pid_t>.size
        return Array(pids.prefix(count)).filter { $0 > 0 }
    }

    private func getDescendantPids(parentPid: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        var visited: Set<pid_t> = [parentPid]
        var queue = [parentPid]
        while !queue.isEmpty {
            let curr = queue.removeFirst()
            let children = getChildPids(parentPid: curr)
            for child in children {
                if !visited.contains(child) {
                    visited.insert(child)
                    result.append(child)
                    queue.append(child)
                }
            }
        }
        return result
    }
}
