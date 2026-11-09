import Foundation
import IOKit.pwr_mgt

public final class SleepPreventer {
    private var assertionID: IOPMAssertionID = IOPMAssertionID(0)
    private var hasAssertion: Bool = false
    private var caffeinateProcess: Process?
    private let lock = NSLock()

    public init() {}

    deinit {
        release()
    }

    public var isPreventingSleep: Bool {
        lock.lock()
        defer { lock.unlock() }
        if hasAssertion { return true }
        if let proc = caffeinateProcess, proc.isRunning { return true }
        return false
    }

    /// Acquires macOS system sleep prevention (`IOKit` power assertion + `/usr/bin/caffeinate -is -w <pid>`)
    /// so the MacBook stays awake while the Telegram bot agent controller is running.
    @discardableResult
    public func acquire(forPid pid: Int32? = nil, reason: String = "MAC (Mobile Agent Control) Telegram Bot Active") -> Bool {
        lock.lock()
        defer { lock.unlock() }

        releaseLocked()

        var newAssertionID = IOPMAssertionID(0)
        let kr = IOPMAssertionCreateWithName(
            "PreventUserIdleSystemSleep" as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &newAssertionID
        )
        if kr == kIOReturnSuccess {
            assertionID = newAssertionID
            hasAssertion = true
        }

        if FileManager.default.isExecutableFile(atPath: "/usr/bin/caffeinate") {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
            if let pid = pid, pid > 0 {
                proc.arguments = ["-i", "-s", "-w", String(pid)]
            } else {
                proc.arguments = ["-i", "-s"]
            }
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            do {
                try proc.run()
                caffeinateProcess = proc
            } catch {
                caffeinateProcess = nil
            }
        }

        return hasAssertion || (caffeinateProcess?.isRunning == true)
    }

    public func release() {
        lock.lock()
        defer { lock.unlock() }
        releaseLocked()
    }

    private func releaseLocked() {
        if hasAssertion {
            IOPMAssertionRelease(assertionID)
            assertionID = IOPMAssertionID(0)
            hasAssertion = false
        }
        if let proc = caffeinateProcess {
            if proc.isRunning {
                proc.terminate()
            }
            caffeinateProcess = nil
        }
    }
}
