from typing import TYPE_CHECKING
from worlds.AutoWorld import LogicMixin
from worlds.generic.Rules import add_rule
from .Routes import ROUTES, SURFACE, UNDERWORLD, boss_victory, active_routes
from .Items import WEAPON_SHORT_NAMES, arcana_titles, keepsake_titles
from .Locations import combine_active, _score_count_for, _combined_room_count, \
    _zone_bounds

if TYPE_CHECKING:
    from . import Hades2World

# Weapons required to leave zones 1/2/3 of a route (pacing, like the old underworld).
ZONE_WEAPON_GATES = [2, 3, 5]
FINAL_WEAPONS = 6

# Location-system option values (match Options.LocationSystem / Locations.py).
POINT_BASED = 0
ROOM_BASED = 1
PER_WEAPON_ROOM_BASED = 2

# --- Logic.txt: "Room Based Logic (Soft)" ------------------------------------
# Power needed to leave each zone (reach the next boss / area). Index i is the gate on
# "Exit <zone[i]>": exiting zone 1 -> boss 2, zone 2 -> boss 3, zone 3 -> last area.
# "(if applicable)" - the grasp half only bites when GraspSanity is on, and the arcana
# half only when ArcanaSanity gates cards (the helpers below return a large number when
# the matching sanity is off, so those gates pass automatically).
ZONE_ARCANA_GATES = [4, 6, 8]
ZONE_GRASP_GATES = [1, 1, 2]

# --- Logic.txt: "Score Based - For Grasp and Arcana sanity (Soft)" -----------
# (point_based only) Cumulative share of a route's score checks, paired with the arcana
# count and grasp count needed to open that band: the first 15% are free, the next 15%
# need 2 arcana + 1 grasp, then 25% -> 4 arcana, 20% -> 8 arcana, and the last 25% need
# 10 arcana + 2 grasp. Each tuple is (upper percentile bound, arcana needed, grasp needed).
SCORE_POWER_TIERS = [
    (0.15, 0, 0),
    (0.30, 2, 1),
    (0.55, 4, 1),
    (0.75, 8, 1),
    (1.01, 10, 2),
]

# --- Logic.txt: "Keepsakes" --------------------------------------------------
# Keepsake check locations are named "<NPC> Keepsake" (see Locations.location_keepsakes).
# Soft keepsakes gate purely on how many keepsakes you've earned; the tier maps to a count
# threshold below. ("Schelemeus" in Logic.txt is Skelly.)
KEEPSAKE_SOFT_TIER = {
    # Tier 0: available from the start.
    "Hecate": 0, "Odysseus": 0, "Skelly": 0, "Dora": 0, "Nemesis": 0,
    "Apollo": 0, "Aphrodite": 0,
    # Tier 1: 4 keepsakes (or 1 Progressive Keepsake).
    "Charon": 1, "Eris": 1, "Hermes": 1, "Artemis": 1, "Selene": 1,
    "Demeter": 1, "Zeus": 1, "Poseidon": 1, "Hestia": 1, "Chaos": 1,
    # Tier 2: 8 keepsakes (or 2 Progressive Keepsake).
    "Hera": 2, "Hephaestus": 2, "Ares": 2,
}
KEEPSAKE_TIER_COUNT = {0: 0, 1: 4, 2: 8}

# Hard keepsakes: (route, area index, keepsake count) - require reaching that route's area
# AND owning enough keepsakes. When the route isn't in the seed, the area gate is dropped
# (so the location can't become unreachable) and only the count requirement remains.
KEEPSAKE_HARD = {
    "Arachne":   (UNDERWORLD, 0, 0),
    "Narcissus": (UNDERWORLD, 1, 4),
    "Echo":      (UNDERWORLD, 2, 8),
    "Heracles":  (SURFACE, 0, 8),
    "Medea":     (SURFACE, 0, 8),
    "Circe":     (SURFACE, 1, 10),
    "Icarus":    (SURFACE, 1, 10),
    "Athena":    (SURFACE, 2, 10),
    "Dionysus":  (SURFACE, 2, 10),
}
# Moros is special: his keepsake unlocks with the "Doomed Beckoning" incantation item.
KEEPSAKE_MOROS_ITEM = "Doomed Beckoning"

