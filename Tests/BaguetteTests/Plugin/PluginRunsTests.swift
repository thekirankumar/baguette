import Foundation
import Mockable
import Testing
@testable import Baguette

@Suite("PluginRuns")
struct PluginRunsTests {
    final class Child: @unchecked Sendable {
        let subprocess = MockSubprocess()
        private let lock = NSLock()
        private var callbacks: [@Sendable (Int32) -> Void] = []
        private var env: [String: String] = [:]
        private var payload = Data()
        private var cwd: URL?
        private var stopped = false
        private var forced = false
        let answer: String?
        let exitImmediately: Bool
        let spawnFailure: Bool

        init(answer: String? = #"{"ok":true}"#, exitImmediately: Bool = true, spawnFailure: Bool = false) {
            self.answer = answer
            self.exitImmediately = exitImmediately
            self.spawnFailure = spawnFailure
            given(subprocess).run(
                executable: .any, arguments: .any, workingDirectory: .any,
                environment: .any, stdin: .any, onBytes: .any, onExit: .any
            ).willProduce { [self] _, _, cwd, env, stdin, bytes, exit in
                lock.withLock {
                    self.env = env
                    payload = stdin
                    self.cwd = cwd
                    callbacks.append(exit)
                }
                if spawnFailure { throw NSError(domain: "secret-value", code: 1) }
                if let answer {
                    try Data(answer.utf8).write(to: workspace!.appendingPathComponent("result.json"), options: .atomic)
                }
                bytes(Data("secret-value stdout must not become the result".utf8))
                if exitImmediately { finish() }
            }
            given(subprocess).terminate().willProduce { [self] in lock.withLock { stopped = true } }
            given(subprocess).kill().willProduce { [self] in
                lock.withLock { forced = true }
                finish(status: 9)
            }
        }

        var environment: [String: String] { lock.withLock { env } }
        var stdin: Data { lock.withLock { payload } }
        var directory: URL? { lock.withLock { cwd } }
        var workspace: URL? { environment["BAGUETTE_RUN_DIR"].map { URL(fileURLWithPath: $0) } }
        var launched: Bool { lock.withLock { !env.isEmpty } }
        var terminated: Bool { lock.withLock { stopped } }
        var killed: Bool { lock.withLock { forced } }

        func finish(status: Int32 = 0) {
            let exits = lock.withLock { let value = callbacks; callbacks = []; return value }
            for exit in exits { exit(status) }
        }
    }

    struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-runs-test-\(UUID())")
        let plugins = MockPlugins()
        let grants = PluginGrants()
        let child: Child
        let runs: PluginRuns

        init(
            answer: String? = #"{"ok":true}"#, immediate: Bool = true,
            spawnFailure: Bool = false, background: Bool = true,
            capabilities: [PluginCapability] = [], capacity: Int = 1000,
            timeout: Duration? = nil, workspaceLimitBytes: Int64 = 24 * 1024 * 1024 * 1024
        ) throws {
            child = Child(answer: answer, exitImmediately: immediate, spawnFailure: spawnFailure)
            var declaration: [String: Any] = ["id": "fetch", "title": "Fetch", "run": ["node", "fetch.js"]]
            if background { declaration["background"] = ["timeoutSeconds": 3600, "environment": ["SECRET"]] }
            let command = try PluginCommand.parsing(dict: declaration)
            given(plugins).all().willReturn([Plugin(
                root: root.appendingPathComponent("plugin"),
                manifest: PluginManifest(name: "build", version: "1", apiVersion: 1,
                    capabilities: capabilities, commands: [command])
            )])
            let child = child
            runs = PluginRuns(root: root, capacity: capacity,
                hostEnvironment: ["PATH": "/usr/bin:/bin", "SECRET": "secret-value", "UNSELECTED": "private"],
                timeout: timeout, grace: .milliseconds(5), pollInterval: .milliseconds(5),
                workspaceLimitBytes: workspaceLimitBytes, subprocess: { child.subprocess })
        }

        func start(udid: String? = "sim-1", apps: (any Apps)? = nil, command: String = "build:fetch",
                   args: [String: Any] = ["ref": "main"]) async throws -> PluginRun {
            try await runs.start(qualifiedCommand: command,
                context: .init(serverURL: "http://localhost:8421", udid: udid, token: "session-secret", args: args),
                plugins: plugins, grants: grants, apps: apps)
        }

