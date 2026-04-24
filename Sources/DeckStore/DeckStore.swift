// Sources/DeckStore/DeckStore.swift
// SwiftData persistence for saved decks + Hearthstone deckstring codec.
//
// Deckstring format reference: https://hearthsim.info/docs/deckstrings/
// Encoding: base64(varint sequence)
//   [0]  reserved       = 0
//   [1]  version        = 1
//   [2]  format         (1=Wild, 2=Standard, 4=Twist)
//   [n]  hero count     = 1
//   [n]  hero dbfId
//   [n]  single-copy card count
//   [n…] dbfId per card
//   [n]  double-copy card count
//   [n…] dbfId per card
//   [n]  n-of count     (rare; sideboards, duels)
//   [n, n…] dbfId, count pairs

import Foundation
import SwiftData
import CardDB

// MARK: - StoredDeck (SwiftData model)

/// A deck saved by the user, persisted via SwiftData.
@Model
public final class StoredDeck {

    // ── Identity ──────────────────────────────────────────────────────────────

    @Attribute(.unique)
    public var id: UUID

    public var name: String

    /// The raw deckstring (base64-encoded varint sequence).
    /// Source of truth for card list reconstruction.
    public var deckstring: String

    // ── Metadata ──────────────────────────────────────────────────────────────

    public var formatRaw: Int           // Format.rawValue
    public var heroCardId: String       // e.g. "HERO_01"
    public var heroClass: String        // CardClass.rawValue
    public var createdAt: Date
    public var updatedAt: Date

    // ── Stats (updated after each tracked game) ───────────────────────────────

    public var wins: Int
    public var losses: Int
    public var ties: Int

    // ── Computed helpers (NOT stored — derived from deckstring on demand) ─────

    public var format: Format {
        Format(rawValue: formatRaw) ?? .unknown
    }

    public var winRate: Double {
        let played = wins + losses
        guard played > 0 else { return 0 }
        return Double(wins) / Double(played)
    }

    public var gamesPlayed: Int { wins + losses + ties }

    // MARK: Init

    public init(
        id: UUID = UUID(),
        name: String,
        deckstring: String,
        format: Format,
        heroCardId: String,
        heroClass: CardClass
    ) {
        self.id          = id
        self.name        = name
        self.deckstring  = deckstring
        self.formatRaw   = format.rawValue
        self.heroCardId  = heroCardId
        self.heroClass   = heroClass.rawValue
        self.createdAt   = Date()
        self.updatedAt   = Date()
        self.wins        = 0
        self.losses      = 0
        self.ties        = 0
    }
}

// MARK: - DeckStore

/// Manages the SwiftData container and exposes CRUD operations for decks.
///
/// Usage:
/// ```swift
/// let store = try DeckStore()
/// let deck  = try store.importDeckstring("AAECAZ8FAAR...", name: "Aggro Rogue")
/// try store.recordWin(for: deck)
/// ```
@MainActor
public final class DeckStore: ObservableObject {

    public let container: ModelContainer

    /// Convenience accessor for the main context.
    private var context: ModelContext { container.mainContext }

    // MARK: Init

    public init() throws {
        let schema = Schema([StoredDeck.self])
        let config = ModelConfiguration(
            schema: schema,
            url: Self.storeURL,
            allowsSave: true
        )
        self.container = try ModelContainer(for: schema, configurations: config)
    }

    private static var storeURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("hs-helper", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("decks.store")
    }

    // MARK: - CRUD

    /// Fetch all saved decks, ordered by most recently updated.
    public func allDecks() throws -> [StoredDeck] {
        let descriptor = FetchDescriptor<StoredDeck>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }

    /// Import a deckstring.  Decodes it, resolves cards via `cardDB`, persists.
    /// Returns the newly created `StoredDeck`.
    /// Throws `DeckstringError` if the deckstring is malformed.
    /// Throws `DeckstringError.cardNotFound` if any dbfId is absent from `cardDB`.
    @discardableResult
    public func importDeckstring(
        _ deckstring: String,
        name: String,
        cardDB: CardDB
    ) async throws -> StoredDeck {
        let decoded = try DeckstringCodec.decode(deckstring)

        // Resolve hero.
        let heroCard = await cardDB.card(dbfId: decoded.heroDeckId)
        let heroCardId = heroCard?.id ?? ""
        let heroClass  = heroCard.map { deriveClass(from: $0) } ?? .neutral

        let deck = StoredDeck(
            name: name.isEmpty ? "Imported Deck" : name,
            deckstring: deckstring,
            format: decoded.format,
            heroCardId: heroCardId,
            heroClass: heroClass
        )

        context.insert(deck)
        try context.save()
        return deck
    }

