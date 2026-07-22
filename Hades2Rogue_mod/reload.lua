---@meta _
---@diagnostic disable: lowercase-global
-- Live wiring — safe to re-run on every hot-reload.

-- ---- Dependency repair: zannc-KeepsakeExtender ------------------------------
-- 2026-07-18: fatal crash "KeepsakeLogic.lua:620: attempt to call field
-- 'createScrollArrowData' (a nil value)" when the keepsake rack opens.
--
-- Root cause is the SAME ModUtil shared-loop abort we already work around in main.lua.
-- Load order is zerp-NPCRoomRandomizer -> zannc-KeepsakeExtender -> ... -> NikkelM-Zagreus_Journey,
-- and all three schedule their init via `modutil.once_loaded.game`, which ModUtil dispatches from
-- one unprotected `for` loop. zerp's callback indexes a Zagreus' Journey room (H_PreBoss01) before
-- ZJ's own callback has created it, throws, and aborts the loop -- so every mod registered AFTER
-- zerp is skipped. KeepsakeExtender is one of them: its main.lua already ran (so its public
-- `lovely_env` table exists) but the loader that imports its reload.lua never fired, leaving
-- `lovely_env` empty. Its lovely patch injects `lovely_env.createScrollArrowData(...)` calls into
-- OpenKeepsakeRackScreen, so opening the rack dereferences nil -> hard crash.
--
-- UPDATE 2026-07-19: root-fixed via load order -- our manifest.json lists
-- NikkelM-Zagreus_Journey ahead of the zerp mods (see main.lua's recovery-shim
-- comment for the full mechanism, incl. why an earlier same-day attempt to avoid
-- this was reverted: both zerp mods and ZJ were decided to be core, expected
-- parts of the helper-randomization feature, not exotic opt-ins worth avoiding a
-- forced download for). With ZJ loading first, zerp no longer throws and this
-- repair should be a permanent no-op. It stays as a second, independent safety
-- net: if a FUTURE mod update introduces a genuine throw inside KeepsakeExtender's
-- own on_ready specifically (not just an upstream abort), the dispatch recovery
-- shim in main.lua can't save it (poisoned mods don't get re-attempted on retry),
-- but this repair still would.
-- We don't touch their files. Instead we re-run KeepsakeExtender's own
-- reload.lua (a pure batch of function definitions -- no side effects) into its own `lovely_env`,
-- exactly the way ENVY's `import` would have (loadfile with the env as `_ENV`; reads fall back to
-- the game globals through the env's metatable, writes land back in lovely_env). Guarded on the
-- missing function, so it only acts when the loader really was skipped and is a no-op otherwise;
-- runs on every hot-reload, so it self-heals after the mid-run script reload re-poisons the loop.
local function repair_keepsake_extender()
  local ke = rom.mods and rom.mods['zannc-KeepsakeExtender']
  if not (ke and ke.lovely_env) then return end            -- mod absent/disabled: nothing to do
  if ke.lovely_env.createScrollArrowData ~= nil then return end -- already initialised: no-op

  local pluginsDir = rom.path.get_parent(_PLUGIN.plugins_mod_folder_path)
  local kePath = rom.path.combine(rom.path.combine(pluginsDir, 'zannc-KeepsakeExtender'), 'reload.lua')

  local ok, err = pcall(function()
    -- `_ENV = ke.lovely_env`: its top-level `function foo` definitions write into lovely_env, and
    -- the globals those functions close over (GameState, SetAlpha, wait, ...) resolve through the
    -- fallback metatable KeepsakeExtender installed with import_as_fallback(rom.game).
    local chunk, lerr = loadfile(kePath, 't', ke.lovely_env)
    if not chunk then error(tostring(lerr)) end
    chunk()
  end)

  if ok and ke.lovely_env.createScrollArrowData ~= nil then
    rom.log.info('[AP] repaired zannc-KeepsakeExtender lovely_env (its once_loaded.game init was skipped by the ModUtil loop abort)')
  else
    rom.log.warning('[AP] could not repair zannc-KeepsakeExtender lovely_env: ' .. tostring(err) ..
      ' -- keepsake rack may still crash on open')
  end
end
repair_keepsake_extender()

-- ---- Dependency health check: helper-randomizer mods ------------------------
-- Runs at boot (and every hot-reload), AFTER ModUtil's once_loaded.game dispatch
-- has finished (ModUtil's rom.on_import.post hook registered before ours, so it
-- runs first on the same import event). Verifies that the third-party mods our
-- helper-NPC randomization delegates to actually initialized this session, using
-- markers each mod's own init provably leaves behind:
--   * Zagreus' Journey: registers RoomData.A_Story01 (Sisyphus) with real data.
--   * zerp-NPCRoomRandomizer: TWO markers, because its historical crash site is
--     MID-init -- the ready.lua:261 loop stamps a PathFalse requirement keyed
--     "zerp-NPCRoomRandomizerSwappedStoryMap" into F_Story01 BEFORE reaching the
--     ZJ rooms it used to crash on, so that marker only proves init STARTED.
--     Completion is proven by `SelectRandomStoryRoom` existing on its registered
--     mod object (modutil.mod.Mods.Data[guid]) -- defined right AFTER that loop.
--   * zerp-Extended_NPC_Encounters: inserts a PathFalse requirement keyed
--     "zerp-Extended_NPC_EncountersNextRoomCageFieldEncounters" into the base
--     NemesisCombatH encounter (its ready.lua PostSetupRunDataFuncs, unconditional).
-- If a marker is missing while the mod is present+enabled, something aborted the
-- dispatch again (or a mod update changed internals) -- scream in the log so a
-- broken-randomizer session is diagnosable in seconds instead of another
-- multi-session hunt. With ZJ now a declared dependency (loads first, see
-- main.lua), none of these should normally fire.
local function dependency_mod_enabled(guid)
  local m = rom.mods and rom.mods[guid]
  if not m then return false end
  local cfg = m.config
  if cfg and cfg.enabled == false then return false end
  return true
end

local function has_pathfalse_marker(reqs, marker)
  if type(reqs) ~= 'table' then return false end
  for _, req in ipairs(reqs) do
    if type(req) == 'table' and type(req.PathFalse) == 'table' then
      for _, part in ipairs(req.PathFalse) do
        if part == marker then return true end
      end
    end
  end
  return false
end

local function check_helper_mods_initialized()
  local ok, err = pcall(function()
    if dependency_mod_enabled('NikkelM-Zagreus_Journey') then
      if game.RoomData and game.RoomData.A_Story01 ~= nil then
        rom.log.info("[AP] HEALTH: Zagreus' Journey rooms registered (Nightmare content available)")
      else
        rom.log.error("[AP] HEALTH: Zagreus' Journey is enabled but its rooms never registered -- "
          .. "either the once_loaded.game dispatch died before reaching it, or its installation is "
          .. "invalid. Nightmare route AND story-room randomization are broken this session.")
      end
    end
    if dependency_mod_enabled('zerp-NPCRoomRandomizer') then
      local f = game.RoomData and game.RoomData.F_Story01
      local started = has_pathfalse_marker(f and f.GameStateRequirements,
        'zerp-NPCRoomRandomizerSwappedStoryMap')
      local zmod = modutil and modutil.mod and modutil.mod.Mods
        and modutil.mod.Mods.Data and modutil.mod.Mods.Data['zerp-NPCRoomRandomizer']
      local completed = zmod ~= nil and type(zmod.SelectRandomStoryRoom) == 'function'
      if completed then
        rom.log.info('[AP] HEALTH: zerp-NPCRoomRandomizer initialized (story-room randomization active)')
      elseif started then
        rom.log.error('[AP] HEALTH: zerp-NPCRoomRandomizer STARTED init but crashed partway '
          .. '(its ready.lua threw mid-run) -- story-room (helper NPC) randomization is NOT active this session')
      else
        rom.log.error('[AP] HEALTH: zerp-NPCRoomRandomizer is enabled but never initialized -- '
          .. 'story-room (helper NPC) randomization is NOT active this session')
      end
    end
    if dependency_mod_enabled('zerp-Extended_NPC_Encounters') then
      local enc = game.EncounterData and game.EncounterData.NemesisCombatH
      if has_pathfalse_marker(enc and enc.GameStateRequirements,
          'zerp-Extended_NPC_EncountersNextRoomCageFieldEncounters') then
        rom.log.info('[AP] HEALTH: zerp-Extended_NPC_Encounters initialized (combat-assist NPC randomization active)')
      else
        rom.log.error('[AP] HEALTH: zerp-Extended_NPC_Encounters is enabled but never initialized -- '
          .. 'combat-assist NPC randomization is NOT active this session')
      end
    end
  end)
  if not ok then
    rom.log.warning('[AP] helper-mod health check errored: ' .. tostring(err))
  end
end
check_helper_mods_initialized()

-- Helper Room Sanity: intercept zerp-NPCRoomRandomizer's own room-swap decision at its
-- source, instead of disabling/removing the mod. ChooseNextRoomData/LeaveRoom (its ready.lua)
-- call `mod.SelectRandomStoryRoom(origStoryRoom, banned1, banned2)` via a LIVE table lookup on
-- its own registered mod object every time a story room is about to appear -- not a captured
-- local -- so replacing that field here, once, after its own init has completed (confirmed by
-- check_helper_mods_initialized just above), redirects every future call without touching its
-- config file, without a restart, and without disabling the dependency. Reads
-- ItemManager.helper_room_random_allowed() fresh on every call (not cached), so a mode change
-- across a rejoin self-heals the same way the rest of this mod's settings do.
-- ZJ_STORY_ROOMS: Zagreus' Journey's own story-room keys (Sisyphus/Eurydice/Patroclus). When
-- IncludeZagreusJourney is off, a swap INTO one of these is rejected below regardless of
-- helper_room_sanity's mode -- these NPCs must never appear via the any-route randomizer
-- without ZJ content enabled (see Routes.ZJ_RANDOMIZED_ONLY, apworld side).
local ZJ_STORY_ROOMS = { A_Story01 = true, X_Story01 = true, Y_Story01 = true }
-- items_random (mode 3): re-roll the native pick a bounded number of times until it lands on an
-- NPC that's actually unlocked (ItemManager.helper_npc_eligible). This is the SECOND half of the
-- "block the room, not the interaction" redesign (see eligibility_override's own comment,
-- ItemManager.lua) -- eligibility_override already keeps a story room from happening AT ALL in
-- its 6 base-game zones unless SOME helper is unlocked; this filter then makes sure the
-- IDENTITY that actually gets picked for that door is one of the unlocked ones, not just
-- whichever native_select happened to roll. Each retry calls native_select with the SAME args
-- (cheap -- it just rerolls game.CurrentRun's own "already used this run" pool, no state
-- mutation happens on a call that isn't ultimately used), so this is safe to loop. Nightmare's
-- A/X/Y_Story01 aren't covered by the eligibility half (see ItemManager.STORY_ROOM_TO_NPC's
-- header -- different requirement DSL, no identity to gate), so on those doors this filter is
-- the ONLY protection; if it exhausts every retry (nobody unlocked at all yet), it falls back to
-- the room native_select originally picked rather than erroring -- if that happens to be a
-- locked NPC, the UseNPC wrap no longer blocks interacting with them (see below), so this is a
-- graceful "proceeds like vanilla" fallback, not a softlock.
local STORY_ROOM_REROLL_ATTEMPTS = 20
local function pick_unlocked_story_room(native_select, origStoryRoom, banned1, banned2)
  local result = native_select(origStoryRoom, banned1, banned2)
  if ItemManager.setting_mode("helper_room_sanity") ~= 3 then return result end
  local tries = 0
  while result and tries < STORY_ROOM_REROLL_ATTEMPTS do
    local npc = ItemManager.STORY_ROOM_TO_NPC[result]
    if not npc or ItemManager.helper_npc_eligible(npc) then break end
    result = native_select(origStoryRoom, banned1, banned2)
    tries = tries + 1
  end
  return result
end

-- ZJ trio fallback (July 22): Sisyphus/Eurydice/Patroclus have no native door at all once
-- Nightmare isn't part of this seed -- their A/X/Y_Story01 rooms are simply never visited, so
-- "unlocked"/"items" (native-only, modes 0/1) would otherwise strand them with nowhere to ever
-- appear (see Locations._route_locked_out's docstring, apworld side). When IncludeZagreusJourney
-- is on but Nightmare is excluded, let zerp's own randomizer roll for a door anyway, but ONLY
-- accept the result if it lands on one of the ZJ trio -- reject anything else so the other 7
-- story NPCs still keep native-only's "no cross-door shuffling" guarantee. Bounded retries, same
-- shape as pick_unlocked_story_room's reroll above. Under mode 1 (items, not random) the result
-- is additionally required to already be eligible (its own "<NPC> Room" item received) --
-- there's no separate room-level gate covering these 3 doors (ItemManager.STORY_ROOM_TO_NPC's
-- header), so this filter is their only protection.
local ZJ_TRIO_FALLBACK_ATTEMPTS = 20
local function pick_zj_trio_fallback(native_select, origStoryRoom, banned1, banned2)
  local mode = ItemManager.setting_mode("helper_room_sanity")
  local tries = 0
  while tries < ZJ_TRIO_FALLBACK_ATTEMPTS do
    local candidate = native_select(origStoryRoom, banned1, banned2)
    if candidate and ZJ_STORY_ROOMS[candidate] then
      local npc = ItemManager.STORY_ROOM_TO_NPC[candidate]
      if mode ~= 1 or not npc or ItemManager.helper_npc_eligible(npc) then
        return candidate
      end
    end
    tries = tries + 1
  end
  return origStoryRoom
end

pcall(function()
  local zmod = modutil and modutil.mod and modutil.mod.Mods and modutil.mod.Mods.Data
    and modutil.mod.Mods.Data['zerp-NPCRoomRandomizer']
  if zmod and type(zmod.SelectRandomStoryRoom) == 'function' then
    local native_select = zmod.SelectRandomStoryRoom
    zmod.SelectRandomStoryRoom = function(origStoryRoom, banned1, banned2)
      if not ItemManager.helper_room_random_allowed() then
        -- Native-only mode (0/1): normally keep the door's own native helper untouched. EXCEPTION:
        -- see pick_zj_trio_fallback's comment above -- the ZJ trio still gets a shot at this door
        -- when Nightmare's excluded from this seed but ZJ content is still enabled.
        if ItemManager.zj_content_enabled() and not ItemManager.route_active("Nightmare") then
          return pick_zj_trio_fallback(native_select, origStoryRoom, banned1, banned2)
        end
        return origStoryRoom
      end
      local result = pick_unlocked_story_room(native_select, origStoryRoom, banned1, banned2)
      if not ItemManager.zj_content_enabled() and ZJ_STORY_ROOMS[result] then
        return origStoryRoom -- IncludeZagreusJourney off: never swap a foreign door into ZJ's cast
      end
      return result
    end
    rom.log.info("[AP] helper_room_sanity: intercepted zerp-NPCRoomRandomizer.SelectRandomStoryRoom")
  else
    rom.log.error("[AP] helper_room_sanity: zerp-NPCRoomRandomizer.SelectRandomStoryRoom not found "
      .. "-- randomization control inactive this session (falls back to that mod's own default)")
  end
end)

