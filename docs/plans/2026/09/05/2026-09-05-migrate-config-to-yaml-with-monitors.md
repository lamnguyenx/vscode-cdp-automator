# Migrate Config to YAML + Monitor Fingerprint Key

**Date:** 2026-09-05
**Status:** Implemented

---

## Goal

Replace the current JSON-based config store with a YAML-based one, using a multi-line fingerprint key (sorted UUID + name per connected monitor) instead of the current verbose positional fingerprint string. Rename `displayLayout` to `monitors` and remove the standalone `display-layout.json` file.

---

## Motivation

1. **Readability** — YAML with literal block keys lets each monitor arrangement be clearly labeled by UUID + name.
2. **Stability** — UUID-based keys are stable across reboots, unlike positional fingerprints that can jitter.
3. **Simplicity** — Drop the standalone `display-layout.json` file. Everything lives in one config file.
4. **Editor-friendly** — YAML is easier to hand-edit than JSON.

---

## New Config File Location

`~/.config/vscode-cdp-automator/config.yaml`

Old file (`config.json`) will be migrated on first read then removed.

---

## Config Structure

```yaml
? 'EINK (1) - 12DF9D18...

   EINK (2) - 4E09C07E...

   EINK (3) - A5C22C33...

   LG ULTRAFINE - B8A0EB60...

   EINK (4) - CA80224C...'
:
  monitors:
    displays:
      - id: CA80224C-2647-4420-8DC2-2CC0F710BC17
        resolution: 1080x1920
        hertz: 60
        color_depth: 8
        origin: { x: 0, y: 0 }
        rotation: 90
        enabled: true
      # ... other displays

  layout:
    sidebar: { width: 300, height: 1440 }
    panel: { width: 0, height: 304 }
    editor: { width: 466, height: 1440 }
    activitybar: { width: 58, height: 1440 }
    auxiliarybar: ~
    workbench: { width: 1080, height: 1920 }
    sidebar_position: left
    panel_position: bottom
    zoom_level: -0.543
    zoom_percent: 90

  windows:
    - title: main.py — test-project — Visual Studio Code
      pid: 12345
      x: 127
      y: 325
      width: 1240
      height: 860
      screenFrame: 'x=0 y=0 1080x1920'
      screenRelativeX: 127
      screenRelativeY: 325
      label: main.py — test-project

  vivaldi:
    tabBarWidth: 224
    tabBarPosition: left
    uiZoom: 0.85
    defaultZoom: 1.0
    window:
      title: Vivaldi
      pid: 23456
      x: 105
      y: 42
      width: 1486
      height: 1273
      screenFrame: 'x=0 y=0 1080x1920'
      screenRelativeX: 105
      screenRelativeY: 42
      label: Vivaldi

  otherWindows:
    com.apple.Terminal:
      - title: bash — 80x24
        x: 106
        y: 222
        width: 785
        height: 442
        screenFrame: 'x=0 y=0 1080x1920'
        screenRelativeX: 106
        screenRelativeY: 222
        label: bash — 80x24
    com.apple.Preview:
      - title: screenshot.png
        x: 147
        y: 25
        width: 662
        height: 598
        screenFrame: 'x=0 y=0 1080x1920'
        screenRelativeX: 147
        screenRelativeY: 25
        label: screenshot.png
```

---

## Changes per File

### 1. `Package.swift` (new file)

```swift
import PackageDescription

let package = Package(
    name: "vscode-ui-resizer",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.2"),
    ],
    targets: [
        .executableTarget(
            name: "vscode-ui-resizer",
            dependencies: ["Yams"],
            path: "."
        )
    ]
)
```

### 2. `Makefile`

Replace:
```makefile
swiftc -o vscode-ui-resizer/vscode-ui-resizer.exe vscode-ui-resizer/*.swift
```

With:
```makefile
cd vscode-ui-resizer && swift build -c release
cp .build/release/vscode-ui-resizer vscode-ui-resizer.exe
```

### 3. `ConfigStore.swift`

