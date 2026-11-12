-- Harness for the 0.11.0 group C fixes (goals, run flow, Dream counters).
--
-- Loads the real LocationManager.lua against stubbed game/mod tables and checks:
--   1. a Dream clear never touches Chronos' counters, and on_dream_run_cleared counts once;
--   2. Asterius lands on the Dream Miniboss tier in both the Elysium Warden room and the Theseus
--      fight, which takes one Boss slot (Theseus) -- the 11/3 ruling, like Roxy/Jetty;
--   3. a Vow of Rivals rival's "Met" sends only when its unit is activated in a boss arena.
-- Then lifts the changed reload.lua hooks (OpenRunClearScreen, KillHero, LeaveRoom, the route-lock
-- kill) and checks the Final Challenge and locked-route flows.
--
-- Usage: lua goals_harness.lua <Hades2Rogue_mod dir>

local MOD_DIR = assert(arg[1], "pass the Hades2Rogue_mod directory")

local function read(path)
  local f = assert(io.open(path, "rb"), path)
  local src = f:read("a"); f:close()
  return (src:gsub("^\239\187\191", ""))
end

local failures, passes = 0, 0
local function check(cond, msg)
  if cond then passes = passes + 1 else failures = failures + 1 end
  print((cond and "PASS  " or "FAIL  ") .. msg)
end

-- A table whose missing fields are no-op functions that return nil, so incidental calls into
-- systems this harness doesn't model never crash the code under test.
local function lenient(t)
  return setmetatable(t or {}, { __index = function() return function() end end })
end

-- ---- shared stub world ------------------------------------------------------
local sent = {}
local settings = {}
shuffle_stub = nil   -- global: read by the EnemySanity.slot_check stub
local route_now, zone_now = "Underworld", 4
local state

local function fresh_state()
  state = {
    chronos_clears = 0, typhon_clears = 0, hades_clears = 0, dream_clears = 0, zagreus_clears = 0,
    weapons_cleared = {}, enemy_killed = {}, npc_met = {},
    dream_species_seen = { regular = {}, miniboss = {}, boss = {} },
    score = { Underworld = { next_check = 1 }, Surface = { next_check = 1 },
              Nightmare = { next_check = 1 }, Dream = { next_check = 1 } },
    combined_rooms = {}, route_progress = {},
  }
end
fresh_state()

local function reset()
  for k in pairs(sent) do sent[k] = nil end
  fresh_state()
end

local function was_sent(name)
  for _, n in ipairs(sent) do if n == name then return true end end
  return false
end

local env = {
  rom = { log = { info = function() end, warning = function() end, error = function() end } },
  APState = { get = function() return state end },
  Bridge = lenient({ send_check = function(name) table.insert(sent, name) end }),
  Notifications = lenient({}),
  ItemManager = lenient({
    settings = settings,
    setting_on = function(k) return tonumber(settings[k]) == 1 end,
    setting_mode = function(k) return tonumber(settings[k]) or 0 end,
    route_active = function(r) return tonumber(settings[r:lower() .. "_active"]) == 1 end,
    route_zone_unlocked = function() return true end,
    combine_active = function() return false end,
    goal_includes_zagreus = function() return tonumber(settings.goal_requires_zagreus) == 1 end,
    score_limit_for = function() return 0 end,
    equipped_weapon_unlocked = function() return true end,
  }),
  Routes = lenient({
    current = function() return route_now, zone_now end,
    biome_current = function() return route_now, zone_now end,
    dream_current = function() return "Dream", zone_now end,
    past_last_zone = function() return false end,
    zone_room_count = function() return 0 end,
    SCORE_PREFIX = {}, ROOM_PREFIX = {}, ROOM_LIMIT_KEY = {},
  }),
  EnemySanity = lenient({
    locations_on = function() return true end,
    MINIBOSS_CHECK_NAMES = { Asterius = true, Theseus = true, Roxy = true, Jetty = true },
    slot_check = function(name) return (shuffle_stub or {})[name] or name end,
  }),
  game = { CurrentRun = { CurrentRoom = {} }, EncounterData = {} },
}
env.LocationManager = {}
setmetatable(env, { __index = _G })
assert(load(read(MOD_DIR .. [[\LocationManager.lua]]), "@LocationManager.lua", "t", env))()
local LM = env.LocationManager

