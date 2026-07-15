from dataclasses import dataclass
from typing import Dict, Any
from Options import Range, DeathLink, Choice, StartInventoryPool, PerGameCommonOptions, \
    OptionGroup, DefaultOnToggle, Toggle


# ----------------------- Gameplay decisions -----------------------------------


class InitialWeapon(Choice):
    """Which weapon will you have at the beginning of the run."""
    display_name = "Weapon"
    option_Staff = 0   # Witch's Staff
    option_Blades = 1  # Sister Blades
    option_Flames = 2  # Umbral Flames
    option_Axe = 3     # Moonstone Axe
    option_Skull = 4   # Argent Skull
    option_Coat = 5    # Black Coat
    default = "random"


class AspectSanity(Choice):
    """
    How you'll get the various weapon aspects.
    unlocked: every Aspect is available from the start, fully upgraded.
    randomized: all 24 Aspects are shuffled - the 18 alternates and each weapon's Aspect of
    Melinoe, which weapons no longer come with for free. Each is its own item, granted at
    max level. Your starting weapon begins on a random one of its 4 Aspects, but only at
    level 1 - that Aspect's item is still out there and maxes it out when you find it.
    Every other weapon starts with no Aspect at all. Aspect levels can't be bought at the
    Cauldron; they only come from items.
    progressive: you start with only Melinoe's Aspect. Each weapon gets "Progressive
    <Weapon> Aspect" items - the first unlocks its other aspects, the rest upgrade them
    (up to rank 5). Normal unlocking and upgrading is blocked.
    per_aspect: all 24 Aspects level independently, each with its own "Progressive
    <Aspect>" item - 5 copies apiece (1 unlock + 4 rank upgrades), 120 items total. Your
    starting weapon begins with a random one of its 4 Aspects at rank 1. With Weapon/Aspect
    Combine on, the first aspect item you receive for a weapon also unlocks that weapon;
    with it off, each weapon unlock is its own item.
    """
    display_name = "AspectSanity"
    option_unlocked = 0
    option_randomized = 1
    option_progressive = 2
    option_per_aspect = 3
    default = 2


class WeaponAspectCombine(DefaultOnToggle):
    """
    Setting removes "Unlock <Weapon>" checks. Instead you unlock a weapon the first time
    you gain access to one of its aspects.
    """
    display_name = "Weapon/Aspect Combine"


class LocationSystem(Choice):
    """
    How to handle base locations.
    Room_based: Each location is the first time you clear that many rooms/encounters in one
    run. For example; Room Check 9 sends the first time you clear 9 encounters in one run.
    Point_based: Each location is a point total you must accumulate, you get points equal
    to a room's depth when you clear it. Use this for much longer APs, and it will likely
    be quite repetitive.
    Per_Weapon_Room_Based: Like room_based, but there are separate pools for each weapon.
    """
    display_name = "Location System"
    option_point_based = 0
    option_room_based = 1
    option_per_weapon_room_based = 2
    default = 1


class ScoreRewardsAmount(Range):
    """
    Point_based only. How many score locations are there? If you set each route to have
    it's own pool later, each route will have a pool this big. If there aren't enough
    locations to fulfill the minimum item pool, this will be increased accordingly. More
    locations means more filler items, which are beneficial, but not required.
    """
    display_name = "Score Rewards Amount"
    range_start = 40
    range_end = 1000
    default = 100


class EnemyLocations(DefaultOnToggle):
    """Add locations for the first time you defeat each enemy type."""
    display_name = "Enemy Locations"


class NpcLocations(DefaultOnToggle):
    """Add locations for the first time you speak to each NPC."""
    display_name = "NPC Locations"


class GraspSanity(DefaultOnToggle):
    """
    Adds Progressive Grasp items to the pool; each one raises your maximum Grasp. You
    start at 0. If you turn this off, I highly recommend adding psyche to the filler pool.
    """
    display_name = "GraspSanity"


class GraspCount(Range):
    """How many Progressive Grasp items in the item pool."""
    display_name = "Grasp Count"
    range_start = 1
    range_end = 30
    default = 6


