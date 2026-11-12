"""Check the in-game tracker's pages (Hades2Rogue_apworld/Journal.py) against real location tables.

For the same matrix of option combinations as tools/tracker_check.py: build the seed's location
table, its real enemy-shuffle and miniboss-room maps, the Tracker model and then the Journal pages,
and verify that every keepsake / Met / enemy check is on a page, that each enemy is listed under a
zone the world's own placement gives it, that no page is longer than the book, and that the wire
format survives a round trip.

Runs standalone (no Archipelago install needed), like tracker_check.py.

Usage:  python tools/journal_check.py                  (exit 0 = all clean, 1 = failures)
        python tools/journal_check.py --sample FILE    also write one JOURNAL payload to FILE
                                                       (input for tools/journal_harness.lua)
"""
import importlib.util
import itertools
import pathlib
import random
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import tracker_check as tc  # noqa: E402  (BaseClasses stub, package loader, _Options)

failures = []


def fail(case: str, msg: str) -> None:
    failures.append(f"[{case}] {msg}")


def _import_apworld() -> dict:
    mods = tc._import_apworld()
    spec = importlib.util.spec_from_file_location("h2r_tracker.Journal", tc.APWORLD / "Journal.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules["h2r_tracker.Journal"] = module
    spec.loader.exec_module(module)
    mods["Journal"] = module
    return mods


def _lines(J, page: dict) -> list:
    return page["body"].split(J.LINE_BREAK)


def _listed(J, page: dict) -> list:
    """(section, name, under the in-logic label) for every name a list page shows as still to do."""
    out, section, logic = [], None, False
    dim_open, close = J.DIM.format(text="\0").split("\0")
    for line in _lines(J, page):
        if line.startswith("{#CodexBoldFormat}"):
            section = line[len("{#CodexBoldFormat}"):].split(":")[0].replace("{#Prev}", "")
            continue
        if line.startswith(dim_open):
            line = line[len(dim_open):-len(close)]
        for key in ("left", "left_in_logic", "left_out_of_logic"):
            if line.startswith(J.LABELS[key] + " "):
                logic = key == "left_in_logic"
                line = line[len(J.LABELS[key]) + 1:]
        for name in line.split(","):
            name = name.strip()
            if page["key"].startswith("npcs") and name.endswith(")"):
                name = name[:name.rindex(" (")]
            if name:
                out.append((section, name, logic))
    return out


def build_case(mods, case: str, values: dict, multiplier: int):
    L, T, J = mods["Locations"], mods["Tracker"], mods["Journal"]
    opts = tc._Options(**values)
    table = L.setup_location_table_with_settings(opts, multiplier)
    locations = {loc_id: name for name, loc_id in table.items() if loc_id is not None}
    routes = L.active_routes(opts)
    slot_data = {
        "location_system": values.get("location_system", 1),
        "separate_checks": values.get("separate_checks", 0),
        "included_weapons": values.get("included_weapons", tc._Options.DEFAULTS["included_weapons"]),
        "aspectsanity": values.get("aspectsanity", 3), "initial_weapon": 0, "starting_aspect_index": 0,
        "goals_required": values.get("goals_required", ["Underworld"]),
        "goal_requires_zagreus": values.get("goal_requires_zagreus", 0),
        "lock_routes": 1, "reverse_vow": 1, "vow_pain": 2, "godsanity": 1, "godsanity_chaos": 1,
        "helper_room_sanity": 1, "combat_helper_sanity": 1,
        "include_zagreus_journey": 1 if "Nightmare" in routes else 0,
    }
    for route in ("Underworld", "Surface", "Nightmare", "Dream"):
        slot_data[f"{route.lower()}_active"] = 1 if route in routes else 0
        slot_data[f"{route.lower()}_offset"] = 0 if route == routes[0] else 1
        slot_data[f"{route.lower()}_start"] = 1 if route == routes[0] else 0
    if "Dream" in routes:
        slot_data["dream_region_count_actual"] = len(L.zone_tables["Dream"])
    # The seed's real maps, the way __init__.generate_early builds them.
    rng = random.Random(case)
    world_routes = [r for r in routes if r != "Dream"]
    try:
        enemy_map = L.compute_enemysanity_shuffle_map(opts, rng, world_routes)
        room_map = L.compute_miniboss_room_map(opts, rng, world_routes)
    except Exception as exc:
        fail(case, f"couldn't build the shuffle maps: {exc!r}")
        enemy_map, room_map = {}, {}
    slot_data["enemysanity_shuffle_map"] = L.serialize_shuffle_map(enemy_map)
    slot_data["miniboss_room_map"] = L.serialize_shuffle_map(room_map)

    keys = T.classify_locations(slot_data, locations)
    ids = sorted(locations)
    checked = {i for i in ids if rng.random() < 0.3}
    in_logic = {i for i in ids if i not in checked and rng.random() < 0.5}
    received = ["Progressive Surface", "Zeus Unlock", "Pain Vow Removal", "Arachne Room"]
    stats = {"clears": {"chronos": 1}, "weapons": {"chronos": 1}, "zagreus": 0}
    model = T.build_model(slot_data, received, locations, keys, checked, in_logic, stats, False)
    hints_here = [(locations[i], "Power Star", "Mario|64") for i in ids[:3]]
    hints_away = [("Progressive Underworld", "Bob-omb~Battlefield", "Luigi")]
    pages = J.build_pages(slot_data, model, hints_here, hints_away)
    return slot_data, locations, keys, model, pages, (enemy_map, room_map, world_routes)


def check_case(mods, case: str, values: dict, multiplier: int) -> str:
    L, T, J = mods["Locations"], mods["Tracker"], mods["Journal"]
    slot_data, locations, keys, model, pages, maps = build_case(mods, case, values, multiplier)
    if not pages:
        fail(case, "no pages")
        return ""
    if J.build_pages(slot_data, model, [], []) == pages:
        fail(case, "hints made no difference to the pages")

    page_keys = [page["key"] for page in pages]
    if len(set(page_keys)) != len(page_keys):
        fail(case, f"duplicate page keys: {page_keys}")
    for page in pages:
        for field in ("key", "title", "portrait", "body"):
            if "\n" in page[field] or "\r" in page[field]:
                fail(case, f"page {page['key']}: newline in {field}")
        cost = sum(J._line_cost(line) for line in _lines(J, page))
        if cost > J.MAX_LINES:
            fail(case, f"page {page['key']}: {cost} lines, the book holds {J.MAX_LINES}")
        if not page["title"] or not page["portrait"]:
            fail(case, f"page {page['key']}: missing title or portrait")
        last = _lines(J, page)[-1]
        # A finished section is its header alone ("Erebus: 7/7"), so that one may end a page.
        count = last.replace("{#Prev}", "").rsplit(": ", 1)[-1].split(" ")[0].split("/")
        finished = len(count) == 2 and count[0] == count[1]
        if last.startswith("{#CodexBoldFormat}") and len(_lines(J, page)) > 1 and not finished:
            fail(case, f"page {page['key']}: ends on a header")

    # Wire round trip, parsed the way Journal.lua does.
    payload = J.encode(pages)
    if "\n" in payload:
        fail(case, "newline in the payload")
    records = payload.split("|")
    if records[0] != J.LABELS["chapter"] or len(records) != len(pages) + 1:
        fail(case, f"payload has {len(records) - 1} records for {len(pages)} pages")
    for record, page in zip(records[1:], pages):
        fields = record.split("~")
        if len(fields) != 4 or fields[0] != page["key"]:
            fail(case, f"page {page['key']}: record splits into {len(fields)} fields")

    # Every keepsake / NPC / enemy / other check still to do is listed, under the right label;
    # one already sent is only counted.
    page_kind = {"keepsakes": "keepsake", "npcs": "npc", "enemies": "enemy", "other": "other"}
    listed = {}     # kind -> {name: in the "in logic" list}
    for page in pages:
        kind = page_kind.get(page["key"].split("_")[0])
        if kind:
            for _section, name, logic in _listed(J, page):
                listed.setdefault(kind, {})[name] = logic
    for category in model["categories"]:
        names = listed.get(category["key"], {})
        for name, is_checked, logic in category["entries"]:
            if is_checked:
                if name in names:
                    fail(case, f"{category['key']} check '{name}' is sent but still listed")
            elif name not in names:
                fail(case, f"{category['key']} check '{name}' is on no page")
            elif names[name] != bool(logic):
                fail(case, f"{category['key']} check '{name}' is under the wrong label")

    # Enemies sit under a zone the world's own placement gives them.
    enemy_map, room_map, world_routes = maps
    placement = L.enemy_zone_placement(L.combined_relabel(enemy_map, room_map), world_routes)
    R = mods["Routes"]
    allowed = {}
    for (route, zone), names in placement.items():
        display = R.ROUTES[route]["zone_display"][R.ROUTES[route]["zones"].index(zone)]
        for location in names:
            allowed.setdefault(location[:-len(" Defeated")], set()).add((route, display))
    for location, zones in L.SHARED_ENEMY_ZONES.items():
        name = location[:-len(" Defeated")]
        if name not in allowed:
            allowed[name] = {(route, R.ROUTES[route]["zone_display"][zi]) for route, zi in zones}
    enemy_names = {name for category in model["categories"] if category["key"] == "enemy"
                   for name, _c, _l in category["entries"]}
    for page in pages:
        if not page["key"].startswith("enemies"):
            continue
        route = next((r for r in world_routes if page["key"].startswith(f"enemies_{r.lower()}")), None)
        for zone, name, _logic in _listed(J, page):
            if zone in (J.LABELS["enemies_elsewhere"], T.LABELS["enemies_title"]):
                if any(r in world_routes for r, _z in allowed.get(name, ())):
                    fail(case, f"enemy '{name}' is under Elsewhere but has a zone")
            elif (route, zone) not in allowed.get(name, ()):
                fail(case, f"enemy '{name}' listed under {route} {zone}, "
                           f"placement says {sorted(allowed.get(name, ()))}")

    # Hints: the separators inside other games' names can't reach the wire.
    hint_pages = [page for page in pages if page["key"].startswith("hints")]
    if not hint_pages:
        fail(case, "no hints page")
    elif "Mario/64" not in payload or "Bob-omb-Battlefield" not in payload:
        fail(case, "hint text wasn't made wire-safe")
    return payload


def check_long_hints(mods) -> None:
    J = mods["Journal"]
    here = [(f"Underworld Erebus Room {i:02d}", f"Item {i}", "Someone") for i in range(200)]
    pages = J._hints_page(here, [])
    if len(pages) != J.MAX_HINT_PAGES:
        fail("hints", f"200 hints made {len(pages)} pages, cap is {J.MAX_HINT_PAGES}")
    if J.LABELS["more"].format(n=0).split("0")[0] not in pages[-1]["body"]:
        fail("hints", "the capped hints page doesn't say more were left out")
    for page in pages:
        if sum(J._line_cost(line) for line in _lines(J, page)) > J.MAX_LINES:
            fail("hints", f"capped page {page['key']} is too long")


def main() -> int:
    sample_path = None
    if "--sample" in sys.argv:
        sample_path = sys.argv[sys.argv.index("--sample") + 1]
    mods = _import_apworld()
    route_sets = [["Underworld"], ["Underworld", "Surface"], ["Surface", "Nightmare"],
                  ["Underworld", "Surface", "Nightmare", "Dream"], ["Dream"], ["Underworld", "Dream"]]
    n, sample, longest = 0, "", 0
    for system, separate, routes, multiplier in itertools.product(
            (0, 1, 2, 3), (0, 1), route_sets, (1, 2)):
        values = {"location_system": system, "separate_checks": separate, "include_regions": routes,
                  "goals_required": routes[:1], "enemysanity": 1 if n % 2 else 3,
                  "keepsakesanity": 1, "npc_locations": 1, "goal_requires_zagreus": n % 3 == 0,
                  "included_aspects": 2 + n % 3, "dream_region_count": 3 + n % 6,
                  "included_weapons": (["Staff", "Axe", "Coat"] if n % 4 == 1
                                       else tc._Options.DEFAULTS["included_weapons"])}
        case = f"sys{system} sep{separate} {'+'.join(routes)} x{multiplier}"
        try:
            payload = check_case(mods, case, values, multiplier)
        except Exception as exc:
            fail(case, f"crashed: {exc!r}")
            payload = ""
        longest = max(longest, len(payload))
        if len(routes) == 4 and system == 3 and not sample:
            sample = payload
        n += 1
    check_long_hints(mods)
    if sample_path and sample:
        pathlib.Path(sample_path).write_text(sample, encoding="utf-8")
        print(f"sample payload written: {sample_path} ({len(sample)} bytes, "
              f"{sample.count('|')} pages)")
    if failures:
        print(f"{len(failures)} failure(s):")
        for line in failures[:60]:
            print("  " + line)
        return 1
    print(f"journal_check: {n} option combinations clean (largest payload {longest} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
