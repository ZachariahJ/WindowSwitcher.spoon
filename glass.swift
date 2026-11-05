// glass.swift — the WindowSwitcher panel, using native Liquid Glass (NSGlassEffectView, macOS 26+).
// init.lua compiles this to `glass`, launches it with hs.task, and sends commands on stdin.
// glass draws the panel and reports clicks on stdout; keys and window switching are in init.lua.
//
// After editing this file, reload Hammerspoon and it recompiles automatically (takes a few seconds).
//
// Try it by hand: in Terminal, cd into this folder, run ./glass, then paste a line and press Return:
//     {"cmd":"show","sel":0,"items":[{"id":"com.apple.finder","title":"Finder"},{"id":"com.apple.Safari","title":"Safari"}]}
//   Then try {"cmd":"select","sel":1} and {"cmd":"hide"}. Ctrl+D quits.
//   Hover a cell to see the hover box; clicking one prints {"event":"click","sel":N}.

import AppKit

// MARK: - Appearance
// Sizes in points. If the windows don't fit on one row, everything scales down together.
//
// Example: bigger icons → icon = 80, and add ~16 to cardW and cardH so they don't get cramped
// Example: capsule-shaped panel → radius = 999 (capped at half the height automatically)
// Example: no fade-in → fade = 0
enum Style {
    static let icon: CGFloat = 64       // app icon size
    static let cardW: CGFloat = 112     // width of one window cell
    static let cardH: CGFloat = 108     // height of one window cell
    static let gap: CGFloat = 6         // space between cells
    static let pad: CGFloat = 14        // panel padding
    static let radius: CGFloat = 34     // panel corner radius; cell radius = radius - pad (concentric corners, a Liquid Glass rule)
    static let titleSize: CGFloat = 11  // window title font size
    static let fade: TimeInterval = 0.08
}

// MARK: - Messages
// One JSON object per line on stdin:
//   {"cmd":"show","sel":1,"screen":69734208,"items":[{"id":"<bundleID>","title":"..."}]}
//   {"cmd":"select","sel":2}      // sel starts at 0
//   {"cmd":"hide"}
// "screen" is the display ID (hs.screen:id() in Lua) to show the panel on; if missing or unknown,
// the panel goes on the main screen.
//
// Example: send an extra field from Lua (say, the app name) → add `let app: String` to Item,
//          and add app = ... to each item in init.lua's "show" message
struct Item: Decodable { let id: String; let title: String }
struct Message: Decodable { let cmd: String; let sel: Int?; let screen: Int?; let items: [Item]? }

// MARK: - Mouse
// The view holding the cells; it takes every mouse event in the panel (so icons and labels don't
// swallow clicks) and passes the position on: onMove (nil = mouse left), onClick.
// glass is never the active app, hence acceptsFirstMouse and .activeAlways.
final class Cells: NSView {
    var onMove: ((NSPoint?) -> Void)?
    var onClick: ((NSPoint) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited,
                                                               .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with e: NSEvent) { onMove?(convert(e.locationInWindow, from: nil)) }
    override func mouseExited(with e: NSEvent) { onMove?(nil) }
    override func mouseDown(with e: NSEvent) { onClick?(convert(e.locationInWindow, from: nil)) }
}

final class Switcher {
    // MARK: - Panel
    // A borderless, non-activating, transparent NSPanel at .popUpMenu level, on all Spaces.
    // Its contentView is an NSGlassEffectView; the cells and the two boxes go inside the glass:
    // highlight = the Cmd+Tab selection, hover = fainter box under the mouse (doesn't change the selection).
    // A click prints {"event":"click","sel":N} on stdout for init.lua.
    let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
    let glass = NSGlassEffectView()
    let content = Cells()
    let highlight = NSView()
    let hover = NSView()
    var cards: [NSRect] = []
    var icons: [String: NSImage] = [:]

    // Example: clearer glass (more of the background shows through) → glass.style = .clear
    // Example: tinted glass → add glass.tintColor = NSColor.systemPurple.withAlphaComponent(0.2)
    // Example: blue selection box → change the highlight backgroundColor to
    //          NSColor.systemBlue.withAlphaComponent(0.35).cgColor
    // Example: stronger hover box → raise hover's 0.08 / 0.18 (keep below highlight's 0.18 / 0.35)
    // Example: no mouse at all → add panel.ignoresMouseEvents = true
    init() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false               // the glass draws its own shadow
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        glass.style = .regular
        glass.contentView = content
        panel.contentView = glass

        for (box, fill, border) in [(highlight, 0.18, 0.35), (hover, 0.08, 0.18)] {
            box.wantsLayer = true
            box.layer?.backgroundColor = NSColor.white.withAlphaComponent(fill).cgColor
            box.layer?.borderColor = NSColor.white.withAlphaComponent(border).cgColor
            box.layer?.borderWidth = 1
            box.layer?.cornerCurve = .continuous
        }