class GraspIntervals(Range):
    """How much each Progressive Grasp raises your maximum Grasp."""
    display_name = "Grasp Intervals"
    range_start = 0
    range_end = 10
    default = 5


class ArcanaSanity(Choice):
    """
    How Arcana Cards are obtained.
    false: unlocked normally by purchasing at the Altar of Ashes. Highly recommend
    adjusting filler checks if you go with this.
    arcana: each card is unlocked by an item and can't be purchased, but still upgrades
    normally.
    progressive_arcana: each card gets multiple progressive items - the first unlocks it,
    the rest upgrade it. Cards can't be upgraded any other way.
    """
    display_name = "ArcanaSanity"
    option_false = 0
    option_Arcana = 1
    option_Progressive_Arcana = 2
    default = 2


class KeepsakeSanity(Choice):
    """
    How Keepsakes are handled.
    false: unchanged from the base game.
    randomized: Adds a location for earning each keepsake, and adds each keepsake to the item pool.
    progressive: Adds a location for earning each keepsake, and adds 3 "Progressive
    Keepsake" items. The first unlocks all keepsakes at level one, the next two level
    them up. Normal keepsake leveling is blocked.
    """
    display_name = "KeepsakeSanity"
    option_false = 0
    option_randomized = 1
    option_progressive = 2
    default = 1


class PetSanity(Choice):
    """
    How Familiars (pets: Frinos, Toula, Raki, Hecuba, Gale) are handled. Items only - no new check locations.
    unlocked: every familiar is available from the start.
    randomized: each familiar becomes its own item; you start with none and unlock each
    at maximum bond when you receive its item.
    progressive: a Progressive Familiar item is added - the first unlocks all familiars,
    the rest upgrade their bonds. Normal familiar unlocking/bonding is blocked.
    """
    display_name = "PetSanity"
    option_unlocked = 0
    option_randomized = 1
    option_progressive = 2
    default = 1


class Hades2DeathLink(DeathLink):
    """When you die, everyone who enabled death link dies. Of course, the reverse is true too."""
    default = 1


class DeathLinkPercent(Range):
    """
    When you receive a DeathLink, how much of your health you'll lose, as a percentage of
    your maximum health. Or, set to 0 to end the run regardless of available death defiances.
    """
    display_name = "DeathLink Damage Percent"
    range_start = 0
    range_end = 100
    default = 100


class DeathLinkAmnesty(Range):
    """
    How many times you die in a row before it sends a Deathlink to everyone else. 0
    means you'll never send, only receive
    """
    display_name = "DeathLink Deaths To Send"
    range_start = 0
    range_end = 5
    default = 1


class NoDeathOnWinningRuns(DefaultOnToggle):
    """
    After winning a run, you don't send a deathlink for returning back to the crossroads.
    I don't know why you would want to turn this off.
    """
    display_name = "No Death On Winning Runs"


# -------------------- Reverse Vow (Oath of the Unseen) ------------------------


class ReverseVow(DefaultOnToggle):
    """
    Start each run with the vows below already active (raising difficulty); each is then
    removed, one at a time, by items found in the multiworld.
    """
    display_name = "Reverse Vow"


class _VowRange(Range):
    range_start = 0
    range_end = 3
    default = 1


class VowPain(_VowRange):
    """How many levels of Vow of Pain to start with (foes deal more damage)."""
    display_name = "Vow of Pain"
    range_end = 3


class VowGrit(_VowRange):
    """How many levels of Vow of Grit to start with (foes have more health)."""
    display_name = "Vow of Grit"
    range_end = 3


class VowWards(_VowRange):
    """How many levels of Vow of Wards to start with (foes gain Barrier)."""
    display_name = "Vow of Wards"
    range_end = 2


class VowFrenzy(_VowRange):
    """How many levels of Vow of Frenzy to start with (foes are faster)."""
    display_name = "Vow of Frenzy"
    range_end = 2


class VowHordes(_VowRange):
    """How many levels of Vow of Hordes to start with (more foes)."""
    display_name = "Vow of Hordes"
    range_end = 3


class VowMenace(_VowRange):
    """How many levels of Vow of Menace to start with (foes from the next region)."""
    display_name = "Vow of Menace"
    range_end = 2