settings.underworld_active, settings.surface_active = 1, 1
settings.nightmare_active, settings.dream_active = 1, 1
settings.underworld_wins_needed, settings.dream_wins_needed = 5, 5
settings.npc_locations, settings.include_minibosses = 1, 1
settings.dream_boss_count, settings.dream_miniboss_count = 20, 20

-- ---- 1. Dream clear is Dream's alone ------------------------------------------
reset()
LM.on_run_cleared("Dream", "WeaponStaffSwing")      -- the OpenRunClearScreen path in a dive
check(state.chronos_clears == 0, "on_run_cleared('Dream') leaves chronos_clears at 0")
check(state.weapons_cleared.Dream == nil and state.weapons_cleared.Underworld == nil,
  "on_run_cleared('Dream') records no weapon clear")
LM.on_dream_run_cleared("WeaponStaffSwing")          -- the CheckDreamBiomeCompletion path
check(state.dream_clears == 1, "on_dream_run_cleared counts the dive once (dream_clears = 1)")
check(state.weapons_cleared.Dream and state.weapons_cleared.Dream.WeaponStaffSwing == true,
  "on_dream_run_cleared records the dive's weapon")
LM.on_run_cleared("Underworld", "WeaponAxe")
check(state.chronos_clears == 1, "a real Chronos clear still counts (chronos_clears = 1)")
check(LM.victory_payload(state) == "VICTORY:1-2-0-2-0-0-2-1",
  "VICTORY payload after one dive + one Chronos clear: " .. LM.victory_payload(state))

-- ---- 2. Asterius: Warden room vs Theseus fight --------------------------------
local function kill_in(encounter, unit_name)
  env.game.CurrentRun.IsDreamRun = true
  env.game.CurrentRun.CurrentRoom = { Encounter = encounter }
  LM.on_dream_enemy_killed({ Name = unit_name })
end
-- 11/3 ruling: one fight, one Boss slot. Asterius is Miniboss-tier everywhere, like Roxy/Jetty.
reset()
route_now, zone_now = "Dream", 2
kill_in({ Name = "MiniBossMinotaur", EncounterType = "Miniboss" }, "Minotaur")
check(was_sent("Dream Miniboss 01") and not was_sent("Dream Boss 01"),
  "Warden Asterius (MiniBossMinotaur) -> Dream Miniboss 01, no Boss slot")
reset()
local theseus_fight = { Name = "BossTheseusAndMinotaur", EncounterType = "Boss" }
kill_in(theseus_fight, "Minotaur")
kill_in(theseus_fight, "Theseus")
check(was_sent("Dream Miniboss 01") and was_sent("Dream Boss 01") and not was_sent("Dream Boss 02"),
  "Theseus fight takes ONE Boss slot (Theseus); Asterius -> Dream Miniboss 01")
check(state.dream_species_seen.boss.Theseus and not state.dream_species_seen.boss.Asterius,
  "boss tier has seen Theseus only")
