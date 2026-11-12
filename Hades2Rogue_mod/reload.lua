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
-- UPDATE 2026-07-19: root-fixed via load order -- our manifest.json listed
-- NikkelM-Zagreus_Journey ahead of the zerp mods as a hard dependency (see
-- main.lua's recovery-shim comment for the full mechanism).
--
-- UPDATE 2026-08-09: ZJ moved to manifest.json's new `rom_soft_deps` (optional
-- dependency) entry -- see main.lua's recovery-shim comment for the full
-- mechanism AND its caveat: moving ZJ alone does not, by itself, still
-- guarantee it loads ahead of the two zerp mods below (soft deps are grouped
-- after all hard deps in the loader's sort). zerp has said they're adding a
-- soft dependency on ZJ to their own mods' manifests to cover this from their
-- side. Until that ships, treat "zerp loads before ZJ" as possible again --
-- the health checks below are exactly how to tell if it happened. With ZJ
-- loading first (either via the old hard-dep mechanism or zerp's own future
-- fix), zerp no longer throws and this repair should be a permanent no-op. It
-- stays as a second, independent safety
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
-- multi-session hunt. 2026-08-09: ZJ is now an OPTIONAL dependency (manifest.json
-- `rom_soft_deps`, see main.lua), so unlike before, none of these are guaranteed
-- to fire clean by construction -- check LogOutput.log after a real boot.
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

-- Each mod's check runs in its OWN pcall, so one check throwing can't skip the ones after it.
-- Same "individually pcall'd steps" shape as the SETTINGS handler (run_settings_step).
local function check_helper_mod_health(name, fn)
  local ok, err = pcall(fn)
  if not ok then
    rom.log.warning("[AP] HEALTH check for '" .. name .. "' errored: " .. tostring(err))
  end
end
local function check_helper_mods_initialized()
  check_helper_mod_health('NikkelM-Zagreus_Journey', function()
    if dependency_mod_enabled('NikkelM-Zagreus_Journey') then
      if game.RoomData and game.RoomData.A_Story01 ~= nil then
        rom.log.info("[AP] HEALTH: Zagreus' Journey rooms registered (Nightmare content available)")
      elseif ItemManager.zj_content_enabled() then
        -- Only worth alarming the player about when this seed's YAML actually wants ZJ
        -- content (include_zagreus_journey). Defaults true (ItemManager.have_settings()
        -- false) before settings arrive, so this still fires during early boot as before.
        AP_log_error("[AP] HEALTH: Zagreus' Journey is enabled but its rooms never registered -- "
          .. "either the once_loaded.game dispatch died before reaching it, or its installation is "
          .. "invalid. Nightmare route AND story-room randomization are broken this session.")
      end
    elseif ItemManager.zj_content_enabled() then
      -- 2026-08-09: ZJ is now an optional dependency, so "not installed at all" is a real,
      -- expected case for the first time (previously Thunderstore force-installed it, so this
      -- branch was unreachable in practice). Only worth alarming about when the seed's YAML
      -- actually wants ZJ content -- same include_zagreus_journey gate as the branch above.
      AP_log_error("[AP] HEALTH: this seed's YAML has include_zagreus_journey enabled, but the "
        .. "Zagreus' Journey mod (NikkelM-Zagreus_Journey) isn't installed -- the Nightmare route "
        .. "and its checks will be unreachable this session. Install Zagreus' Journey, or "
        .. "regenerate with include_zagreus_journey off.")
    end
  end)
  check_helper_mod_health('zerp-NPCRoomRandomizer', function()
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
        AP_log_error('[AP] HEALTH: zerp-NPCRoomRandomizer STARTED init but crashed partway '
          .. '(its ready.lua threw mid-run) -- story-room (helper NPC) randomization is NOT active this session')
      else
        AP_log_error('[AP] HEALTH: zerp-NPCRoomRandomizer is enabled but never initialized -- '
          .. 'story-room (helper NPC) randomization is NOT active this session')
      end
    end
  end)
  check_helper_mod_health('zerp-Extended_NPC_Encounters', function()
    if dependency_mod_enabled('zerp-Extended_NPC_Encounters') then
      local enc = game.EncounterData and game.EncounterData.NemesisCombatH
      if has_pathfalse_marker(enc and enc.GameStateRequirements,
          'zerp-Extended_NPC_EncountersNextRoomCageFieldEncounters') then
        rom.log.info('[AP] HEALTH: zerp-Extended_NPC_Encounters initialized (combat-assist NPC randomization active)')
      else
        AP_log_error('[AP] HEALTH: zerp-Extended_NPC_Encounters is enabled but never initialized -- '
          .. 'combat-assist NPC randomization is NOT active this session')
      end
    end
  end)
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
-- the ONLY protection.
local STORY_ROOM_REROLL_ATTEMPTS = 20
-- Zone/biome key for each story room, matching zerp-NPCRoomRandomizer's own mod.RoomSets /
-- mod.ZagRoomSets tables (ready.lua) -- used ONLY by the "no unlocked NPC anywhere in the pool"
-- fallback below, to hand back an ordinary combat/reward room from the SAME zone instead.
local STORY_ROOM_BIOME_KEY = {
  F_Story01 = "F", G_Story01 = "G", H_Bridge01 = "H", I_Story01 = "I",
  N_Story01 = "N", O_Story01 = "O", P_Story01 = "P",
  A_Story01 = "Tartarus", X_Story01 = "Asphodel", Y_Story01 = "Elysium",
}
-- Confirmed live 2026-07-22: with only ONE helper unlocked (Hades) and helper_room_sanity=
-- items_random, a run that had already visited Hades' own door once (I_Story01, legitimately,
-- since he was eligible) hit a SECOND story door later the same run wanting to swap in some
-- OTHER NPC -- but zerp's own "no repeat NPC in one run" bookkeeping (StoryRoomsCreated,
-- ready.lua) had already removed I_Story01 from the swap pool, leaving ZERO eligible candidates
-- for the retry loop below to ever find, no matter how many times it rerolled. The old fallback
-- (documented above, since removed) just accepted whatever the last reroll happened to be --
-- Narcissus, locked, standing right there. Per user request: reroll to a DIFFERENT KIND OF ROOM
-- instead of ever handing back a locked NPC -- pull a random ordinary combat/reward room name
-- from that zone's own RoomSets (the same table zerp itself uses for its "link back to a normal
-- room" cases elsewhere in ChooseNextRoomData) and use that as the door's identity instead. Note:
-- zerp's ChooseNextRoomData still applies its own post-swap decoration (RewardPreviewOverride=
-- "StoryPreview", secrets/shrine/anomaly disabled for this room instance) since that runs
-- unconditionally after ANY SelectRandomStoryRoom return -- the door's preview icon used to still
-- read "Story" even though a plain fight was behind it (player-reported 2026-07-31). The
-- RewardPreviewOverride half of that is now corrected back to the real room's own value by
-- fixup_fallback_room_preview, below, in the ChooseNextRoomData wrap; the secrets/shrine/anomaly
-- suppression is left alone (purely a room-variety reduction, not a visible mismatch).
local function pick_fallback_combat_room(origStoryRoom)
  local zmod = modutil and modutil.mod and modutil.mod.Mods and modutil.mod.Mods.Data
    and modutil.mod.Mods.Data['zerp-NPCRoomRandomizer']
  local biome = STORY_ROOM_BIOME_KEY[origStoryRoom]
  if not (zmod and biome) then return nil end
  local pool = (zmod.RoomSets and zmod.RoomSets[biome]) or (zmod.ZagRoomSets and zmod.ZagRoomSets[biome])
  if not (pool and #pool > 0) then return nil end
  return pool[math.random(1, #pool)]
end
local function pick_unlocked_story_room(native_select, origStoryRoom, banned1, banned2)
  local result = native_select(origStoryRoom, banned1, banned2)
  if ItemManager.setting_mode("helper_room_sanity") ~= 3 then return result end
  local tries = 0
  while result do
    local npc = ItemManager.STORY_ROOM_TO_NPC[result]
    if not npc or ItemManager.helper_npc_eligible(npc) then return result end
    if tries >= STORY_ROOM_REROLL_ATTEMPTS then break end
    result = native_select(origStoryRoom, banned1, banned2)
    tries = tries + 1
  end
  -- Exhausted (or native_select itself ran dry, e.g. every story room already visited this run)
  -- without ever finding an unlocked NPC -- turn the door into an ordinary room for its own zone
  -- instead of leaving a locked NPC in it. Only falls through to the old "return result" (locked
  -- NPC or nil) if that zone's own combat-room pool can't be found for some reason -- never seen
  -- live, but keeps this from ever handing back an unrecognized room identity.
  local fallback = pick_fallback_combat_room(origStoryRoom)
  if fallback then
    rom.log.info("[AP] helper_room_sanity: no unlocked NPC available for " .. tostring(origStoryRoom)
      .. " after " .. tries .. " reroll(s) -- using " .. fallback .. " instead of a locked NPC")
    return fallback
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

-- All four installs below (story-room intercept, native combat-helper item gate, zerp's
-- foreign-zone item gate, Thanatos item gate) used to be one-shot: if the third-party mod they
-- reach into wasn't finished initializing at the exact moment reload.lua first ran (e.g. its own
-- ready.lua is still mid-init, or -- confirmed live 2026-07-26 -- got skipped entirely because
-- Zagreus' Journey aborted its own install ["Hades mods detected"], which crashed
-- zerp-NPCRoomRandomizer indexing ZJ's now-missing rooms, which aborted ModUtil's shared
-- once_loaded.game dispatch before it ever reached zerp-Extended_NPC_Encounters), the gate simply
-- never installed for the rest of the session -- logged once as an error and never retried,
-- silently leaving that helper's spawns ungated (native default, no AP unlock check) or
-- ungeofenced (that mod's own default zone list, ignoring AP's location control) for the whole
-- run. Each is now a named, idempotent installer (safe to call repeatedly -- returns immediately
-- once already installed) so the render-loop retry further down can keep trying until the
-- dependency actually settles, the same pattern already used for the Nightmare Chaos Gate
-- run-clear hook (ItemManager.install_nightmare_run_clear_hook / retry_nightmare_mod_hooks).
local HELPER_GATE_INSTALLED = {}
local HELPER_GATE_LOGGED_MISSING = {}
-- Cross-zone story-swap tracking (2026-07-29): captures which story-room KEY zerp's
-- SelectRandomStoryRoom was just asked to replace (e.g. "Y_Story01"), so the ChooseNextRoomData
-- wrap below can tell whether THIS swap crossed a zone boundary. See that wrap's comment for the
-- full bug this exists to correct. Reset to nil immediately before every base() call in that wrap,
-- so a stale value from an unrelated call (or zerp's separate Medea/N_Hub swap site in LeaveRoom,
-- which this variable also observes) can never leak into a later, unrelated check.
local HELPER_ROOM_SWAP_ORIGIN = nil
local function install_helper_room_sanity_intercept()
  if HELPER_GATE_INSTALLED.story_room then return true end
  local ok = pcall(function()
    local zmod = modutil and modutil.mod and modutil.mod.Mods and modutil.mod.Mods.Data
      and modutil.mod.Mods.Data['zerp-NPCRoomRandomizer']
    if zmod and type(zmod.SelectRandomStoryRoom) == 'function' then
      local native_select = zmod.SelectRandomStoryRoom
      zmod.SelectRandomStoryRoom = function(origStoryRoom, banned1, banned2)
        HELPER_ROOM_SWAP_ORIGIN = origStoryRoom
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
      HELPER_GATE_INSTALLED.story_room = true
    end
  end)
  if not HELPER_GATE_INSTALLED.story_room and not HELPER_GATE_LOGGED_MISSING.story_room then
    HELPER_GATE_LOGGED_MISSING.story_room = true
    AP_log_error("[AP] helper_room_sanity: zerp-NPCRoomRandomizer.SelectRandomStoryRoom not found "
      .. "-- randomization control inactive for now (falls back to that mod's own default), will retry")
  end
  return HELPER_GATE_INSTALLED.story_room == true
end
pcall(install_helper_room_sanity_intercept)

-- ChooseNextRoomData crash guard: zerp-NPCRoomRandomizer's own wrap (ready.lua) calls its
-- captured `base(...)` and then immediately indexes the result (`nextRoomData.Name`, line 345)
-- with no nil check. The base game's OWN ChooseNextRoomData (RunLogic.lua) can legitimately
-- return nil -- it has a DebugAssert("No eligible rooms for exit door!") guarding that case, but
-- DebugAssert is non-fatal (just logs) and the function returns nil anyway whenever
-- IsRoomEligible rejects every room in the target RoomSet. Root cause of a 2026-07-26 player
-- crash log ("attempt to index local 'nextRoomData' (a nil value)" at
-- zerp-NPCRoomRandomizer/ready.lua:345) that forced them to start a fresh save. zerp is a
-- manifest dependency (loads before us), so this wrap lands OUTSIDE zerp's own -- a pcall here
-- catches an error thrown anywhere in the call chain (zerp's wrap OR the base game function),
-- not just a plain nil return. On failure: retry without ForceNextRoomSet (a forced RoomSet
-- that's been exhausted/visited-out), then with the current biome's room set, then take the
-- room's own authored link, then any room of that biome (fallback_next_room). Never the current
-- room itself -- returning it re-entered the finished room forever.
--
-- Cross-zone story-swap correction (2026-07-29): a second, independent bug living in the SAME
-- wrap chain, root-caused from a player-supplied LogOutput.log showing a Nightmare run crossing
-- Asphodel -> Elysium (score line "RoomSetName=Asphodel RoomName=X_PostBoss01" immediately
-- followed by ZJ's own "Forcing = Y_Story01" debug line, then zerp swapping that Y_Story01 door
-- for G_Story01). zerp's ChooseNextRoomData (ready.lua ~350) always stamps the swapped-in room's
-- "return to this biome after the borrowed room" marker
-- (`nextRoomData[_PLUGIN.guid .. "CurrentBiome"]`) with `currentRun.CurrentRoom.RoomSetName` --
-- i.e. the zone the player is LEAVING. That's correct for zerp's normal case (a story room
-- appearing mid-zone, e.g. F_Story01 mid-Underworld -- the player should return to F afterward).
-- It's wrong specifically when the swapped door is itself the first room of a NEW zone (crossing
-- Asphodel's own post-boss room into Elysium's Y_Story01, a genuine cross-zone jump): the
-- "departure zone" (Asphodel) is already fully cleared, so once the borrowed NPC room (G_Story01)
-- finishes, zerp's own biome-return logic (same ready.lua file, the `currentBiome and
-- args.ForceNextRoomSet == nil` branch) routes the player BACKWARD into a random already-visited
-- Asphodel combat room instead of forward into Elysium -- matching the reported symptom exactly
-- ("room after the fountain is always an NPC, then it replays the region again") -- and that
-- backward room's own state (boss already dead, doors/links already consumed this run) is what
-- crashes shortly after ("crashes in the room behind the boss").
-- Fix: HELPER_ROOM_SWAP_ORIGIN (set above, inside our SelectRandomStoryRoom override) captures
-- the ORIGINAL story-room key zerp was asked to replace on this exact call. Its own native
-- RoomSetName (a genuine static field, unrelated to which zone the player is leaving -- see
-- Routes.lua's identical reasoning for AP_RealRoomSetName) tells us the TRUE destination zone.
-- If that differs from the departure zone zerp stamped, overwrite the marker with the correct
-- destination so the post-NPC-room return routes the player FORWARD into their real next zone
-- instead of back into the one they just cleared. Every same-zone swap (the overwhelming
-- majority) sees trueZone == departureZone and this is a complete no-op.
-- Fallback-room door preview fix (2026-07-31, player-reported): pick_fallback_combat_room above
-- hands zerp back an ORDINARY combat/reward room's key (not a locked NPC's story room) when
-- items_random ran out of unlocked NPCs to swap in for this door. But zerp's ChooseNextRoomData
-- (ready.lua ~349-363) doesn't know the difference -- it unconditionally stamps ANY
-- SelectRandomStoryRoom return with RewardPreviewOverride = "StoryPreview" (or the Chaos/
-- ModsNikkelMHadesBiomes variants), so the door showed a Story/helper icon even though a plain
-- fight is actually behind it -- exactly the "helper is showing as the door preview, but it's not
-- a helper area when you enter" report. Undo the clobber by restoring whatever preview override
-- the room's own UNMODIFIED authored data (game.RoomData, the shared template, not zerp's
-- per-instance deep copy) actually has -- nil for most ordinary combat rooms, which lets the game
-- compute the normal preview from that room's real reward store instead.
local function fixup_fallback_room_preview(origin, result)
  if not (origin and type(result) == 'table' and result.Name) then return end
  if ItemManager.STORY_ROOM_TO_NPC[result.Name] then return end -- a real story room -- leave as-is
  local native = game.RoomData and game.RoomData[result.Name]
  local trueOverride = native and native.RewardPreviewOverride or nil
  if result.RewardPreviewOverride == trueOverride then return end
  pcall(function()
    rom.log.info("[AP] helper_room_sanity: fallback room " .. tostring(result.Name)
      .. " door preview corrected from " .. tostring(result.RewardPreviewOverride)
      .. " to " .. tostring(trueOverride))
  end)
  result.RewardPreviewOverride = trueOverride
end
local function fixup_cross_zone_story_swap(currentRun, result)
  local origin = HELPER_ROOM_SWAP_ORIGIN
  HELPER_ROOM_SWAP_ORIGIN = nil
  fixup_fallback_room_preview(origin, result)
  if not (origin and type(result) == 'table' and result['zerp-NPCRoomRandomizerCurrentBiome']) then
    return
  end
  local originRoomData = game.RoomData and game.RoomData[origin]
  local trueZone = originRoomData and originRoomData.RoomSetName
  local departureZone = currentRun.CurrentRoom and currentRun.CurrentRoom.RoomSetName
  if trueZone and departureZone and trueZone ~= departureZone
     and result['zerp-NPCRoomRandomizerCurrentBiome'] == departureZone then
    result['zerp-NPCRoomRandomizerCurrentBiome'] = trueZone
    pcall(function()
      rom.log.info("[AP] helper_room_sanity: cross-zone story swap (" .. tostring(origin) .. " -> "
        .. tostring(result.Name) .. ") -- correcting return-biome from " .. tostring(departureZone)
        .. " to " .. tostring(trueZone))
    end)
  end
end
-- Last-resort rungs of the crash guard, used only after base() failed twice. Never returns the
-- room the player is standing in (that re-entered the finished room forever: Chaos-room chains,
-- "same room forever").
local function fallback_next_room(currentRun)
  local current = currentRun.CurrentRoom
  local currentName = current and current.Name
  local currentData = currentName and game.RoomData[currentName] or current
  -- The room's own authored link (PreBoss -> boss arena and friends).
  local linked = currentData and (currentData.LinkedRoom
    or (currentData.LinkedRooms and currentData.LinkedRooms[1]))
  if linked and linked ~= currentName and game.RoomData[linked] then
    return game.RoomData[linked], "linked room " .. linked
  end
  -- Any room of the biome the run is routing through, eligibility ignored.
  local set = Routes.current_room_set()
  local names = {}
  for _, name in ipairs((set and game.RoomSets and game.RoomSets[set]) or {}) do
    if name ~= currentName and game.RoomData[name] then table.insert(names, name) end
  end
  if #names > 0 then
    local pick = names[math.random(#names)]
    return game.RoomData[pick], "random " .. tostring(set) .. " room " .. pick
  end
  return nil, "nothing usable"
end

-- Zagreus contract return (Vanilla/Empowered): the contract arena C_Boss01 has UsePreviousRoomSet,
-- so its exit would draw a random room from the biome you came from -- skipping the link the
-- origin room owed you (a PreBoss room's boss arena, a PostBoss room's next biome).
-- ItemManager.apply_zagreus_contract_everywhere stashes that room's own onward target when it
-- spawns the contract (currentRun.APZagReturn); spend it here, once. Returns (roomData, argsOverride).
local function zagreus_contract_return(currentRun, args)
  local ret = currentRun.APZagReturn
  if not ret or not (currentRun.CurrentRoom and currentRun.CurrentRoom.Name == "C_Boss01") then
    return nil, nil
  end
  currentRun.APZagReturn = nil
  if ret.LinkedRoom and game.RoomData[ret.LinkedRoom] then
    return game.RoomData[ret.LinkedRoom], nil
  end
  if ret.LinkedRooms then
    local originData = ret.Origin and game.RoomData[ret.Origin]
    local eligible = {}
    for _, name in ipairs(ret.LinkedRooms) do
      local data = game.RoomData[name]
      if data then
        local ok, yes = pcall(game.IsRoomEligible, currentRun, originData or data, data, args or {})
        if ok and yes then table.insert(eligible, name) end
      end
    end
    local pick = eligible[1] and eligible[math.random(#eligible)] or ret.LinkedRooms[1]
    if pick and game.RoomData[pick] then return game.RoomData[pick], nil end
  end
  if ret.NextRoomSet then
    local override = {}
    for k, v in pairs(args or {}) do override[k] = v end
    override.ForceNextRoomSet = ret.NextRoomSet
    return nil, override
  end
  return nil, nil
end

pcall(function()
  modutil.mod.Path.Wrap("ChooseNextRoomData", function(base, currentRun, args, otherDoors)
    local result, ok
    local direct, zagArgs = nil, nil
    pcall(function() direct, zagArgs = zagreus_contract_return(currentRun, args) end)
    if zagArgs then args = zagArgs end
    if direct then
      rom.log.info("[AP] Zagreus contract: returning to " .. tostring(direct.Name))
      HELPER_ROOM_SWAP_ORIGIN = nil   -- a shared RoomData template: no story-swap fixups apply
      ok, result = true, direct
    else
      HELPER_ROOM_SWAP_ORIGIN = nil
      ok, result = pcall(base, currentRun, args, otherDoors)
      -- Crash guard ladder. zerp-NPCRoomRandomizer's wrap (inside base) and the base game can
      -- both fail here -- the game returns nil when IsRoomEligible rejects every room in the
      -- target set, and zerp 0.4.8 now passes that nil on instead of crashing.
      local retries = {
        { "without ForceNextRoomSet", nil },
        { "with the current biome's room set", Routes.current_room_set() },
      }
      for _, step in ipairs(retries) do
        if ok and result ~= nil then break end
        AP_log_error("ChooseNextRoomData crash guard: " .. tostring(not ok and result or "returned nil")
          .. " -- retrying " .. step[1])
        local retryArgs = {}
        for k, v in pairs(args or {}) do retryArgs[k] = v end
        retryArgs.ForceNextRoomSet = step[2]
        HELPER_ROOM_SWAP_ORIGIN = nil
        ok, result = pcall(base, currentRun, retryArgs, otherDoors)
      end
    end
    if ok and result ~= nil then
      fixup_cross_zone_story_swap(currentRun, result)
      -- Miniboss ROOM shuffle: swap the chosen miniboss room for the seed's permuted one. Done
      -- here, on the room the run just settled on, so it composes with everything upstream (the
      -- crash-guard retries, zerp's own swaps, the cross-zone story fixup) rather than racing
      -- them -- and pcall'd because this whole wrap exists to guarantee ChooseNextRoomData never
      -- throws. A failure leaves the native miniboss room, which is simply vanilla behaviour.
      -- First MinibossRooms.vet_choice turns away a miniboss room straight after another one, or
      -- one whose arena this run already served, by choosing again without it.
      pcall(function()
        local vetted = MinibossRooms.vet_choice(currentRun, result, function(excluded)
          local retryArgs = {}
          for k, v in pairs(args or {}) do retryArgs[k] = v end
          local names = {}
          for k, v in pairs((args and args.ExcludedNames) or {}) do names[k] = v end
          for k in pairs(excluded) do names[k] = true end
          retryArgs.ExcludedNames = names
          HELPER_ROOM_SWAP_ORIGIN = nil
          local okAgain, again = pcall(base, currentRun, retryArgs, otherDoors)
          if not (okAgain and again ~= nil) then return nil end
          fixup_cross_zone_story_swap(currentRun, again)
          return again
        end)
        if vetted then result = vetted end
        local swapped = MinibossRooms.swap_for(result)
        if swapped then result = swapped end
      end)
      -- Asphodel Trap: while one is armed, an ordinary combat door leads to the Anomaly instead
      -- (Traps.anomaly_swap). Last, so it replaces the room everything above settled on.
      pcall(function()
        local anomaly = Traps and Traps.anomaly_swap(currentRun, args, result)
        if anomaly then result = anomaly end
      end)
      return result
    end
    local fallback, how = nil, "fallback errored"
    pcall(function() fallback, how = fallback_next_room(currentRun) end)
    AP_log_error("ChooseNextRoomData crash guard: every retry failed -- using " .. tostring(how))
    return fallback
  end)
  rom.log.info("[AP] ChooseNextRoomData crash guard installed")
end)

-- Miniboss ROOM shuffle bookkeeping: book a swapped room against the HOST slot it took, not the
-- destination whose Name it carries (see MinibossRooms.count_host). One wrap per place the game
-- counts a room by Name; all no-ops for a room that was not swapped.
pcall(function()
  modutil.mod.Path.Wrap("CreateRoom", function(base, roomData, args)
    -- Ephyra's square builds its miniboss door's room here directly, never through
    -- ChooseNextRoomData (MinibossRooms.serve_hub_door), so that slot is swapped here instead.
    pcall(function()
      local served = MinibossRooms.serve_hub_door(CurrentRun, roomData)
      if served then roomData = served end
    end)
    local room = base(roomData, args)
    pcall(function()
      if not (room and room.AP_MinibossRoomOrigin and CurrentRun) then return end
      for _, counts in pairs({ CurrentRun.RoomCreations,
                               CurrentRun.CurrentRoom and CurrentRun.CurrentRoom.RoomCreations }) do
        MinibossRooms.count_host(room, counts)
        MinibossRooms.uncount_dest(room, counts)
      end
    end)
    return room
  end)
  modutil.mod.Path.Wrap("StartRoom", function(base, currentRun, currentRoom)
    pcall(function() MinibossRooms.count_host(currentRoom, currentRun and currentRun.RoomsEntered) end)
    pcall(function() MinibossRooms.note_served(currentRun, currentRoom) end)
    pcall(function() MinibossRooms.credit_hub_pylon(currentRun, currentRoom) end)
    base(currentRun, currentRoom)
    pcall(function() MinibossRooms.uncount_dest(currentRoom, currentRun and currentRun.RoomsEntered) end)
  end)
  modutil.mod.Path.Wrap("UpdateRunHistoryCache", function(base, run, roomAdded)
    base(run, roomAdded)
    pcall(function()
      if not (run and roomAdded and roomAdded.AP_MinibossRoomOrigin) then return end
      for _, counts in pairs({ run.RoomCountCache, run.BiomeRoomCountCache }) do
        MinibossRooms.count_host(roomAdded, counts)
        MinibossRooms.uncount_dest(roomAdded, counts)
      end
    end)
  end)
  -- Miniboss door marker: make the Fated List sub-icon on a miniboss door follow the AP check
  -- behind it instead of vanilla's encounter records (see MinibossRooms.door_marker).
  modutil.mod.Path.Wrap("PopulateDoorRewardPreviewSubIcons", function(base, exitDoor, args)
    local subIcons = base(exitDoor, args)
    pcall(function()
      if type(subIcons) ~= "table" or (args and (args.RewardHidden or args.SkipRoomSubIcons)) then return end
      local want = MinibossRooms.door_marker(exitDoor and exitDoor.Room)
      if want == nil then return end
      local at = nil
      for i, icon in ipairs(subIcons) do
        if icon.Name == "RoomRewardSubIcon_FatedList" then at = i break end
      end
      if want and not at then
        table.insert(subIcons, { Name = "RoomRewardSubIcon_FatedList" })
      elseif not want and at then
        table.remove(subIcons, at)
      end
    end)
    return subIcons
  end)
  -- Ephyra is a hub, and its rooms are wired to the square rather than to themselves (see the
  -- Ephyra section of MinibossRooms.lua). A swapped room takes on the wiring of the slot it fills,
  -- not of the arena it shows: a foreign arena in an Ephyra slot ("hosted") behaves like an Ephyra
  -- room, and an Ephyra arena in another biome's slot ("guest") behaves like that biome's room.
  -- Seen live 2026-10-10 (a dive whose region 3 was Ephyra served N_MiniBoss02 in an Erebus slot)
  -- and 2026-10-15 (the Boar in a Talos slot walked back into the finished square).
  --   * the exit: Ephyra rooms leave by an EphyraExitDoorReturn, whose
  --     ReturnToPreviousRoomName = "N_Hub" swaps the door's room for the square already in the
  --     run's history (RoomLogic.lua:841). Hosted arenas get that; guests lose it.
  modutil.mod.Path.Wrap("AttemptUseDoor", function(base, door, args)
    pcall(function()
      local room = CurrentRun and CurrentRun.CurrentRoom
      if door and room and room.AP_MinibossRoomOrigin then
        door.ReturnToPreviousRoomName = MinibossRooms.hub_return(CurrentRun, room)
      end
    end)
    return base(door, args)
  end)
  --   * the doorway: every Ephyra room's OnUseSetRunData stamps NextHeroStartPoint/EndPoint, the
  --     ids of its doorway in the N_Hub map (RoomLogic.lua:868). LeaveRoom carries them onto the run
  --     and the next room starts the hero there (RoomPresentation.lua:1130). A hosted arena gets the
  --     native slot's doorway (its own doors aren't named for the stamp); a guest's are cleared --
  --     in any other map they don't exist, and the hero started outside the walls with the camera
  --     on a corner (reported 2026-10-10 and 2026-10-25).
  modutil.mod.Path.Wrap("LeaveRoom", function(base, currentRun, door)
    pcall(function()
      local room = currentRun and currentRun.CurrentRoom
      if room and room.AP_MinibossRoomOrigin then
        room.NextHeroStartPoint, room.NextHeroEndPoint = MinibossRooms.hub_doorway(room)
      end
    end)
    return base(currentRun, door)
  end)
  --   * the exit's reward preview: hosted arenas hide it (every exit leads to the square), guests
  --     show it again (MinibossRooms.prepare_exit_doors). Runs on first unlock and on every
  --     restore, before the doors are given rooms and previews.
  modutil.mod.Path.Wrap("DoUnlockRoomExits", function(base, run, room)
    pcall(function()
      if room and room.AP_MinibossRoomOrigin then
        MinibossRooms.prepare_exit_doors(room, game.MapState and game.MapState.OfferedExitDoors)
      end
    end)
    return base(run, room)
  end)
  --   * the pylon: BaseN spawns a Soul Pylon in every Ephyra room and the square counts spawns, so a
  --     guest read 6 - 7 = -1 pylons left (before Ephyra it would have opened the boss exit one
  --     early). Guests spawn none; a hosted arena is credited one instead
  --     (MinibossRooms.credit_hub_pylon, from the StartRoom wrap above).
  modutil.mod.Path.Wrap("SpawnSoulPylon", function(base, room, args)
    local current = CurrentRun and CurrentRun.CurrentRoom
    if current and current.AP_MinibossRoomOrigin then return end
    return base(room, args)
  end)
  modutil.mod.Path.Wrap("HandlePylonObjective", function(base, source, args)
    local current = CurrentRun and CurrentRun.CurrentRoom
    if current and current.AP_MinibossRoomOrigin then return end
    return base(source, args)
  end)
  --   * the closed exit: leaving any Ephyra room closes its exit for the run under the room's Name
  --     (CloseDoorForRun). A guest whose Name was already left once this run (the native one
  --     through the square in a Dive, or the same arena again) found its only exit closed and
  --     never unlocked (Brice13 2026-10-10). A swapped room never inherits that state; swap_for
  --     also stops it closing doors itself. The square's own door to a hosted arena still closes
  --     behind you, as for any Ephyra room: that is N_Hub's CloseDoorsOnUse, untouched.
  modutil.mod.Path.Wrap("IsDoorClosedForRun", function(base, run, obstacle)
    local current = run and run.CurrentRoom
    if current and current.AP_MinibossRoomOrigin then return false end
    return base(run, obstacle)
  end)
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
local function install_combat_helper_native_gate()
  if HELPER_GATE_INSTALLED.native then return true end
  local ok = pcall(function()
    for npc, fnName in pairs({
      Artemis = "HandleArtemisSpawn", Heracles = "HandleHeraclesSpawn", Icarus = "HandleIcarusSpawn",
      Nemesis = "HandleNemesisCombatSpawn", Athena = "HandleAthenaSpawn",
    }) do
      modutil.mod.Path.Wrap(fnName, function(base, ...)
        if not ItemManager.combat_helper_eligible(npc) then return end
        return base(...)
      end)
    end
  end)
  if ok then
    HELPER_GATE_INSTALLED.native = true
    rom.log.info("[AP] combat_helper_sanity: intercepted native Handle<God>Spawn functions")
  elseif not HELPER_GATE_LOGGED_MISSING.native then
    HELPER_GATE_LOGGED_MISSING.native = true
    AP_log_error("[AP] combat_helper_sanity: failed to wrap native Handle<God>Spawn functions -- native-zone item gate inactive for now, will retry")
  end
  return HELPER_GATE_INSTALLED.native == true
end
pcall(install_combat_helper_native_gate)

-- Foreign-zone half for Artemis/Heracles/Icarus (see comment above): their OWN copy lives on
-- zerp-Extended_NPC_Encounters' registered mod object, not on `game`, so Path.Wrap can't
-- reach it -- same live-table monkeypatch technique as the SelectRandomStoryRoom intercept
-- above (there's no ModUtil `base` to capture on a foreign mod's own table).
local function install_combat_helper_foreign_gate()
  if HELPER_GATE_INSTALLED.foreign then return true end
  local all_ok = false
  pcall(function()
    local zmod = modutil and modutil.mod and modutil.mod.Mods and modutil.mod.Mods.Data
      and modutil.mod.Mods.Data['zerp-Extended_NPC_Encounters']
    if not zmod then return end
    all_ok = true
    for npc, fnName in pairs({ Artemis = "HandleArtemisSpawn", Heracles = "HandleHeraclesSpawn", Icarus = "HandleIcarusSpawn" }) do
      local native = zmod[fnName]
      if type(native) == "function" then
        zmod[fnName] = function(...)
          if not ItemManager.combat_helper_eligible(npc) then return end
          return native(...)
        end
      else
        all_ok = false
      end
    end
  end)
  if all_ok then
    HELPER_GATE_INSTALLED.foreign = true
    rom.log.info("[AP] combat_helper_sanity: intercepted zerp-Extended_NPC_Encounters foreign-zone spawn functions")
  elseif not HELPER_GATE_LOGGED_MISSING.foreign then
    HELPER_GATE_LOGGED_MISSING.foreign = true
    AP_log_error("[AP] combat_helper_sanity: zerp-Extended_NPC_Encounters mod table/functions not found "
      .. "-- foreign-zone item gate inactive for now, will retry")
  end
  return HELPER_GATE_INSTALLED.foreign == true
end
pcall(install_combat_helper_foreign_gate)

-- Thanatos: both native (Zagreus' Journey's own Nightmare-zone encounters) and foreign
-- (zerp's base-zone additions, which inherit BaseThanatos wholesale -- confirmed by reading
-- thanatos.lua) call the SAME function, NikkelM-Zagreus_Journey's own mod.HandleThanatosSpawn
-- (confirmed via its FunctionMappings/ThanatosLogic.lua) -- one live-table monkeypatch
-- covers every zone, same technique as the zerp foreign-zone block above.
local function install_thanatos_combat_helper_gate()
  if HELPER_GATE_INSTALLED.thanatos then return true end
  if not dependency_mod_enabled('NikkelM-Zagreus_Journey') then
    return true -- not installed: expected for players who haven't opted into Nightmare, not an error
  end
  local ok = pcall(function()
    local zjmod = modutil and modutil.mod and modutil.mod.Mods and modutil.mod.Mods.Data
      and modutil.mod.Mods.Data['NikkelM-Zagreus_Journey']
    local native = zjmod and zjmod.HandleThanatosSpawn
    if type(native) ~= "function" then error("HandleThanatosSpawn not found") end
    -- EncounterEventsThanatos runs ThanatosPreSpawnPresentation -> HandleThanatosSpawn ->
    -- ThanatosEncounterStartPresentation. The pre-spawn step hides the HUD
    -- (HideCombatUI "ThanatosIntro"), plays "death is coming" and starts his music; the
    -- matching ShowCombatUI is inside the spawn presentation. Gating only the spawn left the
    -- intro playing with no Thanatos and the HUD hidden for the room (Brice13 10/10). Decide
    -- once per encounter at the pre-spawn step and gate all three on that; a blocked encounter
    -- gets vanilla EncounterAudio instead so the room still has combat music.
    local native_pre = zjmod.ThanatosPreSpawnPresentation
    local native_start = zjmod.ThanatosEncounterStartPresentation
    local function blocked(eventSource)
      if type(eventSource) ~= "table" then
        return not ItemManager.combat_helper_eligible("Thanatos")
      end
      if eventSource.APThanatosBlocked == nil then
        eventSource.APThanatosBlocked = not ItemManager.combat_helper_eligible("Thanatos")
      end
      return eventSource.APThanatosBlocked
    end
    if type(native_pre) == "function" then
      zjmod.ThanatosPreSpawnPresentation = function(eventSource, ...)
        if blocked(eventSource) then
          rom.log.info("[AP] combat_helper_sanity: Thanatos locked, skipped his encounter intro")
          pcall(game.EncounterAudio, eventSource)
          return
        end
        return native_pre(eventSource, ...)
      end
    end
    if type(native_start) == "function" then
      zjmod.ThanatosEncounterStartPresentation = function(eventSource, ...)
        if blocked(eventSource) then return end
        return native_start(eventSource, ...)
      end
    end
    zjmod.HandleThanatosSpawn = function(eventSource, ...)
      if blocked(eventSource) then return end
      return native(eventSource, ...)
    end
  end)
  if ok then
    HELPER_GATE_INSTALLED.thanatos = true
    rom.log.info("[AP] combat_helper_sanity: intercepted NikkelM-Zagreus_Journey.HandleThanatosSpawn")
  elseif not HELPER_GATE_LOGGED_MISSING.thanatos then
    HELPER_GATE_LOGGED_MISSING.thanatos = true
    AP_log_error("[AP] combat_helper_sanity: NikkelM-Zagreus_Journey.HandleThanatosSpawn not found "
      .. "-- Thanatos item gate inactive for now (falls back to native behavior), will retry")
  end
  return HELPER_GATE_INSTALLED.thanatos == true
end
pcall(install_thanatos_combat_helper_gate)

-- Third-party crash guard (zannc-SharedKeepsakePort 1.4.3, keepsake_patroclus.lua:87): its
-- Broken Spearpoint OnSelfDamagedFunction reads triggerArgs.Victim.ObjectId before its own
-- "if not victim then return" check. Vanilla scripted self-damage passes no Victim -- the Vow of
-- Time penalty (MetaUpgrades.lua BiomeSpeedTimerLoop), SacrificeHealth, TempHealth, the surface
-- penalty -- so with the keepsake equipped and the time limit run out the game crashed (Golden
-- Warrior, logs 609/611/612/619: Hades and Zagreus fights under vow_time). Vanilla's own
-- retaliate handlers return on a nil Victim, which is what that check meant to do; do it first.
local function install_patroclus_victim_guard()
  if HELPER_GATE_INSTALLED.patroclus then return true end
  if not dependency_mod_enabled('zannc-SharedKeepsakePort') then return true end
  local skp = modutil and modutil.mod and modutil.mod.Mods and modutil.mod.Mods.Data
    and modutil.mod.Mods.Data['zannc-SharedKeepsakePort']
  local native = skp and skp.PatroclusRetaliate
  if type(native) ~= "function" then return false end -- keepsake not loaded yet (or disabled)
  skp.PatroclusRetaliate = function(unit, args, triggerArgs, ...)
    if type(triggerArgs) ~= "table" or triggerArgs.Victim == nil then return end
    return native(unit, args, triggerArgs, ...)
  end
  HELPER_GATE_INSTALLED.patroclus = true
  rom.log.info("[AP] guarded zannc-SharedKeepsakePort.PatroclusRetaliate against a nil Victim")
  return true
end
pcall(install_patroclus_victim_guard)

-- Called every ~0.5s from the render-loop driver (below) until every enabled helper-randomizer
-- gate has actually installed -- see the header comment above these installers for why a single
-- boot-time attempt isn't reliable (third-party mod init races, or a shared-dispatch abort
-- elsewhere silently skipping a mod's own on_ready this pass).
function retry_helper_gate_installs()
  -- Each call individually pcall'd: these installers are now internally safe (their own
  -- "not found, log once" branches pcall the log call), but keeping each retry independent
  -- here too means one throwing for an unforeseen reason still can't block the other three
  -- from getting their retry this cycle.
  pcall(install_helper_room_sanity_intercept)
  pcall(install_combat_helper_native_gate)
  pcall(install_combat_helper_foreign_gate)
  pcall(install_thanatos_combat_helper_gate)
  pcall(install_patroclus_victim_guard)
  AP_try("ItemManager.apply_combat_helper_random", function() ItemManager.apply_combat_helper_random() end)
end

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
    AP_log_error("[AP] SETTINGS step '" .. name .. "' failed: " .. tostring(err))
  end
end
-- The client's self.seed_name (AP's own per-generation identifier, unrelated to our seed's own
-- options) -- sent FIRST, ahead of SETTINGS, on every sync. Lets the mod tell "still the seed
-- this save was tracking" apart from "this save got reused for a different multiworld": every AP
-- counter in APState (dedup sets, room/score high-water marks, route_progress, AP-granted
-- unlocks) belongs to whichever seed last wrote it, and none of that has any automatic
-- cross-generation reconciliation -- reusing a save across two different multiworlds would
-- otherwise silently leak the old seed's progress into the new one (falsely "pre-completing"
-- locations that share the same systematic name, e.g. every seed's own "Underworld Room 0020").
-- A mismatch runs the exact same wipe the manual RESET debug command does, automatically, before
-- SETTINGS's resync_all_checks tail step (below) gets a chance to replay anything stale. A save
-- that predates this feature (s.last_seed_id nil) is treated as "still fine" on its first sync
-- rather than wiped -- there's nothing to compare against yet, so don't punish an in-progress run.
-- The comparison lives in Bridge.verify_save. The seed is kept for the whole connection, so a save
-- loaded after it arrived (the bridge can connect at the main menu) is still compared: Bridge.update
-- runs the same check once the save exists, and holds queued checks and VICTORY until it has.
Bridge.on("SEED", function(payload)
  if not payload or payload == "" then return end
  Bridge.seed_id = payload
  Bridge.verify_save()
end)
Bridge.on("SETTINGS", function(payload)
  run_settings_step("apply_settings", function() ItemManager.apply_settings(payload) end)
  run_settings_step("cache_settings", function() ItemManager.cache_settings(payload) end) -- persist for next boot (load-time settings apply at the menu)
  run_settings_step("apply_all_vows", function() ItemManager.apply_all_vows() end)         -- enforce vows once settings arrive (if in a save)
  run_settings_step("apply_initial_weapon", function() ItemManager.apply_initial_weapon() end) -- unlock the seed's starting weapon (else non-Staff rolls are unobtainable)
  run_settings_step("apply_surface_start", function() ItemManager.apply_surface_start() end)   -- open the surface if the seed starts it unlocked
  run_settings_step("apply_nightmare_start", function() ItemManager.apply_nightmare_start() end) -- open the Nightmare Chaos Gate if the seed starts it unlocked
  run_settings_step("reassert_route_access", function() ItemManager.reassert_route_access() end) -- re-open Surface/Nightmare doors from persisted route_progress (reboot-gap self-heal)
  run_settings_step("apply_unlocked_modes", function() ItemManager.apply_unlocked_modes() end)   -- force-unlock aspects/pets when set to "unlocked"
  run_settings_step("apply_aspect_base_lock", function() ItemManager.apply_aspect_base_lock() end) -- aspectsanity=randomized/per_aspect: take away the free Aspect of Melinoe (it's an item)
  run_settings_step("apply_incantation_starts", function() ItemManager.apply_incantation_starts() end) -- grant the start-with incantations (QoL systems)
  run_settings_step("apply_conditional_incantation_starts", function() ItemManager.apply_conditional_incantation_starts() end) -- grant the route-/mode-scoped start-with incantations
  run_settings_step("repair_nightmare_keepsake_ids", function() ItemManager.repair_nightmare_keepsake_ids() end) -- progressive_per: move Nightmare keepsake grants recorded under the bare trait name
  run_settings_step("repair_keepsake_levels", function() ItemManager.repair_keepsake_levels() end) -- progressive modes: lift last-step keepsakes from 50 chambers (rank 2.5) to rank 3
  run_settings_step("apply_keepsake_reclaim",function() ItemManager.apply_keepsake_reclaim() end)   -- re-lock pre-owned keepsakes so re-gifting checks
  run_settings_step("apply_keepsake_rack_unlock", function() ItemManager.apply_keepsake_rack_unlock() end) -- open the Crossroads keepsake rack (locked until Nectar gained)
  run_settings_step("apply_combat_helper_random", function() ItemManager.apply_combat_helper_random() end) -- flip zerp-Extended_NPC_Encounters' any-location flags to match the mode
  run_settings_step("resync_all_checks", function() LocationManager.resync_all_checks() end) -- once per save: recover any check lost to a pre-queue disconnect

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
-- Test-only: fire a named trap with no item behind it (Cheats tab, /trap, tools/fake_client.py).
Bridge.on("TRAP", function(payload)
  if Traps then AP_try("Traps.debug_fire", function() Traps.debug_fire(payload) end) end
end)

-- In-game tracker: the client's pages for the "Archipelago" Codex chapter (Journal.lua). The
-- wraps go on the vanilla Codex functions; enable() also covers a mod reload in the middle of a
-- session, where CodexInit has already run for the current map.
Bridge.on("JOURNAL", function(payload) Journal.receive(payload) end)
-- Journal.lua is imported by ready.lua, which a reload in the middle of a session doesn't re-run:
-- a mod updated while the game is open has no Journal until the game restarts.
if Journal then
  AP_try("Journal.install_wraps", Journal.install_wraps)
  AP_try("Journal.enable", Journal.enable)
end

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
-- CHECKEDSCORE pool keys (point_based split pools).
local CHECKEDSCORE_POOL_KEY = {
  underworld = "Underworld", surface = "Surface", nightmare = "Nightmare", dream = "Dream",
}
-- point_based: the client tells us which "<route> Score N" checks the server ALREADY has (a
-- finished player's released/collected checks, an admin !send_location, fresh-save recovery).
-- We REPLACE the runtime set, then run a skip pass on each active route so a check that JUST
-- became checked (a player finished mid-session) advances next_check immediately without
-- waiting for a room clear. Earning a checked one costs ZERO score and re-sends nothing.
-- Empty lists (underworld=;surface=) are allowed.
Bridge.on("CHECKEDSCORE", function(payload)
  -- "combined" is combine_pools' shared route-agnostic "Score N" pool; the rest are the
  -- per-route split_pools ones. Only one kind is in play per seed, but parsing both is
  -- harmless and keeps this in step with whatever the client sends.
  local sets = { Underworld = {}, Surface = {}, Nightmare = {}, Dream = {}, Combined = {} }
  for pair in payload:gmatch("[^;]+") do
    local k, v = pair:match("^(.-)=(.*)$")
    local pool_key = CHECKEDSCORE_POOL_KEY[k] or (k == "combined" and Routes.COMBINED_SCORE_KEY)
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
      for _, route in ipairs({ "Underworld", "Surface", "Nightmare", "Dream" }) do
        if s.score[route] and ItemManager.route_active(route) then
          AP_try("LocationManager.score_skip_pass", function() LocationManager.score_skip_pass(route, s.score[route]) end)
        end
      end
    end
  end
  rom.log.info("[AP] checked score: " .. payload)
end)
Bridge.on("GOAL", function() rom.log.info("[AP] Goal reached — congratulations!") end)
Bridge.on("DEATH", function(payload)
  -- Incoming DeathLink (payload = the sender's slot name). Never applied here -- it can arrive
  -- mid-load or while paused -- ItemManager.flush_pending_deathlink() (render driver) applies it
  -- once the player has control: in a run it kills now, in the Crossroads it plays our own
  -- death-and-respawn. No queue (user decision): while one is already held, or while the player
  -- is already dying, any further DeathLink is dropped.
  local source = (payload ~= nil and payload ~= "") and payload or "Archipelago"
  if ItemManager.pending_deathlink_source or ItemManager.deathlink_in_progress then
    rom.log.info("[AP] DeathLink from " .. source .. " dropped (one is already pending)")
    return
  end
  local state = ItemManager.deathlink_state and ItemManager.deathlink_state()
  if state == "dying" then
    rom.log.info("[AP] DeathLink from " .. source .. " dropped (already dying)")
    return
  end
  ItemManager.pending_deathlink_source = source
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
  rom.log.info("[AP] DeathLink received from " .. source .. " -> pending")
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
      AP_try("ItemManager.apply_help_odds", function() ItemManager.apply_help_odds() end)
      if not (Notifications and Notifications.blocked and Notifications.blocked()) then
        AP_try("ItemManager.reassert_stat_bonuses", function() ItemManager.reassert_stat_bonuses() end)
        AP_try("ItemManager.apply_armor", function() ItemManager.apply_armor() end)
        AP_try("ItemManager.grant_pending_daedalus", function() ItemManager.grant_pending_daedalus() end)
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
      AP_try("ItemManager.apply_all_vows", function() ItemManager.apply_all_vows() end)
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
        elseif ItemManager.first_run_should_be_dream() then
          -- Build the fresh-save run as a Dream Dive (Dream_Intro + IsDreamRun), exactly as the Dream
          -- Comforter does; the StartRoom wrap then LoadMaps Dream_Intro. See
          -- ItemManager.redirect_dream_intro_args. If it can't arm, the StartRoom route-lock kill
          -- bounces the player to the Crossroads, where the (unlocked) Dream bed starts the run.
          local redirected = false
          pcall(function() redirected = ItemManager.redirect_dream_intro_args(args) end)
          if redirected then
            rom.log.info("[AP] dream-start: intro run redirected to Dream_Intro (map swaps at StartRoom)")
          else
            rom.log.info("[AP] dream-start: redirect unavailable; route lock will bounce to Crossroads (Dream bed)")
          end
        end
        -- After any rewrite, so the DeathLink guard tracks the room the run ACTUALLY starts in.
        ItemManager.boot_intro_room_name = args.RoomName
      end
      local ret = base(prevRun, args)
      -- Dream run length, before anything else: CurrentRun.IsDreamRun is already set by here
      -- (StartNewRun OverwriteTableKeys' args.RunOverrides, which is where the Dream Comforter
      -- passes it -- DeathLoopData.lua:7066), and this must land before Dream_Intro's
      -- SelectNextDreamBiome UnthreadedEvent generates the region route. See
      -- ItemManager.apply_dream_run_biome_count.
      AP_try("ItemManager.apply_dream_run_biome_count", function() ItemManager.apply_dream_run_biome_count() end)
      -- Make sure the run starts on an AP-unlocked weapon (Test Run 6 #2): the new hero copies
      -- the previous run's weapon set, so the chosen starting weapon / a now-locked weapon needs
      -- correcting here. No-op if the equipped weapon is already a valid unlocked one.
      AP_try("ItemManager.enforce_equipped_weapon", function() ItemManager.enforce_equipped_weapon() end)
      -- New Filler Checks: apply run-start buffs once the run/hero exist.
      AP_try("ItemManager.apply_progressive_start", function() ItemManager.apply_progressive_start() end)
      AP_try("ItemManager.apply_all_npc_gifts", function() ItemManager.apply_all_npc_gifts() end)
      AP_try("ItemManager.apply_help_odds", function() ItemManager.apply_help_odds() end)
      -- Starting Armor at run start (hero exists) so it's present in the opening room, not a room
      -- late (Test Run 10 #3). Self-guarded (once per run); the StartRoom call below stays as a
      -- fallback for the surface-intro hero rebuild.
      AP_try("ItemManager.apply_armor", function() ItemManager.apply_armor() end)
      return ret
    end)
  end)

  -- Resource-gathering spots are no longer suppressed (2026-10-02 user request; the 2026-08-04
  -- CreateRoom wrap that zeroed room.HarvestPointsAllowed and the four <Tool>PointSuccess rolls
  -- is gone): with no spot in any room, Demeter's Plentiful Forage could never heal. Vanilla's
  -- CreateRoom rolls them again, against requirement tables ItemManager has stripped of their
  -- save-file gates (apply_gather_spot_veteran_gates), and Greatest Gift of Gaia -- auto-granted,
  -- see INCANTATION_START_IDS -- collects them on the way out of the room. The tools stay
  -- unobtainable (UseWeaponShop is blocked below).
  --
  -- Guard: AutoHarvestOnExit (HarvestLogic.lua:291) runs unprotected inside LeaveRoom, and vanilla
  -- only reaches it on a save that already owns every tool. Ours owns none, so an error in there
  -- would strand the player at the exit door. It never waits, so a plain pcall is safe; on
  -- failure the room's spots are simply left uncollected.
  pcall(function()
    modutil.mod.Path.Wrap("AutoHarvestOnExit", function(base)
      AP_try("AutoHarvestOnExit", base)
    end)
  end)

  -- Route locking: if the room's zone isn't unlocked yet, kill Melinoe (no DeathLink). Called from
  -- the StartEncounter wrap (before the fight starts) and again after StartRoom's base(). StartRoom's
  -- base() runs the room's whole first encounter before returning (RoomLogic.lua StartRoom ->
  -- StartEncounter), so a check there alone fired only after that fight was cleared (Brice13 10/12:
  -- a locked Mount Olympus's first room). Kills once per room; returns true when this room is
  -- doomed (killed now or earlier), so the StartEncounter wrap starts no further wave in it.
  -- Uses the same ItemManager.route_zone_unlocked gate as the room-score block (Test Run 8 #1), so a
  -- zone that kills you can never also send a room check for itself. NOT gated on lock_routes --
  -- route_zone_unlocked already handles that internally, and ALSO locks a route the seed excluded
  -- entirely regardless of lock_routes (a Nightmare-only seed's hardcoded Underworld boot intro must
  -- still die here even if lock_routes is off).
  -- EXEMPT a story room borrowed by the zerp-NPCRoomRandomizer dependency (its own
  -- `_PLUGIN.guid .. "CurrentBiome"` marker, see Routes.current()): its whole point is a deliberate,
  -- sanctioned, one-room visit into a foreign zone/route -- possibly one the player hasn't unlocked
  -- yet -- that mod already guarantees the player lands back in their real, unlocked progression the
  -- moment they leave.
  local function kill_if_route_locked(currentRoom)
    if currentRoom and currentRoom._ap_route_lock_killed then return true end
    -- A fresh save's fallback intro bounce (Surface/Nightmare start, redirect unavailable) owns
    -- this room's one death. It used to run after StartRoom's base(), but this check now runs from
    -- StartEncounter INSIDE that base(): on a seed whose Underworld zone 1 is locked, both fired in
    -- F_Opening01 and Kill hit an already-dead hero. Take the intro kill here instead (one-shot, its
    -- own log line, no "Route is Locked" banner), so the later kill_surface_intro/kill_nightmare_intro
    -- calls in the StartRoom wrap find nothing pending.
    local intro = false
    pcall(function()
      intro = ItemManager.kill_surface_intro() or ItemManager.kill_nightmare_intro()
    end)
    if intro then
      if currentRoom then
        currentRoom._ap_route_lock_killed = true
        currentRoom._ap_intro_killed = true   -- StartRoom wrap: skip scoring/grants, as before
      end
      return true
    end
    local killed = false
    pcall(function()
      if not currentRoom then return end
      if currentRoom["zerp-NPCRoomRandomizerCurrentBiome"] then return end
      local route, zone = Routes.current()
      if route and zone and not ItemManager.route_zone_unlocked(route, zone) then
        local s = APState.get()
        local have = (s and s.route_progress[route]) or 0
        local offset = tonumber(ItemManager.settings[route:lower() .. "_offset"]) or 0
        local need = (zone - 1) + offset
        rom.log.info("[AP] LOCKED " .. route .. " z" .. zone
          .. " (have " .. have .. " < need " .. need .. ") - killing Melinoe")
        if game.CurrentRun and game.CurrentRun.Hero then
          currentRoom._ap_route_lock_killed = true
          killed = true
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
    return killed
  end

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
      -- Handles the Surface (RoomName N_Opening01), Nightmare (RoomName RoomOpening) and Dream (RoomName
      -- Dream_Intro) redirects -- all set intro_map_redirect_pending. complete_intro_redirect then
      -- branches: Surface and Dream do a cheap LoadMap; Nightmare replicates ZJ's LeaveRoom fresh-file sequence so its
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
      AP_try("ItemManager.apply_all_vows", function() ItemManager.apply_all_vows(true) end)
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
        AP_try("ItemManager.reassert_stat_bonuses", function() ItemManager.reassert_stat_bonuses() end)
      end
      -- Increased Help Odds: RequirementsData is base-game Lua data, not save data, so a fresh
      -- process reload resets it to default -- reassert every room for the same rejoin reason.
      AP_try("ItemManager.apply_help_odds", function() ItemManager.apply_help_odds() end)
      -- Nightmare Furies: RoomData is base Lua data too (reset on a fresh process), so re-strip the
      -- Alecto/Tisiphone rollout gates every room -- otherwise a mid-run rejoin would restore the
      -- "kill Megaera 4 times first" gate. Self-guards to a no-op when Nightmare isn't installed.
      AP_try("ItemManager.apply_nightmare_fury_unlock", function() ItemManager.apply_nightmare_fury_unlock() end)
      -- Hide and Seek flashback: same "base Lua data resets on a fresh process" reasoning as
      -- the strips above. See ItemManager.apply_flashback_disable.
      AP_try("ItemManager.apply_flashback_disable", function() ItemManager.apply_flashback_disable() end)
      -- Vow of Menace: idempotent save-state bump, safe every room. See
      -- ItemManager.apply_vow_of_menace_unlock.
      AP_try("ItemManager.apply_vow_of_menace_unlock", function() ItemManager.apply_vow_of_menace_unlock() end)
      -- Hades exit door redirect: same "base Lua data resets on a fresh process" reasoning as the
      -- Nightmare Furies reassert just above. Self-guards to a no-op once installed.
      AP_try("ItemManager.install_hades_exit_redirect", function() ItemManager.install_hades_exit_redirect() end)
      -- Nightmare helpers/Thanatos: same "base Lua data resets on a fresh process" reasoning --
      -- re-strip the Sisyphus/Eurydice/Patroclus story-room gates and Thanatos's rollout gates
      -- every room. Self-guards to a no-op when Nightmare isn't installed.
      AP_try("ItemManager.apply_nightmare_helpers_unlock", function() ItemManager.apply_nightmare_helpers_unlock() end)
      -- Extended NPC encounters (combat-assist randomizer): re-strip the lifetime intro gates
      -- from zerp-Extended's added encounters every room, same reasoning as the strips above.
      -- Self-guards to a no-op when the dependency isn't initialized.
      AP_try("ItemManager.apply_extended_npc_unlock", function() ItemManager.apply_extended_npc_unlock() end)
      -- Boss ingredient drops -> Nectar: same "base Lua data resets on a fresh-process rejoin"
      -- reasoning as the strips above. See ItemManager.apply_boss_drops_as_nectar.
      AP_try("ItemManager.apply_boss_drops_as_nectar", function() ItemManager.apply_boss_drops_as_nectar() end)
      -- Nightmare boss resource drops -> Nectar: same reasoning, for Zagreus' Journey's own zone
      -- bosses. Self-guards to a no-op when Nightmare isn't installed. See
      -- ItemManager.apply_nightmare_boss_drops_as_nectar.
      AP_try("ItemManager.apply_nightmare_boss_drops_as_nectar", function() ItemManager.apply_nightmare_boss_drops_as_nectar() end)
      -- HadesPreDamageBoon ValidRooms widen (Chronos/Typhon/Styx-Hades). Same reset-on-rejoin
      -- reasoning. See ItemManager.apply_hades_predamage_dream_bosses.
      AP_try("ItemManager.apply_hades_predamage_dream_bosses", function() ItemManager.apply_hades_predamage_dream_bosses() end)
      -- Nightmare Chaos Gate: seal the run-start door whenever the route isn't AP-unlocked (and
      -- reopen it once it is). Applied per-room because the gate obstacle is re-spawned on each
      -- pre-run hub entry; only actually does anything in the hub where the gate exists. Self-
      -- guards to a no-op when Nightmare isn't installed. See ItemManager.apply_nightmare_gate_lock.
      AP_try("ItemManager.apply_nightmare_gate_lock", function() ItemManager.apply_nightmare_gate_lock() end)
      -- Route access (Surface door / Nightmare gate): re-open from the persisted route_progress
      -- counter every room, so a Progressive Surface/Nightmare received across a reboot gap (whose
      -- one-time world-upgrade grant never re-fires) self-heals instead of staying locked forever.
      -- Pass currentRoom through so a live grant while standing in Hub_PreRun also refreshes the
      -- room's already-spawned door obstacle (see ItemManager.refresh_surface_door). Idempotent;
      -- no-op until the route has been progressed. See reassert_route_access.
      AP_try("ItemManager.reassert_route_access", function() ItemManager.reassert_route_access(currentRoom) end)
      -- Starting Aspect (aspectsanity randomized/per_aspect modes): must run here, not from the
      -- SETTINGS handler -- see ItemManager.apply_initial_weapon's comment for why applying it
      -- before the run/hero exist crashes the game (MapState nil during vanilla's first-room
      -- hero setup). Idempotent, so safe to reassert every room.
      AP_try("ItemManager.reassert_starting_aspect", function() ItemManager.reassert_starting_aspect() end)
      -- aspectsanity=randomized/per_aspect: weapons don't get their Aspect of Melinoe for free (it's
      -- one of the shuffled/per-aspect items in both modes). ScreenData.WeaponUpgradeScreen.FreeUnlocks
      -- is base Lua data, so a fresh process restores it -- re-strip every room, same as
      -- apply_help_odds above. Runs AFTER reassert_starting_aspect so a seed whose starting pick IS
      -- the Aspect of Melinoe has already been recorded as earned and is never stripped.
      AP_try("ItemManager.apply_aspect_base_lock", function() ItemManager.apply_aspect_base_lock() end)
      -- Surface-start seeds: the engine forces an Underworld intro, so bounce off it by instantly
      -- killing Melinoe here (no DeathLink) -> the game's first-death flow lands her in the Crossroads,
      -- where she takes the Surface door. One-shot + self-guarded, so it only fires on that intro room.
      -- If we kill, RETURN NOW: this room is doomed, so skip scoring it (else the intro room counts as
      -- cleared and sends a check before she dies) and skip the per-room grants.
      -- The intro bounce usually fires earlier, from StartEncounter inside base()
      -- (kill_if_route_locked); this room is just as doomed then.
      if currentRoom and currentRoom._ap_intro_killed then return ret end
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
        AP_try("ItemManager.apply_armor", function() ItemManager.apply_armor() end)
        AP_try("ItemManager.grant_pending_daedalus", function() ItemManager.grant_pending_daedalus() end)
        -- Surface curse: vanilla's own grant is conditional on already having met Apollo (see
        -- ItemManager.enforce_surface_curse) and silently never fires for a surface_start seed
        -- otherwise -- enforce it directly on every Surface room entry instead.
        AP_try("ItemManager.enforce_surface_curse", function() ItemManager.enforce_surface_curse() end)
      end
      -- Boss "Met": fire when we actually enter the boss arena (this room), not on reaching the
      -- biome (Test Run 5 #7). on_room_started checks EncounterType == "Boss" internally.
      AP_try("LocationManager.on_room_started", function() LocationManager.on_room_started(currentRoom) end)
      -- Score every non-combat room on ENTER (reward/shop rooms per Test Run 6 #6; pure
      -- transition/Intro rooms too as of 8/4 -- see room_has_combat's comment). They have no
      -- enemies to clear, so there's no clear moment to hook. Combat rooms score
      -- per-encounter via score_encounter (StartEncounter/SpawnRoomReward wraps) instead;
      -- score_room dedups per room (room._ap_scored).
      AP_try("LocationManager.score_room", function() LocationManager.score_room(currentRoom) end)
      -- Overlay "Room ##": now driven by the AP room-check logic itself (LocationManager.
      -- score_room/score_encounter), not a separate literal room-progress counter. This just
      -- clears it the moment the player is back in the Crossroads hub (see
      -- LocationManager.clear_room_overlay_on_hub's comment).
      AP_try("LocationManager.clear_room_overlay_on_hub", function() LocationManager.clear_room_overlay_on_hub(currentRoom) end)
      -- Zagreus Vanilla/Empowered: spawn his contract in this room if it's a real shop and he
      -- hasn't been fought yet this run. See ItemManager.apply_zagreus_contract_everywhere.
      AP_try("ItemManager.apply_zagreus_contract_everywhere", function() ItemManager.apply_zagreus_contract_everywhere(currentRoom) end)
      -- Route locking (rooms with no encounter; combat rooms were already handled at
      -- StartEncounter, see kill_if_route_locked).
      kill_if_route_locked(currentRoom)
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
      AP_try("ItemManager.apply_help_odds", function() ItemManager.apply_help_odds() end)
      -- Boss ingredient drops -> Nectar: rejoin path (see StartRoom wrap for the full reasoning).
      AP_try("ItemManager.apply_boss_drops_as_nectar", function() ItemManager.apply_boss_drops_as_nectar() end)
      -- Nightmare boss resource drops -> Nectar: rejoin path (see StartRoom wrap above).
      AP_try("ItemManager.apply_nightmare_boss_drops_as_nectar", function() ItemManager.apply_nightmare_boss_drops_as_nectar() end)
      -- HadesPreDamageBoon ValidRooms widen: rejoin path (see StartRoom wrap above).
      AP_try("ItemManager.apply_hades_predamage_dream_bosses", function() ItemManager.apply_hades_predamage_dream_bosses() end)
      -- Nightmare Chaos Gate: re-seal on rejoin too -- quitting to desktop and resuming while
      -- standing in the pre-run hub takes this path, not StartRoom, so without it a rejoined hub
      -- would show the gate open. Self-guards / no-op away from the gate. See StartRoom hook above.
      AP_try("ItemManager.apply_nightmare_gate_lock", function() ItemManager.apply_nightmare_gate_lock() end)
      -- Route access: re-open the Surface door / Nightmare gate from persisted route_progress on the
      -- rejoin path too (resuming while standing in the hub takes this path, not StartRoom). Mirrors
      -- the StartRoom reassert (currentRoom passed through for the live door-obstacle refresh too);
      -- idempotent / no-op until the route has been progressed.
      AP_try("ItemManager.reassert_route_access", function() ItemManager.reassert_route_access(currentRoom) end)
      -- Same Trait Tray (boon inventory) guard as the StartRoom/UnlockRoomExits hooks -- these all
      -- call AddTraitToHero, which softlocks the tray if it's open when they land.
      if not (Notifications and Notifications.blocked and Notifications.blocked()) then
        AP_try("ItemManager.reassert_stat_bonuses", function() ItemManager.reassert_stat_bonuses() end)
        AP_try("ItemManager.apply_armor", function() ItemManager.apply_armor() end)
        -- Daedalus hammers: re-place any not-yet-spawned hammers for this run. Needed here too --
        -- without this hook, resuming into an already-unlocked room skipped grant_pending_daedalus
        -- entirely, which is why hammers appeared to "reset" on rejoin (never re-placed, not actually
        -- removed).
        AP_try("ItemManager.grant_pending_daedalus", function() ItemManager.grant_pending_daedalus() end)
        -- Surface curse: same reassert as the StartRoom hook above -- see
        -- ItemManager.enforce_surface_curse.
        AP_try("ItemManager.enforce_surface_curse", function() ItemManager.enforce_surface_curse() end)
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
        AP_try("ItemManager.block_run_door", function() ItemManager.block_run_door(usee, args) end)
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
      AP_try("ItemManager.apply_nightmare_gate_lock", function() ItemManager.apply_nightmare_gate_lock() end)
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
        AP_try("ItemManager.update_nightmare_gate", function() ItemManager.update_nightmare_gate(obstacle) end)
      end
      -- Cauldron (GhostAdmin): force vanilla's own "not open yet" presentation permanently.
      -- Identity check lives inside the function itself; no-ops for every other obstacle.
      AP_try("ItemManager.apply_cauldron_locked_visual", function() ItemManager.apply_cauldron_locked_visual(obstacle) end)
      return ret
    end)
  end)

  -- Nightmare Chaos Gate lock (opt-in third-party "Zagreus' Journey" route). Separate from the
  -- UseEscapeDoor wrap above -- the Chaos Gate isn't a vanilla run-start door, it's that mod's
  -- own obstacle. We seal it at the obstacle level (the same way the Vow of Void seals a run door
  -- over-Grasp), applied per-room in the StartRoom / RestoreUnlockRoomExits hooks once the gate
  -- obstacle actually exists. This boot call is just a best-effort first pass (no-op until we're
  -- in the pre-run hub); see ItemManager.apply_nightmare_gate_lock.
  AP_try("ItemManager.apply_nightmare_gate_lock", function() ItemManager.apply_nightmare_gate_lock() end)
  -- Nightmare run-clear detection, second path (see ItemManager.handle_nightmare_run_cleared for
  -- why this exists alongside the OpenRunClearScreen wrap further down).
  AP_try("ItemManager.install_nightmare_run_clear_hook", function() ItemManager.install_nightmare_run_clear_hook() end)
  -- Hades exit door: redirect D_Boss01's exit straight to the Crossroads instead of ZJ's own
  -- post-Hades Surface epilogue (see ItemManager.install_hades_exit_redirect). Also retried
  -- per-frame (reload.lua's render driver) and per-room below, same reasoning as the run-clear
  -- hook and Nightmare Furies just above/below -- game.RoomData is base Lua data that resets on a
  -- fresh-process rejoin.
  AP_try("ItemManager.install_hades_exit_redirect", function() ItemManager.install_hades_exit_redirect() end)
  -- Nightmare Furies: make Alecto + Tisiphone eligible as the Tartarus boss from run 1, instead of
  -- gating them behind 4 lifetime Megaera kills the way Zagreus' Journey ports Nightmare. Runs here
  -- (after ZJ's room data is loaded) AND per-room in the StartRoom wrap, since the boss-room
  -- eligibility is evaluated when the prior room's exits are chosen -- reasserting each room means
  -- a fresh-process rejoin (which reloads ZJ's static room data) can never restore the gate.
  AP_try("ItemManager.apply_nightmare_fury_unlock", function() ItemManager.apply_nightmare_fury_unlock() end)
  -- Extended NPC encounters: strip the lifetime intro-completed gates from the combat-assist
  -- randomizer's added encounters (zerp-Extended runs its init before us, so its
  -- NewNPCEncounters list + EncounterData entries exist by now). Also reasserted per-room in
  -- the StartRoom wrap. See ItemManager.apply_extended_npc_unlock.
  AP_try("ItemManager.apply_extended_npc_unlock", function() ItemManager.apply_extended_npc_unlock() end)
  -- Nightmare helpers/Thanatos: same reasoning, same dual boot+per-room reassertion. See
  -- ItemManager.apply_nightmare_helpers_unlock for the full field-by-field breakdown.
  AP_try("ItemManager.apply_nightmare_helpers_unlock", function() ItemManager.apply_nightmare_helpers_unlock() end)
  -- Boss ingredient drops -> Nectar: same "base Lua data resets on a fresh-process rejoin"
  -- reasoning as the strips above. See ItemManager.apply_boss_drops_as_nectar.
  AP_try("ItemManager.apply_boss_drops_as_nectar", function() ItemManager.apply_boss_drops_as_nectar() end)
  -- Nightmare boss resource drops -> Nectar: same reasoning, for Zagreus' Journey's own zone
  -- bosses. Self-guards to a no-op when Nightmare isn't installed. See
  -- ItemManager.apply_nightmare_boss_drops_as_nectar.
  AP_try("ItemManager.apply_nightmare_boss_drops_as_nectar", function() ItemManager.apply_nightmare_boss_drops_as_nectar() end)
  -- HadesPreDamageBoon ValidRooms widen: boot path, same reasoning. See
  -- ItemManager.apply_hades_predamage_dream_bosses.
  AP_try("ItemManager.apply_hades_predamage_dream_bosses", function() ItemManager.apply_hades_predamage_dream_bosses() end)

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

  -- petsanity progressive/progressive_per: bonds come from Progressive Familiar item(s), so
  -- block the bond shop's purchases. Randomized leaves bonds alone (only the unlock itself
  -- is gated).
  pcall(function()
    modutil.mod.Path.Wrap("HandleFamiliarShopPurchase", function(base, screen, button)
      local mode = ItemManager.setting_mode("petsanity")
      if mode == 2 or mode == 3 then
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
      -- keepsake_items_only: no check to send. The CanReceiveGift wrap (below) only lets a
      -- giver be gifted once their keepsake item is here, so this is normally the award of a
      -- keepsake already owned -- nothing to show. If a gift got through without the item,
      -- block_keepsake_award keeps the keepsake locked (it no-ops once AP-granted).
      if ItemManager.keepsake_items_only() and ItemManager.MANAGED_KEEPSAKES[giftName] then
        ItemManager.block_keepsake_award(giftName)
        return
      end
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
        -- Belt-and-suspenders: the CanReceiveGift wrap (below) is supposed to stop a
        -- second gift to this NPC once its check is sent, but it can only do that if it
        -- can resolve the unit back to the right GiftData trait (see that wrap's comment
        -- for the Artemis field-unit case where it couldn't). If we get here again for an
        -- already-sent trait, don't resend/re-log -- just keep it re-locked and skip.
        local already_sent_s = check and APState.get()
        if check and already_sent_s and already_sent_s.keepsake_check_sent[giftName] then
          ItemManager.block_keepsake_award(giftName)
          return
        end
        if check then
          pcall(function() Bridge.send_check(check) end)
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

  -- Suppress the "Divination of the Elements" first-boon pop-up (2026-08-04 user request).
  -- Confirmed in the installed game, UpgradeChoiceLogic.lua: the first time a boon offer
  -- includes elemental-eligible loot, `if not GameState.Flags.SeenElementalIcons and ... then
  -- thread(ElementalIconsUnlockedPresentation, ...) OpenElementalPromptScreen(screen)
  -- GameState.Flags.SeenElementalIcons = true end` -- OpenElementalPromptScreen
  -- (ElementalPromptScreenLogic.lua) is the actual modal ("ElementalPrompt" title/description).
  -- Wrap just that and skip it -- same "wrap + early-return, skip the popup" idiom as the
  -- keepsake-gift popup above. GameState.Flags.SeenElementalIcons still gets set by the CALLER
  -- regardless of what this function does, so the small per-icon "unlocked" flourish
  -- (ElementalIconsUnlockedPresentation) still plays once and the flag still correctly prevents
  -- any future retrigger -- only the modal itself is suppressed.
  pcall(function()
    modutil.mod.Path.Wrap("OpenElementalPromptScreen", function(base, parentScreen)
      return
    end)
  end)

  -- keepsakesanity: once an NPC's keepsake check has been sent, block re-gifting them
  -- (no point spending more Nectar, and it makes it clear who you've already done).
  --
  -- Player report 2026-08-03: Artemis's keepsake check never completed -- gifting her
  -- always played the fresh "first gift" dialogue and was giftable again next time. Root
  -- cause: this lookup used target.Name directly, but vanilla's own GiveGift resolves the
  -- GiftData key via GetGenusName(target) = target.GenusName or target.Name (InteractLogic.
  -- lua). Artemis's field/helper-encounter unit (NPCData_Artemis.lua NPC_Artemis_Field_01,
  -- CanReceiveGift = true) has Name = "NPC_Artemis_Field_01" but GenusName =
  -- "NPC_Artemis_01" -- the actual GiftData/KeepsakeData key. Looking her up by raw .Name
  -- missed game.GiftData entirely (gd = nil), so `trait` was never resolved, this block
  -- never engaged, and CanReceiveGift fell through to vanilla (which only checks the
  -- CURRENT RUN's GiftRecord, not whether the check was ever sent) -- letting the player
  -- regift field-Artemis every run forever, replaying ArtemisGift01 each time (its
  -- TextLinesRecord flag gets cleared right back by block_keepsake_award below) and
  -- resending the same check without end. GenusName first matches vanilla; GiftName stays
  -- as a fallback for GiveGiftDirectly's own (different) name resolution.
  pcall(function()
    modutil.mod.Path.Wrap("CanReceiveGift", function(base, target)
      if ItemManager.setting_mode("keepsakesanity") ~= 0 and target then
        local name = target.GenusName or target.GiftName or target.Name
        local gd = name and game.GiftData and game.GiftData[name]
        local trait = gd and gd[1] and gd[1].Gift
        if trait and ItemManager.MANAGED_KEEPSAKES[trait] then
          local s = APState.get()
          if s and s.keepsake_check_sent[trait] then
            return false
          end
          -- keepsake_items_only: there's no check to earn, and the first gift would only
          -- replay (block_keepsake_award clears its text line) and eat Nectar for nothing --
          -- so the giver takes no gifts until their keepsake item arrives.
          if s and ItemManager.keepsake_items_only() and not s.keepsake_ap_granted[trait] then
            return false
          end
        end
      end
      return base(target)
    end)
  end)

  -- Dream Dive: keepsake givers stay giftable (user request 2026-09-30). Vanilla mutes every
  -- mid-run giver for a dive with a SilenceForDreamRun setup event (DreamRunLogic.lua) -- the
  -- boon gods, Chaos and Hermes through LootData.lua's BaseLoot, Selene, Charon and the
  -- story-room / combat-assist NPCs through their own data -- and besides the muting, that event
  -- sets CanReceiveGift = false, so a dive could never earn a "<NPC> Keepsake" check (with Dream
  -- the only route, 23 of them). Hand back whatever the unit had before the event: the gift then
  -- runs exactly as it does outside a dive (GiveGift -> PlayerReceivedGiftPresentation above),
  -- with the same once-a-run limit and the same "<NPC>Gift01" requirements. A unit the event
  -- also makes untouchable (BlockInteract: in-person Hermes, Cerberus, Bouldy -- none of them a
  -- keepsake check) is left as vanilla has it.
  --
  -- One of those requirements is having used the giver before (RequireUseToGift, plus
  -- "<NPC>Gift01"'s own PathTrue GameState.UseRecord.<unit>). A dive still records that for
  -- nearly everyone: taking a boon does (HandleLootPickup -- the gods, Artemis, Athena,
  -- Dionysus), and so does talking to an NPC that has a line to play (UseNPC -- Charon, and the
  -- story rooms' forced "<NPC>DreamRun" line). Heracles is the exception: HeraclesPostCombat
  -- skips CheckAvailableTextLines in a dive, UseNPC returns before RecordUse when there's no
  -- line to play, and he walks off 1.5s after the fight unless he can already take a gift. So
  -- meeting him in a dive counts as that first use.
  pcall(function()
    local MEET_COUNTS_AS_USE = { NPC_Heracles_01 = true }
    modutil.mod.Path.Wrap("SilenceForDreamRun", function(base, source, args, ...)
      local could_gift = source and source.CanReceiveGift
      local ret = base(source, args, ...)
      if could_gift and not (args and args.BlockInteract) then
        source.CanReceiveGift = could_gift
        local gs = game.GameState
        if MEET_COUNTS_AS_USE[source.Name] and gs and gs.UseRecord
            and gs.UseRecord[source.Name] == nil then
          gs.UseRecord[source.Name] = 1
        end
      end
      return ret
    end)
  end)

  -- keepsakesanity progressive/progressive_per: keepsake levels come from Progressive
  -- Keepsake item(s), so block normal leveling.
  pcall(function()
    modutil.mod.Path.Wrap("AdvanceKeepsake", function(base, fromTrait)
      local mode = ItemManager.setting_mode("keepsakesanity")
      if mode == 2 or mode == 3 then
        return
      end
      return base(fromTrait)
    end)
  end)

  -- GodSanity: a god keepsake's ForceBoonName must not force a locked god's boon. See
  -- ItemManager.hide_locked_force_boons. Restored even if base throws.
  pcall(function()
    modutil.mod.Path.Wrap("SetupRoomReward", function(base, ...)
      local hidden = ItemManager.hide_locked_force_boons()
      if not hidden then return base(...) end
      local ok, err = pcall(base, ...)
      ItemManager.restore_force_boons(hidden)
      if not ok then error(err, 0) end
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

  -- Grasp is item-only: block the altar's vanilla "raise Grasp" purchase. Besides spending
  -- resources for nothing, its presentation (UpgradeMetaUpgradeLimitPresentation) indexes
  -- ScreenData.MetaUpgradeCardLayout.BonePositions[i] from our item-driven max upward, which
  -- is nil past 30 and crashes the screen. CanIncrease... is the game's only "can buy" test
  -- (screen-open popup, upgrade-available frame, RequireAffordableMetaUpgrade), so false
  -- there hides the purchase everywhere; the IncreaseMetaUpgradeCardLimit wrap is the backstop.
  pcall(function()
    modutil.mod.Path.Wrap("CanIncreaseMetaUpgradeCardLimit", function(base, ...)
      return false
    end)
  end)
  pcall(function()
    modutil.mod.Path.Wrap("IncreaseMetaUpgradeCardLimit", function(base, screen, button)
      rom.log.info("[AP] Grasp limit purchase blocked (Grasp comes from items)")
      return
    end)
  end)

  -- reverse_rivals: the Vow of Rivals (BossDifficultyShrineUpgrade) normally strengthens
  -- the FIRST N bosses (active while rank >= CurrentRun.EnteredBiomes, per
  -- ShrineLogic.IsBossDifficultyShrineUpgradeActive). With reverse_rivals on, strengthen
  -- the LAST N instead (active while EnteredBiomes >= total - rank + 1). Every route is 4
  -- biomes to the final boss; a Dream dive is this seed's region count (Routes.zone_count, the
  -- value sync_dream_region_count hands DreamDiveTweaks -- not GameData.FullRunBiomeCount, which
  -- DreamDiveTweaks 1.13.1 reports as 999 once endless mode starts).
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
      if game.CurrentRun and game.CurrentRun.IsDreamRun then total = Routes.zone_count("Dream") end
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
  --     true, so the obelisk appears from the start (vow changes are bounded below).
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

  -- Chaos Gates in every biome. IsSecretDoorEligible (RoomLogic.lua) is asked once per room by
  -- HandleSecretSpawns, and only when the map has a SecretPoint to put a gate on. Vanilla's own
  -- answer always stands when it's yes; a no gets a second opinion from
  -- ItemManager.chaos_gate_anywhere, which covers the biomes vanilla never rolls a gate in.
  pcall(function()
    modutil.mod.Path.Wrap("IsSecretDoorEligible", function(base, currentRun, currentRoom)
      if base(currentRun, currentRoom) then return true end
      local extra = false
      AP_try("ItemManager.chaos_gate_anywhere", function()
        extra = ItemManager.chaos_gate_anywhere(currentRun, currentRoom)
      end)
      return extra == true
    end)
  end)

  -- Suppress the vanilla first-visit Oath of the Unseen camera cutscene (HubPresentation.lua's
  -- ShrineUnlockedFirstPresentation): it blocks input, pans the camera onto the obelisk for
  -- ~7s, then pans back. Forcing the Oath unlocked from run 1 above (IsGameStateEligible) makes
  -- players walk into this unusually early, but it's worth suppressing regardless of when it
  -- fires -- the player should stay in control walking into the hub. Skip base() entirely: no
  -- input block, no camera pan, no letterbox.
  pcall(function()
    modutil.mod.Path.Wrap("ShrineUnlockedFirstPresentation", function(base, room, args)
      return
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
  -- Layer (1) keeps a "Boon" door from being rolled out of a store while zero gods are unlocked
  -- (see godsanity_boon_target), so layer (2) is normally never asked to fill a Boon door with
  -- truly nothing eligible. Layer (1c) (the ChooseRoomReward wrap) is the one reroll fallback, for
  -- Boons that arrive some other way (see its comment).
  --   onions (mode 1) skips layer (1) and keeps the native store: its Boon doors roll at the
  -- vanilla rate, and layer (1e) (also in the ChooseRoomReward wrap) turns the ones that would
  -- have gone to a locked god into the native RoomRewardConsolationPrize (the Onion). Until
  -- 2026-10-04 it ran through layer (1) like no_waste_same_odds and nothing ever made an Onion.
  --
  -- GetRewardStoreData is the single function both run-start init (InitializeRewardStores) AND
  -- every mid-run refill (once a store's array empties, ChooseRoomReward re-fetches a fresh
  -- copy) call to get that array. Applies to EVERY store: scale_boon_entries returns a store
  -- with no "Boon" entries untouched. This used to be scoped to RunProgress/HubRewards only, but
  -- two more native stores carry Boon entries -- TartarusRewards (RoomDataI BaseI, every
  -- Tartarus room: 3 of 9) and TyphonBossRewards (RoomDataQ Q_BaseMiniBoss, every Summit
  -- miniboss: 2 of 6). Left unthinned, a Q_MiniBoss door rolled "Boon" with 0 gods unlocked and
  -- SetupRoomReward's ChooseLoot() came back nil -> RewardLogic.lua:258 "attempt to index local
  -- 'lootData'" crash (confirmed live 2026-09-27, Dream run starting in the Summit).
  -- See ItemManager.scale_boon_entries / godsanity_boon_target for the per-mode target
  -- count (no_waste_same_odds: full native count once >=1 god is unlocked, 0 before
  -- that; no_waste_less_odds: an eased-in curve).
  pcall(function()
    modutil.mod.Path.Wrap("GetRewardStoreData", function(base, storeName)
      local storeData = base(storeName)
      if not ItemManager.have_settings() then return storeData end
      local mode = ItemManager.setting_mode("godsanity")
      if mode == 0 or mode == 1 then return storeData end
      if type(storeData) ~= "table" then return storeData end
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
  -- GodSanity, layer (1c): last-resort guard. If a door still comes out "Boon" while NO god is
  -- eligible at all, SetupRoomReward's ChooseLoot() returns nil and vanilla crashes indexing it
  -- (RewardLogic.lua:258). Layer (1) makes that impossible for a store's own fresh draws, but a
  -- Boon can still arrive another way: a live store built before layer (1) covered it (a save
  -- from an older build -- the 2026-09-27 TyphonBossRewards crash), or a native path that skips
  -- the store entirely (ForcedReward / ForcedFirstReward / DeferReward /
  -- PersistentExitDoorRewards). Re-choose once with "Boon" made ineligible and the forced paths
  -- skipped, restoring the room fields the first pick wrote. If that retry fails too, fall back to
  -- vanilla's own final fallback reward (RoomRewardHealDrop).
  -- GodSanity, layer (1e), onions only: a door that comes out "Boon" becomes the Onion when its
  -- god would have been a locked one. A god already fixed on the room (ForcedReward's LootName,
  -- a bounty's ForceLootName) is judged as itself; otherwise ItemManager.godsanity_onion_roll
  -- rolls it, excluding the gods on this room's other Boon doors like SetupRoomReward does.
  local ONION_REWARD = "RoomRewardConsolationPrize"
  local function onion_for_locked_god(room, previouslyChosenRewards)
    if room.ForceLootName ~= nil then
      return not ItemManager.god_eligible(room.ForceLootName)
    end
    local exclude = {}
    for _, data in pairs(previouslyChosenRewards or {}) do
      if data.RewardType == "Boon" then table.insert(exclude, data.ForceLootName) end
    end
    return ItemManager.godsanity_onion_roll(exclude)
  end
  local REWARD_FIELDS_SET_BY_CHOOSE = { "Reward", "ForceLootName", "ForcedReward", "RewardOverrides" }
  local function no_god_boon_possible()
    local ok, names = pcall(game.GetEligibleLootNames)
    return ok and type(names) == "table" and #names == 0
  end
  -- GodSanity, layer (1d): padding slots (scale_boon_entries, APPadding) carry AllowDuplicates so
  -- a many-exit hub can fill every door, but that also let an ordinary room put the same reward
  -- on two doors, which vanilla never does. The IsRoomRewardEligible wrap holds a padding slot to
  -- vanilla's own one-per-name dedup; choose_distinct_first lifts that for one ChooseRoomReward
  -- call only when neither the live store nor a refill of it could give the door a distinct
  -- reward. "Boon" is skipped when judging the refill: a thinned refill may add none.
  pcall(function()
    modutil.mod.Path.Wrap("IsRoomRewardEligible", function(base, run, room, reward, previouslyChosenRewards, args)
      if type(reward) == "table" and reward.APPadding and previouslyChosenRewards ~= nil
          and not (type(args) == "table" and args.APPadDuplicatesOK) then
        for _, prevReward in pairs(previouslyChosenRewards) do
          if (prevReward.CheckDuplicatesName or prevReward.RewardType) == reward.Name then
            return false
          end
        end
      end
      return base(run, room, reward, previouslyChosenRewards, args)
    end)
  end)
  local function distinct_reward_available(room, rewardStoreName, previouslyChosenRewards, args)
    local live = game.CurrentRun and game.CurrentRun.RewardStores and game.CurrentRun.RewardStores[rewardStoreName]
    for _, reward in ipairs(live or {}) do
      if game.IsRoomRewardEligible(game.CurrentRun, room, reward, previouslyChosenRewards, args) then
        return true
      end
    end
    for _, reward in ipairs((game.RewardStoreData or {})[rewardStoreName] or {}) do
      if reward.Name ~= "Boon"
          and game.IsRoomRewardEligible(game.CurrentRun, room, reward, previouslyChosenRewards, args) then
        return true
      end
    end
    return false
  end
  local function choose_distinct_first(base, run, room, rewardStoreName, previouslyChosenRewards, args)
    if previouslyChosenRewards == nil or ItemManager.setting_mode("godsanity") == 0 then
      return base(run, room, rewardStoreName, previouslyChosenRewards, args)
    end
    args = args or {}
    local ok, distinct = pcall(distinct_reward_available, room, rewardStoreName, previouslyChosenRewards, args)
    if not ok or distinct then
      return base(run, room, rewardStoreName, previouslyChosenRewards, args)
    end
    args.APPadDuplicatesOK = true
    local ok2, result = pcall(base, run, room, rewardStoreName, previouslyChosenRewards, args)
    args.APPadDuplicatesOK = nil
    if not ok2 then error(result, 0) end
    return result
  end
  pcall(function()
    modutil.mod.Path.Wrap("ChooseRoomReward", function(vanilla, run, room, rewardStoreName, previouslyChosenRewards, args)
      if not ItemManager.have_settings() or type(room) ~= "table" then
        return vanilla(run, room, rewardStoreName, previouslyChosenRewards, args)
      end
      local function base(r, rm, store, prev, a)
        return choose_distinct_first(vanilla, r, rm, store, prev, a)
      end
      local before = {}
      for _, k in ipairs(REWARD_FIELDS_SET_BY_CHOOSE) do before[k] = room[k] end

      local result
      local handled = false
      if room.EligibleRewards and #room.EligibleRewards == 1 and room.EligibleRewards[1] == "Boon" then
        local mode = ItemManager.setting_mode("godsanity")
        if mode ~= 0 then
          local ok, allowed = pcall(ItemManager.godsanity_boon_roll_allowed, mode)
          if ok and not allowed then
            local saved = room.EligibleRewards
            room.EligibleRewards = nil
            -- pcall so a throw inside can't leave the miniboss room's Boon-only filter cleared.
            local okChoose, chosen = pcall(base, run, room, rewardStoreName, previouslyChosenRewards, args)
            room.EligibleRewards = saved
            if not okChoose then error(chosen, 0) end
            result = chosen
            handled = true
          end
        end
      end
      if not handled then
        result = base(run, room, rewardStoreName, previouslyChosenRewards, args)
      end

      -- Onion Trap: the next door to roll a Boon gets an Onion instead (Traps.take_onion spends
      -- one). After the GodSanity roll, so a door that mode already turned costs no trap.
      local okOnion, onion, trapOnion = false, false, false
      if result == "Boon" then
        if ItemManager.setting_mode("godsanity") == 1 then
          okOnion, onion = pcall(onion_for_locked_god, room, previouslyChosenRewards)
        end
        if not (okOnion and onion) and Traps and Traps.take_onion then
          okOnion, onion = pcall(Traps.take_onion)
          trapOnion = okOnion and onion
        end
      end
      if result == "Boon" then
        if okOnion and onion then
          rom.log.info("[AP] " .. (trapOnion and "Onion Trap" or "GodSanity onions") .. ": '" .. tostring(room.Name)
            .. "' Boon door (" .. tostring(room.ForceLootName or "rolled") .. ") -> " .. ONION_REWARD)
          room.Reward = { Name = ONION_REWARD }
          room.ForceLootName = nil
          room.RewardOverrides = nil
          room.ForcedReward = before.ForcedReward
          return ONION_REWARD
        end
      end

      if result ~= "Boon" or not no_god_boon_possible() then return result end

      for _, k in ipairs(REWARD_FIELDS_SET_BY_CHOOSE) do room[k] = before[k] end
      local retry_args = {}
      if type(args) == "table" then
        for k, v in pairs(args) do retry_args[k] = v end
      end
      retry_args.IgnoreForcedReward = true
      retry_args.NumStoreRefills = nil
      local saved_eligible, saved_ineligible = room.EligibleRewards, room.IneligibleRewards
      local ineligible = { "Boon" }
      if type(saved_ineligible) == "table" then
        for _, n in ipairs(saved_ineligible) do table.insert(ineligible, n) end
      end
      room.EligibleRewards = nil
      room.IneligibleRewards = ineligible
      local ok, retry = pcall(base, run, room, rewardStoreName, previouslyChosenRewards, retry_args)
      room.EligibleRewards = saved_eligible
      room.IneligibleRewards = saved_ineligible
      local note = ""
      if not ok or retry == nil or retry == "Boon" then
        note = ok and (" (retry gave " .. tostring(retry) .. ")") or (" (retry errored: " .. tostring(retry) .. ")")
        for _, k in ipairs(REWARD_FIELDS_SET_BY_CHOOSE) do room[k] = before[k] end
        retry = "RoomRewardHealDrop"
        room.Reward = { Name = retry }
      end
      rom.log.info("[AP] GodSanity: '" .. tostring(room.Name) .. "' rolled Boon with no eligible god"
        .. " (store=" .. tostring(rewardStoreName) .. ") -> re-chose " .. tostring(retry) .. note)
      return retry
    end)
  end)

  -- GodSanity, layer (2): once a door IS a "Boon" (guaranteed above to only happen with >=1 god
  -- unlocked), filter which specific god can be picked. GetEligibleLootNames is the ONE function
  -- ChooseLoot/SetupRoomReward consult for "which god loot names are currently eligible" -- its
  -- own base() already applies native per-god story-progress gates AND the caller's
  -- excludeLootNames (this room's own already-offered Boon doors, so the same god doesn't appear
  -- twice at once) -- we just additionally restrict that already-computed list to unlocked gods.
  --   Every mode respects the caller's exclude list first, like vanilla: a room's Boon doors show
  -- different gods for as long as there are unlocked gods left to show. Modes 2/3 used to ignore
  -- the list outright so a slot was never wasted, but DoUnlockRoomExits re-synchronizes the RNG
  -- to the same offset for every door (ChooseRoomReward's RandomSynchronize), so an identical
  -- candidate list drew the identical god each time -- confirmed live 2026-10-04: Ephyra's hub
  -- showing one god on ten doors with seven or more unlocked.
  --   Once every unlocked god is already on a door, the remaining Boon doors repeat them rather
  -- than surfacing a locked god or wasting the slot ("every boon that spawns will always be from
  -- a god you've unlocked"), spread over the gods offered the fewest times so far so the repeats
  -- do not all land on one name for the same RNG reason.
  pcall(function()
    modutil.mod.Path.Wrap("GetEligibleLootNames", function(base, excludeLootNames)
      if not ItemManager.have_settings() then return base(excludeLootNames) end
      local mode = ItemManager.setting_mode("godsanity")
      if mode == 0 then return base(excludeLootNames) end
      local filtered = {}
      for _, n in ipairs(base(excludeLootNames)) do
        if ItemManager.god_eligible(n) then table.insert(filtered, n) end
      end
      if #filtered > 0 then return filtered end
      local unlocked = {}
      for _, n in ipairs(base(nil)) do
        if ItemManager.god_eligible(n) then table.insert(unlocked, n) end
      end
      if type(excludeLootNames) ~= "table" then return unlocked end
      local offered, fewest = {}, nil
      for _, n in pairs(excludeLootNames) do offered[n] = (offered[n] or 0) + 1 end
      for _, n in ipairs(unlocked) do
        local count = offered[n] or 0
        if fewest == nil or count < fewest then
          fewest, filtered = count, { n }
        elseif count == fewest then
          table.insert(filtered, n)
        end
      end
      return filtered
    end)
  end)

  -- Unlimited Gods: vanilla stops introducing new gods once MaxGodsPerRun (HeroData: 4) are
  -- either picked up this run or on this room's other doors -- GetEligibleLootNames then only
  -- offers CurrentRun.LootTypeHistory's. ReachedMaxGods is that one test and nothing else reads
  -- the cap, so answering "no" makes every god roll a draw over every eligible god: all of them
  -- with godsanity unlocked, every unlocked one otherwise (the wrap above filters after this).
  -- godsanity_onion_roll calls it too, so onions' locked-god odds stay over all 9 for the run.
  pcall(function()
    modutil.mod.Path.Wrap("ReachedMaxGods", function(base, excludedGods)
      if ItemManager.have_settings() and ItemManager.setting_on("unlimited_gods") then return false end
      return base(excludedGods)
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

  -- MiniBoss forcing: when enemysanity has locations on (vanilla_plus_locations /
  -- shuffled_plus_locations) AND include_minibosses is on, a miniboss room's LegalEncounters pool
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
    if not (EnemySanity.locations_on() and ItemManager.setting_on("include_minibosses")) then return args end
    local candidates = (args and args.LegalEncounters) or (room and room.LegalEncounters)
    if type(candidates) ~= "table" or #candidates <= 1 or not game.EncounterData then return args end
    local undefeated, allMiniboss = {}, true
    for _, name in ipairs(candidates) do
      local def = game.EncounterData[name]
      if not def or def.EncounterType ~= "Miniboss" then
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

  -- Crash guard: HandleNextSpawn (EncounterLogic.lua ~752) back-compat path -- when the
  -- initially-rolled spawnInfo.Name isn't in EnemyData, it retries via
  -- GetRandomValue(encounter.EnemySet) up to TableLength(encounter.EnemySet) times
  -- ("tries < maxTries", line ~771). If encounter.EnemySet is nil, TableLength returns nil and
  -- that comparison itself throws, taking the whole game down -- same failure shape as the
  -- ChooseEncounter guard just above, one call deeper. Confirmed via LogOutput.log 2026-08-07
  -- 11:59: "EncounterLogic.lua:771: attempt to compare number with nil" right after a fresh
  -- P_Intro room load with combat_helper_sanity any-location enabled (zerp-Extended_NPC_Encounters'
  -- combat-helper encounters InheritFrom a Base<Npc>Combat + Generated<Zone> pair rather than
  -- setting EnemySet directly, so a merge edge case can leave it unset). pcall the real
  -- HandleNextSpawn; on failure, return nil -- a value this function already legitimately returns
  -- for its own "Nothing spawned!" case, so both call sites already tolerate it -- instead of
  -- letting the error propagate.
  --
  -- Softlock guard (9/26, live in F_Combat21): a spawn whose RequiredSpawnPoint type the current
  -- map doesn't have at all. Enemysanity swapped a Mage for Guard2, which inherits
  -- OceanusUnitData's RequiredSpawnPoint = "EnemyPointMelee" -- and no Erebus combat map has a
  -- single EnemyPointMelee. SelectSpawnPoint (EncounterLogic.lua:1071) then shuffles an EMPTY list
  -- (its `or MapState.SpawnPoints` fallback never fires: the cached {} is truthy), falls through
  -- every relaxation, and returns nil; HandleNextSpawn returns nil; and the wave loop (~646) reads
  -- that as "cap hit" and waitUntil("RequiredEnemyKilled"). With the rest of the wave already dead,
  -- nothing is left to send that notify: no enemies, room never clears. Vanilla's own cross-biome
  -- swap hits the same wall and handles it the same way -- MetaUpgradeData's
  -- NextBiomeEnemyShrineUpgrade.SwapMap overrides RequiredSpawnPoint on every swapped entry (for
  -- Guard2 itself, to "EnemyPoint"). A fixed replacement type doesn't work for us, though: 25
  -- combat maps have no plain EnemyPoint either. So check the map actually loaded, and drop the
  -- requirement only when the map has zero points of that type -- the spawn could never succeed
  -- anyway, and the enemy then falls back to its PreferredSpawnPoint / any spawn point. Rooms that
  -- DO have the type keep the requirement untouched. Not gated on enemysanity: a native spawn
  -- whose required type is missing has the same guaranteed hang (other mods port encounters
  -- between maps), and a native spawn whose type is present is unaffected.
  local function relax_missing_spawn_point(spawnInfo)
    if type(spawnInfo) ~= "table" or type(spawnInfo.Name) ~= "string" then return end
    local data = game.EnemyData and game.EnemyData[spawnInfo.Name]
    if not data then return end
    local pointType = data.RequiredSpawnPoint
    if spawnInfo.SpawnOverrides and spawnInfo.SpawnOverrides.RequiredSpawnPoint ~= nil then
      pointType = spawnInfo.SpawnOverrides.RequiredSpawnPoint
    end
    if type(pointType) ~= "string" or pointType == "nil" then return end
    local ids = game.GetIdsByType({ Name = pointType })
    if type(ids) == "table" and next(ids) ~= nil then return end
    spawnInfo.SpawnOverrides = spawnInfo.SpawnOverrides or {}
    spawnInfo.SpawnOverrides.RequiredSpawnPoint = "nil" -- OverwriteTableKeys' literal for "clear"
    local room = game.CurrentRun and game.CurrentRun.CurrentRoom
    rom.log.info("[AP] spawn: " .. spawnInfo.Name .. " requires spawn point " .. pointType .. ", which "
      .. tostring(room and room.Name) .. " has none -- requirement dropped")
  end

  pcall(function()
    modutil.mod.Path.Wrap("HandleNextSpawn", function(base, encounter, ignoreSpawnPreferences, spawnInfo, overrides, args)
      -- Resolve the spawn up front when the caller left it to HandleNextSpawn (Zagreus' Journey's
      -- survival encounters call HandleNextSpawn(encounter) bare), so the guard below can see it.
      -- Same call HandleNextSpawn's own first line would make, just made here instead of there.
      if spawnInfo == nil and encounter ~= nil then
        local okNext, nextInfo = pcall(game.GetNextSpawn, encounter)
        if okNext then spawnInfo = nextInfo end
      end
      pcall(relax_missing_spawn_point, spawnInfo)
      local ok, result = pcall(base, encounter, ignoreSpawnPreferences, spawnInfo, overrides, args)
      -- A nil return with no enemy left alive is the hang described above, whatever caused it
      -- (e.g. the map HAS the required type but every point was ineligible this pass).
      -- SelectSpawnPoint clears SpawnPointsUsed on its way out of a failed pass, so one immediate
      -- retry with spawn preferences ignored almost always lands. With enemies still alive, leave
      -- vanilla's wait-for-a-kill alone -- it recovers on its own.
      if ok and result == nil and spawnInfo ~= nil then
        local okCount, active = pcall(game.GetActiveEnemyCount, encounter)
        if okCount and active == 0 then
          rom.log.info("[AP] spawn: " .. tostring(spawnInfo.Name) .. " found no spawn point with no enemies alive in "
            .. tostring(encounter and encounter.Name) .. " -- retrying without spawn preferences")
          ok, result = pcall(base, encounter, true, spawnInfo, overrides, args)
          -- 11/3 (session B): a third try without the unit's RequiredSpawnPoint. The map can HAVE
          -- that type and still have no usable point of it (586: Turtle_Elite on a ZJ Tartarus map,
          -- room stuck at "foes nearby"), and the retry above can't help -- ignoreSpawnPreferences
          -- only clears PreferredSpawnPoint, after the point is already chosen. Same "nil" literal
          -- relax_missing_spawn_point uses, and kept on the slot: the type is proven unusable here.
          local data = game.EnemyData and game.EnemyData[spawnInfo.Name]
          local required = spawnInfo.SpawnOverrides and spawnInfo.SpawnOverrides.RequiredSpawnPoint
          if required == nil then required = data and data.RequiredSpawnPoint end
          if ok and result == nil and type(required) == "string" and required ~= "nil" then
            spawnInfo.SpawnOverrides = spawnInfo.SpawnOverrides or {}
            spawnInfo.SpawnOverrides.RequiredSpawnPoint = "nil"
            rom.log.info("[AP] spawn: retry for " .. tostring(spawnInfo.Name) .. " failed -- dropping its "
              .. required .. " requirement and trying once more")
            ok, result = pcall(base, encounter, true, spawnInfo, overrides, args)
          end
          if ok and result == nil then
            rom.log.info("[AP] spawn: retry for " .. tostring(spawnInfo.Name) .. " also failed -- encounter may stall")
          end
        end
      end
      if ok then return result end
      rom.log.info("[AP] HandleNextSpawn crashed for encounter " .. tostring(encounter and encounter.Name)
        .. " (" .. tostring(result) .. ") -- no-oping this spawn")
      -- Retire the spawn slot we just failed on. HandleNextSpawn only decrements RemainingSpawns
      -- on a SUCCESSFUL spawn, and the wave loop (EncounterLogic.lua ~620) keeps looping while
      -- GetRemainingSpawns > 0 -- so bailing out without this leaves the same doomed spawn at the
      -- head of the queue forever: the room's enemies never finish spawning, the encounter never
      -- completes, and its exits never unlock. Turning a crash into a permanent softlock is not
      -- an improvement over the crash. Consuming the slot lets the rest of the wave proceed and
      -- the room finish, one enemy short.
      pcall(function()
        if spawnInfo and not spawnInfo.InfiniteSpawns and type(spawnInfo.RemainingSpawns) == "number" then
          spawnInfo.RemainingSpawns = spawnInfo.RemainingSpawns - 1
        end
      end)
      return nil
    end)
  end)

  -- Oath of the Unseen, bounded: ShrineScreenRankUp/RankDown (ShrineLogic.lua:461/439) and
  -- ShrineLogicResetAll (the "Reset All" button, :875) are the only ways to mutate
  -- GameState.ShrineUpgrades from the screen. While connected:
  --   * rank up is always allowed (harder is the player's call) and remembered;
  --   * rank down stops at the vow's lowest allowed rank (starting level minus removals received)
  --     and at minimum_fear -- ItemManager.vow_can_rank_down -- with the game's own "already at
  --     minimum" pulse when refused;
  --   * Reset All stays a no-op (it zeroes every vow, straight through both limits).
  -- Vanilla play, before settings, is untouched.
  pcall(function()
    modutil.mod.Path.Wrap("ShrineScreenRankUp", function(base, screen, button)
      local item = screen and screen.SelectedItem
      local result = base(screen, button)
      if ItemManager.have_settings() and item and item.Data then
        AP_try("ItemManager.record_vow_choice", function() ItemManager.record_vow_choice(item.Data.Name) end)
      end
      return result
    end)
  end)
  pcall(function()
    modutil.mod.Path.Wrap("ShrineScreenRankDown", function(base, screen, button)
      local item = screen and screen.SelectedItem
      if not (ItemManager.have_settings() and item and item.Data) then
        return base(screen, button)
      end
      local allowed = false
      AP_try("ItemManager.vow_can_rank_down", function() allowed = ItemManager.vow_can_rank_down(item.Data.Name) end)
      if not allowed then
        pcall(function() game.ShrineScreenAlreadyAtMinPresentation(screen, item) end)
        return
      end
      local result = base(screen, button)
      AP_try("ItemManager.record_vow_choice", function() ItemManager.record_vow_choice(item.Data.Name) end)
      return result
    end)
  end)
  pcall(function()
    modutil.mod.Path.Wrap("ShrineLogicResetAll", function(base, screen, button)
      if ItemManager.have_settings() then return end
      return base(screen, button)
    end)
  end)

  -- DeathLink (outgoing): KillHero is the confirmed hero-death entry point. Count our
  -- deaths and send a DeathLink on every deathlink_amnesty-th death (0 = never send). The
  -- forcing_deathlink guard skips deaths WE caused from an incoming DeathLink.
  pcall(function()
    modutil.mod.Path.Wrap("KillHero", function(base, victim, triggerArgs)
      -- (Final Challenge's old suppress_win_death skip lived here -- removed 11/3, see the
      -- OpenRunClearScreen wrap: it swallowed the KillHero that really ends the run.)
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
      local result = base(victim, triggerArgs)
      -- Armor visual bug: vanilla's death fade (DeathPresentation -> HideCombatUI ->
      -- HideHealthUI, HUDLogic.lua) already includes the armor bar (HealthBuffer, the same
      -- component ShowHealthUI's HPBarArmorFill animation draws onto) in its hide list --
      -- but it can still be seen lingering on screen through the fade to black. Most likely
      -- cause: the killing blow's own health-update lands a frame after HideHealthUI starts
      -- fading it out and re-shows it. Force it invisible defensively once base() (the whole
      -- death sequence) has run, regardless of what raced it.
      pcall(function()
        if game.HUDScreen and game.HUDScreen.Components and game.HUDScreen.Components.HealthBuffer and SetAlpha then
          SetAlpha({ Id = game.HUDScreen.Components.HealthBuffer.Id, Fraction = 0.0, Duration = 0 })
        end
      end)
      return result
    end)
  end)

  -- enemysanity: every unit death routes through game.Kill (the same entry the
  -- incoming-DeathLink path uses on the hero). Send the first-defeat check for foes we map;
  -- the hero is skipped, and unmapped foes are logged once for discovery (LocationManager).
  pcall(function()
    modutil.mod.Path.Wrap("Kill", function(base, victim, triggerArgs)
      -- zerp-NPCRoomRandomizer writes an explicit false to ZJ's run flag at room transitions, and
      -- a death is where ZJ's per-unit hooks matter most: see EnemySanity.zj_unit_hooks_attach.
      pcall(EnemySanity.zj_unit_hooks_attach, game.CurrentRun)
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
          -- Now that he's dead, show it for real, then end the run on the spot. The screen
          -- (RecordRunCleared sets CurrentRun.Cleared) blocks in HandleScreenInput until the
          -- player closes it; a KillHero with Cleared set is the game's own "won run, back to
          -- the Crossroads" path -- otherwise C_Boss01's exit wandered into random rooms of the
          -- boss biome and the run never ended.
          if ItemManager.goal_includes_zagreus()
             and ItemManager.zagreus_is_final_challenge() then
            game.CurrentRun.APFinalChallengeDeferredClear = nil
            ItemManager.won_run_pending = true
            ItemManager.force_run_clear_screen = true
            game.OpenRunClearScreen()
            rom.log.info("[AP] Final Challenge: Zagreus defeated -- ending the run")
            game.KillHero(game.CurrentRun.Hero, {})
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
      -- Vow of Rivals: "Met Medea"/"Met Heracles"/"Met Chronos" only when that rival woke up here.
      AP_try("LocationManager.on_units_activated", function() LocationManager.on_units_activated(activated, eventSource) end)
      pcall(function()
        if not (activated and ItemManager.goal_includes_zagreus()
                and ItemManager.zagreus_is_empowered()) then
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
      AP_try("LocationManager.on_npc_interacted", function() LocationManager.on_npc_interacted(npc) end)
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
      AP_try("LocationManager.on_eris_curse_applied", function() LocationManager.on_eris_curse_applied() end)
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
  -- Presetting itemData.StackNum below makes vanilla CreateUpgradeChoiceButton take its
  -- "already decided" branch (itemData.StackNum then stackNum = itemData.StackNum) and skip
  -- its own else-branch entirely -- which is also where vanilla adds Jeweled Pom's bonus
  -- (IsFateValid() and GetTotalHeroTraitValue("FatedBoonLevelBonus") > 0 then stackNum =
  -- stackNum + FatedBoonLevelBonus + 1, UpgradeChoiceLogic.lua ~306). Left alone, our preset
  -- silently ate Jeweled Pom's level bonus instead of stacking with it. Replicate that same
  -- addition here (Fate keepsake's rarity-scaled FatedBoonLevelBonus, present whenever
  -- Jeweled Pom is equipped and Fate isn't Unfated) so the two stack.
  pcall(function()
    modutil.mod.Path.Wrap("CreateUpgradeChoiceButton", function(base, screen, lootData, itemIndex, itemData, args)
      pcall(function()
        if itemData and itemData.StackNum == nil then
          local start = ItemManager.boon_level_start()
          if start then
            local fate_bonus = 0
            if game.IsFateValid and game.GetTotalHeroTraitValue and game.IsFateValid() then
              fate_bonus = game.GetTotalHeroTraitValue("FatedBoonLevelBonus") or 0
            end
            itemData.StackNum = start + fate_bonus
          end
        end
      end)
      return base(screen, lootData, itemIndex, itemData, args)
    end)
  end)

  -- npc_locations: meeting field NPCs (Artemis/Athena/Heracles/...). They're combat
  -- encounters, not conversations or loot, so UseNPC/HandleLootPickup never fired for them
  -- (Test Run 5 #3). StartEncounter(currentRun, currentRoom, encounter) is the encounter-start
  -- entry (RoomLogic.lua:1848); on_encounter_started reads SpeakerNames -> "Met <Name>".
  -- (Room-check scoring used to rely solely on the SpawnRoomReward wrap below -- see its
  -- comment. Confirmed 8/4 that's an under-count, not just an over-count precaution: Fields of
  -- Mourning's cage-reward rooms (RoomDataH.lua RewardCageSpawnPoints/MaxCageRewards) pre-spawn
  -- ALL of a room's cage rewards via SpawnRewardCages at room SETUP -- before either of the
  -- room's real encounters has even started -- so every encounter after the first hit the
  -- already-`_ap_scored` dedup and scored nothing (2 encounters, 1 check, sent at room entry).
  -- Worse, Tartarus (zone I) runs multiple back-to-back combat rooms (I_Combat*) whose chosen
  -- reward is nil/Empty -- SpawnRoomReward returns nil for those every time, so score_encounter
  -- is never even called: real, fully-cleared combat encounters silently earned NOTHING. Given
  -- that, the user's ruling (8/4) is to score every completed combat encounter on the "wave
  -- killed" moment below, full stop -- accepting that a pre-combat filler wave (Mount Olympus
  -- GeneratedP_PreCombat, EncounterRoomRewardOverride="Empty") now also earns its own check,
  -- since under-counting (checks vanishing) is the far worse failure mode than over-counting
  -- (a few extra checks from filler waves). That also covers Thessaly's NoReward and Styx's
  -- DeferReward rooms, which used to need their own special-case scorers.)
  -- EnemySanity art preload. LoadSpawnPackages is the game's own "get this encounter's art
  -- resident" pass (RoomLogic.lua:1593, called from room load at RoomLogic.lua:1136-1144), and it
  -- keys packages off the unit ids present at that moment -- i.e. the ORIGINAL ones, since our
  -- substitution doesn't run until StartEncounter. Planning the substitutions here lets the
  -- replacements' packages ride along with the room's own load instead of being requested at wave
  -- start, and pins pure_random's choice so the preloaded id is the one that spawns. Runs AFTER
  -- base() so the vanilla loads are already queued and encounter data is fully populated;
  -- plan_encounter mutates nothing, so a wrapped-but-unsubstituted encounter is unaffected.
  pcall(function()
    modutil.mod.Path.Wrap("LoadSpawnPackages", function(base, encounter)
      base(encounter)
      pcall(function()
        if EnemySanity.substitution_on() then
          local route = Routes.current()
          if route then EnemySanity.plan_encounter(encounter, route) end
        end
      end)
    end)
  end)

  -- The load that actually counts for spawns rewritten at SetupEncounter (i.e. nearly all of
  -- them): LoadCurrentRoomResources runs on every run-room map load, including a save loaded
  -- straight into the room, which never reaches LoadSpawnPackages. See
  -- EnemySanity.preload_room_art.
  pcall(function()
    modutil.mod.Path.Wrap("LoadCurrentRoomResources", function(base, currentRoom)
      pcall(EnemySanity.zj_unit_hooks_attach, game.CurrentRun)
      base(currentRoom)
      pcall(EnemySanity.preload_room_art, currentRoom)
    end)
  end)

  -- The save never sees the metatable zj_unit_hooks_attach puts on CurrentRun: it comes off for
  -- the duration of Save() and goes straight back. savebinary very likely ignores metatables (it
  -- replaced luabins, which does), but a save that asserts is not a thing to find out live.
  pcall(function()
    modutil.mod.Path.Wrap("Save", function(base, ...)
      pcall(EnemySanity.zj_unit_hooks_detach)
      local ok, err = pcall(base, ...)
      pcall(EnemySanity.zj_unit_hooks_attach, game.CurrentRun)
      if not ok then error(err, 0) end
    end)
  end)

  -- Vanilla nil index, reachable only through us. RootApplyPresentation (EventPresentation.lua:568)
  -- recurses into a rooted unit's TetherIds as RootApplyPresentation(nil, tetherId) and then reads
  -- victim.NeverDeferRootPresentation with no nil check. No Hades II enemy has tethers; Hades I's
  -- Brimstone family does (its floating crystals), and Zagreus' Journey patches the hole itself --
  -- but only while CurrentRun.ModsNikkelMHadesBiomesIsModdedRun, which is false whenever the
  -- shuffle puts one of those enemies on another route. 10/7, live: Demeter's Freeze on a
  -- substituted Brimstone in Ephyra threw here on every hit and left combat dead. Same handling
  -- ZJ uses: queue the tether for the deferred pass, which is all base() would have done with it.
  pcall(function()
    modutil.mod.Path.Wrap("RootApplyPresentation", function(base, victim, victimId)
      if victim == nil then
        if victimId ~= nil then
          game.FrameState.DeferredPresentation = game.FrameState.DeferredPresentation or {}
          local deferred = game.FrameState.DeferredPresentation
          deferred.DoRootApplyPresentation = deferred.DoRootApplyPresentation or {}
          table.insert(deferred.DoRootApplyPresentation, victimId)
        end
        return
      end
      return base(victim, victimId)
    end)
  end)

  -- PRIMARY substitution point. SetupEncounter (RunLogic.lua:1099) is where SpawnWaves and each
  -- entry's TotalCount are first built, and everything that later reads them -- the room-load
  -- pre-spawn pass (EncounterLogic.lua HandleEncounterPreSpawns, which places the enemies already
  -- standing in a room when you walk in) and StartEncounter's wave spawns alike -- runs after it.
  -- Rewriting here is what makes pre-placed enemies shuffle at all; the StartEncounter hook below
  -- stays as a fallback for any encounter that reaches it without passing through here.
  --
  -- SetupEncounter runs while the room is being built, so Routes.current() can still report the
  -- room you're leaving; Routes.for_room answers for the room this encounter belongs to instead.
  -- 10/4: that is what lets pure_random rewrite here too. It draws from a route-scoped pool, so it
  -- used to wait for StartEncounter -- which left it with the 8/16 bug the shuffled modes had
  -- already been cured of (enemies standing in the room when you walk in were never swapped).
  pcall(function()
    modutil.mod.Path.Wrap("SetupEncounter", function(base, encounterData, room)
      local encounter = base(encounterData, room)
      pcall(function()
        if EnemySanity.substitution_on() then
          local route = Routes.for_room(room)
          if route then EnemySanity.substitute_encounter(encounter, route, room) end
        end
      end)
      return encounter
    end)
  end)

  pcall(function()
    modutil.mod.Path.Wrap("StartEncounter", function(base, currentRun, currentRoom, encounter)
      AP_try("LocationManager.on_encounter_started", function() LocationManager.on_encounter_started(encounter) end)
      -- EnemySanity substitution (shuffled/shuffled_plus_locations/pure_random): remap each
      -- already-resolved spawn's unit id to its replacement BEFORE base() actually spawns the
      -- wave. NOTE: this used to mutate encounter.EnemySet instead, on the wrong assumption
      -- that it's an ordered list of what will spawn -- it's actually just the RANDOM POOL
      -- FillEnemyTypes/GenerateEncounter samples from, and that sampling already happened
      -- earlier in the pipeline, inside SetupEncounter (RunLogic.lua ~1093-1119), well before
      -- StartEncounter ever runs. By StartEncounter time the real spawn list already lives in
      -- encounter.SpawnWaves[*].Spawns[*].Name (concrete unit ids, both for Generated rooms
      -- and hand-authored fixed encounters, confirmed via installed game
      -- Content/Scripts/RunLogic.lua FillEnemyTypes/AddToSpawnTable and EncounterData.lua's
      -- SpawnWaves entries) -- mutating EnemySet there was a no-op on what actually spawns,
      -- which is why enemies never appeared shuffled in a live run. EnemySanity.replacement_unit_id
      -- returns nil (leave the entry untouched) for vanilla modes, units it can't identify, and
      -- miniboss slots when include_minibosses is off.
      -- _ap_substituted marks a spawn slot we've already rewritten. StartEncounter can run more
      -- than once against the same encounter table (its own `if encounter.Completed then return`
      -- guard exists for exactly that, and it sits INSIDE base(), i.e. after this block), and a
      -- second pass would substitute the substitute -- walking one more step around the shuffle
      -- map's cycle each time and quietly ignoring the seed's actual permutation.
      -- SpawnOverrides.AP_EnemySanitySubstituted is how the flag reaches the live unit:
      -- HandleNextSpawn OverwriteTableKeys' a spawn's SpawnOverrides onto the enemy table it
      -- builds (EncounterLogic.lua, both the plain and SpawnUnitGroup paths), so the SetupUnit
      -- wrap below can tell "EnemySanity put this here" from "the game placed this here" --
      -- which is what keeps the Dream Dive stat scaling off ordinary, correctly-placed enemies.
      pcall(function()
        if EnemySanity.substitution_on() and encounter and encounter.SpawnWaves
           and not EnemySanity.encounter_is_miniboss(encounter) then
          local route = Routes.current()
          if route then
            for _, wave in ipairs(encounter.SpawnWaves) do
              if wave.Spawns then
                for _, spawnData in ipairs(wave.Spawns) do
                  if spawnData.Name and not spawnData._ap_substituted then
                    -- Prefer the decision already taken (and art already preloaded) by the
                    -- LoadSpawnPackages wrap below; only decide here if this encounter never
                    -- went through that pass. See EnemySanity.plan_encounter.
                    local replacement, decided = EnemySanity.planned_replacement(spawnData)
                    if not decided then
                      replacement = EnemySanity.replacement_unit_id(spawnData.Name, route)
                      if replacement then EnemySanity.preload_unit_package(replacement) end
                    end
                    if replacement then
                      rom.log.info("[AP] enemysanity: substituted " .. spawnData.Name .. " -> " .. replacement)
                      -- Before .Name is overwritten: rescale this slot's TotalCount so the
                      -- replacement costs the same slice of the wave's difficulty budget the
                      -- generator already spent on the original. See
                      -- EnemySanity.rebalance_spawn_count.
                      local original = spawnData.Name
                      pcall(function()
                        EnemySanity.rebalance_spawn_count(spawnData, original, replacement, currentRoom)
                      end)
                      spawnData.Name = replacement
                      EnemySanity.mark_substituted(spawnData, original)
                    end
                  end
                end
              end
            end
          end
        end
      end)
      base(currentRun, currentRoom, encounter)
      -- StartEncounter runs its whole wave to completion before returning (RoomLogic.lua's
      -- multi-encounter loop chains the next wave on this return), so this line is the
      -- "wave killed" moment. If the player dies mid-wave the room thread is killed inside
      -- base(), so this never runs -- no score. score_encounter itself no-ops on a NonCombat
      -- encounter and dedups per encounter instance (encounter._ap_scored), so calling it here
      -- unconditionally for every zone is safe even though SpawnRoomReward below may also (or
      -- may never) fire for the same encounter.
      AP_try("LocationManager.score_encounter", function() LocationManager.score_encounter(currentRoom, encounter) end)
      -- Zone cascade: a completed zone-boss fight (a "Boss" encounter in a <Biome>_BossNN room)
      -- releases the rest of that zone's room checks. C_Boss01 is the Zagreus contract arena,
      -- not a zone boss.
      pcall(function()
        if not (encounter and encounter.Completed and currentRoom and currentRoom.Name) then return end
        if currentRoom.Name == "C_Boss01" or not currentRoom.Name:match("_Boss%d+$") then return end
        local data = game.EncounterData and encounter.Name and game.EncounterData[encounter.Name]
        local etype = encounter.EncounterType or (data and data.EncounterType)
        if etype ~= "Boss" then return end
        local route, zone = Routes.current()
        if route and zone then LocationManager.on_zone_boss_defeated(route, zone) end
      end)
    end)
  end)

  -- EnemySanity balance scaling (shuffled/shuffled_plus_locations/pure_random): mirrors Hades
  -- II's own native Dream Dive per-unit scaling (RoomLogic.lua:SetupUnit, ~line 3294 --
  -- "if currentRun.IsDreamRun and unit.DreamBiomeData ~= nil then ... OverwriteTableKeys(unit,
  -- dreamBiomeData.DataOverrides) end"), applied outside real Dream Dive runs too but ONLY to
  -- units EnemySanity itself substituted in, or spawned in a miniboss room the room shuffle moved
  -- (scale_unit's scaling_reason gate -- this fires for every enemy the game spawns,
  -- natively-placed ones included), and keyed by the
  -- CURRENT ROOM's zone number (Routes.current()) instead of
  -- CurrentRun.EnteredBiomes -- see EnemySanity.scale_unit. MUST run BEFORE base(), not after
  -- (8/7 fix): base() IS RoomLogic.lua's native SetupUnit body, and that body consumes
  -- unit.HealthMultiplier (~line 3411, "unit.MaxHealth = unit.MaxHealth * healthMultiplier")
  -- and unit.SpeedMultiplier (~line 3336-3354, baked into a one-shot SetThingProperty call)
  -- SYNCHRONOUSLY WITHIN ITSELF -- by the time base() returns, both have already been read and
  -- applied once. Calling scale_unit() after base() (the original code) set unit.HealthMultiplier
  -- too late to affect unit.MaxHealth at all, so a substituted enemy kept its native/origin-zone
  -- stats regardless of which zone it actually spawned into (reported as area-4-tuned enemies
  -- spawning in area 1). unit.DreamBiomeData itself is already present on `unit` before SetupUnit
  -- is even called (callers build the full EnemyData-template-merged unit table first, e.g.
  -- CombatLogic.lua's CreateEnemy, then pass it to SetupUnit) so scale_unit has everything it
  -- needs pre-base(). AddOutgoingDamageModifier is unaffected either way (CombatLogic.lua's
  -- AddOutgoingDamageModifier just appends to unit.OutgoingDamageModifiers, read dynamically at
  -- damage time, not baked at spawn) -- kept here regardless since it must run before base() too
  -- for MoneyMultiplier/other DataOverrides keys to be in place at spawn-adjacent read sites.
  pcall(function()
    modutil.mod.Path.Wrap("SetupUnit", function(base, unit, currentRun, args)
      -- Before anything can be asked about this unit: see EnemySanity.zj_unit_hooks_attach.
      pcall(EnemySanity.zj_unit_hooks_attach, game.CurrentRun)
      pcall(function() EnemySanity.scale_unit(unit) end)
      return base(unit, currentRun, args)
    end)
  end)

  -- (The encounter-level twin of the wrap above -- a SetupEncounter wrap calling
  -- EnemySanity.scale_encounter -- was removed. Substitution only ever swaps individual spawns,
  -- never the encounter itself, so no encounter is ever "from another zone" and there was
  -- nothing for it to correct; all it did was retune every encounter in the game to Dream Dive
  -- values whenever enemysanity was in a substitution mode. See EnemySanity.lua's note where
  -- scale_encounter used to live.)

  -- Secondary/redundant room-check trigger: also fire the instant an encounter's reward
  -- actually spawns (RewardLogic.lua:SpawnRoomReward). Now that the StartEncounter wrap above
  -- scores every completed combat encounter unconditionally, this path rarely does new work --
  -- but it still matters for cage-reward rooms (Fields of Mourning), where SpawnRoomReward can
  -- fire at room SETUP, before the corresponding encounter's StartEncounter wrap has run, so
  -- being able to score from either side avoids depending on ordering. encounter._ap_scored
  -- dedup makes firing from both sites for the same encounter harmless.
  pcall(function()
    modutil.mod.Path.Wrap("SpawnRoomReward", function(base, eventSource, args)
      local reward = base(eventSource, args)
      if reward ~= nil then
        local room = game.CurrentRun and game.CurrentRun.CurrentRoom
        AP_try("LocationManager.score_encounter", function() LocationManager.score_encounter(room, room and room.Encounter) end)
      end
      return reward
    end)
  end)

  -- npc_locations: meeting boon gods. Olympians aren't NPC conversations - their boon is a
  -- loot pickup, routed through HandleLootPickup(currentRun, loot, args) (InteractLogic.lua:693),
  -- which plays the god's greeting on interact. on_loot_pickup maps "<God>Upgrade" -> "Met <God>".
  pcall(function()
    modutil.mod.Path.Wrap("HandleLootPickup", function(base, currentRun, loot, args)
      AP_try("LocationManager.on_loot_pickup", function() LocationManager.on_loot_pickup(loot) end)
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
      AP_try("LocationManager.on_spell_screen_opened", function() LocationManager.on_spell_screen_opened(spellItem) end)
      return base(spellItem, args, user)
    end)
  end)

  -- "SHUSH Homer" / "Find Hecate 1/2/3" npc_locations checks REMOVED (2026-08-04, user request):
  -- both fired off the Hecate hide-and-seek Crossroads flashback (Flashback01), which is now
  -- permanently disabled -- see ItemManager.apply_flashback_disable. With that flashback's
  -- OnDeathLoadRequirements never satisfiable, InspectHomerReveal01/HecateHideAndSeek01-03 can
  -- never play, so this PlayTextLines-matching send hook would be dead code. The four
  -- corresponding AP locations were also removed on the Python/apworld side (Locations.py
  -- NPC_INTRO, Rules.py) -- see that change for the version-bump/new-seed caveat.

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
        if route == "Dream" then
          -- A Dream Dive's last-region boss opens this screen too (vanilla's I/Q/F/H/O kill
          -- presentations call it once EnteredBiomes reaches FullRunBiomeCount). That clear is
          -- Dream's own, counted once by the CheckDreamBiomeCompletion wrap (on_dream_run_cleared).
          -- Handing it to on_run_cleared counted it as a Chronos clear as well, which goaled seeds
          -- whose Underworld was never beaten (0.10.0 logs, 10/26). Dives never offer Zagreus's
          -- contract either (the apworld's Routes.py zagreus_reachable), so the screen just plays.
          rom.log.info("[AP] run-clear screen in a Dream Dive - Dream counts it on region completion")
          ItemManager.won_run_pending = true
          return
        end
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
           and ItemManager.zagreus_is_final_challenge() then
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
        -- room-transition internals. We also skip the vanilla run-clear screen for now (no
        -- base() call below); it plays after Zagreus (Kill wrap) or, if the player takes the
        -- boss room's normal exit instead, on the way out (LeaveRoom wrap below).
        -- No KillHero follows this screen in vanilla: the run ends later, in I/Q_PostBoss01's
        -- ending dialogue (PostLineThreadedFunctionName = "KillHero"). The old
        -- suppress_win_death flag armed here therefore swallowed the NEXT KillHero -- the one
        -- ending the run after Zagreus (C_Boss01's exit then led into endless rooms) or Zeus's
        -- in the Temple after turning him down (the room never let you leave). 0.10.0 report,
        -- aihkii 11/3.
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
            -- Offset from the Hero (spawning ON the Hero blocked talking to Chronos).
            contractItem.ObjectId = game.SpawnObstacle({
              DestinationId = currentRun.Hero.ObjectId, Name = "ZagContract", Group = "Standing",
              OffsetX = 250, OffsetY = 0, ForceToValidLocation = true,
            })
            contractItem.RerollFunctionName = nil
            local nextRoom = game.CreateRoom(roomData)
            game.AssignRoomToExitDoor(contractItem, nextRoom)
            game.SetupObstacle(contractItem)
            currentRun.APFinalChallengeDeferredClear = true
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

  -- Dream Dive run-clear detection: CheckDreamBiomeCompletion (NOT OpenRunClearScreen -- Dream
  -- Dive's completion flow is entirely separate from Chronos/Typhon/Hades's, confirmed by
  -- reading the vanilla/DreamDiveTweaks source directly). DreamDiveTweaks ITSELF already wraps
  -- this same function once (its own runlength.lua, to detect EnteredBiomes exceeding the
  -- configured region count and fire EndDreamRunPresentation) -- base(...) is called FIRST and
  -- unconditionally so that existing wrap chain is preserved regardless of our own logic.
  -- Guarded per-CurrentRun (game.CurrentRun._ap_dream_clear_handled) rather than a persistent
  -- APState flag: CurrentRun is a fresh table every new run, so this naturally resets without
  -- needing an explicit "new attempt started" reset hook, same idiom as room._ap_scored/
  -- encounter._ap_scored elsewhere in this file.
  -- A true return does NOT mean "run cleared". Read DreamRunLogic.lua: this function returns
  -- false only when the room isn't a region-ending DreamPointsDrop room, and returns true for
  -- EVERY region transition -- the final-region branch (EndDreamRunPresentation) and the
  -- "build the next region's room and LeaveRoom into it" branch alike. Firing on the bare
  -- return value therefore counted a Dream "clear" the moment the player finished REGION ONE of
  -- an attempt, and the per-CurrentRun guard then made sure it never fired again -- so a
  -- dream_wins_needed=1 seed hit its Dream goal after a single region, and every attempt banked
  -- another bogus clear. Gate on the same condition the game's own final-region branch uses:
  -- EnteredBiomes reaching GameData.FullRunBiomeCount (which DreamDiveTweaks overwrites with the
  -- configured region count, and whose own wrap adds a > safeguard branch -- hence >=, not ==).
  pcall(function()
    modutil.mod.Path.Wrap("CheckDreamBiomeCompletion", function(base, ...)
      local region_before = game.CurrentRun and game.CurrentRun.EnteredBiomes
      local result = base(...)
      local run = game.CurrentRun
      -- A region just ended (its boss is behind us): release that region's remaining room
      -- checks for the current lane (zone cascade; idempotent).
      if result and (region_before or 0) >= 1 then
        AP_try("LocationManager.on_zone_boss_defeated", function() LocationManager.on_zone_boss_defeated("Dream", region_before) end)
      end
      if result and run and not run._ap_dream_clear_handled then
        local entered = run.EnteredBiomes or 0
        local needed = (GameData and GameData.FullRunBiomeCount) or 4
        if entered >= needed then
          run._ap_dream_clear_handled = true
          local weapon_id = game.GameState and game.GameState.PrimaryWeaponName or nil
          AP_try("LocationManager.on_dream_run_cleared", function() LocationManager.on_dream_run_cleared(weapon_id) end)
        else
          rom.log.info("[AP] Dream: region " .. entered .. "/" .. needed
            .. " complete - not a run clear")
        end
      end
      return result
    end)
  end)

  -- Dream Dive bosses drop Nectar too. ItemManager.apply_boss_drops_as_nectar never reaches a
  -- dive: ChooseRoomReward (RewardLogic.lua) returns "DreamPointsDrop" for any CanSpawnDreamReward
  -- room BEFORE it ever looks at room.ForcedReward, so the "GiftDrop" redirect is dead data
  -- there. The DreamPointsDrop can't be swapped out either -- CheckDreamBiomeCompletion (and
  -- DreamDiveTweaks' wrap of it) keys the whole region transition on
  -- CurrentRoom.UseRecord.DreamPointsDrop -- so the Nectar is spawned NEXT to it instead.
  -- Hooked at RoomRewardSpawnPresentation because SpawnRoomReward calls it right after the
  -- DreamPointsDrop is created and registered in MapState.RoomRequiredObjects, and before its
  -- own optional WaitUntilPickup block. Order matters: GiveRandomConsumables registers the
  -- bottle as a required pickup as well, and if it were the ONLY required object for a moment
  -- (spawned first), grabbing it would run UnlockRoomExits with no DreamPointsDrop used yet --
  -- the boss room's ordinary exits would unlock, room.ExitsUnlocked would latch, and the later
  -- DreamPointsDrop pickup could never reach CheckDreamBiomeCompletion. With both registered
  -- the region only ends once both are picked up, in either order, so the bottle can't be left
  -- behind. The RoomRequiredObjects scan keeps a second SpawnRoomReward in the same room from
  -- stacking bottles.
  pcall(function()
    modutil.mod.Path.Wrap("RoomRewardSpawnPresentation", function(base, reward, args)
      AP_try("dream boss nectar", function()
        local run = game.CurrentRun
        if not (run and run.IsDreamRun and reward and reward.Name == "DreamPointsDrop") then return end
        for _, obj in pairs(game.MapState.RoomRequiredObjects or {}) do
          if obj.Name == "GiftDrop" then return end
        end
        game.GiveRandomConsumables({
          LootOptions = { { Name = "GiftDrop", Overrides = { CanDuplicate = false, IgnorePurchase = true } } },
          DestinationId = reward.ObjectId,
          ForceToValidLocation = true,
          KeepCollision = true,
        })
        rom.log.info("[AP] Dream: boss Nectar spawned in '" .. tostring(run.CurrentRoom and run.CurrentRoom.Name) .. "'")
      end)
      return base(reward, args)
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
           and ItemManager.zagreus_is_final_challenge() then
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

  -- Final Challenge, Zagreus turned down: the player walks out of Chronos'/Typhon's room by its
  -- normal exit instead of the contract. The run-clear screen the OpenRunClearScreen wrap held
  -- back never played, so RecordRunCleared never set CurrentRun.Cleared, and the ending's
  -- KillHero would record the won run as a death. Play the held-back screen on the way out
  -- (still in the boss room, as vanilla does), then leave.
  pcall(function()
    modutil.mod.Path.Wrap("LeaveRoom", function(base, currentRun, door)
      local show = false
      pcall(function()
        local nextRoom = door and door.Room
        show = currentRun ~= nil and currentRun.APFinalChallengeDeferredClear == true
          and not (nextRoom and nextRoom.Name == "C_Boss01")
      end)
      if show then
        currentRun.APFinalChallengeDeferredClear = nil
        AP_try("Final Challenge: deferred run-clear screen", function()
          ItemManager.force_run_clear_screen = true
          game.OpenRunClearScreen()
          rom.log.info("[AP] Final Challenge: Zagreus turned down - showed the run-clear screen on the way out")
        end)
        ItemManager.force_run_clear_screen = false
      end
      return base(currentRun, door)
    end)
  end)

  -- Route locking on entry: a locked zone's first encounter never starts -- Melinoe dies as it
  -- would begin (see kill_if_route_locked). Registered after the enemysanity StartEncounter wrap
  -- above, so this one is outermost and skipping base() also skips that wave's scoring.
  pcall(function()
    modutil.mod.Path.Wrap("StartEncounter", function(base, currentRun, currentRoom, encounter)
      if kill_if_route_locked(currentRoom) then return end
      return base(currentRun, currentRoom, encounter)
    end)
  end)
end

-- ---- Socket polling driver --------------------------------------------------
-- Driven from ReturnOfModding's render loop via add_always_draw_imgui, which
-- fires every frame regardless of game state. We deliberately do NOT use the
-- game's thread()/wait(): those are coupled to game session state (SessionMapState)
-- and throw during save loads, which froze the game. Registered once.

-- This instance's rom.gui/rom.inputs entry points (frame driver, overlay toggle, menu entry),
-- published as a game global so a Hell2Modding reload of just this plugin can re-attach to them
-- instead of losing them -- see main.lua's AP_LIVE_KEY.
AP_live = AP_live or {}
AP_live.modutil = modutil
pcall(function() rom.game[AP_LIVE_KEY] = AP_live end)

if not Bridge.driver_started then
  Bridge.driver_started = true
  -- ReturnOfModding's render-loop callback: fires every frame regardless of game
  -- state, decoupled from the game's thread()/wait() (which are coupled to session/map
  -- state and throw during load transitions). We use it purely as a frame driver now.
  local function render_frame()
    -- Heartbeat: log every ~5 min (assuming ~60fps) so a log shows whether this render driver
    -- is still ticking. Cheap modulo, no per-frame logging.
    AP_render_frames = (AP_render_frames or 0) + 1
    if AP_render_frames % 18000 == 0 then
      rom.log.info("[AP] render driver alive (frame " .. AP_render_frames .. ")")
    end
    -- Retry the Nightmare Chaos Gate hooks (~every 0.5s @60fps) until Zagreus' Journey's own
    -- install/validation finishes. A real session showed our one-shot boot-time install call
    -- losing that race by ~1.6ms against the mod's first-time-install auto-reload, leaving the
    -- gate permanently unlocked for the whole run. Both install functions are idempotent and
    -- near-free once installed, so this is safe to leave running indefinitely.
    if AP_render_frames % 30 == 0 then
      AP_try("ItemManager.retry_nightmare_mod_hooks", function() ItemManager.retry_nightmare_mod_hooks() end)
      -- Also re-apply the Chaos Gate seal on this same cadence (not just at room-transition /
      -- Grasp-repaint hook points) so it self-heals if anything else touches the gate's
      -- UseText/OnUsedFunctionName/animation in between -- same self-healing pattern as the
      -- other per-room reasserts, just on a tighter loop since there's no room-change event to
      -- hang it off while the player is just standing in the hub.
      AP_try("ItemManager.apply_nightmare_gate_lock", function() ItemManager.apply_nightmare_gate_lock() end)
      -- Retry Helper/Combat Helper Sanity's own gates on the same cadence, same reasoning: these
      -- reach into zerp-NPCRoomRandomizer/zerp-Extended_NPC_Encounters/Zagreus' Journey tables
      -- that can still be mid-init (or skipped by a shared once_loaded.game dispatch abort
      -- elsewhere) the first time reload.lua ran. Each installer no-ops once it has actually
      -- installed, so this is cheap to leave running indefinitely.
      if retry_helper_gate_installs then pcall(retry_helper_gate_installs) end
      -- Retry the Daedalus Hammer grant on this same cadence too: the StartRoom/UnlockRoomExits
      -- hooks only try ONCE per room transition, and grant_pending_daedalus silently defers
      -- (no live CurrentRun.Hero yet / Routes.current() nil / Trait Tray open) with no automatic
      -- follow-up until the NEXT room event -- which can be an entire room later. A room takes
      -- real playtime to clear, which is exactly the window a player can walk into a real
      -- WeaponUpgrade reward door and pick a hammer up BEFORE the deferred grant ever lands --
      -- at which point grant_pending_daedalus's own "adopt pre-existing" self-heal (see its
      -- comment) mistakes that legitimately-earned hammer for one of the owed AP grants and
      -- shorts the player by however many hammers they found first. Retrying every ~0.5s instead
      -- of once-per-room-event shrinks that window from "up to a room" to "a fraction of a
      -- second," well under how long it takes to reach any real reward door. Same Trait Tray
      -- guard as the StartRoom/UnlockRoomExits call sites (AddTraitToHero mutates
      -- CurrentRun.Hero.Traits out from under that screen's cached component list); the function
      -- itself is idempotent/self-limiting, so leaving this running indefinitely is safe.
      if not (Notifications and Notifications.blocked and Notifications.blocked()) then
        AP_try("ItemManager.grant_pending_daedalus", function() ItemManager.grant_pending_daedalus() end)
      end
    end
    -- Poll the socket every frame.
    local ok, err = pcall(Bridge.update)
    if not ok then AP_log_error("[AP] update error: " .. tostring(err)) end

    -- Apply any queued incoming DeathLink, but only when the player is in a killable,
    -- unpaused state (see ItemManager.flush_pending_deathlink). Called by table lookup so a
    -- hot-reload picks up a new version. Held DeathLinks retry themselves every few seconds.
    -- Logging failures here (like the Bridge.update() pcall above) matters: an unlogged error
    -- would silently wedge a queued DeathLink forever with zero trace in the log.
    local dl_ok, dl_err = pcall(function()
      if ItemManager.flush_pending_deathlink then ItemManager.flush_pending_deathlink() end
    end)
    if not dl_ok then AP_log_error("[AP] DeathLink flush error: " .. tostring(dl_err)) end

    -- Apply any stashed incoming items, but only on a frame where receiving is safe (not mid-boon
    -- selection / conversation / pause -- see ItemManager.receive_safe). Held payloads apply
    -- automatically once the player is back in normal control.
    pcall(function() if ItemManager.drain_pending_items then ItemManager.drain_pending_items() end end)

    -- Fire a queued trap once the player is in a run with control (Traps.update). After the
    -- DeathLink flush above, which goes first. Traps.lua is imported by ready.lua, so a mod
    -- updated while the game is open has no Traps until the game restarts.
    if Traps then
      local trap_ok, trap_err = pcall(Traps.update)
      if not trap_ok then AP_log_error("[AP] trap update error: " .. tostring(trap_err)) end
    end

    -- Surface bridge-connection trouble: pinned in the corner overlay (never fades). We deliberately
    -- do NOT banner it -- the banner auto-dismisses too fast to read a diagnostic; the pinned corner
    -- line stays up until the bridge reconnects.
    local diag = Bridge.status_text and Bridge.status_text()
    if Overlay and Overlay.set_diag then Overlay.set_diag(diag) end
    -- Drain the in-game notification queue (native banners). Guarded internally.
    pcall(function() if Notifications then Notifications.update() end end)
    -- Draw the Archipelago overlay (score + sent/filler feed). Guarded internally.
    pcall(function() if Overlay then Overlay.draw() end end)
  end
  rom.gui.add_always_draw_imgui(render_frame)
  AP_live.frame = render_frame
end

-- ---- Overlay show/hide shortcut ---------------------------------------------
-- A global keyboard shortcut to toggle the overlay (so it can be reopened after the "x" close
-- button hides it). rom.inputs.on_key_pressed fires even while the game is focused and the mod
-- menu is closed -- the same input system that owns the Insert menu-toggle and the debug keys.
-- Guarded by a plugin global so a hot-reload doesn't stack duplicate handlers (the key only
-- re-registers, with the latest config value, on a full game restart).
if not AP_overlay_key_registered and rom.inputs and rom.inputs.on_key_pressed then
  local key = (config and config.overlay_toggle_key) or "F8"
  local function toggle_overlay()
    rom.log.info("[AP] overlay toggle key fired")
    if Overlay then Overlay.toggle() end
  end
  AP_live.toggle_overlay = toggle_overlay
  local ok, handle = pcall(function()
    return rom.inputs.on_key_pressed{ key, Name = "Archipelago: Toggle Overlay", toggle_overlay }
  end)
  if ok then
    AP_overlay_key_registered = true
    AP_overlay_key_handle = handle
    rom.log.info("[AP] overlay toggle key registered: " .. tostring(key))
  else
    AP_log_error("[AP] overlay toggle key registration failed: " .. tostring(handle))
  end
end

-- A menu-bar entry (visible when the Hell2Modding menu / Insert is open) as a discoverable,
-- no-keyboard way to show the overlay again and a reminder of the shortcut. Registered once.
if not AP_menu_bar_registered and rom.gui and rom.gui.add_to_menu_bar then
  local function menu_bar()
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
  end
  rom.gui.add_to_menu_bar(menu_bar)
  AP_live.menu_bar = menu_bar
  AP_menu_bar_registered = true
end