# Without the Surface Penalty Cure you can only reach a sliver of the Surface: in-game the
# curse walls you off after room 3 (the cure is locked behind meeting Athena), so the cure
# must turn up in that early sphere -- the first 3 surface rooms, a Crossroads NPC/god "Met"
# check, or an early keepsake -- all of which stay ungated below. Score systems keep the same
# proportion the original 5-room cap had (5 rooms <-> 6%), so 3 rooms <-> 3.6%.
SURFACE_NO_CURE_ROOM_DEPTH = 3
SURFACE_NO_CURE_SCORE_FRACTION = 0.036

# Item-name lists for the arcana/keepsake counters.
_ARCANA_ITEMS = [f"{title} Arcana" for title in arcana_titles]
_ARCANA_PROG_ITEMS = [f"Progressive {title} Arcana" for title in arcana_titles]


class Hades2Logic(LogicMixin):
    def _hades2_has_weapon(self, weapon_subfix: str, player: int, options) -> bool:
        # Weapons are always shuffled (the WeaponSanity toggle was removed): you have a
        # weapon if it's your starting weapon or you've received its unlock item.
        mapping = {
            "Staff": (0, "Staff Weapon Unlock Item"),
            "Blades": (1, "Blades Weapon Unlock Item"),
            "Flames": (2, "Flames Weapon Unlock Item"),
            "Axe": (3, "Axe Weapon Unlock Item"),
            "Skull": (4, "Skull Weapon Unlock Item"),
            "Coat": (5, "Coat Weapon Unlock Item"),
        }
        initial, item = mapping[weapon_subfix]
        # weapon_aspect_combine replaces the unlock item with "Progressive <Weapon>"
        # (the first copy unlocks the weapon), so accept either form here.
        return (options.initial_weapon == initial) or self.has(item, player) \
            or self.has("Progressive " + weapon_subfix, player)

    def _hades2_has_enough_weapons(self, player: int, options, amount: int) -> bool:
        count = 0
        for weapon in ("Staff", "Blades", "Flames", "Axe", "Skull", "Coat"):
            if self._hades2_has_weapon(weapon, player, options):
                count += 1
        return count >= amount

    def _hades2_arcana_count(self, player: int, options) -> int:
        """How many distinct Arcana cards are unlocked. Returns a large number when
        ArcanaSanity is off (cards are bought normally, so they don't gate anything)."""
        mode = options.arcanasanity.value
        if mode == 1:  # Arcana: one unlock item per card
            return sum(1 for name in _ARCANA_ITEMS if self.has(name, player))
        if mode == 2:  # Progressive_Arcana: first "Progressive <Card>" copy unlocks it
            return sum(1 for name in _ARCANA_PROG_ITEMS if self.has(name, player))
        return 99

    def _hades2_grasp_count(self, player: int, options) -> int:
        """How many Progressive Grasp items are owned. Returns a large number when grasp
        isn't a real resource (GraspSanity off, or 0 grasp per item), so grasp gates pass."""
        if not options.graspsanity or int(options.grasp_intervals) <= 0:
            return 99
        return self.count("Progressive Grasp", player)

    def _hades2_keepsake_count(self, player: int, options) -> int:
        """How many keepsakes have effectively been earned, for the Logic.txt thresholds.
        Randomized: count distinct keepsake items. Progressive: each Progressive Keepsake
        copy counts as 4 (1 copy ~ tier 1, 2 ~ tier 2, 3 ~ "all"). Normal keepsakes have
        no check locations, so this is never consulted there."""
        mode = options.keepsakesanity.value
        if mode == 2:
            return self.count("Progressive Keepsake", player) * 4
        if mode == 1:
            return sum(1 for title in keepsake_titles if self.has(title, player))
        return 99

    def _hades2_can_get_victory(self, player: int, options) -> bool:
        weapons = options.weapons_clears_needed.value
        chronos = (self.has("Chronos Victory", player)
                   and self._hades2_has_enough_weapons(player, options, weapons))
        typhon = (self.has("Typhon Victory", player)
                  and self._hades2_has_enough_weapons(player, options, weapons))
        goal = options.goal.value
        if goal == 1:
            return typhon
        if goal == 2:
            return chronos or typhon
        if goal == 3:
            return chronos and typhon
        return chronos  # goal == 0


