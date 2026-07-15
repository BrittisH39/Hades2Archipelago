---@diagnostic disable: lowercase-global
-- Notifications.lua — big in-game banners for the Archipelago events worth interrupting
-- for (DeathLink, route-locked deaths), drawn with the game's OWN DisplayInfoBanner so they
-- match the rest of the UI. Everything else -- sent checks, ALL item receipts (filler and
-- important alike), the per-room score readout, and the bridge-connection diagnostic -- goes to
-- the subtle corner log in Overlay.lua instead. See Notifications.push for the routing.
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

-- Native scripted-sequence tracker: AddInputBlock/RemoveInputBlock (engine-native, no Lua
-- reader exposed) is the game's general-purpose "something scripted is happening, don't let
-- the player act" signal -- used for boss-kill presentations, MapLoad, StartRoom, dream-run
-- transitions, Eris' curse cutscene (ErisCurseAppliedPresentation), etc. reload.lua wraps both
-- functions and mirrors every named block into this table so Notifications.blocked() below can see it
-- (there's no ScreenAnchors entry for most of these -- ScreenAnchors only covers modal screens
-- like the boon-choice UI, not scripted cutscenes).
Notifications.active_input_blocks = Notifications.active_input_blocks or {}

function Notifications.on_input_block(name, active)
  if not name then return end
  if active then
    Notifications.active_input_blocks[name] = true
  else
    Notifications.active_input_blocks[name] = nil
  end
end

function Notifications.clear_input_blocks()
  Notifications.active_input_blocks = {}
end

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
    -- Item receipts go to the corner log ONLY now. The big banner used to also fire for
    -- non-filler items, but it was redundant with the corner log and interruptive, so the
    -- banner is reserved for the rare events worth breaking focus for (DeathLink / route-locked).
    return
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
  -- Only "received" / "death" / "locked" ever reach the queue ("sent" is routed
  -- straight to the corner log in Notifications.push and never banners).
  local prefix, color
  if n.kind == "received" then
    prefix, color = "Received: ", { 70, 200, 130, 255 }
  elseif n.kind == "death" then
    prefix, color = "DeathLink: ", { 210, 70, 70, 255 }
  elseif n.kind == "warning" then  -- bridge-connection diagnostic (Bridge.status_text)
    prefix, color = "", { 210, 90, 60, 255 }
  else  -- "locked": orange, no prefix (e.g. area-locked death)
    prefix, color = "", { 210, 130, 60, 255 }
  end
  return {
    TitleText = "Archipelago",
    SubtitleText = prefix .. n.text,
    Color = color,
    TextColor = { 255, 255, 255, 255 },
    SubTextColor = { 235, 240, 255, 255 },
    Duration = (n.kind == "locked" or n.kind == "warning") and 6.0 or 3.0,
    TitleFont = "SpectralSCLightTitling",
    SubtitleFont = "SpectralSCLightTitling",
    Layer = "Combat_Menu_TraitTray_Overlay",
    AnimationName = "LocationBackingIrisSmallIn",
    AnimationOutName = "LocationBackingIrisSmallOut",
    IconBackingAnimationName = "LocationBackingIrisSmallSubtitleIn",
    IconBackingAnimationOutName = "LocationBackingIrisSmallSubtitleOut",
    TextRevealSound = "/Leftovers/Menu Sounds/TextReveal3",
  }
end

-- Screen states where popping a banner is unsafe: DisplayInfoBanner's own
-- SessionMapState.BlockInfoBanners guard covers Codex/Encounter/Event/Hub/Resource
-- moments, but Supergiant never needed it for the boon-choice screen (vanilla code
-- never fires a banner from there). Spawning our screen obstacle on top of that modal
-- while it holds input focus is what softlocks the choice screen -- so hold the queue
-- ourselves while ScreenAnchors marks one of these screens open.
-- Also covers the Trait Tray ("boon inventory" -- the hold-a-button overlay showing your
-- current boons/Daedalus upgrades/keepsakes, TraitTrayLogic.lua) via ActiveScreens.TraitTrayScreen.
-- Unlike ChoiceScreen/QuestLogScreen it isn't tracked in ScreenAnchors -- it's a modal,
-- player-openable-mid-room screen that caches its own trait component list at open time, so any
-- live grant that calls AddTraitToHero while it's open (a Daedalus hammer, Arachne Armor, the
-- stat-bonus/armor top-ups) mutates CurrentRun.Hero.Traits out from under it and locks up input --
-- reported as "looking at boon inventory when anything is added freezes the game."
-- Public so the item-receipt gate (ItemManager.receive_safe) and the DeathLink gate
-- (deathlink_can_apply) can reuse the SAME "is a conversation or boon screen up?" test the banner
-- uses -- one source of truth for "don't interrupt right now."
function Notifications.blocked()
  local anchors = game.ScreenAnchors
  if anchors ~= nil and (anchors.ChoiceScreen ~= nil or anchors.QuestLogScreen ~= nil) then
    return true
  end
  local screens = game.ActiveScreens
  if screens ~= nil and screens.TraitTrayScreen ~= nil then
    return true
  end
  if next(Notifications.active_input_blocks) ~= nil then
    return true
  end
  return false
end

-- Called every render frame from reload.lua. Shows the next queued banner when the
-- game is in a map/run state and isn't already showing one.
function Notifications.update()
  local q = Notifications.queue
  if #q == 0 then return end
  local sms = game.SessionMapState
  if not sms then return end              -- main menu / loading: hold until in a map
  if sms.ShowingInfoBanner then return end -- one banner at a time
  if sms.BlockInfoBanners then return end
  if Notifications.blocked() then return end -- e.g. boon selection: leave queued, don't drop
  local n = table.remove(q, 1)
  pcall(function()
    if game.thread and game.DisplayInfoBanner then
      game.thread(game.DisplayInfoBanner, nil, banner_args(n))
    end
  end)
end
