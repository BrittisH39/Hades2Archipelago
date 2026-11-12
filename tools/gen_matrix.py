"""Generation matrix: build the apworld, install it into the local Archipelago, and run a real
ArchipelagoGenerate.exe over a fixed set of YAML combinations. Any case that prints a failure
marker (or exits non-zero, or writes no output zip) fails the run.

Usage:  python tools/gen_matrix.py [--seed N] [--only NAME_SUBSTRING] [--keep]
        (exit 0 = every case generated cleanly)

The installed Hades2Rogue.apworld is backed up (…apworld.bak_genmatrix_<timestamp>) before it is
replaced, unless it is already byte-identical to the fresh build. Other apworlds' manifest
warnings in the output are ignored -- only the markers below count.
"""
import argparse
import datetime
import pathlib
import shutil
import subprocess
import sys
import tempfile

PROJECT_ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_ROOT / "tools"))
import build_apworld  # noqa: E402

AP_DIR = pathlib.Path(r"C:\ProgramData\Archipelago")
GENERATE = AP_DIR / "ArchipelagoGenerate.exe"
INSTALLED = AP_DIR / "custom_worlds" / "Hades2Rogue.apworld"

ATTEMPTS = 5

FAIL_MARKERS = (
    "Traceback",
    "KeyError",
    "Unplaced items",
    "more items than locations",
    "Location Accessibility requirements not fulfilled",
)

UW_SF = ["Underworld", "Surface"]
ALL3 = ["Underworld", "Surface", "Nightmare"]

# name -> list of per-player option dicts (one YAML per player).
CASES = {
    "default": [{}],
    "nightmare_only": [{"include_zagreus_journey": True, "include_regions": ["Nightmare"],
                        "goals_required": ["Nightmare"], "starting_route": "nightmare"}],
    "aspect_combine": [{"location_system": "per_aspect_room_based", "separate_checks": "combine_pools",
                        "include_regions": UW_SF}],
    "multiworld_dream_plus_plain": [
        {"include_regions": ["Underworld", "Dream"], "goals_required": ["Underworld"],
         "dream_region_count": 6, "enemysanity": "shuffled_plus_locations", "include_minibosses": True},
        {},
    ],
}
for system in ("point_based", "room_based", "per_weapon_room_based", "per_aspect_room_based"):
    for pools in ("separate_pools", "combine_pools"):
        CASES[f"{system}_{pools}"] = [{"location_system": system, "separate_checks": pools,
                                       "include_regions": UW_SF}]
    CASES[f"{system}_all_routes"] = [{"location_system": system, "include_zagreus_journey": True,
                                      "include_regions": ALL3, "goals_required": ALL3}]
for lock in (True, False):
    CASES[f"dream_lock_{'on' if lock else 'off'}"] = [
        {"include_regions": ["Underworld", "Dream"], "goals_required": ["Underworld", "Dream"],
         "lock_routes": lock, "dream_region_count": 4}]
for count in (4, 8, 12):
    CASES[f"dream_{count}_no_nightmare"] = [
        {"include_regions": ["Underworld", "Dream"], "goals_required": ["Dream"],
         "dream_region_count": count, "dream_enemy_locations": count}]
    CASES[f"dream_{count}_with_nightmare"] = [
        {"include_zagreus_journey": True, "include_regions": ["Nightmare", "Dream"],
         "goals_required": ["Dream"], "dream_region_count": count, "dream_enemy_locations": count}]
for system in ("per_weapon_room_based", "per_aspect_room_based"):
    CASES[f"dream_{system}"] = [
        {"location_system": system, "include_regions": ["Underworld", "Dream"],
         "goals_required": ["Dream"], "dream_region_count": 6,
         "enemysanity": "shuffled_plus_locations", "include_minibosses": True}]
# Items that are only promoted to progression per seed (Grasp, Arcana, Keepsakes, Vow Removals)
# must still count in logic when core builds them through create_item: start_inventory_from_pool
# pulls the pool copies and pre-collects create_item() copies instead. Every Grasp moved this way
# used to leave the boss gates unsatisfiable.
CASES["start_inventory_from_pool_gating_items"] = [
    {"start_inventory_from_pool": {"Progressive Grasp": 6, "Progressive Death Arcana": 3,
                                   "Pain Vow Removal": 1}}]
