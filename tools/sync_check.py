"""Cross-check the apworld's Python data tables against the Lua mod's mirrors,
and validate item/location ID uniqueness.

Runs standalone (no Archipelago install needed): BaseClasses is stubbed before the
apworld modules are imported, and the Lua tables are extracted with brace-counting
text parsers keyed to this project's consistent formatting.

It also enforces the id lock (tools/id_lock.json): every item code and location id that has
shipped must keep its value, and a retired id must never be handed to a new name.

It also checks template YAMLs against archipelago.json: `requires: version:` must equal
minimum_ap_version (and `requires: game: Hades2Rogue:`, when present, world_version). It reads
every YAML in `Published Versions/v<world_version>/` plus any given with --template.

Usage:  python tools/sync_check.py                   (exit 0 = all clean, 1 = mismatches found)
        python tools/sync_check.py --update-id-lock  (after a deliberate id change: re-record)
        python tools/sync_check.py --template PATH   (also check this template YAML; repeatable)
"""
import hashlib
import json
import pathlib
import re
import sys
import types

PROJECT_ROOT = pathlib.Path(__file__).resolve().parent.parent
APWORLD = PROJECT_ROOT / "Hades_2_Archipelago" / "Hades2Rogue_apworld"
MOD = PROJECT_ROOT / "Hades_2_Archipelago" / "Hades2Rogue_mod"
ID_LOCK = pathlib.Path(__file__).resolve().parent / "id_lock.json"

failures = []

# Documented, deliberate Python<->Lua divergences (see the comments at each site).
# ("boss-met", "Met Hades"): Lua fires it from the Nightmare zone-4 boss arena; Python
#   models it as a Crossroads-cast location with a multi-route rule (NPC_MULTI_ROUTE_LOCK),
#   so it has no NPC_BOSS_MEET tuple.
# ("npc-route-lock", "Megaera"): Lua defensively route-gates her so no stray send happens
#   when Nightmare content isn't loaded; Python-side her "Met" is boss-met machinery and her
#   keepsake is item-only, so she has no NPC_ROUTE_LOCK entry.
KNOWN_INTENTIONAL = {
    ("boss-met", "Met Hades"),
    ("npc-route-lock", "Megaera"),
}


def fail(section: str, msg: str, name: str = None) -> None:
    if name is not None and (section, name) in KNOWN_INTENTIONAL:
        return
    failures.append(f"[{section}] {msg}")


# --------------------------------------------------------------------------
# Import the apworld data modules with BaseClasses stubbed out.
# --------------------------------------------------------------------------

def _install_stubs() -> None:
    base = types.ModuleType("BaseClasses")

    class _Stub:
        def __init__(self, *a, **k):
            pass

    class _ItemClassification:
        progression = "progression"
        useful = "useful"
        filler = "filler"
        trap = "trap"

    base.Item = _Stub
    base.Location = _Stub
    base.ItemClassification = _ItemClassification
    base.Entrance = _Stub
    base.Region = _Stub
    base.MultiWorld = _Stub
    base.Tutorial = _Stub
    sys.modules["BaseClasses"] = base


def _import_apworld_data():
    """Import Items/Locations/Routes as a package (they use relative imports)."""
    _install_stubs()
    import importlib.util

    pkg_name = "h2r_data"
    pkg = types.ModuleType(pkg_name)
    pkg.__path__ = [str(APWORLD)]
    sys.modules[pkg_name] = pkg

    mods = {}
    for name in ("Routes", "Items", "Locations"):
        spec = importlib.util.spec_from_file_location(
            f"{pkg_name}.{name}", APWORLD / f"{name}.py")
        module = importlib.util.module_from_spec(spec)
        sys.modules[f"{pkg_name}.{name}"] = module
        spec.loader.exec_module(module)
        mods[name] = module
    return mods["Routes"], mods["Items"], mods["Locations"]


# --------------------------------------------------------------------------
# Lua table extraction. All the tables we care about are formatted as either
#   NAME = { "a", "b", ... }                         (list of strings)
#   NAME = { ["k"] = "v", ... } / { k = "v", ... }   (string map)
# possibly spanning lines, with -- comments. Brace-count from the opening
# brace of the named table to its matching close, then pull string tokens.
# --------------------------------------------------------------------------

def _lua_source(name: str) -> str:
    return (MOD / name).read_text(encoding="utf-8")


def _strip_comments(chunk: str) -> str:
    return re.sub(r"--[^\n]*", "", chunk)


