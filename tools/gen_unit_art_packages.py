"""Regenerate Hades2Rogue_mod/UnitArtPackages.lua: unit id -> the art packages that hold its textures.

Why this exists: EnemySanity swaps an encounter's spawns after the game has already decided which
art packages the room needs, so a substituted enemy's textures are only resident if something
loads them. Missing textures render as a flat single-colour silhouette. The mod used to guess the
package from the enemy's home zone ("Biome" + zone letter), which is wrong for any unit whose art
lives somewhere else -- e.g. the Bloodless family's textures ship in BiomeB (the Asphodel Anomaly)
and BiomeH, never in BiomeG, the Oceanus package the guess picked.

This reads the answer out of the installed game instead of guessing:
  Units/Enemies.sjson       unit -> GrannyModel (mesh), following InheritFrom
  GR2/_Optimized/*.gpk      which model container holds each mesh
  GR2/_Optimized/*.sdb      the texture files that container's meshes use
  Packages/1080p/*.pkg      which packages carry each texture (entries named "GR2\\<Texture>")

Packages are mostly LZ4-compressed, so a texture's name is found by scanning for it in the raw
bytes. That works because names sit in literal runs, but a name can in principle be split by a
back-reference and missed; the report at the end lists every unit left without an entry, and the
mod falls back to the home-zone guess for those.

Zagreus' Journey (Nightmare) units aren't covered: ZJ builds them at runtime from the Hades I
install, so there is nothing static to scan. EnemySanity loads the package set ZJ's own rooms load.

Usage:  python tools/gen_unit_art_packages.py [--game "C:/.../Hades II"] [--check]
        --check exits non-zero if the committed file differs from what would be generated.
"""
import argparse
import difflib
import glob
import mmap
import os
import pathlib
import re
import struct
import sys

PROJECT_ROOT = pathlib.Path(__file__).resolve().parent.parent
MOD = PROJECT_ROOT / "Hades_2_Archipelago" / "Hades2Rogue_mod"
OUT = MOD / "UnitArtPackages.lua"
DEFAULT_GAME = r"C:\Program Files (x86)\Steam\steamapps\common\Hades II"

TEXTURE_IN_PKG = re.compile(rb"GR2\\([A-Za-z0-9_]+)")
TEXTURE_IN_SDB = re.compile(rb"/([A-Za-z0-9_]+)\.(?:png|tga|psd)")


# --- game data readers -----------------------------------------------------------------------

def scan_packages(content: pathlib.Path) -> tuple:
    """({texture_lower: {package}}, {package: size_bytes})"""
    where, sizes = {}, {}
    for path in sorted(glob.glob(str(content / "Packages" / "1080p" / "*.pkg"))):
        package = os.path.basename(path)[:-len(".pkg")]
        sizes[package] = os.path.getsize(path)
        with open(path, "rb") as fh:
            mm = mmap.mmap(fh.fileno(), 0, access=mmap.ACCESS_READ)
            try:
                for m in TEXTURE_IN_PKG.finditer(mm):
                    where.setdefault(m.group(1).decode("latin1").lower(), set()).add(package)
            finally:
                mm.close()
    return where, sizes


def gpk_entry_names(path: str) -> list:
    """A .gpk is <u32 version><u32 count> then count x (<u8 len><name><u32 size><payload>)."""
    data = pathlib.Path(path).read_bytes()
    _version, count = struct.unpack_from("<II", data, 0)
    off, names = 8, []
    for _ in range(count):
        n = data[off]
        names.append(data[off + 1:off + 1 + n].decode("latin1"))
        size = struct.unpack_from("<I", data, off + 1 + n)[0]
        off += 1 + n + 4 + size
    return names


def scan_models(content: pathlib.Path) -> dict:
    """{mesh_name: [texture names used by its model container]}"""
    out = {}
    for gpk in sorted(glob.glob(str(content / "GR2" / "_Optimized" / "*.gpk"))):
        sdb = gpk[:-len(".gpk")] + ".sdb"
        textures = []
        if os.path.exists(sdb):
            textures = sorted({m.decode("latin1") for m in TEXTURE_IN_SDB.findall(pathlib.Path(sdb).read_bytes())})
        try:
            meshes = [n for n in gpk_entry_names(gpk) if n.endswith("_Mesh")]
        except (struct.error, IndexError):
            print(f"warning: could not parse {os.path.basename(gpk)}", file=sys.stderr)
            continue
        for mesh in meshes:
            out[mesh] = textures
    return out


def _unit_objects(text: str):
    """Yield each top-level object's text from `{ Units = [ {...} {...} ] }`."""
    depth, start, in_str = 0, None, False
    i = text.index("[") + 1
    while i < len(text):
        c = text[i]
        if in_str:
            in_str = c != '"'
        elif c == '"':
            in_str = True
        elif c == "/" and text.startswith("//", i):
            i = text.find("\n", i)
            if i == -1:
                break
            continue
        elif c == "{":
            if depth == 0:
                start = i
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                yield text[start:i + 1]
        elif c == "]" and depth == 0:
            break
        i += 1


def _field(text: str, key: str):
    m = re.search(r"\b" + key + r'\s*=\s*"([^"]*)"', text)
    return m.group(1) if m else None


