-- Harness for ItemManager's vow ranks: minimum_fear, removals, and the bounded Oath.
--
-- Runs the mod's own vow code (lifted out of ItemManager.lua) against the installed game's
-- MetaUpgradeData ranks and vanilla's ShrineLogic.lua (GetTotalSpentShrinePoints,
-- GetShrineUpgradeMaxRank, ShrineScreenRankUp/RankDown). The Oath wraps in reload.lua are
-- mirrored here by rank_up / rank_down.
--
-- Usage: lua vow_floor_harness.lua <ItemManager.lua>

local SCRIPTS = [[C:\Program Files (x86)\Steam\steamapps\common\Hades II\Content\Scripts\]]
local MOD_FILE = assert(arg[1], "pass the path to ItemManager.lua")

local STUB
STUB = setmetatable({}, {
  __index = function() return STUB end,
  __call = function() return STUB end,
  __concat = function() return "" end,
  __newindex = function() end,
  __len = function() return 0 end,
  __add = function() return 0 end, __sub = function() return 0 end,
  __mul = function() return 0 end, __div = function() return 0 end,
  __unm = function() return 0 end,
})
local NILS = { CurrentRun = true }
setmetatable(_G, { __index = function(_, k)
  if NILS[k] then return nil end
  return STUB
end })

local function copy_keys(dst, src) for k, v in pairs(src) do dst[k] = v end return dst end
OverwriteTableKeys, AddTableKeysCheckDupes, AddTableKeys = copy_keys, copy_keys, copy_keys
function Import() end

local function load_file(name)
  local f = assert(io.open(SCRIPTS .. name, "rb"))
  local src = f:read("a"); f:close()
  src = src:gsub("^\239\187\191", "")
  assert(load(src, "@" .. name))()
end

MetaUpgradeData = {}
load_file("MetaUpgradeData.lua")
for name, data in pairs(MetaUpgradeData) do data.Name = name end  -- the game stamps these at load
load_file("ShrineLogic.lua")
-- vanilla pieces the screen functions call that this harness doesn't model
function IsGameStateEligible() return true end
function ProcessSimpleExtractValues() end
function ShrineScreenUpdateSkellyText() end
function ShrineScreenRankDownPresentation() end
function ShrineScreenRankUpPresentation() end
function ShrineScreenAlreadyAtMaxPresentation() end
local refused = 0
function ShrineScreenAlreadyAtMinPresentation() refused = refused + 1 end

-- ---- the mod's code ---------------------------------------------------------------------
local f = assert(io.open(MOD_FILE, "rb"))
local mod_src = f:read("a"); f:close()
local function lift(from, to)
  local a = assert(mod_src:find(from, 1, true), from .. " not found")
  local b = assert(mod_src:find(to, a, true), to .. " not found")
  return mod_src:sub(a, b - 1)
end
local snippet = lift("local VOW_NAME_TO_ID = {", "-- Aspect item (display title)")
  .. lift("-- Vow ranks. Each vow has", "-- Open the Surface route by adding")
  .. "\nreturn apply_vow_removal, VOW_NAME_TO_ID\n"

game = _G
rom = { log = { info = function() end, warning = function() end } }
local state, live
APState = { get = function() return state end }
ItemManager = {
  settings = {},
  have_settings = function() return next(ItemManager.settings) ~= nil end,
  have_live_settings = function() return live end,
  setting_on = function(k) return ItemManager.settings[k] == "1" end,
}
local remove_vow, VOWS = assert(load(snippet, "=mod"))()

-- ---- helpers ----------------------------------------------------------------------------
local failures, checks = 0, 0
local function check(cond, label)
  checks = checks + 1
  if not cond then failures = failures + 1; print("  FAIL: " .. label) end
end

