import ArgumentParser
import Foundation
import Testing
@testable import Baguette

@Suite("PluginRunCommand")
struct PluginRunCommandTests {
    @Test func `should manage background runs through the baguette root command`() throws {
        let start = try #require(Baguette.parseAsRoot(["plugin", "start", "artifacts:download", "--udid", "U", "--url", "https://host/mount", "--args", #"{"job":42}"#]) as? PluginsCommand.Start)
        #expect(start.command == "artifacts:download")
        #expect(start.udid == "U")
        #expect(start.url == "https://host/mount")
        #expect(start.args == #"{"job":42}"#)
        for verb in ["status", "cancel", "wait"] {
            let parsed = try Baguette.parseAsRoot(["plugin", verb, "run-id", "--url", "https://host/mount"])
            #expect(type(of: parsed).configuration.commandName == verb)
        }
        let defaults = try #require(Baguette.parseAsRoot(["plugin", "start", "artifacts:download"]) as? PluginsCommand.Start)
        #expect(defaults.args == "{}")
        #expect(defaults.udid == nil)
    }

    @Test(arguments: ["[]", "null", "true", "42", #""text""#, "{broken"])
    func `should reject a background start when arguments are not a JSON object`(args: String) {
        #expect(throws: (any Error).self) {
            try Baguette.parseAsRoot(["plugin", "start", "artifacts:download", "--args", args])
        }
    }

    @Test(arguments: ["--token", "--run", "--shell"])
    func `should reject execution overrides when starting a background run`(flag: String) {
        #expect(throws: (any Error).self) {
            try Baguette.parseAsRoot(["plugin", "start", "artifacts:download", flag, "secret"])
        }
    }