# -----------------------------------------------------------------------------


def _grasp_cap(options) -> int:
    """How many Progressive Grasp exist, for clamping grasp requirements. A large number
    when grasp isn't a real resource (so grasp gates never bind)."""
    if not options.graspsanity or int(options.grasp_intervals) <= 0:
        return 99
    return int(options.grasp_count)


def set_rules(world: "Hades2World", player: int, options, route_offsets: dict,
              surface_access_via_progressive: bool = False) -> None:
    locked = bool(options.lock_routes)
    routes = active_routes(options)
    system = options.location_system.value
    grasp_cap = _grasp_cap(options)

    for route in routes:
        zones = ROUTES[route]["zones"]
        bosses = ROUTES[route]["bosses"]
        prog = ROUTES[route]["progressive"]
        offset = route_offsets[route]

        # Entering the route's first zone: needs `offset` route-progressives when locked.
        if locked:
            add_rule(world.get_entrance("Descend " + route, player),
                     lambda state, p=prog, o=offset: state.count(p, player) >= o)

        # Leaving zone i -> zone i+1: beat that zone's boss, own enough weapons, and
        # (when locked) have enough route-progressives to open the next gate.
        for i in range(len(zones) - 1):
            add_rule(world.get_entrance("Exit " + zones[i], player),
                     lambda state, b=bosses[i], w=ZONE_WEAPON_GATES[i]:
                         state.has(boss_victory(b), player)
                         and state._hades2_has_enough_weapons(player, options, w))
            # Logic.txt (Soft): reaching the next boss/area also needs enough Arcana and
            # Grasp. (The counters return a large number when the relevant sanity is off,
            # so those gates pass; the grasp requirement is clamped to how many Progressive
            # Grasp actually exist, so a small grasp_count can't make the goal impossible.)
            add_rule(world.get_entrance("Exit " + zones[i], player),
                     lambda state, a=ZONE_ARCANA_GATES[i], g=min(ZONE_GRASP_GATES[i], grasp_cap):
                         state._hades2_arcana_count(player, options) >= a
                         and state._hades2_grasp_count(player, options) >= g)
            if locked:
                add_rule(world.get_entrance("Exit " + zones[i], player),
                         lambda state, p=prog, need=i + 1 + offset: state.count(p, player) >= need)

        # The final boss requires all weapons.
        add_rule(world.get_location("Beat " + bosses[-1], player),
                 lambda state: state._hades2_has_enough_weapons(player, options, FINAL_WEAPONS))

    # combine_pools (room systems): the shared "Room NNNN" pool is gated by depth only —
    # each check is reachable once its depth's zone is reachable on EITHER route (plus the
    # weapon, for per_weapon). Handled separately since those checks aren't in zone regions.
    if combine_active(options) and system in (ROOM_BASED, PER_WEAPON_ROOM_BASED):
        _set_combined_room_rules(world, player, options, routes)
    # per_weapon_room_based (split_pools): each "<Room prefix> NNNN <Weapon>" check
    # additionally needs that specific weapon in hand.
    elif system == PER_WEAPON_ROOM_BASED:
        _set_per_weapon_rules(world, player, options, routes)

    # point_based: gate score checks by the Arcana/Grasp percentile bands (Logic.txt).
    if system == POINT_BASED:
        _set_score_power_rules(world, player, options, routes, grasp_cap)

    # The Surface route needs the Surface Access item to open the door. The Surface
    # Penalty Cure no longer gates entry: per Logic.txt you can play the early Surface
    # without it, but it's needed to push past the first few rooms (handled per-location).
    if SURFACE in routes:
        if surface_access_via_progressive:
            # No separate "Surface Access" item: the first Progressive Surface opens the door
            # (Test Run 5 #14), so entering the Surface needs 1 Progressive Surface.
            prog = ROUTES[SURFACE]["progressive"]
            add_rule(world.get_entrance("Descend Surface", player),
                     lambda state, p=prog: state.count(p, player) >= 1)
        else:
            add_rule(world.get_entrance("Descend Surface", player),
                     lambda state: state.has("Surface Access", player))
        _set_surface_cure_rules(world, player, options)

    # Keepsake unlock checks gate on keepsake count and (hard ones) area access.
    _set_keepsake_rules(world, player, options, routes)

    world.completion_condition[player] = lambda state: state._hades2_can_get_victory(player, options)


