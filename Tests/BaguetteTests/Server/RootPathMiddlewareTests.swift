import Testing
import Hummingbird
import HummingbirdWebSocket
import HTTPTypes
import Logging
import NIOCore
import NIOEmbedded
import Mockable
@testable import Baguette

@Suite("RootPath middleware")
struct RootPathMiddlewareTests {
    @Test func `should expose notification and defaults routes beneath a configured root path`() async throws {
        let server = Server(simulators: MockSimulators(), chromes: MockChromes())
        let router = Router(context: BasicWebSocketRequestContext.self)
        let mounted = router.group("/subpath")
        server.registerNotifyRoutes(on: mounted, rejectUntrustedBrowser: { _ in nil })
        server.registerDefaultsRoutes(on: mounted, rejectUntrustedBrowser: { _ in nil })
        for path in ["/subpath/simulators/ID/defaults.json", "/subpath/simulators/ID/notify"] {
            let request = Request(
                head: HTTPRequest(method: path.hasSuffix("notify") ? .post : .get,
                                  scheme: nil, authority: "localhost:8421", path: path),
                body: .init(buffer: ByteBuffer())
            )
            let context = BasicWebSocketRequestContext(source: .init(
                channel: EmbeddedChannel(), logger: Logger(label: "RootPathMiddlewareTests")
            ))
            let response = try await router.buildResponder().respond(to: request, context: context)
            #expect(response.status == .badRequest)
        }
    }

    @Test(arguments: ["?name=a%2Fb&name=c+d&empty=", "?", ""])
    func `should preserve the request query and body beneath a root path`(_ query: String) async throws {
        let request = Self.request("/team/simulators/ID/input" + query)
        let middleware = Server.RootPathMiddleware<Context>(rootPath: try RootPath("/team"))
        let response = try await middleware.handle(request, context: Context(source: .init())) { rewritten, _ in
            #expect(rewritten.uri.path == "/simulators/ID/input")
            #expect(rewritten.uri.query == request.uri.query)
            #expect(rewritten.head.path == "/simulators/ID/input" + query)
            #expect(rewritten.method == .post)
            #expect(rewritten.headers[.contentType] == "application/json")
            let body = try await rewritten.body.collect(upTo: 1024)
            #expect(String(buffer: body) == "payload")
            return Response(status: .accepted)
        }
        #expect(response.status == .accepted)
    }

    @Test(arguments: ["/simulators/ID/input", "/team-other/simulators/ID/input", "/Team/simulators/ID/input"])
    func `should refuse a request when it is outside the root path`(_ path: String) async throws {
        let middleware = Server.RootPathMiddleware<Context>(rootPath: try RootPath("/team"))
        let response = try await middleware.handle(Self.request(path), context: Context(source: .init())) { _, _ in
            return Response(status: .accepted)
        }
        #expect(response.status == .notFound)
    }

    @Test func `should preserve the request query and body beneath a root path when using the origin root`() async throws {
        let request = Self.request("/simulators/ID/input?name=a%2Fb")
        let middleware = Server.RootPathMiddleware<Context>(rootPath: try RootPath())
        let response = try await middleware.handle(request, context: Context(source: .init())) { rewritten, _ in
            #expect(rewritten.head == request.head)
            let body = try await rewritten.body.collect(upTo: 1024)
            #expect(String(buffer: body) == "payload")
            return Response(status: .accepted)
        }
        #expect(response.status == .accepted)
    }

    private static func request(_ path: String) -> Request {
        Request(
            head: HTTPRequest(method: .post, scheme: nil, authority: "localhost:8421", path: path,
                              headerFields: [.contentType: "application/json"]),
            body: .init(buffer: ByteBuffer(string: "payload"))
        )
    }

    @Test(arguments: ["/subpath", "/subpath/"])
    func `should lead to the mounted simulator list when visiting the mount root`(_ path: String) async throws {
        let response = try await Self.respond(path: path)
        #expect(response.status == .found)
        #expect(response.headers[.location] == "/subpath/simulators")
    }