-- A later Warden kill doesn't count Asterius again: the species already counted on that tier.
kill_in({ Name = "MiniBossMinotaur", EncounterType = "Miniboss" }, "Minotaur")
check(not was_sent("Dream Miniboss 02"), "Asterius counts once on the Miniboss tier across both rooms")
-- include_minibosses off: Asterius sends nothing at all (the Miniboss tier doesn't exist), Theseus still does.
reset()
settings.include_minibosses = 0
kill_in(theseus_fight, "Minotaur")
kill_in(theseus_fight, "Theseus")
check(not was_sent("Dream Miniboss 01") and was_sent("Dream Boss 01") and not was_sent("Dream Boss 02"),
  "include_minibosses off: Asterius sends nothing, Theseus -> Dream Boss 01")
settings.include_minibosses = 1
env.game.CurrentRun.IsDreamRun = nil

-- ---- 3. Vow of Rivals rival Met -------------------------------------------------
reset()
route_now, zone_now = "Surface", 1
local boss01 = { Name = "BossPolyphemus01", EncounterType = "Boss" }
env.game.CurrentRun.CurrentRoom = { Encounter = boss01 }
LM.on_encounter_started(boss01)
check(was_sent("Met Polyphemus"), "Polyphemus fight sends Met Polyphemus")
check(not was_sent("Met Medea"), "Polyphemus fight WITHOUT the Vow does not send Met Medea")
LM.on_units_activated({ [101] = { Name = "Polyphemus" } }, boss01)
check(not was_sent("Met Medea"), "activating only Polyphemus sends nothing more")
local boss02 = { Name = "BossPolyphemus02", EncounterType = "Boss" }
LM.on_units_activated({ [101] = { Name = "Polyphemus" }, [102] = { Name = "Medea" } }, boss02)
check(was_sent("Met Medea"), "Medea activated in the Vow fight -> Met Medea")
reset()
LM.on_units_activated({ [5] = { Name = "Heracles" } }, { Name = "BossPrometheus02", EncounterType = "Boss" })
check(was_sent("Met Heracles"), "Heracles activated in BossPrometheus02 -> Met Heracles")
LM.on_units_activated({ [6] = { Name = "Chronos_TyphonFight" } }, { Name = "BossTyphonHead02", EncounterType = "Boss" })
check(was_sent("Met Chronos"), "Chronos_TyphonFight activated in BossTyphonHead02 -> Met Chronos")
reset()
env.game.CurrentRun.CurrentRoom = { Encounter = { Name = "ArtemisCombatF", EncounterType = "Default" } }
LM.on_units_activated({ [7] = { Name = "Heracles" } }, { Name = "HeraclesCombatN", EncounterType = "Default" })
check(not was_sent("Met Heracles"), "a rival unit outside a boss arena is left to its own meet hooks")
settings.npc_locations = 0
LM.on_units_activated({ [102] = { Name = "Medea" } }, boss02)
check(not was_sent("Met Medea"), "npc_locations off: no rival Met")
settings.npc_locations = 1

-- ---- 3b. Bone Hydra head waves are boss phases, not rooms (10/4 guard) ------------
reset()
route_now, zone_now = "Nightmare", 2
settings.location_system = 1
local hydra_room = { Name = "X_Boss01", Encounter = { Name = "BossHydra", EncounterType = "Boss" } }
local heads = { Name = "HydraHeads3", EncounterType = "Default", SpawnWaves = {}, Spawns = {} }
pcall(LM.score_encounter, hydra_room, heads)
check(not heads._ap_scored, "HydraHeads3 inside X_Boss01 does not score a room")
pcall(LM.score_encounter, hydra_room, hydra_room.Encounter)
check(hydra_room.Encounter._ap_scored == true, "the BossHydra encounter itself still scores")

-- ---- 3c. Fields' rare cage slots released on the Cerberus kill (session F's gate) ---
reset()
settings.location_system = 0
LM.on_zone_boss_defeated("Underworld", 3)
check(was_sent("Brush-Stalker Defeated") and was_sent("Dread-Wailer Defeated"),
  "Cerberus kill releases Brush-Stalker / Dread-Wailer Defeated (any location system)")
reset()
shuffle_stub = { ["Brush-Stalker"] = "Auto-Watcher" }
LM.on_zone_boss_defeated("Underworld", 3)
check(was_sent("Auto-Watcher Defeated") and not was_sent("Brush-Stalker Defeated"),
  "shuffled: the slot's shuffle target is released instead")
shuffle_stub = nil
reset()
LM.on_zone_boss_defeated("Underworld", 2)
check(not was_sent("Brush-Stalker Defeated"), "another zone's boss releases nothing")

