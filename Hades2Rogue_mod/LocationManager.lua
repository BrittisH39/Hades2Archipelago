---@diagnostic disable: lowercase-global
-- LocationManager.lua — turns in-game progress into Archipelago location checks.
--
-- Three location systems (settings.location_system, matching the Python world):
--   0 point_based: each room cleared adds "its depth" to a per-route pool that persists
--      across runs/deaths; whenever the pool covers the next check's cost, that check is
--      earned and the pool draws down. Separate pool per route.
--   1 room_based: the first time you clear a room at depth N (per route) earns
--      "<route> Room NNNN".
--   2 per_weapon_room_based: like room_based, but per equipped weapon -
--      "<route> Room NNNN <Weapon>".

LocationManager = LocationManager or {}
-- All persistent progress lives in APState (the game save). See APState.lua.

-- Fixed room-check count for a route (sent in SETTINGS as <route>_room_count). This is
-- the cap for room_based / per_weapon_room_based and the ceiling the final-boss cascade
-- flushes up to. Defaults to 50 if the setting hasn't arrived yet.
local function room_limit(route)
  local key = (route == "Surface") and "surface_room_count" or "underworld_room_count"
  return tonumber(ItemManager.settings[key]) or 50
end

local function pad4(n)
  return string.format("%04d", n)
end

-- Build a room / per-weapon check name, matching the Python world's Locations._room_name.
-- slot 0 keeps the bare name ("<prefix> NNNN" / ".. <Weapon>", backward compatible with
-- pre-scaling seeds); slots >0 append " +k"; any weapon stays the LAST token so the rules'
-- last-token weapon parsing keeps working.
local function room_name(prefix, depth, slot, weapon)
  local name = prefix .. " " .. pad4(depth)
  if slot and slot > 0 then name = name .. " +" .. slot end
  if weapon then name = name .. " " .. weapon end
  return name
end

-- Send every location-multiplier "slot" check for one cleared room depth (location
-- auto-scaling). Each depth grants m checks: slot 0 is the bare name, slots 1..m-1 the " +k"
-- variants, weapon (if any) staying last. Returns the count sent. Used by BOTH the live
-- room-clear hooks and the boss cascade so they scale identically.
local function send_room_slots(prefix, depth, weapon)
  local m = ItemManager.location_multiplier()
  for slot = 0, m - 1 do
    local check = room_name(prefix, depth, slot, weapon)
    rom.log.info("[AP] check: " .. check .. " (room " .. depth .. " slot " .. slot
      .. (weapon and (" " .. weapon) or "") .. ")")
    Bridge.send("CHECK:" .. check)
  end
  return m
end

-- point_based draw-down / skip pass. Walks next_check upward, deciding each one:
--   * already checked on the server (CHECKEDSCORE) -> advance for FREE (no points, no resend)
--   * enough points banked              -> spend points and send the CHECK
--   * otherwise                          -> stop (wait for more depth)
-- Gap-safe: a checked 0017 while 0015 is unchecked only frees 0017 when next_check reaches it;
-- it never skips the unchecked 0015. Reusable so the CHECKEDSCORE handler (reload.lua) can
-- advance immediately when a check JUST became checked, without waiting for a room clear.
-- combine_pools halves the per-route score-check count; split_pools gives the full total.
function LocationManager.score_skip_pass(route, pool)
  local limit = ItemManager.score_limit_for(route)
  while pool.next_check <= limit do
    if ItemManager.is_score_checked(route, pool.next_check) then
      pool.next_check = pool.next_check + 1            -- already sent on the server: free skip
    elseif pool.points >= pool.next_check then
      pool.points = pool.points - pool.next_check
      local check = Routes.SCORE_PREFIX[route] .. " " .. pad4(pool.next_check)
      rom.log.info("[AP] check: " .. check .. " (" .. route .. ")")
      Bridge.send("CHECK:" .. check)
      pool.next_check = pool.next_check + 1
    else
      break
    end
  end
end

-- point_based: accumulate depth into the route's pool and draw down per earned check.
local function on_room_point(route, depth, pool)
  if depth <= 1 then pool.last_depth = 0 end       -- fresh run
  if depth <= pool.last_depth then return end       -- already scored this room
  pool.last_depth = depth
  pool.points = pool.points + depth

  LocationManager.score_skip_pass(route, pool)

  -- Wishlist "Score X/Y" readout: after clearing a room, pin the route's pool vs the next
  -- check's cost at the top of the overlay (always visible, never fades -- Test Run 6 #1). The
  -- "Sent Score Check N - ..." line comes from the client's CHECKED echo (see reload.lua).
  local limit = ItemManager.score_limit_for(route)
  if Overlay and Overlay.set_score and pool.next_check <= limit then
    Overlay.set_score("Score " .. pool.points .. "/" .. pool.next_check, Overlay.COLOR.score)
  end
end

-- room_based: send "<route> Room NNNN" (+ its " +k" multiplier slots) the first time each
-- depth is cleared.
local function on_room_room(route, depth, pool)
  local limit = room_limit(route)
  if depth <= limit and depth > (pool.room_high or 0) then
    pool.room_high = depth
    send_room_slots(Routes.ROOM_PREFIX[route], depth)
  end
end

