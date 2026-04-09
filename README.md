# Bitscope

A lightweight macOS menu-bar app that records and replays mouse input
(movement, clicks, scroll), logs click coordinates to a file, and snapshots
the on-screen UI of the frontmost app as structured JSON that other tools
can consume.

## Features

- **Record & replay** mouse movement, left/right/other clicks, drags and
  scroll wheel events — timing is preserved on playback.
- **Screen information capture** — at the start of each recording, the
  Accessibility tree of the frontmost app is serialized into plain JSON
  (`role`, `title`, `value`, `frame`, `children`) and stored alongside the
  event stream.
- **Click coordinate log** — every click is appended to a tab-separated
  log file for downstream tooling.
- **Menu-bar only** — no dock icon, no main window. All UI lives in a
  popover attached to an `NSStatusItem`.
- **Graceful Accessibility permission flow** — in-app banner, one-shot
  system prompt, deep link to System Settings, live-polled so the banner
  disappears the instant permission is granted.
- **Reset permission** — wraps `tccutil reset Accessibility` for when the
  permission entry gets wedged.
- **Delete-all** recordings with confirmation dialog.
- **Single instance** — a second launch activates the existing menu-bar
  item instead of stacking a duplicate.
- **Unsigned DMG** builder for casual distribution.

## Requirements

- macOS 13 (Ventura) or newer
- Xcode 15+ (Swift 5.9)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`
  (optional; the generated `Bitscope.xcodeproj` is committed, but the build
  script regenerates it automatically when sources change)

## Build & run

```bash
# Build Bitscope.app into ./build/Bitscope.app
./build-app.sh

# Or build an unsigned .dmg for distribution
./build-dmg.sh

# Launch
open build/Bitscope.app
```

You can also open `Bitscope.xcodeproj` in Xcode and hit Run.

After launch, Bitscope appears as a `record.circle` glyph in the menu bar.

- **Left click** — toggle the popover
- **Right click** — Open / Quit menu
- **⌘R** inside the popover — start/stop recording
- **⌘Q** inside the popover — quit

## Granting Accessibility permission

Bitscope needs Accessibility access to (a) observe global mouse events via
`CGEventTap` and (b) read the Accessibility tree of other apps.

On first recording attempt, the system prompt appears. If you dismiss it,
use the in-app **Grant Access** button, or **Open System Settings** to add
Bitscope manually under *Privacy & Security → Accessibility*. The banner
disappears automatically once trust is granted — no relaunch required.

If the TCC entry gets into a bad state, click **Reset Permission** in the
popover footer to run `tccutil reset Accessibility com.bitscope.Bitscope`
and start over.

> **Note:** the app is ad-hoc signed. Re-signing on every rebuild means the
> TCC grant normally persists; if it doesn't, delete the existing entry in
> System Settings and re-grant.

## Where data is stored

All persistent data lives under `~/Library/Application Support/Bitscope/`:

```
Bitscope/
├── Recordings/
│   └── <uuid>.json      # one file per recording
└── clicks.log           # append-only tab-separated click log
```

### Recording JSON schema

```jsonc
{
  "id": "UUID",
  "name": "Recording 2026-04-09 10:30:00",
  "createdAt": "2026-04-09T10:30:00Z",
  "duration": 12.34,
  "events": [
    {
      "kind": "mouseMove",     // mouseMove | leftDown | leftUp | rightDown |
                                // rightUp  | otherDown | otherUp | scroll
      "time": 0.142,            // seconds since recording start
      "x": 512.0,
      "y": 337.5,
      "dx": 0,                  // scroll delta x (scroll events only)
      "dy": 0,                  // scroll delta y
      "button": 0               // button number for `other*` events
    }
  ],
  "screenSnapshot": [
    {
      "role": "AXApplication",
      "title": "Safari",
      "value": null,
      "frame": { "origin": { "x": 0, "y": 0 }, "size": { "w": 1440, "h": 900 } },
      "children": [ /* recursively */ ]
    }
  ]
}
```

### Click log format

Plain UTF-8, one click per line, tab-separated:

```
2026-04-09T10:30:01.123Z	left	512.0	337.5
2026-04-09T10:30:02.456Z	right	640.0	480.0
```

## Project layout

```
Bitscope/
├── Bitscope.xcodeproj/          # generated from project.yml
├── project.yml                  # XcodeGen manifest (source of truth)
├── Sources/Bitscope/
│   ├── main.swift               # NSApp bootstrap, status item, menu
│   ├── AppModel.swift           # @MainActor view model
│   ├── ContentView.swift        # SwiftUI popover UI
│   ├── EventRecorder.swift      # CGEventTap capture
│   ├── EventPlayer.swift        # CGEvent synthesis + playback timing
│   ├── Recording.swift          # Codable event + recording models
│   ├── RecordingStore.swift     # JSON persistence in Application Support
│   ├── ScreenReader.swift       # AX tree → ScreenElement snapshots
│   ├── ClickLogger.swift        # tab-separated click log file
│   └── PermissionManager.swift  # AXIsProcessTrusted / tccutil wrappers
├── Resources/Info.plist         # LSUIElement = true, bundle metadata
├── build-app.sh                 # xcodebuild → build/Bitscope.app
├── build-dmg.sh                 # hdiutil → build/Bitscope.dmg (unsigned)
└── spec.md                      # original feature spec
```

## Scripts

| Script          | What it does                                                     |
| --------------- | ---------------------------------------------------------------- |
| `build-app.sh`  | Regenerates project if sources changed, runs `xcodebuild`, copies `Bitscope.app` into `build/`. Usage: `./build-app.sh [Debug\|Release]` (default `Release`). |
| `build-dmg.sh`  | Chains through `build-app.sh`, stages an `Applications` symlink alongside the app, packages via `hdiutil create -format UDZO`. Output: `build/Bitscope.dmg` — unsigned. |

## License

No license specified — treat as all rights reserved unless you add one.
