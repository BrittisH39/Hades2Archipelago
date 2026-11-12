-- Harness for ItemManager's apply_gather_spot_veteran_gates and apply_plentiful_forage_unlock.
--
-- Property under test, for every gather-spot requirement table in the installed game's data:
--   the STRIPPED table evaluated on a FRESH save
--     ==  the ORIGINAL table evaluated on a LONG-PLAYED save
-- under vanilla's own IsGameStateEligible (RequirementsLogic.lua), across both outcomes of every
-- ChanceToPlay roll and a spread of within-run situations (depth, what the previous rooms held).
--
-- Plentiful Forage (TraitData_Demeter.lua's PlantHealthBoon): on a fresh save the boon must be
-- refused before the unlock and offered after it, and still be refused in a Dream run, in a
-- bounty, and in a room that blocks gift boons.
--
-- Usage: lua gather_gate_harness.lua <ItemManager.lua> [Zagreus' Journey plugins/Scripts folder]

local SCRIPTS = [[C:\Program Files (x86)\Steam\steamapps\common\Hades II\Content\Scripts\]]
local MOD_FILE = assert(arg[1], "pass the path to ItemManager.lua")

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
local strict = false
-- the per-room counters are read off _G first (nil in the real game) before SumPrevRooms replaces them
local NILS = { SessionMapState = true, verboseLogging = true, NumHarvestPoints = true, NumShovelPoints = true,
  NumPickaxePoints = true, NumExorcismPoints = true, NumFishingPoints = true }
setmetatable(_G, { __index = function(_, k)
  if NILS[k] then return nil end
  if strict then error("undefined global '" .. tostring(k) .. "'", 2) end
  return STUB
end })

RoomSetData, RoomData, NamedRequirementsData, TraitData = {}, {}, {}, {}
local function copy_keys(dst, src) for k, v in pairs(src) do dst[k] = v end return dst end
OverwriteTableKeys, AddTableKeysCheckDupes, AddTableKeys = copy_keys, copy_keys, copy_keys
function Import() end

local function load_file(name)
  local f = assert(io.open(SCRIPTS .. name, "rb"))
  local src = f:read("a"); f:close()
  src = src:gsub("^\239\187\191", "")
  local chunk, err = load(src, "@" .. name)
  assert(chunk, err)
  chunk()
end

local data_files = {
  "HarvestData.lua", "RoomData.lua",
  "RoomDataF.lua", "RoomDataG.lua", "RoomDataH.lua", "RoomDataI.lua",
  "RoomDataN.lua", "RoomDataO.lua", "RoomDataP.lua", "RoomDataQ.lua", "RoomDataChaos.lua",
  "TraitData_Demeter.lua",
}
for _, name in ipairs(data_files) do
  local ok, err = pcall(load_file, name)
  if not ok then print("  (skipped " .. name .. ": " .. tostring(err) .. ")") end
end

-- Optional: Zagreus' Journey's room data (arg[2] = its plugins/Scripts folder). Each file builds
-- local tables and hands them to mod.ApplyModificationsAndInheritRoomData; capture those.
local ZJ_DIR = arg[2]
if ZJ_DIR then
  mod = setmetatable({
    ApplyModificationsAndInheritRoomData = function(_, modifications, replacements, name)
      RoomSetData["ZJ_" .. tostring(name)] = replacements
      RoomSetData["ZJ_" .. tostring(name) .. "_modifications"] = modifications
    end,
  }, { __index = function() return STUB end })
  for _, name in ipairs({ "RoomDataTartarus.lua", "RoomDataAsphodel.lua", "RoomDataElysium.lua",
      "RoomDataStyx.lua", "RoomDataSurface.lua" }) do
    local ok, err = pcall(function()
      local f = assert(io.open(ZJ_DIR .. "/" .. name, "rb"))
      local src = f:read("a"); f:close()
      src = src:gsub("^\239\187\191", "")
      assert(load(src, "@ZJ/" .. name))()
    end)
    if not ok then print("  (skipped ZJ " .. name .. ": " .. tostring(err) .. ")") end
  end
end

-- Anything the data files read from a global this harness doesn't model came back as STUB (which
-- indexes to itself forever). Drop those values so only real data is left.
local function scrub(t, seen)
  if seen[t] then return end
  seen[t] = true
  for k, v in pairs(t) do
    if v == STUB then t[k] = nil
    elseif type(v) == "table" then scrub(v, seen) end
  end
end
local scrubbed = {}
scrub(RoomSetData, scrubbed)
scrub(RoomData, scrubbed)
scrub(TraitData, scrubbed)

-- ---- vanilla evaluator, strict globals from here on -------------------------------------
function IsEmpty(t) return t == nil or next(t) == nil end
function TableLength(t) local n = 0 if t then for _ in pairs(t) do n = n + 1 end end return n end
function Contains(t, v) if t then for _, x in pairs(t) do if x == v then return true end end end return false end
function ContainsAny(t, vs) for _, v in pairs(vs) do if Contains(t, v) then return true end end return false end
function DebugAssert() end
function DebugPrint() end
local chance_passes = true
function RandomChance() return chance_passes end
strict = true
load_file("RequirementsLogic.lua")

-- ---- the mod's code, lifted straight out of ItemManager.lua -----------------------------
local f = assert(io.open(MOD_FILE, "rb"))
local mod_src = f:read("a"); f:close()
local a = assert(mod_src:find("local GATHER_SPOT_KINDS = {", 1, true), "GATHER_SPOT_KINDS not found")
local b = assert(mod_src:find("-- Artemis/Heracles/Icarus/Nemesis/Athena", a, true), "end marker not found")
local snippet = mod_src:sub(a, b - 1) .. "\nreturn apply_gather_spot_veteran_gates, GATHER_SPOT_KINDS, apply_plentiful_forage_unlock\n"
game = _G
local log_lines = {}
rom = { log = { info = function(s) log_lines[#log_lines + 1] = s end } }
local apply, KINDS, apply_forage = assert(load(snippet, "=mod"))()

-- ---- collect every target table, with a pristine copy -----------------------------------
local function deep_copy(t, seen)
  if type(t) ~= "table" then return t end
  seen = seen or {}
  if seen[t] then return seen[t] end
  local c = {}
  seen[t] = c
  for k, v in pairs(t) do c[k] = deep_copy(v, seen) end
  return c
end
local targets, order = {}, {}
local function note(tbl, label)
  if type(tbl) ~= "table" then return end
  if not targets[tbl] then
    targets[tbl] = { original = deep_copy(tbl), labels = {} }
    order[#order + 1] = tbl
  end
  local labels = targets[tbl].labels
  if #labels < 3 then labels[#labels + 1] = label end
end
local function note_rooms(rooms, prefix)
  local names = {}
  for name in pairs(rooms) do names[#names + 1] = name end
  table.sort(names, function(x, y) return tostring(x) < tostring(y) end)
  for _, name in ipairs(names) do
    local room = rooms[name]
    if type(room) == "table" then
      for _, kind in ipairs(KINDS) do note(rawget(room, kind.key), prefix .. tostring(name) .. "." .. kind.key) end
    end
  end
end
local zones = {}
for zone in pairs(RoomSetData) do zones[#zones + 1] = zone end
table.sort(zones)
for _, zone in ipairs(zones) do note_rooms(RoomSetData[zone], zone .. "/") end
note_rooms(RoomData, "RoomData/")
for _, kind in ipairs(KINDS) do
  local data = rawget(_G, kind.data)
  note(data and data.DefaultGameStateRequirements, kind.data .. ".DefaultGameStateRequirements")
end

-- ---- save files ----------------------------------------------------------------------------
local function always(value) return setmetatable({}, { __index = function() return value end }) end
local function veteran_save()
  return {
    CompletedRunsCache = 250, ModsNikkelMHadesBiomesCompletedRunsCache = 250,
    LifetimeResourcesGained = always(100000),
    ExorcisedNames = always(50),
    WorldUpgradesAdded = always(true), WorldUpgrades = always(true),
    TextLinesRecord = always(true), WeaponsUnlocked = always(true),
    RunHistory = {},
  }
end
local function fresh_save()
  return {
    CompletedRunsCache = 0,
    LifetimeResourcesGained = {}, ExorcisedNames = {},
    WorldUpgradesAdded = {}, WorldUpgrades = {},
    TextLinesRecord = {}, WeaponsUnlocked = {},
    RunHistory = {},
  }
end

-- within-run situations: biome depth x which spot kinds the previous rooms held
local COUNTS = { "NumHarvestPoints", "NumShovelPoints", "NumPickaxePoints", "NumExorcismPoints", "NumFishingPoints" }
local function blank_room(extra)
  local room = { Name = "Test" }
  for _, k in ipairs(COUNTS) do room[k] = 0 end
  for k, v in pairs(extra or {}) do room[k] = v end
  return room
end
local situations = {}
for _, depth in ipairs({ 1, 2, 6 }) do
  situations[#situations + 1] = { label = "depth " .. depth .. ", no history", depth = depth, history = {} }
  for _, k in ipairs(COUNTS) do
    for _, roomsAgo in ipairs({ 1, 2, 3, 5, 9, 14 }) do
      local history = {}
      for i = 1, 16 do history[i] = blank_room() end
      history[#history - (roomsAgo - 1)] = blank_room({ [k] = 1 })
      situations[#situations + 1] = {
        label = "depth " .. depth .. ", " .. k .. " " .. roomsAgo .. " room(s) ago",
        depth = depth, history = history,
      }
    end
  end
end

local function evaluate(reqs, save, situation)
  GameState = save
  CurrentRun = {
    CurrentRoom = blank_room(), RoomHistory = situation.history,
    BiomeDepthCache = situation.depth, ResourcesGained = {},
  }
  return IsGameStateEligible({ Name = "Test", RoomSetName = "F" }, reqs, { RoomSetName = "F" })
end

-- ---- run -----------------------------------------------------------------------------------
apply(RoomSetData)
print(log_lines[1] or "(no log line)")

local function has_save_condition(reqs)
  for _, cond in ipairs(reqs) do
    if type(cond) == "table" then
      local path = cond.Path or cond.PathTrue or cond.PathFalse
      if type(path) == "table" and path[1] == "GameState" then return true end
    end
  end
  if type(reqs.OrRequirements) == "table" then
    for _, branch in ipairs(reqs.OrRequirements) do
      if type(branch) == "table" and has_save_condition(branch) then return true end
    end
  end
  return false
end

local checks, mismatches, leftovers, empty_or = 0, 0, 0, 0
local mismatch_tables = {}
local fresh_before, fresh_after = 0, 0
for _, tbl in ipairs(order) do
  local info = targets[tbl]
  if has_save_condition(tbl) then
    leftovers = leftovers + 1
    print("  LEFTOVER save-file condition in " .. info.labels[1])
  end
  if type(tbl.OrRequirements) == "table" and #tbl.OrRequirements == 0 then
    empty_or = empty_or + 1
    print("  EMPTY OrRequirements in " .. info.labels[1])
  end
  for _, passes in ipairs({ true, false }) do
    chance_passes = passes
    for _, situation in ipairs(situations) do
      local want = evaluate(info.original, veteran_save(), situation)
      local got = evaluate(tbl, fresh_save(), situation)
      checks = checks + 1
      if want ~= got then
        mismatches = mismatches + 1
        mismatch_tables[info.labels[1]] = (mismatch_tables[info.labels[1]] or 0) + 1
        if mismatches <= 3 then
          print(("  MISMATCH %s [%s, chance %s]: veteran+original=%s fresh+stripped=%s"):format(
            info.labels[1], situation.label, tostring(passes), tostring(want), tostring(got)))
        end
      end
      if passes and situation.label == "depth 6, no history" then
        if evaluate(info.original, fresh_save(), situation) then fresh_before = fresh_before + 1 end
        if got then fresh_after = fresh_after + 1 end
      end
    end
  end
end

-- idempotence: a second pass must change nothing
local snapshot = {}
for _, tbl in ipairs(order) do snapshot[tbl] = deep_copy(tbl) end
local function same(x, y)
  if type(x) ~= type(y) then return false end
  if type(x) ~= "table" then return x == y end
  for k, v in pairs(x) do if not same(v, y[k]) then return false end end
  for k in pairs(y) do if x[k] == nil then return false end end
  return true
end
apply(RoomSetData)
local changed = 0
for _, tbl in ipairs(order) do if not same(tbl, snapshot[tbl]) then changed = changed + 1 end end

for label, n in pairs(mismatch_tables) do print(("  mismatching table: %s (%d comparisons)"):format(label, n)) end
print(("%d requirement tables, %d situations each x2 chance outcomes = %d comparisons"):format(#order, #situations, checks))
print(("mismatches: %d   leftover save-file conditions: %d   emptied OrRequirements: %d   changed by 2nd pass: %d"):format(
  mismatches, leftovers, empty_or, changed))
print(("tables a FRESH save can pass (best case: deep in a biome, clean history, chance rolls pass): %d before -> %d after, of %d"):format(
  fresh_before, fresh_after, #order))

-- ---- Plentiful Forage --------------------------------------------------------------------
local forage_ok = true
local function forage_check(label, want, got)
  if want ~= got then
    forage_ok = false
    print(("  FORAGE %s: wanted %s, got %s"):format(label, tostring(want), tostring(got)))
  end
end
local boon = rawget(TraitData, "PlantHealthBoon")
if not apply_forage then
  forage_ok = false
  print("  FORAGE: this ItemManager.lua has no apply_plentiful_forage_unlock")
elseif type(boon) ~= "table" or type(boon.GameStateRequirements) ~= "table" then
  forage_ok = false
  print("  FORAGE: PlantHealthBoon.GameStateRequirements not found in TraitData_Demeter.lua")
else
  local reqs = boon.GameStateRequirements
  local function offered(save, run)
    GameState = save
    CurrentRun = { CurrentRoom = blank_room(run.room), RoomHistory = {}, BiomeDepthCache = 3,
      ActiveBounty = run.bounty, IsDreamRun = run.dream }
    return IsGameStateEligible(boon, reqs, {})
  end
  local plain = {}
  local clauses_before = #reqs
  forage_check("vanilla, fresh save", false, offered(fresh_save(), plain))
  forage_check("vanilla, long-played save", true, offered(veteran_save(), plain))
  apply_forage()
  forage_check("clauses removed", 1, clauses_before - #reqs)
  forage_check("unlocked, fresh save", true, offered(fresh_save(), plain))
  forage_check("unlocked, long-played save", true, offered(veteran_save(), plain))
  forage_check("unlocked, Dream run", false, offered(fresh_save(), { dream = true }))
  forage_check("unlocked, bounty", false, offered(fresh_save(), { bounty = "PackageBountyChaos" }))
  forage_check("unlocked, room blocks gift boons", false, offered(fresh_save(), { room = { BlockGiftBoons = true } }))
  apply_forage()
  forage_check("second pass changes nothing", clauses_before - 1, #reqs)
end
print("Plentiful Forage unlock: " .. (forage_ok and "ok (9 checks)" or "FAILED"))

os.exit((mismatches == 0 and leftovers == 0 and empty_or == 0 and changed == 0 and forage_ok) and 0 or 1)
