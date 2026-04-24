# Comprehensive Codebase Audit

After a thorough review of the codebase architecture, concurrency model, log processing, and UI layers, I have identified several structural gaps, data-loss risks, and unhandled edge cases.

## 1. UI & Overlay Lifecycle Bugs
* **The Invisible Window Bug (Hearthstone Status Toggle)**
  - **Location:** `HSHelperApp.swift` (`startObservingGameController`)
  - **Issue:** When Hearthstone is closed, the app hides the overlays and sets `lastPhase = nil`. When Hearthstone re-opens, `isRunning` flips to `true`, but `phase` is also `nil`. The conditional `else if phase != lastPhase` evaluates to `false`. 
  - **Impact:** The app never calls `showOverlays()` again until a new game actually starts. The Waiting for game... window vanishes permanently while the user is on the main menu, making them think the app crashed.
* **AppPreferences Observability Mismatch**
  - **Location:** `HSHelperApp.swift` & `AppPreferences.swift`
  - **Issue:** `AppPreferences` is an `ObservableObject`, but `HSHelperApp` holds it as a plain `private let prefs = AppPreferences.shared` rather than using `@ObservedObject`. 
  - **Impact:** Changing settings like `overlayLocked` from the `SettingsView` updates the boolean but never triggers the UI layout refresh or passes the new `isLocked` state to the `OverlayController`, decoupling settings from reality.
* **Drag Operation Micro-stutters**
  - **Location:** `OverlayPanel.swift` (`saveFrameIfNeeded`)
  - **Issue:** The drag modifier calls `move(by:)` 60 times a second. Every single call triggers `saveFrameIfNeeded()`, which synchronously writes to `UserDefaults.standard`.
  - **Impact:** Causes micro-stuttering during dragging due to excessive continuous disk I/O.

## 2. Parsing & Data Loss Risks
* **UTF-8 Chunk Boundary Data Loss**
  - **Location:** `HSLogTailer.swift` (`readNewBytes`)
  - **Issue:** The tailer reads raw log data in 64KB chunks (`chunkSize = 65_536`) and blindly decodes it using `String(data: newData, encoding: .utf8)`. If Hearthstone writes a multi-byte Unicode character (e.g., Cyrillic deck names like `### фиракк`) and the 64KB boundary splits that character perfectly in half, the Swift `.utf8` conversion evaluates to `nil`.
  - **Impact:** The tailer will silently abort reading that entire chunk, permanently dropping game data and freezing the tracker for that match.
* **Main Thread Flooding**
  - **Location:** `GameReducer.swift` (`start`)
  - **Issue:** The asynchronous stream `for await line in stream` processes lines one by one. For every single line, it spawns an `await MainActor.run { ... }` block to parse and dispatch the event. 
  - **Impact:** A standard 3MB `Power.log` contains ~30,000 lines. On app launch or reconnect, the app fires 30,000 sequential `MainActor` dispatches, which will severely flood the main thread and freeze the UI.
* **Log Tailer Polling State Lockout**
  - **Location:** `HSLogTailer.swift` (`checkLogPathChanged`)
  - **Issue:** The active polling timer checks if Hearthstone has generated a new log directory. However, the check requires `!activeLogPath.isEmpty`. If the app is launched *before* Hearthstone, `activeLogPath` is empty. 
  - **Impact:** The polling timer will ignore the newly created log directory, forcing the app to rely entirely on an unmanaged backup retry loop.

## 3. Network & Persistence Flaws
* **Blocking Network Fetch & Lack of Retries**
  - **Location:** `CardDB.swift` (`load`)
  - **Issue:** If the `cards.collectible.json` cache is missing (e.g., fresh install), the app immediately halts to await `fetchFromNetwork`. If the network call times out or fails, `CardDB` throws an error and leaves the database completely empty. There is no automated retry mechanism.
  - **Impact:** If the user opens the app offline once, the entire tracker becomes permanently bricked until they restart the app with a stable connection.
* **Zombie Window Objects in AppKit**
  - **Location:** `OverlayPanel.swift` (`tearDown`)
  - **Issue:** When overlays are torn down, the code nullifies the `panel` reference but never explicitly calls `.close()`. Because the panel initializes with `isReleasedWhenClosed = false`, the object stays alive in AppKit window hierarchy.
  - **Impact:** If overlays are aggressively cycled, it creates memory leaks consisting of hidden, detached NSPanels.

## 4. UI Missing Data Hooks
* **Missing Deck Name in UI**
  - **Location:** `DeckTrackerView.swift`
  - **Issue:** The custom side-panel redesign successfully renders the UI, but hardcodes the title as `PanelHeader(title: "Deck", ...)`. The parser successfully extracts the deck name from `Decks.log` (`game.player.deckName`), but it is never actually piped into the View.

