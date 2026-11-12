"""Build Hades2Rogue.apworld from the apworld source folder.

Produces a zip that passes the Archipelago Launcher's install validation on
every AP version:
  - entry names use forward slashes (Windows zip tools like Compress-Archive
    write backslashes, which older frozen Pythons don't sanitize -> the
    Launcher sees no directories and shows "APWorld appears to be invalid or
    damaged. (expected a single directory)")
  - an explicit `Hades2Rogue/` directory entry is included (AP <= 0.5.x
    requires a zero-byte directory entry; implied directories aren't enough)

Usage:  python tools/build_apworld.py [output_path] [--no-cheats]
Default output: Hades_2_Archipelago/Hades2Rogue.apworld

--no-cheats: exclude CheatClient.py and its Launcher component registration --
for player-facing releases, which must not carry the dev-only Cheats tab.
"""
import argparse
import pathlib
import zipfile

MODULE_NAME = "Hades2Rogue"
PROJECT_ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE_DIR = PROJECT_ROOT / "Hades_2_Archipelago" / f"{MODULE_NAME}_apworld"
DEFAULT_OUTPUT = PROJECT_ROOT / "Hades_2_Archipelago" / f"{MODULE_NAME}.apworld"

EXCLUDE_DIRS = {"__pycache__", ".git", ".build"}
EXCLUDE_SUFFIXES = {".pyc"}

# __init__.py snippets stripped out under --no-cheats, verbatim from source.
_CHEAT_LAUNCH_FN = '''def launch_cheat_client(*args):
    from .CheatClient import launch
    launch_subprocess(launch, "Hades2RogueCheatClient", args)


'''
_CHEAT_COMPONENT = '''
components.append(Component("Hades 2 Rogue Client (Cheats)",
                            func=launch_cheat_client, component_type=Type.CLIENT,
                            game_name="Hades2Rogue", supports_uri=True))'''


def build(output: pathlib.Path, no_cheats: bool = False) -> None:
    files = sorted(
        f for f in SOURCE_DIR.rglob("*")
        if f.is_file()
        and f.suffix not in EXCLUDE_SUFFIXES
        and not (EXCLUDE_DIRS & set(p.name for p in f.relative_to(SOURCE_DIR).parents))
    )
    if not (SOURCE_DIR / "__init__.py").is_file():
        raise SystemExit(f"missing __init__.py in {SOURCE_DIR}")

    if no_cheats:
        files = [f for f in files if f.name != "CheatClient.py"]

    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as z:
        # explicit directory entry, required by AP 0.5.x installers
        z.writestr(zipfile.ZipInfo(f"{MODULE_NAME}/"), b"")
        for f in files:
            arcname = f"{MODULE_NAME}/" + f.relative_to(SOURCE_DIR).as_posix()
            if no_cheats and f.name == "__init__.py":
                src = f.read_text(encoding="utf-8")
                for snippet in (_CHEAT_LAUNCH_FN, _CHEAT_COMPONENT):
                    if snippet not in src:
                        raise SystemExit(
                            f"--no-cheats: expected snippet not found in __init__.py "
                            f"(source may have changed):\n{snippet!r}"
                        )
                    src = src.replace(snippet, "")
                z.writestr(arcname, src)
            else:
                z.write(f, arcname)

    verify(output)
    print(f"built {output} ({len(files)} files{', no-cheats' if no_cheats else ''})")


def verify(path: pathlib.Path) -> None:
    """Run the same validation the Archipelago Launcher runs on install."""
    z = zipfile.ZipFile(path)
    for name in z.namelist():
        assert "\\" not in name, f"backslash in entry name: {name!r}"
    # AP 0.6.x check (worlds/LauncherComponents.py)
    directories = [f.name for f in zipfile.Path(z).iterdir() if f.is_dir()]
    assert directories == [MODULE_NAME], f"0.6.x check failed: {directories}"
    # AP 0.5.x check (explicit zero-byte directory entry)
    old_dirs = [f.filename.strip("/") for f in z.filelist
                if f.CRC == 0 and f.file_size == 0 and f.filename.count("/") == 1]
    assert old_dirs == [MODULE_NAME], f"0.5.x check failed: {old_dirs}"
    z.open(f"{MODULE_NAME}/__init__.py").close()


if __name__ == "__main__":
    # argparse, not a hand split of sys.argv: the old parser treated any unknown flag as the
    # output path, which is how `build_apworld.py --help` wrote a zip named "--help".
    parser = argparse.ArgumentParser(description="Build Hades2Rogue.apworld from source.")
    parser.add_argument("output", nargs="?", type=pathlib.Path, default=DEFAULT_OUTPUT,
                        help=f"output path (default: {DEFAULT_OUTPUT})")
    parser.add_argument("--no-cheats", action="store_true",
                        help="leave out CheatClient.py and its Launcher entry (player releases)")
    cli = parser.parse_args()
    build(cli.output, no_cheats=cli.no_cheats)
