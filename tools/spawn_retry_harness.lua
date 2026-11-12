-- Harness for reload.lua's HandleNextSpawn wrap (the spawn-point softlock guards).
--
-- Cuts the real block out of reload.lua -- from `local function relax_missing_spawn_point` up to
-- the "Oath of the Unseen" comment that follows the wrap -- and runs it against a fake
-- HandleNextSpawn whose spawn succeeds only when the unit's RequiredSpawnPoint is satisfiable.
-- Checks:
--   * a map with NO points of the required type: relaxed up front (9/26), spawns first try
--   * a map with points of the type that are all unusable, nothing alive: the third try drops the
--     requirement and spawns (11/3, the 586 Turtle_Elite stall)
--   * the same with enemies still alive: left to vanilla's wait-for-a-kill (one call, no relax)
--   * a unit with no requirement that still can't spawn: two tries, no third, "may stall" logged
--   * an override the slot already carries ("nil") is not re-dropped
--
-- Usage: lua spawn_retry_harness.lua <path to reload.lua>

local path = assert(arg[1], "pass the path to reload.lua")
local f = assert(io.open(path, "rb"))
local src = f:read("a"); f:close()
local first = assert(src:find("local function relax_missing_spawn_point", 1, true), "relax function not found")
local last = assert(src:find("-- Oath of the Unseen", first, true), "end marker not found")
local block = src:sub(first, last - 1)

-- ---- fakes ---------------------------------------------------------------------------------
local logs = {}
rom = { log = { info = function(s) logs[#logs + 1] = s end, warning = function(s) logs[#logs + 1] = s end } }
local wrapped
modutil = { mod = { Path = { Wrap = function(name, fn) if name == "HandleNextSpawn" then wrapped = fn end end } } }

local world -- per case: points by type, usable flag, active count
game = {
  CurrentRun = { CurrentRoom = { Name = "TestRoom" } },
  EnemyData = {
    Turtle_Elite = { RequiredSpawnPoint = "EnemyPointMelee" },
    Guard = {},
    Guard2 = { RequiredSpawnPoint = "EnemyPointMelee" },
  },
  GetIdsByType = function(a) return world.points[a.Name] or {} end,
  GetActiveEnemyCount = function() return world.active end,
  GetNextSpawn = function() return nil end,
}

local calls
local function fake_base(encounter, ignore, spawnInfo)
  calls = calls + 1
  local data = game.EnemyData[spawnInfo.Name]
  local required = data.RequiredSpawnPoint
  if spawnInfo.SpawnOverrides and spawnInfo.SpawnOverrides.RequiredSpawnPoint ~= nil then
    required = spawnInfo.SpawnOverrides.RequiredSpawnPoint
  end
  if required == "nil" then required = nil end
  if required then
    if world.usable_required then return 1 end
    return nil
  end
  if world.any_usable then return 1 end
  return nil
end

local chunk = assert(load(block .. "\nreturn true", "@reload.lua (HandleNextSpawn block)"))
chunk()
assert(wrapped, "HandleNextSpawn wrap was not registered")

-- ---- cases ---------------------------------------------------------------------------------
local failures = 0
local function case(label, w, spawnInfo, wantResult, wantCalls, wantOverride, wantLog)
  world, calls, logs = w, 0, {}
  local result = wrapped(fake_base, { Name = "GeneratedTest" }, false, spawnInfo, nil, nil)
  local override = spawnInfo.SpawnOverrides and spawnInfo.SpawnOverrides.RequiredSpawnPoint
  local joined = table.concat(logs, "\n")
  local notes = {}
  if result ~= wantResult then notes[#notes + 1] = "result " .. tostring(result) .. ", want " .. tostring(wantResult) end
  if calls ~= wantCalls then notes[#notes + 1] = "calls " .. calls .. ", want " .. wantCalls end
  if override ~= wantOverride then notes[#notes + 1] = "override " .. tostring(override) .. ", want " .. tostring(wantOverride) end
  if wantLog and not joined:find(wantLog, 1, true) then notes[#notes + 1] = "missing log '" .. wantLog .. "'" end
  if #notes > 0 then failures = failures + 1 end
  print(string.format("%-4s %-62s %s", #notes == 0 and "ok" or "FAIL", label, table.concat(notes, "; ")))
end

case("no points of the type at all: relaxed up front",
  { points = {}, usable_required = false, any_usable = true, active = 0 },
  { Name = "Turtle_Elite" }, 1, 1, "nil", "requirement dropped")
case("type present but unusable, nothing alive: third try spawns",
  { points = { EnemyPointMelee = { 7 } }, usable_required = false, any_usable = true, active = 0 },
  { Name = "Turtle_Elite" }, 1, 3, "nil", "dropping its EnemyPointMelee requirement")
case("type present but unusable, enemies alive: vanilla waits",
  { points = { EnemyPointMelee = { 7 } }, usable_required = false, any_usable = true, active = 3 },
  { Name = "Turtle_Elite" }, nil, 1, nil, nil)
case("type present and usable: first try, untouched",
  { points = { EnemyPointMelee = { 7 } }, usable_required = true, any_usable = true, active = 0 },
  { Name = "Guard2" }, 1, 1, nil, nil)
case("no requirement, nothing usable: two tries, then may stall",
  { points = {}, usable_required = false, any_usable = false, active = 0 },
  { Name = "Guard" }, nil, 2, nil, "encounter may stall")
case("slot already overridden to \"nil\": not dropped again",
  { points = { EnemyPointMelee = { 7 } }, usable_required = false, any_usable = false, active = 0 },
  { Name = "Turtle_Elite", SpawnOverrides = { RequiredSpawnPoint = "nil" } }, nil, 2, "nil", "encounter may stall")
case("third try also fails: may stall, requirement stays dropped",
  { points = { EnemyPointMelee = { 7 } }, usable_required = false, any_usable = false, active = 0 },
  { Name = "Turtle_Elite" }, nil, 3, "nil", "encounter may stall")

print(failures == 0 and "\nOK" or ("\nFAILED: " .. failures .. " case(s)"))
os.exit(failures == 0 and 0 or 1)
