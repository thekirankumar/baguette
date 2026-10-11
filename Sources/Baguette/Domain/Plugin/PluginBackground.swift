import Foundation

/// Host-trusted execution policy, never supplied by an API caller.
struct PluginBackground: Codable, Equatable, Sendable {
    let timeoutSeconds: Int
    let environment: [String]

    init(timeoutSeconds: Int = 3600, environment: [String] = []) {
        self.timeoutSeconds = timeoutSeconds
        self.environment = environment
    }

    static func parsing(_ value: Any) throws -> Self {
        guard let dict = value as? [String: Any],
              dict["timeoutSeconds"] == nil || dict["timeoutSeconds"] is NSNumber,
              dict["environment"] == nil || dict["environment"] is [String] else {
            throw PluginManifestError.invalidBackground
        }
        let number = dict["timeoutSeconds"] as? NSNumber
        guard number.map({ CFGetTypeID($0) != CFBooleanGetTypeID()
            && $0.doubleValue >= 1 && $0.doubleValue <= 86400
            && $0.doubleValue.rounded(.towardZero) == $0.doubleValue }) ?? true else {
            throw PluginManifestError.invalidBackground
        }
        let timeout = number?.intValue ?? 3600
        let environment = dict["environment"] as? [String] ?? []
        guard (1...86400).contains(timeout), environment.allSatisfy({ name in
            name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil
                && !name.hasPrefix("BAGUETTE_") && name != "PATH"
        }) else { throw PluginManifestError.invalidBackground }
        return Self(timeoutSeconds: timeout, environment: environment)
    }
}
