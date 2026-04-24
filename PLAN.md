# hs-helper — Native macOS Hearthstone Deck Tracker

**Goal:** A native, Apple-Silicon-first macOS app that mirrors the core value of HearthstoneDeckTracker (HDT): live in-game deck tracking, opponent card memory, mulligan assistant, and (stretch) HSReplay upload — all driven by Hearthstone's own log files, with zero memory reading or game hooking.

**Non-goals (v1):** Windows/Linux support, arena draft helper, battlegrounds, Twitch overlay, cloud sync.

---

## 1. How this actually works

HDT's architecture is log-driven. Hearthstone writes structured game-state logs to disk; the tracker tails them and reconstructs a model of the game. We do the same thing, natively.

### 1.1 Data source
- **Log folder:** `~/Library/Logs/Blizzard/Hearthstone/`
- **Key files:** `Power.log` (game state + cards), `Zone.log` (zone transitions), `Decks.log` (deck selection), `LoadingScreen.log` (scene).
- **Enablement:** Create/update `~/Library/Preferences/Blizzard/Hearthstone/log.config` with `[Power]`, `[Zone]`, `[Decks]`, `[LoadingScreen]` sections — `LogLevel=1`, `FilePrinting=true`, `ConsolePrinting=false`. The app installs this on first run.
- **Card data:** [HearthstoneJSON](https://hearthstonejson.com) (`cards.collectible.json`) + CDN card images. Cached locally, versioned per patch.

### 1.2 No game hooking
We never inject, never read HS memory, never call private APIs. This keeps us inside Blizzard's ToS (HDT operates the same way).

---

## 2. Architecture

Modular Swift package layout. Each module has one responsibility, one public surface, ~200–400 LOC target.

```
hs-helper/
├── App/                     # SwiftUI app entry, AppDelegate, lifecycle
├── Packages/
│   ├── HSLogTailer/         # File-tail primitive: GCD + FSEvents
│   ├── HSLogParser/         # Line → typed event (state machine)
│   ├── GameState/           # Pure-Swift reducer: events → Game model
│   ├── CardDB/              # HearthstoneJSON loader, image cache, search
│   ├── DeckStore/           # SwiftData: decks, deckstring codec, import
│   ├── Overlay/             # AppKit NSPanel overlay, floats over HS
│   ├── TrackerUI/           # SwiftUI views: deck list, opponent panel
│   ├── Settings/            # Preferences window, log.config installer
│   └── Replay/              # (stretch) HSReplay upload client
└── Tests/                   # Per-package XCTest + fixture logs
```

### 2.1 Data flow

```
Power.log ──► HSLogTailer ──► HSLogParser ──► GameState reducer ──► @Observable Game
                                                                         │
                                                                         ▼
                                                           Overlay (AppKit) + TrackerUI (SwiftUI)
```

- **One-way flow.** UI observes `Game`; never mutates it.
- **Reducer is pure.** Given `(Game, Event) → Game`. Trivially testable with recorded log fixtures.
- **Tailer is dumb.** Emits lines; knows nothing about cards.

### 2.2 Overlay window (the tricky part)

- `NSPanel` subclass with:
  - `level = .statusBar` (above `.floating`, below system UI)
  - `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]` — the `.fullScreenAuxiliary` flag is what lets it render over HS when HS is in Spaces-fullscreen
  - `styleMask = [.borderless, .nonactivatingPanel]`
  - `backgroundColor = .clear`, `isOpaque = false`, `hasShadow = false`
  - `ignoresMouseEvents = true` by default; toggled off only while user is dragging/resizing
- **Positioning:** persisted per monitor; "Lock overlay" toggle in menu bar.
- **Hearthstone window mode:** Borderless Windowed is fully supported. True exclusive fullscreen on macOS is rare for HS — if a user hits issues, docs point them to Borderless.
- **Metal compatibility:** SwiftUI-inside-NSPanel works because the panel is a plain layer-backed window; HS's Metal layer is in its own process. No CGWindowServer trickery needed.

### 2.3 State model (sketch)

```swift
struct Game {
    var matchID: UUID
    var format: Format           // standard | wild | classic | twist
    var mode: Mode               // ranked | casual | friendly | adventure
    var player: Side
    var opponent: Side
    var turn: Int
    var phase: Phase             // mulligan | main | gameOver
    var events: [GameEvent]      // append-only timeline, drives undo + replay
}

struct Side {
    var hero: Card?
    var deck: Deck?              // nil for opponent until cards are revealed
    var hand: [CardInstance]     // known + unknown slots
    var board: [CardInstance]
    var graveyard: [CardInstance]
    var cardsPlayed: [Card]
    var resources: Resources     // mana, health, armor, fatigue counter
}
```

---

## 3. Stack

| Concern | Choice | Why |
|---|---|---|
| Language | Swift 6 (strict concurrency) | Native, first-class on macOS, actor isolation fits our pipeline |
| UI | SwiftUI + AppKit (`NSPanel`) | SwiftUI for panels/settings, AppKit for overlay window behavior SwiftUI can't do |
| Persistence | SwiftData | Decks, settings, match history. Lightweight, no SQLite boilerplate |
| File tailing | `DispatchSource.makeFileSystemObjectSource` + `FileHandle` | Kernel-level, low CPU. FSEvents as fallback for rotation |
| HTTP | `URLSession` async/await | HearthstoneJSON fetch, HSReplay upload |
| Image cache | `NSCache` + disk LRU in `Application Support` | Card art, hero portraits |
| Distribution | Developer ID signed + notarized DMG | Bypasses Gatekeeper. No Mac App Store — we need broad file access under `~/Library/Logs/` |
| Min target | macOS 14 Sonoma | `@Observable`, SwiftData, modern concurrency |
| Build | Swift Package Manager + Xcode project | One workspace, SPM packages for modules |
| Tests | XCTest + recorded `.log` fixtures | Replay real games against the reducer |
| CI | GitHub Actions (macOS runners) | Build, test, sign, notarize on tag |

---

## 4. Phased plan

Built in thin vertical slices — each phase produces a runnable app, not a pile of scaffolding.

### Phase 0 — Spike (2–3 days)
Prove the two scariest unknowns before committing.
- [ ] Tail `Power.log` while a real HS match runs; dump lines to stdout.
- [ ] Draw a red rectangle `NSPanel` that stays visible over Hearthstone in Borderless Windowed.
- **Exit criteria:** can see log lines in real time AND see overlay pinned over HS. If either fails, reassess.

### Phase 1 — Own deck tracker (1–2 weeks)
The MVP. One user, one deck, live updates.
- [ ] `HSLogTailer`: file tail with rotation handling.
- [ ] `HSLogParser`: minimal subset — `CREATE_GAME`, `TAG_CHANGE`, `SHOW_ENTITY`, `FULL_ENTITY`, zone transitions.
- [ ] `GameState` reducer: tracks own deck, own hand, cards drawn.
- [ ] `CardDB`: load HearthstoneJSON, lookup by `dbfId` / `cardId`.
- [ ] `DeckStore`: paste deckstring → stored deck. Swift port of HS deckstring codec (varint + base64).
- [ ] `Overlay` + `TrackerUI`: floating list of remaining cards, count badges, dim on draw.
- [ ] `Settings`: installs `log.config`, pick monitor, toggle lock.
- **Exit criteria:** start HS, play a match with a saved deck, see the card list decrement correctly in real time.

### Phase 2 — Opponent tracking (1 week)
- [ ] Extend reducer: opponent hand size, cards played, revealed cards, graveyard.
- [ ] Opponent panel on the right side of the screen.
- [ ] Fatigue counter, secrets tracker.
- **Exit criteria:** full match replay-from-log produces the correct final opponent-played list.

### Phase 3 — Mulligan + deck import (3–4 days)
- [ ] Detect mulligan phase; show deck odds overlay during it.
- [ ] Import from Hearthstone's in-game "Copy Deck" clipboard (auto-detect on launch).
- [ ] Deck editor: search, filter by class/cost, export deckstring.

### Phase 4 — Polish + ship (1 week)
- [ ] Match history view with won/lost, deck, opponent class, duration.
- [ ] Keyboard shortcuts, menu-bar item.
- [ ] Auto-update (Sparkle).
- [ ] Developer ID signing + notarization in CI.
- [ ] README, screenshots, DMG release.
- **Ship v1.**

### Phase 5 — Stretch
- [ ] HSReplay upload.
- [ ] Arena draft helper (HearthArena-style tier list).
- [ ] Battlegrounds MMR + hero picker.
- [ ] iCloud sync for decks.

---

## 5. Risks + mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| Log format changes on patch | Medium | Version-gate the parser; ship a hotfix path. Fixture corpus catches regressions. |
| Overlay fails in true fullscreen | Low-Medium | Default docs recommend Borderless; detect and warn. `.fullScreenAuxiliary` covers most cases. |
| HearthstoneJSON stops updating | Low | Fallback: pull from HearthSim's `python-hearthstone` data dumps, or scrape HS Press Kit. |
| Blizzard ToS shifts | Low | We read our own user's logs — same posture as HDT for 10+ years. Monitor ToS; no game hooks ever. |
| Apple Silicon / Intel parity | Low | Universal binary from day one. CI builds both. |
| Card art licensing | Medium | HearthstoneJSON links to Blizzard CDN assets; HDT precedent. Add a "remove images" fallback if ever challenged. |

---

## 6. Open questions (decide before Phase 1)

1. **App name + bundle ID.** `hs-helper` is the repo; need a real product name. Suggestion: something not-Blizzard-trademarked.
2. **Free / paid / donation?** Affects notarization cost amortization and whether we need a license server.
3. **Open source?** HDT is GPLv3. Going MIT/Apache vs. GPL changes what code we can port vs. must clean-room.
4. **Deck stats scope.** Just win/loss, or per-card mulligan stats like HSReplay? The latter is a lot more UI.
5. **Minimum macOS.** 14 (Sonoma) gives us `@Observable` and matters for perf; 13 widens audience. Lean 14.

---

## 7. Effort estimate

Solo dev, part-time:
- Phase 0: **3 days**
- Phase 1: **2 weeks**
- Phase 2: **1 week**
- Phase 3: **4 days**
- Phase 4: **1 week**
- **Total to v1: ~5 weeks.**

Full-time, experienced Swift + one prior log-parsing project: ~3 weeks to v1.

---

## 8. First concrete steps

1. Answer the 5 open questions in §6.
2. Spin up Xcode workspace + SPM package skeleton.
3. Phase 0 spike in a throwaway branch.
4. If spike passes: tag `v0.0.1-spike`, start Phase 1 for real.