        content.onMove = { [unowned self] p in
            if let i = p.flatMap(card(at:)) {
                hover.frame = cards[i]
                hover.isHidden = false
            } else {
                hover.isHidden = true
            }
        }
        content.onClick = { [unowned self] p in
            guard let i = card(at: p) else { return }
            print("{\"event\":\"click\",\"sel\":\(i)}")
            fflush(stdout)  // stdout is a pipe; without this the line sits in a buffer
        }
    }

    // Index of the cell under point p, or nil for padding and gaps.
    func card(at p: NSPoint) -> Int? { cards.firstIndex { $0.contains(p) } }

    // MARK: - App icons
    // Look up the icon by bundle ID (NSWorkspace) and cache it.
    // If the app can't be found (empty bundle ID, uninstalled), use the generic app icon.
    func icon(_ id: String) -> NSImage {
        if let cached = icons[id] { return cached }
        let img = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(named: NSImage.applicationIconName)!
        icons[id] = img
        return img
    }

    // MARK: - show
    // Size the panel for the number of windows and center it on the screen whose display ID
    // Lua sent (the screen of the focused window; init.lua picks it).
    // One cell per window: icon + one-line title (truncated at the end).
    // Place the selection box, then fade in.
    //
    // Example: which screen is chosen is decided in init.lua (see the examples above step()), not here
    // Example: panel a bit higher (like Spotlight) → in setFrame, change y's `/ 2` to `* 0.6`
    //   (AppKit's origin is bottom-left, so bigger y is higher)
    // Example: icons only, no titles → delete the NSTextField block and make cardH smaller
    func show(_ items: [Item], sel: Int, screenID: Int?) {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let target = NSScreen.screens.first { ($0.deviceDescription[key] as? NSNumber)?.intValue == screenID }
        guard !items.isEmpty, let screen = target ?? NSScreen.main else { return }
        let sf = screen.visibleFrame
        let n = CGFloat(items.count)
        let s = min(1, (sf.width * 0.9 - 2 * Style.pad + Style.gap) / (n * (Style.cardW + Style.gap)))
        let pad = Style.pad * s, gap = Style.gap * s, cw = Style.cardW * s, ch = Style.cardH * s
        let iconSize = Style.icon * s
        let w = 2 * pad + n * cw + (n - 1) * gap, h = 2 * pad + ch
        let r = min(Style.radius * s, h / 2)

        panel.setFrame(NSRect(x: sf.midX - w / 2, y: sf.minY + (sf.height - h) / 2, width: w, height: h),
                       display: false)
        glass.cornerRadius = r
        content.frame = NSRect(x: 0, y: 0, width: w, height: h)
        content.subviews = [hover, highlight]   // hover first so it sits below the selection box
        hover.isHidden = true                    // appears once the mouse moves over a cell
        for box in [highlight, hover] { box.layer?.cornerRadius = max(r - pad, 4) }

        cards = []
        for (i, item) in items.enumerated() {
            let x = pad + CGFloat(i) * (cw + gap)
            let card = NSRect(x: x, y: pad, width: cw, height: ch)
            cards.append(card)

            let iv = NSImageView(image: icon(item.id))
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.frame = NSRect(x: x + (cw - iconSize) / 2, y: card.maxY - 12 * s - iconSize,
                              width: iconSize, height: iconSize)
            content.addSubview(iv)

            let label = NSTextField(labelWithString: item.title)
            label.font = .systemFont(ofSize: Style.titleSize * s, weight: .medium)
            label.alignment = .center
            label.lineBreakMode = .byTruncatingTail
            label.frame = NSRect(x: x + 6 * s, y: pad + 8 * s, width: cw - 12 * s, height: Style.titleSize * s * 1.5)
            content.addSubview(label)
        }
        select(sel)

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Style.fade
            panel.animator().alphaValue = 1
        }
    }

    // MARK: - select
    // Just move the selection box to cell `sel`.
    func select(_ sel: Int) {
        guard cards.indices.contains(sel) else { return }
        highlight.frame = cards[sel]
    }

    // MARK: - hide
    // Hide the panel (kept around and reused by the next show).
    func hide() { panel.orderOut(nil) }

    func handle(_ m: Message) {
        switch m.cmd {
        case "show": show(m.items ?? [], sel: m.sel ?? 0, screenID: m.screen)
        case "select": select(m.sel ?? 0)
        case "hide": hide()
        default: break
        }
    }
}

// MARK: - Entry point
// Run as an accessory app (no Dock icon).
// A background thread reads stdin line by line, decodes it, and hands it to the main thread.
// On EOF (Hammerspoon reloaded or quit) the process exits, so it never lingers.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let switcher = Switcher()

Thread.detachNewThread {
    while let line = readLine() {
        guard let m = try? JSONDecoder().decode(Message.self, from: Data(line.utf8)) else { continue }
        DispatchQueue.main.async { switcher.handle(m) }
    }
    exit(0)
}
app.run()