class VowReturn(_VowRange):
    """How many levels of Vow of Return to start with (slain foes may revive)."""
    display_name = "Vow of Return"
    range_end = 2


class VowFangs(_VowRange):
    """How many levels of Vow of Fangs to start with (armored foes gain perks)."""
    display_name = "Vow of Fangs"
    range_end = 2


class VowScars(_VowRange):
    """How many levels of Vow of Scars to start with (healing is less effective)."""
    display_name = "Vow of Scars"
    range_end = 2


class VowDebt(_VowRange):
    """How many levels of Vow of Debt to start with (Higher gold costs)."""
    display_name = "Vow of Debt"
    range_end = 2


class VowShadow(_VowRange):
    """How many levels of Vow of Shadow to start with (Shadow Servants)."""
    display_name = "Vow of Shadow"
    range_end = 1
    default = 0


class VowForfeit(_VowRange):
    """How many levels of Vow of Forfeit to start with (first Boon becomes Red Onion)."""
    display_name = "Vow of Forfeit"
    range_end = 1
    default = 0


class VowTime(_VowRange):
    """How many levels of Vow of Time to start with (time limit per region)."""
    display_name = "Vow of Time"
    range_end = 3


class VowVoid(_VowRange):
    """How many levels of Vow of Void to start with (less Grasp for Arcana)."""
    display_name = "Vow of Void"
    range_end = 4
    default = 2


class VowHubris(_VowRange):
    """How many levels of Vow of Hubris to start with (Primes Magick after Boons)."""
    display_name = "Vow of Hubris"
    range_end = 2


class VowDenial(_VowRange):
    """How many levels of Vow of Denial to start with (unpicked blessings vanish)."""
    display_name = "Vow of Denial"
    range_end = 1
    default = 0


class VowRivals(_VowRange):
    """How many levels of Vow of Rivals to start with (Guardians are stronger)."""
    display_name = "Vow of Rivals"
    range_end = 4
    default = 2


class ReverseRivals(DefaultOnToggle):
    """
    Reverse which Guardians the Vow of Rivals strengthens: this makes Chronos and Typhon
    the last boss to return to normal.
    """
    display_name = "Reverse Rivals"


# -------------------- Routes & Endgame settings -------------------------------


class GoalRequiresChronos(DefaultOnToggle):
    """Whether defeating Chronos (Underworld's final boss) is part of your Goal."""
    display_name = "Goal Requires Chronos"


class GoalRequiresTyphon(DefaultOnToggle):
    """Whether defeating Typhon (Surface's final boss) is part of your Goal."""
    display_name = "Goal Requires Typhon"


class GoalRequiresHades(Toggle):
    """
    Whether defeating Hades (Nightmare route's final boss) is part of your goal. Requires
    the "Zagreus_Journey" mod by NikkelM, which in turn requires Hades 1 be installed.
    """
    display_name = "Goal Requires Hades"


class GoalRequiresZagreus(Toggle):
    """Whether defeating Zagreus is part of your Goal."""
    display_name = "Goal Requires Zagreus"


class GoalMode(Choice):
    """
    How the toggled-on Goal bosses above combine.
    all_selected: every toggled-on boss must be defeated.
    any_selected: defeating any one of the toggled-on bosses is enough.
    """
    display_name = "Goal Mode"
    option_all_selected = 0
    option_any_selected = 1
    default = 1


class ZagreusEncounterMode(Choice):
    """How Zagreus fights appear (only matters if Zagreus is part of your Goal):
    Vanilla: Zagreus fights appear how they normally do in the late game.
    Empowered: Zagreus fights appear how they normally do, but Zagreus starts heavily
    empowered. Progressive Zagreus Weaken items are added to the multiworld that weaken him
    back down to, and eventually below, his normal strength.
    Final Challenge: Defeating any route's final boss spawns a contract to go fight Zagreus
    instead of ending the run."""
    display_name = "Zagreus Encounter Mode"
    option_vanilla = 0
    option_empowered = 1
    option_final_challenge = 2
    default = 1


class ZagreusDefeatsNeeded(Range):
    """How many times you must defeat Zagreus to satisfy the Zagreus part of the goal."""
    display_name = "Zagreus Defeats Needed"
    range_start = 1
    range_end = 20
    default = 1


