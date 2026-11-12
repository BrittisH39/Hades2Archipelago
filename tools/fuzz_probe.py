"""Fuzz the working-tree apworld in-process: random option sets through a real Archipelago
generation + fill, without installing anything into custom_worlds (reference: the Ionium fuzz
report, 10/1 -- item/location count mismatches and non-deterministic generation).

Usage:
  python tools/fuzz_probe.py fuzz N [FIRST_SEED]         N random YAMLs; prints every failure + a tally
  python tools/fuzz_probe.py determinism N [FIRST_SEED]  same seeds in two processes with different
                                                         PYTHONHASHSEED; any difference is a failure
  python tools/fuzz_probe.py yaml FILE [SEED]            replay one YAML (unknown options are listed)
  (add --apworld DIR to test another source folder, e.g. an unzipped published build)
  (add --with-empty for the index CI's "no-restrictive-starts" run: a second player whose world is
   100 free locations, so every seed is a two-player multiworld)

Statuses: ok / option_error (the YAML was rejected with a clear message -- not a failure) /
count (itempool size != fillable locations) / fill (FillError) / unbeatable / accessibility (a
location nobody can reach on a full-accessibility seed) / indirect (an entrance
rule reaches into another region without register_indirect_condition) / crash.
The frozen core on this machine is run from C:\\ProgramData\\Archipelago\\lib, read-only.
"""
import hashlib
import importlib.util
import json
import logging
import os
import pathlib
import random
import subprocess
import sys
import tempfile
import time
import traceback
import types
from argparse import Namespace

PROJECT_ROOT = pathlib.Path(__file__).resolve().parent.parent
AP_DIR = pathlib.Path(r"C:\ProgramData\Archipelago")
GAME = "Hades2Rogue"

argv = sys.argv[1:]
APWORLD = PROJECT_ROOT / "Hades_2_Archipelago" / "Hades2Rogue_apworld"
if "--apworld" in argv:
    at = argv.index("--apworld")
    APWORLD = pathlib.Path(argv[at + 1])
    del argv[at:at + 2]
WITH_EMPTY = "--with-empty" in argv
if WITH_EMPTY:
    argv.remove("--with-empty")
sys.argv = sys.argv[:1]     # Archipelago's own modules parse sys.argv on import

sys.path[:0] = [str(AP_DIR / "lib" / "library.zip"), str(AP_DIR / "lib")]
import Utils  # noqa: E402

# Nothing reads or writes the real host.yaml.
_scratch = tempfile.mkdtemp(prefix="h2r_fuzz_")
Utils.local_path.cached_path = _scratch
Utils.user_path.cached_path = _scratch

# A bare `worlds` package, so no installed world (custom_worlds included) gets loaded.
_worlds = types.ModuleType("worlds")
_worlds.__path__ = [str(AP_DIR / "lib" / "worlds")]
sys.modules["worlds"] = _worlds

from worlds.AutoWorld import AutoWorldRegister, call_all  # noqa: E402
import worlds.generic  # noqa: E402,F401
from BaseClasses import MultiWorld, CollectionState  # noqa: E402
import Fill  # noqa: E402
import Options  # noqa: E402

_spec = importlib.util.spec_from_file_location(
    "worlds.hades2rogue_src", APWORLD / "__init__.py", submodule_search_locations=[str(APWORLD)])
_module = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = _module
_spec.loader.exec_module(_module)
WORLD = AutoWorldRegister.world_types[GAME]
logging.disable(logging.CRITICAL)

if WITH_EMPTY:
    from worlds.AutoWorld import World  # noqa: E402
    from BaseClasses import Item, ItemClassification, Location, Region  # noqa: E402

    class EmptyWorld(World):
        """Same shape as ionium-ap/empty-apworld: 100 free locations, 100 items, one of them the goal."""
        game = "Empty"
        options_dataclass = Options.PerGameCommonOptions
        location_name_to_id = {f"Loc{i}": i for i in range(1, 101)}
        item_name_to_id = {f"Item{i}": i for i in range(1, 101)}

        def create_item(self, name):
            classification = ItemClassification.progression if name == "Item69" else ItemClassification.filler
            return Item(name, classification, self.item_name_to_id[name], self.player)

        def create_items(self):
            self.multiworld.itempool += [self.create_item(name) for name in self.item_name_to_id]

        def create_regions(self):
            region = Region("Menu", self.player, self.multiworld)
            self.multiworld.regions.append(region)
            region.add_locations(dict(self.location_name_to_id), Location)

        def set_rules(self):
            self.multiworld.completion_condition[self.player] = lambda state: state.has("Item69", self.player)

