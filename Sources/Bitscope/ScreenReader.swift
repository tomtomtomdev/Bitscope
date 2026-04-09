import AppKit
import ApplicationServices

/// Walks the Accessibility tree of the frontmost application to produce a
/// `ScreenElement` snapshot. This satisfies the spec requirement of "reading
/// information on screen" in a form that's easy for other apps to consume —
/// the output is plain JSON (roles, titles, values, frames).
enum ScreenReader {
    static func snapshotFrontmost(maxDepth: Int = 8) -> [ScreenElement] {
        guard PermissionManager.isTrusted,
              let app = NSWorkspace.shared.frontmostApplication
        else { return [] }

        let ax = AXUIElementCreateApplication(app.processIdentifier)
        guard let root = element(from: ax, depth: 0, maxDepth: maxDepth) else {
            return []
        }
        return [root]
    }

    private static func element(from ax: AXUIElement,
                                depth: Int,
                                maxDepth: Int) -> ScreenElement? {
        let role = string(ax, kAXRoleAttribute as CFString) ?? "AXUnknown"
        let title = string(ax, kAXTitleAttribute as CFString)
        let value = string(ax, kAXValueAttribute as CFString)
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

        return ScreenElement(role: role, title: title, value: value,
                             frame: frame, children: children)
    }

    private static func string(_ ax: AXUIElement, _ attr: CFString) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, attr, &ref) == .success else { return nil }
        if let s = ref as? String { return s.isEmpty ? nil : s }
        return nil
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
