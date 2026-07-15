# Shared definitions for the three routes (Underworld, Surface, Nightmare). All are clean
# 4-zone paths, so Locations/Regions/Rules parameterize over this table.

UNDERWORLD = "Underworld"
SURFACE = "Surface"
NIGHTMARE = "Nightmare"

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
    NIGHTMARE: {
        # Hades 1's original route, ported into Hades II by the third-party "Zagreus'
        # Journey" mod (opt-in, see Options.IncludeNightmare -- default off since it needs that
        # mod installed). Zone 0's boss is a random pick of one of the three Furies; zone 2's
        # bosses (Theseus & Asterius) are fought together but tracked as separate enemy/NPC
        # checks -- see Locations.py/Rules.py for how those are handled around this shared
        # "bosses" list (which only drives the single zone-clear event per zone).
        # "Tartarus" is disambiguated to "Tartarus (Nightmare)": Hades II's own Underworld
        # route already has a zone literally named "Tartarus" (its 4th zone) -- AP regions
        # must have a globally unique name per player, so an exact duplicate would silently
        # collide (two Region objects sharing one name/entrance-cache key). The other 3
        # zone names (Asphodel/Elysium/Styx) don't collide with anything existing.
        "zones": ["Tartarus (Nightmare)", "Asphodel", "Elysium", "Styx"],
        "bosses": ["The Furies", "Bone Hydra", "Theseus and Asterius", "Hades"],
        "score_prefix": "Nightmare Score",
        "room_prefix": "Nightmare Room",
        "score_id_base": 4000,                   # point ids: base + 4000..4999
        "room_id_base": 8500,                    # room ids: base + 8500..8500+MAX_ROOMS (slots up to +479)
        "weapon_room_id_base": 40000,            # per-weapon ids: base + 40000 + weapon*stride + depth
        "room_count": 50,
        "progressive": "Progressive Nightmare",
        "final_boss": "Hades",
    },
}

ROUTE_NAMES = [UNDERWORLD, SURFACE, NIGHTMARE]

# NPCs who are only ever encountered on one route (Known Bugs/"Logic is all out of
# whack"). Their "<NPC> Keepsake" and "Met <NPC>" locations only exist in the per-seed
# table when that route is active (see Locations._route_locked); Rules.py reuses this to
# gate reachability once the location *does* exist. Athena is NOT here even though she's
# Surface-only lore-wise: she has an alternate access path (holding her keepsake item)
# that keeps her reachable on Underworld-only seeds too, so her location must stay in the
# table -- see Rules.py's Athena handling. Hades is NOT here either: see
# NPC_MULTI_ROUTE_LOCK below. Megaera is NOT here either -- she's a route boss, not
# Crossroads cast, so her "Met Megaera" gating comes from her NPC_BOSS_MEET zone tuple
# instead (Locations.py), same as "Megaera Defeated". Thanatos/Orpheus/Achilles still have
# no locations at all right now (Locations.KEEPSAKE_NO_LOCATION / NPC_NO_MEET).
NPC_ROUTE_LOCK = {
    "Arachne": UNDERWORLD, "Artemis": UNDERWORLD, "Narcissus": UNDERWORLD, "Echo": UNDERWORLD,
    "Heracles": SURFACE, "Medea": SURFACE, "Circe": SURFACE, "Icarus": SURFACE,
    "Eris": SURFACE, "Dionysus": SURFACE,
    # Nightmare keepsake-giving cast (zannc-SharedKeepsakePort).
    "Sisyphus": NIGHTMARE, "Eurydice": NIGHTMARE, "Patroclus": NIGHTMARE,
}

# NPCs meetable via more than one route, where the location should exist (and be
# reachable) if ANY listed route is active this seed -- not just one specific route.
# "Hades" is met either as the Underworld's Jeweled Pom keepsake-giver (deep Underworld,
# zone 3) or by reaching the Nightmare final-boss zone (zone 3); one "Met Hades" location,
# whichever the player reaches first sends it (see Rules._set_hades_met_rule and the
# SHARED_ENEMY_ZONES "any of these regions" pattern this mirrors).
NPC_MULTI_ROUTE_LOCK = {
    "Hades": (UNDERWORLD, NIGHTMARE),
}

# The bosses whose defeat can be part of the Goal, and (when it's a route's final boss)
# which route that is. "zagreus" maps to no route -- he's a secret superboss reachable via
# either route's zone index 1, not tied to a specific route's zone chain.
GOAL_BOSSES = ["chronos", "typhon", "hades", "zagreus"]
_BOSS_ROUTES = {"chronos": UNDERWORLD, "typhon": SURFACE, "hades": NIGHTMARE}

ALL_SELECTED = 0
ANY_SELECTED = 1


def _goal_toggle(options, boss: str) -> bool:
    return bool(getattr(options, "goal_requires_" + boss))


def _goal_forced_routes(options) -> list:
    """The route(s) the current Goal forces to be included (so the goal stays reachable
    even if the player excluded that route). goal_mode=any_selected forces nothing (whichever
    route the player kept satisfies it, as long as at least one toggled-on boss's route -- or
    zagreus, tied to no route -- is actually included); goal_mode=all_selected forces every
    route named by a toggled-on boss."""
    if options.goal_mode.value == ANY_SELECTED:
        return []
    return [route for boss, route in _BOSS_ROUTES.items()
            if _goal_toggle(options, boss)]


def active_routes(options) -> list:
    """The routes actually generated for this seed: the player's include_* toggles, plus any
    route the goal forces in (so the goal is always reachable)."""
    routes = set()
    if options.include_underworld:
        routes.add(UNDERWORLD)
    if options.include_surface:
        routes.add(SURFACE)
    if options.include_nightmare:
        routes.add(NIGHTMARE)
    for route in _goal_forced_routes(options):
        routes.add(route)
    return [route for route in ROUTE_NAMES if route in routes]


def goal_includes(options, boss: str) -> bool:
    """Whether `boss` ("chronos"/"typhon"/"hades"/"zagreus") is part of the active goal."""
    return _goal_toggle(options, boss)


def boss_event(boss: str) -> str:
    return "Beat " + boss


def boss_victory(boss: str) -> str:
    return boss + " Victory"
