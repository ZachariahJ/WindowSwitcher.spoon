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
//   Thumbnails: first {"cmd":"snap","wids":[12345]} with a real window ID (in the Hammerspoon Console:
//   hs.window.focusedWindow():id()), then a show with "preview":true and "wid":12345 on that item.
//   Run from Terminal, capture uses Terminal's Screen Recording permission instead of Hammerspoon's.

import AppKit
import ScreenCaptureKit

// MARK: - Appearance
// Sizes in points. Windows that don't fit on one row wrap onto more rows (see show()).
//
// Example: bigger icons → icon = 80, and add ~16 to cardW and cardH so they don't get cramped
// Example: capsule-shaped panel → radius = 999 (capped at half the height automatically)
// Example: no fade-in → fade = 0
// Example: bigger thumbnails → previewW = 280, previewH = 210 (keep roughly the 4:3 of the defaults)
// Example: sharper thumbnails (more memory) → snapMax = 640
enum Style {
    static let icon: CGFloat = 64       // app icon size
    static let cardW: CGFloat = 112     // width of one window cell
    static let cardH: CGFloat = 108     // height of one window cell
    static let gap: CGFloat = 6         // space between cells
    static let pad: CGFloat = 14        // panel padding
    static let radius: CGFloat = 34     // panel corner radius; cell radius = radius - pad (concentric corners, a Liquid Glass rule)
    static let titleSize: CGFloat = 11  // window title font size
    static let fade: TimeInterval = 0.08
    // Live preview ("preview":true): bigger cells with a window thumbnail above the title
    static let previewW: CGFloat = 220  // width of one cell with preview
    static let previewH: CGFloat = 170  // height of one cell with preview
    static let badge: CGFloat = 28      // small app icon on the thumbnail's bottom-left corner
    static let snapMax: CGFloat = 440   // longest side of a cached thumbnail, in pixels (~0.5 MB each)
}

