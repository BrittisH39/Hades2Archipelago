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

-- Error logging for the whole mod. rom.log.error() RAISES in this environment (it writes the line
-- and then throws), so never call it directly: an error log inside a pcall just aborts that pcall.
-- This writes a warning-level line tagged "ERROR" instead and never throws.
function AP_log_error(msg)
  pcall(function()
    rom.log.warning("[AP] ERROR " .. (tostring(msg):gsub("^%[AP%] ", "")))
  end)
end

-- pcall for the hook bodies: same return values, but the first failure under each label is
-- logged instead of vanishing. Only the first, because many of these run every room or every
-- few frames and would otherwise flood LogOutput.log with the same line.
AP_try_failed = AP_try_failed or {}
function AP_try(label, fn)
  local ok, err = pcall(fn)
  if not ok and not AP_try_failed[label] then
    AP_try_failed[label] = true
    AP_log_error(tostring(label) .. " failed (further failures not logged): " .. tostring(err))
  end
  return ok, err
end
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
-- The ROOT fix for that specific crash is load order. From July 18 through
-- August 8 that meant one thing: NikkelM-Zagreus_Journey listed as our own
-- HARD dependency in manifest.json, ahead of the zerp entries. Confirmed via
-- ReturnOfModdingBase source (src/lua/lua_manager.hpp, `load_all_modules`)
-- that the native loader genuinely topologically sorts plugin load order from
-- each manifest's `dependencies` array (DFS post-order: a mod's declared
-- dependencies are visited, and load, before the mod itself) -- this isn't a
-- guess, it's read directly from the loader's own C++. Listing ZJ there made
-- it (and its whole zannc/NikkelM chain) load and register ahead of zerp, so
-- zerp never reached the crash site at all.
--
-- 2026-07-19 and 2026-07-21: twice tried to make ZJ NOT a hard dependency
-- (concern: force-downloading a large mod -- needs its own separate Hades 1
-- install -- for every player via r2modman/Thunderstore, which reads this same
-- `dependencies` field to auto-install). Both times reverted after live
-- breakage: the loader's manifest struct at the time (src/thunderstore/v1/
-- manifest.hpp) had no separate soft/optional-dependency field, so it was
-- force-all-or-force-nothing, and a same-evening attempt to preseed stub room
-- data instead of fixing load order found three independently-shaped crashes
-- across the two zerp mods with no sign of converging (see
-- project_zerp_zj_roomdata_preseed_fix memory). Settled on hard dependency as
-- the only fix that covered the whole class instead of one assumption at a time.
--
-- 2026-08-09: Hell2Modding shipped a genuine soft/optional-dependency field,
-- `rom_soft_deps` (ReturnOfModdingBase commit ab269ac, landed 2026-08-08,
-- "Add rom_soft_deps field"). Confirmed by reading the loader source directly
-- (lua_manager.hpp/.cpp at that commit, not docs -- there barely are any):
-- `rom_soft_deps` entries get parsed the same way as `dependencies` and merged
-- into the SAME dependency_selector used by the topological sort (so an
-- installed soft dep still gets pulled ahead of us in load order), but
-- Thunderstore/r2modman's own installer only ever reads `dependencies` for
-- auto-install -- `rom_soft_deps` is invisible to it. NikkelM-Zagreus_Journey-
-- 1.1.3 moved from `dependencies` to `rom_soft_deps` accordingly; players who
-- don't want the Nightmare route no longer get ZJ force-installed, but if it
-- IS installed, load order still puts it ahead of us.
--
-- CAVEAT (verify against a live boot before trusting this fully): the merge is
-- `all_deps = dependencies ++ rom_soft_deps` -- a mod's hard deps are ALWAYS
-- walked, and fully resolved, before its soft deps, as a flat group, no matter
-- how you interleave them in the JSON. So this change alone does NOT force ZJ
-- ahead of the two zerp entries (still hard deps of ours) via OUR manifest --
-- if anything, it reopens that specific race. zerp (their author) has said
-- they're independently adding NikkelM-Zagreus_Journey as a `rom_soft_deps`
-- entry on zerp-NPCRoomRandomizer/zerp-Extended_NPC_Encounters themselves,
-- which would enforce the correct order from THEIR manifest instead of ours --
-- the textbook-correct place for it, since it's their mods reading ZJ's data.
-- Until that ships (and players are on the updated zerp version), the July-18
-- race can still occur in principle. Check the "[AP] HEALTH:" lines in
-- LogOutput.log after a real boot (below, and in reload.lua) to confirm which
-- world we're actually in.
--
-- This shim stays as the safety net for the whole CLASS of failure (any mod's
-- once_loaded.game throwing, not just this one) -- wrap the dispatch so a
-- throwing callback gets logged and the dispatch re-run, letting mods queued
-- after the failure still initialize. SGG_Modding-ReLoad de-duplicates on_ready
-- per mod (handle_load marks the sig loaded BEFORE calling on_ready), so a re-run
-- never double-fires any mod's on_ready; on_reload steps re-run, which is their
-- documented contract (same as any hot-reload). With a healthy queue the pcall
-- succeeds first try and behavior is byte-identical to stock ModUtil; if the
-- zerp-before-ZJ race above does recur, this is what contains it to just
-- zerp-NPCRoomRandomizer's own story-swap feature sitting out that session
-- instead of cascading.
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
          AP_log_error('a mod errored inside once_loaded.game dispatch (attempt '
            .. attempt .. '/3): ' .. tostring(err2))
          if attempt < 3 then
            pcall(function()
              rom.log.warning('[AP] re-running once_loaded.game dispatch so mods queued after the failure still initialize')
            end)
          end
        end
        AP_log_error('once_loaded.game dispatch still failing after 3 attempts -- some mods may not have initialized')
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

