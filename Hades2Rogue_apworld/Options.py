from dataclasses import dataclass
from typing import Dict, Any
from Options import Range, Toggle, DeathLink, Choice, StartInventoryPool, PerGameCommonOptions, \
    OptionGroup, DefaultOnToggle


# ----------------------- Gameplay decisions -----------------------------------


class InitialWeapon(Choice):
    """Choose which will be your starting weapon."""
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
    unlocked: every Aspect is available from the start, fully upgraded
    randomized: each of the 24 aspects becomes its own item; each weapon starts with one level one aspect, and the items grant their respective aspect at max level.
    progressive: you start with only Melinoe's Aspect; a "Progressive <Weapon> Aspect" item is added per weapon - the first unlocks all of that weapon's other aspects, and the rest upgrade them (up to rank 5). Normal unlocking/upgrading is blocked.
    """
    display_name = "AspectSanity"
    option_unlocked = 0
    option_randomized = 1
    option_progressive = 2
    default = 2


class WeaponAspectCombine(DefaultOnToggle):
    """
    If aspectsanity is set to progressive, replaces weapon unlocks and progressive aspects with "Progressive (Weapon)". The first you get unlocks the weapon and all aspects, the rest level up those aspects.
    If aspectsanity is set to randomized, when you unlock an aspect for a weapon, that weapon becomes unlocked but only using the aspects it's unlocked.
    """
    display_name = "Weapon/Aspect Combine"


class LocationSystem(Choice):
    """
    How to handle progression based checks.
    point_based: Each room you clear, you get points equal to it's room number, then you send checks when you get points equal to that check's number. Meaning clearing rooms 3 and 4 would give you 7 points, and unlock check 7. Then you clear 5 and 6, unlocking check 8, and leaving some progress to check 9.
    room_based: each check is the first time you clear that many rooms in one run. Room Check 10 would send when you clear 10 rooms in one run.
    per_weapon_room_based: like room_based, but a separate check for each depth cleared with each weapon - This multiplies the amount of checks by 6, leading to a substantial amount of checks.
    """
    display_name = "Location System"
    option_point_based = 0
    option_room_based = 1
    option_per_weapon_room_based = 2
    default = 0


class ScoreRewardsAmount(Range):
    """
    (point_based only) How many points checks are available. If the total number of items before fillers is larger than the total locations, this will be increased to accommodate.
    The more locations, the more filler checks, which are beneficial, but none are required.
    """
    display_name = "Score Rewards Amount"
    range_start = 40
    range_end = 1000
    default = 200


class EnemyLocations(DefaultOnToggle):
    """Add locations for the first time you defeat each enemy type."""
    display_name = "Enemy Locations"


class NpcLocations(DefaultOnToggle):
    """Add locations for the first time you speak to each NPC."""
    display_name = "NPC Locations"


class GraspSanity(DefaultOnToggle):
    """Adds progressive Grasp to the item pool, each raising your maximum Grasp from the starting 0."""
    display_name = "GraspSanity"


class GraspCount(Range):
    """How many Progressive Grasp items in the item pool."""
    display_name = "Grasp Count"
    range_start = 1
    range_end = 30
    default = 6


class GraspIntervals(Range):
    """How much each Progressive Grasp raises your maximum Grasp. (0 disables grasp gains.)"""
    display_name = "Grasp Intervals"
    range_start = 0
    range_end = 10
    default = 5


class ArcanaSanity(Choice):
    """
    How Arcana Cards are obtained.
    false: unlocked normally by purchasing at the Altar of Ashes.
    arcana: each card is unlocked by an item and cannot be purchased, but is still upgraded normally.
    Progressive_Arcana: each card gets multiple progressive items - the first unlocks
    it and the rest upgrade it; cards cannot be upgraded any other way.
    """
    display_name = "ArcanaSanity"
    option_false = 0
    option_Arcana = 1
    option_Progressive_Arcana = 2
    default = 2


class KeepsakeSanity(Choice):
    """
    How Keepsakes are handled.
    normal: unchanged from the base game.
    randomized: receiving each (reachable) keepsake is a check, and every keepsake is added as an item. (Chronos's, Zagreus's, and Hades' keepsake are added as an item, but not a location)
    progressive: receiving each keepsake is still a check, but the pool gets 3 Progressive Keepsake items - the first unlocks all keepsakes, the next two upgrade them. Normal keepsake leveling is blocked.
    """
    display_name = "KeepsakeSanity"
    option_normal = 0
    option_randomized = 1
    option_progressive = 2
    default = 1


class PetSanity(Choice):
    """
    How Familiars (pets: Frinos, Toula, Raki, Hecuba, Gale) are handled. Items only - no new check locations.
    unlocked: every familiar is available from the start.
    randomized: each familiar becomes its own item; you start with none and unlock each at maximum bond when you receive its item.
    progressive: a Progressive Familiar item is added - the first unlocks all familiars, the rest upgrade their bonds. Normal familiar unlocking/bonding is blocked.
    """
    display_name = "PetSanity"
    option_unlocked = 0
    option_randomized = 1
    option_progressive = 2
    default = 2


class Hades2DeathLink(DeathLink):
    """When you die, everyone who enabled death link dies. Of course, the reverse is true too."""
    default = 1


class DeathLinkPercent(Range):
    """When you receive a DeathLink, how much of your health you'll lose, as a percentage of your maximum health. Or, set to 0 to end the run regardless of available revives."""
    display_name = "DeathLink Damage Percent"
    range_start = 0
    range_end = 100
    default = 100


class DeathLinkAmnesty(Range):
    """
    How many of your own deaths before a DeathLink is sent to everyone else. 0 means you never send, only receive. 1 means you send one each death, anything above one is how many deaths before you send one.
    This can alleviate some pain for games where dying is a more substantial burden.
    """
    display_name = "DeathLink Deaths To Send"
    range_start = 0
    range_end = 5
    default = 1


class NoDeathOnWinningRuns(DefaultOnToggle):
    """After winning a run, you don't send a deathlink for returning back to the crossroads. I don't know why you would want to turn this off."""
    display_name = "No Death On Winning Runs"


# -------------------- Reverse Vow (Oath of the Unseen) ------------------------


class ReverseVow(DefaultOnToggle):
    """Start each run with the vows below already active (raising difficulty); each is then removed, one level at a time, by items found in the multiworld."""
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
    """Reverse which Guardians the Vow of Rivals strengthens: this makes Chronos and Typhon the last boss to return to normal."""
    display_name = "Reverse Rivals"


# -------------------- Routes & Endgame settings -------------------------------


class Goal(Choice):
    """Which final boss(es) you must defeat to win"""
    display_name = "Goal"
    option_chronos = 0
    option_typhon = 1
    option_chronos_or_typhon = 2
    option_chronos_and_typhon = 3
    default = 2


class IncludedRoutes(Choice):
    """Which routes to include. If your goal includes the final boss of a route you didn't choose, it will also be included."""
    display_name = "Included Routes"
    option_both = 0
    option_underworld_only = 1
    option_surface_only = 2
    default = 0


class SeparateChecks(Choice):
    """
    If you've included each route; should each route have it's own set of checks, or should they be combined?
    For Room based, this would mean clearing the first underworld room is a separate check than clearing the first surface room
    For Score based, this means half the score checks will be underworld, half will be surface. Meaning if you set it to 200 score checks, each route will only have 100.
    """
    display_name = "Separate Checks"
    option_split_pools = 0
    option_combine_pools = 1
    default = 0


class LockRoutes(DefaultOnToggle):
    """Lock each route's regions behind Progressive Underworld / Progressive Surface items."""
    display_name = "Lock Routes"


class StartingRoute(Choice):
    """
    Which route you can access from the start. The other route(s) open once you
    receive the route-unlock progressive item(s).
    If you pick a route you didn't include, it snaps to a route you did include. A route
    your goal forces in (e.g. the Surface when your goal is Typhon) is still reachable, but
    it won't be your starting route unless you also chose it here.
    """
    display_name = "Starting Route"
    option_random = 0
    option_underworld = 1
    option_surface = 2
    option_both = 3
    default = 1


class StartWithSurfaceCure(DefaultOnToggle):
    """Start with the "Unraveling a Fateful Bond" incantation, avoiding taking constant damage on the surface path.
    When off, the Surface Penalty Cure becomes a normal item placed in the multiworld (even on a surface start),
    and the Surface curse limits you to its earliest checks until you find it."""
    display_name = "Start With Surface Cure"


class ChronosDefeatsNeeded(Range):
    """
    How many times you must defeat Chronos to satisfy the Chronos part of the goal.
    Ignored if Chronos is not part of your goal.
    Note: with the "Chronos or Typhon" goal you only need to reach EITHER this count
    or the Typhon count (whichever boss you choose), not both.
    """
    display_name = "Chronos Defeats Needed"
    range_start = 1
    range_end = 20
    default = 1


class TyphonDefeatsNeeded(Range):
    """
    How many times you must defeat Typhon to satisfy the Typhon part of the goal.
    Ignored if Typhon is not part of your goal.
    Note: with the "Chronos or Typhon" goal you only need to reach EITHER this count
    or the Chronos count (whichever boss you choose), not both.
    """
    display_name = "Typhon Defeats Needed"
    range_start = 1
    range_end = 20
    default = 1


class WeaponsClearsNeeded(Range):
    """
    How many different weapons must clear a goal route to win.
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
    """Amount of starting max health gained from each Starting Health item."""
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
    """Amount of starting max Magick gained from each Starting Magick item."""
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
    """Amount of starting gold gained from each Starting Gold item."""
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
    """Amount of starting armor gained from each Starting Armor item."""
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
    """Share of the filler pool that is Rarity Increase, which increase the chances of higher rarity boons."""
    display_name = "Rarity Increase Percentage"
    range_start = 0
    range_end = 100
    default = 10


class MajorFindsPercentage(Range):
    """Share of the filler pool that is Increased Odds of Major Finds, which biases the rewards behind doors toward Major Finds (Boons, Daedalus Hammers, Centaur Heart, etc.) instead of Minor Finds (Bones, Ash, and Nectar)."""
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


class BonesPackValue(Range):
    """Amount of Bones granted per Bones item."""
    display_name = "Bones Pack Value"
    range_start = 0
    range_end = 500
    default = 20


class BonesPackPercentage(Range):
    """
    Share of the filler pool that is Bones. (Bones has no sink in this mod, so it is
    always dropped from the pool regardless of this value.)
    """
    display_name = "Bones Pack Percentage"
    range_start = 0
    range_end = 100
    default = 0


class MoonDustPackValue(Range):
    """Amount of Moon dust granted per Moon dust item."""
    display_name = "Moon Dust Pack Value"
    range_start = 0
    range_end = 50
    default = 2


class MoonDustPackPercentage(Range):
    """Share of the filler pool that is Moon dust. I don't recommend this for Progressive Arcana Arcanasanity option."""
    display_name = "Moon Dust Pack Percentage"
    range_start = 0
    range_end = 100
    default = 0


class ArachneArmor(DefaultOnToggle):
    """Adds a "Starting Arachne Armor" item to the pool, which grants you a random arachne silk armor at the beginning of each run."""
    display_name = "Arachne Armor"


class DaedalusUpgrade(Range):
    """Adds this many Daedalus Upgrade items to the pool, each of which grants you a random Daedalus upgrade at the beginning of each run."""
    display_name = "Daedalus Upgrade"
    range_start = 0
    range_end = 5
    default = 1


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
    goal: Goal
    included_routes: IncludedRoutes
    separate_checks: SeparateChecks
    lock_routes: LockRoutes
    starting_route: StartingRoute
    start_with_surface_cure: StartWithSurfaceCure
    chronos_defeats_needed: ChronosDefeatsNeeded
    typhon_defeats_needed: TyphonDefeatsNeeded
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
    bones_pack_value: BonesPackValue
    bones_pack_percentage: BonesPackPercentage
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
        Goal,
        IncludedRoutes,
        SeparateChecks,
        LockRoutes,
        StartingRoute,
        StartWithSurfaceCure,
        ChronosDefeatsNeeded,
        TyphonDefeatsNeeded,
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
        BonesPackValue,
        BonesPackPercentage,
        MoonDustPackValue,
        MoonDustPackPercentage,
    ]),
]


# ------------------------------ Presets ---------------------------------------

hades2_option_presets: Dict[str, Dict[str, Any]] = {
    "Standard": {
        "score_rewards_amount": 200,
        "chronos_defeats_needed": 1,
        "weapons_clears_needed": 1,
    },
}
