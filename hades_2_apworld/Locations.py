from BaseClasses import Location

from .Routes import ROUTES, ROUTE_NAMES, UNDERWORLD, SURFACE, MAX_ROOMS, \
    WEAPON_ROOM_STRIDE, boss_event, active_routes
from .Items import keepsake_titles, KEEPSAKE_NO_LOCATION, WEAPON_SHORT_NAMES, KEEPSAKE_NPC

hades2_base_location_id = 1

# ID layout (offsets from hades2_base_location_id), per route:
#   Underworld point checks:  0    .. 999      Surface point checks:  2000 .. 2999
#   Weapon-unlock checks:     4000 .. 4005
#   Keepsake unlock checks:   6100 .. 6132
#   Underworld room checks:   7000 .. 7000+MAX Surface room checks:   8000 .. 8000+MAX
#   Underworld per-weapon:    10000 + weapon*WEAPON_ROOM_STRIDE + depth
#   Surface per-weapon:       20000 + weapon*WEAPON_ROOM_STRIDE + depth
#   Combined room checks:     9000 .. 9000+MAX  (separate_checks=combine_pools)
#   Combined per-weapon:      60000 + weapon*WEAPON_ROOM_STRIDE + depth
weapon_id_base = 4000

# Location-system option values (match Options.LocationSystem).
POINT_BASED = 0
ROOM_BASED = 1
PER_WEAPON_ROOM_BASED = 2

# separate_checks option values (match Options.SeparateChecks).
SPLIT_POOLS = 0
COMBINE_POOLS = 1

# --- Location auto-scaling (room systems) ------------------------------------
# When a seed has more items than locations, the room-based systems can't just raise a
# number (a run is only ~50 rooms), so instead each room depth grants several checks. Each
# extra check is a "slot" 0..m-1 living in a disjoint id block, so ids stay stable across
# seeds. MAX_LOCATION_MULTIPLIER caps m and is what the datapackage reserves ids for; the
# slot strides below must keep every slot inside its route's reserved id range (see the ID
# layout map above): plain rooms get MAX_ROOMS ids per slot, per-weapon rooms get 1000.
MAX_LOCATION_MULTIPLIER = 8
WEAPON_ROOM_SLOT_STRIDE = 1000

# Combined (separate_checks=combine_pools) room pools use route-agnostic names ("Room NNNN")
# in their own id space, distinct from the per-route "Underworld Room NNNN" ids. Combined
# means a single shared pool keyed only on room DEPTH: clearing depth N the first time on
# EITHER route earns it. (Combined point_based instead keeps per-route names and just
# splits score_rewards_amount across the routes -- see _score_count_for.)
COMBINED_ROOM_PREFIX = "Room"
combined_room_id_base = 9000           # "Room NNNN"            -> base + (depth-1)
combined_weapon_id_base = 60000        # "Room NNNN <Weapon>"   -> base + weapon*stride + (depth-1)

# Per-route, per-seed zone tables. Each maps a location name -> id (or None for
# the boss-event location). Rebuilt by setup_location_table_with_settings().
# Structured as zone_tables[route][zone_name] = { location: id_or_None }.
zone_tables = {}


def _pad(number: int) -> str:
    text = str(number)
    while len(text) < 4:
        text = "0" + text
    return text


def _room_name(prefix: str, depth: int, slot: int, weapon: str = None) -> str:
    """Build a room / per-weapon check name. slot 0 keeps the original name (backward
    compatible with pre-scaling seeds); higher slots append ' +k'. Any weapon stays the
    LAST token so the rules' weapon parsing (rsplit / last-token) keeps working."""
    name = prefix + " " + _pad(depth)
    if slot > 0:
        name += " +" + str(slot)
    if weapon:
        name += " " + weapon
    return name


def _empty_zone_tables() -> dict:
    tables = {}
    for route in ROUTE_NAMES:
        tables[route] = {}
        for i, zone in enumerate(ROUTES[route]["zones"]):
            # Each zone seeds with its boss-defeat event location.
            boss = ROUTES[route]["bosses"][i]
            tables[route][zone] = {boss_event(boss): None}
    return tables


def clear_tables() -> None:
    global zone_tables
    zone_tables = _empty_zone_tables()


def _zone_bounds(count: int) -> list:
    """Split `count` checks into 4 zone-aligned ranges; the first zone takes the
    remainder so totals always add up."""
    quarter = count // 4
    first = count - 3 * quarter
    return [0, first, first + quarter, first + 2 * quarter, count]


