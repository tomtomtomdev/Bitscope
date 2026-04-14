import AppKit
import SwiftUI

// CLI mode: process Desktop screenshots and output JSON
if CommandLine.arguments.contains("--recognize") {
    let json = ImageRecognizer.processDesktopScreenshots()
    print(json)
    exit(0)
}

if CommandLine.arguments.contains("--stocks") {
    let json = ImageRecognizer.extractStockPicks()
    print(json)
    exit(0)
}

if CommandLine.arguments.contains("--stocks-save") {
    if let url = ImageRecognizer.processAndSave() {
        print("Saved to: \(url.path)")
        exit(0)
    } else {
        fputs("Failed to save stock picks\n", stderr)
        exit(1)
    }
}

// Trading model commands
if CommandLine.arguments.contains("--trade-import") {
    let model = TradingModel()
    let count = model.importLatestData()
    print("Imported \(count) new data points")
    exit(0)
}

if CommandLine.arguments.contains("--trade-analyze") {
    let model = TradingModel()
    _ = model.importLatestData()  // Import latest first
    print(model.generateReport())
    exit(0)
}

if CommandLine.arguments.contains("--trade-signals") {
    let model = TradingModel()
    _ = model.importLatestData()
    print(model.exportAnalysisJSON())
    exit(0)
}

if CommandLine.arguments.contains("--trade-backtest") {
    let model = TradingModel()
    _ = model.importLatestData()
    let backtester = Backtester(model: model)

    print("Running backtest on imported data...")

    // Run portfolio backtest
    let result = backtester.backtestPortfolio(stockHistory: model.stockHistory)
    print(backtester.generateBacktestReport(result: result))

    // Also show current signals
    let analysis = model.analyzeAll()
    print("\n\nCURRENT SIGNAL DISTRIBUTION")
    print("-".padding(toLength: 40, withPad: "-", startingAt: 0))
    let buys = analysis.filter { $0.signal == .buy }.count
    let holds = analysis.filter { $0.signal == .hold }.count
    let sells = analysis.filter { $0.signal == .sell }.count
    let avoids = analysis.filter { $0.signal == .avoid }.count
    print("  BUY: \(buys), HOLD: \(holds), SELL: \(sells), AVOID: \(avoids)")

    print("\nTOP BUY SIGNALS:")
    for stock in analysis.filter({ $0.signal == .buy }).prefix(5) {
        print("  \(stock.signal.emoji) \(stock.symbol): \(stock.stage.description)")
        print("     Confidence: \(String(format: "%.0f%%", stock.confidence * 100))")
    }

    exit(0)
}

if CommandLine.arguments.contains("--help") || CommandLine.arguments.contains("-h") {
    print("""
    Bitscope - Screen Recording & Stock Analysis

    USAGE:
      Bitscope                    Launch GUI app
      Bitscope [OPTIONS]          CLI mode

    SCREENSHOT RECOGNITION:
      --recognize                 OCR all Desktop screenshots to JSON
      --stocks                    Extract stock picks to stdout
      --stocks-save               Save stock picks to ~/Desktop/stock-picks.json

    TRADING MODEL:
      --trade-import              Import latest stock data into model
      --trade-analyze             Generate trading signals report
      --trade-signals             Export signals as JSON
      --trade-backtest            Run backtest on historical data

    """)
    exit(0)
}

/// Bitscope is a menu-bar-only app: no dock icon, no main window. All UI
/// is presented through a popover attached to an `NSStatusItem`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var globalHotkeyMonitor: Any?
    private var localHotkeyMonitor: Any?

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

        installGlobalHotkey()
    }

    /// Installs a global ⌘⇧S hotkey that stops recording or replay,
    /// whichever is currently active. Uses both a global monitor (app not
    /// focused) and a local monitor (app focused) so it works regardless
    /// of popover visibility.
    private func installGlobalHotkey() {
        let handler: (NSEvent) -> Bool = { [weak self] event in
            guard let self,
                  event.modifierFlags.contains([.command, .shift]),
                  event.charactersIgnoringModifiers?.lowercased() == "s" else {
                return false
            }
            if self.model.isPlaying {
                self.model.stopPlayback()
                return true
            } else if self.model.isRecording {
                self.model.stopRecording()
                return true
            }
            return false
        }

        globalHotkeyMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: .keyDown
        ) { event in
            _ = handler(event)
        }

        localHotkeyMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { event in
            handler(event) ? nil : event
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

    func applicationWillTerminate(_ notification: Notification) {
        if let m = globalHotkeyMonitor { NSEvent.removeMonitor(m) }
        if let m = localHotkeyMonitor { NSEvent.removeMonitor(m) }
        // Give the current session a proper `ended_at` timestamp.
        model.shutdown()
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
