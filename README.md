# Ambeo Companion

[English](README.md) | [日本語](README.ja.md)

A macOS menu bar application designed for seamless control and integration with the Sennheiser AMBEO Soundbar Mini (Plus and Max are unverified).

It resolves volume adjustment limitations in macOS eARC / HDMI passthrough setups, providing keyboard media key integration, automatic Dolby Atmos volume compensation, auto-standby (Eco Standby) control and force wake-up during idle silence, on-screen display (OSD), and global shortcut support.

---

## Features

- **Media Key Integration & Volume Sync**:
  - Intercepts volume keys (Volume Up, Volume Down, Mute) from Apple Magic Keyboards and Mac keyboards, synchronizing them in real time with the AMBEO Soundbar's hardware volume—which cannot typically be controlled via eARC from macOS.
- **macOS-Native HUD / OSD (On-Screen Display)**:
  - Displays a clean HUD resembling the native macOS volume indicator whenever volume or sound modes are changed.
  - Detects external adjustments made via the physical remote, hardware buttons, or Web UI in real time using long polling, immediately reflecting them on the OSD.
  - Graphically displays front-LED-style AMBEO logo, Night Mode (purple LED matching the physical unit), Voice Enhancement, Eco Mode, Auto Standby, and power status.
  - Smoothly tracks the active screen in multi-monitor setups with fluid fade animations.
- **Atmos Boost (Automatic Dolby Atmos Volume Compensation)**:
  - Automatically boosts playback volume by a configurable amount (0–40%) during Dolby Atmos playback, eliminating noticeable volume drops when switching between Dolby Atmos (Spatial Audio) and stereo PCM tracks in mixed playlists.
- **Fallback Audio Format Control**:
  - Automatically falls back to a designated format (e.g., 48 kHz 2ch) when Dolby Atmos is not playing, preventing macOS from defaulting to 192 kHz and causing unnecessary processing overhead or latency.
- **Auto Standby Control & Automatic Sync (Fixes Idle Sleep Issues)**:
  - Allows direct configuration of the auto-standby timeout (Off / 5 min / 10 min / 15 min / 30 min) from the settings window, an option hidden in the official Smart Control app and Web UI due to regulations (such as EU ErP directives).
  - Fundamentally solves the PC issue where the soundbar enters Eco Standby after a period of silence and stops outputting audio over HDMI/eARC, by setting it to "Off (Never)".
  - Persisted in the app settings; even if the soundbar's standby timeout is reset after powering off or a firmware update, the app automatically enforces and synchronizes your desired setting on launch and reconnection.
- **Wake Up Soundbar (One-Click & One-Key Force Wake)**:
  - Instantly wakes the soundbar and restores HDMI TV audio with a single action—via the menu bar "Wake Up Soundbar" item or an assigned global shortcut—even if the soundbar has entered Eco Standby and severed the HDMI/eARC audio link.
  - Eliminates the need for manual workarounds such as toggling between AirPlay and HDMI.
- **Global Shortcuts**:
  - Assign customizable hotkeys to control key functions at any time:
    - Wake Up Soundbar (Instantly wake from standby and restore HDMI)
    - Toggle AMBEO 3D Mode (On / Off)
    - Cycle AMBEO 3D Level (Light / Standard / Boost)
    - Switch Sound Presets (Adaptive, Music, Movie, News, Neutral, Sports)
    - Toggle Night Mode (On / Off)
    - Toggle Voice Enhancement (On / Off)
- **Launch at Login**:
  - Fully compliant with macOS 13+ `ServiceManagement` (`SMAppService.mainApp`). Easily enable background launch at Mac startup with a single click in Settings.
- **mDNS Device Auto-Discovery**:
  - Automatically discovers AMBEO Soundbars on the local network, allowing instant connection without manually specifying an IP address.

---

## Requirements

- **OS**: macOS 14.0 (Sonoma) or later
- **Swift / Xcode**: Swift 6.0+ / Xcode 16+
- **Supported Devices**: Sennheiser AMBEO Soundbar Mini / Plus / Max (Plus and Max are unverified)

---

## Build & Packaging

Build using SPM (Swift Package Manager). Xcode is not required.

### 1. Debug Run

```bash
swift run AmbeoCompanion
```

### 2. Debug Build

```bash
swift build
```

### 3. Release Build
```bash
swift build -c release --product AmbeoCompanion
```

### 4. Package macOS App Bundle (`AmbeoCompanion.app`)
Run the included packaging script to compile the release build, bundle resources, and apply ad-hoc code signing automatically:

```bash
swift Scripts/PackageApp.swift
```

What the script does:
1. Builds an optimized binary via `swift build -c release --product AmbeoCompanion`
2. Creates the standard `AmbeoCompanion.app` bundle structure (`Contents/MacOS`, `Contents/Resources`)
3. Copies the executable, `Info.plist`, app icon (`AppIcon.icns`), and dependency package resources (`KeyboardShortcuts_KeyboardShortcuts.bundle`)
4. Applies ad-hoc code signing with `codesign --deep --force --options runtime --sign - AmbeoCompanion.app`

### 4. Launching the App
The generated app bundle can be launched directly:

```bash
open AmbeoCompanion.app
```

### 5. Install to `/Applications`
The following script handles building, signing, copying to `/Applications/AmbeoCompanion.app`, and resetting privacy permissions that are invalidated by re-signing:

```bash
Scripts/install.sh
```

Capturing media keys requires both **Accessibility** (active event tap to intercept and consume events) and **Input Monitoring** (observing keys). The script resets both TCC registrations and opens the respective System Settings panes. Because macOS does not permit scripts to toggle these switches automatically, please enable them manually in the displayed settings windows.

---

## Required Permissions & Security Settings

Volume keys from Magic Keyboards or Macs are captured via `CGEventTap`, consumed, and forwarded to the AMBEO Soundbar. This requires both of the following permissions:

- **System Settings > Privacy & Security > Accessibility**
- **System Settings > Privacy & Security > Input Monitoring**

If `AmbeoCompanion.app` is not listed, click `+` to add `/Applications/AmbeoCompanion.app` and toggle the switch on.

Every time the app is rebuilt, its ad-hoc signature checksum changes, which invalidates existing permissions even if the toggles appear on. Running `Scripts/install.sh` will reset both registrations and open the settings panes in sequence. If media keys do not work, run the script or toggle the switches off and back on in each pane.

---

## Regenerate App Icon (Optional)

To modify or regenerate the app icon, run the vector generation script to automatically produce a multi-resolution `.icns` file from a 1024x1024 PNG:

```bash
swift Scripts/GenerateAppIcon.swift
```

---

## License

[MIT License](LICENSE)
