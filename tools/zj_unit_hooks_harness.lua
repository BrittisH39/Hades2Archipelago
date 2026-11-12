-- Harness for EnemySanity's "Zagreus' Journey's own enemy hooks, off its own route" layer.
--
-- Loads that section of EnemySanity.lua standalone, then loads the INSTALLED Zagreus' Journey
-- scripts with a stub environment that only captures their modutil wraps, and calls those wraps
-- directly. Properties under test:
--   * on an ordinary run, ZJ's per-unit hooks (kill, cleanup, trap, chariot AI) fire for a unit
--     carrying ModsNikkelMHadesBiomesIsModdedEnemy and for nothing else;
--   * its run-level hooks (CreateRoom, StartRoom, OnAllEnemiesDead) and the excluded SetupUnit
--     block stay off;
--   * a real ZJ run behaves exactly as before;
--   * the metatable comes off for the save and moves with the run.
-- Rerun after a Zagreus' Journey update: the per-unit lines are found by scanning its scripts.
--
-- Usage: lua zj_unit_hooks_harness.lua <EnemySanity.lua> <NikkelM-Zagreus_Journey plugin folder>
--   (pass the plugin folder with forward slashes)
local modSrc = assert(arg[1], "pass the path to EnemySanity.lua")
local zjRoot = assert(arg[2], "pass the Zagreus' Journey plugin folder")
local FLAG = "ModsNikkelMHadesBiomesIsModdedRun"

-- 1. pull the new section out of EnemySanity.lua and run it standalone
local text = assert(io.open(modSrc, "r")):read("a")
local section = assert(text:match("(local ZJ_RUN_FLAG = .-)\n%-%- Sound%. ZJ loads"), "section not found")
local zjInstalled = true
local env = setmetatable({
  EnemySanity = {},
  rom = { log = { info = function(m) print("     log: " .. m) end, warning = function(m) print("     WARN: " .. m) end } },
  Routes = { NIGHTMARE_MOD_NAME = "NikkelM-Zagreus_Journey" },
  ItemManager = { nightmare_mod = function() return zjInstalled and {} or nil end },
}, { __index = _G })
assert(load(section, "=EnemySanity section", "t", env))()
local ES = env.EnemySanity

-- 2. load real ZJ scripts with a stub environment that just captures the wraps
local function permissive()
  return setmetatable({}, {
    __index = function(t, k) local v = permissive(); rawset(t, k, v); return v end,
    __call = function() return nil end,
  })
end

