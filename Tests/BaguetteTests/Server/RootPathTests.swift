import Testing
@testable import Baguette

@Suite("RootPath")
struct RootPathTests {
    @Test func `should serve the web app beneath a requested root path`() throws {
        let command = try ServeCommand.parse(["--rootpath", "/subpath"])
        #expect(command.rootpath == "/subpath")
        let root = try RootPath("/subpath/")
        #expect(root.path == "/subpath")
        #expect(root.route("/simulators") == "/subpath/simulators")
        #expect(root.route("/simulators/:udid/stream") == "/subpath/simulators/:udid/stream")
        #expect(root.route("/") == "/subpath/")
        #expect(root.relative("/subpath/devices/ID/companion/video") == "/devices/ID/companion/video")
        #expect(root.relative("/subpath") == "/")
        #expect(root.relative("/subpath-other/devices.json") == nil)
        #expect(root.relative("/devices.json") == nil)
    }

    @Test func `should serve the web app beneath a requested root path when using a nested mount`() throws {
        let root = try RootPath("/team/simulators")
        #expect(root.route("/devices.json") == "/team/simulators/devices.json")
    }

    @Test func `should keep the web app at the origin root when no root path is requested`() throws {
        let command = try ServeCommand.parse([])
        #expect(command.rootpath == "/")
        let root = try RootPath("/")
        #expect(root.path == "")
        #expect(root.route("/simulators") == "/simulators")
        #expect(root.route("/") == "/")
        #expect(root.relative("/devices.json") == "/devices.json")
    }

    @Test(arguments: ["subpath", "//subpath", "/a//b", "/a/../b", "/a/./b", "/a?b", "/a#b", "/a%2fb", "/a b", "/a\\b", "/:id", "/a*", "/{id}", ""])
    func `should reject a root path when it is not an absolute clean URL path`(_ value: String) {
        #expect(throws: (any Error).self) { try RootPath(value) }
    }
}
