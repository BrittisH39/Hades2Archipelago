"""Verify the Lua mod's game-data mappings against the actual installed game sources.

Checks every internal id the mod writes/reads (vows, arcana, keepsakes + ownership flags,
aspects, incantations, resources, familiars, Arachne costumes, weapon kits, miniboss rooms,
helper/encounter keys) for existence in:
  - Hades II  Content/Scripts (+ Game/Text HelpText for enemy display names)
  - Hades (1) Game/Text HelpText (Nightmare-route enemy names)
  - the installed Zagreus' Journey / SharedKeepsakePort plugin sources (Nightmare ids)

Also validates ENEMY_UNIT_OVERRIDE: for every unit id that appears in a HelpText file,
the AP check name must equal that game's own DisplayName.

Usage:  python tools/verify_game_data.py     (exit 0 = clean; prints each finding)
Paths below assume the default Steam / r2modman locations; adjust if yours differ.
"""
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from sync_check import lua_map, lua_list, lua_table_chunk, _strip_comments  # noqa: E402

PROJECT_ROOT = pathlib.Path(__file__).resolve().parent.parent
MOD = PROJECT_ROOT / "Hades_2_Archipelago" / "Hades2Rogue_mod"

H2_ROOT = pathlib.Path(r"C:\Program Files (x86)\Steam\steamapps\common\Hades II\Content")
H1_ROOT = pathlib.Path(r"C:\Program Files (x86)\Steam\steamapps\common\Hades\Content")
PLUGINS = pathlib.Path.home() / "AppData/Roaming/r2modmanPlus-local/HadesII/profiles/Default/ReturnOfModding/plugins"
ZJ = PLUGINS / "NikkelM-Zagreus_Journey"
SKP = PLUGINS / "zannc-SharedKeepsakePort"
OST = PLUGINS / "NikkelM-Hades_OST_for_the_Music_Maker"

problems = []
notes = []


def read_all(root: pathlib.Path, pattern: str) -> str:
    """Concatenated text of every file under root matching the glob pattern."""
    chunks = []
    for f in sorted(root.rglob(pattern)):
        try:
            chunks.append(f.read_text(encoding="utf-8", errors="replace"))
        except OSError:
            pass
    return "\n".join(chunks)


def parse_helptext(path: pathlib.Path) -> dict:
    """HelpText sjson -> { Id: DisplayName } (only entries that have both)."""
    text = path.read_text(encoding="utf-8-sig", errors="replace")
    table = {}
    for m in re.finditer(r'Id = "([^"]+)"\s*\n\s*(?:InheritFrom[^\n]*\n\s*)?DisplayName = "([^"]*)"', text):
        table.setdefault(m.group(1), m.group(2))
    return table


def check_ids(section: str, ids, corpus: str, corpus_name: str) -> None:
    for internal in sorted(set(ids)):
        if internal not in corpus:
            problems.append(f"[{section}] id {internal!r} not found anywhere in {corpus_name}")


