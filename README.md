# WindowSwitcher.spoon

English | [简体中文](README.zh-CN.md)

Windows-style Alt+Tab for macOS, as a [Hammerspoon](https://www.hammerspoon.org) Spoon.
**Cmd+Tab switches between windows, not apps**, on a native Liquid Glass panel.

![WindowSwitcher panel](screenshot.png)

- Two windows of the same app are separate entries, so you can jump straight to the one you want.
- Most recently used first: a quick Cmd+Tab tap goes back to the previous window without showing the panel.
- The panel is a real `NSGlassEffectView` (macOS 26 Liquid Glass), not an imitation.
- Fast: no window thumbnails; the panel is drawn by a small native helper that stays running (~8 MB).

## Keys

| Key | Action |
| --- | --- |
| Cmd+Tab | Next window (first press selects the previously used window) |
| Cmd+Shift+Tab | Previous window |
| Release Cmd | Switch to the selected window |
| Esc | Cancel |
| Hover a window | Marks it with a fainter box (the Cmd+Tab selection doesn't move) |
| Click a window | Switch to it |

Only windows on the current Space are listed. The panel appears on the display under the mouse.

## Requirements

- macOS 26 or later
- [Hammerspoon](https://www.hammerspoon.org), with Accessibility permission
- Xcode Command Line Tools (`xcode-select --install`), used to compile the panel helper

## Install

**With [SpoonInstall](https://www.hammerspoon.org/Spoons/SpoonInstall.html)** — add to `~/.hammerspoon/init.lua` and reload:

```lua
hs.loadSpoon("SpoonInstall")
spoon.SpoonInstall.repos.WindowSwitcher = {
  url = "https://github.com/ZachariahJ/WindowSwitcher.spoon",
  desc = "WindowSwitcher.spoon",
  branch = "main",
}
spoon.SpoonInstall:andUse("WindowSwitcher", { repo = "WindowSwitcher", start = true })
```

**With git**

```sh
git clone https://github.com/ZachariahJ/WindowSwitcher.spoon ~/.hammerspoon/Spoons/WindowSwitcher.spoon
```

Then add to `~/.hammerspoon/init.lua` and reload:

```lua
hs.loadSpoon("WindowSwitcher")
spoon.WindowSwitcher:start()
```

To update, `git pull` in that folder and reload.

Either way, the first start compiles the panel helper, which freezes Hammerspoon for a few seconds.
It only recompiles when `glass.swift` changes.

## Configuration

```lua
hs.loadSpoon("WindowSwitcher")
spoon.WindowSwitcher.delay = 0   -- show the panel immediately (default 0.12 s)
spoon.WindowSwitcher:start()
```

`spoon.WindowSwitcher:stop()` gives you the system Cmd+Tab back.

More tweaks are documented as comments in the source, with examples:
Alt+Tab instead of Cmd+Tab, arrow keys, all Spaces, hiding apps, which display the panel appears on (`init.lua`);
clear or tinted glass, sizes, panel position (`glass.swift`).

## How it works

- `init.lua` does the logic. macOS reserves Cmd+Tab, so it is caught with an `hs.eventtap`.
  Windows come from `hs.window.filter`, sorted by most recent use, and releasing Cmd focuses the selected one.
- `glass.swift` draws the panel. Hammerspoon can't create Liquid Glass itself, so this small AppKit program does it.
  It's compiled to `glass` on first start, runs in the background, and gets one JSON command per line on stdin
  (`show`, `select`, `hide`). Clicks go back to `init.lua` the same way, one JSON line on stdout.
  It exits when Hammerspoon reloads or quits.

## Development

After changing the Spoon, run `./build.sh` before committing. It regenerates `docs/docs.json` and
`Spoons/WindowSwitcher.spoon.zip`, which SpoonInstall downloads.

## License

MIT
