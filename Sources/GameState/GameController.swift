import CardDB
import Foundation
import HSLogParser
import HSLogTailer
import Observation

@Observable
@MainActor
public final class GameController: Observable {

    // MARK: Published state

    /// The game currently in progress.  Nil between games.
    public private(set) var currentGame: Game? = nil

    /// Whether a game is actively being tracked.
    public var isTracking: Bool { currentGame?.isActive ?? false }

    /// Match history (most recent first), kept in memory for the session.
    public private(set) var recentGames: [Game] = []

    /// Pending deckstring from Decks.log — consumed on game start.
    public private(set) var pendingDeckstring: String? = nil
    public private(set) var pendingDeckName: String? = nil

    /// Whether the overlay should be visible.
    public var showOverlay: Bool = true

    // MARK: Dependencies (injected)

    public let cardDB: CardDB

    // MARK: Private pipeline

    private let powerTailer: HSLogTailer
    private let decksTailer: HSLogTailer
    private let loadingTailer: HSLogTailer
    private let powerParser: HSLogParser
    private let decksParser: HSLogParser
    private let loadingParser: HSLogParser
    private var tailerTasks: [Task<Void, Never>] = []

    // MARK: Init

    public init(cardDB: CardDB) {
        self.cardDB = cardDB
        self.powerTailer = HSLogTailer()
        self.decksTailer = HSLogTailer()
        self.loadingTailer = HSLogTailer()
        self.powerParser = HSLogParser()
        self.decksParser = HSLogParser()
        self.loadingParser = HSLogParser()
    }

    // MARK: - Lifecycle

    /// Start tailing log files. Call once on app launch.
    public func start() {
        guard tailerTasks.isEmpty else { return }

        let logs: [(String, HSLogTailer, HSLogParser, () -> String)] = [
            ("[Power] ", powerTailer, powerParser, powerLogPath),
            ("[Decks] ", decksTailer, decksParser, decksLogPath),
            ("[LoadingScreen] ", loadingTailer, loadingParser, loadingScreenLogPath),
        ]

        for (prefix, tailer, parser, pathFunc) in logs {
            let task = Task { [weak self] in
                guard let self else { return }
                let logPath = pathFunc()
                let stream = await tailer.lines(at: logPath)
                for await line in stream {
                    // Parse off the main thread to avoid blocking UI during bursts
                    let events = parser.process(line: prefix + line)
                    if !events.isEmpty {
                        await MainActor.run {
                            for event in events {
                                self.handleEvent(event)
                            }
                        }
                    }
                }
            }
            tailerTasks.append(task)
        }
    }

    /// Stop tailing and release resources.
    public func stop() {
        for task in tailerTasks {
            task.cancel()
        }
        tailerTasks.removeAll()
        Task {
            await powerTailer.stop()
            await decksTailer.stop()
            await loadingTailer.stop()
        }
    }

    // MARK: - Event dispatch

