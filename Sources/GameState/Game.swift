// Sources/GameState/Game.swift
// The complete game state model.
// All types are pure value types (structs/enums) and Sendable.
// The reducer takes (inout Game, LogEvent) — nothing here does any I/O.

import CardDB
import Foundation
import HSLogParser

// MARK: - Game

/// The authoritative snapshot of a single Hearthstone match.
/// Rebuilt from scratch every time a new game starts (CREATE_GAME event).
/// The reducer appends events to `timeline` so the full game can be replayed.
public struct Game: Sendable {

    // ── Identity ──────────────────────────────────────────────────────────────

    /// Unique ID assigned when the reducer sees CREATE_GAME.
    public var matchID: UUID = UUID()

    /// Wall-clock time the game started, set on CREATE_GAME.
    public var startedAt: Date = Date()

    /// Wall-clock time the game ended, set on gameOver.
    public var endedAt: Date? = nil

    // ── Format / mode ─────────────────────────────────────────────────────────

    public var format: Format = .unknown
    public var gameMode: GameMode = .unknown

    // ── Players ───────────────────────────────────────────────────────────────

    /// The local player (the person running the tracker).
    public var player: Side = Side()

    /// The opponent.
    public var opponent: Side = Side()

    // ── Turn / phase ──────────────────────────────────────────────────────────

    public var turn: Int = 0
    public var phase: GamePhase = .waiting

    // ── Entity map ────────────────────────────────────────────────────────────

    /// Every entity the game has created, keyed by the integer entity ID.
    /// This is the core data structure the reducer mutates on every log event.
    public var entities: [Int: Entity] = [:]

    /// Maps player entity IDs (1 / 2) to "local" or "opponent".
    /// Populated during CREATE_GAME → Player sub-events.
    public var playerIdMap: [Int: PlayerSide] = [:]

    /// The entity ID of the GameEntity (usually 1).
    public var gameEntityId: Int? = nil

    /// Set once we've identified which PlayerID is the local player and
    /// confirmed the `player` / `opponent` Side assignment. Prevents the
    /// detection heuristic from re-swapping mid-game on spurious reveals.
    public var localSideResolved: Bool = false

    /// Card IDs of the local player's full deck (populated from the
    /// deckstring). Used as the definitive signal for local-player
    /// detection: the controller of a SHOW_ENTITY whose cardId matches
    /// one of these is the local player.
    public var localDeckCardIds: Set<String> = []

    // ── Block stack ───────────────────────────────────────────────────────────

    /// BLOCK_START events push onto this stack; BLOCK_END pops.
    /// The top of the stack gives context for interpreting nested TAG_CHANGEs.
    public var blockStack: [Block] = []

    // ── Event timeline ────────────────────────────────────────────────────────

    /// Append-only ordered list of every LogEvent applied to this game.
    /// Enables offline replay and HSReplay export.
    public var timeline: [LogEvent] = []

    // ── Result ────────────────────────────────────────────────────────────────

    public var result: GameResult = .unknown

    // ── Counters ──────────────────────────────────────────────────────────────

    public var counters: GameCounters = GameCounters()

    // MARK: Derived helpers

    /// Returns the Side for a given PlayerSide value.
    public func side(_ which: PlayerSide) -> Side {
        which == .player ? player : opponent
    }

    /// Mutating variant — returns a reference to the correct Side.
    public mutating func mutateSide(_ which: PlayerSide, body: (inout Side) -> Void) {
        if which == .player {
            body(&player)
        } else {
            body(&opponent)
        }
    }

    /// Which PlayerSide owns this entity (by CONTROLLER tag).
    public func ownerOf(entityId: Int) -> PlayerSide? {
        guard let entity = entities[entityId],
            let controllerStr = entity.tags[.controller],
            let controllerId = Int(controllerStr)
        else { return nil }
        return playerIdMap[controllerId]
    }