# Filler remainder must not fall back to a filler the YAML set to 0%.
CASES["filler_nectar_zero"] = [{"nectar_pack_percentage": 0}]
for label, routes, zj in (("underworld", ["Underworld"], False), ("surface", ["Surface"], False),
                          ("all_routes", ALL3, True)):
    CASES[f"enemysanity_{label}"] = [
        {"enemysanity": "shuffled_plus_locations", "include_minibosses": True,
         "include_zagreus_journey": zj, "include_regions": routes, "goals_required": routes,
         "starting_route": "all"}]


def _yaml_value(v) -> str:
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, list):
        return "[" + ", ".join(f"'{x}'" for x in v) + "]"
    if isinstance(v, dict):
        return "{" + ", ".join(f"'{k}': {_yaml_value(x)}" for k, x in v.items()) + "}"
    return str(v)


def write_yamls(folder: pathlib.Path, players: list) -> None:
    for i, opts in enumerate(players, 1):
        lines = [f"name: P{i}", "game: Hades2Rogue", "Hades2Rogue:"]
        if not opts:
            lines[-1] += " {}"
        for k, v in opts.items():
            lines.append(f"  {k}: {_yaml_value(v)}")
        (folder / f"P{i}.yaml").write_text("\n".join(lines) + "\n", encoding="utf-8")


def install_build() -> None:
    build_dir = pathlib.Path(tempfile.mkdtemp(prefix="h2r_build_"))
    built = build_dir / "Hades2Rogue.apworld"
    build_apworld.build(built)
    if INSTALLED.exists() and INSTALLED.read_bytes() != built.read_bytes():
        stamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
        backup = INSTALLED.with_name(f"Hades2Rogue.apworld.bak_genmatrix_{stamp}")
        shutil.copy2(INSTALLED, backup)
        print(f"backed up installed apworld -> {backup.name}")
    shutil.copy2(built, INSTALLED)
    shutil.rmtree(build_dir, ignore_errors=True)
    print(f"installed fresh build -> {INSTALLED}")


def run_case(name: str, players: list, seed: int, keep: bool) -> tuple:
    work = pathlib.Path(tempfile.mkdtemp(prefix=f"h2r_gen_{name}_"))
    yamls, out = work / "players", work / "output"
    yamls.mkdir()
    out.mkdir()
    write_yamls(yamls, players)
    # Output goes straight to a log file; stdin gets one empty line (the exe waits for Enter
    # after an error).
    log_path = work / "generate.log"
    stdin_path = work / "stdin.txt"
    stdin_path.write_text("\n", encoding="utf-8")
    with open(log_path, "w", encoding="utf-8") as log_f, open(stdin_path, "r") as in_f:
        proc = subprocess.run(
            [str(GENERATE), "--player_files_path", str(yamls), "--outputpath", str(out),
             "--seed", str(seed), "--spoiler", "2"],
            stdin=in_f, stdout=log_f, stderr=subprocess.STDOUT, cwd=str(AP_DIR), timeout=900)
    log = log_path.read_text(encoding="utf-8", errors="replace")
    problems = [m for m in FAIL_MARKERS if m in log]
    if proc.returncode != 0:
        problems.append(f"exit code {proc.returncode}")
    if not any(out.glob("*.zip")):
        problems.append("no output zip")
    if not problems and not keep:
        shutil.rmtree(work, ignore_errors=True)
    return problems, work


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--only", default=None)
    ap.add_argument("--keep", action="store_true", help="keep work folders of passing cases too")
    args = ap.parse_args()

    install_build()
    failed = []
    flakes = 0
    for name, players in CASES.items():
        if args.only and args.only not in name:
            continue
        # Same seed + same YAMLs generate deterministically, so a real bug fails every attempt.
        # The frozen ArchipelagoGenerate.exe on this machine also crashes at random (native
        # 0xC0000005/0xC0000409, or nonsense tracebacks from a corrupted interpreter) -- those
        # pass on a retry and are only counted as flakes.
        history, crashed_dirs = [], []
        for _attempt in range(ATTEMPTS):
            problems, work = run_case(name, players, args.seed, args.keep)
            if not problems:
                break
            history.append(f"{', '.join(problems)}  (log: {work / 'generate.log'})")
            crashed_dirs.append(work)
        if problems:
            failed.append(name)
            print(f"FAIL {name}: failed {ATTEMPTS}/{ATTEMPTS} attempts")
            for h in history:
                print(f"       {h}")
        else:
            flakes += len(history)
            for d in crashed_dirs:
                shutil.rmtree(d, ignore_errors=True)
            print(f"ok   {name}" + (f"  (passed after {len(history)} crashed attempt(s))" if history else ""))
    print(f"\n{len(failed)} failed" + (f": {', '.join(failed)}" if failed else "")
          + f"; {flakes} flaky crash(es) retried")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