def fill_score_checks(route: str, count: int) -> None:
    """point_based: distribute `count` score checks for a route across its 4 zones."""
    prefix = ROUTES[route]["score_prefix"]
    id_base = hades2_base_location_id + ROUTES[route]["score_id_base"]
    zones = ROUTES[route]["zones"]
    bounds = _zone_bounds(count)
    for z in range(4):
        zone = zones[z]
        for i in range(bounds[z], bounds[z + 1]):
            zone_tables[route][zone][prefix + " " + _pad(i + 1)] = id_base + i


def fill_room_checks(route: str, count: int, multiplier: int = 1) -> None:
    """room_based: one check per room-depth (1..count), depth aligned to its zone. With
    multiplier m, each depth gets m checks (slots 0..m-1) in disjoint id blocks."""
    prefix = ROUTES[route]["room_prefix"]
    id_base = hades2_base_location_id + ROUTES[route]["room_id_base"]
    zones = ROUTES[route]["zones"]
    bounds = _zone_bounds(count)
    for slot in range(multiplier):
        for z in range(4):
            zone = zones[z]
            for i in range(bounds[z], bounds[z + 1]):
                zone_tables[route][zone][_room_name(prefix, i + 1, slot)] = \
                    id_base + slot * MAX_ROOMS + i


def fill_weapon_room_checks(route: str, count: int, multiplier: int = 1) -> None:
    """per_weapon_room_based: one check per (room-depth, weapon), depth aligned to zone.
    With multiplier m, each (depth, weapon) gets m checks in disjoint id blocks."""
    prefix = ROUTES[route]["room_prefix"]
    id_base = hades2_base_location_id + ROUTES[route]["weapon_room_id_base"]
    zones = ROUTES[route]["zones"]
    bounds = _zone_bounds(count)
    for slot in range(multiplier):
        for w, weapon in enumerate(WEAPON_SHORT_NAMES):
            for z in range(4):
                zone = zones[z]
                for i in range(bounds[z], bounds[z + 1]):
                    zone_tables[route][zone][_room_name(prefix, i + 1, slot, weapon)] = \
                        id_base + slot * WEAPON_ROOM_SLOT_STRIDE + w * WEAPON_ROOM_STRIDE + i


def combine_active(options) -> bool:
    """combine_pools only does anything when both routes are actually generated; with a
    single route there's nothing to combine, so it behaves like split_pools."""
    return options.separate_checks.value == COMBINE_POOLS and len(active_routes(options)) > 1


def _combined_room_count() -> int:
    """Size of the shared (combined) room pool. Both routes use the same room_count, so a
    single shared pool of that size covers a run's depth either way."""
    return ROUTES[UNDERWORLD]["room_count"]


def _score_count_for(route: str, options) -> int:
    """point_based score-check count for a route. split_pools: each route gets the full
    score_rewards_amount. combine_pools: the total is divided across the active routes
    (200 -> 100 + 100), the first active route taking any remainder."""
    total = options.score_rewards_amount.value
    if not combine_active(options):
        return total
    routes = active_routes(options)
    n = len(routes)
    return total // n + (1 if routes.index(route) < (total % n) else 0)


def combined_room_table(options, multiplier: int = 1) -> dict:
    """The shared room pool's locations (name -> id) for this seed: route-agnostic
    "Room NNNN" (room_based) or "Room NNNN <Weapon>" (per_weapon_room_based). With
    multiplier m, each depth (and weapon) gets m checks in disjoint id blocks."""
    system = options.location_system.value
    count = _combined_room_count()
    table = {}
    if system == ROOM_BASED:
        for slot in range(multiplier):
            for i in range(count):
                table[_room_name(COMBINED_ROOM_PREFIX, i + 1, slot)] = \
                    hades2_base_location_id + combined_room_id_base + slot * MAX_ROOMS + i
    elif system == PER_WEAPON_ROOM_BASED:
        for slot in range(multiplier):
            for w, weapon in enumerate(WEAPON_SHORT_NAMES):
                for i in range(count):
                    table[_room_name(COMBINED_ROOM_PREFIX, i + 1, slot, weapon)] = \
                        hades2_base_location_id + combined_weapon_id_base \
                        + slot * WEAPON_ROOM_SLOT_STRIDE + w * WEAPON_ROOM_STRIDE + i
    return table


