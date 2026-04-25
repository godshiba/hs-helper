// Sources/GameState/StatsStore.swift
// Persists per-game records to ~/Library/Application Support/hs-helper/stats.json.
// StatsStore is an actor — all disk I/O is serialised off the main thread.

import CardDB
import Foundation

// MARK: - GameRecord

/// A compact, Codable snapshot of a completed game.
/// Stored by StatsStore; loaded for the history view and win-rate stats.
public struct GameRecord: Codable, Sendable, Identifiable {

    public let id: UUID
    public let date: Date
    public let result: GameResult
    public let ownClass: CardClass
    public let opponentClass: CardClass
    public let deckName: String
    public let turns: Int
    public let durationSeconds: Double
    public let format: Format
    public let mode: GameMode

    // MARK: init from Game

    public static func from(game: Game) -> GameRecord {
        let duration = game.endedAt.map { $0.timeIntervalSince(game.startedAt) } ?? 0
        return GameRecord(
            id: game.matchID,
            date: game.startedAt,
            result: game.result,
            ownClass: game.player.heroClass,
            opponentClass: game.opponent.heroClass,
            deckName: game.player.deckName ?? "",
            turns: max(1, (game.turn + 1) / 2),
            durationSeconds: duration,
            format: game.format,
            mode: game.gameMode
        )
    }

    // MARK: Computed helpers

    public var resultEmoji: String {
        switch result {
        case .won: return "W"
        case .lost: return "L"
        case .tied: return "T"
        default: return "?"
        }
    }
}

// MARK: - StatsStore

/// Persists `GameRecord` values to disk as a JSON array.
/// Keeps the last 500 records; older entries are dropped.
public actor StatsStore {

    public static let shared = StatsStore()

    private let maxRecords = 500
    private(set) var records: [GameRecord] = []
    private var loaded = false

    private var fileURL: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let dir = support.appendingPathComponent("hs-helper", isDirectory: true)
        return dir.appendingPathComponent("stats.json")
    }

    // MARK: - Public API

    public func save(game: Game) async {
        guard game.phase == .gameOver || game.result != .unknown else { return }
        await loadIfNeeded()
        let record = GameRecord.from(game: game)
        records.removeAll { $0.id == record.id }
        records.insert(record, at: 0)
        if records.count > maxRecords {
            records = Array(records.prefix(maxRecords))
        }
        persist()
    }

    public func allRecords() async -> [GameRecord] {
        await loadIfNeeded()
        return records
    }

    /// Win rate for a given class (nil = all classes).
    public func winRate(for heroClass: CardClass? = nil) async -> Double {
        await loadIfNeeded()
        let filtered = heroClass.map { cls in records.filter { $0.ownClass == cls } } ?? records
        let decided = filtered.filter { $0.result == .won || $0.result == .lost }
        guard !decided.isEmpty else { return 0 }
        let wins = decided.filter { $0.result == .won }.count
        return Double(wins) / Double(decided.count)
    }

    // MARK: - Private

    private func loadIfNeeded() async {
        guard !loaded else { return }
        loaded = true
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            records = try JSONDecoder().decode([GameRecord].self, from: data)
        } catch {
            records = []
        }
    }

    private func persist() {
        let url = fileURL
        let snapshot = records
        Task.detached {
            do {
                let dir = url.deletingLastPathComponent()
                try FileManager.default.createDirectory(
                    at: dir, withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                // Non-fatal — stats loss is annoying but not a crash.
            }
        }
    }
}
