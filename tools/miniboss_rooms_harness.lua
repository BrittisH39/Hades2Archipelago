-- Harness for the miniboss ROOM shuffle (MinibossRooms.lua + its reload.lua wraps), 0.11.0.
--
-- Drives the game's OWN code -- ChooseNextRoomData / IsRoomEligible / IsRoomForced /
-- UpdateRunHistoryCache / GetBiomeDepth / CloseDoorForRun / IsDoorClosedForRun from RunLogic.lua,
-- DoUnlockRoomExits / AssignRoomToExitDoor / AttemptUseDoor / SetupDefaultDoor from RoomLogic.lua,
-- all lifted verbatim, and IsGameStateEligible from RequirementsLogic.lua -- over the real miniboss
-- rooms' and N_Hub's RoomData, with the mod's MinibossRooms.lua loaded as-is and reload.lua's
-- ChooseNextRoomData wrap and bookkeeping block lifted out of the file and run through a stand-in
-- modutil. Ordinary rooms are synthetic always-eligible combat rooms; presentation and reward
-- calls are stubs. Every run takes the miniboss door whenever one is offered, the worst case for
-- chaining.
--
-- Four builds are compared on the same seeds:
--   0.10.0   the swap alone (what players ran: no bookkeeping, no vetting, no Ephyra plumbing)
--   pre      the tree with the vetting backstop switched off
--   vet      the tree with the bookkeeping switched off: the vetting backstop alone
--   now      the current tree
-- Properties under test for `now`: never two miniboss rooms in a row, no arena served twice in a
-- run, and every slot -- Ephyra's included -- serves its mapped (foreign) arena, in seed runs and
-- Dream Dives. 0.10.0 must reproduce the reported chains and the unswapped Ephyra slot, or the
-- harness is not modelling the bugs.
--
-- Then both Ephyra directions, step by step through the vanilla door code:
--   hosted  a foreign arena behind the square's miniboss door: built through the square's
--           PredeterminedDoorRooms, booked to the host slot, counted as a pylon once, its exits
--           hide their previews and lead back to N_Hub, coming out of the slot's own doorway; the
--           square swaps the same arena again on a return visit.
--   guest   an Ephyra arena in another biome's slot, after the native one closed its exit (a
--           Dive): its exit is still offered, shows the next room's reward, leads forward rather
--           than to the square, leaves no square doorway behind, spawns no pylon and closes
--           nothing. The same sequence on 0.10.0 must reproduce the reported softlock.
-- And the Dream map: a biome derangement of all twenty rooms.
--
-- What it cannot show: anything on screen. Where the hero and camera actually end up, the pylon
-- objective text, door animations -- those need the game.
--
-- Usage: lua miniboss_rooms_harness.lua <Hades2Rogue_mod folder> [runs]

local SCRIPTS = [[C:\Program Files (x86)\Steam\steamapps\common\Hades II\Content\Scripts\]]
local MOD_DIR = assert(arg[1], "pass the path to the Hades2Rogue_mod folder")
local RUNS = tonumber(arg[2] or "400")

local function read(path)
  local f = assert(io.open(path, "rb"))
  local src = f:read("a"); f:close()
  return (src:gsub("^\239\187\191", ""))
end

-- ---- permissive globals while the data files load ---------------------------------------
local STUB
STUB = setmetatable({}, {
  __index = function() return STUB end, __call = function() return STUB end,
  __concat = function() return "" end, __newindex = function() end, __len = function() return 0 end,
  __add = function() return 0 end, __sub = function() return 0 end,
  __mul = function() return 0 end, __div = function() return 0 end, __unm = function() return 0 end,
})
local loading = true
setmetatable(_G, { __index = function() if loading then return STUB end return nil end })

RoomData, RoomSetData, NamedRequirementsData = {}, {}, {}
local function copy_keys(dst, src) for k, v in pairs(src) do dst[k] = v end return dst end
OverwriteTableKeys, AddTableKeysCheckDupes, AddTableKeys = copy_keys, copy_keys, copy_keys
function Import() end
for _, name in ipairs({ "RoomData.lua", "RoomDataF.lua", "RoomDataG.lua", "RoomDataH.lua", "RoomDataI.lua",
    "RoomDataN.lua", "RoomDataO.lua", "RoomDataP.lua", "RoomDataQ.lua" }) do
  local ok, err = pcall(function() assert(load(read(SCRIPTS .. name), "@" .. name))() end)
  if not ok then print("  (skipped " .. name .. ": " .. tostring(err) .. ")") end