def _room_depth(name: str, prefix: str) -> int:
    """Depth of a room/score check from its name: '<prefix> NNNN [Weapon]' -> NNNN."""
    return int(name[len(prefix) + 1:].split(" ")[0])


def _score_power_requirement(percentile: float) -> tuple:
    """(arcana, grasp) needed for a score check at the given percentile of the route."""
    for upper, arcana, grasp in SCORE_POWER_TIERS:
        if percentile <= upper:
            return arcana, grasp
    return SCORE_POWER_TIERS[-1][1], SCORE_POWER_TIERS[-1][2]


def _set_score_power_rules(world: "Hades2World", player: int, options, routes: list,
                           grasp_cap: int) -> None:
    """point_based: each score check past the first 15% needs progressively more Arcana
    (and Grasp), per Logic.txt's score bands. Applies to both routes' score checks."""
    for route in routes:
        count = _score_count_for(route, options)   # combine_pools halves this per route
        if count <= 0:
            continue
        prefix = ROUTES[route]["score_prefix"]
        for zone in ROUTES[route]["zones"]:
            for location in world.get_region(zone, player).locations:
                name = location.name
                if not name.startswith(prefix + " "):
                    continue
                percentile = _room_depth(name, prefix) / count
                arcana, grasp = _score_power_requirement(percentile)
                grasp = min(grasp, grasp_cap)
                if arcana or grasp:
                    add_rule(location,
                             lambda state, a=arcana, g=grasp:
                                 state._hades2_arcana_count(player, options) >= a
                                 and state._hades2_grasp_count(player, options) >= g)


def _set_surface_cure_rules(world: "Hades2World", player: int, options) -> None:
    """Without the Surface Penalty Cure the Surface curse limits you to its earliest
    checks (Logic.txt): rooms up to depth 5, or the first 6% of score checks."""
    system = options.location_system.value
    if system == POINT_BASED:
        prefix = ROUTES[SURFACE]["score_prefix"]
        count = _score_count_for(SURFACE, options)
    else:
        prefix = ROUTES[SURFACE]["room_prefix"]
        count = 0
    for zone in ROUTES[SURFACE]["zones"]:
        for location in world.get_region(zone, player).locations:
            name = location.name
            if not name.startswith(prefix + " "):
                continue
            depth = _room_depth(name, prefix)
            if system == POINT_BASED:
                gated = count > 0 and (depth / count) > SURFACE_NO_CURE_SCORE_FRACTION
            else:
                gated = depth > SURFACE_NO_CURE_ROOM_DEPTH
            if gated:
                add_rule(location, lambda state: state.has("Surface Penalty Cure", player))


