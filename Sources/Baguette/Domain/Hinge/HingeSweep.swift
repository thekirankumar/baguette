import Foundation

/// A sweep baguette plays on a foldable's hinge, as `HingeControl sweep
/// <from> <to> <ms>` plays it in the guest: one sample every 60 Hz frame
/// with Device Hub's ease-out, the first step at once and the last
/// exactly on the target.
struct HingeSweep: Equatable, Sendable {
    let from: Double
    let to: Double
    let duration: TimeInterval

    static let frameInterval: TimeInterval = 1.0 / 60

    /// `HingeControl`'s count: whole 16.667 ms frames, at least one, and
    /// as many as an `Int` holds for a sweep longer than that.
    private var frames: Int {
        let count = duration * 1000 / 16.667
        guard count >= 1 else { return 1 }
        return count < Double(Int.max) ? Int(count) : Int.max
    }

    /// How long after the start the last sample goes out.
    var settlesAfter: TimeInterval { Double(frames - 1) * Self.frameInterval }

    /// The angle the guest has been sent `elapsed` seconds in.
    func degrees(after elapsed: TimeInterval) -> Double {
        let sample = self.sample(after: elapsed)
        if sample == frames { return to }
        let progress = Double(sample) / Double(frames)
        return from + (to - from) * (1 - pow(1 - progress, 3))
    }

    func hasSettled(after elapsed: TimeInterval) -> Bool {
        sample(after: elapsed) == frames
    }

    /// 1-based, as the guest counts; a frame boundary counts as reached.
    private func sample(after elapsed: TimeInterval) -> Int {
        min(frames, max(0, Int(elapsed / Self.frameInterval + 1e-6)) + 1)
    }
}

/// A sweep baguette plays on a hinge, told as it begins and as it ends.
enum HingeSweepEvent: Equatable, Sendable {
    case began(HingeSweep)
    case ended(PoseDelivery)
}
