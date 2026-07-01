from typing import Dict, NamedTuple, Optional

from BaseClasses import Item, ItemClassification

from .Routes import ROUTES, ROUTE_NAMES, boss_event, boss_victory


class ItemData(NamedTuple):
    code: Optional[int]
    progression: bool
    event: bool = False
    trap: bool = False
    useful: bool = False


hades2_base_item_id = 1

# --- Weapons (Nocturnal Arms) -------------------------------------------------
# Short names map to: Staff = Witch's Staff, Blades = Sister Blades,
# Flames = Umbral Flames, Axe = Moonstone Axe, Skull = Argent Skull,
# Coat = Black Coat. Melinoe starts with the Staff by default.
item_table_weapons: Dict[str, ItemData] = {
    "Staff Weapon Unlock Item": ItemData(hades2_base_item_id + 0, True),
    "Blades Weapon Unlock Item": ItemData(hades2_base_item_id + 1, True),
    "Flames Weapon Unlock Item": ItemData(hades2_base_item_id + 2, True),
    "Axe Weapon Unlock Item": ItemData(hades2_base_item_id + 3, True),
    "Skull Weapon Unlock Item": ItemData(hades2_base_item_id + 4, True),
    "Coat Weapon Unlock Item": ItemData(hades2_base_item_id + 5, True),
}

# --- Filler items (the 4 meta-progression currencies) -------------------------
item_table_filler: Dict[str, ItemData] = {
    "Ashes": ItemData(hades2_base_item_id + 6, False),
    "Psyche": ItemData(hades2_base_item_id + 7, False),
    "Bones": ItemData(hades2_base_item_id + 8, False),
    "Nectar": ItemData(hades2_base_item_id + 9, False),
    # Moon Dust (CardUpgradePoints) = the Arcana upgrade currency. Only joins the filler
    # rotation when ArcanaSanity is not Progressive (so manual upgrades are allowed).
    "Moon Dust": ItemData(hades2_base_item_id + 153, False),
}

# --- Grasp (graspsanity) ------------------------------------------------------
# Each Progressive Grasp raises max Grasp by the grasp_intervals option amount.
item_table_grasp: Dict[str, ItemData] = {
    "Progressive Grasp": ItemData(hades2_base_item_id + 10, False, useful=True),
}

# --- Arcana cards (arcanasanity) ----------------------------------------------
# One entry per Arcana Card, named by its card title. In "Arcana" mode each is a
# single unlock item; in "Progressive_Arcana" mode multiple copies stack (1st
# unlocks, the rest upgrade). The Lua mod maps these titles to internal card ids.
arcana_titles = [
    "The Sorceress", "Wayward Son", "Huntress", "Eternity", "Moon",
    "Furies", "Persistence", "Messenger", "Unseen", "Night",
    "Swift Runner", "Death", "Centaur", "Origination", "Lovers",
    "The Enchantress", "Boatman", "Artificer", "Excellence", "Queen",
    "The Fates", "Champions", "Strength", "Divinity", "Judgment",
]
item_table_arcana: Dict[str, ItemData] = {
    f"{title} Arcana": ItemData(hades2_base_item_id + 11 + i, False, useful=True)
    for i, title in enumerate(arcana_titles)
}
# Progressive_Arcana mode uses these names instead, so the 3 copies read clearly as
# "Progressive <Card> Arcana" in the spoiler. The Lua mod treats them the same as
# "<Card> Arcana" (first unlocks, the rest upgrade).
item_table_arcana_progressive: Dict[str, ItemData] = {
    f"Progressive {title} Arcana": ItemData(hades2_base_item_id + 126 + i, False, useful=True)
    for i, title in enumerate(arcana_titles)
}

# --- Vow removal (reverse_vow) ------------------------------------------------
# In reverse_vow mode you start with vows active; each "<Vow> Vow Removal" item
# lowers that vow's level by one. The Lua mod maps these names to ShrineUpgrades.
vow_names = [
    "Pain", "Grit", "Wards", "Frenzy", "Hordes", "Menace", "Return", "Fangs",
    "Scars", "Debt", "Shadow", "Forfeit", "Time", "Void", "Hubris", "Denial", "Rivals",
]
item_table_vows: Dict[str, ItemData] = {
    f"{vow} Vow Removal": ItemData(hades2_base_item_id + 36 + i, False, useful=True)
    for i, vow in enumerate(vow_names)
}

