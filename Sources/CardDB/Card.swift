// Sources/CardDB/Card.swift
// The canonical Card model, populated from HearthstoneJSON (cards.collectible.json).
// All types here are value types and Sendable — safe to pass across actor boundaries.
//
// HearthstoneJSON reference: https://hearthstonejson.com/docs/cards.html

import Foundation

// MARK: - Card

/// A single collectible Hearthstone card as returned by HearthstoneJSON.
/// Fields are named to match the JSON keys exactly so Codable synthesis works
/// with zero custom coding keys.
public struct Card: Codable, Sendable, Hashable, Identifiable {

    // ── Identity ──────────────────────────────────────────────────────────────

    /// String card identifier used in Power.log ("EX1_066", "UNG_027", etc.).
    /// This is the primary key used by the log parser.
    public let id: String

    /// Numeric database ID used in deckstrings (varint-encoded).
    /// This is the primary key used by the deckstring codec.
    public let dbfId: Int

    // ── Display ───────────────────────────────────────────────────────────────

    public let name: String
    public let text: String?
    public let flavorText: String?
    public let artistName: String?

    // ── Stats ─────────────────────────────────────────────────────────────────

    public let cost: Int
    public let attack: Int?
    public let health: Int?
    public let durability: Int?     // weapons
    public let armor: Int?          // hero cards

    // ── Classification ────────────────────────────────────────────────────────

    public let type: CardType
    public let rarity: Rarity
    public let cardClass: CardClass
    public let multiClassGroup: MultiClassGroup?

    /// The expansion / adventure set this card belongs to.
    public let set: CardSet

    /// True for cards that appear in the collection manager.
    /// HearthstoneJSON uses this to filter out hero skins, tokens, etc.
    public let collectible: Bool

    // ── Mechanics ─────────────────────────────────────────────────────────────

    public let mechanics: [String]?
    public let referencedTags: [String]?

    // ── Tribe / race ──────────────────────────────────────────────────────────

    public let race: Race?
    public let races: [Race]?           // multi-tribe (Hearthstone 2023+); unknown entries silently dropped

    // ── Dual-class / linked cards ─────────────────────────────────────────────

    public let classes: [CardClass]?    // non-nil for dual-class cards; unknown entries silently dropped
    public let relatedCardDbfIds: [Int]?

    // MARK: Coding keys
    // HearthstoneJSON uses "cardClass" and "multiClassGroup" etc. — map them here.

    private enum CodingKeys: String, CodingKey {
        case id
        case dbfId
        case name
        case text
        case flavorText
        case artistName
        case cost
        case attack
        case health
        case durability
        case armor
        case type
        case rarity
        case cardClass
        case multiClassGroup
        case set
        case collectible
        case mechanics
        case referencedTags
        case race
        case races
        case classes
        case relatedCardDbfIds
    }

    // Custom init to handle unknown enum values and optional fields gracefully.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        id             = try c.decode(String.self, forKey: .id)
        dbfId          = try c.decode(Int.self,    forKey: .dbfId)
        name           = try c.decodeIfPresent(String.self, forKey: .name)           ?? ""
        text           = try c.decodeIfPresent(String.self, forKey: .text)
        flavorText     = try c.decodeIfPresent(String.self, forKey: .flavorText)
        artistName     = try c.decodeIfPresent(String.self, forKey: .artistName)
        cost           = try c.decodeIfPresent(Int.self,    forKey: .cost)            ?? 0
        attack         = try c.decodeIfPresent(Int.self,    forKey: .attack)
        health         = try c.decodeIfPresent(Int.self,    forKey: .health)
        durability     = try c.decodeIfPresent(Int.self,    forKey: .durability)
        armor          = try c.decodeIfPresent(Int.self,    forKey: .armor)
        type           = try c.decodeIfPresent(CardType.self,       forKey: .type)           ?? .invalid
        rarity         = try c.decodeIfPresent(Rarity.self,         forKey: .rarity)         ?? .free
        cardClass      = try c.decodeIfPresent(CardClass.self,       forKey: .cardClass)      ?? .neutral
        multiClassGroup = try c.decodeIfPresent(MultiClassGroup.self, forKey: .multiClassGroup)
        set            = try c.decodeIfPresent(CardSet.self,         forKey: .set)            ?? .unknown
        collectible    = try c.decodeIfPresent(Bool.self,            forKey: .collectible)    ?? false
        mechanics      = try c.decodeIfPresent([String].self,        forKey: .mechanics)
        referencedTags = try c.decodeIfPresent([String].self,        forKey: .referencedTags)
        race           = try c.decodeIfPresent(Race.self,            forKey: .race)
        relatedCardDbfIds = try c.decodeIfPresent([Int].self,        forKey: .relatedCardDbfIds)

