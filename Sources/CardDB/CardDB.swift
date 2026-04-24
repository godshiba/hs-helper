// Sources/CardDB/CardDB.swift
// Actor-isolated card database.
// On first launch: downloads cards.collectible.json from HearthstoneJSON CDN,
// caches to Application Support, builds two in-memory indexes.
// On subsequent launches: loads from cache, revalidates in the background with ETag.

import Foundation

// MARK: - CardDB

/// Thread-safe card database.  All state is actor-isolated.
///
/// Usage:
/// ```swift
/// let db = CardDB()
/// try await db.load()
/// let card = db.card(id: "EX1_066")   // Acidic Swamp Ooze
/// ```
public actor CardDB {

    // MARK: Public state

    /// True once `load()` has successfully populated the indexes.
    public private(set) var isLoaded: Bool = false

    /// The locale used when fetching card data.
    public let locale: String

    // MARK: Private indexes

    private var byId: [String: Card] = [:]  // "EX1_066" → Card
    private var byDbfId: [Int: Card] = [:]  // 1440      → Card

    // MARK: Constants

    private static let apiBase = "https://api.hearthstonejson.com/v1/latest"
    private static let artBase = "https://art.hearthstonejson.com/v1/tiles"
    // Use cards.json (full list) not cards.collectible.json — Hearthstone's
    // deckstrings include non-collectible cards for certain mechanics (e.g.
    // Rogue's Imbue-Travel "King Llane" line), which the collectible-only
    // file omits, leaving the deck tracker short two entries.
    private var cacheFile: String { "cards-\(locale).json" }
    private var etagFile: String { "cards-\(locale).etag" }

    // MARK: Init

    public init(locale: String? = nil) {
        self.locale = locale ?? Self.defaultLocale()
    }

    /// Pick the best HearthstoneJSON locale for the user's system language.
    /// HS uses dash-less codes like "ruRU", "enUS", "deDE"…
    private static func defaultLocale() -> String {
        if let override = UserDefaults.standard.string(forKey: "hs-helper.gameLanguage"),
            !override.isEmpty, override != "System"
        {
            return override
        }
        let preferred = Locale.preferredLanguages.first ?? "en-US"
        let code = preferred.replacingOccurrences(of: "-", with: "_")
        let map: [String: String] = [
            "ru": "ruRU", "ru_RU": "ruRU",
            "en": "enUS", "en_US": "enUS", "en_GB": "enGB",
            "de": "deDE", "de_DE": "deDE",
            "es": "esES", "es_ES": "esES", "es_MX": "esMX",
            "fr": "frFR", "fr_FR": "frFR",
            "it": "itIT", "it_IT": "itIT",
            "ja": "jaJP", "ja_JP": "jaJP",
            "ko": "koKR", "ko_KR": "koKR",
            "pl": "plPL", "pl_PL": "plPL",
            "pt": "ptBR", "pt_BR": "ptBR", "pt_PT": "ptBR",
            "th": "thTH", "th_TH": "thTH",
            "zh_Hant": "zhTW", "zh_TW": "zhTW",
            "zh_Hans": "zhCN", "zh_CN": "zhCN",
        ]
        if let hit = map[code] { return hit }
        if let hit = map[String(code.prefix(2))] { return hit }
        return "enUS"
    }

    // MARK: - Public API

    /// Load the card database.
    /// 1. If a valid on-disk cache exists, load it immediately (fast path).
    /// 2. Revalidate the cache against the CDN in the background using ETag.
    /// 3. If no cache exists, block until the download finishes.
    public func load() async throws {
        if let cached = loadFromDisk() {
            index(cached)
            isLoaded = true
            // Revalidate in background — don't block the caller.
            Task { try? await self.revalidate() }
        } else {
            var lastError: Error?
            for attempt in 1...3 {
                do {
                    let cards = try await fetchFromNetwork(etag: nil)
                    index(cards)
                    saveToDisk(cards)
                    isLoaded = true
                    return
                } catch {
                    lastError = error
                    if attempt < 3 {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                    }
                }
            }
            throw lastError ?? CardDBError.invalidResponse
        }
    }

    /// Look up a card by its string identifier (the value that appears in Power.log).
    public func card(id: String) -> Card? {
        byId[id]
    }

    /// Look up a card by its numeric database ID (used in deckstrings).
    public func card(dbfId: Int) -> Card? {
        byDbfId[dbfId]
    }

    /// Return all cards matching a predicate — for deck editor search.
    public func cards(matching predicate: @Sendable (Card) -> Bool) -> [Card] {
        byId.values.filter(predicate).sorted {
            $0.cost != $1.cost ? $0.cost < $1.cost : $0.name < $1.name
        }
    }

    /// All collectible cards for a specific class (includes neutral).
    public func cards(for cardClass: CardClass) -> [Card] {
        cards { $0.collectible && ($0.cardClass == cardClass || $0.cardClass == .neutral) }
    }

    /// Resolve a list of (dbfId, count) pairs into DeckEntry values.
    /// Returns nil for any dbfId not found in the database.
    public func resolve(pairs: [(dbfId: Int, count: Int)]) -> [DeckEntry] {
        pairs.compactMap { pair in
            guard let card = byDbfId[pair.dbfId] else { return nil }
            return DeckEntry(card: card, count: pair.count)
        }
    }

    /// Force a fresh fetch from the CDN, bypassing the ETag check.
    /// Used when a deck resolves partially, implying new-set cards aren't
    /// yet in the local cache.
    public func refreshFromNetwork() async {
        do {
            let cards = try await fetchFromNetwork(etag: nil)
            index(cards)
            saveToDisk(cards)
        } catch {
            // Non-fatal: keep the existing cache.
        }
    }

    /// Total number of indexed cards.
    public var cardCount: Int { byId.count }

    // MARK: - Indexing

    private func index(_ cards: [Card]) {
        byId.removeAll(keepingCapacity: true)
        byDbfId.removeAll(keepingCapacity: true)
        for card in cards {
            byId[card.id] = card
            byDbfId[card.dbfId] = card
        }
    }

    // MARK: - Network

    /// Fetch cards from the HearthstoneJSON CDN.
    /// Pass a cached ETag to use conditional GET (304 = no update needed).
    private func fetchFromNetwork(etag: String?) async throws -> [Card] {
        let url = URL(string: "\(Self.apiBase)/\(locale)/cards.json")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("hs-helper/1.0", forHTTPHeaderField: "User-Agent")
        if let etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw CardDBError.invalidResponse
        }

        switch http.statusCode {
        case 200:
            let cards = try JSONDecoder().decode([Card].self, from: data)
            // Persist new ETag if present.
            if let newEtag = http.value(forHTTPHeaderField: "ETag") {
                saveEtag(newEtag)
            }
            return cards

        case 304:
            // Cache is still fresh — nothing to do.
            throw CardDBError.notModified

        default:
            throw CardDBError.httpError(http.statusCode)
        }
    }

    /// Check the CDN for updates using the stored ETag.
    /// Silently swallows `.notModified` — that is the happy path.
    private func revalidate() async throws {
        let etag = loadEtag()
        do {
            let cards = try await fetchFromNetwork(etag: etag)
            index(cards)
            saveToDisk(cards)
        } catch CardDBError.notModified {
            // Cache is current — nothing to do.
        }
    }

    // MARK: - Disk cache

    private static var cacheDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("hs-helper/CardCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var cacheURL: URL {
        Self.cacheDirectory.appendingPathComponent(cacheFile)
    }

    private var etagURL: URL {
        Self.cacheDirectory.appendingPathComponent(etagFile)
    }

    private func loadFromDisk() -> [Card]? {
        guard FileManager.default.fileExists(atPath: cacheURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: cacheURL)
            return try JSONDecoder().decode([Card].self, from: data)
        } catch {
            // Corrupted cache — delete and re-download.
            try? FileManager.default.removeItem(at: cacheURL)
            return nil
        }
    }

    private func saveToDisk(_ cards: [Card]) {
        if let data = try? JSONEncoder().encode(cards) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }

    private func loadEtag() -> String? {
        try? String(contentsOf: etagURL, encoding: .utf8)
    }

    private func saveEtag(_ etag: String) {
        try? etag.write(to: etagURL, atomically: true, encoding: .utf8)
    }
}