GAMES = {1: GAME, 2: "Empty"} if WITH_EMPTY else {1: GAME}

# Core options a fuzzed YAML leaves at their defaults.
SKIP = {"local_items", "non_local_items", "start_inventory", "start_inventory_from_pool", "start_hints",
        "start_location_hints", "exclude_locations", "priority_locations", "item_links", "plando_items"}
BRIEF = ("location_system", "separate_checks", "include_regions", "goals_required", "goal_mode",
         "goal_requires_zagreus", "include_zagreus_journey", "lock_routes", "starting_route",
         "aspectsanity", "keepsakesanity", "npc_locations", "enemysanity", "accessibility")


def random_options(rng: random.Random) -> dict:
    out = {}
    for name, option in WORLD.options_dataclass.type_hints.items():
        if name in SKIP:
            continue
        if issubclass(option, Options.OptionSet):
            # Same draw as the Ionium fuzzer: every set size equally likely, so empty and full sets are common.
            keys = sorted(option.valid_keys)
            out[name] = rng.sample(keys, k=rng.randint(0, len(keys)))
        elif issubclass(option, Options.Range):
            out[name] = rng.randint(option.range_start, option.range_end)
        elif issubclass(option, (Options.Choice, Options.Toggle)):
            out[name] = rng.choice(sorted(option.name_lookup.values()))
    return out


def generate(values: dict, seed: int) -> MultiWorld:
    """Everything Main.py does up to (not including) the fill. Player 1 is the fuzzed YAML."""
    mw = MultiWorld(len(GAMES))
    for player, game in GAMES.items():
        mw.game[player] = game
    mw.player_name = {player: f"P{player}" for player in GAMES}
    mw.set_seed(seed)
    args = Namespace()
    for player, game in GAMES.items():
        for name, option in AutoWorldRegister.world_types[game].options_dataclass.type_hints.items():
            value = values.get(name, option.default) if player == 1 else option.default
            vars(args).setdefault(name, {})[player] = option.from_any(value)
    mw.set_options(args)
    mw.state = CollectionState(mw)
    for step in ("generate_early", "create_regions", "create_items", "set_rules", "connect_entrances",
                 "generate_basic", "pre_fill"):
        call_all(mw, step)
    return mw


