# hs-helper — Native macOS Hearthstone Deck Tracker

**Goal:** A native, Apple-Silicon-first macOS overlay that gives you everything HDT gives Windows users — live deck tracking, opponent memory, game stats — driven purely by Hearthstone's log files. Zero memory reading, zero game hooking.

---

## Current State (as of April 2026)

The app is feature-complete for core tracking. All major HDT patterns have been ported.

### What works today

| Area | Status |
|---|---|
| Log tailing (Power, Zone, Decks, LoadingScreen) | Done |
| Full entity/tag/block reducer | Done |
| Own deck panel — remaining cards, x2 badge, draw highlight | Done |
| Generated cards (shuffled mid-game) — GEN label, live count | Done |
| Wild mode local-player detection (post-deck-load re-verify) | Done |
| New game detection and auto-reset between games | Done |
| Opponent panel — cards played, last played, hand count, fatigue | Done |
| Opponent panel — known hand cards (IN HAND section) | Done |
| Entity.info.created / stolen flags | Done |
| Game counters — spells, minions played/killed, cards drawn | Done |
| Stats persistence — GameRecord JSON to Application Support | Done |
| Menu bar status item | Done |
| Overlay NSPanel (floats over HS, drag to reposition, lock) | Done |
| Preferences window | Done |
| log.config auto-installer | Done |
| CardDB — HearthstoneJSON load, card lookup by ID and dbfId | Done |
| DeckStore — deckstring codec, SwiftData persistence | Done |

---

## Architecture

```
Power.log ──► HSLogTailer ──► HSLogParser ──► apply(event:to:) ──► Game (value type)
                                                                        │
                                                              GameController (@Observable)
                                                                        │
                                                    ┌───────────────────┴───────────────────┐
                                               OwnDeckPanel                         OpponentPanel
                                           (DeckTrackerView)                    (OpponentPanelView)
```

**Key design rules:**
- `apply(event:to:)` is a pure free function — no I/O, fully testable with log fixtures
- `GameController` is `@Observable @MainActor` — SwiftUI observes it directly
- All game state is value types (`struct`, `enum`) — safe across actor boundaries
- `StatsStore` is an actor — all disk I/O serialised off the main thread

### Module layout

```
Sources/
├── App/            SwiftUI @main, AppDelegate, menu bar
├── HSLogTailer/    File-tail primitive (DispatchSource + FSEvents)
├── HSLogParser/    Line → LogEvent state machine
├── GameState/      Reducer, Game model, StatsStore
├── CardDB/         HearthstoneJSON loader + card lookup
├── DeckStore/      SwiftData decks, deckstring codec
├── Overlay/        NSPanel overlay controller
├── TrackerUI/      SwiftUI overlay views
└── Settings/       Preferences + log.config installer
```

---

## Gaps vs HDT — what's left

These are the remaining meaningful gaps between hs-helper and HDT, ordered by value.

### 1. Secrets tracker (medium effort, high value)
Track which opponent secrets are still possible based on game events.
Each event eliminates secrets that could not have triggered (e.g. you attacked → Explosive Trap, Freezing Trap still live; Snipe eliminated).

HDT reference: `Hearthstone Deck Tracker/Hearthstone/Secrets/SecretsManager.cs`

Implementation path:
- Create a `SecretsTracker` struct in `GameState` with a set of remaining possible secrets per class
- Hook into `handleZoneChange`, `handleTagSideEffects`, and block events to eliminate secrets
- Show remaining possibilities in the opponent panel under the IN HAND section
- Needs a data table: `[CardId: [EliminationCondition]]` — one entry per secret

### 2. Match history view (low effort, high value)
`StatsStore` already persists `GameRecord` to disk. Need a SwiftUI view to display it.

- Win/loss record per deck and per class
- Filter by mode (Ranked, Casual, etc.) and format (Standard, Wild)
- Total games played, overall win rate
- Open from menu bar → "Match History…"

### 3. Related cards / token tracking (low-medium effort)
Show what a card generates when played — tokens, discovers, copies.

HDT reference: `Hearthstone Deck Tracker/Hearthstone/RelatedCardsSystem/`

- Maintain a data table: `[cardId: [relatedCardId]]` (can be derived from HearthstoneJSON `mechanics` + `referencedTags`)
- Show related cards as a tooltip or sub-row in the deck panel

### 4. Opponent deck prediction (medium effort)
Infer what the opponent is likely playing based on revealed cards.

- When enough cards are revealed, match against known decklists from HSReplay or a bundled archetype DB
- Show predicted archetype name ("Flood Paladin", "Control Warrior") in the opponent header
- HDT does this via HSReplay API; we can start with a bundled archetype signature file

### 5. Mulligan guide (high effort, requires API)
Show keep/replace recommendations during mulligan based on HSReplay win-rate data.

- Requires HSReplay OAuth + API calls during mulligan phase
- HDT reference: `Controls/Overlay/Constructed/Mulligan/`
- Phase 1: just show deck odds (already there as "top deck odds %")
- Phase 2: fetch per-card mulligan win rates from HSReplay and display as +/- indicators

### 6. Arena draft helper (separate feature, medium effort)
Show tier ratings for each offered card during arena draft.

- Trigger: `HSScene.gameplay` with game mode `.arena` during a choice event
- Data: HearthArena or Lightforge tier lists (bundled JSON, refreshed on launch)
- Show tier + rating in a small overlay during the pick phase

### 7. HSReplay upload (medium effort, nice to have)
Upload completed games as `.hsreplay` files.

- `game.timeline` already records every `LogEvent` in order — replay export is straightforward
- Need OAuth flow + `URLSession` upload to `api.hsreplay.net`
- HDT reference: `HsReplay/ApiWrapper.cs`

### 8. Auto-update (Sparkle, low effort)
Ship updates via a Sparkle appcast. Notarized DMG on GitHub Releases, appcast XML at a fixed URL.

---

## Known limitations

| Issue | Notes |
|---|---|
| True exclusive fullscreen | Borderless Windowed is the recommended HS window mode. `.fullScreenAuxiliary` covers Spaces fullscreen. |
| Opponent deck identification | We see played cards only — no deck prediction yet (see gap #4 above). |
| Wild: detection relies on deckstring | If a game starts before the deckstring is received, `verifyLocalPlayerAssignment()` corrects it post-load. |
| Log format changes | Parser is version-gated via fixture corpus. A breaking patch needs a parser hotfix. |

---

## Next concrete steps

1. **Match history view** — wire `StatsStore.allRecords()` into a new SwiftUI sheet opened from the menu bar. Simplest possible table: date, result, own class vs opponent class, turns.
2. **Secrets tracker** — start with Mage and Paladin (most common in Ranked). Build the elimination rule table, add the UI row to the opponent panel.
3. **Related cards tooltip** — add a hover interaction to `CardRow` that shows tokens/generates in a popover.