end
for _, set in pairs(RoomSetData) do
  if type(set) == "table" then for name, data in pairs(set) do
    if type(data) == "table" and RoomData[name] == nil then data.Name = data.Name or name; RoomData[name] = data end
  end end
end
local function scrub(t, seen)
  if seen[t] then return end
  seen[t] = true
  for k, v in pairs(t) do
    if v == STUB then t[k] = nil elseif type(v) == "table" then scrub(v, seen) end
  end
end
scrub(RoomData, {})
-- InheritFrom, resolved the way the game's data processing does for the fields read here: a
-- room takes each parent's value for any key it doesn't set itself (I_MiniBoss02 gets its
-- MaxCreationsThisRun and ForceAtBiomeDepth* from I_MiniBoss01 this way).
local resolved = {}
local function inherit(name)
  local data = RoomData[name]
  if type(data) ~= "table" or resolved[name] then return data end
  resolved[name] = true
  for _, parentName in ipairs(data.InheritFrom or {}) do
    local parent = inherit(parentName)
    if type(parent) == "table" then
      for k, v in pairs(parent) do
        if data[k] == nil and k ~= "DebugOnly" and k ~= "Name" then data[k] = v end
      end
    end
  end
  return data
end
for name in pairs(RoomData) do inherit(name) end
-- The game stamps Name (and inherits RoomSetName) while processing RoomData; the raw files don't.
for name, data in pairs(RoomData) do
  if type(data) == "table" then
    data.Name = data.Name or name
    data.RoomSetName = data.RoomSetName or name:match("^(%u)_")
  end
end
loading = false