def fill_route_checks(route: str, options, multiplier: int = 1) -> None:
    """Fill a route's zone tables according to the chosen location system. Under
    combine_pools the room systems are NOT filled per-route here (they live in the shared
    "Combined Rooms" region instead); only the per-route boss events remain."""
    system = options.location_system.value
    if system in (ROOM_BASED, PER_WEAPON_ROOM_BASED):
        if combine_active(options):
            return
        if system == ROOM_BASED:
            fill_room_checks(route, ROUTES[route]["room_count"], multiplier)
        else:
            fill_weapon_room_checks(route, ROUTES[route]["room_count"], multiplier)
    else:
        fill_score_checks(route, _score_count_for(route, options))


# (Weapon-unlock locations removed: weapons are still shuffled as items, but buying them
# at the Crossroads weapon shop is blocked outright and earns no check, so players never
# need to grind Silver / mining tools to obtain them.)

# (Incantation checks removed: incantationsanity was dropped, and the Cauldron is blocked
# entirely in-game. Surface access still comes from the Surface Access / Penalty Cure items.)

# Keepsake unlock checks (keepsakesanity, randomized/progressive). Gifting an NPC
# enough Nectar sends the check. Chronos's "Time Piece" is intentionally NOT a location
# (unreachable here), though it still exists as an item.
# Aspects and Familiars are items-only (no check locations) by design.
keepsake_location_base = hades2_base_location_id + 6100
location_keepsakes = {
    f"{KEEPSAKE_NPC[title]} Keepsake": keepsake_location_base + i
    for i, title in enumerate(keepsake_titles)
    if title not in KEEPSAKE_NO_LOCATION
}


# --- Enemy locations (enemy_locations) ----------------------------------------
# First-time defeat checks, one per enemy type. Each enemy is mapped to the route + zone
# (layer) it appears in, so the location lives in that zone's region and is reachable
# exactly when that zone is. (Boss enemies are listed here as distinct checks from the
# "Beat <Boss>" route events.) Order is fixed so ids stay stable.
ENEMY_LAYERS = {
    UNDERWORLD: [
        ["Casket", "Lanthorn", "Sister of the Dead", "Spindle", "Wailer", "Wastrel",
         "Whisper", "Thorn-Weeper", "Root-Stalker", "Shadow-Spiller", "Headmistress Hecate",
         "Master-Slicer", "Dread-Wailer"],
        # Zone 2 (Oceanus) + the Asphodel "Anomaly" detour foes. Asphodel only becomes reachable
        # once Oceanus is your second area, so its enemies share Oceanus's sphere (Test Run 5
        # #13). Display names from HelpText: SpreadShotUnit=Wretched Witch, BloodlessNaked=Bloodless,
        # BloodlessBerserker=Bone-Raker, BloodlessWaveFist=Wave-Maker, BloodlessGrenadier=
        # Inferno-Bomber, BloodlessSelfDestruct=Slam-Dancer, BloodlessPitcher=Burn-Flinger.
        ["Hippo", "Lurker", "Pinhead", "Sea-Serpent", "Shellback", "Sop-Spindle",
         "Wet-Whisper", "Wretched Pest", "Deep Serpent", "Hellifish", "King Vermin",
         "Scylla and the Sirens",
         "Wretched Witch", "Bloodless", "Bone-Raker", "Wave-Maker", "Inferno-Bomber",
         "Slam-Dancer", "Burn-Flinger"],
        ["Bawlder", "Blight-Shade", "Bloat-Shade", "Blood-Shade", "Canine", "Holeheart",
         "Lamia", "Lycaon", "Mourner", "Smacker", "Sorrow-Spiller", "Phantom",
         "Queen Lamia", "Brush-Stalker", "Infernal Beast"],
        ["Crawler", "Goldwraith", "Numbskull", "Sandskull", "Satyr Hoplite",
         "Satyr Supplicant", "Satyr Vierophant", "Tempus", "Wretched Thug", "Goldwrath",
         "Verminancer", "Wringer", "Chronos"],
    ],
    SURFACE: [
        ["Bronzebeak", "Cutthroat", "Eidolon", "Lubber", "Shambler", "Tombstone",
         "Satyr Champion", "Erymanthian Boar", "The Cyclops Polyphemus"],
        ["Anchor", "Blasket", "Boozer", "Droplet", "Harpy Talon", "Sea-Shambler",
         "Seesword", "Stickler", "Charybdis", "The Yargonaut", "Eris"],
        ["Auto-Forcer", "Auto-Seeker", "Auto-Watcher", "Harpy Raptor", "Satyr Goldpike",
         "Satyr Raider", "Satyr Sapper", "Sky-Dracon", "Snow-Shambler", "Mega-Dracon",
         "Talos", "Prometheus"],
        ["Eyesore", "Headstone", "Horror", "Land-Dracon", "Polyp", "Stalker",
         "Eye of Typhon", "Spawn of Typhon", "Tail of Typhon", "Twins of Typhon", "Typhon"],
    ],
}

