# MacChargePower

A tiny native macOS menu-bar app that shows the **live wattage flowing into your Mac's battery** — the real charging power right now, not the charger's rated max.

It sits next to the clock as `⚡ 38W`, flashes a toast when you plug in or the wattage shifts, and opens an *Aurora Glass* detail card on click. No Dock icon, near-zero battery use.

## Why

`system_profiler` and the battery rating only tell you the charger's *maximum* (e.g. 100W). The number that actually matters — how fast your Mac is charging *right now* — lives in IOKit as `Voltage × Amperage` on the `AppleSmartBattery` node, and it drifts (58W → 8W) as the battery fills, the system load changes, or the cell warms up. This app surfaces exactly that.

## Features

- **Menu bar:** ⚡ + current charge watts while charging; a bolt when full; a slashed bolt on battery.
- **Detail card** (click the icon): big gradient watts, charge state + %, time-to-full, and a `CHARGER · VOLTS · AMPS` row. A liquid aurora fill rises behind it to show how much of the charger's negotiated ceiling you're currently pulling.
- **Toast:** flashes top-center on plug-in, charge start, or a ≥10W shift — visible even when the icon is hidden behind the notch / menu-bar overflow.
- **Charger ceiling from the PD handshake:** read live from `AdapterDetails` (negotiated `Voltage × Current`), so it's individual per charger (65W, 100W…) and reflects cable/port limits, not just the printed rating.
- **Low power:** event-driven via `IOPSNotificationCreateRunLoopSource`; only polls (every 2s) while plugged in, zero timers on battery.

## Stack

- **Swift 6**, single file (`Sources/main.swift`), no dependencies or package manager.
- **AppKit** shell — `NSStatusItem`, a borderless `NSPanel`/`NSWindow`, running as an `.accessory` agent.
- **SwiftUI** content (the Aurora Glass card + toast) bridged in via `NSHostingView` — gradients, `.ultraThinMaterial` blur, `TimelineView` animations, a custom `Shape` for the arrow.
- **IOKit** (`AppleSmartBattery` IORegistry) + **IOKit.ps** notifications for the data.
- Built with `swiftc` and a shell script (no `.xcodeproj`), ad-hoc signed.

## Build & run

```sh
./build.sh run
```

Builds `build/MacChargePower.app` and launches it. `./build.sh` alone just builds.

Inspect the raw reading without the GUI:

```sh
build/MacChargePower.app/Contents/MacOS/MacChargePower --print
```

## Launch at login

System Settings → General → Login Items → **＋** → pick `build/MacChargePower.app`.

## Requirements

macOS 13+ (developed on macOS 26), a Mac with a battery, and the Swift toolchain (Xcode or Command Line Tools). No Xcode project required.

## License

[MIT](LICENSE) © Steffen Behn
