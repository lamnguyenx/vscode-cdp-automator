# How macOS Assigns Monitor Names

`NSScreen.localizedName` is the display name macOS exposes to applications. It appears in System Settings → Displays. Note that `system_profiler SPDisplaysDataType` prints only the base name (e.g. `EINK`) without the `(N)` de-duplication suffix, so it cannot be used to cross-check suffixed fingerprints.

## Heuristic

macOS derives the name from **EDID** data:

1. **Primary name** — `ProductName` field in the monitor's EDID block (e.g. `EINK`, `LG ULTRAFINE`).
2. **De-duplication suffix** — When multiple monitors share the same `ProductName`, macOS appends `(1)`, `(2)`, etc. The exact assignment rule is undocumented: empirically the suffix does **not** follow IORegistry discovery order or `CGDirectDisplayID` order (one snapshot observed `(1)→ID 2, (2)→ID 10, (3)→ID 9, (4)→ID 3`); it appears to follow WindowServer's framebuffer registration order. This order is **not guaranteed stable** across reboots or dock reconnections.
3. **Transport does not change the name** — The name comes from the EDID regardless of transport; HDMI, DisplayPort, and DisplayLink passthrough all yielded `EINK` on the same machine. What differs per transport is the IORegistry node path (`BranchDeviceID`, e.g. `pHDMIg` for HDMI vs `176GB0` for DisplayPort).

## Why the number suffix changes

The suffix `(1)`–`(N)` appears to be assigned by framebuffer registration order in `WindowServer` (not by IORegistry or display-ID order). Any of these change the order:

- **DisplayLink reconnection** — DisplayLink can reassign persistent UUIDs on reboot or dock hot-plug because the USB topology can shuffle (the earlier UUID-based fingerprint suffered from this).
- **HDMI vs USB-C boot** — If macOS detects displays in a different order during boot vs. resume from sleep, the suffixes renumber.
- **Dock hot-plug** — Physically detaching/reattaching a dock can re-enumerate its downstream displays in a different order than before.

## Fingerprint stability in this project

The config fingerprint is now **name-only** (sorted alphabetically, e.g. `EINK (1)\nEINK (2)\n...\nLG ULTRAFINE`). This is more stable than UUID-based keys because:

| Key scheme | Changes on | Stable? |
|------------|-----------|---------|
| Persistent UUID | DisplayLink reconnection, macOS monitor DB reset | ❌ No |
| Name (sorted) | Adding/removing a monitor type, EDID renaming | ✅ Mostly — only breaks on physical changes |
| Name + UUID (old) | Both of the above | ❌ No |

## Tracing the connection topology

To map monitor names to physical ports, use a combination of:

```bash
# macOS display list (shows names)
system_profiler SPDisplaysDataType

# displayplacer (shows UUIDs + serials + types)
displayplacer list

# USB tree (shows DisplayLink vs direct)
ioreg -p IOUSB -l -w0 | grep -E "kUSBProductString|DisplayLink|Dock"

# DP/HDMI sink metadata (shows BranchDeviceID + DFP type + EDID ProductName per port)
ioreg -lw0 | grep -E '"BranchDeviceID"|"DFP Type Description"|"ProductName"'
```

DisplayLink-connected monitors go through a virtual framebuffer driven by `DisplayLinkUserAgent`. They typically get a fallback serial number (`s1` in `displayplacer` output, though not universal — some can still show distinct serials) and rotate persistent UUIDs on reconnection. Direct HDMI/USB-C connected monitors keep stable serial numbers and unique UUIDs.

This repository's displayplacer list output and `system_profiler` data at `last-saved-config` time is archived alongside the config at `~/.config/vscode-cdp-automator/config.yaml` (the `monitors:` block).