-- Combat Helper Sanity: item-gate each combat-assist NPC's own spawn-trigger function so
-- items/items_random (1/3) can silently no-op the spawn (the fight continues without a
-- helper, exactly like a native low roll) until ItemManager.combat_helper_eligible(name) is
-- true. Nemesis and Athena need only one wrap each: their zerp-added foreign-zone encounters
-- inherit BaseNemesisCombat/BaseAthenaCombat wholesale (confirmed by reading nemesis.lua/
-- athena.lua), so native AND foreign zones already call the SAME base-game function.
-- Artemis/Heracles/Icarus are different: zerp defines its OWN parallel copy of each on its
-- own registered mod object for use ONLY by its foreign-zone encounters (confirmed by
-- reading artemis.lua/heracles.lua/icarus.lua) -- their native-zone encounters still call
-- the base game's own function. Both need wrapping for full coverage; see the second pcall
-- block below for the foreign-zone half. Modeled on the pre-existing (removed) Category 2
-- redirect wraps -- same functions, same `base`-capture-not-`game[name]`-lookup technique
-- (see [[project_helper_npcs_any_location]] for why the latter silently no-ops) -- repurposed
-- here to gate eligibility instead of swap identity.
for npc, fnName in pairs({
  Artemis = "HandleArtemisSpawn", Heracles = "HandleHeraclesSpawn", Icarus = "HandleIcarusSpawn",
  Nemesis = "HandleNemesisCombatSpawn", Athena = "HandleAthenaSpawn",
}) do
  pcall(function()
    modutil.mod.Path.Wrap(fnName, function(base, ...)
      if not ItemManager.combat_helper_eligible(npc) then return end
      return base(...)
    end)
  end)
end

-- Foreign-zone half for Artemis/Heracles/Icarus (see comment above): their OWN copy lives on
-- zerp-Extended_NPC_Encounters' registered mod object, not on `game`, so Path.Wrap can't
-- reach it -- same live-table monkeypatch technique as the SelectRandomStoryRoom intercept
-- above (there's no ModUtil `base` to capture on a foreign mod's own table).
pcall(function()
  local zmod = modutil and modutil.mod and modutil.mod.Mods and modutil.mod.Mods.Data
    and modutil.mod.Mods.Data['zerp-Extended_NPC_Encounters']
  if not zmod then
    rom.log.error("[AP] combat_helper_sanity: zerp-Extended_NPC_Encounters mod table not found "
      .. "-- foreign-zone item gate inactive this session")
    return
  end
  for npc, fnName in pairs({ Artemis = "HandleArtemisSpawn", Heracles = "HandleHeraclesSpawn", Icarus = "HandleIcarusSpawn" }) do
    local native = zmod[fnName]
    if type(native) == "function" then
      zmod[fnName] = function(...)
        if not ItemManager.combat_helper_eligible(npc) then return end
        return native(...)
      end
    else
      rom.log.error("[AP] combat_helper_sanity: zerp-Extended_NPC_Encounters." .. fnName
        .. " not found -- foreign-zone item gate inactive for " .. npc .. " this session")
    end
  end
  rom.log.info("[AP] combat_helper_sanity: intercepted zerp-Extended_NPC_Encounters foreign-zone spawn functions")
end)

-- Thanatos: both native (Zagreus' Journey's own Nightmare-zone encounters) and foreign
-- (zerp's base-zone additions, which inherit BaseThanatos wholesale -- confirmed by reading
-- thanatos.lua) call the SAME function, NikkelM-Zagreus_Journey's own mod.HandleThanatosSpawn
-- (confirmed via its FunctionMappings/ThanatosLogic.lua) -- one live-table monkeypatch
-- covers every zone, same technique as the zerp foreign-zone block above.
pcall(function()
  if not dependency_mod_enabled('NikkelM-Zagreus_Journey') then
    return -- not installed: expected for players who haven't opted into Nightmare, not an error
  end
  local zjmod = modutil and modutil.mod and modutil.mod.Mods and modutil.mod.Mods.Data
    and modutil.mod.Mods.Data['NikkelM-Zagreus_Journey']
  local native = zjmod and zjmod.HandleThanatosSpawn
  if type(native) == "function" then
    zjmod.HandleThanatosSpawn = function(...)
      if not ItemManager.combat_helper_eligible("Thanatos") then return end
      return native(...)
    end
    rom.log.info("[AP] combat_helper_sanity: intercepted NikkelM-Zagreus_Journey.HandleThanatosSpawn")
  else
    rom.log.error("[AP] combat_helper_sanity: NikkelM-Zagreus_Journey.HandleThanatosSpawn not found "
      .. "-- Thanatos item gate inactive this session (falls back to native behavior)")
  end
end)

-- ---- Client -> mod message handlers -----------------------------------------

-- Each step below used to run bare: a Lua error partway through (e.g. from stale
-- game.CurrentRun/GameState references while the game is mid-transition) silently
-- aborted every step after it with zero log trace -- e.g. the 7/22 9:56am crash, where
-- the log shows apply_all_vows's diagnostic lines and then nothing before the native
-- crash, so there was no way to tell which of the remaining steps was mid-flight.
-- pcall each step individually so one failure can't eat the rest of the chain, and
-- logs which step failed if it does.
local function run_settings_step(name, fn)
  local ok, err = pcall(fn)
  if not ok then
    rom.log.error("[AP] SETTINGS step '" .. name .. "' failed: " .. tostring(err))
  end