class ZagreusWeakenTiers(Range):
    """
    If Zagreus Encounter Mode is set to Empowered, how many "Progressive Zagreus Weaken"
    items exist to weaken him.
    """
    display_name = "Zagreus Weaken Tiers"
    range_start = 1
    range_end = 10
    default = 5


class IncludeUnderworld(DefaultOnToggle):
    """Whether to include the Hades 2 Underworld route (Erebus/Oceanus/Fields of Mourning/Tartarus)."""
    display_name = "Include Underworld"


class IncludeSurface(DefaultOnToggle):
    """Whether to include the Surface route (City of Ephyra/Rift of Thessaly/Mount Olympus/The Summit)."""
    display_name = "Include Surface"


class IncludeNightmare(Toggle):
    """
    Whether the Hades 1 route should be included (Tartarus/Asphodel/Elysium/Styx). This
    requires NikkelM's mod Zagreus Journey, which in turn requires Hades 1 to be installed;
    without those, this route's locations will be inaccessible.
    """
    display_name = "Include Nightmare"


class SeparateChecks(Choice):
    """
    When you've included more than one route: does each route get its own full set of
    checks, or do they share one pool?
    separate_pools: Every route gets their own locations, meaning you'll have to
    thoroughly explore each of your routes.
    combine_pools: the routes share one pool. Score checks stop being route-specific:
    there are 200 of them total, every route's rooms bank into the same points pool, and
    you could earn all 200 without ever leaving one route. Each room check is likewise
    earned the first time you clear that depth on ANY route.
    """
    display_name = "Separate Checks"
    option_separate_pools = 0
    option_combine_pools = 1
    default = 0


class LockRoutes(DefaultOnToggle):
    """
    Lock each route's regions behind its progressive route items (Progressive Underworld
    / Progressive Surface / Progressive Nightmare).
    """
    display_name = "Lock Routes"


class StartingRoute(Choice):
    """
    Which route is open from the start. The others open as you receive their progressive
    route items (or, for Surface/Nightmare, their Access item).
    Picking a route you didn't include snaps to one you did. A route your goal forces in
    (e.g. the Surface when your goal requires Typhon) is still reachable, but it won't be
    your starting route unless you chose it here.
    all: every included route starts open, no unlock items needed.
    """
    display_name = "Starting Route"
    option_random = 0
    option_underworld = 1
    option_surface = 2
    option_all = 3
    option_nightmare = 4
    default = 1


class StartWithSurfaceCure(DefaultOnToggle):
    """
    Start with the "Unraveling a Fateful Bond" incantation to remove Melinoe's curse in
    the overworld. If this is turned off, it will be added to the item pool.
    """
    display_name = "Start With Surface Cure"


class ChronosDefeatsNeeded(Range):
    """How many times you must defeat Chronos to satisfy the Chronos part of the goal"""
    display_name = "Chronos Defeats Needed"
    range_start = 1
    range_end = 20
    default = 1


class TyphonDefeatsNeeded(Range):
    """How many times you must defeat Typhon to satisfy the Typhon part of the goal"""
    display_name = "Typhon Defeats Needed"
    range_start = 1
    range_end = 20
    default = 1


class HadesDefeatsNeeded(Range):
    """How many times you must defeat Hades to satisfy the Hades part of the goal."""
    display_name = "Hades Defeats Needed"
    range_start = 1
    range_end = 20
    default = 1


class WeaponsClearsNeeded(Range):
    """
    How many different weapons you must use to defeat any boss. Meaning defeating Chronos
    with the axe and Typhon with the blades would count as 2 weapons.
    """
    display_name = "Weapons Clears Needed"
    range_start = 1
    range_end = 6
    default = 1


# ----------------------- Filler item proportions ------------------------------
# The 4 meta-progression currencies. Each currency has a "value" (how much you
# receive per item) and a "percentage" (its share of the filler pool). If the
# percentages don't sum to 100 they are treated as proportions.


class NectarPackValue(Range):
    """Amount of Nectar granted per Nectar item."""
    display_name = "Nectar Pack Value"
    range_start = 0
    range_end = 50
    default = 2


