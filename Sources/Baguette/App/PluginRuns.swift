import Darwin
import Foundation

/// Owns jobs independently of request tasks. The default root is private to this
/// server lifetime; a custom root retains statuses across restarts and must have
/// a single owner. Plugins atomically publish result.json before exiting.
/// Disk accounting is periodic, not an OS quota or a sandbox.
actor PluginRuns {
    enum Failure: Error, Equatable, CustomStringConvertible {
        case unknownCommand, notBackground, appsUnavailable, simulatorBusy
        case concurrencyLimit, capacity, installing, shuttingDown, storage

        var description: String {
            switch self {
            case .unknownCommand: "no installed plugin contributes this command"
            case .notBackground: "command is not background enabled"
            case .appsUnavailable: "app installation requires a target simulator and its apps"
            case .simulatorBusy: "simulator already has an active background run"
            case .concurrencyLimit: "two background runs are already active"
            case .capacity: "background run status retention is full"
            case .installing: "app installation is in progress and cannot be cancelled"
            case .shuttingDown: "background runs are shutting down"
            case .storage: "background run storage is unavailable"
            }
        }
    }

    private final class Job {
        let workspace: URL
        let child: any Subprocess
        let redactions: NSRegularExpression?
        var task: Task<Void, Never>?
        var monitor: Task<Void, Never>?
        var escalation: Task<Void, Never>?
        var reason: String?
        var cancelled = false
        var processPending = false
        var installing = false

        init(workspace: URL, child: any Subprocess, secrets: [String]) {
            self.workspace = workspace
            self.child = child
            let unique = Set(secrets.filter { !$0.isEmpty && $0.utf8.count <= 65536 })
            let literals = unique.sorted { left, right in
                let leftLength = left.utf16.count
                let rightLength = right.utf16.count
                return leftLength == rightLength ? left < right : leftLength > rightLength
            }
            var patterns: [String] = []
            var bytes = 0
            for literal in literals {
                let pattern = NSRegularExpression.escapedPattern(for: literal)
                bytes += pattern.utf8.count + 1
                guard bytes <= 128 * 1024 else { redactions = nil; return }
                patterns.append(pattern)
            }
            redactions = try? NSRegularExpression(pattern: patterns.isEmpty ? "(?!)" : patterns.joined(separator: "|"))
        }

        func redact(_ value: String) -> String {
            // Match only original text, longest alternatives first. Never scan
            // replacement markers again; excessive input/patterns fail closed.
            guard value.utf8.count <= 65536, let redactions else { return "[redacted]" }
            let redacted = redactions.stringByReplacingMatches(in: value,
                range: NSRange(value.startIndex..., in: value), withTemplate: "[redacted]")
            var result = String.UnicodeScalarView()
            var bytes = 0
            for scalar in redacted.unicodeScalars {
                bytes += scalar.utf8.count
                guard bytes <= 4096 else { break }
                result.append(scalar)
            }
            return String(result)
        }
    }

    private let root: URL
    private let capacity: Int
    private let hostEnvironment: [String: String]
    private let timeout: Duration?
    private let grace: Duration
    private let pollInterval: Duration
    private let workspaceLimitBytes: Int64
    private let subprocess: @Sendable () -> any Subprocess
    private var statuses: [String: PluginRun] = [:]
    private var jobs: [String: Job] = [:]
    private var storageUnavailable = false
    private var closing = false

    init(
        root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("baguette-runs-\(UUID())"),
        capacity: Int = 1000,
        hostEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: Duration? = nil, grace: Duration = .seconds(2),
        pollInterval: Duration = .seconds(1),
        workspaceLimitBytes: Int64 = 24 * 1024 * 1024 * 1024,
        subprocess: @escaping @Sendable () -> any Subprocess = { RunSubprocess() }
    ) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.capacity = max(0, min(capacity, 1000))
        self.hostEnvironment = hostEnvironment
        self.timeout = timeout
        self.grace = grace
        self.pollInterval = pollInterval
        self.workspaceLimitBytes = workspaceLimitBytes
        self.subprocess = subprocess
        do {
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            for file in try FileManager.default.contentsOfDirectory(at: self.root, includingPropertiesForKeys: nil)
            where file.pathExtension == "json" {
                guard statuses.count < self.capacity else { throw Failure.capacity }
                var run = try JSONDecoder().decode(PluginRun.self, from: Self.read(file, within: self.root))
                guard UUID(uuidString: run.id) != nil, file.lastPathComponent == "\(run.id).json" else {
                    throw Failure.storage
                }
                if !run.isFinished {
                    // A registry restart cannot resume an invocation or its grant.
                    let workspace = self.root.appendingPathComponent(run.id)
                    var message = "background run interrupted by server restart"
                    if FileManager.default.fileExists(atPath: workspace.path) {
                        do { try FileManager.default.removeItem(at: workspace) }
                        catch { message = "background workspace cleanup failed" }
                    }
                    run.finish(state: .failed, message: message)
                    try JSONEncoder().encode(run).write(to: file, options: .atomic)
                }
                statuses[run.id] = run
            }
        } catch { storageUnavailable = true }
    }

    func start(
        qualifiedCommand: String, context: PluginDispatch.Context,
        plugins: any Plugins, grants: PluginGrants, apps: (any Apps)? = nil
    ) throws -> PluginRun {
        guard !closing else { throw Failure.shuttingDown }
        guard !storageUnavailable else { throw Failure.storage }
        guard let (plugin, command) = try plugins.resolve(qualifiedCommand: qualifiedCommand) else {
            throw Failure.unknownCommand
        }
        guard let spec = command.background else { throw Failure.notBackground }
        if plugin.manifest.capabilities.contains(.apps), apps == nil || context.udid == nil {
            throw Failure.appsUnavailable
        }
        if let udid = context.udid, jobs.keys.contains(where: { statuses[$0]?.udid == udid }) {
            throw Failure.simulatorBusy
        }
        guard jobs.count < 2 else { throw Failure.concurrencyLimit }
        guard statuses.count < capacity else { throw Failure.capacity }

        let run = PluginRun(id: UUID().uuidString, command: qualifiedCommand, udid: context.udid)
        let workspace = root.appendingPathComponent(run.id, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            try persist(run)
        } catch {
            if FileManager.default.fileExists(atPath: workspace.path) {
                do { try FileManager.default.removeItem(at: workspace) }
                catch { storageUnavailable = true }
            }
            throw Failure.storage
        }
        var environment = ["PATH": hostEnvironment["PATH"] ?? "/usr/bin:/bin"]
        for name in spec.environment { environment[name] = hostEnvironment[name] }
        let token = grants.issue(plugin: plugin.id, capabilities: plugin.manifest.capabilities)
        environment["BAGUETTE_URL"] = context.serverURL
        environment["BAGUETTE_TOKEN"] = token
        environment["BAGUETTE_UDID"] = context.udid
        environment["BAGUETTE_RUN_DIR"] = workspace.path
        var payload: [String: Any] = ["version": 1, "command": qualifiedCommand,
            "url": context.serverURL, "token": token, "workspace": workspace.path]
        payload["udid"] = context.udid
        payload["args"] = context.args?.object
        let stdin = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let job = Job(workspace: workspace, child: subprocess(),
            secrets: spec.environment.compactMap { hostEnvironment[$0] } + [token, context.token]
                + Self.strings(context.args?.object))
        statuses[run.id] = run
        jobs[run.id] = job
        let environmentCopy = environment
        job.task = Task {
            await self.execute(run.id, plugin: plugin, command: command,
                environment: environmentCopy, stdin: stdin, token: token, grants: grants,
                apps: apps, deadline: self.timeout ?? .seconds(spec.timeoutSeconds))
        }
        return run
    }

    func get(_ id: String) -> PluginRun? {
        guard var run = statuses[id] else { return nil }
        if let job = jobs[id], !job.installing,
           let data = try? Self.read(job.workspace.appendingPathComponent("progress.json"), within: job.workspace),
           let progress = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let phase = progress["phase"] as? String { run.phase = job.redact(phase) }
            if let bytes = progress["downloadedBytes"] as? NSNumber,
               CFGetTypeID(bytes) != CFBooleanGetTypeID(), bytes.int64Value >= 0,
               bytes.doubleValue == Double(bytes.int64Value) { run.downloadedBytes = bytes.int64Value }
            statuses[id] = run
        }
        return run
    }

    func cancel(_ id: String) throws -> PluginRun? {
        guard let job = jobs[id] else { return statuses[id] }
        guard !job.installing else { throw Failure.installing }
        stop(id, reason: "background command cancelled", cancelled: true)
        return statuses[id]
    }

    func shutdown() async {
        closing = true
        let pending = jobs.values.compactMap(\.task)
        for (id, job) in jobs where !job.installing {
            stop(id, reason: "background command cancelled", cancelled: true)
        }
        for task in pending { await task.value }
    }

    private func execute(
        _ id: String, plugin: Plugin, command: PluginCommand, environment: [String: String],
        stdin: Data, token: String, grants: PluginGrants, apps: (any Apps)?, deadline: Duration
    ) async {
        guard let job = jobs[id] else { return }
        var state: PluginRun.State = .succeeded
        var message: String?
        if job.reason == nil {
            statuses[id]?.start()
            do {
                try persist(statuses[id]!)
                job.processPending = true
                let expires = ContinuousClock.now.advanced(by: deadline)
                job.monitor = Task {
                    while !Task.isCancelled {
                        guard (try? await Task.sleep(for: self.pollInterval)) != nil else { return }
                        self.inspect(id, expires: expires)
                    }
                }
                let status: Int32 = try await withCheckedThrowingContinuation { continuation in
                    do {
                        // This synchronous start is actor-isolated: cancellation
                        // cannot signal an unstarted child and then lose the race.
                        try job.child.run(executable: URL(fileURLWithPath: "/usr/bin/env"),
                            arguments: command.run, workingDirectory: plugin.root,
                            environment: environment, stdin: stdin, onBytes: { _ in },
                            onExit: { continuation.resume(returning: $0) })
                    } catch { continuation.resume(throwing: Failure.storage) }
                }
                job.processPending = false
                job.monitor?.cancel()
                job.escalation?.cancel()
                grants.revoke(token)
                if job.reason == nil {
                    let result: [String: Any]? = try? {
                        let data = try Self.read(job.workspace.appendingPathComponent("result.json"), within: job.workspace)
                        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    }()
                    guard let result,
                          let ok = result["ok"] as? NSNumber,
                          CFGetTypeID(ok) == CFBooleanGetTypeID() else {
                        if status != 0 { throw RunError("background command exited \(status)") }
                        throw RunError("background command produced an invalid result")
                    }
                    guard ok.boolValue else {
                        throw RunError(result["message"] as? String ?? "background command reported failure")
                    }
                    guard status == 0 else { throw RunError("background command exited \(status)") }
                    if plugin.manifest.capabilities.contains(.apps), result["output"] == nil {
                        throw RunError("background command produced no app output")
                    }
                    if let output = result["output"] {
                        guard plugin.manifest.capabilities.contains(.apps), let apps,
                              let output = output as? [String: Any],
                              output["kind"] as? String == "simulator-app",
                              let path = output["path"] as? String else {
                            throw RunError("background command produced unauthorized or invalid app output")
                        }
                        let app = try Self.app(path, workspace: job.workspace)
                        job.installing = true
                        statuses[id]?.phase = "installing"
                        try await apps.install(AppBundle(path: app))
                    }
                }
            } catch {
                state = .failed
                message = job.processPending ? "background command failed to start"
                    : (error as? RunError)?.description ?? (error as? AppsError)?.description
                        ?? "background command result or app installation failed"
            }
        }
        job.processPending = false
        job.monitor?.cancel()
        job.escalation?.cancel()
        grants.revoke(token)
        if let reason = job.reason {
            state = job.cancelled ? .cancelled : .failed
            message = reason
        }
        do { try FileManager.default.removeItem(at: job.workspace) }
        catch { state = .failed; message = "background workspace cleanup failed" }
        statuses[id]?.finish(state: state, message: message.map(job.redact))
        do { try persist(statuses[id]!) }
        catch {
            storageUnavailable = true
            // finish is intentionally terminal-only; reconstruct to report a
            // persistence failure without pretending the disk write succeeded.
            if let old = statuses[id] {
                var failed = PluginRun(id: old.id, command: old.command, udid: old.udid)
                failed.finish(state: .failed, message: "background run status persistence failed")
                statuses[id] = failed
            }
        }
        jobs.removeValue(forKey: id)
    }

    private func inspect(_ id: String, expires: ContinuousClock.Instant) {
        guard let job = jobs[id], job.processPending, job.reason == nil else { return }
        if ContinuousClock.now >= expires {
            stop(id, reason: "background command timed out")
        } else {
            do {
                if try Self.size(job.workspace, limit: workspaceLimitBytes) > workspaceLimitBytes {
                    stop(id, reason: "background workspace exceeds its disk allowance")
                }
            } catch { stop(id, reason: "background workspace could not be inspected") }
        }
    }

    private func stop(_ id: String, reason: String, cancelled: Bool = false) {
        guard let job = jobs[id], job.reason == nil else { return }
        job.reason = reason
        job.cancelled = cancelled
        guard job.processPending else { return }
        job.child.terminate()
        job.escalation = Task {
            guard (try? await Task.sleep(for: self.grace)) != nil else { return }
            if job.processPending { job.child.kill() }
        }
    }

    private func persist(_ run: PluginRun) throws {
        try JSONEncoder().encode(run).write(to: root.appendingPathComponent("\(run.id).json"), options: .atomic)
    }

    private struct RunError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private static func strings(_ value: Any?) -> [String] {
        if let string = value as? String { return [string] }
        if let array = value as? [Any] { return array.flatMap(strings) }
        if let object = value as? [String: Any] { return object.values.flatMap(strings) }
        return []
    }

    private static func contains(_ url: URL, in root: URL) -> Bool {
        url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/")
    }

    /// O_NOFOLLOW plus fstat prevents symlinks, FIFOs and unbounded reads.
    private static func read(_ url: URL, within root: URL) throws -> Data {
        guard contains(url, in: root) else { throw Failure.storage }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw Failure.storage }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size <= 65536 else { throw Failure.storage }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try handle.read(upToCount: 65537) ?? Data()
        guard data.count <= 65536 else { throw Failure.storage }
        return data
    }

    private static func app(_ path: String, workspace: URL) throws -> URL {
        let components = path.components(separatedBy: "/")
        guard !path.hasPrefix("/"), !components.contains(".."), !components.contains("."),
              !components.contains(""), !path.contains("\0") else { throw Failure.storage }
        let url = workspace.appendingPathComponent(path)
        var directory: ObjCBool = false
        guard url.pathExtension == "app", contains(url, in: workspace),
              FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else {
            throw Failure.storage
        }
        var unreadable = false
        guard let files = FileManager.default.enumerator(at: url.resolvingSymlinksInPath(),
            includingPropertiesForKeys: nil, errorHandler: { _, _ in unreadable = true; return false }) else {
            throw Failure.storage
        }
        for case let file as URL in files {
            guard contains(file, in: workspace) else { throw Failure.storage }
        }
        guard !unreadable else { throw Failure.storage }
        return url.resolvingSymlinksInPath()
    }

    private static func size(_ workspace: URL, limit: Int64) throws -> Int64 {
        var unreadable = false
        guard let files = FileManager.default.enumerator(at: workspace,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .fileSizeKey],
            errorHandler: { _, _ in unreadable = true; return false }) else { throw Failure.storage }
        var total: Int64 = 0
        for case let file as URL in files {
            let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
            if values.isSymbolicLink == true { continue }
            let bytes = Int64(values.fileSize ?? 0)
            if bytes > limit - total { return limit == Int64.max ? limit : limit + 1 }
            total += bytes
        }
        guard !unreadable else { throw Failure.storage }
        return total
    }
}
