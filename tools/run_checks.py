"""Run every offline check in tools/ against the working tree and print one summary.

Usage:  python -I tools/run_checks.py             (exit 0 = every check passed)
        python -I tools/run_checks.py --fuzz      (also: fuzz_probe fuzz 100 + determinism 40)
        python -I tools/run_checks.py --plugins DIR   (r2modman plugins folder; default: Default profile)

Covers: luac -p on every mod file, the Lua harnesses (each with the arguments it needs), and the
Python checks (sync_check, journal_check, tracker_check, version_check). Harnesses that read an
installed dependency (Zagreus' Journey, SharedKeepsakePort) take it from the plugins folder; when
it's missing they're reported as skipped, not failed. Nothing is installed or deployed.
"""
import argparse
import ast
import os
import re
import pathlib
import subprocess
import sys
import time

TOOLS = pathlib.Path(__file__).resolve().parent
ROOT = TOOLS.parent
MOD = ROOT / "Hades_2_Archipelago" / "Hades2Rogue_mod"
DEFAULT_PLUGINS = pathlib.Path(os.environ.get("APPDATA", "")) / (
    "r2modmanPlus-local/HadesII/profiles/Default/ReturnOfModding/plugins")


def fuzz_passed(lines) -> bool:
    """fuzz_probe exits 0 either way: 'TALLY {...}' may hold only ok/option_error, and
    determinism prints 'N seeds, 0 differ between processes'."""
    for line in reversed(lines):
        if line.startswith("TALLY "):
            tally = ast.literal_eval(line[len("TALLY "):])
            return set(tally) <= {"ok", "option_error"}
        m = re.search(r"(\d+) differ", line)
        if m:
            return m.group(1) == "0"
    return False


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--plugins", default=str(DEFAULT_PLUGINS))
    ap.add_argument("--fuzz", action="store_true")
    opts = ap.parse_args()
    plugins = pathlib.Path(opts.plugins)
    zj = plugins / "NikkelM-Zagreus_Journey"
    skp = plugins / "zannc-SharedKeepsakePort"
    py = [sys.executable, "-I"]

    checks = []  # (name, argv or None, why skipped)
    for f in sorted(MOD.glob("*.lua")):
        checks.append((f"luac -p {f.name}", ["luac", "-p", str(f)], None))
    checks += [
        ("enemysanity_count_harness", ["lua", "enemysanity_count_harness.lua", str(MOD)], None),
        ("goals_harness", ["lua", "goals_harness.lua", str(MOD)], None),
        ("miniboss_rooms_harness", ["lua", "miniboss_rooms_harness.lua", str(MOD), "100"], None),
        ("spawn_retry_harness", ["lua", "spawn_retry_harness.lua", str(MOD / "reload.lua")], None),
        ("trap_harness", ["lua", "trap_harness.lua", str(MOD)], None),
        ("version_check_harness", ["lua", "version_check_harness.lua"], None),
        ("vow_floor_harness", ["lua", "vow_floor_harness.lua", str(MOD / "ItemManager.lua")], None),
        ("keepsake_harness", ["lua", "keepsake_harness.lua", str(MOD), str(skp)],
         None if skp.is_dir() else f"no {skp.name} in {plugins}"),
        ("zj_unit_hooks_harness", ["lua", "zj_unit_hooks_harness.lua", str(MOD / "EnemySanity.lua"), str(zj)],
         None if zj.is_dir() else f"no {zj.name} in {plugins}"),
        ("gather_gate_harness", ["lua", "gather_gate_harness.lua", str(MOD / "ItemManager.lua"), str(zj)],
         None if zj.is_dir() else f"no {zj.name} in {plugins}"),
        ("sync_check", py + ["sync_check.py"], None),
        ("journal_check", py + ["journal_check.py"], None),
        ("tracker_check", py + ["tracker_check.py"], None),
        ("version_check", py + ["version_check.py"], None),
    ]
    if opts.fuzz:
        checks += [
            ("fuzz_probe fuzz 100", py + ["fuzz_probe.py", "fuzz", "100", "41001"], None),
            ("fuzz_probe determinism 40", py + ["fuzz_probe.py", "determinism", "40", "42001"], None),
        ]

    results = []
    for name, argv, skip in checks:
        if skip:
            results.append((name, "skip", skip, 0.0))
            continue
        start = time.time()
        try:
            proc = subprocess.run(argv, cwd=TOOLS, capture_output=True, text=True,
                                  encoding="utf-8", errors="replace", timeout=1800)
            out = (proc.stdout + proc.stderr).strip().splitlines()
            ok = proc.returncode == 0
            # fuzz_probe exits 0 even with failures; read its tally.
            if ok and name.startswith("fuzz_probe"):
                ok = fuzz_passed(out)
            summary = next((l for l in reversed(out) if l.strip() and "UserWarning" not in l), "")
            if not ok:
                bad = [l for l in out if l.startswith(("FAIL", "SYNTAX", "  FAIL")) or " FAIL" in l]
                summary = (bad[0] if bad else summary)
            results.append((name, "ok" if ok else "FAIL", summary, time.time() - start))
        except FileNotFoundError as exc:
            results.append((name, "FAIL", f"can't run: {exc}", 0.0))
        except subprocess.TimeoutExpired:
            results.append((name, "FAIL", "timed out", time.time() - start))

    width = max(len(n) for n, *_ in results)
    for name, status, summary, secs in results:
        print(f"{status:4}  {name:<{width}}  {secs:5.1f}s  {summary[:110]}")
    failed = [n for n, s, *_ in results if s == "FAIL"]
    skipped = [n for n, s, *_ in results if s == "skip"]
    print(f"\n{len(results) - len(failed) - len(skipped)} ok, {len(failed)} failed, {len(skipped)} skipped")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
