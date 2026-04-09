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

- [x] **JSONL daily export** — `JSONLExporter` streams new actions into
      `~/Library/Application Support/Bitscope/export/actions-YYYY-MM-DD.jsonl`
      (incremental via `meta['jsonl_last_exported_action_id']`); runs on
      launch and after each recording save

- [x] **Screenshot + Vision OCR fallback** — when the AX hit is nil,
      `AXUnknown`, or has no title/value/identifier, captures a 400×400
      patch via `CGWindowListCreateImage`, stores it content-addressed
      under `blobs/`, runs `VNRecognizeTextRequest`, and writes
      `screenshot_hash` + `ocr_text` into the action row
      (`source = "ocr"` or `"hybrid"`)
- [x] **Retention policy** — `RetentionManager` runs on launch;
      screenshots expire after 30 days (NULL-ifies `screenshot_hash`,
      deletes unreferenced blobs), action rows expire after 90 days;
      configurable via `meta` keys `retention_screenshots_days` /
      `retention_actions_days`
- [x] **Per-app deny list** — `meta['deny_list_bundle_ids']` (JSON
      array); defaults to 1Password, Keychain Access, Safari Private
      Browsing; checked in `ActionEnricher` — clicks in denied apps
      are silently dropped
- [x] **OCR text redaction** — `Redactor` scrubs emails, card numbers,
      bearer tokens, AWS keys, and generic secret=value pairs before
      OCR text is written to SQLite or JSONL
- [x] **FTS5 full-text search** — `actions_fts` virtual table over
      `ax_title`, `ax_value`, `ocr_text`, `window_title` with
      insert/delete/update triggers; `Database.searchActions(query:)`
      returns matching action IDs by relevance

- [x] **Global hotkey ⌘⇧S** — stops recording or replay from anywhere
      (global + local `NSEvent` monitors); prioritises stopping playback
      if both states are somehow active

### Planned (not yet implemented)

- [ ] 
