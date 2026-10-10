import Testing
import Foundation
import Mockable
@testable import Baguette

/// Which of a simulator's panels the chrome, screen and tap space
/// describe. On a foldable that is the hinge's call; everything else
/// has one panel and never asks.
@Suite("Simulator lit panel")
struct LitPanelTests {

    private func duo(angle: HingeAngle?) -> (MockSimulator, MockChromes) {
        let sim = MockSimulator()
        let chromes = MockChromes()
        let hinge = MockHinge()
        given(sim).deviceTypeName.willReturn("iPhone Duo")
        given(sim).hinge().willReturn(hinge)
        given(hinge).angle().willReturn(angle)
        given(chromes).panels(forDeviceName: .value("iPhone Duo")).willReturn([.primary, .secondary])
        return (sim, chromes)
    }

    @Test func `should light the cover when folded`() {
        let (sim, chromes) = duo(angle: HingeAngle(degrees: 3))
        #expect(sim.litPanel(in: chromes) == .primary)
    }

    @Test func `should light the unfolded panel when open`() {
        let (sim, chromes) = duo(angle: HingeAngle(degrees: 130))
        #expect(sim.litPanel(in: chromes) == .secondary)
    }

    /// No reading means as booted: folded.
    @Test func `should light the cover when there is no hinge reading`() {
        let (sim, chromes) = duo(angle: nil)
        #expect(sim.litPanel(in: chromes) == .primary)
    }

    /// The hinge read is a devicectl round-trip; a phone must not pay it.
    @Test func `should never ask the hinge of a single-panel device`() {
        let sim = MockSimulator()
        let chromes = MockChromes()
        given(sim).deviceTypeName.willReturn("iPhone 17 Pro")
        given(chromes).panels(forDeviceName: .any).willReturn([.primary])
        #expect(sim.litPanel(in: chromes) == .primary)
        verify(sim).hinge().called(0)
    }

    @Test func `should show the lit panel's chrome`() {
        let (sim, chromes) = duo(angle: HingeAngle(degrees: 130))
        let unfolded = DeviceChromeAssets(
            chrome: DeviceChrome(
                identifier: "phone14",
                screenInsets: Insets(top: 0, left: 0, bottom: 0, right: 0),
                outerCornerRadius: 0, buttons: [],
                compositeImageName: "X"
            ),
            composite: ChromeImage(data: Data(), size: Size(width: 1, height: 1))
        )
        given(chromes).assets(forDeviceName: .value("iPhone Duo"), panel: .value(.secondary))
            .willReturn(unfolded)
        #expect(sim.chrome(in: chromes)?.chrome.identifier == "phone14")
    }
}
