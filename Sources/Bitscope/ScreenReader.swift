import AppKit
import ApplicationServices

/// Walks the Accessibility tree of the frontmost application to produce a
/// `ScreenElement` snapshot. This satisfies the spec requirement of "reading
/// information on screen" in a form that's easy for other apps to consume —
/// the output is plain JSON (roles, titles, values, frames).
/// Flat description of a single element hit-tested at a click point.
/// Richer than `ScreenElement` because it carries identity metadata needed
/// to turn a click into a queryable action.
struct HitElement {
    var pid: pid_t
    var appBundleID: String?
    var appName: String?
    var windowTitle: String?
    var role: String?
    var subrole: String?
    var identifier: String?
    var title: String?
    var value: String?
    var help: String?
    var frame: CGRect?
    var url: String?
    var domIdentifier: String?
    var domClassList: [String]?
}

enum ScreenReader {
    /// Returns the Accessibility element under a screen point together with
    /// its owning app/window metadata. Cheap enough to call on every click.
    /// Runs on the caller's thread — don't call from the CGEventTap callback;
    /// enqueue on a background queue instead.
    static func hitElement(at point: CGPoint) -> HitElement? {
        guard PermissionManager.isTrusted else { return nil }

        let systemWide = AXUIElementCreateSystemWide()
        var elementRef: AXUIElement?
        let status = AXUIElementCopyElementAtPosition(
            systemWide, Float(point.x), Float(point.y), &elementRef
        )
        guard status == .success, let element = elementRef else { return nil }

        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let runningApp = NSRunningApplication(processIdentifier: pid)

        let role = string(element, kAXRoleAttribute as CFString)
        let subrole = string(element, kAXSubroleAttribute as CFString)
        let identifier = string(element, kAXIdentifierAttribute as CFString)
        let title = string(element, kAXTitleAttribute as CFString)
        let value = string(element, kAXValueAttribute as CFString)
        let help = string(element, kAXHelpAttribute as CFString)
        let frame = rect(element)
        let url = stringURL(element, kAXURLAttribute as CFString)
        let domIdentifier = string(element, "AXDOMIdentifier" as CFString)
        let domClassList = stringArray(element, "AXDOMClassList" as CFString)
        let windowTitle = enclosingWindowTitle(for: element)

        return HitElement(
            pid: pid,
            appBundleID: runningApp?.bundleIdentifier,
            appName: runningApp?.localizedName,
            windowTitle: windowTitle,
            role: role,
            subrole: subrole,
            identifier: identifier,
            title: title,
            value: value,
            help: help,
            frame: frame,
            url: url,
            domIdentifier: domIdentifier,
            domClassList: domClassList
        )
    }

    /// Walks up the `AXParent` chain until it finds an `AXWindow`, then
    /// returns its title. Returns nil if there's no enclosing window.
    private static func enclosingWindowTitle(for element: AXUIElement) -> String? {
        var current: AXUIElement = element
        for _ in 0..<12 { // hard cap on parent walk
            let role = string(current, kAXRoleAttribute as CFString)
            if role == (kAXWindowRole as String) {
                return string(current, kAXTitleAttribute as CFString)
            }
            var parentRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parentRef)
                == .success,
               let parent = parentRef {
                // swift-lint-disable-next-line force_cast
                current = parent as! AXUIElement
            } else {
                return nil
            }
        }
        return nil
    }

    private static func stringURL(_ ax: AXUIElement, _ attr: CFString) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, attr, &ref) == .success else { return nil }
        if let url = ref as? URL { return url.absoluteString }
        if let s = ref as? String { return s.isEmpty ? nil : s }
        return nil
    }

    static func snapshotFrontmost(maxDepth: Int = 8) -> [ScreenElement] {
        guard PermissionManager.isTrusted,
              let app = NSWorkspace.shared.frontmostApplication
        else { return [] }

        let ax = AXUIElementCreateApplication(app.processIdentifier)
        guard var root = element(from: ax, depth: 0, maxDepth: maxDepth) else {
            return []
        }
        // Stamp app-level identity onto the root so consumers don't have
        // to guess where the snapshot came from.
        root.appBundleID = app.bundleIdentifier
        root.appName = app.localizedName
        root.pid = app.processIdentifier
        return [root]
    }

    private static func element(from ax: AXUIElement,
                                depth: Int,
                                maxDepth: Int) -> ScreenElement? {
        let role = string(ax, kAXRoleAttribute as CFString) ?? "AXUnknown"
        let subrole = string(ax, kAXSubroleAttribute as CFString)
        let title = string(ax, kAXTitleAttribute as CFString)
        let value = string(ax, kAXValueAttribute as CFString)
        let identifier = string(ax, kAXIdentifierAttribute as CFString)
        let help = string(ax, kAXHelpAttribute as CFString)
        let url = stringURL(ax, kAXURLAttribute as CFString)
        let domIdentifier = string(ax, "AXDOMIdentifier" as CFString)
        let domClassList = stringArray(ax, "AXDOMClassList" as CFString)
        let focused = bool(ax, kAXFocusedAttribute as CFString)
        let selected = bool(ax, kAXSelectedAttribute as CFString)
        let frame = rect(ax)

        var children: [ScreenElement] = []
        if depth < maxDepth {
            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(ax, kAXChildrenAttribute as CFString, &childrenRef)
                == .success,
               let axChildren = childrenRef as? [AXUIElement] {
                for child in axChildren {
                    if let c = element(from: child, depth: depth + 1, maxDepth: maxDepth) {
                        children.append(c)
                    }
                }
            }
        }

        return ScreenElement(
            role: role,
            subrole: subrole,
            title: title,
            value: value,
            identifier: identifier,
            help: help,
            url: url,
            domIdentifier: domIdentifier,
            domClassList: domClassList,
            isFocused: focused,
            isSelected: selected,
            frame: frame,
            appBundleID: nil,
            appName: nil,
            pid: nil,
            children: children
        )
    }

    private static func string(_ ax: AXUIElement, _ attr: CFString) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, attr, &ref) == .success else { return nil }
        if let s = ref as? String { return s.isEmpty ? nil : s }
        return nil
    }

    private static func bool(_ ax: AXUIElement, _ attr: CFString) -> Bool? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, attr, &ref) == .success else { return nil }
        if CFGetTypeID(ref!) == CFBooleanGetTypeID() {
            return CFBooleanGetValue((ref as! CFBoolean))
        }
        return nil
    }

    private static func stringArray(_ ax: AXUIElement, _ attr: CFString) -> [String]? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, attr, &ref) == .success else { return nil }
        guard let arr = ref as? [Any] else { return nil }
        let strings = arr.compactMap { $0 as? String }
        return strings.isEmpty ? nil : strings
    }

    private static func rect(_ ax: AXUIElement) -> CGRect {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        var origin = CGPoint.zero
        var size = CGSize.zero
        if AXUIElementCopyAttributeValue(ax, kAXPositionAttribute as CFString, &posRef)
            == .success, let v = posRef {
            AXValueGetValue(v as! AXValue, .cgPoint, &origin)
        }
        if AXUIElementCopyAttributeValue(ax, kAXSizeAttribute as CFString, &sizeRef)
            == .success, let v = sizeRef {
            AXValueGetValue(v as! AXValue, .cgSize, &size)
        }
        return CGRect(origin: origin, size: size)
    }
}
