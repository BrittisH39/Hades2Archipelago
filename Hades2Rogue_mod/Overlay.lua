---@diagnostic disable: lowercase-global
-- Overlay.lua — the on-screen Archipelago feed.
--
-- Surfaces routine traffic (checks we send, filler we receive) plus a pinned "Score X/Y"
-- readout. Two view modes (Test Run 6 #1):
--   * COMPACT (default): a small window showing the pinned score line and the last few feed
--     lines — "enough to show the score and a couple of checks".
--   * EXPANDED: a larger, scrollable window showing the full recent history (no fading), for
--     when you want to review everything that happened.
-- Toggle compact/expanded with the "AP [+]/[-]" button in the header; close it with the "x"
-- button. A keyboard shortcut (config.overlay_toggle_key, default F8; registered in reload.lua)
-- shows/hides it again at any time, even mid-run.
--
-- INTERACTION MODEL (this is the bit that bit us before): ImGui only receives mouse/keyboard
-- input while the Hell2Modding menu is open (VK_INSERT). So:
--   * Menu OPEN  (rom.gui.is_open()==true): the overlay is a normal window — drag it to move,
--     drag the edge to resize (expanded), click the header buttons to expand/close.
--   * Menu CLOSED (normal play): it's drawn passively with NoInputs (locked + click-through) so
--     it can never eat gameplay input. Press Insert when you want to rearrange it.
-- Position/size are persisted by ImGui (imgui.ini) — we only set them on first use — so a drag
-- sticks across rooms and restarts.
--
-- The big native DisplayInfoBanner (Notifications.lua) stays reserved for things worth
-- interrupting for (non-filler items, DeathLink, route-locked deaths).
--
-- Drawn every frame from reload.lua's render driver. Auto-fading in compact mode.

Overlay = Overlay or {}
Overlay.lines = Overlay.lines or {}   -- ring buffer of { text, r, g, b, born }
Overlay.score = Overlay.score or nil  -- pinned { text, r, g, b } (latest "Score X/Y"); never fades
Overlay.diag = Overlay.diag or nil    -- pinned { text, r, g, b } bridge-connection diagnostic; never fades
Overlay.room = Overlay.room or nil    -- pinned room/depth number for this run; drawn top-right of the anchor line
if Overlay.enabled == nil then Overlay.enabled = true end
if Overlay.expanded == nil then Overlay.expanded = false end

local HISTORY_MAX     = 60     -- total feed lines kept (for the expanded scroll view)
local COMPACT_LINES   = 4      -- feed lines shown in compact mode (below the score)
local LIFETIME        = 6.0    -- seconds a compact line stays fully opaque
local FADE            = 1.5    -- seconds it then takes to fade out
local POS_X           = 24     -- top-left anchor (kept clear of the top-center banner)
local POS_Y           = 200
local BG_ALPHA        = 0.42   -- faint backing so text stays readable over bright scenes
local EXPANDED_W      = 460    -- expanded window size
local EXPANDED_H      = 320

-- Color palette (0-255), by event kind.
Overlay.COLOR = {
  sent      = { 130, 165, 235 },  -- checks we sent out (blue)
  received  = { 90, 205, 140 },   -- filler items we got (green)
  important = { 235, 205, 90 },   -- non-filler items (gold) — these ALSO show on the banner
  score     = { 235, 240, 255 },  -- the per-room "Score X/Y" readout (near-white)
  header    = { 180, 190, 210 },  -- the AP toggle / heading
  warning   = { 235, 120, 90 },   -- bridge-connection diagnostic (orange-red)
}

-- Frame clock. os.clock is wall-time seconds and is always available; the render driver
-- calls draw() every frame so this advances smoothly.
local function now()
  return os.clock()
end

-- Append a feed line. color is {r,g,b} (0-255); defaults to the near-white tint.
function Overlay.push(text, color)
  if not text or text == "" then return end
  color = color or Overlay.COLOR.score
  local l = Overlay.lines
  l[#l + 1] = { text = tostring(text), r = color[1], g = color[2], b = color[3], born = now() }
  while #l > HISTORY_MAX do table.remove(l, 1) end
end

-- Set the pinned "Score X/Y" readout (always shown at the top, never fades). Pass nil to clear.
function Overlay.set_score(text, color)
  if not text or text == "" then Overlay.score = nil; return end
  color = color or Overlay.COLOR.score
  Overlay.score = { text = tostring(text), r = color[1], g = color[2], b = color[3] }
end

-- Set the pinned bridge-connection diagnostic (Bridge.status_text(), driven from reload.lua).
-- Shown in warning color right under the score line, never fades. Pass nil to clear.
function Overlay.set_diag(text)
  if not text or text == "" then Overlay.diag = nil; return end
  local color = Overlay.COLOR.warning
  Overlay.diag = { text = tostring(text), r = color[1], g = color[2], b = color[3] }
end

-- Set the pinned "Room ##" readout (this run's scored-room depth counter; LocationManager
-- drives this from score_room/score_encounter). Pass nil or 0 to clear (no run in progress).
function Overlay.set_room(n)
  if not n or n <= 0 then Overlay.room = nil; return end
  Overlay.room = tostring(n)
end

-- Show/hide the overlay. Bound to the keyboard shortcut in reload.lua so it can be reopened
-- after closing (the "x" button sets Overlay.enabled = false).
--
-- Debounced: a Lua hot-reload re-runs reload.lua's `rom.inputs.on_key_pressed` registration,
-- and its guard (a bare global) does NOT reliably survive the reload (confirmed via
-- LogOutput.log: "Keybind Registered: None F8 - Archipelago: Toggle Overlay" logged twice in
-- one session with no game restart in between). Since `Overlay` itself DOES persist across a
-- hot-reload (`Overlay = Overlay or {}`), both the old and new handler close over the SAME
-- table, so one F8 press can call this twice and flip-then-flip-back -> looks like F8 "does
-- nothing". Collapse near-simultaneous calls into a single flip so a stacked duplicate handler
-- can't cancel a real press out.
local TOGGLE_DEBOUNCE = 0.2 -- seconds
function Overlay.toggle()
  local t = now()
  if Overlay._last_toggle and (t - Overlay._last_toggle) < TOGGLE_DEBOUNCE then
    return Overlay.enabled
  end
  Overlay._last_toggle = t
  Overlay.enabled = not Overlay.enabled
  return Overlay.enabled
end

function Overlay.set_visible(v)
  Overlay.enabled = not not v
end

-- Resolve an ImGuiWindowFlags_* value across the binding's possible shapes; 0 if unknown.
local function flag(name)
  local v = rawget(_G, "ImGuiWindowFlags_" .. name)
  if v ~= nil then return v end
  if ImGui and ImGui["WindowFlags_" .. name] ~= nil then return ImGui["WindowFlags_" .. name] end
  local t = rawget(_G, "ImGuiWindowFlags")
  if type(t) == "table" and t[name] ~= nil then return t[name] end
  return 0
end

-- ImGuiCond_FirstUseEver — note this is an ImGuiCond, NOT a WindowFlags, so it can't go through
-- flag() above. Resolve it across binding shapes, falling back to the stable upstream enum value
-- (None=0, Always=1, Once=2, FirstUseEver=4). Used so we set the window's default pos/size only
-- once and then leave the player's dragged position alone (persisted via imgui.ini).
local function cond_first_use_ever()
  local v = rawget(_G, "ImGuiCond_FirstUseEver")
  if v ~= nil then return v end
  if ImGui and ImGui["Cond_FirstUseEver"] ~= nil then return ImGui["Cond_FirstUseEver"] end
  local t = rawget(_G, "ImGuiCond")
  if type(t) == "table" and t.FirstUseEver ~= nil then return t.FirstUseEver end
  return 4
end

-- Distinct power-of-two flags, so addition == bitwise OR (avoids needing 5.3+ bitops).
-- `interactive` = the Hell2Modding menu is open, so ImGui is actually receiving mouse input;
-- only then do we let the window be moved/resized. We deliberately DON'T set NoSavedSettings,
-- so ImGui remembers the position/size the player dragged it to (imgui.ini).
local function window_flags(interactive)
  local f = flag("NoTitleBar") + flag("NoCollapse") + flag("NoNavInputs") + flag("NoNavFocus")
    + flag("NoFocusOnAppearing")
  if not interactive then
    -- Passive: lock it down and let clicks pass through to the game.
    f = f + flag("NoInputs") + flag("NoMove")
  end
  if Overlay.expanded then
    -- Expanded scroll view: resizable only while interactive.
    if not interactive then f = f + flag("NoResize") end
  else
    -- Compact: auto-sized chip, never a scrollbar.
    f = f + flag("NoResize") + flag("NoScrollbar") + flag("AlwaysAutoResize")
  end
  return f
end

-- Draw one colored, optionally-faded text line.
local function draw_line(ig, line, alpha)
  local ok = pcall(function()
    ig.TextColored(line.r / 255, line.g / 255, line.b / 255, alpha, line.text)
  end)
  if not ok then pcall(function() ig.Text(line.text) end) end
end

-- Draw "Room ##" right-aligned on the current line (tacked onto the anchor/score line so it
-- sits opposite the "Archipelago"/"Score X/Y" text). Falls back to a plain SameLine gap if the
-- binding doesn't expose the layout queries needed for true right-alignment.
local function draw_room(ig, text)
  local ok = pcall(function()
    if ig.SameLine and ig.GetWindowWidth and ig.CalcTextSize then
      local avail_w = ig.GetWindowWidth()
      local sz = ig.CalcTextSize(text)
      local w = type(sz) == "table" and (sz.x or sz[1]) or sz
      ig.SameLine(math.max(0, (avail_w or 0) - (w or 0) - 16))
    elseif ig.SameLine then
      ig.SameLine(0, 24)
    end
    ig.TextColored(180 / 255, 190 / 255, 210 / 255, 0.85, text)
  end)
  if not ok then pcall(function() ig.Text(text) end) end
end

-- The "AP" header row: an expand/collapse toggle plus a close button. Buttons only respond
-- while the menu is open (input routed); otherwise they just render. Drag the window body to
-- move it (a no-title-bar ImGui window is moved by its body when NoMove isn't set).
local function draw_header(ig)
  local toggle_label = (Overlay.expanded and "AP  [-]" or "AP  [+]") .. "##ap_toggle"
  pcall(function()
    if ig.SmallButton then
      if ig.SmallButton(toggle_label) then Overlay.expanded = not Overlay.expanded end
    else
      ig.TextColored(0.7, 0.74, 0.82, 1.0, Overlay.expanded and "AP  [-]" or "AP  [+]")
    end
  end)
  pcall(function()
    if ig.SmallButton and ig.SameLine then
      ig.SameLine()
      if ig.SmallButton("x##ap_close") then Overlay.enabled = false end
    end
  end)
end

-- Called every render frame from reload.lua. Prunes expired compact lines and draws.
function Overlay.draw()
  -- Self-heal the ImGui handle: if the captured `ImGui` global was lost across a reload/reset,
  -- fall back to rom.ImGui so the overlay can't silently die (Test Run 6 #1).
  local ig = ImGui or (rom and rom.ImGui)
  if not Overlay.enabled or not ig then return end

  local l = Overlay.lines
  local t = now()
  -- In compact mode, drop fully-faded lines so the window stays small. In expanded mode keep
  -- everything (it's a scrollable history) until the ring buffer rolls it off.
  if not Overlay.expanded then
    for i = #l, 1, -1 do
      if (t - l[i].born) > (LIFETIME + FADE) then table.remove(l, i) end
    end
  end

  -- Is the Hell2Modding menu open? Only then does ImGui receive mouse input, so only then is
  -- the window movable/resizable/clickable. Guarded: default to passive if the call is missing.
  local interactive = false
  pcall(function() interactive = rom and rom.gui and rom.gui.is_open and rom.gui.is_open() or false end)

  -- Set position/size ONLY on first use (or once, if FirstUseEver isn't available) so dragging
  -- the window actually sticks. Pinning it every frame is what blocked moving it before.
  local fue = cond_first_use_ever()
  pcall(function()
    if not ig.SetNextWindowPos then return end
    if fue ~= 0 then ig.SetNextWindowPos(POS_X, POS_Y, fue)
    elseif not Overlay._placed then ig.SetNextWindowPos(POS_X, POS_Y) end
  end)
  pcall(function() if ig.SetNextWindowBgAlpha then ig.SetNextWindowBgAlpha(BG_ALPHA) end end)
  if Overlay.expanded then
    pcall(function()
      if not ig.SetNextWindowSize then return end
      if fue ~= 0 then ig.SetNextWindowSize(EXPANDED_W, EXPANDED_H, fue)
      elseif not Overlay._placed then ig.SetNextWindowSize(EXPANDED_W, EXPANDED_H) end
    end)
  end
  Overlay._placed = true

  -- Begin/End MUST stay balanced or ImGui crashes: only End when Begin actually ran, and keep
  -- content in its own pcall so a bad draw call can't skip the End.
  local began = false
  pcall(function() ig.Begin("##ap_overlay", window_flags(interactive)); began = true end)
  if not began then return end
  pcall(function()
    draw_header(ig)
    if Overlay.score then
      draw_line(ig, Overlay.score, 1.0)
    else
      -- Keep a visible anchor line so toggling the overlay on always shows *something*.
      draw_line(ig, { text = "Archipelago", r = 180, g = 190, b = 210 }, 0.7)
    end
    if Overlay.room then draw_room(ig, "Room " .. Overlay.room) end
    if Overlay.diag then draw_line(ig, Overlay.diag, 1.0) end
    if ig.Separator then pcall(ig.Separator) end

    if Overlay.expanded then
      -- Full scrollable history (oldest -> newest), no fading.
      for i = 1, #l do draw_line(ig, l[i], 1.0) end
    else
      -- Compact: just the last COMPACT_LINES, faded by age.
      local startIdx = math.max(1, #l - COMPACT_LINES + 1)
      for i = startIdx, #l do
        local age = t - l[i].born
        local a = 1.0
        if age > LIFETIME then a = math.max(0, 1 - (age - LIFETIME) / FADE) end
        draw_line(ig, l[i], a)
      end
    end
  end)
  pcall(function() ig.End() end)
end