// MARK: - Messages
// One JSON object per line on stdin:
//   {"cmd":"show","sel":1,"screen":69734208,"preview":true,
//    "items":[{"id":"<bundleID>","title":"...","wid":12345}]}
//   {"cmd":"select","sel":2}      // sel starts at 0
//   {"cmd":"hide"}
//   {"cmd":"snap","wids":[12345,67890]}   // capture these windows into the thumbnail cache
// "screen" is the display ID (hs.screen:id() in Lua) to show the panel on; if missing or unknown,
// the panel goes on the main screen.
// "preview" turns on window thumbnails (taken from the cache, see snap); "wid" is the window's
// CGWindowID (hs.window:id() in Lua). Both are optional: without them it's the plain icon panel.
//
// Example: send an extra field from Lua (say, the app name) → add `let app: String` to Item,
//          and add app = ... to each item in init.lua's "show" message
struct Item: Decodable { let id: String; let title: String; let wid: Int? }
struct Message: Decodable { let cmd: String; let sel: Int?; let screen: Int?; let preview: Bool?; let items: [Item]?
                        let wids: [Int]? }

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
    // Lua sent (init.lua picks it).
    // One cell per window: icon + one-line title (truncated at the end).
    // Cells keep their full size: a row holds as many as fit in 90% of the screen width, the rest wrap
    // onto more rows (left to right, top to bottom; a short last row is centered) and the panel grows taller.
    // Only if the rows would be taller than 90% of the screen does everything scale down together.
    // Place the selection box, then fade in.
    //
    // Example: at most 6 per row → in the `cols` line, change min(n, ...) to min(n, 6, ...)
    // Example: last row aligned left instead of centered → change the x line to
    //     let x = pad + CGFloat(col) * (cw + gap)
    //
    // Example: which screen is chosen is decided in init.lua (see the examples above step()), not here
    // Example: panel a bit higher (like Spotlight) → in setFrame, change y's `/ 2` to `* 0.6`
    //   (AppKit's origin is bottom-left, so bigger y is higher)
    // Example: icons only, no titles → delete the NSTextField block and make cardH smaller
    //
    // With preview, each cell is: thumbnail area (the cached thumbnail plus a small badge icon,
    // or just the app icon in the middle if the window isn't cached yet) above the title.
    // Example: no badge icon on thumbnails → delete the `badge` lines in the preview block
    // Example: thumbnail only, no title, in preview mode → in the preview block, set
    //   `bottom = card.minY + 8 * s` and skip addSubview(label) when preview is true
    func show(_ items: [Item], sel: Int, screenID: Int?, preview: Bool) {
        shots = []
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let target = NSScreen.screens.first { ($0.deviceDescription[key] as? NSNumber)?.intValue == screenID }
        guard !items.isEmpty, let screen = target ?? NSScreen.main else { return }
        let sf = screen.visibleFrame
        let n = items.count
        let baseW = preview ? Style.previewW : Style.cardW
        let baseH = preview ? Style.previewH : Style.cardH
        let cols = max(1, min(n, Int((sf.width * 0.75 - 2 * Style.pad + Style.gap) / (baseW + Style.gap))))
        let rows = (n + cols - 1) / cols
        let fullH = 2 * Style.pad + CGFloat(rows) * baseH + CGFloat(rows - 1) * Style.gap
        let s = min(1, sf.height * 0.9 / fullH)   // 1 unless there are too many rows for the screen
        let pad = Style.pad * s, gap = Style.gap * s, cw = baseW * s, ch = baseH * s
        let iconSize = Style.icon * s
        let w = 2 * pad + CGFloat(cols) * cw + CGFloat(cols - 1) * gap
        let h = 2 * pad + CGFloat(rows) * ch + CGFloat(rows - 1) * gap
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
            let row = i / cols, col = i % cols
            let inRow = min(cols, n - row * cols)              // cells in this row (the last may be short)
            let rowW = CGFloat(inRow) * cw + CGFloat(inRow - 1) * gap
            let x = (w - rowW) / 2 + CGFloat(col) * (cw + gap)  // center the row
            let y = h - pad - ch - CGFloat(row) * (ch + gap)     // row 0 on top (AppKit's y grows upward)
            let card = NSRect(x: x, y: y, width: cw, height: ch)
            cards.append(card)

            let label = NSTextField(labelWithString: item.title)
            label.font = .systemFont(ofSize: Style.titleSize * s, weight: .medium)
            label.alignment = .center
            label.lineBreakMode = .byTruncatingTail
            label.frame = NSRect(x: x + 6 * s, y: card.minY + 8 * s, width: cw - 12 * s, height: Style.titleSize * s * 1.5)
            content.addSubview(label)

            let iv = NSImageView(image: icon(item.id))
            iv.imageScaling = .scaleProportionallyUpOrDown

            if preview {
                let top = card.maxY - 8 * s, bottom = label.frame.maxY + 6 * s
                let box = NSRect(x: x + 8 * s, y: bottom, width: cw - 16 * s, height: top - bottom)
                let thumb = NSImageView()
                thumb.imageScaling = .scaleProportionallyUpOrDown
                thumb.frame = box
                content.addSubview(thumb)

                iv.frame = NSRect(x: box.midX - iconSize / 2, y: box.midY - iconSize / 2,
                                  width: iconSize, height: iconSize)
                content.addSubview(iv)

                let b = Style.badge * s
                let badge = NSImageView(image: icon(item.id))
                badge.imageScaling = .scaleProportionallyUpOrDown
                badge.frame = NSRect(x: box.minX - 4 * s, y: box.minY - 4 * s, width: b, height: b)
                badge.isHidden = true            // shown together with a thumbnail
                content.addSubview(badge)

                let shot = Shot(wid: item.wid, thumb: thumb, placeholder: iv, badge: badge)
                shots.append(shot)
                fill(shot)
            } else {
                iv.frame = NSRect(x: x + (cw - iconSize) / 2, y: card.maxY - 12 * s - iconSize,
                                  width: iconSize, height: iconSize)
                content.addSubview(iv)
            }
        }
        select(sel)

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Style.fade
            panel.animator().alphaValue = 1
        }
    }

    // MARK: - Thumbnail cache
    // Thumbnails live in memory only (`cache`, keyed by window ID); nothing is written to disk.
    // The panel itself never captures: show() uses whatever is cached; an uncached window shows its app icon.
    // init.lua decides when to capture, by sending {"cmd":"snap","wids":[...]}:
    //   · when Cmd+Tab is pressed (just the current window) and when a window loses focus (just that one)
    //   · once at start, then every 300 s (every window on the current Space)
    // snap: look the IDs up in SCShareableContent, capture them all at once with SCScreenshotManager
    // (longest side Style.snapMax pixels), store them, and update the cell if the panel is open.
    // It also drops cached thumbnails of windows that no longer exist, so memory doesn't grow.
    // Windows that can't be captured (no Screen Recording permission, minimized, hidden, on another Space)
    // are skipped and keep their previous thumbnail, if any.
    //
    // Example: include the window's shadow → delete `cfg.ignoreShadowsSingleWindow = true`
    // Example: show the mouse pointer in thumbnails → cfg.showsCursor = true
    struct Shot { let wid: Int?; let thumb: NSImageView; let placeholder: NSImageView; let badge: NSImageView }
    var shots: [Shot] = []            // thumbnail cells of the open panel; empty when hidden
    var cache: [Int: NSImage] = [:]   // window ID → thumbnail

    // Put the cached thumbnail (if any) into a cell, replacing the app icon.
    func fill(_ shot: Shot) {
        guard let wid = shot.wid, let img = cache[wid] else { return }
        shot.thumb.image = img
        shot.placeholder.isHidden = true
        shot.badge.isHidden = false
    }

    func snap(_ wids: [Int]) {
        Task { @MainActor in
            // All windows (onScreenWindowsOnly: false), so pruning keeps minimized / other-Space windows
            guard let all = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            else { return }
            var byID: [Int: SCWindow] = [:]
            for w in all.windows { byID[Int(w.windowID)] = w }
            cache = cache.filter { byID[$0.key] != nil }

            await withTaskGroup(of: (Int, CGImage?).self) { group in
                for wid in wids {
                    guard let w = byID[wid], w.isOnScreen, w.frame.width > 0, w.frame.height > 0 else { continue }
                    let k = Style.snapMax / max(w.frame.width, w.frame.height)
                    let cfg = SCStreamConfiguration()
                    cfg.width = max(1, Int(w.frame.width * k))
                    cfg.height = max(1, Int(w.frame.height * k))
                    cfg.showsCursor = false
                    cfg.ignoreShadowsSingleWindow = true
                    let filter = SCContentFilter(desktopIndependentWindow: w)
                    group.addTask {
                        (wid, try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg))
                    }
                }
                for await (wid, img) in group {
                    guard let img else { continue }
                    cache[wid] = NSImage(cgImage: img, size: .zero)
                    shots.filter { $0.wid == wid }.forEach(fill)
                }
            }
        }
    }

    // MARK: - select
    // Just move the selection box to cell `sel`.
    func select(_ sel: Int) {
        guard cards.indices.contains(sel) else { return }
        highlight.frame = cards[sel]
    }

    // MARK: - hide
    // Hide the panel (kept around and reused by the next show). The thumbnail cache is kept.
    func hide() {
        shots = []
        panel.orderOut(nil)
    }

    func handle(_ m: Message) {
        switch m.cmd {
        case "show": show(m.items ?? [], sel: m.sel ?? 0, screenID: m.screen, preview: m.preview ?? false)
        case "select": select(m.sel ?? 0)
        case "hide": hide()
        case "snap": snap(m.wids ?? [])
        default: break
        }
    }
}

// MARK: - Entry point
// Run as an accessory app (no Dock icon).
// A background thread reads stdin line by line, decodes it, and hands it to the main thread.
// Every line read is answered with {"event":"read"} on stdout: init.lua waits for these before
// sending more (hs.task:setInput drops a write if another comes before it's done; see send() in init.lua).
// On EOF (Hammerspoon reloaded or quit) the process exits, so it never lingers.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let switcher = Switcher()

Thread.detachNewThread {
    while let line = readLine() {
        print("{\"event\":\"read\"}")
        fflush(stdout)
        guard let m = try? JSONDecoder().decode(Message.self, from: Data(line.utf8)) else { continue }
        DispatchQueue.main.async { switcher.handle(m) }
    }
    exit(0)
}
app.run()