-- ---- 4. reload.lua hooks: Final Challenge + route lock --------------------------
-- Lift the wraps out of reload.lua and drive them with a fake modutil that just records them.
local RL = read(MOD_DIR .. [[\reload.lua]])
local function slice(src, first, stop)
  local a = assert(src:find(first, 1, true), "not found: " .. first)
  a = src:sub(1, a):match(".*\n()") or 1
  local b = assert(src:find(stop, a + #first, true), "not found: " .. stop)
  return src:sub(a, b - 1)
end

local wraps = {}
local function wrap_of(name)
  return wraps[name]
end
local hook_log = {}
local IM = {
  settings = settings,
  setting_on = function(k) return tonumber(settings[k]) == 1 end,
  goal_includes_zagreus = function() return tonumber(settings.goal_requires_zagreus) == 1 end,
  zagreus_is_final_challenge = function()
    local m = tonumber(settings.zagreus_encounter_mode) or 0
    return m == 2 or m == 3
  end,
  route_zone_unlocked = function(route, zone) return not (route == "Surface" and zone == 4) end,
  handle_nightmare_run_cleared = function() table.insert(hook_log, "nightmare_clear") end,
}
local LM2 = {
  on_run_cleared = function(route) table.insert(hook_log, "on_run_cleared:" .. tostring(route)) end,
}
local fake_game = {
  CurrentRun = nil,
  GameState = { PrimaryWeaponName = "WeaponAxe" },
  ObstacleData = { ZagContract = {} }, RoomData = { C_Boss01 = { Name = "C_Boss01" } },
  CreateRoom = function(data) return { Name = data.Name } end,
  AssignRoomToExitDoor = function() end, SpawnObstacle = function() return 999 end,
  SetupObstacle = function() end, DeepCopyTable = function(t) local c = {} for k, v in pairs(t) do c[k] = v end return c end,
  RemoveTimerBlock = function() end,
  Kill = function(who) table.insert(hook_log, "Kill:" .. tostring(who and who.Name)) end,
}
local fake_env = setmetatable({
  modutil = { mod = { Path = { Wrap = function(name, fn) wraps[name] = fn end } } },
  ItemManager = IM, LocationManager = LM2, Routes = env.Routes, APState = env.APState,
  Notifications = lenient({}), game = fake_game,
  rom = env.rom,
  AP_try = function(_, fn) local ok, err = pcall(fn); if not ok then print("  AP_try error: " .. tostring(err)) end end,
}, { __index = _G })

-- OpenRunClearScreen wrap
assert(load(slice(RL, "  -- game.OpenRunClearScreen() fires when a run is cleared", "  -- Dream Dive run-clear detection:"),
  "@reload.lua:OpenRunClearScreen", "t", fake_env))()
-- KillHero wrap (DeathLink half only matters here)
assert(load(slice(RL, "  -- DeathLink (outgoing): KillHero is the confirmed hero-death entry point.",
  "  -- enemysanity: every unit death routes through game.Kill"), "@reload.lua:KillHero", "t", fake_env))()
-- SetupHeroForEnding + deferred-screen LeaveRoom + route-lock StartEncounter, plus kill_if_route_locked
local lock_fn_src = slice(RL, "  local function kill_if_route_locked(currentRoom)", "  -- Also set the vows at the top of every StartRoom")
assert(load(lock_fn_src .. "\n" .. slice(RL, "  -- Final Challenge boon-wipe root cause:", "-- ---- Socket polling driver"):gsub("\nend%s*$", "\n"),
  "@reload.lua:tail", "t", fake_env))()

local screens = 0
local function base_screen() screens = screens + 1 end

-- 4a. Dream dive's final boss opens the screen: no Chronos credit, screen plays.
hook_log = {}; screens = 0
route_now, zone_now = "Dream", 4
settings.goal_requires_zagreus, settings.zagreus_encounter_mode = 1, 3
fake_game.CurrentRun = { Hero = { ObjectId = 1, Name = "Hero" }, IsDreamRun = true }
wrap_of("OpenRunClearScreen")(base_screen)
check(#hook_log == 0, "Dream: OpenRunClearScreen wrap does not call on_run_cleared")
check(screens == 1, "Dream: the run-clear screen plays (no Zagreus redirect in a dive)")
check(fake_game.CurrentRun.APFinalChallengeDeferredClear == nil, "Dream: no Final Challenge deferral")

-- 4b. Final Challenge after Typhon: contract spawns, screen held back, no death suppression armed.
hook_log = {}; screens = 0
route_now, zone_now = "Surface", 4
fake_game.CurrentRun = { Hero = { ObjectId = 1, Name = "Hero" } }
wrap_of("OpenRunClearScreen")(base_screen)
check(hook_log[1] == "on_run_cleared:Surface", "Final Challenge: Typhon's clear is banked first")
check(screens == 0, "Final Challenge: run-clear screen held back while the contract is up")
check(fake_game.CurrentRun.APFinalChallengeDeferredClear == true, "Final Challenge: deferral recorded on the run")
check(IM.suppress_win_death == nil, "Final Challenge: suppress_win_death is never armed any more")

-- The run-ending KillHero (Zeus's ending line, or ours after Zagreus) is NOT swallowed.
local killed_for_real = false
wrap_of("KillHero")(function() killed_for_real = true end, fake_game.CurrentRun.Hero, {})
check(killed_for_real, "the next KillHero really runs (run can end)")

-- 4c. Turning Zagreus down: walking out the normal exit plays the held-back screen once.
IM.won_run_pending = false
fake_game.OpenRunClearScreen = function() wrap_of("OpenRunClearScreen")(base_screen) end
local left = 0
local leave = function() left = left + 1 end
wrap_of("LeaveRoom")(leave, fake_game.CurrentRun, { Room = { Name = "Q_PostBoss01" } })
check(screens == 1 and left == 1, "declined: screen plays once on the way out, then the room is left")
check(fake_game.CurrentRun.APFinalChallengeDeferredClear == nil, "declined: deferral consumed")
check(not IM.force_run_clear_screen, "declined: force flag cleared")
wrap_of("LeaveRoom")(leave, fake_game.CurrentRun, { Room = { Name = "Q_PostBoss01" } })
check(screens == 1 and left == 2, "declined: a second exit does not replay the screen")

-- 4d. Taking the contract: LeaveRoom into C_Boss01 keeps the screen deferred.
fake_game.CurrentRun.APFinalChallengeDeferredClear = true
wrap_of("LeaveRoom")(leave, fake_game.CurrentRun, { Room = { Name = "C_Boss01" } })
check(screens == 1 and fake_game.CurrentRun.APFinalChallengeDeferredClear == true,
  "contract taken: no screen yet, deferral kept for after Zagreus")

-- 4e. Route lock on entry: a locked zone's first encounter never starts; kill only once.
hook_log = {}
route_now, zone_now = "Surface", 4
local room = { Name = "Q_Combat01" }
fake_game.CurrentRun = { Hero = { Name = "Hero" }, CurrentRoom = room }
local started = 0
wrap_of("StartEncounter")(function() started = started + 1 end, fake_game.CurrentRun, room, { Name = "Wave" })
check(started == 0, "locked zone: the encounter's base never runs")
check(hook_log[1] == "Kill:Hero" and #hook_log == 1, "locked zone: Melinoe killed at encounter start")
wrap_of("StartEncounter")(function() started = started + 1 end, fake_game.CurrentRun, room, { Name = "Wave2" })
check(#hook_log == 1 and started == 0, "locked zone: no second kill and no later wave in the same room")
hook_log = {}
zone_now = 3
local open_room = { Name = "P_Combat01" }
wrap_of("StartEncounter")(function() started = started + 1 end, fake_game.CurrentRun, open_room, { Name = "Wave" })
check(started == 1 and #hook_log == 0, "unlocked zone: encounter runs, no kill")

-- 4f. Fresh-save fallback intro bounce (redirect unavailable) in a LOCKED zone: the intro kill
-- runs at StartEncounter inside StartRoom's base(), and nothing kills a second time. Before the
-- fix both the route lock and kill_surface_intro killed in F_Opening01. Uses the real one-shot
-- kill functions lifted from ItemManager.lua.
local IMSRC = read(MOD_DIR .. [[\ItemManager.lua]])
assert(load(slice(IMSRC, "function ItemManager.kill_surface_intro()", "function ItemManager.apply_item(name)"),
  "@ItemManager.lua:intro_kills", "t", fake_env))()
local function intro_case(flag, label)
  hook_log = {}
  route_now, zone_now = "Surface", 4                 -- locked, as in a seed whose intro zone is locked
  IM[flag] = true
  local intro_room = { Name = "F_Opening01" }
  fake_game.CurrentRun = { Hero = { Name = "Hero" }, CurrentRoom = intro_room }
  local ran = 0
  wrap_of("StartEncounter")(function() ran = ran + 1 end, fake_game.CurrentRun, intro_room, { Name = "Opening" })
  check(ran == 0 and #hook_log == 1 and hook_log[1] == "Kill:Hero", label .. ": one kill at encounter start")
  check(IM[flag] == false, label .. ": the one-shot intro flag is consumed")
  check(intro_room._ap_intro_killed == true, label .. ": room marked so StartRoom skips its scoring/grants")
  -- What StartRoom's post-base code then calls: neither may kill again.
  local again = IM.kill_surface_intro() or IM.kill_nightmare_intro()
  check(not again and #hook_log == 1, label .. ": StartRoom's own intro kill finds nothing pending")
end
intro_case("pending_surface_intro_kill", "surface intro fallback")
intro_case("pending_nightmare_intro_kill", "nightmare intro fallback")

print(("\n%d passed, %d failed"):format(passes, failures))
os.exit(failures == 0 and 0 or 1)
