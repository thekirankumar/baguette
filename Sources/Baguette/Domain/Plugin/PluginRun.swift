import Foundation

/// A background invocation whose outcome survives the request that started it.
struct PluginRun: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        case queued, running, succeeded, failed, cancelled
    }

    let id: String
    let command: String
    let udid: String?
    private(set) var state: State = .queued
    private(set) var message: String?
    var phase: String?
    var downloadedBytes: Int64?
    var createdAt: Date = Date()

    var isFinished: Bool { state == .succeeded || state == .failed || state == .cancelled }

    mutating func start() {
        guard !isFinished else { return }
        state = .running
    }

    mutating func finish(state: State, message: String?) {
        guard !isFinished, state == .succeeded || state == .failed || state == .cancelled else { return }
        self.state = state
        self.message = message
    }
}
