from .Routes import ROUTES, active_routes


def create_regions(ctx, location_database: dict) -> None:
    from . import create_region
    from .Locations import zone_tables, location_keepsakes, ENEMY_BY_ZONE, \
        NPC_BOSS_BY_ZONE, location_npc_crossroads, combine_active, combined_room_table, \
        ROOM_BASED, PER_WEAPON_ROOM_BASED

    routes = active_routes(ctx.options)
    combined_rooms = combine_active(ctx.options) \
        and ctx.options.location_system.value in (ROOM_BASED, PER_WEAPON_ROOM_BASED)

    crossroads_exits = ["Descend " + route for route in routes]

    menu_exits = ["Start"]
    if combined_rooms:
        menu_exits.append("To Combined Rooms")
    ctx.multiworld.regions += [
        create_region(ctx.multiworld, ctx.player, location_database, "Menu", None, menu_exits),
    ]

    # Each active route's 4 zones: an exit to the next zone, plus a death exit to the hub.
    for route in routes:
        zones = ROUTES[route]["zones"]
        for i, zone in enumerate(zones):
            locs = [loc for loc in zone_tables[route][zone]]
            if ctx.options.enemy_locations:
                locs += ENEMY_BY_ZONE.get((route, zone), [])
            if ctx.options.npc_locations:
                locs += NPC_BOSS_BY_ZONE.get((route, zone), [])
            exits = ["Die " + zone]
            if i < len(zones) - 1:
                exits.append("Exit " + zone)
            ctx.multiworld.regions += [
                create_region(ctx.multiworld, ctx.player, location_database, zone, locs, exits),
            ]

    # The Crossroads hub holds the keepsake unlock checks (when keepsakesanity isn't
    # "normal"). Aspects and pets are items-only; incantations were removed.
    crossroads_locs = []
    if ctx.options.keepsakesanity.value != 0:
        crossroads_locs += [loc for loc in location_keepsakes]
    if ctx.options.npc_locations:
        crossroads_locs += [loc for loc in location_npc_crossroads]

    ctx.multiworld.regions += [
        create_region(ctx.multiworld, ctx.player, location_database, "Crossroads",
                      crossroads_locs, crossroads_exits),
    ]

    # combine_pools: a single shared room region, reached from the Menu (its per-check
    # reachability — depth's zone on either route, plus the weapon for per-weapon — is set
    # in Rules._set_combined_room_rules).
    if combined_rooms:
        combined_locs = list(combined_room_table(ctx.options, ctx.location_multiplier).keys())
        ctx.multiworld.regions += [
            create_region(ctx.multiworld, ctx.player, location_database, "Combined Rooms",
                          combined_locs, None),
        ]

    # --- Link everything up ---------------------------------------------------
    ctx.multiworld.get_entrance("Start", ctx.player).connect(
        ctx.multiworld.get_region("Crossroads", ctx.player))
    if combined_rooms:
        ctx.multiworld.get_entrance("To Combined Rooms", ctx.player).connect(
            ctx.multiworld.get_region("Combined Rooms", ctx.player))

    for route in routes:
        zones = ROUTES[route]["zones"]
        ctx.multiworld.get_entrance("Descend " + route, ctx.player).connect(
            ctx.multiworld.get_region(zones[0], ctx.player))
        for i, zone in enumerate(zones):
            ctx.multiworld.get_entrance("Die " + zone, ctx.player).connect(
                ctx.multiworld.get_region("Crossroads", ctx.player))
            if i < len(zones) - 1:
                ctx.multiworld.get_entrance("Exit " + zone, ctx.player).connect(
                    ctx.multiworld.get_region(zones[i + 1], ctx.player))