# --- Route-unlock progressives (lock_routes) ----------------------------------
item_table_routes: Dict[str, ItemData] = {
    "Progressive Underworld": ItemData(hades2_base_item_id + 53, True),
    "Progressive Surface": ItemData(hades2_base_item_id + 54, True),
    # Opens the Surface path (the AP version of the Witching-Wards incantation).
    "Surface Access": ItemData(hades2_base_item_id + 55, True),
    # Removes the Surface's lethal damage penalty (Unraveling a Fateful Bond).
    "Surface Penalty Cure": ItemData(hades2_base_item_id + 56, True),
}

# --- Weapon Aspects (aspectsanity) --------------------------------------------
# Items only (no check locations). Every weapon keeps its default Aspect of Melinoe.
# "randomized" mode uses one item per non-default Aspect (deity names are unique, so
# the item name is just the Aspect title). "progressive" mode uses one item per weapon
# ("Progressive <Weapon> Aspect"), copied 5x (1 unlock + 4 rank upgrades).
# Each randomized entry is (display title, weapon short-name); the Lua mod maps the
# title to the internal aspect id and the weapon. Order is fixed so item ids stay stable.
aspect_titles = [
    ("Aspect of Circe", "Staff"), ("Aspect of Momus", "Staff"), ("Aspect of Anubis", "Staff"),
    ("Aspect of Pan", "Blades"), ("Aspect of Artemis", "Blades"), ("Aspect of the Morrigan", "Blades"),
    ("Aspect of Medea", "Skull"), ("Aspect of Persephone", "Skull"), ("Aspect of Hel", "Skull"),
    ("Aspect of Eos", "Flames"), ("Aspect of Moros", "Flames"), ("Aspect of Supay", "Flames"),
    ("Aspect of Charon", "Axe"), ("Aspect of Thanatos", "Axe"), ("Aspect of Nergal", "Axe"),
    ("Aspect of Nyx", "Coat"), ("Aspect of Selene", "Coat"), ("Aspect of Shiva", "Coat"),
]
WEAPON_SHORT_NAMES = ["Staff", "Blades", "Skull", "Flames", "Axe", "Coat"]
ASPECT_MAX_RANK = 5      # 1 unlock + 4 upgrades, so 5 progressive copies per weapon
KEEPSAKE_PROGRESSIVE_COUNT = 3   # 1 unlock + 2 level upgrades
FAMILIAR_PROGRESSIVE_COUNT = 4   # 1 unlock + 3 bond-tier upgrades

aspect_item_base = hades2_base_item_id + 57           # randomized: +57..+74 (18)
item_table_aspects_randomized: Dict[str, ItemData] = {
    title: ItemData(aspect_item_base + i, False, useful=True)
    for i, (title, _weapon) in enumerate(aspect_titles)
}
aspect_prog_item_base = hades2_base_item_id + 75       # progressive: +75..+80 (6)
item_table_aspects_progressive: Dict[str, ItemData] = {
    f"Progressive {weapon} Aspect": ItemData(aspect_prog_item_base + i, False, useful=True)
    for i, weapon in enumerate(WEAPON_SHORT_NAMES)
}
item_table_aspects = {**item_table_aspects_randomized, **item_table_aspects_progressive}