    /// Convenience: all entities currently in a given zone for a given controller.
    public func entities(in zone: Zone, for side: PlayerSide) -> [Entity] {
        entities.values.filter { entity in
            entity.tags[.zone] == zone.rawValue && ownerOf(entityId: entity.id) == side
        }
        .sorted {
            ($0.tags[.zonePosition].flatMap(Int.init) ?? 0)
                < ($1.tags[.zonePosition].flatMap(Int.init) ?? 0)
        }
    }

    /// True once CREATE_GAME has been seen and at least one TAG_CHANGE applied.
    public var isActive: Bool {
        gameEntityId != nil && phase != .waiting && phase != .gameOver
    }
}

// MARK: - Side

/// The state of one player's side of the board.
public struct Side: Sendable {

    // ── Identity ──────────────────────────────────────────────────────────────

    /// The Hearthstone account ID (hi + lo), used to identify the local player.
    public var accountHi: Int = 0
    public var accountLo: Int = 0

    /// The BattleTag or display name seen in the log.
    public var name: String = ""

    /// The player slot (1 or 2) assigned by the game server.
    public var playerId: Int = 0

    /// The entity ID of this player's Player entity.
    public var entityId: Int = 0

    // ── Hero ──────────────────────────────────────────────────────────────────

    /// The card ID of the hero card being played this game ("HERO_01", etc.).
    public var heroCardId: String? = nil

    /// The class derived from the hero card.
    public var heroClass: CardClass = .neutral

    public var deckName: String? = nil

    /// Temporary: deckstring from Decks.log, consumed by GameController
    /// when it populates remainingDeck via CardDB.
    public var pendingDeckstring: String = ""

    /// Card IDs shuffled into the deck mid-game that are not in the original
    /// deckList (generated by effects, tutors, etc.).  GameController drains
    /// this, resolves metadata from CardDB, and merges into remainingDeck.
    public var pendingExtraDeckCardIds: [String: Int] = [:]

    // ── Deck ──────────────────────────────────────────────────────────────────

    /// The constructed deck the player selected before the game.
    /// Nil for the opponent until cards are revealed.
    public var deckList: [DeckEntry] = []

    /// Cards remaining in the deck (copy of deckList decremented as cards are drawn).
    /// Nil count means we haven't confirmed the count yet.
    public var remainingDeck: [TrackedCard] = []

    // ── Hand ──────────────────────────────────────────────────────────────────

    /// Entities currently in hand. CardId may be nil for opponent's hidden cards.
    public var hand: [Int] = []  // entity IDs in hand

    // ── Board ─────────────────────────────────────────────────────────────────

    public var board: [Int] = []  // entity IDs in play

    // ── History ───────────────────────────────────────────────────────────────

    /// Cards this player has played this game, in order.
    public var cardsPlayed: [CardPlay] = []

    /// Cards revealed from the opponent's deck/hand (Phase 2).
    public var revealedCards: [String: Int] = [:]  // cardId → count seen

    /// Cards known to be in the opponent's hand (entity IDs with resolved card IDs).
    public var knownInHand: [Int: String] = [:]  // entityId → cardId

    // ── Resources ─────────────────────────────────────────────────────────────

    public var resources: Resources = Resources()

    // ── Graveyard / removed ───────────────────────────────────────────────────

    public var graveyard: [Int] = []  // entity IDs
    public var removed: [Int] = []  // entity IDs (set aside / transformed)

    // ── Secrets ───────────────────────────────────────────────────────────────

    public var secrets: [Int] = []  // entity IDs of active secrets

    // ── Quest ─────────────────────────────────────────────────────────────────

    public var questEntityId: Int? = nil
    public var questProgress: Int = 0
    public var questProgressTotal: Int = 0

    // ── Fatigue ───────────────────────────────────────────────────────────────

    public var fatigueCounter: Int = 0

    // ── Mulligan ──────────────────────────────────────────────────────────────

