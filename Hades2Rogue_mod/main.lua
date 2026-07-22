---@meta _
-- Hades II Archipelago — plugin entry point.
-- Modeled on the official SGG Hades2ModTemplate.

---@diagnostic disable-next-line: undefined-global
local mods = rom.mods

---@module 'LuaENVY-ENVY-auto'
mods['LuaENVY-ENVY'].auto()
-- ^ gives us `public`, `import`, `import_as_fallback`, and makes our globals
--   private to this plugin.
---@diagnostic disable: lowercase-global

---@diagnostic disable-next-line: undefined-global
rom = rom
---@diagnostic disable-next-line: undefined-global
_PLUGIN = _PLUGIN
-- ImGui lives under `rom.ImGui` (see Hell2Modding's ImGui example), not as a bare
-- global. Capture it so reload.lua can use plain `ImGui`.
ImGui = rom.ImGui
rom.log.info("[AP] ImGui captured: " .. tostring(ImGui ~= nil))

-- the game's globals, available as a fallback for any name we don't define
---@module 'game'
game = rom.game
---@module 'game-import'
import_as_fallback(game)

---@module 'SGG_Modding-SJSON'
sjson = mods['SGG_Modding-SJSON']
---@module 'SGG_Modding-ModUtil'
modutil = mods['SGG_Modding-ModUtil']
---@module 'SGG_Modding-Chalk'
chalk = mods['SGG_Modding-Chalk']
---@module 'SGG_Modding-ReLoad'
reload = mods['SGG_Modding-ReLoad']

-- ---- Recovery shim: ModUtil's shared once_loaded.game dispatch --------------
-- ModUtil runs EVERY mod's once_loaded.game callback from one unprotected `for`
-- loop (its main.lua, trigger_loaded.game): one mod throwing aborts the loop and
-- silently skips every mod registered after it. Confirmed in the wild 2026-07-18:
-- zerp-NPCRoomRandomizer's ready.lua indexed Zagreus' Journey story rooms
-- (A/X/Y_Story01) before ZJ's own callback had registered them, threw, and took
-- down zerp-Extended_NPC_Encounters, the zannc keepsake mods, and all of Zagreus'
-- Journey with it, every boot.
--
-- The ROOT fix for that specific crash is load order, done in OUR manifest.json:
-- NikkelM-Zagreus_Journey is listed as our own dependency, ahead of the zerp
-- entries. Confirmed via ReturnOfModdingBase source (src/lua/lua_manager.hpp,
-- `load_all_modules`) that the native loader genuinely topologically sorts
-- plugin load order from each manifest's `dependencies` array (DFS post-order:
-- a mod's declared dependencies are visited, and load, before the mod itself) --
-- this isn't a guess, it's read directly from the loader's own C++. Listing ZJ
-- here makes it (and its whole zannc/NikkelM chain) load and register ahead of
-- zerp, which is the order those mods are designed for, so zerp never reaches
-- the crash site at all.
--
-- 2026-07-19: briefly reverted this and shipped ZJ as an unlisted soft
-- dependency instead, over concern about force-downloading a large mod (needs
-- its own separate Hades 1 install) for every player via r2modman/Thunderstore,
-- which read this exact same `dependencies` field to auto-install. Confirmed via
-- the loader's manifest struct (src/thunderstore/v1/manifest.hpp) that no
-- separate soft/optional-dependency field exists in this schema, so it really
-- was force-all-or-force-nothing. Re-added ZJ as a hard dependency the same day
-- once the call was made that both zerp mods AND ZJ are core, expected parts of
-- this mod's helper-randomization feature, not exotic opt-ins.
--
-- 2026-07-21: removed the hard dependency again (see
-- project_zj_optional_dependency_restored memory), and separately tried
-- preseeding minimal stub data for the specific rooms/encounters zerp's mods
-- index before ZJ registers them (see project_zerp_zj_roomdata_preseed_fix
-- memory) instead of fixing load order. That approach found three independent,
-- differently-shaped crashes across two zerp mods in one evening (room
-- GameStateRequirements, room LegalEncounters, then a nested EncounterData
-- array meant to be mutated by ZJ's real registration) with no sign of
-- converging, and the third case risked silently WRONG behavior (data quietly
-- lost to ZJ's later overwrite) instead of a crash if stubbed. Abandoned that
-- approach and restored the hard dependency below -- load order is what every
-- one of these third-party mods actually assumes, and it's the only fix that
-- covers the whole class instead of one assumption at a time.
--
-- This shim stays as the safety net for the whole CLASS of failure (any mod's
-- once_loaded.game throwing, not just this one) -- wrap the dispatch so a
-- throwing callback gets logged and the dispatch re-run, letting mods queued
-- after the failure still initialize. SGG_Modding-ReLoad de-duplicates on_ready
-- per mod (handle_load marks the sig loaded BEFORE calling on_ready), so a re-run
-- never double-fires any mod's on_ready; on_reload steps re-run, which is their
-- documented contract (same as any hot-reload). With a healthy queue (the normal
-- case now that ZJ is listed) the pcall succeeds first try and behavior is
-- byte-identical to stock ModUtil.
do
  local ok, err = pcall(function()
    local mu = mods['SGG_Modding-ModUtil']
    local priv = mu and mu.private
    local tl = priv and priv.trigger_loaded
    if tl and type(tl.game) == 'function'
        and tl.game ~= priv.AP_Hades2Rogue_game_dispatch_wrap then
      local orig = tl.game
      local function dispatch_with_recovery()
        for attempt = 1, 3 do
          local ok2, err2 = pcall(orig)
          if ok2 then return end
          rom.log.error('[AP] a mod errored inside once_loaded.game dispatch (attempt '
            .. attempt .. '/3): ' .. tostring(err2))
          if attempt < 3 then
            rom.log.warning('[AP] re-running once_loaded.game dispatch so mods queued after the failure still initialize')
          end
        end
        rom.log.error('[AP] once_loaded.game dispatch still failing after 3 attempts -- some mods may not have initialized')
      end
      tl.game = dispatch_with_recovery
      priv.AP_Hades2Rogue_game_dispatch_wrap = dispatch_with_recovery
    end
  end)
  if not ok then
    rom.log.warning('[AP] could not install once_loaded.game recovery shim: ' .. tostring(err))
  end
end

---@module 'config'
config = chalk.auto 'config.lua'
public.config = config

local function on_ready()
  -- runs once when the game's lua is ready; not re-run on hot-reload
  if config.enabled == false then return end
  mod = modutil.mod.Mod.Register(_PLUGIN.guid)
  import 'ready.lua'
end

local function on_reload()
  -- runs on ready AND on every hot-reload; keep it safe to re-run
  if config.enabled == false then return end
  import 'reload.lua'
end

local loader = reload.auto_multiple()

-- Fire off the native RoomLogic.lua/RoomManager.lua import event directly -- the exact same
-- condition SGG_Modding-ModUtil's once_loaded.game uses internally -- instead of going through
-- modutil.once_loaded.game itself. ModUtil dispatches EVERY mod's once_loaded.game callback from
-- one shared, unprotected `for` loop (see its main.lua trigger_loaded.game): one mod's uncaught
-- error aborts that loop and silently skips every mod registered after it. Confirmed in the wild
-- 2026-07-18: zerp-NPCRoomRandomizer's ready.lua indexes a Zagreus' Journey room
-- (A_Story01/X_Story01/Y_Story01) before Zagreus' Journey's own once_loaded.game callback has run
-- and created it, throws, and since zerp is a declared dependency (loads, and registers, before
-- us) our on_ready never fired -- zero bridge logs, ever, every boot. Registering our own
-- rom.on_import.post listener is an independent native registration (ReLoad's own triggers.lua
-- does the same thing for its post_import trigger), so another mod's callback throwing inside
-- ModUtil's shared list can no longer take us down with it, regardless of load order.
rom.on_import.post(function(name)
  if name == 'RoomLogic.lua' or name == 'RoomManager.lua' then
    loader.load("early", on_ready, on_reload)
  end
end)
