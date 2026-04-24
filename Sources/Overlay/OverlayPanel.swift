// Sources/Overlay/OverlayPanel.swift
// NSPanel subclass that floats above Hearthstone at .statusBar window level.
// Renders SwiftUI content via NSHostingView.
// Handles fullscreen-auxiliary behaviour, monitor persistence, drag-to-reposition.
//
// Key AppKit flags:
//   .statusBar level          — above .floating, below system UI
//   .fullScreenAuxiliary      — renders in Spaces fullscreen (the critical flag for HS)
//   .canJoinAllSpaces         — follows the user across every Space
//   .stationary               — doesn't animate with Exposé
//   .nonactivatingPanel       — clicking the overlay never steals focus from HS
//   ignoresMouseEvents = true — fully click-through by default

import AppKit
import SwiftUI

// MARK: - OverlayPanel

/// A borderless, transparent, non-activating NSPanel that stays above all
/// normal application windows including Hearthstone running in Borderless
/// Windowed or Spaces fullscreen mode.
public final class OverlayPanel: NSPanel {

    // MARK: Init

    /// - Parameters:
    ///   - contentRect: Initial frame in screen coordinates.
    ///   - screen: The screen this panel belongs to (used for position persistence).
    public init(contentRect: NSRect, screen: NSScreen? = NSScreen.main) {
        super.init(
            contentRect: contentRect,
            styleMask: [
                .borderless,
                .nonactivatingPanel,
                .fullSizeContentView,
            ],
            backing: .buffered,
            defer: false
        )

        configureWindow()
    }

    // MARK: - NSPanel overrides

    /// Must return false — we never want the overlay to become the key window.
    /// Returning true here would steal keyboard focus from Hearthstone.
    override public var canBecomeKey: Bool { false }
    override public var canBecomeMain: Bool { false }

    // MARK: - Private configuration

    private func configureWindow() {
        // ── Window level ──────────────────────────────────────────────────────
        // .statusBar (level 25) sits above floating windows (3) but below
        // the system notification HUD.  This is the correct level for a
        // game overlay that should not obscure macOS UI.
        level = .statusBar

        // ── Collection behaviour ──────────────────────────────────────────────
        // .canJoinAllSpaces  — follow the user across Mission Control spaces
        // .fullScreenAuxiliary — THE critical flag: renders inside the Spaces
        //   fullscreen window that Hearthstone occupies when run in fullscreen
        // .stationary — panel does not move during Exposé/Mission Control
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
        ]

        // ── Appearance ────────────────────────────────────────────────────────
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = false

        // ── Interaction ───────────────────────────────────────────────────────
        // Click-through by default — the user interacts with HS, not us.
        // OverlayController toggles this off only during drag-to-reposition.
        ignoresMouseEvents = true

        // Do not hide when the app deactivates.
        hidesOnDeactivate = false

        // Keep the panel object alive after it is "closed".
        isReleasedWhenClosed = false

        // ── Ordering ──────────────────────────────────────────────────────────
        // orderFrontRegardless bypasses the normal activation-policy check
        // so the panel appears even when our app has .accessory policy.
        orderFrontRegardless()
    }
}

// MARK: - OverlayController

/// Owns the overlay panel and its SwiftUI content view.
/// Lives on the MainActor — all mutations happen on the main thread.
@MainActor
public final class OverlayController {

    // MARK: Public state

    /// Whether the overlay is currently visible.
    public private(set) var isVisible: Bool = false

    /// When true the panel ignores mouse events (click-through).
    /// Set to false to enable drag-to-reposition.
    public var isLocked: Bool = true {
        didSet { panel?.ignoresMouseEvents = isLocked }
    }

    // MARK: Private

    private var panel: OverlayPanel?
    private var hostingView: NSHostingView<AnyView>?

    // Persistence keys
    private let positionKeyPrefix: String
    private let defaultFrameProvider: ((NSScreen?) -> NSRect)?

    // MARK: Init

    public init(id: String, defaultFrameProvider: ((NSScreen?) -> NSRect)? = nil) {
        self.positionKeyPrefix = "overlay.frame.\(id)."
        self.defaultFrameProvider = defaultFrameProvider
    }

    // MARK: - Public API

    /// Show the overlay displaying `content`.
    /// If the panel already exists, replaces the content view.
    public func show<Content: View>(content: Content, on screen: NSScreen? = nil) {
        let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first

        if panel == nil {
            let frame = restoredFrame(for: targetScreen) ?? defaultFrame(for: targetScreen)
            let p = OverlayPanel(contentRect: frame, screen: targetScreen)
            panel = p
        }

        if let hosting = hostingView {
            hosting.rootView = AnyView(content)
        } else {
            let hosting = NSHostingView(rootView: AnyView(content))
            hosting.frame = panel!.contentView?.bounds ?? .zero
            hosting.autoresizingMask = [.width, .height]

            panel!.contentView = hosting
            hostingView = hosting
        }

        panel!.ignoresMouseEvents = isLocked
        panel!.orderFrontRegardless()
        isVisible = true
    }

