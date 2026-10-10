import Testing
import Foundation
import Mockable
@testable import Baguette

/// Handler-level coverage for the status-bar routes. As with the
/// orientation route, we test the pure parse + dispatch helpers
/// (`parseStatusBarOverride`, `applyStatusBar`, `clearStatusBar`)
/// rather than the Hummingbird `Response` wrappers — every branch is
/// driven with `MockSimulators` + `MockStatusBar`.
@Suite("Server status-bar routes")
struct StatusBarRoutesTests {

    // MARK: - parse

    @Test func `should read every status-bar field from a JSON body`() {
        let json = """
        {"time":"9:41","operatorName":"Baguette","dataNetwork":"5g",
         "wifiMode":"active","wifiBars":3,"cellularMode":"active",
         "cellularBars":4,"batteryState":"charged","batteryLevel":68}
        """
        #expect(Server.parseStatusBarOverride(json: json) == StatusBarOverride(
            time: "9:41", operatorName: "Baguette", dataNetwork: .fiveG,
            wifiMode: .active, wifiBars: 3, cellularMode: .active,
            cellularBars: 4, batteryState: .charged, batteryLevel: 68
        ))
    }

    @Test func `should read no status-bar override from malformed JSON`() {
        #expect(Server.parseStatusBarOverride(json: "not json") == nil)
    }

    @Test func `should read no status-bar override when an enum field is unrecognised`() {
        #expect(Server.parseStatusBarOverride(json: #"{"dataNetwork":"6g"}"#) == nil)
    }

    @Test func `should accept a partial status-bar body`() {
        #expect(Server.parseStatusBarOverride(json: #"{"batteryLevel":20}"#)
            == StatusBarOverride(batteryLevel: 20))
    }

    // MARK: - apply

    @Test func `should override the simulator's status bar with the posted fields`() async {
        let host = MockSimulators()
        let sim = MockSimulator()
        let statusBar = MockStatusBar()
        given(host).find(udid: .value("U")).willReturn(sim)
        given(sim).statusBar().willReturn(statusBar)
        given(statusBar).override(.any).willReturn(())

        let outcome = await Server.applyStatusBar(
            udid: "U", body: #"{"batteryLevel":50}"#, simulators: host
        )
        #expect(outcome == .ok)
        verify(statusBar).override(.value(StatusBarOverride(batteryLevel: 50))).called(1)
    }

    @Test func `should report an unknown device when overriding the status bar of a missing simulator`() async {
        let host = MockSimulators()
        given(host).find(udid: .value("ghost")).willReturn(nil)
        let outcome = await Server.applyStatusBar(
            udid: "ghost", body: #"{"batteryLevel":50}"#, simulators: host
        )
        #expect(outcome == .unknownDevice)
    }

    @Test func `should report an invalid body when the status-bar override is malformed JSON`() async {
        let host = MockSimulators()
        let sim = MockSimulator()
        given(host).find(udid: .value("U")).willReturn(sim)
        let outcome = await Server.applyStatusBar(udid: "U", body: "{", simulators: host)
        #expect(outcome == .invalidBody)
    }

    @Test func `should report an empty override when no status-bar field is set`() async {
        let host = MockSimulators()
        let sim = MockSimulator()
        given(host).find(udid: .value("U")).willReturn(sim)
        let outcome = await Server.applyStatusBar(udid: "U", body: "{}", simulators: host)
        #expect(outcome == .emptyOverride)
    }

    @Test func `should report a failed dispatch when simctl cannot override the status bar`() async {
        let host = MockSimulators()
        let sim = MockSimulator()
        let statusBar = MockStatusBar()
        given(host).find(udid: .value("U")).willReturn(sim)
        given(sim).statusBar().willReturn(statusBar)
        given(statusBar).override(.any).willThrow(StatusBarError.simctlFailed(status: 1))

        let outcome = await Server.applyStatusBar(
            udid: "U", body: #"{"batteryLevel":50}"#, simulators: host
        )
        #expect(outcome == .dispatchFailed)
    }

    // MARK: - clear

    @Test func `should clear the simulator's status-bar overrides`() async {
        let host = MockSimulators()
        let sim = MockSimulator()
        let statusBar = MockStatusBar()
        given(host).find(udid: .value("U")).willReturn(sim)
        given(sim).statusBar().willReturn(statusBar)
        given(statusBar).clear().willReturn(())

        #expect(await Server.clearStatusBar(udid: "U", simulators: host) == .ok)
        verify(statusBar).clear().called(1)
    }

    @Test func `should report an unknown device when clearing the status bar for an empty udid`() async {
        let host = MockSimulators()
        #expect(await Server.clearStatusBar(udid: "", simulators: host) == .unknownDevice)
    }

    // MARK: - read

    @Test func `should read the simulator's current status-bar overrides`() async {
        let host = MockSimulators()
        let sim = MockSimulator()
        let statusBar = MockStatusBar()
        given(host).find(udid: .value("U")).willReturn(sim)
        given(sim).statusBar().willReturn(statusBar)
        given(statusBar).read().willReturn(StatusBarOverride(dataNetwork: .wifi, wifiBars: 2))

        #expect(await Server.readStatusBar(udid: "U", simulators: host)
            == .ok(StatusBarOverride(dataNetwork: .wifi, wifiBars: 2)))
    }

    @Test func `should report an unknown device when reading the status bar for an empty udid`() async {
        let host = MockSimulators()
        #expect(await Server.readStatusBar(udid: "", simulators: host) == .unknownDevice)
    }

    @Test func `should report a failure when the status bar cannot be read`() async {
        let host = MockSimulators()
        let sim = MockSimulator()
        let statusBar = MockStatusBar()
        given(host).find(udid: .value("U")).willReturn(sim)
        given(sim).statusBar().willReturn(statusBar)
        given(statusBar).read().willThrow(StatusBarError.simctlFailed(status: 1))

        #expect(await Server.readStatusBar(udid: "U", simulators: host) == .failed)
    }
}
