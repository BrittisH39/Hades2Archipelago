"""Build the mod's texture package: the Archipelago logo the in-game tracker's Codex tab shows.

The game only draws textures that live in a .pkg, so the mod ships one in its plugins_data folder
(Journal.lua loads it). This rebuilds it from the PNGs under Hades2Rogue_mod_package/src.

Needs deppth2 (pip install deppth2) and Pillow.

Usage:  python tools/build_mod_package.py [--logo PNG] [--install PLUGINS_DATA_DIR]

--logo PNG       remake src/APLogo.png from an Archipelago logo image first (e.g. the Archipelago
                 install's data/icon.png): trimmed, fitted to 68 px, centred on a 72x72 canvas --
                 the size of the vanilla GUI\\Screens\\Codex\\Icon-* tab icons.
--install DIR    also copy the package into DIR/<package name>/ (a profile's
                 ReturnOfModding/plugins_data folder).

A release zip has to carry the two output files as plugins_data/<both files> next to the Lua.
"""
import argparse
import pathlib
import shutil
import subprocess
import tempfile

# Journal.lua's PACKAGE: the package's file name and the prefix of every texture name inside it.
PACKAGE = "BrittisH39-Hades2RogueArchipelago"
PROJECT_ROOT = pathlib.Path(__file__).resolve().parent.parent
PACKAGE_DIR = PROJECT_ROOT / "Hades_2_Archipelago" / "Hades2Rogue_mod_package"
SOURCE_DIR = PACKAGE_DIR / "src"
ICON_CANVAS, ICON_FIT = 72, 68


def make_logo(source: pathlib.Path) -> None:
    from PIL import Image
    image = Image.open(source).convert("RGBA")
    image = image.crop(image.getbbox())
    scale = ICON_FIT / max(image.size)
    image = image.resize((round(image.width * scale), round(image.height * scale)), Image.LANCZOS)
    canvas = Image.new("RGBA", (ICON_CANVAS, ICON_CANVAS), (0, 0, 0, 0))
    canvas.paste(image, ((ICON_CANVAS - image.width) // 2, (ICON_CANVAS - image.height) // 2))
    SOURCE_DIR.mkdir(parents=True, exist_ok=True)
    canvas.save(SOURCE_DIR / "APLogo.png")


def build() -> list:
    with tempfile.TemporaryDirectory() as work:
        work = pathlib.Path(work)
        shutil.copytree(SOURCE_DIR, work / "src")
        # hadespack names each texture "<target>\<path under src, no extension>".
        subprocess.run(["deppth2", "hpk", "-s", "src", "-t", PACKAGE], cwd=work, check=True)
        subprocess.run(["deppth2", "pk", "-s", PACKAGE, "-t", f"{PACKAGE}.pkg"], cwd=work, check=True)
        outputs = []
        for suffix in (".pkg", ".pkg_manifest"):
            target = PACKAGE_DIR / (PACKAGE + suffix)
            shutil.copyfile(work / (PACKAGE + suffix), target)
            outputs.append(target)
    return outputs


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--logo", type=pathlib.Path)
    parser.add_argument("--install", type=pathlib.Path)
    args = parser.parse_args()
    if args.logo:
        make_logo(args.logo)
    outputs = build()
    for path in outputs:
        print(f"built {path} ({path.stat().st_size} bytes)")
    if args.install:
        folder = args.install / PACKAGE
        folder.mkdir(parents=True, exist_ok=True)
        for path in outputs:
            shutil.copyfile(path, folder / path.name)
        print(f"installed to {folder}")


if __name__ == "__main__":
    main()