-- ---- Mid-session reload of just this plugin ---------------------------------
-- Hell2Modding watches each plugin folder and reloads a plugin whose files change while the game
-- runs (e.g. a deploy mid-run). That re-runs this file in a fresh environment and drops every
-- rom.gui / rom.inputs callback the previous instance registered -- the per-frame driver (bridge
-- polling: incoming items, DeathLink), the overlay, its F8 key and its Insert-menu entry. The
-- game's Lua isn't re-imported, so the on_import.post listener below never fires and nothing
-- re-registers. Confirmed 2026-09-26: EnemySanity.lua deployed mid-run -> overlay gone, F8 and
-- the menu entry dead, only outbound checks still working (they send inline from the previous
-- instance's game hooks). A fresh init can't fix it: ReLoad already marked us loaded (so
-- ready.lua and every module import would be skipped), and the previous instance's game hooks
-- are still installed, so wrapping again would run every hook twice.
-- Instead re-attach thin forwarders to the running instance, which reload.lua publishes as a
-- game global. It's only reused when it was loaded under this same ModUtil instance: a full Lua
-- reset reloads ModUtil too, so a leftover handle can never hijack a normal load. Code changes in
-- the changed files still need a game restart to take effect.
AP_LIVE_KEY = '__' .. _PLUGIN.guid .. '_live'
local live
pcall(function()
  local l = rom.game[AP_LIVE_KEY]
  if type(l) == 'table' and l.modutil == modutil then live = l end
end)

if live then
  rom.gui.add_always_draw_imgui(function()
    if live.frame then live.frame() end
  end)
  if live.menu_bar and rom.gui.add_to_menu_bar then
    rom.gui.add_to_menu_bar(function() live.menu_bar() end)
  end
  if live.toggle_overlay and rom.inputs and rom.inputs.on_key_pressed then
    local key = (config and config.overlay_toggle_key) or 'F8'
    local ok, err = pcall(function()
      return rom.inputs.on_key_pressed{ key, Name = 'Archipelago: Toggle Overlay', function()
        live.toggle_overlay()
      end }
    end)
    if not ok then AP_log_error('[AP] overlay toggle key re-registration failed: ' .. tostring(err)) end
  end
  rom.log.warning('[AP] plugin files changed mid-session: re-attached to the running instance '
    .. '(frame driver, overlay, F8, menu entry). Restart the game to load the changed code.')
  return
end

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
