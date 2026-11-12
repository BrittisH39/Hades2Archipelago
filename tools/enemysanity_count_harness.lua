-- Harness for EnemySanity.rebalance_spawn_count (the enemy shuffle's wave resizing).
--
-- Loads the installed game's enemy data and the mod's real EnemySanity.lua, then replays
-- substitutions taken from a live log (ReturnOfModding\LogOutput.log, 2026-10-04) through it.
-- Checks, for each case:
--   * the zone health factor equals the multiplier scale_unit logged for that enemy in that zone
--   * the wave's total "rating x health" stays close to what the generator budgeted
--   * no slot grows past Vow of Hordes' top rank (1.6x) of the generator's count (11/3; was 4x)
--   * a Bone Dracon ("Dracon") slot never grows at all
--   * mark_substituted drops a replacement's RequiredSpawnPoint unless the original shared it
--
-- 11/3 cases come from the 0.10.0 player logs in Player Reports 2026-11-03/attachments (415
-- quarth, 537 RyoTsushigawa).
--
-- Usage: lua enemysanity_count_harness.lua <path to Hades2Rogue_mod>

local SCRIPTS = [[C:\Program Files (x86)\Steam\steamapps\common\Hades II\Content\Scripts\]]
local MOD_DIR = assert(arg[1], "pass the path to Hades2Rogue_mod")

-- ---- permissive globals while the data files load ---------------------------------------
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
local permissive = true
setmetatable(_G, { __index = function(_, k)
  if permissive then return STUB end
  return nil
end })

EnemyData, UnitSetData, WeaponSetData, WeaponData, WeaponDataEnemies = {}, {}, {}, {}, {}
ConstantsData = {}
local function copy_keys(dst, src)
  if type(dst) == "table" and type(src) == "table" and dst ~= STUB then
    for k, v in pairs(src) do dst[k] = v end
  end
  return dst
end
OverwriteTableKeys, AddTableKeysCheckDupes, AddTableKeys = copy_keys, copy_keys, copy_keys
function Import() end

local function load_file(path, name)
  local f = assert(io.open(path, "rb"))
  local src = f:read("a"); f:close()
  src = src:gsub("^\239\187\191", "")
  local chunk, err = load(src, "@" .. name)
  assert(chunk, err)
  chunk()
end

local listing = io.popen('dir /b "' .. SCRIPTS .. 'EnemyData*.lua"')
local files = {}
for line in listing:lines() do files[#files + 1] = line end
listing:close()
table.sort(files) -- EnemyData.lua (the base archetypes) sorts first
for _, name in ipairs(files) do
  local ok, err = pcall(load_file, SCRIPTS .. name, name)
  if not ok then print("  (skipped " .. name .. ": " .. tostring(err) .. ")") end
end

-- ---- the game's data inheritance (RunData.lua ProcessDataInheritance), child wins ----------
local function deep_copy(t)
  if type(t) ~= "table" or t == STUB then return t end
  local out = {}
  for k, v in pairs(t) do out[k] = deep_copy(v) end
  return out
end
local function inherit(data, parent)
  for k, pv in pairs(parent) do
    local v = data[k]
    if v == nil then
      data[k] = deep_copy(pv)
    elseif type(v) == "table" and type(pv) == "table" and v ~= STUB and pv ~= STUB and k ~= "InheritFrom" then
      inherit(v, pv)
    end
  end
end
local done = {}
local function process(name)
  local data = EnemyData[name]
  if type(data) ~= "table" or done[name] then return end
  done[name] = true
  if type(data.InheritFrom) == "table" then
    for _, parentName in ipairs(data.InheritFrom) do
      process(parentName)
      if type(EnemyData[parentName]) == "table" then inherit(data, EnemyData[parentName]) end
    end
  end
end
for name in pairs(EnemyData) do process(name) end
permissive = false

-- ---- what EnemySanity.lua needs from the rest of the mod -----------------------------------
local route, zone = "Underworld", 1
game = { CurrentRun = { CurrentRoom = {} } }
rom = { log = { info = function() end, warning = function() end } }
ItemManager = { settings = {}, setting_mode = function() return 3 end, setting_on = function() return false end,
  nightmare_mod = function() return nil end }
LocationManager = { UNIT_TO_ENEMY_CHECK = {}, CHECK_TO_UNIT_ID = {}, ENEMY_CHECKS_BY_ROUTE = {},
  enemy_check_for_unit = function() return nil end }
Routes = { ROOMSET = {}, current = function() return route, zone end, for_room = function() return route, zone end }
CalculateEnemyDifficultyRating = nil -- fall through to the raw GeneratorData rating, as at room build

load_file(MOD_DIR .. "\\EnemySanity.lua", "EnemySanity.lua")

-- ---- cases, from the live log ------------------------------------------------------------
-- { original, count, replacement, route, zone, health multiplier scale_unit logged (or nil) }
local CASES = {
  { "SwarmerClockwork", 19, "Guard", "Underworld", 4, 6.000 },
  { "SwarmerClockwork", 13, "Guard", "Underworld", 4, 6.000 },
  { "SwarmerClockwork_Elite", 13, "Guard_Elite", "Underworld", 4, 6.000 },
  { "FishmanMelee", 2, "Guard2", "Underworld", 2, 1.000 },
  { "FishmanMelee_Elite", 3, "Guard2_Elite", "Underworld", 2, 1.000 },
  { "Guard2", 7, "Mourner", "Underworld", 2, 0.560 },
  { "Radiator", 4, "FishmanRanged", "Underworld", 1, 0.560 },
  { "CorruptedShadeSmall", 43, "BrokenHearted", "Underworld", 3, 1.000 },
  { "BrokenHearted", 30, "FishmanMelee", "Underworld", 3, 1.833 },
  { "Mourner", 10, "GoldElemental", "Underworld", 3, 0.600 },
  { "Lamia", 15, "SatyrLancer", "Underworld", 3, 0.600 },
  { "GoldElemental", 19, "Screamer2", "Underworld", 4, 1.833 },
  { "SatyrLancer", 4, "TimeElemental", "Underworld", 4, 1.000 },
  { "Lycanthrope", 6, "DespairElemental", "Underworld", 3, 1.000 },
  { "Radiator2", 20, "Radiator", "Dream", 3, nil },
  { "FishmanMelee", 5, "Guard2", "Dream", 3, nil },
  { "Guard2", 21, "Mourner", "Dream", 3, nil },
  { "SwarmerClockwork_Elite", 2, "Guard_Elite", "Dream", 1, nil },
  { "SatyrLancer", 2, "TimeElemental", "Dream", 1, nil },
  -- 11/3, from 0.10.0 logs (counts there predate the 10/4 health weighting)
  { "BrokenHearted", 9, "Guard", "Underworld", 3, nil },       -- 415: x68 in 0.10.0
  { "SatyrRatCatcher", 9, "Guard", "Underworld", 4, 6.000 },   -- 537: x198 in 0.10.0
  { "SatyrRatCatcher", 2, "Guard", "Underworld", 4, 6.000 },   -- 537: x44
  { "ClockworkHeavyMelee", 6, "Zombie", "Underworld", 4, nil }, -- 537: x125
  { "ZombieSpawner", 1, "Zombie", "Surface", 1, nil },         -- 415: x7
}
local GROWTH = 1.6

local failures = 0
local function rating(id) return EnemyData[id].GeneratorData.DifficultyRating end
local function dream_health(id, z)
  local d = EnemyData[id].DreamBiomeData
  local tier = d and d[z]
  return tier and tier.DataOverrides and tier.DataOverrides.HealthMultiplier or 1
end

print(string.format("%-46s %-13s %6s %6s %8s %8s", "substitution", "zone", "before", "after", "factor", "budget"))
for _, c in ipairs(CASES) do
  local orig, count, repl, logged = c[1], c[2], c[3], c[6]
  route, zone = c[4], c[5]
  game.CurrentRun.IsDreamRun = (route == "Dream")
  assert(EnemyData[orig] and EnemyData[repl], "missing enemy data for " .. orig .. " / " .. repl)

  local before = math.max(1, math.floor(count * rating(orig) / rating(repl) + 0.5))
  local spawn = { Generated = true, TotalCount = count, Name = orig }
  EnemySanity.rebalance_spawn_count(spawn, orig, repl, {})
  local after = spawn.TotalCount

  -- the factor the function used, recovered from the same data scale_unit reads
  local factor
  if route == "Dream" then
    factor = dream_health(repl, zone) / dream_health(orig, zone)
  else
    local letters = { Underworld = { "F", "G", "H", "I" }, Surface = { "N", "O", "P", "Q" } }
    factor = dream_health(repl, zone) / dream_health("Base" .. letters[route][zone] .. "Enemy", zone)
  end
  local budget = (after * rating(repl) * factor) / (count * rating(orig))

  local notes = {}
  if logged and math.abs(factor - logged) > 0.002 then notes[#notes + 1] = "factor differs from the log's x" .. logged end
  local ceiling = math.max(count, math.floor(count * GROWTH + 0.5))
  if after > ceiling then notes[#notes + 1] = "grew past " .. GROWTH .. "x" end
  local expected = math.max(1, math.floor(count * rating(orig) / (rating(repl) * factor) + 0.5))
  if expected > ceiling then expected = ceiling end
  if after ~= expected then notes[#notes + 1] = "expected " .. expected end
  if #notes > 0 then failures = failures + 1 end

  print(string.format("%-46s %-13s %6d %6d %8.3f %7.0f%% %s",
    orig .. " x" .. count .. " -> " .. repl, route .. " " .. zone, before, after, factor, budget * 100,
    table.concat(notes, "; ")))
end

-- ---- one-for-one units (11/3): the Bone Dracon never outgrows its slot ---------------------
-- Its data is Zagreus' Journey's, which this harness doesn't load, so check the ceiling itself.
local real_check = LocationManager.enemy_check_for_unit
LocationManager.enemy_check_for_unit = function(id)
  if id == "RangedBurrower" or id == "RangedBurrowerElite" then return "Dracon" end
  return nil
end
print("\none-for-one ceiling")
for _, c in ipairs({ { "RangedBurrower", 5, 5 }, { "RangedBurrowerElite", 1, 1 }, { "Guard", 5, 8 },
                     { "Guard", 1, 2 }, { "Guard", 9, 14 } }) do
  local got = EnemySanity.max_spawn_count(c[2], c[1])
  local ok = got == c[3]
  if not ok then failures = failures + 1 end
  print(string.format("  %-20s x%-3d -> at most %-3d %s", c[1], c[2], got, ok and "" or ("expected " .. c[3])))
end
LocationManager.enemy_check_for_unit = real_check

-- ---- spawn-point requirement on substitutes (11/3) ----------------------------------------
-- { original, replacement, authored override on the slot, RequiredSpawnPoint expected after }
print("\nsubstitute spawn points")
local POINT_CASES = {
  { "Brawler_Elite", "Turtle_Elite", nil, "nil" },        -- 586's stall, with an H2 original
  { "Mage", "Guard2", nil, "nil" },                       -- the 9/26 Erebus softlock pair
  { "FishmanMelee", "Guard2", nil, nil },                 -- both Oceanus: requirement kept
  { "Brawler", "Guard", nil, nil },                       -- replacement has none: untouched
  { "Mage", "Guard2", "EnemyPoint", "EnemyPoint" },       -- authored override left alone
}
for _, c in ipairs(POINT_CASES) do
  local orig, repl, authored, want = c[1], c[2], c[3], c[4]
  assert(EnemyData[orig] and EnemyData[repl], "missing enemy data for " .. orig .. " / " .. repl)
  local spawn = { Name = repl, SpawnOverrides = authored and { RequiredSpawnPoint = authored } or nil }
  EnemySanity.mark_substituted(spawn, orig)
  local got = spawn.SpawnOverrides.RequiredSpawnPoint
  local ok = got == want
  if not ok then failures = failures + 1 end
  print(string.format("  %-14s -> %-13s requires %-17s override %-11s %s", orig, repl,
    tostring(EnemyData[repl].RequiredSpawnPoint), got == nil and "(none)" or ('"' .. got .. '"'),
    ok and "" or ("expected " .. tostring(want))))
end

-- 11/6: a Hades II substitute off its home biome gets that biome's sound bank, once per room,
-- and never the room's own biome. biome_package_for_unit is stubbed here: its own data path
-- (ENEMY_HOME_TIER + route rosters) is the art preload's and already in use live.
print("\nhome-biome sound bank")
do
  local loads = {}
  local saved = { rom.audio, rom.paths, rom.path, EnemySanity.biome_package_for_unit, game }
  rom.audio = { load_bank = function(p) loads[#loads + 1] = p end }
  rom.paths = { Content = function() return [[C:\Game\Content]] end }
  rom.path = { combine = function(a, b) return a .. "\\" .. b end }
  EnemySanity.biome_package_for_unit = function(id)
    return ({ Guard_Elite = "BiomeF", SatyrRatCatcher = "BiomeH" })[id]
  end
  local function case(label, ok)
    if not ok then failures = failures + 1 end
    print(string.format("  %-58s %s", label, ok and "ok" or "FAIL"))
  end
  local roomI = { RoomSetName = "I" }
  game = { CurrentRun = { CurrentRoom = roomI } }
  EnemySanity.load_h2_enemy_audio("Guard_Elite")
  case("Guard_Elite in a Tartarus room loads BiomeF", loads[1] == [[C:\Game\Content\Audio\Desktop\BiomeF.bank]])
  EnemySanity.load_h2_enemy_audio("Guard_Elite")
  case("a second Guard_Elite in the same room loads nothing more", #loads == 1)
  EnemySanity.load_h2_enemy_audio("NoSuchUnit")
  case("a unit with no home biome loads nothing", #loads == 1)
  game.CurrentRun.CurrentRoom = { RoomSetName = "F" }
  EnemySanity.load_h2_enemy_audio("Guard_Elite")
  case("Guard_Elite in an Erebus room: the room's own bank, skipped", #loads == 1)
  game.CurrentRun.CurrentRoom = { RoomSetName = "Tartarus" }
  EnemySanity.load_h2_enemy_audio("SatyrRatCatcher")
  EnemySanity.load_h2_enemy_audio("Guard_Elite")
  case("a new room (Hades I Tartarus) loads each substitute's bank again", #loads == 3)
  rom.audio = nil
  game.CurrentRun.CurrentRoom = { RoomSetName = "O" }
  case("no rom.audio: no error", pcall(EnemySanity.load_h2_enemy_audio, "Guard_Elite"))
  rom.audio, rom.paths, rom.path, EnemySanity.biome_package_for_unit, game =
    saved[1], saved[2], saved[3], saved[4], saved[5]
end

print(failures == 0 and "\nOK" or ("\nFAILED: " .. failures .. " case(s)"))
os.exit(failures == 0 and 0 or 1)
