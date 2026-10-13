# FindandClean

Native macOS utility that combines **auto uninstall** with **find any file search system** - **in one!**, reveal in Finder, and Trash.

![FindandClean](<img width="2092" height="1176" alt="iScreen Shoter - 20261013183456824" src="https://github.com/user-attachments/assets/e3794a2b-a809-4fca-acef-dd0dbdde8ec9" />)

## Download

Grab the latest DMG from [Releases](../../releases) or open:

`dist/FindandClean-1.0.dmg`

Drag **FindandClean** into **Applications**, then grant **Full Disk Access** (required for `~/Library/Biome` and other protected folders).

## Requirements

- macOS 13 or later
- **Full Disk Access** for reliable deep search

### Grant Full Disk Access

1. System Settings → Privacy & Security → Full Disk Access  
2. Enable **FindandClean** (add with + if needed)  
3. Quit and reopen the app  

Sandbox is **off** so the app can scan and trash files across the filesystem.

## Open & run (from source)

```bash
open FindandClean.xcodeproj
```

Then Run (⌘R) in Xcode. Or:

```bash
xcodebuild -scheme FindandClean -configuration Release build
```

## Features

**Find Files (default)**
- Opens like Find Any File: search fills the window
- Foldable path tree with classic zebra stripes
- Live results while searching
- Roots: Home, Macintosh HD, Applications, or a custom folder
- Reveal in Finder, Open, Move to Trash (non-recursive selection)

**Uninstall (on demand)**
- Drop a `.app` onto the window to switch into duo mode
- Left: leftover scan / checklist; right: Find stays available
- Close Uninstall (✕) to return to Find-only

## Safety

- Apple / SIP system apps are blocked from leftover cleaning
- Application Support / Containers default unchecked and require confirmation
- Volume roots are refused
- Deletes go to Trash only (no permanent delete in v1)
