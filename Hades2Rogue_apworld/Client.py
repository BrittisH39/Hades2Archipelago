import asyncio
from typing import Optional

import Utils
from NetUtils import ClientStatus
from CommonClient import gui_enabled, logger, get_base_parser, ClientCommandProcessor, \
    CommonContext, server_loop


# --- Local bridge to the in-game Lua mod -------------------------------------
BRIDGE_HOST = "127.0.0.1"
BRIDGE_PORT = 43055

MOD_VERSION = "0.1"


class Hades2CommandProcessor(ClientCommandProcessor):
    def _cmd_resync(self):
        """Resend settings and all received items to the game."""
        Utils.async_start(self.ctx.sync_mod())

    def _cmd_bridge(self):
        """Report whether the game (Lua mod) is connected to this client."""
        if self.ctx.bridge_server is None:
            logger.info(
                f"Game bridge: NOT LISTENING on {BRIDGE_HOST}:{BRIDGE_PORT} -- the port is "
                "likely held by another process (a stale client from a previous launch?). "
                "Check the log above for 'couldn't bind' retry messages.")
        elif self.ctx.bridge_writer is not None:
            logger.info(f"Game bridge: connected (listening on {BRIDGE_HOST}:{BRIDGE_PORT}).")
        else:
            logger.info(
                f"Game bridge: listening on {BRIDGE_HOST}:{BRIDGE_PORT}, but the game hasn't "
                "connected yet. Check the game's ReturnOfModding LogOutput.log for '[AP]' lines "
                "-- look for 'LuaSocket unavailable' or a missing 'render driver alive' heartbeat.")

    def _cmd_deathlink(self):
        """Toggle Death Link, overriding the YAML setting for this session."""
        self.ctx.deathlink_enabled = not self.ctx.deathlink_enabled
        Utils.async_start(self.ctx.update_death_link(self.ctx.deathlink_enabled))
        logger.info(f"Death Link: {'enabled' if self.ctx.deathlink_enabled else 'disabled'}")

    def _cmd_death(self):
        """Test-only: push a DeathLink to the game directly, without telling the AP server
        or any other player. Use this to verify the mod's death-handling in isolation."""
        logger.info("Sending a local test DeathLink to the game (not sent to the server or other players).")
        self.ctx._forward_death_to_mod("Test")