enemy_location_base = hades2_base_location_id + 30000
location_enemies = {}          # name -> id (every enemy, both routes)
ENEMY_ROUTE = {}               # name -> route
ENEMY_BY_ZONE = {}             # (route, zone) -> [enemy names]
_enemy_index = 0
for _route in ROUTE_NAMES:
    for _zi, _layer in enumerate(ENEMY_LAYERS[_route]):
        _zone = ROUTES[_route]["zones"][_zi]
        ENEMY_BY_ZONE.setdefault((_route, _zone), [])
        for _name in _layer:
            _loc = f"{_name} Defeated"
            location_enemies[_loc] = enemy_location_base + _enemy_index
            ENEMY_ROUTE[_loc] = _route
            ENEMY_BY_ZONE[(_route, _zone)].append(_loc)
            _enemy_index += 1


def enemy_locations_for(route: str) -> dict:
    return {name: location_enemies[name]
            for name, r in ENEMY_ROUTE.items() if r == route}


# --- NPC / "Met" locations (npc_locations) ------------------------------------
# Intro story beats and Crossroads meets are reachable from the start. Each route boss
# "Met" check lives in the boss's zone region, so it unlocks once that layer is reachable
# (mirroring the wishlist: Scylla at layer 2, Cerberus at layer 3, etc.).
NPC_INTRO = ["SHUSH Homer", "Find Hecate 1", "Find Hecate 2", "Find Hecate 3"]

# Bosses meet checks, keyed to the zone that gates them.
NPC_BOSS_MEET = [
    ("Met Hecate", UNDERWORLD, 0),
    ("Met Scylla", UNDERWORLD, 1),
    ("Met Cerberus", UNDERWORLD, 2),
    ("Met Chronos", UNDERWORLD, 3),
    ("Met Polyphemus", SURFACE, 0),
    ("Met Eris", SURFACE, 1),
    ("Met Prometheus", SURFACE, 2),
    ("Met Typhon", SURFACE, 3),
]
_NPC_BOSS_NAMES = {"Hecate", "Scylla", "Cerberus", "Chronos",
                   "Polyphemus", "Eris", "Prometheus", "Typhon"}

# Route bosses you meet regardless of which routes the seed generates, so their "Met" check
# must always exist and be reachable from the start instead of being gated behind their route's
# zone. Hecate mentors you at the Crossroads from the very first run, so a Surface-only seed
# (Underworld excluded) still meets her -- previously that fired a "Met Hecate" check for a
# location that was never generated ("Unknown location checked by game"). NOT included: Eris --
# it's unconfirmed whether she appears off the Surface; until then she stays route-gated (the
# mod's send_first guard simply suppresses her meet when the Surface is excluded). Add "Eris"
# here (and "Met Eris" to the mod's ALWAYS_MET_BOSS) once confirmed.
ALWAYS_MET_BOSSES = {"Hecate"}
ALWAYS_MET_BOSS_LOCATIONS = {"Met " + boss for boss in ALWAYS_MET_BOSSES}

# NPCs who can't be met in normal Archipelago play, so their "Met <NPC>" check would be a
# dead location. Zagreus is only reachable through the scripted Elysium "memory" rescue, which
# the mod doesn't force open -- and his Calling Card keepsake is likewise item-only (see
# KEEPSAKE_NO_LOCATION), so he has no obtainable check at all.
NPC_NO_MEET = {"Zagreus"}

# The Crossroads cast: every keepsake-giving character who isn't a route boss (or otherwise
# unmeetable), plus a few meet-able NPCs who don't give keepsakes. Hypnos (Test Run 5 #5) wasn't
# in the keepsake cast, so "Met Hypnos" never existed; he's added here (met once he's awake).
NPC_EXTRA_CAST = ["Hypnos"]
NPC_CAST = [npc for npc in dict.fromkeys(KEEPSAKE_NPC.values())
            if npc not in _NPC_BOSS_NAMES and npc not in NPC_NO_MEET]
NPC_CAST += [npc for npc in NPC_EXTRA_CAST if npc not in NPC_CAST]

npc_location_base = hades2_base_location_id + 31000
location_npc_intro = {name: npc_location_base + i for i, name in enumerate(NPC_INTRO)}
location_npc_meet = {f"Met {npc}": npc_location_base + 100 + i
                     for i, npc in enumerate(NPC_CAST)}