class NectarPackPercentage(Range):
    """Share of the filler pool that is Nectar."""
    display_name = "Nectar Pack Percentage"
    range_start = 0
    range_end = 100
    default = 20


class StartingHealthValue(Range):
    """How much max health each Starting Max Health item grants."""
    display_name = "Starting Health Value"
    range_start = 0
    range_end = 50
    default = 20


class StartingHealthPercentage(Range):
    """Share of the filler pool that is Max Health."""
    display_name = "Starting Health Percentage"
    range_start = 0
    range_end = 100
    default = 15


class StartingMagickValue(Range):
    """How much max Magick each Starting Max Magick item grants."""
    display_name = "Starting Magick Value"
    range_start = 0
    range_end = 50
    default = 2


class StartingMagickPercentage(Range):
    """Share of the filler pool that is Max Magick."""
    display_name = "Starting Magick Percentage"
    range_start = 0
    range_end = 100
    default = 15


class StartingGoldValue(Range):
    """How much run-start gold each Starting Gold item grants."""
    display_name = "Starting Gold Value"
    range_start = 1
    range_end = 100
    default = 10


class StartingGoldPercentage(Range):
    """Share of the filler pool that is Starting Gold."""
    display_name = "Starting Gold Percentage"
    range_start = 0
    range_end = 100
    default = 15


class StartingArmorValue(Range):
    """How much run-start armor each Starting Armor item grants."""
    display_name = "Starting Armor Value"
    range_start = 1
    range_end = 100
    default = 10


class StartingArmorPercentage(Range):
    """Share of the filler pool that is Starting Armor."""
    display_name = "Starting Armor Percentage"
    range_start = 0
    range_end = 100
    default = 15


class RarityIncreasePercentage(Range):
    """
    Share of the filler pool that is Rarity Increase. Each one permanently raises your
    odds of higher-rarity boons.
    """
    display_name = "Rarity Increase Percentage"
    range_start = 0
    range_end = 100
    default = 10


class MajorFindsPercentage(Range):
    """
    Share of the filler pool that is Increased Odds of Major Finds. Each one nudges door
    rewards toward Major Finds (Boons, Daedalus Hammers, Centaur Hearts) and away from
    Minor Finds (Bones, Ash, Nectar).
    """
    display_name = "Major Finds Percentage"
    range_start = 0
    range_end = 100
    default = 10


# REMOVED: Increased Help Odds filler did not pan out as a meaningful mechanic.
# Option stubbed out (kept for reference / possible revival). See also Items.py and __init__.py.
# class HelpOddsPercentage(Range):
#     """Share of the filler pool that is Increased Help Odds (more chance an NPC, e.g. Artemis, shows up to help during a run). 0 = none."""
#     display_name = "Increased Help Odds Percentage"
#     range_start = 0
#     range_end = 100
#     default = 10


class AshesPackValue(Range):
    """Amount of Ashes granted per Ashes item."""
    display_name = "Ashes Pack Value"
    range_start = 0
    range_end = 1000
    default = 100


class AshesPackPercentage(Range):
    """Share of the filler pool that is Ashes. I don't recommend this if Arcanasanity is on."""
    display_name = "Ashes Pack Percentage"
    range_start = 0
    range_end = 100
    default = 0


class PsychePackValue(Range):
    """Amount of Psyche granted per Psyche item."""
    display_name = "Psyche Pack Value"
    range_start = 0
    range_end = 500
    default = 20


class PsychePackPercentage(Range):
    """Share of the filler pool that is Psyche. I don't recommend this if Graspsanity is on."""
    display_name = "Psyche Pack Percentage"
    range_start = 0
    range_end = 100
    default = 0


# REMOVED: Bones filler stubbed out. Bones has no sink in this mod (its only spend,
# Cauldron incantations, is blocked entirely), so it was always force-dropped from the
# filler pool regardless of these settings -- the options did nothing. Item id offsets
# retired; do not reuse. See also Items.py and __init__.py.
# class BonesPackValue(Range):
#     """Amount of Bones granted per Bones item."""
#     display_name = "Bones Pack Value"
#     range_start = 0
#     range_end = 500
#     default = 20
#
#
# class BonesPackPercentage(Range):
#     """Share of the filler pool that is Bones."""
#     display_name = "Bones Pack Percentage"
#     range_start = 0
#     range_end = 100
#     default = 0


