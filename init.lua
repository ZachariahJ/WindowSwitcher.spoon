--- === WindowSwitcher ===
---
--- Windows-style Alt+Tab for macOS: Cmd+Tab switches between windows on a native Liquid Glass panel.
---
--- It switches *windows*, not apps, so two windows of the same app are separate entries.
--- The panel is a real `NSGlassEffectView` (macOS 26+), not an imitation.
---
--- Keys:
---  * Cmd+Tab        - next window (the first press selects the previously used window)
---  * Cmd+Shift+Tab  - previous window
---  * release Cmd    - switch to the selected window
---  * Esc            - cancel
---
--- A quick Cmd+Tab tap switches straight back to the previous window without showing the panel.
---
--- How it works: this file does all the logic (key interception, window list, focusing).
--- `glass.swift` only draws the panel. It is compiled to `glass` on first start
--- (needs Xcode Command Line Tools), runs in the background, and takes one JSON command per line on stdin.
---
--- Install with SpoonInstall (see README), or `git clone https://github.com/ZachariahJ/WindowSwitcher.spoon ~/.hammerspoon/Spoons/WindowSwitcher.spoon`
---
--- Download: [https://github.com/ZachariahJ/WindowSwitcher.spoon/raw/main/Spoons/WindowSwitcher.spoon.zip](https://github.com/ZachariahJ/WindowSwitcher.spoon/raw/main/Spoons/WindowSwitcher.spoon.zip)

-- Usage (in ~/.hammerspoon/init.lua):
--     hs.loadSpoon("WindowSwitcher")
--     spoon.WindowSwitcher:start()
--
-- Example: temporarily get the system Cmd+Tab back → run spoon.WindowSwitcher:stop() in the Console,
--          and spoon.WindowSwitcher:start() to turn it on again

local types = hs.eventtap.event.types
local TAB = hs.keycodes.map.tab
local ESC = hs.keycodes.map.escape

-- Spoon metadata
local obj = {}
obj.__index = obj
obj.name = "WindowSwitcher"
obj.version = "1.1.0"
obj.author = "ZachariahJ"
obj.homepage = "https://github.com/ZachariahJ/WindowSwitcher.spoon"
obj.license = "MIT - https://opensource.org/licenses/MIT"

-- Settings

--- WindowSwitcher.delay
--- Variable
--- Seconds Cmd+Tab must be held before the panel appears. Default `0.12`.
--- A tap shorter than this switches to the previous window without showing the panel.
---
--- Notes:
---  * Example: show the panel immediately → `spoon.WindowSwitcher.delay = 0` before `:start()`
obj.delay = 0.12

-- Paths inside this Spoon's folder. glass and glass.sha256 are build outputs (not shipped).
local SRC = hs.spoons.resourcePath("glass.swift")
local BIN = hs.spoons.resourcePath("glass")
local STAMP = hs.spoons.resourcePath("glass.sha256")

-- Which windows to list: normal windows on the current Space, most recently used first.
--
-- Example: list windows from all Spaces (picking one jumps to its Space) → change
--          setCurrentSpace(true) to setCurrentSpace(nil)
-- Example: hide an app → append :rejectApp("Finder")
-- Example: also list dialogs (preferences windows, pop-ups) → change allowRoles to "*"
--          (this also lets in things like the Teams notification center or Zoom's floating button)
local wf = hs.window.filter.new():setCurrentSpace(true):setDefaultFilter{ allowRoles = "AXStandardWindow" }

-- Build glass
-- Recompile when glass is missing or glass.swift changed. Changes are detected by content hash
-- rather than modification time, because unzipping an update can leave the source "older" than the old binary.
-- Hammerspoon freezes for a few seconds while compiling; this only happens on first run or after an update.
local function readFile(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("a")
  f:close()
  return s
end

local function build()
  local hash = hs.hash.SHA256(readFile(SRC))
  if hs.fs.attributes(BIN) and readFile(STAMP) == hash then return true end
  local out, ok = hs.execute(string.format('/usr/bin/swiftc -O "%s" -o "%s" 2>&1', SRC, BIN))
  if not ok then
    hs.alert.show("WindowSwitcher: failed to compile glass.swift\n"
      .. "Needs Xcode Command Line Tools (xcode-select --install). See Console.")
    print(out)
    return false
  end
  local f = io.open(STAMP, "w")
  f:write(hash)
  f:close()
  return true
end

-- Talk to glass
-- One JSON object per line on its stdin, e.g. {"cmd":"select","sel":2}
local function send(t)
  if obj.task and obj.task:isRunning() then
    obj.task:setInput(hs.json.encode(t) .. "\n")
  end
end

-- State
obj.windows = nil  -- window list while switching; nil when not switching
obj.index = nil    -- selected window (Lua index, starts at 1; glass gets index - 1)
obj.timer = nil    -- delay before showing the panel
obj.shown = false  -- whether glass is currently showing the panel

-- step(dir): move the selection by dir (+1 / -1)
-- First call: grab the window list and start the delay timer; when it fires, send "show".
-- Every call: move the selection, wrapping around; if the panel is visible, send "select".
--
-- The panel goes on the screen under the mouse; glass gets that screen's display ID.
--
-- Example: show something else for untitled windows (e.g. "(untitled)") → change app:name() in the title line
-- Example: show on the focused window's screen instead → change the screen line to
--     local focused = hs.window.focusedWindow()
--     local screen = focused and focused:screen() or hs.mouse.getCurrentScreen()
-- Example: always show on the primary display (the one with the menu bar) → change the screen line to
--     local screen = hs.screen.primaryScreen()
local function step(dir)
  if not obj.windows then
    obj.windows = wf:getWindows(hs.window.filter.sortByFocusedLast)
    if #obj.windows == 0 then obj.windows = nil return end
    obj.index = 1
    obj.timer = hs.timer.doAfter(obj.delay, function()
      local items = {}
      for i, win in ipairs(obj.windows) do
        local app = win:application()
        local title = win:title() or ""
        if title == "" and app then title = app:name() end
        items[i] = { id = app and app:bundleID() or "", title = title }
      end
      local screen = hs.mouse.getCurrentScreen()
      send({ cmd = "show", sel = obj.index - 1, screen = screen and screen:id(), items = items })
      obj.shown = true
    end)
  end
  obj.index = (obj.index - 1 + dir) % #obj.windows + 1
  if obj.shown then send({ cmd = "select", sel = obj.index - 1 }) end
end

-- finish(focus): stop switching
-- Stop the timer, hide the panel, and if focus is true, focus the selected window.
local function finish(focus)
  if obj.timer then obj.timer:stop() end
  if obj.shown then send({ cmd = "hide" }) end
  local win = focus and obj.windows[obj.index]
  obj.windows, obj.index, obj.timer, obj.shown = nil, nil, nil, false
  if win then win:focus() end
end

-- Mouse
-- glass prints {"event":"click","sel":N} on stdout when a cell is clicked (sel starts at 0);
-- that switches to the window, like releasing Cmd on it. The hover box is drawn by glass alone.
--
-- Example: a click only moves the selection (releasing Cmd switches) → replace the two lines in the if with
--     obj.index = m.sel + 1; send({ cmd = "select", sel = m.sel })
local function onOutput(_, out)
  for line in (out or ""):gmatch("[^\n]+") do
    local ok, m = pcall(hs.json.decode, line)
    if ok and type(m) == "table" and m.event == "click" and obj.windows and obj.windows[m.sel + 1] then
      obj.index = m.sel + 1
      finish(true)
    end
  end
  return true
end

-- Key interception
-- macOS reserves Cmd+Tab, so hs.hotkey can't bind it; an eventtap can.
--   Cmd+Tab / Cmd+Shift+Tab   → step(±1) and swallow the key (the system switcher never appears)
--   Esc while switching       → cancel
--   Cmd released while switching → switch
--   anything else             → passed through
--
-- Example: use Alt+Tab instead → swap f.cmd and f.alt below (in both branches)
-- Example: arrow keys move the selection while the panel is open → add before the Esc check:
--     if obj.windows and key == hs.keycodes.map.left then step(-1) return true end
--     if obj.windows and key == hs.keycodes.map.right then step(1) return true end
-- Example: W closes the selected window → add:
--     if obj.windows and key == hs.keycodes.map.w then obj.windows[obj.index]:close(); finish(false) return true end
obj.tap = hs.eventtap.new({ types.keyDown, types.flagsChanged }, function(e)
  local f = e:getFlags()
  if e:getType() == types.flagsChanged then
    if obj.windows and not f.cmd then finish(true) end
    return false
  end
  local key = e:getKeyCode()
  if key == TAB and f.cmd and not f.alt and not f.ctrl then
    step(f.shift and -1 or 1)
    return true
  end
  if obj.windows and key == ESC then
    finish(false)
    return true
  end
  return false
end)

-- start / stop

--- WindowSwitcher:start()
--- Method
--- Compiles the panel helper if needed, launches it, and starts intercepting Cmd+Tab.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The WindowSwitcher object
---
--- Notes:
---  * Requires macOS 26 or later (Liquid Glass) and Xcode Command Line Tools (to compile `glass.swift`).
function obj:start()
  if hs.host.operatingSystemVersion().major < 26 then
    hs.alert.show("WindowSwitcher needs macOS 26 or later")
    return self
  end
  if not build() then return self end
  -- The third argument (a streaming callback) is required: without it, hs.task closes
  -- stdin after the first write, and glass exits on EOF. It also receives glass's stdout (clicks).
  self.task = hs.task.new(BIN, function(code)
    print("WindowSwitcher: glass exited, code = " .. tostring(code))
  end, onOutput)
  self.task:start()
  self.tap:start()
  return self
end

--- WindowSwitcher:stop()
--- Method
--- Stops intercepting Cmd+Tab (the system app switcher comes back) and quits the panel helper.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The WindowSwitcher object
function obj:stop()
  self.tap:stop()
  if self.windows then finish(false) end
  if self.task then self.task:terminate() end
  self.task = nil
  return self
end

return obj