class Hades2Context(CommonContext):
    command_processor = Hades2CommandProcessor
    game = "Hades2Rogue"
    items_handling = 0b111  # full remote
    mod_version = MOD_VERSION

    def __init__(self, server_address: Optional[str] = None, password: Optional[str] = None):
        super().__init__(server_address, password)
        self.slot_data: Optional[dict] = None
        self.location_name_to_id: dict = {}
        # Checks the mod sent before we finished connecting to the server (location_name_to_id is
        # only populated on Connected). Without buffering, such a check is dropped as "unknown"
        # AND never retried -- the mod's send_first marks it sent, so a one-time check (e.g.
        # "Met <NPC>", met at the Crossroads the instant a run loads) is lost until a manual
        # release. Held here and flushed on Connected. See the CHECK handler / _flush_pending_checks.
        self.pending_checks: list = []
        # location_id -> "<PlayerName> - <ItemName>", from LocationScouts (see scout_locations).
        # Lets the mod's subtle corner log show who got what when a check is sent.
        self.scouted: dict = {}
        self.deathlink_enabled = False
        self.deathlink_pending = False
        # A DeathLink that arrived while the game wasn't connected to the bridge (very common
        # right after a reboot: the client reaches the AP server in ~1s but the game takes tens
        # of seconds to launch and connect the local bridge). Held here instead of being dropped
        # silently, and flushed to the mod the moment the game connects (on its HELLO handshake).
        # A bool, not a count: owing one death is enough -- we don't want to insta-kill the
        # player repeatedly on reconnect after a long disconnect.
        self.pending_mod_death = False
        # Sender's slot name for the held DeathLink above, so the mod can still show who killed
        # us once it's flushed on HELLO. "Archipelago" if the bounce never carried one.
        self.pending_death_source = "Archipelago"

        # The single active connection from the Lua mod, if any.
        self.bridge_server: Optional[asyncio.AbstractServer] = None
        self.bridge_writer: Optional[asyncio.StreamWriter] = None

    # ---------------- AP server auth / lifecycle -----------------------------

    async def server_auth(self, password_requested: bool = False) -> None:
        if password_requested and not self.password:
            await super().server_auth(password_requested)
        await self.get_username()
        self.tags = set()
        await self.send_connect()

    async def shutdown(self):
        if self.bridge_server is not None:
            self.bridge_server.close()
        await super().shutdown()

    # ---------------- AP package handling ------------------------------------

    def on_package(self, cmd: str, args: dict) -> None:
        if cmd == "Connected":
            self.slot_data = args["slot_data"]
            version = self.slot_data.get("version_check", "?")
            if version != self.mod_version:
                logger.warning(
                    f"Seed generated with mod version {version}, client expects {self.mod_version}. "
                    "These may be incompatible.")
            self.location_name_to_id = self.get_location_name_to_id()
            # Flush any checks the mod sent during the pre-sync window (see pending_checks).
            if self.pending_checks:
                buffered, self.pending_checks = self.pending_checks, []
                Utils.async_start(self._flush_pending_checks(buffered))
            # Re-arm on every (re)connect: server_auth resets self.tags, so without this a
            # reconnect would silently drop the DeathLink tag even when it was enabled --
            # including a manual /deathlink enable on a seed whose slot_data has it off.
            if self.slot_data.get("deathlink") or self.deathlink_enabled:
                self.deathlink_enabled = True
                Utils.async_start(self.update_death_link(True))
            Utils.async_start(self.scout_locations())
            Utils.async_start(self.sync_mod())

        elif cmd == "ReceivedItems":
            Utils.async_start(self.send_items_to_mod())

        elif cmd == "RoomUpdate":
            # checked_locations may have changed by ANY means (another player finished and
            # released/collected their checks, an admin !send_location, etc.). Resend the
            # point_based "already checked" set so the mod can skip those checks for free.
            # (The Connected path is covered by sync_mod.) Guard like the other send paths.
            if self.bridge_writer is not None and self.slot_data is not None:
                self.send_to_mod(self.compute_checked_score())

        elif cmd == "LocationInfo":
            # Reply to our LocationScouts: cache each location's contents as
            # "<receiving player> - <item>" so sent-check banners can name who got what.
            for net_item in args.get("locations", []):
                player_name = self.player_names.get(net_item.player, f"Player {net_item.player}")
                item_name = self.item_names.lookup_in_slot(net_item.item, net_item.player)
                self.scouted[net_item.location] = f"{player_name} - {item_name}"

        # NOTE: no "Bounced" branch here on purpose. CommonContext.process_server_cmd already
        # dispatches DeathLink bounces to on_deathlink, guarded by an echo filter
        # (data["time"] != our own last_death_link, set by send_death). Handling Bounced here
        # too dispatched every link twice and bypassed that filter -- if the server echoed our
        # OWN death back after the 3s deathlink_pending window, we'd kill the player again.

    def get_location_name_to_id(self) -> dict:
        table = {}
        for location_id in self.server_locations:
            table[self.location_names.lookup_in_slot(location_id)] = location_id
        return table

    async def _flush_pending_checks(self, payloads: list) -> None:
        """Retry checks the mod sent before we were synced, now that location_name_to_id exists.
        A name still unknown here (wrong seed / genuinely-invalid location) is warned, not looped."""
        loc_ids = []
        for payload in payloads:
            loc_id = self.location_name_to_id.get(payload)
            if loc_id is None:
                logger.warning(f"Unknown location checked by game (buffered pre-connect): {payload!r}")
                continue
            loc_ids.append(loc_id)
            detail = self.scouted.get(loc_id, "")
            self.send_to_mod(f"CHECKED:{payload}|{detail}")
        if loc_ids:
            await self.check_locations(loc_ids)
            logger.info(f"Flushed {len(loc_ids)} buffered check(s) after connecting.")

    async def scout_locations(self) -> None:
        # Ask the server what every location contains (no hints created) so we can tell
        # the mod "<player> - <item>" when it sends a check. Replies arrive as LocationInfo.
        if not self.server_locations:
            return
        await self.send_msgs([{
            "cmd": "LocationScouts",
            "locations": list(self.server_locations),
            "create_as_hint": 0,
        }])

    # ---------------- DeathLink ----------------------------------------------

    def on_deathlink(self, data: dict) -> None:
        if self.deathlink_pending:
            return
        self.deathlink_pending = True
        # "source" is the sending player's slot name per the standard DeathLink payload; fall
        # back to a generic label if a bounce ever arrives without one.
        source = str(data.get("source") or "Archipelago")
        self._forward_death_to_mod(source)
        super().on_deathlink(data)
        Utils.async_start(self._lower_deathlink_flag())

    def _forward_death_to_mod(self, source: str) -> None:
        # Push an incoming DeathLink to the game. If the game isn't connected to the bridge yet
        # (reboot gap: client connected to AP, game still launching), DON'T drop it -- hold it and
        # flush on the mod's next HELLO. Otherwise the client shows the DeathLink banner but the
        # player never dies, which reads as "DeathLink does nothing."
        # Payload carries the killer's name so the mod can show "<source> Killed You" instead of
        # a generic message. ":" can't appear in a slot name (it's the mod protocol's own
        # command/payload separator), so no escaping needed beyond stripping stray newlines.
        source = source.replace("\n", " ").replace("\r", " ")
        if self.bridge_writer is not None:
            self.send_to_mod(f"DEATH:{source}")
        else:
            self.pending_mod_death = True
            self.pending_death_source = source
            logger.info("DeathLink received while the game wasn't connected -- holding it; "
                        "it will apply once the game connects to the bridge.")

    async def _lower_deathlink_flag(self) -> None:
        await asyncio.sleep(3)
        self.deathlink_pending = False

    # ---------------- Bridge: TCP server for the Lua mod ---------------------

    async def start_bridge_server(self) -> None:
        # Bind in a retry loop so a stuck port (a previous Hades 2 Rogue Client still holding
        # 43055, or a TIME_WAIT socket) NEVER prevents the client window from opening.
        # This runs as a background task; the client UI starts regardless.
        while not self.exit_event.is_set():
            try:
                self.bridge_server = await asyncio.start_server(
                    self.handle_bridge_connection, BRIDGE_HOST, BRIDGE_PORT)
                logger.info(f"Game bridge listening on {BRIDGE_HOST}:{BRIDGE_PORT}")
                return
            except OSError as exc:
                logger.warning(
                    f"Game bridge couldn't bind {BRIDGE_HOST}:{BRIDGE_PORT} ({exc}); "
                    "another Hades 2 Rogue Client may still be running. Retrying in 5s "
                    "(the client is usable now; the game will connect once the port frees).")
                await asyncio.sleep(5)

    async def watch_bridge_connection(self) -> None:
        # One-shot nudge: most people never type /bridge unprompted, so if the game hasn't
        # shown up after a generous grace period, tell them what to check instead of leaving
        # them staring at a client that looks idle.
        await asyncio.sleep(45)
        if not self.exit_event.is_set() and self.bridge_writer is None:
            if self.bridge_server is None:
                logger.warning(
                    f"Still couldn't bind {BRIDGE_HOST}:{BRIDGE_PORT} after 45s -- something "
                    "else has that port. Close any other Hades 2 Rogue Client windows/processes "
                    "and restart this client.")
            else:
                logger.warning(
                    "No connection from the game after 45s. In-game, check the small "
                    "Archipelago overlay for a red diagnostic line, or the ReturnOfModding "
                    "LogOutput.log for '[AP]' lines. Type /bridge here anytime to recheck.")

    async def handle_bridge_connection(self, reader: asyncio.StreamReader,
                                       writer: asyncio.StreamWriter) -> None:
        # Only one game connection at a time; a new one supersedes the old.
        if self.bridge_writer is not None:
            try:
                self.bridge_writer.close()
            except Exception:
                pass
        self.bridge_writer = writer
        logger.info("Game connected to bridge.")
        try:
            while not reader.at_eof():
                line = await reader.readline()
                if not line:
                    break
                message = line.decode("utf-8", errors="replace").strip()
                if message:
                    await self.handle_mod_message(message)
        except (ConnectionResetError, asyncio.IncompleteReadError):
            pass
        finally:
            if self.bridge_writer is writer:
                self.bridge_writer = None
            logger.info("Game disconnected from bridge.")

    def send_to_mod(self, message: str) -> None:
        if self.bridge_writer is None:
            return
        try:
            self.bridge_writer.write((message + "\n").encode("utf-8"))
        except Exception as exc:
            logger.warning(f"Failed to send to game: {exc}")

    async def handle_mod_message(self, message: str) -> None:
        command, _, payload = message.partition(":")

        if command == "HELLO":
            await self.sync_mod()
            # Flush a DeathLink that arrived while the game was disconnected (see
            # _forward_death_to_mod). The mod's own pending-death queue only applies it once the
            # player is in a killable, unpaused state, so this won't kill you at the Crossroads.
            if self.pending_mod_death:
                self.pending_mod_death = False
                self.send_to_mod(f"DEATH:{self.pending_death_source}")
                logger.info("Flushed a held DeathLink to the game now that it's connected.")

        elif command == "CHECK":
            if payload in self.location_name_to_id:
                loc_id = self.location_name_to_id[payload]
                await self.check_locations([loc_id])
                # Echo back the scouted contents so the mod's subtle log can show who got
                # what. Detail is empty if scout data hasn't arrived yet (mod handles that).
                detail = self.scouted.get(loc_id, "")
                self.send_to_mod(f"CHECKED:{payload}|{detail}")
            elif not self.location_name_to_id:
                # Not connected/synced yet (location_name_to_id is only filled on Connected). Don't
                # drop it -- the mod won't resend a one-time check -- buffer and flush on Connected.
                self.pending_checks.append(payload)
                logger.info(f"Buffered a check until connected: {payload!r}")
            else:
                logger.warning(f"Unknown location checked by game: {payload!r}")

        elif command == "VICTORY":
            self.evaluate_goal(payload)

        elif command == "DEATH":
            await self.send_player_death()

    # ---------------- Bridge: pushing state to the mod -----------------------

    async def sync_mod(self) -> None:
        if self.slot_data is not None:
            self.send_to_mod("SETTINGS:" + self.encode_settings())
            # Tell the mod the highest score check the server already has, so a fresh save
            # doesn't re-send / re-notify "Clear Score" checks it re-earns from depth 0.
            self.send_to_mod(self.compute_score_sync())
            # point_based: tell the mod which score checks the server already has so it can
            # skip them for free (see compute_checked_score). Sent here so a reconnecting mod
            # gets the current set; also resent on RoomUpdate when checked_locations changes.
            self.send_to_mod(self.compute_checked_score())
        await self.send_items_to_mod()

    def compute_score_sync(self) -> str:
        # Tell the mod the highest already-earned ROOM check per route, so a fresh save (lost
        # save, power outage) doesn't re-notify room checks the server already has. Covers
        # room_based ("<route> Room N") and the combine_pools shared room pool ("Room N").
        # Point-based "<route> Score N" checks are NO LONGER synced here: a max()-based jump
        # would wrongly skip 1..16 if 0017 is checked out of order. Point skipping is now
        # per-number via CHECKEDSCORE (see compute_checked_score). Per-weapon room checks
        # aren't synced (their high-water is per weapon); they re-notify harmlessly on a fresh
        # save - the checks themselves still dedupe server-side.
        id_to_name = {loc_id: name for name, loc_id in self.location_name_to_id.items()}
        uroom = sroom = hroom = croom = 0
        for loc_id in self.checked_locations:
            name = id_to_name.get(loc_id, "")
            # combine_pools shared room pool: "Room NNNN" (no route prefix, no weapon).
            if name.startswith("Room "):
                remainder = name[len("Room "):]
                if " " not in remainder:   # weapon suffix -> per-weapon combined, skip
                    try:
                        croom = max(croom, int(remainder))
                    except ValueError:
                        pass
                continue
            for prefix, route in (
                ("Underworld Room ", "u"), ("Surface Room ", "s"), ("Nightmare Room ", "h"),
            ):
                if not name.startswith(prefix):
                    continue
                remainder = name[len(prefix):]
                if " " in remainder:   # has a weapon suffix -> per-weapon, skip
                    break
                try:
                    num = int(remainder)
                except ValueError:
                    break
                if route == "u":
                    uroom = max(uroom, num)
                elif route == "s":
                    sroom = max(sroom, num)
                else:
                    hroom = max(hroom, num)
                break
        return (f"SCORESYNC:underworld_room={uroom};surface_room={sroom};"
                f"nightmare_room={hroom};combined_room={croom}")

    def compute_checked_score(self) -> str:
        # point_based only: tell the mod which score checks the server ALREADY has (a finished
        # player's auto-released/collected checks, an admin !send_location, fresh-save
        # recovery). The mod advances past these for FREE - no score spent, no CHECK re-sent.
        # This is per-number (not a high-water mark) so a gap like "0017 checked while 0015 is
        # not" is handled correctly. Parsing mirrors compute_score_sync (names with a trailing
        # space + weapon suffix are room checks and are skipped).
        # "combined" is separate_checks=combine_pools' shared, route-agnostic "Score N" pool;
        # the per-route buckets are split_pools' "<Route> Score N". A seed only ever uses one
        # kind, so the other simply comes through empty.
        id_to_name = {loc_id: name for name, loc_id in self.location_name_to_id.items()}
        underworld, surface, nightmare, combined = [], [], [], []
        for loc_id in self.checked_locations:
            name = id_to_name.get(loc_id, "")
            for prefix, bucket in (("Underworld Score ", underworld),
                                   ("Surface Score ", surface),
                                   ("Nightmare Score ", nightmare),
                                   ("Score ", combined)):
                if not name.startswith(prefix):
                    continue
                remainder = name[len(prefix):]
                if " " in remainder:   # weapon suffix -> per-weapon room check, skip
                    break
                try:
                    bucket.append(int(remainder))
                except ValueError:
                    pass
                break
        for bucket in (underworld, surface, nightmare, combined):
            bucket.sort()
        return ("CHECKEDSCORE:underworld=" + ",".join(str(n) for n in underworld)
                + ";surface=" + ",".join(str(n) for n in surface)
                + ";nightmare=" + ",".join(str(n) for n in nightmare)
                + ";combined=" + ",".join(str(n) for n in combined))

    def encode_settings(self) -> str:
        if not self.slot_data:
            return ""
        keys = [
            "initial_weapon", "location_system",
            "score_rewards_amount", "underworld_room_count", "surface_room_count",
            "nightmare_room_count", "location_multiplier",
            "enemy_locations", "npc_locations",
            "graspsanity", "grasp_intervals", "arcanasanity",
            "aspectsanity", "starting_aspect_index", "weapon_aspect_combine",
            "keepsakesanity", "petsanity",
            "reverse_vow", "reverse_rivals",
            "vow_pain", "vow_grit", "vow_wards", "vow_frenzy", "vow_hordes",
            "vow_menace", "vow_return", "vow_fangs", "vow_scars", "vow_debt",
            "vow_shadow", "vow_forfeit", "vow_time", "vow_void", "vow_hubris",
            "vow_denial", "vow_rivals",
            "goal_requires_chronos", "goal_requires_typhon", "goal_requires_hades",
            "goal_requires_zagreus", "goal_mode",
            "zagreus_encounter_mode",
            "include_underworld", "include_surface", "include_nightmare", "separate_checks",
            "starting_route", "lock_routes",
            "underworld_offset", "surface_offset", "nightmare_offset",
            "surface_start", "nightmare_start", "start_with_surface_cure",
            "underworld_active", "surface_active", "nightmare_active",
            "chronos_defeats_needed", "typhon_defeats_needed", "hades_defeats_needed",
            "zagreus_defeats_needed",
            "zagreus_weaken_tiers", "weapons_clears_needed",
            "ashes_pack_value", "psyche_pack_value",
            "nectar_pack_value", "moon_dust_pack_value",
            "starting_health_value", "starting_magick_value",
            "starting_gold_value", "starting_armor_value",
            "deathlink", "deathlink_percent", "deathlink_amnesty",
            "no_death_on_winning_runs",
        ]
        return ";".join(f"{k}={self.slot_data.get(k, 0)}" for k in keys)

    async def send_items_to_mod(self) -> None:
        if self.bridge_writer is None:
            return
        names = [self.item_names.lookup_in_game(item.item) for item in self.items_received]
        self.send_to_mod("ITEMS:" + "|".join(names))

    # ---------------- Goal evaluation ----------------------------------------

    # Route bosses (chronos/typhon/hades) each need the configured weapon-clear variety;
    # zagreus (secret superboss, no route) doesn't. Mirrors Rules.GOAL_BOSSES; kept as an
    # inline duplicate since this module runs standalone and doesn't import the apworld
    # package.
    GOAL_BOSSES = ["chronos", "typhon", "hades", "zagreus"]

    def evaluate_goal(self, payload: str) -> None:
        # payload: "<chronos_clears>-<chronos_weapons>-<typhon_clears>-<typhon_weapons>-
        #           <zagreus_clears>-<hades_clears>-<hades_weapons>"
        if not self.slot_data:
            return
        parts = payload.split("-")
        try:
            (chronos_clears, chronos_weapons, typhon_clears, typhon_weapons,
             zagreus_clears, hades_clears, hades_weapons) = (int(p) for p in parts[:7])
        except (ValueError, IndexError):
            logger.warning(f"Malformed VICTORY payload: {payload!r}")
            return

        weapons_needed = int(self.slot_data.get("weapons_clears_needed", 1))
        clears = {"chronos": chronos_clears, "typhon": typhon_clears, "hades": hades_clears}
        weapons = {"chronos": chronos_weapons, "typhon": typhon_weapons, "hades": hades_weapons}
        achieved = {
            boss: clears[boss] >= int(self.slot_data.get(f"{boss}_defeats_needed", 1))
                  and weapons[boss] >= weapons_needed
            for boss in ("chronos", "typhon", "hades")
        }
        # No weapon-variety requirement for Zagreus.
        achieved["zagreus"] = zagreus_clears >= int(self.slot_data.get("zagreus_defeats_needed", 1))

        bosses = [b for b in self.GOAL_BOSSES if int(self.slot_data.get(f"goal_requires_{b}", 0))]
        if not bosses:
            return    # misconfigured -- never completable
        all_selected = int(self.slot_data.get("goal_mode", 1)) == 0
        done = all(achieved[b] for b in bosses) if all_selected else any(achieved[b] for b in bosses)

        if done:
            self.send_to_mod("GOAL")
            Utils.async_start(self.send_msgs([{"cmd": "StatusUpdate", "status": ClientStatus.CLIENT_GOAL}]))
            self.finished_game = True

    async def send_player_death(self) -> None:
        if self.deathlink_pending or not self.deathlink_enabled:
            return
        self.deathlink_pending = True
        await self.send_death("Melinoë was slain.")
        await self._lower_deathlink_flag()

    # ---------------- GUI ----------------------------------------------------

    def run_gui(self) -> None:
        from kvui import GameManager

        class Hades2Manager(GameManager):
            base_title = "Archipelago Hades 2 Rogue Client"

        self.ui = Hades2Manager(self)
        self.ui_task = Utils.async_start(self.ui.async_run(), name="UI")


def launch():
    async def main(args):
        ctx = Hades2Context(args.connect, args.password)
        ctx.server_task = Utils.async_start(server_loop(ctx), name="server loop")
        # Background task (retries on a stuck port) so the UI always opens.
        Utils.async_start(ctx.start_bridge_server(), name="bridge server")
        Utils.async_start(ctx.watch_bridge_connection(), name="bridge watchdog")
        if gui_enabled:
            ctx.run_gui()
        ctx.run_cli()

        await ctx.exit_event.wait()
        ctx.server_address = None
        await ctx.shutdown()

    import colorama
    parser = get_base_parser()
    args = parser.parse_args()
    colorama.init()
    asyncio.run(main(args))
    colorama.deinit()
