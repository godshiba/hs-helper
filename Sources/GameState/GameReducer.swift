// Sources/GameState/GameReducer.swift
// Pure reducer:  apply(event:to:)  mutates a Game in place.
// Observable GameController owns the live Game and wires the full pipeline.
//
// Design rules:
//   • apply() is a free function — zero I/O, trivially testable.
//   • GameController is @MainActor + @Observable — SwiftUI observes it directly.
//   • Local-player detection: first player whose FULL_ENTITY deck cards have
//     a non-nil cardId during CREATE_GAME setup is identified as the local player.
//     Falls back to player 1 if ambiguous.

import CardDB
import Foundation
import HSLogParser
import HSLogTailer
import Observation

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Reducer entry point
// ═══════════════════════════════════════════════════════════════════════════════

/// Apply a single `LogEvent` to a `Game`, mutating it in place.
/// This is the only function that may mutate a `Game`.
public func apply(event: LogEvent, to game: inout Game) {
    // Always append to timeline for replay / export.
    game.timeline.append(event)

    switch event {
    case .gameCreated(let gameEntityId):
        handleGameCreated(entityId: gameEntityId, game: &game)

    case .playerCreated(let entityId, let playerId, let accountHi, let accountLo):
        handlePlayerCreated(
            entityId: entityId, playerId: playerId,
            accountHi: accountHi, accountLo: accountLo,
            game: &game
        )

    case .fullEntity(let id, let cardId, let tags):
        handleFullEntity(id: id, cardId: cardId, tags: tags, game: &game)

    case .showEntity(let id, let cardId, let tags):
        handleShowEntity(id: id, cardId: cardId, tags: tags, game: &game)

    case .hideEntity(let id, let zone):
        handleHideEntity(id: id, zone: zone, game: &game)

    case .changeEntity(let id, let cardId, let tags):
        handleChangeEntity(id: id, cardId: cardId, tags: tags, game: &game)

    case .tagChange(let ref, let tag, let value):
        handleTagChange(ref: ref, tag: tag, value: value, game: &game)

    case .blockStart(let type, let entity, let effectCardId, let effectIndex):
        game.blockStack.append(
            Block(
                type: type,
                entity: entity,
                effectCardId: effectCardId,
                effectIndex: effectIndex
            ))

    case .blockEnd:
        if !game.blockStack.isEmpty {
            game.blockStack.removeLast()
        }

    case .choices(let id, let playerName, let choiceType, let entityIds):
        handleChoices(
            id: id, playerName: playerName, choiceType: choiceType,
            entityIds: entityIds, game: &game)

    case .chosenEntities(let choiceId, let entityIds):
        handleChosenEntities(choiceId: choiceId, entityIds: entityIds, game: &game)

    case .gameOver:
        finaliseResult(game: &game)

    case .sceneChanged(let scene):
        if scene == .gameplay {
            // A new game is starting — handled externally by GameController.reset()
        }

    case .deckSelected(let deckstring, let name):
        game.player.pendingDeckstring = deckstring
        game.player.deckName = name

    case .subSpellStart, .subSpellEnd, .metaData, .options, .parseWarning:
        break  // Not needed for deck tracking in v1.
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Individual event handlers
// ═══════════════════════════════════════════════════════════════════════════════

private func handleGameCreated(entityId: Int, game: inout Game) {
    game.gameEntityId = entityId
    game.phase = .setup
    game.startedAt = Date()
    game.matchID = UUID()
    game.blockStack = []

    // Create the GameEntity.
    var ge = Entity(id: entityId)
    ge.tags[.zone] = Zone.play.rawValue
    game.entities[entityId] = ge
}

private func handlePlayerCreated(
    entityId: Int,
    playerId: Int,
    accountHi: Int,
    accountLo: Int,
    game: inout Game
) {
    var entity = Entity(id: entityId)
    entity.tags[.controller] = "\(playerId)"
    game.entities[entityId] = entity

    // We'll resolve which side is local once we see deck entities.
    // For now, store the account pair alongside a provisional mapping.
    if game.player.entityId == 0 {
        game.player.entityId = entityId
        game.player.playerId = playerId
        game.player.accountHi = accountHi
        game.player.accountLo = accountLo
        game.playerIdMap[playerId] = .player
    } else {
        game.opponent.entityId = entityId
        game.opponent.playerId = playerId
        game.opponent.accountHi = accountHi
        game.opponent.accountLo = accountLo
        game.playerIdMap[playerId] = .opponent
    }
}

private func handleFullEntity(
    id: Int,
    cardId: String?,
    tags: [GameTag: String],
    game: inout Game
) {
    let existing = game.entities[id]
    let oldZone = existing?.zone ?? .invalid
    let isNew = existing == nil

    var entity = existing ?? Entity(id: id)
    // Preserve an earlier-revealed cardId — FULL_ENTITY Updating reprints
    // carry `CardID=` empty for still-hidden entities, which would otherwise
    // wipe a cardId set by a prior SHOW_ENTITY.
    if let cid = cardId, !cid.isEmpty {
        entity.cardId = cid
    }
    for (k, v) in tags { entity.tags[k] = v }
    game.entities[id] = entity

    let newZone = entity.zone

    // FULL_ENTITY Updating reprints can move an entity (e.g. a revealed
    // opponent card from HAND to PLAY). Apply the side effect.
    // Mark as "created" (generated by an effect) when an entity spawns directly
    // into HAND, PLAY, or DECK during main phase. Entities during setup/mulligan are
    // normal starting-hand cards and must not be flagged.
    if isNew, game.phase == .main,
        let cid = cardId, !cid.isEmpty,
        newZone == .hand || newZone == .play || newZone == .deck
    {
        entity.info.created = true
        game.entities[id] = entity
    }

    if !isNew && oldZone != newZone {
        handleZoneChange(entityId: id, from: oldZone, to: newZone, game: &game)
    }

    // If this is a brand new entity spawning directly into play, hand, or deck.
    if isNew, let side = game.ownerOf(entityId: id) {
        if newZone == .hand {
            if side == .player {
                if !game.player.hand.contains(id) { game.player.hand.append(id) }
            } else {
                if !game.opponent.hand.contains(id) { game.opponent.hand.append(id) }
            }
        } else if newZone == .play {
            addToBoard(entityId: id, side: side, game: &game)
        } else if newZone == .deck,
            side == .player,
            game.phase == .mulligan || game.phase == .main,
            let cid = cardId, !cid.isEmpty
        {
            returnToDeck(cardId: cid, isCreated: entity.info.created, game: &game)
        }
    }

    // Local-player detection from FULL_ENTITY reveals.
    // The local player's deck cards have a real cardId; the opponent's don't.
    if !game.localSideResolved,
        let cid = cardId, !cid.isEmpty,
        newZone == .deck,
        let controllerStr = tags[.controller] ?? entity.tags[.controller],
        let controllerId = Int(controllerStr)
    {
        if game.playerIdMap[controllerId] == .opponent {
            swapSides(game: &game)
        }
        game.localSideResolved = true
    }

    // Hero: populate heroClass / heroCardId for the owning side.
    applyHeroIfApplicable(entityId: id, game: &game)
}

/// If the entity is a HERO card, copy its class and card id to the side
/// it belongs to. Called from FULL_ENTITY, SHOW_ENTITY and CHANGE_ENTITY
/// handlers — HS can reveal a hero through any of those, and hero skins
/// can also be swapped mid-game via CHANGE_ENTITY (Transfer Student etc.).
private func applyHeroIfApplicable(entityId: Int, game: inout Game) {
    guard let entity = game.entities[entityId] else { return }
    guard entity.tags[.cardType] == "HERO" else { return }
    guard let side = game.ownerOf(entityId: entityId) else { return }
    guard let cid = entity.cardId, !cid.isEmpty else { return }

    let heroClass: CardClass = {
        if let raw = entity.tags[.class], let c = CardClass(rawValue: raw) {
            return c
        }
        return .neutral
    }()

    game.mutateSide(side) { s in
        s.heroCardId = cid
        if heroClass != .neutral {
            s.heroClass = heroClass
        }
    }
}

private func handleShowEntity(
    id: Int,
    cardId: String,
    tags: [GameTag: String],
    game: inout Game
) {
    let existing = game.entities[id]
    let oldZone = existing?.zone ?? .invalid
    let oldCardId = existing?.cardId

    var entity = existing ?? Entity(id: id)
    entity.cardId = cardId
    for (k, v) in tags { entity.tags[k] = v }
    game.entities[id] = entity

    let newZone = entity.zone

    // Local-player detection (definitive signal).
    //
    // Local player detection fallback. The local player's hand is revealed
    // via SHOW_ENTITY almost immediately.
    // Lock immediately after the first hit so later opponent-card reveals
    // (e.g. triggered Discovers) don't re-swap.
    if !game.localSideResolved,
        !cardId.isEmpty,
        cardId != "GAME_005",
        let controllerStr = entity.tags[.controller],
        let controllerId = Int(controllerStr)
    {
        if game.playerIdMap[controllerId] == .opponent {
            swapSides(game: &game)
        }
        game.localSideResolved = true
    }

    // Apply the same zone-transition side effects that TAG_CHANGE would.
    // SHOW_ENTITY frequently carries zone=PLAY for an opponent card being
    // played straight from hand — without this, the card would stay in
    // opponent.hand and the hand count would never decrement.
    if oldZone != newZone {
        handleZoneChange(entityId: id, from: oldZone, to: newZone, game: &game)
    }

    guard let side = game.ownerOf(entityId: id) else { return }

    // If the entity was previously unknown (opponent card revealed),
    // record it in the opponent's revealedCards map.
    if side == .opponent, oldCardId == nil || oldCardId != cardId {
        game.opponent.revealedCards[cardId, default: 0] += 1
    }

    // If it's now in the opponent's hand, track it there too.
    if newZone == .hand, side == .opponent {
        game.opponent.knownInHand[id] = cardId
    }

    applyHeroIfApplicable(entityId: id, game: &game)
}

private func handleHideEntity(id: Int, zone: Zone, game: inout Game) {
    guard var entity = game.entities[id] else { return }
    let oldZone = entity.zone
    entity.tags[.zone] = zone.rawValue
    game.entities[id] = entity

    // Trigger the standard zone-transition side effects. In particular,
    // mulligan replaces emit HIDE_ENTITY for HAND → DECK, and we need
    // `returnToDeck` to run so remainingDeck counts restore correctly.
    if oldZone != zone && oldZone != .invalid {
        handleZoneChange(entityId: id, from: oldZone, to: zone, game: &game)
    }

    if zone == .hand {
        // Card was returned to hand face-down — remove from knownInHand if present.
        if game.ownerOf(entityId: id) == .opponent {
            game.opponent.knownInHand.removeValue(forKey: id)
        }
    }
}

private func handleChangeEntity(
    id: Int,
    cardId: String,
    tags: [GameTag: String],
    game: inout Game
) {
    guard var entity = game.entities[id] else { return }
    let oldZone = entity.zone
    let oldCardId = entity.cardId
    entity.cardId = cardId
    for (k, v) in tags { entity.tags[k] = v }
    game.entities[id] = entity
    let newZone = entity.zone

    if oldZone != newZone {
        handleZoneChange(entityId: id, from: oldZone, to: newZone, game: &game)
    }

    if !game.localSideResolved,
        !cardId.isEmpty,
        cardId != "GAME_005",
        let controllerStr = entity.tags[.controller],
        let controllerId = Int(controllerStr)
    {
        if game.playerIdMap[controllerId] == .opponent {
            swapSides(game: &game)
        }
        game.localSideResolved = true
    }

    // If a local-player card in deck was transformed into a different card,
    // the OLD card left the deck (count--) and the NEW card joined it (count++).
    if let side = game.ownerOf(entityId: id), side == .player,
        entity.zone == .deck, oldCardId != cardId
    {
        if let old = oldCardId, !old.isEmpty,
            let idx = game.player.remainingDeck.firstIndex(where: { $0.card.id == old })
        {
            game.player.remainingDeck[idx].count = max(0, game.player.remainingDeck[idx].count - 1)
        }
        if !cardId.isEmpty,
            let idx = game.player.remainingDeck.firstIndex(where: { $0.card.id == cardId })
        {
            game.player.remainingDeck[idx].count += 1
        }
    }

    applyHeroIfApplicable(entityId: id, game: &game)
}

// ─────────────────────────────────────────────────────────────────────────────
// TAG_CHANGE — the most common and most complex event
// ─────────────────────────────────────────────────────────────────────────────

private func handleTagChange(
    ref: EntityRef,
    tag: GameTag,
    value: String,
    game: inout Game
) {
    let entityId = resolveEntityId(ref: ref, game: game)

    // Update the entity's tag map.
    if let eid = entityId, var entity = game.entities[eid] {
        let oldValue = entity.tags[tag]
        if oldValue == value { return }

        entity.tags[tag] = value
        game.entities[eid] = entity

        handleTagSideEffects(
            entityId: eid,
            tag: tag,
            oldValue: oldValue,
            newValue: value,
            game: &game
        )
    } else {
        // Named entity (GameEntity, player names) — update via the game entity id.
        if case .name(let name) = ref {
            handleNamedEntityTagChange(name: name, tag: tag, value: value, game: &game)
        }
    }
}

/// Called after an entity's tag has been updated in game.entities.
/// Triggers higher-level state transitions (zone moves, phase changes, etc.).
private func handleTagSideEffects(
    entityId: Int,
    tag: GameTag,
    oldValue: String?,
    newValue: String,
    game: inout Game
) {
    switch tag {

    // ── Zone transitions ──────────────────────────────────────────────────────
    case .zone:
        let old = oldValue.flatMap(Zone.init(rawValue:)) ?? .invalid
        let new = Zone(rawValue: newValue) ?? .invalid
        handleZoneChange(entityId: entityId, from: old, to: new, game: &game)

    // ── Step → game phase ─────────────────────────────────────────────────────
    case .step:
        if let gameEntityId = game.gameEntityId, entityId == gameEntityId {
            handleStepChange(step: Step(rawValue: newValue) ?? .invalid, game: &game)
        }

    // ── Turn counter ──────────────────────────────────────────────────────────
    case .turn:
        if let gameEntityId = game.gameEntityId, entityId == gameEntityId,
            let turn = Int(newValue)
        {
            game.turn = turn
        }

    // ── Player health / armor ─────────────────────────────────────────────────
    // (Used for future "health bar" feature; no action needed in v1.)

    // ── Controller change (steal effects) ─────────────────────────────────────
    case .controller:
        if let oldStr = oldValue, let oldId = Int(oldStr),
            let newId = Int(newValue), oldId != newId
        {
            game.entities[entityId]?.info.stolen = true
            game.entities[entityId]?.info.originalController = oldId
        }

    // ── Resources ─────────────────────────────────────────────────────────────
    case .resources:
        if let side = game.ownerOf(entityId: entityId), let v = Int(newValue) {
            game.mutateSide(side) { $0.resources.total = v }
        }
    case .resourcesUsed:
        if let side = game.ownerOf(entityId: entityId), let v = Int(newValue) {
            game.mutateSide(side) { $0.resources.used = v }
        }
    case .tempResources:
        if let side = game.ownerOf(entityId: entityId), let v = Int(newValue) {
            game.mutateSide(side) { $0.resources.temp = v }
        }
    case .overloadedMana:
        if let side = game.ownerOf(entityId: entityId), let v = Int(newValue) {
            game.mutateSide(side) { $0.resources.overloadLocked = v }
        }
    case .overloadOwe:
        if let side = game.ownerOf(entityId: entityId), let v = Int(newValue) {
            game.mutateSide(side) { $0.resources.overloadOwed = v }
        }

    // ── Fatigue ───────────────────────────────────────────────────────────────
    case .fatigue:
        if let side = game.ownerOf(entityId: entityId), let v = Int(newValue) {
            game.mutateSide(side) { $0.fatigueCounter = v }
        }

    // ── PlayState → game result ───────────────────────────────────────────────
    case .playState:
        handlePlayStateChange(entityId: entityId, value: newValue, game: &game)

    // ── Quest progress ────────────────────────────────────────────────────────
    case .questProgress:
        if let side = game.ownerOf(entityId: entityId), let v = Int(newValue) {
            game.mutateSide(side) { $0.questProgress = v }
        }
    case .questProgressTotal:
        if let side = game.ownerOf(entityId: entityId), let v = Int(newValue) {
            game.mutateSide(side) { $0.questProgressTotal = v }
        }

    default:
        break
    }
}

/// TAG_CHANGE on a named entity (GameEntity / player names).
private func handleNamedEntityTagChange(
    name: String,
    tag: GameTag,
    value: String,
    game: inout Game
) {
    // STEP is only emitted on the GameEntity. Always apply.
    if name == "GameEntity", tag == .step, let step = Step(rawValue: value) {
        handleStepChange(step: step, game: &game)
        return
    }

    // TURN is emitted on both GameEntity (the authoritative game turn) and
    // player-name entities (the number of turns THAT player has taken so far).
    // Only the GameEntity value represents the current game turn — applying
    // the per-player value would rewind the displayed turn every time the
    // opponent passed priority.
    if name == "GameEntity", tag == .turn, let v = Int(value) {
        game.turn = v
        return
    }

    // Any other named-entity TAG_CHANGE references a player by BattleTag.
    // Record it so the UI can display the real names instead of placeholders.
    assignPlayerName(name, game: &game)
}

/// Best-effort assignment of a BattleTag to the owning Side.
/// The local player's BattleTag is known (non-UNKNOWN). Opponents begin as
/// "UNKNOWN HUMAN PLAYER" until HS reveals their name partway through the
/// match; once revealed we capture it.
private func assignPlayerName(_ name: String, game: inout Game) {
    guard !name.isEmpty, name != "GameEntity" else { return }

    // Already assigned somewhere?
    if game.player.name == name || game.opponent.name == name { return }

    let isUnknown = name == "UNKNOWN HUMAN PLAYER"

    // Fill any empty slot with a non-unknown name first — those are
    // definitive. Unknown placeholders fill the remaining slot last.
    if !isUnknown {
        if game.player.name.isEmpty {
            game.player.name = name
            return
        }
        if game.opponent.name.isEmpty {
            game.opponent.name = name
            return
        }
    } else {
        if game.opponent.name.isEmpty {
            game.opponent.name = name
        } else if game.player.name.isEmpty {
            game.player.name = name
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Zone change side-effects
// ─────────────────────────────────────────────────────────────────────────────

private func handleZoneChange(
    entityId: Int,
    from: Zone,
    to: Zone,
    game: inout Game
) {
    guard let side = game.ownerOf(entityId: entityId) else { return }
    let entity = game.entities[entityId]

    switch (from, to) {

    // DECK → PLAY  (recruit, call to arms, etc.)
    case (.deck, .play):
        if side == .player, let cardId = entity?.cardId {
            removeFromRemainingDeck(
                cardId: cardId, isCreated: entity?.info.created ?? false, game: &game)
        }
        addToBoard(entityId: entityId, side: side, game: &game)

    // DECK → HAND  (draw / coin / forced draw)
    case (.deck, .hand):
        if side == .player {
            drawCard(entityId: entityId, game: &game)
            game.counters.playerCardsDrawn += 1
        }
        if side == .opponent {
            // Opponent drew — increment hand count (card is unknown).
            if !game.opponent.hand.contains(entityId) {
                game.opponent.hand.append(entityId)
            }
            game.counters.opponentCardsDrawn += 1
        }

    // HAND → PLAY  (play a card)
    case (.hand, .play):
        removeFromHand(entityId: entityId, side: side, game: &game)
        addToBoard(entityId: entityId, side: side, game: &game)
        if let cardId = entity?.cardId, !cardId.isEmpty {
            let play = CardPlay(
                turn: game.turn,
                cardId: cardId,
                entityId: entityId
            )
            game.mutateSide(side) { $0.cardsPlayed.append(play) }
        }
        switch entity?.tags[.cardType] {
        case "SPELL":
            if side == .player {
                game.counters.playerSpellsPlayed += 1
            } else {
                game.counters.opponentSpellsPlayed += 1
            }
        case "MINION":
            if side == .player {
                game.counters.playerMinionsPlayed += 1
            } else {
                game.counters.opponentMinionsPlayed += 1
            }
        case "WEAPON":
            if side == .player {
                game.counters.playerWeaponsPlayed += 1
            } else {
                game.counters.opponentWeaponsPlayed += 1
            }
        default:
            break
        }

    // HAND → GRAVEYARD  (discard, hero power used, etc.)
    case (.hand, .graveyard):
        removeFromHand(entityId: entityId, side: side, game: &game)
        game.mutateSide(side) { $0.graveyard.append(entityId) }

    // PLAY → GRAVEYARD  (minion died, weapon broke, spell resolved)
    case (.play, .graveyard):
        removeFromBoard(entityId: entityId, side: side, game: &game)
        game.mutateSide(side) { $0.graveyard.append(entityId) }
        if entity?.tags[.cardType] == "MINION" {
            if side == .player {
                game.counters.playerMinionsKilled += 1
            } else {
                game.counters.opponentMinionsKilled += 1
            }
        }

    // PLAY → HAND  (bounce)
    case (.play, .hand):
        removeFromBoard(entityId: entityId, side: side, game: &game)
        if side == .player {
            game.player.hand.append(entityId)
        } else {
            game.opponent.hand.append(entityId)
            game.opponent.knownInHand.removeValue(forKey: entityId)
        }

    // HAND → DECK  (mulligan replacement / shuffle-back effects)
    case (.hand, .deck):
        removeFromHand(entityId: entityId, side: side, game: &game)
        if side == .player, let cardId = entity?.cardId, !cardId.isEmpty {
            returnToDeck(cardId: cardId, isCreated: entity?.info.created ?? false, game: &game)
        }

    // DECK → GRAVEYARD  (milled, destroyed in deck)
    case (.deck, .graveyard):
        if side == .player, let cardId = entity?.cardId {
            removeFromRemainingDeck(
                cardId: cardId, isCreated: entity?.info.created ?? false, game: &game)
        }
        game.mutateSide(side) { $0.graveyard.append(entityId) }

    // HAND → SECRET (play a secret)
    case (.hand, .secret):
        removeFromHand(entityId: entityId, side: side, game: &game)
        if !game.side(side).secrets.contains(entityId) {
            game.mutateSide(side) { $0.secrets.append(entityId) }
        }
        if let cardId = entity?.cardId, !cardId.isEmpty {
            let play = CardPlay(
                turn: game.turn,
                cardId: cardId,
                entityId: entityId
            )
            game.mutateSide(side) { $0.cardsPlayed.append(play) }
        }
        if side == .player {
            game.counters.playerSpellsPlayed += 1
        } else {
            game.counters.opponentSpellsPlayed += 1
        }

    // → SECRET
    case (_, .secret):
        if !game.side(side).secrets.contains(entityId) {
            game.mutateSide(side) { $0.secrets.append(entityId) }
        }

    // SECRET → GRAVEYARD  (secret triggered or destroyed)
    case (.secret, .graveyard):
        game.mutateSide(side) { $0.secrets.removeAll { $0 == entityId } }
        game.mutateSide(side) { $0.graveyard.append(entityId) }

    // → REMOVED / SETASIDE  (transform, set-aside effects)
    case (let from, .removed), (let from, .setAside):
        removeFromBoard(entityId: entityId, side: side, game: &game)
        removeFromHand(entityId: entityId, side: side, game: &game)
        if from == .deck, side == .player, let cardId = entity?.cardId {
            removeFromRemainingDeck(
                cardId: cardId, isCreated: entity?.info.created ?? false, game: &game)
        }
        game.mutateSide(side) { $0.removed.append(entityId) }

    // NON-HAND → DECK mid-game (graveyard, play, setAside → deck via shuffle effects)
    // The (.hand, .deck) case above already handles mulligan returns.
    case (let from, .deck) where from != .hand && from != .invalid:
        if from == .play {
            removeFromBoard(entityId: entityId, side: side, game: &game)
        } else if from == .secret {
            game.mutateSide(side) { $0.secrets.removeAll { $0 == entityId } }
        }
        if side == .player,
            let cardId = entity?.cardId, !cardId.isEmpty,
            game.phase == .mulligan || game.phase == .main
        {
            returnToDeck(cardId: cardId, isCreated: entity?.info.created ?? false, game: &game)
        }

    default:
        break
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Step → game phase
// ─────────────────────────────────────────────────────────────────────────────

private func handleStepChange(step: Step, game: inout Game) {
    switch step {
    case .beginMulligan:
        game.phase = .mulligan

    case .mainReady:
        // First MAIN_READY marks the transition from mulligan to gameplay.
        if game.phase == .mulligan || game.phase == .setup {
            game.phase = .main
        }

    case .finalGameover:
        game.phase = .gameOver
        game.endedAt = Date()

    default:
        break
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// PLAYSTATE → result
// ─────────────────────────────────────────────────────────────────────────────

private func handlePlayStateChange(entityId: Int, value: String, game: inout Game) {
    guard let playState = PlayState(rawValue: value) else { return }

    // Only terminal states matter for the result.
    let terminal: Set<PlayState> = [.won, .lost, .tied, .conceded, .disconnected]
    guard terminal.contains(playState) else { return }

    // Determine which side this entity belongs to.
    let isPlayer = game.player.entityId == entityId

    switch playState {
    case .won:
        game.result = isPlayer ? .won : .lost
    case .lost, .conceded:
        game.result = isPlayer ? .lost : .won
    case .tied:
        game.result = .tied
    case .disconnected:
        game.result = isPlayer ? .lost : .won
    default:
        break
    }

    game.phase = .gameOver
    game.endedAt = Date()
}

// ─────────────────────────────────────────────────────────────────────────────
// Choices / Mulligan
// ─────────────────────────────────────────────────────────────────────────────

private func handleChoices(
    id: Int,
    playerName: String,
    choiceType: ChoiceType,
    entityIds: [Int],
    game: inout Game
) {
    if choiceType == .mulligan, game.player.name == playerName {
        _ = entityIds
    }
}

private func handleChosenEntities(
    choiceId: Int,
    entityIds: [Int],
    game: inout Game
) {
    _ = choiceId
    // We receive chosen entities when the player confirms their mulligan.
    // Cards NOT in this set were replaced (sent back to deck).
    // For v1: record kept and replaced sets on the player side.
    if game.phase == .mulligan {
        game.player.mulliganKept = entityIds
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Deck tracking helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Remove one copy of `cardId` from the player's remaining deck.
private func drawCard(entityId: Int, game: inout Game) {
    guard let cardId = game.entities[entityId]?.cardId, !cardId.isEmpty else { return }
    game.player.hand.append(entityId)
    removeFromRemainingDeck(
        cardId: cardId, isCreated: game.entities[entityId]?.info.created ?? false, game: &game)
}

private func removeFromRemainingDeck(cardId: String, isCreated: Bool, game: inout Game) {
    guard let idx = game.player.remainingDeck.firstIndex(where: { $0.card.id == cardId && $0.isCreated == isCreated }) else { return }
    game.player.remainingDeck[idx].count = max(0, game.player.remainingDeck[idx].count - 1)
    game.player.remainingDeck[idx].drawnCount += 1
}

private func returnToDeck(cardId: String, isCreated: Bool, game: inout Game) {
    if let idx = game.player.remainingDeck.firstIndex(where: { $0.card.id == cardId && $0.isCreated == isCreated }) {
        game.player.remainingDeck[idx].count += 1
        if game.player.remainingDeck[idx].drawnCount > 0 {
            game.player.remainingDeck[idx].drawnCount -= 1
        }
    } else {
        // Card not in the original deck — queue for async CardDB resolution.
        let pendingKey = Side.PendingDeckCard(cardId: cardId, isCreated: isCreated)
        game.player.pendingExtraDeckCardIds[pendingKey, default: 0] += 1
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Board / hand helpers
// ─────────────────────────────────────────────────────────────────────────────

private func removeFromHand(entityId: Int, side: PlayerSide, game: inout Game) {
    game.mutateSide(side) { s in
        s.hand.removeAll { $0 == entityId }
        if side == .opponent {
            s.knownInHand.removeValue(forKey: entityId)
        }
    }
}

private func addToBoard(entityId: Int, side: PlayerSide, game: inout Game) {
    game.mutateSide(side) { s in
        if !s.board.contains(entityId) {
            s.board.append(entityId)
        }
    }
}

private func removeFromBoard(entityId: Int, side: PlayerSide, game: inout Game) {
    game.mutateSide(side) { $0.board.removeAll { $0 == entityId } }
}

// ─────────────────────────────────────────────────────────────────────────────
// Finalise result
// ─────────────────────────────────────────────────────────────────────────────

private func finaliseResult(game: inout Game) {
    // If PLAYSTATE tag changes already set result, use them.
    // Otherwise inspect entity PlayState tags as a fallback.
    if game.result != .unknown { return }

    let playerEntity = game.entities[game.player.entityId]
    let opponentEntity = game.entities[game.opponent.entityId]

    let playerState = playerEntity?.playState
    let opponentState = opponentEntity?.playState

    if playerState == .won || opponentState == .lost || opponentState == .conceded {
        game.result = .won
    } else if playerState == .lost || playerState == .conceded || opponentState == .won {
        game.result = .lost
    } else if playerState == .tied {
        game.result = .tied
    }

    game.phase = .gameOver
    game.endedAt = game.endedAt ?? Date()
}

// ─────────────────────────────────────────────────────────────────────────────
// Entity resolution
// ─────────────────────────────────────────────────────────────────────────────

private func resolveEntityId(ref: EntityRef, game: Game) -> Int? {
    switch ref {
    case .id(let n):
        return n
    case .name(let name):
        // "GameEntity" maps to the game entity id.
        if name == "GameEntity" { return game.gameEntityId }
        // Try to match by player name.
        if game.player.name == name { return game.player.entityId }
        if game.opponent.name == name { return game.opponent.entityId }
        // Try parsing as int (some log lines use the player's numeric entity id as a string).
        return Int(name)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Side-swap (local player detection correction)
// ─────────────────────────────────────────────────────────────────────────────

/// Swap player ↔ opponent if we detect we had the assignment backwards.
func swapSides(game: inout Game) {
    let tmp = game.player
    game.player = game.opponent
    game.opponent = tmp

    // Re-build the playerIdMap.
    game.playerIdMap = [
        game.player.playerId: .player,
        game.opponent.playerId: .opponent,
    ]

    // Restore the local player's deck tracking info, which was attached to the
    // initial 'player' side (now temporarily in 'opponent') before the swap.
    let deckList = game.opponent.deckList
    let remainingDeck = game.opponent.remainingDeck
    let pendingDeckstring = game.opponent.pendingDeckstring
    let deckName = game.opponent.deckName

    game.opponent.deckList = game.player.deckList
    game.opponent.remainingDeck = game.player.remainingDeck
    game.opponent.pendingDeckstring = game.player.pendingDeckstring
    game.opponent.deckName = game.player.deckName

    game.player.deckList = deckList
    game.player.remainingDeck = remainingDeck
    game.player.pendingDeckstring = pendingDeckstring
    game.player.deckName = deckName
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - GameController
// ═══════════════════════════════════════════════════════════════════════════════

/// The single source of truth the UI observes.
/// Lives on the MainActor; bridged from background tailer/parser via Task.
