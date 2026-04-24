// Sources/HSLogParser/HSLogParser.swift
// Full state-machine parser for Hearthstone's Power.log, Zone.log,
// LoadingScreen.log, and Decks.log.
//
// Call process(line:) for each raw line coming from HSLogTailer.
// Returns zero or more LogEvent values per line.
// Call reset() whenever the tailer detects log rotation (new game session).

import Foundation

// MARK: - HSLogParser

public final class HSLogParser: @unchecked Sendable {

    // MARK: Parser state

    /// Multi-line constructs in Power.log require carrying state between lines.
    private enum State {
        case idle

        /// Inside a FULL_ENTITY or SHOW_ENTITY block — accumulating tag lines.
        case entityTags(
            entityId: Int,
            cardId: String?,
            kind: EntityKind,
            tags: [GameTag: String]
        )

        /// Inside a CHANGE_ENTITY block.
        case changeEntityTags(
            entityId: Int,
            cardId: String,
            tags: [GameTag: String]
        )

        /// Reading Entities[] lines after DebugPrintEntityChoices header.
        case choices(
            id: Int,
            playerName: String,
            choiceType: ChoiceType,
            entityIds: [Int]
        )

        /// Reading Entities[] lines after DebugPrintEntitiesChosen header.
        case chosenEntities(
            choiceId: Int,
            entityIds: [Int]
        )

        /// Inside a META_DATA block — accumulating Info[] lines.
        case metaData(
            type: String,
            data: Int,
            info: [Int]
        )

        /// Reading deck selection in Decks.log
        case readingDeck(name: String?)
    }

    private enum EntityKind { case full, show }

    private var state: State = .idle

    /// Power.log occasionally splits a single logical line across two physical
    /// lines when an `entityName=` value contains an embedded newline (certain
    /// localised card names in Russian / CJK locales). Buffer the incomplete
    /// first half and join it with the next line.
    private var pendingPartialPowerLine: String? = nil

    // MARK: Public API

    public init() {}

    /// Reset all internal state.  Call when HSLogTailer detects log rotation.
    public func reset() {
        state = .idle
        pendingPartialPowerLine = nil
    }

    /// Process one raw line from the log file.
    /// Returns the events (0 or more) that result from this line.
    public func process(line: String) -> [LogEvent] {
        // Route by log section.
        if line.hasPrefix("[Power]") {
            return processPowerLine(line)
        } else if line.hasPrefix("[LoadingScreen]") {
            return processLoadingScreenLine(line)
        } else if line.hasPrefix("[Decks]") {
            return processDeckLine(line)
        }
        // Zone.log entries are handled through TAG_CHANGE in Power.log;
        // we ignore raw Zone.log lines to avoid double-counting.
        return []
    }

    // MARK: - [Power] section

    private func processPowerLine(_ line: String) -> [LogEvent] {
        // Determine sub-section.
        if line.contains("GameState.DebugPrintEntityChoices()") {
            return processChoicesLine(line)
        }
        if line.contains("GameState.DebugPrintEntitiesChosen()") {
            return processChosenLine(line)
        }
        if line.contains("GameState.DebugPrintOptions()") {
            return processOptionsLine(line)
        }

        // If the previous line opened an Entity=[ that wasn't closed on the
        // same physical line (embedded newline in entityName=), stitch.
        if let pending = pendingPartialPowerLine {
            pendingPartialPowerLine = nil
            let joined = pending + " " + line
            if hasUnbalancedEntityBracket(joined) {
                pendingPartialPowerLine = joined
                return []
            }
            return processPowerLineStitched(joined)
        }

        if hasUnbalancedEntityBracket(line) {
            pendingPartialPowerLine = line
            return []
        }

        return processPowerLineStitched(line)
    }

    private func processPowerLineStitched(_ line: String) -> [LogEvent] {
        // Both GameState.DebugPrintPower and PowerTaskList.DebugPrintPower share
        // the same payload format; strip the prefix up to " - " then dispatch.
        guard let content = powerContent(from: line) else { return [] }
        return processPowerContent(content, rawLine: line)
    }

