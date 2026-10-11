import Foundation
import Mockable
import Testing
@testable import Baguette

@Suite("PluginBackgroundDiscovery")
struct PluginBackgroundDiscoveryTests {
    @Test func `should advertise background eligibility and deadline without exposing credentials or executables`() throws {
        let plugins = MockPlugins()
        given(plugins).all().willReturn([Self.plugin(background: .init(timeoutSeconds: 7200, environment: ["GITLAB_TOKEN"]))])
        let json = try plugins.listJSON
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let list = try #require(object["plugins"] as? [[String: Any]])
        let commands = try #require(list[0]["commands"] as? [[String: Any]])
        #expect(commands[0]["background"] as? Bool == true)
        #expect(commands[0]["timeoutSeconds"] as? Int == 7200)
        #expect(Set(commands[0].keys) == ["id", "title", "background", "timeoutSeconds"])
        #expect(!json.contains("GITLAB_TOKEN"))
        #expect(!json.contains("download.py"))
    }

    @Test func `should preserve synchronous discovery bytes when background execution is not declared`() throws {
        let plugins = MockPlugins()
        given(plugins).all().willReturn([Self.plugin(background: nil)])
        #expect(try plugins.listJSON == #"{"plugins":[{"commands":[{"id":"artifacts:download","title":"Download"}],"name":"artifacts","panels":[],"version":"1.0.0"}]}"#)
    }

    @Test func `should disclose background execution and inherited credential names to the host`() {
        let text = PluginsCommand.detail(Self.plugin(background: .init(timeoutSeconds: 7200, environment: ["GITLAB_TOKEN"])))
        #expect(text.contains("background"))
        #expect(text.contains("7200"))
        #expect(text.contains("inherited environment: GITLAB_TOKEN"))
    }

    @Test func `should preserve synchronous detail when background execution is not declared`() {
        #expect(PluginsCommand.detail(Self.plugin(background: nil)) == """
        artifacts 1.0.0
        root: /tmp/artifacts
        capabilities: none

        commands:
          artifacts:download  Download  [python3 download.py]
        """)
    }

    static func plugin(background: PluginBackground?) -> Plugin {
        Plugin(root: URL(fileURLWithPath: "/tmp/artifacts"), manifest: .init(
            name: "artifacts", version: "1.0.0", apiVersion: 1,
            commands: [.init(id: "download", title: "Download", run: ["python3", "download.py"], background: background)]))
    }
}
