"""Check the client's "Hades 2" tab model (Hades2Rogue_apworld/Tracker.py) against real location
tables: for a matrix of option combinations, build the seed's location table with
Locations.setup_location_table_with_settings, run it through Tracker.classify_locations /
build_model, and verify every location lands somewhere the tab shows it with the right totals.

Runs standalone (no Archipelago install needed): BaseClasses is stubbed like tools/sync_check.py.

Usage:  python tools/tracker_check.py        (exit 0 = all clean, 1 = failures)
"""
import importlib.util
import itertools
import pathlib
import random
import sys
import types

PROJECT_ROOT = pathlib.Path(__file__).resolve().parent.parent
APWORLD = PROJECT_ROOT / "Hades_2_Archipelago" / "Hades2Rogue_apworld"

failures = []


def fail(case: str, msg: str) -> None:
    failures.append(f"[{case}] {msg}")


def _import_apworld():
    base = types.ModuleType("BaseClasses")

    class _Stub:
        def __init__(self, *a, **k):
            pass

    class _ItemClassification:
        progression = "progression"
        useful = "useful"
        filler = "filler"
        trap = "trap"

    base.Item = base.Location = base.Entrance = base.Region = base.MultiWorld = base.Tutorial = _Stub
    base.ItemClassification = _ItemClassification
    sys.modules["BaseClasses"] = base

    pkg_name = "h2r_tracker"
    pkg = types.ModuleType(pkg_name)
    pkg.__path__ = [str(APWORLD)]
    sys.modules[pkg_name] = pkg
    mods = {}
    for name in ("Routes", "Items", "Locations", "Tracker"):
        spec = importlib.util.spec_from_file_location(f"{pkg_name}.{name}", APWORLD / f"{name}.py")
        module = importlib.util.module_from_spec(spec)
        sys.modules[f"{pkg_name}.{name}"] = module
        spec.loader.exec_module(module)
        mods[name] = module
    return mods


class _Opt:
    def __init__(self, value):
        self.value = value

    def __bool__(self):
        return bool(self.value)

    def __int__(self):
        return int(self.value)

    def __eq__(self, other):
        return self.value == (other.value if isinstance(other, _Opt) else other)

    __hash__ = None


class _Options:
    DEFAULTS = {
        "include_regions": ["Underworld"], "goals_required": ["Underworld"], "goal_mode": 1,
        "goal_requires_zagreus": 0, "location_system": 1, "separate_checks": 0,
        "score_rewards_amount": 40, "included_weapons": ["Staff", "Blades", "Skull", "Flames", "Axe", "Coat"],
        "included_aspects": 4, "enemysanity": 0, "include_minibosses": 1, "keepsakesanity": 0,
        "npc_locations": 0, "dream_region_count": 4, "dream_enemy_locations": 4,
        "combat_helper_sanity": 0, "include_zagreus_journey": 1,
    }

    def __init__(self, **values):
        for key, value in {**self.DEFAULTS, **values}.items():
            setattr(self, key, _Opt(value))