    /// True if the line contains an `entityName=` bracket opener without a
    /// matching close on the same physical line (embedded-newline names).
    private func hasUnbalancedEntityBracket(_ line: String) -> Bool {
        guard
            line.range(of: "[entityName=") != nil
                || line.range(of: "Entity=[") != nil
        else { return false }
        var depth = 0
        for ch in line {
            if ch == "[" { depth += 1 } else if ch == "]" { depth -= 1 }
        }
        return depth > 0
    }

    /// Strip everything up to and including the last " - " delimiter.
    private func powerContent(from line: String) -> String? {
        // Hearthstone prints every event TWICE:
        //
        //   GameState.DebugPrintPower()    — the authoritative event stream
        //   PowerTaskList.DebugPrintPower() — a debug reprint of the same state
        //
        // Processing both double-applies every zone transition / tag change
        // and corrupts the reducer. Accept only the GameState stream.
        //
        // `DebugPrintPowerList()` (with "List") prints `Count=N` headers that
        // aren't events either.
        guard line.contains("GameState.DebugPrintPower() - ") else { return nil }
        guard let range = line.range(of: ") - ") else { return nil }
        let content = String(line[range.upperBound...])
        return content
    }

    private func processPowerContent(_ content: String, rawLine: String) -> [LogEvent] {
        let trimmed = content.trimmingCharacters(in: .whitespaces)

        let isStructural =
            trimmed == "CREATE_GAME" || trimmed.hasPrefix("GameEntity")
            || trimmed.hasPrefix("Player ") || trimmed.hasPrefix("FULL_ENTITY")
            || trimmed.hasPrefix("SHOW_ENTITY") || trimmed.hasPrefix("HIDE_ENTITY")
            || trimmed.hasPrefix("CHANGE_ENTITY") || trimmed.hasPrefix("TAG_CHANGE")
            || trimmed.hasPrefix("BLOCK_START") || trimmed == "BLOCK_END"
            || trimmed.hasPrefix("META_DATA") || trimmed.hasPrefix("SUB_SPELL_START")
            || trimmed == "SUB_SPELL_END"

        // ── Multi-line continuation check ─────────────────────────────────────
        // Tag lines inside entity blocks are indented with spaces.
        // "    tag=ZONE value=DECK"
        if !isStructural && (content.hasPrefix("    ") || content.hasPrefix("\t")) {
            return handleContinuationLine(trimmed, rawLine: rawLine)
        }

        // ── If we were in a multi-line state and hit a non-indented line,
        //    flush the pending event first, then process the new line.
        let flushed = flushPendingState()

        let newEvents = dispatchTopLevelContent(trimmed, rawLine: rawLine)
        return flushed + newEvents
    }

    /// Dispatch a top-level (non-indented) content string.
    private func dispatchTopLevelContent(_ s: String, rawLine: String) -> [LogEvent] {
        if s == "CREATE_GAME" {
            return []  // The GameEntity + Player sub-lines carry the real data.
        }
        if s.hasPrefix("GameEntity") {
            return parseGameEntity(s)
        }
        if s.hasPrefix("Player EntityID=") {
            return parsePlayerLine(s)
        }
        if s.hasPrefix("FULL_ENTITY") {
            return beginEntityBlock(s, kind: .full)
        }
        if s.hasPrefix("SHOW_ENTITY") {
            return beginEntityBlock(s, kind: .show)
        }
        if s.hasPrefix("HIDE_ENTITY") {
            return parseHideEntity(s)
        }
        if s.hasPrefix("CHANGE_ENTITY") {
            return beginChangeEntityBlock(s)
        }
        if s.hasPrefix("TAG_CHANGE") {
            return parseTagChange(s, rawLine: rawLine)
        }
        if s.hasPrefix("BLOCK_START") {
            return parseBlockStart(s, rawLine: rawLine)
        }
        if s == "BLOCK_END" {
            return [.blockEnd]
        }
        if s.hasPrefix("META_DATA") {
            return beginMetaData(s)
        }
        if s.hasPrefix("SUB_SPELL_START") {
            return parseSubSpellStart(s)
        }
        if s == "SUB_SPELL_END" {
            return [.subSpellEnd]
        }
        // Unknown top-level line — emit warning in debug, silence in release.
        #if DEBUG
            if !s.isEmpty {
                return [
                    .parseWarning(
                        line: rawLine, reason: "Unrecognised top-level token: \(s.prefix(40))")
                ]
            }
        #endif
        return []
    }