-- per_weapon_room_based: send "<route> Room NNNN <Weapon>" (+ its " +k" multiplier slots) the
-- first time each depth is cleared with the currently-equipped weapon.
local function on_room_per_weapon(route, depth, pool)
  local weapon = ItemManager.current_weapon_short()
  if not weapon then return end
  pool.weapon_high = pool.weapon_high or {}
  local limit = room_limit(route)
  if depth <= limit and depth > (pool.weapon_high[weapon] or 0) then
    pool.weapon_high[weapon] = depth
    send_room_slots(Routes.ROOM_PREFIX[route], depth, weapon)
  end
end

-- combine_pools room_based: one SHARED "Room NNNN" pool keyed on depth only. The first
-- time depth N is cleared on EITHER route earns it (dedup via the shared high-water mark).
local function on_room_room_combined(depth)
  local s = APState.get()
  local cr = s.combined_rooms
  local limit = room_limit("Underworld")          -- both routes share the same count
  if depth <= limit and depth > (cr.room_high or 0) then
    cr.room_high = depth
    send_room_slots(Routes.COMBINED_ROOM_PREFIX, depth)
  end
end

-- combine_pools per_weapon_room_based: shared "Room NNNN <Weapon>" pool, per-weapon
-- high-water shared across routes.
local function on_room_per_weapon_combined(depth)
  local weapon = ItemManager.current_weapon_short()
  if not weapon then return end
  local s = APState.get()
  local cr = s.combined_rooms
  cr.weapon_high = cr.weapon_high or {}
  local limit = room_limit("Underworld")
  if depth <= limit and depth > (cr.weapon_high[weapon] or 0) then
    cr.weapon_high[weapon] = depth
    send_room_slots(Routes.COMBINED_ROOM_PREFIX, depth, weapon)
  end
end

