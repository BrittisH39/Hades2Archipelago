---@meta _
---@diagnostic disable: lowercase-global
-- One-time setup (not re-run on hot-reload). Load our modules once; all the
-- live wiring happens in reload.lua so it can be iterated on without restarting.

import 'APState.lua'
import 'Routes.lua'
import 'Overlay.lua'
import 'Notifications.lua'
import 'Bridge.lua'
import 'ItemManager.lua'
import 'UnitArtPackages.lua' -- before LocationManager: its CHECK_TO_UNIT_ID pick reads it
import 'LocationManager.lua'
import 'EnemySanity.lua'
import 'MinibossRooms.lua'
import 'Journal.lua'
import 'Traps.lua'

rom.log.info("[AP] Hades II Archipelago plugin loaded.")

-- Apply the load-time-critical settings from the on-disk cache NOW, at boot, before the player can
-- start a new game. The live connection only delivers SETTINGS after a save loads (the socket poll
-- runs on the render loop, which doesn't tick at the menu), which is too late for a fresh save's
-- intro run -- so the starting weapon reads from the last session's cached settings here instead.
-- The cache also backstops the fresh-save intro redirect (ItemManager.redirect_intro_args reads
-- settings at StartNewRun if the live blocking fetch can't reach the client). Safe no-op if
-- there's no cache yet (first ever connect).
pcall(function() ItemManager.apply_cached_settings() end)

-- Dream Dive bed force-unlock: add our own OR-branch to the NATIVE (vanilla, not
-- DreamDiveTweaks-added) game.NamedRequirementsData.DreamRunsUnlocked, true only once
-- ItemManager.sync_dream_bed_unlocked has determined zone 1 of Dream is actually reachable
-- (GameState.Archipelago.dream_bed_unlocked -- route_zone_unlocked("Dream", 1) mirrored into
-- save state, since PathTrue can't call a Lua function directly). This used to read a plain
-- "is Dream part of this seed" flag with no regard for dream_offset/lock_routes, so the bed
-- was force-unlocked from frame one even on seeds where Dream isn't the starting route --
-- letting the player start a Dream run the StartRoom route-lock backstop (reload.lua) then
-- killed them for on the very first room. Same table/injection pattern DreamDiveTweaks' OWN
-- early_unlock.lua already uses for its own early-access config -- confirmed by reading that
-- file directly. pcall-guarded since this table's existence in a given game version isn't
-- something we control; a missing table just means the bed keeps its normal vanilla gating
-- instead of silently crashing plugin load.
pcall(function()
  if game.NamedRequirementsData and game.NamedRequirementsData.DreamRunsUnlocked then
    table.insert(game.NamedRequirementsData.DreamRunsUnlocked.OrRequirements, {
      PathTrue = { "GameState", "Archipelago", "dream_bed_unlocked" },
    })
    rom.log.info("[AP] Dream Dive bed force-unlock requirement installed")
  end
end)