    private func handleEvent(_ event: LogEvent) {
        switch event {

        // A new game is starting — archive the old one, reset.
        case .gameCreated(let gameEntityId):
            // PowerTaskList can reprint CREATE_GAME during an active game.
            // Only skip if the current game is still in progress — gameEntityId
            // is always 1 in every game, so comparing IDs alone would block
            // every new game that follows a non-archived previous game.
            let isActiveDuplicate =
                currentGame.map { g in
                    g.isActive && g.gameEntityId == gameEntityId
                } ?? false
            if isActiveDuplicate { break }

            archiveCurrentGame()
            var game = Game()
            apply(event: event, to: &game)
            currentGame = game

            // If we have a pending deckstring from Decks.log, consume it.
            if let ds = pendingDeckstring {
                currentGame?.player.pendingDeckstring = ds
                currentGame?.player.deckName = pendingDeckName
                pendingDeckstring = nil
                pendingDeckName = nil
                Task { [weak self] in
                    await self?.populateRemainingDeck()
                }
            }

        case .deckSelected(let deckstring, let name):
            pendingDeckstring = deckstring
            pendingDeckName = name
            // If a game is already in progress, populate immediately.
            if currentGame != nil {
                currentGame?.player.pendingDeckstring = deckstring
                currentGame?.player.deckName = name
                Task { [weak self] in await self?.populateRemainingDeck() }
            }

        case .gameOver:
            if var game = currentGame {
                apply(event: event, to: &game)
                currentGame = game
                archiveCurrentGame()
            }

        case .sceneChanged(let scene):
            // When we leave gameplay, clear the current game.
            if scene != .gameplay && scene != .unknown {
                archiveCurrentGame()
            }

        default:
            // Apply all other events to the current game.
            if var game = currentGame {
                let hadNoPending = game.player.pendingExtraDeckCardIds.isEmpty
                apply(event: event, to: &game)
                currentGame = game
                // The parser never emits .gameOver directly; game-over is
                // signalled via PLAYSTATE/STEP tag changes that set phase
                // to .gameOver inside apply(). Archive immediately so the
                // next game is never blocked by a stale currentGame.
                if game.phase == .gameOver {
                    archiveCurrentGame()
                } else if hadNoPending && !game.player.pendingExtraDeckCardIds.isEmpty {
                    Task { [weak self] in await self?.resolveExtraDeckCards() }
                }
            }
        }
    }

    // MARK: - Deck population

    /// Decode the pending deckstring and build the remainingDeck list.
    /// Retries while CardDB is still loading (up to ~30 s) and preserves
    /// `pendingDeckstring` on failure so a later trigger can populate.
    private func populateRemainingDeck() async {
        guard let ds = currentGame?.player.pendingDeckstring, !ds.isEmpty else { return }
        guard let decoded = try? DeckstringCodec.decode(ds) else {
            currentGame?.player.pendingDeckstring = ""
            return
        }

        // Wait up to 30 s for the CardDB to finish loading the first time.
        for _ in 0..<300 {
            if await cardDB.isLoaded { break }
            try? await Task.sleep(for: .milliseconds(100))
        }

        var entries = await cardDB.resolve(pairs: decoded.allPairs)

        // Some dbfIds didn't resolve — refresh from network (bypassing ETag)
        // in case new-set cards aren't in the cached JSON yet, then retry.
        if entries.count < decoded.allPairs.count {
            await cardDB.refreshFromNetwork()
            entries = await cardDB.resolve(pairs: decoded.allPairs)
        }

        // CardDB still empty or no matches — leave pendingDeckstring intact.
        guard !entries.isEmpty else { return }

        let tracked: [TrackedCard] = entries.map { entry in
            TrackedCard(card: entry.card, count: entry.count)
        }.sorted {
            $0.card.cost != $1.card.cost
                ? $0.card.cost < $1.card.cost
                : $0.card.name < $1.card.name
        }

        // Apply only the resolved deck to the currently active game to avoid data races
        // with log events processed while awaiting the CardDB resolution.
        currentGame?.player.remainingDeck = tracked
        currentGame?.player.pendingDeckstring = ""
        currentGame?.player.deckList = entries
        // Feed the local-player detector: any SHOW_ENTITY that reveals one of
        // these cardIds is, by construction, a local player's card.
        currentGame?.localDeckCardIds = Set(entries.map { $0.card.id })

        // Re-verify local-player assignment now that we know the deck card IDs.
        // Catches Wild mode where FULL_ENTITY during CREATE_GAME may not carry
        // card IDs, leaving the initial detection heuristic wrong.
        verifyLocalPlayerAssignment()

        // Reconcile: any cards already drawn/played before populate finished
        // (starting hand SHOW_ENTITYs, or mid-game reconnect) need to be
        // subtracted from remainingDeck so the count reflects reality.
        reconcileAlreadyDrawnCardsAgainstRemainingDeck()
    }