    /// Delete a deck from the store.
    public func delete(_ deck: StoredDeck) throws {
        context.delete(deck)
        try context.save()
    }

    /// Rename a deck.
    public func rename(_ deck: StoredDeck, to newName: String) throws {
        deck.name      = newName
        deck.updatedAt = Date()
        try context.save()
    }

    // MARK: - Match result recording

    public func recordWin(for deck: StoredDeck) throws {
        deck.wins      += 1
        deck.updatedAt  = Date()
        try context.save()
    }

    public func recordLoss(for deck: StoredDeck) throws {
        deck.losses    += 1
        deck.updatedAt  = Date()
        try context.save()
    }

    public func recordTie(for deck: StoredDeck) throws {
        deck.ties      += 1
        deck.updatedAt  = Date()
        try context.save()
    }

    // MARK: - Deck resolution

    /// Decode the deckstring of a `StoredDeck` and resolve each card via `cardDB`.
    /// Returns an ordered array of `DeckEntry` values (card + copy count).
    public func entries(for deck: StoredDeck, cardDB: CardDB) async throws -> [DeckEntry] {
        let decoded = try DeckstringCodec.decode(deck.deckstring)
        let pairs   = decoded.singles.map { ($0, 1) } + decoded.doubles.map { ($0, 2) }
        return await cardDB.resolve(pairs: pairs)
    }

    // MARK: - Private helpers

    private func deriveClass(from card: Card) -> CardClass {
        if let classes = card.classes, !classes.isEmpty {
            return classes.first ?? card.cardClass
        }
        return card.cardClass
    }
}

// MARK: - DeckstringCodec

/// Encodes and decodes Hearthstone deckstrings.
///
/// Format:  base64( varint(0), varint(1), varint(format),
///                  varint(1), varint(heroDeckDbfId),
///                  varint(singleCount), varint(dbfId)...,
///                  varint(doubleCount), varint(dbfId)...,
///                  varint(nOfCount),    varint(dbfId), varint(count)... )
public enum DeckstringCodec {

    // MARK: Decoded payload

    public struct DecodedDeck: Sendable {
        public let format:     Format
        public let heroDeckId: Int       // hero dbfId (NOT the hero card played in-game)
        public let singles:    [Int]     // dbfIds with 1 copy
        public let doubles:    [Int]     // dbfIds with 2 copies
        public let nOfs:       [(dbfId: Int, count: Int)]  // dbfIds with 3+ copies

        /// Convenience: all (dbfId, count) pairs.
        public var allPairs: [(dbfId: Int, count: Int)] {
            singles.map { ($0, 1) } +
            doubles.map { ($0, 2) } +
            nOfs.map    { ($0.dbfId, $0.count) }
        }
    }

    // MARK: - Decode

    /// Decode a deckstring into its component parts.
    public static func decode(_ deckstring: String) throws -> DecodedDeck {
        // Deckstrings may contain URL-safe base64 or standard base64.
        let normalised = deckstring
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        // Pad to a multiple of 4 if needed.
        let padded: String
        let remainder = normalised.count % 4
        if remainder == 0 {
            padded = normalised
        } else {
            padded = normalised + String(repeating: "=", count: 4 - remainder)
        }

        guard let data = Data(base64Encoded: padded) else {
            throw DeckstringError.invalidBase64
        }

        var reader = VarintReader(data: data)

        // [0] Reserved — must be 0.
        let reserved = try reader.readVarint()
        guard reserved == 0 else { throw DeckstringError.invalidReservedByte(reserved) }

        // [1] Version — must be 1.
        let version = try reader.readVarint()
        guard version == 1 else { throw DeckstringError.unsupportedVersion(version) }

        // [2] Format.
        let formatRaw = try reader.readVarint()
        let format    = Format(rawValue: formatRaw) ?? .unknown

        // [3] Hero count — always 1 for constructed.
        let heroCount = try reader.readVarint()
        guard heroCount == 1 else { throw DeckstringError.unexpectedHeroCount(heroCount) }

        // [4] Hero dbfId.
        let heroDeckId = try reader.readVarint()

        // Single-copy cards.
        let singleCount = try reader.readVarint()
        var singles = [Int]()
        singles.reserveCapacity(singleCount)
        for _ in 0..<singleCount {
            singles.append(try reader.readVarint())
        }

        // Double-copy cards.
        let doubleCount = try reader.readVarint()
        var doubles = [Int]()
        doubles.reserveCapacity(doubleCount)
        for _ in 0..<doubleCount {
            doubles.append(try reader.readVarint())
        }

        // n-of cards (uncommon; used by sideboards / Duels).
        var nOfs = [(dbfId: Int, count: Int)]()
        if reader.hasBytes {
            let nOfCount = try reader.readVarint()
            for _ in 0..<nOfCount {
                let dbfId = try reader.readVarint()
                let count = try reader.readVarint()
                nOfs.append((dbfId, count))
            }
        }

        return DecodedDeck(
            format:     format,
            heroDeckId: heroDeckId,
            singles:    singles,
            doubles:    doubles,
            nOfs:       nOfs
        )
    }

