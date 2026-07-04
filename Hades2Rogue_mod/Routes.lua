---@diagnostic disable: lowercase-global
-- Routes.lua — maps the game's biome code (CurrentRun.CurrentRoom.RoomSetName) to
-- our route + zone index, so the mod knows whether a run is Underworld or Surface.
-- Mapping (confirmed from the game's RoomData<code>.lua files):
--   Underworld: F=Erebus(1) G=Oceanus(2) H=Fields of Mourning(3) I=Tartarus(4)
--   Surface:    N=City of Ephyra(1) O=Rift of Thessaly(2) P=Mount Olympus(3) Q=The Summit(4)

Routes = Routes or {}

Routes.ROOMSET = {
  F = { "Underworld", 1 }, G = { "Underworld", 2 }, H = { "Underworld", 3 }, I = { "Underworld", 4 },
  N = { "Surface", 1 },    O = { "Surface", 2 },    P = { "Surface", 3 },    Q = { "Surface", 4 },
}

-- Check-name prefixes per route (must match the Python world's location names).
-- SCORE_PREFIX = point_based system; ROOM_PREFIX = room_based / per_weapon_room_based.
Routes.SCORE_PREFIX = { Underworld = "Underworld Score", Surface = "Surface Score" }
Routes.ROOM_PREFIX = { Underworld = "Underworld Room", Surface = "Surface Room" }
-- separate_checks=combine_pools room pool: route-agnostic, keyed on depth only ("Room NNNN").
Routes.COMBINED_ROOM_PREFIX = "Room"

-- Returns route_name, zone_index for the current room, or nil if not on a route
-- (hub, Chaos/Anomaly/secret biomes, etc.).
function Routes.current()
  local run = game.CurrentRun
  local room = run and run.CurrentRoom
  local code = room and room.RoomSetName
  local info = code and Routes.ROOMSET[code]
  if not info then return nil end
  return info[1], info[2]
end
