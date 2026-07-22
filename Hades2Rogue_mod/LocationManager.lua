---@diagnostic disable: lowercase-global
-- LocationManager.lua — turns in-game progress into Archipelago location checks.
--
-- Three location systems (settings.location_system, matching the Python world):
--   0 point_based: each room cleared adds "its depth" to a points pool that persists across
--      runs/deaths; whenever the pool covers the next check's cost, that check is earned and
--      the pool draws down. separate_checks decides the pool: split_pools gives each route its
--      own ("<Route> Score NNNN"), combine_pools one shared route-agnostic pool every route
--      banks into ("Score NNNN") -- see LocationManager.score_pool_for.
--   1 room_based: the first time you clear a room at depth N (per route) earns
--      "<route> Room NNNN".
--   2 per_weapon_room_based: like room_based, but per equipped weapon -
--      "<route> Room NNNN <Weapon>".

LocationManager = LocationManager or {}
-- All persistent progress lives in APState (the game save). See APState.lua.

-- Fixed room-check count for a route (sent in SETTINGS as <route>_room_count). This is
-- the cap for room_based / per_weapon_room_based and the ceiling the final-boss cascade
-- flushes up to. Defaults to 50 if the setting hasn't arrived yet.
local ROOM_LIMIT_KEY = {
  Underworld = "underworld_room_count", Surface = "surface_room_count", Nightmare = "nightmare_room_count",
}
local function room_limit(route)
  local key = ROOM_LIMIT_KEY[route] or "underworld_room_count"
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
-- Every pool holds the full score_rewards_amount: split_pools gives each route its own,
-- combine_pools has one shared route-agnostic pool (see LocationManager.score_pool_for).
function LocationManager.score_skip_pass(pool_key, pool)
  local limit = ItemManager.score_limit_for(pool_key)
  while pool.next_check <= limit do
    if ItemManager.is_score_checked(pool_key, pool.next_check) then
      pool.next_check = pool.next_check + 1            -- already sent on the server: free skip
    elseif pool.points >= pool.next_check then
      pool.points = pool.points - pool.next_check
      local check = Routes.SCORE_PREFIX[pool_key] .. " " .. pad4(pool.next_check)
      rom.log.info("[AP] check: " .. check .. " (" .. pool_key .. ")")
      Bridge.send("CHECK:" .. check)
      pool.next_check = pool.next_check + 1
    else
      break
    end
  end
end

-- Which point_based pool a route's cleared rooms bank into, as (pool_key, pool).
--   split_pools:   that route's own pool -> "<Route> Score NNNN".
--   combine_pools: ONE shared route-agnostic pool -> "Score NNNN". Every active route feeds
--     the same points and the same next_check, so the whole pool is earnable on a single
--     route (Python: Locations.combined_score_table / Rules._set_combined_score_rules).
-- The per-route s.score[route] pools simply go unused under combine_pools (and vice versa),
-- so switching the option mid-seed can't corrupt either -- though it would strand progress.
function LocationManager.score_pool_for(route, s)
  if ItemManager.combine_active() then
    return Routes.COMBINED_SCORE_KEY, s.combined_score
  end
  return route, s.score[route]
end

