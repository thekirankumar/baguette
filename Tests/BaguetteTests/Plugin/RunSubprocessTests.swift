import Foundation
import Testing
@testable import Baguette

@Suite("RunSubprocess")
struct RunSubprocessTests {
    final class Group: @unchecked Sendable {
        private let lock = NSLock()
        private var reads = 0
        let aliveReads: Int
        init(aliveReads: Int) { self.aliveReads = aliveReads }
        var inspections: Int { lock.withLock { reads } }
        func hasLiveProcesses(_ pid: Int32) -> Bool? {
            lock.withLock {
                reads += 1
                return reads <= aliveReads
            }
        }
    }

    @Test func `should report completion only after background helpers are confirmed stopped`() async throws {
        let group = Group(aliveReads: 3)
        let child = RunSubprocess(cleanupTimeout: .seconds(1), pollInterval: .milliseconds(1),
            groupHasLiveProcesses: { group.hasLiveProcesses($0) })
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            do {
                try child.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 0"],
                    onBytes: { _ in }, onExit: { status in
                        #expect(group.inspections >= 4)
                        continuation.resume(returning: status)
                    })
            } catch { continuation.resume(throwing: error) }
        }
        #expect(status == 0)
    }

    @Test func `should report failure within a bounded wait when background helper cleanup cannot be confirmed`() async throws {
        for inspection: Bool? in [true, nil] {
            let child = RunSubprocess(cleanupTimeout: .milliseconds(20), pollInterval: .milliseconds(1),
                groupHasLiveProcesses: { _ in inspection })
            let started = ContinuousClock.now
            let status: Int32 = try await withCheckedThrowingContinuation { continuation in
                do {
                    try child.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 0"],
                        onBytes: { _ in }, onExit: { continuation.resume(returning: $0) })
                } catch { continuation.resume(throwing: error) }
            }
            #expect(status == -1)
            #expect(ContinuousClock.now - started < .seconds(2))
        }
    }

    @Test func `should prevent descendants from writing after the background command exits`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("run-process-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let child = RunSubprocess()
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            do {
                try child.run(executable: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "(sleep 0.2; touch marker) & exit 0"],
                    workingDirectory: root, environment: ["PATH": "/usr/bin:/bin"], stdin: Data(),
                    onBytes: { _ in Issue.record("background stdout must be discarded") },
                    onExit: { continuation.resume(returning: $0) })
            } catch { continuation.resume(throwing: error) }
        }
        #expect(status == 0)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("marker").path))
    }

    @Test func `should stop the entire background process group when cancellation escalates`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("run-process-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let child = RunSubprocess()
        let completed = Task {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                do {
                    try child.run(executable: URL(fileURLWithPath: "/bin/sh"),
                        arguments: ["-c", "trap '' TERM; (sleep 0.3; touch marker) & touch ready; wait"],
                        workingDirectory: root, environment: ["PATH": "/usr/bin:/bin"], stdin: Data(),
                        onBytes: { _ in }, onExit: { continuation.resume(returning: $0) })
                } catch { continuation.resume(throwing: error) }
            }
        }
        for _ in 0..<1000 {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("ready").path) { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("ready").path))
        child.terminate()
        child.kill()
        #expect(try await completed.value != 0)
        try await Task.sleep(for: .milliseconds(400))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("marker").path))
    }

    @Test func `should never launch a background command when cancellation precedes startup`() async throws {
        let child = RunSubprocess()
        child.kill()
        #expect(throws: (any Error).self) {
            try child.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 0"],
                onBytes: { _ in }, onExit: { _ in Issue.record("cancelled child started") })
        }
    }
}