def check_case(mods, case: str, values: dict, multiplier: int) -> None:
    L, T, R = mods["Locations"], mods["Tracker"], mods["Routes"]
    opts = _Options(**values)
    table = L.setup_location_table_with_settings(opts, multiplier)
    locations = {loc_id: name for name, loc_id in table.items() if loc_id is not None}
    routes = L.active_routes(opts)
    slot_data = {
        "location_system": values.get("location_system", 1),
        "separate_checks": values.get("separate_checks", 0),
        "included_weapons": values.get("included_weapons", _Options.DEFAULTS["included_weapons"]),
        "aspectsanity": values.get("aspectsanity", 3), "initial_weapon": 0, "starting_aspect_index": 0,
        "goals_required": values.get("goals_required", ["Underworld"]),
        "goal_requires_zagreus": values.get("goal_requires_zagreus", 0),
        "lock_routes": 1, "reverse_vow": 0, "godsanity": 0,
    }
    for route in ("Underworld", "Surface", "Nightmare", "Dream"):
        slot_data[f"{route.lower()}_active"] = 1 if route in routes else 0
        slot_data[f"{route.lower()}_offset"] = 0 if route == routes[0] else 1
        slot_data[f"{route.lower()}_start"] = 1 if route == routes[0] else 0
    if "Dream" in routes:
        slot_data["dream_region_count_actual"] = len(L.zone_tables["Dream"])

    keys = T.classify_locations(slot_data, locations)
    others = sorted(locations[i] for i, key in keys.items() if key[0] == "other")
    if others:
        fail(case, f"{len(others)} unclassified location(s), e.g. {others[:5]}")

    # Deterministic pseudo-random checked / in-logic subsets.
    rng = random.Random(case)
    ids = sorted(locations)
    checked = {i for i in ids if rng.random() < 0.3}
    in_logic = {i for i in ids if i not in checked and rng.random() < 0.5}
    model = T.build_model(slot_data, ["Progressive Surface"], locations, keys, checked, in_logic,
                          {"clears": {"chronos": 1}, "weapons": {"chronos": 1}, "zagreus": 0}, False)
    if model != T.build_model(slot_data, ["Progressive Surface"], locations, keys, checked, in_logic,
                              {"clears": {"chronos": 1}, "weapons": {"chronos": 1}, "zagreus": 0}, False):
        fail(case, "model is not deterministic")

    def expect(label: str, got: tuple, want_ids: list) -> None:
        want = (sum(1 for i in want_ids if i in checked), len(want_ids),
                sum(1 for i in want_ids if i in in_logic))
        if tuple(got) != want:
            fail(case, f"{label}: got {tuple(got)}, want {want}")

    by_kind = {}
    for loc_id, key in keys.items():
        by_kind.setdefault(key[0], []).append(loc_id)

    # Every location is shown in exactly one top-level place: a route row, the shared pool, or a
    # category list.
    shown = 0
    for route_model in model["routes"]:
        route = route_model["route"]
        rows = {row[0]: row[1:] for row in route_model["rows"]}
        room_ids = [i for i, k in keys.items() if k[0] == "room" and k[1] == route]
        score_ids = [i for i, k in keys.items() if k == ("score", route)]
        if room_ids:
            expect(f"{route} rooms", rows.get(T.LABELS["rooms"], (0, 0, 0)), room_ids)
            shown += len(room_ids)
        elif T.LABELS["rooms"] in rows:
            fail(case, f"{route} shows a rooms row with no room checks")
        if score_ids:
            expect(f"{route} score", rows.get(T.LABELS["score"], (0, 0, 0)), score_ids)
            shown += len(score_ids)
        for prefix in (T.DREAM_COUNTER_PREFIXES if route == "Dream" else ()):
            counter_ids = [i for i, k in keys.items() if k == ("dream_counter", prefix)]
            if counter_ids:
                expect(prefix, rows.get(prefix, (0, 0, 0)), counter_ids)
                shown += len(counter_ids)
        zones = T.zone_names(route, slot_data)
        if len(route_model["zones"]) != len(zones):
            fail(case, f"{route}: {len(route_model['zones'])} zone rows for {len(zones)} zones")
        for zi, zone_row in enumerate(route_model["zones"]):
            zone_ids = [i for i, k in keys.items() if k[0] == "room" and k[1] == route and k[2] == zi]
            if zone_ids:
                expect(f"{route} zone {zi}",
                       (zone_row["checked"], zone_row["total"], zone_row["in_logic"]), zone_ids)
            elif zone_row["total"] is not None:
                fail(case, f"{route} zone {zi} shows counts with no room checks")
        if room_ids and sum(z["total"] or 0 for z in route_model["zones"]) != len(room_ids):
            fail(case, f"{route}: zone totals don't add up to the route's rooms")
    for row in model["shared"]:
        kind = "shared_room" if row[0] == T.LABELS["rooms"] else "shared_score"
        expect(f"shared {kind}", row[1:], by_kind.get(kind, []))
        shown += len(by_kind.get(kind, []))
    for category in model["categories"]:
        cat_ids = by_kind.get(category["key"], [])
        expect(category["title"], (category["checked"], category["total"], category["in_logic"]), cat_ids)
        if len(category["entries"]) != len(cat_ids):
            fail(case, f"{category['title']}: {len(category['entries'])} entries for {len(cat_ids)} locations")
        shown += len(cat_ids)
    if shown != len(locations):
        fail(case, f"tab shows {shown} of {len(locations)} locations")

    # Weapon lanes (per_weapon / per_aspect): each column's cells cover exactly that route's (or
    # the shared pool's) room checks, and a weapon's cell equals the sum of its aspect rows.
    weapons = model["weapons"]
    system = values.get("location_system", 1)
    if system in (2, 3) and not weapons["columns"]:
        fail(case, "per-weapon/per-aspect seed has no weapon columns")
    for ci, column in enumerate(weapons["columns"]):
        pool = [i for i, k in keys.items()
                if (k[0] == "shared_room" if column is None else (k[0] == "room" and k[1] == column))]
        weapon_total = sum(row["cells"][ci][1] for row in weapons["rows"]
                           if not row["indent"] and row["cells"][ci])
        if weapon_total != len(pool):
            fail(case, f"weapon column {column}: weapon cells cover {weapon_total} of {len(pool)} rooms")
        if system == 3:
            aspect_total = sum(row["cells"][ci][1] for row in weapons["rows"]
                               if row["indent"] and row["cells"][ci])
            if aspect_total != len(pool):
                fail(case, f"weapon column {column}: aspect cells cover {aspect_total} of {len(pool)} rooms")
    included = values.get("included_weapons", _Options.DEFAULTS["included_weapons"])
    top_rows = [row["name"] for row in weapons["rows"] if not row["indent"]]
    if top_rows != [w for w in mods["Items"].WEAPON_SHORT_NAMES if w in included]:
        fail(case, f"weapon rows {top_rows} don't match included weapons {included}")