    // MARK: Continuation lines (indented)

    private func handleContinuationLine(_ trimmed: String, rawLine: String) -> [LogEvent] {
        switch state {
        case .readingDeck:
            return []

        case .entityTags(let id, let cardId, let kind, var tags):
            if let (tag, value) = parseTagLine(trimmed) {
                tags[tag] = value
                state = .entityTags(entityId: id, cardId: cardId, kind: kind, tags: tags)
            }
            return []

        case .changeEntityTags(let id, let cardId, var tags):
            if let (tag, value) = parseTagLine(trimmed) {
                tags[tag] = value
                state = .changeEntityTags(entityId: id, cardId: cardId, tags: tags)
            }
            return []

        case .choices(let id, let pname, let ct, var eids):
            if let eid = parseEntityListLine(trimmed) {
                eids.append(eid)
                state = .choices(id: id, playerName: pname, choiceType: ct, entityIds: eids)
            }
            return []

        case .chosenEntities(let id, var eids):
            if let eid = parseEntityListLine(trimmed) {
                eids.append(eid)
                state = .chosenEntities(choiceId: id, entityIds: eids)
            }
            return []

        case .metaData(let type, let data, var info):
            // Info[N] = M
            if trimmed.hasPrefix("Info["),
                let eqRange = trimmed.range(of: " = "),
                let val = Int(trimmed[eqRange.upperBound...].trimmingCharacters(in: .whitespaces))
            {
                info.append(val)
                state = .metaData(type: type, data: data, info: info)
            }
            return []

        case .idle:
            return []
        }
    }

    // MARK: Flush pending multi-line state

    private func flushPendingState() -> [LogEvent] {
        let current = state
        state = .idle

        switch current {
        case .idle, .readingDeck:
            return []

        case .entityTags(let id, let cardId, let kind, let tags):
            switch kind {
            case .full:
                return [.fullEntity(id: id, cardId: cardId, tags: tags)]
            case .show:
                // SHOW_ENTITY without a cardId is a debug reprint of an already
                // hidden entity — nothing to apply, nothing worth warning about.
                guard let cid = cardId, !cid.isEmpty else { return [] }
                return [.showEntity(id: id, cardId: cid, tags: tags)]
            }

        case .changeEntityTags(let id, let cardId, let tags):
            return [.changeEntity(id: id, cardId: cardId, tags: tags)]

        case .choices(let id, let pname, let ct, let eids):
            return [.choices(id: id, playerName: pname, choiceType: ct, entityIds: eids)]

        case .chosenEntities(let id, let eids):
            return [.chosenEntities(choiceId: id, entityIds: eids)]

        case .metaData(let type, let data, let info):
            return [.metaData(type: type, data: data, info: info)]
        }
    }

    // MARK: - Top-level parsers

    // CREATE_GAME sub-line: "GameEntity EntityID=1"
    private func parseGameEntity(_ s: String) -> [LogEvent] {
        guard let id = extractInt(s, key: "EntityID") else { return [] }
        return [.gameCreated(gameEntityId: id)]
    }

    // "Player EntityID=2 PlayerID=1 GameAccountId=[hi=144115198130930503 lo=93766391]"
    private func parsePlayerLine(_ s: String) -> [LogEvent] {
        guard let entityId = extractInt(s, key: "EntityID"),
            let playerId = extractInt(s, key: "PlayerID")
        else { return [] }

        var hi = 0
        var lo = 0
        if let hiRange = s.range(of: "hi="),
            let loRange = s.range(of: " lo=")
        {
            let hiStr = s[hiRange.upperBound...].prefix(while: { $0.isNumber || $0 == "-" })
            let loStr = s[loRange.upperBound...].prefix(while: { $0.isNumber || $0 == "-" })
            hi = Int(hiStr) ?? 0
            lo = Int(loStr) ?? 0
        }

        return [
            .playerCreated(entityId: entityId, playerId: playerId, accountHi: hi, accountLo: lo)
        ]
    }

