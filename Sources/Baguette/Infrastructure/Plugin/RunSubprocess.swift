import Darwin
import Foundation

/// Background commands need no output pipe: their contract is result.json.
/// The wrapper establishes its own process group before exec; signaling group and
/// leader also covers cancellation before the wrapper has established it.
final class RunSubprocess: Subprocess, @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var requested: Int32?
    private var started = false
    private let cleanupTimeout: Duration
    private let pollInterval: Duration
    private let groupHasLiveProcesses: @Sendable (Int32) -> Bool?

    init(cleanupTimeout: Duration = .seconds(2), pollInterval: Duration = .milliseconds(10),
         groupHasLiveProcesses: @escaping @Sendable (Int32) -> Bool? = { RunSubprocess.liveProcesses(in: $0) }) {
        self.cleanupTimeout = cleanupTimeout
        self.pollInterval = pollInterval
        self.groupHasLiveProcesses = groupHasLiveProcesses
    }

    func run(
        executable: URL, arguments: [String],
        onBytes: @escaping @Sendable (Data) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws {
        try run(executable: executable, arguments: arguments, stdin: Data(), onBytes: onBytes, onExit: onExit)
    }

    func run(
        executable: URL, arguments: [String], stdin: Data,
        onBytes: @escaping @Sendable (Data) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws {
        try run(executable: executable, arguments: arguments,
            workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            environment: ProcessInfo.processInfo.environment, stdin: stdin, onBytes: onBytes, onExit: onExit)
    }

    func run(
        executable: URL, arguments: [String], workingDirectory: URL,
        environment: [String: String], stdin: Data,
        onBytes: @escaping @Sendable (Data) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws {
        try lock.withLock {
            guard !started, requested == nil else { throw SubprocessError.notInteractive }
            started = true
            // An unlinked regular file avoids pipe backpressure, SIGPIPE and
            // a writer task that can outlive the run or retain its secrets.
            let inputURL = FileManager.default.temporaryDirectory.appendingPathComponent("baguette-stdin-\(UUID())")
            guard FileManager.default.createFile(atPath: inputURL.path, contents: stdin,
                attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
            defer { try? FileManager.default.removeItem(at: inputURL) }
            let input = try FileHandle(forReadingFrom: inputURL)
            defer { try? input.close() }
            try FileManager.default.removeItem(at: inputURL)
            let output = try FileHandle(forWritingTo: URL(fileURLWithPath: "/dev/null"))
            defer { try? output.close() }
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            child.arguments = ["-e", "use POSIX (); POSIX::setpgid(0, 0) == 0 or die 'setpgid'; exec @ARGV; die 'exec';", "--", executable.path] + arguments
            child.currentDirectoryURL = workingDirectory
            child.environment = environment
            child.standardInput = input
            child.standardOutput = output
            child.standardError = output
            child.terminationHandler = { [self] exited in
                lock.withLock {
                    // A successful leader may leave downloader helpers alive.
                    // Stop them before the coordinator inspects or removes files.
                    Darwin.kill(-exited.processIdentifier, SIGKILL)
                    process = nil
                }
                let pid = exited.processIdentifier
                let status = exited.terminationStatus
                Task.detached { [self] in
                    let deadline = ContinuousClock.now.advanced(by: cleanupTimeout)
                    while groupHasLiveProcesses(pid) != false {
                        guard ContinuousClock.now < deadline else { onExit(-1); return }
                        try? await Task.sleep(for: pollInterval)
                    }
                    onExit(status)
                }
            }
            process = child
            do { try child.run() }
            catch { process = nil; throw error }
        }
    }

    func terminate() { signal(SIGTERM) }
    func kill() { signal(SIGKILL) }

    private func signal(_ signal: Int32) {
        lock.withLock {
            if requested == SIGKILL || requested == signal { return }
            requested = signal
            guard let process else { return }
            let pid = process.processIdentifier
            guard pid > 0 else { return }
            Darwin.kill(-pid, signal)
            Darwin.kill(pid, signal)
        }
    }

    /// Zombies cannot write files and may outlive us while launchd reaps them.
    /// A failed or racing process-table read is unknown, never "all stopped".
    private static func liveProcesses(in group: Int32) -> Bool? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PGRP, group]
        var bytes = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &bytes, nil, 0) == 0 else { return nil }
        let stride = MemoryLayout<kinfo_proc>.stride
        let capacity = bytes / stride + 16
        guard capacity <= 65536 else { return nil }
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        bytes = capacity * stride
        let result = processes.withUnsafeMutableBytes {
            sysctl(&mib, UInt32(mib.count), $0.baseAddress, &bytes, nil, 0)
        }
        guard result == 0, bytes % stride == 0, bytes <= capacity * stride else { return nil }
        return processes.prefix(bytes / stride).contains { $0.kp_proc.p_stat != SZOMB }
    }
}