        // Decode races array — skip any unknown tribe values instead of throwing.
        if var raceContainer = try? c.nestedUnkeyedContainer(forKey: .races) {
            var decoded = [Race]()
            while !raceContainer.isAtEnd {
                if let r = try? raceContainer.decode(Race.self) { decoded.append(r) }
                else { _ = try? raceContainer.decode(String.self) }
            }
            races = decoded.isEmpty ? nil : decoded
        } else {
            races = nil
        }

        // Decode classes array — skip unknowns.
        if var classContainer = try? c.nestedUnkeyedContainer(forKey: .classes) {
            var decoded = [CardClass]()
            while !classContainer.isAtEnd {
                if let cl = try? classContainer.decode(CardClass.self) { decoded.append(cl) }
                else { _ = try? classContainer.decode(String.self) }
            }
            classes = decoded.isEmpty ? nil : decoded
        } else {
            classes = nil
        }
    }
}

// MARK: - Card convenience helpers

public extension Card {

    /// True if the card is a minion, spell, weapon, location, or hero card
    /// that would appear in a constructed deck.
    var isDeckable: Bool {
        collectible && type != .enchantment && type != .heroPower
    }

    /// Mana cost clamped to 0–10 for display in the mana curve.
    var clampedCost: Int {
        min(max(cost, 0), 10)
    }

    /// Returns all race labels as a human-readable string.
    /// Prefers `races` (multi-tribe) over the legacy `race` field.
    var raceLabel: String? {
        if let all = races, !all.isEmpty {
            return all.map(\.displayName).joined(separator: "/")
        }
        return race?.displayName
    }

    /// The canonical image URL for this card on the Blizzard CDN via HearthstoneJSON.
    func imageURL(locale: String = "enUS") -> URL? {
        URL(string: "https://art.hearthstonejson.com/v1/render/latest/\(locale)/256x/\(id).png")
    }

    /// Tile (small bar) image URL — used in the deck tracker card rows.
    func tileURL(locale: String = "enUS") -> URL? {
        URL(string: "https://art.hearthstonejson.com/v1/tiles/\(id).png")
    }
}

// MARK: - CardType

public enum CardType: String, Codable, Sendable, Hashable, CaseIterable {
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

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CardType(rawValue: raw) ?? .invalid
    }

    public var displayName: String {
        switch self {
        case .invalid:      return "Invalid"
        case .hero:         return "Hero"
        case .minion:       return "Minion"
        case .spell:        return "Spell"
        case .enchantment:  return "Enchantment"
        case .weapon:       return "Weapon"
        case .item:         return "Item"
        case .token:        return "Token"
        case .heroPower:    return "Hero Power"
        case .location:     return "Location"
        case .lettuce:      return "Lettuce"
        }
    }
}

// MARK: - Rarity

