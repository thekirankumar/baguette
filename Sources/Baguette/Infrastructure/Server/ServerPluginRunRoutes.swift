import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import NIOCore

extension Server {
    func registerPluginRunRoutes(
        on router: some RouterMethods<BasicWebSocketRequestContext>,
        rejectUntrustedBrowser: @escaping @Sendable (Request) -> Response?
    ) {
        let runs = pluginRuns
        let plugins = plugins
        let simulators = simulators
        let grants = grants
        let rootPath = rootPath
        let origin = "http://\(host):\(port)\(rootPath.path)"

        router.post("/plugins/:id/commands/:cmd/runs") { request, _ in
            if let rejected = rejectUntrustedBrowser(request) { return rejected }
            guard let buffer = try? await request.body.collect(upTo: 64 * 1024) else {
                return Self.pluginRunInvalidBody()
            }
            return await Self.startPluginRun(
                qualified: Self.qualifiedCommandParam(request), body: Data(buffer: buffer),
                udid: request.uri.queryParameters.get("udid").map { String($0) },
                origin: origin, rootPath: rootPath, plugins: plugins,
                simulators: simulators, grants: grants, runs: runs
            )
        }

        // Hummingbird treats :id.json as a parameter name, not a suffix
        // constraint. Share :id with cancellation and validate the suffix.
        router.get("/runs/:id") { request, _ in
            if let rejected = rejectUntrustedBrowser(request) { return rejected }
            let id = Self.pluginRunID(request, suffix: ".json")
            guard let run = await runs.get(id) else {
                return Self.pluginRunNotFound(id)
            }
            return Self.pluginRunResponse(run, status: .ok)
        }

        router.post("/runs/:id/cancel") { request, _ in
            if let rejected = rejectUntrustedBrowser(request) { return rejected }
            let id = Self.pluginRunID(request)
            do {
                guard let run = try await runs.cancel(id) else {
                    return Self.pluginRunNotFound(id)
                }
                // A cancellation request is not completion: the child and
                // workspace remain owned until the registry finishes cleanup.
                return Self.pluginRunResponse(run, status: run.isFinished ? .ok : .accepted)
            } catch {
                return Self.pluginRunFailure(error)
            }
        }
    }

    enum PluginRunBodyError: Error { case invalid }

    static func parsePluginRunArgs(body: Data) throws -> PluginArgs? {
        guard body.count <= 64 * 1024 else { throw PluginRunBodyError.invalid }
        if body.isEmpty { return nil }
        guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              Set(object.keys).isSubset(of: ["args"]) else {
            throw PluginRunBodyError.invalid
        }
        guard let value = object["args"] else { return nil }
        guard let args = value as? [String: Any], let parsed = PluginArgs(args) else {
            throw PluginRunBodyError.invalid
        }
        return args.isEmpty ? nil : parsed
    }

    static func startPluginRun(
        qualified: String, body: Data, udid: String?, origin: String, rootPath: RootPath,
        plugins: any Plugins, simulators: any Simulators, grants: PluginGrants, runs: PluginRuns
    ) async -> Response {
        let args: PluginArgs?
        do { args = try parsePluginRunArgs(body: body) }
        catch { return pluginRunInvalidBody() }

        do {
            guard let (plugin, command) = try plugins.resolve(qualifiedCommand: qualified) else {
                return pluginRunFailure(PluginRuns.Failure.unknownCommand)
            }
            guard command.background != nil else {
                return pluginRunFailure(PluginRuns.Failure.notBackground)
            }
            var apps: (any Apps)?
            if let udid {
                guard !udid.isEmpty else { return pluginRunFailure(PluginRuns.Failure.appsUnavailable) }
                guard let simulator = simulators.find(udid: udid) else {
                    return pluginRunNotFound("simulator \(udid)")
                }
                if plugin.manifest.capabilities.contains(.apps) { apps = simulator.apps() }
            }
            let run = try await runs.start(qualifiedCommand: qualified,
                context: .init(serverURL: origin, udid: udid, token: "", args: args?.object),
                plugins: plugins, grants: grants, apps: apps)
            var response = pluginRunResponse(run, status: .accepted)
            response.headers[.location] = rootPath.route("/runs/\(run.id).json")
            return response
        } catch {
            return pluginRunFailure(error)
        }
    }

    static func pluginRunFailure(_ error: any Error) -> Response {
        let failure = error as? PluginRuns.Failure ?? .storage
        let status: HTTPResponse.Status
        switch failure {
        case .unknownCommand: status = .notFound
        case .notBackground, .appsUnavailable: status = .badRequest
        case .simulatorBusy, .concurrencyLimit, .capacity, .installing, .shuttingDown: status = .conflict
        case .storage: status = .internalServerError
        }
        var response = pluginError(failure.description, status: status)
        response.headers[.cacheControl] = "no-store"
        return response
    }

    static func pluginRunResponse(_ run: PluginRun, status: HTTPResponse.Status) -> Response {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(run)
            return Response(status: status,
                headers: [.contentType: "application/json", .cacheControl: "no-store"],
                body: .init(byteBuffer: ByteBuffer(data: data)))
        } catch { return pluginRunFailure(error) }
    }

    private static func pluginRunID(_ request: Request, suffix: String = "") -> String {
        let parts = request.uri.path.split(separator: "/")
        guard parts.count >= 2 else { return "" }
        let value = String(parts[1]).removingPercentEncoding ?? ""
        guard suffix.isEmpty || value.hasSuffix(suffix) else { return "" }
        return String(value.dropLast(suffix.count))
    }

    private static func pluginRunInvalidBody() -> Response {
        var response = pluginError("run body must be a JSON object containing only an args object (max 64 KiB)",
            status: .badRequest)
        response.headers[.cacheControl] = "no-store"
        return response
    }

    private static func pluginRunNotFound(_ id: String) -> Response {
        var response = pluginError("unknown run or target: \(id)", status: .notFound)
        response.headers[.cacheControl] = "no-store"
        return response
    }
}
