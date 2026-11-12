"""
Offline check of the client's version handshake (0.11.0 group D).

    python tools/version_check.py

Loads the working-tree apworld against the frozen Archipelago core in C:\\ProgramData\\Archipelago
(read-only, nothing installed, host.yaml untouched) and drives the real Hades2Context:
  * mod vs apworld vs seed version comparison (HELLO payloads from old and new mods);
  * the error box (gui_error is recorded, not drawn) and the ALERT banner sent to the game;
  * "Unknown location" checks, both "apworld never heard of it" and "not in this seed";
  * a real TCP round trip on a spare port, with the HELLO line Bridge.lua builds;
  * duplicate-apworld detection over fake worlds/ and custom_worlds/ folders.
tools/version_check_harness.lua covers the mod side (Bridge.lua).
"""
import asyncio
import importlib
import importlib.util
import logging
import pathlib
import shutil
import sys
import tempfile
import types
import zipfile

PROJECT_ROOT = pathlib.Path(__file__).resolve().parent.parent
AP_DIR = pathlib.Path(r"C:\ProgramData\Archipelago")
APWORLD = PROJECT_ROOT / "Hades_2_Archipelago" / "Hades2Rogue_apworld"
PUBLISHED = PROJECT_ROOT / "Published Versions"
sys.argv = sys.argv[:1]

sys.path[:0] = [str(AP_DIR / "lib" / "library.zip"), str(AP_DIR / "lib")]
import Utils  # noqa: E402

_scratch = tempfile.mkdtemp(prefix="h2r_version_")
Utils.local_path.cached_path = _scratch
Utils.user_path.cached_path = _scratch
_mu = types.ModuleType("ModuleUpdate")
_mu.update = lambda *a, **k: None
sys.modules["ModuleUpdate"] = _mu

_worlds = types.ModuleType("worlds")
_worlds.__path__ = [str(AP_DIR / "lib" / "worlds")]
sys.modules["worlds"] = _worlds
from worlds.AutoWorld import AutoWorldRegister  # noqa: E402
import worlds.generic  # noqa: E402,F401
# What CommonClient imports from the real package.
_worlds.network_data_package = {"games": {}}
_worlds.AutoWorldRegister = AutoWorldRegister

_spec = importlib.util.spec_from_file_location(
    "worlds.hades2rogue_src", APWORLD / "__init__.py", submodule_search_locations=[str(APWORLD)])
_module = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = _module
_spec.loader.exec_module(_module)
_worlds.network_data_package["games"].update(
    {name: world.get_data_package_data() for name, world in AutoWorldRegister.world_types.items()})
Client = importlib.import_module("worlds.hades2rogue_src.Client")
WORLD = AutoWorldRegister.world_types["Hades2Rogue"]
logging.getLogger("Client").setLevel(logging.CRITICAL)
logging.getLogger().setLevel(logging.CRITICAL)

passes, failures = 0, 0


def check(cond, label):
    global passes, failures
    if cond:
        passes += 1
    else:
        failures += 1
        print("FAIL:", label)


def said(key):
    """The fixed text an ALERT_TEXT message starts with (everything before its first field)."""
    return Client.ALERT_TEXT[key].split("{")[0]


class Writer:
    """Stands in for the bridge's StreamWriter: records each line sent to the game."""
    def __init__(self):
        self.lines = []

    def write(self, data):
        self.lines += [l for l in data.decode("utf-8").split("\n") if l]

    def close(self):
        pass

    def alerts(self):
        return [l for l in self.lines if l.startswith("ALERT:")]


def new_ctx(apworld="0.11.0"):
    ctx = Client.Hades2Context(None, None)
    ctx.mod_version = apworld
    ctx.boxes = []
    ctx.gui_error = lambda title, text: ctx.boxes.append((title, text))

    async def no_sync():
        pass
    ctx.sync_mod = no_sync
    ctx.bridge_writer = Writer()
    return ctx


