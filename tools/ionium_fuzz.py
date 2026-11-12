"""Fuzz the apworld through the real Archipelago generator -- Generate.main + Main.main, the same call
the Ionium index CI's fuzzer makes -- on Ionium's own Archipelago fork. tools/fuzz_probe.py is quicker
but only runs the stock core's fill: the fork also FAILS a seed whose full-accessibility check finds
an unreachable location (stock only logs a warning), which is how 0.10.0 failed their CI while the
probe said it was clean (10/1, "Beat Zagreus" on Dream-only seeds).

Usage:
  python tools/ionium_fuzz.py N [FIRST_SEED]      N random YAMLs, drawn the way their fuzzer draws them
  python tools/ionium_fuzz.py yaml FILE [SEED]    replay one YAML (e.g. from a saved Waimea report)
  --with-empty    their "no-restrictive-starts" run: a second player with 100 free locations
  --apworld DIR   another source folder, e.g. an unzipped published build
  --stock         the frozen 0.6.7 core in C:\\ProgramData\\Archipelago instead of the fork
  --tag NAME      folder name for this run's failures (.build/ionium_fuzz_failures/NAME)

The fork is a trimmed source copy in .build/ionium_ap_f04b3a34 (commit f04b3a34, the one their CI and
aptests.ionium.fyi pin; only the core generator files, worlds/generic, worlds/apquest and test/).
Third-party packages still come from the frozen install. Nothing is installed and custom_worlds is
never touched.

Statuses: ok / option_error (not a failure) / FAIL. A FAIL whose error is nonsense (TypeError "object
is not iterable", "does not support the context manager protocol", a segfault) is this machine's
interpreter crashing, not the apworld: rerun that seed alone. Anything over 30 s is listed too -- their
CI stops a generation there.
"""
import importlib.util
import logging
import pathlib
import random
import shutil
import sys
import tempfile
import time
import traceback
import types
from argparse import Namespace

PROJECT_ROOT = pathlib.Path(__file__).resolve().parent.parent
AP_DIR = pathlib.Path(r"C:\ProgramData\Archipelago")
argv = sys.argv[1:]


def flag(name, takes_value):
    if name not in argv:
        return None
    at = argv.index(name)
    value = argv[at + 1] if takes_value else True
    del argv[at:at + (2 if takes_value else 1)]
    return value


APWORLD = pathlib.Path(flag("--apworld", True)
                       or PROJECT_ROOT / "Hades_2_Archipelago" / "Hades2Rogue_apworld")
FORK = None if flag("--stock", False) else str(PROJECT_ROOT / ".build" / "ionium_ap_f04b3a34")
WITH_EMPTY = flag("--with-empty", False)
TAG = flag("--tag", True) or "run"
sys.argv = sys.argv[:1]
# Frozen install LAST: it is only here for third-party packages (and, with --stock, the core).
# Ahead of the real stdlib it shadows it with another 3.13 patch's .pyc and .pyd files.
sys.path += [str(AP_DIR / "lib" / "library.zip"), str(AP_DIR / "lib")]
if FORK:
    sys.path.insert(0, FORK)
    # The fork's NetUtils encodes with orjson, which isn't installed here; generation never needs it.
    import json as _json
    _orjson = types.ModuleType("orjson")
    _orjson.OPT_NON_STR_KEYS = 0
    _orjson.dumps = lambda obj, default=None, option=0: _json.dumps(obj, default=default).encode()
    _orjson.loads = _json.loads
    sys.modules["orjson"] = _orjson
import Utils  # noqa: E402

core_root = pathlib.Path(FORK) if FORK else AP_DIR
_scratch = tempfile.mkdtemp(prefix="h2r_real_")
Utils.local_path.cached_path = _scratch
Utils.user_path.cached_path = _scratch
(pathlib.Path(_scratch) / "data").mkdir(exist_ok=True)
shutil.copy(core_root / "data" / "options.yaml", pathlib.Path(_scratch) / "data" / "options.yaml")

_worlds = types.ModuleType("worlds")
_worlds.__path__ = [str((pathlib.Path(FORK) if FORK else AP_DIR / "lib") / "worlds")]
_worlds.failed_world_loads = []
sys.modules["worlds"] = _worlds
from worlds.AutoWorld import AutoWorldRegister, World  # noqa: E402
from worlds import AutoWorld  # noqa: E402,F401
import worlds.generic  # noqa: E402,F401
import Options  # noqa: E402
from BaseClasses import Item, ItemClassification, Location, Region, PlandoOptions  # noqa: E402

_spec = importlib.util.spec_from_file_location(
    "worlds.hades2rogue_src", APWORLD / "__init__.py", submodule_search_locations=[str(APWORLD)])
_module = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = _module
_spec.loader.exec_module(_module)
GAME = "Hades2Rogue"
WORLD = AutoWorldRegister.world_types[GAME]

if WITH_EMPTY:
    class EmptyWorld(World):
        """Same shape as ionium-ap/empty-apworld."""
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

_worlds.network_data_package = {"games": {name: world.get_data_package_data()
                                          for name, world in AutoWorldRegister.world_types.items()}}
_worlds.AutoWorldRegister = AutoWorldRegister

