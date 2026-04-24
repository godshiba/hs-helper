// Sources/App/HSHelperApp.swift
// SwiftUI @main entry point.
// Wires CardDB → GameController → OverlayController → TrackerUI.
// Runs as an .accessory app (no Dock icon) with a menu-bar status item.

import AppKit
import CardDB
import Combine
import DeckStore
import GameState
import HSLogParser
import HSLogTailer
import Observation
import Overlay
import Settings
import SwiftUI
import TrackerUI

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - App entry point
// ═══════════════════════════════════════════════════════════════════════════════

@main
struct HSHelperApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Settings window — opened from the menu-bar item.
        Window("Preferences", id: "preferences") {
            SettingsView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .commandsRemoved()
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - AppDelegate
// ═══════════════════════════════════════════════════════════════════════════════

/// Owns all long-lived objects and wires the full pipeline.
/// Lives on the MainActor because it touches AppKit and SwiftUI.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: Core services

    private let cardDB = CardDB()
    private lazy var gameController = GameController(cardDB: cardDB)
    private let deckStore: DeckStore? = try? DeckStore()
    private let installer = LogConfigInstaller.shared
    private let prefs = AppPreferences.shared

    // Cached on MainActor after async load — avoids crossing actor boundary in sync code.
    private var cardDBLoaded: Bool = false
    private var cardDBCount: Int = 0

    private var prefsCancellable: AnyCancellable?
    private var workspaceCancellable: AnyCancellable?

    // MARK: Overlay

    private let playerOverlay = OverlayController(id: "player")
    private let opponentOverlay = OverlayController(id: "opponent") { screen in
        guard let screen else {
            return NSRect(x: 20, y: 200, width: 240, height: 720)
        }
        let sv = screen.visibleFrame
        let w: CGFloat = 240
        let h: CGFloat = min(720, sv.height - 40)
        // Opponent panel lives on the LEFT safe zone
        let x = sv.minX + 20
        let y = sv.minY + (sv.height - h) / 2
        return NSRect(x: x, y: y, width: w, height: h)
    }

    // MARK: Menu bar

    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("HSHelperApp: applicationDidFinishLaunching started")
        // ── 1. Hide from Dock — we are a pure menu-bar accessory ─────────────
        NSApp.setActivationPolicy(.accessory)

        // ── 2. Install log.config if needed ───────────────────────────────────
        let installResult = installer.ensureInstalled()
        if case .installed = installResult {
            // Config was just written — the user needs to restart HS.
            // We show a notification after the menu bar is set up (below).
        }

        // ── 3. Build the status bar item ──────────────────────────────────────
        setupMenuBar()

        // ── 4. Load card database (async — non-blocking) ──────────────────────
        Task {
            do {
                try await cardDB.load()
                cardDBLoaded = await cardDB.isLoaded
                cardDBCount = await cardDB.cardCount
                updateMenuBar()
                // If a game started before the card DB finished loading,
                // its pending deckstring is still waiting — populate now.
                gameController.retryPopulateRemainingDeckIfNeeded()
            } catch {
                showError("Failed to load card database: \(error.localizedDescription)")
            }
        }

        // ── 5. Show overlays ──────────────────────────────────────────────────
        showOverlays()

        // ── 6. Start tailing Power.log ────────────────────────────────────────
        gameController.start()

        // ── 7. Observe game state changes to update overlays ─────────────────
        startObservingGameController()

        // ── 8. Notify if log.config was just installed ────────────────────────
        if case .installed = installResult {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.showLogConfigInstalledNotice()
            }
        }

        // ── 9. Bind AppPreferences changes ────────────────────────────────────
        prefsCancellable = prefs.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.applyPreferences()
            }
        }

        // ── 10. Instant active app tracking ───────────────────────────────────
        workspaceCancellable = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.applyPreferences()
                }
            }
    }

    private func applyPreferences() {
        playerOverlay.isLocked = prefs.overlayLocked
        opponentOverlay.isLocked = prefs.overlayLocked

        let isRunning = installer.hearthstoneIsRunning
        let isActive = installer.hearthstoneIsActive
        let shouldShow = isRunning && (!prefs.hideInBackground || isActive)

        if !prefs.showOverlay || !shouldShow {
            playerOverlay.hide()
            opponentOverlay.hide()
        } else {
            if !playerOverlay.isVisible {
                showOverlays()
                handlePhaseChange(phase: gameController.currentGame?.phase)
            } else if prefs.showOpponentPanel && !opponentOverlay.isVisible {
                showOverlays()
            } else if !prefs.showOpponentPanel && opponentOverlay.isVisible {
                opponentOverlay.hide()
            }
        }
        updateMenuBar()
    }

    func applicationWillTerminate(_ notification: Notification) {
        gameController.stop()
        playerOverlay.tearDown()
        opponentOverlay.tearDown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Returning false keeps us alive as a menu-bar-only app even after
        // all windows are closed.
        false
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Overlays
    // ═══════════════════════════════════════════════════════════════════════════

    private func showOverlays() {
        guard prefs.showOverlay else { return }

        let screen = prefs.preferredScreen

        // Player deck panel
        playerOverlay.show(
            content: DeckTrackerView()
                .environment(gameController)
                .environmentObject(prefs)
                .draggableOverlay(
                    onDrag: { [weak self] delta in
                        self?.playerOverlay.move(by: delta)
                    },
                    onEnd: { [weak self] in
                        self?.playerOverlay.saveFrameIfNeeded()
                    }
                ),
            on: screen
        )

        // Opponent panel
        if prefs.showOpponentPanel {
            opponentOverlay.show(
                content: OpponentPanelView()
                    .environment(gameController)
                    .environmentObject(prefs)
                    .draggableOverlay(
                        onDrag: { [weak self] delta in
                            self?.opponentOverlay.move(by: delta)
                        },
                        onEnd: { [weak self] in
                            self?.opponentOverlay.saveFrameIfNeeded()
                        }
                    ),
                on: screen
            )
        } else {
            opponentOverlay.hide()
        }

        // Apply lock state from preferences.
        playerOverlay.isLocked = prefs.overlayLocked
        opponentOverlay.isLocked = prefs.overlayLocked
    }

    private func positionOpponentPanel(on screen: NSScreen?) {
        guard let screen else { return }
        let sv = screen.visibleFrame
        let w: CGFloat = 240
        let h: CGFloat = min(720, sv.height - 40)
        // Opponent panel lives on the LEFT safe zone; own deck is on the right.
        let x = sv.minX + 20
        let y = sv.minY + (sv.height - h) / 2
        opponentOverlay.resize(to: CGSize(width: w, height: h))
        opponentOverlay.move(to: CGPoint(x: x, y: y))
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Game state observation
    // ═══════════════════════════════════════════════════════════════════════════

    private var observationTask: Task<Void, Never>? = nil

    private func startObservingGameController() {
        observationTask = Task { [weak self] in
            guard let self else { return }
            // Poll the observable at ~5 Hz — sufficient for UI updates.
            // A proper withObservationTracking loop would be cleaner but
            // requires careful setup across async contexts.
            var lastPhase: GamePhase? = nil
            var lastResult: GameResult? = nil
            var wasRunning = self.installer.hearthstoneIsRunning

            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))

                let phase = self.gameController.currentGame?.phase
                let result = self.gameController.currentGame?.result
                let isRunning = self.installer.hearthstoneIsRunning
                let isActive = self.installer.hearthstoneIsActive

                let shouldShow = isRunning && (!self.prefs.hideInBackground || isActive)

                // Show / hide overlays based on phase.
                if !shouldShow {
                    if self.playerOverlay.isVisible || self.opponentOverlay.isVisible {
                        await MainActor.run {
                            self.playerOverlay.hide()
                            self.opponentOverlay.hide()
                        }
                    }
                    if !isRunning {
                        lastPhase = nil
                    }
                } else {
                    // Re-show overlay if it was hidden (e.g. from backgrounding or launch)
                    if !self.playerOverlay.isVisible, self.prefs.showOverlay {
                        await MainActor.run {
                            self.showOverlays()
                            self.handlePhaseChange(phase: phase)
                        }
                        lastPhase = phase
                    } else if phase != lastPhase {
                        await MainActor.run {
                            self.handlePhaseChange(phase: phase)
                        }
                        lastPhase = phase
                    }
                }

                if result != lastResult || isRunning != wasRunning {
                    await MainActor.run {
                        self.updateMenuBar()
                    }
                    lastResult = result
                    wasRunning = isRunning
                }
            }
        }
    }

    private func handlePhaseChange(phase: GamePhase?) {
        guard prefs.showOverlay else { return }

        switch phase {
        case .none, .waiting:
            // No game — keep overlay visible but showing "waiting" state.
            break

        case .setup, .mulligan, .main:
            if !playerOverlay.isVisible {
                showOverlays()
            }

        case .gameOver:
            // Overlay stays visible to show the result banner.
            break
        }

        updateMenuBar()
    }

    private func handleGameResult(_ result: GameResult) {
        // Persist win/loss to DeckStore if we know which deck was played.
        guard let store = deckStore else { return }

        Task {
            guard let deckstring = gameController.currentGame?.player.pendingDeckstring,
                !deckstring.isEmpty
            else { return }

            // Find the matching deck in the store.
            let decks = (try? store.allDecks()) ?? []
            guard let match = decks.first(where: { $0.deckstring == deckstring }) else { return }

            do {
                switch result {
                case .won: try store.recordWin(for: match)
                case .lost: try store.recordLoss(for: match)
                case .tied: try store.recordTie(for: match)
                default: break
                }
            } catch {
                // Non-fatal — stats update failure shouldn't surface to the user.
                print("[DeckStore] Failed to record result: \(error)")
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Menu bar
    // ═══════════════════════════════════════════════════════════════════════════

    private func setupMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "rectangle.on.rectangle",
                accessibilityDescription: "hs-helper"
            )
            button.image?.isTemplate = true  // adapts to light/dark menu bar
        }

        let menu = NSMenu()

        // Status line
        let statusItem = NSMenuItem(title: "hs-helper — idle", action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        statusItem.tag = MenuTag.status
        menu.addItem(statusItem)

        menu.addItem(.separator())

        // Toggle overlay
        let overlayItem = NSMenuItem(
            title: "Show Overlay",
            action: #selector(toggleOverlay),
            keyEquivalent: "o"
        )
        overlayItem.keyEquivalentModifierMask = [.command, .shift]
        overlayItem.target = self
        overlayItem.state = prefs.showOverlay ? .on : .off
        overlayItem.tag = MenuTag.toggleOverlay
        menu.addItem(overlayItem)

        // Lock / unlock overlay
        let lockItem = NSMenuItem(
            title: prefs.overlayLocked ? "Unlock Overlay Position" : "Lock Overlay Position",
            action: #selector(toggleOverlayLock),
            keyEquivalent: "l"
        )
        lockItem.keyEquivalentModifierMask = [.command, .shift]
        lockItem.target = self
        lockItem.tag = MenuTag.lockOverlay
        menu.addItem(lockItem)

        // Reset overlay position
        let resetItem = NSMenuItem(
            title: "Reset Overlay Position",
            action: #selector(resetOverlayPosition),
            keyEquivalent: ""
        )
        resetItem.target = self
        menu.addItem(resetItem)

        menu.addItem(.separator())

        // Card DB status
        let dbItem = NSMenuItem(title: "Card DB: loading…", action: nil, keyEquivalent: "")
        dbItem.isEnabled = false
        dbItem.tag = MenuTag.cardDB
        menu.addItem(dbItem)

        menu.addItem(.separator())

        // Preferences
        let prefsItem = NSMenuItem(
            title: "Preferences…",
            action: #selector(openPreferences),
            keyEquivalent: ","
        )
        prefsItem.target = self
        menu.addItem(prefsItem)

        menu.addItem(.separator())

        // Quit
        let quitItem = NSMenuItem(
            title: "Quit hs-helper",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)

        item.menu = menu

        self.statusItem = item
        self.statusMenu = menu
    }

    private func updateMenuBar() {
        guard let menu = statusMenu else { return }

        // Status line
        if let statusMenuItem = menu.item(withTag: MenuTag.status) {
            if !installer.hearthstoneIsRunning {
                statusMenuItem.title = "hs-helper — Hearthstone closed"
            } else if let game = gameController.currentGame {
                switch game.phase {
                case .mulligan:
                    statusMenuItem.title = "hs-helper — Mulligan"
                case .main:
                    let remaining = game.player.remainingDeck.reduce(0) { $0 + max(0, $1.count) }
                    statusMenuItem.title = "hs-helper — \(remaining) cards remaining"
                case .gameOver:
                    let resultStr: String
                    switch game.result {
                    case .won: resultStr = "Victory"
                    case .lost: resultStr = "Defeat"
                    case .tied: resultStr = "Tie"
                    default: resultStr = "Game Over"
                    }
                    statusMenuItem.title = "hs-helper — \(resultStr)"
                default:
                    statusMenuItem.title = "hs-helper — In Game"
                }
            } else {
                statusMenuItem.title = "hs-helper — idle"
            }
        }

        // Card DB
        if let dbMenuItem = menu.item(withTag: MenuTag.cardDB) {
            if cardDBLoaded {
                dbMenuItem.title = "Card DB: \(cardDBCount) cards loaded"
            } else {
                dbMenuItem.title = "Card DB: loading…"
            }
        }

        // Overlay toggle state
        if let overlayMenuItem = menu.item(withTag: MenuTag.toggleOverlay) {
            overlayMenuItem.state = prefs.showOverlay ? .on : .off
        }

        // Lock state
        if let lockMenuItem = menu.item(withTag: MenuTag.lockOverlay) {
            lockMenuItem.title =
                prefs.overlayLocked
                ? "Unlock Overlay Position"
                : "Lock Overlay Position"
        }
    }

    // MARK: Menu actions

    @objc private func toggleOverlay() {
        prefs.showOverlay.toggle()

        if prefs.showOverlay {
            showOverlays()
        } else {
            playerOverlay.hide()
            opponentOverlay.hide()
        }

        updateMenuBar()
    }

    @objc private func toggleOverlayLock() {
        prefs.overlayLocked.toggle()
        playerOverlay.isLocked = prefs.overlayLocked
        opponentOverlay.isLocked = prefs.overlayLocked
        updateMenuBar()
    }

    @objc private func resetOverlayPosition() {
        playerOverlay.resetPosition(for: prefs.preferredScreen)
        opponentOverlay.resetPosition(for: prefs.preferredScreen)
    }

    @objc private func openPreferences() {
        NSApp.activate(ignoringOtherApps: true)
        openPreferencesWindowDirectly()
    }

    private var preferencesWindow: NSWindow?

    private func openPreferencesWindowDirectly() {
        if let existing = preferencesWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 360),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "hs-helper Preferences"
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView())
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        preferencesWindow = window
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Notifications / alerts
    // ═══════════════════════════════════════════════════════════════════════════

    private func showLogConfigInstalledNotice() {
        let alert = NSAlert()
        alert.messageText = "Hearthstone logging enabled"
        alert.informativeText =
            "hs-helper has installed the log configuration.\n\nPlease restart Hearthstone to begin tracking."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "hs-helper Error"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Menu tag constants
    // ═══════════════════════════════════════════════════════════════════════════

    private enum MenuTag {
        static let status = 100
        static let toggleOverlay = 101
        static let lockOverlay = 102
        static let cardDB = 103
    }
}
