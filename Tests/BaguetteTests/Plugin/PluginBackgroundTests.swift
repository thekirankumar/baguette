import Foundation
import Testing
@testable import Baguette

@Suite("PluginBackground")
struct PluginBackgroundTests {
    @Test func `should accept the shortest deadline when the manifest arrives as JSON`() throws {
        let manifest = try PluginManifest.parsing(json: Data(#"{"name":"jobs","version":"1","contributes":{"commands":[{"id":"run","run":["tool"],"background":{"timeoutSeconds":1}}]}}"#.utf8))
        #expect(manifest.commands.first?.background?.timeoutSeconds == 1)
    }

    @Test func `should refuse a boolean deadline when the manifest arrives as JSON`() {
        #expect(throws: (any Error).self) {
            try PluginManifest.parsing(json: Data(#"{"name":"jobs","version":"1","contributes":{"commands":[{"id":"run","run":["tool"],"background":{"timeoutSeconds":true}}]}}"#.utf8))
        }
    }
    @Test func `should permit a long-running command with explicitly inherited credentials`() throws {
        let command = try PluginCommand.parsing(dict: [
            "id": "install", "run": ["python3", "bin/download.py"],
            "background": ["timeoutSeconds": 3600, "environment": ["GITLAB_TOKEN"]]
        ])
        #expect(command.background == PluginBackground(timeoutSeconds: 3600, environment: ["GITLAB_TOKEN"]))
    }

    @Test func `should refuse a long-running command when its deadline is invalid`() {
        #expect(throws: (any Error).self) {
            try PluginCommand.parsing(dict: ["id": "install", "run": ["tool"], "background": ["timeoutSeconds": 0]])
        }
    }

    @Test func `should refuse inherited credentials when their names override the run context`() {
        #expect(throws: (any Error).self) {
            try PluginCommand.parsing(dict: ["id": "install", "run": ["tool"], "background": ["environment": ["BAGUETTE_RUN_DIR"]]])
        }
    }

    @Test func `should keep short commands synchronous when background execution is not declared`() throws {
        let command = try PluginCommand.parsing(dict: ["id": "audit", "run": ["tool"]])
        #expect(command.background == nil)
    }
}