    @Test(arguments: ["https://host/mount/nested", "https://host/mount/nested/"])
    func `should preserve the server mount when starting a background run`(base: String) throws {
        let request = try PluginRunCommand.request(base: base, action: .start("artifacts:download", udid: "U&other=1", args: #"{"job":42}"#))
        #expect(request.url?.path == "/mount/nested/plugins/artifacts/commands/download/runs")
        #expect(URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems == [.init(name: "udid", value: "U&other=1")])
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(String(decoding: try #require(request.httpBody), as: UTF8.self) == #"{"args":{"job":42}}"#)
    }

    @Test func `should escape run identities as single path segments`() throws {
        let id = "a/b?c#d% e:+@"
        let status = try PluginRunCommand.request(base: "http://host/m%20ount/", action: .status(id))
        #expect(status.url?.absoluteString == "http://host/m%20ount/runs/a%2Fb%3Fc%23d%25%20e%3A%2B%40.json")
        #expect(status.httpMethod == "GET")
        #expect(status.httpBody == nil)
        let cancel = try PluginRunCommand.request(base: "http://host", action: .cancel(id))
        #expect(cancel.url?.absoluteString == "http://host/runs/a%2Fb%3Fc%23d%25%20e%3A%2B%40/cancel")
        #expect(cancel.httpMethod == "POST")
    }

    @Test(arguments: ["file:///tmp", "ftp://host", "http://", "http://user:pass@host", "https://host?token=x", "https://host#fragment", "https://host/a/../b", "https://host/a/%2f/b"])
    func `should reject an unsafe server address`(base: String) {
        #expect(throws: (any Error).self) { try PluginRunCommand.request(base: base, action: .status("id")) }
    }

    @Test(arguments: ["plain", ":command", "plugin:", "a:b:c", "../a:b", "a:..", "a:b/c", "a:b?c", "a:%2f", "a:b\\c"])
    func `should reject a background command when its qualified identity could change the route`(command: String) {
        #expect(throws: (any Error).self) {
            try PluginRunCommand.request(base: "http://host", action: .start(command, udid: nil, args: "{}"))
        }
    }

    @Test(arguments: ["", ".", ".."])
    func `should reject a run identity when it is empty or a dot segment`(id: String) {
        #expect(throws: (any Error).self) { try PluginRunCommand.request(base: "http://host", action: .cancel(id)) }
    }

    @Test func `should submit opaque arguments without granting execution overrides`() throws {
        let request = try PluginRunCommand.request(base: "http://host", action: .start("my-plugin:download_job", udid: nil, args: #"{"shell":"text only","token":"opaque"}"#))
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(body.keys) == ["args"])
        #expect((body["args"] as? [String: String])?["shell"] == "text only")
        #expect(throws: (any Error).self) {
            try PluginRunCommand.request(base: "http://host", action: .start("a:b", udid: nil, args: "{\"large\":\"" + String(repeating: "x", count: 65536) + "\"}"))
        }
    }

    @Test func `should print only terminal JSON when waiting for a successful background run`() async throws {
        var states = [PluginRun.State.queued, .running, .succeeded]
        var delays: [Duration] = []
        var output: [String] = []
        try await PluginRunCommand.perform(base: "http://host", action: .status("id"), wait: true, send: { request in
            Self.response(request, state: states.removeFirst())
        }, sleep: { delays.append($0) }, output: { output.append($0) })
        #expect(states.isEmpty)
        #expect(delays == [.seconds(1), .seconds(1)])
        #expect(output.count == 1)
        #expect(output[0].contains("succeeded"))
    }

    @Test(arguments: [PluginRun.State.failed, .cancelled])
    func `should print terminal JSON and exit unsuccessfully when a background run does not succeed`(state: PluginRun.State) async throws {
        var output: [String] = []
        await #expect(throws: ExitCode.failure) {
            try await PluginRunCommand.perform(base: "http://host", action: .status("id"), wait: true,
                send: { Self.response($0, state: state) }, sleep: { _ in }, output: { output.append($0) })
        }
        #expect(output.count == 1)
        #expect(output[0].contains(state.rawValue))
    }

    @Test func `should print the current JSON without polling when inspecting a background run`() async throws {
        var output: [String] = []
        try await PluginRunCommand.perform(base: "http://host", action: .status("id"),
            send: { Self.response($0, state: .running) }, sleep: { _ in Issue.record("unexpected poll") }, output: { output.append($0) })
        #expect(output.count == 1)
        #expect(output[0].contains("running"))
    }

    @Test func `should stop waiting when the server disappears rather than retrying`() async throws {
        var requests = 0
        var delays = 0
        await #expect(throws: (any Error).self) {
            try await PluginRunCommand.perform(base: "http://host", action: .status("id"), wait: true, send: { request in
                requests += 1
                if requests == 1 { return Self.response(request, state: .running) }
                throw URLError(.cannotConnectToHost)
            }, sleep: { _ in delays += 1 }, output: { _ in Issue.record("unexpected output") })
        }
        #expect(requests == 2)
        #expect(delays == 1)
    }

    @Test(arguments: ["http", "oversized", "malformed", "nonhttp"])
    func `should reject an unsafe server response without printing its contents`(kind: String) async throws {
        var requests = 0
        var output: [String] = []
        await #expect(throws: (any Error).self) {
            try await PluginRunCommand.perform(base: "http://host", action: .status("id"), wait: true, send: { request in
                requests += 1
                let url = request.url!
                let response: URLResponse = kind == "nonhttp" ? URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil) : HTTPURLResponse(url: url, statusCode: kind == "http" ? 404 : 200, httpVersion: nil, headerFields: nil)!
                return (Data((kind == "oversized" ? String(repeating: "x", count: 65537) : "secret\u{1b}[31m").utf8), response)
            }, sleep: { _ in Issue.record("unexpected retry") }, output: { output.append($0) })
        }
        #expect(requests == 1)
        #expect(output.isEmpty)
    }

    static func response(_ request: URLRequest, state: PluginRun.State) -> (Data, URLResponse) {
        var run = PluginRun(id: "id", command: "a:b", udid: nil)
        if state == .running { run.start() }
        else if state != .queued { run.finish(state: state, message: nil) }
        return (try! JSONEncoder().encode(run), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
