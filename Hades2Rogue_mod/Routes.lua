---@diagnostic disable: lowercase-global
-- Routes.lua — maps the game's biome code (CurrentRun.CurrentRoom.RoomSetName) to
-- our route + zone index, so the mod knows whether a run is Underworld, Surface, or Nightmare.
-- Mapping (confirmed from the game's RoomData<code>.lua files):
--   Underworld: F=Erebus(1) G=Oceanus(2) H=Fields of Mourning(3) I=Tartarus(4)
--   Surface:    N=City of Ephyra(1) O=Rift of Thessaly(2) P=Mount Olympus(3) Q=The Summit(4)
-- Nightmare is the opt-in third-party "Zagreus' Journey" mod (NikkelM-Zagreus_Journey). Unlike
-- vanilla's letter codes, that mod's RoomSetName is the literal biome word (confirmed via its
-- Scripts/RoomSets.lua and HadesRoomData.lua) -- so Routes.ROOMSET is a mixed-key table.

Routes = Routes or {}

Routes.NIGHTMARE_MOD_NAME = "NikkelM-Zagreus_Journey"

Routes.ROOMSET = {
  F = { "Underworld", 1 }, G = { "Underworld", 2 }, H = { "Underworld", 3 }, I = { "Underworld", 4 },
  N = { "Surface", 1 },    O = { "Surface", 2 },    P = { "Surface", 3 },    Q = { "Surface", 4 },
  Tartarus = { "Nightmare", 1 }, Asphodel = { "Nightmare", 2 }, Elysium = { "Nightmare", 3 }, Styx = { "Nightmare", 4 },
  -- Zagreus' Journey has two more roomsets (Meta/Constants.lua ValidModdedRunBiomes):
  -- "Surface" is Hades 1's endgame surface walk + the Hades boss arena (post-Styx, so zone
  -- 4), and "Challenge" is the ported Erebus infernal-gate rooms, which can be entered from
  -- any biome -- no fixed zone (nil zone is handled as "don't over-block" downstream).
  Surface = { "Nightmare", 4 }, Challenge = { "Nightmare" },
}

-- Check-name prefixes per route (must match the Python world's location names).
-- SCORE_PREFIX = point_based system. The room-based systems have no per-route prefix constant:
-- their check names are per ZONE ("<Route> <Zone> Room NN") and are built from ZONE_DISPLAY
-- below via LocationManager.room_name.
Routes.SCORE_PREFIX = { Underworld = "Underworld Score", Surface = "Surface Score", Nightmare = "Nightmare Score", Dream = "Dream Score" }
-- separate_checks=combine_pools room pool: route-agnostic, keyed on depth only ("Room NNNN").
Routes.COMBINED_ROOM_PREFIX = "Room"
-- separate_checks=combine_pools point pool: route-agnostic ("Score NNNN"). COMBINED_SCORE_KEY
-- stands in for a route name wherever a score pool is keyed (SCORE_PREFIX, score_limit_for,
-- is_score_checked), so the shared pool flows through the same code as a per-route one.
Routes.COMBINED_SCORE_KEY = "Combined"
Routes.SCORE_PREFIX[Routes.COMBINED_SCORE_KEY] = "Score"

-- Real per-zone room-check counts -- mirrors the Python world's Routes.ROUTES[route]
-- ["zone_room_counts"]/["zone_display"] (see that file's comment for where the real numbers
-- came from; keep these two tables in sync by hand if the counts are ever re-tuned).
-- Room checks are counted and named PER ZONE: "<Route> <Zone> Room NN" means the Nth room
-- cleared inside that zone, in one run. That has to key off the zone the player is ACTUALLY in
-- (Routes.current()), not off a route-wide running depth mapped back onto a zone -- how many
-- rooms a zone yields varies run to run (multi-encounter rooms score per encounter, Chaos
-- Gate/Anomaly detours add more), so a route-wide counter drifts out of alignment with the
-- real zone almost immediately and would both mislabel checks and strand the deep tail of a
-- route as unreachable. See LocationManager.score_room/on_room_room.
Routes.ZONE_ROOM_COUNTS = {
  Underworld = { 13, 10, 10, 12 },
  Surface    = { 10, 14, 10, 10 },
  Nightmare  = { 13, 10, 11, 12 },
}
-- Rooms every run scores before the zone boss (Python "zone_room_guaranteed"). The mod doesn't
-- use these -- logic does -- but they're kept here so tools/sync_check.py can hold both tables to
-- the Python ones. Rooms past these are released by the zone boss
-- (LocationManager.on_zone_boss_defeated).
Routes.ZONE_ROOM_GUARANTEED = {
  Underworld = { 10, 6, 4, 2 },
  Surface    = { 8, 12, 9, 3 },
  Nightmare  = { 10, 6, 8, 8 },
}
Routes.ZONE_DISPLAY = {
  Underworld = { "Erebus", "Oceanus", "Fields of Mourning", "Tartarus" },
  Surface    = { "City of Ephyra", "Rift of Thessaly", "Mount Olympus", "The Summit" },
  Nightmare  = { "Tartarus", "Asphodel", "Elysium", "Styx" },
}

-- Dream Dive's per-region room count (Locations.DREAM_ROOM_LOCATIONS_PER_REGION on the Python
-- side) -- the same for every region, regardless of dream_region_count (a per-seed option, so
-- Dream has no fixed zone list the way the other routes do).
Routes.DREAM_ROOM_LOCATIONS_PER_REGION = 12
Routes.DREAM_ROOM_GUARANTEED_PER_REGION = 2
Routes.DREAM_MAX_REGIONS = 12