-- point_based: accumulate depth into the pool and draw down per earned check.
local function on_room_point(route, depth, s)
  local pool_key, pool = LocationManager.score_pool_for(route, s)
  if not pool then return end
  if depth <= 1 then pool.last_depth = 0 end       -- fresh run
  if depth <= pool.last_depth then return end       -- already scored this room
  pool.last_depth = depth
  pool.points = pool.points + depth

  LocationManager.score_skip_pass(pool_key, pool)

  -- Wishlist "Score X/Y" readout: after clearing a room, pin the pool vs the next check's
  -- cost at the top of the overlay (always visible, never fades -- Test Run 6 #1). The
  -- "Sent Score Check N - ..." line comes from the client's CHECKED echo (see reload.lua).
  local limit = ItemManager.score_limit_for(pool_key)
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
  local limit = room_limit("Underworld")          -- all routes share the same count (Python's _combined_room_count)
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
  local limit = room_limit("Underworld")  -- all routes share the same count
  if depth <= limit and depth > (cr.weapon_high[weapon] or 0) then
    cr.weapon_high[weapon] = depth
    send_room_slots(Routes.COMBINED_ROOM_PREFIX, depth, weapon)
  end
end

-- Combat = an Encounter whose EncounterType isn't "NonCombat" (EncounterData.lua). Resolve
-- EncounterType through EncounterData for inherited encounters. Shared by room_has_combat
-- (room.Encounter, used for the reward/shop gate) and score_encounter (any individual
-- encounter instance, including the extra ones in a multi-encounter room).
local function encounter_is_combat(enc)
  if not enc then return false end
  local etype = enc.EncounterType
    or (enc.Name and game.EncounterData and game.EncounterData[enc.Name]
        and game.EncounterData[enc.Name].EncounterType)
  return etype ~= nil and etype ~= "NonCombat"
end

-- A room counts toward score if it has a COMBAT encounter, OR grants a REWARD, OR is a SHOP
-- (Test Run 6 #6 -- the pre-boss reward room and shops should score, not just combat rooms).
-- Pure transition/hub rooms (no encounter, no reward, no store) still never score.
-- reward = room.ChosenRewardType is set; shop = room.Store exists or its reward type is "Shop"
-- (RoomLogic.lua:278).
local function room_has_combat(room)
  return encounter_is_combat(room and room.Encounter)
end

-- room.Store isn't a reliable "this is a real shop" signal on its own: post-boss rest
-- rooms (F_PostBoss01 / G / H / Dream biomes) carry a static ForceWellShop/ForceSellShop
-- RoomData flag that makes the game's IsWellShopEligible() short-circuit true on EVERY
-- visit (RoomLogic.lua), so room.Store gets populated even when the kiosk itself never
-- activates. That kiosk is separately gated on GameState.WorldUpgrades
-- .WorldUpgradePostBossWellShops / .WorldUpgradePostBossSellTraitShops (both AP items --
-- "Surge of Stygian Wells" / "Surge of Desecrating Pools" in ItemManager.WORLD_UPGRADE_ITEMS)
-- -- check that instead of trusting room.Store for these rooms.
local function room_is_shop(room)
  if room == nil then return false end
  if room.ChosenRewardType == "Shop" then return true end
  if room.Store == nil then return false end
  if room.ForceWellShop or room.ForceSellShop then
    local wu = game.GameState and game.GameState.WorldUpgrades
    return wu ~= nil and (wu.WorldUpgradePostBossWellShops == true
      or wu.WorldUpgradePostBossSellTraitShops == true)
  end
  return true
end
-- Exposed publicly: ItemManager's Zagreus-contract-in-every-shop feature
-- (see reload.lua's StartRoom hook) reuses this same real-shop check.
LocationManager.room_is_shop = room_is_shop

local function room_qualifies_for_score(room)
  return room_has_combat(room)
    or (room ~= nil and room.ChosenRewardType ~= nil)
    or room_is_shop(room)
end

-- =============================================================================
-- enemy_locations / npc_locations  (More Locations.txt)
-- =============================================================================

-- Every enemy first-defeat check, by bare enemy name, grouped by owning route. The AP
-- location is "<Enemy> Defeated" (the " Defeated" suffix is added at send time); these bare
-- names mirror the Python world's ENEMY_LAYERS so unit-id matching stays simple. A check
-- only exists in the seed when its route is active (Python enemy_locations_for), so sends
-- are gated per route -- see ROUTE_GATED_CHECKS below. The 13 names Nightmare shares with the
-- Underworld roster live in the Underworld list and get dual-route membership via
-- SHARED_ENEMY_CHECKS (mirrors Python Locations.SHARED_ENEMY_ZONES).
local ENEMY_CHECKS_BY_ROUTE = {
  Underworld = {
    "Casket", "Lanthorn", "Sister of the Dead", "Spindle", "Wailer", "Wastrel",
    "Whisper", "Thorn-Weeper", "Root-Stalker", "Shadow-Spiller", "Headmistress Hecate",
    "Master-Slicer",
    "Hippo", "Lurker", "Pinhead", "Sea-Serpent", "Shellback", "Sop-Spindle",
    "Wet-Whisper", "Wretched Pest", "Deep Serpent", "Hellifish", "King Vermin",
    "Scylla and the Sirens",
    -- Asphodel (Anomaly detour) -- shares the Oceanus sphere (Test Run 5 #13)
    "Wretched Witch", "Bloodless", "Bone-Raker", "Wave-Maker", "Inferno-Bomber",
    "Slam-Dancer", "Burn-Flinger",
    -- Dread-Wailer (Screamer2) really spawns in Mourning Fields (Biome H), not Erebus --
    -- see Locations.py ENEMY_LAYERS comment.
    "Bawlder", "Blight-Shade", "Bloat-Shade", "Blood-Shade", "Canine", "Holeheart",
    "Lamia", "Lycaon", "Mourner", "Smacker", "Sorrow-Spiller", "Phantom",
    "Queen Lamia", "Brush-Stalker", "Infernal Beast", "Dread-Wailer",
    "Crawler", "Goldwraith", "Numbskull", "Sandskull", "Satyr Hoplite",
    "Satyr Supplicant", "Satyr Vierophant", "Tempus", "Wretched Thug", "Goldwrath",
    "The Verminancer", "Wringer", "Chronos",
  },
  Surface = {
    "Bronzebeak", "Cutthroat", "Eidolon", "Lubber", "Shambler", "Tombstone",
    "Satyr Champion", "Erymanthian Boar", "The Cyclops Polyphemus",
    "Anchor", "Blasket", "Boozer", "Droplet", "Harpy Talon", "Sea-Shambler",
    "Seesword", "Stickler", "Charybdis", "The Yargonaut", "Eris",
    "Auto-Forcer", "Auto-Seeker", "Auto-Watcher", "Harpy Raptor", "Satyr Goldpike",
    "Satyr Raider", "Satyr Sapper", "Sky-Dracon", "Snow-Shambler", "Mega-Dracon",
    "Talos", "Prometheus",
    "Eyesore", "Headstone", "Horror", "Land-Dracon", "Polyp", "Stalker",
    "Eye of Typhon", "Spawn of Typhon", "Tail of Typhon", "Twins of Typhon", "Typhon",
  },
  -- Nightmare (opt-in third-party "Zagreus' Journey" route). Real unit ids for most of these
  -- are in ENEMY_UNIT_OVERRIDE below (verified July 11); identity holds only for
  -- Theseus/Hades.
  Nightmare = {
    "Skullomat", "Wretched Lout", "Brimstone", "Dire Inferno-Bomber", "Doomstone",
    "Wretched Sneak", "Megaera", "Alecto", "Tisiphone",
    "Spreader", "Voidstone", "Skull-Crusher", "Gorgon", "Dracon", "Megagorgon",
    "Dire Spreader", "Bone Hydra",
    "Splitter", "Nemean Chariot", "Flame Wheel", "Brightsword", "Longspear",
    "Strongbow", "Greatshield", "Soul Catcher", "Theseus", "Asterius",
    "Gigantic Vermin", "Bother", "Snakestone", "Satyr Cultist", "Hades",
  },
}

-- Mirrors Python Locations.SHARED_ENEMY_ZONES: as of July 18 these checks exist only when
-- the NIGHTMARE route is in the seed (see the ROUTE_GATED_CHECKS loop below) -- but when it
-- is, a kill on either route still satisfies them.
local SHARED_ENEMY_CHECKS = {
  "Numbskull", "Wringer", "Wretched Thug", "Crawler", "Wretched Witch", "Wretched Pest",
  "Bloodless", "Bone-Raker", "Wave-Maker", "Inferno-Bomber", "Slam-Dancer", "Burn-Flinger",
  "King Vermin",
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
  ["SatyrRatCatcher_Miniboss"] = "The Verminancer", -- own HelpText entry, not base "Satyr Vierophant"
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
  -- Nightmare (Zagreus' Journey). Unit ids verified two ways (July 11): the mod's own
  -- Scripts/Meta/NameMappingData.lua "EnemyNameMappings" is the COMPLETE list of ids that
  -- get a "Hades"-prefix rename (only ids that also exist natively in H2 are renamed;
  -- everything else spawns bare), and display names come from the actual Hades 1 install's
  -- HelpText.en.sjson Id->DisplayName table (the port keeps H1's names). Elite tiers here
  -- use NO underscore (SwarmerElite, RatThugMiniboss...) unlike native H2's "_Elite"; the
  -- suffix-strip fallback in on_enemy_killed covers every tier not explicitly listed.
  -- Tartarus
  ["HadesSwarmer"] = "Numbskull",          -- bare SwarmerElite/SuperElite strip to native Swarmer, same check
  ["SwarmerHelmeted"] = "Numbskull",
  ["HadesLightRanged"] = "Wretched Witch", -- H1 LightRanged = "Wretched Witch"; only the base tier is renamed,
  ["LightRangedElite"] = "Wretched Witch", -- so its bare elite tiers MUST stay explicit: suffix-stripping them
  ["LightRangedSuperElite"] = "Wretched Witch", -- would hit native H2 LightRanged ("Sister of the Dead") instead
  ["HadesThiefMineLayer"] = "Wretched Pest",
  ["HadesThiefMineLayerElite"] = "Wretched Pest",
  ["PunchingBagUnit"] = "Wretched Lout",
  ["WretchAssassin"] = "Wretched Sneak",
  ["WretchAssassinMiniboss"] = "Wretched Sneak", -- the Tartarus miniboss proper
  ["LightSpawner"] = "Skullomat",
  ["DisembodiedHand"] = "Wringer",
  ["HeavyMelee"] = "Wretched Thug",
  ["HeavyRanged"] = "Brimstone",
  ["HeavyRangedSplitterMiniboss"] = "Doomstone",
  ["Harpy"] = "Megaera",                   -- the Furies boss: one random sister per run
  ["Harpy2"] = "Alecto",
  ["Harpy3"] = "Tisiphone",
  -- Asphodel. The Bloodless family + SpreadShotUnit are renamed (native H2 reuses those
  -- ids); the Berserker and all SuperElite tiers spawn bare (not in the rename list).
  ["HadesBloodlessNaked"] = "Bloodless",
  ["HadesBloodlessNakedElite"] = "Bloodless",
  ["BloodlessNakedBerserker"] = "Bone-Raker",
  ["HadesBloodlessGrenadier"] = "Inferno-Bomber",
  ["HadesBloodlessGrenadierElite"] = "Dire Inferno-Bomber", -- own check: the Tartarus MiniBossGrenadier pair
  ["HadesBloodlessSelfDestruct"] = "Slam-Dancer",
  ["HadesBloodlessSelfDestructElite"] = "Slam-Dancer",
  ["HadesBloodlessPitcher"] = "Burn-Flinger",
  ["HadesBloodlessPitcherElite"] = "Burn-Flinger",
  ["HadesBloodlessWaveFist"] = "Wave-Maker",
  ["HadesBloodlessWaveFistElite"] = "Wave-Maker",
  ["HadesSpreadShotUnit"] = "Spreader",    -- H1's SpreadShotUnit = "Spreader"; H2's own = "Wretched Witch" (different check!)
  ["HadesSpreadShotUnitElite"] = "Spreader",
  ["SpreadShotUnitMiniboss"] = "Dire Spreader", -- own check: Asphodel MiniBossSpreadShot
  ["FreezeShotUnit"] = "Gorgon",
  ["CrusherUnit"] = "Skull-Crusher",
  ["RangedBurrower"] = "Dracon",
  ["HitAndRunUnit"] = "Megagorgon",
  ["ShieldRanged"] = "Voidstone",          -- intro encounter is Asphodel; also appears in Elysium
  -- The Bone Hydra spawns as one of five behavior variants -- each IS the boss. The mortal
  -- side heads (HydraHeadDartmaker/Lavamaker/...) die mid-fight and must NOT map here.
  ["HydraHeadImmortal"] = "Bone Hydra",
  ["HydraHeadImmortalLavamaker"] = "Bone Hydra",
  ["HydraHeadImmortalSummoner"] = "Bone Hydra",
  ["HydraHeadImmortalSlammer"] = "Bone Hydra",
  ["HydraHeadImmortalWavemaker"] = "Bone Hydra",
  -- Elysium
  ["SplitShotUnit"] = "Splitter",
  ["Chariot"] = "Nemean Chariot",
  ["ChariotSuicide"] = "Flame Wheel",
  ["ShadeSwordUnit"] = "Brightsword",
  ["ShadeSpearUnit"] = "Longspear",
  ["ShadeBowUnit"] = "Strongbow",
  ["ShadeShieldUnit"] = "Greatshield",
  ["FlurrySpawner"] = "Soul Catcher",
  ["Theseus2"] = "Theseus",                -- Extreme Measures chariot Theseus
  ["Minotaur"] = "Asterius",               -- confirmed unit id (also his Elysium Warden miniboss appearance)
  ["Minotaur2"] = "Asterius",              -- Extreme Measures Asterius
  -- Styx. Hades (the final boss) spawns as plain "Hades" -- identity via ENEMY_CHECKS_BY_ROUTE.
  ["HadesCrawler"] = "Crawler",
  ["HadesCrawlerMiniBoss"] = "King Vermin",
  ["RatThug"] = "Gigantic Vermin",
  ["ThiefImpulseMineLayer"] = "Bother",
  ["HeavyRangedForked"] = "Snakestone",
  ["SatyrRanged"] = "Satyr Cultist",       -- NOT native H2's SatyrCultist id (= "Satyr Supplicant")
}

local UNIT_TO_ENEMY_CHECK = {}
for _, _names in pairs(ENEMY_CHECKS_BY_ROUTE) do
  for _, name in ipairs(_names) do UNIT_TO_ENEMY_CHECK[name] = name end
end
for unit, name in pairs(LocationManager.ENEMY_UNIT_OVERRIDE) do UNIT_TO_ENEMY_CHECK[unit] = name end

-- Route boss "Met" checks, keyed by (route, zone). Fired the first time you clear a combat
-- room in that boss's layer (access = reaching the layer, matching the Python region gating).
-- A zone's entry is normally a single check name; Nightmare's zone 3 (Elysium) has TWO --
-- Theseus and Asterius are fought together but tracked as separate "Met" checks -- so that
-- entry is a list instead (send_boss_met handles both shapes).
-- "Met Megaera" (zone 1) exists Python-side as an NPC_BOSS_MEET tuple (appended after the
-- other boss meets so ids stayed stable). Zone 4's "Met Hades" is deliberately the SAME
-- name as the Underworld's "Met Hades" (Jeweled Pom keepsake-giver): one shared location,
-- whichever route reaches him first sends it (Python Routes.NPC_MULTI_ROUTE_LOCK /
-- Rules._set_hades_met_rule).
local BOSS_MET_BY_ZONE = {
  Underworld = { [1] = "Met Hecate", [2] = "Met Scylla", [3] = "Met Cerberus", [4] = "Met Chronos" },
  Surface    = { [1] = "Met Polyphemus", [2] = "Met Eris", [3] = "Met Prometheus", [4] = "Met Typhon" },
  Nightmare    = { [1] = "Met Megaera", [2] = "Met Bone Hydra",
                 [3] = { "Met Theseus", "Met Asterius" }, [4] = "Met Hades" },
}

-- Bosses you meet regardless of route (Hecate mentors you at the Crossroads from the start).
-- Their "Met" location is always generated and start-reachable (Python ALWAYS_MET_BOSSES), so it
-- must NOT be route-gated here. Keep in sync with Python: add "Met Eris" if Eris is confirmed
-- meetable off the Surface.
local ALWAYS_MET_BOSS = { ["Met Hecate"] = true }

-- NPCs met on only one route (mirrors Python Routes.NPC_ROUTE_LOCK): their "Met <NPC>" and
-- "<NPC> Keepsake" locations only exist in the seed when that route is active.
-- July 18: shrank from 17 entries to 4, mirroring the Python-side change. The story-room
-- NPCs (zerp-NPCRoomRandomizer shuffles who appears in every story slot, across routes --
-- Patroclus really was met in an Underworld run replacing Arachne, and his check was
-- silently dropped by this very gate) and the combat-assist NPCs (zerp-Extended_NPC_
-- Encounters covers every route's zones) moved to Python's NPC_RANDOMIZED_HELPERS: their
-- locations now exist on EVERY seed, so they must never be send-blocked here. What stays:
-- Eris (Surface boss/bath only), Orpheus (ZJ Tartarus rooms only), Achilles (native
-- Nightmare Elysium progression only), and Megaera as a Lua-only defensive entry -- her
-- "Met" is boss-met machinery and her keepsake is item-only, so that just stops any stray
-- send when Nightmare content isn't loaded.
local NPC_ROUTE_LOCK = {
  Eris = "Surface",
  Orpheus = "Nightmare", Megaera = "Nightmare", Achilles = "Nightmare",
}

-- Full check name -> the route(s) whose activation gates its existence in the seed. Checks
-- can be reached through un-route-gated paths (hub chat, field encounter, boon pickup, a
-- gift, a shared enemy killed on the other route) -- when every route a check belongs to is
-- excluded, the location was never generated, so sending it makes the client log "Unknown
-- location checked by game". Gate at the send sites instead (send_first /
-- check_route_blocked). Covers every enemy "Defeated" check, route boss "Met"s (except
-- always-met ones, whose location always exists), and route-locked cast "Met"s + their
-- "<NPC> Keepsake" checks.
local ROUTE_GATED_CHECKS = {}
for _route, _names in pairs(ENEMY_CHECKS_BY_ROUTE) do
  for _, _name in ipairs(_names) do
    ROUTE_GATED_CHECKS[_name .. " Defeated"] = { _route }
  end
end
-- July 18 (user ruling): the 13 shared H1-callback checks only EXIST in a seed when the
-- Nightmare route is active (their Underworld-side spawns -- Asphodel-anomaly detours and
-- the odd H2 callback -- are too rare to justify pool membership on their own). Gate their
-- existence on Nightmare alone; when Nightmare IS in the seed, a kill on EITHER route
-- still sends (this gate is seed-level, never current-route).
for _, _name in ipairs(SHARED_ENEMY_CHECKS) do
  ROUTE_GATED_CHECKS[_name .. " Defeated"] = { "Nightmare" }
end
for _route, _byzone in pairs(BOSS_MET_BY_ZONE) do
  for _, _check in pairs(_byzone) do
    local _names = (type(_check) == "table") and _check or { _check }
    for _, _name in ipairs(_names) do
      if not ALWAYS_MET_BOSS[_name] then ROUTE_GATED_CHECKS[_name] = { _route } end
    end
  end
end
for _npc, _route in pairs(NPC_ROUTE_LOCK) do
  ROUTE_GATED_CHECKS["Met " .. _npc] = { _route }
  ROUTE_GATED_CHECKS[_npc .. " Keepsake"] = { _route }
end
-- Clears the single-route gate the BOSS_MET_BY_ZONE loop above set for "Met Hades"
-- (Nightmare's final boss): as of July 18 he's a randomized helper (his I_Story01 story
-- room shuffles into any route's story slots), so his location exists on EVERY seed and
-- must never be send-blocked.
ROUTE_GATED_CHECKS["Met Hades"] = nil

-- True when `name` is route-gated and none of its routes are in this seed. Used by
-- send_first and by reload.lua's keepsakesanity gift hook (which sends its check directly).
function LocationManager.check_route_blocked(name)
  local routes = ROUTE_GATED_CHECKS[name]
  if not routes then return false end
  for _, r in ipairs(routes) do
    if ItemManager.route_active(r) then return false end
  end
  return true
end

-- Crossroads cast "Met" checks (must match the Python NPC_CAST). Keyed by the AP check name.
-- As with enemies, map the real in-game NPC id -> "Met <Name>" here; on_npc_interacted()
-- logs unmapped ids when npc_locations is on. Identity is assumed otherwise.
local NPC_CAST = {
  "Moros", "Skelly", "Dora", "Nemesis", "Artemis", "Selene", "Charon", "Odysseus",
  "Circe", "Narcissus", "Arachne", "Icarus", "Heracles", "Medea", "Hermes", "Echo",
  -- Zagreus stays out of this table (Python NPC_NO_MEET / not in NPC_CAST): the Crossroads
  -- cast's UseNPC-based "Met" doesn't apply to him. His real "Met Zagreus" check (added July
  -- 17, Locations.py ZAGREUS_MET_LOCATION) is sent separately by on_zagreus_met() below, fired
  -- from reload.lua on arrival in his C_Boss01 fight room (works across all 3 encounter modes).
  "Chaos", "Dionysus", "Athena", "Hades", "Hephaestus", "Zeus", "Demeter",
  "Aphrodite", "Poseidon", "Apollo", "Hestia", "Ares", "Hera",
  -- Non-keepsake meet-able NPC (Test Run 5 #5): met by talking to NPC_Hypnos_01 once awake.
  "Hypnos",
  -- Nightmare keepsake-giving cast (Megaera excluded -- she's boss-gated via BOSS_MET_BY_ZONE
  -- instead, same convention as Hecate/Eris not being double-listed here). Orpheus/Thanatos/
  -- Achilles have real Python-side locations as of July 16 (unit ids NPC_Orpheus_01,
  -- NPC_Thanatos_01/_Field_01, NPC_Achilles_01 -- all parse via the NPC_<Char>_ fallback).
  "Sisyphus", "Eurydice", "Patroclus", "Orpheus", "Thanatos", "Achilles",
}
LocationManager.NPC_UNIT_OVERRIDE = LocationManager.NPC_UNIT_OVERRIDE or {
  -- ["NPC_Hecate_01"] = "Met Hecate",   -- example
  -- Explicit (not relying on the "NPC_<Char>_.." parse fallback): the Underworld "Curse of
  -- Eris" ambush spawns unit id "NPC_Eris_01" (RoomDataG/H/I.lua SpawnErisForCurse), same id
  -- used for her Crossroads/bath appearances. "Met Eris" stays Surface-gated (send_first's
  -- ROUTE_GATED_CHECKS gate), so this only actually sends when Surface is part of the seed.
  ["NPC_Eris_01"] = "Met Eris",
  -- Nightmare: Megaera's conversation appearances use "FurySister", which the NPC_<Char>_
  -- pattern can't match to her cast name. Route-gated via ROUTE_GATED_CHECKS in send_first.
  ["NPC_FurySister_01"] = "Met Megaera",
  ["NPC_FurySister_Story_01"] = "Met Megaera",
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
    -- A zone entry can be a list (Nightmare's Elysium: Theseus + Asterius) -- normalize to a
    -- list either way so this loop handles both shapes without calling :match on a table.
    local checks = (type(check) == "table") and check or { check }
    for _, name in ipairs(checks) do
      local char = name:match("^Met (%a+)$")
      if char then NPC_CAST_SET[char] = name end
    end
  end
end

local _logged_unmapped_enemies = {}
local _logged_unmapped_npcs = {}

-- Send a check once: guarded by a per-save set so a re-kill / re-talk never re-sends.
local function send_first(set, name)
  local s = APState.get()
  if not s or not s[set] then return end
  if s[set][name] then return end
  -- Route-gated checks (enemy kills, boss/cast "Met"s) don't exist in a seed that excludes
  -- every route they belong to -- skip the send. Don't poison the dedup set: leave it unset
  -- so a legit send can still fire later (e.g. after reconnecting under a different seed).
  if LocationManager.check_route_blocked(name) then return end
  s[set][name] = true
  Bridge.send("CHECK:" .. name)
  rom.log.info("[AP] check: " .. name .. " (" .. set .. ")")
end

-- Resolve a spawned unit id to its bare AP enemy-check name (no " Defeated" suffix), or nil if
-- unmapped. Shared by on_enemy_killed (send-on-death) and the miniboss-forcing lookup in
-- reload.lua's ChooseEncounter wrap (need-to-know "is this candidate already defeated?").
local function resolve_enemy_check(id)
  if type(id) ~= "string" then return nil end
  local check = UNIT_TO_ENEMY_CHECK[id]
  if not check then
    -- Elite spawns share their base unit's AP check. Native H2 always underscores its
    -- variant suffixes -- "_Elite" (Brawler_Elite, Guard_Elite...), "_SuperElite" (Screamer2_
    -- SuperElite, Boar_SuperElite, Lamia_SuperElite...), and "_Shadow" (the shrine-upgrade
    -- reskin used by MiniBossTreant_Shrine/MiniBossFogEmitter_Shrine once the player has taken
    -- the "MinibossCountShrineUpgradeActive" upgrade -- Treant_Shadow, FogEmitter_Shadow,
    -- Screamer_Shadow, ...). The ported Nightmare content instead uses bare "Elite"/"SuperElite"/
    -- "Miniboss" with NO underscore (SwarmerElite, RatThugMiniboss; WretchAssassinMiniboss
    -- SuperElite strips to the explicitly-mapped WretchAssassinMiniboss). Try the underscored
    -- (native) forms first since they're unambiguous; explicit ENEMY_UNIT_OVERRIDE entries
    -- always win over stripping regardless -- required where the stripped base id belongs to a
    -- DIFFERENT native-H2 enemy (see the LightRangedElite note in the table above).
    for _, suffix in ipairs({ "_Elite", "_SuperElite", "_Shadow", "SuperElite", "Elite", "Miniboss", "MiniBoss" }) do
      if #id > #suffix and id:sub(-#suffix) == suffix then
        check = UNIT_TO_ENEMY_CHECK[id:sub(1, #id - #suffix)]
        if check then break end
      end
    end
  end
  return check
end

-- Public: same resolution on_enemy_killed uses, exposed so other systems (the miniboss-forcing
-- ChooseEncounter hook in reload.lua) can ask "what check would killing THIS unit id satisfy?"
-- without duplicating the override table / suffix-strip rules.
function LocationManager.enemy_check_for_unit(id)
  return resolve_enemy_check(id)
end

-- Public: has this bare enemy-check name (e.g. "King Vermin", no " Defeated" suffix) already
-- been sent this save? Used by the miniboss-forcing hook to tell "already killed" candidates
-- apart from ones still worth guaranteeing. Route-blocked/unknown names read as "not defeated"
-- (never true), which is the safe default -- it just means that candidate stays eligible.
function LocationManager.enemy_check_defeated(name)
  local s = APState.get()
  return (s and s.enemy_killed and s.enemy_killed[name .. " Defeated"]) == true
end

-- Wrapped on every unit death (reload.lua). If enemy_locations is on and the unit maps to
-- an enemy check, send it (first time only). Unmapped enemies are logged once for discovery.
function LocationManager.on_enemy_killed(unit)
  if not ItemManager.setting_on("enemy_locations") then return end
  local id = unit and unit.Name
  if not id then return end
  local check = resolve_enemy_check(id)
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
-- Loot names that don't follow the "<God>Upgrade" pattern and can't be trusted to carry a
-- live loot.SpeakerName at runtime (confirmed 2026-07-15: a Selene SpellDrop pickup logged
-- zero output from on_loot_pickup -- neither a send nor an "unmapped loot" fallback -- while
-- the exact same code path fired correctly for a ZeusUpgrade pickup moments later, because
-- "ZeusUpgrade" resolves via the Upgrade-suffix parse alone and never needed SpeakerName at
-- all. Every other tracked god/NPC loot matches that suffix; only these two don't, so they were
-- silently 100% dependent on a field that isn't reliably present on the runtime instance).
local LOOT_NAME_OVERRIDE = { SpellDrop = "Selene", TrialUpgrade = "Chaos" }
function LocationManager.on_loot_pickup(loot)
  if not ItemManager.setting_on("npc_locations") then return end
  if not loot then return end
  local id = loot.Name
  local who = LOOT_NAME_OVERRIDE[id] or loot.SpeakerName
  if not (who and NPC_CAST_SET[who]) and id then
    who = id:match("^(%a+)Upgrade$")
  end
  -- NOTE: no shop guard here (unlike on_encounter_started below). HandleLootPickup only ever
  -- fires from UseLoot on an actual completed interact/purchase (InteractLogic.lua -- SpendResources
  -- happens before HandleLootPickup is called), never from merely being in/near a shop room. So
  -- every call here is already a genuine meet, whether or not the room is a "Shop". A shop guard
  -- was mistakenly copy-pasted onto this hook too (Test Run 6 #5); it silently ate every real
  -- purchase-based meet forever, including Selene's own paid SpellDrop node and buying her Hex
  -- from a general shop (both confirmed 2026-07-15: game log shows zero "loot meet" output for
  -- either). The room-entry false-positive that #5 actually reported can only have come from
  -- on_encounter_started (StartEncounter fires on mere room entry, listing every seller) -- that
  -- guard stays below.
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

-- Wrapped on OpenSpellScreen (reload.lua). Selene's Hex ("SpellDrop") doesn't go through the
-- generic UseLoot/HandleLootPickup path at all -- her loot object's OnUsedFunctionName is
-- "OpenSpellScreen" (SpellScreenLogic.lua), called directly from the engine's OnUsed dispatch
-- the instant the player interacts with her, BEFORE the affordability check and BEFORE
-- SpendResources. So on_loot_pickup (which only fires after a completed purchase) never sees a
-- real interaction that the player couldn't afford or backed out of -- confirmed 2026-07-15: a
-- field SpellDrop reward was interacted with but not purchased, and zero "Met Selene" fired.
-- Firing here instead, on interaction rather than purchase, matches how every other NPC gets
-- credit just for talking. First time only (send_first dedups with on_loot_pickup, whichever
-- wins first).
function LocationManager.on_spell_screen_opened(spellItem)
  if not ItemManager.setting_on("npc_locations") then return end
  if not (spellItem and spellItem.Name == "SpellDrop") then return end
  rom.log.info("[AP] spell screen meet: who=Selene loot=" .. tostring(spellItem.Name))
  send_first("npc_met", NPC_CAST_SET["Selene"])
end

-- Fire the route boss "Met" check for a (route, zone), first time only. Declared before
-- on_encounter_started (which calls it) so it's in lexical scope there, not a nil global.
local function send_boss_met(route, zone)
  if not ItemManager.setting_on("npc_locations") then return end
  local byzone = BOSS_MET_BY_ZONE[route]
  local name = byzone and byzone[zone]
  if not name then return end
  if type(name) == "table" then
    for _, n in ipairs(name) do send_first("npc_met", n) end
  else
    send_first("npc_met", name)
  end
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
    -- Same shop guard as on_loot_pickup (Test Run 6 #5): a SHOP room lists every selling god/NPC
    -- in its encounter SpeakerNames, so walking into e.g. Charon's shop (F_Shop01), where Selene
    -- sells Hexes, fired "Met Selene" prematurely -- before you actually met her. Don't count an
    -- encounter meet while in a shop; the real meet still fires via UseNPC / a non-shop hex pickup
    -- / her own field encounter. (Boss meets below are unaffected -- bosses never spawn in shops.)
    local room = game.CurrentRun and game.CurrentRun.CurrentRoom
    local in_shop = room ~= nil and (room.Store ~= nil or room.ChosenRewardType == "Shop")
    for _, who in ipairs(speakers) do
      if NPC_CAST_SET[who] then
        if in_shop then
          rom.log.info("[AP] encounter meet suppressed in shop: who=" .. tostring(who)
            .. " encounter=" .. tostring(encounter.Name)
            .. " RoomSetName=" .. tostring(room and room.RoomSetName)
            .. " reward=" .. tostring(room and room.ChosenRewardType))
        else
          rom.log.info("[AP] encounter meet: who=" .. tostring(who)
            .. " encounter=" .. tostring(encounter.Name)
            .. " RoomSetName=" .. tostring(room and room.RoomSetName)
            .. " reward=" .. tostring(room and room.ChosenRewardType))
          send_first("npc_met", NPC_CAST_SET[who])
        end
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
-- sends "Met Eris" when Surface is part of the seed (ROUTE_GATED_CHECKS), so this is a no-op on an
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

-- Score a REWARD-ONLY or SHOP room (Test Run 6 #6) on ENTER (StartRoom) -- there's no enemy to
-- clear so there's no encounter-clear moment to hook. Combat rooms are scored per-ENCOUNTER
-- instead (see score_encounter below), not here: a room can run several encounters back-to-back
-- (RoomLogic.lua currentRoom.Encounters / MultipleEncountersData) before its exits ever unlock,
-- and each one should earn its own check the moment IT clears rather than making the player wait
-- for the whole cluster. Each room is counted at most once via a flag on the room table
-- (room._ap_scored), so a repeated StartRoom call (e.g. a rejoin) never double-counts.
function LocationManager.score_room(room)
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

  if room_has_combat(room) then return end                  -- combat rooms score via score_encounter
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
  if Overlay and Overlay.set_room then Overlay.set_room(depth) end

  rom.log.info("[AP] score room: RoomSetName=" .. tostring(room.RoomSetName)
    .. " RoomName=" .. tostring(room.Name)
    .. " reward=" .. tostring(room.ChosenRewardType)
    .. " shop=" .. tostring(room_is_shop(room)) .. " -> route=" .. route
    .. " depth=" .. depth .. " system=" .. tostring(system))

  -- Boss "Met" fires from on_encounter_started (entering the boss arena), not here.

  local combine = ItemManager.combine_active()
  if system == 1 then
    if combine then on_room_room_combined(depth) else on_room_room(route, depth, pool) end
  elseif system == 2 then
    if combine then on_room_per_weapon_combined(depth) else on_room_per_weapon(route, depth, pool) end
  else
    on_room_point(route, depth, s)      -- picks the per-route or shared pool itself
  end
end

-- Score ONE encounter the instant it actually PAYS OUT (not when the room finally unlocks its
-- exits, and not merely when combat ends). RoomLogic.lua's StartEncounter loops
-- currentRoom.Encounters for rooms with MultipleEncountersData (confirmed in the installed game's
-- RoomDataO/P.lua -- several Surface/Underworld rooms chain 2+ combat encounters), and exits stay
-- locked (CheckRoomExitsReady) until ALL of them finish. Waiting for UnlockRoomExits meant a
-- multi-encounter room only ever earned ONE check no matter how many fights it actually took --
-- but scoring every encounter-completion over-corrected: some of those chained encounters are
-- deliberately reward-less pre-combat waves (e.g. GeneratedP_PreCombat in Mount Olympus rooms,
-- EncounterRoomRewardOverride="Empty"), so every "wave" was sending a check. Called from the
-- SpawnRoomReward wrap (reload.lua) only when that call actually spawned a reward object -- the
-- game's own signal for "this encounter is done and something popped" -- and from
-- score_thessaly_wave below for the one biome whose rooms never spawn a reward at all.
-- Dedup'd per encounter instance (encounter._ap_scored) so a re-entrant call is a no-op,
-- same pattern as room._ap_scored.
function LocationManager.score_encounter(room, encounter)
  local s = APState.get()
  if not s then return end
  if not room or not encounter then return end
  if encounter._ap_scored then return end
  if not encounter_is_combat(encounter) then return end     -- NonCombat encounters don't score

  local route, zone = Routes.current()
  if not route then return end                              -- hub / Chaos / non-scored biome
  if not ItemManager.route_active(route) then return end    -- excluded route: no checks
  -- Same unlocked-zone gate as score_room (Test Run 8 #1): never score an area the player hasn't
  -- unlocked yet (e.g. the surface-start seed's forced Underworld intro).
  if not ItemManager.route_zone_unlocked(route, zone) then
    rom.log.info("[AP] score encounter: " .. route .. " z" .. tostring(zone)
      .. " not unlocked yet - no room check")
    return
  end

  local system = ItemManager.setting_mode("location_system")
  -- per_weapon checks additionally require the equipped weapon to be AP-unlocked (Test Run 8 #1).
  if system == 2 and not ItemManager.equipped_weapon_unlocked() then
    rom.log.info("[AP] score encounter: equipped weapon not AP-unlocked - no per-weapon room check")
    return
  end

  encounter._ap_scored = true
  local pool = s.score[route]
  pool.depth_counter = (pool.depth_counter or 0) + 1
  local depth = pool.depth_counter
  if Overlay and Overlay.set_room then Overlay.set_room(depth) end

  rom.log.info("[AP] score encounter: RoomName=" .. tostring(room.Name)
    .. " EncounterName=" .. tostring(encounter.Name) .. " -> route=" .. route
    .. " depth=" .. depth .. " system=" .. tostring(system))

  local combine = ItemManager.combine_active()
  if system == 1 then
    if combine then on_room_room_combined(depth) else on_room_room(route, depth, pool) end
  elseif system == 2 then
    if combine then on_room_per_weapon_combined(depth) else on_room_per_weapon(route, depth, pool) end
  else
    on_room_point(route, depth, s)      -- picks the per-route or shared pool itself
  end
end

-- Rift of Thessaly open-water rooms (RoomSetName "O") can NEVER score through the
-- SpawnRoomReward wrap: every O_Combat* room is NoReward = true (RoomDataO.lua O_CombatData),
-- so SpawnRoomReward takes its nil-reward early-out on all of them -- the room's actual reward
-- is chosen at the ship's steering wheel AFTER every wave clears (PresentationBiomeO.lua
-- ShipsSteeringWheelChoicePresentation / MapState.SurfaceShopItems), a path that never calls
-- SpawnRoomReward. These rooms were sending ZERO room checks. Score EVERY wave in the room's
-- chain instead (O_CombatData.MultipleEncountersData runs 1-3: the pre-spawned
-- OEncountersIntros pack killed before reward-choosing opens, then 1-2 more), keeping
-- per-encounter parity with the rest of the game -- each fight the room makes you clear earns
-- its own check. The reward-payout signal other biomes key on simply has no O equivalent (no
-- wave ever pays; the wheel does), so wave completion IS the payout moment here. Called from
-- the StartEncounter wrap AFTER base() returns -- StartEncounter only returns once its wave is
-- fully dead (RoomLogic.lua runs RunEvents to completion then sets encounter.Completed; the
-- multi-encounter loop chains waves on that return) -- so "returned + Completed" is the
-- wave-killed moment. Membership in the room's own Encounters chain is required so a stray
-- encounter routed through the same StartEncounter path (e.g. a timed-challenge encounter)
-- can't score. O_PostBoss01 is also NoReward but its rest encounter is NonCombat, which
-- score_encounter's own combat filter rejects -- all route/zone/system gating and per-encounter
-- dedup (_ap_scored) live there too.
function LocationManager.score_thessaly_wave(room, encounter)
  if not room or not encounter then return end
  if room.RoomSetName ~= "O" or not room.NoReward then return end
  if not encounter.Completed then return end     -- never score a wave that didn't finish
  local in_chain = (room.Encounter == encounter)
  if not in_chain and room.Encounters then
    for _, enc in ipairs(room.Encounters) do
      if enc == encounter then
        in_chain = true
        break
      end
    end
  end
  if not in_chain then return end
  LocationManager.score_encounter(room, encounter)
end

-- Nightmare Styx (the route's last zone) "wing" rooms (D_Mini01-14, HadesRoomDataStyx.lua
-- BaseStyxMini) can NEVER score through the SpawnRoomReward wrap either: BaseStyxMini sets
-- DeferReward = true (confirmed the only room in Styx's data with that field), and
-- RewardLogic.lua:SpawnRoomReward early-returns nil on `currentRoom.DeferReward` before ever
-- spawning a reward object -- by design, since a wing's actual reward is handed out once at
-- its MiniBoss/Reprieve end room (BaseStyxWingEnd), not per mini room along the way. That
-- deferred-payout design is exactly why these 14 rooms were sending ZERO room checks even
-- though the player is clearing a full combat encounter in each one. Score wave completion
-- itself instead, same precedent as score_thessaly_wave above: called from the same
-- StartEncounter wrap AFTER base() returns (the "wave killed" moment), gated on
-- RoomSetName=="Styx" + DeferReward so only these wing rooms match (MiniBoss/Reprieve/Hub/
-- Intro rooms don't set DeferReward and keep scoring via SpawnRoomReward as before).
function LocationManager.score_styx_mini(room, encounter)
  if not room or not encounter then return end
  if room.RoomSetName ~= "Styx" or not room.DeferReward then return end
  if not encounter.Completed then return end     -- never score a wave that didn't finish
  local in_chain = (room.Encounter == encounter)
  if not in_chain and room.Encounters then
    for _, enc in ipairs(room.Encounters) do
      if enc == encounter then
        in_chain = true
        break
      end
    end
  end
  if not in_chain then return end
  LocationManager.score_encounter(room, encounter)
end

-- How many times the route's final boss must be defeated before its goal cascade fires
-- (YAML underworld_wins_needed / surface_wins_needed / nightmare_wins_needed). Defaults to
-- 1 if unset.
local DEFEATS_NEEDED_KEY = {
  Underworld = "underworld_wins_needed", Surface = "surface_wins_needed",
  Nightmare = "nightmare_wins_needed",
}
local function defeats_needed(route)
  local key = DEFEATS_NEEDED_KEY[route] or "underworld_wins_needed"
  return tonumber(ItemManager.settings[key]) or 1
end

-- The route's total final-boss clears so far (persisted in APState).
local function route_clears(s, route)
  if route == "Surface" then return s.typhon_clears end
  if route == "Nightmare" then return s.hades_clears end
  return s.chronos_clears
end

-- Goal cascade: once the route's final boss has been defeated the YAML-specified number of
-- times (underworld_wins_needed / surface_wins_needed / nightmare_wins_needed, default 1),
-- the player has
-- "completed" that route's goal, so release every remaining Score/Room check for it instead
-- of making them grind RNG for the last few. point_based flushes every remaining "<route>
-- Score N" (bypassing the points requirement); room_based flushes the route's shared room
-- checks; per_weapon_room_based flushes only the weapon that just cleared the run.
local function flush_route_checks(route, pool)
  local system = ItemManager.setting_mode("location_system")
  if system == 0 then
    -- combine_pools: there are no per-route score checks to flush -- clearing a route's goal
    -- releases the one shared pool instead (the same checks any route would have earned).
    local pool_key, score_pool = LocationManager.score_pool_for(route, APState.get())
    if not score_pool then return end
    local limit = ItemManager.score_limit_for(pool_key)
    local sent = 0
    while score_pool.next_check <= limit do
      if not ItemManager.is_score_checked(pool_key, score_pool.next_check) then
        local check = Routes.SCORE_PREFIX[pool_key] .. " " .. pad4(score_pool.next_check)
        rom.log.info("[AP] check: " .. check .. " (" .. route .. " goal cascade)")
        Bridge.send("CHECK:" .. check)
        sent = sent + 1
      end
      score_pool.next_check = score_pool.next_check + 1
    end
    rom.log.info("[AP] goal cascade: flushed " .. sent .. " " .. pool_key
      .. " score checks (up to " .. limit .. ")")
    return
  end
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
      rom.log.info("[AP] goal cascade: flushed " .. sent .. " combined room checks (up to " .. limit .. ")")
      return
    end
    local sent = 0
    for depth = (pool.room_high or 0) + 1, limit do
      sent = sent + send_room_slots(Routes.ROOM_PREFIX[route], depth)
    end
    pool.room_high = math.max(pool.room_high or 0, limit)
    rom.log.info("[AP] goal cascade: flushed " .. sent .. " " .. route .. " room checks (up to " .. limit .. ")")
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
      rom.log.info("[AP] goal cascade: flushed " .. sent .. " combined " .. weapon
        .. " room checks (up to " .. limit .. ")")
      return
    end
    pool.weapon_high = pool.weapon_high or {}
    local sent = 0
    for depth = (pool.weapon_high[weapon] or 0) + 1, limit do
      sent = sent + send_room_slots(Routes.ROOM_PREFIX[route], depth, weapon)
    end
    pool.weapon_high[weapon] = math.max(pool.weapon_high[weapon] or 0, limit)
    rom.log.info("[AP] goal cascade: flushed " .. sent .. " " .. route .. " " .. weapon
      .. " room checks (up to " .. limit .. ")")
  end
end

-- Goal cascade (continued): release every remaining enemy "Defeated" check owned by a
-- completed route, the same way flush_route_checks releases its Score/Room checks -- once
-- you've beaten the route's final boss enough times, don't force grinding out the last few
-- enemy RNG spawns either. Shared-zone enemies (SHARED_ENEMY_CHECKS) are flushed on a
-- NIGHTMARE clear only (July 18): they now exist in the pool only when Nightmare is in the
-- seed (ROUTE_GATED_CHECKS gates them on Nightmare alone), so Nightmare is their owning
-- route for cascade purposes. send_first (existing dedup + route-block guard) does the
-- actual work; this just walks every name the route owns.
local function flush_route_enemy_checks(route)
  if not ItemManager.setting_on("enemy_locations") then return end
  local s = APState.get()
  if not s or not s.enemy_killed then return end
  local sent = 0
  local function flush_list(names)
    for _, name in ipairs(names) do
      local check = name .. " Defeated"
      if not s.enemy_killed[check] then
        send_first("enemy_killed", check)
        if s.enemy_killed[check] then sent = sent + 1 end
      end
    end
  end
  flush_list(ENEMY_CHECKS_BY_ROUTE[route] or {})
  if route == "Nightmare" then
    flush_list(SHARED_ENEMY_CHECKS)
  end
  rom.log.info("[AP] goal cascade: flushed " .. sent .. " " .. route .. " enemy checks")
end

local function distinct_weapons(s, route)
  local n = 0
  for _ in pairs(s.weapons_cleared[route] or {}) do n = n + 1 end
  return n
end

-- Send the goal state: Chronos clears / distinct weapons, Typhon clears / weapons, Zagreus
-- clears (no weapon-variety requirement -- see Client.py evaluate_goal), then Hades clears /
-- weapons appended last (matches the VICTORY payload's fixed positional order both sides agree on).
function LocationManager.send_victory()
  local s = APState.get()
  if not s then return end
  Bridge.send("VICTORY:" .. s.chronos_clears .. "-" .. distinct_weapons(s, "Underworld")
    .. "-" .. s.typhon_clears .. "-" .. distinct_weapons(s, "Surface")
    .. "-" .. (s.zagreus_clears or 0)
    .. "-" .. (s.hades_clears or 0) .. "-" .. distinct_weapons(s, "Nightmare"))
end

-- Call on arrival in C_Boss01, the Zagreus fight room (reload.lua's SetCurrentRoom hook) --
-- reached by Vanilla/Empowered's contract door and by the Final Challenge redirect alike, so
-- this one hook covers "Met Zagreus" regardless of encounter mode. Mirrors ZAGREUS_MET_LOCATION's
-- npc_locations + goal_requires_zagreus gate (Locations.py setup_location_table_with_settings)
-- -- the latter also matches goal_includes_zagreus() already no-opping the contract spawn/redirect
-- that's the only way into this room, so this location can't exist in the pool without also being
-- reachable. First time only.
function LocationManager.on_zagreus_met()
  if not ItemManager.setting_on("npc_locations") then return end
  if not ItemManager.goal_includes_zagreus() then return end
  send_first("npc_met", "Met Zagreus")
end

-- Call when the secret Zagreus superboss fight is cleared (any encounter mode).
function LocationManager.on_zagreus_cleared()
  local s = APState.get()
  if not s then return end
  s.zagreus_clears = (s.zagreus_clears or 0) + 1
  rom.log.info("[AP] Zagreus cleared (now " .. s.zagreus_clears .. ")")
  -- "Zagreus Defeated" (ZAGREUS_DEFEATED_LOCATION) is a real check distinct from the VICTORY
  -- goal payload below -- mirrors ZAGREUS_MET_LOCATION's enemy_locations + goal_requires_zagreus gate.
  if ItemManager.setting_on("enemy_locations") and ItemManager.goal_includes_zagreus() then
    send_first("enemy_killed", "Zagreus Defeated")
  end
  LocationManager.send_victory()
end

-- Call when a run is cleared (final boss defeated). `route` is Underworld (Chronos),
-- Surface (Typhon), or Nightmare (Hades); `weapon_id` is the weapon used, for the goal weapon count.
function LocationManager.on_run_cleared(route, weapon_id)
  local s = APState.get()
  if not s then return end
  if route == "Surface" then
    s.typhon_clears = s.typhon_clears + 1
  elseif route == "Nightmare" then
    s.hades_clears = (s.hades_clears or 0) + 1
  else
    s.chronos_clears = s.chronos_clears + 1
  end
  if route and weapon_id then
    s.weapons_cleared[route] = s.weapons_cleared[route] or {}
    s.weapons_cleared[route][weapon_id] = true
  end
  rom.log.info("[AP] run cleared: " .. tostring(route) .. " (weapon " .. tostring(weapon_id) .. ")")
  -- Goal cascade: once the route's final boss has been defeated the YAML-specified number
  -- of times, release the rest of its Score/Room checks. Idempotent past that point (the
  -- flush already caught everything up to the limit on the run it first triggered).
  if route and ItemManager.route_active(route) and s.score[route]
     and route_clears(s, route) >= defeats_needed(route) then
    pcall(function() flush_route_checks(route, s.score[route]) end)
    pcall(function() flush_route_enemy_checks(route) end)
  end
  LocationManager.send_victory()
end