class MoonDustPackValue(Range):
    """Amount of Moon dust granted per Moon dust item."""
    display_name = "Moon Dust Pack Value"
    range_start = 0
    range_end = 50
    default = 2


class MoonDustPackPercentage(Range):
    """Share of the filler pool that is Moon Dust. I don't recommend this if Arcanasanity is progressive_arcana."""
    display_name = "Moon Dust Pack Percentage"
    range_start = 0
    range_end = 100
    default = 0


class ArachneArmor(DefaultOnToggle):
    """
    Adds a "Starting Arachne Armor" item to the item pool, which grants you a random
    Arachne silk armor at the start of each run. It's still lost when your armor breaks.
    """
    display_name = "Arachne Armor"


class DaedalusUpgrade(Range):
    """
    Adds this many Daedalus Upgrade items to the pool. Each one grants a random Daedalus
    Hammer upgrade for your equipped weapon at the start of each run.
    """
    display_name = "Daedalus Upgrade"
    range_start = 0
    range_end = 5
    default = 3


# ------------------------------ Options dataclass -----------------------------


@dataclass
class Hades2Options(PerGameCommonOptions):
    start_inventory_from_pool: StartInventoryPool
    # Weapon Options
    initial_weapon: InitialWeapon
    aspectsanity: AspectSanity
    weapon_aspect_combine: WeaponAspectCombine
    # Location Options
    location_system: LocationSystem
    score_rewards_amount: ScoreRewardsAmount
    enemy_locations: EnemyLocations
    npc_locations: NpcLocations
    # Item Options
    graspsanity: GraspSanity
    grasp_count: GraspCount
    grasp_intervals: GraspIntervals
    arcanasanity: ArcanaSanity
    keepsakesanity: KeepsakeSanity
    petsanity: PetSanity
    # Deathlink
    deathlink: Hades2DeathLink
    deathlink_percent: DeathLinkPercent
    deathlink_amnesty: DeathLinkAmnesty
    no_death_on_winning_runs: NoDeathOnWinningRuns
    # Vow Options
    reverse_vow: ReverseVow
    vow_pain: VowPain
    vow_grit: VowGrit
    vow_wards: VowWards
    vow_frenzy: VowFrenzy
    vow_hordes: VowHordes
    vow_menace: VowMenace
    vow_return: VowReturn
    vow_fangs: VowFangs
    vow_scars: VowScars
    vow_debt: VowDebt
    vow_shadow: VowShadow
    vow_forfeit: VowForfeit
    vow_time: VowTime
    vow_void: VowVoid
    vow_hubris: VowHubris
    vow_denial: VowDenial
    vow_rivals: VowRivals
    reverse_rivals: ReverseRivals
    # Goal & Route Options
    goal_requires_chronos: GoalRequiresChronos
    goal_requires_typhon: GoalRequiresTyphon
    goal_requires_hades: GoalRequiresHades
    goal_requires_zagreus: GoalRequiresZagreus
    goal_mode: GoalMode
    zagreus_encounter_mode: ZagreusEncounterMode
    include_underworld: IncludeUnderworld
    include_surface: IncludeSurface
    include_nightmare: IncludeNightmare
    separate_checks: SeparateChecks
    lock_routes: LockRoutes
    starting_route: StartingRoute
    start_with_surface_cure: StartWithSurfaceCure
    chronos_defeats_needed: ChronosDefeatsNeeded
    typhon_defeats_needed: TyphonDefeatsNeeded
    hades_defeats_needed: HadesDefeatsNeeded
    zagreus_defeats_needed: ZagreusDefeatsNeeded
    zagreus_weaken_tiers: ZagreusWeakenTiers
    weapons_clears_needed: WeaponsClearsNeeded
    # Misc Options
    arachne_armor: ArachneArmor
    daedalus_upgrade: DaedalusUpgrade
    # Filler Options
    nectar_pack_value: NectarPackValue
    nectar_pack_percentage: NectarPackPercentage
    starting_health_value: StartingHealthValue
    starting_health_percentage: StartingHealthPercentage
    starting_magick_value: StartingMagickValue
    starting_magick_percentage: StartingMagickPercentage
    starting_gold_value: StartingGoldValue
    starting_gold_percentage: StartingGoldPercentage
    starting_armor_value: StartingArmorValue
    starting_armor_percentage: StartingArmorPercentage
    rarity_increase_percentage: RarityIncreasePercentage
    major_finds_percentage: MajorFindsPercentage
    # help_odds_percentage: HelpOddsPercentage  # REMOVED: Increased Help Odds stubbed out
    ashes_pack_value: AshesPackValue
    ashes_pack_percentage: AshesPackPercentage
    psyche_pack_value: PsychePackValue
    psyche_pack_percentage: PsychePackPercentage
    # bones_pack_value / bones_pack_percentage: REMOVED, see Options.py comment above
    moon_dust_pack_value: MoonDustPackValue
    moon_dust_pack_percentage: MoonDustPackPercentage