async def hello(ctx, payload, new_connection=False):
    if new_connection:      # what handle_bridge_connection resets
        ctx.bridge_writer = Writer()
        ctx.mod_said_hello, ctx.mod_reported_version, ctx.mod_alerts = False, None, False
        ctx.mod_bannered = set()
    await ctx.handle_mod_message("HELLO" + (":" + payload if payload is not None else ""))


def connected(ctx, seed_version):
    # The version part of on_package("Connected"); the rest needs a live server.
    ctx.slot_data = {"version_check": seed_version} if seed_version is not None else {}
    ctx.check_versions()


async def main():
    # ---- release lines
    check(Client._release_line("0.11.0") == (0, 11), "release line 0.11.0")
    check(Client._release_line("0.10.1") == (0, 10), "release line 0.10.1")
    check(Client._release_line("?") is None and Client._release_line(None) is None, "no release line")

    # ---- matching versions: nothing shown
    ctx = new_ctx()
    await hello(ctx, "journal,alert,version=0.11.0")
    connected(ctx, "0.11.0")
    check(ctx.boxes == [] and ctx.bridge_writer.alerts() == [], "all 0.11.0: no box, no banner")

    # ---- patch-only difference: log line, no box
    ctx = new_ctx()
    await hello(ctx, "journal,alert,version=0.11.1")
    connected(ctx, "0.11.0")
    check(ctx.boxes == [] and ctx.bridge_writer.alerts() == [], "patch difference: no box")
    check(any(said("patch_difference") in n for n in ctx.version_notes), "patch difference: logged")

    # ---- old mod (0.10.x HELLO:journal, no version): box, no banner (it can't show one)
    ctx = new_ctx()
    await hello(ctx, "journal")
    check(len(ctx.boxes) == 1 and said("mod_unreported") in ctx.boxes[0][1], "old mod: box shown")
    check(ctx.bridge_writer.alerts() == [], "old mod: no ALERT sent (no alert capability)")
    check(ctx.boxes[0][0] == Client.ALERT_TITLE, "box title")
    # a pre-journal mod sends a bare HELLO
    ctx2 = new_ctx()
    await hello(ctx2, None)
    check(len(ctx2.boxes) == 1 and said("mod_unreported") in ctx2.boxes[0][1], "bare HELLO: box shown")
    # same old mod reconnecting (every save load): not shown again
    await hello(ctx, "journal", new_connection=True)
    check(len(ctx.boxes) == 1, "old mod reconnect: no second box")
    # seed arrives too, from another release: one box listing both
    connected(ctx, "0.10.0")
    check(len(ctx.boxes) == 2 and said("mod_unreported") in ctx.boxes[-1][1] and said("seed_mismatch") in ctx.boxes[-1][1],
          "old mod + old seed: box lists both")

    # ---- new mod from another release line: box + one banner per connection
    ctx = new_ctx()
    await hello(ctx, "journal,alert,version=0.12.0")
    check(len(ctx.boxes) == 1 and said("mod_mismatch") + "0.12.0" in ctx.boxes[0][1], "mod mismatch: box")
    check(len(ctx.bridge_writer.alerts()) == 1 and said("banner_version") in ctx.bridge_writer.alerts()[0], "mod mismatch: banner")
    await hello(ctx, "journal,alert,version=0.12.0")   # resync on the same connection
    check(len(ctx.bridge_writer.alerts()) == 1, "same connection: banner not repeated")
    await hello(ctx, "journal,alert,version=0.12.0", new_connection=True)
    check(len(ctx.bridge_writer.alerts()) == 1 and len(ctx.boxes) == 1, "new connection: banner again, box not")
    # the seed then shows up from yet another release: new box, new banner
    connected(ctx, "0.9.3")
    check(len(ctx.boxes) == 2 and said("seed_mismatch") in ctx.boxes[-1][1], "seed mismatch after mod mismatch: box")
    check(len(ctx.bridge_writer.alerts()) == 2, "seed mismatch: banner")

    # ---- seed mismatch before the game connects
    ctx = new_ctx()
    ctx.bridge_writer = None
    connected(ctx, "0.10.1")
    check(len(ctx.boxes) == 1 and said("seed_mismatch") in ctx.boxes[0][1], "seed mismatch, game not connected: box")
    ctx.bridge_writer = Writer()
    await hello(ctx, "journal,alert,version=0.11.0")
    check(len(ctx.boxes) == 1 and len(ctx.bridge_writer.alerts()) == 1, "game connects later: banner, no new box")
    ctx = new_ctx()
    connected(ctx, None)
    check(len(ctx.boxes) == 1 and "seed ?" not in ctx.boxes[0][1] and "?" in ctx.boxes[0][1],
          "seed without version_check: box")

    # ---- mod couldn't read its manifest: log line only
    ctx = new_ctx()
    await hello(ctx, "journal,alert,version=unknown")
    connected(ctx, "0.11.0")
    check(ctx.boxes == [] and any(said("mod_unknown") in n for n in ctx.version_notes), "unknown mod version: logged only")

    # ---- unknown locations
    ctx = new_ctx()
    await hello(ctx, "journal,alert,version=0.11.0")
    ctx.location_name_to_id = {"Surface Ephyra Room 01": 1}
    await ctx.handle_mod_message("CHECK:Surface Room 0001")       # a 0.9.x name
    check(len(ctx.boxes) == 1 and said("unknown_location") in ctx.boxes[0][1] and "Surface Room 0001" in ctx.boxes[0][1],
          "unknown-to-apworld location: box")
    check(len(ctx.bridge_writer.alerts()) == 1 and said("banner_unknown_location") in ctx.bridge_writer.alerts()[0], "unknown location: banner")
    await ctx.handle_mod_message("CHECK:Surface Room 0002")
    check(len(ctx.boxes) == 1 and len(ctx.bridge_writer.alerts()) == 1, "second unknown location: quiet")
    real_name = next(n for n in sorted(WORLD.location_name_to_id) if n not in ctx.location_name_to_id)
    ctx = new_ctx()
    await hello(ctx, "journal")
    connected(ctx, "0.11.0")
    ctx.boxes.clear()
    ctx.location_name_to_id = {"Surface Ephyra Room 01": 1}
    await ctx.handle_mod_message("CHECK:" + real_name)
    check(len(ctx.boxes) == 1 and said("unknown_in_seed") in ctx.boxes[0][1], f"known-to-apworld, not in seed ({real_name}): box")
    check(ctx.bridge_writer.alerts() == [], "old mod: unknown location sends no ALERT")
    # buffered pre-connect checks take the same path
    ctx = new_ctx()
    ctx.location_name_to_id = {"Surface Ephyra Room 01": 1}
    await ctx._flush_pending_checks(["Surface Room 0001"])
    check(len(ctx.boxes) == 1 and said("unknown_location") in ctx.boxes[0][1], "buffered unknown location: box")

    # ---- the real gui_error with no window doesn't throw
    plain = Client.Hades2Context(None, None)
    try:
        plain.alert_player("x", "text")
        check(True, "")
    except Exception as exc:
        check(False, f"alert_player without a UI raised {exc!r}")

    # ---- real TCP round trip with Bridge.lua's HELLO
    manifest = (APWORLD.parent / "Hades2Rogue_mod" / "manifest.json").read_text(encoding="utf-8")
    import json
    mod_version = json.loads(manifest)["version_number"]
    Client.BRIDGE_PORT = 43155
    ctx = new_ctx(apworld="0.11.0")
    ctx.bridge_writer = None
    await ctx.start_bridge_server()
    reader, writer = await asyncio.open_connection("127.0.0.1", 43155)
    writer.write(f"HELLO:journal,alert,version={mod_version}\n".encode())
    await writer.drain()
    expect_alert = Client._release_line(mod_version) != (0, 11)
    if expect_alert:
        line = (await asyncio.wait_for(reader.readline(), 5)).decode().strip()
        check(line.startswith("ALERT:") and mod_version in line, f"TCP: ALERT for mod {mod_version}: {line!r}")
    else:
        # The mod's manifest is on this release line: the client has nothing to warn about.
        try:
            line = (await asyncio.wait_for(reader.readline(), 1)).decode().strip()
        except asyncio.TimeoutError:
            line = ""
        check(not line.startswith("ALERT:"), f"TCP: no ALERT for a matching mod {mod_version}: {line!r}")
    check(ctx.mod_reported_version == mod_version and ctx.mod_alerts, "TCP: HELLO parsed")
    writer.close()
    ctx.bridge_server.close()

    # ---- duplicate apworlds
    root = pathlib.Path(_scratch)
    lib_worlds, custom = root / "lib_worlds", root / "custom_worlds"
    lib_worlds.mkdir()
    custom.mkdir()
    shutil.copy(PUBLISHED / "v0.10.1" / "Hades2Rogue.apworld", custom / "Hades2Rogue.apworld")
    shutil.copy(PUBLISHED / "v0.9.3" / "Hades2Rogue.apworld", custom / "Hades2Rogue (1).apworld")
    shutil.copy(PUBLISHED / "v0.9.3" / "Hades2Rogue.apworld", custom / "Hades2Rogue.apworld.bak")  # not loaded
    shutil.copy(PUBLISHED / "v0.9.3" / "Hades2Rogue.apworld", custom / "_Hades2Rogue.apworld")     # skipped
    shutil.copy(PUBLISHED / "v0.7.0" / "Hades2Rogue.apworld", lib_worlds / "hades2rogue.apworld")  # no manifest
    with zipfile.ZipFile(custom / "other.apworld", "w") as z:
        z.writestr("other/", "")
        z.writestr("other/archipelago.json", '{"game": "Other", "world_version": "1.0.0"}')
        z.writestr("other/__init__.py", 'game = "Other"\n')
    (lib_worlds / "hades2rogue_dev").mkdir()
    shutil.copy(APWORLD / "archipelago.json", lib_worlds / "hades2rogue_dev" / "archipelago.json")
    (lib_worlds / "hades2rogue_dev" / "__init__.py").write_text("", encoding="utf-8")
    (lib_worlds / "not_a_world").mkdir()
    sys.modules["worlds"].local_folder = str(lib_worlds)
    sys.modules["worlds"].user_folder = str(custom)
    copies = Client.find_installed_copies()
    names = sorted(pathlib.Path(p).name for p, _ in copies)
    check(names == ["Hades2Rogue (1).apworld", "Hades2Rogue.apworld", "hades2rogue.apworld", "hades2rogue_dev"],
          f"copies found: {names}")
    versions = {pathlib.Path(p).name: v for p, v in copies}
    check(versions.get("Hades2Rogue.apworld") == "0.10.1" and versions.get("Hades2Rogue (1).apworld") == "0.9.3"
          and versions.get("hades2rogue.apworld") == "?", f"copy versions: {versions}")
    ctx = new_ctx()
    Client.asyncio.sleep = _no_sleep
    Client._loaded_world_file = lambda: str(custom / "Hades2Rogue (1).apworld" / "Hades2Rogue" / "__init__.py")
    await ctx.check_installed_copies()
    check(len(ctx.boxes) == 1 and said("duplicate_apworld") in ctx.boxes[0][1], "duplicates: box")
    loaded_line = next((l for l in ctx.boxes[0][1].splitlines() if "<- loaded" in l), "") if ctx.boxes else ""
    check("Hades2Rogue (1).apworld" in loaded_line, f"duplicates: loaded copy marked ({loaded_line!r})")
    # one copy: nothing
    for p, _ in copies:
        if pathlib.Path(p).name != "Hades2Rogue.apworld":
            shutil.rmtree(p) if pathlib.Path(p).is_dir() else pathlib.Path(p).unlink()
    ctx = new_ctx()
    await ctx.check_installed_copies()
    check(ctx.boxes == [], "single copy: no box")


_real_sleep = asyncio.sleep


async def _no_sleep(_seconds):
    await _real_sleep(0)


asyncio.run(main())
shutil.rmtree(_scratch, ignore_errors=True)
print(f"{passes} passed, {failures} failed")
sys.exit(1 if failures else 0)