-- ---- engine/utility stand-ins -----------------------------------------------------------
function IsEmpty(t) return t == nil or next(t) == nil end
function TableLength(t) local n = 0 if t then for _ in pairs(t) do n = n + 1 end end return n end
function Contains(t, v) if t then for _, x in pairs(t) do if x == v then return true end end end return false end
function ContainsAll(t, vs) for _, v in pairs(vs) do if not Contains(t, v) then return false end end return true end
function ContainsAny(t, vs) for _, v in pairs(vs) do if Contains(t, v) then return true end end return false end
function DebugAssert() end
function DebugPrint() end
function RandomChance(p) return math.random() < (p or 0) end
function GetRandomValue(t) local keys = {} for _, v in pairs(t or {}) do keys[#keys + 1] = v end
  if #keys == 0 then return nil end return keys[math.random(#keys)] end
function CollapseTableOrdered(t) local out = {} for _, v in pairs(t or {}) do out[#out + 1] = v end return out end
function DeepCopyTable(t, seen)
  if type(t) ~= "table" then return t end
  seen = seen or {}
  if seen[t] then return seen[t] end
  local c = {} seen[t] = c
  for k, v in pairs(t) do c[DeepCopyTable(k, seen)] = DeepCopyTable(v, seen) end
  return c
end
function HasEncounterBeenCompleted() return true end
function HasSeenRoomInNumRuns() return true end
function GetPreviousRoom(run) return run.RoomHistory[#run.RoomHistory] end
-- Requirement-side FunctionName checks (story and presentation gates) pass: the harness only
-- models the counters the miniboss rooms are gated on.
function CallFunctionName() return true end
assert(load(read(SCRIPTS .. "RequirementsLogic.lua"), "@RequirementsLogic.lua"))()

-- Vanilla functions lifted verbatim out of their files.
local function lift(file, names)
  local src = read(SCRIPTS .. file)
  for _, name in ipairs(names) do
    local a = assert(src:find("\nfunction " .. name .. "%("), name .. " not found in " .. file)
    local b = src:find("\nfunction ", a + 1) or #src
    assert(load(src:sub(a, b), "@" .. file .. ":" .. name))()
  end
end

-- Engine, presentation and reward calls the lifted door code makes, reduced to nothing (or to the
-- one value the door logic reads).
function ShallowCopyTable(t) local c = {} for k, v in pairs(t or {}) do c[k] = v end return c end
function GetConfigOptionValue() return false end
function RandomSynchronize() end
function ChooseNextRewardStore() return "RunProgress" end
function ChooseRoomReward() return "Boon" end
function SetupRoomReward() end
function wait() end
function thread() end
function HasHeroTraitValue() return false end
function AddToGroup() end
function RefreshUseButton() end
function StartTriggers() end
function RunThreadedEvents() end
function SetAnimation() end
function PlaySound() end
function SetPlayerInvulnerable() end
function SetPlayerVulnerable() end
function AddTimerBlock() end
function RemoveTimerBlock() end
function CheckRoomExitsReady() return true end
RewardStoreData = { InvalidOverrides = {} }
EncounterData = {}
-- CreateDoorRewardPreview's own first test (RewardPresentation.lua:7), recorded instead of drawn.
local PREVIEWS = {}
function CreateDoorRewardPreview(exitDoor)
  PREVIEWS[exitDoor.ObjectId] = not (exitDoor.HideRewardPreview or exitDoor.Room.HideRewardPreview)
end

-- CreateRoom, StartRoom and LeaveRoom reduced to the parts this reads: the counters
-- (RunLogic.lua 592/744, RoomLogic.lua 1086), and LeaveRoom's doorway hand-off and door closing
-- (RoomLogic.lua 4177-4178, 4223-4225). SpawnSoulPylon / HandlePylonObjective just count calls.
local PYLON_SPAWNS, PYLON_OBJECTIVES = 0, 0
local function install_vanilla()
  lift("RunLogic.lua", { "ChooseNextRoomData", "IsRoomForced", "IsRoomEligible", "UpdateRunHistoryCache",
    "GetRunDepth", "GetBiomeDepth", "CloseDoorForRun", "IsDoorClosedForRun" })
  lift("RoomLogic.lua", { "DoUnlockRoomExits", "AssignRoomToExitDoor", "AttemptUseDoor",
    "CheckSpecialDoorRequirement", "SetupDefaultDoor" })
  function CreateRoom(roomData, args)
    local room = DeepCopyTable(roomData)
    room.RoomCreations = {}
    room.ExitDoorRooms = {}
    room.TimesVisited = 0
    room.Encounter = room.Encounter or { Name = "Harness" }
    CurrentRun.RoomCreations[room.Name] = (CurrentRun.RoomCreations[room.Name] or 0) + 1
    if CurrentRun.CurrentRoom ~= nil then
      CurrentRun.CurrentRoom.RoomCreations[room.Name] = (CurrentRun.CurrentRoom.RoomCreations[room.Name] or 0) + 1
    end
    return room
  end
  function StartRoom(run, room)
    run.RoomsEntered[room.Name] = (run.RoomsEntered[room.Name] or 0) + 1
  end
  function LeaveRoom(currentRun, door)
    CurrentRun.NextHeroStartPoint = CurrentRun.CurrentRoom.NextHeroStartPoint or CurrentRun.NextHeroStartPoint
    CurrentRun.NextHeroEndPoint = CurrentRun.CurrentRoom.NextHeroEndPoint or CurrentRun.NextHeroEndPoint
    if currentRun.CurrentRoom.CloseDoorsOnUse then
      CloseDoorForRun( currentRun, door )
    end
  end
  function SpawnSoulPylon() PYLON_SPAWNS = PYLON_SPAWNS + 1 end
  function HandlePylonObjective() PYLON_OBJECTIVES = PYLON_OBJECTIVES + 1 end
end

-- ---- the mod --------------------------------------------------------------------------------
game = _G
local logs = {}
rom = { log = { info = function(s) logs[#logs + 1] = s end, warning = function(s) logs[#logs + 1] = "WARN " .. s end } }
ItemManager = { settings = {}, setting_on = function() return true end }
EnemySanity = { locations_on = function() return true end }
LocationManager = { miniboss_check_pending = function() return true end }
Routes = { current_room_set = function() return CurrentRun and CurrentRun.CurrentRoom and CurrentRun.CurrentRoom.RoomSetName end }
function AP_log_error(s) logs[#logs + 1] = "ERR " .. s end

local reload_src = read(MOD_DIR .. "/reload.lua")
local function block(startPat, endPat)
  local a = assert(reload_src:find(startPat, 1, true), "start not found: " .. startPat)
  local b = assert(reload_src:find(endPat, a, true), "end not found: " .. endPat)
  return reload_src:sub(a, b - 1)
end
local CNRD_BLOCK = block('pcall(function()\n  modutil.mod.Path.Wrap("ChooseNextRoomData"',
  "-- Miniboss ROOM shuffle bookkeeping")
local BOOK_BLOCK = block("-- Miniboss ROOM shuffle bookkeeping", "-- Combat Helper Sanity")
local PRELUDE = [[
local HELPER_ROOM_SWAP_ORIGIN = nil
local function fixup_cross_zone_story_swap() end
local function zagreus_contract_return() return nil, nil end
local function fallback_next_room() return nil, "harness has no fallback" end
]]

local function install_mod(build)
  install_vanilla()
  modutil = { mod = { Path = { Wrap = function(name, fn)
    local base = _G[name] or function() end
    _G[name] = function(...) return fn(base, ...) end
  end } } }
  MinibossRooms = nil
  assert(load(read(MOD_DIR .. "/MinibossRooms.lua"), "@MinibossRooms.lua"))()
  if build == "0.10.0" or build == "pre" then
    MinibossRooms.vet_choice = function() return nil end
    MinibossRooms.note_served = function() end
  elseif build == "vet" then
    MinibossRooms.count_host = function() end
    MinibossRooms.uncount_dest = function() end
  end
  assert(load(PRELUDE .. CNRD_BLOCK, "@reload.lua:ChooseNextRoomData"))()
  if build ~= "0.10.0" then assert(load(BOOK_BLOCK, "@reload.lua:bookkeeping"))() end
end

-- ---- run model ------------------------------------------------------------------------------
local BIOMES = { "F", "G", "H", "I", "N", "O", "P", "Q" }
local MB = {}
for name, letter in pairs({ F_MiniBoss01 = "F", F_MiniBoss02 = "F", F_MiniBoss03 = "F",
    G_MiniBoss01 = "G", G_MiniBoss02 = "G", G_MiniBoss03 = "G", H_MiniBoss01 = "H", H_MiniBoss02 = "H",
    I_MiniBoss01 = "I", I_MiniBoss02 = "I", N_MiniBoss01 = "N", N_MiniBoss02 = "N",
    O_MiniBoss01 = "O", O_MiniBoss02 = "O", P_MiniBoss01 = "P", P_MiniBoss02 = "P",
    Q_MiniBoss02 = "Q", Q_MiniBoss03 = "Q", Q_MiniBoss04 = "Q", Q_MiniBoss05 = "Q" }) do
  MB[letter] = MB[letter] or {}
  table.insert(MB[letter], name)
  assert(RoomData[name], "RoomData missing " .. name)
end
assert(RoomData.N_Hub and RoomData.N_Hub.PredeterminedDoorRooms, "RoomData missing N_Hub's PredeterminedDoorRooms")
local HUB_MB_DOOR = {}
for doorId, roomName in pairs(RoomData.N_Hub.PredeterminedDoorRooms) do
  if MB.N and Contains(MB.N, roomName) then HUB_MB_DOOR[roomName] = doorId end
end
assert(HUB_MB_DOOR.N_MiniBoss01 and HUB_MB_DOOR.N_MiniBoss02, "N_Hub has no door for an Ephyra miniboss room")
local HUB_COMBAT_DOORS = {}
for doorId, roomName in pairs(RoomData.N_Hub.PredeterminedDoorRooms) do
  if roomName:find("^N_Combat") then HUB_COMBAT_DOORS[#HUB_COMBAT_DOORS + 1] = doorId end
end
table.sort(HUB_COMBAT_DOORS)

-- Synthetic ordinary rooms (named apart from the real ones, which keep their data). Ephyra's set
-- is only ever asked for the throwaway rooms its return doors are given.
RoomSets = {}
for _, letter in ipairs(BIOMES) do
  table.sort(MB[letter])
  RoomSets[letter] = {}
  for i = 1, 14 do
    local name = string.format("%s_HarnessCombat%02d", letter, i)
    RoomData[name] = { Name = name, RoomSetName = letter }
    table.insert(RoomSets[letter], name)
  end
  for _, name in ipairs(MB[letter]) do table.insert(RoomSets[letter], name) end
end
local BIOME_LEN = 11

-- Seed-style map: a biome derangement of all twenty rooms (Locations.compute_miniboss_room_map).
local function seed_map_string()
  local rooms = {}
  for _, letter in ipairs(BIOMES) do for _, r in ipairs(MB[letter]) do rooms[#rooms + 1] = r end end
  table.sort(rooms)
  local biome = function(r) return r:sub(1, 1) end
  while true do
    local s = {}
    for i, r in ipairs(rooms) do s[i] = r end
    for i = #s, 2, -1 do local j = math.random(i); s[i], s[j] = s[j], s[i] end
    local ok = true
    for i = 1, #rooms do if biome(rooms[i]) == biome(s[i]) then ok = false break end end
    if ok then
      local parts = {}
      for i = 1, #rooms do parts[#parts + 1] = rooms[i] .. ":" .. s[i] end
      return table.concat(parts, ",")
    end
  end
end

local function new_run(dream)
  CurrentRun = { RoomHistory = {}, RoomCreations = {}, RoomsEntered = {}, RoomCountCache = {},
    BiomeRoomCountCache = {}, EncountersCompletedCache = {}, ClosedDoors = {}, SpawnRecord = {},
    BiomeRewardsSpawned = 0, MaxClockworkNonGoalRewards = 3, IsDreamRun = dream or nil, Hero = {} }
  GameState = setmetatable({ SpawnRecord = {} },
    { __index = function() return setmetatable({}, { __index = function() return 99 end }) end })
  MapState = { OfferedExitDoors = { {}, {} }, ActiveObstacles = {} }
  PYLON_SPAWNS, PYLON_OBJECTIVES = 0, 0
end

local function enter(room)
  if CurrentRun.CurrentRoom then
    table.insert(CurrentRun.RoomHistory, CurrentRun.CurrentRoom)
    UpdateRunHistoryCache(CurrentRun, CurrentRun.CurrentRoom)
  end
  CurrentRun.CurrentRoom = room
  room.RoomCreations = room.RoomCreations or {}
  StartRoom(CurrentRun, room)
end

local function biome_start(letter)
  CurrentRun.BiomeRoomCountCache = {}
  enter({ Name = letter .. "_Opening", RoomSetName = letter, NextRoomSet = { letter }, RoomCreations = {} })
  UpdateRunHistoryCache(CurrentRun)
end

local function record(served, letter, room)
  table.insert(served, { letter = letter, name = room.Name, mb = MinibossRooms.is_miniboss_room(room.Name) })
end

-- One linear biome: offer two or three doors per room, always take a miniboss door when there is one.
local function play_biome(letter, served)
  for _ = 1, BIOME_LEN do
    local doors = {}
    for _ = 1, math.random(2, 3) do
      local data = ChooseNextRoomData(CurrentRun, {}, doors)
      if data == nil then break end
      table.insert(doors, { Room = CreateRoom(data) })
    end
    if #doors == 0 then return "no room for any door" end
    local pick = doors[math.random(#doors)]
    for _, door in ipairs(doors) do
      if MinibossRooms.is_miniboss_room(door.Room.Name) then pick = door break end
    end
    enter(pick.Room)
    record(served, letter, pick.Room)
  end
end

-- Ephyra: the square and back, six times. The square's doors get their rooms through the real
-- DoUnlockRoomExits (PredeterminedDoorRooms); one of its two miniboss doors is open per city, as
-- ChooseAvailableN_HubDoors' coin flip leaves it. The miniboss door is taken first.
local function play_ephyra(served)
  local hub = CreateRoom(RoomData.N_Hub)
  hub.RoomSetName = "N"
  enter(hub)
  local mbDoor = HUB_MB_DOOR[math.random(2) == 1 and "N_MiniBoss01" or "N_MiniBoss02"]
  for visit = 1, 6 do
    MapState.OfferedExitDoors = {}
    for _, id in ipairs({ mbDoor, HUB_COMBAT_DOORS[visit], HUB_COMBAT_DOORS[visit + 6] }) do
      local door = { ObjectId = id, Name = "EphyraExitDoor" }
      SetupDefaultDoor(door)
    end
    DoUnlockRoomExits(CurrentRun, CurrentRun.CurrentRoom)
    local pick = MapState.OfferedExitDoors[mbDoor] or MapState.OfferedExitDoors[HUB_COMBAT_DOORS[visit]]
    if not (pick and pick.Room) then return "the square offered no room" end
    CloseDoorForRun(CurrentRun, pick)   -- N_Hub's CloseDoorsOnUse
    enter(pick.Room)
    record(served, "N", pick.Room)
    local back = ShallowCopyTable(hub)
    back.ExitsUnlocked = true
    CurrentRun.CurrentRoom.Leaving = true
    table.insert(CurrentRun.RoomHistory, CurrentRun.CurrentRoom)
    UpdateRunHistoryCache(CurrentRun, CurrentRun.CurrentRoom)
    CurrentRun.CurrentRoom = back       -- a return visit restores, it does not StartRoom
    record(served, "N", back)
  end
end

local function simulate(build, dream, seed)
  math.randomseed(seed)
  install_mod(build)
  new_run(dream)
  ItemManager.settings = { miniboss_room_map = dream and "" or seed_map_string() }
  local served = {}
  local biomes = BIOMES
  if dream then
    biomes = {}
    local pool = { table.unpack(BIOMES) }
    for _ = 1, 4 do biomes[#biomes + 1] = table.remove(pool, math.random(#pool)) end
  end
  for _, letter in ipairs(biomes) do
    biome_start(letter)
    local err = (letter == "N") and play_ephyra(served) or play_biome(letter, served)
    if err then return nil, err end
  end
  return served
end

local function measure(served)
  local m = { back_to_back = 0, repeats = 0, longest = 0, per_biome_max = 0, native = 0, ephyra_native = 0 }
  local seen, streak, count = {}, 0, {}
  for i, s in ipairs(served) do
    if s.mb then
      streak = (i > 1 and served[i - 1].mb and served[i - 1].letter == s.letter) and streak + 1 or 1
      if streak > 1 then m.back_to_back = m.back_to_back + 1 end
      if seen[s.name] then m.repeats = m.repeats + 1 end
      seen[s.name] = true
      count[s.letter] = (count[s.letter] or 0) + 1
      if count[s.letter] > m.per_biome_max then m.per_biome_max = count[s.letter] end
      if MinibossRooms.ROOM_BIOME[s.name] == s.letter then
        m.native = m.native + 1
        if s.letter == "N" then m.ephyra_native = m.ephyra_native + 1 end
      end
    else
      streak = 0
    end
    if streak > m.longest then m.longest = streak end
  end
  return m
end

local failures = 0
local function check(cond, what) if not cond then failures = failures + 1; print("FAIL: " .. what) end end

print(string.format("%-7s %-6s %5s %12s %8s %8s %10s %10s", "build", "mode", "runs", "back-to-back",
  "repeats", "longest", "max/biome", "unswapped"))
for _, build in ipairs({ "0.10.0", "pre", "vet", "now" }) do
  for _, dream in ipairs({ false, true }) do
    local tot = { back_to_back = 0, repeats = 0, longest = 0, per_biome_max = 0, native = 0, ephyra_native = 0 }
    for seed = 1, RUNS do
      local served, err = simulate(build, dream, seed)
      check(served ~= nil, build .. " seed " .. seed .. ": " .. tostring(err))
      if served then
        local m = measure(served)
        for _, k in ipairs({ "back_to_back", "repeats", "native", "ephyra_native" }) do tot[k] = tot[k] + m[k] end
        if m.longest > tot.longest then tot.longest = m.longest end
        if m.per_biome_max > tot.per_biome_max then tot.per_biome_max = m.per_biome_max end
      end
    end
    print(string.format("%-7s %-6s %5d %12d %8d %8d %10d %10d", build, dream and "dream" or "seed", RUNS,
      tot.back_to_back, tot.repeats, tot.longest, tot.per_biome_max, tot.native))
    if build == "0.10.0" and not dream then
      check(tot.back_to_back > 0 and tot.longest >= 3, "0.10.0 should reproduce the reported chains")
      check(tot.ephyra_native > 0, "0.10.0 should leave Ephyra's slot unswapped")
    end
    if build == "now" or build == "vet" then
      local label = build .. (dream and " dream" or " seed")
      check(tot.back_to_back == 0, label .. ": back-to-back miniboss rooms")
      check(tot.repeats == 0, label .. ": an arena served twice")
      check(tot.native == 0, label .. ": a slot served its own biome's arena (" .. tot.native .. ")")
      -- Vanilla's own one-per-biome (two in the Summit) is the bookkeeping's job; the backstop
      -- alone only promises the properties above.
      if build == "now" then
        check(tot.per_biome_max <= 2, label .. ": more than two miniboss rooms in one biome")
      end
    end
  end
end

-- ---- Ephyra hosting a foreign arena -----------------------------------------------------------
local function hub_room()
  local hub = CreateRoom(RoomData.N_Hub)
  hub.RoomSetName = "N"
  hub.TimesVisited = 1
  return hub
end

for _, host in ipairs({ "N_MiniBoss01", "N_MiniBoss02" }) do
  install_mod("now")
  math.randomseed(11)
  new_run(false)
  local dest = (host == "N_MiniBoss01") and "G_MiniBoss02" or "F_MiniBoss03"
  ItemManager.settings = { miniboss_room_map = host .. ":" .. dest }
  local doorId = HUB_MB_DOOR[host]
  local stamp
  for _, s in pairs(RoomData[host].OnUseSetRunData) do stamp = s end
  local label = "hosted " .. host .. " -> " .. dest .. ": "

  enter({ Name = "N_PreHub01", RoomSetName = "N", RoomCreations = {} })
  local hub = hub_room()
  enter(hub)
  MapState.OfferedExitDoors = {}
  for _, id in ipairs({ doorId, HUB_COMBAT_DOORS[1] }) do SetupDefaultDoor({ ObjectId = id, Name = "EphyraExitDoor" }) end
  DoUnlockRoomExits(CurrentRun, hub)
  local door = MapState.OfferedExitDoors[doorId]
  local arena = door and door.Room
  check(arena and arena.Name == dest, label .. "the square's miniboss door builds the mapped arena")
  check(arena and arena.AP_MinibossRoomOrigin == host and arena.AP_HostRoomSet == "N", label .. "the arena is booked to Ephyra's slot")
  check(MapState.OfferedExitDoors[HUB_COMBAT_DOORS[1]].Room.Name == RoomData.N_Hub.PredeterminedDoorRooms[HUB_COMBAT_DOORS[1]],
    label .. "the square's other doors are untouched")
  check((CurrentRun.RoomCreations[host] or 0) >= 1 and CurrentRun.RoomCreations[dest] == nil, label .. "RoomCreations booked to the host")
  check(PREVIEWS[doorId] == true, label .. "the square's door shows its preview")

  -- Through the door (vanilla AttemptUseDoor -> LeaveRoom): the square closes its door.
  door.ReadyToUse = true
  AttemptUseDoor(door)
  check(IsDoorClosedForRun(CurrentRun, door), label .. "the square's door closes behind you")
  enter(arena)
  StartRoom(CurrentRun, arena)   -- a reload re-running StartRoom must not count twice
  check(CurrentRun.SpawnRecord.SoulPylon == 1, label .. "the arena counts as one pylon (got "
    .. tostring(CurrentRun.SpawnRecord.SoulPylon) .. ")")
  check(PYLON_SPAWNS == 0, label .. "no physical pylon")

  -- Its exits: previews hidden, no reroll, every one leads back to the square at the slot's doorway.
  MapState.OfferedExitDoors = {}
  for _, id in ipairs({ 901, 902 }) do SetupDefaultDoor({ ObjectId = id, Name = "ExitDoor", AllowReroll = true }) end
  PREVIEWS = {}
  DoUnlockRoomExits(CurrentRun, arena)
  for _, id in ipairs({ 901, 902 }) do
    local exit = MapState.OfferedExitDoors[id]
    check(exit and exit.Room ~= nil, label .. "exit " .. id .. " got a room")
    check(PREVIEWS[id] == false, label .. "exit " .. id .. " hides its preview")
    check(exit and exit.AllowReroll == false, label .. "exit " .. id .. " cannot be rerolled")
  end
  local exit = MapState.OfferedExitDoors[901]
  exit.ReadyToUse = true
  AttemptUseDoor(exit)
  check(exit.Room and exit.Room.Name == "N_Hub", label .. "the exit leads back to the square (got "
    .. tostring(exit.Room and exit.Room.Name) .. ")")
  check(CurrentRun.NextHeroStartPoint == stamp.NextHeroStartPoint and CurrentRun.NextHeroEndPoint == stamp.NextHeroEndPoint,
    label .. "the hero comes back out of the slot's doorway (" .. tostring(CurrentRun.NextHeroStartPoint) .. ")")

  -- A return visit: the square restores and runs DoUnlockRoomExits again on fresh door objects.
  local back = exit.Room
  back.ExitsUnlocked = true
  enter(back)
  MapState.OfferedExitDoors = {}
  SetupDefaultDoor({ ObjectId = doorId, Name = "EphyraExitDoor" })
  check(MapState.OfferedExitDoors[doorId] == nil, label .. "the used door stays closed on a return visit")
  CurrentRun.ClosedDoors.N_Hub = nil
  SetupDefaultDoor({ ObjectId = doorId, Name = "EphyraExitDoor" })
  DoUnlockRoomExits(CurrentRun, back)
  local again = MapState.OfferedExitDoors[doorId].Room
  check(again.Name == dest and again.AP_MinibossRoomOrigin == host, label .. "a return visit swaps the same arena again")
end

-- ---- An Ephyra arena as a guest elsewhere ---------------------------------------------------
-- A Dive: Ephyra came first and the native Boar was fought (its exit is now closed for the run
-- under the Name N_MiniBoss02); a later Erebus slot serves the Boar's arena.
local function guest_run(build)
  install_mod(build)
  math.randomseed(13)
  new_run(true)
  CurrentRun.AP_DreamMinibossRooms = { F_MiniBoss02 = "N_MiniBoss02" }
  local exitId = 4242
  enter({ Name = "N_Hub", RoomSetName = "N", RoomCreations = {}, TimesVisited = 1 })
  CurrentRun.ClosedDoors.N_MiniBoss02 = { [exitId] = true }
  biome_start("F")
  local arena = CreateRoom(MinibossRooms.swap_for(RoomData.F_MiniBoss02) or RoomData.F_MiniBoss02)
  enter(arena)
  SpawnSoulPylon(arena, { SpawnName = "SoulPylon" })   -- BaseN's start event (RoomDataN.lua:378)
  MapState.OfferedExitDoors = {}
  local door = { ObjectId = exitId, Name = "EphyraExitDoorReturnNE", ReturnToPreviousRoomName = "N_Hub",
    HideRewardPreview = true, AllowReroll = false }
  SetupDefaultDoor(door)
  local offered = MapState.OfferedExitDoors[exitId] ~= nil
  PREVIEWS = {}
  local leadsTo, startPoint
  if offered then
    DoUnlockRoomExits(CurrentRun, arena)
    door.ReadyToUse = true
    AttemptUseDoor(door)
    leadsTo, startPoint = door.Room and door.Room.Name, CurrentRun.NextHeroStartPoint
  end
  local closed = 0
  for _ in pairs(CurrentRun.ClosedDoors.N_MiniBoss02 or {}) do closed = closed + 1 end
  return { arena = arena, offered = offered, preview = PREVIEWS[exitId], leadsTo = leadsTo,
    startPoint = startPoint, pylons = PYLON_SPAWNS, closeOnUse = arena.CloseDoorsOnUse, closed = closed }
end

check(RoomData.N_MiniBoss02.CloseDoorsOnUse == true, "control: N_MiniBoss02 inherits BaseN's CloseDoorsOnUse")
local old = guest_run("0.10.0")
check(not old.offered, "control: on 0.10.0 the guest Boar's only exit is closed (the reported softlock)")
local g = guest_run("now")
check(g.arena.Name == "N_MiniBoss02" and g.arena.AP_HostRoomSet == "F", "guest: the Erebus slot serves the Boar's arena")
check(g.offered, "guest: its exit is offered despite the native room having closed it")
check(g.preview == true, "guest: its exit shows the next room's reward")
check(g.leadsTo and g.leadsTo ~= "N_Hub" and RoomData[g.leadsTo] and RoomData[g.leadsTo].RoomSetName == "F",
  "guest: its exit leads on into Erebus (got " .. tostring(g.leadsTo) .. ")")
check(g.startPoint == nil, "guest: no square doorway is handed to the next room (got " .. tostring(g.startPoint) .. ")")
check(g.pylons == 0, "guest: no Soul Pylon spawns")
check(g.closeOnUse == nil and g.closed == 1, "guest: leaving closes nothing")

-- ---- Dream map: all twenty rooms, none in its own biome, a bijection -----------------------
install_mod("now")
for seed = 1, 300 do
  math.randomseed(seed)
  new_run(true)
  ItemManager.settings = {}
  local dests, n = {}, 0
  for host in pairs(MinibossRooms.ROOM_BIOME) do
    local swapped = MinibossRooms.swap_for(RoomData[host])
    check(swapped ~= nil, "dream: " .. host .. " not swapped")
    if swapped then
      n = n + 1
      check(MinibossRooms.ROOM_BIOME[swapped.Name] ~= MinibossRooms.ROOM_BIOME[host], "dream: same-biome " .. host)
      check(not dests[swapped.Name], "dream: " .. swapped.Name .. " served by two slots")
      dests[swapped.Name] = true
    end
  end
  check(n == 20, "dream map covers " .. n .. " rooms, not 20")
end

print(failures == 0 and "ALL CHECKS PASSED" or (failures .. " CHECK(S) FAILED"))
os.exit(failures == 0 and 0 or 1)