-- A room counts toward score if it has a COMBAT encounter, OR grants a REWARD, OR is a SHOP
-- (Test Run 6 #6 -- the pre-boss reward room and shops should score, not just combat rooms).
-- Pure transition/hub rooms (no encounter, no reward, no store) still never score.
-- Combat = an Encounter whose EncounterType isn't "NonCombat" (EncounterData.lua); reward =
-- room.ChosenRewardType is set; shop = room.Store exists or its reward type is "Shop"
-- (RoomLogic.lua:278). Resolve EncounterType through EncounterData for inherited encounters.
local function room_has_combat(room)
  local enc = room and room.Encounter
  if not enc then return false end
  local etype = enc.EncounterType
    or (enc.Name and game.EncounterData and game.EncounterData[enc.Name]
        and game.EncounterData[enc.Name].EncounterType)
  return etype ~= nil and etype ~= "NonCombat"
end

local function room_is_shop(room)
  return room ~= nil and (room.Store ~= nil or room.ChosenRewardType == "Shop")
end

local function room_qualifies_for_score(room)
  return room_has_combat(room)
    or (room ~= nil and room.ChosenRewardType ~= nil)
    or room_is_shop(room)
end

-- =============================================================================
-- enemy_locations / npc_locations  (More Locations.txt)
-- =============================================================================

-- Every enemy first-defeat check, by bare enemy name. The AP location is "<Enemy> Defeated"
-- (the " Defeated" suffix is added at send time); these bare names mirror the Python world's
-- ENEMY_LAYERS so unit-id matching stays simple.
local ENEMY_CHECK_LIST = {
  -- Underworld
  "Casket", "Lanthorn", "Sister of the Dead", "Spindle", "Wailer", "Wastrel",
  "Whisper", "Thorn-Weeper", "Root-Stalker", "Shadow-Spiller", "Headmistress Hecate",
  "Master-Slicer", "Dread-Wailer",
  "Hippo", "Lurker", "Pinhead", "Sea-Serpent", "Shellback", "Sop-Spindle",
  "Wet-Whisper", "Wretched Pest", "Deep Serpent", "Hellifish", "King Vermin",
  "Scylla and the Sirens",
  -- Asphodel (Anomaly detour) -- shares the Oceanus sphere (Test Run 5 #13)
  "Wretched Witch", "Bloodless", "Bone-Raker", "Wave-Maker", "Inferno-Bomber",
  "Slam-Dancer", "Burn-Flinger",
  "Bawlder", "Blight-Shade", "Bloat-Shade", "Blood-Shade", "Canine", "Holeheart",
  "Lamia", "Lycaon", "Mourner", "Smacker", "Sorrow-Spiller", "Phantom",
  "Queen Lamia", "Brush-Stalker", "Infernal Beast",
  "Crawler", "Goldwraith", "Numbskull", "Sandskull", "Satyr Hoplite",
  "Satyr Supplicant", "Satyr Vierophant", "Tempus", "Wretched Thug", "Goldwrath",
  "Verminancer", "Wringer", "Chronos",
  -- Surface
  "Bronzebeak", "Cutthroat", "Eidolon", "Lubber", "Shambler", "Tombstone",
  "Satyr Champion", "Erymanthian Boar", "The Cyclops Polyphemus",
  "Anchor", "Blasket", "Boozer", "Droplet", "Harpy Talon", "Sea-Shambler",
  "Seesword", "Stickler", "Charybdis", "The Yargonaut", "Eris",
  "Auto-Forcer", "Auto-Seeker", "Auto-Watcher", "Harpy Raptor", "Satyr Goldpike",
  "Satyr Raider", "Satyr Sapper", "Sky-Dracon", "Snow-Shambler", "Mega-Dracon",
  "Talos", "Prometheus",
  "Eyesore", "Headstone", "Horror", "Land-Dracon", "Polyp", "Stalker",
  "Eye of Typhon", "Spawn of Typhon", "Tail of Typhon", "Twins of Typhon", "Typhon",
}

-- ⚠ In-game unit ids (the `.Name` on a slain unit / EnemyData key) usually DON'T match the
-- AP display names above. Map the real id -> AP check name here. When enemy_locations is on
-- and an unmapped enemy dies, on_enemy_killed() logs its real id ONCE so you can fill this
-- table by playing. Identity (unit id == AP name) is assumed for anything not overridden.
-- Built from the game's own data (HelpText.en.sjson Id->DisplayName + CodexData unit lists,
-- June 27). Key = the spawned unit's `.Name` (EnemyData/UnitSetData key); value = AP check.
-- Enemies whose unit key already equals the AP name (Crawler, Stalker, Lamia, Mourner,
-- Stickler, Talos, Charybdis, Chronos, Eris, Prometheus, Wringer) are handled by identity below.
LocationManager.ENEMY_UNIT_OVERRIDE = LocationManager.ENEMY_UNIT_OVERRIDE or {
  ["AutomatonBeamer"] = "Auto-Watcher",
  ["AutomatonEnforcer"] = "Auto-Forcer",
  -- Asphodel "Anomaly" detour foes (Test Run 5 #13). Both the base and _Elite spawns map to
  -- the same AP check so either variant counts as the first defeat.
  ["SpreadShotUnit"] = "Wretched Witch",
  ["SpreadShotUnit_Elite"] = "Wretched Witch",
  ["BloodlessNaked"] = "Bloodless",
  ["BloodlessNaked_Elite"] = "Bloodless",
  ["BloodlessBerserker"] = "Bone-Raker",
  ["BloodlessBerserker_Elite"] = "Bone-Raker",
  ["BloodlessWaveFist"] = "Wave-Maker",
  ["BloodlessWaveFist_Elite"] = "Wave-Maker",
  ["BloodlessGrenadier"] = "Inferno-Bomber",
  ["BloodlessGrenadier_Elite"] = "Inferno-Bomber",
  ["BloodlessSelfDestruct"] = "Slam-Dancer",
  ["BloodlessSelfDestruct_Elite"] = "Slam-Dancer",
  ["BloodlessPitcher"] = "Burn-Flinger",
  ["BloodlessPitcher_Elite"] = "Burn-Flinger",
  ["Boar"] = "Erymanthian Boar",   -- City of Ephyra miniboss (spawned unit .Name is "Boar")
  ["Brawler"] = "Wastrel",
  ["BrokenHearted"] = "Smacker",
  ["Brute"] = "Horror",
  ["Brute_Miniboss"] = "Spawn of Typhon",
  ["Captain"] = "The Yargonaut",
  ["Carrion"] = "Bronzebeak",
  ["ClockworkHeavyMelee"] = "Wretched Thug",
  ["CorruptedShadeLarge"] = "Bloat-Shade",
  ["CorruptedShadeMedium"] = "Blood-Shade",
  ["CorruptedShadeSmall"] = "Blight-Shade",
  ["CrawlerMiniboss"] = "King Vermin",
  ["DespairElemental"] = "Bawlder",
  ["Dragon"] = "Sky-Dracon",
  ["DragonBurrower"] = "Land-Dracon",
  ["Dragon_MiniBoss"] = "Mega-Dracon",
  ["Drunk"] = "Boozer",
  ["EarthElemental"] = "Headstone",
  ["FishSwarmer"] = "Pinhead",
  ["FishmanMelee"] = "Lurker",
  ["FishmanRanged"] = "Hippo",
  ["FogEmitter"] = "Shadow-Spiller",
  ["FogEmitter2"] = "Sorrow-Spiller",
  ["GoldElemental"] = "Goldwraith",
  ["GoldElemental_MiniBoss"] = "Goldwrath",
  ["Guard"] = "Whisper",
  ["Guard2"] = "Wet-Whisper",
  ["HarpyCutter"] = "Harpy Talon",
  ["HarpyDropper"] = "Harpy Raptor",
  ["Hecate"] = "Headmistress Hecate",
  ["InfestedCerberus"] = "Infernal Beast",
  ["Lamia_Miniboss"] = "Queen Lamia",
  ["LightRanged"] = "Sister of the Dead",
  ["Lovesick"] = "Holeheart",
  ["LycanSwarmer"] = "Canine",
  ["Lycanthrope"] = "Lycaon",
  ["Mage"] = "Casket",
  ["Mage2"] = "Blasket",
  ["Mati"] = "Eyesore",
  ["Mudman"] = "Eidolon",
  ["Octofish_Miniboss"] = "Hellifish",
  ["Polyphemus"] = "The Cyclops Polyphemus",
  ["Radiator"] = "Spindle",
  ["Radiator2"] = "Sop-Spindle",
  ["SatyrCrossbow"] = "Satyr Champion",
  ["SatyrCrossbow2"] = "Satyr Raider",
  ["SatyrCultist"] = "Satyr Supplicant",
  ["SatyrLancer"] = "Satyr Hoplite",
  ["SatyrLancer2"] = "Satyr Goldpike",
  ["SatyrRatCatcher"] = "Satyr Vierophant",
  ["SatyrRatCatcher_Miniboss"] = "Verminancer",
  ["SatyrSapper"] = "Satyr Sapper",
  ["Scimiterror"] = "Seesword",
  ["Screamer"] = "Wailer",
  ["Screamer2"] = "Dread-Wailer",
  ["Scylla"] = "Scylla and the Sirens",
  ["SentryBot"] = "Auto-Seeker",
  ["SiegeVine"] = "Thorn-Weeper",
  ["Simple"] = "Polyp",
  ["Stalker_Miniboss"] = "Twins of Typhon",
  ["Swab"] = "Anchor",
  ["Swarmer"] = "Numbskull",
  ["SwarmerClockwork"] = "Sandskull",
  ["ThiefMineLayer"] = "Wretched Pest",
  ["TimeElemental"] = "Tempus",
  ["Treant"] = "Root-Stalker",
  ["Treant2"] = "Brush-Stalker",
  ["Turtle"] = "Shellback",
  ["TyphonEye"] = "Eye of Typhon",
  ["TyphonHead"] = "Typhon",
  ["TyphonTail"] = "Tail of Typhon",
  ["Vampire"] = "Phantom",
  ["WaterElemental"] = "Droplet",
  ["WaterUnit"] = "Sea-Serpent",
  ["WaterUnitMiniboss"] = "Deep Serpent",
  ["Wisp"] = "Lanthorn",
  ["Zombie"] = "Shambler",
  ["ZombieAssassin"] = "Cutthroat",
  ["ZombieAssassin_Miniboss"] = "Master-Slicer",
  ["ZombieCrewman"] = "Sea-Shambler",
  ["ZombieHeavyRanged"] = "Lubber",
  ["ZombieOlympus"] = "Snow-Shambler",
  ["ZombieSpawner"] = "Tombstone",
}

local UNIT_TO_ENEMY_CHECK = {}
for _, name in ipairs(ENEMY_CHECK_LIST) do UNIT_TO_ENEMY_CHECK[name] = name end
for unit, name in pairs(LocationManager.ENEMY_UNIT_OVERRIDE) do UNIT_TO_ENEMY_CHECK[unit] = name end

-- Route boss "Met" checks, keyed by (route, zone). Fired the first time you clear a combat
-- room in that boss's layer (access = reaching the layer, matching the Python region gating).
local BOSS_MET_BY_ZONE = {
  Underworld = { [1] = "Met Hecate", [2] = "Met Scylla", [3] = "Met Cerberus", [4] = "Met Chronos" },
  Surface    = { [1] = "Met Polyphemus", [2] = "Met Eris", [3] = "Met Prometheus", [4] = "Met Typhon" },
}

-- Bosses you meet regardless of route (Hecate mentors you at the Crossroads from the start).
-- Their "Met" location is always generated and start-reachable (Python ALWAYS_MET_BOSSES), so it
-- must NOT be route-gated here. Keep in sync with Python: add "Met Eris" if Eris is confirmed
-- meetable off the Surface.
local ALWAYS_MET_BOSS = { ["Met Hecate"] = true }

-- Reverse map: route-gated boss "Met X" check -> the route whose activation gates it. A boss meet
-- can be detected through the un-route-gated cast paths (Crossroads conversation, field encounter,
-- boon pickup -- all via NPC_CAST_SET below), not just the boss-arena path. On a seed that excludes
-- a route, that route's boss "Met" location is never generated (Regions.py), so firing it anyway
-- makes the client log "Unknown location checked by game". Gate those meets on their route wherever
-- detected (see send_first); always-met bosses are excluded since their location always exists.
local BOSS_MET_ROUTE = {}
for _route, _byzone in pairs(BOSS_MET_BY_ZONE) do
  for _, _check in pairs(_byzone) do
    if not ALWAYS_MET_BOSS[_check] then BOSS_MET_ROUTE[_check] = _route end
  end
end

-- Crossroads cast "Met" checks (must match the Python NPC_CAST). Keyed by the AP check name.
-- As with enemies, map the real in-game NPC id -> "Met <Name>" here; on_npc_interacted()
-- logs unmapped ids when npc_locations is on. Identity is assumed otherwise.
local NPC_CAST = {
  "Moros", "Skelly", "Dora", "Nemesis", "Artemis", "Selene", "Charon", "Odysseus",
  "Circe", "Narcissus", "Arachne", "Icarus", "Heracles", "Medea", "Hermes", "Echo",
  -- Zagreus is intentionally absent (Python NPC_NO_MEET): he's only reachable via the scripted
  -- Elysium "memory" rescue, which we don't force, so "Met Zagreus" would be a dead check.
  "Chaos", "Dionysus", "Athena", "Hades", "Hephaestus", "Zeus", "Demeter",
  "Aphrodite", "Poseidon", "Apollo", "Hestia", "Ares", "Hera",
  -- Non-keepsake meet-able NPC (Test Run 5 #5): met by talking to NPC_Hypnos_01 once awake.
  "Hypnos",
}
LocationManager.NPC_UNIT_OVERRIDE = LocationManager.NPC_UNIT_OVERRIDE or {
  -- ["NPC_Hecate_01"] = "Met Hecate",   -- example
  -- Explicit (not relying on the "NPC_<Char>_.." parse fallback): the Underworld "Curse of
  -- Eris" ambush spawns unit id "NPC_Eris_01" (RoomDataG/H/I.lua SpawnErisForCurse), same id
  -- used for her Crossroads/bath appearances. "Met Eris" stays Surface-gated (send_first's
  -- BOSS_MET_ROUTE check), so this only actually sends when Surface is part of the seed.
  ["NPC_Eris_01"] = "Met Eris",
}
local UNIT_TO_NPC_CHECK = {}
for _, name in ipairs(NPC_CAST) do UNIT_TO_NPC_CHECK[name] = "Met " .. name end
for unit, name in pairs(LocationManager.NPC_UNIT_OVERRIDE) do UNIT_TO_NPC_CHECK[unit] = name end

-- In-game NPC unit ids follow the pattern NPC_<Char>_<variant> (e.g. NPC_Nemesis_01,
-- NPC_Hades_Field_01, NPC_Zeus_Story_01 - confirmed across NPCData*.lua). So rather than
-- hand-listing every unit id, we parse <Char> out of the name and match it to the cast.
-- Bosses (Hecate, Scylla, ...) are included too: the wishlist says their "Met" check fires
-- "however they first meet them", so talking to one at the Crossroads counts as well as
-- reaching their layer (send_first dedups whichever happens first).
local NPC_CAST_SET = {}
for _, name in ipairs(NPC_CAST) do NPC_CAST_SET[name] = "Met " .. name end
for _, byzone in pairs(BOSS_MET_BY_ZONE) do
  for _, check in pairs(byzone) do
    local char = check:match("^Met (%a+)$")
    if char then NPC_CAST_SET[char] = check end
  end
end

local _logged_unmapped_enemies = {}
local _logged_unmapped_npcs = {}

-- Send a check once: guarded by a per-save set so a re-kill / re-talk never re-sends.
local function send_first(set, name)
  local s = APState.get()
  if not s or not s[set] then return end
  if s[set][name] then return end
  -- A boss "Met" reached via a cast path (hub chat / field encounter / boon) isn't route-gated
  -- by its caller, so block it here if its route is excluded -- that location doesn't exist in
  -- the seed. Don't poison the dedup set: leave it unset so a legit meet can still fire later.
  local boss_route = BOSS_MET_ROUTE[name]
  if boss_route and not ItemManager.route_active(boss_route) then return end
  s[set][name] = true
  Bridge.send("CHECK:" .. name)
  rom.log.info("[AP] check: " .. name .. " (" .. set .. ")")
end

-- Wrapped on every unit death (reload.lua). If enemy_locations is on and the unit maps to
-- an enemy check, send it (first time only). Unmapped enemies are logged once for discovery.
function LocationManager.on_enemy_killed(unit)
  if not ItemManager.setting_on("enemy_locations") then return end
  local id = unit and unit.Name
  if not id then return end
  local check = UNIT_TO_ENEMY_CHECK[id]
  if not check and type(id) == "string" then
    -- Elite spawns share their base unit's AP check (only the Bloodless/Anomaly family had
    -- explicit "_Elite" entries above; every other enemy's Elite variant was silently dropped
    -- until this fallback -- e.g. Brawler_Elite, Guard_Elite, Mage_Elite never sent "Defeated").
    local base_id = id:match("^(.-)_Elite$")
    if base_id then check = UNIT_TO_ENEMY_CHECK[base_id] end
  end
  if check then
    -- Python location names are "<Enemy> Defeated"; UNIT_TO_ENEMY_CHECK holds the bare
    -- enemy name (so unit-id matching stays simple), so add the suffix at send time.
    send_first("enemy_killed", check .. " Defeated")
  else
    -- No mapping. Surface the real id once so ENEMY_UNIT_OVERRIDE can be completed in-game.
    -- The old heuristic only logged units with EnemyData/AIData; minibosses and special foes
    -- can carry their data elsewhere, so they slipped through silently (Test Run 5 #18). Treat
    -- anything with combat fields, or a name that looks like a foe/miniboss, as loggable.
    local looks_like_foe = unit.EnemyData or unit.AIData or unit.MaxHealth or unit.WeaponData
      or (type(id) == "string" and (id:find("Miniboss") or id:find("MiniBoss") or id:find("_Boss")))
    if looks_like_foe and not _logged_unmapped_enemies[id] then
      _logged_unmapped_enemies[id] = true
      rom.log.info("[AP] enemy_locations: unmapped foe id '" .. tostring(id)
        .. "' (add it to LocationManager.ENEMY_UNIT_OVERRIDE to make it a check)")
    end
  end
end

-- Wrapped on UseNPC (reload.lua) - the confirmed conversation entry point. Sends
-- "Met <Name>" the first time you talk to each cast member. Resolution order:
--   1. explicit NPC_UNIT_OVERRIDE / identity match on the raw unit id, then
--   2. parse NPC_<Char>_... and match <Char> against the cast list.
-- Anything that looks like an NPC but maps to nothing is logged once for discovery.
function LocationManager.on_npc_interacted(unit)
  if not ItemManager.setting_on("npc_locations") then return end
  local id = unit and unit.Name
  if not id then return end
  local check = UNIT_TO_NPC_CHECK[id]
  if not check then
    local char = id:match("^NPC_(%a+)")
    if char then check = NPC_CAST_SET[char] end
  end
  if check then
    send_first("npc_met", check)
  elseif id:match("^NPC_") and not _logged_unmapped_npcs[id] then
    _logged_unmapped_npcs[id] = true
    rom.log.info("[AP] npc_locations: unmapped NPC id '" .. tostring(id)
      .. "' (add it to LocationManager.NPC_UNIT_OVERRIDE as \"Met <Name>\")")
  end
end

-- Wrapped on HandleLootPickup (reload.lua). Boon gods aren't NPC conversations - they're
-- loot interactions, so UseNPC never fires for them. The boon's loot.Name is "<God>Upgrade"
-- (ZeusUpgrade, HeraUpgrade, ...). Interacting plays the god's greeting (GodLootPickupPresentation)
-- BEFORE the boon menu, so this is the "meet" moment. First time only; dedups with the
-- Crossroads cast meet via the shared npc_met set.
function LocationManager.on_loot_pickup(loot)
  if not ItemManager.setting_on("npc_locations") then return end
  if not loot then return end
  local id = loot.Name
  -- Prefer the loot's SpeakerName: it's the speaking god/NPC and is reliable across the
  -- non-"<God>Upgrade" loot names. Chaos boons are loot.Name "TrialUpgrade" (SpeakerName
  -- "Chaos") and Selene's Hexes are "SpellDrop" (SpeakerName "Selene"), so the old
  -- "^(%a+)Upgrade$" parse never matched them -> Met Chaos / Met Selene never fired
  -- (Test Run 5 #15/#6). SpeakerName catches those and the ZeusUpgrade-style god boons alike.
  local who = loot.SpeakerName
  if not (who and NPC_CAST_SET[who]) and id then
    who = id:match("^(%a+)Upgrade$")
  end
  -- Test Run 6 #5: walking into a SHOP sent "Met Selene". A shop's purchasable wares are loots
  -- carrying the selling god's SpeakerName, so browsing them tripped the meet. Don't count a meet
  -- from loot while in a shop room -- you haven't actually met them, just seen their ware. The
  -- real meet still fires elsewhere (UseNPC / a non-shop boon pickup / the field encounter).
  local room = game.CurrentRun and game.CurrentRun.CurrentRoom
  local in_shop = room ~= nil and (room.Store ~= nil or room.ChosenRewardType == "Shop")
  if who and NPC_CAST_SET[who] and in_shop then
    rom.log.info("[AP] loot meet suppressed in shop: who=" .. tostring(who)
      .. " loot=" .. tostring(id) .. " roomReward=" .. tostring(room.ChosenRewardType))
    return
  end
  if who and NPC_CAST_SET[who] then
    rom.log.info("[AP] loot meet: who=" .. tostring(who) .. " loot=" .. tostring(id)
      .. " SpeakerName=" .. tostring(loot.SpeakerName))
    send_first("npc_met", NPC_CAST_SET[who])
  elseif (loot.GodLoot or loot.SpeakerName) and id and not _logged_unmapped_npcs[id] then
    -- A god/NPC boon we don't have a cast entry for: log once for discovery.
    _logged_unmapped_npcs[id] = true
    rom.log.info("[AP] npc_locations: unmapped loot '" .. tostring(id)
      .. "' SpeakerName='" .. tostring(loot.SpeakerName)
      .. "' (add the name to NPC_CAST or map it as \"Met <Name>\")")
  end
end

-- Fire the route boss "Met" check for a (route, zone), first time only. Declared before
-- on_encounter_started (which calls it) so it's in lexical scope there, not a nil global.
local function send_boss_met(route, zone)
  if not ItemManager.setting_on("npc_locations") then return end
  local byzone = BOSS_MET_BY_ZONE[route]
  local name = byzone and byzone[zone]
  if name then send_first("npc_met", name) end
end

-- Wrapped on StartEncounter (reload.lua). Field-NPC combat encounters (Artemis, Athena,
-- Heracles, ... -- EncounterData_<Name>.lua) carry SpeakerNames = { "<Name>" }. Those NPCs
-- aren't conversations (UseNPC) or loot (HandleLootPickup), so neither hook fired for them
-- (Test Run 5 #3: "Met Artemis didn't fire" in the underworld field encounter). Firing on the
-- encounter start is the moment you meet them. First time only (send_first dedups).
function LocationManager.on_encounter_started(encounter)
  if not ItemManager.setting_on("npc_locations") then return end
  if not encounter then return end
  local data = (encounter.Name and game.EncounterData and game.EncounterData[encounter.Name])
    or encounter
  local speakers = data and data.SpeakerNames
  if type(speakers) == "table" then
    for _, who in ipairs(speakers) do
      if NPC_CAST_SET[who] then
        local room = game.CurrentRun and game.CurrentRun.CurrentRoom
        rom.log.info("[AP] encounter meet: who=" .. tostring(who)
          .. " encounter=" .. tostring(encounter.Name)
          .. " RoomSetName=" .. tostring(room and room.RoomSetName)
          .. " reward=" .. tostring(room and room.ChosenRewardType))
        send_first("npc_met", NPC_CAST_SET[who])
      end
    end
  end

  -- Boss "Met" (Test Run 6 #7: "Met Hecate" didn't fire in her boss fight). Reading
  -- EncounterType at StartRoom (on_room_started) was unreliable -- the encounter isn't always
  -- resolved that early. Here at StartEncounter the encounter is fully built, and every boss
  -- arena encounter inherits EncounterType == "Boss" (BossEncounter base, EncounterData.lua:913).
  -- Fire the route's zone boss "Met" when a Boss encounter starts. send_first dedups with
  -- on_room_started (whichever wins first).
  local etype = encounter.EncounterType or (data and data.EncounterType)
  if etype == "Boss" then
    local route, zone = Routes.current()
    rom.log.info("[AP] boss encounter start: name=" .. tostring(encounter.Name)
      .. " route=" .. tostring(route) .. " zone=" .. tostring(zone))
    if route and ItemManager.route_active(route) then
      pcall(function() send_boss_met(route, zone) end)
    end
  end
end

-- Fire a fixed-name NPC/intro check directly (e.g. story beats "SHUSH Homer",
-- "Find Hecate 1"). First time only.
function LocationManager.send_npc_check(name)
  if not ItemManager.setting_on("npc_locations") then return end
  send_first("npc_met", name)
end

-- Wrapped on ApplyErisCurse (reload.lua) - fires once the Underworld "Curse of Eris" ambush's
-- dialogue resolves (ShrineLogic.lua), a reliable meet-signal independent of whether UseNPC
-- fired for that scripted spawn. Same dedup/gate as everything else: send_first only actually
-- sends "Met Eris" when Surface is part of the seed (BOSS_MET_ROUTE), so this is a no-op on an
-- Underworld-only seed where the location doesn't exist.
function LocationManager.on_eris_curse_applied()
  if not ItemManager.setting_on("npc_locations") then return end
  send_first("npc_met", "Met Eris")
end

-- The EncounterType of a room's encounter ("Boss", "MiniBoss", normal, ...). Boss arenas are
-- the only rooms with EncounterType == "Boss".
local function room_encounter_type(room)
  local enc = room and room.Encounter
  if not enc then return nil end
  return enc.EncounterType
    or (enc.Name and game.EncounterData and game.EncounterData[enc.Name]
        and game.EncounterData[enc.Name].EncounterType)
end

-- Call when a room STARTS (StartRoom hook). Boss "Met" must fire when you actually meet the
-- boss -- i.e. walk into its arena -- NOT the moment you reach the boss's biome (Test Run 5
-- #7: "Met Scylla fired well before I actually met her"). Only the boss arena room has
-- EncounterType == "Boss", so gate on that. First time only (send_first dedups).
function LocationManager.on_room_started(room)
  if not ItemManager.setting_on("npc_locations") then return end
  room = room or (game.CurrentRun and game.CurrentRun.CurrentRoom)
  if room_encounter_type(room) ~= "Boss" then return end
  local route, zone = Routes.current()
  if not route or not ItemManager.route_active(route) then return end
  pcall(function() send_boss_met(route, zone) end)
end

-- Score a room (Test Run 6 #6). Called from BOTH the room-clear hook (UnlockRoomExits, is_clear
-- true) and the room-start hook (StartRoom, is_clear false). The mod keeps its OWN per-run depth
-- counter (s.score[route].depth_counter) that bumps once for each qualifying room -- combat OR
-- reward OR shop -- instead of the game's combat-only EncounterDepth. Combat rooms are scored on
-- CLEAR (you have to fight first); reward-only and shop rooms are scored on ENTER (no enemies to
-- clear). Each room is counted at most once via a flag on the room table (room._ap_scored), so the
-- two trigger points never double-count, and UnlockRoomExits firing repeatedly is safe.
function LocationManager.score_room(room, is_clear)
  local s = APState.get()
  if not s then
    rom.log.info("[AP] score room: no save state (APState.get nil) - skipping")
    return
  end
  room = room or (game.CurrentRun and game.CurrentRun.CurrentRoom)
  if not room then return end
  local route, zone = Routes.current()
  if not route then return end                              -- hub / Chaos / non-scored biome
  if not ItemManager.route_active(route) then return end    -- excluded route: no checks
  -- Don't send room checks for an area the player hasn't unlocked yet (Test Run 8 #1). The
  -- surface-start seed's forced Underworld intro is here before its bounce-to-Crossroads death;
  -- without this it sends "Underworld Room 1" for a zone the player has no access to. Same gate as
  -- the route-lock kill, so a zone that would kill you also never scores.
  if not ItemManager.route_zone_unlocked(route, zone) then
    rom.log.info("[AP] score room: " .. route .. " z" .. tostring(zone)
      .. " not unlocked yet - no room check")
    return
  end
  if room._ap_scored then return end                        -- already counted this room

  local combat = room_has_combat(room)
  -- Combat rooms wait for the clear; reward-only / shop rooms count the moment you enter.
  if combat and not is_clear then return end
  if not room_qualifies_for_score(room) then return end     -- pure transition/hub room: never scores

  local system = ItemManager.setting_mode("location_system")
  -- per_weapon checks ("<route> Room NNNN <Weapon>") additionally require the equipped weapon to be
  -- AP-unlocked (Test Run 8 #1): no "Staff Underworld Room 1" while the forced intro holds a Staff
  -- the player hasn't unlocked. Checked before counting the room so the depth counter stays in sync.
  if system == 2 and not ItemManager.equipped_weapon_unlocked() then
    rom.log.info("[AP] score room: equipped weapon not AP-unlocked - no per-weapon room check")
    return
  end

  room._ap_scored = true
  local pool = s.score[route]
  pool.depth_counter = (pool.depth_counter or 0) + 1
  local depth = pool.depth_counter

  rom.log.info("[AP] score room: RoomSetName=" .. tostring(room.RoomSetName)
    .. " RoomName=" .. tostring(room.Name)
    .. " combat=" .. tostring(combat) .. " reward=" .. tostring(room.ChosenRewardType)
    .. " shop=" .. tostring(room_is_shop(room)) .. " -> route=" .. route
    .. " depth=" .. depth .. " system=" .. tostring(system) .. " is_clear=" .. tostring(is_clear))

  -- Boss "Met" fires from on_encounter_started (entering the boss arena), not here.

  local combine = ItemManager.combine_active()
  if system == 1 then
    if combine then on_room_room_combined(depth) else on_room_room(route, depth, pool) end
  elseif system == 2 then
    if combine then on_room_per_weapon_combined(depth) else on_room_per_weapon(route, depth, pool) end
  else
    on_room_point(route, depth, pool)   -- point uses score_limit_for(route) internally
  end
end

-- Boss cascade (room systems only): once the route's FINAL boss is defeated, the player
-- has "completed" the route, so release every remaining room check for it instead of
-- making them grind RNG for the last few rooms. room_based flushes the route's shared
-- room checks; per_weapon_room_based flushes only the weapon that just cleared the run.
local function flush_route_rooms(route, pool)
  local system = ItemManager.setting_mode("location_system")
  local combine = ItemManager.combine_active()
  local limit = room_limit(route)
  -- Each depth releases all location_multiplier slot checks (send_room_slots), so a scaled
  -- seed's "+k" room locations are flushed too, not just slot 0.
  if system == 1 then
    if combine then
      -- One shared pool: flush the combined "Room NNNN" checks once (either final boss).
      local cr = APState.get().combined_rooms
      local sent = 0
      for depth = (cr.room_high or 0) + 1, limit do
        sent = sent + send_room_slots(Routes.COMBINED_ROOM_PREFIX, depth)
      end
      cr.room_high = math.max(cr.room_high or 0, limit)
      rom.log.info("[AP] boss cascade: flushed " .. sent .. " combined room checks (up to " .. limit .. ")")
      return
    end
    local sent = 0
    for depth = (pool.room_high or 0) + 1, limit do
      sent = sent + send_room_slots(Routes.ROOM_PREFIX[route], depth)
    end
    pool.room_high = math.max(pool.room_high or 0, limit)
    rom.log.info("[AP] boss cascade: flushed " .. sent .. " " .. route .. " room checks (up to " .. limit .. ")")
  elseif system == 2 then
    local weapon = ItemManager.current_weapon_short()
    if not weapon then return end
    if combine then
      local cr = APState.get().combined_rooms
      cr.weapon_high = cr.weapon_high or {}
      local sent = 0
      for depth = (cr.weapon_high[weapon] or 0) + 1, limit do
        sent = sent + send_room_slots(Routes.COMBINED_ROOM_PREFIX, depth, weapon)
      end
      cr.weapon_high[weapon] = math.max(cr.weapon_high[weapon] or 0, limit)
      rom.log.info("[AP] boss cascade: flushed " .. sent .. " combined " .. weapon
        .. " room checks (up to " .. limit .. ")")
      return
    end
    pool.weapon_high = pool.weapon_high or {}
    local sent = 0
    for depth = (pool.weapon_high[weapon] or 0) + 1, limit do
      sent = sent + send_room_slots(Routes.ROOM_PREFIX[route], depth, weapon)
    end
    pool.weapon_high[weapon] = math.max(pool.weapon_high[weapon] or 0, limit)
    rom.log.info("[AP] boss cascade: flushed " .. sent .. " " .. route .. " " .. weapon
      .. " room checks (up to " .. limit .. ")")
  end
end

local function distinct_weapons(s, route)
  local n = 0
  for _ in pairs(s.weapons_cleared[route] or {}) do n = n + 1 end
  return n
end

-- Send the goal state: Chronos clears / distinct weapons, then Typhon clears / weapons.
function LocationManager.send_victory()
  local s = APState.get()
  if not s then return end
  Bridge.send("VICTORY:" .. s.chronos_clears .. "-" .. distinct_weapons(s, "Underworld")
    .. "-" .. s.typhon_clears .. "-" .. distinct_weapons(s, "Surface"))
end

-- Call when a run is cleared (final boss defeated). `route` is Underworld (Chronos)
-- or Surface (Typhon); `weapon_id` is the weapon used, for the goal weapon count.
function LocationManager.on_run_cleared(route, weapon_id)
  local s = APState.get()
  if not s then return end
  if route == "Surface" then
    s.typhon_clears = s.typhon_clears + 1
  else
    s.chronos_clears = s.chronos_clears + 1
  end
  if route and weapon_id then
    s.weapons_cleared[route][weapon_id] = true
  end
  rom.log.info("[AP] run cleared: " .. tostring(route) .. " (weapon " .. tostring(weapon_id) .. ")")
  -- Boss cascade: defeating the route's final boss releases the rest of its room checks.
  if route and ItemManager.route_active(route) and s.score[route] then
    pcall(function() flush_route_rooms(route, s.score[route]) end)
  end
  LocationManager.send_victory()
end

-- Call when Melinoë dies (for DeathLink broadcasting).
function LocationManager.on_death()
  Bridge.send("DEATH")
end
