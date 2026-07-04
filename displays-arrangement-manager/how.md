# macOS Displays Arrangement — Backup & Restore

## Where it lives

The display arrangement (positions, rotations, resolutions, mirroring) is stored in:

```
~/Library/Preferences/ByHost/com.apple.windowserver.displays.<system-uuid>.plist
```

The `<system-uuid>` is the machine's hardware UUID (find with `ioreg -d2 -c IOPlatformExpertDevice | grep IOPlatformUUID`).

On this Mac:

```
~/Library/Preferences/ByHost/com.apple.windowserver.displays.BC36AB00-7D83-50EF-9EA9-8A45165D4585.plist
```

## Current setup (this Mac)

| Display       | Resolution (panel) | UI looks like      | Hz   | Rotation | Note        |
|---------------|---------------------|---------------------|------|----------|-------------|
| LG ULTRAFINE  | 5120 × 2880 (5K)    | 2560 × 1440 (2×)    | 60   | 0°       | Main display |
| Display       | 1600 × 2560         | 1600 × 2560         | 60   | 90°      |             |
| EINK          | 1080 × 1920         | 1080 × 1920         | 60   | 270°     |             |
| EINK          | 1080 × 1920         | 1080 × 1920         | 60   | 90°      |             |

## Backup

```bash
cp ~/Library/Preferences/ByHost/com.apple.windowserver.displays.BC36AB00-7D83-50EF-9EA9-8A45165D4585.plist \
   ~/displays-arrangement-backup.plist
```

## Restore

```bash
cp ~/displays-arrangement-backup.plist \
   ~/Library/Preferences/ByHost/com.apple.windowserver.displays.BC36AB00-7D83-50EF-9EA9-8A45165D4585.plist \
   && killall cfprefsd
```

Then disconnect and reconnect displays, or log out and back in, or restart for the changes to take full effect.

## Inspect current state

```bash
# Human-readable overview
system_profiler SPDisplaysDataType

# Raw plist contents
plutil -p ~/Library/Preferences/ByHost/com.apple.windowserver.displays.*.plist
```
