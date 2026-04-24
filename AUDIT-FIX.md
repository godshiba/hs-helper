# MVP Audit Fixes & Implementation Guide

This document wires directly to `AUDIT.md` and provides the exact technical solutions to achieve a flawless MVP. It explicitly ignores out-of-scope issues (like reconnects or alternate modes) and introduces fixes for modern deckstring sideboards (E.T.C. / Zilliax).

---

## 1. UI & Overlay Lifecycle Bugs

### 1.1 The "Invisible Window" Bug
**Problem (`AUDIT.md` 1.1):** Overlays disappear forever if Hearthstone is closed and reopened because of `nil` phase checking.
**The Fix (in `HSHelperApp.swift`):**
Modify `startObservingGameController()`. When transitioning from `!isRunning` to `isRunning`, explicitly force a UI refresh.
```swift
if !isRunning {
    // Hide logic...
} else if phase != lastPhase || !wasRunning {
    await MainActor.run { self.handlePhaseChange(phase: phase) }
    lastPhase = phase
}
```
*Result:* The "Waiting for game..." overlay successfully reappears when Hearthstone launches.

### 1.2 AppPreferences Observability Mismatch
**Problem (`AUDIT.md` 1.2):** Settings changes (like locking the overlay) aren't triggering UI updates.
**The Fix (in `HSHelperApp.swift`):**
Change the property declaration to strictly observe changes.
```swift
// Change this:
private let prefs = AppPreferences.shared

// To this:
@ObservedObject private var prefs = AppPreferences.shared
```
*Result:* Checkboxes in Settings instantly affect the running overlays.

### 1.3 Drag Operation Micro-stutters
**Problem (`AUDIT.md` 1.3):** Disk writes on every pixel dragged causing UI lag.
**The Fix (in `OverlayPanel.swift`):**
In `DraggableOverlayModifier`, only call `onDragEnded` (which saves to disk) inside `.onEnded`. During `.onChanged`, merely update the `dragOffset`. Remove `saveFrameIfNeeded()` from `move(by:)` and put it exclusively in `move(to:)` or a new `save()` function triggered on drag end.

---

## 2. Parsing & Data Loss Risks

### 2.1 UTF-8 Chunk Boundary Data Loss
**Problem (`AUDIT.md` 2.1):** 64KB log chunks splitting multi-byte unicode characters, causing `.utf8` to fail and drop logs.
**The Fix (in `HSLogTailer.swift`):**
Instead of blindly converting `Data` to `String`, use a rolling `Data` buffer. Find the last newline character (`
`) byte. Decode only up to that byte, and save the remaining incomplete bytes to prepend to the next read.
*Result:* Cyrillic characters and emojis in deck names will never break the tailer.

### 2.2 Main Thread Flooding
**Problem (`AUDIT.md` 2.2):** 30,000 log lines dispatched to `MainActor` individually during setup.
**The Fix (in `GameReducer.swift`):**
Parse the line *off* the main thread.
```swift
let events = parser.process(line: prefix + line)
if !events.isEmpty {
    await MainActor.run {
        for event in events { self.handleEvent(event) }
    }
}
```
*(Note: Ensure `HSLogParser` is instantiated per-tailer task so it doesn't cross actor boundaries unsafely).*

### 2.3 Log Tailer Polling State Lockout
**Problem (`AUDIT.md` 2.3):** App doesn't track logs if opened before Hearthstone.
**The Fix (in `HSLogTailer.swift`):**
Remove the strict condition in `checkLogPathChanged()`.
```swift
// Change:
if !activeLogPath.isEmpty && newPath != activeLogPath 

// To:
if newPath != activeLogPath { ... }
```
*Result:* Launch order no longer matters. App automatically latches onto HS when it opens.

---

## 3. Sideboards & Complex Deckstrings (E.T.C., Zilliax)

### 3.1 DeckstringCodec Fails on Modern Decks
**Problem (New):** The Varint decoder crashes or miscounts cards when encountering Sideboards (nested arrays for E.T.C. Band Manager or Zilliax modules).
**The Fix (in `GameReducer.swift` -> `DeckstringCodec`):**
Hearthstone deckstrings appended a new `Sideboard` segment after standard cards. Update the decoder logic:
```swift
// After reading standard single/double/N-count cards:
if reader.hasBytes {
    let hasSideboards = try reader.next()
    if hasSideboards == 1 {
        let sideboardCount = try reader.next()
        for _ in 0..<sideboardCount {
            _ = try reader.next() // Owner DBFID (e.g., E.T.C.)
            let cardsInSideboard = try reader.next()
            for _ in 0..<cardsInSideboard {
                let sId = try reader.next()
                let sCount = try reader.next()
                pairs.append((sId, sCount)) // Add sideboard cards to main tracking pool
            }
        }
    }
}
```
*Result:* Zilliax and E.T.C. bands will successfully parse and show up in the tracker!

---

## 4. Network & Persistence Flaws

### 4.1 Blocking Network Fetch 
**Problem (`AUDIT.md` 3.1):** Fails permanently on bad internet.
**The Fix (in `CardDB.swift`):**
Wrap the `fetchFromNetwork` call in a simple 3-attempt retry loop with `Task.sleep` before throwing the fatal error.

### 4.2 Zombie Window Objects in AppKit
**Problem (`AUDIT.md` 3.2):** Overlays remain in memory after teardown.
**The Fix (in `OverlayPanel.swift`):**
Update `tearDown()`:
```swift
public func tearDown() {
    saveFrameIfNeeded()
    panel?.close() // Explicit AppKit destruction
    panel = nil
    ...
}
```

### 4.3 Missing Deck Name in UI
**Problem (`AUDIT.md` 4.1):** Hardcoded "Deck" title.
**The Fix (in `DeckTrackerView.swift`):**
Pass the tracked deck name to `PanelHeader`.
```swift
// Game.swift must hold the name:
public var deckName: String?

// GameReducer.swift:
case .deckSelected(let deckstring, let name):
    currentGame?.player.deckName = name

// DeckTrackerView.swift:
PanelHeader(title: game.player.deckName ?? "Deck", ...)
```

---
**Implementation Strategy for MVP:**
1. Apply **1.1** and **2.3** first to ensure robust connections.
2. Apply **3.1** to guarantee standard tracker integrity (cards).
3. Apply **2.1** to eliminate silent crash points.
4. Clean up **1.3** and **4.2** for UI polish.

