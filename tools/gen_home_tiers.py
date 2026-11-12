"""Regenerate EnemySanity.lua's ENEMY_HOME_TIER block from Python's Locations.ENEMY_LAYERS.

ENEMY_HOME_TIER answers "what zone does this enemy natively belong to", which EnemySanity.
scale_unit divides out of a substituted unit's DreamBiomeData entry (see the comment above the
table in EnemySanity.lua). It is a flattened mirror of ENEMY_LAYERS: a name's tier is its index
within its route's layer list, and all three routes' zone 1s are tier 1.

Prints the Lua block on stdout -- paste it over the existing `_home(...)` calls. Exits non-zero
if two routes disagree on a name's tier, which would make the flat map lossy and mean the table
needs to become route-aware instead.

Usage:  python tools/gen_home_tiers.py
"""
import ast
import collections
import pathlib
import sys

LOCATIONS = (pathlib.Path(__file__).resolve().parent.parent
             / "Hades_2_Archipelago" / "Hades2Rogue_apworld" / "Locations.py")


def load_layers() -> dict:
    """{route_name: [[names...], ...]} parsed statically, so importing the apworld (and all of
    Archipelago core with it) isn't required just to read a literal."""
    tree = ast.parse(LOCATIONS.read_text(encoding="utf-8"))
    consts, layers = {}, None
    for node in tree.body:
        if not isinstance(node, ast.Assign):
            continue
        target = node.targets[0]
        if not isinstance(target, ast.Name):
            continue
        if isinstance(node.value, ast.Constant):
            consts[target.id] = node.value.value
        if target.id == "ENEMY_LAYERS":
            layers = node.value
    if layers is None:
        sys.exit("could not find ENEMY_LAYERS in Locations.py")
    out = {}
    for key, value in zip(layers.keys, layers.values):
        name = consts.get(key.id, key.id) if isinstance(key, ast.Name) else ast.literal_eval(key)
        out[name] = [[ast.literal_eval(e) for e in layer.elts] for layer in value.elts]
    return out


def main() -> int:
    routes = load_layers()
    tier, conflicts = {}, collections.defaultdict(set)
    for names_by_zone in routes.values():
        for zone_index, names in enumerate(names_by_zone, start=1):
            for name in names:
                if name in tier and tier[name] != zone_index:
                    conflicts[name] |= {tier[name], zone_index}
                tier.setdefault(name, zone_index)

    if conflicts:
        for name, tiers in sorted(conflicts.items()):
            print(f"CONFLICT: {name!r} appears at tiers {sorted(tiers)}", file=sys.stderr)
        print("\nA flat name -> tier map cannot represent this; make ENEMY_HOME_TIER route-aware.",
              file=sys.stderr)
        return 1

    by_tier = collections.defaultdict(list)
    for name, t in tier.items():
        by_tier[t].append(name)

    for t in sorted(by_tier):
        tokens = [f'"{n}"' for n in sorted(by_tier[t])]
        lines, current = [], "  "
        for token in tokens:
            chunk = token + ", "
            if len(current) + len(chunk) > 96:
                lines.append(current.rstrip())
                current = "  "
            current += chunk
        lines.append(current.rstrip().rstrip(","))
        print(f"_home({t}, {{")
        print("\n".join(lines))
        print("})")

    print(f"\n-- {len(tier)} names across {len(routes)} routes", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
