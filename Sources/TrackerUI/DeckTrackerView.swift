// Sources/TrackerUI/DeckTrackerView.swift
// SwiftUI views for the hs-helper overlay.
// Matches the concept in pencil-new.pen — two 240pt side panels that
// sit in the Hearthstone UI's left/right safe zones.
//
// View hierarchy:
//   DeckTrackerView      — right-side "own deck" panel
//   OpponentPanelView    — left-side "opponent" panel
//   MatchResultBanner    — shown at game end
//
// Both panels observe GameController (@Observable); neither mutates it.

import CardDB
import GameState
import SwiftUI
import Observation

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Localisation Helper
// ═══════════════════════════════════════════════════════════════════════════════

extension String {
    var localized: String {
        Translations.translate(self)
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Design tokens (pencil-new.pen)
// ═══════════════════════════════════════════════════════════════════════════════

private enum Tokens {
    static let panelWidth: CGFloat = 240
    static let panelFill = Color(hex: "#0E1117E6")
    static let panelStroke = Color(hex: "#2A3142")
    static let rowFill = Color(hex: "#121623")
    static let rowDrawnFill = Color(hex: "#0E121C")
    static let rowJustDrewFill = Color(hex: "#12231A")
    static let rowJustDrewStroke = Color(hex: "#3A8C2F")
    static let statsFill = Color(hex: "#1A2030")
    static let footerFill = Color(hex: "#181C26")
    static let sectionLabel = Color(hex: "#6A7182")
    static let textPrimary = Color(hex: "#F5F5F7")
    static let textSecondary = Color(hex: "#A8B0BD")
    static let textTertiary = Color(hex: "#8E8E93")
    static let accentBlue = Color(hex: "#4D9FFF")
    static let accentAmber = Color(hex: "#D4A04C")
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - DeckTrackerView (right: own deck)
// ═══════════════════════════════════════════════════════════════════════════════

public struct DeckTrackerView: View {

    public let gameController: GameController

    public init(gameController: GameController) {
        self.gameController = gameController
    }

    public var body: some View {
        if let game = gameController.currentGame {
            OwnDeckPanel(game: game)
        } else {
            WaitingPanel(side: .player)
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - OpponentPanelView (left: opponent)
// ═══════════════════════════════════════════════════════════════════════════════

public struct OpponentPanelView: View {

    public let gameController: GameController

    public init(gameController: GameController) {
        self.gameController = gameController
    }

    public var body: some View {
        if let game = gameController.currentGame {
            OpponentPanel(game: game, cardDB: gameController.cardDB)
        } else {
            WaitingPanel(side: .opponent)
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - OwnDeckPanel
// ═══════════════════════════════════════════════════════════════════════════════

struct OwnDeckPanel: View {

    let game: Game

    private var remainingCards: [TrackedCard] {
        game.player.remainingDeck
            .filter { !$0.isCreated || $0.count > 0 }
            .sorted {
                if $0.card.cost != $1.card.cost { return $0.card.cost < $1.card.cost }
                return $0.card.name < $1.card.name
            }
    }

    private var totalRemaining: Int {
        game.entities(in: .deck, for: .player).count
    }

    private var deckCapacity: Int {
        let deckListSum = game.player.deckList.reduce(0) { $0 + $1.count }
        return deckListSum > 0 ? deckListSum : 30
    }

    private var subtitle: String {
        let formatName =
            game.format == .unknown ? "Constructed".localized : game.format.displayName.localized
        return "\(formatName) · \(totalRemaining)"
    }

    private var topDeckOdds: Int {
        // Chance to draw any specific singleton copy on next draw.
        guard totalRemaining > 0 else { return 0 }
        return Int((100.0 / Double(totalRemaining)).rounded())
    }

    @AppStorage("hs-helper.showResourcesRow") private var showResourcesRow = true

    var body: some View {
        PanelShell {
            VStack(alignment: .leading, spacing: 10) {

                PanelHeader(
                    initial: initial(for: game.player.heroClass),
                    gradient: ownGradient,
                    title: deckTitle,
                    subtitle: subtitle
                )

                if showResourcesRow {
                    StatsRow(
                        icon: "bolt.fill",
                        iconColor: Tokens.accentBlue,
                        label: "Top deck odds".localized,
                        trailing: "\(topDeckOdds)%",
                        trailingColor: Tokens.accentBlue
                    )
                    if game.counters.playerSpellsPlayed > 0
                        || game.counters.playerMinionsKilled > 0
                    {
                        StatsRow(
                            icon: "wand.and.stars",
                            iconColor: Tokens.textSecondary,
                            label: "\("Spells".localized): \(game.counters.playerSpellsPlayed)",
                            trailing:
                                "\("Deaths".localized): \(game.counters.playerMinionsKilled + game.counters.opponentMinionsKilled)",
                            trailingColor: Tokens.textSecondary
                        )
                    }
                }

                SectionLabel(text: "\("DECK".localized) (\(totalRemaining) / \(deckCapacity))")

                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 3) {
                        ForEach(remainingCards) { tracked in
                            CardRow(
                                cost: tracked.card.cost,
                                name: tracked.card.name,
                                state: rowState(for: tracked),
                                trailing: trailing(for: tracked),
                                costColor: costColor(for: tracked.card.rarity)
                            )
                        }
                    }
                    .padding(.trailing, 2)
                    .contentShape(Rectangle())
                }

                Spacer(minLength: 0)
            }
        }
    }

    private var deckTitle: String {
        if let name = game.player.deckName, !name.isEmpty {
            return name
        }
        let cls = game.player.heroClass
        return cls == .neutral || cls == .invalid
            ? "Your Deck".localized
            : "\(cls.displayName.localized) \("Deck".localized)"
    }

    private var ownGradient: LinearGradient {
        LinearGradient(
            colors: [Color(hex: "#1C4F1A"), Color(hex: "#3A8C2F")],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func rowState(for tracked: TrackedCard) -> CardRow.RowState {
        if tracked.count <= 0 { return .drawn }
        if tracked.drawnCount > 0 { return .justDrew }
        return .normal
    }

    private func trailing(for tracked: TrackedCard) -> CardRow.Trailing {
        if tracked.isCreated {
            return tracked.count >= 2 ? .labelAndCount("GEN", tracked.count) : .label("GEN")
        }
        let originalCount = tracked.count + tracked.drawnCount
        guard originalCount >= 2, tracked.count > 0 else { return .none }
        return .count(tracked.count)
    }

    private func costColor(for rarity: Rarity) -> Color {
        rarity == .legendary ? Color(hex: "#E0A030") : Tokens.textPrimary
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - OpponentPanel
// ═══════════════════════════════════════════════════════════════════════════════

struct OpponentPanel: View {

    let game: Game
    let cardDB: CardDB

    @State private var groupedCards: [TrackedCard] = []
    @State private var knownHand: [TrackedCard] = []
    @State private var lastPlayedName: String = ""
    @State private var lastPlayedTurn: Int = 0

    private var handCount: Int {
        let dynamicCount = game.entities(in: .hand, for: .opponent).count
        return dynamicCount > 0 ? dynamicCount : game.opponent.hand.count
    }
    private var playedCards: [CardPlay] { game.opponent.cardsPlayed }
    private var secrets: [Entity] { game.entities(in: .secret, for: .opponent) }
    private var fatigue: Int { game.opponent.fatigueCounter }
    private var playedCount: Int { game.opponent.cardsPlayed.count }

    @AppStorage("hs-helper.showResourcesRow") private var showResourcesRow = true

    var body: some View {
        PanelShell {
            VStack(alignment: .leading, spacing: 10) {

                PanelHeader(
                    initial: initial(for: game.opponent.heroClass),
                    gradient: oppGradient,
                    title: "Opponent".localized,
                    subtitle:
                        "\(game.opponent.heroClass.displayName.localized) · \("Turn".localized) \(displayTurn)"
                )

                if showResourcesRow {
                    StatsRow(
                        icon: "square.stack.3d.up.fill",
                        iconColor: Tokens.textSecondary,
                        label: "\("Hand".localized) \(handCount)",
                        trailing: fatigue > 0 ? "\("Fatigue".localized) \(fatigue)" : "",
                        trailingColor: fatigue > 0 ? .red : Tokens.textTertiary
                    )
                    if game.counters.opponentSpellsPlayed > 0 {
                        StatsRow(
                            icon: "wand.and.stars",
                            iconColor: Tokens.textSecondary,
                            label: "\("Spells".localized): \(game.counters.opponentSpellsPlayed)",
                            trailing: "",
                            trailingColor: Tokens.textTertiary
                        )
                    }
                }

                if !knownHand.isEmpty {
                    SectionLabel(text: "\("IN HAND".localized) (\(knownHand.count))")
                    LazyVStack(spacing: 3) {
                        ForEach(knownHand) { tracked in
                            CardRow(
                                cost: tracked.card.cost,
                                name: tracked.card.name,
                                state: .normal,
                                trailing: tracked.count >= 2 ? .count(tracked.count) : .none,
                                costColor: Tokens.textPrimary
                            )
                        }
                    }
                }

                SectionLabel(text: "\("CARDS PLAYED".localized) (\(playedCount))")

                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 4) {
                        ForEach(groupedCards) { tracked in
                            CardRow(
                                cost: tracked.card.cost,
                                name: tracked.card.name,
                                state: .normal,
                                trailing: tracked.count >= 2 ? .count(tracked.count) : .none,
                                costColor: Tokens.textPrimary
                            )
                        }
                        if groupedCards.isEmpty {
                            Text("No cards played yet".localized)
                                .font(.system(size: 10))
                                .foregroundStyle(Tokens.textTertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                        }
                    }
                    .padding(.trailing, 2)
                    .contentShape(Rectangle())
                }

                Spacer(minLength: 0)

                // Footer: last played card
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.system(size: 10))
                        .foregroundStyle(Tokens.sectionLabel)
                        .frame(width: 12, height: 12)

                    Text(footerText)
                        .font(.system(size: 10))
                        .foregroundStyle(Tokens.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Tokens.footerFill)
                )
            }
        }
        .task(id: game.opponent.cardsPlayed.count) {
            await resolvePlayedCards()
        }
        .task(id: Set(game.opponent.knownInHand.values)) {
            await resolveKnownHand()
        }
    }

    private var footerText: String {
        lastPlayedName.isEmpty
            ? "No plays yet".localized
            : "\("Last:".localized) \(lastPlayedName) (\("Turn".localized) \(lastPlayedTurn))"
    }

    private var displayTurn: Int { max(1, (game.turn + 1) / 2) }

    private var oppGradient: LinearGradient {
        LinearGradient(
            colors: [Color(hex: "#5B3A8C"), Color(hex: "#2A5BB8")],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func resolvePlayedCards() async {
        let plays = game.opponent.cardsPlayed

        var counts: [String: Int] = [:]
        for play in plays { counts[play.cardId, default: 0] += 1 }

        var resolved: [TrackedCard] = []
        for (cardId, count) in counts {
            if let card = await cardDB.card(id: cardId) {
                resolved.append(TrackedCard(card: card, count: count))
            }
        }
        resolved.sort { a, b in
            if a.card.cost != b.card.cost { return a.card.cost < b.card.cost }
            return a.card.name < b.card.name
        }
        self.groupedCards = resolved

        if let last = plays.last {
            let name = await cardDB.card(id: last.cardId)?.name ?? last.cardId
            self.lastPlayedName = name
            self.lastPlayedTurn = max(1, (last.turn + 1) / 2)
        } else {
            self.lastPlayedName = ""
            self.lastPlayedTurn = 0
        }
    }

    private func resolveKnownHand() async {
        let cardIds = Array(game.opponent.knownInHand.values)
        guard !cardIds.isEmpty else {
            self.knownHand = []
            return
        }
        var counts: [String: Int] = [:]
        for cardId in cardIds { counts[cardId, default: 0] += 1 }

        var resolved: [TrackedCard] = []
        for (cardId, count) in counts {
            if let card = await cardDB.card(id: cardId) {
                resolved.append(TrackedCard(card: card, count: count))
            }
        }
        resolved.sort {
            if $0.card.cost != $1.card.cost { return $0.card.cost < $1.card.cost }
            return $0.card.name < $1.card.name
        }
        self.knownHand = resolved
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - PanelShell
// ═══════════════════════════════════════════════════════════════════════════════

/// 240pt-wide side panel chrome used by both sides.
struct PanelShell<Content: View>: View {

    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(14)
            .frame(width: Tokens.panelWidth, alignment: .top)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Tokens.panelFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Tokens.panelStroke, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.66), radius: 24, x: 0, y: 8)
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - PanelHeader (avatar + title + subtitle)
// ═══════════════════════════════════════════════════════════════════════════════

struct PanelHeader: View {

    let initial: String
    let gradient: LinearGradient
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(gradient)
                Text(initial)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tokens.textPrimary)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Tokens.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - StatsRow (pill with icon + label + trailing value)
// ═══════════════════════════════════════════════════════════════════════════════

struct StatsRow: View {

    let icon: String
    let iconColor: Color
    let label: String
    let trailing: String
    let trailingColor: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 14, height: 14)

            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Tokens.textSecondary)
                .lineLimit(1)

            Spacer(minLength: 0)

            Text(trailing)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(trailingColor)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Tokens.statsFill)
        )
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - SectionLabel
// ═══════════════════════════════════════════════════════════════════════════════

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Tokens.sectionLabel)
            .tracking(1)
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - CardRow
// ═══════════════════════════════════════════════════════════════════════════════

struct CardRow: View {

    enum RowState { case normal, drawn, justDrew }
    enum Trailing {
        case none
        case count(Int)
        case label(String)
        case labelAndCount(String, Int)
    }

    let cost: Int
    let name: String
    let state: RowState
    let trailing: Trailing
    let costColor: Color

    @AppStorage("hs-helper.dimExhaustedCards") private var dimExhaustedCards = true

    var body: some View {
        HStack(spacing: 10) {
            Text("\(min(cost, 99))")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(
                    state == .drawn && dimExhaustedCards ? Tokens.textTertiary : costColor
                )
                .frame(width: 16, alignment: .center)

            Text(name)
                .font(.system(size: 11))
                .foregroundStyle(nameColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            trailingView
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(rowFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(rowStroke, lineWidth: state == .justDrew ? 1 : 0)
        )
        .opacity(state == .drawn && dimExhaustedCards ? 0.4 : 1.0)
    }

    @ViewBuilder
    private var trailingView: some View {
        switch trailing {
        case .none:
            EmptyView()
        case .count(let n):
            Text("×\(n)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Tokens.textTertiary)
        case .label(let s):
            Text(s)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(state == .justDrew ? Color(hex: "#7AE06A") : Tokens.textTertiary)
                .tracking(0.3)
        case .labelAndCount(let s, let n):
            HStack(spacing: 4) {
                Text(s)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(
                        state == .justDrew ? Color(hex: "#7AE06A") : Tokens.textTertiary
                    )
                    .tracking(0.3)
                Text("×\(n)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Tokens.textTertiary)
            }
        }
    }

    private var rowFill: Color {
        switch state {
        case .normal: return Tokens.rowFill
        case .drawn: return Tokens.rowDrawnFill
        case .justDrew: return Tokens.rowJustDrewFill
        }
    }

    private var rowStroke: Color {
        state == .justDrew ? Tokens.rowJustDrewStroke : .clear
    }

    private var nameColor: Color {
        switch state {
        case .drawn: return dimExhaustedCards ? Tokens.textTertiary : Tokens.textPrimary
        case .justDrew: return Tokens.textPrimary
        case .normal: return Tokens.textPrimary
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - WaitingPanel (shown while no game is in progress)
// ═══════════════════════════════════════════════════════════════════════════════

struct WaitingPanel: View {

    enum Side { case player, opponent }
    let side: Side

    var body: some View {
        PanelShell {
            VStack(alignment: .leading, spacing: 10) {
                PanelHeader(
                    initial: "—",
                    gradient: LinearGradient(
                        colors: [Color(hex: "#2A3142"), Color(hex: "#1A2030")],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    title: side == .player ? "Your Deck".localized : "Opponent".localized,
                    subtitle: "Waiting for game…".localized
                )

                Spacer(minLength: 0)

                HStack(spacing: 6) {
                    Circle()
                        .fill(Tokens.accentAmber)
                        .frame(width: 6, height: 6)
                    Text("Tracking Power.log".localized)
                        .font(.system(size: 10))
                        .foregroundStyle(Tokens.textTertiary)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - MatchResultBanner
// ═══════════════════════════════════════════════════════════════════════════════

public struct MatchResultBanner: View {

    let result: GameResult
    let onDismiss: () -> Void

    public init(result: GameResult, onDismiss: @escaping () -> Void) {
        self.result = result
        self.onDismiss = onDismiss
    }

    public var body: some View {
        PanelShell {
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(color)

                Text(text)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(color)

                Button("Dismiss", action: onDismiss)
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Tokens.textTertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
    }

    private var icon: String {
        switch result {
        case .won: return "crown.fill"
        case .lost: return "xmark.circle.fill"
        case .tied: return "equal.circle.fill"
        case .disconnected: return "wifi.slash"
        case .unknown: return "questionmark.circle"
        }
    }

    private var color: Color {
        switch result {
        case .won: return Color(hex: "#7AE06A")
        case .lost: return Color(hex: "#D43C3C")
        case .tied: return .orange
        default: return Tokens.textTertiary
        }
    }

    private var text: String {
        switch result {
        case .won: return "Victory!"
        case .lost: return "Defeat"
        case .tied: return "Tie"
        case .disconnected: return "Disconnected"
        case .unknown: return "Game Over"
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Helpers
// ═══════════════════════════════════════════════════════════════════════════════

private func initial(for heroClass: CardClass) -> String {
    switch heroClass {
    case .invalid, .neutral: return "?"
    case .demonHunter: return "DH"
    case .deathKnight: return "DK"
    default:
        return String(heroClass.displayName.prefix(1))
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Color(hex:)
// ═══════════════════════════════════════════════════════════════════════════════

extension Color {
    /// Accepts "#RGB", "#RRGGBB", or "#RRGGBBAA".
    init(hex: String) {
        let trimmed = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: trimmed).scanHexInt64(&int)

        let r: UInt64
        let g: UInt64
        let b: UInt64
        let a: UInt64
        switch trimmed.count {
        case 3:
            let rr = (int >> 8) & 0xF
            let gg = (int >> 4) & 0xF
            let bb = int & 0xF
            (r, g, b, a) = (rr * 17, gg * 17, bb * 17, 255)
        case 6:
            (r, g, b, a) = ((int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF, 255)
        case 8:
            (r, g, b, a) = ((int >> 24) & 0xFF, (int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        default:
            (r, g, b, a) = (0, 0, 0, 255)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