def lua_table_chunk(source: str, table_name: str) -> str:
    """The text between the named table's opening { and its matching }."""
    # allow the hot-reload-safe idiom `NAME = NAME or { ... }`
    m = re.search(re.escape(table_name) + r"\s*=\s*(?:[\w.]+\s+or\s+)?{", source)
    if not m:
        raise KeyError(f"table {table_name} not found")
    start = m.end()
    depth = 1
    i = start
    while depth > 0 and i < len(source):
        c = source[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
        elif c == "-" and source[i:i + 2] == "--":
            i = source.find("\n", i)
        i += 1
    return source[start:i - 1]


def lua_list(source: str, table_name: str) -> list:
    """Bare string entries of a (possibly nested) Lua list table."""
    chunk = _strip_comments(lua_table_chunk(source, table_name))
    # remove map-style entries so only bare strings remain
    chunk = re.sub(r'\[\s*"[^"]*"\s*\]\s*=\s*("[^"]*"|\w+)', "", chunk)
    chunk = re.sub(r'\b\w+\s*=\s*("[^"]*"|\w+)', "", chunk)
    return re.findall(r'"([^"]+)"', chunk)


def lua_map(source: str, table_name: str) -> dict:
    """["key"] = "value" (or bare-word keys/values) entries of a Lua map table."""
    chunk = _strip_comments(lua_table_chunk(source, table_name))
    out = {}
    for k, v in re.findall(r'\[\s*"([^"]+)"\s*\]\s*=\s*"([^"]+)"', chunk):
        out[k] = v
    for k, v in re.findall(r'(?<!\[)\b(\w+)\s*=\s*"([^"]+)"', chunk):
        out[k] = v
    for k, v in re.findall(r'\[\s*"([^"]+)"\s*\]\s*=\s*(true|false)', chunk):
        out[k] = v == "true"
    for k, v in re.findall(r'(?<!\[)\b(\w+)\s*=\s*(true|false)', chunk):
        out[k] = v == "true"
    return out


def diff(section: str, python_side, lua_side, py_label="Python", lua_label="Lua") -> None:
    p, l = set(python_side), set(lua_side)
    for name in sorted(p - l):
        fail(section, f"in {py_label} but missing from {lua_label}: {name!r}", name)
    for name in sorted(l - p):
        fail(section, f"in {lua_label} but missing from {py_label}: {name!r}", name)


# --------------------------------------------------------------------------
# Id lock. Ids are baked into every generated seed's datapackage, so once shipped they are
# frozen. Hand-listed names (no digits: enemies, keepsakes, NPCs, items) are locked one by one.
# Numbered families ("Underworld Erebus Room 07 Staff", "Dream Enemy 0042") are generated by
# formula and number in the tens of thousands, so each family is locked as a digest of its
# entries in id order -- appending new entries at the end of a family still passes, while
# renumbering, reordering or shrinking one fails.
# --------------------------------------------------------------------------

def _family(name: str) -> str:
    return re.sub(r"\d+", "#", name)


def _digest(pairs) -> str:
    h = hashlib.sha1()
    for name, i in pairs:
        h.update(f"{name}={i}\n".encode("utf-8"))
    return h.hexdigest()[:16]


def id_snapshot(Items, loc_table) -> dict:
    items = {n: d.code for n, d in Items.item_table.items() if d.code is not None}
    single = {n: i for n, i in loc_table.items() if not re.search(r"\d", n)}
    families = {}
    for n, i in loc_table.items():
        if re.search(r"\d", n):
            families.setdefault(_family(n), []).append((i, n))
    fam = {}
    for key, rows in families.items():
        rows.sort()
        fam[key] = {"count": len(rows), "first_id": rows[0][0],
                    "digest": _digest((n, i) for i, n in rows)}
    return {"items": items, "locations": single, "location_families": fam,
            "_rows": {k: sorted(v) for k, v in families.items()}}


def check_template_requires(path: pathlib.Path, minimum: str, world_version: str) -> bool:
    """A template's `requires:` block against archipelago.json. AP's template generator writes the
    generating core's own version there (data/options.yaml renders __version__), not ours, so it
    drifts: 0.10.x templates said 0.6.7 while minimum_ap_version said 0.6.4, and a player on 0.6.4
    couldn't generate (Miraba 10/16). Returns False for a YAML that isn't a Hades2Rogue template."""
    text = path.read_text(encoding="utf-8", errors="replace")
    if not re.search(r"""^game:\s*['"]?Hades2Rogue['"]?\s*(#.*)?$""", text, re.M):
        return False
    block = re.search(r"^requires:[ \t]*(?:#.*)?\n((?:[ \t]+.*(?:\n|$))*)", text, re.M)
    if not block:
        fail("template", f"{path}: no requires: block")
        return True
    version = re.search(r"""^[ \t]+version:\s*['"]?([\w.]+)""", block.group(1), re.M)
    if not version or version.group(1) != minimum:
        fail("template", f"{path}: requires version {version.group(1) if version else 'missing'} "
                         f"!= archipelago.json minimum_ap_version {minimum}")
    game_version = re.search(r"""^[ \t]+['"]?Hades2Rogue['"]?:\s*['"]?([\w.]+)""", block.group(1), re.M)
    if game_version and game_version.group(1) != world_version:
        fail("template", f"{path}: requires Hades2Rogue {game_version.group(1)} "
                         f"!= archipelago.json world_version {world_version}")
    return True


def _load_lock():
    if not ID_LOCK.exists():
        return None
    return json.loads(ID_LOCK.read_text(encoding="utf-8"))


def check_id_lock(current: dict) -> None:
    lock = _load_lock()
    if lock is None:
        fail("id-lock", f"{ID_LOCK.name} is missing -- run with --update-id-lock to create it")
        return
    for kind in ("items", "locations"):
        now = current[kind]
        retired = lock.get("retired", {}).get(kind, {})
        taken = {i: n for n, i in {**retired, **lock[kind]}.items()}
        for name, locked_id in lock[kind].items():
            if name not in now:
                fail("id-lock", f"{kind[:-1]} {name!r} (id {locked_id}) was removed; if that's "
                                "deliberate, --update-id-lock retires its id")
            elif now[name] != locked_id:
                fail("id-lock", f"{kind[:-1]} {name!r} changed id {locked_id} -> {now[name]}")
        candidates = dict(now)
        if kind == "locations":
            # a numbered name must not land on a hand-listed name's live or retired id either
            candidates.update({n: i for rows in current["_rows"].values() for i, n in rows})
        for name, i in candidates.items():
            if name not in lock[kind] and i in taken and taken[i] != name:
                fail("id-lock", f"new {kind[:-1]} {name!r} reuses id {i}, which belongs to "
                                f"{taken[i]!r}")
    for key, locked in lock["location_families"].items():
        rows = current["_rows"].get(key)
        if not rows:
            fail("id-lock", f"location family {key!r} disappeared ({locked['count']} ids)")
            continue
        if len(rows) < locked["count"]:
            fail("id-lock", f"location family {key!r} shrank {locked['count']} -> {len(rows)}")
            continue
        if _digest((n, i) for i, n in rows[:locked["count"]]) != locked["digest"]:
            moved = (f" (first id {locked['first_id']} -> {rows[0][0]})"
                     if rows[0][0] != locked["first_id"] else "")
            fail("id-lock", f"location family {key!r}: an existing name/id pair changed{moved}")


def write_id_lock(current: dict) -> None:
    lock = _load_lock() or {}
    retired = lock.get("retired", {"items": {}, "locations": {}})
    for kind in ("items", "locations"):
        for name, i in lock.get(kind, {}).items():
            if name not in current[kind]:
                retired.setdefault(kind, {})[name] = i
                print(f"  retiring {kind[:-1]} {name!r} (id {i})")
    out = {
        "_comment": "Written by tools/sync_check.py --update-id-lock. Shipped ids are frozen; "
                    "see sync_check.py's id-lock section before editing by hand.",
        "items": dict(sorted(current["items"].items(), key=lambda kv: kv[1])),
        "locations": dict(sorted(current["locations"].items(), key=lambda kv: kv[1])),
        "location_families": dict(sorted(current["location_families"].items())),
        "retired": retired,
    }
    ID_LOCK.write_text(json.dumps(out, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"  wrote {ID_LOCK.name}: {len(out['items'])} items, {len(out['locations'])} locations, "
          f"{len(out['location_families'])} location families")


def main() -> int:
    Routes, Items, Locations = _import_apworld_data()
    im = _lua_source("ItemManager.lua")
    lm = _lua_source("LocationManager.lua")

    # ---- ID uniqueness ----------------------------------------------------
    codes = {}
    for name, data in Items.item_table.items():
        if data.code is None:
            continue
        if data.code in codes:
            fail("item-ids", f"code {data.code} shared by {codes[data.code]!r} and {name!r}")
        codes[data.code] = name

    loc_table = Locations.give_all_locations_table()
    ids = {}
    for name, loc_id in loc_table.items():
        if not isinstance(loc_id, int):
            # The datapackage must only hold real ids; event locations have none.
            fail("location-ids", f"{name!r} has non-integer id {loc_id!r}")
            continue
        if loc_id in ids:
            fail("location-ids", f"id {loc_id} shared by {ids[loc_id]!r} and {name!r}")
        ids[loc_id] = name

    # ---- Enemy checks -----------------------------------------------------
    for route in Routes.ROUTE_NAMES:
        py = [n for layer in Locations.ENEMY_LAYERS[route] for n in layer]
        chunk = lua_table_chunk(lm, "ENEMY_CHECKS_BY_ROUTE")
        sub = lua_table_chunk(chunk, route)
        lua = re.findall(r'"([^"]+)"', _strip_comments(sub))
        diff(f"enemies/{route}", py, lua)

    diff("shared-enemies",
         [n[:-len(" Defeated")] for n in Locations.SHARED_ENEMY_ZONES],
         lua_list(lm, "SHARED_ENEMY_CHECKS"))

    # Enemy classification sets that are hand-duplicated between Locations.py and EnemySanity.lua.
    es = _lua_source("EnemySanity.lua")
    diff("miniboss-names", Locations.MINIBOSS_ENEMY_NAMES,
         lua_map(es, "EnemySanity.MINIBOSS_CHECK_NAMES").keys())
    diff("scripted-only", Locations.SCRIPTED_ONLY_CHECK_NAMES,
         lua_map(es, "EnemySanity.SCRIPTED_ONLY_CHECK_NAMES").keys())
    all_enemies = {n for route in Routes.ROUTE_NAMES for layer in Locations.ENEMY_LAYERS[route] for n in layer}
    for companion, host in Locations.ENEMY_COMPANIONS.items():
        if companion not in all_enemies or host not in all_enemies:
            fail("enemy-companions", f"{companion!r} -> {host!r}: not an enemy check name")
        elif (companion not in Locations.SCRIPTED_ONLY_CHECK_NAMES
              and companion not in Locations.MINIBOSS_ENEMY_NAMES):
            # A companion that the enemy shuffle can still move would have two placements.
            fail("enemy-companions", f"{companion!r} is still in the enemy shuffle")
    for name in Locations.MINIBOSS_ENEMY_NAMES:
        if name not in all_enemies:
            fail("miniboss-names", f"{name!r} is not an enemy check name")
    # Every miniboss room's check must be classified as a miniboss, or include_minibosses and the
    # Dream counters treat that fight as an ordinary enemy.
    for room, (_route, _zone, check) in Locations.MINIBOSS_ROOMS.items():
        if check not in Locations.MINIBOSS_ENEMY_NAMES:
            fail("miniboss-rooms", f"{room}: {check!r} is not in MINIBOSS_ENEMY_NAMES")
    # Home tiers used by EnemySanity.scale_unit must match each name's ENEMY_LAYERS zone.
    lua_tiers = {}
    for tier, body in re.findall(r"_home\((\d),\s*\{(.*?)\}\)", es, re.S):
        for n in re.findall(r'"([^"]+)"', body):
            lua_tiers[n] = int(tier)
    for route in Routes.ROUTE_NAMES:
        for zi, layer in enumerate(Locations.ENEMY_LAYERS[route]):
            for n in layer:
                if lua_tiers.get(n) != zi + 1:
                    fail("home-tiers", f"{n!r}: ENEMY_LAYERS zone {zi + 1} vs Lua ENEMY_HOME_TIER "
                                       f"{lua_tiers.get(n)}")

    # King Vermin: its own route-gated check on both sides (not a shared one).
    lua_kv = re.search(r'local KING_VERMIN_CHECK\s*=\s*"([^"]+)"', lm)
    if not lua_kv or lua_kv.group(1) + " Defeated" != Locations.KING_VERMIN_LOCATION:
        fail("king-vermin", f"Python {Locations.KING_VERMIN_LOCATION!r} vs Lua "
                            f"{lua_kv.group(1) if lua_kv else None!r} (+ ' Defeated')")

    # ---- Dream --------------------------------------------------------------
    diff("dream-boss-names", Locations.DREAM_BOSS_NAMES, lua_map(lm, "DREAM_BOSS_NAMES").keys())
    rt = _lua_source("Routes.lua")
    for py_name, lua_name in (("DREAM_ROOM_LOCATIONS_PER_REGION", "Routes.DREAM_ROOM_LOCATIONS_PER_REGION"),
                              ("DREAM_ROOM_GUARANTEED_PER_REGION", "Routes.DREAM_ROOM_GUARANTEED_PER_REGION")):
        m = re.search(re.escape(lua_name) + r"\s*=\s*(\d+)", rt)
        if not m or int(m.group(1)) != getattr(Locations, py_name):
            fail("dream-rooms", f"{py_name}: Python {getattr(Locations, py_name)} vs Lua "
                                f"{m.group(1) if m else None}")

    # ---- Zone room counts (N) and guaranteed-before-boss counts (K) ----------
    for py_key, lua_name in (("zone_room_counts", "Routes.ZONE_ROOM_COUNTS"),
                             ("zone_room_guaranteed", "Routes.ZONE_ROOM_GUARANTEED")):
        chunk = _strip_comments(lua_table_chunk(rt, lua_name))
        for route in ("Underworld", "Surface", "Nightmare"):
            m = re.search(route + r"\s*=\s*{([^}]*)}", chunk)
            lua_vals = [int(x) for x in re.findall(r"\d+", m.group(1))] if m else None
            if lua_vals != list(Routes.ROUTES[route][py_key]):
                fail("zone-rooms", f"{route} {py_key}: Python {Routes.ROUTES[route][py_key]} vs "
                                   f"Lua {lua_vals}")
        for route in ("Underworld", "Surface", "Nightmare"):
            n, k = Routes.ROUTES[route]["zone_room_counts"], Routes.ROUTES[route]["zone_room_guaranteed"]
            if any(kk > nn for kk, nn in zip(k, n)):
                fail("zone-rooms", f"{route}: a guaranteed count exceeds its zone total ({k} vs {n})")

    # ---- Miniboss room shuffle ------------------------------------------------
    mr = _lua_source("MinibossRooms.lua")
    lua_biome = lua_map(mr, "MinibossRooms.ROOM_BIOME")
    diff("miniboss-rooms", Locations.MINIBOSS_ROOMS.keys(), lua_biome.keys())
    for room in Locations.MINIBOSS_ROOMS:
        if room in lua_biome and lua_biome[room] != room.split("_")[0]:
            fail("miniboss-rooms", f"{room}: Lua ROOM_BIOME {lua_biome[room]!r}")
    lua_check = lua_map(mr, "MinibossRooms.ROOM_CHECK")
    diff("miniboss-room-checks", Locations.MINIBOSS_ROOMS.keys(), lua_check.keys())
    for room, (_r, _z, chk) in Locations.MINIBOSS_ROOMS.items():
        if room in lua_check and lua_check[room] != chk:
            fail("miniboss-room-checks", f"{room}: Lua ROOM_CHECK {lua_check[room]!r}, Python {chk!r}")

    # The generated art-package table (tools/gen_unit_art_packages.py) must load before its reader.
    imports = re.findall(r"import '([^']+)'", _lua_source("ready.lua"))
    if "UnitArtPackages.lua" not in imports or not (MOD / "UnitArtPackages.lua").exists():
        fail("art-packages", "UnitArtPackages.lua missing or not imported by ready.lua")
    elif imports.index("UnitArtPackages.lua") > imports.index("EnemySanity.lua"):
        fail("art-packages", "ready.lua imports UnitArtPackages.lua after EnemySanity.lua")

    # ---- Keepsakes ----------------------------------------------------------
    diff("keepsake-titles", Items.keepsake_titles, lua_map(im, "KEEPSAKE_ITEM_TO_ID").keys())
    # NPC attribution must agree for every keepsake that HAS a location.
    lua_npc = lua_map(im, "KEEPSAKE_TITLE_TO_NPC")
    for title, npc in Items.KEEPSAKE_NPC.items():
        if title in Items.KEEPSAKE_NO_LOCATION:
            continue
        if lua_npc.get(title) != npc:
            fail("keepsake-npc", f"{title!r}: Python NPC {npc!r} vs Lua {lua_npc.get(title)!r}")
    diff("keepsake-no-location", Items.KEEPSAKE_NO_LOCATION,
         lua_map(im, "KEEPSAKE_NO_LOCATION").keys())

    # ---- NPC cast / boss meets / route locks --------------------------------
    diff("npc-cast", Locations.NPC_CAST, lua_list(lm, "NPC_CAST"))
    py_boss = [name for name, _r, _z in Locations.NPC_BOSS_MEET]
    boss_chunk = _strip_comments(lua_table_chunk(lm, "BOSS_MET_BY_ZONE"))
    lua_boss = re.findall(r'"(Met [^"]+)"', boss_chunk)
    diff("boss-met", py_boss, lua_boss)
    diff("npc-route-lock", Routes.NPC_ROUTE_LOCK.keys(), lua_map(lm, "NPC_ROUTE_LOCK").keys())
    for npc, route in Routes.NPC_ROUTE_LOCK.items():
        lua_route = lua_map(lm, "NPC_ROUTE_LOCK").get(npc)
        if lua_route is not None and lua_route != route:
            fail("npc-route-lock", f"{npc!r}: Python {route!r} vs Lua {lua_route!r}")

    # ---- Incantations / arcana / vows / aspects / familiars ----------------
    py_inc = (list(Items.incantation_always) + list(Items.incantation_underworld)
              + list(Items.incantation_surface) + list(Items.incantation_keepsake_nonprog)
              + list(Items.incantation_nightmare))
    diff("incantations", py_inc, lua_map(im, "INCANTATION_ITEM_TO_ID").keys())
    diff("arcana", Items.arcana_titles, lua_map(im, "ARCANA_TITLE_TO_ID").keys())
    diff("vows", Items.vow_names, lua_map(im, "VOW_NAME_TO_ID").keys())
    diff("aspects", [t for t, _w in Items.aspect_titles], lua_map(im, "ASPECT_ITEM_TO_ID").keys())
    # aspect -> weapon attribution
    lua_aspects_by_weapon = {}
    abw_chunk = lua_table_chunk(im, "ASPECTS_BY_WEAPON")
    for weapon in Items.WEAPON_SHORT_NAMES:
        sub = lua_table_chunk(abw_chunk, weapon)
        lua_aspects_by_weapon[weapon] = re.findall(r'"([^"]+)"', _strip_comments(sub))
    aspect_id = lua_map(im, "ASPECT_ITEM_TO_ID")
    for title, weapon in Items.aspect_titles:
        internal = aspect_id.get(title)
        if internal and internal not in lua_aspects_by_weapon.get(weapon, []):
            fail("aspect-weapon", f"{title!r} ({internal}) not in Lua ASPECTS_BY_WEAPON[{weapon}]")
    diff("familiars", Items.familiar_names, lua_map(im, "FAMILIAR_ITEM_TO_ID").keys())
    diff("gods", [f"{god} Unlock" for god in Items.godsanity_gods],
         lua_map(im, "GOD_ITEM_TO_ID").keys())
    # Chaos shares the Lua map with Hermes/Selene: all three are existence-gated, outside the
    # 9-god Boon-door denominator.
    diff("shop-gods", [f"{god} Unlock" for god in Items.godsanity_shop_gods + [Items.GODSANITY_CHAOS]],
         lua_map(im, "SHOP_GOD_ITEM_TO_ID").keys())

    # ---- Traps ----------------------------------------------------------------
    # A trap the mod doesn't know is an "unknown item": received, never fired.
    diff("traps", Items.item_table_traps, lua_map(_lua_source("Traps.lua"), "Traps.ITEMS").keys())
    if "Traps.lua" not in imports:
        fail("traps", "Traps.lua is not imported by ready.lua")
    # The Cheats tab's "Fire trap" row keeps its own copy of the names (CheatClient.TRAP_NAMES).
    cheat_traps = re.search(r"^TRAP_NAMES = \(([^)]*)\)", (APWORLD / "CheatClient.py").read_text(encoding="utf-8"), re.M)
    diff("cheat-traps", Items.item_table_traps,
         re.findall(r'"([^"]+)"', cheat_traps.group(1)) if cheat_traps else [],
             lua_label="CheatClient.TRAP_NAMES")
    for name, data in Items.item_table_traps.items():
        if not data.trap or data.progression:
            fail("traps", f"{name!r} must be classified trap, not progression")

    # ---- Combined God Unlock + Keepsake --------------------------------------
    gkc_chunk = _strip_comments(lua_table_chunk(im, "GOD_KEEPSAKE_COMBINED"))
    lua_gkc_names = re.findall(r'\["([^"]+ Unlock \+ Keepsake)"\]\s*=\s*\{', gkc_chunk)
    diff("god-keepsake-combined",
         [f"{god} Unlock + Keepsake" for god in Items.GOD_KEEPSAKE_COMBINED_GODS],
         lua_gkc_names)
    for god, title in Items.GOD_KEEPSAKE_TITLE.items():
        name = f"{god} Unlock + Keepsake"
        m = re.search(re.escape(f'["{name}"]') + r'\s*=\s*\{([^}]*)\}', gkc_chunk)
        if not m:
            continue
        entry = m.group(1)
        god_m = re.search(r'god\s*=\s*"([^"]+)"', entry)
        keep_m = re.search(r'keepsake\s*=\s*"([^"]+)"', entry)
        if god_m and god_m.group(1) != f"{god} Unlock":
            fail("god-keepsake-combined", f"{name!r}: Lua god field {god_m.group(1)!r} vs {god} Unlock")
        if keep_m and keep_m.group(1) != title:
            fail("god-keepsake-combined", f"{name!r}: Lua keepsake field {keep_m.group(1)!r} vs {title!r}")

    # ---- Version stamps -------------------------------------------------------
    # The four places a release version lives. They drifted apart twice (7/16, 8/2), so they're
    # checked here rather than remembered. Bumping them is still a deliberate, user-directed act.
    stamps = {
        "__init__.py mod_version": re.search(r'mod_version\s*=\s*"([^"]+)"',
                                             (APWORLD / "__init__.py").read_text(encoding="utf-8")).group(1),
        "Client.py MOD_VERSION": re.search(r'^MOD_VERSION\s*=\s*"([^"]+)"',
                                           (APWORLD / "Client.py").read_text(encoding="utf-8"), re.M).group(1),
        "archipelago.json world_version": json.loads(
            (APWORLD / "archipelago.json").read_text(encoding="utf-8"))["world_version"],
        "manifest.json version_number": json.loads(
            (MOD / "manifest.json").read_text(encoding="utf-8"))["version_number"],
    }
    if len(set(stamps.values())) != 1:
        fail("versions", "version stamps disagree: " + ", ".join(f"{k}={v}" for k, v in stamps.items()))
    # Third-party mods whose tables/config the mod reaches into must be declared, or r2modman
    # won't install them and ReturnOfModding won't order them ahead of us.
    manifest = json.loads((MOD / "manifest.json").read_text(encoding="utf-8"))
    declared = {"-".join(d.split("-")[:2]) for d in manifest.get("dependencies", []) + manifest.get("rom_soft_deps", [])}
    for guid in ("zerp-NPCRoomRandomizer", "zerp-Extended_NPC_Encounters", "zerp-DreamDiveTweaks",
                 "NikkelM-Zagreus_Journey"):
        if guid not in declared:
            fail("dependencies", f"{guid} is used by the mod but not declared in manifest.json")

    # ---- Template YAML vs archipelago.json -----------------------------------
    # Templates are generated at packaging, after this check usually runs, so run it again with
    # the new one in Published Versions/v<world_version>/ (or pass it with --template).
    ap_manifest = json.loads((APWORLD / "archipelago.json").read_text(encoding="utf-8"))
    template_paths = sorted((PROJECT_ROOT / "Published Versions" / f"v{ap_manifest['world_version']}").glob("*.yaml"))
    for i, arg in enumerate(sys.argv):
        if arg == "--template" and i + 1 < len(sys.argv):
            template_paths.append(pathlib.Path(sys.argv[i + 1]))
    templates_checked = [p for p in template_paths
                         if check_template_requires(p, ap_manifest["minimum_ap_version"], ap_manifest["world_version"])]

    # ---- Id lock ------------------------------------------------------------
    current = id_snapshot(Items, loc_table)
    if "--update-id-lock" in sys.argv:
        write_id_lock(current)
    else:
        check_id_lock(current)

    # ---- Report -------------------------------------------------------------
    if failures:
        print(f"SYNC CHECK: {len(failures)} problem(s)\n")
        for f in failures:
            print("  " + f)
        return 1
    print("SYNC CHECK: all clean")
    print(f"  items: {len(codes)} unique codes; locations: {len(ids)} unique ids")
    print(f"  templates: {', '.join(str(p) for p in templates_checked) or 'none found to check'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