    // Handles every variant currently produced by Hearthstone:
    //
    //   Creating form (FULL_ENTITY on initial reveal):
    //     FULL_ENTITY - Creating ID=47 CardID=EX1_066
    //
    //   Short updating form (seen in GameState.DebugPrintPower output):
    //     SHOW_ENTITY - Updating Entity=4 CardID=END_000
    //
    //   Bracket updating form (seen in PowerTaskList.DebugPrintPower reprints):
    //     SHOW_ENTITY - Updating Entity=[entityName=... id=4 ... cardId= ...] CardID=END_000
    //
    //   Named entity form (rare — opponent not yet revealed):
    //     FULL_ENTITY - Updating UNKNOWN HUMAN PLAYER CardID=
    private func beginEntityBlock(_ s: String, kind: EntityKind) -> [LogEvent] {
        let flushed = flushPendingState()

        if s.contains("Creating ID=") {
            var id: Int? = nil
            var cardId: String? = nil
            if let idRange = s.range(of: "ID=") {
                let idStr = s[idRange.upperBound...].prefix(while: { $0.isNumber })
                id = Int(idStr)
            }
            if let cardIdRange = s.range(of: "CardID=") {
                let cid = s[cardIdRange.upperBound...].trimmingCharacters(in: .whitespaces)
                cardId = cid.isEmpty ? nil : cid
            }
            if let eid = id {
                state = .entityTags(entityId: eid, cardId: cardId, kind: kind, tags: [:])
                return flushed
            }
        }

        if let (id, cardId) = parseUpdatingLine(s) {
            state = .entityTags(entityId: id, cardId: cardId, kind: kind, tags: [:])
            return flushed
        }

        // Named-entity updates ("UNKNOWN HUMAN PLAYER", "shiba", etc.) carry
        // no id — the Player entity is identified via parsePlayerLine during
        // CREATE_GAME. Nothing to apply here; skip silently.
        if isNamedEntityUpdatingLine(s) {
            return flushed
        }

        guard let (id, cardId) = parseEntityBracket(s) else {
            return flushed + [.parseWarning(line: s, reason: "Could not parse entity bracket")]
        }

        state = .entityTags(entityId: id, cardId: cardId, kind: kind, tags: [:])
        return flushed
    }

    /// True when the " - Updating" payload resolves to a player/opponent name
    /// instead of a numeric id or bracketed entity (e.g. "shiba CardID=").
    private func isNamedEntityUpdatingLine(_ s: String) -> Bool {
        guard let updRange = s.range(of: " - Updating ") else { return false }
        let rest = s[updRange.upperBound...]
        // If the token after Updating is a bracket or Entity=NUM we'd have
        // matched earlier; anything else is a name.
        let firstChar = rest.first
        return firstChar != nil && firstChar != "[" && firstChar != "E"
    }

    // CHANGE_ENTITY carries the NEW card id in the trailing `CardID=` field,
    // while the bracket block describes the entity BEFORE the change.
    //
    //   CHANGE_ENTITY - Updating Entity=[entityName=X id=134 ... cardId=OLD player=1] CardID=NEW
    //   CHANGE_ENTITY - Updating Entity=134 CardID=NEW
    private func beginChangeEntityBlock(_ s: String) -> [LogEvent] {
        let flushed = flushPendingState()

        guard let (id, newCardId) = parseUpdatingLine(s),
            let cid = newCardId, !cid.isEmpty
        else {
            return flushed + [.parseWarning(line: s, reason: "CHANGE_ENTITY missing cardId")]
        }

        state = .changeEntityTags(entityId: id, cardId: cid, tags: [:])
        return flushed
    }