public enum Rarity: String, Codable, Sendable, Hashable, CaseIterable {
    case invalid   = "INVALID"
    case free      = "FREE"
    case common    = "COMMON"
    case rare      = "RARE"
    case epic      = "EPIC"
    case legendary = "LEGENDARY"

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Rarity(rawValue: raw) ?? .invalid
    }

    /// Gem color used in deck tracker row badges.
    public var gemColorHex: String {
        switch self {
        case .invalid, .free:   return "#9E9E9E"
        case .common:           return "#FFFFFF"
        case .rare:             return "#0070FF"
        case .epic:             return "#A335EE"
        case .legendary:        return "#FF8000"
        }
    }

    /// Sort priority — higher = more rare.
    public var sortOrder: Int {
        switch self {
        case .invalid:   return 0
        case .free:      return 1
        case .common:    return 2
        case .rare:      return 3
        case .epic:      return 4
        case .legendary: return 5
        }
    }
}

// MARK: - CardClass

public enum CardClass: String, Codable, Sendable, Hashable, CaseIterable {
    case invalid        = "INVALID"
    case neutral        = "NEUTRAL"
    case druid          = "DRUID"
    case hunter         = "HUNTER"
    case mage           = "MAGE"
    case paladin        = "PALADIN"
    case priest         = "PRIEST"
    case rogue          = "ROGUE"
    case shaman         = "SHAMAN"
    case warlock        = "WARLOCK"
    case warrior        = "WARRIOR"
    case demonHunter    = "DEMONHUNTER"
    case deathKnight    = "DEATHKNIGHT"

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        // HearthstoneJSON uses both "DEMONHUNTER" and "DEMON_HUNTER" across patches.
        switch raw {
        case "DEMON_HUNTER": self = .demonHunter
        case "DEATH_KNIGHT": self = .deathKnight
        default:             self = CardClass(rawValue: raw) ?? .neutral
        }
    }

    public var displayName: String {
        switch self {
        case .invalid:      return "Invalid"
        case .neutral:      return "Neutral"
        case .druid:        return "Druid"
        case .hunter:       return "Hunter"
        case .mage:         return "Mage"
        case .paladin:      return "Paladin"
        case .priest:       return "Priest"
        case .rogue:        return "Rogue"
        case .shaman:       return "Shaman"
        case .warlock:      return "Warlock"
        case .warrior:      return "Warrior"
        case .demonHunter:  return "Demon Hunter"
        case .deathKnight:  return "Death Knight"
        }
    }

    /// HSI class color used for hero portrait tints and UI accents.
    public var colorHex: String {
        switch self {
        case .invalid, .neutral: return "#C8C8C8"
        case .druid:             return "#FF7D0A"
        case .hunter:            return "#ABD473"
        case .mage:              return "#69CCF0"
        case .paladin:           return "#F58CBA"
        case .priest:            return "#FFFFFF"
        case .rogue:             return "#FFF569"
        case .shaman:            return "#0070DE"
        case .warlock:           return "#9482C9"
        case .warrior:           return "#C79C6E"
        case .demonHunter:       return "#A330C9"
        case .deathKnight:       return "#C41E3A"
        }
    }
}

// MARK: - MultiClassGroup

public enum MultiClassGroup: String, Codable, Sendable, Hashable {
    case invalid    = "INVALID"
    case grimy      = "GRIMY_GOONS"
    case jade       = "JADE_LOTUS"
    case kabal      = "KABAL"

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MultiClassGroup(rawValue: raw) ?? .invalid
    }
}

// MARK: - CardSet

public enum CardSet: String, Codable, Sendable, Hashable {
    // Classic / Legacy
    case core           = "CORE"
    case legacy         = "LEGACY"
    case vanilla        = "VANILLA"
    case expert1        = "EXPERT1"         // Classic set

    // Year of the Dragon
    case uldum          = "ULDUM"
    case dalaran        = "DALARAN"
    case troll          = "TROLL"

    // Year of the Phoenix
    case demon          = "DEMON_HUNTER_INITIATE"
    case black          = "BLACK_TEMPLE"
    case scholomance    = "SCHOLOMANCE"
    case darkmoon       = "DARKMOON_FAIRE"

