import AppKit
import SwiftUI

/// Bitscope is a menu-bar-only app: no dock icon, no main window. All UI
/// is presented through a popover attached to an `NSStatusItem`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var monitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prevent a second Bitscope from attaching a duplicate status item.
        // If another instance is already running, activate it and quit.
        if let bundleID = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            if let existing = others.first {
                existing.activate(options: [.activateIgnoringOtherApps])
                NSApp.terminate(nil)
                return
            }
        }

        let content = ContentView().environmentObject(model)

        popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 420, height: 460)
        popover.contentViewController = NSHostingController(rootView: content)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "record.circle",
                                   accessibilityDescription: "Bitscope")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(handleStatusClick(_:))
            // Receive both left- and right-clicks so we can show a menu on
            // secondary click without blocking the primary toggle action.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Reflect recording state in the menu-bar glyph.
        model.onStateChange = { [weak self] in
            self?.updateStatusIcon()
        }
    }

    @objc private func handleStatusClick(_ sender: Any?) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            showMenu()
        } else {
            togglePopover(sender)
        }
    }

    private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Bitscope",
                     action: #selector(openFromMenu),
                     keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Bitscope",
                     action: #selector(quit),
                     keyEquivalent: "q").target = self
        // Attach the menu momentarily so it appears under the status item,
        // then detach so left-click continues to toggle the popover.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openFromMenu() {
        togglePopover(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        let name = model.isRecording ? "record.circle.fill" : "record.circle"
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: "Bitscope")
        button.image?.isTemplate = !model.isRecording
        button.contentTintColor = model.isRecording ? .systemRed : nil
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    objc_setAssociatedObject(app, "BitscopeDelegate", delegate, .OBJC_ASSOCIATION_RETAIN)
    app.delegate = delegate
    // Accessory = menu-bar only, no Dock icon, no main menu activation.
    app.setActivationPolicy(.accessory)
    app.run()
}
