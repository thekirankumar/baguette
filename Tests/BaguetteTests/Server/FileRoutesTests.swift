import Testing
import Foundation
import Mockable
@testable import Baguette

/// Handler-level coverage for the file-upload route. We test the pure
/// dispatch helper (`Server.addFile`) rather than the Hummingbird
/// `Response` wrapper — every branch driven with `MockSimulators` +
/// `MockApps` / `MockPhotoLibrary`.
///
/// `addFile` is the thin "which collection?" router: an app file goes
/// to `apps().install`, media to `photos().add`, and anything with no
/// home on a simulator is refused out loud (never silently dropped).
/// Classification is by extension, so the tests pass plain paths — no
/// bytes need exist on disk.
@Suite("Server file routes")
struct FileRoutesTests {

    @Test func `should install a dropped .ipa on the simulator`() async {
        let host = MockSimulators()
        let sim = MockSimulator()
        let apps = MockApps()
        given(host).find(udid: .value("U")).willReturn(sim)
        given(sim).apps().willReturn(apps)
        given(apps).install(.any).willReturn(())

        let outcome = await Server.addFile(
            udid: "U", path: URL(fileURLWithPath: "/tmp/up/MyApp.ipa"), simulators: host
        )
        #expect(outcome == .installed)
        verify(apps).install(.value(AppBundle(path: URL(fileURLWithPath: "/tmp/up/MyApp.ipa")))).called(1)
    }

    @Test func `should add a dropped photo to the simulator's photo library`() async {
        let host = MockSimulators()
        let sim = MockSimulator()
        let photos = MockPhotoLibrary()
        given(host).find(udid: .value("U")).willReturn(sim)
        given(sim).photos().willReturn(photos)
        given(photos).add(.any).willReturn(())

        let outcome = await Server.addFile(
            udid: "U", path: URL(fileURLWithPath: "/tmp/up/shot.png"), simulators: host
        )
        #expect(outcome == .added)
        verify(photos).add(.value(MediaItem(path: URL(fileURLWithPath: "/tmp/up/shot.png")))).called(1)
    }

    // MARK: - what a given route will accept

    @Test func `should refuse an app on the media route`() async {
        // `/media` carries the `media` capability. Installing software
        // through it would let a plugin trusted only to add photos put
        // an executable on the device.
        let host = MockSimulators()
        let sim = MockSimulator()
        let apps = MockApps()
        given(host).find(udid: .value("U")).willReturn(sim)
        given(sim).apps().willReturn(apps)

        let outcome = await Server.addFile(
            udid: "U", path: URL(fileURLWithPath: "/tmp/up/MyApp.ipa"),
            simulators: host, allowing: .media
        )
        #expect(outcome == .wrongKind(ext: "ipa"))
        verify(apps).install(.any).called(0)
    }

    @Test func `should refuse a photo on the apps route`() async {
        let host = MockSimulators()
        let sim = MockSimulator()
        let photos = MockPhotoLibrary()
        given(host).find(udid: .value("U")).willReturn(sim)
        given(sim).photos().willReturn(photos)

        let outcome = await Server.addFile(
            udid: "U", path: URL(fileURLWithPath: "/tmp/up/shot.png"),
            simulators: host, allowing: .apps
        )
        #expect(outcome == .wrongKind(ext: "png"))
        verify(photos).add(.any).called(0)
    }