def run_one(values: dict, seed: int) -> tuple:
    """-> (status, detail, digest). digest covers everything the Ionium determinism hook compares:
    itempool order and classifications, start inventory, entrances, location order, placements --
    plus slot_data."""
    try:
        mw = generate(values, seed)
    except Options.OptionError as e:
        return "option_error", str(e), ""
    except Exception:
        return "crash", traceback.format_exc(), ""
    pool = [(item.name, item.player, int(item.classification)) for item in mw.itempool]
    open_locations = sum(1 for loc in mw.get_locations() if loc.item is None)
    if len(pool) != open_locations:
        return "count", f"items={len(pool)} locations={open_locations} ({len(pool) - open_locations:+d})", ""
    try:
        Fill.distribute_items_restrictive(mw)
        if mw.players > 1:
            Fill.balance_multiworld_progression(mw)
        call_all(mw, "post_fill")
    except Fill.FillError as e:
        return "fill", str(e)[:300], ""
    except Exception:
        return "crash", traceback.format_exc(), ""
    if any(loc.item is None for loc in mw.get_locations()):
        return "fill", "unfilled locations", ""
    if not mw.can_beat_game(CollectionState(mw)):
        return "unbeatable", "", ""
    if not mw.fulfills_accessibility():
        # Stock Archipelago only logs a warning here; the Ionium fork fails the seed with a FillError.
        swept = CollectionState(mw)
        swept.sweep_for_advancements()
        missing = [loc.name for loc in mw.get_locations() if not loc.can_reach(swept)]
        return "accessibility", f"unreachable: {missing[:5]}", ""
    world = mw.worlds[1]
    if world.explicit_indirect_conditions:
        explicit = sphere_names(mw)
        world.explicit_indirect_conditions = False
        implicit = sphere_names(mw)
        world.explicit_indirect_conditions = True
        if explicit != implicit:
            return "indirect", f"{len(explicit)} spheres explicit, {len(implicit)} implicit", ""
    blob = json.dumps({
        "pool": pool,
        "precollected": [item.name for item in mw.precollected_items[1]],
        "entrances": [(entrance.name, entrance.player, entrance.parent_region.name,
                       entrance.connected_region.name) for entrance in mw.get_entrances()],
        "placements": [(loc.name, loc.player, loc.item.name, loc.item.player, int(loc.progress_type))
                       for loc in mw.get_locations()],
        "slot_data": world.fill_slot_data(),
    }, default=sorted, sort_keys=True)
    return "ok", "", hashlib.sha1(blob.encode()).hexdigest()[:16]


def sphere_names(mw: MultiWorld) -> list:
    return [frozenset((loc.name, loc.player) for loc in sphere) for sphere in mw.get_spheres()]


def fuzz(count: int, first: int, digests: bool) -> int:
    tally = {}
    slowest = (0.0, None)       # the index CI kills a generation after 15 s
    for seed in range(first, first + count):
        values = random_options(random.Random(seed))
        started = time.perf_counter()
        status, detail, digest = run_one(values, seed)
        slowest = max(slowest, (time.perf_counter() - started, seed))
        tally[status] = tally.get(status, 0) + 1
        if digests:
            print(seed, status, digest, flush=True)
        elif status not in ("ok", "option_error"):
            print(f"seed {seed}: {status} {detail}\n    { {k: values[k] for k in BRIEF if k in values} }",
                  flush=True)
    if not digests:
        print("TALLY", tally)
        print(f"SLOWEST {slowest[0]:.1f}s (seed {slowest[1]})")
    return sum(n for status, n in tally.items() if status not in ("ok", "option_error"))


def determinism(count: int, first: int) -> int:
    """Set order follows the string hash, which Python re-seeds per process -- so the same seeds
    run under two PYTHONHASHSEED values must agree line for line."""
    runs = []
    for hash_seed in ("1", "2"):
        out = subprocess.run(
            [sys.executable, __file__, "digests", str(count), str(first), "--apworld", str(APWORLD)]
            + (["--with-empty"] if WITH_EMPTY else []),
            env=dict(os.environ, PYTHONHASHSEED=hash_seed), capture_output=True, text=True)
        runs.append(out.stdout.splitlines())
    different = [(a, b) for a, b in zip(*runs) if a != b]
    for a, b in different:
        print("DIFFERS", a, "|", b)
    print(f"{len(runs[0])} seeds, {len(different)} differ between processes")
    return len(different) + (0 if runs[0] else 1)


def main() -> int:
    mode = argv[0]
    if mode == "yaml":
        import yaml
        doc = yaml.safe_load(pathlib.Path(argv[1]).read_text(encoding="utf-8"))
        known = WORLD.options_dataclass.type_hints
        print("unknown options (ignored):", sorted(k for k in doc[GAME] if k not in known))
        values = {k: v for k, v in doc[GAME].items() if k in known}
        status, detail, _digest = run_one(values, int(argv[2]) if len(argv) > 2 else 1)
        print(status, detail)
        return 0 if status in ("ok", "option_error") else 1
    count = int(argv[1])
    first = int(argv[2]) if len(argv) > 2 else 1
    if mode == "determinism":
        return 1 if determinism(count, first) else 0
    return 1 if fuzz(count, first, digests=(mode == "digests")) else 0


if __name__ == "__main__":
    sys.exit(main())
