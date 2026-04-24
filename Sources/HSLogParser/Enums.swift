// Sources/HSLogParser/Enums.swift
// All raw-value enums mirror the string identifiers Hearthstone writes into
// Power.log and Zone.log.  Using String raw values means the parser can do a
// single RawRepresentable init — no hand-rolled switch tables.

// MARK: - GameTag

/// The subset of Hearthstone GameTags that the tracker actually cares about.
/// Values are the exact strings that appear after "tag=" in Power.log lines.
/// Unknown / unneeded tags are silently discarded by the parser.
public enum GameTag: String, Sendable, Hashable {

    // ── Zone / position ──────────────────────────────────────────────────────
    case zone               = "ZONE"
    case zonePosition       = "ZONE_POSITION"

    // ── Ownership ────────────────────────────────────────────────────────────
    case controller         = "CONTROLLER"
    case entityId           = "ENTITY_ID"

    // ── Card identity ─────────────────────────────────────────────────────────
    case cardType           = "CARDTYPE"
    case `class`            = "CLASS"
    case rarity             = "RARITY"
    case cost               = "COST"
    case attack             = "ATK"
    case health             = "HEALTH"
    case durability         = "DURABILITY"
    case armor              = "ARMOR"
    case damage             = "DAMAGE"
    case premium            = "PREMIUM"         // golden / diamond
    case linked             = "LINKED_ENTITY"

    // ── Game flow ─────────────────────────────────────────────────────────────
    case playState          = "PLAYSTATE"
    case step               = "STEP"
    case turn               = "TURN"
    case fatigue            = "FATIGUE"
    case numTurnsInPlay     = "NUM_TURNS_IN_PLAY"
    case numAttacksThisTurn = "NUM_ATTACKS_THIS_TURN"

    // ── Keywords ──────────────────────────────────────────────────────────────
    case taunt              = "TAUNT"
    case divineShield       = "DIVINE_SHIELD"
    case charge             = "CHARGE"
    case windfury           = "WINDFURY"
    case megaWindfury       = "MEGA_WINDFURY"
    case stealth            = "STEALTH"
    case poisonous          = "POISONOUS"
    case freeze             = "FREEZE"
    case frozen             = "FROZEN"
    case secret             = "SECRET"
    case quest              = "QUEST"
    case questProgress      = "QUEST_PROGRESS"
    case questProgressTotal = "QUEST_PROGRESS_TOTAL"
    case silenced           = "SILENCED"
    case cantBeAttacked     = "CANT_BE_ATTACKED"
    case cantAttack         = "CANT_ATTACK"
    case exhausted          = "EXHAUSTED"
    case rush               = "RUSH"
    case lifesteal          = "LIFESTEAL"
    case reborn             = "REBORN"
    case echo               = "ECHO"
    case overkill           = "OVERKILL"
    case dormant            = "DORMANT"

    // ── Resources ─────────────────────────────────────────────────────────────
    case resources          = "RESOURCES"
    case resourcesUsed      = "RESOURCES_USED"
    case tempResources      = "TEMP_RESOURCES"
    case overloadedMana     = "OVERLOADED_MANA"
    case overloadOwe        = "OVERLOAD_OWED"
}

// MARK: - Zone

/// All zones a card entity can occupy during a game.
public enum Zone: String, Sendable, Hashable, CaseIterable {
    case deck       = "DECK"
    case hand       = "HAND"
    case play       = "PLAY"
    case graveyard  = "GRAVEYARD"
    case removed    = "REMOVED"
    case setAside   = "SETASIDE"
    case secret     = "SECRET"
    case invalid    = "INVALID"
}

// MARK: - BlockType

/// The type attribute of a BLOCK_START / BLOCK_END pair in Power.log.
/// Tracking block type lets the reducer know *why* a TAG_CHANGE is happening
/// (e.g. a draw vs. a discard vs. a play).
public enum BlockType: String, Sendable, Hashable {
    case attack     = "ATTACK"
    case joust      = "JOUST"
    case power      = "POWER"
    case trigger    = "TRIGGER"
    case deaths     = "DEATHS"
    case play       = "PLAY"
    case fatigue    = "FATIGUE"
    case ritual     = "RITUAL"
    case reveal     = "REVEAL_CARD"
    case gameReset  = "GAME_RESET"
    case unknown    = "UNKNOWN"
}

// MARK: - PlayState

/// The value of the PLAYSTATE tag, written when a game concludes.
public enum PlayState: String, Sendable, Hashable {
    case playing        = "PLAYING"
    case won            = "WON"
    case lost           = "LOST"
    case tied           = "TIED"
    case disconnected   = "DISCONNECTED"
    case conceded       = "CONCEDED"
    case invalid        = "INVALID"
}

// MARK: - Step

/// The STEP tag tracks which phase of the game state machine is active.
/// Monitoring MAIN_READY vs BEGIN_MULLIGAN lets the tracker switch views.
public enum Step: String, Sendable, Hashable {
    case beginFirst         = "BEGIN_FIRST"
    case beginShuffle       = "BEGIN_SHUFFLE"
    case beginDraw          = "BEGIN_DRAW"
    case beginMulligan      = "BEGIN_MULLIGAN"
    case mainBegin          = "MAIN_BEGIN"
    case mainReady          = "MAIN_READY"
    case mainStartTriggers  = "MAIN_START_TRIGGERS"
    case mainStart          = "MAIN_START"
    case mainAction         = "MAIN_ACTION"
    case mainCombat         = "MAIN_COMBAT"
    case mainEnd            = "MAIN_END"
    case mainNext           = "MAIN_NEXT"
    case mainCleanup        = "MAIN_CLEANUP"
    case finalWrapup        = "FINAL_WRAPUP"
    case finalGameover      = "FINAL_GAMEOVER"
    case invalid            = "INVALID"
}

// MARK: - CardType

/// The CARDTYPE tag value, written inside FULL_ENTITY and SHOW_ENTITY blocks.
public enum CardType: String, Sendable, Hashable {
    case invalid        = "INVALID"
    case hero           = "HERO"
    case minion         = "MINION"
    case spell          = "SPELL"
    case enchantment    = "ENCHANTMENT"
    case weapon         = "WEAPON"
    case item           = "ITEM"
    case token          = "TOKEN"
    case heroPower      = "HERO_POWER"
    case location       = "LOCATION"
    case lettuce        = "LETTUCE_ABILITY"
}

// MARK: - Rarity

public enum Rarity: String, Sendable, Hashable {
    case invalid   = "INVALID"
    case common    = "COMMON"
    case free      = "FREE"
    case rare      = "RARE"
    case epic      = "EPIC"
    case legendary = "LEGENDARY"
}

// MARK: - EntityRef
// A Hearthstone entity can be referenced by integer ID or by a special
// named placeholder like "GameEntity" or the player's BattleTag.

public enum EntityRef: Sendable, Hashable {
    case id(Int)
    case name(String)
}