    @Test(arguments: ["/subpath/devices/ID/stream", "/subpath/devices/ID/companion/video", "/subpath/devices/ID/companion/motion"])
    func `should expose the web app and streams beneath the root path`(_ path: String) async throws {
        #expect(try await Self.respond(path: path).status == .ok)
    }

    @Test(arguments: [("/subpath/simulators", "sim.html"), ("/subpath/farm", "farm/farm.html"), ("/subpath/baguette/baguette.js", "baguette/baguette.js")])
    func `should expose the web app and streams beneath the root path when serving static assets`(_ path: String, _ asset: String) async throws {
        let response = try await Self.respond(path: path)
        let expected = Server.staticAsset(asset)
        #expect(response.status == expected.status)
        #expect(response.headers == expected.headers)
    }

    @Test(arguments: ["/", "/simulators", "/subpath-other/simulators", "/devices/ID/companion/video"])
    func `should refuse the web app and streams when outside the mounted root path`(_ path: String) async throws {
        #expect(try await Self.respond(path: path).status == .notFound)
    }

    @Test func `should preserve browser trust checks when the web app is mounted`() async throws {
        let response = try await Self.respond(
            path: "/subpath/devices/ID/stream", headers: [.origin: "https://attacker.test"]
        )
        #expect(response.status == .methodNotAllowed)
    }

    @Test(arguments: ["/subpath", "/"])
    func `should allow trusted browser preflights when serving beneath a root path`(_ root: String) async throws {
        let response = try await Self.respond(
            path: root == "/" ? "/simulators/ID/input" : root + "/simulators/ID/input",
            method: .options,
            headers: [.origin: "https://trusted.test", .accessControlRequestMethod: "POST",
                      .accessControlRequestHeaders: "content-type"],
            root: root, allowedHosts: ["trusted.test"]
        )
        #expect(response.status == .noContent)
        #expect(response.headers[.accessControlAllowOrigin] == "https://trusted.test")
    }

    @Test func `should authorize a plugin capability beneath the mounted root path`() async throws {
        let grants = PluginGrants()
        let token = grants.issue(plugin: "audit", capabilities: [.input])
        let response = try await Self.respond(
            path: "/subpath/simulators/ID/input", method: .post,
            headers: [HTTPField.Name("X-Baguette-Token")!: token], grants: grants
        )
        #expect(response.status == .notFound)
    }

    @Test func `should authorize a plugin capability beneath the mounted root path when another capability is requested`() async throws {
        let grants = PluginGrants()
        let token = grants.issue(plugin: "audit", capabilities: [.input])
        let response = try await Self.respond(
            path: "/subpath/simulators/ID/describe-ui.json",
            headers: [HTTPField.Name("X-Baguette-Token")!: token], grants: grants
        )
        #expect(response.status == .forbidden)
    }

    private static func respond(
        path: String, method: HTTPRequest.Method = .get,
        headers: HTTPFields = [:], grants: PluginGrants = PluginGrants(),
        root: String = "/subpath", allowedHosts: [String] = []
    ) async throws -> Response {
        let simulators = MockSimulators()
        given(simulators).find(udid: .any).willReturn(nil)
        let server = Server(simulators: simulators, chromes: MockChromes(),
                             allowedHosts: allowedHosts, rootPath: try RootPath(root), grants: grants)
        let request = Request(
            head: HTTPRequest(method: method, scheme: nil, authority: "localhost:8421",
                              path: path, headerFields: headers),
            body: .init(buffer: ByteBuffer())
        )
        let context = BasicWebSocketRequestContext(source: .init(
            channel: EmbeddedChannel(), logger: Logger(label: "RootPathMiddlewareTests")
        ))
        return try await server.makeRouter().buildResponder().respond(to: request, context: context)
    }

    private struct Context: RequestContext {
        var coreContext: CoreRequestContextStorage
        init(source: Source) { coreContext = .init(source: source) }
        struct Source: RequestContextSource {
            let logger = Logger(label: "RootPathMiddlewareTests")
        }
    }
}