def scan_units(content: pathlib.Path) -> dict:
    """{unit: mesh} for every enemy unit with a 3D model (InheritFrom resolved)."""
    raw = {}
    text = (content / "Game" / "Units" / "Enemies.sjson").read_text(encoding="utf-8-sig")
    for obj in _unit_objects(text):
        nested = obj.find("{", 1)
        head = obj[1:nested] if nested != -1 else obj   # Name/InheritFrom sit above any sub-table
        name = _field(head, "Name")
        if name:
            raw[name] = (_field(head, "InheritFrom"), _field(obj, "GrannyModel"))

    def mesh_of(name, seen=()):
        if name not in raw or name in seen:
            return None
        parent, mesh = raw[name]
        return mesh or (mesh_of(parent, seen + (name,)) if parent else None)

    return {name: mesh for name in raw if (mesh := mesh_of(name))}


# --- matching --------------------------------------------------------------------------------

def _stem(name: str) -> str:
    return re.sub(r"_(mesh|color)$", "", name.lower())


def textures_for_mesh(mesh: str, family_textures: list) -> list:
    """The container's textures this mesh uses. Containers hold several meshes (the Bloodless
    container has six), and mesh and texture names drift apart ("BloodlessNaked_Mesh" wears
    "BonelessNaked_color"), so take the closest name; if nothing is clearly closest, require them
    all -- a package holding every texture of the family certainly holds this mesh's."""
    colour = [t for t in family_textures if t.lower().endswith("_color")] or family_textures
    if len(colour) <= 1:
        return colour
    exact = [t for t in colour if _stem(t) == _stem(mesh)]
    if exact:
        return exact
    scored = sorted(((difflib.SequenceMatcher(None, _stem(mesh), _stem(t)).ratio(), t) for t in colour),
                    reverse=True)
    best, runner_up = scored[0][0], scored[1][0]
    if best >= 0.6 and best - runner_up >= 0.1:
        return [scored[0][1]]
    return colour


def build_table(game: pathlib.Path) -> tuple:
    content = game / "Content"
    where, sizes = scan_packages(content)
    models = scan_models(content)
    units = scan_units(content)
    table, unresolved = {}, {}
    for unit, mesh in sorted(units.items()):
        textures = textures_for_mesh(mesh, models.get(mesh, []))
        holders = [where.get(t.lower(), set()) for t in textures]
        packages = set.intersection(*holders) if holders else set()
        if not packages and holders:
            packages = set.union(*holders)   # textures split across packages: any of them helps
        if packages:
            table[unit] = sorted(packages, key=lambda p: (sizes.get(p, 0), p))
        else:
            unresolved[unit] = (mesh, textures)
    return table, unresolved


# --- output ----------------------------------------------------------------------------------

def render(table: dict, game: pathlib.Path) -> str:
    version = (game / "Content" / "packagever")
    stamp = version.read_text(encoding="latin1").strip() if version.exists() else "unknown"
    lines = [
        "-- GENERATED by tools/gen_unit_art_packages.py from the installed game -- do not edit by hand.",
        f"-- Game package version {stamp}. Rerun the tool after a game update.",
        "--",
        "-- unit id -> the art packages whose textures that unit's model uses, smallest package first.",
        "-- Read by EnemySanity.art_packages_for_unit so a substituted enemy's textures get loaded; a",
        "-- unit missing here (2D units, anything the scan couldn't place) falls back to its home biome.",
        "UnitArtPackages = {",
    ]
    for unit, packages in sorted(table.items()):
        lines.append(f'  ["{unit}"] = {{ ' + ", ".join(f'"{p}"' for p in packages) + " },")
    lines.append("}")
    return "\n".join(lines) + "\n"


def mod_unit_ids() -> set:
    """Unit ids the mod can substitute IN: override keys plus identity names, from
    LocationManager.lua. Used only for the coverage report."""
    lm = (MOD / "LocationManager.lua").read_text(encoding="utf-8")
    ids = set(re.findall(r'\["([A-Za-z0-9_]+)"\]\s*=\s*"[^"]+"', lm))
    return ids


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--game", default=DEFAULT_GAME, help="Hades II install folder")
    ap.add_argument("--check", action="store_true", help="fail if UnitArtPackages.lua is stale")
    args = ap.parse_args()
    game = pathlib.Path(args.game)
    if not (game / "Content").is_dir():
        sys.exit(f"no Hades II install at {game}")

    table, unresolved = build_table(game)
    text = render(table, game)
    if args.check:
        current = OUT.read_text(encoding="utf-8") if OUT.exists() else ""
        if current != text:
            print(f"{OUT.name} is stale -- rerun tools/gen_unit_art_packages.py")
            return 1
        print(f"{OUT.name} is up to date ({len(table)} units)")
        return 0
    OUT.write_text(text, encoding="utf-8", newline="\n")
    print(f"wrote {OUT.relative_to(PROJECT_ROOT)}: {len(table)} units")

    relevant = mod_unit_ids()
    gaps = sorted(u for u in unresolved if u in relevant)
    if gaps:
        print(f"\n{len(gaps)} unit(s) the mod maps to a check have a model but no package was found "
              "(they keep the home-biome fallback):")
        for unit in gaps:
            mesh, textures = unresolved[unit]
            print(f"  {unit}: {mesh} -> {textures or 'no textures listed'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