_mu = types.ModuleType("ModuleUpdate")     # the real one wants a requirements scan / worlds folder
_mu.update = lambda *a, **k: None
sys.modules["ModuleUpdate"] = _mu

import yaml  # noqa: E402
from Generate import main as GenMain  # noqa: E402
from Main import main as ERmain  # noqa: E402

SKIP_TYPES = (Options.ItemSet, Options.LocationSet, Options.OptionDict)


def random_value(name, option, rng):
    """The Ionium fuzzer's get_random_value, for the option types this world has."""
    if name == "item_links" or issubclass(option, SKIP_TYPES):
        return option.default
    if issubclass(option, (Options.Choice, Options.Toggle)):
        keys = [k for k in option.options if k not in option.aliases] or list(option.options)
        return rng.choice(keys)
    if issubclass(option, Options.Range):
        return rng.randint(option.range_start, option.range_end)
    if issubclass(option, Options.OptionSet):
        keys = sorted(option.valid_keys)
        return rng.sample(keys, k=rng.randint(0, len(keys)))
    return option.default


def sanitize(value):
    if isinstance(value, (frozenset, set)):
        return sorted(value)
    return value


def random_yaml(rng):
    game_options = {}
    for group, options in Options.get_option_groups(WORLD).items():
        for name, option in options.items():
            game_options[name] = sanitize(random_value(name, option, rng))
    return {"description": "fuzz", "game": GAME, "requires": {"version": Utils.__version__}, GAME: game_options}


def call_generate(yaml_dir, out_dir, seed):
    args = Namespace(
        weights_file_path="weights-doesnt-exist.yaml", sameoptions=False, player_files_path=yaml_dir,
        seed=seed, multi=1, spoiler=1, outputpath=out_dir, race=False,
        meta_file_path="meta-doesnt-exist.yaml", log_level="info", yaml_output=1,
        plando=PlandoOptions.items | PlandoOptions.connections | PlandoOptions.texts | PlandoOptions.bosses,
        skip_prog_balancing=False, skip_output=False, csv_output=False, log_time=False, spoiler_only=False)
    erargs, seed = GenMain(args)
    return ERmain(erargs, seed)


def in_causes(e, ty, seen=None):
    seen = seen or set()
    while e is not None and id(e) not in seen:
        seen.add(id(e))
        if isinstance(e, ty):
            return True
        for x in getattr(e, "exceptions", ()) or ():
            if isinstance(x, BaseException) and in_causes(x, ty, seen):
                return True
        e = e.__cause__ or (None if e.__suppress_context__ else e.__context__)
    return False


def run(doc, seed):
    with tempfile.TemporaryDirectory(prefix="h2r_y_") as yd, tempfile.TemporaryDirectory(prefix="h2r_o_") as od:
        (pathlib.Path(yd) / "p1.yaml").write_text(yaml.safe_dump(doc, sort_keys=False), encoding="utf-8")
        if WITH_EMPTY:
            (pathlib.Path(yd) / "static.yaml").write_text(
                "name: Empty{number}\ngame: Empty\nEmpty: {}\n", encoding="utf-8")
        try:
            call_generate(yd, od, seed)
            return "ok", ""
        except Exception as e:
            if in_causes(e, Options.OptionError):
                return "option_error", str(e)[:200]
            return "FAIL", "".join(traceback.format_exception(e))
        finally:
            root = logging.getLogger()
            for h in root.handlers[:]:
                root.removeHandler(h)
                h.close()


def headline(detail):
    lines = [line for line in detail.strip().splitlines() if line.strip()]
    for line in reversed(lines):
        if "Error" in line or "Exception" in line:
            return line.strip()[:260]
    return lines[-1][:260] if lines else ""


def main():
    logging.disable(logging.CRITICAL)
    if argv[0] == "yaml":
        doc = yaml.safe_load(pathlib.Path(argv[1]).read_text(encoding="utf-8"))
        status, detail = run(doc, int(argv[2]) if len(argv) > 2 else 1)
        print(status, detail)
        return
    count, first = int(argv[0]), int(argv[1]) if len(argv) > 1 else 1
    tally, slowest, slow = {}, (0.0, None), 0
    fail_dir = PROJECT_ROOT / ".build" / "ionium_fuzz_failures" / TAG
    fail_dir.mkdir(parents=True, exist_ok=True)
    for seed in range(first, first + count):
        doc = random_yaml(random.Random(seed))
        t = time.perf_counter()
        status, detail = run(doc, seed)
        took = time.perf_counter() - t
        slowest = max(slowest, (took, seed))
        slow += took > 30
        tally[status] = tally.get(status, 0) + 1
        if status == "FAIL" or took > 30:
            (fail_dir / f"{seed}.yaml").write_text(yaml.safe_dump(doc, sort_keys=False), encoding="utf-8")
            (fail_dir / f"{seed}.txt").write_text(f"{took:.1f}s {status}\n{detail}", encoding="utf-8")
            print(f"seed {seed} {status} {took:.1f}s: {headline(detail)}", flush=True)
    print(f"TALLY[{TAG}] {tally} over30s={slow} SLOWEST {slowest[0]:.1f}s (seed {slowest[1]})", flush=True)


if __name__ == "__main__":
    main()
