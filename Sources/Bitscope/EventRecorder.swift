import AppKit
import CoreGraphics

/// Captures global mouse events via a `CGEventTap`. The tap is installed at
/// the session level so events from any app are observed; Accessibility
/// permission is required for this to work.
final class EventRecorder {
    private(set) var isRecording = false
    private(set) var events: [RecordedEvent] = []
    private var startTime: CFAbsoluteTime = 0
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    func start() -> Bool {
        guard !isRecording else { return true }
        guard PermissionManager.isTrusted else { return false }

        events.removeAll()
        startTime = CFAbsoluteTimeGetCurrent()

        let types: [CGEventType] = [
            .mouseMoved,
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged,
            .scrollWheel
        ]
        var mask: CGEventMask = 0
        for t in types {
            mask |= (1 << UInt64(t.rawValue))
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: EventRecorder.tapCallback,
            userInfo: refcon
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        isRecording = true
        return true
    }

    func stop() -> (events: [RecordedEvent], duration: TimeInterval) {
        guard isRecording else { return (events, 0) }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isRecording = false
        let duration = CFAbsoluteTimeGetCurrent() - startTime
        return (events, duration)
    }

    private static let tapCallback: CGEventTapCallBack = { _, type, cgEvent, userInfo in
        guard let userInfo = userInfo else { return Unmanaged.passUnretained(cgEvent) }
        let recorder = Unmanaged<EventRecorder>.fromOpaque(userInfo).takeUnretainedValue()
        recorder.handle(type: type, event: cgEvent)
        return Unmanaged.passUnretained(cgEvent)
    }

    private func handle(type: CGEventType, event: CGEvent) {
        let t = CFAbsoluteTimeGetCurrent() - startTime
        let loc = event.location

        let kind: RecordedEvent.Kind?
        var dx: Double = 0
        var dy: Double = 0
        var button = 0

        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            kind = .mouseMove
        case .leftMouseDown:  kind = .leftDown
        case .leftMouseUp:    kind = .leftUp
        case .rightMouseDown: kind = .rightDown
        case .rightMouseUp:   kind = .rightUp
        case .otherMouseDown:
            kind = .otherDown
            button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        case .otherMouseUp:
            kind = .otherUp
            button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        case .scrollWheel:
            kind = .scroll
            dy = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
            dx = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
        default:
            kind = nil
        }

        guard let kind = kind else { return }
        events.append(RecordedEvent(
            kind: kind, time: t, x: Double(loc.x), y: Double(loc.y),
            dx: dx, dy: dy, button: button
        ))

        // Persist click coordinates to a standalone log so they can be
        // inspected independently of the JSON recording file.
        switch kind {
        case .leftDown:
            ClickLogger.shared.logClick(button: "left", x: Double(loc.x), y: Double(loc.y))
        case .rightDown:
            ClickLogger.shared.logClick(button: "right", x: Double(loc.x), y: Double(loc.y))
        case .otherDown:
            ClickLogger.shared.logClick(button: "other", x: Double(loc.x), y: Double(loc.y))
        default:
            break
        }
    }
}