    /// Decrement remainingDeck for local-player entities that are no longer
    /// in the DECK zone. Safe to call repeatedly — we re-scan from scratch.
    private func reconcileAlreadyDrawnCardsAgainstRemainingDeck() {
        guard var game = currentGame else { return }
        guard !game.player.remainingDeck.isEmpty else { return }

        // Collect cardIds of player-owned entities outside the deck.
        var drawnCounts: [String: Int] = [:]
        for entity in game.entities.values {
            guard let cid = entity.cardId, !cid.isEmpty else { continue }
            guard game.ownerOf(entityId: entity.id) == .player else { continue }
            if entity.info.created { continue }
            // Card must have left the deck to count as drawn.
            if entity.zone == .deck || entity.zone == .invalid { continue }
            drawnCounts[cid, default: 0] += 1
        }

        for (cardId, drawn) in drawnCounts {
            guard let idx = game.player.remainingDeck.firstIndex(where: { $0.card.id == cardId && !$0.isCreated })
            else { continue }
            let newCount = max(0, game.player.remainingDeck[idx].count - drawn)
            let reduced = game.player.remainingDeck[idx].count - newCount
            game.player.remainingDeck[idx].count = newCount
            game.player.remainingDeck[idx].drawnCount += reduced
        }

        currentGame = game
    }

    /// Retry deck population once the CardDB finishes loading.
    /// Called by AppDelegate after `cardDB.load()` completes so cold starts
    /// (game already in progress when the app launches) still populate.
    public func retryPopulateRemainingDeckIfNeeded() {
        guard let ds = currentGame?.player.pendingDeckstring, !ds.isEmpty else { return }
        Task { [weak self] in await self?.populateRemainingDeck() }
    }

    /// Re-verify local-player assignment after deck card IDs become known.
    /// Wild mode often skips card IDs on FULL_ENTITY during CREATE_GAME, so the
    /// initial heuristic may assign sides backwards. Once `localDeckCardIds` is
    /// populated we can do a definitive check: any entity whose cardId is in our
    /// deck but is owned by the opponent means the sides are swapped.
    private func verifyLocalPlayerAssignment() {
        guard var game = currentGame else { return }
        guard !game.localDeckCardIds.isEmpty else { return }

        var playerKnownCards = 0
        var opponentKnownCards = 0

        for entity in game.entities.values {
            guard let cid = entity.cardId, !cid.isEmpty else { continue }
            guard entity.zone == .deck || entity.zone == .hand else { continue }

            if game.ownerOf(entityId: entity.id) == .player {
                playerKnownCards += 1
            } else if game.ownerOf(entityId: entity.id) == .opponent {
                opponentKnownCards += 1
            }
        }

        // If the side we currently call "opponent" has significantly more known cards
        // in hand/deck than the "player" side, the sides are backwards.
        // In Hearthstone, the local player's deck and hand are fully known (~30 cards),
        // while the opponent's are hidden (0 cards, maybe 1 for quests/start of game effects).
        if opponentKnownCards > playerKnownCards && opponentKnownCards > 10 {
            swapSides(game: &game)
            game.localSideResolved = true
            currentGame = game
            return
        }

    }

    /// Resolve card IDs queued by mid-game deck-shuffle effects (e.g. tutor cards,
    /// generated copies) into full TrackedCard entries and merge into remainingDeck.
    private func resolveExtraDeckCards() async {
        guard var game = currentGame else { return }
        let pending = game.player.pendingExtraDeckCardIds
        guard !pending.isEmpty else { return }

        // Drain the queue immediately so concurrent calls don't double-add.
        game.player.pendingExtraDeckCardIds = [:]
        currentGame = game

        for _ in 0..<100 {
            if await cardDB.isLoaded { break }
            try? await Task.sleep(for: .milliseconds(100))
        }

        guard currentGame != nil else { return }

        for (pendingCard, addedCount) in pending {
            let cardId = pendingCard.cardId
            let isCreated = pendingCard.isCreated
            guard let card = await cardDB.card(id: cardId) else { continue }
            if let idx = currentGame?.player.remainingDeck.firstIndex(where: {
                $0.card.id == cardId && $0.isCreated == isCreated
            }) {
                currentGame?.player.remainingDeck[idx].count += addedCount
            } else {
                var tracked = TrackedCard(card: card, count: addedCount)
                tracked.isCreated = isCreated
                currentGame?.player.remainingDeck.append(tracked)
            }
        }

        currentGame?.player.remainingDeck.sort {
            $0.card.cost != $1.card.cost
                ? $0.card.cost < $1.card.cost
                : $0.card.name < $1.card.name
        }
    }

