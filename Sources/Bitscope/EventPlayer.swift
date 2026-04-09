import Foundation
import CoreGraphics

/// Replays a recording by synthesizing `CGEvent`s on a background queue.
/// The inter-event timing of the original capture is preserved.
final class EventPlayer {
    private var workItem: DispatchWorkItem?
    private(set) var isPlaying = false

    func play(_ recording: Recording, completion: @escaping () -> Void) {
        stop()
        guard !recording.events.isEmpty else { completion(); return }

        isPlaying = true
        let events = recording.events
        let start = Date()

        let work = DispatchWorkItem { [weak self] in
            for event in events {
                if self?.workItem?.isCancelled == true { break }
                let target = start.addingTimeInterval(event.time)
                let wait = target.timeIntervalSinceNow
                if wait > 0 {
                    Thread.sleep(forTimeInterval: wait)
                }
                Self.post(event)
            }
            DispatchQueue.main.async {
                self?.isPlaying = false
                completion()
            }
        }
        workItem = work
        DispatchQueue.global(qos: .userInteractive).async(execute: work)
    }

    func stop() {
        workItem?.cancel()
        workItem = nil
        isPlaying = false
    }

    private static func post(_ event: RecordedEvent) {
        let point = CGPoint(x: event.x, y: event.y)
        let source = CGEventSource(stateID: .hidSystemState)

        let cg: CGEvent?
        switch event.kind {
        case .mouseMove:
            cg = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                         mouseCursorPosition: point, mouseButton: .left)
        case .leftDown:
            cg = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                         mouseCursorPosition: point, mouseButton: .left)
        case .leftUp:
            cg = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                         mouseCursorPosition: point, mouseButton: .left)
        case .rightDown:
            cg = CGEvent(mouseEventSource: source, mouseType: .rightMouseDown,
                         mouseCursorPosition: point, mouseButton: .right)
        case .rightUp:
            cg = CGEvent(mouseEventSource: source, mouseType: .rightMouseUp,
                         mouseCursorPosition: point, mouseButton: .right)
        case .otherDown:
            cg = CGEvent(mouseEventSource: source, mouseType: .otherMouseDown,
                         mouseCursorPosition: point, mouseButton: .center)
            cg?.setIntegerValueField(.mouseEventButtonNumber, value: Int64(event.button))
        case .otherUp:
            cg = CGEvent(mouseEventSource: source, mouseType: .otherMouseUp,
                         mouseCursorPosition: point, mouseButton: .center)
            cg?.setIntegerValueField(.mouseEventButtonNumber, value: Int64(event.button))
        case .scroll:
            cg = CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                         wheelCount: 2,
                         wheel1: Int32(event.dy),
                         wheel2: Int32(event.dx),
                         wheel3: 0)
        }
        cg?.post(tap: .cgSessionEventTap)
    }
}