def check_route_access(mods) -> None:
    """Zone-open thresholds vs. Rules.set_rules: non-starting locked route = 4 copies (door + 3
    zones), starting route = 3, unlocked routes = everything open once entered."""
    T = mods["Tracker"]
    base = {"lock_routes": 1, "underworld_active": 1, "surface_active": 1}
    starting = {**base, "underworld_offset": 0, "surface_offset": 1, "surface_start": 0}
    cases = [
        ("Underworld", starting, 0, [True, False, False, False], ("Progressive Underworld", 0, 3)),
        ("Underworld", starting, 3, [True, True, True, True], ("Progressive Underworld", 3, 3)),
        ("Surface", starting, 0, [False] * 4, ("Progressive Surface", 0, 4)),
        ("Surface", starting, 1, [True, False, False, False], ("Progressive Surface", 1, 4)),
        ("Surface", starting, 3, [True, True, True, False], ("Progressive Surface", 3, 4)),
        ("Surface", starting, 4, [True] * 4, ("Progressive Surface", 4, 4)),
        ("Surface", {**starting, "lock_routes": 0}, 0, [False] * 4, None),
    ]
    for route, slot_data, copies, want_open, want_prog in cases:
        counts = {f"Progressive {route}": copies} if copies else {}
        got = T.route_access(route, slot_data, counts)
        if got["zone_open"] != want_open or got["progressive"] != want_prog:
            fail("route_access", f"{route} x{copies} lock={slot_data['lock_routes']}: got "
                                 f"{got['zone_open']} {got['progressive']}, want {want_open} {want_prog}")
    got = T.route_access("Surface", {**starting, "lock_routes": 0}, {"Surface Access": 1})
    if got["zone_open"] != [True] * 4:
        fail("route_access", f"unlocked Surface with Surface Access: got {got['zone_open']}")
    dream = {"lock_routes": 1, "dream_active": 1, "dream_offset": 1, "dream_start": 0,
             "dream_region_count_actual": 5}
    got = T.route_access("Dream", dream, {"Progressive Dream": 2})
    if got["zone_open"] != [True, True, False, False, False] or got["progressive"] != ("Progressive Dream", 2, 5):
        fail("route_access", f"Dream x2 of 5 regions: got {got['zone_open']} {got['progressive']}")


def main() -> int:
    mods = _import_apworld()
    route_sets = [["Underworld"], ["Underworld", "Surface"], ["Surface", "Nightmare"],
                  ["Underworld", "Surface", "Nightmare", "Dream"], ["Dream"], ["Underworld", "Dream"]]
    n = 0
    for system, separate, routes, multiplier in itertools.product(
            (0, 1, 2, 3), (0, 1), route_sets, (1, 2)):
        values = {"location_system": system, "separate_checks": separate, "include_regions": routes,
                  "goals_required": routes[:1], "enemysanity": 1 if n % 2 else 3,
                  "keepsakesanity": 1, "npc_locations": 1, "goal_requires_zagreus": n % 3 == 0,
                  "included_aspects": 2 + n % 3, "dream_region_count": 3 + n % 6,
                  "included_weapons": (["Staff", "Axe", "Coat"] if n % 4 == 1
                                       else _Options.DEFAULTS["included_weapons"])}
        check_case(mods, f"sys{system} sep{separate} {'+'.join(routes)} x{multiplier}", values, multiplier)
        n += 1
    check_route_access(mods)
    if failures:
        print(f"{len(failures)} failure(s):")
        for line in failures[:60]:
            print("  " + line)
        return 1
    print(f"tracker_check: {n} option combinations clean")
    return 0


if __name__ == "__main__":
    sys.exit(main())
