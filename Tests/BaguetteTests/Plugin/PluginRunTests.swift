import Foundation
import Testing
@testable import Baguette

@Suite("PluginRun")
struct PluginRunTests {
    @Test func `should retain an asynchronous failure for the caller when a background command fails`() throws {
        var run = PluginRun(id: "run-1", command: "gitlab:install", udid: "U")
        run.finish(state: .failed, message: "Artifact download failed")
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(run)) as? [String: Any]
        #expect(json?["state"] as? String == "failed")
        #expect(json?["message"] as? String == "Artifact download failed")
        #expect(run.isFinished)
    }

    @Test func `should retain an asynchronous success for the caller when a background command completes`() {
        var run = PluginRun(id: "run-1", command: "gitlab:install", udid: "U")
        run.finish(state: .succeeded, message: nil)
        #expect(run.state == .succeeded)
        #expect(run.isFinished)
    }

    @Test func `should preserve the first outcome when late completion arrives`() {
        var run = PluginRun(id: "run-1", command: "gitlab:install", udid: "U")
        run.finish(state: .cancelled, message: "Cancelled")
        run.finish(state: .succeeded, message: nil)
        #expect(run.state == .cancelled)
    }
}