local function fresh(settings, opts)
  opts = opts or {}
  ItemManager.settings = { seed = "x" }
  for k, v in pairs(settings) do ItemManager.settings[k] = tostring(v) end
  live = opts.live ~= false
  state = { vow_removals = {}, vow_choice = {} }
  GameState = { ShrineUpgrades = opts.leftovers or {}, SpentShrinePointsCache = 0 }
  CurrentRun = nil
  ItemManager.apply_all_vows(true)
end
local function rank(vow) return GameState.ShrineUpgrades[VOWS[vow]] or 0 end
local function fear() return GetTotalSpentShrinePoints() end
local function screen_for(vow) return { SelectedItem = { Data = MetaUpgradeData[VOWS[vow]] } } end

-- reload.lua's ShrineScreenRankUp / ShrineScreenRankDown wraps
local function rank_up(vow)
  local screen = screen_for(vow)
  ShrineScreenRankUp(screen)
  ItemManager.record_vow_choice(screen.SelectedItem.Data.Name)
end
local function rank_down(vow)
  local screen = screen_for(vow)
  local name = screen.SelectedItem.Data.Name
  if not ItemManager.vow_can_rank_down(name) then
    ShrineScreenAlreadyAtMinPresentation(screen, screen.SelectedItem)
    return false
  end
  ShrineScreenRankDown(screen)
  ItemManager.record_vow_choice(name)
  return true
end
-- what every run start / room start does
local function reassert() ItemManager.apply_all_vows(true) end

local DEFAULTS = { reverse_vow = 1, vow_pain = 1, vow_grit = 1, vow_wards = 1, vow_frenzy = 1,
  vow_hordes = 1, vow_menace = 1, vow_return = 1, vow_fangs = 1, vow_scars = 1, vow_debt = 1,
  vow_shadow = 0, vow_forfeit = 0, vow_time = 1, vow_void = 2, vow_hubris = 1, vow_denial = 0,
  vow_rivals = 2 }
local function with(extra)
  local t = {}
  for k, v in pairs(DEFAULTS) do t[k] = v end
  for k, v in pairs(extra or {}) do t[k] = v end
  return t
end

-- ---- 1. no floor: today's behavior ------------------------------------------------------
fresh(with())
local start_fear = fear()
check(rank("Void") == 2 and rank("Rivals") == 2 and rank("Shadow") == 0, "starting ranks follow the YAML")
remove_vow("Time")
check(rank("Time") == 0, "removal lowers the vow with no floor")
remove_vow("Void")
check(rank("Void") == 1, "second-rank vow drops one rank per removal")
check(rank_down("Void") == false, "Oath can't go under the lowest allowed rank")
rank_up("Time"); reassert()
check(rank("Time") == 1, "a removed vow can be turned back on, and stays on")
check(rank_down("Time") and rank("Time") == 0, "and turned back off")
rank_up("Shadow"); reassert()
check(rank("Shadow") == 1, "a vow the YAML left at 0 can be raised")
rank_up("Pain"); rank_up("Pain"); rank_up("Pain"); reassert()
check(rank("Pain") == 3, "rank up goes to the game's max, past the YAML's level")
remove_vow("Pain"); reassert()
check(rank("Pain") == 3, "a removal doesn't touch a vow the player raised")
check(rank_down("Pain") and rank_down("Pain") and rank_down("Pain") and rank("Pain") == 0,
  "then it can come down to the new lowest rank")
check(rank_down("Pain") == false, "and no further")

-- ---- 2. reverse_vow off, no floor: everything is the player's ---------------------------
fresh({ reverse_vow = 0 }, { leftovers = { EnemyHealthShrineUpgrade = 3 } })
check(fear() == 0, "leftover vanilla ranks are cleared")
rank_up("Grit"); reassert()
check(rank("Grit") == 1, "free rank up with reverse_vow off")
check(rank_down("Grit") and fear() == 0, "free rank down with reverse_vow off")

