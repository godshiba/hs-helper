# hs-helper

**hs-helper** is a native, lightweight, and blazingly fast Hearthstone deck tracker for macOS. It is written completely in Swift 6 and SwiftUI, and optimized for macOS 15+. 

Instead of dealing with clunky Electron apps or heavy cross-platform frameworks, `hs-helper` runs natively in your menu bar (as an `.accessory` app with no Dock icon) and provides a clean, transparent overlay floating directly on top of the Hearthstone client.

## Features
- **Zero UI Clutter:** Operates entirely from the macOS menu bar. No dock icon.
- **Real-Time Deck Tracking:** Parses `Power.log`, `Decks.log`, and `LoadingScreen.log` to track your remaining cards, your opponent's played cards, fatigue, and hand counts.
- **Battlegrounds Ready:** Aware of Hearthstone scenes and handles game mode parsing directly from the logs.
- **Extremely Low Memory Footprint:** Built natively with Swift's structured concurrency (`async/await`, `actors`) for pure, minimal overhead.
- **Multilingual Support:** Localizes the interface dynamically based on your Hearthstone language preference.

## Requirements
- macOS 15.0 or later
- Swift 6.0
- Hearthstone installed at `/Applications/Hearthstone` (default location)

## How to Build & Run

`hs-helper` is packaged as an SPM-only (Swift Package Manager) project. There is no `.xcodeproj` file needed to build it, though you can easily open it in Xcode.

```bash
# Clone the repository
git clone https://github.com/yourusername/hs-helper.git
cd hs-helper

# Build the project (debug mode)
swift build

# Run the app directly from terminal
swift run App

# Run the test suite
swift test
```

If you prefer Xcode, simply open the `Package.swift` file in Xcode or type `xed .` in your terminal.

## Architecture
This project implements a unidirectional data flow and separates pure parsing logic from UI rendering:

1. **`HSLogTailer`:** Uses `DispatchSourceFileSystemObject` to safely tail log files in real-time, yielding a pure `AsyncStream<String>`.
2. **`HSLogParser`:** A fast state machine that processes raw strings into strongly-typed `LogEvent` structs (zero I/O).
3. **`GameReducer` & `GameController`:** Applies `LogEvent` items against a `Game` state struct. The `@Observable @MainActor` GameController acts as the single source of truth for the views.
4. **`TrackerUI`:** SwiftUI overlays that solely observe the `GameState`—they never mutate it directly.

See [`CLAUDE.md`](CLAUDE.md) for deeper technical guidelines and architecture specifics.

## Configuration (log.config)
For `hs-helper` to track matches, Hearthstone must output logs. The app automatically attempts to configure this for you on launch by installing a standard `log.config` in `~/Library/Preferences/Blizzard/Hearthstone/`. If tracking isn't working, make sure Hearthstone was restarted after launching the tracker!

## Contributing
Pull requests, feature requests, and bug reports are welcome. Since we are targeting Swift 6, please ensure all async code conforms to the new strict concurrency checking guidelines.
