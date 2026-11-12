-- Miniboss ROOM shuffle (2026-08-16 user ruling). Minibosses no longer shuffle as enemies -- see
-- EnemySanity.substitute_encounter, which skips every "MiniBoss*" encounter outright -- because
-- classifying by check NAME cannot express "this spawn is the room's miniboss", and both
-- directions broke live (ordinary trash drawing real minibosses out of the miniboss pool; the
-- room's own miniboss being replaced by a regular enemy).
--
-- Instead the ROOMS move. You still fight each miniboss in the room it belongs to, with its own
-- authored composition intact -- you might just meet Charybdis' room partway through Erebus.
--
-- The permutation is decided at GENERATION (Locations.compute_miniboss_room_map) and arrives in
-- the "miniboss_room_map" setting as "Host:Dest,...". It has to come from there rather than being
-- rolled here, because AP logic is derived from it: a miniboss check is reachable in whatever zone
-- hosts its room, exactly the correctness rule established for the enemy shuffle in
-- [[project_enemysanity_logic_follows_shuffle]]. A locally-invented permutation would describe
-- spawns the rules never saw.
MinibossRooms = MinibossRooms or {}

-- Mirrors Python Locations.MINIBOSS_ROOMS (hand-duplicated -- keep both in sync). Room -> the
-- biome letter it natively lives in. The biome letter doubles as the RoomSetName the run routes
-- by, and as the art package name ("BiomeF"), so one table serves both jobs.
-- Derivation of which miniboss each room holds is recorded Python-side; the mod only needs to
-- know where each room natively belongs.
MinibossRooms.ROOM_BIOME = {
  F_MiniBoss01 = "F", F_MiniBoss02 = "F", F_MiniBoss03 = "F",
  G_MiniBoss01 = "G", G_MiniBoss02 = "G", G_MiniBoss03 = "G",
  H_MiniBoss01 = "H", H_MiniBoss02 = "H",
  I_MiniBoss01 = "I", I_MiniBoss02 = "I",
  N_MiniBoss01 = "N", N_MiniBoss02 = "N",
  O_MiniBoss01 = "O", O_MiniBoss02 = "O",
  P_MiniBoss01 = "P", P_MiniBoss02 = "P",
  Q_MiniBoss02 = "Q", Q_MiniBoss03 = "Q", Q_MiniBoss04 = "Q", Q_MiniBoss05 = "Q",
}

-- The AP checks these rooms own, mirroring Python Locations.MINIBOSS_ROOM_CHECK_NAMES. Read by
-- EnemySanity.replacement_unit_id to keep them out of enemy substitution: each check must have
-- exactly one system deciding where it is obtainable, and these belong to the room shuffle.
-- "Shadow-Spiller" is the one that looks out of place -- it is F_MiniBoss02's miniboss
-- (FogEmitter_Elite), not ordinary trash; plain FogEmitter is in no generic spawn pool.
--
-- Kept per room (the third column of Python's MINIBOSS_ROOMS) rather than as a bare set, because
-- the door marker below needs to know WHICH check sits behind a given miniboss door.
MinibossRooms.ROOM_CHECK = {
  F_MiniBoss01 = "Root-Stalker", F_MiniBoss02 = "Shadow-Spiller", F_MiniBoss03 = "Master-Slicer",
  G_MiniBoss01 = "Deep Serpent", G_MiniBoss02 = "King Vermin", G_MiniBoss03 = "Hellifish",
  H_MiniBoss01 = "Phantom", H_MiniBoss02 = "Queen Lamia",
  I_MiniBoss01 = "The Verminancer", I_MiniBoss02 = "Goldwrath",
  N_MiniBoss01 = "Satyr Champion", N_MiniBoss02 = "Erymanthian Boar",
  O_MiniBoss01 = "Charybdis", O_MiniBoss02 = "The Yargonaut",
  P_MiniBoss01 = "Talos", P_MiniBoss02 = "Mega-Dracon",
  Q_MiniBoss02 = "Spawn of Typhon", Q_MiniBoss03 = "Tail of Typhon",
  Q_MiniBoss04 = "Eye of Typhon", Q_MiniBoss05 = "Twins of Typhon",
}
MinibossRooms.ROOM_CHECK_NAMES = {}
for _, check in pairs(MinibossRooms.ROOM_CHECK) do MinibossRooms.ROOM_CHECK_NAMES[check] = true end

-- Ephyra (0.11.0). Its two miniboss rooms shuffle like the rest, but the city is a hub -- the
-- square (N_Hub) and rooms that each lead back to it -- so both directions need plumbing that no
-- other biome does. The decisions live here; reload.lua's wraps call them.
--   * Ephyra HOSTING a foreign arena. The square never asks ChooseNextRoomData for its miniboss
--     doors: N_Hub.PredeterminedDoorRooms gives each door a fixed room (RoomDataN.lua:1307,
--     RoomLogic.lua:3905 DoUnlockRoomExits -> CreateRoom). On 0.10.x the swap never ran there and
--     the check mapped into an Ephyra slot could not be earned anywhere. serve_hub_door swaps it
--     at CreateRoom instead. The arena must then behave like an Ephyra room: its exits lead back
--     to the square (hub_return), the hero comes back out of the same doorway (hub_doorway), and
--     it counts toward the square's six pylons (credit_hub_pylon).
--   * An Ephyra arena as a GUEST elsewhere. It brings the city's wiring along: its exit returns
--     to the square, the next room starts at a square doorway id, it spawns a Soul Pylon, it hides
--     the next room's reward and it closes its exit for the run. Each is undone for guests (here
--     and in reload.lua).
local EPHYRA = "N"
local EPHYRA_HUB = "N_Hub"

-- Lazily parsed from the "miniboss_room_map" setting, re-parsed only when the raw string actually
-- changes (e.g. reconnecting to a different seed). Same shape and lifecycle as EnemySanity's
-- shuffle_map cache.
local _raw = nil
local _map = {}

local function room_map()
  local raw = ItemManager.settings and ItemManager.settings["miniboss_room_map"]
  if raw ~= _raw then
    _raw = raw
    _map = {}
    if type(raw) == "string" and raw ~= "" then
      for pair in raw:gmatch("[^,]+") do
        local host, dest = pair:match("^(.-):(.*)$")
        if host and dest and host ~= "" and dest ~= "" then _map[host] = dest end
      end
    end
  end
  return _map
end

-- Dream Dives roll their own permutation, once per dive, over all twenty rooms. The seed's map
-- only covers the routes the seed generated, but a dive draws its regions from every biome: on an
-- Underworld + Dream seed the four Surface biomes' miniboss rooms had no entry and always came up
-- native, and a Dream-only seed has no map at all (seen live 2026-10-04: P_MiniBoss02 unswapped in
-- a dive whose Oceanus region had just been swapped). Nothing in logic depends on which room a
-- dive serves where -- a Dream miniboss kill counts its species toward "Dream Miniboss NN"
-- (LocationManager.on_dream_enemy_killed), never a named check -- so this can be decided here.
-- Kept on CurrentRun so a save/load mid-dive keeps the same rooms behind the same slots.
--
-- Like the seed's map, a slot never loads a room from its own biome: a sibling room shows a
-- miniboss that region rolls anyway, which reads as not shuffled.
local function roll_dream_map()
  local rooms = {}
  for name in pairs(MinibossRooms.ROOM_BIOME) do table.insert(rooms, name) end
  table.sort(rooms)
  local n = #rooms
  for _ = 1, 500 do
    local shuffled = {}
    for i, name in ipairs(rooms) do shuffled[i] = name end
    for i = n, 2, -1 do
      local j = math.random(i)
      shuffled[i], shuffled[j] = shuffled[j], shuffled[i]
    end
    local ok = true
    for i = 1, n do
      if MinibossRooms.ROOM_BIOME[rooms[i]] == MinibossRooms.ROOM_BIOME[shuffled[i]] then
        ok = false
        break
      end
    end
    if ok then
      local map = {}
      for i = 1, n do map[rooms[i]] = shuffled[i] end
      return map
    end
  end
  -- Not reached in practice. `rooms` is sorted, so each biome's rooms sit together; rotating by
  -- the largest biome's size (Q, four rooms) puts every slot outside its own biome.
  local map = {}
  for i = 1, n do map[rooms[i]] = rooms[(i + 3) % n + 1] end
  return map
end

local function dream_map()
  local run = game.CurrentRun
  if type(run.AP_DreamMinibossRooms) ~= "table" then
    run.AP_DreamMinibossRooms = roll_dream_map()
  end
  return run.AP_DreamMinibossRooms
end

-- The map in force for the current run. Dives shuffle under the same condition the seed's map is
-- generated under (Locations.compute_miniboss_room_map): enemysanity places miniboss checks.
local function active_map()
  if game.CurrentRun and game.CurrentRun.IsDreamRun then
    if EnemySanity.locations_on() and ItemManager.setting_on("include_minibosses") then
      return dream_map()
    end
    return {}
  end
  return room_map()
end

-- Public: is this room one the shuffle can move? (Used by the reload.lua hook to stay cheap on
-- the overwhelming majority of rooms, which aren't miniboss rooms at all.)
function MinibossRooms.is_miniboss_room(name)
  return type(name) == "string" and MinibossRooms.ROOM_BIOME[name] ~= nil
end

-- Make the destination room's art resident before it loads. Room art ships in the biome packages
-- exactly like enemy art does -- Content/Packages/1080p has BiomeF/G/H/I/N/O/P/Q .pkg files and no
-- per-room ones -- so a foreign miniboss room needs its own biome package or it renders untextured
-- (the same failure that produced the flat-black enemies, but for a whole arena).
local function preload_biome(letter)
  if type(letter) ~= "string" or letter == "" then return end
  if type(LoadPackages) ~= "function" then return end
  pcall(LoadPackages, { Name = "Biome" .. letter, IgnoreAssert = true })
end

-- Public: given the room the run just chose, return the room it should load instead (or nil to
-- leave it alone).
--
-- The swapped-in room is a DEEP COPY -- game.RoomData entries are shared authored templates, and
-- stamping our routing fields onto the global would leak into every later use of that room,
-- including its native appearance in its own biome.
--
-- Three fields carry the "foreign arena, native routing" behaviour the user asked for:
--   * ForceNextRoomSet -- the game's OWN override, read by ChooseNextRoomData (RunLogic.lua:789)
--     ahead of the current room's RoomSetName. Setting it to the HOST biome means that when you
--     take the exit out of Charybdis' room, the next room is drawn from Erebus as normal, so the
--     run's length and shape are unchanged ("continue the run forward").
--   * RoomSetName -- also set to the host biome (see below).
--   * AP_HostRoomSet -- ours, read by Routes.current(). Without it every AP system keyed off the
--     route (room checks, score, enemy checks, Dream scaling) would think you had teleported to
--     the Surface for one room, because those all resolve through the room's native RoomSetName.
function MinibossRooms.swap_for(roomData)
  local hostName = roomData and roomData.Name
  if not MinibossRooms.is_miniboss_room(hostName) or roomData.AP_MinibossRoomOrigin then return nil end
  local destName = active_map()[hostName]
  if not destName or destName == hostName then return nil end
  local template = game.RoomData and game.RoomData[destName]
  if not template then
    rom.log.warning("[AP] miniboss rooms: no RoomData for '" .. tostring(destName)
      .. "' -- leaving " .. tostring(hostName) .. " alone")
    return nil
  end

  local hostBiome = MinibossRooms.ROOM_BIOME[hostName]
  local destBiome = MinibossRooms.ROOM_BIOME[destName]
  preload_biome(destBiome)

  local swapped = DeepCopyTable(template)
  swapped.ForceNextRoomSet = hostBiome
  swapped.AP_HostRoomSet = hostBiome
  -- Also the room's own RoomSetName: a Chaos gate out of this arena (G/N/O/Q arenas allow them)
  -- resolves "the previous room's biome" through it (vanilla ChooseNextRoomData's
  -- UsePreviousRoomSet branch), which would otherwise send the run into the foreign route.
  swapped.RoomSetName = hostBiome
  -- Ephyra rooms (BaseN) close the door you leave by for the rest of the run, keyed by room Name
  -- and door id (RunLogic.lua CloseDoorForRun). The arena has one exit, so the next time a room of
  -- that Name loads -- the native one through the hub, or this one again -- SetupDefaultDoor finds
  -- its only exit closed, UnlockRoomExits sees no offered doors and returns, and the room never
  -- opens (Brice13 2026-10-10: the Boar twice in Oceanus). reload.lua's IsDoorClosedForRun wrap
  -- covers the other half (a guest arena entered after the native one was left).
  swapped.CloseDoorsOnUse = nil
  swapped.AP_MinibossRoomOrigin = hostName
  rom.log.info("[AP] miniboss rooms: " .. hostName .. " -> " .. destName
    .. " (routing stays in biome " .. tostring(hostBiome) .. ")")
  return swapped
end

-- ---- Ephyra ------------------------------------------------------------------------------------

-- A swapped arena standing in one of Ephyra's two slots (the host is N_MiniBoss01/02).
function MinibossRooms.ephyra_hosted(room)
  return type(room) == "table" and room.AP_MinibossRoomOrigin ~= nil and room.AP_HostRoomSet == EPHYRA
end

-- One of Ephyra's arenas swapped into another biome's slot.
function MinibossRooms.ephyra_guest(room)
  return type(room) == "table" and room.AP_MinibossRoomOrigin ~= nil and room.AP_HostRoomSet ~= EPHYRA
    and MinibossRooms.ROOM_BIOME[room.Name] == EPHYRA
end

-- Public: CreateRoom is about to build `roomData` for one of the square's doors. Returns the swapped
-- arena for an Ephyra miniboss slot, nil otherwise. Only the square: it is the one place a miniboss
-- room is created without going through ChooseNextRoomData (whose wrap swaps everything else), and
-- swap_for refuses a room that is already a swapped copy, so nothing is swapped twice. The square's
-- own door choice (ChooseAvailableN_HubDoors' coin flip between the two slots) still reads the
-- native rooms' data, so Ephyra keeps offering exactly one miniboss door per visit to the city.
function MinibossRooms.serve_hub_door(run, roomData)
  local current = run and run.CurrentRoom
  if not (current and current.Name == EPHYRA_HUB) then return nil end
  if MinibossRooms.ROOM_BIOME[roomData and roomData.Name] ~= EPHYRA then return nil end
  return MinibossRooms.swap_for(roomData)
end

-- Public: where a door out of `room` must lead instead of its own room, for AttemptUseDoor's
-- ReturnToPreviousRoomName. A hosted arena returns to the square, as the Ephyra room it replaced
-- did (EphyraExitDoorReturn, ObstacleDataN.lua:100). A guest arena returns nowhere: its own
-- EphyraExitDoorReturn would otherwise walk back into a square already finished this run
-- (RoomLogic.lua:841). nil for both "not a swapped room" and "clear it" -- the caller only applies
-- it to swapped rooms. Without a square in the run's history (not reachable: the square is
-- Ephyra's second room) the hosted arena keeps the room its door was given.
function MinibossRooms.hub_return(run, room)
  if not MinibossRooms.ephyra_hosted(room) then return nil end
  for _, past in ipairs((run and run.RoomHistory) or {}) do
    if past.Name == EPHYRA_HUB then return EPHYRA_HUB end
  end
  return nil
end

-- Public: the square doorway the hero comes back out of, as (startId, endId), for LeaveRoom's
-- NextHeroStartPoint/NextHeroEndPoint. A hosted arena uses the doorway of the slot it took --
-- vanilla stamps those through the native room's OnUseSetRunData, keyed by the native exit door's
-- Name, which the arena's own doors don't have (N_MiniBoss02: 560889/561166, the square's door
-- to it). Anything else gets (nil, nil): a guest arena's own stamp names square ids that don't
-- exist in the next room's map, which started the hero outside the walls with the camera stuck
-- on a corner (Brice13 2026-10-10, Bojacx 2026-10-25).
function MinibossRooms.hub_doorway(room)
  if not MinibossRooms.ephyra_hosted(room) then return nil, nil end
  local host = game.RoomData and game.RoomData[room.AP_MinibossRoomOrigin]
  for _, stamp in pairs((host and host.OnUseSetRunData) or {}) do
    if type(stamp) == "table" and stamp.NextHeroStartPoint and stamp.NextHeroEndPoint then
      return stamp.NextHeroStartPoint, stamp.NextHeroEndPoint
    end
  end
  return nil, nil
end

-- Public: count a hosted arena toward the square's pylons. Every Ephyra room spawns one Soul Pylon
-- (BaseN's SpawnSoulPylon start event, RoomDataN.lua:378), and the square's boss exit opens on
-- pylons SPAWNED this run, not broken (EphyraExitBossDoor's AvailableRequirements and
-- HandlePylonObjective both read CurrentRun.SpawnRecord.SoulPylon). A foreign arena runs its own
-- biome's start events, not BaseN's, so without this the slot would cost the city one pylon.
-- Credited rather than spawned: Soul Pylons stand on SoulPylonSpawnPoints, which only Ephyra's
-- maps contain, and a pylon is a RoomRequiredObject -- one placed somewhere unreachable would
-- keep the arena's exits shut for good. Once per arena, so a reload cannot count it twice.
function MinibossRooms.credit_hub_pylon(run, room)
  if not (run and MinibossRooms.ephyra_hosted(room)) or room.AP_HubPylonCredited then return end
  room.AP_HubPylonCredited = true
  run.SpawnRecord = run.SpawnRecord or {}
  run.SpawnRecord.SoulPylon = (run.SpawnRecord.SoulPylon or 0) + 1
  if game.GameState and type(game.GameState.SpawnRecord) == "table" then
    game.GameState.SpawnRecord.SoulPylon = (game.GameState.SpawnRecord.SoulPylon or 0) + 1
  end
  rom.log.info("[AP] miniboss rooms: " .. tostring(room.Name) .. " in Ephyra's "
    .. tostring(room.AP_MinibossRoomOrigin) .. " slot counts as pylon "
    .. tostring(run.SpawnRecord.SoulPylon))
end

-- Public: set up `room`'s exit doors before DoUnlockRoomExits gives them rooms and previews. A
-- hosted arena's exits all lead back to the square (hub_return), so the reward preview of the
-- throwaway room each one is assigned would be a lie; vanilla's Ephyra return doors hide it and
-- forbid rerolls. A guest arena's single exit is one of those return doors, so it hid the reward
-- of the room it now really leads to; show it again.
function MinibossRooms.prepare_exit_doors(room, doors)
  local hosted, guest = MinibossRooms.ephyra_hosted(room), MinibossRooms.ephyra_guest(room)
  if not (hosted or guest) then return end
  for _, door in pairs(doors or {}) do
    if type(door) == "table" then
      if hosted then
        door.HideRewardPreview = true
        door.AllowReroll = false
      else
        door.HideRewardPreview = false
      end
    end
  end
end

-- Door marker (the Fated List sub-icon the Miniboss Prophecy puts on a miniboss door you still
-- need). Vanilla decides it from its own lifetime encounter records, which do not line up with
-- our checks: Master-Slicer's encounter is in neither prophecy, and with the Shadow vow active
-- Root-Stalker and Shadow-Spiller run as "_Shrine" encounters the prophecies do not name, so
-- those doors never get marked. Unshuffled you could work out by elimination what an unmarked
-- Erebus door held; with the rooms shuffled the marker is the only thing telling you whether the
-- miniboss behind a door is one you still need, so it has to be right for all twenty.
--
-- Returns true (mark it), false (do not), or nil (not ours to decide -- leave vanilla's answer).
-- Keyed by the room's Name, which for a swapped room is the DESTINATION's: the miniboss you will
-- actually meet.
function MinibossRooms.door_marker(room)
  local check = room and MinibossRooms.ROOM_CHECK[room.Name]
  if not check then return nil end
  if not (EnemySanity.locations_on() and ItemManager.setting_on("include_minibosses")) then return nil end
  return LocationManager.miniboss_check_pending(check)
end

-- Selection bookkeeping. The swapped room keeps the DESTINATION's Name (the map, encounter and
-- art all key off it), but the game's "have I used this miniboss room yet" counters are keyed by
-- Name too -- CurrentRun.RoomsEntered, RoomCreations, RoomCountCache, BiomeRoomCountCache. Left
-- alone, the slot the run actually spent (the HOST) never registers, and the destination's
-- native slot registers as spent instead. Seen live 2026-10-03: F_MiniBoss01 -> I_MiniBoss01,
-- then F_MiniBoss02 (gated on RoomsEntered having no F_MiniBoss01) was still eligible and forced
-- by ForceAtBiomeDepthMin, so Erebus served two miniboss rooms back to back. The mirror image is
-- quieter: I_MiniBoss01 would later be refused in Tartarus as already created this run.
--
-- So each counter is moved from the destination's name to the host's. Split in two because
-- StartRoom needs the host counted before base runs (exits can be assigned inside it) and can
-- only take the destination back off after base has put it on. GameState's lifetime counters
-- are left alone -- the destination room really was visited.
local function swapped_names(room)
  local host = room and room.AP_MinibossRoomOrigin
  if type(host) ~= "string" or host == room.Name then return nil end
  return host, room.Name
end

function MinibossRooms.count_host(room, counts)
  local host = swapped_names(room)
  if not host or type(counts) ~= "table" then return end
  counts[host] = (counts[host] or 0) + 1
end

-- Clears the entry instead of leaving a 0: HasNone requirements test for presence.
function MinibossRooms.uncount_dest(room, counts)
  local host, dest = swapped_names(room)
  if not host or type(counts) ~= "table" then return end
  local n = counts[dest]
  if type(n) ~= "number" then return end
  counts[dest] = (n > 1) and (n - 1) or nil
end

-- No miniboss arena twice in a run, and never two miniboss rooms in a row (0.11.0, the most
-- reported problem on 0.10.0: up to five miniboss rooms back to back in Erebus, the same one up to
-- four times). The bookkeeping above is the real fix -- 0.10.0 shipped without it, so a swapped
-- host never registered as used, its siblings stayed eligible, and ForceAtBiomeDepthMin kept
-- forcing them -- but it rests on matching vanilla's counters exactly. This is the backstop the
-- players asked for, checked on the room the run actually chose.
--
-- The ledger is keyed by the room actually SERVED (a swapped room's Name is its destination), on
-- CurrentRun so it survives a save and starts empty each run. Native miniboss rooms are recorded
-- too: with the shuffle on, any arena serving twice is a bug.
function MinibossRooms.note_served(run, room)
  if not (run and room and MinibossRooms.is_miniboss_room(room.Name)) then return end
  run.AP_MinibossRoomsServed = run.AP_MinibossRoomsServed or {}
  run.AP_MinibossRoomsServed[room.Name] = true
end

-- Why the run must not take `hostName` next, or nil. `map` is the active map.
local function refusal(run, hostName, map)
  local current = run and run.CurrentRoom
  if current and (current.AP_MinibossRoomOrigin or MinibossRooms.is_miniboss_room(current.Name)) then
    return "back to back"
  end
  local served = map[hostName] or hostName
  if run and run.AP_MinibossRoomsServed and run.AP_MinibossRoomsServed[served] then
    return served .. " already served this run"
  end
  return nil
end

-- Public: given the room ChooseNextRoomData settled on (before swap_for), return a replacement
-- or nil to keep it. `reroll(excluded)` re-runs the room choice with `excluded` (a Name -> true
-- set) added to ExcludedNames and returns its room or nil. Only acts while the shuffle has a map:
-- vanilla's own rules already keep unshuffled minibosses apart. If the reroll comes back empty or
-- still on a refused room the original stands -- a door without a room is worse than a repeat.
function MinibossRooms.vet_choice(run, result, reroll)
  local name = result and result.Name
  if not MinibossRooms.is_miniboss_room(name) then return nil end
  -- In Ephyra (a hosted arena included: its RoomSetName is the host's) every room chosen here is the
  -- throwaway an exit is given before it returns you to the square; the square's own doors never
  -- come through here. Nothing to vet, and refusing would only fill the log.
  local current = run and run.CurrentRoom
  if current and current.RoomSetName == EPHYRA then return nil end
  local map = active_map()
  if next(map) == nil then return nil end
  local why = refusal(run, name, map)
  if not why then return nil end
  local excluded = {}
  for room in pairs(MinibossRooms.ROOM_BIOME) do
    if refusal(run, room, map) then excluded[room] = true end
  end
  local again = type(reroll) == "function" and reroll(excluded) or nil
  if not again or excluded[again.Name] then
    rom.log.warning("[AP] miniboss rooms: " .. name .. " refused (" .. why
      .. ") but no other room was eligible -- keeping it")
    return nil
  end
  rom.log.info("[AP] miniboss rooms: " .. name .. " refused (" .. why .. ") -- "
    .. tostring(again.Name) .. " instead")
  return again
end