    /// Hide the overlay without destroying it.
    public func hide() {
        panel?.orderOut(nil)
        isVisible = false
    }

    /// Completely tear down the overlay (call on app quit).
    public func tearDown() {
        saveFrameIfNeeded()
        panel?.close()
        panel?.contentView = nil
        panel = nil
        hostingView = nil
        isVisible = false
    }

    /// Move the overlay to a specific position on screen.
    public func move(to origin: CGPoint) {
        guard let p = panel else { return }
        p.setFrameOrigin(NSPoint(x: origin.x, y: origin.y))
        saveFrameIfNeeded()
    }

    /// Move the overlay by a translation offset.
    /// Called from the drag handler in the SwiftUI content view.
    /// Does NOT persist — the drag handler calls `saveFrameIfNeeded()` once
    /// on drag end to avoid hammering UserDefaults for every frame.
    public func move(by translation: CGSize) {
        guard let p = panel else { return }
        var origin = p.frame.origin
        origin.x += translation.width
        // SwiftUI drag translation: positive Y is down.
        // AppKit window coordinates: origin is bottom-left, so positive Y is up.
        origin.y -= translation.height
        p.setFrameOrigin(origin)
    }

    /// Resize the overlay.
    public func resize(to size: CGSize) {
        guard let p = panel else { return }
        var frame = p.frame
        frame.size = size
        p.setFrame(frame, display: true, animate: false)
        saveFrameIfNeeded()
    }

    /// Call when the user finishes dragging to persist the new position.
    public func saveFrameIfNeeded() {
        guard let p = panel else { return }
        let key = positionKeyPrefix + screenIdentifier(for: p.screen)
        UserDefaults.standard.set(NSStringFromRect(p.frame), forKey: key)
    }

    /// Move the overlay to the default position for the given screen.
    public func resetPosition(for screen: NSScreen? = nil) {
        let s = screen ?? panel?.screen ?? NSScreen.main
        let frame = defaultFrame(for: s)
        panel?.setFrame(frame, display: true, animate: true)
        saveFrameIfNeeded()
    }

    // MARK: - Frame helpers

    /// The default frame: right edge of the screen, vertically centred,
    /// 240 pt wide × 720 pt tall — matches the pencil-new.pen panel spec
    /// and fits inside the Hearthstone UI's right-side safe zone.
    private func defaultFrame(for screen: NSScreen?) -> NSRect {
        if let custom = defaultFrameProvider {
            return custom(screen)
        }
        guard let screen else {
            return NSRect(x: 20, y: 200, width: 240, height: 720)
        }
        let sv = screen.visibleFrame
        let w: CGFloat = 240
        let h: CGFloat = min(720, sv.height - 40)
        let x = sv.maxX - w - 20
        let y = sv.minY + (sv.height - h) / 2
        return NSRect(x: x, y: y, width: w, height: h)
    }

    /// Load the last known frame for the given screen from UserDefaults.
    private func restoredFrame(for screen: NSScreen?) -> NSRect? {
        let key = positionKeyPrefix + screenIdentifier(for: screen)
        guard let str = UserDefaults.standard.string(forKey: key) else { return nil }
        let rect = NSRectFromString(str)
        guard rect != .zero else { return nil }

        // Validate the frame is still on a connected screen.
        let onScreen = NSScreen.screens.contains { $0.frame.intersects(rect) }
        return onScreen ? rect : nil
    }

    /// A stable string identifier for a screen, based on its localised name
    /// or frame as a fallback.  Used as the UserDefaults key suffix.
    private func screenIdentifier(for screen: NSScreen?) -> String {
        guard let screen else { return "main" }
        if #available(macOS 10.15, *) {
            return screen.localizedName
                .replacingOccurrences(of: " ", with: "_")
        }
        return NSStringFromRect(screen.frame)
    }
}

// MARK: - DraggableOverlayModifier

/// SwiftUI ViewModifier that makes the content draggable by moving the
/// whole NSPanel continuously as the user drags — the content itself never
/// shifts relative to the window chrome, which is what users expect.
///
/// `onDrag` receives per-frame delta offsets (not cumulative translations).
public struct DraggableOverlayModifier: ViewModifier {

    @State private var previous: CGSize = .zero
    private let onDrag: (CGSize) -> Void
    private let onEnd: () -> Void

    public init(onDrag: @escaping (CGSize) -> Void, onEnd: @escaping () -> Void) {
        self.onDrag = onDrag
        self.onEnd = onEnd
    }

    public func body(content: Content) -> some View {
        content
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { value in
                        let delta = CGSize(
                            width: value.translation.width - previous.width,
                            height: value.translation.height - previous.height
                        )
                        previous = value.translation
                        onDrag(delta)
                    }
                    .onEnded { _ in
                        previous = .zero
                        onEnd()
                    }
            )
    }
}

extension View {
    public func draggableOverlay(
        onDrag: @escaping (CGSize) -> Void,
        onEnd: @escaping () -> Void = {}
    ) -> some View {
        modifier(DraggableOverlayModifier(onDrag: onDrag, onEnd: onEnd))
    }
}