# --- Keepsakes (keepsakesanity) -----------------------------------------------
# 33 keepsakes (randomized mode), named by their in-game title. Chronos's "Time Piece"
# is a findable item but has NO location. "progressive" mode adds 3 "Progressive
# Keepsake" copies instead. The Lua mod maps each title to its keepsake trait.
keepsake_titles = [
    "Engraved Pin", "Luckier Tooth", "Ghost Onion", "Evil Eye", "White Antler",
    "Moon Beam", "Gold Purse", "Knuckle Bones", "Silver Wheel", "Crystal Figurine",
    "Aromatic Phial", "Silken Sash", "Experimental Hammer", "Lion Fang", "Blackened Fleece",
    "Discordant Bell", "Metallic Droplet", "Concave Stone", "Transcendent Embryo", "Fig Leaf",
    "Gorgon Amulet", "Calling Card", "Jeweled Pom", "Time Piece", "Adamant Shard",
    "Cloud Bangle", "Barley Sheaf", "Beautiful Mirror", "Vivid Sea", "Harmonic Photon",
    "Everlasting Ember", "Sword Hilt", "Iridescent Fan",
]
# Keepsake title -> the NPC who gives it. Keepsake check locations are named
# "<NPC> Keepsake" (e.g. "Dora Keepsake"), which reads more clearly than the item name.
# Derived from each keepsake's GiftPresentation flag (DoraGift01, CharonGift01, ...).
KEEPSAKE_NPC: Dict[str, str] = {
    "Engraved Pin": "Moros",
    "Luckier Tooth": "Skelly",
    "Ghost Onion": "Dora",
    "Evil Eye": "Nemesis",
    "White Antler": "Artemis",
    "Moon Beam": "Selene",
    "Gold Purse": "Charon",
    "Knuckle Bones": "Odysseus",
    "Silver Wheel": "Hecate",
    "Crystal Figurine": "Circe",
    "Aromatic Phial": "Narcissus",
    "Silken Sash": "Arachne",
    "Experimental Hammer": "Icarus",
    "Lion Fang": "Heracles",
    "Blackened Fleece": "Medea",
    "Discordant Bell": "Eris",
    "Metallic Droplet": "Hermes",
    "Concave Stone": "Echo",
    "Transcendent Embryo": "Chaos",
    "Fig Leaf": "Dionysus",
    "Gorgon Amulet": "Athena",
    "Calling Card": "Zagreus",
    "Jeweled Pom": "Hades",
    "Time Piece": "Chronos",
    "Adamant Shard": "Hephaestus",
    "Cloud Bangle": "Zeus",
    "Barley Sheaf": "Demeter",
    "Beautiful Mirror": "Aphrodite",
    "Vivid Sea": "Poseidon",
    "Harmonic Photon": "Apollo",
    "Everlasting Ember": "Hestia",
    "Sword Hilt": "Ares",
    "Iridescent Fan": "Hera",
}
CHRONOS_KEEPSAKE = "Time Piece"  # item only, never a check location
# Keepsakes that exist as items but are NOT check locations, because they can't be
# reliably earned by gifting an NPC: Chronos's Time Piece, Zagreus's Calling Card, and
# Hades' Jeweled Pom (boss/story-granted). They behave like Time Piece: item-only.
KEEPSAKE_NO_LOCATION = {"Time Piece", "Calling Card", "Jeweled Pom"}
keepsake_item_base = hades2_base_item_id + 90          # randomized: +90..+122 (33)
item_table_keepsakes_randomized: Dict[str, ItemData] = {
    title: ItemData(keepsake_item_base + i, False, useful=True)
    for i, title in enumerate(keepsake_titles)
}
item_table_keepsakes_progressive: Dict[str, ItemData] = {
    "Progressive Keepsake": ItemData(hades2_base_item_id + 123, False, useful=True),
}
item_table_keepsakes = {**item_table_keepsakes_randomized, **item_table_keepsakes_progressive}

# --- Familiars / pets (petsanity) ---------------------------------------------
# Items only (no check locations). "randomized" mode = one item per familiar.
# "progressive" mode = "Progressive Familiar" copied 4x (1 unlock + 3 bond tiers).
familiar_names = ["Frinos", "Toula", "Raki", "Hecuba", "Gale"]
familiar_item_base = hades2_base_item_id + 81          # randomized: +81..+85 (5)
item_table_familiars_randomized: Dict[str, ItemData] = {
    name: ItemData(familiar_item_base + i, False, useful=True)
    for i, name in enumerate(familiar_names)
}
item_table_familiars_progressive: Dict[str, ItemData] = {
    "Progressive Familiar": ItemData(hades2_base_item_id + 86, False, useful=True),
}
item_table_familiars = {**item_table_familiars_randomized, **item_table_familiars_progressive}

