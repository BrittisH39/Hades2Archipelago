"""Cheat/debug variant of the Hades 2 Rogue client.

Adds a "Cheats" tab for manually driving location checks straight through the normal AP
client APIs (check_locations / send_msgs) -- nothing here bypasses server-side validation,
it just lets a check be sent without the game/mod having to be the one to ask for it. Built
for two things:
  1. Fixing checks that should have been sent by the mod but weren't (e.g. a full Nightmare
     clear + Hades kill where the mod<->client bridge silently ate the CHECK messages).
  2. Faster manual testing, without having to replay content in-game to trigger a send.

Registered as its own Launcher entry ("Hades 2 Rogue Client (Cheats)") so the plain client
in Client.py is untouched and stays exactly what regular players run. This is a drop-in
replacement for it otherwise -- same bridge port, same Hades 2 tab, same slash commands --
just with the extra tab. Don't run this alongside a plain Client.py instance at the same
time; only one can hold the bridge port (see Hades2Context.start_bridge_server).
"""
import asyncio

import Utils
from NetUtils import ClientStatus
from CommonClient import gui_enabled, get_base_parser, server_loop

from .Client import Hades2Context, UNIVERSAL_TRACKER_LOADED
from .Locations import enemy_locations_for
from .Routes import ROUTES, UNDERWORLD, SURFACE, NIGHTMARE


