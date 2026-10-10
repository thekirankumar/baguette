import Foundation

/// A literal mount prefix shared by HTTP routes, redirects and WebSockets.
struct RootPath: Sendable, Equatable {
    let path: String

    init(_ value: String = "/") throws {
        guard value.hasPrefix("/"),
              value.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "/abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~").contains($0)
              }),
              !value.contains("//"),
              !value.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
        else {
            throw InvalidRootPath()
        }
        self.path = value == "/" ? "" : value.hasSuffix("/") ? String(value.dropLast()) : value
    }

    func route(_ route: String) -> String { path + route }

    func relative(_ route: String) -> String? {
        guard !path.isEmpty else { return route }
        if route == path { return "/" }
        guard route.hasPrefix(path + "/") else { return nil }
        return String(route.dropFirst(path.count))
    }

    struct InvalidRootPath: Error, CustomStringConvertible {
        var description: String {
            "rootpath must be an absolute literal URL path (for example /subpath), without empty or dot segments"
        }
    }
}