local calls = {}
local function note(name) return function(...) calls[#calls + 1] = name; return nil end end

local run = {}
local game = permissive()
game.CurrentRun = run
game.CurrentHubRoom = nil
rawset(game, "CurrentHubRoom", false)
game.thread = function(fn, ...) calls[#calls + 1] = "thread" end
game.SetThreadWait = note("SetThreadWait")
game.Kill = note("Kill")
game.RandomChance = function() calls[#calls + 1] = "RandomChance"; return true end
game.IsEmpty = function(t) return t == nil or next(t) == nil end
game.ContainsAny = function() return false end
game.GetNumShrineUpgrades = function() return 0 end
game.IsBossDifficultyShrineUpgradeActive = function() return false end
game.MapState = {}
game.RoomData = { ModsNikkelMHadesBiomesBaseRoom = { ShrinePointDoorSpawnChance = 1.0 } }

local wraps = {}   -- file -> name -> { wrapper, ... }
local currentFile
local modutil = { mod = { Path = {
  Wrap = function(name, fn)
    wraps[currentFile][name] = wraps[currentFile][name] or {}
    table.insert(wraps[currentFile][name], fn)
  end,
  Context = { Wrap = { Static = function(name, fn) fn() end } },
}, Locals = { Stacked = function() return {} end } } }

local function zjmod()
  local m = permissive()
  m.EnemyBelongsToBiome = {}
  m.ModdedUnitMaxHealthMultiplierBonus = { Default = 0.38 }
  m.ModdedUnitHealthBufferMultiplierBonus = { Default = 0.13 }
  return m
end

local function loadZJ(rel)
  currentFile = rel
  wraps[rel] = {}
  local zenv = setmetatable({
    game = game, mod = zjmod(), modutil = modutil, rom = permissive(),
    config = { accessibility = { z_GoddessMode = false } },
    _PLUGIN = { guid = "NikkelM-Zagreus_Journey" },
    SetAnimation = note("SetAnimation"), StopAnimation = note("StopAnimation"),
    SpawnObstacle = note("SpawnObstacle"), CreateAnimation = note("CreateAnimation"),
    GetAngle = function() return 0 end, Destroy = note("Destroy"), GetIds = function() return {} end,
    RemoveOutline = note("RemoveOutline"), ClearEffect = note("ClearEffect"),
    GetIdsByType = function() return {} end, SetColor = note("SetColor"),
    AddEffectBlock = note("AddEffectBlock"), RemoveEffectBlock = note("RemoveEffectBlock"),
    EndRamWeapons = note("EndRamWeapons"), LoadPackages = note("LoadPackages"),
    GetLocation = function() return {} end,
  }, { __index = _G })
  local chunk = assert(loadfile(zjRoot .. "/" .. rel, "t", zenv))
  chunk()
end

for _, rel in ipairs({
  "Scripts/CombatLogic.lua", "Scripts/CombatPresentation.lua", "Scripts/RoomLogic.lua",
  "Scripts/RunLogic.lua", "Scripts/EffectPresentation.lua", "Scripts/EncounterLogic.lua",
  "Scripts/FunctionMappings/Chariot.lua", "Scripts/EnemyAILogic.lua",
}) do
  local ok, err = pcall(loadZJ, rel)
  if not ok then print("LOAD FAIL " .. rel .. ": " .. tostring(err)) end
end

local pass, fail = 0, 0
local function check(label, cond)
  if cond then pass = pass + 1 else fail = fail + 1 end
  print((cond and "ok   " or "FAIL ") .. label)
end
local function called(name)
  for _, c in ipairs(calls) do if c == name then return true end end
  return false
end
local function reset() calls = {} end
local nobase = function() end

local h1 = function(extra)
  local u = { ObjectId = 5, ModsNikkelMHadesBiomesIsModdedEnemy = true }
  for k, v in pairs(extra or {}) do u[k] = v end
  return u
end
local h2 = function(extra)
  local u = { ObjectId = 6 }
  for k, v in pairs(extra or {}) do u[k] = v end
  return u
end

local KillPresentation = wraps["Scripts/CombatPresentation.lua"].KillPresentation[1]
local KillEnemy = wraps["Scripts/CombatLogic.lua"].KillEnemy[1]
local CleanupEnemy = wraps["Scripts/CombatLogic.lua"].CleanupEnemy[1]
local DisableTrap = wraps["Scripts/RoomLogic.lua"].DisableTrap[1]
local SetupUnit = wraps["Scripts/RoomLogic.lua"].SetupUnit[1]
local StartRoom = wraps["Scripts/RoomLogic.lua"].StartRoom[1]
local CreateRoom = wraps["Scripts/RunLogic.lua"].CreateRoom[1]
local OnAllEnemiesDead = wraps["Scripts/EncounterLogic.lua"].OnAllEnemiesDead[1]
local RamAILoop = wraps["Scripts/FunctionMappings/Chariot.lua"].RamAILoop[1]

print("--- before attach (today's behaviour): nothing of ZJ's runs off its route")
reset(); KillPresentation(nobase, h1(), {}, {})
check("KillPresentation ignores an H1 enemy", not called("thread"))

print("--- attached, ordinary (non-ZJ) run")
ES.zj_unit_hooks_attach(run)
check("flag still reads nil from this file", run[FLAG] == nil)
check("flag is not a real field", rawget(run, FLAG) == nil)

reset(); KillPresentation(nobase, h1(), {}, {})
check("KillPresentation: H1 enemy gets tether cleanup", called("thread"))
reset(); KillPresentation(nobase, h1({ DeathAnimation = "X", ManualDeathAnimation = true }), {}, {})
check("KillPresentation: H1 enemy gets its death animation", called("CreateAnimation"))
reset(); KillPresentation(nobase, h2({ DeathAnimation = "X", ManualDeathAnimation = true }), {}, {})
check("KillPresentation: H2 enemy untouched", not called("thread") and not called("CreateAnimation"))

reset(); KillEnemy(nobase, h1({ EndThreadWaitsOnDeath = "t" }), {})
check("KillEnemy: H1 enemy block runs", called("SetThreadWait"))
reset(); KillEnemy(nobase, h2({ EndThreadWaitsOnDeath = "t" }), {})
check("KillEnemy: H2 enemy untouched", not called("SetThreadWait"))

reset(); CleanupEnemy(nobase, h1({ DisplayAttackTimer = true, AttackTimerId = 9 }))
check("CleanupEnemy: H1 enemy block runs", called("Destroy"))

reset(); local baseHit = false
DisableTrap(function() baseHit = true end, h1({ DestroyOnTrapDisable = true }))
check("DisableTrap: H1 trap takes ZJ's path", called("Kill") and not baseHit)
reset(); baseHit = false
DisableTrap(function() baseHit = true end, h2({ DestroyOnTrapDisable = true }))
check("DisableTrap: H2 trap takes vanilla path", baseHit and not called("Kill"))

reset(); local ramBase = false
pcall(RamAILoop, function() ramBase = true end, h1(), {})
check("RamAILoop: H1 chariot does not fall through to vanilla", not ramBase)
reset(); ramBase = false
RamAILoop(function() ramBase = true end, h2(), {})
check("RamAILoop: H2 enemy uses vanilla", ramBase)

print("--- run-level and excluded hooks must stay off")
local u = h1({ HealthMultiplier = 0.4 })
run.CurrentRoom = { RoomSetName = "N" }
SetupUnit(nobase, u, run, {})
check("SetupUnit: no ZJ health bonus (0.4 stays 0.4)", u.HealthMultiplier == 0.4)
check("SetupUnit: LastInvisibilityTime not set", u.LastInvisibilityTime == nil)

reset(); local room = CreateRoom(function() return {} end, {}, {})
check("CreateRoom: no shrine-door roll", room.ShrinePointDoorChanceSuccess == nil and not called("RandomChance"))
reset(); run.WingDepth = nil
StartRoom(nobase, run, { Name = "N_Combat01" })
check("StartRoom: no wing-depth bookkeeping", run.WingDepth == nil)
reset(); OnAllEnemiesDead(nobase, {}, { Name = "x" })
check("OnAllEnemiesDead: no MedeaPoison clear", not called("ClearEffect"))

print("--- a real ZJ run is unchanged")
run[FLAG] = true
reset(); room = CreateRoom(function() return {} end, {}, {})
check("CreateRoom rolls the shrine door", room.ShrinePointDoorChanceSuccess == true)
u = h1({ HealthMultiplier = 1 }); SetupUnit(nobase, u, run, {})
check("SetupUnit applies ZJ's health bonus", u.HealthMultiplier > 1)

print("--- Dream: ZJ biome -> vanilla biome writes false")
run[FLAG] = false
ES.zj_unit_hooks_attach(run)
check("explicit false is dropped", rawget(run, FLAG) == nil)
reset(); KillPresentation(nobase, h1(), {}, {})
check("H1 enemy handled again", called("thread"))

print("--- save and run turnover")
ES.zj_unit_hooks_detach()
check("detached for the save", getmetatable(run) == nil)
ES.zj_unit_hooks_attach(run)
check("re-attached", getmetatable(run) ~= nil)
local nextRun = {}
ES.zj_unit_hooks_attach(nextRun)
check("previous run released", getmetatable(run) == nil and getmetatable(nextRun) ~= nil)
local foreign = setmetatable({}, {})
ES.zj_unit_hooks_attach(foreign)
check("someone else's metatable left alone", getmetatable(nextRun) ~= nil and next(getmetatable(foreign)) == nil)

print("--- ZJ not installed")
zjInstalled = false
local bare = {}
ES.zj_unit_hooks_attach(bare)
check("no metatable without ZJ", getmetatable(bare) == nil)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