location_npc_boss = {name: npc_location_base + 200 + i
                     for i, (name, _r, _z) in enumerate(NPC_BOSS_MEET)}
# Crossroads-resident NPC checks (reachable from the start): intro beats, the Crossroads cast,
# and any always-met boss (Hecate) whose "Met" lives in the hub rather than behind a route.
location_npc_crossroads = {**location_npc_intro, **location_npc_meet,
                           **{name: location_npc_boss[name] for name in ALWAYS_MET_BOSS_LOCATIONS}}

NPC_BOSS_BY_ZONE = {}          # (route, zone) -> [boss "Met" names]
for _name, _route, _zi in NPC_BOSS_MEET:
    if _name in ALWAYS_MET_BOSS_LOCATIONS:
        continue               # always met at the Crossroads; not gated behind its route's zone
    _zone = ROUTES[_route]["zones"][_zi]
    NPC_BOSS_BY_ZONE.setdefault((_route, _zone), []).append(_name)


def npc_boss_locations_for(route: str) -> dict:
    return {name: location_npc_boss[name]
            for name, r, _zi in NPC_BOSS_MEET if r == route}


# -----------------------------------------------------------------------------


def setup_location_table_with_settings(options, multiplier: int = 1) -> dict:
    """Build the flat active location table (name -> id) for this seed. multiplier scales
    the room-based check pools (see MAX_LOCATION_MULTIPLIER)."""
    clear_tables()
    for route in active_routes(options):
        fill_route_checks(route, options, multiplier)

    total = {}
    for route in active_routes(options):
        for zone, locs in zone_tables[route].items():
            total.update(locs)

    # combine_pools: the shared room pool's checks live outside the per-route zone tables.
    if combine_active(options) and options.location_system.value in (ROOM_BASED, PER_WEAPON_ROOM_BASED):
        total.update(combined_room_table(options, multiplier))

    # Keepsake checks exist in randomized (1) and progressive (2), not normal (0).
    if options.keepsakesanity.value != 0:
        total.update(location_keepsakes)

    # Enemy first-defeat checks, per active route.
    if options.enemy_locations:
        for route in active_routes(options):
            total.update(enemy_locations_for(route))

    # NPC "Met" checks: intro + Crossroads cast always, boss meets per active route.
    if options.npc_locations:
        total.update(location_npc_crossroads)
        for route in active_routes(options):
            total.update(npc_boss_locations_for(route))
    return total


def give_all_locations_table() -> dict:
    """Every location this world can define, for the AP datapackage (max counts across
    all routes and all location systems)."""
    clear_tables()
    for route in ROUTE_NAMES:
        fill_score_checks(route, 1000)
        fill_room_checks(route, MAX_ROOMS, MAX_LOCATION_MULTIPLIER)
        fill_weapon_room_checks(route, MAX_ROOMS, MAX_LOCATION_MULTIPLIER)
    table = {}
    for route in ROUTE_NAMES:
        for zone, locs in zone_tables[route].items():
            for name, loc_id in locs.items():
                if loc_id is not None:
                    table[name] = loc_id
    # Combined room pools (separate_checks=combine_pools), full depth range and every slot up
    # to MAX_LOCATION_MULTIPLIER, for stable ids across seeds.
    for slot in range(MAX_LOCATION_MULTIPLIER):
        for i in range(MAX_ROOMS):
            table[_room_name(COMBINED_ROOM_PREFIX, i + 1, slot)] = \
                hades2_base_location_id + combined_room_id_base + slot * MAX_ROOMS + i
        for w, weapon in enumerate(WEAPON_SHORT_NAMES):
            for i in range(MAX_ROOMS):
                table[_room_name(COMBINED_ROOM_PREFIX, i + 1, slot, weapon)] = \
                    hades2_base_location_id + combined_weapon_id_base \
                    + slot * WEAPON_ROOM_SLOT_STRIDE + w * WEAPON_ROOM_STRIDE + i
    table.update(location_keepsakes)
    table.update(location_enemies)
    table.update(location_npc_crossroads)
    table.update(location_npc_boss)
    return table


# --- Name groups --------------------------------------------------------------
location_name_groups = {
    "keepsakes": location_keepsakes.keys(),
    "enemies": location_enemies.keys(),
    "npcs": list(location_npc_crossroads) + list(location_npc_boss),
}


class Hades2Location(Location):
    game: str = "Hades 2"

    def __init__(self, player: int, name: str, address=None, parent=None):
        super(Hades2Location, self).__init__(player, name, address, parent)
        if address is None:
            self.event = True
            self.locked = True
