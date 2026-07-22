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
-- SCORE_PREFIX = point_based system; ROOM_PREFIX = room_based / per_weapon_room_based.
Routes.SCORE_PREFIX = { Underworld = "Underworld Score", Surface = "Surface Score", Nightmare = "Nightmare Score" }
Routes.ROOM_PREFIX = { Underworld = "Underworld Room", Surface = "Surface Room", Nightmare = "Nightmare Room" }
-- separate_checks=combine_pools room pool: route-agnostic, keyed on depth only ("Room NNNN").
Routes.COMBINED_ROOM_PREFIX = "Room"
-- separate_checks=combine_pools point pool: route-agnostic ("Score NNNN"). COMBINED_SCORE_KEY
-- stands in for a route name wherever a score pool is keyed (SCORE_PREFIX, score_limit_for,
-- is_score_checked), so the shared pool flows through the same code as a per-route one.
Routes.COMBINED_SCORE_KEY = "Combined"
Routes.SCORE_PREFIX[Routes.COMBINED_SCORE_KEY] = "Score"

-- Returns route_name, zone_index for the current room, or nil if not on a route
-- (hub, Chaos/Anomaly/secret biomes, etc.).
function Routes.current()
  local run = game.CurrentRun
  local room = run and run.CurrentRoom
  -- The zerp-NPCRoomRandomizer dependency (replaced our own homegrown static-helper-room swap --
  -- see [[project_helper_npcs_any_location]]) borrows one story NPC's room to stand in for
  -- another's door the same way ours used to, and tracks the REAL biome that borrow is standing
  -- in for on its own per-instance key (confirmed via its ready.lua: `_PLUGIN.guid ..
  -- "CurrentBiome"`, guid == its manifest FullName). Read that instead of the borrowed room's own
  -- native RoomSetName (e.g. "N" for a Medea-shaped room actually standing in for an Underworld
  -- door) -- same reasoning our own removed AP_RealRoomSetName used to cover.
  local code = room and (room["zerp-NPCRoomRandomizerCurrentBiome"] or room.RoomSetName)
  local info = code and Routes.ROOMSET[code]
  if not info then return nil end
  -- The word-keyed roomsets belong to Zagreus' Journey, and that mod flags its own runs.
  -- Require the flag so a future vanilla RoomSetName reusing a generic word (especially
  -- "Surface") can never misroute a vanilla run onto Nightmare. Letter codes are vanilla.
  if info[1] == "Nightmare" and not (run and run.ModsNikkelMHadesBiomesIsModdedRun) then
    return nil
  end
  return info[1], info[2]
end
