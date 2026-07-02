# Shared definitions for the two routes (Underworld and Surface). Both are clean
# 4-zone paths, so Locations/Regions/Rules parameterize over this table.

UNDERWORLD = "Underworld"
SURFACE = "Surface"

# Datapackage maximum depth tracked per route in the room-based location systems.
# (A full Hades 2 run is ~40 rooms; 60 leaves headroom so the ids stay stable.)
# MAX_ROOMS is the id ceiling for the datapackage; each route's actual room-check
# count ("room_count" below) must stay <= MAX_ROOMS.
MAX_ROOMS = 60
# Per-weapon room locations reserve this many ids per weapon, per route.
WEAPON_ROOM_STRIDE = 100

ROUTES = {
    UNDERWORLD: {
        "zones": ["Erebus", "Oceanus", "Fields of Mourning", "Tartarus"],
        "bosses": ["Hecate", "Scylla", "Cerberus", "Chronos"],
        "score_prefix": "Underworld Score",      # point-based check-name prefix
        "room_prefix": "Underworld Room",        # room-based check-name prefix
        "score_id_base": 0,                      # point ids: base + 0..999
        "room_id_base": 7000,                    # room ids: base + 7000..7000+MAX_ROOMS
        "weapon_room_id_base": 10000,            # per-weapon ids: base + 10000 + weapon*stride + depth
        "room_count": 50,                        # room-based checks for this route (no longer a YAML option)
        "progressive": "Progressive Underworld",
        "final_boss": "Chronos",
    },
    SURFACE: {
        "zones": ["City of Ephyra", "Rift of Thessaly", "Mount Olympus", "The Summit"],
        "bosses": ["Cyclops", "Eris", "Prometheus", "Typhon"],
        "score_prefix": "Surface Score",
        "room_prefix": "Surface Room",
        "score_id_base": 2000,                   # point ids: base + 2000..2999
        "room_id_base": 8000,                    # room ids: base + 8000..8000+MAX_ROOMS
        "weapon_room_id_base": 20000,            # per-weapon ids: base + 20000 + weapon*stride + depth
        "room_count": 50,                        # room-based checks for this route (no longer a YAML option)
        "progressive": "Progressive Surface",
        "final_boss": "Typhon",
    },
}

ROUTE_NAMES = [UNDERWORLD, SURFACE]

# NPCs who are only ever encountered on one route (Known Bugs/"Logic is all out of
# whack"). Their "<NPC> Keepsake" and "Met <NPC>" locations only exist in the per-seed
# table when that route is active (see Locations._route_locked); Rules.py reuses this to
# gate reachability once the location *does* exist. Athena is NOT here even though she's
# Surface-only lore-wise: she has an alternate access path (holding her keepsake item)
# that keeps her reachable on Underworld-only seeds too, so her location must stay in the
# table -- see Rules.py's Athena handling.
NPC_ROUTE_LOCK = {
    "Arachne": UNDERWORLD, "Artemis": UNDERWORLD, "Narcissus": UNDERWORLD, "Echo": UNDERWORLD,
    "Hades": UNDERWORLD,
    "Heracles": SURFACE, "Medea": SURFACE, "Circe": SURFACE, "Icarus": SURFACE,
    "Eris": SURFACE, "Dionysus": SURFACE,
}

# The route(s) a given goal value forces to be included (so the goal stays reachable
# even if the player excluded that route). goal: 0=chronos, 1=typhon,
# 2=chronos_or_typhon, 3=chronos_and_typhon. "or" forces nothing (whichever route the
# player kept satisfies it); "and" forces both.
GOAL_REQUIRED_ROUTES = {
    0: [UNDERWORLD],
    1: [SURFACE],
    2: [],
    3: [UNDERWORLD, SURFACE],
}


def active_routes(options) -> list:
    """The routes actually generated for this seed: the player's included_routes choice,
    plus any route the goal forces in (so the goal is always reachable)."""
    included = options.included_routes.value
    if included == 1:
        routes = {UNDERWORLD}
    elif included == 2:
        routes = {SURFACE}
    else:
        routes = {UNDERWORLD, SURFACE}
    for route in GOAL_REQUIRED_ROUTES.get(options.goal.value, []):
        routes.add(route)
    return [route for route in ROUTE_NAMES if route in routes]


def boss_event(boss: str) -> str:
    return "Beat " + boss


def boss_victory(boss: str) -> str:
    return boss + " Victory"
