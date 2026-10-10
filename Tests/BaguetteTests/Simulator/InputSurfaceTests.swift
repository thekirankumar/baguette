import Testing
import Mockable
@testable import Baguette

/// Default-impl behaviour on `InputSurface`: `heal` is the one verb the
/// App layer calls — after a boot, or on `baguette heal` — and it only
/// pays for the SpringBoard restart when the surface is actually shadowed.
@Suite("InputSurface")
struct InputSurfaceTests {

    @Test func `should leave an unshadowed input surface alone when healing`() async throws {
        let surface = MockInputSurface()
        let sim = MockSimulator()
        given(surface).shadowed(on: .any).willReturn(false)

        let outcome = try await surface.heal(on: sim)

        #expect(outcome == .unshadowed)
        verify(surface).reclaim(on: .any).called(0)
    }

    @Test func `should reclaim a shadowed input surface when healing`() async throws {
        let surface = MockInputSurface()
        let sim = MockSimulator()
        given(surface).shadowed(on: .any).willReturn(true)
        given(surface).reclaim(on: .any).willReturn()

        let outcome = try await surface.heal(on: sim)

        #expect(outcome == .reclaimed)
        verify(surface).reclaim(on: .any).called(1)
    }

    @Test func `should report a failed reclaim when healing`() async {
        let surface = MockInputSurface()
        let sim = MockSimulator()
        given(surface).shadowed(on: .any).willReturn(true)
        given(surface).reclaim(on: .any).willThrow(InputSurfaceError.springBoardMissing)

        await #expect(throws: InputSurfaceError.springBoardMissing) {
            try await surface.heal(on: sim)
        }
    }

    @Test func `should wait for the input surface to be ready when healing after boot`() async throws {
        let surface = MockInputSurface()
        let sim = MockSimulator()
        given(surface).ready(on: .any).willReturn()
        given(surface).shadowed(on: .any).willReturn(true)
        given(surface).reclaim(on: .any).willReturn()

        let outcome = try await surface.healAfterBoot(on: sim)

        #expect(outcome == .reclaimed)
        verify(surface).ready(on: .any).called(1)
    }

    @Test func `should summarise each heal outcome in one line`() {
        #expect(HealOutcome.unshadowed.summary.contains("not shadowed"))
        #expect(HealOutcome.reclaimed.summary.contains("reclaimed"))
    }
}