    // Year of the Gryphon
    case barrens        = "THE_BARRENS"
    case stormwind      = "STORMWIND"
    case alterac        = "ALTERAC_VALLEY"

    // Year of the Hydra
    case sunken         = "THE_SUNKEN_CITY"
    case murder         = "MURDER_AT_CASTLE_NATHRIA"
    case maw           = "REVENDRETH"

    // Year of the Wolf
    case titans         = "TITANS"
    case badlands       = "WILD_WEST"
    case whizzBangs     = "WHIZBANGS_WORKSHOP"

    // Year of the Pegasus
    case abyss          = "PERILS_IN_THE_DISLES"
    case greatDark      = "SPACE"
    case raven          = "EVENT"           // various mini-sets

    // Adventures
    case naxx            = "NAXX"
    case gvg             = "GVG"
    case brm             = "BRM"
    case tgt             = "TGT"
    case loe             = "LOE"
    case og              = "OG"
    case kara            = "KARA"
    case gangs           = "GANGS"
    case ungoro          = "UNGORO"
    case icecrown        = "ICECROWN"
    case lootapalooza    = "LOOTAPALOOZA"
    case gilneas         = "GILNEAS"
    case boomsday        = "BOOMSDAY"

    // Battlegrounds / other
    case battlegrounds   = "BATTLEGROUNDS"
    case lettuce         = "LETTUCE"
    case placeholder     = "PLACEHOLDER_202204"

    // Fallback for sets added after this enum was written
    case unknown         = "UNKNOWN"

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CardSet(rawValue: raw) ?? .unknown
    }
}

// MARK: - Race / Tribe

public enum Race: String, Codable, Sendable, Hashable, CaseIterable {
    case invalid    = "INVALID"
    case bloodElf   = "BLOODELF"
    case draenei    = "DRAENEI"
    case dwarf      = "DWARF"
    case gnome      = "GNOME"
    case goblin     = "GOBLIN"
    case human      = "HUMAN"
    case nightElf   = "NIGHTELF"
    case orc        = "ORC"
    case tauren     = "TAUREN"
    case troll      = "TROLL"
    case undead     = "UNDEAD"
    case worgen     = "WORGEN"
    case murloc     = "MURLOC"
    case demon      = "DEMON"
    case mech       = "MECHANICAL"
    case elemental  = "ELEMENTAL"
    case beast      = "BEAST"
    case totem      = "TOTEM"
    case pirate     = "PIRATE"
    case dragon     = "DRAGON"
    case all        = "ALL"
    case quilboar   = "QUILBOAR"
    case naga       = "NAGA"
    case undying    = "UNDYING"
    case halfOrc    = "HALFORC"

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Race(rawValue: raw) ?? .invalid
    }

    public var displayName: String {
        switch self {
        case .invalid:    return "None"
        case .bloodElf:   return "Blood Elf"
        case .draenei:    return "Draenei"
        case .dwarf:      return "Dwarf"
        case .gnome:      return "Gnome"
        case .goblin:     return "Goblin"
        case .human:      return "Human"
        case .nightElf:   return "Night Elf"
        case .orc:        return "Orc"
        case .tauren:     return "Tauren"
        case .troll:      return "Troll"
        case .undead:     return "Undead"
        case .worgen:     return "Worgen"
        case .murloc:     return "Murloc"
        case .demon:      return "Demon"
        case .mech:       return "Mech"
        case .elemental:  return "Elemental"
        case .beast:      return "Beast"
        case .totem:      return "Totem"
        case .pirate:     return "Pirate"
        case .dragon:     return "Dragon"
        case .all:        return "All"
        case .quilboar:   return "Quilboar"
        case .naga:       return "Naga"
        case .undying:    return "Undying"
        case .halfOrc:    return "Half-Orc"
        }
    }
}

// MARK: - Mechanic