    // MARK: - History

    private func archiveCurrentGame() {
        guard let game = currentGame else { return }
        if game.phase != .waiting && game.phase != .setup {
            // Strip the event timeline — it's only needed for HSReplay export
            // (not yet implemented). Keeping it would accumulate thousands of
            // LogEvent values per game across all archived games.
            var archived = game
            archived.timeline = []
            recentGames.insert(archived, at: 0)
            if recentGames.count > 50 {
                recentGames.removeLast()
            }
            Task { await StatsStore.shared.save(game: game) }
        }
        currentGame = nil
        powerParser.reset()
        decksParser.reset()
        loadingParser.reset()
    }

    // MARK: - Helpers

    private func powerLogPath() -> String {
        return "/Applications/Hearthstone/Logs/Power.log"
    }

    private func decksLogPath() -> String {
        return "/Applications/Hearthstone/Logs/Decks.log"
    }

    private func loadingScreenLogPath() -> String {
        return "/Applications/Hearthstone/Logs/LoadingScreen.log"
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - DeckstringCodec re-export (avoid import DeckStore from GameState)
// ═══════════════════════════════════════════════════════════════════════════════

// GameState depends on CardDB but NOT DeckStore (would be circular).
// We need DeckstringCodec to decode the pending deckstring here.
// Solution: a minimal local decoder that mirrors DeckStore's VarintReader.

private struct DecodedDeckLocal {
    let format: Format
    let allPairs: [(dbfId: Int, count: Int)]
}

private enum DeckstringCodec {
    static func decode(_ deckstring: String) throws -> DecodedDeckLocal {
        let normalised =
            deckstring
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalised.count % 4
        let padded =
            remainder == 0 ? normalised : normalised + String(repeating: "=", count: 4 - remainder)

        guard let data = Data(base64Encoded: padded) else {
            throw CocoaError(.coderInvalidValue)
        }

        var reader = LightVarintReader(data: data)

        _ = try reader.next()  // reserved = 0
        _ = try reader.next()  // version  = 1
        let formatRaw = try reader.next()
        let format = Format(rawValue: formatRaw) ?? .unknown
        _ = try reader.next()  // hero count = 1
        _ = try reader.next()  // hero dbfId (we don't need it here)

        let singleCount = try reader.next()
        var pairs = [(dbfId: Int, count: Int)]()
        for _ in 0..<singleCount {
            pairs.append((try reader.next(), 1))
        }
        let doubleCount = try reader.next()
        for _ in 0..<doubleCount {
            pairs.append((try reader.next(), 2))
        }
        if reader.hasBytes {
            let nOfCount = try reader.next()
            for _ in 0..<nOfCount {
                let id = try reader.next()
                let cnt = try reader.next()
                pairs.append((id, cnt))
            }
        }

        if reader.hasBytes {
            let hasSideboards = try reader.next()
            if hasSideboards == 1 {
                let sideboardCount = try reader.next()
                for _ in 0..<sideboardCount {
                    _ = try reader.next()  // Owner DBFID (e.g., E.T.C. or Zilliax)
                    let cardsInSideboard = try reader.next()
                    for _ in 0..<cardsInSideboard {
                        let sId = try reader.next()
                        let sCount = try reader.next()
                        pairs.append((sId, sCount))
                    }
                }
            }
        }

        return DecodedDeckLocal(format: format, allPairs: pairs)
    }
}

private struct LightVarintReader {
    private let data: Data
    private var cursor: Int = 0

    init(data: Data) { self.data = data }

    var hasBytes: Bool { cursor < data.count }

    mutating func next() throws -> Int {
        var result = 0
        var shift = 0
        while cursor < data.count {
            let byte = Int(data[cursor])
            cursor += 1
            result |= (byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        throw CocoaError(.coderInvalidValue)
    }
}