def _set_keepsake_rules(world: "Hades2World", player: int, options, routes: list) -> None:
    """Gate each "<NPC> Keepsake" check per Logic.txt: soft keepsakes by count tier, hard
    keepsakes by area access + count, and Moros by the Doomed Beckoning incantation."""
    if options.keepsakesanity.value == 0:
        return  # no keepsake check locations exist

    def loc(npc: str):
        try:
            return world.get_location(f"{npc} Keepsake", player)
        except KeyError:
            return None

    # Soft keepsakes: a flat keepsake-count threshold.
    for npc, tier in KEEPSAKE_SOFT_TIER.items():
        location = loc(npc)
        threshold = KEEPSAKE_TIER_COUNT[tier]
        if location is not None and threshold > 0:
            add_rule(location,
                     lambda state, t=threshold: state._hades2_keepsake_count(player, options) >= t)

    # Moros: needs the Doomed Beckoning incantation item.
    moros = loc("Moros")
    if moros is not None:
        add_rule(moros, lambda state: state.has(KEEPSAKE_MOROS_ITEM, player))

    # Hard keepsakes: reach the route's area (when that route is in the seed) AND own
    # enough keepsakes.
    for npc, (route, area, threshold) in KEEPSAKE_HARD.items():
        location = loc(npc)
        if location is None:
            continue
        if route in routes:
            region = ROUTES[route]["zones"][area]
            add_rule(location,
                     lambda state, r=region: state.can_reach(r, "Region", player))
        if threshold > 0:
            add_rule(location,
                     lambda state, t=threshold: state._hades2_keepsake_count(player, options) >= t)


def _set_per_weapon_rules(world: "Hades2World", player: int, options, routes: list) -> None:
    """Gate each per-weapon room check behind owning the matching weapon."""
    for route in routes:
        prefix = ROUTES[route]["room_prefix"]
        for region_name in ROUTES[route]["zones"]:
            region = world.get_region(region_name, player)
            for location in region.locations:
                name = location.name
                if not name.startswith(prefix + " "):
                    continue
                weapon = name.rsplit(" ", 1)[-1]
                if weapon in WEAPON_SHORT_NAMES:
                    add_rule(location,
                             lambda state, w=weapon: state._hades2_has_weapon(w, player, options))


def _set_combined_room_rules(world: "Hades2World", player: int, options, routes: list) -> None:
    """combine_pools: gate each shared "Room NNNN" / "Room NNNN <Weapon>" check by depth.
    A check at depth d is reachable once depth d's zone is reachable on ANY active route
    (so the easier route satisfies it); per_weapon checks also need the matching weapon."""
    try:
        region = world.get_region("Combined Rooms", player)
    except KeyError:
        return
    count = _combined_room_count()
    bounds = _zone_bounds(count)   # depth d (1..count) lives in zone z where bounds[z] < d <= bounds[z+1]

    def zone_of(depth: int) -> int:
        for z in range(4):
            if bounds[z] < depth <= bounds[z + 1]:
                return z
        return 3

    for location in region.locations:
        # name: "Room NNNN", "Room NNNN <Weapon>", or with a " +k" scaling slot token
        # between the depth and the (optional, always-last) weapon.
        parts = location.name.split(" ")
        depth = int(parts[1])
        weapon = parts[-1] if parts[-1] in WEAPON_SHORT_NAMES else None
        zi = zone_of(depth)
        # A combined "Room N" check is reachable once depth N's zone is reachable on ANY
        # active route. The Surface branch is special: the surface curse walls you off past
        # room 3 without the Penalty Cure, so reaching a deeper combined room *via the
        # Surface* also needs the cure. The Underworld reaches the same depth with no such
        # cap. Together that's exactly the surface-only-start case: past room 3 you need
        # either a Progressive Underworld (to open the uncapped Underworld branch) or the
        # cure -- and fill keeps one of those in the early ungated sphere (rooms 1-3 / NPC
        # meets). When the cure is precollected (start_with_surface_cure on) the cure clause
        # is trivially satisfied, so this collapses back to "any route's zone is reachable".
        capped = depth > SURFACE_NO_CURE_ROOM_DEPTH
        surface_zone = ROUTES[SURFACE]["zones"][zi] if SURFACE in routes else None
        other_zones = [ROUTES[route]["zones"][zi] for route in routes if route != SURFACE]
        add_rule(location,
                 lambda state, sz=surface_zone, others=other_zones, capped=capped:
                     any(state.can_reach(reg, "Region", player) for reg in others)
                     or (sz is not None
                         and state.can_reach(sz, "Region", player)
                         and (not capped
                              or state.has("Surface Penalty Cure", player))))
        if weapon and weapon in WEAPON_SHORT_NAMES:
            add_rule(location,
                     lambda state, w=weapon: state._hades2_has_weapon(w, player, options))
