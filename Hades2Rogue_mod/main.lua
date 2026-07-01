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

modutil.once_loaded.game(function()
  loader.load("early", on_ready, on_reload)
end)