def main() -> int:
    im = (MOD / "ItemManager.lua").read_text(encoding="utf-8")
    lm = (MOD / "LocationManager.lua").read_text(encoding="utf-8")

    h2_scripts = read_all(H2_ROOT / "Scripts", "*.lua")
    zj_src = read_all(ZJ, "*.lua") if ZJ.exists() else ""
    skp_src = read_all(SKP, "*.lua") if SKP.exists() else ""
    ost_src = read_all(OST, "*.lua") if OST.exists() else ""
    nightmare_src = zj_src + skp_src + ost_src

    # ---- internal-id existence ----------------------------------------------
    check_ids("vows", lua_map(im, "VOW_NAME_TO_ID").values(), h2_scripts, "H2 Scripts")
    check_ids("arcana", lua_map(im, "ARCANA_TITLE_TO_ID").values(), h2_scripts, "H2 Scripts")
    check_ids("resources", lua_map(im, "RESOURCE_KEYS").values(), h2_scripts, "H2 Scripts")
    npc_gift_pools_chunk = lua_table_chunk(im, "NPC_GIFT_POOLS")
    for npc in ("Arachne", "Medea", "Icarus", "Circe", "Dionysus", "Artemis", "Athena", "Hades"):
        npc_chunk = _strip_comments(lua_table_chunk(npc_gift_pools_chunk, npc))
        check_ids(f"npc-gift/{npc}", re.findall(r'"([^"]+)"', npc_chunk), h2_scripts, "H2 Scripts")
    check_ids("weapon-kits", lua_map(im, "WEAPON_ITEM_TO_ID").values(), h2_scripts, "H2 Scripts")
    check_ids("familiars", lua_map(im, "FAMILIAR_ITEM_TO_ID").values(), h2_scripts, "H2 Scripts")
    check_ids("incantation-starts", lua_list(im, "INCANTATION_START_IDS"), h2_scripts, "H2 Scripts")

    aspects = list(lua_map(im, "ASPECT_ITEM_TO_ID").values()) \
        + list(lua_map(im, "ASPECT_BASE_BY_WEAPON").values())
    check_ids("aspects", aspects, h2_scripts, "H2 Scripts")

    # Keepsake traits + ownership flags: base game vs Nightmare (SharedKeepsakePort).
    for title, trait in lua_map(im, "KEEPSAKE_ITEM_TO_ID").items():
        corpus, name = (h2_scripts, "H2 Scripts")
        if trait not in h2_scripts:
            corpus, name = (nightmare_src, "Nightmare mod sources")
        if trait not in corpus:
            problems.append(f"[keepsakes] trait {trait!r} ({title}) not in H2 Scripts nor Nightmare mods")
    for trait, flag in lua_map(im, "KEEPSAKE_TRAIT_TO_OWNFLAG").items():
        if flag not in h2_scripts and flag not in nightmare_src:
            problems.append(f"[keepsake-flags] flag {flag!r} ({trait}) not in H2 Scripts nor Nightmare mods")

    # Incantations: vanilla WorldUpgrades in H2; ModsNikkelM*/H1-music ids in the mods.
    for name, internal in lua_map(im, "INCANTATION_ITEM_TO_ID").items():
        if internal in h2_scripts or internal in nightmare_src:
            continue
        problems.append(f"[incantations] id {internal!r} ({name}) not in H2 Scripts nor Nightmare mods")

    # Familiar bond tracks (each track + its "2"/"3" tiers must be purchasable upgrades).
    bond_chunk = _strip_comments(lua_table_chunk(im, "FAMILIAR_BOND"))
    for track in re.findall(r'"(\w+)"', bond_chunk):
        for suffix in ("", "2", "3"):
            key = track + suffix
            if track.startswith("Base") and suffix:
                continue
            if key not in h2_scripts:
                problems.append(f"[familiar-bonds] upgrade {key!r} not found in H2 Scripts")

    # Miniboss rooms / helper encounter keys / pools.
    # (Cross-zone "any location" guest NPCs -- ANY_LOCATION_NPCS/ANY_LOCATION_ZONES_* -- were
    # removed from ItemManager.lua on 2026-07-17 in favor of third-party mod dependencies
    # (zerp-Extended_NPC_Encounters, zerp-NPCRoomRandomizer); nothing left in our own source to
    # verify for that feature.)
    room_chunk = _strip_comments(lua_table_chunk(im, "MINIBOSS_UNLOCK_ROOMS"))
    check_ids("miniboss-rooms", re.findall(r'room = "(\w+)"', room_chunk), h2_scripts, "H2 Scripts")
    check_ids("helper-intros", lua_list(im, "HELPER_INTRO_KEYS"), h2_scripts, "H2 Scripts")
    check_ids("god-pickup-flags", lua_list(im, "HELPER_GOD_PICKUPS"), h2_scripts, "H2 Scripts")
    check_ids("force-god-upgrades", lua_list(im, "FORCE_GOD_UPGRADES"), h2_scripts, "H2 Scripts")
    if zj_src:
        story_chunk = _strip_comments(lua_table_chunk(im, "NIGHTMARE_STORY_ROOMS"))
        check_ids("nightmare-story-rooms", re.findall(r'room = "(\w+)"', story_chunk), zj_src, "ZJ sources")
        thanatos_chunk = _strip_comments(lua_table_chunk(im, "NIGHTMARE_THANATOS_ENCOUNTERS"))
        check_ids("nightmare-thanatos", re.findall(r'key = "(\w+)"', thanatos_chunk), zj_src, "ZJ sources")

    # ---- enemy display names vs HelpText -------------------------------------
    h2_names = parse_helptext(H2_ROOT / "Game/Text/en/HelpText.en.sjson")
    h1_names = parse_helptext(H1_ROOT / "Game/Text/en/HelpText.en.sjson")

    def clean(display: str) -> str:
        """Strip {!Icons...} markup H2 prefixes onto elite/bounty names."""
        return re.sub(r"\{![^}]*\}\s*", "", display).strip()

    ELITE_SUFFIXES = ("_SuperElite", "_Elite", "_Shadow", "SuperElite", "Elite",
                      "_Miniboss", "Miniboss", "_MiniBoss", "MiniBoss")

    def display_candidates(unit: str, primary_only: bool = False) -> list:
        """Plausible in-game display names for this unit id. Primary = its own HelpText
        entry (both games; Hades-prefix stripped for ZJ renames) and its _NickName entry
        (H2 gags like CrawlerMiniboss='Uh-oh' put the real name there). Non-primary adds
        the suffix-stripped base id's names — elite tiers deliberately share the base
        enemy's check, so those count as a match but never as a mismatch (bounty titles
        often live under encounter ids like MiniBossStalker that we can't derive)."""
        out = []
        forms = [unit]
        if not primary_only:
            for suffix in ELITE_SUFFIXES:
                if unit.endswith(suffix) and len(unit) > len(suffix):
                    forms.append(unit[:-len(suffix)])
        if unit.startswith("Hades"):
            forms += [f[5:] for f in list(forms)]
        for form in forms:
            for game_name, table in (("H2", h2_names), ("H1", h1_names)):
                for key in (form, form + "_NickName"):
                    if key in table:
                        out.append((game_name, clean(table[key])))
        return out

    def name_matches(ap_name: str, display: str) -> bool:
        if ap_name == display:
            return True
        # boss epithets: "Megaera, the Fury" satisfies "Megaera"
        return display.startswith(ap_name + ",")

    override = lua_map(lm, "ENEMY_UNIT_OVERRIDE")
    for unit, ap_name in sorted(override.items()):
        all_candidates = display_candidates(unit)
        primary = display_candidates(unit, primary_only=True)
        if not all_candidates:
            notes.append(f"[enemy-names] {unit!r} -> {ap_name!r}: no HelpText entry in either game (unverifiable)")
            continue
        if any(name_matches(ap_name, display) for _g, display in all_candidates):
            continue
        shown = ", ".join(f"{g}:{d!r}" for g, d in all_candidates)
        if primary:
            problems.append(f"[enemy-names] {unit!r} mapped to {ap_name!r} but HelpText says {shown}")
        else:
            notes.append(f"[enemy-names] {unit!r} -> {ap_name!r}: only base-form HelpText found ({shown}) - "
                         "likely an encounter-titled miniboss, verify by eye")

    # Identity-mapped enemies (no override entry): unit id assumed == AP display name.
    chunk = lua_table_chunk(lm, "ENEMY_CHECKS_BY_ROUTE")
    for route in ("Underworld", "Surface", "Nightmare"):
        sub = _strip_comments(lua_table_chunk(chunk, route))
        for ap_name in re.findall(r'"([^"]+)"', sub):
            if ap_name in override.values():
                continue
            table = h1_names if route == "Nightmare" else h2_names
            if ap_name in table and table[ap_name] != ap_name:
                problems.append(f"[enemy-names] identity id {ap_name!r} ({route}) has HelpText "
                                f"DisplayName {table[ap_name]!r} (rename needed?)")

    # ---- report ---------------------------------------------------------------
    for n in notes:
        print("  note: " + n)
    if problems:
        print(f"GAME-DATA CHECK: {len(problems)} problem(s)")
        for p in problems:
            print("  " + p)
        return 1
    print("GAME-DATA CHECK: all clean")
    return 0


if __name__ == "__main__":
    sys.exit(main())
