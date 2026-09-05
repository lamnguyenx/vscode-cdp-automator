# Monitor Layout Rules

**Date:** 2026-09-05
**Status:** Implemented

---

## Goal

Add a **monitor layout rules** feature: when a set of persistent display UUIDs is present and no saved `monitors:` snapshot exists for the current fingerprint, the system applies a declarative rule to arrange those monitors at fixed positions/rotations. This bootstraps a known-good layout for unsaved monitor arrangements.

---

## Motivation

The user has 3 EINK portrait monitors (EINK 1, 4, 2) that they always want arranged in a horizontal row at specific coordinates and rotations, regardless of what other monitors are connected. Without a saved snapshot for the current fingerprint (e.g., after a reboot or dock hot-plug that macOS shuffled), the old code reported `PRECONDITION` — the user had to manually position them. A rule automates this.

---

## Rule Storage

A new reserved top-level key `rules` in `~/.config/vscode-cdp-automator/config.yaml`, alongside the existing fingerprint blocks. Not migrated from anywhere; hand-edited.

### Example

```yaml
rules:
  - name: eink-row
    match:
      all_of:
        - 12DF9D18-D36A-4B71-B782-384E1AA1DDA7
        - CA80224C-2647-4420-8DC2-2CC0F710BC17
        - 4E09C07E-CA1F-461A-B1A8-EDC759F564CE
    layout:
      type: row
      origin: { x: -1080, y: 0 }
      members:
        - { id: 12DF9D18-D36A-4B71-B782-384E1AA1DDA7, rotation: 90,  width: 1080 }
        - { id: CA80224C-2647-4420-8DC2-2CC0F710BC17, rotation: 90,  width: 1080 }
        - { id: 4E09C07E-CA1F-461A-B1A8-EDC759F564CE, rotation: 270, width: 1080 }
```

Member `i` gets `x = layout.origin.x + Σ(width[0..i-1])`, `y = layout.origin.y`.

---

## Behavior

| State of current fingerprint | `restore-monitors` does |
|---|---|
| Has `monitors:` snapshot | Replays snapshot (current behavior; rule not consulted) |
| No snapshot, ≥1 rule's `all_of` satisfied by connected UUIDs | First matching rule fires: rule members get `origin`/`rotation` from rule; all other monitors keep their live `resolution`/`hertz`/`color_depth`/`scaling` (whatever macOS left them at). Rules evaluated in declaration order; first match wins. |
| No snapshot, no rule matches | `PRECONDITION` exit (current behavior) |

After a rule fires, user runs `save-monitors` to lock in the full arrangement (including non-rule monitors). Going forward, the snapshot path takes over and the rule stays dormant for that fingerprint.

---

## New Config Store Structure

Top-level `config.yaml` now uses a `ConfigFile` wrapper to hold both dynamic fingerprint keys and the reserved `rules` key. The wrapper uses a custom `AnyKey: CodingKey` helper for dynamic-key container encoding/decoding.

```yaml
rules:
  - name: eink-row
    ...

? 'fingerprint1...'
: monitors: ...

? 'fingerprint2...'
: monitors: ...
```

`loadConfigStore()` returns `[String: DisplayConfig]` (just arrangements) — existing callers unchanged. A new `loadConfigRules()` returns `[MonitorRule]`. `saveConfigStore()` reads existing rules from disk and writes back `ConfigFile(arrangements:, rules: existingRules)`.

---

## Changes per File

### 1. `ConfigStore.swift` (~80 LOC added)

- **New Codable structs:**
  ```swift
  struct MonitorRule: Codable {
      var name: String?
      var match: MonitorRuleMatch
      var layout: MonitorRuleLayout
  }
  struct MonitorRuleMatch: Codable {
      var all_of: [String]
  }
  struct MonitorRuleLayout: Codable {
      var type: String
      var origin: MonitorOrigin
      var members: [MonitorRuleMember]
  }
  struct MonitorRuleMember: Codable {
      var id: String
      var rotation: Int
      var width: Int
  }
  ```
- **`ConfigFile` Codable** — holds `var rules: [MonitorRule]` + `var arrangements: [String: DisplayConfig]`. Custom `init(from:)` decodes `rules:` as the reserved key and everything else as arrangements.
- **`AnyKey: CodingKey`** — helper for dynamic-key decoding.
- **`loadConfigRules() -> [MonitorRule]`** — loads just the rules block.
- **`saveConfigStore(_:)`** — read-modify-write: reads existing rules from disk via `loadConfigRules()`, writes `ConfigFile`.
- **`loadConfigStore()`** — decodes `ConfigFile`, returns `.arrangements`.

### 2. `Orchestration.swift` (~50 LOC added)

- **`readCurrentDisplays() -> [MonitorEntry]`** — runs `displayplacer list`, parses via existing `parseDisplayplacerList()`.
- **`applyRule(_ rule:, to current: [MonitorEntry]) -> [MonitorEntry]`** — returns input list with rule members' `origin`/`rotation` overridden; remaining fields copied through.
- **Extract `runDisplayplacer(_:) -> Int32`** from the current inline displayplacer exec in `cmdRestoreDisplayLayout`.
- **Restructure `cmdRestoreDisplayLayout()`:**
  1. Load config, compute fingerprint.
  2. If snapshot exists → `runDisplayplacer(snapshot.displays)` (unchanged).
  3. Else → read current displays, iterate rules. First match → `runDisplayplacer(applyRule(rule, to: current))`. Verbose log.
  4. Else → PRECONDITION.

### 3. `main.swift`

No new CLI commands. Rule is transparent.

### 4. `README.md`

New "Monitor Rules" subsection under "How it works": schema, firing condition, rule evaluation order, caveats.

---

## Edge Cases

| Scenario | Behavior |
|---|---|
| Existing `config.yaml` has no `rules:` key | Decodes as empty array. No migration needed. |
| Typo in rule UUID | Rule won't match any connected display → silently skipped. |
| Rule `width:` doesn't match actual display size | Slot positions drift by cumulative error. User notices on first restore and fixes. |
| Multiple rules, first doesn't match | Second rule checked; first match wins. |
| All 3 EINKs present + other monitors | Rule only touches the 3; others keep macOS default positions. |
| Only 2 of the 3 present | Rule's `all_of` unsatisfied → not fired. |
| After rule fires but before save, user runs `restore-monitors` again | Rule fires again (same behavior). |
| After rule fires and user runs `save-monitors`, runs `restore-monitors` | Snapshot path takes over; rule dormant. |

---

## Testing

1. **Snapshot path unchanged** — saved fingerprint with `monitors:` entry replays as before; no rule log.
2. **Rule fires on new fingerprint** — rename current fingerprint key (or disconnect a monitor), add `rules:` block, run `restore-monitors --verbose`. Expect rule-firing log, row at `x ∈ [−1080, 2160], y=0`.
3. **Partial match skipped** — ensure only 2 of the 3 EINK UUIDs present → PRECONDITION.
4. **Non-rule monitors untouched** — place LG at unusual spot; after rule fires, LG stays there.
5. **YAML roundtrip** — after rule fires and `save-monitors`, config.yaml has both `rules:` and fingerprint block, re-parses cleanly.

---

## Out of Scope

- No CLI command to add/edit rules (hand-edit YAML).
- No EINK 3 rule.
- No auto-save after rule fires (intentional — user inspects then saves).
- No changes to `save-all` flow.
