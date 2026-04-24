// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "hs-helper",
    platforms: [
        .macOS(.v15)
    ],
    targets: [

        // MARK: - App (entry point, wires everything)
        .executableTarget(
            name: "App",
            dependencies: [
                "HSLogTailer",
                "HSLogParser",
                "GameState",
                "CardDB",
                "DeckStore",
                "Overlay",
                "TrackerUI",
                "Settings",
            ],
            path: "Sources/App",
            resources: [
                .process("Resources")
            ]
        ),

        // MARK: - HSLogTailer
        // Kernel-level file tail via DispatchSource + FSEvents fallback.
        // Emits raw log lines via AsyncStream. Knows nothing about cards or game state.
        .target(
            name: "HSLogTailer",
            path: "Sources/HSLogTailer"
        ),

        // MARK: - HSLogParser
        // Converts raw log lines into typed LogEvent values.
        // Owns the GameTag / Zone / BlockType enums used everywhere downstream.
        // Pure state machine — no I/O, trivially testable.
        .target(
            name: "HSLogParser",
            path: "Sources/HSLogParser"
        ),

        // MARK: - GameState
        // Pure reducer: (inout Game, LogEvent) -> Void.
        // Owns the Game / Side / Entity / Deck models.
        // @Observable GameController drives UI observation.
        .target(
            name: "GameState",
            dependencies: [
                "HSLogTailer",
                "HSLogParser",
                "CardDB",
            ],
            path: "Sources/GameState"
        ),

        // MARK: - CardDB
        // Loads HearthstoneJSON, indexes cards by id string and dbfId int.
        // Downloads and caches card art. Actor-isolated for safe concurrent access.
        .target(
            name: "CardDB",
            path: "Sources/CardDB"
        ),

        // MARK: - DeckStore
        // SwiftData persistence for saved decks.
        // Implements the Hearthstone deckstring codec (varint + base64).
        .target(
            name: "DeckStore",
            dependencies: [
                "CardDB",
            ],
            path: "Sources/DeckStore"
        ),

        // MARK: - Overlay
        // NSPanel subclass that floats above Hearthstone at .statusBar level.
        // Handles fullscreen-auxiliary behaviour, monitor persistence, drag-to-reposition.
        .target(
            name: "Overlay",
            path: "Sources/Overlay"
        ),

        // MARK: - TrackerUI
        // SwiftUI views: deck list panel, opponent panel, card rows, mana curve.
        // Observes GameState; never mutates it.
        .target(
            name: "TrackerUI",
            dependencies: [
                "HSLogTailer",
                "GameState",
                "CardDB",
                "Settings",
            ],
            path: "Sources/TrackerUI"
        ),

        // MARK: - Settings
        // Writes log.config on first launch, exposes preferences window,
        // manages monitor selection and overlay lock toggle.
        .target(
            name: "Settings",
            dependencies: [
                "DeckStore",
            ],
            path: "Sources/Settings"
        ),

        // MARK: - Tests

        .testTarget(
            name: "HSLogParserTests",
            dependencies: ["HSLogParser"],
            path: "Tests/HSLogParserTests",
            resources: [
                .copy("Fixtures")
            ]
        ),

        .testTarget(
            name: "GameStateTests",
            dependencies: ["GameState"],
            path: "Tests/GameStateTests",
            resources: [
                .copy("Fixtures")
            ]
        ),
    ]
)