    /// Entity IDs the player kept during mulligan (populated from chosenEntities).
    public var mulliganKept: [Int] = []

    /// Entity IDs the player replaced during mulligan.
    public var mulliganReplaced: [Int] = []
}

// MARK: - Resources

/// Mana and overload state for one player.
public struct Resources: Sendable {
    public var total: Int = 0  // crystals shown (before overload reduction)
    public var used: Int = 0  // crystals spent this turn
    public var temp: Int = 0  // temporary mana added by effects
    public var overloadLocked: Int = 0  // locked for THIS turn from last turn's overload
    public var overloadOwed: Int = 0  // will be locked NEXT turn

    public var available: Int {
        max(0, total - used - overloadLocked + temp)
    }
}

// MARK: - Entity

/// A single in-game entity — could be a card, the game itself, or a player.
/// Entities are created by FULL_ENTITY and mutated by TAG_CHANGE / SHOW_ENTITY.
public struct Entity: Sendable, Identifiable {

    public let id: Int

    /// Metadata about how this entity entered the game.
    public var info: EntityInfo = EntityInfo()

    /// The card this entity represents. Nil until the entity is revealed
    /// (e.g. opponent's cards during their turn are entities with nil cardId).
    public var cardId: String? = nil

    /// All tags ever set on this entity, keyed by GameTag.
    /// Values are stored as raw strings matching what the log writes,
    /// e.g. tags[.zone] = "HAND", tags[.controller] = "1".
    public var tags: [GameTag: String] = [:]

    // ── Derived zone helpers ──────────────────────────────────────────────────

    public var zone: Zone {
        guard let raw = tags[.zone] else { return .invalid }
        return Zone(rawValue: raw) ?? .invalid
    }

    public var controller: Int? {
        tags[.controller].flatMap(Int.init)
    }

    public var zonePosition: Int {
        tags[.zonePosition].flatMap(Int.init) ?? 0
    }

    public var cardType: String? {
        tags[.cardType]
    }

    public var isSecret: Bool {
        tags[.secret] == "1"
    }

    public var isExhausted: Bool {
        tags[.exhausted] == "1"
    }

    public var costTag: Int? {
        tags[.cost].flatMap(Int.init)
    }

    public var attackTag: Int? {
        tags[.attack].flatMap(Int.init)
    }

    public var healthTag: Int? {
        tags[.health].flatMap(Int.init)
    }

    public var damageTag: Int {
        tags[.damage].flatMap(Int.init) ?? 0
    }

    public var currentHealth: Int? {
        guard let h = healthTag else { return nil }
        return h - damageTag
    }

    public var playState: PlayState? {
        guard let raw = tags[.playState] else { return nil }
        return PlayState(rawValue: raw)
    }

    // MARK: init

    public init(id: Int, cardId: String? = nil, tags: [GameTag: String] = [:]) {
        self.id = id
        self.cardId = cardId
        self.tags = tags
    }
}

// MARK: - Block

/// Represents one frame of the BLOCK_START / BLOCK_END stack.
/// The reducer uses this to understand why a TAG_CHANGE is happening.
public struct Block: Sendable {
    public let type: BlockType
    public let entity: EntityRef
    public let effectCardId: String?
    public let effectIndex: Int?

    public init(
        type: BlockType,
        entity: EntityRef,
        effectCardId: String? = nil,
        effectIndex: Int? = nil
    ) {
        self.type = type
        self.entity = entity
        self.effectCardId = effectCardId
        self.effectIndex = effectIndex
    }
}

// MARK: - EntityInfo

/// Metadata about how an entity entered the game.
/// Mirrors HDT's EntityInfo — used to distinguish generated/stolen cards in the UI.
public struct EntityInfo: Sendable {
    /// True when the entity was created by an effect, not drawn from the original deck.
    /// Set for cards that spawn directly into HAND or PLAY during the main phase.
    public var created: Bool = false

