import Foundation
import Mockable
import Testing
@testable import Baguette

@Suite("Devices")
struct DevicesTests {
    private let hello = TwinHello(
        udid: "U1", name: "Baguette's iPhone", model: "iPhone17,2",
        capabilities: ["motion", "screen"]
    )

    @Test func `should know a device by the identity its companion says hello with`() {
        let device = Device(hello: hello)
        #expect(device == Device(
            udid: "U1", name: "Baguette's iPhone", model: "iPhone17,2",
            capabilities: ["motion", "screen"]
        ))
    }

    @Test func `should find a connected device by udid and nothing for an unknown one`() {
        let devices = MockDevices()
        given(devices).all.willReturn([Device(hello: hello)])
        #expect(devices.find(udid: "U1")?.name == "Baguette's iPhone")
        #expect(devices.find(udid: "nope") == nil)
    }

    @Test func `should list connected devices as JSON with sorted keys`() {
        let devices = MockDevices()
        given(devices).all.willReturn([Device(hello: hello)])
        #expect(devices.listJSON == """
        {"connected":[{"capabilities":["motion","screen"],"model":"iPhone17,2","name":"Baguette's iPhone","udid":"U1"}]}
        """)
    }

    @Test func `should list an empty connected array when no companions are connected`() {
        let devices = MockDevices()
        given(devices).all.willReturn([])
        #expect(devices.listJSON == #"{"connected":[]}"#)
    }
}
