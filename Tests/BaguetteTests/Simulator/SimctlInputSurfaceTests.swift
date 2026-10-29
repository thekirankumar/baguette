import Testing
import Foundation
import Mockable
@testable import Baguette

/// Orchestration coverage for `SimctlInputSurface` — the argv it sends
/// through `Subprocess` to ask whether Device Hub has shadowed a
/// simulator's input surface, and to reclaim it.
///
/// Reclaiming is a fixed sequence in the guest: clear the notify state
/// Device Hub's daemon set, restart backboardd (SpringBoard goes down with
/// it), then wait until SpringBoard is back under a new pid. Every branch
/// is driven through `MockSubprocess`; the real `xcrun` spawn lives in
/// `HostSubprocess` (integration-only).
@Suite("SimctlInputSurface")
struct SimctlInputSurfaceTests {

    final class Captures: @unchecked Sendable {
        var spawns: [[String]] = []
        var sleeps: [Duration] = []
        /// SpringBoard pid reported by each successive `launchctl list`.
        var springBoardPids: [Int32?] = []
        /// Notify state reported by each successive `notifyutil -g`.
        var states: [String?] = []
        var onExit: (@Sendable (Int32) -> Void)?
    }

    private func guestListing(springBoard: Int32?) -> String {
        let pid = springBoard.map(String.init) ?? "-"
        return "42499\t0\tcom.apple.backboardd\n\(pid)\t0\tcom.apple.SpringBoard\n"
    }

    /// - Parameters:
    ///   - state: what `notifyutil -g` prints, nil for a failed spawn.
    ///   - springBoardPids: what successive `launchctl list` calls report;
    ///     the last entry repeats.
    ///   - failing: an argv fragment whose spawn should exit non-zero.
    private func makeSurface(
        state: String? = nil,
        states: [String?]? = nil,
        springBoardPids: [Int32?] = [100, 100, 200],
        failing: String? = nil,
        deviceHubRunning: Bool = false,
        deviceSetPath: String? = nil
    ) -> (SimctlInputSurface, MockSimulator, Captures) {
        let sub = MockSubprocess()
        let sim = MockSimulator()
        given(sim).udid.willReturn("U")
        given(sim).deviceSetPath.willReturn(deviceSetPath)
        let captures = Captures()
        captures.springBoardPids = springBoardPids
        captures.states = states ?? []
        given(sub).run(
            executable: .any, arguments: .any,
            onBytes: .any, onExit: .any
        ).willProduce { _, args, onBytes, onExit in
            captures.spawns.append(args)
            if let failing, args.contains(failing) {
                onExit(1)
                return
            }
            if args.contains("-g") {
                // Successive reads walk `states` (last repeats); else `state`.
                let read = captures.states.count > 1
                    ? captures.states.removeFirst()
                    : captures.states.first ?? state
                if let read { onBytes(Data(read.utf8)) }
                onExit(read == nil ? 1 : 0)
            } else if args.contains("list") {
                let pid = captures.springBoardPids.count > 1
                    ? captures.springBoardPids.removeFirst()
                    : captures.springBoardPids[0]
                onBytes(Data(self.guestListing(springBoard: pid).utf8))
                onExit(0)
            } else {
                onExit(0)
            }
        }
        given(sub).terminate().willReturn()
        let surface = SimctlInputSurface(
            subprocess: { sub },
            deviceHubRunning: { deviceHubRunning },
            sleep: { captures.sleeps.append($0) }
        )
        return (surface, sim, captures)
    }

    // MARK: - shadowed

