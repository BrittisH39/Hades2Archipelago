import string
import typing

from BaseClasses import Entrance, Item, ItemClassification, MultiWorld, Region, Tutorial
from .Items import item_table, item_table_weapons, item_table_filler, \
    item_table_arcana, item_table_arcana_progressive, \
    item_table_aspects_randomized, item_table_keepsakes_randomized, \
    item_table_familiars_randomized, WEAPON_SHORT_NAMES, ASPECT_MAX_RANK, \
    KEEPSAKE_PROGRESSIVE_COUNT, FAMILIAR_PROGRESSIVE_COUNT, \
    incantation_always, incantation_underworld, incantation_surface, \
    incantation_keepsake_nonprog, INCANTATION_SURFACE_ONLY_EXTRA, \
    vow_names, event_item_pairs, Hades2Item, item_name_groups
from .Routes import ROUTES, ROUTE_NAMES, UNDERWORLD, SURFACE
from .Locations import setup_location_table_with_settings, give_all_locations_table, \
    Hades2Location, location_name_groups, POINT_BASED, MAX_LOCATION_MULTIPLIER, \
    combine_active
from .Options import Hades2Options, hades2_option_groups, hades2_option_presets
from .Regions import create_regions
from .Rules import set_rules
from worlds.AutoWorld import WebWorld, World
from worlds.LauncherComponents import Component, components, Type, launch_subprocess


def launch_client():
    from .Client import launch
    launch_subprocess(launch, "Hades2Client")


components.append(Component("Hades 2 Client", "Hades2Client",
                            func=launch_client, component_type=Type.CLIENT))


class Hades2Web(WebWorld):
    tutorials = [Tutorial(
        "Multiworld Setup Guide",
        "A guide to setting up Hades 2 for Archipelago.",
        "English",
        "setup_en.md",
        "hades2/en",
        ["BrittisH39"]
    )]
    options_presets = hades2_option_presets
    option_groups = hades2_option_groups