    /// Parses "<TAG> - Updating <entity> CardID=<card>" lines.
    /// Returns (entityId, trailingCardId?) or nil if the entity can't be resolved.
    private func parseUpdatingLine(_ s: String) -> (id: Int, cardId: String?)? {
        guard let updRange = s.range(of: " - Updating ") else { return nil }

        let rest = String(s[updRange.upperBound...])

        // The trailing " CardID=" is the authoritative card id (new value).
        var trailingCardId: String? = nil
        var entityStr = rest
        if let cidRange = rest.range(of: " CardID=") {
            let cid = rest[cidRange.upperBound...].trimmingCharacters(in: .whitespaces)
            trailingCardId = cid.isEmpty ? nil : cid
            entityStr = String(rest[..<cidRange.lowerBound])
        }

        // Entity= prefix may be absent for legacy forms but is present for
        // SHOW/CHANGE. Strip it to normalise.
        if entityStr.hasPrefix("Entity=") {
            entityStr = String(entityStr.dropFirst("Entity=".count))
        }
        let trimmed = entityStr.trimmingCharacters(in: .whitespaces)

        // Bracketed form — id lives inside the (possibly nested) bracket.
        if trimmed.hasPrefix("[") {
            if let (id, _) = parseEntityBracket(trimmed) {
                return (id, trailingCardId)
            }
            return nil
        }

        // Plain numeric entity id.
        if let n = Int(trimmed) {
            return (n, trailingCardId)
        }

        return nil
    }

    // Current Hearthstone format:
    //   HIDE_ENTITY - Entity=[entityName=X id=50 zone=HAND zonePos=1 cardId=Y player=2] tag=ZONE value=DECK
    //
    // The `zone=HAND` inside the bracket is the SOURCE (pre-hide) zone; the
    // DESTINATION zone is the trailing `tag=ZONE value=<dest>`. Parsing the
    // source used to silently send cards to HAND when they were actually
    // being returned to DECK during mulligan, so mulligan replaces never
    // incremented the remainingDeck counts.
    private func parseHideEntity(_ s: String) -> [LogEvent] {
        let flushed = flushPendingState()

        // Prefer the id inside the bracket (unambiguous). Fall back to the
        // legacy `id=N` at the top level if no bracket is present.
        var id: Int? = nil
        if let (bid, _) = parseEntityBracket(s) {
            id = bid
        } else if let idRange = s.range(of: "id=") {
            id = Int(s[idRange.upperBound...].prefix(while: { $0.isNumber }))
        }
        guard let entityId = id else { return flushed }

        var zone: Zone = .invalid
        if let tagRange = s.range(of: "tag=ZONE value=") {
            let zStr = String(
                s[tagRange.upperBound...]
                    .prefix(while: { $0.isLetter || $0 == "_" }))
            zone = Zone(rawValue: zStr) ?? .invalid
        }

        return flushed + [.hideEntity(id: entityId, zone: zone)]
    }

    // "TAG_CHANGE Entity=1 tag=STEP value=BEGIN_MULLIGAN"
    // "TAG_CHANGE Entity=GameEntity tag=TURN value=3"
    // "TAG_CHANGE Entity=[id=47 cardId=EX1_066 type=MINION] tag=ZONE value=HAND"
    private func parseTagChange(_ s: String, rawLine: String) -> [LogEvent] {
        let flushed = flushPendingState()

        // Extract Entity= portion (everything between "Entity=" and " tag=")
        guard let entityRange = s.range(of: "Entity="),
            let tagRange = s.range(of: " tag=")
        else {
            return flushed + [
                .parseWarning(line: rawLine, reason: "TAG_CHANGE missing Entity or tag")
            ]
        }

        let entityStr = String(s[entityRange.upperBound..<tagRange.lowerBound])
        let ref = parseEntityRef(entityStr)

        // tag= and value=
        guard let (tag, value) = parseTagAndValue(String(s[tagRange.lowerBound...])) else {
            return flushed
        }

        return flushed + [.tagChange(entity: ref, tag: tag, value: value)]
    }