    // MARK: - Encode

    /// Encode a list of (dbfId, count) pairs and a format into a deckstring.
    /// `heroDeckDbfId` is the *deck hero* dbfId (e.g. the base class hero card),
    /// not the hero skin being used in-game.
    public static func encode(
        heroDeckDbfId: Int,
        format: Format,
        cards: [(dbfId: Int, count: Int)]
    ) throws -> String {
        var singles = [Int]()
        var doubles = [Int]()
        var nOfs    = [(dbfId: Int, count: Int)]()

        for (dbfId, count) in cards {
            switch count {
            case 1:  singles.append(dbfId)
            case 2:  doubles.append(dbfId)
            default: nOfs.append((dbfId, count))
            }
        }

        singles.sort()
        doubles.sort()

        var writer = VarintWriter()

        writer.writeVarint(0)                   // reserved
        writer.writeVarint(1)                   // version
        writer.writeVarint(format.rawValue)     // format
        writer.writeVarint(1)                   // hero count
        writer.writeVarint(heroDeckDbfId)       // hero
        writer.writeVarint(singles.count)
        for id in singles { writer.writeVarint(id) }
        writer.writeVarint(doubles.count)
        for id in doubles { writer.writeVarint(id) }
        writer.writeVarint(nOfs.count)
        for (id, count) in nOfs {
            writer.writeVarint(id)
            writer.writeVarint(count)
        }

        return writer.data.base64EncodedString()
    }
}

// MARK: - Varint primitives

/// Reads LEB128-style varints from a Data buffer.
private struct VarintReader {
    private let data: Data
    private var cursor: Int = 0

    init(data: Data) { self.data = data }

    var hasBytes: Bool { cursor < data.count }

    mutating func readVarint() throws -> Int {
        var result = 0
        var shift  = 0

        while cursor < data.count {
            let byte = Int(data[cursor])
            cursor += 1
            result |= (byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift >= 64 { throw DeckstringError.varintOverflow }
        }

        throw DeckstringError.unexpectedEndOfData
    }
}

/// Writes LEB128-style varints into a growing Data buffer.
private struct VarintWriter {
    var data = Data()

    mutating func writeVarint(_ value: Int) {
        var v = value
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            data.append(byte)
        } while v != 0
    }
}

// MARK: - DeckstringError

public enum DeckstringError: Error, LocalizedError {
    case invalidBase64
    case invalidReservedByte(Int)
    case unsupportedVersion(Int)
    case unexpectedHeroCount(Int)
    case varintOverflow
    case unexpectedEndOfData
    case cardNotFound(dbfId: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidBase64:
            return "The deckstring is not valid base64."
        case .invalidReservedByte(let b):
            return "Expected reserved byte 0, got \(b)."
        case .unsupportedVersion(let v):
            return "Unsupported deckstring version \(v) (expected 1)."
        case .unexpectedHeroCount(let c):
            return "Expected 1 hero in deckstring, got \(c)."
        case .varintOverflow:
            return "Varint value exceeds 64 bits — malformed deckstring."
        case .unexpectedEndOfData:
            return "Deckstring ended before all fields were read."
        case .cardNotFound(let id):
            return "Card with dbfId \(id) not found in the card database."
        }
    }
}
