import ArgumentParser
import Foundation

extension PluginsCommand {
    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "start", abstract: "Start a background plugin command on a running server")
        @Argument(help: "Qualified command id, e.g. artifacts:download.") var command: String
        @Option(help: "Device the command targets.") var udid: String?
        @Option(help: "Running server URL, including its mount prefix.") var url = "http://127.0.0.1:8421"
        @Option(help: "Plugin arguments as a JSON object, not executable or shell overrides.") var args = "{}"

        func validate() throws {
            _ = try PluginRunCommand.request(base: url, action: .start(command, udid: udid, args: args))
        }

        func run() async throws {
            try await PluginRunCommand.perform(base: url, action: .start(command, udid: udid, args: args))
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "status", abstract: "Print a background run's current JSON")
        @Argument(help: "Run id.") var id: String
        @Option(help: "Running server URL, including its mount prefix.") var url = "http://127.0.0.1:8421"

        func validate() throws { _ = try PluginRunCommand.request(base: url, action: .status(id)) }
        func run() async throws { try await PluginRunCommand.perform(base: url, action: .status(id)) }
    }

    struct Cancel: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "cancel", abstract: "Request cancellation of a background run")
        @Argument(help: "Run id.") var id: String
        @Option(help: "Running server URL, including its mount prefix.") var url = "http://127.0.0.1:8421"

        func validate() throws { _ = try PluginRunCommand.request(base: url, action: .cancel(id)) }
        func run() async throws { try await PluginRunCommand.perform(base: url, action: .cancel(id)) }
    }

    struct Wait: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "wait", abstract: "Wait for terminal run JSON; fail if the run failed or was cancelled")
        @Argument(help: "Run id.") var id: String
        @Option(help: "Running server URL, including its mount prefix.") var url = "http://127.0.0.1:8421"

        func validate() throws { _ = try PluginRunCommand.request(base: url, action: .status(id)) }
        func run() async throws { try await PluginRunCommand.perform(base: url, action: .status(id), wait: true) }
    }
}

/// Server-owned runs only: no manifest lookup, process execution or client token.
enum PluginRunCommand {
    enum Action {
        case start(String, udid: String?, args: String)
        case status(String)
        case cancel(String)
    }

    static func request(base: String, action: Action) throws -> URLRequest {
        guard var components = URLComponents(string: base),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw ValidationError("Server URL must be http or https with a host and no credentials, query or fragment")
        }
        let prefix = components.percentEncodedPath
        let mountSegments = prefix.split(separator: "/", omittingEmptySubsequences: false)
        guard mountSegments.enumerated().allSatisfy({ index, segment in
            if segment.isEmpty { return index == 0 || index == mountSegments.count - 1 }
            guard let decoded = String(segment).removingPercentEncoding else { return false }
            return decoded != "." && decoded != ".." && !decoded.contains("/") && !decoded.contains("\\")
                && !decoded.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        }) else { throw ValidationError("Server mount must not contain empty, dot or encoded separator segments") }

        let pathCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let segments: [String]
        var body: Data?
        var method = "GET"
        switch action {
        case .start(let qualified, let udid, let args):
            let parts = qualified.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, parts.allSatisfy({ part in
                !part.isEmpty && part != "." && part != ".." && part.unicodeScalars.allSatisfy { pathCharacters.contains($0) }
            }) else { throw ValidationError("Command must be plugin:command with URL-safe identity segments") }
            guard args.utf8.count <= 64 * 1024,
                  let object = try? JSONSerialization.jsonObject(with: Data(args.utf8)) as? [String: Any] else {
                throw ValidationError("Arguments must be a JSON object (max 64 KiB)")
            }
            body = try JSONSerialization.data(withJSONObject: ["args": object], options: [.sortedKeys, .withoutEscapingSlashes])
            guard body!.count <= 64 * 1024 else { throw ValidationError("Run request exceeds 64 KiB") }
            if let udid {
                guard !udid.isEmpty else { throw ValidationError("Device identity must not be empty") }
                components.queryItems = [.init(name: "udid", value: udid)]
            }
            segments = ["plugins", parts[0], "commands", parts[1], "runs"]
            method = "POST"
        case .status(let id), .cancel(let id):
            guard !id.isEmpty, id != ".", id != "..",
                  !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  let encoded = id.addingPercentEncoding(withAllowedCharacters: pathCharacters) else {
                throw ValidationError("Run identity must be nonempty and not a dot segment")
            }
            if case .cancel = action {
                segments = ["runs", encoded, "cancel"]
                method = "POST"
            } else { segments = ["runs", encoded + ".json"] }
        }
        components.percentEncodedPath = (prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix) + "/" + segments.joined(separator: "/")
        guard let url = components.url else { throw ValidationError("Invalid server URL") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }

    static func perform(
        base: String, action: Action, wait: Bool = false,
        send: (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) },
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        output: (String) -> Void = { print($0) }
    ) async throws {
        let request = try request(base: base, action: action)
        while true {
            try Task.checkCancellation()
            let (data, response) = try await send(request)
            guard data.count <= 64 * 1024 else { throw ValidationError("Server run response exceeds 64 KiB") }
            guard let response = response as? HTTPURLResponse else { throw ValidationError("Server did not provide an HTTP response") }
            // Never echo arbitrary error bodies, which can contain secrets or terminal escapes.
            guard (200..<300).contains(response.statusCode) else { throw ValidationError("Server rejected run request (HTTP \(response.statusCode))") }
            guard let run = try? JSONDecoder().decode(PluginRun.self, from: data) else { throw ValidationError("Server provided invalid run JSON") }
            if !wait || run.isFinished {
                // Re-serialize JSON rather than printing untrusted raw response bytes.
                let object = try JSONSerialization.jsonObject(with: data)
                let json = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
                output(String(decoding: json, as: UTF8.self))
                if wait && run.state != .succeeded { throw ExitCode.failure }
                return
            }
            try await sleep(.seconds(1))
        }
    }
}