# ------------------------------ Option groups ---------------------------------
# Group names double as the section headers in the generated template; the leading/
# trailing spaces in " Item Options " are intentional (they centre the title in its box).


hades2_option_groups = [
    OptionGroup("Weapon Options", [
        InitialWeapon,
        AspectSanity,
        WeaponAspectCombine,
    ]),
    OptionGroup("Location Options", [
        LocationSystem,
        ScoreRewardsAmount,
        EnemyLocations,
        NpcLocations,
    ]),
    OptionGroup(" Item Options ", [
        GraspSanity,
        GraspCount,
        GraspIntervals,
        ArcanaSanity,
        KeepsakeSanity,
        PetSanity,
    ]),
    OptionGroup("Deathlink", [
        Hades2DeathLink,
        DeathLinkPercent,
        DeathLinkAmnesty,
        NoDeathOnWinningRuns,
    ]),
    OptionGroup("Vow Options", [
        ReverseVow,
        VowPain, VowGrit, VowWards, VowFrenzy, VowHordes, VowMenace, VowReturn,
        VowFangs, VowScars, VowDebt, VowShadow, VowForfeit, VowTime, VowVoid,
        VowHubris, VowDenial, VowRivals,
        ReverseRivals,
    ]),
    OptionGroup("Goal & Route Options", [
        GoalRequiresChronos,
        GoalRequiresTyphon,
        GoalRequiresHades,
        GoalRequiresZagreus,
        GoalMode,
        ZagreusEncounterMode,
        IncludeUnderworld,
        IncludeSurface,
        IncludeNightmare,
        SeparateChecks,
        LockRoutes,
        StartingRoute,
        StartWithSurfaceCure,
        ChronosDefeatsNeeded,
        TyphonDefeatsNeeded,
        HadesDefeatsNeeded,
        ZagreusDefeatsNeeded,
        ZagreusWeakenTiers,
        WeaponsClearsNeeded,
    ]),
    OptionGroup("Misc Options", [
        ArachneArmor,
        DaedalusUpgrade,
    ]),
    OptionGroup("Filler Options", [
        NectarPackValue,
        NectarPackPercentage,
        StartingHealthValue,
        StartingHealthPercentage,
        StartingMagickValue,
        StartingMagickPercentage,
        StartingGoldValue,
        StartingGoldPercentage,
        StartingArmorValue,
        StartingArmorPercentage,
        RarityIncreasePercentage,
        MajorFindsPercentage,
        # HelpOddsPercentage,  # REMOVED: Increased Help Odds stubbed out
        AshesPackValue,
        AshesPackPercentage,
        PsychePackValue,
        PsychePackPercentage,
        # BonesPackValue, BonesPackPercentage,  # REMOVED: Bones filler stubbed out
        MoonDustPackValue,
        MoonDustPackPercentage,
    ]),
]


# ------------------------------ Presets ---------------------------------------

hades2_option_presets: Dict[str, Dict[str, Any]] = {
    "Standard": {
        "score_rewards_amount": 100,
        "chronos_defeats_needed": 1,
        "weapons_clears_needed": 1,
    },
}
