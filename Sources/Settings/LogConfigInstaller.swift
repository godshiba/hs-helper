// Sources/Settings/LogConfigInstaller.swift
// Installs Hearthstone's log.config on first launch and exposes a SwiftUI
// preferences view for overlay options and monitor selection.
//
// log.config path:
//   ~/Library/Preferences/Blizzard/Hearthstone/log.config
//
// Without this file Hearthstone writes no log output and the tracker is blind.
// The app installs it automatically; the user must restart HS once afterwards.

import AppKit
import Foundation
import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - LogConfigInstaller
// ═══════════════════════════════════════════════════════════════════════════════

/// Manages the Hearthstone log.config file.
///
/// Call `ensureInstalled()` once on app launch.
/// If the config is missing or incomplete it is written atomically.
/// The installer never overwrites sections the user has customised beyond
/// what the tracker needs — it merges at the section level.
public final class LogConfigInstaller: Sendable {

    // MARK: Paths

    public static let shared = LogConfigInstaller()

    private static var configURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return
            home
            .appendingPathComponent("Library/Preferences/Blizzard/Hearthstone/log.config")
    }

    private static var hearthstoneLogDir: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return
            home
            .appendingPathComponent("Library/Logs/Blizzard Entertainment/Hearthstone")
    }

    // MARK: Required sections

    /// The sections hs-helper needs.  Any already-present sections with
    /// correct values are left untouched.
    private static let requiredSections: [LogSection] = [
        LogSection(name: "Power", logLevel: 1, filePrinting: true),
        LogSection(name: "Zone", logLevel: 1, filePrinting: true),
        LogSection(name: "LoadingScreen", logLevel: 1, filePrinting: true),
        LogSection(name: "Decks", logLevel: 1, filePrinting: true),
    ]

    // MARK: - Public API

    public init() {}

    /// Check whether the config is present and complete.
    public var isInstalled: Bool {
        guard let existing = readExisting() else { return false }
        return Self.requiredSections.allSatisfy { section in
            existing.contains(section: section)
        }
    }

    /// True if Hearthstone.app is present on this machine.
    public var hearthstoneIsPresent: Bool {
        FileManager.default.fileExists(
            atPath: "/Applications/Hearthstone/Hearthstone.app"
        )
    }

    /// True if Hearthstone is currently running as a process.
    public var hearthstoneIsRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "unity.Blizzard Entertainment.Hearthstone"
        }
    }

    /// True if Hearthstone is the currently active (frontmost) application.
    public var hearthstoneIsActive: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            == "unity.Blizzard Entertainment.Hearthstone"
    }

    /// Install or update log.config.
    /// Returns `.alreadyInstalled` if no changes were needed.
    /// Returns `.installed` if the file was written.
    /// Returns `.failed(Error)` if the write failed.
    @discardableResult
    public func ensureInstalled() -> InstallResult {
        guard !isInstalled else { return .alreadyInstalled }

        do {
            try writeConfig()
            return .installed
        } catch {
            return .failed(error)
        }
    }

    // MARK: - Reading

    /// Parse the existing config file into a ParsedConfig, or nil if absent.
    private func readExisting() -> ParsedConfig? {
        guard let data = try? Data(contentsOf: Self.configURL),
            let text = String(data: data, encoding: .utf8)
        else { return nil }
        return ParsedConfig(source: text)
    }

    // MARK: - Writing

    private func writeConfig() throws {
        // Create the directory if it doesn't exist.
        let dir = Self.configURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )

        // Merge: start with any existing content, add/update required sections.
        var config = readExisting() ?? ParsedConfig(source: "")

        for section in Self.requiredSections {
            config.upsert(section: section)
        }

        let output = config.serialised()
        try output.write(to: Self.configURL, atomically: true, encoding: .utf8)
    }

    // MARK: - InstallResult

    public enum InstallResult: Sendable {
        case alreadyInstalled
        case installed
        case failed(Error)

        public var succeeded: Bool {
            switch self {
            case .alreadyInstalled, .installed: return true
            case .failed: return false
            }
        }

        public var errorDescription: String? {
            if case .failed(let e) = self { return e.localizedDescription }
            return nil
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - LogSection
// ═══════════════════════════════════════════════════════════════════════════════

/// One [Section] block in log.config.
struct LogSection: Sendable {
    let name: String
    var logLevel: Int
    var filePrinting: Bool
    var consolePrinting: Bool = false
    var screenPrinting: Bool = false

    /// The serialised text for this section.
    func serialised() -> String {
        """
        [\(name)]
        LogLevel=\(logLevel)
        FilePrinting=\(filePrinting ? "true" : "false")
        ConsolePrinting=\(consolePrinting ? "true" : "false")
        ScreenPrinting=\(screenPrinting ? "true" : "false")

        """
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - ParsedConfig
// ═══════════════════════════════════════════════════════════════════════════════

/// Simple mutable representation of a log.config file.
/// Tracks sections by name; preserves unrecognised sections verbatim.
struct ParsedConfig {

    /// One logical section — header line + key-value pairs.
    struct Section {
        var name: String
        var pairs: [(key: String, value: String)]

        func value(for key: String) -> String? {
            pairs.first(where: { $0.key.lowercased() == key.lowercased() })?.value
        }

        mutating func set(_ key: String, to value: String) {
            if let idx = pairs.firstIndex(where: { $0.key.lowercased() == key.lowercased() }) {
                pairs[idx] = (key, value)
            } else {
                pairs.append((key, value))
            }
        }
    }

    var sections: [Section] = []

    // MARK: Init

    init(source: String) {
        var currentSection: Section? = nil

        for line in source.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                // Flush previous section.
                if let s = currentSection { sections.append(s) }
                let name = String(trimmed.dropFirst().dropLast())
                currentSection = Section(name: name, pairs: [])

            } else if trimmed.contains("="), let current = currentSection {
                let parts = trimmed.components(separatedBy: "=")
                if parts.count >= 2 {
                    let key = parts[0].trimmingCharacters(in: .whitespaces)
                    let value = parts[1...].joined(separator: "=")
                        .trimmingCharacters(in: .whitespaces)
                    var updated = current
                    updated.pairs.append((key, value))
                    currentSection = updated
                }
            }
        }

        if let s = currentSection { sections.append(s) }
    }

    // MARK: Queries

    /// True if the required LogSection values are already present and correct.
    func contains(section: LogSection) -> Bool {
        guard let existing = sections.first(where: { $0.name == section.name }) else {
            return false
        }
        let lvl = existing.value(for: "LogLevel").flatMap(Int.init) ?? 0
        let fp = (existing.value(for: "FilePrinting") ?? "false").lowercased() == "true"
        return lvl >= section.logLevel && fp == section.filePrinting
    }

    // MARK: Mutations

    /// Insert a new section or update the required keys on an existing one.
    mutating func upsert(section: LogSection) {
        if let idx = sections.firstIndex(where: { $0.name == section.name }) {
            sections[idx].set("LogLevel", to: "\(section.logLevel)")
            sections[idx].set("FilePrinting", to: section.filePrinting ? "true" : "false")
            sections[idx].set("ConsolePrinting", to: section.consolePrinting ? "true" : "false")
            sections[idx].set("ScreenPrinting", to: section.screenPrinting ? "true" : "false")
        } else {
            var s = Section(name: section.name, pairs: [])
            s.set("LogLevel", to: "\(section.logLevel)")
            s.set("FilePrinting", to: section.filePrinting ? "true" : "false")
            s.set("ConsolePrinting", to: section.consolePrinting ? "true" : "false")
            s.set("ScreenPrinting", to: section.screenPrinting ? "true" : "false")
            sections.append(s)
        }
    }

    // MARK: Serialisation

    func serialised() -> String {
        sections.map { section in
            var lines = ["[\(section.name)]"]
            for (key, value) in section.pairs {
                lines.append("\(key)=\(value)")
            }
            lines.append("")  // blank line between sections
            return lines.joined(separator: "\n")
        }.joined(separator: "\n")
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - AppPreferences (UserDefaults wrapper)
// ═══════════════════════════════════════════════════════════════════════════════

/// Centralised preferences with type-safe accessors.
/// All keys are namespaced under "hs-helper." to avoid collisions.
public final class AppPreferences: ObservableObject, @unchecked Sendable {

    public static let shared = AppPreferences()

    private let defaults = UserDefaults.standard
    private enum Key {
        static let showOverlay = "hs-helper.showOverlay"
        static let overlayOpacity = "hs-helper.overlayOpacity"
        static let overlayScale = "hs-helper.overlayScale"
        static let overlayLocked = "hs-helper.overlayLocked"
        static let showOpponentPanel = "hs-helper.showOpponentPanel"
        static let showResourcesRow = "hs-helper.showResourcesRow"
        static let dimExhaustedCards = "hs-helper.dimExhaustedCards"
        static let launchAtLogin = "hs-helper.launchAtLogin"
        static let preferredScreenName = "hs-helper.preferredScreenName"
        static let gameLanguage = "hs-helper.gameLanguage"
        static let hideInBackground = "hs-helper.hideInBackground"
    }

    public init() {}

    // MARK: Overlay visibility

    public var showOverlay: Bool {
        get { defaults.object(forKey: Key.showOverlay) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Key.showOverlay)
            objectWillChange.send()
        }
    }

    public var hideInBackground: Bool {
        get { defaults.object(forKey: Key.hideInBackground) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Key.hideInBackground)
            objectWillChange.send()
        }
    }

    // MARK: Overlay appearance

    public var overlayOpacity: Double {
        get { defaults.object(forKey: Key.overlayOpacity) as? Double ?? 0.85 }
        set {
            defaults.set(newValue, forKey: Key.overlayOpacity)
            objectWillChange.send()
        }
    }

    public var overlayScale: Double {
        get { defaults.object(forKey: Key.overlayScale) as? Double ?? 1.0 }
        set {
            defaults.set(newValue, forKey: Key.overlayScale)
            objectWillChange.send()
        }
    }

    public var overlayLocked: Bool {
        get { defaults.object(forKey: Key.overlayLocked) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Key.overlayLocked)
            objectWillChange.send()
        }
    }

    // MARK: Panel components

    public var showOpponentPanel: Bool {
        get { defaults.object(forKey: Key.showOpponentPanel) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Key.showOpponentPanel)
            objectWillChange.send()
        }
    }

    public var showResourcesRow: Bool {
        get { defaults.object(forKey: Key.showResourcesRow) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Key.showResourcesRow)
            objectWillChange.send()
        }
    }

    public var dimExhaustedCards: Bool {
        get { defaults.object(forKey: Key.dimExhaustedCards) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Key.dimExhaustedCards)
            objectWillChange.send()
        }
    }

    // MARK: System

    public var gameLanguage: String {
        get { defaults.string(forKey: Key.gameLanguage) ?? "System" }
        set {
            defaults.set(newValue, forKey: Key.gameLanguage)
            objectWillChange.send()
        }
    }

    public var preferredScreenName: String {
        get { defaults.string(forKey: Key.preferredScreenName) ?? "" }
        set {
            defaults.set(newValue, forKey: Key.preferredScreenName)
            objectWillChange.send()
        }
    }

    /// The NSScreen that matches the preferred screen name, or main if not found.
    public var preferredScreen: NSScreen? {
        if preferredScreenName.isEmpty { return NSScreen.main }
        return NSScreen.screens.first { $0.localizedName == preferredScreenName }
            ?? NSScreen.main
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - SettingsView
// ═══════════════════════════════════════════════════════════════════════════════

/// The preferences window content.
/// Opened from the menu-bar item → Preferences…
public struct SettingsView: View {

    @StateObject private var prefs = AppPreferences.shared
    @State private var installResult: LogConfigInstaller.InstallResult? = nil
    @State private var showingRestartAlert = false

    private let installer = LogConfigInstaller.shared

    public init() {}

    public var body: some View {
        TabView {
            GeneralTab(
                prefs: prefs,
                installer: installer,
                installResult: $installResult,
                showingRestartAlert: $showingRestartAlert
            )
            .tabItem { Label("General", systemImage: "gearshape") }

            OverlayTab(prefs: prefs)
                .tabItem { Label("Overlay", systemImage: "rectangle.on.rectangle") }

            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 460, height: 340)
        .alert("Restart Hearthstone", isPresented: $showingRestartAlert) {
            Button("OK") {}
        } message: {
            Text(
                "hs-helper has installed the log configuration. Please restart Hearthstone for tracking to begin."
            )
        }
    }
}

// MARK: - GeneralTab

private struct GeneralTab: View {

    @ObservedObject var prefs: AppPreferences
    let installer: LogConfigInstaller
    @Binding var installResult: LogConfigInstaller.InstallResult?
    @Binding var showingRestartAlert: Bool

    var body: some View {
        Form {
            // ── Log config status ─────────────────────────────────────────────
            Section("Hearthstone Logging") {
                HStack {
                    Image(
                        systemName: installer.isInstalled
                            ? "checkmark.circle.fill"
                            : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(installer.isInstalled ? .green : .orange)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(
                            installer.isInstalled
                                ? "log.config is installed"
                                : "log.config is missing or incomplete"
                        )
                        .font(.body)

                        Text(logConfigPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    Spacer()

                    if !installer.isInstalled {
                        Button("Install") {
                            let result = installer.ensureInstalled()
                            installResult = result
                            if result.succeeded {
                                showingRestartAlert = installer.hearthstoneIsRunning
                            }
                        }
                        .controlSize(.small)
                    }
                }

                if installer.hearthstoneIsRunning {
                    Label(
                        "Hearthstone is running — restart it after any config change.",
                        systemImage: "arrow.clockwise.circle"
                    )
                    .foregroundStyle(.orange)
                    .font(.caption)
                }
            }

            // ── Monitor selection ─────────────────────────────────────────────
            Section("Display") {
                Picker("Show overlay on", selection: $prefs.preferredScreenName) {
                    Text("Primary display").tag("")
                    ForEach(NSScreen.screens, id: \.localizedName) { screen in
                        Text(screen.localizedName).tag(screen.localizedName)
                    }
                }
                .pickerStyle(.menu)
            }

            // ── Panels ────────────────────────────────────────────────────────
            Section("Panels") {
                Toggle("Show deck tracker overlay", isOn: $prefs.showOverlay)
                Toggle("Show opponent panel", isOn: $prefs.showOpponentPanel)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var logConfigPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Preferences/Blizzard/Hearthstone/log.config"
    }
}

// MARK: - OverlayTab

private struct OverlayTab: View {

    @ObservedObject var prefs: AppPreferences

    var body: some View {
        Form {
            Section("Appearance") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Opacity: \(Int(prefs.overlayOpacity * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $prefs.overlayOpacity, in: 0.3...1.0)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Scale: \(String(format: "%.0f%%", prefs.overlayScale * 100))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $prefs.overlayScale, in: 0.7...1.5)
                }
            }

            Section("Components") {
                Toggle("Show mana / turn row", isOn: $prefs.showResourcesRow)
                Toggle("Dim exhausted cards", isOn: $prefs.dimExhaustedCards)
            }

            Section("Language") {
                Picker("Game Language", selection: $prefs.gameLanguage) {
                    Text("System Default").tag("System")
                    Text("English").tag("enUS")
                    Text("Russian (Русский)").tag("ruRU")
                    Text("German (Deutsch)").tag("deDE")
                    Text("French (Français)").tag("frFR")
                    Text("Spanish (Español)").tag("esES")
                    Text("Korean (한국어)").tag("koKR")
                    Text("Japanese (日本語)").tag("jaJP")
                    Text("Chinese (简体中文)").tag("zhCN")
                    Text("Chinese (繁體中文)").tag("zhTW")
                }

                Text(
                    "Note: Changing the language requires restarting the app to download the correct card database."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Interaction") {
                Toggle("Hide when Hearthstone is backgrounded", isOn: $prefs.hideInBackground)
                Toggle("Lock overlay position", isOn: $prefs.overlayLocked)

                if !prefs.overlayLocked {
                    Label(
                        "Drag the overlay to reposition it. Lock when done.",
                        systemImage: "hand.draw"
                    )
                    .foregroundStyle(.secondary)
                    .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - OverlayTab
// MARK: - AboutTab

private struct AboutTab: View {

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.on.rectangle.slash.fill")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text("hs-helper")
                .font(.title2.bold())

            Text(
                "Native macOS Hearthstone deck tracker.\nLog-driven. No game hooking. No memory reading."
            )
            .multilineTextAlignment(.center)
            .font(.subheadline)
            .foregroundStyle(.secondary)

            Divider()
                .padding(.horizontal, 40)

            VStack(spacing: 4) {
                Link("HearthstoneJSON", destination: URL(string: "https://hearthstonejson.com")!)
                Link(
                    "Log format reference (HearthSim)",
                    destination: URL(string: "https://github.com/HearthSim/python-hslog")!)
            }
            .font(.footnote)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
