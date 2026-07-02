---@diagnostic disable: lowercase-global
-- Notifications.lua — big in-game banners for the Archipelago events worth interrupting
-- for (important item receipts, DeathLink, route-locked deaths), drawn with the game's
-- OWN DisplayInfoBanner so they match the rest of the UI. Routine traffic (sent checks,
-- filler items, the per-room score readout) goes to the subtle corner log in Overlay.lua;
-- important items appear in BOTH. See Notifications.push for the routing.
--
-- DisplayInfoBanner only shows one banner at a time (it early-outs while
-- SessionMapState.ShowingInfoBanner is set), so we keep a queue and feed it one entry
-- per opening, drained every frame from reload.lua's render-loop driver. That also
-- keeps things from overlapping / feeling spammy.
--
-- UNVERIFIED in-game — tune here (everything is centralized in this file):
--   1) DisplayInfoBanner may treat SubtitleText as a localization key; AP names are
--      dynamic, so they might render as the raw string (fine) or need a raw-text path.
--   2) Whether threading DisplayInfoBanner from the render callback is safe (it's a
--      one-shot, guarded by SessionMapState, so it should be — but confirm).
--   3) Colors / duration / fonts.

Notifications = Notifications or {}
Notifications.queue = Notifications.queue or {}

local MAX_QUEUE = 12              -- cap the backlog so a flood can't pile up forever

-- Tier routing:
--   kind = "received" — an item we got. Important (non-filler) items show on BOTH the big
--                       banner and the corner log; filler items show on the corner log only.
--   kind = "sent"     — a check we sent. Corner log only. (Sent lines normally come straight
--                       to Overlay with the "<player> - <item>" detail from the client's
--                       CHECKED reply; this path is the plain fallback.)
--   kind = "death" / "locked" — always the banner (rare, important events).
function Notifications.push(kind, text)
  if not text or text == "" then return end

  if kind == "sent" then
    if Overlay then Overlay.push("Sent: " .. text, Overlay.COLOR.sent) end
    return
  end

  if kind == "received" then
    local filler = ItemManager and ItemManager.is_filler and ItemManager.is_filler(text)
    if Overlay then
      Overlay.push("Received: " .. text, filler and Overlay.COLOR.received or Overlay.COLOR.important)
    end
    if filler then return end   -- filler: corner log only; important items also banner below
  end

  local q = Notifications.queue
  q[#q + 1] = { kind = kind, text = tostring(text) }
  -- Past the cap, drop the oldest entry to keep the backlog bounded.
  while #q > MAX_QUEUE do
    table.remove(q, 1)
  end
end

-- Build DisplayInfoBanner args, styled after the game's small "Familiar Recruited"
-- banner (small iris animation, Spectral titling font), tinted by event kind.
local function banner_args(n)
  local prefix, color
  if n.kind == "received" then
    prefix, color = "Received: ", { 70, 200, 130, 255 }
  elseif n.kind == "death" then
    prefix, color = "DeathLink: ", { 210, 70, 70, 255 }
  elseif n.kind == "locked" then
    prefix, color = "", { 210, 130, 60, 255 }  -- orange, no prefix (e.g. area-locked death)
  else  -- "sent"
    prefix, color = "Sent: ", { 120, 150, 220, 255 }
  end
  return {
    TitleText = "Archipelago",
    SubtitleText = prefix .. n.text,
    Color = color,
    TextColor = { 255, 255, 255, 255 },
    SubTextColor = { 235, 240, 255, 255 },
    Duration = (n.kind == "sent") and 2.0 or (n.kind == "locked") and 6.0 or 3.0,
    TitleFont = "SpectralSCLightTitling",
    SubtitleFont = "SpectralSCLightTitling",
    Layer = "Combat_Menu_TraitTray_Overlay",
    AnimationName = "LocationBackingIrisSmallIn",
    AnimationOutName = "LocationBackingIrisSmallOut",
    IconBackingAnimationName = "LocationBackingIrisSmallSubtitleIn",
    IconBackingAnimationOutName = "LocationBackingIrisSmallSubtitleOut",
    TextRevealSound = (n.kind ~= "sent") and "/Leftovers/Menu Sounds/TextReveal3" or nil,
  }
end

-- Called every render frame from reload.lua. Shows the next queued banner when the
-- game is in a map/run state and isn't already showing one.
function Notifications.update()
  local q = Notifications.queue
  if #q == 0 then return end
  local sms = game.SessionMapState
  if not sms then return end              -- main menu / loading: hold until in a map
  if sms.ShowingInfoBanner then return end -- one banner at a time
  local n = table.remove(q, 1)
  pcall(function()
    if game.thread and game.DisplayInfoBanner then
      game.thread(game.DisplayInfoBanner, nil, banner_args(n))
    end
  end)
end