# --- Progressive Start + filler boosts (New Filler Checks) ---------------------
# Each Progressive Start cumulatively strengthens your run start, cycling through
# +25 Max Health, +100 starting Gold, +1 base boon rarity (or an extra boon), and
# +1 Daedalus Hammer option (or an extra hammer). Rarity Increase is a filler item
# that boosts your chance of rarer boons; it joins the currency filler rotation.
item_table_extras: Dict[str, ItemData] = {
    "Progressive Start": ItemData(hades2_base_item_id + 124, False, useful=True),
    "Rarity Increase": ItemData(hades2_base_item_id + 125, False),
    # Increased Odds of Major Finds: filler that biases exit-door rewards toward Major Finds
    # (boons, Daedalus hammers, Centaur Hearts) over Minor Finds (Ash/Bones/Nectar). A pure
    # odds-boost filler like Rarity Increase; joins the filler currency rotation.
    "Increased Odds of Major Finds": ItemData(hades2_base_item_id + 217, False),
    # REMOVED: Increased Help Odds filler stubbed out (no longer placed in the pool).
    # Item id 151 retired; do not reuse. Lua handler is left dormant.
    # "Increased Help Odds": ItemData(hades2_base_item_id + 151, False),
    # Single unlock (not filler): once received you start each run with a random Arachne armor.
    "Starting Arachne Armor": ItemData(hades2_base_item_id + 152, False, useful=True),
    # Each grants a random Daedalus Hammer upgrade at the start of every run.
    "Daedalus Upgrade": ItemData(hades2_base_item_id + 210, False, useful=True),
}

# --- Progressive start-boost fillers ------------------------------------------
# Each of these permanently raises a starting stat by its configured "value". They join
# the filler currency rotation by their configured "percentage" (see build_filler_pool).
item_table_progressive_filler: Dict[str, ItemData] = {
    "Starting Max Health": ItemData(hades2_base_item_id + 206, False),
    "Starting Max Magick": ItemData(hades2_base_item_id + 207, False),
    "Starting Gold": ItemData(hades2_base_item_id + 208, False),
    "Starting Armor": ItemData(hades2_base_item_id + 209, False),
}

# --- Combined weapon + aspect progressives (weapon_aspect_combine) -------------
# When weapon_aspect_combine is on (with AspectSanity randomized/progressive), these
# replace the per-weapon unlock items and Aspect items. The first "Progressive <Weapon>"
# unlocks that weapon and all of its Aspects; each later copy upgrades those Aspects.
item_table_weapon_combine: Dict[str, ItemData] = {
    f"Progressive {weapon}": ItemData(hades2_base_item_id + 211 + i, True)
    for i, weapon in enumerate(WEAPON_SHORT_NAMES)
}

# --- Incantations (Cauldron unlocks shuffled as items) ------------------------
# The Cauldron is blocked in-game, so these meta/QoL unlocks become AP items: collecting
# one grants its world-upgrade. No check locations (items-only, like aspects/familiars).
# The Lua mod maps each display name to its internal WorldUpgrade id. create_items gates
# them by route/keepsake mode. Five OTHER incantations are auto-granted at connect (not
# items): Consecration of Ashes, Aspects of Night and Darkness, Spreading of Ashes,
# Favored of All Keepsakes, Insight into Offerings.
incantation_always = [
    "Gathering of Ancient Bones", "Doomed Beckoning", "End to Deepest Slumber",
    "End to Dearest Slumber", "End to Dumbest Slumber", "Divination of the Elements",
    "Rite of Vapor-Cleansing", "Rite of Social Solidarity", "Rite of River-Fording",
    "Empath's Intuition", "Rise of Stygian Wells", "Surge of Stygian Wells",
    "Cleansing of Fountain-Waters", "Purification of Fountain-Waters", "Kindred Keepsakes",
    "Propensity Toward Gold", "Necromantic Influence", "Eyes of Night and Darkness",
    "Summoning of Musical Rhapsody", "Path to Desired Blessings", "Shuffling of Noted Ballads",
    "Bones of Arcane Wisdom", "Gathering of Subterranean Riches", "Bounties of the Infinite Abyss",
    "Ashen Memories of Life", "Nectar of Godly Savor", "Augmentation of Bone Density",
    "Alteration of Familiar Forms",
]
incantation_underworld = [
    "Temporal Fluctuation", "Circles of the Moon", "Woodsy Lifespring", "Briny Lifespring",
    "Golden Lifespring", "Reviving a Mournful Husk", "Circles of Protection", "Exhumed Troves",
    "Surge of Desecrating Pools", "Revival of a Desecrating Pool",
]
incantation_surface = [
    "Surge of Fresh Air", "Summoning a Colony of Bats", "Rush of Fresh Air", "Sandy Lifespring",
    "Arisen Troves", "Frozen Lifespring", "Rage of the Elements",
]
incantation_keepsake_nonprog = ["Quickening of Sentimental Value"]
# Exhumed Troves lives in the underworld list, but is also wanted when the seed is
# surface-only (no underworld), so create_items adds it in that case too.
INCANTATION_SURFACE_ONLY_EXTRA = "Exhumed Troves"

