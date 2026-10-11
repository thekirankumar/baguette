import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import Logging
import Mockable
import NIOCore
import NIOEmbedded
import Testing
@testable import Baguette

@Suite("PluginRunRoutes")
struct PluginRunRoutesTests {
    @Test func `should accept a background run and retain its outcome after cleanup`() async throws {
        let f = try PluginRunsTests.Fixture(immediate: false)
        let server = try Self.server(f)
        let response = try await Self.respond(server, path: "/team/plugins/build/commands/fetch/runs?udid=sim-1",
            method: .post, body: #"{"args":{"ref":"main","token":"caller","workspace":"caller"}}"#)
        #expect(response.status == .accepted)
        #expect(response.headers[.cacheControl] == "no-store")
        let location = try #require(response.headers[.location])
        #expect(location.hasPrefix("/team/runs/"))
        #expect(location.hasSuffix(".json"))
        let id = String(location.dropFirst("/team/runs/".count).dropLast(5))
        let run = try #require(await f.runs.get(id))
        let accepted = try await Self.runJSON(response)
        #expect(accepted.id == run.id)
        #expect(accepted.command == run.command)
        #expect(accepted.udid == run.udid)
        #expect(!accepted.isFinished)
        #expect(run.command == "build:fetch")
        #expect(run.udid == "sim-1")
        try await PluginRunsTests.eventually { f.child.launched }
        let payload = try #require(JSONSerialization.jsonObject(with: f.child.stdin) as? [String: Any])
        #expect(payload["url"] as? String == "http://127.0.0.1:8421/team")
        #expect(payload["token"] as? String != "caller")
        #expect(payload["workspace"] as? String != "caller")
        #expect((payload["args"] as? [String: String])?["ref"] == "main")
        f.child.finish()
        _ = try await PluginRunsTests.finished(f, run)
        let retained = try await Self.respond(server, path: location)
        #expect(retained.status == .ok)
        #expect(retained.headers[.cacheControl] == "no-store")
        #expect(await f.runs.get(id)?.state == .succeeded)
        #expect(try await Self.runJSON(retained).state == .succeeded)
        #expect(try await Self.respond(server, path: "/team/runs/\(id)").status == .notFound)
        #expect(!FileManager.default.fileExists(atPath: try #require(f.child.workspace).path))
        try await f.clean()
    }

    @Test(arguments: ["", "{}", #"{"args":{}}"#])
    func `should accept a background run when no arguments are supplied`(_ body: String) async throws {
        #expect(try Server.parsePluginRunArgs(body: Data(body.utf8)) == nil)
        let f = try PluginRunsTests.Fixture()
        let response = try await Self.respond(try Self.server(f), path: "/team/plugins/build/commands/fetch/runs",
            method: .post, body: body)
        #expect(response.status == .accepted)
        try await f.clean()
    }

    @Test(arguments: [" ", "not json", "[]", "null", "1", #"{"args":null}"#,
        #"{"args":[]}"#, #"{"args":"x"}"#, #"{"udid":"sim-1"}"#,
        #"{"args":{},"token":"x"}"#, #"{"command":"build:fetch"}"#,
        #"{"workspace":"/tmp"}"#, #"{"url":"http://attacker"}"#])
    func `should refuse a background run when its body is not an arguments envelope`(_ body: String) async throws {
        #expect(throws: (any Error).self) { try Server.parsePluginRunArgs(body: Data(body.utf8)) }
        let f = try PluginRunsTests.Fixture()
        let response = try await Self.respond(try Self.server(f), path: "/team/plugins/build/commands/fetch/runs",
            method: .post, body: body)
        #expect(response.status == .badRequest)
        #expect(!f.child.launched)
        try await f.clean()
    }

    @Test func `should refuse a background run when its body exceeds sixty four kibibytes`() async throws {
        let body = "{\"args\":{\"value\":\"" + String(repeating: "x", count: 65536) + "\"}}"
        #expect(throws: (any Error).self) { try Server.parsePluginRunArgs(body: Data(body.utf8)) }
        let f = try PluginRunsTests.Fixture()
        #expect(try await Self.respond(try Self.server(f), path: "/team/plugins/build/commands/fetch/runs",
            method: .post, body: body).status == .badRequest)
        #expect(!f.child.launched)
        try await f.clean()
    }

    @Test(arguments: [(PluginRuns.Failure.unknownCommand, HTTPResponse.Status.notFound),
        (.notBackground, .badRequest), (.appsUnavailable, .badRequest), (.simulatorBusy, .conflict),
        (.concurrencyLimit, .conflict), (.capacity, .conflict), (.installing, .conflict),
        (.shuttingDown, .conflict), (.storage, .internalServerError)])
    func `should describe a background run refusal with its matching HTTP status`(
        _ failure: PluginRuns.Failure, _ status: HTTPResponse.Status
    ) async throws {
        let response = Server.pluginRunFailure(failure)
        #expect(response.status == status)
        #expect(response.headers[.contentType] == "application/json")
        #expect(response.headers[.cacheControl] == "no-store")
        let body = Body()
        try await response.body.write(body)
        let json = try #require(JSONSerialization.jsonObject(with: await body.data) as? [String: Any])
        #expect(json["ok"] as? Bool == false)
        #expect(json["error"] as? String == failure.description)
    }

    @Test func `should refuse a background run when its command or simulator is unknown`() async throws {
        let f = try PluginRunsTests.Fixture()
        let server = try Self.server(f)
        #expect(try await Self.respond(server, path: "/team/plugins/build/commands/missing/runs",
            method: .post).status == .notFound)
        #expect(try await Self.respond(server, path: "/team/plugins/build/commands/fetch/runs?udid=missing",
            method: .post).status == .notFound)
        #expect(!f.child.launched)
        try await f.clean()
    }

    @Test func `should refuse a background run when its command is synchronous`() async throws {
        let f = try PluginRunsTests.Fixture(background: false)
        #expect(try await Self.respond(try Self.server(f), path: "/team/plugins/build/commands/fetch/runs",
            method: .post).status == .badRequest)
        #expect(!f.child.launched)
        try await f.clean()
    }

    @Test func `should refuse a synchronous invocation when its command is background enabled`() async throws {
        let f = try PluginRunsTests.Fixture()
        #expect(await Server.runPlugin(qualified: "build:fetch", context: PluginRoutesTests.context,
            plugins: f.plugins, subprocess: { f.child.subprocess }) == .background)
        #expect(try await Self.respond(try Self.server(f), path: "/team/plugins/build/commands/fetch",
            method: .post).status == .badRequest)
        #expect(!f.child.launched)
        try await f.clean()
    }

    @Test func `should refuse an app capable background run when no simulator is supplied`() async throws {
        let f = try PluginRunsTests.Fixture(capabilities: [.apps])
        #expect(try await Self.respond(try Self.server(f), path: "/team/plugins/build/commands/fetch/runs",
            method: .post).status == .badRequest)
        #expect(!f.child.launched)
        try await f.clean()
    }

    @Test func `should reserve a simulator until cancellation has cleaned the background run`() async throws {
        let f = try PluginRunsTests.Fixture(immediate: false)
        let server = try Self.server(f)
        let path = "/team/plugins/build/commands/fetch/runs?udid=sim-1"
        let started = try await Self.respond(server, path: path, method: .post)
        let location = try #require(started.headers[.location])
        let id = String(location.dropFirst("/team/runs/".count).dropLast(5))
        try await PluginRunsTests.eventually { f.child.launched }
        #expect(try await Self.respond(server, path: path, method: .post).status == .conflict)
        let cancelled = try await Self.respond(server, path: "/team/runs/\(id)/cancel", method: .post)
        #expect(cancelled.status == .accepted)
        #expect(cancelled.headers[.cacheControl] == "no-store")
        #expect(try await Self.runJSON(cancelled).isFinished == false)
        let run = try #require(await f.runs.get(id))
        f.child.finish(status: 15)
        #expect(try await PluginRunsTests.finished(f, run).state == .cancelled)
        #expect(try await Self.respond(server, path: location).status == .ok)
        #expect(try await Self.respond(server, path: "/team/runs/\(id)/cancel", method: .post).status == .ok)
        try await f.clean()
    }

    @Test(arguments: [false, true])
    func `should retain a failed run after cleanup when startup or the result fails`(_ spawnFailure: Bool) async throws {
        let f = try PluginRunsTests.Fixture(answer: "malformed", spawnFailure: spawnFailure)
        let server = try Self.server(f)
        let response = try await Self.respond(server, path: "/team/plugins/build/commands/fetch/runs", method: .post)
        #expect(response.status == .accepted)
        let location = try #require(response.headers[.location])
        let id = String(location.dropFirst("/team/runs/".count).dropLast(5))
        let run = try #require(await f.runs.get(id))
        #expect(try await PluginRunsTests.finished(f, run).state == .failed)
        #expect(try await Self.respond(server, path: location).status == .ok)
        #expect(!FileManager.default.fileExists(atPath: try #require(f.child.workspace).path))
        #expect(f.grants.capabilities(for: try #require(f.child.environment["BAGUETTE_TOKEN"])) == nil)
        try await f.clean()
    }

    @Test func `should refuse a background run when retained capacity is exhausted`() async throws {
        let f = try PluginRunsTests.Fixture(capacity: 0)
        #expect(try await Self.respond(try Self.server(f), path: "/team/plugins/build/commands/fetch/runs",
            method: .post).status == .conflict)
        try await f.clean()
    }

    @Test func `should refuse cancellation when a background run is installing an app`() async throws {
        let f = try PluginRunsTests.Fixture(
            answer: #"{"ok":true,"output":{"kind":"simulator-app","path":"App.app"}}"#,
            immediate: false, capabilities: [.apps])
        let installation = PluginRunsTests.Installation()
        let server = try Self.server(f, apps: installation)
        let response = try await Self.respond(server,
            path: "/team/plugins/build/commands/fetch/runs?udid=sim-1", method: .post)
        #expect(response.status == .accepted)
        let run = try await Self.runJSON(response)
        try await PluginRunsTests.eventually { f.child.launched }
        let workspace = try #require(f.child.workspace)
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("App.app"),
            withIntermediateDirectories: true)
        f.child.finish()
        try await PluginRunsTests.eventually { await installation.started }
        let cancelled = try await Self.respond(server, path: "/team/runs/\(run.id)/cancel", method: .post)
        #expect(cancelled.status == .conflict)
        #expect(await f.runs.get(run.id)?.isFinished == false)
        #expect(FileManager.default.fileExists(atPath: workspace.path))
        await installation.finish()
        #expect(try await PluginRunsTests.finished(f, run).state == .succeeded)
        try await f.clean()
    }

    @Test func `should refuse a background run when its retained storage is unavailable`() async throws {
        let f = try PluginRunsTests.Fixture()
        let blocked = f.root.appendingPathComponent("blocked")
        try Data().write(to: blocked)
        let runs = PluginRuns(root: blocked)
        let simulators = MockSimulators()
        let server = Server(simulators: simulators, chromes: MockChromes(), plugins: f.plugins,
            rootPath: try RootPath("/team"), grants: f.grants, pluginRuns: runs)
        #expect(try await Self.respond(server, path: "/team/plugins/build/commands/fetch/runs",
            method: .post).status == .internalServerError)
        #expect(!f.child.launched)
        await runs.shutdown()
        try await f.clean()
    }

    @Test(arguments: [("/team/plugins/build/commands/fetch/runs", HTTPRequest.Method.post),
        ("/team/runs/missing.json", .get), ("/team/runs/missing/cancel", .post)])
    func `should protect background runs when the caller is an untrusted browser or a plugin grant`(
        _ path: String, _ method: HTTPRequest.Method
    ) async throws {
        let f = try PluginRunsTests.Fixture()
        let server = try Self.server(f)
        #expect(try await Self.respond(server, path: path, method: method,
            headers: [.origin: "https://attacker.test"]).status == .forbidden)
        let token = f.grants.issue(plugin: "build", capabilities: [.apps, .input, .describeUI])
        #expect(try await Self.respond(server, path: path, method: method,
            headers: [HTTPField.Name("X-Baguette-Token")!: token]).status == .forbidden)
        #expect(!f.child.launched)
        try await f.clean()
    }

    @Test(arguments: [("/team/runs/missing.json", HTTPRequest.Method.get),
        ("/team/runs/missing/cancel", .post), ("/runs/missing.json", .get)])
    func `should report no background run when its identity or mount is unknown`(
        _ path: String, _ method: HTTPRequest.Method
    ) async throws {
        let f = try PluginRunsTests.Fixture()
        #expect(try await Self.respond(try Self.server(f), path: path, method: method).status == .notFound)
        try await f.clean()
    }

    private static func server(_ f: PluginRunsTests.Fixture, apps: (any Apps)? = nil) throws -> Server {
        let simulator = MockSimulator()
        given(simulator).apps().willReturn(apps ?? MockApps())
        let simulators = MockSimulators()
        given(simulators).find(udid: .any).willProduce { $0 == "sim-1" ? simulator : nil }
        return Server(simulators: simulators, chromes: MockChromes(), plugins: f.plugins,
            rootPath: try RootPath("/team"), grants: f.grants, pluginRuns: f.runs)
    }

    private static func respond(_ server: Server, path: String, method: HTTPRequest.Method = .get,
        body: String = "", headers: HTTPFields = [:]) async throws -> Response {
        let request = Request(head: HTTPRequest(method: method, scheme: nil, authority: "127.0.0.1:8421",
            path: path, headerFields: headers), body: .init(buffer: ByteBuffer(string: body)))
        let context = BasicWebSocketRequestContext(source: .init(
            channel: EmbeddedChannel(), logger: Logger(label: "PluginRunRoutesTests")))
        return try await server.makeRouter().buildResponder().respond(to: request, context: context)
    }

    private actor Body: ResponseBodyWriter {
        var data = Data()
        func write(_ buffer: ByteBuffer) { data.append(Data(buffer: buffer)) }
        func finish(_ trailingHeaders: HTTPFields?) {}
    }

    private static func runJSON(_ response: Response) async throws -> PluginRun {
        let body = Body()
        try await response.body.write(body)
        return try JSONDecoder().decode(PluginRun.self, from: await body.data)
    }
}