/// A safe array decoder that skips elements whose raw value is unrecognised
/// rather than throwing and failing the entire card decode.
@propertyWrapper
public struct LossyCodableArray<Element: Codable>: Codable, Sendable where Element: Sendable {
    public var wrappedValue: [Element]

    public init(wrappedValue: [Element]) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements  = [Element]()
        while !container.isAtEnd {
            // Attempt to decode each element; skip on failure.
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                // Advance past the bad element.
                _ = try? container.decode(AnyCodable.self)
            }
        }
        wrappedValue = elements
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}

/// Minimal type-erased Codable used to advance past unknown JSON values.
private struct AnyCodable: Codable {}

public enum Mechanic: String, Codable, Sendable, Hashable {
    case adaptable          = "ADAPT"
    case aiEnchantment      = "AI_MUST_PLAY"
    case autoAttack         = "AUTOATTACK"
    case battlecry          = "BATTLECRY"
    case cantBeSilenced     = "CANT_BE_SILENCED"
    case charge             = "CHARGE"
    case choose             = "CHOOSE_ONE"
    case combo              = "COMBO"
    case counter            = "COUNTER"
    case deathrattle        = "DEATHRATTLE"
    case discover           = "DISCOVER"
    case divineShield       = "DIVINE_SHIELD"
    case echo               = "ECHO"
    case enrage             = "ENRAGE"
    case forgetful          = "FORGETFUL"
    case freeze             = "FREEZE"
    case immune             = "IMMUNE"
    case immuenWhileAttack  = "ImmuneToSpellpower"
    case inspire            = "INSPIRE"
    case jade               = "JADE_GOLEM"
    case kazakusPotion      = "KAZAKUS_POTION"
    case lifesteal          = "LIFESTEAL"
    case magnetize          = "MAGNETIC"
    case morph              = "MORPH"
    case multipleChoice     = "MULTIPLY_BUFFS"
    case overkill           = "OVERKILL"
    case overload           = "OVERLOAD"
    case poisonous          = "POISONOUS"
    case quest              = "QUEST"
    case questline          = "QUESTLINE"
    case reborn             = "REBORN"
    case recruit            = "RECRUIT"
    case rush               = "RUSH"
    case secret             = "SECRET"
    case sidequest          = "SIDEQUEST"
    case silence            = "SILENCE"
    case spellburst         = "SPELLBURST"
    case spellPower         = "SPELLPOWER"
    case startOfGame        = "START_OF_GAME"
    case stealth            = "STEALTH"
    case summon             = "SUMMON"
    case taunt              = "TAUNT"
    case topdeck            = "TOPDECK"
    case twinspell          = "TWINSPELL"
    case windfury           = "WINDFURY"
    case megaWindfury       = "MEGA_WINDFURY"
    case outcast            = "OUTCAST"
    case frenzy             = "FRENZY"
    case infuse             = "INFUSE"
    case excavate           = "EXCAVATE"
    case forge              = "FORGE"
    case miniaturize        = "MINIATURIZE"
    case locationPassive    = "LOCATION"
}

// MARK: - DeckEntry

/// A single entry in a constructed deck: a card and how many copies are included.
/// Counts are 1 or 2 for Standard/Wild; can be higher for special formats.
public struct DeckEntry: Sendable, Hashable, Codable, Identifiable {
    public let card: Card
    public var count: Int

    public var id: String { card.id }

    public init(card: Card, count: Int) {
        self.card = card
        self.count = count
    }
}

// MARK: - Format

/// Hearthstone constructed format, encoded in the deckstring header.
public enum Format: Int, Sendable, Codable, Hashable, CaseIterable {
    case unknown    = 0
    case wild       = 1
    case standard   = 2
    case classic    = 3
    case twist      = 4

    public var displayName: String {
        switch self {
        case .unknown:  return "Unknown"
        case .wild:     return "Wild"
        case .standard: return "Standard"
        case .classic:  return "Classic"
        case .twist:    return "Twist"
        }
    }
}