    @Test func `should find the input surface shadowed when Device Hub's notify state is active in the guest`() async {
        let (surface, sim, captures) = makeSurface(state: "com.apple.coredevice.dtuhidd.active 1\n")
        let shadowed = await surface.shadowed(on: sim)
        #expect(shadowed)
        #expect(captures.spawns == [[
            "simctl", "spawn", "U",
            "notifyutil", "-g", "com.apple.coredevice.dtuhidd.active",
        ]])
    }

    @Test func `should find the input surface unshadowed when Device Hub's state is inactive`() async {
        let (surface, sim, _) = makeSurface(state: "com.apple.coredevice.dtuhidd.active 0\n")
        #expect(await surface.shadowed(on: sim) == false)
    }

    @Test func `should find the input surface unshadowed when the state cannot be read`() async {
        // A device that is shut down, or an Xcode 26 host: no Device Hub
        // to speak of, so no heal to advise.
        let (surface, sim, _) = makeSurface(state: nil)
        #expect(await surface.shadowed(on: sim) == false)
    }

    // MARK: - ready

    @Test func `should wait on bootstatus until the boot completes before reporting ready`() async throws {
        // `boot()` returns as soon as the device state flips. launchd
        // starts SpringBoard and backboardd within a second of that, and
        // Device Hub's daemon a second later — long before the home
        // screen. `bootstatus -b` is the one simctl verb that waits for
        // the real thing.
        let (surface, sim, captures) = makeSurface()
        try await surface.ready(on: sim)

        #expect(captures.spawns == [["simctl", "bootstatus", "U", "-b"]])
        #expect(captures.sleeps.isEmpty)
    }

    @Test func `should wait for the boot and read the input surface inside the simulator's custom device set when it lives in one`() async throws {
        let (surface, sim, captures) = makeSurface(
            state: "com.apple.coredevice.dtuhidd.active 1\n", deviceSetPath: "/custom set")
        try await surface.ready(on: sim)
        _ = await surface.shadowed(on: sim)

        #expect(captures.spawns == [
            ["simctl", "--set", "/custom set", "bootstatus", "U", "-b"],
            ["simctl", "--set", "/custom set", "spawn", "U", "notifyutil", "-g", "com.apple.coredevice.dtuhidd.active"],
        ])
    }

    @Test func `should give Device Hub's daemon time to attach when Device Hub is running`() async throws {
        // bootstatus can return before dtuhidd has published its state.
        // With Device Hub up on the host, the attach is coming; wait for it.
        let inactive = "com.apple.coredevice.dtuhidd.active 0\n"
        let active = "com.apple.coredevice.dtuhidd.active 1\n"
        let (surface, sim, captures) = makeSurface(
            states: [inactive, inactive, active], deviceHubRunning: true)
        try await surface.ready(on: sim)

        #expect(captures.spawns.first == ["simctl", "bootstatus", "U", "-b"])
        #expect(captures.spawns.filter { $0.contains("-g") }.count == 3)
        #expect(captures.sleeps.count == 2)
    }

    @Test func `should stop waiting when Device Hub's daemon never attaches`() async throws {
        // Device Hub running but not attaching to this device (another
        // device set, say): bounded wait, then carry on unshadowed.
        let inactive = "com.apple.coredevice.dtuhidd.active 0\n"
        let (surface, sim, captures) = makeSurface(states: [inactive], deviceHubRunning: true)
        try await surface.ready(on: sim)

        #expect(captures.spawns.filter { $0.contains("-g") }.count == 20)
        #expect(captures.sleeps.count == 19)
    }

    @Test func `should report a failure when the boot never completes`() async {
        let (surface, sim, _) = makeSurface(failing: "bootstatus")
        await #expect(throws: InputSurfaceError.simctlFailed(status: 1)) {
            try await surface.ready(on: sim)
        }
    }

    // MARK: - reclaim

    @Test func `should stop waiting for a boot when its command deadline expires`() async {
        let sub = MockSubprocess()
        given(sub).run(executable: .any, arguments: .any, onBytes: .any, onExit: .any).willReturn()
        given(sub).kill().willReturn()
        let sim = MockSimulator()
        given(sim).udid.willReturn("U")
        given(sim).deviceSetPath.willReturn(nil)
        let surface = SimctlInputSurface(subprocess: { sub }, bootTimeout: .milliseconds(20))

        await #expect(throws: InputSurfaceError.timedOut) {
            try await surface.ready(on: sim)
        }
        verify(sub).kill().called(1)
    }

    @Test func `should stop waiting for a boot when preparation is cancelled`() async {
        let sub = MockSubprocess()
        let started = AsyncStream<Void>.makeStream()
        given(sub).run(executable: .any, arguments: .any, onBytes: .any, onExit: .any)
            .willProduce { _, _, _, _ in started.continuation.yield(()) }
        given(sub).kill().willReturn()
        let sim = MockSimulator()
        given(sim).udid.willReturn("U")
        given(sim).deviceSetPath.willReturn(nil)
        let surface = SimctlInputSurface(subprocess: { sub })
        let task = Task { try await surface.ready(on: sim) }
        for await _ in started.stream { break }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        verify(sub).kill().called(1)
    }

    @Test func `should stop waiting for a guest command when its deadline expires`() async {
        let sub = MockSubprocess()
        given(sub).run(executable: .any, arguments: .any, onBytes: .any, onExit: .any).willReturn()
        given(sub).kill().willReturn()
        let sim = MockSimulator()
        given(sim).udid.willReturn("U")
        given(sim).deviceSetPath.willReturn(nil)
        let surface = SimctlInputSurface(subprocess: { sub }, commandTimeout: .milliseconds(20))

        #expect(await surface.shadowed(on: sim) == false)
        verify(sub).kill().called(1)
    }

    @Test func `should stop preparing the input surface when its total deadline expires`() async {
        let sub = MockSubprocess()
        given(sub).run(executable: .any, arguments: .any, onBytes: .any, onExit: .any).willReturn()
        given(sub).kill().willReturn()
        let sim = MockSimulator()
        given(sim).udid.willReturn("U")
        given(sim).deviceSetPath.willReturn(nil)
        let surface = SimctlInputSurface(subprocess: { sub }, preparationTimeout: .milliseconds(20))

        await #expect(throws: InputSurfaceError.timedOut) {
            try await surface.healAfterBoot(on: sim)
        }
        verify(sub).kill().called(1)
    }

    @Test func `should reclaim the input surface after boot when Device Hub has shadowed it`() async throws {
        let (surface, sim, _) = makeSurface(state: "com.apple.coredevice.dtuhidd.active 1\n")

        #expect(try await surface.healAfterBoot(on: sim) == .reclaimed)
    }

    @Test func `should leave the input surface alone after boot when Device Hub has not shadowed it`() async throws {
        let (surface, sim, _) = makeSurface(state: "com.apple.coredevice.dtuhidd.active 0\n")

        #expect(try await surface.healAfterBoot(on: sim) == .unshadowed)
    }

    @Test func `should stop preparing the input surface when healing exceeds the total deadline`() async {
        let sub = MockSubprocess()
        let captures = Captures()
        given(sub).run(executable: .any, arguments: .any, onBytes: .any, onExit: .any)
            .willProduce { _, args, onBytes, onExit in
                captures.spawns.append(args)
                if args.contains("kickstart") { return }
                if args.contains("-g") { onBytes(Data("com.apple.coredevice.dtuhidd.active 1\n".utf8)) }
                if args.contains("list") { onBytes(Data(self.guestListing(springBoard: 100).utf8)) }
                onExit(0)
            }
        given(sub).kill().willReturn()
        let sim = MockSimulator()
        given(sim).udid.willReturn("U")
        given(sim).deviceSetPath.willReturn(nil)
        let surface = SimctlInputSurface(
            subprocess: { sub }, deviceHubRunning: { false }, preparationTimeout: .milliseconds(50))

        await #expect(throws: InputSurfaceError.timedOut) {
            try await surface.healAfterBoot(on: sim)
        }
        #expect(captures.spawns.last?.contains("kickstart") == true)
        verify(sub).kill().called(1)
    }

    @Test func `should keep the timeout outcome when the stopped boot reports a late exit`() async {
        let sub = MockSubprocess()
        let captures = Captures()
        given(sub).run(executable: .any, arguments: .any, onBytes: .any, onExit: .any)
            .willProduce { _, _, _, onExit in captures.onExit = onExit }
        given(sub).kill().willProduce {
            captures.onExit?(0)
            captures.onExit?(1)
        }
        let sim = MockSimulator()
        given(sim).udid.willReturn("U")
        given(sim).deviceSetPath.willReturn(nil)
        let surface = SimctlInputSurface(subprocess: { sub }, bootTimeout: .milliseconds(20))

        await #expect(throws: InputSurfaceError.timedOut) {
            try await surface.ready(on: sim)
        }
        verify(sub).kill().called(1)
    }

    @Test func `should avoid starting a boot wait when preparation is already cancelled`() async {
        let sub = MockSubprocess()
        let surface = SimctlInputSurface(subprocess: { sub })
        let sim = MockSimulator()
        given(sim).udid.willReturn("U")
        given(sim).deviceSetPath.willReturn(nil)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await surface.ready(on: sim)
        }

        await #expect(throws: CancellationError.self) { try await task.value }
        verify(sub).run(executable: .any, arguments: .any, onBytes: .any, onExit: .any).called(0)
    }

    @Test func `should clear Device Hub's state before restarting backboardd when reclaiming`() async throws {
        let (surface, sim, captures) = makeSurface()
        try await surface.reclaim(on: sim)

        // First the state, so SimulatorHID re-initialises believing Device
        // Hub is absent; then the restart. The other order would let the
        // new backboardd read the stale `1`.
        #expect(Array(captures.spawns.prefix(3)) == [
            ["simctl", "spawn", "U", "launchctl", "list"],
            ["simctl", "spawn", "U",
             "notifyutil", "-s", "com.apple.coredevice.dtuhidd.active", "0"],
            ["simctl", "spawn", "U",
             "launchctl", "kickstart", "-k", "system/com.apple.backboardd"],
        ])
    }

    @Test func `should wait for SpringBoard to come back under a new pid when reclaiming`() async throws {
        // Old SpringBoard was 100; two polls still see it (or nothing),
        // the third sees the replacement.
        let (surface, sim, captures) = makeSurface(springBoardPids: [100, 100, nil, 200])
        try await surface.reclaim(on: sim)

        let polls = captures.spawns.filter { $0.contains("list") }
        #expect(polls.count == 4)  // one before the restart, three after
        #expect(captures.sleeps.count == 4)  // one before each poll, plus a settle
    }

    @Test func `should give up reclaiming when SpringBoard never returns`() async {
        let (surface, sim, _) = makeSurface(springBoardPids: [100, 100])
        await #expect(throws: InputSurfaceError.springBoardMissing) {
            try await surface.reclaim(on: sim)
        }
    }

    @Test func `should fail to reclaim when backboardd cannot be restarted`() async {
        let (surface, sim, _) = makeSurface(failing: "kickstart")
        await #expect(throws: InputSurfaceError.simctlFailed(status: 1)) {
            try await surface.reclaim(on: sim)
        }
    }
}