class Hades2World(World):
    """
    Hades 2 is a rogue-like dungeon crawler in which the witch Melinoe battles
    through the Underworld to defeat the Titan of Time, Chronos.
    """

    options: Hades2Options
    options_dataclass = Hades2Options
    game = "Hades 2"
    topology_present = False
    web = Hades2Web()
    required_client_version = (0, 6, 4)

    mod_version = "0.1"

    item_name_to_id = {name: data.code for name, data in item_table.items() if data.code is not None}
    location_name_to_id = give_all_locations_table()

    item_name_groups = item_name_groups
    location_name_groups = location_name_groups

    def _normalize_route_options(self) -> None:
        """Reconcile route/goal/start settings that can otherwise contradict each other, so
        the seed generates coherently and slot_data tells the mod the truth.

        - starting_route must be a route the player actually included; an out-of-set choice
          (or a resolved "random"/"both") snaps to an included route. A goal-forced route is
          reachable but never the starting route -- it stays locked behind its unlock item.
        - vows only matter with reverse_vow on; otherwise they're zeroed (see below).
        - included_routes / separate_checks / starting_route are rewritten to match what will
          actually generate, so the values shipped in slot_data don't lie to the mod.
        """
        from .Routes import active_routes

        # Routes the player explicitly included (before the goal forces any in).
        included = self.options.included_routes.value
        included_set = {UNDERWORLD} if included == 1 else \
            {SURFACE} if included == 2 else {UNDERWORLD, SURFACE}

        # Snap starting_route to an included route.
        start_choices = ([1] if UNDERWORLD in included_set else []) + \
                        ([2] if SURFACE in included_set else [])
        sr = self.options.starting_route.value
        if sr == 0:                                   # random -> among included routes
            sr = self.random.choice(start_choices)
        elif sr == 3:                                 # both -> valid only if both included
            if len(included_set) == 1:
                sr = start_choices[0]
        elif sr == 1 and UNDERWORLD not in included_set:
            sr = start_choices[0]
        elif sr == 2 and SURFACE not in included_set:
            sr = start_choices[0]
        self.options.starting_route.value = sr

        # Vows only matter with reverse_vow on (only then are the removal items that walk
        # them back created); zero them otherwise so the mod isn't told to apply vows that
        # can never be removed.
        if not self.options.reverse_vow:
            for vow in vow_names:
                getattr(self.options, "vow_" + vow.lower()).value = 0

        # Reconcile the stored values with what will actually generate (goal-forced routes
        # included). One active route => nothing to split, and the start is that route.
        active = active_routes(self.options)
        u, s = UNDERWORLD in active, SURFACE in active
        self.options.included_routes.value = 0 if (u and s) else (1 if u else 2)
        if len(active) == 1:
            self.options.separate_checks.value = 0
            self.options.starting_route.value = 1 if u else 2

    def generate_early(self) -> None:
        from .Routes import active_routes
        self._normalize_route_options()
        # Surface entry is gated by the "Surface Access" item (the AP form of the
        # Witching-Wards incantation), so per-route lock offsets stay 0; lock_routes
        # only gates zones 2-4 within each route.
        self.route_offsets = {UNDERWORLD: 0, SURFACE: 0}
        # Which routes this seed actually generates (included_routes + whatever the goal
        # forces in). Excluded routes get no regions, locations, items, or events.
        self.active_routes = active_routes(self.options)

        # Whether the Surface starts unlocked (Surface Access pre-collected) or must be
        # found in the multiworld. Forced on when the Surface is the only route; off when
        # the Surface isn't generated at all; otherwise driven by starting_route.
        if SURFACE not in self.active_routes:
            self.surface_start = False
        elif UNDERWORLD not in self.active_routes:
            self.surface_start = True
        else:
            sr = self.options.starting_route.value
            if sr == 0:  # random
                sr = self.random.choice([1, 2])
            self.surface_start = sr in (2, 3)  # surface or both
            # A non-starting route stays locked from its FIRST zone too (not just zones 2-4):
            # entering it requires an unlock item. The Surface gates its own entry (the Surface
            # Access item / surface_access_via_progressive), so only the Underworld needs a zone
            # offset here -- set it when the Underworld isn't a starting route (i.e. a Surface-only
            # start) and routes are locked. Rules.py already scales every zone gate by this offset,
            # and create_items adds the matching extra Progressive Underworld so zone 4 stays reachable.
            if self.options.lock_routes and sr not in (1, 3):
                self.route_offsets[UNDERWORLD] = 1

        # When routes are locked and the Surface is a non-starting route, the surface door is
        # opened by the first Progressive Surface item (the mod grants the AltRunDoor on it),
        # so there is no separate "Surface Access" item -- "Descend Surface" then needs 1
        # Progressive Surface instead (Test Run 5 #14).
        self.surface_access_via_progressive = (
            SURFACE in self.active_routes
            and bool(self.options.lock_routes)
            and not self.surface_start
        )

        # --- Auto-scale locations so every item fits with ~40 filler to spare ----------
        # point_based bumps score_rewards_amount (each added score check is one location);
        # the room systems grow a multiplier so each room depth grants more checks. Both
        # are capped (score ids per route, MAX_LOCATION_MULTIPLIER); if a seed is still too
        # full after the cap, create_items logs a warning and Archipelago drops the excess.
        self.location_multiplier = 1
        target = len(self._main_pool_item_names()[0]) + 40
        if self.options.location_system.value == POINT_BASED:
            deficit = target - self._fillable_count()
            if deficit > 0:
                n = len(self.active_routes)
                # split_pools gives each route `score` checks (raise by ceil(deficit/n));
                # combine_pools splits one `score` total across routes (raise by deficit).
                add = deficit if combine_active(self.options) else -(-deficit // n)
                self.options.score_rewards_amount.value = min(
                    1000, self.options.score_rewards_amount.value + add)
        else:
            m = 1
            while m < MAX_LOCATION_MULTIPLIER and self._fillable_count(m) < target:
                m += 1
            self.location_multiplier = m

    def _fillable_count(self, multiplier: int = 1) -> int:
        """How many real (non-event) locations this seed generates at the given room
        multiplier -- i.e. how many items (filler included) it can hold."""
        table = setup_location_table_with_settings(self.options, multiplier)
        events = sum(1 for name in table if name in event_item_pairs)
        return len(table) - events

    def _main_pool_item_names(self):
        """The non-filler itempool as (pool_names, precollect_names, prog_names): names that
        go into the itempool, names to pre-collect, and which pool names must be progression.
        Pure (no multiworld side effects) so generate_early can size locations against the
        item count and create_items can build the real items. Keep in sync with create_items.

        Items that gate logic (Rules.py) must be progression, or Archipelago's reachability
        sweep (which only collects progression items) can never satisfy those gates -- so
        Grasp, Arcana and Keepsakes are promoted while their sanity is active."""
        pool, precollect, prog = [], [], set()

        # weapon_aspect_combine fuses the weapon unlock and its Aspects into a single
        # "Progressive <Weapon>" item (only when AspectSanity is randomized/progressive).
        combined = bool(self.options.weapon_aspect_combine) \
            and self.options.aspectsanity.value in (1, 2)

        # Non-starting weapons (always shuffled). When combined, the "Progressive <Weapon>"
        # items below carry the weapon unlocks, so the standalone unlocks are skipped.
        if not combined:
            for name in item_table_weapons:
                if not self.should_ignore_weapon(name):
                    pool.append(name)

        # Grasp (graspsanity): grasp_count Progressive Grasp; gates later bosses/areas.
        if self.options.graspsanity and int(self.options.grasp_intervals) > 0:
            prog.add("Progressive Grasp")
            pool += ["Progressive Grasp"] * int(self.options.grasp_count)

        # Arcana (arcanasanity): one "<Card> Arcana" each (Arcana), or 3 "Progressive
        # <Card> Arcana" each (Progressive_Arcana). Gates bosses/areas + deep score checks.
        if self.options.arcanasanity == 1:
            for name in item_table_arcana:
                prog.add(name)
                pool.append(name)
        elif self.options.arcanasanity == 2:
            for name in item_table_arcana_progressive:
                prog.add(name)
                pool += [name] * 3

        # Aspects (aspectsanity): 1 = randomized, 2 = progressive (per weapon), 0 = none.
        # When combined, Aspects ride on the "Progressive <Weapon>" items instead.
        asp = self.options.aspectsanity.value
        if combined:
            for weapon in WEAPON_SHORT_NAMES:
                pool += [f"Progressive {weapon}"] * ASPECT_MAX_RANK
        elif asp == 1:
            pool += list(item_table_aspects_randomized)
        elif asp == 2:
            for weapon in WEAPON_SHORT_NAMES:
                pool += [f"Progressive {weapon} Aspect"] * ASPECT_MAX_RANK

        # Keepsakes (keepsakesanity): 1 = randomized (one per keepsake), 2 = progressive
        # (3 Progressive Keepsake), 0 = normal. Keepsake count gates the unlock checks.
        keep = self.options.keepsakesanity.value
        if keep == 1:
            for name in item_table_keepsakes_randomized:
                prog.add(name)
                pool.append(name)
        elif keep == 2:
            prog.add("Progressive Keepsake")
            pool += ["Progressive Keepsake"] * KEEPSAKE_PROGRESSIVE_COUNT

        # Familiars (petsanity): 1 = randomized, 2 = progressive, 0 = unlocked (no items).
        pet = self.options.petsanity.value
        if pet == 1:
            pool += list(item_table_familiars_randomized)
        elif pet == 2:
            pool += ["Progressive Familiar"] * FAMILIAR_PROGRESSIVE_COUNT

        # Daedalus Upgrades (run-start Hammer) and Arachne Armor (run-start armor).
        pool += ["Daedalus Upgrade"] * int(self.options.daedalus_upgrade)
        if self.options.arachne_armor:
            pool.append("Starting Arachne Armor")

        # Vow removal items (reverse_vow): one per starting level.
        if self.options.reverse_vow:
            for vow in vow_names:
                levels = int(getattr(self.options, "vow_" + vow.lower()))
                pool += [f"{vow} Vow Removal"] * levels

        # Surface unlocks (open the door + remove the lethal penalty), only when the Surface
        # is in this seed. Surface Access is pre-collected on a surface start (and skipped
        # entirely when the first Progressive Surface opens the door instead); the Penalty
        # Cure is pre-collected only when start_with_surface_cure is on (default). When it's
        # off the cure is a normal pool item -- even on a surface start -- and the Surface
        # curse limits you to its earliest checks until you find it (see Rules.py).
        if SURFACE in self.active_routes:
            for surface_item in ("Surface Access", "Surface Penalty Cure"):
                if surface_item == "Surface Access" and self.surface_access_via_progressive:
                    continue
                if surface_item == "Surface Penalty Cure":
                    precollect_it = bool(self.options.start_with_surface_cure)
                else:
                    precollect_it = self.surface_start
                (precollect if precollect_it else pool).append(surface_item)

        # Incantation items (Cauldron unlocks, shuffled): always-on set, plus route- and
        # keepsake-gated sets. Each grants its world-upgrade in-game; no check locations.
        underworld_on = UNDERWORLD in self.active_routes
        surface_on = SURFACE in self.active_routes
        incantations = list(incantation_always)
        if underworld_on:
            incantations += incantation_underworld
        if surface_on:
            incantations += incantation_surface
            # Exhumed Troves normally rides with the underworld set; add it for surface-only.
            if not underworld_on:
                incantations.append(INCANTATION_SURFACE_ONLY_EXTRA)
        # Quickening of Sentimental Value (doubles keepsake leveling) only when keepsakes
        # aren't progressive (progressive controls leveling via its own items).
        if self.options.keepsakesanity.value != 2:
            incantations += incantation_keepsake_nonprog
        pool += incantations

        # Route-unlock progressives (lock_routes): 3 per active route gate zones 2-4, plus
        # one extra per unit of a route's lock offset (see generate_early).
        if self.options.lock_routes:
            for route in self.active_routes:
                pool += [ROUTES[route]["progressive"]] * (3 + self.route_offsets[route])

        return pool, precollect, prog

    def create_items(self) -> None:
        local_location_table = setup_location_table_with_settings(
            self.options, self.location_multiplier).copy()

        pool_names, precollect_names, prog_names = self._main_pool_item_names()
        pool = []
        for name in pool_names:
            item = Hades2Item(name, self.player)
            if name in prog_names:
                item.classification = ItemClassification.progression
            pool.append(item)
        for name in precollect_names:
            self.multiworld.push_precollected(self.create_item(name))

        # --- Lock boss-victory event items onto their event locations (active routes) ---
        active_event_pairs = {
            event: item for event, item in event_item_pairs.items()
            if event in local_location_table
        }
        for event, item in active_event_pairs.items():
            event_item = Hades2Item(item, self.player)
            self.multiworld.get_location(event, self.player).place_locked_item(event_item)

        # --- Fill the rest with filler currencies by configured proportions ---
        # The boss events are placed above and are not real, fillable locations.
        fillable = len(local_location_table) - len(active_event_pairs)
        if len(pool) > fillable:
            import logging
            logging.warning(
                "Hades 2 (player %s): %d non-filler items but only %d fillable locations - "
                "Archipelago will drop %d of them. Raise score_rewards_amount (point_based), "
                "use a location system with more checks, or turn off some sanities, to keep every item.",
                self.player_name, len(pool), fillable, len(pool) - fillable)
        total_fillers_needed = fillable - len(pool)
        if total_fillers_needed > 0:
            pool += self.build_filler_pool(total_fillers_needed)

        self.multiworld.itempool += pool

    def dropped_filler_currencies(self) -> set:
        """Currencies with no use in this mod, so they're dropped from the filler pool and
        their share redistributes to the kept fillers. Bones is always dropped (its only
        sink, Cauldron incantations, is blocked entirely); Ashes is dropped when
        ArcanaSanity is on (it would unlock Arcana) and Psyche when GraspSanity is on (it
        would raise Grasp)."""
        dropped = {"Bones"}
        if self.options.arcanasanity.value != 0:
            dropped.add("Ashes")
        # Psyche only has a sink (raising Grasp) when GraspSanity is actually active; with
        # grasp_intervals == 0 no Grasp items exist and Grasp gates nothing, so keep Psyche.
        if self.options.graspsanity and int(self.options.grasp_intervals) > 0:
            dropped.add("Psyche")
        # Moon Dust upgrades Arcana; it's useless when ArcanaSanity is Progressive (manual
        # upgrades are blocked), so drop it from the filler pool there. Otherwise keep it.
        if self.options.arcanasanity.value == 2:
            dropped.add("Moon Dust")
        return dropped

    def build_filler_pool(self, amount: int) -> list:
        dropped = self.dropped_filler_currencies()
        percentages = {
            "Ashes": int(self.options.ashes_pack_percentage),
            "Psyche": int(self.options.psyche_pack_percentage),
            "Bones": int(self.options.bones_pack_percentage),
            "Nectar": int(self.options.nectar_pack_percentage),
            "Moon Dust": int(self.options.moon_dust_pack_percentage),
            "Starting Max Health": int(self.options.starting_health_percentage),
            "Starting Max Magick": int(self.options.starting_magick_percentage),
            "Starting Gold": int(self.options.starting_gold_percentage),
            "Starting Armor": int(self.options.starting_armor_percentage),
            "Rarity Increase": int(self.options.rarity_increase_percentage),
            "Increased Odds of Major Finds": int(self.options.major_finds_percentage),
            # "Increased Help Odds": int(self.options.help_odds_percentage),  # REMOVED: stubbed out
        }
        for name in dropped:
            percentages[name] = 0

        # The "absorber" soaks up the rounding remainder; it must be a filler we are
        # keeping (Bones is always dropped now, so prefer Nectar, then the effect fillers).
        absorber = next((n for n in ("Nectar", "Starting Max Health", "Starting Gold", "Rarity Increase",
                                     "Increased Odds of Major Finds",
                                     "Starting Max Magick", "Starting Armor",  # "Increased Help Odds" REMOVED
                                     "Moon Dust", "Ashes", "Psyche")
                         if n not in dropped), "Nectar")
        total_percentage = sum(percentages.values())
        if total_percentage == 0:
            percentages[absorber] = 1
            total_percentage = 1

        filler = []
        allocated = 0
        names = [n for n in ("Ashes", "Psyche", "Bones", "Nectar", "Moon Dust",
                             "Starting Max Health", "Starting Max Magick", "Starting Gold", "Starting Armor",
                             "Rarity Increase", "Increased Odds of Major Finds")
                 if n != absorber]  # "Increased Help Odds" REMOVED
        for name in names:
            count = int(amount * percentages[name] / total_percentage)
            for _ in range(count):
                filler.append(Hades2Item(name, self.player))
            allocated += count
        for _ in range(amount - allocated):
            filler.append(Hades2Item(absorber, self.player))
        return filler

    def should_ignore_weapon(self, name: str) -> bool:
        mapping = {
            0: "Staff Weapon Unlock Item",
            1: "Blades Weapon Unlock Item",
            2: "Flames Weapon Unlock Item",
            3: "Axe Weapon Unlock Item",
            4: "Skull Weapon Unlock Item",
            5: "Coat Weapon Unlock Item",
        }
        return mapping.get(self.options.initial_weapon.value) == name

    def set_rules(self) -> None:
        set_rules(self.multiworld, self.player, self.options, self.route_offsets,
                  self.surface_access_via_progressive)

    def create_item(self, name: str) -> Item:
        return Hades2Item(name, self.player)

    def create_regions(self) -> None:
        local_location_table = setup_location_table_with_settings(
            self.options, self.location_multiplier).copy()
        create_regions(self, local_location_table)

    def fill_slot_data(self) -> dict:
        slot_data = self.options.as_dict(
            "initial_weapon", "location_system",
            "score_rewards_amount", "enemy_locations", "npc_locations",
            "graspsanity", "grasp_intervals", "grasp_count", "arcanasanity",
            "aspectsanity", "weapon_aspect_combine", "keepsakesanity", "petsanity",
            "reverse_vow", "reverse_rivals",
            "vow_pain", "vow_grit", "vow_wards", "vow_frenzy", "vow_hordes",
            "vow_menace", "vow_return", "vow_fangs", "vow_scars", "vow_debt",
            "vow_shadow", "vow_forfeit", "vow_time", "vow_void", "vow_hubris",
            "vow_denial", "vow_rivals",
            "goal", "included_routes", "separate_checks", "starting_route", "lock_routes",
            "start_with_surface_cure",
            "chronos_defeats_needed", "typhon_defeats_needed", "weapons_clears_needed",
            "ashes_pack_value", "ashes_pack_percentage",
            "psyche_pack_value", "psyche_pack_percentage",
            "bones_pack_value", "bones_pack_percentage",
            "nectar_pack_value", "nectar_pack_percentage",
            "moon_dust_pack_value", "moon_dust_pack_percentage",
            "starting_health_value", "starting_health_percentage",
            "starting_magick_value", "starting_magick_percentage",
            "starting_gold_value", "starting_gold_percentage",
            "starting_armor_value", "starting_armor_percentage",
            "rarity_increase_percentage", "major_finds_percentage",  # "help_odds_percentage" REMOVED: stubbed out
            "arachne_armor", "daedalus_upgrade",
            "deathlink", "deathlink_percent", "deathlink_amnesty",
            "no_death_on_winning_runs")
        # Resolved route-locking offsets (random already decided), for the mod.
        slot_data["underworld_offset"] = self.route_offsets[UNDERWORLD]
        slot_data["surface_offset"] = self.route_offsets[SURFACE]
        slot_data["surface_start"] = 1 if self.surface_start else 0
        # Which routes the seed actually generated, so the mod can force a route open and
        # avoid expecting checks from an excluded route.
        slot_data["underworld_active"] = 1 if UNDERWORLD in self.active_routes else 0
        slot_data["surface_active"] = 1 if SURFACE in self.active_routes else 0
        # Per-route room-check counts, so the mod knows the cap and can flush all
        # remaining room checks when the route's final boss is defeated (boss cascade).
        slot_data["underworld_room_count"] = ROUTES[UNDERWORLD]["room_count"]
        slot_data["surface_room_count"] = ROUTES[SURFACE]["room_count"]
        # Room-check multiplier from the location auto-scaler: in the room systems each room
        # depth grants this many checks (slots), so the mod must send that many per clear.
        slot_data["location_multiplier"] = self.location_multiplier
        slot_data["seed"] = "".join(self.random.choice(string.ascii_letters) for _ in range(16))
        slot_data["version_check"] = self.mod_version
        return slot_data

    def get_filler_item_name(self) -> str:
        dropped = self.dropped_filler_currencies()
        return next((n for n in ("Bones", "Nectar", "Ashes", "Psyche")
                     if n not in dropped), "Bones")


def create_region(multiworld: MultiWorld, player: int, location_database, name: str,
                  locations=None, exits=None) -> Region:
    ret = Region(name, player, multiworld)
    if locations:
        for location in locations:
            loc_id = location_database.get(location, None)
            ret.locations.append(Hades2Location(player, location, loc_id, ret))
    if exits:
        for exit_name in exits:
            ret.exits.append(Entrance(player, exit_name, ret))
    return ret