| Change | Detail |
|--------|--------|
| **CONFIG_PATH** | Change from `config.json` to `config.yaml` |
| **Imports** | Add `import Yams` |
| **DisplayConfig.monitors** | Rename `displayLayout` → `monitors` (type `DisplayLayout?`) |
| **loadConfigStore()** | Check `config.yaml` first; if missing but `config.json` exists, migrate: read JSON, rename `displayLayout` → `monitors` in every entry, write YAML, delete JSON. Return store. |
| **saveConfigStore()** | Use `YAMLEncoder` instead of `JSONEncoder` |
| **`Encoder.outputFormatting`** | Not applicable in YAMLEncoder (no equivalent needed) |
| **Remove** | `DISPLAY_LAYOUT_PATH` constant (standalone file no longer needed) |

### 4. `Screens.swift` — `displayFingerprint()`

**Current behavior:** Builds a multi-line string from NSScreen positions, sizes, scale, rotation, names.

**New behavior:** Run `displayplacer list`, parse persistent UUIDs + contextual screen IDs, match contextual IDs to NSScreen's `NSScreenNumber` for `localizedName`, sort alphabetically by UUID, return lines of `Name - UUID...`.

```swift
func displayFingerprint() -> String {
    // Run displayplacer list, parse persistent IDs + positions
    // Match positions to NSScreen.screens for localized names
    // Sort alphabetically by UUID
    // Return lines: "UUID  Name"
}
```

**Why sorting by UUID (alphabetically):** Stable order regardless of which display macOS considers "main" or arrangement order.

### 5. `Orchestration.swift`

| Change | Detail |
|--------|--------|
| `cmdSaveDisplayLayout()` | Remove standalone `DISPLAY_LAYOUT_PATH` write. Just save into store under `monitors` key. |
| `cmdRestoreDisplayLayout()` | Read `monitors` from store's matched entry. Remove `DISPLAY_LAYOUT_PATH` fallback. |
| `parseDisplayplacerList()` | Unchanged (produces `[MonitorEntry]` correctly). |
| `displayLayoutChanged()` | Can be simplified or kept as-is. |
| `cmdSaveAll()` | Unchanged (already calls `cmdSaveDisplayLayout` first). |
| `cmdRestoreAll()` | Unchanged (already calls `cmdRestoreDisplayLayout` first). |

### 6. `main.swift`

No changes (commands already registered).

---

### Fingerprint Key Format

The fingerprint key is now `Name - UUID...` instead of `UUID... Name`:
```
EINK (1) - 12DF9D18...
EINK (2) - 4E09C07E...
EINK (3) - A5C22C33...
LG ULTRAFINE - B8A0EB60...
EINK (4) - CA80224C...
```

Sorted alphabetically by UUID (stable order). Names come from `NSScreen.localizedName`, matched via contextual screen ID (`NSScreenNumber`).

### Pruning Old Keys

`pruneOldFingerprintKeys()` filters config entries: only keys containing `" - "` (the new format) are kept. Old positional keys like `[-1080, 0] 1080x1920pt...` are automatically removed on load.

**Important:** After migration, you must run `save-all` once to re-capture windows/layout/vivaldi data under the new UUID-based key.

---

## Migration Path

On first run after rebuild:

1. `loadConfigStore()` checks for `config.yaml` → found → return store (fast path).
2. If `config.yaml` not found but `config.json` exists:
   - Read JSON store
   - For each entry, rename `displayLayout` → `monitors`
   - Write to `config.yaml` via `YAMLEncoder`
   - Remove `config.json`
   - Return the migrated store
3. If neither exists → return empty store as before.

---

## Edge Cases

| Scenario | Behavior |
|----------|----------|
| `displayplacer` not installed | `save-monitors` / `restore-monitors` returns PRECONDITION, `fingerprint` falls back to current positional fingerprint (backward-compatible) |
| First run after migration | Old `config.json` read → YAML written → JSON deleted → next reads use YAML |
| Hand-edited YAML with wrong key | `loadConfigStore()` won't match fingerprint → no saved config for this arrangement → PRECONDITION (same as now) |
| Mixed monitor sets (laptop + dock) | Each unique UUID set gets its own YAML block key; restore picks the right one automatically |
| Yams fail to decode | Treated as corrupt file → backed up → returned as empty store (same error handling as JSON) |