    // "BLOCK_START BlockType=PLAY Entity=[id=47 cardId=EX1_066 type=MINION] EffectCardId= EffectIndex=-1 Target=0"
    private func parseBlockStart(_ s: String, rawLine: String) -> [LogEvent] {
        let flushed = flushPendingState()

        var blockType: BlockType = .unknown
        if let btRange = s.range(of: "BlockType="),
            let spaceAfter = s[btRange.upperBound...].firstIndex(of: " ")
        {
            let btStr = String(s[btRange.upperBound..<spaceAfter])
            blockType = BlockType(rawValue: btStr) ?? .unknown
        }

        // Entity= is between "Entity=" and " EffectCardId="
        var entityRef: EntityRef = .name("GameEntity")
        if let eRange = s.range(of: " Entity=") {
            let afterEntity = s[eRange.upperBound...]
            // Could be [id=...] or a plain name/number
            if afterEntity.hasPrefix("[") {
                if let close = afterEntity.firstIndex(of: "]") {
                    let bracket = String(afterEntity[afterEntity.startIndex...close])
                    if let (id, _) = parseEntityBracket(bracket) {
                        entityRef = .id(id)
                    }
                }
            } else {
                let token = String(afterEntity.prefix(while: { $0 != " " }))
                if let num = Int(token) {
                    entityRef = .id(num)
                } else {
                    entityRef = .name(token)
                }
            }
        }

        var effectCardId: String? = nil
        if let ecRange = s.range(of: "EffectCardId=") {
            let afterEc = s[ecRange.upperBound...]
            let token = String(afterEc.prefix(while: { $0 != " " }))
            if !token.isEmpty {
                effectCardId = token
            }
        }

        var effectIndex: Int? = nil
        if let eiRange = s.range(of: "EffectIndex=") {
            let token = String(s[eiRange.upperBound...].prefix(while: { $0.isNumber || $0 == "-" }))
            effectIndex = Int(token)
        }

        return flushed + [
            .blockStart(
                type: blockType,
                entity: entityRef,
                effectCardId: effectCardId,
                effectIndex: effectIndex
            )
        ]
    }

    // "META_DATA - Meta=TARGET Data=47 Info=1"
    private func beginMetaData(_ s: String) -> [LogEvent] {
        let flushed = flushPendingState()

        var metaType = "UNKNOWN"
        if let mRange = s.range(of: "Meta="),
            let space = s[mRange.upperBound...].firstIndex(of: " ")
        {
            metaType = String(s[mRange.upperBound..<space])
        }

        var data = 0
        if let dRange = s.range(of: "Data=") {
            let token = String(s[dRange.upperBound...].prefix(while: { $0.isNumber || $0 == "-" }))
            data = Int(token) ?? 0
        }

        state = .metaData(type: metaType, data: data, info: [])
        return flushed
    }

    // "SUB_SPELL_START SpellPrefab=... Source=..."
    private func parseSubSpellStart(_ s: String) -> [LogEvent] {
        let flushed = flushPendingState()
        var spellPrefab: String? = nil
        var parentId: Int? = nil

        if let spRange = s.range(of: "SpellPrefab="),
            let space = s[spRange.upperBound...].firstIndex(of: " ")
        {
            spellPrefab = String(s[spRange.upperBound..<space])
        }
        if let srcRange = s.range(of: "Source=") {
            let token = String(s[srcRange.upperBound...].prefix(while: { $0.isNumber }))
            parentId = Int(token)
        }

        return flushed + [.subSpellStart(spellPrefab: spellPrefab, parentEntityId: parentId)]
    }

    // MARK: - Choices

    // "GameState.DebugPrintEntityChoices() - id=1 Player=Name TaskList=0 ChoiceType=MULLIGAN CountMin=0 CountMax=4"
    // "GameState.DebugPrintEntityChoices() -   Entities[0]=[id=3 cardId=EX1_066 type=MINION]"
    private func processChoicesLine(_ line: String) -> [LogEvent] {
        guard let dashRange = line.range(of: "() - ") else { return [] }
        let content = String(line[dashRange.upperBound...]).trimmingCharacters(in: .whitespaces)

        // Entity continuation line
        if content.hasPrefix("Entities[") {
            if case .choices(let id, let pid, let ct, var eids) = state {
                if let eid = parseEntityListLine(content) {
                    eids.append(eid)
                    state = .choices(id: id, playerId: pid, choiceType: ct, entityIds: eids)
                }
            }
            return []
        }

        // Header line — flush any pending state first.
        let flushed = flushPendingState()

        guard let id = extractInt(content, key: "id") else { return flushed }

        var playerId = 0
        if let pidRange = content.range(of: "TaskList=") {
            // Player name is between "Player=" and " TaskList=", but it can contain spaces
            // fall back: use PlayerID from the Player entity map — for now store 0
            // We'll resolve from context in GameState reducer.
            _ = pidRange
        }
        // Try to get playerId from a different key if available.
        playerId = extractInt(content, key: "PlayerID") ?? 0

        var choiceType: ChoiceType = .general
        if let ctRange = content.range(of: "ChoiceType="),
            let space = content[ctRange.upperBound...].firstIndex(of: " ")
        {
            let ctStr = String(content[ctRange.upperBound..<space])
            choiceType = ChoiceType(rawValue: ctStr) ?? .general
        } else if content.contains("ChoiceType=MULLIGAN") {
            choiceType = .mulligan
        }

        state = .choices(id: id, playerName: playerName, choiceType: choiceType, entityIds: [])
        return flushed
    }