    /// True when the entity changed controller mid-game (Mind Control, theft effects).
    public var stolen: Bool = false

    /// The original controller ID before a steal occurred.
    public var originalController: Int? = nil
}

// MARK: - GameCounters

/// Running tallies of game-wide events. Reset each game.
/// Used by the overlay to show counters relevant to deck synergies.
public struct GameCounters: Sendable {
    public var playerSpellsPlayed: Int = 0
    public var opponentSpellsPlayed: Int = 0
    public var playerMinionsPlayed: Int = 0
    public var opponentMinionsPlayed: Int = 0
    public var playerMinionsKilled: Int = 0
    public var opponentMinionsKilled: Int = 0
    public var playerCardsDrawn: Int = 0
    public var opponentCardsDrawn: Int = 0
    public var playerWeaponsPlayed: Int = 0
    public var opponentWeaponsPlayed: Int = 0
}

// MARK: - TrackedCard

/// One entry in the "remaining deck" list shown in the overlay.
/// Carries both the card data and the current count in the deck.
public struct TrackedCard: Sendable, Identifiable, Hashable {

    public var id: String { card.id }

    public let card: Card
    public var count: Int      // starts at deck count, decrements on draw
    public var drawnCount: Int // how many times this card has been drawn
    public var isCreated: Bool = false  // generated mid-game, not from original deck

    /// True when count == 0 — the card has been fully drawn / played.
    public var isExhausted: Bool { count <= 0 }

    public init(card: Card, count: Int) {
        self.card = card
        self.count = count
        self.drawnCount = 0
    }
}

// MARK: - CardPlay

/// A record of one card being played by a player.
public struct CardPlay: Sendable, Identifiable {
    public let id: UUID = UUID()
    public let turn: Int
    public let cardId: String
    public let entityId: Int
    public let timestamp: Date

    public init(turn: Int, cardId: String, entityId: Int, timestamp: Date = Date()) {
        self.turn = turn
        self.cardId = cardId
        self.entityId = entityId
        self.timestamp = timestamp
    }
}

// MARK: - GamePhase

/// The phase the current game is in, derived from the STEP tag on the GameEntity.
public enum GamePhase: String, Sendable, Hashable {
    /// No game is in progress (tracker just launched, or between games).
    case waiting = "WAITING"

    /// CREATE_GAME received, setting up entities.
    case setup = "SETUP"

    /// BEGIN_MULLIGAN step — show mulligan overlay.
    case mulligan = "MULLIGAN"

    /// MAIN_READY step — normal gameplay.
    case main = "MAIN"

    /// FINAL_GAMEOVER step — game is over, show result.
    case gameOver = "GAME_OVER"
}

// MARK: - GameResult

public enum GameResult: String, Codable, Sendable, Hashable {
    case unknown = "unknown"
    case won = "won"
    case lost = "lost"
    case tied = "tied"
    case disconnected = "disconnected"
}

// MARK: - GameMode

public enum GameMode: String, Codable, Sendable, Hashable, CaseIterable {
    case unknown = "UNKNOWN"
    case ranked = "RANKED"
    case casual = "CASUAL"
    case friendly = "FRIENDLY"
    case practice = "PRACTICE"
    case adventure = "ADVENTURE"
    case arena = "ARENA"
    case brawl = "BRAWL"
    case duels = "DUELS"

    public var displayName: String {
        switch self {
        case .unknown: return "Unknown"
        case .ranked: return "Ranked"
        case .casual: return "Casual"
        case .friendly: return "Friendly"
        case .practice: return "Practice"
        case .adventure: return "Adventure"
        case .arena: return "Arena"
        case .brawl: return "Tavern Brawl"
        case .duels: return "Duels"
        }
    }
}

// MARK: - PlayerSide

/// Which side of the table an entity / player belongs to.
public enum PlayerSide: Sendable, Hashable {
    case player
    case opponent
}
