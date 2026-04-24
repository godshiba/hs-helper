// Sources/HSLogParser/LogEvent.swift
// The single output type of HSLogParser.
// Every distinct thing that can happen in a Hearthstone log is one case here.
// The GameState reducer receives a stream of these and applies them to Game.
//
// Design rules:
//   • All associated values are value types and Sendable — safe to cross actor boundaries.
//   • No optionals-inside-optionals; use dedicated cases instead.
//   • Names match the Power.log terminology so grep() from a log line leads straight here.

// MARK: - LogEvent

public enum LogEvent: Sendable {

    // ── Game lifecycle ────────────────────────────────────────────────────────

    /// `CREATE_GAME` — the root entity of every game session.
    case gameCreated(gameEntityId: Int)

    /// `CREATE_GAME` → `Player` sub-block for each of the two players.
    /// `isLocalPlayer` is inferred by the parser from the `ENTITY_ID` tag
    /// matching the account the user is logged in as.
    case playerCreated(
        entityId: Int,
        playerId: Int,
        accountHi: Int,
        accountLo: Int
    )

    /// The game ended. The reducer should inspect each player's PLAYSTATE tag
    /// to determine winner / loser — this event is the signal to stop tracking.
    case gameOver

    // ── Entity lifecycle ──────────────────────────────────────────────────────

    /// `FULL_ENTITY — Updating` — entity is created for the first time.
    /// `cardId` is nil when the entity is hidden (opponent's deck / hand).
    case fullEntity(
        id: Int,
        cardId: String?,
        tags: [GameTag: String]
    )

    /// `SHOW_ENTITY — Updating` — a previously hidden entity is revealed.
    /// `cardId` is always non-empty here; this is how opponent cards become known.
    case showEntity(
        id: Int,
        cardId: String,
        tags: [GameTag: String]
    )

    /// `HIDE_ENTITY` — an entity is hidden (e.g. a card returned to hand face-down).
    case hideEntity(
        id: Int,
        zone: Zone
    )

    /// `CHANGE_ENTITY` — entity transforms into a different card mid-game
    /// (e.g. Jade Golems, "Discover and replace" effects, Whizbang).
    case changeEntity(
        id: Int,
        cardId: String,
        tags: [GameTag: String]
    )

    // ── Tag changes ───────────────────────────────────────────────────────────

    /// `TAG_CHANGE` — the most common event; one tag on one entity changed value.
    /// `ref` is EntityRef.id(_) in the vast majority of cases; EntityRef.name(_)
    /// for the GameEntity and the two Player entities which use string identifiers
    /// in early-game lines before their numeric IDs are established.
    case tagChange(
        entity: EntityRef,
        tag: GameTag,
        value: String
    )

    // ── Blocks ────────────────────────────────────────────────────────────────

    /// `BLOCK_START` — opens a logical action scope.
    /// `effectCardId` is present for triggered/enchantment effects.
    case blockStart(
        type: BlockType,
        entity: EntityRef,
        effectCardId: String?,
        effectIndex: Int?
    )

    /// `BLOCK_END` — closes the innermost open block.
    case blockEnd

    // ── Sub-spells (Hearthstone 2020+ nested spell system) ────────────────────

    /// `SUB_SPELL_START` — nested spell effect begins.
    case subSpellStart(spellPrefab: String?, parentEntityId: Int?)

    /// `SUB_SPELL_END`
    case subSpellEnd

    // ── Choices (Discover / Mulligan / Choose One) ────────────────────────────

    /// `GameState.DebugPrintEntityChoices` — the game offered the local player
    /// a choice (Discover, Mulligan keep/replace, Choose One).
    case choices(
        id: Int,
        playerName: String,
        choiceType: ChoiceType,
        entityIds: [Int]
    )

    /// `GameState.DebugPrintEntitiesChosen` — the player made their selection.
    case chosenEntities(
        choiceId: Int,
        entityIds: [Int]
    )

    // ── Options (targeting / attack / end turn) ───────────────────────────────

    /// `GameState.DebugPrintOptions` — the local player has available actions.
    /// We use this primarily to detect whose turn it is without polling TURN tag.
    case options(entityIds: [Int])

    // ── Metadata ──────────────────────────────────────────────────────────────

    /// `META_DATA` lines annotate blocks with extra info (damage targets, etc.).
    /// Stored as a raw string because the format varies widely and most of it
    /// is irrelevant for deck tracking.  Exposed for future replay / HSReplay use.
    case metaData(type: String, data: Int, info: [Int])

    // ── LoadingScreen.log ─────────────────────────────────────────────────────

    /// The user navigated to a new scene in the HS client.
    case sceneChanged(to: HSScene)

    // ── Decks.log ─────────────────────────────────────────────────────────────

    /// The player selected a deck for the current game.  Contains the raw
    /// deckstring so DeckStore can look up or import the deck automatically.
    case deckSelected(deckstring: String, name: String)

    // ── Sentinel / diagnostics ────────────────────────────────────────────────

    /// A line the parser recognised as belonging to a known log section but
    /// could not fully parse.  Carrying the raw line aids debugging without
    /// crashing the pipeline.
    case parseWarning(line: String, reason: String)
}

// MARK: - Supporting types

/// Hearthstone scenes reported by LoadingScreen.log.
public enum HSScene: String, Sendable, Hashable {
    case login = "Login"
    case hub = "Hub"
    case gameplay = "GamePlay"
    case deckBuilder = "DeckBuilder"
    case collectionManager = "CollectionManager"
    case packOpening = "PackOpening"
    case tournament = "Tournament"
    case friendly = "Friendly"
    case adventure = "Adventure"
    case tavern = "TavernBrawl"
    case battlegrounds = "Battlegrounds"
    case unknown = "Unknown"
}

/// The type of a Choices packet — determines how the UI should respond.
public enum ChoiceType: String, Sendable, Hashable {
    case mulligan = "MULLIGAN"
    case general = "GENERAL"  // Discover, Choose One, etc.
}