    // "GameState.DebugPrintEntitiesChosen() - id=1 Player=Name EntitiesCount=2"
    // "GameState.DebugPrintEntitiesChosen() -   Entities[0]=[id=3 cardId=EX1_066 type=MINION]"
    private func processChosenLine(_ line: String) -> [LogEvent] {
        guard let dashRange = line.range(of: "() - ") else { return [] }
        let content = String(line[dashRange.upperBound...]).trimmingCharacters(in: .whitespaces)

        if content.hasPrefix("Entities[") {
            if case .chosenEntities(let id, var eids) = state {
                if let eid = parseEntityListLine(content) {
                    eids.append(eid)
                    state = .chosenEntities(choiceId: id, entityIds: eids)
                }
            }
            return []
        }

        let flushed = flushPendingState()
        guard let id = extractInt(content, key: "id") else { return flushed }
        state = .chosenEntities(choiceId: id, entityIds: [])
        return flushed
    }

    // Options line — extract entity IDs of available plays.
    private func processOptionsLine(_ line: String) -> [LogEvent] {
        let flushed = flushPendingState()
        // We only use options to track turn ownership; emit a basic event.
        // Full options parsing is low priority for v1.
        _ = line
        return flushed
    }

    // MARK: - [LoadingScreen]

    private func processLoadingScreenLine(_ line: String) -> [LogEvent] {
        let flushed = flushPendingState()
        // "[LoadingScreen] LoadingScreen.OnSceneLoaded() - prevScene=HUB nextScene=GAMEPLAY"
        guard line.contains("OnSceneLoaded"),
            let nsRange = line.range(of: "nextScene=")
        else {
            return flushed
        }
        let sceneStr = String(
            line[nsRange.upperBound...].prefix(while: { $0.isLetter || $0.isNumber }))
        let scene = HSScene(rawValue: sceneStr) ?? .unknown
        return flushed + [.sceneChanged(to: scene)]
    }

    // MARK: - [Decks]

    private func processDeckLine(_ line: String) -> [LogEvent] {
        // Handle "Finding Game With Deck:" block
        if line.contains("Finding Game With Deck:") {
            _ = flushPendingState()
            state = .readingDeck(name: nil)
            return []
        }

        if case .readingDeck(let name) = state {
            // Check for ### deck name
            if let hashRange = line.range(of: "### ") {
                let newName = String(line[hashRange.upperBound...]).trimmingCharacters(
                    in: .whitespaces)
                state = .readingDeck(name: newName)
                return []
            }

            // Check for deckstring (starts with AA usually)
            let components = line.components(separatedBy: " ")
            if let last = components.last, last.hasPrefix("AA"), last.count > 20 {
                _ = flushPendingState()
                return [.deckSelected(deckstring: last, name: name ?? "")]
            }
        }

        // Fallback for old format just in case
        if line.contains("deckstring:"),
            let dsRange = line.range(of: "deckstring: ")
        {
            let ds = String(line[dsRange.upperBound...].trimmingCharacters(in: .whitespaces))
            var deckName = ""
            if let nameRange = line.range(of: "deck_name="),
                let endRange = line.range(of: " format=")
            {
                deckName = String(line[nameRange.upperBound..<endRange.lowerBound])
            }
            if !ds.isEmpty {
                return [.deckSelected(deckstring: ds, name: deckName)]
            }
        }
        return []
    }

    // MARK: - Shared parsing helpers

    /// Parse "tag=ZONE value=HAND" → (.zone, "HAND")
    private func parseTagLine(_ s: String) -> (GameTag, String)? {
        parseTagAndValue(s)
    }

