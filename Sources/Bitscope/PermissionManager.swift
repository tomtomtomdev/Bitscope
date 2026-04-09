import AppKit
import ApplicationServices

/// Thin wrapper around the Accessibility permission APIs. Recording global
/// mouse events and reading other apps' UI both require this.
enum PermissionManager {
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Prompts the user if necessary. Returns the current trusted state.
    @discardableResult
    static func requestTrust() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options: CFDictionary = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Opens the Accessibility pane in System Settings so the user can grant
    /// access without hunting through menus.
    static func openSystemSettings() {
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    /// Shells out to `tccutil reset Accessibility <bundle-id>` to clear
    /// this app's Accessibility permission entry. Silent on failure — the
    /// user can always fall back to revoking manually in System Settings.
    static func resetTrust() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.bitscope.Bitscope"
        let process = Process()
        process.launchPath = "/usr/bin/tccutil"
        process.arguments = ["reset", "Accessibility", bundleID]
        try? process.run()
        process.waitUntilExit()
    }
}