        func clean() async throws {
            await runs.shutdown()
            if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        }
    }

    static func eventually(_ predicate: () async throws -> Bool) async throws {
        for _ in 0..<1000 {
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("background run did not reach the expected state")
    }

    static func finished(_ fixture: Fixture, _ run: PluginRun) async throws -> PluginRun {
        try await eventually { await fixture.runs.get(run.id)?.isFinished == true }
        return try #require(await fixture.runs.get(run.id))
    }

    @Test func `should retain a background run outcome after its workspace is cleaned`() async throws {
        let f = try Fixture()
        let run = try await f.start()
        let result = try await Self.finished(f, run)
        #expect(result.state == .succeeded)
        #expect(!FileManager.default.fileExists(atPath: try #require(f.child.workspace).path))
        let restored = PluginRuns(root: f.root)
        let retained = try #require(await restored.get(run.id))
        #expect(retained.id == result.id)
        #expect(retained.command == result.command)
        #expect(retained.udid == result.udid)
        #expect(retained.state == result.state)
        #expect(f.grants.capabilities(for: try #require(f.child.environment["BAGUETTE_TOKEN"])) == nil)
        try await f.clean()
    }

    @Test func `should keep invocation secrets out of retained status and inherit only selected environment`() async throws {
        let f = try Fixture(answer: #"{"ok":false,"message":"secret-value session-secret"}"#)
        let run = try await f.start()
        let result = try await Self.finished(f, run)
        #expect(result.state == .failed)
        #expect(result.message == "[redacted] [redacted]")
        #expect(f.child.environment["SECRET"] == "secret-value")
        #expect(f.child.environment["UNSELECTED"] == nil)
        #expect(f.child.environment["BAGUETTE_TOKEN"] != "session-secret")
        #expect(f.child.directory == f.root.appendingPathComponent("plugin"))
        let payload = try #require(JSONSerialization.jsonObject(with: f.child.stdin) as? [String: Any])
        #expect(payload["version"] as? Int == 1)
        #expect(payload["workspace"] as? String == f.child.workspace?.path)
        #expect((payload["args"] as? [String: String])?["ref"] == "main")
        let persisted = try Data(contentsOf: f.root.appendingPathComponent("\(run.id).json"))
        #expect(!String(decoding: persisted, as: UTF8.self).contains("secret-value"))
        try await f.clean()
    }

    @Test func `should refuse a run when its command is not background enabled`() async throws {
        let f = try Fixture(background: false)
        await #expect(throws: PluginRuns.Failure.notBackground) { try await f.start() }
        #expect(!f.child.launched)
        try await f.clean()
    }

    @Test func `should refuse a run when its command is unknown`() async throws {
        let f = try Fixture()
        await #expect(throws: PluginRuns.Failure.unknownCommand) { try await f.start(command: "build:missing") }
        try await f.clean()
    }

    @Test func `should refuse an app capable run when no target apps are available`() async throws {
        let f = try Fixture(capabilities: [.apps])
        await #expect(throws: PluginRuns.Failure.appsUnavailable) { try await f.start() }
        try await f.clean()
    }

    @Test func `should reserve the simulator until cancellation has cleaned the workspace`() async throws {
        let f = try Fixture(immediate: false)
        let run = try await f.start()
        await #expect(throws: PluginRuns.Failure.simulatorBusy) { try await f.start() }
        try await Self.eventually { f.child.launched }
        _ = try await f.runs.cancel(run.id)
        let result = try await Self.finished(f, run)
        #expect(result.state == .cancelled)
        #expect(f.child.terminated)
        #expect(f.child.killed)
        #expect(!FileManager.default.fileExists(atPath: try #require(f.child.workspace).path))
        #expect(try await f.runs.cancel("missing") == nil)
        #expect(try await f.runs.cancel(run.id) == result)
        try await f.clean()
    }

    @Test func `should refuse further runs when two background jobs are active`() async throws {
        let f = try Fixture(immediate: false)
        _ = try await f.start(udid: "one")
        _ = try await f.start(udid: "two")
        await #expect(throws: PluginRuns.Failure.concurrencyLimit) { try await f.start(udid: "three") }
        try await f.clean()
    }

    @Test func `should refuse new runs without evicting retained outcomes when capacity is full`() async throws {
        let f = try Fixture(capacity: 1)
        let run = try await f.start()
        _ = try await Self.finished(f, run)
        await #expect(throws: PluginRuns.Failure.capacity) { try await f.start() }
        #expect(await f.runs.get(run.id)?.state == .succeeded)
        try await f.clean()
    }

    @Test func `should fail and clean a run when the result file is missing malformed or too large`(
    ) async throws {
        for answer in [nil, "not json", #"{"ok":1}"#, String(repeating: "x", count: 65537)] as [String?] {
            let f = try Fixture(answer: answer)
            let run = try await f.start()
            #expect(try await Self.finished(f, run).state == .failed)
            #expect(!FileManager.default.fileExists(atPath: try #require(f.child.workspace).path))
            try await f.clean()
        }
    }

    @Test func `should fail and clean a run when the child cannot start`() async throws {
        let f = try Fixture(spawnFailure: true)
        let run = try await f.start()
        let result = try await Self.finished(f, run)
        #expect(result.state == .failed)
        #expect(result.message == "background command failed to start")
        #expect(!FileManager.default.fileExists(atPath: try #require(f.child.workspace).path))
        try await f.clean()
    }

    @Test func `should fail and clean a run when its deadline passes`() async throws {
        let f = try Fixture(immediate: false, timeout: .milliseconds(10))
        let run = try await f.start()
        let result = try await Self.finished(f, run)
        #expect(result.state == .failed)
        #expect(result.message == "background command timed out")
        #expect(f.child.killed)
        #expect(!FileManager.default.fileExists(atPath: try #require(f.child.workspace).path))
        try await f.clean()
    }

    @Test func `should expose bounded progress while the background command is running`() async throws {
        let f = try Fixture(immediate: false)
        let run = try await f.start()
        try await Self.eventually { f.child.launched }
        let workspace = try #require(f.child.workspace)
        try Data(#"{"phase":"downloading secret-value","downloadedBytes":123}"#.utf8)
            .write(to: workspace.appendingPathComponent("progress.json"), options: .atomic)
        let progress = try #require(await f.runs.get(run.id))
        #expect(progress.phase == "downloading [redacted]")
        #expect(progress.downloadedBytes == 123)
        try await f.clean()
        #expect(await f.runs.get(run.id)?.state == .cancelled)
    }

    @Test func `should stop and clean a run when its workspace exceeds the disk allowance`() async throws {
        let f = try Fixture(immediate: false, workspaceLimitBytes: 1)
        let run = try await f.start()
        let result = try await Self.finished(f, run)
        #expect(result.state == .failed)
        #expect(result.message == "background workspace exceeds its disk allowance")
        try await f.clean()
    }

    @Test func `should reject app output when the plugin has no apps capability`() async throws {
        let f = try Fixture(answer: #"{"ok":true,"output":{"kind":"simulator-app","path":"App.app"}}"#)
        let run = try await f.start()
        #expect(try await Self.finished(f, run).state == .failed)
        try await f.clean()
    }

    @Test func `should reject app output when the path escapes or is not an app directory`() async throws {
        for path in ["/tmp/App.app", "../App.app", "folder/../App.app", "file.ipa", "Missing.app"] {
            let f = try Fixture(answer: "{\"ok\":true,\"output\":{\"kind\":\"simulator-app\",\"path\":\"\(path)\"}}", capabilities: [.apps])
            let apps = MockApps()
            let run = try await f.start(apps: apps)
            #expect(try await Self.finished(f, run).state == .failed)
            try await f.clean()
        }
    }

    @Test func `should install a contained app after revoking the process grant`() async throws {
        let f = try Fixture(answer: #"{"ok":true,"output":{"kind":"simulator-app","path":"App.app"}}"#,
            immediate: false, capabilities: [.apps])
        let apps = MockApps()
        given(apps).install(.any).willProduce { app in
            #expect(app.path.lastPathComponent == "App.app")
            #expect(FileManager.default.fileExists(atPath: app.path.path))
            #expect(f.grants.capabilities(for: f.child.environment["BAGUETTE_TOKEN"] ?? "missing") == nil)
        }
        let run = try await f.start(apps: apps)
        try await Self.eventually { f.child.launched }
        try FileManager.default.createDirectory(at: try #require(f.child.workspace).appendingPathComponent("App.app"),
            withIntermediateDirectories: true)
        f.child.finish()
        #expect(try await Self.finished(f, run).state == .succeeded)
        try await f.clean()
    }

    actor Installation: Apps {
        let apps = MockApps()
        private var waiter: CheckedContinuation<Void, Never>?
        private(set) var started = false

        init() { given(apps).install(.any).willReturn(()) }

        func install(_ app: AppBundle) async throws {
            started = true
            await withCheckedContinuation { waiter = $0 }
            try await apps.install(app)
        }

        func finish() { waiter?.resume(); waiter = nil }
        func install(archive: AppArchive) async throws { try await apps.install(archive: archive) }
        func open(_ link: DeepLink) async throws { try await apps.open(link) }
        func deliver(_ notification: RemoteNotification) async throws { try await apps.deliver(notification) }
        func terminate(bundleID: String) async throws { try await apps.terminate(bundleID: bundleID) }
        func launch(bundleID: String) async throws { try await apps.launch(bundleID: bundleID) }
        func installed() async throws -> [InstalledApp] { try await apps.installed() }
    }

    @Test func `should refuse cancellation during app installation and wait for installation at shutdown`() async throws {
        let f = try Fixture(answer: #"{"ok":true,"output":{"kind":"simulator-app","path":"App.app"}}"#,
            immediate: false, capabilities: [.apps])
        let installation = Installation()
        let run = try await f.start(apps: installation)
        try await Self.eventually { f.child.launched }
        let workspace = try #require(f.child.workspace)
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("App.app"), withIntermediateDirectories: true)
        f.child.finish()
        try await Self.eventually { await installation.started }
        await #expect(throws: PluginRuns.Failure.installing) { try await f.runs.cancel(run.id) }
        #expect(await f.runs.get(run.id)?.phase == "installing")
        #expect(await f.runs.get(run.id)?.isFinished == false)
        #expect(FileManager.default.fileExists(atPath: workspace.path))
        let shutdown = Task { await f.runs.shutdown() }
        await installation.finish()
        await shutdown.value
        #expect(await f.runs.get(run.id)?.state == .succeeded)
        #expect(!FileManager.default.fileExists(atPath: workspace.path))
        try await f.clean()
    }

    @Test func `should fail and clean a run when app installation fails`() async throws {
        let f = try Fixture(answer: #"{"ok":true,"output":{"kind":"simulator-app","path":"App.app"}}"#,
            immediate: false, capabilities: [.apps])
        let apps = MockApps()
        given(apps).install(.any).willThrow(AppsError.installFailed(status: 1))
        let run = try await f.start(apps: apps)
        try await Self.eventually { f.child.launched }
        let workspace = try #require(f.child.workspace)
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("App.app"), withIntermediateDirectories: true)
        f.child.finish()
        let outcome = try await Self.finished(f, run)
        #expect(outcome.state == .failed)
        #expect(outcome.message == "xcrun simctl install exited 1")
        #expect(!FileManager.default.fileExists(atPath: workspace.path))
        try await f.clean()
    }

    @Test func `should reject app output when a bundle or nested symlink escapes the workspace`() async throws {
        for nested in [false, true] {
            let f = try Fixture(answer: #"{"ok":true,"output":{"kind":"simulator-app","path":"App.app"}}"#,
                immediate: false, capabilities: [.apps])
            let apps = MockApps()
            let run = try await f.start(apps: apps)
            try await Self.eventually { f.child.launched }
            let workspace = try #require(f.child.workspace)
            let outside = f.root.appendingPathComponent("outside.app")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            let app = workspace.appendingPathComponent("App.app")
            if nested {
                try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(at: app.appendingPathComponent("escape"), withDestinationURL: outside)
            } else {
                try FileManager.default.createSymbolicLink(at: app, withDestinationURL: outside)
            }
            f.child.finish()
            #expect(try await Self.finished(f, run).state == .failed)
            #expect(FileManager.default.fileExists(atPath: outside.path))
            try await f.clean()
        }
    }

    @Test func `should reject a result file when it is a symlink outside the workspace`() async throws {
        let f = try Fixture(answer: nil, immediate: false)
        let run = try await f.start()
        try await Self.eventually { f.child.launched }
        let outside = f.root.appendingPathComponent("outside")
        try Data(#"{"ok":true}"#.utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: try #require(f.child.workspace).appendingPathComponent("result.json"),
            withDestinationURL: outside)
        f.child.finish()
        #expect(try await Self.finished(f, run).state == .failed)
        #expect(FileManager.default.fileExists(atPath: outside.path))
        try await f.clean()
    }

    @Test func `should fail a run without exposing stdout when the child exits unsuccessfully`() async throws {
        let f = try Fixture(immediate: false)
        let run = try await f.start()
        try await Self.eventually { f.child.launched }
        f.child.finish(status: 42)
        let result = try await Self.finished(f, run)
        #expect(result.state == .failed)
        #expect(result.message == "background command exited 42")
        try await f.clean()
    }

    @Test func `should retain a cancelled outcome when cancellation arrives before startup`() async throws {
        let f = try Fixture(immediate: false)
        let run = try await f.start()
        _ = try await f.runs.cancel(run.id)
        #expect(try await Self.finished(f, run).state == .cancelled)
        try await f.clean()
    }

    @Test func `should refuse new runs after shutdown`() async throws {
        let f = try Fixture()
        await f.runs.shutdown()
        await #expect(throws: PluginRuns.Failure.shuttingDown) { try await f.start() }
        try await f.clean()
    }

    @Test func `should report cleanup failure rather than a successful or cancelled outcome`() async throws {
        let f = try Fixture(immediate: false)
        let run = try await f.start()
        try await Self.eventually { f.child.launched }
        try FileManager.default.removeItem(at: try #require(f.child.workspace))
        f.child.finish(status: 1)
        let result = try await Self.finished(f, run)
        #expect(result.state == .failed)
        #expect(result.message == "background workspace cleanup failed")
        try await f.clean()
    }

    @Test func `should retain an interrupted outcome and clean stale workspaces when a custom registry restarts`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-runs-restart-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var run = PluginRun(id: UUID().uuidString, command: "build:fetch", udid: "sim")
        run.start()
        try JSONEncoder().encode(run).write(to: root.appendingPathComponent("\(run.id).json"))
        let workspace = root.appendingPathComponent(run.id)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        let runs = PluginRuns(root: root)
        #expect(await runs.get(run.id)?.state == .failed)
        #expect(await runs.get(run.id)?.message == "background run interrupted by server restart")
        #expect(!FileManager.default.fileExists(atPath: workspace.path))
    }

    @Test func `should ignore malformed and oversized progress without failing the background run`() async throws {
        let f = try Fixture(immediate: false)
        let run = try await f.start()
        try await Self.eventually { f.child.launched }
        let progress = try #require(f.child.workspace).appendingPathComponent("progress.json")
        for value in ["not json", String(repeating: "x", count: 65537), #"{"downloadedBytes":-1}"#] {
            try Data(value.utf8).write(to: progress, options: .atomic)
            #expect(await f.runs.get(run.id)?.state == .running)
            #expect(await f.runs.get(run.id)?.downloadedBytes == nil)
        }
        f.child.finish()
        #expect(try await Self.finished(f, run).state == .succeeded)
        try await f.clean()
    }

    @Test func `should bound retained failure messages so the status remains readable after restart`() async throws {
        let answer = "{\"ok\":false,\"message\":\"\(String(repeating: "x", count: 60000))\"}"
        let f = try Fixture(answer: answer)
        let run = try await f.start()
        let result = try await Self.finished(f, run)
        #expect(result.message?.count == 4096)
        let retained = PluginRuns(root: f.root)
        #expect(await retained.get(run.id)?.state == .failed)
        try await f.clean()
    }

    @Test func `should redact original text once when short secrets are repeated`() async throws {
        // The first case fails safely on the old implementation rather than
        // allowing its repeated replacements to exhaust memory in the second.
        for count in [2, 100] {
            let f = try Fixture(answer: #"{"ok":false,"message":"download failed"}"#)
            let args = Dictionary(uniqueKeysWithValues: (0..<count).map { ("secret\($0)", "d") })
            let started = ContinuousClock.now
            let run = try await f.start(args: args)
            let result = try await Self.finished(f, run)
            try await f.clean()
            #expect(ContinuousClock.now - started < .seconds(2))
            try #require(result.message == "[redacted]ownloa[redacted] faile[redacted]")
        }
    }

    @Test func `should redact the longest literal secret without redacting replacement markers`() async throws {
        let message = "download d [x].*"
        let answer = String(decoding: try JSONSerialization.data(withJSONObject: ["ok": false, "message": message]), as: UTF8.self)
        let f = try Fixture(answer: answer)
        let run = try await f.start(args: ["one": "d", "two": "download", "three": "[x].*"])
        #expect(try await Self.finished(f, run).message == "[redacted] [redacted] [redacted]")
        try await f.clean()
    }

    @Test func `should retain at most 4096 bytes of Unicode failure text after redaction`() async throws {
        let message = String(repeating: "\u{1F680}", count: 2000) + "secret-value"
        let answer = String(decoding: try JSONSerialization.data(withJSONObject: ["ok": false, "message": message]), as: UTF8.self)
        let f = try Fixture(answer: answer)
        let run = try await f.start()
        let retained = try #require(try await Self.finished(f, run).message)
        #expect(retained.utf8.count <= 4096)
        #expect(!retained.contains("secret-value"))
        #expect(!retained.contains("\u{FFFD}"))
        try await f.clean()
    }

    @Test func `should fail an app capable run when successful output is missing`() async throws {
        let f = try Fixture(capabilities: [.apps])
        let apps = MockApps()
        let run = try await f.start(apps: apps)
        #expect(try await Self.finished(f, run).state == .failed)
        verify(apps).install(.any).called(0)
        try await f.clean()
    }

    @Test func `should preserve a redacted failure result when the command exits unsuccessfully`() async throws {
        let f = try Fixture(answer: #"{"ok":false,"message":"download failed secret-value"}"#, immediate: false)
        let run = try await f.start()
        try await Self.eventually { f.child.launched }
        f.child.finish(status: 1)
        let result = try await Self.finished(f, run)
        #expect(result.state == .failed)
        #expect(result.message == "download failed [redacted]")
        try await f.clean()
    }

    @Test func `should show the exit status when an unsuccessful command has no valid failure result`() async throws {
        for answer in [nil, "bad JSON", #"{"ok":1,"message":"not a boolean"}"#, #"{"ok":true}"#] as [String?] {
            let f = try Fixture(answer: answer, immediate: false)
            let run = try await f.start()
            try await Self.eventually { f.child.launched }
            f.child.finish(status: 7)
            #expect(try await Self.finished(f, run).message == "background command exited 7")
            try await f.clean()
        }
    }

    @Test func `should never install app output when the command exits unsuccessfully`() async throws {
        let f = try Fixture(answer: #"{"ok":true,"output":{"kind":"simulator-app","path":"App.app"}}"#,
            immediate: false, capabilities: [.apps])
        let apps = MockApps()
        let run = try await f.start(apps: apps)
        try await Self.eventually { f.child.launched }
        try FileManager.default.createDirectory(at: try #require(f.child.workspace).appendingPathComponent("App.app"),
            withIntermediateDirectories: true)
        f.child.finish(status: 1)
        #expect(try await Self.finished(f, run).state == .failed)
        verify(apps).install(.any).called(0)
        try await f.clean()
    }

    @Test func `should redact an entire secret before truncating retained failure text`() async throws {
        let message = String(repeating: "x", count: 4090) + "secret-value"
        let answer = String(decoding: try JSONSerialization.data(withJSONObject: ["ok": false, "message": message]), as: UTF8.self)
        let f = try Fixture(answer: answer)
        let run = try await f.start()
        let retained = try #require(try await Self.finished(f, run).message)
        #expect(retained == String(repeating: "x", count: 4090) + "[redac")
        #expect(retained.utf8.count == 4096)
        try await f.clean()
    }

    @Test func `should redact repeated short secrets in bounded Unicode progress`() async throws {
        let f = try Fixture(immediate: false)
        let args = Dictionary(uniqueKeysWithValues: (0..<100).map { ("secret\($0)", "d") })
        let run = try await f.start(args: args)
        try await Self.eventually { f.child.launched }
        let phase = "download " + String(repeating: "\u{1F680}", count: 2000)
        let data = try JSONSerialization.data(withJSONObject: ["phase": phase])
        try data.write(to: try #require(f.child.workspace).appendingPathComponent("progress.json"), options: .atomic)
        let progress = try #require(await f.runs.get(run.id)?.phase)
        #expect(progress.hasPrefix("[redacted]ownloa[redacted] "))
        #expect(progress.utf8.count <= 4096)
        #expect(!progress.contains("\u{FFFD}"))
        try await f.clean()
    }

    @Test func `should hide failure text when the combined secret pattern exceeds its allowance`() async throws {
        let f = try Fixture(answer: #"{"ok":false,"message":"private failure"}"#)
        let args = Dictionary(uniqueKeysWithValues: (0..<300).map {
            ("secret\($0)", String(repeating: ".", count: 300) + String($0))
        })
        let run = try await f.start(args: args)
        #expect(try await Self.finished(f, run).message == "[redacted]")
        try await f.clean()
    }
}