-- ---- 3. floor with reverse_vow off ------------------------------------------------------
fresh({ reverse_vow = 0, minimum_fear = 10 })
check(fear() >= 10, "floor is filled on first apply (" .. fear() .. ")")
check(rank("Time") == 0 and rank("Void") == 0 and rank("Forfeit") == 0, "fill leaves the run-changing vows for last")
local before = fear()
reassert(); reassert()
check(fear() == before, "fill is stable across re-asserts")
-- trade: raise one, lower others, never under the floor
rank_up("Time"); rank_up("Time")
local lowered = 0
for vow in pairs(VOWS) do
  if vow ~= "Time" then while rank_down(vow) do lowered = lowered + 1 end end
end
check(lowered > 0, "other vows can be lowered after raising one")
check(fear() >= 10, "Oath never goes under the floor (" .. fear() .. ")")
reassert()
check(fear() >= 10 and rank("Time") == 2, "the player's trade survives a re-assert")

-- ---- 4. floor at the starting Fear: removals become trades ------------------------------
fresh(with({ minimum_fear = start_fear }))
check(fear() == start_fear, "floor == starting Fear changes nothing at the start")
remove_vow("Time")
check(rank("Time") == 1, "removal held by the floor")
check(rank_down("Time") == false, "can't just lower it at the Oath either")
rank_up("Grit")
check(rank_down("Time") and rank("Time") == 0, "after raising another vow it can be lowered")
check(fear() >= start_fear, "still at or above the floor")
reassert()
check(rank("Time") == 0 and rank("Grit") == 2, "trade survives a re-assert")

-- ---- 5. floor above the starting Fear ---------------------------------------------------
fresh(with({ minimum_fear = start_fear + 8 }))
check(fear() >= start_fear + 8, "floor above the start adds vows (" .. fear() .. ")")
for vow in pairs(VOWS) do
  check(rank(vow) >= math.max(0, (DEFAULTS["vow_" .. vow:lower()] or 0)), vow .. " not below its YAML level")
end

-- ---- 6. floor in between: removals lower until the floor, then hold ---------------------
fresh(with({ minimum_fear = start_fear - 2 }))
remove_vow("Grit")   -- 1 Fear
check(rank("Grit") == 0 and fear() == start_fear - 1, "first removal lands")
remove_vow("Frenzy") -- 3 Fear: would go under
check(rank("Frenzy") == 1 and fear() == start_fear - 1, "a removal that would cross the floor is held")
remove_vow("Wards")  -- 1 Fear: lands exactly on the floor
check(rank("Wards") == 0 and fear() == start_fear - 2, "a removal that lands on the floor is taken")

-- ---- 7. max floor, every removal: Fear never dips ---------------------------------------
fresh(with({ minimum_fear = 67 }))
check(fear() == 67, "floor 67 maxes every vow (" .. fear() .. ")")
for vow in pairs(VOWS) do
  for _ = 1, 4 do remove_vow(vow) end
  check(fear() == 67, "Fear holds at 67 through removals (" .. vow .. ")")
  check(rank_down(vow) == false, "nothing can be lowered at max floor (" .. vow .. ")")
end

-- ---- 8. boot-cache settings don't write picks into the save -----------------------------
fresh({ reverse_vow = 0, minimum_fear = 10 }, { live = false })
check(fear() >= 10, "floor still applies on cached settings")
check(next(state.vow_choice) == nil, "but nothing is saved until live settings arrive")
live = true; reassert()
check(next(state.vow_choice) ~= nil and fear() >= 10, "saved once live")

-- ---- 9. old seed (no minimum_fear key) --------------------------------------------------
fresh(with())
ItemManager.settings.minimum_fear = nil
for vow in pairs(VOWS) do for _ = 1, 4 do remove_vow(vow) end end
check(fear() == 0, "without the setting every vow can be removed")

print(string.format("%d checks, %d failures (starting Fear with default vows: %d)", checks, failures, start_fear))
os.exit(failures == 0 and 0 or 1)