    /// Parse " tag=ZONE value=HAND" or "tag=ZONE value=HAND"
    private func parseTagAndValue(_ s: String) -> (GameTag, String)? {
        guard let tagRange = s.range(of: "tag="),
            let valueRange = s.range(of: " value=")
        else { return nil }

        let tagStr = String(s[tagRange.upperBound..<valueRange.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        let valueStr = String(s[valueRange.upperBound...])
            .trimmingCharacters(in: .whitespaces)

        guard let tag = GameTag(rawValue: tagStr) else {
            // Unknown tag — silently ignore.
            return nil
        }
        return (tag, valueStr)
    }

    /// Parse entity bracket. Handles both legacy and current Hearthstone forms,
    /// including nested brackets:
    ///
    ///   [id=47 cardId=EX1_066 type=MINION]
    ///   [entityName=UNKNOWN ENTITY [cardType=INVALID] id=254 zone=SETASIDE cardId= player=1]
    ///
    /// Returns (id, cardId?) — cardId is nil when empty or absent.
    private func parseEntityBracket(_ s: String) -> (id: Int, cardId: String?)? {
        guard let openBracket = s.firstIndex(of: "[") else { return nil }

        // Find the MATCHING close bracket by tracking depth — firstIndex(of:)
        // would return the inner "[cardType=INVALID]"'s close, losing the rest.
        var depth = 0
        var closeBracket: String.Index? = nil
        var i = openBracket
        while i < s.endIndex {
            switch s[i] {
            case "[": depth += 1
            case "]":
                depth -= 1
                if depth == 0 { closeBracket = i }
            default: break
            }
            if closeBracket != nil { break }
            i = s.index(after: i)
        }
        guard let close = closeBracket else { return nil }

        let inner = String(s[s.index(after: openBracket)..<close])

        guard let id = extractBracketId(from: inner) else { return nil }

        let cardId = extractBracketCardId(from: inner)

        return (id, cardId)
    }

    /// Find `id=N` preceded by start-of-string or whitespace so it doesn't
    /// match inside `cardId=` or `EffectCardId=`.
    private func extractBracketId(from inner: String) -> Int? {
        var cursor = inner.startIndex
        while cursor < inner.endIndex {
            guard let range = inner.range(of: "id=", range: cursor..<inner.endIndex)
            else { return nil }
            let isWordStart: Bool = {
                if range.lowerBound == inner.startIndex { return true }
                let prev = inner[inner.index(before: range.lowerBound)]
                return prev == " " || prev == "\t"
            }()
            if isWordStart {
                let digits = inner[range.upperBound...].prefix(while: { $0.isNumber })
                if let n = Int(digits) { return n }
            }
            cursor = range.upperBound
        }
        return nil
    }

    /// Extract the bracket-local `cardId=` value (terminated by space or ']').
    private func extractBracketCardId(from inner: String) -> String? {
        guard let range = inner.range(of: "cardId=") else { return nil }
        let after = inner[range.upperBound...]
        let value = String(after.prefix(while: { $0 != " " && $0 != "]" }))
        return value.isEmpty ? nil : value
    }

    /// Parse an entity reference which can be:
    ///   - A plain integer: "47"
    ///   - A named string:  "GameEntity"
    ///   - A bracket block: "[id=47 cardId=EX1_066 type=MINION]"
    private func parseEntityRef(_ s: String) -> EntityRef {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("[") {
            if let (id, _) = parseEntityBracket(t) {
                return .id(id)
            }
        }
        if let n = Int(t) {
            return .id(n)
        }
        return .name(t)
    }

    /// Parse "Entities[0]=[id=3 cardId=EX1_066 type=MINION]" → 3
    private func parseEntityListLine(_ s: String) -> Int? {
        guard s.hasPrefix("Entities["),
            let eqIdx = s.firstIndex(of: "="),
            let (id, _) = parseEntityBracket(String(s[s.index(after: eqIdx)...]))
        else {
            return nil
        }
        return id
    }

    /// Extract an integer value for a key like "EntityID=47".
    private func extractInt(_ s: String, key: String) -> Int? {
        guard let range = s.range(of: "\(key)=") else { return nil }
        let after = s[range.upperBound...]
        let digits = after.prefix(while: { $0.isNumber || $0 == "-" })
        return Int(digits)
    }
}