    @Test func `should take both apps and photos on the browser's drag-and-drop route`() async {
        // `/files` is the one entry point that classifies for you, which
        // is why it is closed to plugins entirely.
        let host = MockSimulators()
        let sim = MockSimulator()
        let apps = MockApps()
        let photos = MockPhotoLibrary()
        given(host).find(udid: .value("U")).willReturn(sim)
        given(sim).apps().willReturn(apps)
        given(sim).photos().willReturn(photos)
        given(apps).install(.any).willReturn(())
        given(photos).add(.any).willReturn(())

        #expect(await Server.addFile(
            udid: "U", path: URL(fileURLWithPath: "/tmp/up/MyApp.ipa"),
            simulators: host, allowing: .all
        ) == .installed)
        #expect(await Server.addFile(
            udid: "U", path: URL(fileURLWithPath: "/tmp/up/shot.png"),
            simulators: host, allowing: .all
        ) == .added)
    }

    @Test func `should refuse a file that has no home on a simulator`() async {
        let host = MockSimulators()
        let sim = MockSimulator()
        given(host).find(udid: .value("U")).willReturn(sim)

        let outcome = await Server.addFile(
            udid: "U", path: URL(fileURLWithPath: "/tmp/up/notes.pdf"), simulators: host
        )
        #expect(outcome == .unsupported(ext: "pdf"))
    }

    @Test func `should report an unknown device when a file is added for an unknown udid`() async {
        let host = MockSimulators()
        given(host).find(udid: .value("ghost")).willReturn(nil)
        let outcome = await Server.addFile(
            udid: "ghost", path: URL(fileURLWithPath: "/tmp/up/MyApp.ipa"), simulators: host
        )
        #expect(outcome == .unknownDevice)
    }

    @Test func `should install a zipped .app as an archive`() async {
        let host = MockSimulators()
        let sim = MockSimulator()
        let apps = MockApps()
        given(host).find(udid: .value("U")).willReturn(sim)
        given(sim).apps().willReturn(apps)
        given(apps).install(archive: .any).willReturn(())

        let outcome = await Server.addFile(
            udid: "U", path: URL(fileURLWithPath: "/tmp/up/MyApp.app.zip"), simulators: host
        )
        #expect(outcome == .installed)
        verify(apps).install(archive: .value(AppArchive(path: URL(fileURLWithPath: "/tmp/up/MyApp.app.zip")))).called(1)
    }

    @Test func `should refuse a zip with no app inside and say why`() async {
        let host = MockSimulators()
        let sim = MockSimulator()
        let apps = MockApps()
        given(host).find(udid: .value("U")).willReturn(sim)
        given(sim).apps().willReturn(apps)
        given(apps).install(archive: .any).willThrow(AppsError.noAppInArchive)

        let outcome = await Server.addFile(
            udid: "U", path: URL(fileURLWithPath: "/tmp/up/docs.zip"), simulators: host
        )
        #expect(outcome == .badArchive(reason: "no single .app bundle at the top level of the zip"))
    }

    @Test func `should refuse a corrupt zip with the extract failure`() async {
        let host = MockSimulators()
        let sim = MockSimulator()
        let apps = MockApps()
        given(host).find(udid: .value("U")).willReturn(sim)
        given(sim).apps().willReturn(apps)
        given(apps).install(archive: .any).willThrow(AppsError.extractFailed(status: 2))

        let outcome = await Server.addFile(
            udid: "U", path: URL(fileURLWithPath: "/tmp/up/broken.zip"), simulators: host
        )
        #expect(outcome == .badArchive(reason: "ditto -x -k exited 2 (corrupt zip?)"))
    }

    @Test func `should refuse a zip that inflates past the extraction cap and say why`() async {
        let host = MockSimulators()
        let sim = MockSimulator()
        let apps = MockApps()
        given(host).find(udid: .value("U")).willReturn(sim)
        given(sim).apps().willReturn(apps)
        given(apps).install(archive: .any)
            .willThrow(AppsError.archiveTooLarge(bytes: 8_589_934_592, limit: 4_294_967_296))

        let outcome = await Server.addFile(
            udid: "U", path: URL(fileURLWithPath: "/tmp/up/bomb.zip"), simulators: host
        )
        #expect(outcome == .badArchive(
            reason: "archive inflates to 8589934592 bytes, over the 4294967296-byte cap (zip bomb?)"
        ))
    }

    @Test func `should report a failed dispatch when simctl cannot install a zipped app`() async {
        let host = MockSimulators()
        let sim = MockSimulator()
        let apps = MockApps()
        given(host).find(udid: .value("U")).willReturn(sim)
        given(sim).apps().willReturn(apps)
        given(apps).install(archive: .any).willThrow(AppsError.installFailed(status: 1))

        let outcome = await Server.addFile(
            udid: "U", path: URL(fileURLWithPath: "/tmp/up/MyApp.app.zip"), simulators: host
        )
        #expect(outcome == .dispatchFailed)
    }

    @Test func `should report a failed dispatch when simctl cannot install an .ipa`() async {
        let host = MockSimulators()
        let sim = MockSimulator()
        let apps = MockApps()
        given(host).find(udid: .value("U")).willReturn(sim)
        given(sim).apps().willReturn(apps)
        given(apps).install(.any).willThrow(AppsError.installFailed(status: 1))

        let outcome = await Server.addFile(
            udid: "U", path: URL(fileURLWithPath: "/tmp/up/MyApp.ipa"), simulators: host
        )
        #expect(outcome == .dispatchFailed)
    }
}