class Hades2CheatContext(Hades2Context):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        # Cheat-only: bosses whose goal-victory condition (defeats_needed + weapon-variety)
        # is being force-treated as met -- see force_boss_victory.
        self.forced_goal_bosses: set = set()

    def cascade_route_locations(self, route: str) -> list:
        """Every currently-unsent location this route's boss-clear cascade would flush --
        mirrors LocationManager.lua's flush_route_checks/flush_route_enemy_checks (see
        project_route_goal_cascade): the route's own Score/Room checks, the route-agnostic
        combine_pools "Score N"/"Room N" bucket (flushed by whichever route hits its
        threshold first, so always included), and every enemy Defeated check
        enemy_locations_for(route) says this route owns or shares."""
        id_to_name = {loc_id: name for name, loc_id in self.location_name_to_id.items()}
        enemy_names = set(enemy_locations_for(route))
        prefixes = (ROUTES[route]["score_prefix"] + " ", ROUTES[route]["room_prefix"] + " ",
                    "Score ", "Room ")
        return [loc_id for loc_id in self.missing_locations
                if id_to_name.get(loc_id, "") in enemy_names
                or id_to_name.get(loc_id, "").startswith(prefixes)]

    def force_boss_victory(self, boss: str) -> bool:
        """Cheat-only: mark `boss`'s goal-victory condition (defeats_needed + weapon-variety)
        as satisfied without actually clearing it in-game, then immediately re-check the
        overall goal using the most recently known REAL numbers for every other boss (cached
        by Hades2Context.evaluate_goal in last_goal_clears/last_goal_weapons/
        last_goal_zagreus_clears from the last real VICTORY the mod sent this session -- 0
        for any boss the mod hasn't reported yet, same as a fresh save). So this genuinely
        needs the game connected and at least one real run-clear behind it for the OTHER
        bosses in a multi-boss goal to count; only the boss you force is exempt from that.
        Returns True if this completed the overall goal."""
        self.forced_goal_bosses.add(boss)
        if not self.slot_data:
            return False
        weapons_needed = int(self.slot_data.get("weapons_clears_needed", 1))
        achieved = {}
        for b in ("chronos", "typhon", "hades"):
            real = (self.last_goal_clears.get(b, 0) >= int(
                        self.slot_data.get(f"{self.BOSS_ROUTE[b]}_wins_needed", 1))
                    and self.last_goal_weapons.get(b, 0) >= weapons_needed)
            achieved[b] = real or b in self.forced_goal_bosses
        achieved["zagreus"] = (
            self.last_goal_zagreus_clears >= int(self.slot_data.get("zagreus_defeats_needed", 1))
            or "zagreus" in self.forced_goal_bosses)

        goals_required = self.slot_data.get("goals_required") or []
        bosses = [b for b in self.GOAL_BOSSES
                  if (b == "zagreus" and int(self.slot_data.get("goal_requires_zagreus", 0)))
                  or (b in self.BOSS_ROUTE and self.BOSS_ROUTE[b].capitalize() in goals_required)]
        if not bosses:
            return False
        all_selected = int(self.slot_data.get("goal_mode", 1)) == 0
        done = all(achieved[b] for b in bosses) if all_selected else any(achieved[b] for b in bosses)
        if done:
            self.send_to_mod("GOAL")
            Utils.async_start(self.send_msgs([{"cmd": "StatusUpdate", "status": ClientStatus.CLIENT_GOAL}]))
            self.finished_game = True
        return done

    def make_gui(self):
        from kivy.clock import Clock
        from kivy.uix.boxlayout import BoxLayout
        from kivy.uix.button import Button
        from kivy.uix.gridlayout import GridLayout
        from kivy.uix.label import Label
        from kivy.uix.popup import Popup
        from kivy.uix.scrollview import ScrollView
        from kivy.uix.textinput import TextInput

        ui = super().make_gui()

        class Hades2CheatManager(ui):
            base_title = "Archipelago Hades 2 Rogue Client [CHEATS]"
            ctx: "Hades2CheatContext"

            def build(self):
                container = super().build()
                self.add_client_tab("Cheats", self.build_cheats_tab())
                return container

            # ---- Cheats tab ----------------------------------------------------

            def build_cheats_tab(self):
                root = BoxLayout(orientation="vertical", padding=8, spacing=6)

                warning = Label(
                    text="These buttons talk to the AP server directly and affect the real "
                         "multiworld -- use on your own slot only.",
                    size_hint_y=None, height=24, color=(1, 0.6, 0.2, 1))
                root.add_widget(warning)

                cascade_bar = BoxLayout(size_hint_y=None, height=44, spacing=6)
                cascade_bar.add_widget(Label(text="Boss cascade:", size_hint_x=0.22))
                for route in (UNDERWORLD, SURFACE, NIGHTMARE):
                    boss = ROUTES[route]["final_boss"]
                    btn = Button(text=f"Complete {boss} ({route})")
                    btn.bind(on_release=lambda inst, r=route, b=boss: self._cheat_cascade(r, b))
                    cascade_bar.add_widget(btn)
                root.add_widget(cascade_bar)

                victory_bar = BoxLayout(size_hint_y=None, height=44, spacing=6)
                victory_bar.add_widget(Label(text="Force victory met:", size_hint_x=0.22))
                for boss_key, boss_label in (("chronos", "Chronos"), ("typhon", "Typhon"),
                                              ("hades", "Hades"), ("zagreus", "Zagreus")):
                    btn = Button(text=boss_label)
                    btn.bind(on_release=lambda inst, bk=boss_key, bl=boss_label:
                              self._cheat_force_boss_victory(bk, bl))
                    victory_bar.add_widget(btn)
                root.add_widget(victory_bar)

                actions_bar = BoxLayout(size_hint_y=None, height=36, spacing=6)
                send_all_btn = Button(text="Send ALL Unsent")
                send_all_btn.bind(on_release=self._cheat_send_all)
                resync_btn = Button(text="Force Resync")
                resync_btn.bind(on_release=lambda *_a: Utils.async_start(self.ctx.sync_mod()))
                death_btn = Button(text="Test DeathLink")
                death_btn.bind(on_release=lambda *_a: self.ctx._forward_death_to_mod("Cheat Tab Test"))
                goal_btn = Button(text="Force FULL Goal Complete")
                goal_btn.bind(on_release=self._cheat_force_goal)
                for b in (send_all_btn, resync_btn, death_btn, goal_btn):
                    actions_bar.add_widget(b)
                root.add_widget(actions_bar)

                top = BoxLayout(size_hint_y=None, height=36, spacing=6)
                self._cheat_search = TextInput(hint_text="Filter unsent locations by name...",
                                                multiline=False, size_hint_x=0.75)
                self._cheat_search.bind(text=lambda *_a: self._refresh_cheat_list(0, force=True))
                self._cheat_status = Label(text="", size_hint_x=0.25)
                top.add_widget(self._cheat_search)
                top.add_widget(self._cheat_status)
                root.add_widget(top)

                scroll = ScrollView()
                self._cheat_list = GridLayout(cols=1, size_hint_y=None, spacing=2)
                self._cheat_list.bind(minimum_height=self._cheat_list.setter("height"))
                scroll.add_widget(self._cheat_list)
                root.add_widget(scroll)

                self._cheat_list_key = None
                Clock.schedule_interval(self._refresh_cheat_list, 2.0)
                return root

            def _confirm(self, title, message, on_yes):
                content = BoxLayout(orientation="vertical", spacing=8, padding=8)
                content.add_widget(Label(text=message))
                btn_row = BoxLayout(size_hint_y=None, height=40, spacing=8)
                popup = Popup(title=title, content=content, size_hint=(0.6, 0.4), auto_dismiss=False)

                def do_yes(*_a):
                    popup.dismiss()
                    on_yes()

                yes_btn = Button(text="Yes")
                yes_btn.bind(on_release=do_yes)
                no_btn = Button(text="Cancel")
                no_btn.bind(on_release=lambda *_a: popup.dismiss())
                btn_row.add_widget(yes_btn)
                btn_row.add_widget(no_btn)
                content.add_widget(btn_row)
                popup.open()

            def _cheat_cascade(self, route, boss):
                ctx = self.ctx
                ids = ctx.cascade_route_locations(route)
                if not ids:
                    self._cheat_status.text = f"Nothing unsent to cascade for {route}."
                    return

                def do():
                    Utils.async_start(ctx.check_locations(ids))

                self._confirm(
                    "Confirm boss cascade",
                    f"Send {len(ids)} remaining {route} Score/Room/enemy checks, as if "
                    f"{boss} was just cleared enough times (matches the mod's own "
                    "boss-clear cascade)? This affects the real multiworld.",
                    do)

            def _cheat_force_boss_victory(self, boss_key, boss_label):
                ctx = self.ctx

                def do():
                    completed = ctx.force_boss_victory(boss_key)
                    if completed:
                        self._cheat_status.text = f"{boss_label} forced -- GOAL COMPLETED."
                    else:
                        self._cheat_status.text = (
                            f"{boss_label} victory forced. Goal not yet complete -- other "
                            "required boss(es) still need real progress from the game.")

                self._confirm(
                    "Confirm forced victory",
                    f"Mark {boss_label}'s goal-victory condition (defeats + weapon variety) "
                    "as met, without actually clearing it in-game? Other required bosses "
                    "still need real progress reported by the mod. If this is the last one "
                    "your goal needs, the goal completes immediately and is visible to the room.",
                    do)

            def _cheat_send_all(self, *_a):
                ctx = self.ctx
                count = len(ctx.missing_locations)
                if not count:
                    self._cheat_status.text = "Nothing unsent."
                    return

                def do():
                    Utils.async_start(ctx.check_locations(list(ctx.missing_locations)))

                self._confirm(
                    "Confirm bulk send",
                    f"Send ALL {count} unsent location checks to the server? This releases "
                    "their items to whoever's slot has them.",
                    do)

            def _cheat_force_goal(self, *_a):
                ctx = self.ctx

                def do():
                    ctx.finished_game = True
                    Utils.async_start(ctx.send_msgs(
                        [{"cmd": "StatusUpdate", "status": ClientStatus.CLIENT_GOAL}]))

                self._confirm(
                    "Confirm goal complete",
                    "Mark this slot's goal as complete on the server, regardless of which "
                    "boss(es) the YAML actually requires? Visible to the room.",
                    do)

            def _refresh_cheat_list(self, dt, force=False):
                ctx = self.ctx
                filter_text = (self._cheat_search.text or "").strip().lower()
                id_to_name = {loc_id: ctx.location_names.lookup_in_slot(loc_id)
                              for loc_id in ctx.missing_locations}
                rows = sorted(
                    ((loc_id, name) for loc_id, name in id_to_name.items()
                     if not filter_text or filter_text in name.lower()),
                    key=lambda pair: pair[1])

                key = (filter_text, tuple(loc_id for loc_id, _ in rows))
                if key == self._cheat_list_key and not force:
                    return
                self._cheat_list_key = key

                self._cheat_list.clear_widgets()
                for loc_id, name in rows[:300]:
                    row = BoxLayout(size_hint_y=None, height=28, spacing=6)
                    name_label = Label(text=name, halign="left", valign="middle", size_hint_x=0.8)
                    name_label.bind(size=lambda inst, value: setattr(inst, "text_size", value))
                    row.add_widget(name_label)
                    send_btn = Button(text="Send", size_hint_x=0.2)
                    send_btn.bind(on_release=lambda inst, lid=loc_id:
                                  Utils.async_start(ctx.check_locations([lid])))
                    row.add_widget(send_btn)
                    self._cheat_list.add_widget(row)

                suffix = "" if len(rows) <= 300 else " (showing first 300 -- refine filter)"
                self._cheat_status.text = f"{len(rows)}/{len(id_to_name)} shown{suffix}"

        return Hades2CheatManager


def launch():
    async def main(args):
        ctx = Hades2CheatContext(args.connect, args.password)
        ctx.server_task = Utils.async_start(server_loop(ctx), name="server loop")
        Utils.async_start(ctx.start_bridge_server(), name="bridge server")
        Utils.async_start(ctx.watch_bridge_connection(), name="bridge watchdog")
        if UNIVERSAL_TRACKER_LOADED:
            ctx.run_generator()
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
