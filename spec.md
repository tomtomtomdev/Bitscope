Bitscope spec
---

## Implemented

### Spec items

- [x] Record mouse movement, clicks (left/right/other), drags and scroll
      via a session-level `CGEventTap`
- [x] Replay recordings via synthesized `CGEvent`s, preserving original
      inter-event timing
- [x] Delete-all-recordings function with confirmation dialog
- [x] Read on-screen information via the Accessibility tree and store it
      as JSON alongside each recording
- [x] Graceful Accessibility permission handling — in-app banner,
      one-shot system prompt, deep link to System Settings, live polling
      so state updates without relaunch
- [x] Permission banner auto-dismisses the moment trust flips to true
- [x] Menu-bar-only UI (`NSStatusItem` + `NSPopover`), no Dock icon,
      `LSUIElement = true`
- [x] Unsigned DMG build script (`build-dmg.sh` → `hdiutil create`)
- [x] Converted from Swift Package to Xcode project via XcodeGen
      (`project.yml` → `Bitscope.xcodeproj`)
- [x] Click coordinate log at
      `~/Library/Application Support/Bitscope/clicks.log`
- [x] Reset Permission button (shells out to `tccutil reset
      Accessibility com.bitscope.Bitscope`)
- [x] Single-instance guard — second launch activates the existing
      status item and terminates
- [x] Record button hidden when Accessibility not granted
- [x] Quit button in popover footer **and** right-click menu on the
      status item (`⌘Q` shortcut)
- [x] Play-All-in-series button with mid-series cancellation

### Architecture additions (beyond literal spec)

- [x] **GRDB-backed queryable index** at
      `~/Library/Application Support/Bitscope/bitscope.sqlite`
      - Schema v1: `sessions`, `recordings`, `actions` with indexes
      - Schema v2: extended AX fields (`ax_help`,
        `ax_dom_identifier`, `ax_dom_class_list`)
      - Append-only `DatabaseMigrator`; DB failure degrades gracefully
        (capture still works, index disabled)
- [x] **Action derivation** — every click is hit-tested via
      `AXUIElementCopyElementAtPosition` on a background queue and
      inserted as a row carrying bundle id, app name, window title,
      role, subrole, identifier, title, value, help, DOM
      identifier/class list, URL and frame
- [x] **Session lifecycle** — one session per app launch, started in
      `AppModel.init`, ended from `applicationWillTerminate`
- [x] **Rich snapshots** — `ScreenReader.snapshotFrontmost` pulls
      subrole, identifier, help, URL, DOM id/class, focused/selected
      state per node, and stamps app bundle id / name / pid on the
      root

### Planned (not yet implemented)

- [ ] Step 5: daily JSONL export of `actions` for agent/tool
      consumption
- [ ] Step 6: screenshot + Vision OCR fallback when the AX tree at a
      click site is empty or `AXUnknown`; populate reserved
      `screenshot_hash` / `ocr_text` columns
- [ ] Step 7: retention policy, per-app deny list, OCR redaction
      (emails, tokens, card numbers) before persistence
- [ ] FTS5 virtual table over `ax_title` / `ax_value` / `ocr_text` /
      `window_title` for free-text queries