_incantation_order = (incantation_always + incantation_underworld
                      + incantation_surface + incantation_keepsake_nonprog)
incantation_item_base = hades2_base_item_id + 160          # +160..+205 (46)
# Doomed Beckoning unlocks the Moros keepsake check (Rules.KEEPSAKE_MOROS_ITEM), so it must
# be progression -- otherwise Archipelago's reachability sweep (progression items only) can
# never collect it and the Moros Keepsake location is flagged unreachable.
_INCANTATION_PROGRESSION = {"Doomed Beckoning"}
item_table_incantations: Dict[str, ItemData] = {
    name: ItemData(incantation_item_base + i, name in _INCANTATION_PROGRESSION,
                   useful=name not in _INCANTATION_PROGRESSION)
    for i, name in enumerate(_incantation_order)
}


# --- Event items (boss victories, no real code) -------------------------------
# One "<Boss> Victory" event item per boss across both routes.
items_table_event: Dict[str, ItemData] = {
    boss_victory(boss): ItemData(None, True, True)
    for route in ROUTE_NAMES for boss in ROUTES[route]["bosses"]
}


item_table = {
    **item_table_weapons,
    **item_table_filler,
    **item_table_grasp,
    **item_table_arcana,
    **item_table_arcana_progressive,
    **item_table_vows,
    **item_table_routes,
    **item_table_aspects,
    **item_table_keepsakes,
    **item_table_familiars,
    **item_table_extras,
    **item_table_progressive_filler,
    **item_table_weapon_combine,
    **item_table_incantations,
    **items_table_event,
}


# --- Item name groups (for yaml/plando convenience) ---------------------------
group_weapons = {"weapons": list(item_table_weapons) + list(item_table_weapon_combine)}
group_fillers = {"fillers": list(item_table_filler) + list(item_table_progressive_filler)}
group_arcana = {"arcana": list(item_table_arcana) + list(item_table_arcana_progressive)}
group_vows = {"vows": item_table_vows.keys()}
group_aspects = {"aspects": item_table_aspects.keys()}
group_keepsakes = {"keepsakes": item_table_keepsakes.keys()}
group_familiars = {"familiars": item_table_familiars.keys()}
group_incantations = {"incantations": item_table_incantations.keys()}

item_name_groups = {
    **group_weapons,
    **group_fillers,
    **group_arcana,
    **group_vows,
    **group_aspects,
    **group_keepsakes,
    **group_familiars,
    **group_incantations,
}


# --- Pairing of event locations with their event items ------------------------
# "Beat <Boss>" event location -> "<Boss> Victory" event item, both routes.
event_item_pairs: Dict[str, str] = {
    boss_event(boss): boss_victory(boss)
    for route in ROUTE_NAMES for boss in ROUTES[route]["bosses"]
}


class Hades2Item(Item):
    game = "Hades2Rogue"

    def __init__(self, name, player: int = None):
        item_data = item_table[name]
        if item_data.progression:
            item_class = ItemClassification.progression
        elif item_data.trap:
            item_class = ItemClassification.trap
        elif item_data.useful:
            item_class = ItemClassification.useful
        else:
            item_class = ItemClassification.filler

        super(Hades2Item, self).__init__(
            name,
            item_class,
            item_data.code, player
        )

    def is_progression(self) -> bool:
        return self.classification == ItemClassification.progression