-- Display name for a route's zone (1-indexed). Dream's "zones" are DreamDiveTweaks region
-- SLOTS, whose biome identity is randomized per attempt, so they're named by position.
function Routes.zone_display_for(route, zone_index)
  -- < 1 is not a real zone: Routes.dream_current falls back to 0 for EnteredBiomes before any
  -- biome start room has loaded, and naming a check "Dream Region 0 Room 01" would invent a
  -- location that exists in no seed. Callers treat nil as "don't send a per-zone room check".
  if not zone_index or zone_index < 1 then return nil end
  if route == "Dream" then return "Region " .. zone_index end
  local display = Routes.ZONE_DISPLAY[route]
  return display and display[zone_index] or nil
end

-- How many room checks that zone has (i.e. the cap on its local depth).
function Routes.zone_room_count(route, zone_index)
  if not zone_index or zone_index < 1 then return 0 end
  if route == "Dream" then return Routes.DREAM_ROOM_LOCATIONS_PER_REGION end
  local counts = Routes.ZONE_ROOM_COUNTS[route]
  return counts and counts[zone_index] or 0
end

-- How many zones the route has this seed. Fixed 4 for the real routes; Dream's is the
-- per-seed, already-clamped region count the world reports in slot_data (falling back to the
-- native maximum so a missing setting can't silently shorten a cascade).
function Routes.zone_count(route)
  if route ~= "Dream" then return 4 end
  local n = ItemManager and ItemManager.settings
    and tonumber(ItemManager.settings["dream_region_count_actual"])
  return n or Routes.DREAM_MAX_REGIONS
end

-- True past the route's last zone this seed. Only Dream gets there: DreamDiveTweaks' endless
-- mode (offered on the Dream victory screen) keeps the dive going beyond the configured region
-- count. Those regions are open (no route-lock kill) but send no checks -- none exist for them.
function Routes.past_last_zone(route, zone_index)
  return route ~= nil and zone_index ~= nil and zone_index > Routes.zone_count(route)
end

-- Returns route_name, zone_index for the current room, or nil if not on a route
-- (hub, Chaos/Anomaly/secret biomes, etc.).
-- Dream Dive (zerp's DreamDiveTweaks-extended Hypnos postgame content): checked BEFORE the
-- normal RoomSetName lookup below, since a Dream room still carries a REAL vanilla biome
-- letter (whatever DreamDiveTweaks randomized into this region slot) that would otherwise
-- misroute it as a normal Underworld/Surface room. The region "zone" index is read directly
-- from game.CurrentRun.EnteredBiomes (DreamDiveTweaks' own region-slot counter) rather than
-- tracked separately in APState -- slot POSITION is what our design keys off (see
-- project_dream_dive_feature_design memory), and this is the single source of truth for it,
-- already maintained by the game/DreamDiveTweaks itself.
-- NO +1 here (fixed 8/6): vanilla RoomLogic.lua increments CurrentRun.EnteredBiomes the moment
-- a BiomeStartRoom loads (IncrementTableValue, inside the native StartRoom this mod's StartRoom
-- wrap calls via base() BEFORE any of our Routes.current() callers run) -- so EnteredBiomes is
-- ALREADY the 1-based "region I'm currently standing in" index by the time anything here reads
-- it, exactly like F/G/H/I are already 1-4 for the other routes. Confirmed against the game's
-- own native indexing, RoomLogic.lua:3295 `unit.DreamBiomeData[currentRun.EnteredBiomes]` (no
-- +1). The old +1 made the very first Dream region read as zone 2, so route_zone_unlocked's
-- "have >= (zone-1)+offset" check (reload.lua StartRoom) failed on a fresh 0-Progressive-Dream
-- start and killed the player the instant they entered their first region -- and separately
-- miscalibrated EnemySanity.scale_unit/scale_encounter's DreamBiomeData lookups by one level.
function Routes.dream_current()
  local run = game.CurrentRun
  if not (run and run.IsDreamRun) then return nil end
  return "Dream", (run.EnteredBiomes or 0)
end

-- The room set a room really belongs to for routing: our miniboss-shuffle host stamp, then
-- zerp-NPCRoomRandomizer's borrow key, then the room's own RoomSetName.
local function routing_set(room)
  return room and (room.AP_HostRoomSet
    or room["zerp-NPCRoomRandomizerCurrentBiome"] or room.RoomSetName)
end

-- The room-set code (biome letter, or Zagreus' Journey's biome word) the current room routes as,
-- or nil. Shared by Routes.current and the ChooseNextRoomData crash guard.
function Routes.current_room_set()
  local run = game.CurrentRun
  local room = run and run.CurrentRoom
  -- The zerp-NPCRoomRandomizer dependency (replaced our own homegrown static-helper-room swap --
  -- see [[project_helper_npcs_any_location]]) borrows one story NPC's room to stand in for
  -- another's door the same way ours used to, and tracks the REAL biome that borrow is standing
  -- in for on its own per-instance key (confirmed via its ready.lua: `_PLUGIN.guid ..
  -- "CurrentBiome"`, guid == its manifest FullName). Read that instead of the borrowed room's own
  -- native RoomSetName (e.g. "N" for a Medea-shaped room actually standing in for an Underworld
  -- door) -- same reasoning our own removed AP_RealRoomSetName used to cover.
  -- AP_HostRoomSet is stamped by MinibossRooms.swap_for when the miniboss ROOM shuffle drops a
  -- foreign arena into this run (Charybdis' Oceanus room appearing partway through Erebus). The
  -- room's own RoomSetName is "O" there, but the player never left the Underworld -- the run is
  -- still routing through Erebus (ForceNextRoomSet keeps it that way). Every AP system that keys
  -- off the route reads through here, so without this one room would score against the wrong
  -- route, count toward the wrong zone's room checks, and take the wrong Dream tier. Checked
  -- FIRST, ahead of zerp's own borrow key, because a swapped miniboss room is ours outright --
  -- zerp only ever borrows ordinary story/NPC rooms, so the two can't both apply.
  local code = routing_set(room)
  -- Chaos Gate secret rooms (RoomDataChaos.lua, RoomSetName "Chaos") and the Asphodel Anomaly
  -- detour (RoomDataAnomaly.lua, RoomSetName "Anomaly") don't carry a routable RoomSetName of
  -- their own -- both set UsePreviousRoomSet instead, and the installed game resolves that
  -- via GetPreviousRoom(CurrentRun).RoomSetName. Resolve through the room they were entered from
  -- -- through the same routing stamps, so a Chaos gate taken out of a swapped miniboss arena
  -- routes as the host biome, not the arena's native one.
  if room and room.UsePreviousRoomSet and game.GetPreviousRoom then
    local ok, prevRoom = pcall(game.GetPreviousRoom, run)
    if ok and prevRoom and routing_set(prevRoom) then
      code = routing_set(prevRoom)
    end
  end
  return code
end

-- The route + zone the current room's BIOME belongs to, whatever kind of run it's in. Same as
-- Routes.current() on an ordinary run. On a Dream Dive it sees through the region overlay to
-- the real biome DreamDiveTweaks dealt into this region slot (Oceanus is still Underworld zone
-- 2 there) -- which is what identifies the region's boss, the one thing Dream's own
-- region-slot numbering can't. nil off-route.
function Routes.biome_current()
  local run = game.CurrentRun
  local code = Routes.current_room_set()
  local info = code and Routes.ROOMSET[code]
  if not info then return nil end
  -- The word-keyed roomsets belong to Zagreus' Journey, and that mod flags its own runs.
  -- Require the flag so a future vanilla RoomSetName reusing a generic word (especially
  -- "Surface") can never misroute a vanilla run onto Nightmare. Letter codes are vanilla.
  -- A dive is exempt: whether Zagreus' Journey raises that flag for a biome it lends to one
  -- is its own business, and the only word-keyed rooms a dive can deal are its biomes.
  if info[1] == "Nightmare" and not (run and (run.ModsNikkelMHadesBiomesIsModdedRun or run.IsDreamRun)) then
    return nil
  end
  return info[1], info[2]
end

function Routes.current()
  local dreamRoute, dreamZone = Routes.dream_current()
  if dreamRoute then return dreamRoute, dreamZone end
  return Routes.biome_current()
end

-- Route + zone for a room that may not be the current one yet. SetupEncounter builds the NEXT
-- room's encounter while the player is still standing in this one, so Routes.current() there
-- answers for the room being left -- one zone short for a biome's first room. Falls back to
-- Routes.current() whenever the room can't answer for itself (Chaos/Anomaly borrow the previous
-- room's set; a Zagreus' Journey room outside a ZJ run).
function Routes.for_room(room)
  local run = game.CurrentRun
  if type(room) ~= "table" or not run or room == run.CurrentRoom then return Routes.current() end
  if run.IsDreamRun then
    -- EnteredBiomes only ticks up once a BiomeStartRoom has loaded (RoomLogic.lua:1281).
    local zone = run.EnteredBiomes or 0
    if room.BiomeStartRoom then zone = zone + 1 end
    return "Dream", zone
  end
  if room.UsePreviousRoomSet then return Routes.current() end
  local code = routing_set(room)
  local info = code and Routes.ROOMSET[code]
  if not info or not info[2] then return Routes.current() end
  if info[1] == "Nightmare" and not run.ModsNikkelMHadesBiomesIsModdedRun then return Routes.current() end
  return info[1], info[2]
end
