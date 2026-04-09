import Foundation

/// A single captured input event. Timestamps are seconds relative to the
/// start of the recording so playback is location/clock independent.
struct RecordedEvent: Codable {
    enum Kind: String, Codable {
        case mouseMove
        case leftDown, leftUp
        case rightDown, rightUp
        case otherDown, otherUp
        case scroll
    }

    var kind: Kind
    var time: TimeInterval
    var x: Double
    var y: Double
    // Scroll deltas (points). Unused for non-scroll events.
    var dx: Double = 0
    var dy: Double = 0
    // Mouse button number for `other*` events.
    var button: Int = 0
}

/// A captured element on screen, produced by `ScreenReader`. These are
/// lightweight snapshots meant to be easy for other apps to consume.
struct ScreenElement: Codable {
    var role: String
    var title: String?
    var value: String?
    var frame: CGRect
    var children: [ScreenElement]
}

struct Recording: Codable, Identifiable {
    var id: UUID
    var name: String
    var createdAt: Date
    var duration: TimeInterval
    var events: [RecordedEvent]
    /// Optional snapshot of visible UI at the moment recording started.
    var screenSnapshot: [ScreenElement]

    init(id: UUID = UUID(),
         name: String,
         createdAt: Date = Date(),
         duration: TimeInterval,
         events: [RecordedEvent],
         screenSnapshot: [ScreenElement] = []) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.duration = duration
        self.events = events
        self.screenSnapshot = screenSnapshot
    }
}