// MARK: - Image cache

extension CardDB {

    /// Returns the cached tile image data for a card, downloading it if needed.
    /// Tile images are small (~8 KB) horizontal bar images used in the deck tracker rows.
    public func tileImageData(for cardId: String) async -> Data? {
        let cacheURL = Self.tileCacheURL(for: cardId)

        // Cache hit.
        if let data = try? Data(contentsOf: cacheURL) {
            return data
        }

        // Download.
        guard let url = URL(string: "\(Self.artBase)/\(cardId).png") else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
            (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }

        // Persist asynchronously — failure is non-fatal.
        try? data.write(to: cacheURL, options: .atomic)
        return data
    }

    private static func tileCacheURL(for cardId: String) -> URL {
        let dir = cacheDirectory.appendingPathComponent("Tiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(cardId).png")
    }
}

// MARK: - CardDBError

public enum CardDBError: Error, LocalizedError {
    case invalidResponse
    case notModified
    case httpError(Int)
    case decodingFailed(Error)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid HTTP response from HearthstoneJSON"
        case .notModified: return "Card data is up to date (304)"
        case .httpError(let code): return "HearthstoneJSON returned HTTP \(code)"
        case .decodingFailed(let e): return "Failed to decode card JSON: \(e.localizedDescription)"
        }
    }
}