end
Bridge.on("SETTINGS", function(payload)
  run_settings_step("apply_settings", function() ItemManager.apply_settings(payload) end)
  run_settings_step("cache_settings", function() ItemManager.cache_settings(payload) end) -- persist for next boot (load-time settings apply at the menu)
  run_settings_step("apply_all_vows", function() ItemManager.apply_all_vows() end)         -- enforce vows once settings arrive (if in a save)
  run_settings_step("apply_initial_weapon", function() ItemManager.apply_initial_weapon() end) -- unlock the seed's starting weapon (else non-Staff rolls are unobtainable)
  run_settings_step("apply_surface_start", function() ItemManager.apply_surface_start() end)   -- open the surface if the seed starts it unlocked
  run_settings_step("apply_nightmare_start", function() ItemManager.apply_nightmare_start() end) -- open the Nightmare Chaos Gate if the seed starts it unlocked
  run_settings_step("reassert_route_access", function() ItemManager.reassert_route_access() end) -- re-open Surface/Nightmare doors from persisted route_progress (reboot-gap self-heal)
  run_settings_step("apply_unlocked_modes", function() ItemManager.apply_unlocked_modes() end)   -- force-unlock aspects/pets when set to "unlocked"
  run_settings_step("apply_aspect_base_lock", function() ItemManager.apply_aspect_base_lock() end) -- aspectsanity=randomized: take away the free Aspect of Melinoe (it's an item)
  run_settings_step("apply_incantation_starts", function() ItemManager.apply_incantation_starts() end) -- grant the start-with incantations (QoL systems)
  run_settings_step("apply_conditional_incantation_starts", function() ItemManager.apply_conditional_incantation_starts() end) -- grant the route-/mode-scoped start-with incantations
  run_settings_step("apply_keepsake_reclaim", function() ItemManager.apply_keepsake_reclaim() end)   -- re-lock pre-owned keepsakes so re-gifting checks
  run_settings_step("apply_keepsake_rack_unlock", function() ItemManager.apply_keepsake_rack_unlock() end) -- open the Crossroads keepsake rack (locked until Nectar gained)
  run_settings_step("apply_combat_helper_random", function() ItemManager.apply_combat_helper_random() end) -- flip zerp-Extended_NPC_Encounters' any-location flags to match the mode
end)
Bridge.on("ITEMS", function(payload)
  -- Do NOT apply inline. Receiving items runs live grants (the currency-gain presentation, the
  -- live rarity-trait mutation) that crash/softlock the game if they fire while a boon-selection
  -- screen or a scripted conversation/cutscene owns input -- the same class of bug as the boon
  -- banner softlock. So just stash the payload; ItemManager.drain_pending_items (render driver,
  -- below) applies it on the next SAFE frame. ITEMS is always the full ordered list and
  -- apply_full_list is idempotent (s.processed), so a newer payload simply supersedes a pending
  -- one -- no queue to manage.
  ItemManager.pending_items = payload
end)
Bridge.on("RESET", function() ItemManager.reset_applied() end)

-- Turn a raw location name into a short label for the corner log, matching the wishlist
-- mockup ("Sent Score Check 15 - Mario64 - Power Star").
local function check_label(loc)
  local n = loc:match("^[%a ]+ Score (%d+)$")               -- "Underworld/Nightmare Score 0015"
  if n then return "Score Check " .. tonumber(n) end
  local cn = loc:match("^Score (%d+)$")                      -- combine_pools shared "Score 0015"
  if cn then return "Score Check " .. tonumber(cn) end
  local route, depth, rest = loc:match("^([%a ]+) Room (%d+)(.*)$")  -- "Surface Room 0012 [Weapon]"
  if depth then return route .. " Room " .. tonumber(depth) .. (rest or "") end
  local cdepth, crest = loc:match("^Room (%d+)(.*)$")      -- combine_pools shared "Room 0012"
  if cdepth then return "Room " .. tonumber(cdepth) .. (crest or "") end
  return loc
end

-- The client echoes CHECKED:<location>|<player> - <item> after each check it forwards, so
-- we can show who got what in the subtle corner log (detail is empty until scouts arrive).
Bridge.on("CHECKED", function(payload)
  if not Overlay then return end
  local loc, detail = payload:match("^(.-)|(.*)$")
  loc = loc or payload
  local line = "Sent " .. check_label(loc)
  if detail and detail ~= "" then line = line .. " - " .. detail end
  Overlay.push(line, Overlay.COLOR.sent)
end)
-- The client tells us the highest score check the server already has, so a fresh save
-- doesn't re-send / re-notify "Clear Score" checks it re-earns from depth 0.
local SCORESYNC_ROUTE_KEY = { underworld = "Underworld", surface = "Surface", nightmare = "Nightmare" }
local SCORESYNC_ROOM_ROUTE_KEY = {
  underworld_room = "Underworld", surface_room = "Surface", nightmare_room = "Nightmare",
}
Bridge.on("SCORESYNC", function(payload)
  local s = APState.get()
  if not s then return end
  for pair in payload:gmatch("[^;]+") do
    local k, v = pair:match("^(.-)=(.*)$")
    local n = tonumber(v) or 0
    -- point_based keys: underworld / surface / nightmare (advance next_check past earned checks).
    local route = SCORESYNC_ROUTE_KEY[k]
    if route and s.score[route] and (n + 1) > s.score[route].next_check then
      s.score[route].next_check = n + 1
    end
    -- room_based keys: underworld_room / surface_room / nightmare_room (advance the room high-water mark).
    local room_route = SCORESYNC_ROOM_ROUTE_KEY[k]
    if room_route and s.score[room_route] and n > (s.score[room_route].room_high or 0) then
      s.score[room_route].room_high = n
    end
    -- combine_pools shared room pool: advance the combined high-water mark.
    if k == "combined_room" and s.combined_rooms and n > (s.combined_rooms.room_high or 0) then
      s.combined_rooms.room_high = n
    end
  end
  rom.log.info("[AP] score sync: " .. payload)
end)
-- point_based: the client tells us which "<route> Score N" checks the server ALREADY has (a
-- finished player's released/collected checks, an admin !send_location, fresh-save recovery).
-- We REPLACE the runtime set, then run a skip pass on each active route so a check that JUST
-- became checked (a player finished mid-session) advances next_check immediately without
-- waiting for a room clear. Earning a checked one costs ZERO score and re-sends nothing.
-- Parsing mirrors the SCORESYNC handler above; empty lists (underworld=;surface=) are allowed.
Bridge.on("CHECKEDSCORE", function(payload)
  -- "combined" is combine_pools' shared route-agnostic "Score N" pool; the rest are the
  -- per-route split_pools ones. Only one kind is in play per seed, but parsing both is
  -- harmless and keeps this in step with whatever the client sends.
  local sets = { Underworld = {}, Surface = {}, Nightmare = {}, Combined = {} }
  for pair in payload:gmatch("[^;]+") do
    local k, v = pair:match("^(.-)=(.*)$")
    local pool_key = SCORESYNC_ROUTE_KEY[k] or (k == "combined" and Routes.COMBINED_SCORE_KEY)
    if pool_key and v then
      for num in v:gmatch("%d+") do sets[pool_key][tonumber(num)] = true end
    end
  end
  ItemManager.checked_score = sets
  -- Advance next_check now for whichever pool(s) can free-skip newly-checked numbers.
  local s = APState.get()
  if s then
    if ItemManager.combine_active() then
      pcall(function()
        LocationManager.score_skip_pass(Routes.COMBINED_SCORE_KEY, s.combined_score)
      end)
    else
      for _, route in ipairs({ "Underworld", "Surface", "Nightmare" }) do
        if s.score[route] and ItemManager.route_active(route) then
          pcall(function() LocationManager.score_skip_pass(route, s.score[route]) end)
        end
      end
    end
  end
  rom.log.info("[AP] checked score: " .. payload)
end)
Bridge.on("GOAL", function() rom.log.info("[AP] Goal reached — congratulations!") end)
Bridge.on("DEATH", function(payload)
  -- Incoming DeathLink. Don't apply it here -- the message can arrive at any moment
  -- (at the Crossroads with no live Hero, while the game is paused with all threads
  -- frozen, mid-load), and applying it then is either a no-op or a lost death. Instead
  -- just enqueue it; ItemManager.flush_pending_deathlink() (called every frame from the
  -- render driver) applies it the moment the player is actually in a killable, unpaused
  -- state. Counter, not a bool, so several DeathLinks in quick succession all land.
  -- payload is the sender's slot name (Client.py's DEATH:<source>); queued in its own FIFO
  -- alongside the counter so a burst of DeathLinks still pairs each kill with the right sender.
  local source = (payload ~= nil and payload ~= "") and payload or "Archipelago"
  ItemManager.pending_deathlinks = (ItemManager.pending_deathlinks or 0) + 1
  ItemManager.pending_deathlink_sources = ItemManager.pending_deathlink_sources or {}
  table.insert(ItemManager.pending_deathlink_sources, source)
  -- Receiving a DeathLink from another player resets our own amnesty counter: the death
  -- we're about to take (once flushed) doesn't count toward the outgoing threshold, and any
  -- partial progress toward it is wiped, so the amnesty window restarts from this death.
  pcall(function()
    local s = APState.get()
    if s and (s.death_count or 0) > 0 then
      s.death_count = 0
      rom.log.info("[AP] amnesty counter reset to 0 (incoming DeathLink)")
    end
  end)
  rom.log.info("[AP] DeathLink received from " .. source .. " -> queued (pending=" .. ItemManager.pending_deathlinks .. ")")
end)

-- ---- Game -> mod hooks ------------------------------------------------------
-- Wrapped once; guarded so hot-reloads don't stack duplicate wraps.
-- The wrapped function names below are CONFIRMED against the Hades II API
-- (SGG-Modding/Hades2GameDef). Data-value strings (resource keys, weapon ids)
-- still need confirming once the game is installed — see ItemManager.lua.

if not AP_hooks_installed then
  AP_hooks_installed = true

  -- game.UnlockRoomExits(run, room, delay) fires the instant a room's exits unlock (all its
  -- encounters completed -> reward spawns). Combat scoring no longer happens here -- it now
  -- happens per-ENCOUNTER (score_encounter, via the StartEncounter wrap below) so a room that
  -- chains several encounters (MultipleEncountersData) earns a check for each fight instead of
  -- one for the whole cluster on exit-unlock. This hook now only handles filler reasserts.
  pcall(function()
    modutil.mod.Path.Wrap("UnlockRoomExits", function(base, run, room, delay)
      -- Never let our logic break the game's room-clear flow.
      -- Also reassert the AP fillers here, not just on room entry: the AP bridge connects and
      -- delivers settings/items ASYNCHRONOUSLY (see the StartNewRun wrap below), so on a fresh
      -- launch it's possible to enter a room BEFORE APState has anything to read yet --
      -- reassert_stat_bonuses/apply_help_odds/apply_armor/grant_pending_daedalus silently no-op in
      -- that case (no settings = nothing to grant). A room takes real time to clear, so by the time
      -- this fires the connection has almost always finished -- this is what was making the bonus
      -- seem to only "appear" when a room is cleared and its reward spawns, rather than at entry.
      -- UnlockRoomExits fires the instant the room's last enemy dies -- which can land while the
      -- player has the Trait Tray (boon inventory) open reviewing their build mid-room. The trait
      -- grants below (AddTraitToHero) mutate CurrentRun.Hero.Traits out from under that screen's
      -- cached component list and softlock it, so hold them (like the item-receipt gate) while
      -- Notifications.blocked() says a boon/tray/conversation screen owns input. Self-healing:
      -- they're idempotent ledger top-ups that simply re-fire at the next room hook if skipped here.
      pcall(function() ItemManager.apply_help_odds() end)
      if not (Notifications and Notifications.blocked and Notifications.blocked()) then
        pcall(function() ItemManager.reassert_stat_bonuses() end)
        pcall(function() ItemManager.apply_armor() end)
        pcall(function() ItemManager.grant_pending_daedalus() end)
      end
      return base(run, room, delay)
    end)
  end)

  -- reverse_vow: re-assert the vows at the start of EVERY run. "Undo Night" and
  -- reloads can clear GameState.ShrineUpgrades, so set + extract them fresh here.
  pcall(function()
    modutil.mod.Path.Wrap("StartNewRun", function(base, prevRun, args)
      -- If this session hasn't gotten a LIVE settings message yet (only the boot-cache carryover,
      -- which can be a launch-old seed entirely -- see have_live_settings), pull them synchronously
      -- now -- BEFORE the hero is built -- so the starting weapon/aspect are right on a single
      -- launch, no connect-restart dance. Bounded (~1.5s) and guarded; if the client isn't up it
      -- falls through and we proceed as before.
      if not ItemManager.have_live_settings() then
        pcall(function() Bridge.fetch_blocking(1.5) end)
      end
      pcall(function() ItemManager.apply_all_vows() end)
      ItemManager.won_run_pending = false  -- a new run starting clears any stale win-flag
      -- Fresh-save intro (prevRun==nil): the engine's new-game map is hardcoded to
      -- F_Opening01 (in Hades2.exe itself), but StartNewRun builds the run around
      -- args.RoomName -- so for surface-start seeds, rewrite the args HERE (pre-base) to
      -- vanilla's own Surface opening (N_Opening01) and let the StartRoom wrap below swap
      -- the actual map (ItemManager.complete_intro_redirect). See the intro-redirect block
      -- in ItemManager.lua for the full mechanism; the old bounce-kill stays as fallback.
      if prevRun == nil and args then
        rom.log.info("[AP] FIRST RUN: RoomName=" .. tostring(args.RoomName)
          .. " StartingBiome=" .. tostring(args.StartingBiome))
        -- Arm the DeathLink intro guard (ItemManager.in_scripted_opening_room) for exactly this
        -- one room load -- see its comment in ItemManager.lua for why this can't be room-name
        -- matching. Cleared by the StartRoom wrap below the moment the room actually changes.
        ItemManager.in_boot_intro_run = true
        if args.RoomName == "N_Opening01" then
          -- Already the Surface opening (nothing to redirect). Match biome tracking.
          args.StartingBiome = "N"
          rom.log.info("[AP] first run starting on Surface (StartingBiome=N, room=N_Opening01)")
        elseif ItemManager.first_run_should_be_surface() then
          local redirected = false
          pcall(function() redirected = ItemManager.redirect_intro_args(args) end)
          if redirected then
            rom.log.info("[AP] surface-start: intro run redirected to N_Opening01"
              .. " (map swaps at StartRoom)")
          else
            -- Fallback: one-shot kill at the first room so the game's own first-death ->
            -- Crossroads flow takes over and the player walks through the Surface door.
            ItemManager.pending_surface_intro_kill = true
            rom.log.info("[AP] surface-start: redirect unavailable; will kill to reach Crossroads")
          end
        elseif ItemManager.first_run_should_be_nightmare() then
          -- Redirect the fresh-save run into ZJ's Nightmare opening (RoomOpening/Tartarus) and let
          -- ZJ's own fresh-file map reload perform the transition -- same pattern as the Surface
          -- redirect above. See ItemManager.redirect_nightmare_intro_args.
          local redirected = false
          pcall(function() redirected = ItemManager.redirect_nightmare_intro_args(args) end)
          if redirected then
            rom.log.info("[AP] nightmare-start: intro run redirected to RoomOpening/Tartarus"
              .. " (ZJ reloads the map at StartRoomPresentation)")
          else
            -- Fallback: bounce off the forced Underworld intro with a one-shot kill so the game's
            -- own first-death -> Crossroads flow lands the player at the Chaos Gate.
            ItemManager.pending_nightmare_intro_kill = true
            rom.log.info("[AP] nightmare-start: redirect unavailable; will kill to reach Crossroads (Chaos Gate)")
          end
        end
        -- After any rewrite, so the DeathLink guard tracks the room the run ACTUALLY starts in.
        ItemManager.boot_intro_room_name = args.RoomName
      end
      local ret = base(prevRun, args)
      -- Make sure the run starts on an AP-unlocked weapon (Test Run 6 #2): the new hero copies
      -- the previous run's weapon set, so the chosen starting weapon / a now-locked weapon needs
      -- correcting here. No-op if the equipped weapon is already a valid unlocked one.
      pcall(function() ItemManager.enforce_equipped_weapon() end)
      -- New Filler Checks: apply run-start buffs once the run/hero exist.
      pcall(function() ItemManager.apply_progressive_start() end)
      pcall(function() ItemManager.apply_all_npc_gifts() end)
      pcall(function() ItemManager.apply_help_odds() end)
      -- Starting Armor at run start (hero exists) so it's present in the opening room, not a room
      -- late (Test Run 10 #3). Self-guarded (once per run); the StartRoom call below stays as a
      -- fallback for the surface-intro hero rebuild.
      pcall(function() ItemManager.apply_armor() end)
      return ret
    end)
  end)

  -- Also set the vows at the top of every StartRoom, since the biome timer and
  -- other per-room vow effects read them there (and that runs before/independent
  -- of StartNewRun's set). Quiet to avoid per-room log spam.
  pcall(function()
    modutil.mod.Path.Wrap("StartRoom", function(base, currentRun, currentRoom)
      -- Fresh-save intro redirect, step 2 (see ItemManager.redirect_intro_args): the run was
      -- built for the correct route's opening room, but the map on screen is still the
      -- engine's hardcoded F_Opening01. Swap the real map the way the game's own hub->run
      -- flow does (LoadMap on the run room's name); the new map's OnAnyLoad calls StartRoom
      -- again properly, so this mismatched call must NOT run base.
      -- Handles BOTH the Surface (RoomName N_Opening01) and Nightmare (RoomName RoomOpening) redirects
      -- -- both set intro_map_redirect_pending. complete_intro_redirect then branches on which one:
      -- Surface does a cheap LoadMap; Nightmare replicates ZJ's LeaveRoom fresh-file sequence so its
      -- ported audio + reward previews actually load (needs currentRun for the LeaveRoom call).
      if ItemManager.intro_map_redirect_pending then
        local consumed = false
        pcall(function() consumed = ItemManager.complete_intro_redirect(currentRoom, currentRun) end)
        if consumed then return end
      end
      -- Clear the boot-intro DeathLink guard the moment the room actually changes away from the
      -- one room StartNewRun(prevRun=nil) armed it for -- see ItemManager.in_boot_intro_run.
      if ItemManager.in_boot_intro_run and currentRoom
          and currentRoom.Name ~= ItemManager.boot_intro_room_name then
        ItemManager.in_boot_intro_run = false
      end
      pcall(function() ItemManager.apply_all_vows(true) end)
      local ret = base(currentRun, currentRoom)
      -- Final Challenge: the build arrives intact now that SetupHeroForEnding is skipped for
      -- the contract-door transition (see that wrap below) -- just log the trait count on
      -- arrival so a playtest can verify from the log alone.
      pcall(function()
        if currentRoom and currentRoom.Name == "C_Boss01" then
          ItemManager.log_zagreus_arrival()
          LocationManager.on_zagreus_met()
        end
      end)
      -- Re-assert the MaxHealth/MaxMana stat-bonus trait, rarity boost, and major-finds ratio on
      -- EVERY room, not just at StartNewRun: quitting to desktop and rejoining a run-in-progress
      -- never fires StartNewRun (the game only calls it for a genuinely new run), so a fresh Lua
      -- process's game.TraitData never gets ArchipelagoStatBonus/ArchipelagoRarityBoost registered
      -- again, and the game's own DoPatches strips those saved hero traits as unrecognized before
      -- this room ever renders. Calling it here heals that the moment the first room after a
      -- rejoin loads (same pattern as the armor/vow reasserts below).
      -- Guard on Notifications.blocked() same as the UnlockRoomExits hook above: the Trait Tray
      -- (boon inventory) can plausibly still be closing/reopening right at a room transition, and
      -- AddTraitToHero here would hit the same softlock. Idempotent/self-healing, so skipping just
      -- defers to the next room hook.
      local trait_tray_blocked = Notifications and Notifications.blocked and Notifications.blocked()
      if not trait_tray_blocked then
        pcall(function() ItemManager.reassert_stat_bonuses() end)
      end
      -- Increased Help Odds: RequirementsData is base-game Lua data, not save data, so a fresh
      -- process reload resets it to default -- reassert every room for the same rejoin reason.
      pcall(function() ItemManager.apply_help_odds() end)
      -- Nightmare Furies: RoomData is base Lua data too (reset on a fresh process), so re-strip the
      -- Alecto/Tisiphone rollout gates every room -- otherwise a mid-run rejoin would restore the
      -- "kill Megaera 4 times first" gate. Self-guards to a no-op when Nightmare isn't installed.
      pcall(function() ItemManager.apply_nightmare_fury_unlock() end)
      -- Hades exit door redirect: same "base Lua data resets on a fresh process" reasoning as the
      -- Nightmare Furies reassert just above. Self-guards to a no-op once installed.
      pcall(function() ItemManager.install_hades_exit_redirect() end)
      -- Nightmare helpers/Thanatos: same "base Lua data resets on a fresh process" reasoning --
      -- re-strip the Sisyphus/Eurydice/Patroclus story-room gates and Thanatos's rollout gates
      -- every room. Self-guards to a no-op when Nightmare isn't installed.
      pcall(function() ItemManager.apply_nightmare_helpers_unlock() end)
      -- Extended NPC encounters (combat-assist randomizer): re-strip the lifetime intro gates
      -- from zerp-Extended's added encounters every room, same reasoning as the strips above.
      -- Self-guards to a no-op when the dependency isn't initialized.
      pcall(function() ItemManager.apply_extended_npc_unlock() end)
      -- Boss ingredient drops -> Nectar: same "base Lua data resets on a fresh-process rejoin"
      -- reasoning as the strips above. See ItemManager.apply_boss_drops_as_nectar.
      pcall(function() ItemManager.apply_boss_drops_as_nectar() end)
      -- Nightmare boss resource drops -> Nectar: same reasoning, for Zagreus' Journey's own zone
      -- bosses. Self-guards to a no-op when Nightmare isn't installed. See
      -- ItemManager.apply_nightmare_boss_drops_as_nectar.
      pcall(function() ItemManager.apply_nightmare_boss_drops_as_nectar() end)
      -- Nightmare Chaos Gate: seal the run-start door whenever the route isn't AP-unlocked (and
      -- reopen it once it is). Applied per-room because the gate obstacle is re-spawned on each
      -- pre-run hub entry; only actually does anything in the hub where the gate exists. Self-
      -- guards to a no-op when Nightmare isn't installed. See ItemManager.apply_nightmare_gate_lock.
      pcall(function() ItemManager.apply_nightmare_gate_lock() end)
      -- Route access (Surface door / Nightmare gate): re-open from the persisted route_progress
      -- counter every room, so a Progressive Surface/Nightmare received across a reboot gap (whose
      -- one-time world-upgrade grant never re-fires) self-heals instead of staying locked forever.
      -- Pass currentRoom through so a live grant while standing in Hub_PreRun also refreshes the
      -- room's already-spawned door obstacle (see ItemManager.refresh_surface_door). Idempotent;
      -- no-op until the route has been progressed. See reassert_route_access.
      pcall(function() ItemManager.reassert_route_access(currentRoom) end)
      -- Starting Aspect (aspectsanity randomized/per_aspect modes): must run here, not from the
      -- SETTINGS handler -- see ItemManager.apply_initial_weapon's comment for why applying it
      -- before the run/hero exist crashes the game (MapState nil during vanilla's first-room
      -- hero setup). Idempotent, so safe to reassert every room.
      pcall(function() ItemManager.reassert_starting_aspect() end)
      -- aspectsanity=randomized: weapons don't get their Aspect of Melinoe for free (it's one of
      -- the 24 shuffled items). ScreenData.WeaponUpgradeScreen.FreeUnlocks is base Lua data, so a
      -- fresh process restores it -- re-strip every room, same as apply_help_odds above. Runs
      -- AFTER reassert_starting_aspect so a seed whose starting pick IS the Aspect of Melinoe has
      -- already been recorded as earned and is never stripped.
      pcall(function() ItemManager.apply_aspect_base_lock() end)
      -- Surface-start seeds: the engine forces an Underworld intro, so bounce off it by instantly
      -- killing Melinoe here (no DeathLink) -> the game's first-death flow lands her in the Crossroads,
      -- where she takes the Surface door. One-shot + self-guarded, so it only fires on that intro room.
      -- If we kill, RETURN NOW: this room is doomed, so skip scoring it (else the intro room counts as
      -- cleared and sends a check before she dies) and skip the per-room grants.
      local killed = false
      pcall(function() killed = ItemManager.kill_surface_intro() end)
      if killed then return ret end
      -- Nightmare-start seeds: same bounce, but toward the Crossroads Chaos Gate (no Surface door and
      -- no opening map to redirect into -- see ItemManager.kill_nightmare_intro). Same one-shot,
      -- self-guarded, skip-scoring-the-doomed-room contract as the surface intro kill above.
      pcall(function() killed = ItemManager.kill_nightmare_intro() end)
      if killed then return ret end
      -- At the Crossroads / pre-run hub, force the carried weapon to the AP weapon so the player can't
      -- leave the hub still holding the Staff when it isn't the seed's starting weapon (the stale boot
      -- cache can unlock the Staff during the intro before the live weapon arrives). enforce honors a
      -- valid rack pick and no-ops when already correct, so it's safe to run on every hub entry.
      pcall(function()
        local name = currentRoom and currentRoom.Name and tostring(currentRoom.Name)
        if name and name:match("^Hub") then ItemManager.enforce_equipped_weapon() end
      end)
      -- Starting Armor: a ONE-TIME grant at the start of the run (Test Run 5 #2). apply_armor
      -- self-guards (per-run flag + only in a real biome room), so calling it each StartRoom is
      -- safe -- it only actually grants in this run's opening room.
      -- Daedalus hammers: place any not-yet-spawned hammers for this run now that we're in a
      -- real room with LootPoints (spawning at StartNewRun was too early -- Test Run 5 #11).
      -- Both call AddTraitToHero -- hold them with the same Trait Tray guard as above.
      if not trait_tray_blocked then
        pcall(function() ItemManager.apply_armor() end)
        pcall(function() ItemManager.grant_pending_daedalus() end)
        -- Surface curse: vanilla's own grant is conditional on already having met Apollo (see
        -- ItemManager.enforce_surface_curse) and silently never fires for a surface_start seed
        -- otherwise -- enforce it directly on every Surface room entry instead.
        pcall(function() ItemManager.enforce_surface_curse() end)
      end
      -- Boss "Met": fire when we actually enter the boss arena (this room), not on reaching the
      -- biome (Test Run 5 #7). on_room_started checks EncounterType == "Boss" internally.
      pcall(function() LocationManager.on_room_started(currentRoom) end)
      -- Score reward-only / shop rooms on ENTER (Test Run 6 #6): they have no enemies to clear,
      -- so there's no clear moment to hook. score_room only counts non-combat qualifying rooms
      -- here (combat rooms score per-encounter via score_encounter) and dedups per room.
      pcall(function() LocationManager.score_room(currentRoom) end)
      -- Zagreus Vanilla/Empowered: spawn his contract in this room if it's a real shop and he
      -- hasn't been fought yet this run. See ItemManager.apply_zagreus_contract_everywhere.
      pcall(function() ItemManager.apply_zagreus_contract_everywhere(currentRoom) end)
      -- Route locking: if this zone isn't unlocked yet, kill Melinoe (no DeathLink). Uses the same
      -- ItemManager.route_zone_unlocked gate as the room-score block (Test Run 8 #1), so a zone that
      -- kills you can never also send a room check for itself. NOT gated on lock_routes here anymore
      -- -- route_zone_unlocked already handles that internally, and now ALSO locks a route the seed
      -- excluded entirely regardless of lock_routes (a Nightmare-only seed's hardcoded Underworld
      -- boot intro must still die here even if lock_routes is off).
      -- EXEMPT a story room borrowed by the zerp-NPCRoomRandomizer dependency (its own
      -- `_PLUGIN.guid .. "CurrentBiome"` marker, see Routes.current()): its whole point is a
      -- deliberate, sanctioned, one-room visit into a foreign zone/route -- possibly one the
      -- player hasn't unlocked yet -- that mod already guarantees the player lands back in their
      -- real, unlocked progression the moment they leave. This lock check has no way to tell
      -- "borrowed for a second" apart from "genuinely bypassed into unauthorized content" without
      -- this marker.
      pcall(function()
        if currentRoom and currentRoom["zerp-NPCRoomRandomizerCurrentBiome"] then return end
        local route, zone = Routes.current()
        if route and zone and not ItemManager.route_zone_unlocked(route, zone) then
          local s = APState.get()
          local have = (s and s.route_progress[route]) or 0
          local offset = tonumber(ItemManager.settings[route:lower() .. "_offset"]) or 0
          local need = (zone - 1) + offset
          rom.log.info("[AP] LOCKED " .. route .. " z" .. zone
            .. " (have " .. have .. " < need " .. need .. ") - killing Melinoe")
          if game.CurrentRun and game.CurrentRun.Hero then
            if Notifications then
              Notifications.push("locked", "Route is Locked")
            end
            -- A route-lock death is not a "real" death: don't send a DeathLink for it.
            ItemManager.forcing_deathlink = true
            game.Kill(game.CurrentRun.Hero, { Name = "Archipelago Route Lock" })
            ItemManager.forcing_deathlink = false
          end
        end
      end)
      return ret
    end)
  end)

  -- Quitting to desktop and rejoining a run-in-progress does NOT always call StartRoom above:
  -- OnAnyLoad (RoomLogic.lua ~233) calls RestoreUnlockRoomExits INSTEAD of StartRoom whenever the
  -- resumed room's exits were already unlocked (e.g. you quit after clearing the room, in the Hub,
  -- or generally anywhere past the room's opening beat -- a very common save point). Our StartRoom
  -- wrap never ran on that path, so none of the rejoin-heal reasserts fired -- this is why the
  -- Max Health/Magick fix "didn't work": it only covered half of the two paths the game actually
  -- uses to resume a room. Mirror the same reasserts here.
  pcall(function()
    modutil.mod.Path.Wrap("RestoreUnlockRoomExits", function(base, currentRun, currentRoom)
      local ret = base(currentRun, currentRoom)
      pcall(function() ItemManager.apply_help_odds() end)
      -- Boss ingredient drops -> Nectar: rejoin path (see StartRoom wrap for the full reasoning).
      pcall(function() ItemManager.apply_boss_drops_as_nectar() end)
      -- Nightmare boss resource drops -> Nectar: rejoin path (see StartRoom wrap above).
      pcall(function() ItemManager.apply_nightmare_boss_drops_as_nectar() end)
      -- Nightmare Chaos Gate: re-seal on rejoin too -- quitting to desktop and resuming while
      -- standing in the pre-run hub takes this path, not StartRoom, so without it a rejoined hub
      -- would show the gate open. Self-guards / no-op away from the gate. See StartRoom hook above.
      pcall(function() ItemManager.apply_nightmare_gate_lock() end)
      -- Route access: re-open the Surface door / Nightmare gate from persisted route_progress on the
      -- rejoin path too (resuming while standing in the hub takes this path, not StartRoom). Mirrors
      -- the StartRoom reassert (currentRoom passed through for the live door-obstacle refresh too);
      -- idempotent / no-op until the route has been progressed.
      pcall(function() ItemManager.reassert_route_access(currentRoom) end)
      -- Same Trait Tray (boon inventory) guard as the StartRoom/UnlockRoomExits hooks -- these all
      -- call AddTraitToHero, which softlocks the tray if it's open when they land.
      if not (Notifications and Notifications.blocked and Notifications.blocked()) then
        pcall(function() ItemManager.reassert_stat_bonuses() end)
        pcall(function() ItemManager.apply_armor() end)
        -- Daedalus hammers: re-place any not-yet-spawned hammers for this run. Needed here too --
        -- without this hook, resuming into an already-unlocked room skipped grant_pending_daedalus
        -- entirely, which is why hammers appeared to "reset" on rejoin (never re-placed, not actually
        -- removed).
        pcall(function() ItemManager.grant_pending_daedalus() end)
        -- Surface curse: same reassert as the StartRoom hook above -- see
        -- ItemManager.enforce_surface_curse.
        pcall(function() ItemManager.enforce_surface_curse() end)
      end
      return ret
    end)
  end)

  -- Physical ward on the Crossroads run-start doors (Test Run 8 #2). Both run doors fire
  -- UseEscapeDoor(usee, args) with args.StartingBiome ("F"=Underworld, "N"=Surface). On a
  -- surface-start seed the Underworld is locked (underworld_offset=1), but the player could still
  -- walk through its door and begin a run -- the StartRoom kill only caught them once the biome had
  -- loaded. Here we repulse Melinoe AT the door (the game's own warded-door presentation) and return
  -- WITHOUT calling base, so no run starts -- a real ward, not a delayed death. The StartRoom kill
  -- stays as a backstop for locked DEEPER zones (G/H/I) reached mid-run, which aren't doors.
  pcall(function()
    modutil.mod.Path.Wrap("UseEscapeDoor", function(base, usee, args)
      if ItemManager.run_door_locked(args) then
        pcall(function() ItemManager.block_run_door(usee, args) end)
        return
      end
      return base(usee, args)
    end)
  end)

  -- Persistent VISUAL ward on those same AP-locked run doors (companion to the UseEscapeDoor block
  -- above, which only handled the interaction -- the door still LOOKED open). The game repaints each
  -- run door's locked/unlocked sprite through UpdateEscapeDoorForLimitGraspShrineUpgrade -- its own
  -- Vow of Void (LimitGraspShrineUpgrade) handler -- at hub setup AND after every Grasp change. We
  -- wrap it so, after the game repaints, we re-stamp the warded sprite on any door AP has locked.
  -- Piggybacking on the game's refresh cadence means our ward can never be left showing the open
  -- sprite. Visual only -- interaction still flows through the UseEscapeDoor wrap above. See
  -- ItemManager.ward_locked_run_doors.
  pcall(function()
    modutil.mod.Path.Wrap("UpdateEscapeDoorForLimitGraspShrineUpgrade", function(base, source, args)
      local ret = base(source, args)
      pcall(function()
        local ids = (args and args.EscapeDoorIds) or (source and { source.ObjectId })
        ItemManager.ward_locked_run_doors(ids)
      end)
      -- Nightmare Chaos Gate: Zagreus' Journey wraps this SAME function and reroutes it to its own
      -- gate updater (HubPresentation.lua), whose unlock branch rewrites the gate's UseText/
      -- OnUsedFunctionName back to the OPEN values -- clobbering our seal on every Grasp/hub
      -- refresh. We load after ZJ (its wrap runs inside our base call), so re-sealing here always
      -- gets the last word. No-op when the gate doesn't exist or the route is unlocked.
      pcall(function() ItemManager.apply_nightmare_gate_lock() end)
      return ret
    end)
  end)

  -- Nightmare Chaos Gate, spawn-time seal. The gate is spawned by a Hub_PreRun
  -- StartUnthreadedEvent (ZJ's SpawnHadesRunStartDoor) -- and hub maps are entered via map loads
  -- that never fire our StartRoom wrap, so every other call site ran either before the gate
  -- existed (boot) or not at all (hub entry) and the seal silently never applied (July 18: a full
  -- session log had zero Chaos Gate lines with the gate usable). ZJ stamps its unique
  -- ModsNikkelMHadesBiomesIsRunStartDoor marker on the gate's table BEFORE calling
  -- game.SetupObstacle on it (DeathLoopData.lua:84/101), so this wrap catches the gate the
  -- instant it spawns, regardless of which flow spawned the room. One field test per obstacle --
  -- effectively free for the overwhelming majority of SetupObstacle calls.
  pcall(function()
    modutil.mod.Path.Wrap("SetupObstacle", function(base, obstacle, ...)
      local ret = base(obstacle, ...)
      if type(obstacle) == "table" and obstacle.ModsNikkelMHadesBiomesIsRunStartDoor then
        pcall(function() ItemManager.update_nightmare_gate(obstacle) end)
      end
      -- Cauldron (GhostAdmin): force vanilla's own "not open yet" presentation permanently.
      -- Identity check lives inside the function itself; no-ops for every other obstacle.
      pcall(function() ItemManager.apply_cauldron_locked_visual(obstacle) end)
      return ret
    end)
  end)

  -- Nightmare Chaos Gate lock (opt-in third-party "Zagreus' Journey" route). Separate from the
  -- UseEscapeDoor wrap above -- the Chaos Gate isn't a vanilla run-start door, it's that mod's
  -- own obstacle. We seal it at the obstacle level (the same way the Vow of Void seals a run door
  -- over-Grasp), applied per-room in the StartRoom / RestoreUnlockRoomExits hooks once the gate
  -- obstacle actually exists. This boot call is just a best-effort first pass (no-op until we're
  -- in the pre-run hub); see ItemManager.apply_nightmare_gate_lock.
  pcall(function() ItemManager.apply_nightmare_gate_lock() end)
  -- Nightmare run-clear detection, second path (see ItemManager.handle_nightmare_run_cleared for
  -- why this exists alongside the OpenRunClearScreen wrap further down).
  pcall(function() ItemManager.install_nightmare_run_clear_hook() end)
  -- Hades exit door: redirect D_Boss01's exit straight to the Crossroads instead of ZJ's own
  -- post-Hades Surface epilogue (see ItemManager.install_hades_exit_redirect). Also retried
  -- per-frame (reload.lua's render driver) and per-room below, same reasoning as the run-clear
  -- hook and Nightmare Furies just above/below -- game.RoomData is base Lua data that resets on a
  -- fresh-process rejoin.
  pcall(function() ItemManager.install_hades_exit_redirect() end)
  -- Nightmare Furies: make Alecto + Tisiphone eligible as the Tartarus boss from run 1, instead of
  -- gating them behind 4 lifetime Megaera kills the way Zagreus' Journey ports Nightmare. Runs here
  -- (after ZJ's room data is loaded) AND per-room in the StartRoom wrap, since the boss-room
  -- eligibility is evaluated when the prior room's exits are chosen -- reasserting each room means
  -- a fresh-process rejoin (which reloads ZJ's static room data) can never restore the gate.
  pcall(function() ItemManager.apply_nightmare_fury_unlock() end)
  -- Extended NPC encounters: strip the lifetime intro-completed gates from the combat-assist
  -- randomizer's added encounters (zerp-Extended runs its init before us, so its
  -- NewNPCEncounters list + EncounterData entries exist by now). Also reasserted per-room in
  -- the StartRoom wrap. See ItemManager.apply_extended_npc_unlock.
  pcall(function() ItemManager.apply_extended_npc_unlock() end)
  -- Nightmare helpers/Thanatos: same reasoning, same dual boot+per-room reassertion. See
  -- ItemManager.apply_nightmare_helpers_unlock for the full field-by-field breakdown.
  pcall(function() ItemManager.apply_nightmare_helpers_unlock() end)
  -- Boss ingredient drops -> Nectar: same "base Lua data resets on a fresh-process rejoin"
  -- reasoning as the strips above. See ItemManager.apply_boss_drops_as_nectar.
  pcall(function() ItemManager.apply_boss_drops_as_nectar() end)
  -- Nightmare boss resource drops -> Nectar: same reasoning, for Zagreus' Journey's own zone
  -- bosses. Self-guards to a no-op when Nightmare isn't installed. See
  -- ItemManager.apply_nightmare_boss_drops_as_nectar.
  pcall(function() ItemManager.apply_nightmare_boss_drops_as_nectar() end)

  -- arcanasanity gating: cards are unlocked by AP items, so block buying a LOCKED
  -- card at the Altar (the unlock-purchase branch of MetaUpgradeCardAction).
  -- Equipping an already-unlocked card still works. FAIL-CLOSED on purpose: the mod is
  -- only ever meant to run with an AP session, so before settings arrive (nil ~= "0" is
  -- true) purchases stay blocked rather than letting an early buy slip through.
  pcall(function()
    modutil.mod.Path.Wrap("MetaUpgradeCardAction", function(base, screen, button)
      if ItemManager.settings.arcanasanity ~= "0" and button and button.CardState == "LOCKED" then
        pcall(function() game.InvalidMetaUpgradeCardAction(screen, button) end)
        return
      end
      return base(screen, button)
    end)
  end)

  -- Progressive_Arcana (=="2") also blocks normal upgrades (they come from items).
  pcall(function()
    modutil.mod.Path.Wrap("CanUpgradeMetaUpgrade", function(base, metaUpgradeName)
      if ItemManager.settings.arcanasanity == "2" then
        return false
      end
      return base(metaUpgradeName)
    end)
  end)

  -- aspectsanity: aspects are items-only (no checks). Block unlocking/upgrading the
  -- non-default Aspects at the weapon shop so they come only from AP items. Base unlocks
  -- are blocked in randomized + progressive; upgrades (<aspect>2..5) only in progressive.
  pcall(function()
    modutil.mod.Path.Wrap("HandleWeaponShopPurchase", function(base, screen, button)
      local item = button and button.Data and button.Data.Name
      -- Weapons come ONLY from AP items (weaponsanity is always on, no longer a toggle), so
      -- block buying them at the Crossroads weapon shop entirely. There is no check (no
      -- weapon-unlock locations), so players never need to grind Silver / mining tools.
      if item and ItemManager.WEAPON_KIT_TO_SHORT[item] then
        rom.log.info("[AP] blocked weapon purchase: " .. tostring(item) .. " (AP-gated, no check)")
        return
      end
      -- aspectsanity: block unlocking/upgrading non-default Aspects (items-only).
      -- Upgrades (<aspect>2..5, including the default Aspect's) are AP-gated in every mode but
      -- "unlocked" (0) -- progressive (2) and per_aspect (3) rank up an Aspect one item at a
      -- time, randomized (1) hands it straight to max, and either way every rank comes from an
      -- item. randomized especially: its starting Aspect begins at rank 1 and its item is what
      -- takes it to max, so a buyable upgrade would let the player skip that item entirely.
      local mode = ItemManager.setting_mode("aspectsanity")
      if item and mode ~= 0 then
        if ItemManager.ASPECT_UNLOCK_NAMES[item] or ItemManager.ASPECT_UPGRADE_NAMES[item] then
          rom.log.info("[AP] blocked aspect purchase: " .. tostring(item) .. " (AP-gated)")
          return
        end
      end
      return base(screen, button)
    end)
  end)

  -- Block the Nocturnal Arms weapon/aspect SHOP entirely (Test Run 8 #5). Two different screens:
  --   * OpenWeaponUpgradeScreen (UseWeaponKit on an owned weapon rack) = the aspect SELECTION /
  --     equip screen ("WeaponName_Aspects"); it only switches which aspect you run with, no resource
  --     spending (WeaponUpgradeLogic.SelectWeaponUpgrade). KEEP THIS OPEN -- it's how you change aspect.
  --   * OpenWeaponShopScreen (UseWeaponShop, WeaponShopLogic.lua:1) = the PURCHASE/upgrade shop where
  --     you'd buy weapon kits and aspect unlocks/upgrades. THIS is the one to block (aspects/weapons
  --     come only from AP items, so there's nothing to buy and no checks live behind it).
  -- Wrap UseWeaponShop to no-op while connected: it early-returns before AddInputBlock (added inside
  -- OpenWeaponShopScreen), so there's no input-block leak and the interaction simply does nothing.
  pcall(function()
    modutil.mod.Path.Wrap("UseWeaponShop", function(base, usee, args)
      if ItemManager.have_settings() then
        rom.log.info("[AP] blocked Nocturnal Arms shop (AP-gated, no purchases/checks)")
        return
      end
      return base(usee, args)
    end)
  end)
  -- Belt-and-suspenders: no-op the shop opener itself (before its AddInputBlock) so it can never
  -- appear by any other path.
  pcall(function()
    modutil.mod.Path.Wrap("OpenWeaponShopScreen", function(base, openedFrom, args)
      if ItemManager.have_settings() then return end
      return base(openedFrom, args)
    end)
  end)

  -- Hide the "!" attention / new-content markers (Test Run 8 #5). All status icons funnel through
  -- PlayStatusAnimation (RoomLogic.lua:4778); of the StatusIcon* family only these five are the
  -- standalone "there's something new here / go talk to me" markers -- the rest are in-conversation
  -- emotes (Smile, Fear, Speaking, ...) which we leave alone. Players currently just ignore the "!",
  -- so suppress them entirely while connected. This name set is the single tuning point; later it
  -- could be repurposed to instead mark where AP checks are.
  local AP_HIDE_STATUS_ICONS = {
    StatusIconWantsToTalk          = true,
    StatusIconWantsToTalkImportant = true,
    StatusIconWantsToTalkBoon      = true,
    StatusIconNewItemsInStock      = true,
    StatusIconWantsAffection       = true,
  }
  pcall(function()
    modutil.mod.Path.Wrap("PlayStatusAnimation", function(base, source, args)
      if ItemManager.have_settings() and args and AP_HIDE_STATUS_ICONS[args.Animation] then
        return
      end
      return base(source, args)
    end)
  end)

  -- petsanity progressive: bonds come from Progressive Familiar items, so block the bond
  -- shop's purchases. Randomized leaves bonds alone (only the unlock itself is gated).
  pcall(function()
    modutil.mod.Path.Wrap("HandleFamiliarShopPurchase", function(base, screen, button)
      if ItemManager.setting_mode("petsanity") == 2 then
        rom.log.info("[AP] blocked familiar bond purchase (progressive, AP-gated)")
        return
      end
      return base(screen, button)
    end)
  end)

  -- petsanity: block normal familiar recruitment (randomized + progressive) so a familiar
  -- is owned only via its AP item. The recruit presentation sets GameState.FamiliarsUnlocked,
  -- so undo it afterward -- unless AP already granted that familiar. No check (items-only).
  pcall(function()
    modutil.mod.Path.Wrap("FamiliarRecruitPresentation", function(base, usee, args)
      local mode = ItemManager.setting_mode("petsanity")
      local ret = base(usee, args)
      if mode ~= 0 and usee and usee.Name then
        local s = APState.get()
        local ap_granted = s and s.familiar_ap_granted[usee.Name]
        if not ap_granted then
          pcall(function()
            if game.GameState and game.GameState.FamiliarsUnlocked then
              game.GameState.FamiliarsUnlocked[usee.Name] = nil
            end
            if game.CurrentRun and game.CurrentRun.FamiliarsUnlocked then
              game.CurrentRun.FamiliarsUnlocked[usee.Name] = nil
            end
          end)
          rom.log.info("[AP] blocked familiar recruit: " .. tostring(usee.Name) .. " (AP-gated)")
        end
      end
      return ret
    end)
  end)

  -- keepsakesanity: earning a keepsake by gifting an NPC becomes a check (randomized +
  -- progressive). The award sets GiftPresentation/NewKeepsakeItem just before this fires,
  -- so clear them to keep the keepsake locked until the AP item arrives, and skip the popup.
  pcall(function()
    modutil.mod.Path.Wrap("PlayerReceivedGiftPresentation", function(base, npc, giftName)
      if ItemManager.setting_mode("keepsakesanity") ~= 0 then
        -- Diagnostic: log EVERY gift presentation so we can see whether Charon's keepsake gift
        -- routes through here at all (Test Run 5 #4: Charon's keepsake check didn't fire on the
        -- first Nectar gift). npc.Name + giftName reveal the real trait id / NPC if unmapped.
        rom.log.info("[AP] gift presentation: npc=" .. tostring(npc and npc.Name)
          .. " giftName=" .. tostring(giftName)
          .. " -> check=" .. tostring(ItemManager.KEEPSAKE_TRAIT_TO_CHECK[giftName]))
        local check = ItemManager.KEEPSAKE_TRAIT_TO_CHECK[giftName]
        if check and LocationManager.check_route_blocked(check) then
          -- This NPC's keepsake location isn't in the seed (its route is excluded), so
          -- there's no check to send or gate on -- let the gift behave vanilla instead.
          check = nil
        end
        if check then
          pcall(function() Bridge.send("CHECK:" .. check) end)
          local s = APState.get()
          if s then s.keepsake_check_sent[giftName] = true end  -- so we can block re-gifting
          -- Keep the keepsake LOCKED (clear its ownership) so it's unselectable until the
          -- AP item. We gate on ownership, NOT EquipKeepsake -- blocking the equip itself
          -- crashed KeepsakeScreenClose (it reads the trait right after equipping).
          ItemManager.block_keepsake_award(giftName)
          rom.log.info("[AP] keepsake award -> check '" .. check .. "' (kept locked until item)")
          return  -- skip the "new keepsake" popup
        end
      end
      return base(npc, giftName)
    end)
  end)

  -- keepsakesanity: once an NPC's keepsake check has been sent, block re-gifting them
  -- (no point spending more Nectar, and it makes it clear who you've already done).
  pcall(function()
    modutil.mod.Path.Wrap("CanReceiveGift", function(base, target)
      if ItemManager.setting_mode("keepsakesanity") ~= 0 and target then
        local name = target.GiftName or target.Name
        local gd = name and game.GiftData and game.GiftData[name]
        local trait = gd and gd[1] and gd[1].Gift
        if trait and ItemManager.MANAGED_KEEPSAKES[trait] then
          local s = APState.get()
          if s and s.keepsake_check_sent[trait] then
            return false
          end
        end
      end
      return base(target)
    end)
  end)

  -- keepsakesanity progressive: keepsake levels come from Progressive Keepsake items,
  -- so block normal leveling.
  pcall(function()
    modutil.mod.Path.Wrap("AdvanceKeepsake", function(base, fromTrait)
      if ItemManager.setting_mode("keepsakesanity") == 2 then
        return
      end
      return base(fromTrait)
    end)
  end)

  -- The Cauldron is disabled in this Archipelago (incantationsanity was dropped). Its menu is
  -- the "GhostAdmin" system: UseGhostAdmin opens it, HandleGhostAdminPurchase crafts an
  -- incantation (-> AddWorldUpgrade). Block BOTH so it can't be opened or crafted. Surface
  -- access / penalty cure still come from AP items (force_world_upgrade calls AddWorldUpgrade
  -- directly, not via this menu, so it's unaffected).
  -- Blocked UNCONDITIONALLY (not gated on have_settings): the mod is only ever meant to
  -- run with an AP session, and fail-closed means the Cauldron can't be used in the
  -- window before settings arrive.
  -- Belt-and-suspenders: the SetupObstacle wrap above forces the object's OnUsedFunctionName to
  -- vanilla's own "UseLockedSystemObjectPresentation" permanently (see
  -- ItemManager.apply_cauldron_locked_visual), so UseGhostAdmin should never actually fire from
  -- player interaction anymore -- these two wraps stay as a fail-closed backstop.
  pcall(function()
    modutil.mod.Path.Wrap("UseGhostAdmin", function(base, usee, args)
      rom.log.info("[AP] Cauldron (GhostAdmin) open blocked (disabled in this seed)")
      return
    end)
  end)
  pcall(function()
    modutil.mod.Path.Wrap("HandleGhostAdminPurchase", function(base, screen, button)
      rom.log.info("[AP] Cauldron craft blocked (disabled in this seed)")
      return
    end)
  end)

  -- Override the max-Grasp computation to grasp_count * grasp_intervals (you start at 0
  -- and Progressive Grasp items raise it), instead of the normal StartingMetaUpgradeLimit
  -- + purchased levels.
  pcall(function()
    modutil.mod.Path.Wrap("GetMaxMetaUpgradeCost", function(base, ...)
      local s = APState.get()
      local interval = tonumber(ItemManager.settings.grasp_intervals) or 0
      local value = (s and s.grasp_count or 0) * interval
      if game.GameState then game.GameState.MaxMetaUpgradeCostCache = value end
      return value
    end)
  end)

  -- reverse_rivals: the Vow of Rivals (BossDifficultyShrineUpgrade) normally strengthens
  -- the FIRST N bosses (active while rank >= CurrentRun.EnteredBiomes, per
  -- ShrineLogic.IsBossDifficultyShrineUpgradeActive). With reverse_rivals on, strengthen
  -- the LAST N instead (active while EnteredBiomes >= total - rank + 1). Both routes are 4
  -- biomes to the final boss. Best-effort: omits the dream-run nuance; verify in-game.
  pcall(function()
    modutil.mod.Path.Wrap("IsBossDifficultyShrineUpgradeActive", function(base, source, args)
      if not ItemManager.setting_on("reverse_rivals") then
        return base(source, args)
      end
      args = args or {}
      local rank
      if args.UseShrineUpgradesCache and game.CurrentRun and game.CurrentRun.ShrineUpgradesCache then
        rank = game.CurrentRun.ShrineUpgradesCache.BossDifficultyShrineUpgrade or 0
      else
        rank = (game.GameState and game.GameState.ShrineUpgrades
          and game.GameState.ShrineUpgrades.BossDifficultyShrineUpgrade) or 0
      end
      if rank <= 0 then return false end
      local entered = (game.CurrentRun and game.CurrentRun.EnteredBiomes) or 0
      local total = 4
      if entered < (total - rank + 1) then return false end
      return true
    end)
  end)

  -- "Start with more unlocked" (wishlist): one central requirement-evaluator wrap drives the
  -- early Oath of the Unseen, the early field-NPC "helpers", early Chaos Gates, the early
  -- Fated List, and (wishlist "All gods are accessible from the beginning") every god that's
  -- normally introduced gradually. IsGameStateEligible (RequirementsLogic.lua:9) is the game's
  -- single gate for "is this content available right now" -- the Crossroads Oath obelisk
  -- (DeathLoopData Shrine object, gated NamedRequirements ShrineUnlocked, DestroyIfNotSetup),
  -- the Chaos Gate rooms (RoomData/RoomDataI/N/P, gated NamedRequirements
  -- {"ChaosUnlocked","NoRecentChaosEncounter"}), the Crossroads QuestLog/Fated List pedestal
  -- (HubRoomData.Hub_Main.ObstacleData[560662]), each helper's intro encounter, and each
  -- gated god's own boon/shop eligibility (LootData.<God>Upgrade.GameStateRequirements, or for
  -- Hermes/Selene their NamedRequirementsData entry) all flow through it.
  --   * Oath: when the requirements ARE the ShrineUnlocked named-requirement table, return
  --     true, so the obelisk appears from the start (vows are made view-only below).
  --   * Chaos Gates: when the requirements ARE the ChaosUnlocked named-requirement table
  --     (normally needs GameState.UseRecord.HermesUpgrade -- a Hermes Boon taken in some past
  --     run -- among other clauses), return true, so Chaos Gates can spawn from run 1.
  --     NoRecentChaosEncounter (per-run spacing cooldown) is untouched, so gates still don't
  --     spam back-to-back rooms.
  --   * Fated List: forces true on 3 tables -- the pedestal's own SetupGameStateRequirements
  --     (normally needs TextLinesRecord.MorosGrantsQuestLog, a story beat), its OverwriteSelf
  --     SetupEvents[1].GameStateRequirements (normally needs WorldUpgradesAdded.WorldUpgradeQuestLog,
  --     which actually wires up the UseQuestLog interaction), and the QuestLogUnlocked named
  --     requirement (gates the quest-tracking logic / codex menu icon, RequirementsData.lua:93).
  --     All three are one-time story flags with no per-run situational component, so forcing
  --     them true is as safe as the Oath/Chaos overrides.
  --   * Helpers: for the four gated intro encounters, evaluate with their story-unlock gates
  --     temporarily satisfied (ItemManager.eval_helper_intro) so they can show up the first
  --     time you're in their area, while keeping the natural depth/cooldown spawn cadence.
  --   * Gods: Zeus/Hera/Ares/Hestia/Aphrodite/Hephaestus each have a single story-flag gate
  --     with no per-run component (see FORCE_GOD_UPGRADES, ItemManager.lua), so they're forced
  --     true the same way as Oath/Chaos/QuestLog. Hermes and Selene use the identical
  --     mechanism but their NamedRequirementsData entries also carry per-run pacing (don't
  --     reoffer if already taken/in-store this run), so they go through the same "patch" path
  --     as the helper intros instead, preserving that pacing.
  --   * Story rooms: Echo(H) -- the "empty room, one ally, gives a gift" bridge encounter --
  --     has its extra story-progress gate forced true (collect_story_room_force_keys,
  --     ItemManager.lua). Arachne(F)/Narcissus(G) instead have ONLY their specific lifetime-
  --     progress gates stripped (apply_story_room_lifetime_unlock) -- the native BiomeDepthCache
  --     window + ForceIfUnseenForRuns pity timer are left completely untouched, so the game's own
  --     built-in odds/placement decide when and where, not an override here. Hades(I)/Medea(N)/
  --     Circe(O)/Dionysus(P) need no override at all -- pure native pool competition.
  --   * Zagreus (Vanilla/Empowered): InfernalContractUnlocked forced true (goal-gated, harmless --
  --     it also legitimately gates the post-fight reward pickup, SpawnZagContractRewards, which
  --     should keep working once earned); the outer StoreData.ZagreusContractRequirement is
  --     forced FALSE, disabling the native per-room contract mechanism entirely --
  --     ItemManager.apply_zagreus_contract_everywhere (StartRoom hook below) supersedes it,
  --     spawning the contract directly in every real shop room instead of the ~4 rooms vanilla
  --     happened to author it in. See [[project_zagreus_vanilla_empowered_shop_rarity]].
  -- Everything is identity-matched against the live game tables (resolved lazily) and only
  -- acts in a connected AP session; nothing is written to the save.
  pcall(function()
    modutil.mod.Path.Wrap("IsGameStateEligible", function(base, source, requirements, args)
      local ov = ItemManager.eligibility_override(requirements)
      if ov == "true" then return true end
      if ov == "false" then return false end
      if ov == "patch" then return ItemManager.eval_helper_intro(base, source, requirements, args) end
      return base(source, requirements, args)
    end)
  end)

  -- GodSanity: gate each of the 9 boon gods (Zeus/Poseidon/Ares/Aphrodite/Apollo/Hestia/Hera/
  -- Demeter/Hephaestus) behind its own "<God> Unlock" item, by altering the native loot tables
  -- directly rather than letting vanilla pick freely and patching the outcome afterward. Two
  -- layers, both wrapping the exact native functions vanilla itself uses to build these tables
  -- fresh each time they're needed (so nothing needs separate reassertion):
  --  (1) GetRewardStoreData (below) -- decides whether a door's reward TYPE can be "Boon" at
  --      all, by thinning/padding the store's own "Boon" array entries.
  --  (2) GetEligibleLootNames (below that) -- once a door IS a "Boon", decides WHICH god's loot
  --      is a candidate, by filtering the candidate list itself before the native random pick.
  -- Layer (1) guarantees a "Boon" door can never even be rolled while zero gods are unlocked
  -- (see godsanity_boon_target), which in turn guarantees layer (2) is never asked to fill a
  -- Boon door with truly nothing eligible -- so neither layer needs an Onion/reroll fallback of
  -- its own; the tables are simply correct by construction. onions still gets its "declined
  -- boon" flavor from the SAME native RoomRewardConsolationPrize the game already uses whenever
  -- literally nothing is eligible (SpawnPerfectClearRoomReward's own pattern), just reached by
  -- the reward TYPE never being "Boon" in the first place rather than a post-hoc swap.
  --
  -- GetRewardStoreData is the single function both run-start init (InitializeRewardStores) AND
  -- every mid-run refill (once a store's array empties, ChooseRoomReward re-fetches a fresh
  -- copy) call to get that array. Scoped to RunProgress (the normal room-reward store) and
  -- HubRewards (the hub's own separate Boon set) -- the only two stores with native Boon
  -- entries. See ItemManager.scale_boon_entries / godsanity_boon_target for the per-mode target
  -- count (onions/no_waste_same_odds: full native count once >=1 god is unlocked, 0 before
  -- that; no_waste_less_odds: an eased-in curve).
  pcall(function()
    modutil.mod.Path.Wrap("GetRewardStoreData", function(base, storeName)
      local storeData = base(storeName)
      if not ItemManager.have_settings() then return storeData end
      local mode = ItemManager.setting_mode("godsanity")
      if mode == 0 then return storeData end
      if storeName ~= "RunProgress" and storeName ~= "HubRewards" then return storeData end
      local ok, result = pcall(ItemManager.scale_boon_entries, storeData, mode, storeName)
      if ok and result then return result end
      return storeData
    end)
  end)

  -- GodSanity, layer (1b): MiniBoss encounters (every zone's RoomData) hardcode
  -- EligibleRewards = { "Boon" } on their reward room -- a SEPARATE native filter
  -- (RewardLogic.IsRoomRewardEligible) that rejects every non-Boon candidate regardless of how
  -- few Boon copies layer (1) left in the store. Since >=1 Boon copy always survives once any god
  -- is unlocked, these rooms were 100% Boon forever under no_waste_less_odds, bypassing its curve
  -- entirely (confirmed live 2026-07-21). Roll the SAME fraction once per room; on a miss,
  -- temporarily clear EligibleRewards for this call so it falls through to the room's normal
  -- (already-thinned) reward pool instead. No-op for modes 0/1/3 (godsanity_boon_roll_allowed's
  -- fraction is always 1 there once >=1 god is unlocked, matching their own native-odds design).
  pcall(function()
    modutil.mod.Path.Wrap("ChooseRoomReward", function(base, run, room, rewardStoreName, previouslyChosenRewards, args)
      if ItemManager.have_settings() and room and room.EligibleRewards
          and #room.EligibleRewards == 1 and room.EligibleRewards[1] == "Boon" then
        local mode = ItemManager.setting_mode("godsanity")
        if mode ~= 0 then
          local ok, allowed = pcall(ItemManager.godsanity_boon_roll_allowed, mode)
          if ok and not allowed then
            local saved = room.EligibleRewards
            room.EligibleRewards = nil
            local result = base(run, room, rewardStoreName, previouslyChosenRewards, args)
            room.EligibleRewards = saved
            return result
          end
        end
      end
      return base(run, room, rewardStoreName, previouslyChosenRewards, args)
    end)
  end)

  -- GodSanity, layer (2): once a door IS a "Boon" (guaranteed above to only happen with >=1 god
  -- unlocked), filter which specific god can be picked. GetEligibleLootNames is the ONE function
  -- ChooseLoot/SetupRoomReward consult for "which god loot names are currently eligible" -- its
  -- own base() already applies native per-god story-progress gates AND the caller's
  -- excludeLootNames (this room's own already-offered Boon doors, so the same god doesn't appear
  -- twice at once) -- we just additionally restrict that already-computed list to unlocked gods.
  --   onions (mode 1): respects the caller's exclude list like vanilla always has -- if that
  --     leaves nothing (this room's one unlocked god was already offered on an earlier door this
  --     room), retries ignoring the exclude list rather than ever surfacing a locked god; only
  --     matters when a room has 2+ Boon doors and exactly 1 god unlocked, an edge case onions'
  --     own docstring already expects some variance in.
  --   no_waste_less_odds / no_waste_same_odds (modes 2/3): ignore the exclude list from the
  --     start, so the same unlocked god(s) can repeat across a room's doors rather than ever
  --     wasting a slot -- see GodSanity's docstring ("every boon that spawns will always be from
  --     a god you've unlocked").
  pcall(function()
    modutil.mod.Path.Wrap("GetEligibleLootNames", function(base, excludeLootNames)
      if not ItemManager.have_settings() then return base(excludeLootNames) end
      local mode = ItemManager.setting_mode("godsanity")
      if mode == 0 then return base(excludeLootNames) end
      local ignoreExclude = (mode == 2 or mode == 3)
      local names = base(ignoreExclude and nil or excludeLootNames)
      local filtered = {}
      for _, n in ipairs(names) do
        if ItemManager.god_eligible(n) then table.insert(filtered, n) end
      end
      if #filtered > 0 then return filtered end
      -- Defensive only: by construction (layer 1 above) this door should never have become
      -- "Boon" with zero unlocked gods, so this can only fire from a same-room dedup exhausting
      -- the one unlocked god (onions, since it didn't already ignore excludeLootNames above).
      -- Retry ignoring dedup entirely rather than ever falling back to a locked god.
      local retry = base(nil)
      for _, n in ipairs(retry) do
        if ItemManager.god_eligible(n) then table.insert(filtered, n) end
      end
      return filtered
    end)
  end)

  -- Combat-assist helper redirect (Artemis/Heracles/Icarus/Nemesis/Athena/Thanatos) is now
  -- handled by the zerp-Extended_NPC_Encounters dependency (manifest.json) instead of our own
  -- Handle<God>Spawn wraps -- see ItemManager.lua's Category-2 header comment and
  -- [[project_helper_npcs_any_location]] for why.

  -- Static helper rooms (Arachne/Narcissus/Echo/Hades/Medea/Circe/Dionysus + Nightmare's
  -- Sisyphus/Eurydice/Patroclus) cross-NPC randomization is now handled by the
  -- zerp-NPCRoomRandomizer dependency (manifest.json) instead of our own CreateRoom/
  -- ChooseNextRoomData wraps -- see ItemManager.lua's Category-1 header comment and
  -- [[project_helper_npcs_any_location]] for why.

  -- MiniBoss forcing: when enemy_locations is on, a miniboss room's LegalEncounters pool
  -- (the set of possible minibosses that specific room slot can roll -- e.g. G_MiniBoss02's
  -- pool historically included MiniBossCrawler alongside sibling encounters, gated by lifetime
  -- EncountersCompletedCache the way vanilla rotates its miniboss variety) can contain several
  -- candidates. If any of them map to a "<Name> Defeated" check the player hasn't earned yet,
  -- narrow the pool to just the not-yet-defeated ones before the real pick runs, so the roll is
  -- guaranteed to land on one you still need instead of possibly re-rolling one already checked.
  -- Only touches pools where EVERY candidate resolves to a MiniBoss-type encounter (a uniform
  -- miniboss slot) -- mixed pools (normal fights that occasionally roll a miniboss) are left
  -- untouched, and a candidate whose spawned unit can't be resolved to a check stays eligible
  -- (treated as "not defeated" -- see LocationManager.enemy_check_defeated) rather than being
  -- dropped, so an unmapped miniboss can never shrink the pool to zero.
  local function first_enemy_check_in_encounter(encounterDef)
    local set = encounterDef and encounterDef.EnemySet
    if not set then return nil end
    for _, entry in ipairs(set) do
      local unitId = (type(entry) == "string") and entry or (type(entry) == "table" and (entry.Name or entry.UnitName))
      local check = unitId and LocationManager.enemy_check_for_unit(unitId)
      if check then return check end
    end
    return nil
  end
  local function force_undefeated_miniboss(room, args)
    if not ItemManager.setting_on("enemy_locations") then return args end
    local candidates = (args and args.LegalEncounters) or (room and room.LegalEncounters)
    if type(candidates) ~= "table" or #candidates <= 1 or not game.EncounterData then return args end
    local undefeated, allMiniboss = {}, true
    for _, name in ipairs(candidates) do
      local def = game.EncounterData[name]
      if not def or def.EncounterType ~= "MiniBoss" then
        allMiniboss = false
        break
      end
      local check = first_enemy_check_in_encounter(def)
      if not check or not LocationManager.enemy_check_defeated(check) then
        table.insert(undefeated, name)
      end
    end
    if not allMiniboss or #undefeated == 0 or #undefeated == #candidates then return args end
    rom.log.info("[AP] miniboss forcing: narrowed room " .. tostring(room and room.Name)
      .. " pool from " .. #candidates .. " to " .. #undefeated .. " undefeated candidate(s)")
    local newArgs = {}
    if args then for k, v in pairs(args) do newArgs[k] = v end end
    newArgs.LegalEncounters = undefeated
    return newArgs
  end

  -- Crash guard: ChooseEncounter (RunLogic.lua, called from inside CreateRoom -- confirmed via
  -- crash log line numbers) picks a room's LegalEncounters entry with GetRandomValue, which
  -- silently returns nil instead of erroring when the eligible/forced pool is empty; the very
  -- next line then does `encounterData.EnemySet`, a hard Lua error that took down the whole game
  -- (confirmed twice via LogOutput.log: "RunLogic.lua:1079: attempt to index local 'encounterData'
  -- (a nil value)", both times in zone G shortly after a room-clear, no room transition logged in
  -- between -- consistent with the game precomputing the NEXT door's encounter for its icon, not
  -- a room the player was actually standing in). Both crashes landed on rooms our own
  -- eligibility-relaxation fixes touch this run (G_Story01's lifetime-gate strip / G_MiniBoss02's
  -- unlock, see ItemManager.apply_story_room_lifetime_unlock / apply_miniboss_unlock) but the exact
  -- causal chain inside vanilla's eligibility check wasn't pinned down from static reading alone --
  -- this guards the SYMPTOM directly instead of guessing which requirement to patch. pcall the
  -- real ChooseEncounter; on failure, retry once with a synthetic single-item LegalEncounters list
  -- pointing at that room's own zone-generic pool ("Generated" .. RoomSetName, e.g. GeneratedG) --
  -- a baseline encounter every zone already has and rolls constantly, so it's always eligible.
  pcall(function()
    modutil.mod.Path.Wrap("ChooseEncounter", function(base, currentRun, room, args)
      local forceOk, forced = pcall(force_undefeated_miniboss, room, args)
      if forceOk then args = forced end
      local ok, result = pcall(base, currentRun, room, args)
      if ok then return result end
      local zone = room and room.RoomSetName
      local fallbackName = zone and ("Generated" .. zone)
      rom.log.info("[AP] ChooseEncounter crashed for room " .. tostring(room and room.Name)
        .. " (" .. tostring(result) .. ") -- retrying with fallback encounter "
        .. tostring(fallbackName))
      if fallbackName and game.EncounterData and game.EncounterData[fallbackName] then
        local ok2, result2 = pcall(base, currentRun, room, { LegalEncounters = { fallbackName } })
        if ok2 then return result2 end
        rom.log.info("[AP] ChooseEncounter fallback also failed: " .. tostring(result2))
      end
      return nil
    end)
  end)

  -- Oath view-only: the player can OPEN the Oath of the Unseen and see what vows are affecting
  -- them, but cannot change ranks -- in Archipelago the Oath is driven by reverse_vow items, not
  -- manual edits. ShrineScreenRankUp/RankDown (ShrineLogic.lua:461/439) and ShrineLogicResetAll
  -- (the "Reset All" button, :875) are the only ways to mutate GameState.ShrineUpgrades from the
  -- screen; no-op all three while connected (vanilla play, before settings, is untouched). The
  -- screen still opens, scrolls, and displays the active vows normally.
  for _, fn in ipairs({ "ShrineScreenRankUp", "ShrineScreenRankDown", "ShrineLogicResetAll" }) do
    pcall(function()
      modutil.mod.Path.Wrap(fn, function(base, screen, button)
        if ItemManager.have_settings() then return end
        return base(screen, button)
      end)
    end)
  end

  -- DeathLink (outgoing): KillHero is the confirmed hero-death entry point. Count our
  -- deaths and send a DeathLink on every deathlink_amnesty-th death (0 = never send). The
  -- forcing_deathlink guard skips deaths WE caused from an incoming DeathLink.
  pcall(function()
    modutil.mod.Path.Wrap("KillHero", function(base, victim, triggerArgs)
      -- Final Challenge: the scripted "you return to the Crossroads" that normally follows
      -- Chronos'/Typhon's run-clear screen goes through this same KillHero entry point
      -- (win or lose, the run-end sequence is the same code -- see DeathLoopLogic.lua's
      -- KillHero checking CurrentRun.Cleared). Skipping base() entirely here (not just the
      -- DeathLink send below) means the Hero never actually dies -- they stay put, free to
      -- walk up to the Zagreus contract the OpenRunClearScreen wrap just spawned.
      if ItemManager.suppress_win_death then
        ItemManager.suppress_win_death = false
        -- won_run_pending was armed (if set) for THIS same suppressed event -- clear it too,
        -- so it doesn't linger and wrongly swallow the DeathLink for whatever later death
        -- (win or lose) actually ends the Zagreus fight.
        ItemManager.won_run_pending = false
        rom.log.info("[AP] Final Challenge: suppressed the scripted return-to-Crossroads death")
        return
      end
      -- Send BEFORE base() so the DeathLink fires at the START of the death sequence,
      -- not after the whole death animation (base) has played out and returned.
      pcall(function()
        if ItemManager.forcing_deathlink then return end
        -- no_death_on_winning_runs: swallow the one death that ends a winning run.
        if ItemManager.won_run_pending then
          ItemManager.won_run_pending = false
          rom.log.info("[AP] no DeathLink: winning-run return to Crossroads")
          return
        end
        if not ItemManager.setting_on("deathlink") then return end
        local amount = tonumber(ItemManager.settings.deathlink_amnesty) or 1
        if amount <= 0 then return end
        local s = APState.get()
        if not s then return end
        s.death_count = (s.death_count or 0) + 1
        if s.death_count >= amount then
          s.death_count = 0
          Bridge.send("DEATH")
          rom.log.info("[AP] sent DeathLink (death threshold " .. amount .. " reached)")
          if Notifications then Notifications.push("death", "Sent to everyone") end
        else
          rom.log.info("[AP] death " .. s.death_count .. "/" .. amount .. " (no DeathLink yet)")
          if Notifications then Notifications.push("death", "Amnesty " .. s.death_count .. "/" .. amount) end
        end
      end)
      return base(victim, triggerArgs)
    end)
  end)

  -- enemy_locations: every unit death routes through game.Kill (the same entry the
  -- incoming-DeathLink path uses on the hero). Send the first-defeat check for foes we map;
  -- the hero is skipped, and unmapped foes are logged once for discovery (LocationManager).
  pcall(function()
    modutil.mod.Path.Wrap("Kill", function(base, victim, triggerArgs)
      local is_zagreus = false
      pcall(function()
        if victim and not (game.CurrentRun and victim == game.CurrentRun.Hero) then
          LocationManager.on_enemy_killed(victim)
          -- Zagreus goal: his death is the whole fight's win condition (no adds to track,
          -- unlike a normal boss room's "all enemies dead" check) -- same reliable hook as
          -- every other boss/enemy defeat, just routed to the goal tracker instead of (or
          -- in addition to) a "Defeated <enemy>" check.
          if victim.Name == "Zagreus" then
            LocationManager.on_zagreus_cleared()
            is_zagreus = true
          elseif victim.Name == "Hades" and Routes.current() == "Nightmare" then
            -- Nightmare run-clear, taken directly off Hades's own death instead of ZJ's
            -- ModsNikkelMHadesBiomesOpenRunClearScreen (install_nightmare_run_clear_hook) --
            -- that hook depends on rom.mods["NikkelM-Zagreus_Journey"] resolving to a live
            -- table, which was confirmed (2026-07-19 live log) to silently never succeed for
            -- an entire session even though ZJ's own room data loaded and played fine, so
            -- hades_clears never incremented and the goal never re-evaluated true. Kill fires
            -- for every unit regardless of which mod owns it, the same reliable path Zagreus's
            -- own goal tracking above already relies on. handle_nightmare_run_cleared is
            -- idempotent (nightmare_run_clear_handled guard), so this is a safe no-op if one of
            -- the other two paths (vanilla OpenRunClearScreen / the ZJ hook) also ends up firing
            -- for the same clear.
            ItemManager.handle_nightmare_run_cleared()
          end
        end
      end)
      -- base(...) runs Zagreus's own OnDeathFunctionName (ZagreusKillPresentation) to
      -- completion first (it's called directly, not via thread(), so this blocks in our
      -- same coroutine) -- confetti/reward and all -- before we do anything below.
      local result = base(victim, triggerArgs)
      if is_zagreus then
        pcall(function()
          -- Final Challenge: the run-clear screen was deferred back when Chronos/Typhon
          -- fell (see the OpenRunClearScreen wrap) so the player could fight Zagreus first.
          -- Now that he's dead, show it for real -- the run still ends after Zagreus, same
          -- as it would have right after Chronos/Typhon in every other mode.
          if ItemManager.goal_includes_zagreus()
             and ItemManager.zagreus_mode() == ItemManager.ZAGREUS_MODE_FINAL_CHALLENGE then
            ItemManager.won_run_pending = true
            ItemManager.force_run_clear_screen = true
            game.OpenRunClearScreen()
          end
        end)
      end
      return result
    end)
  end)

  -- Empowered Zagreus mode: ActivatePrePlaced (EventLogic.lua:75) is the function that
  -- activates and sets up the pre-placed boss unit for BossZagreus01's
  -- StartRoomUnthreadedEvents (LegalTypes = {"Zagreus"}), returning the activated unit(s).
  -- Let the game finish its own normal spawn/setup first (base(...)), THEN scale the
  -- already-real base stats -- avoids racing the game's own threaded per-unit setup.
  pcall(function()
    modutil.mod.Path.Wrap("ActivatePrePlaced", function(base, eventSource, args)
      local activated = base(eventSource, args)
      pcall(function()
        if not (activated and ItemManager.goal_includes_zagreus()
                and ItemManager.zagreus_mode() == ItemManager.ZAGREUS_MODE_EMPOWERED) then
          return
        end
        local s = APState.get()
        local received = (s and s.zagreus_weaken) or 0
        local tiers = tonumber(ItemManager.settings.zagreus_weaken_tiers) or 5
        for _, unit in pairs(activated) do
          if unit and unit.Name == "Zagreus" then
            ItemManager.apply_zagreus_empower(unit, received, tiers)
          end
        end
      end)
      return activated
    end)
  end)

  -- npc_locations: talking to an NPC. UseNPC(npc, args, user) is the confirmed conversation
  -- entry point (InteractLogic.lua:61) - every cast interaction routes through it. The handler
  -- maps npc.Name -> "Met <Name>" (first time only) and is harmless on anything unmapped. Boss
  -- "Met" checks DON'T use this - they fire reliably from on_room_cleared (reaching the layer).
  --
  -- Helper Room Sanity (items/items_random): used to ALSO block this interaction outright while
  -- locked ("<NPC> doesn't recognize you yet", no base() call). REMOVED 2026-07-21 -- found live
  -- to cause a genuine softlock: several helper rooms' own exit door only unlocks once the NPC's
  -- gift/dialogue completes (native game design), so blocking JUST the interaction left the
  -- player standing in the room with no way to leave. The room-level gate (eligibility_override
  -- + the SelectRandomStoryRoom filter, both in ItemManager.lua) is now the ONLY enforcement --
  -- it keeps a locked NPC's room from being selected to appear in the first place. If the player
  -- ever ends up face to face with a locked helper anyway (the Nightmare-cast / no-unlocks-yet
  -- edge cases those two mechanisms can't fully cover -- see their own comments), this now just
  -- proceeds exactly like vanilla: full dialogue, full gift, no lock message.
  pcall(function()
    modutil.mod.Path.Wrap("UseNPC", function(base, npc, args, user)
      pcall(function() LocationManager.on_npc_interacted(npc) end)
      return base(npc, args, user)
    end)
  end)

  -- Remove Eris' Underworld "Curse" ambush entirely (user request: never want to be cursed).
  -- Confirmed via game scripts (ShrineLogic.lua/RoomDataG,H,I.lua/NPCData_Eris.lua) this ambush
  -- is Underworld-only -- her real Surface boss fight never calls ApplyErisCurse, so there's no
  -- equivalent to worry about there. Two layers, both while an AP session is connected:
  --   1) SpawnErisForCurse (the StartUnthreadedEvents call in RoomDataG/H/I's intro room) is a
  --      no-op, so she never spawns for the ambush at all. The room already handles her absence
  --      gracefully in vanilla (there's a separate "ErisNotSightedVoiceLines" flavor line for
  --      when she isn't encountered), so nothing else breaks.
  --   2) ApplyErisCurse (every one of her ambush dialogue branches ends by calling this,
  --      regardless of how the conversation was entered) also never applies the actual curse
  --      trait, as a defense-in-depth backstop in case some other path into it exists.
  -- "Met Eris" tracking is untouched: it's Surface-gated (matches her real boss fight), and this
  -- ambush was only ever a redundant second way to trigger that same flag -- removing it doesn't
  -- drop any check.
  pcall(function()
    modutil.mod.Path.Wrap("SpawnErisForCurse", function(base, source, args)
      if ItemManager.have_settings() then
        rom.log.info("[AP] blocked Eris curse ambush spawn (removed by request)")
        return
      end
      return base(source, args)
    end)
  end)
  pcall(function()
    modutil.mod.Path.Wrap("ApplyErisCurse", function(base, source, args)
      pcall(function() LocationManager.on_eris_curse_applied() end)
      if ItemManager.have_settings() then
        -- Only skip the trait grant (AddTrait/CallFunctionName/UpdateTraitSummary) -- NOT the
        -- whole function. base() also runs ErisCurseAppliedPresentation, which is what makes
        -- Eris actually leave (animation, restores combat UI, removes her own AddInputBlock).
        -- An earlier version returned before calling base() at all: if SpawnErisForCurse had
        -- already let her spawn (a race -- the AP bridge can connect AFTER the room starts, see
        -- the wrap above), the player could still reach her dialogue and trigger this, and
        -- skipping the whole function left her stuck mid-interaction with nothing ever
        -- resolving her -- this, not the curse itself, is the likely cause of the freeze.
        rom.log.info("[AP] Eris curse trait suppressed (removed by request); still resolving her exit normally")
        pcall(function() game.ErisCurseAppliedPresentation(source, args) end)
        return
      end
      return base(source, args)
    end)
  end)

  -- AddInputBlock/RemoveInputBlock are the engine-native "a scripted sequence is playing,
  -- don't let the player act" signal -- used all over (boss-kill presentations, MapLoad,
  -- StartRoom, dream-run transitions, and Eris' curse cutscene above, if the have_settings()
  -- backstop above doesn't catch it in time). There's no Lua-readable global state for "is any
  -- input block active" the way ScreenAnchors/SessionMapState work, so mirror every named block
  -- into Notifications.active_input_blocks ourselves -- Notifications.update() holds the banner
  -- queue while any are set, instead of popping a banner mid-cutscene (see Notifications.lua).
  pcall(function()
    modutil.mod.Path.Wrap("AddInputBlock", function(base, args)
      pcall(function() Notifications.on_input_block(args and args.Name, true) end)
      return base(args)
    end)
  end)
  pcall(function()
    modutil.mod.Path.Wrap("RemoveInputBlock", function(base, args)
      local result = base(args)
      pcall(function()
        if args and args.All then
          Notifications.clear_input_blocks()
        else
          Notifications.on_input_block(args and args.Name, false)
        end
      end)
      return result
    end)
  end)

  -- Progressive Boon Level: AddTraitToHero(args) (TraitLogic.lua) is the single low-level grant
  -- every boon pickup funnels through -- pedestal, door reward, Charon/Hermes shop purchase, the
  -- boon-choice screen's confirm handler, all of it. It already supports an explicit starting
  -- StackNum via args.StackNum (see e.g. FamiliarLogic.lua's own AddTraitToHero({TraitName=...,
  -- StackNum=...}) call) -- we're just feeding it a different one, not inventing a new mechanism.
  -- Only touch a call that's unambiguously a BRAND-NEW boon grant: args.TraitName set (a named
  -- grant, not args.TraitData -- the shape IncreaseTraitLevel's own internal re-add uses when a
  -- duplicate pickup levels up an existing boon), args.StackNum not already specified by whatever
  -- is calling in (don't clobber an intentional caller-set level), IsGodTrait (a real boon, not a
  -- keepsake/weapon trait/our own hidden AP traits), and not already held (HeroHasTrait false) --
  -- that last check is what keeps this from ever touching a boon the player already has; it only
  -- ever raises the level a FUTURE boon starts at. Fires synchronously inside the player's own
  -- pickup/purchase action (not an async network item arrival), so it doesn't share the boon-
  -- screen-timing softlock risk the AP item-receipt path guards against with
  -- Notifications.blocked() -- see [[project_trait_tray_softlock_fix]] for that unrelated class.
  pcall(function()
    modutil.mod.Path.Wrap("AddTraitToHero", function(base, args)
      pcall(function()
        if args and args.TraitName and args.TraitData == nil and args.StackNum == nil
            and game.IsGodTrait and game.HeroHasTrait
            and game.IsGodTrait(args.TraitName) and not game.HeroHasTrait(args.TraitName) then
          local start = ItemManager.boon_level_start()
          if start then args.StackNum = start end
        end
      end)
      return base(args)
    end)
  end)

  -- Progressive Boon Level (continued): the wrap above only ever fires for AddTraitToHero calls
  -- shaped args.TraitName (no args.TraitData) -- but the dominant way players get a NEW boon, the
  -- pedestal/door/shop choice-menu's confirm handler (HandleUpgradeChoiceSelection,
  -- UpgradeChoiceLogic.lua), calls AddTraitToHero({ TraitData = upgradeData, ... }) with a
  -- TraitData table that was already fully built -- StackNum baked in -- back when the choice
  -- BUTTON was created. By the time AddTraitToHero fires it's too late: args.TraitData is already
  -- non-nil, so the wrap above never touches it. Root-caused by reading the real decompiled game
  -- source (see [[reference_rarity_bonus_field_names]] for why that's the right first move) --
  -- CreateUpgradeChoiceButton (UpgradeChoiceLogic.lua) decides the baked-in StackNum from
  -- itemData.StackNum, IF the caller already set one. That's the exact field vanilla's own
  -- "bonus boon rank" system uses (the Fate keepsake / an Aspect's MaxBonusBoonRankWeighted --
  -- see TraitData_Aspect.lua/TraitData_Keepsake.lua) -- so this isn't a new mechanism either, just
  -- feeding the same input earlier. Pre-set itemData.StackNum here, before base runs, and let
  -- vanilla's own IsGodTrait/StackOnly/TraitToReplace gating inside CreateUpgradeChoiceButton
  -- decide whether it actually applies -- traced through: it only ever affects a genuine new-boon
  -- offer (StackOnly level-up slots and TraitToReplace/exchange slots never read this field), so
  -- no extra filtering needed here. Only set when nil so a real native bonus roll already on the
  -- item (Fate/Aspect) is never clobbered.
  pcall(function()
    modutil.mod.Path.Wrap("CreateUpgradeChoiceButton", function(base, screen, lootData, itemIndex, itemData, args)
      pcall(function()
        if itemData and itemData.StackNum == nil then
          local start = ItemManager.boon_level_start()
          if start then itemData.StackNum = start end
        end
      end)
      return base(screen, lootData, itemIndex, itemData, args)
    end)
  end)

  -- npc_locations: meeting field NPCs (Artemis/Athena/Heracles/...). They're combat
  -- encounters, not conversations or loot, so UseNPC/HandleLootPickup never fired for them
  -- (Test Run 5 #3). StartEncounter(currentRun, currentRoom, encounter) is the encounter-start
  -- entry (RoomLogic.lua:1848); on_encounter_started reads SpeakerNames -> "Met <Name>".
  -- (General room-check scoring is NOT hooked on encounter completion -- see the
  -- SpawnRoomReward wrap below. Raw encounter-completion over-counts: Mount Olympus
  -- "P_Combat01"-style rooms run a pre-combat wave (GeneratedP_PreCombat,
  -- EncounterRoomRewardOverride="Empty") before the real fight, and both are real combat
  -- encounters that "complete". Two exceptions: Rift of Thessaly's NoReward rooms score each
  -- of their waves after base() returns -- see score_thessaly_wave -- and Nightmare Styx's
  -- DeferReward mini rooms (the route's last zone) do the same for the same reason -- see
  -- score_styx_mini.)
  pcall(function()
    modutil.mod.Path.Wrap("StartEncounter", function(base, currentRun, currentRoom, encounter)
      pcall(function() LocationManager.on_encounter_started(encounter) end)
      base(currentRun, currentRoom, encounter)
      -- StartEncounter runs its whole wave to completion before returning (RoomLogic.lua's
      -- multi-encounter loop chains the next wave on this return), so this line is the
      -- "wave killed" moment. Rift of Thessaly's NoReward open-water rooms score EACH of
      -- their chained waves here -- the SpawnRoomReward wrap below can't ever fire for them
      -- (reward is chosen at the steering wheel, not spawned). Nightmare Styx's DeferReward
      -- mini rooms (D_Mini01-14) score here for the identical reason -- their reward is
      -- deferred to the wing's MiniBoss/Reprieve end room, so SpawnRoomReward never spawns
      -- anything for them either. If the player dies mid-wave the room thread is killed
      -- inside base(), so this never runs -- no score.
      pcall(function() LocationManager.score_thessaly_wave(currentRoom, encounter) end)
      pcall(function() LocationManager.score_styx_mini(currentRoom, encounter) end)
    end)
  end)

  -- Room-check trigger for combat rooms: fire when an encounter's reward actually spawns
  -- (RewardLogic.lua:SpawnRoomReward), the game's own definition of "this encounter paid out" --
  -- not just "combat finished" (see the StartEncounter comment above for why that over-counted).
  -- SpawnRoomReward returns the spawned reward object on its one real-spawn path and nil on
  -- every no-op path (Empty/Story/Shop/DeferReward/no reward chosen), so only score a real spawn.
  -- CurrentRun.CurrentRoom.Encounter is whichever encounter is currently resolving (RoomLogic.lua's
  -- multi-encounter loop reassigns it before each StartEncounter call), so this correctly attributes
  -- the check to that specific encounter, not the room as a whole.
  pcall(function()
    modutil.mod.Path.Wrap("SpawnRoomReward", function(base, eventSource, args)
      local reward = base(eventSource, args)
      if reward ~= nil then
        local room = game.CurrentRun and game.CurrentRun.CurrentRoom
        pcall(function() LocationManager.score_encounter(room, room and room.Encounter) end)
      end
      return reward
    end)
  end)

  -- npc_locations: meeting boon gods. Olympians aren't NPC conversations - their boon is a
  -- loot pickup, routed through HandleLootPickup(currentRun, loot, args) (InteractLogic.lua:693),
  -- which plays the god's greeting on interact. on_loot_pickup maps "<God>Upgrade" -> "Met <God>".
  pcall(function()
    modutil.mod.Path.Wrap("HandleLootPickup", function(base, currentRun, loot, args)
      pcall(function() LocationManager.on_loot_pickup(loot) end)
      return base(currentRun, loot, args)
    end)
  end)

  -- npc_locations: meeting Selene. Her Hex ("SpellDrop") loot never reaches HandleLootPickup --
  -- its OnUsedFunctionName is OpenSpellScreen (SpellScreenLogic.lua:1), called directly from the
  -- engine's OnUsed dispatch on interact, before the affordability check and before any resources
  -- are spent. Hooking here fires "Met Selene" the moment she's interacted with, whether or not
  -- the Hex is actually purchased -- matching every other NPC's free "just talked" credit.
  pcall(function()
    modutil.mod.Path.Wrap("OpenSpellScreen", function(base, spellItem, args, user)
      pcall(function() LocationManager.on_spell_screen_opened(spellItem) end)
      return base(spellItem, args, user)
    end)
  end)

  -- npc_locations: story-beat intro checks fired off named text-line sets. PlayTextLines
  -- (NarrativeLogic.lua:190) records GameState.TextLinesRecord[textLines.Name] for every
  -- conversation, so matching the set name is a reliable trigger (Test Run 5 #8: these
  -- locations existed but had no caller).
  --   "SHUSH Homer"   <- the Homer narrator reveal at the Crossroads inspect point
  --                      (InspectHomerReveal01).
  --   "Find Hecate 1/2/3" <- the Hecate hide-and-seek beats (HecateHideAndSeek01/02/03).
  -- If your intended triggers differ, adjust the matched names below.
  pcall(function()
    modutil.mod.Path.Wrap("PlayTextLines", function(base, source, textLines, args)
      pcall(function()
        local nm = textLines and textLines.Name
        if type(nm) == "string" then
          if nm:find("InspectHomerReveal") then
            LocationManager.send_npc_check("SHUSH Homer")
          else
            local n = nm:match("^HecateHideAndSeek0(%d)$")
            if n then LocationManager.send_npc_check("Find Hecate " .. n) end
          end
        end
      end)
      return base(source, textLines, args)
    end)
  end)

  -- game.OpenRunClearScreen() fires when a run is cleared (Chronos/Typhon defeated).
  pcall(function()
    modutil.mod.Path.Wrap("OpenRunClearScreen", function(base, ...)
      -- Final Challenge: this is US calling game.OpenRunClearScreen() a second time (the Kill
      -- wrap, once Zagreus dies) to show the screen that was deferred when Chronos/Typhon
      -- fell -- go straight to the real screen instead of re-running the redirect check below
      -- (which would otherwise fire again, since the goal/mode conditions are still true, and
      -- spawn a second contract instead of actually showing the screen).
      if ItemManager.force_run_clear_screen then
        ItemManager.force_run_clear_screen = false
        return base(...)
      end
      local redirect_to_zagreus = false
      pcall(function()
        -- Which route was cleared (Underworld=Chronos, Surface=Typhon, Nightmare=Hades) from
        -- the final boss room's biome, and the equipped weapon for the goal count. This is
        -- banked UNCONDITIONALLY, before anything about Final Challenge below -- a later
        -- Zagreus win/loss must never undo Chronos/Typhon/Hades's own AP credit.
        local route = Routes.current()
        local weapon_id = game.GameState and game.GameState.PrimaryWeaponName or nil
        if route == "Nightmare" then
          -- Nightmare's own custom run-clear function is ALSO wrapped directly (see
          -- ItemManager.handle_nightmare_run_cleared) -- route both through the same guarded
          -- handler so whichever actually fires first is the one that counts, never both.
          ItemManager.handle_nightmare_run_cleared()
        else
          LocationManager.on_run_cleared(route, weapon_id)
        end
        -- The return-to-Crossroads after a win can read as a death; flag it so the next
        -- KillHero doesn't broadcast a DeathLink.
        ItemManager.won_run_pending = true
        if ItemManager.goal_includes_zagreus()
           and ItemManager.zagreus_mode() == ItemManager.ZAGREUS_MODE_FINAL_CHALLENGE then
          redirect_to_zagreus = true
        end
      end)
      if redirect_to_zagreus then
        -- Final Challenge: instead of forcing a room transition ourselves, spawn the exact
        -- same "ZagContract" secret-door obstacle vanilla's SpawnZagContract (EventLogic.lua
        -- 1875) spawns, right here in Chronos'/Typhon's own boss room, at the Hero's current
        -- position (these rooms have no authored ZagContractDestinationId anchor point of
        -- their own). ZagContract InheritFrom = {"ExitDoor"} (ObstacleData.lua), so
        -- SetupObstacle wires up the normal "walk up, read the contract, get pulled into
        -- C_Boss01" interaction verbatim -- no hand-rolled LeaveRoom call, no guessing at
        -- room-transition internals. We also skip the vanilla run-clear screen entirely (no
        -- base() call below) and suppress the one KillHero that would otherwise follow it
        -- (see ItemManager.suppress_win_death / the KillHero wrap) -- that "you return to the
        -- Crossroads" is scripted as a death regardless of win/loss, and normally happens
        -- right after the run-clear screen closes; without suppressing it the player would be
        -- yanked back to the Crossroads before they ever get a chance to use the contract.
        local handled = false
        local ok, err = pcall(function()
          local currentRun = game.CurrentRun
          local obstacleData = game.ObstacleData and game.ObstacleData.ZagContract
          local roomData = game.RoomData and game.RoomData.C_Boss01
          if currentRun and currentRun.Hero and obstacleData and roomData
             and game.CreateRoom and game.AssignRoomToExitDoor and game.SpawnObstacle
             and game.SetupObstacle and game.DeepCopyTable then
            -- InterBiome is added unconditionally by Chronos'/Typhon's own kill presentation
            -- (PresentationBiomeI/Q) and normally only released by StartRoom's
            -- roomData.RemoveTimerBlock check on the NEXT normal biome room -- since the
            -- player is staying in the current room until they use the contract, release it
            -- now so timed buffs/keepsakes don't sit paused in the meantime.
            game.RemoveTimerBlock(currentRun, "InterBiome")
            local contractItem = game.DeepCopyTable(obstacleData)
            contractItem.ObjectId = game.SpawnObstacle({
              DestinationId = currentRun.Hero.ObjectId, Name = "ZagContract", Group = "Standing",
            })
            contractItem.RerollFunctionName = nil
            local nextRoom = game.CreateRoom(roomData)
            game.AssignRoomToExitDoor(contractItem, nextRoom)
            game.SetupObstacle(contractItem)
            ItemManager.suppress_win_death = true
            handled = true
            rom.log.info("[AP] Final Challenge: spawned the Zagreus contract in the boss room")
          end
        end)
        if handled then return end
        rom.log.warning("[AP] Final Challenge: spawning the Zagreus contract failed, falling back to the run-clear screen ("
          .. tostring(err) .. ")")
      end
      return base(...)
    end)
  end)

  -- Final Challenge boon-wipe root cause: SetupHeroForEnding (RoomLogic.lua) is the game's
  -- "strip the build for the ending cinematic" step -- its ClearUpgrades call empties Traits,
  -- OnFireWeapons, WeaponDataOverride, LastStands, and ManaRegenSources. It's wired into
  -- Chronos'/Typhon's boss rooms' LeavePostPresentationEvents (RoomDataI/RoomDataQ, gated on a
  -- first-ever clear), which fire for ANY door out of those rooms -- including our spawned
  -- ZagContract -- even though vanilla only ever reaches it en route to the I/Q_PostBoss01
  -- ending rooms (vanilla's own contract spawns in early F/G/O rooms, which don't carry the
  -- event). Skip the strip when the exit actually leads to the Zagreus fight; the normal ending
  -- door still runs it untouched. RunEventsGeneric calls this as (room, event.Args=nil,
  -- contextArgs={NextRoom=...}), hence the third parameter.
  pcall(function()
    modutil.mod.Path.Wrap("SetupHeroForEnding", function(base, room, args, contextArgs)
      local skip = false
      pcall(function()
        local nextRoom = contextArgs and contextArgs.NextRoom
        if nextRoom and nextRoom.Name == "C_Boss01"
           and ItemManager.goal_includes_zagreus()
           and ItemManager.zagreus_mode() == ItemManager.ZAGREUS_MODE_FINAL_CHALLENGE then
          skip = true
        end
      end)
      if skip then
        rom.log.info("[AP] Final Challenge: kept the run's build (skipped SetupHeroForEnding into C_Boss01)")
        return
      end
      return base(room, args, contextArgs)
    end)
  end)
end

-- ---- Socket polling driver --------------------------------------------------
-- Driven from ReturnOfModding's render loop via add_always_draw_imgui, which
-- fires every frame regardless of game state. We deliberately do NOT use the
-- game's thread()/wait(): those are coupled to game session state (SessionMapState)
-- and throw during save loads, which froze the game. Registered once.

if not Bridge.driver_started then
  Bridge.driver_started = true
  -- ReturnOfModding's render-loop callback: fires every frame regardless of game
  -- state, decoupled from the game's thread()/wait() (which are coupled to session/map
  -- state and throw during load transitions). We use it purely as a frame driver now.
  rom.gui.add_always_draw_imgui(function()
    -- Heartbeat: log every ~10s (assuming ~60fps) so the log shows whether this render driver is
    -- still ticking after the first run (Test Run 6 #1: the overlay vanished after run one -- if
    -- the heartbeat stops, the driver itself died and we re-register; if it keeps going, the
    -- overlay draw is at fault). Cheap modulo, no per-frame logging.
    AP_render_frames = (AP_render_frames or 0) + 1
    if AP_render_frames % 600 == 0 then
      rom.log.info("[AP] render driver alive (frame " .. AP_render_frames .. ")")
    end
    -- Retry the Nightmare Chaos Gate hooks (~every 0.5s @60fps) until Zagreus' Journey's own
    -- install/validation finishes. A real session showed our one-shot boot-time install call
    -- losing that race by ~1.6ms against the mod's first-time-install auto-reload, leaving the
    -- gate permanently unlocked for the whole run. Both install functions are idempotent and
    -- near-free once installed, so this is safe to leave running indefinitely.
    if AP_render_frames % 30 == 0 then
      pcall(function() ItemManager.retry_nightmare_mod_hooks() end)
      -- Also re-apply the Chaos Gate seal on this same cadence (not just at room-transition /
      -- Grasp-repaint hook points) so it self-heals if anything else touches the gate's
      -- UseText/OnUsedFunctionName/animation in between -- same self-healing pattern as the
      -- other per-room reasserts, just on a tighter loop since there's no room-change event to
      -- hang it off while the player is just standing in the hub.
      pcall(function() ItemManager.apply_nightmare_gate_lock() end)
    end
    -- Poll the socket every frame.
    local ok, err = pcall(Bridge.update)
    if not ok then rom.log.error("[AP] update error: " .. tostring(err)) end

    -- Apply any queued incoming DeathLink, but only when the player is in a killable,
    -- unpaused state (see ItemManager.flush_pending_deathlink). Called by table lookup so a
    -- hot-reload picks up a new version. Held DeathLinks retry themselves every few seconds.
    -- Logging failures here (like the Bridge.update() pcall above) matters: an unlogged error
    -- would silently wedge a queued DeathLink forever with zero trace in the log.
    local dl_ok, dl_err = pcall(function()
      if ItemManager.flush_pending_deathlink then ItemManager.flush_pending_deathlink() end
    end)
    if not dl_ok then rom.log.error("[AP] DeathLink flush error: " .. tostring(dl_err)) end

    -- Apply any stashed incoming items, but only on a frame where receiving is safe (not mid-boon
    -- selection / conversation / pause -- see ItemManager.receive_safe). Held payloads apply
    -- automatically once the player is back in normal control.
    pcall(function() if ItemManager.drain_pending_items then ItemManager.drain_pending_items() end end)

    -- Surface bridge-connection trouble: pinned in the corner overlay (never fades). We deliberately
    -- do NOT banner it -- the banner auto-dismisses too fast to read a diagnostic; the pinned corner
    -- line stays up until the bridge reconnects.
    local diag = Bridge.status_text and Bridge.status_text()
    if Overlay and Overlay.set_diag then Overlay.set_diag(diag) end
    -- Drain the in-game notification queue (native banners). Guarded internally.
    pcall(function() if Notifications then Notifications.update() end end)
    -- Draw the Archipelago overlay (score + sent/filler feed). Guarded internally.
    pcall(function() if Overlay then Overlay.draw() end end)
  end)
end

-- ---- Overlay show/hide shortcut ---------------------------------------------
-- A global keyboard shortcut to toggle the overlay (so it can be reopened after the "x" close
-- button hides it). rom.inputs.on_key_pressed fires even while the game is focused and the mod
-- menu is closed -- the same input system that owns the Insert menu-toggle and the debug keys.
-- Guarded by a plugin global so a hot-reload doesn't stack duplicate handlers (the key only
-- re-registers, with the latest config value, on a full game restart).
if not AP_overlay_key_registered and rom.inputs and rom.inputs.on_key_pressed then
  local key = (config and config.overlay_toggle_key) or "F8"
  local ok, handle = pcall(function()
    return rom.inputs.on_key_pressed{ key, Name = "Archipelago: Toggle Overlay", function()
      rom.log.info("[AP] overlay toggle key fired")
      if Overlay then Overlay.toggle() end
    end }
  end)
  if ok then
    AP_overlay_key_registered = true
    AP_overlay_key_handle = handle
    rom.log.info("[AP] overlay toggle key registered: " .. tostring(key))
  else
    rom.log.error("[AP] overlay toggle key registration failed: " .. tostring(handle))
  end
end

-- A menu-bar entry (visible when the Hell2Modding menu / Insert is open) as a discoverable,
-- no-keyboard way to show the overlay again and a reminder of the shortcut. Registered once.
if not AP_menu_bar_registered and rom.gui and rom.gui.add_to_menu_bar then
  rom.gui.add_to_menu_bar(function()
    local ig = ImGui or (rom and rom.ImGui)
    if not ig or not Overlay then return end
    pcall(function()
      local shown = Overlay.enabled and true or false
      if ig.MenuItem then
        local clicked = ig.MenuItem("Archipelago Overlay", config and config.overlay_toggle_key or "", shown)
        if clicked then Overlay.set_visible(not shown) end
      elseif ig.Checkbox then
        local _, v = ig.Checkbox("Archipelago Overlay", shown)
        if v ~= nil then Overlay.set_visible(v) end
      end
    end)
  end)
  AP_menu_bar_registered = true
end
