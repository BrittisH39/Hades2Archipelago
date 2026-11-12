---@diagnostic disable: lowercase-global
-- EnemySanity.lua — enemysanity mode (vanilla / vanilla_plus_locations / shuffled /
-- shuffled_plus_locations / pure_random) spawn substitution + Dream Dive-based balance scaling
-- FOR SUBSTITUTED UNITS ONLY (natively-placed enemies keep their own tuning -- see
-- scale_unit). Loaded after ItemManager.lua (settings accessors) and LocationManager.lua (needs
-- its UNIT_TO_ENEMY_CHECK/CHECK_TO_UNIT_ID/ENEMY_CHECKS_BY_ROUTE/SHARED_ENEMY_CHECKS, and its
-- MINIBOSS_CHECK_NAMES-consuming on_enemy_killed calls back into this file's locations_on()).
-- Routes.lua's Routes.current() gives the destination zone number (1-4) that both the
-- substitution scope and the Dream Dive scaling key off.

EnemySanity = EnemySanity or {}

-- Mirrors Python Locations.MINIBOSS_ENEMY_NAMES exactly (hand-duplicated, same convention
-- already used for LocationManager.ENEMY_CHECKS_BY_ROUTE mirroring Locations.ENEMY_LAYERS --
-- keep both lists in sync by hand on future changes).
EnemySanity.MINIBOSS_CHECK_NAMES = {
  ["Headmistress Hecate"] = true, ["Master-Slicer"] = true, ["Thorn-Weeper"] = true,
  ["Scylla"] = true, ["Roxy"] = true, ["Jetty"] = true, ["Hellifish"] = true, ["Deep Serpent"] = true,
  ["Queen Lamia"] = true, ["Infernal Beast"] = true, -- InfestedCerberus, boss-identical (Cerberus)
  ["Chronos"] = true, ["Goldwrath"] = true, ["The Verminancer"] = true,
  ["The Cyclops Polyphemus"] = true, ["Erymanthian Boar"] = true,
  ["Eris"] = true,
  ["Mega-Dracon"] = true, ["Prometheus"] = true,
  ["Typhon"] = true, ["Spawn of Typhon"] = true, ["Twins of Typhon"] = true,
  ["Megaera"] = true, ["Alecto"] = true, ["Tisiphone"] = true,
  ["Wretched Sneak"] = true, ["Doomstone"] = true, ["Dire Inferno-Bomber"] = true,
  ["Bone Hydra"] = true, ["Dire Spreader"] = true,
  ["Theseus"] = true, ["Asterius"] = true,
  ["Hades"] = true,
  ["King Vermin"] = true,
  -- 8/16: four miniboss-only units were missing from this list, so they sat in the REGULAR
  -- (trash) shuffle pool and could replace ordinary mobs in ordinary rooms -- reported live as
  -- "minibosses spawning in normal rooms". Found by walking every MiniBoss* encounter that a
  -- RoomData*.lua LegalEncounters line actually uses and mapping its headline spawn back through
  -- UNIT_TO_ENEMY_CHECK. None of these four appear in ANY generic BiomeX spawn pool in the
  -- game's EnemySets.lua (only in their own miniboss encounter, plus BiomeHDebugSpawnScreen for
  -- Vampire, which is a debug-menu set and never a real pool), so they are miniboss-only:
  ["Root-Stalker"] = true,   -- Treant, MiniBossTreant (Erebus)
  ["Phantom"] = true,        -- Vampire, MiniBossVampire (Fields of Mourning)
  ["Satyr Champion"] = true, -- SatyrCrossbow, MiniBossSatyrCrossbow (City of Ephyra)
  ["Headstone"] = true,      -- EarthElemental, MiniBossStalker (The Summit)
  -- 2026-09-24: the remaining miniboss-room headliners (MinibossRooms.ROOM_BIOME). They were
  -- left out so include_minibosses=off kept them and Dream counted them as ordinary enemies.
  ["Shadow-Spiller"] = true, -- FogEmitter_Elite, F_MiniBoss02 (Erebus)
  ["Charybdis"] = true,      -- O_MiniBoss01 (Rift of Thessaly)
  ["The Yargonaut"] = true,  -- Captain, O_MiniBoss02 (Rift of Thessaly)
  ["Talos"] = true,          -- P_MiniBoss01 (Mount Olympus)
  ["Tail of Typhon"] = true, -- TyphonTail, Q_MiniBoss03 (The Summit)
  ["Eye of Typhon"] = true,  -- TyphonEye, Q_MiniBoss04 (The Summit)
}

-- Each enemy check's HOME zone tier (1-4) -- the zone the enemy natively belongs to. Mirrors
-- Python Locations.ENEMY_LAYERS (route -> list of per-zone rosters), flattened: a name's tier is
-- its index within its route's layer list, and the three routes' zone 1s are all tier 1. Verified
-- conflict-free at generation time -- no name appears at two different tiers across routes, so a
-- flat name -> tier map is lossless (137 names, matching the shuffle map's own entry count).
-- Regenerate rather than hand-edit if ENEMY_LAYERS changes (tools/gen_home_tiers.py).
--
-- Used by the art-package lookup (biome_package_for_unit / art_packages_for_unit) to find the
-- biome a unit's textures ship in. (Until 9/26 scale_unit also divided by the unit's Dream tier
-- at this home tier; it now divides by the destination zone's natives instead -- see native_tier.)
--
-- Why a mirrored list instead of reading the game: vanilla H2 hangs DreamBiomeData off the
-- Base<X>Enemy archetypes (readable via InheritFrom), but Zagreus' Journey assigns its templates
-- DIRECTLY per unit with no archetype to read, and its own file notes that modifying base types
-- doesn't work in its setup. Our AP zone assignment is the one source that covers both.
EnemySanity.ENEMY_HOME_TIER = {}
local function _home(tier, names)
  for _, n in ipairs(names) do EnemySanity.ENEMY_HOME_TIER[n] = tier end
end
_home(1, {
  "Alecto", "Brimstone", "Bronzebeak", "Casket", "Cutthroat", "Dire Inferno-Bomber",
  "Doomstone", "Eidolon", "Erymanthian Boar", "Headmistress Hecate", "Lanthorn", "Lubber",
  "Master-Slicer", "Megaera", "Root-Stalker", "Satyr Champion", "Shadow-Spiller", "Shambler",
  "Sister of the Dead", "Skullomat", "Spindle", "The Cyclops Polyphemus", "Thorn-Weeper",
  "Tisiphone", "Tombstone", "Wailer", "Wastrel", "Whisper", "Wretched Lout", "Wretched Sneak"
})
_home(2, {
  "Anchor", "Blasket", "Bloodless", "Bone Hydra", "Bone-Raker", "Boozer", "Burn-Flinger",
  "Charybdis", "Deep Serpent", "Dire Spreader", "Dracon", "Droplet", "Eris", "Gorgon",
  "Harpy Talon", "Hellifish", "Hippo", "Inferno-Bomber", "Jetty", "King Vermin", "Lurker",
  "Megagorgon", "Pinhead", "Roxy", "Scylla", "Sea-Serpent", "Sea-Shambler", "Seesword",
  "Shellback", "Skull-Crusher", "Slam-Dancer", "Sop-Spindle", "Spreader", "Stickler",
  "The Yargonaut", "Voidstone", "Wave-Maker", "Wet-Whisper", "Wretched Pest", "Wretched Witch"
})
_home(3, {
  "Asterius", "Auto-Forcer", "Auto-Seeker", "Auto-Watcher", "Bawlder", "Blight-Shade",
  "Bloat-Shade", "Blood-Shade", "Brightsword", "Brush-Stalker", "Canine", "Dread-Wailer",
  "Flame Wheel", "Greatshield", "Harpy Raptor", "Holeheart", "Infernal Beast", "Lamia",
  "Longspear", "Lycaon", "Mega-Dracon", "Mourner", "Nemean Chariot", "Phantom", "Prometheus",
  "Queen Lamia", "Satyr Goldpike", "Satyr Raider", "Satyr Sapper", "Sky-Dracon", "Smacker",
  "Snow-Shambler", "Sorrow-Spiller", "Soul Catcher", "Splitter", "Strongbow", "Talos",
  "Theseus"
})
_home(4, {
  "Bother", "Chronos", "Crawler", "Eye of Typhon", "Eyesore", "Gigantic Vermin", "Goldwraith",
  "Goldwrath", "Hades", "Headstone", "Horror", "Land-Dracon", "Numbskull", "Polyp",
  "Sandskull", "Satyr Cultist", "Satyr Hoplite", "Satyr Supplicant", "Satyr Vierophant",
  "Snakestone", "Spawn of Typhon", "Stalker", "Tail of Typhon", "Tempus", "The Verminancer",
  "Twins of Typhon", "Typhon", "Wretched Thug", "Wringer"
})

-- Checks whose real unit id ONLY ever spawns through a dedicated scripted boss encounter
-- (unique arena, camera work, a reveal/transition function, cross-referencing another unit's
-- HP in the SAME fight, etc.) -- never through the ordinary generic wave/room-mob spawn path
-- substitution actually runs through. "Charybdis" (Scylla's tentacle companion,
-- EnemyData_Charybdis.lua -- has its own TransitionFunction/PreAISetupFunctionName a generic
-- HandleNextSpawn spawn never triggers, renders as an uninitialized black silhouette when
-- substituted into a normal room) and "Talos" (Mount Olympus miniboss, EnemyData_Talos.lua --
-- MaxHealth 13300 + GenericBossKillPresentation, same one-off choreography) were the first
-- confirmed cases. "Jetty" escalated this from a visual bug to a real SOFTLOCK (8/7, confirmed
-- live): her shield only drops once Scylla AND Roxy are also at half health -- spawned alone in
-- an unrelated miniboss room via substitution, that condition can never be met, so her shield
-- never drops and the room becomes unwinnable. Widened to every zone's singular, uniquely-named
-- boss/multi-unit choreographed fight (Scylla/Roxy/Jetty trio, the three Furies, Theseus+
-- Asterius "fought together", Bone Hydra, and each route's final boss) rather than waiting for
-- more of these to surface one softlock at a time. Left OUT of this set (still ordinary,
-- generic-pool miniboss-room fodder, confirmed via EncounterData_MiniBoss.lua's shared generic
-- miniboss list using the same suffixed unit ids): Master-Slicer, Thorn-Weeper, Deep Serpent,
-- Hellifish, Goldwrath, The Verminancer, Mega-Dracon, Erymanthian Boar, Spawn of Typhon, Twins
-- of Typhon, Dire Spreader, Wretched Sneak, Doomstone, Dire Inferno-Bomber, King Vermin -- none
-- of their EnemyData tables (Boar/Brute_Miniboss/Stalker_Miniboss/...) define a
-- TransitionFunction/PreAISetupFunctionName/PreBossHealthBarSetupFunctionName, just an ordinary
-- OnDeathFunctionName="GenericBossKillPresentation" death flourish -- these substitute among
-- each other same as before. Checked regardless of include_minibosses (this is a
-- technical/softlock limitation, not a difficulty preference). Excluded on BOTH sides (never
-- substituted away from, never substituted in as a replacement) since the same "needs its own
-- choreography" problem applies whichever direction it's used.
-- 8/7 audit (installed game's EnemyData_*.lua files, grepped for TransitionFunction/
-- PreAISetupFunctionName/PreBossHealthBarSetupFunctionName): found 3 more boss-identical checks
-- with real multi-stage choreography that were missing from this set -- Headmistress Hecate
-- (EnemyData_Hecate.lua's HecateStageTransition1/2 + BossStageTransition), The Cyclops
-- Polyphemus (EnemyData_Polyphemus.lua's BossStageTransition), and Infernal Beast
-- (EnemyData_InfestedCerberus.lua's PreBossHealthBarSetupFunctionName +
-- CerberusStageEnter/Exit -- also missing from MINIBOSS_CHECK_NAMES entirely until this pass,
-- since its boss-event name "Cerberus" differs from its enemy-check name).
EnemySanity.SCRIPTED_ONLY_CHECK_NAMES = {
  -- 8/16, user-reported and confirmed against the installed game: SatyrCultist appears in NO
  -- EnemySet at all -- its only references are EncounterData_Boss.lua's Chronos fight (an
  -- ActivatePrePlaced with LegalTypes = { "Chronos", "SatyrCultist" }) and WeaponData_Chronos.lua,
  -- which summons it mid-fight. It is a Chronos-fight-only unit and makes no sense in an ordinary
  -- room. It also explains why the biome-package preload never fixed its silhouette: its art
  -- ships in the Chronos package, not in any Biome<X> one. An audit for the same pattern (unit in
  -- no EnemySet, referenced only from boss/weapon data) found this to be the ONLY such case.
  ["Satyr Supplicant"] = true,
  ["Charybdis"] = true,
  ["Talos"] = true,
  ["Scylla"] = true,
  ["Roxy"] = true,
  ["Jetty"] = true,
  ["Chronos"] = true,
  ["Eris"] = true,
  ["Prometheus"] = true,
  ["Typhon"] = true,
  ["Megaera"] = true,
  ["Alecto"] = true,
  ["Tisiphone"] = true,
  ["Theseus"] = true,
  ["Asterius"] = true,
  ["Hades"] = true,
  ["Bone Hydra"] = true,
  ["Headmistress Hecate"] = true,
  ["The Cyclops Polyphemus"] = true,
  ["Infernal Beast"] = true,
  -- 9/23: units that never come through a spawn this file can rewrite (it only touches
  -- SpawnWaves entries it can map to a check), so in the permutation they're dead ends: their
  -- target is never produced, and anything mapped onto them puts the wrong unit in a normal
  -- room. Mirrors Python Locations.SCRIPTED_ONLY_CHECK_NAMES, which lists the reason for each.
  -- Already-generated seeds are repaired by induced_map below, same as the entries above.
  ["Eye of Typhon"] = true,       -- 25,000-HP pre-placed Summit arena unit (BossTyphonEye01)
  ["Tail of Typhon"] = true,      -- same, BossTyphonTail01
  ["Lanthorn"] = true,            -- only summoned by Master-Slicer
  ["Canine"] = true,              -- only summoned by Lycaon
  ["Pinhead"] = true,             -- pools spawn it as FishSwarmerSquad (unmapped group)
  ["Polyp"] = true,               -- pools spawn it as SimpleSquad (unmapped group)
  ["Sister of the Dead"] = true,  -- only Hecate's boss-fight adds
  -- 11/3, mirroring session F's Locations.py entry: HitAndRunUnit is in no regular ZJ pool (only
  -- MiniBossHitAndRun's Elite, never substituted, and SuperElite in ZJ's special sets).
  ["Megagorgon"] = true,
}

-- enemysanity option values (match Options.EnemySanity / Locations.ENEMYSANITY_*).
local MODE_VANILLA = 0
local MODE_VANILLA_PLUS_LOCATIONS = 1
local MODE_SHUFFLED = 2
local MODE_SHUFFLED_PLUS_LOCATIONS = 3
local MODE_PURE_RANDOM = 4

local function current_mode()
  return ItemManager.setting_mode("enemysanity")
end

-- Public: does the current mode add "X Defeated" check locations? (vanilla_plus_locations /
-- shuffled_plus_locations). Read by LocationManager.on_enemy_killed and the goal-cascade /
-- Zagreus-Defeated send gates in place of the old ItemManager.setting_on("enemy_locations").
function EnemySanity.locations_on()
  local m = current_mode()
  return m == MODE_VANILLA_PLUS_LOCATIONS or m == MODE_SHUFFLED_PLUS_LOCATIONS
end

-- Public: does the current mode substitute/scale spawns at all? (shuffled /
-- shuffled_plus_locations / pure_random).
function EnemySanity.substitution_on()
  local m = current_mode()
  return m == MODE_SHUFFLED or m == MODE_SHUFFLED_PLUS_LOCATIONS or m == MODE_PURE_RANDOM
end

-- Public: is this one of the map-based modes? Their permutation is keyed by enemy name and takes
-- no route argument. (No caller since 10/4: the SetupEncounter hook now serves pure_random too.)
function EnemySanity.shuffled_mode()
  local m = current_mode()
  return m == MODE_SHUFFLED or m == MODE_SHUFFLED_PLUS_LOCATIONS
end

local function include_minibosses()
  return ItemManager.setting_on("include_minibosses")
end

-- 2026-08-09: ZJ became an optional dependency, so "the YAML wants ZJ content" and "ZJ is
-- actually installed" are no longer the same thing (previously Thunderstore force-installed it,
-- guaranteeing the two matched). Without the presence check, pool_for() would pool Nightmare's
-- ZJ-exclusive unit ids (Theseus/Hades/Megaera/...) into Underworld/Surface substitution even
-- with ZJ absent, handing a non-existent unit id to the native spawn path.
local function global_scope()
  return ItemManager.setting_on("include_zagreus_journey") and ItemManager.nightmare_mod() ~= nil
end

-- Is this unit id something the generic wave-spawn path can actually spawn? EncounterLogic.lua's
-- HandleNextSpawn indexes EnemyData[spawnInfo.Name] directly, and an id that isn't there drops
-- into its "Back Compat" retry loop -- which crashes outright when encounter.EnemySet is nil
-- (the 8/7 "attempt to compare number with nil" run-killer), and even with reload.lua's crash
-- guard in place leaves the spawn's RemainingSpawns undecremented, so the wave can never finish.
-- Every id this file hands back to the spawn path goes through here first.
-- Checked LIVE (not once at load): LocationManager builds CHECK_TO_UNIT_ID during our on_ready,
-- which fires off the RoomLogic.lua import event -- Zagreus' Journey registers its own EnemyData
-- entries later, so a load-time check would wrongly reject every Nightmare unit id.
local function spawnable(id)
  return type(id) == "string" and EnemyData ~= nil and EnemyData[id] ~= nil
end

-- Variant tiers a spawn can carry. Native H2 underscores them (Brawler_Elite, Boar_SuperElite,
-- Treant_Shadow); ported Nightmare content doesn't (SwarmerElite, RatThugMiniboss). Ordered
-- longest-first so "_SuperElite" is matched before "_Elite" and "SuperElite" before "Elite".
-- Same list LocationManager.resolve_enemy_check strips to find a variant's base AP check.
local VARIANT_SUFFIXES = { "_SuperElite", "_Elite", "_Shadow", "SuperElite", "Elite", "MiniBoss", "Miniboss" }
local ALT_SUFFIX = {
  ["_SuperElite"] = "SuperElite", ["SuperElite"] = "_SuperElite",
  ["_Elite"] = "Elite",           ["Elite"] = "_Elite",
  ["_Shadow"] = "Shadow",         ["Shadow"] = "_Shadow",
  ["Miniboss"] = "MiniBoss",      ["MiniBoss"] = "Miniboss",
}

-- Split a spawn's unit id into (base id, variant suffix) -- suffix nil when it's a plain base
-- unit. Guarded on the stripped base actually being a real unit (either mapped to an AP check,
-- like resolve_enemy_check requires, or present in EnemyData), so an ordinary enemy whose name
-- merely happens to end in one of these strings isn't mistaken for a variant.
local function split_variant(unitId)
  for _, suffix in ipairs(VARIANT_SUFFIXES) do
    if #unitId > #suffix and unitId:sub(-#suffix) == suffix then
      local base = unitId:sub(1, #unitId - #suffix)
      if LocationManager.UNIT_TO_ENEMY_CHECK[base] or spawnable(base) then return base, suffix end
    end
  end
  return unitId, nil
end

-- The matching variant of a replacement's base unit id, or nil if the game has no such variant.
-- Elite/SuperElite/Shadow/Miniboss spawns are a real difficulty tier, not a skin: substituting
-- one for a plain base unit silently downgrades the fight (confirmed live 8/8 --
-- "HeavyRangedForkedMiniboss -> CrusherUnit" and "RatThugMiniboss -> SentryBot" turned miniboss
-- rooms into ordinary trash while still paying a miniboss reward, and every "...Elite" spawn lost
-- its elite tier). Tries the original suffix first, then the other naming convention, since a
-- replacement drawn from the opposite content set spells it the other way.
local function variant_of(baseId, suffix)
  if not suffix then return baseId end
  if spawnable(baseId .. suffix) then return baseId .. suffix end
  local alt = ALT_SUFFIX[suffix]
  if alt and spawnable(baseId .. alt) then return baseId .. alt end
  return nil
end

-- Lazily parsed from the "enemysanity_shuffle_map" setting ("NameA:NameB,NameC:NameD,...",
-- bare enemy names -- see Locations.compute_enemysanity_shuffle_map/Client.encode_settings).
-- Re-parsed only when the raw string actually changes (e.g. on reconnect to a different seed).
local _shuffle_map_raw = nil
local _shuffle_map_cache = {}

-- Rebuild the seed's permutation so it never routes through a SCRIPTED_ONLY_CHECK_NAMES entry.
-- The generated map is a derangement (a cyclic permutation per pool), so every name is exactly
-- one other name's replacement. Refusing to substitute FROM a scripted-only name therefore
-- orphans whatever that name mapped TO: with this seed's map ("Scylla:Queen Lamia" and
-- "Doomstone:Scylla"), Scylla never substitutes, so Queen Lamia never spawns ANYWHERE -- and
-- because her own slot spawns something else, "Queen Lamia Defeated" becomes unobtainable for
-- the rest of the seed. One unreachable check per scripted-only name, ~19 of them.
-- Fix: take the permutation INDUCED on the non-scripted names -- walk the cycle past each
-- scripted-only entry to the next real one. That's still a bijection over exactly the names we
-- do substitute, so every one of them stays reachable, and scripted-only units simply keep
-- spawning natively (their own checks were never at risk). Derived from the map we already have,
-- so already-generated seeds are fixed without regenerating.
-- The same walk additionally repairs miniboss/trash CROSSINGS (8/16). Python builds the miniboss
-- and regular cycles separately (Locations.compute_enemysanity_shuffle_map split_pools), so a
-- correct map never crosses classes and this walk is a no-op on it. But that split is only as
-- good as MINIBOSS_ENEMY_NAMES, and four miniboss-only names were missing from it (see the
-- MINIBOSS_CHECK_NAMES additions above) -- in ALREADY-GENERATED seeds those four sit inside the
-- regular cycle, so a trash slot could roll a miniboss and a miniboss slot could roll trash.
-- Walking past any target whose class differs from the source's restores the split without
-- regenerating: the four keep spawning natively in their own miniboss rooms (where their
-- "Defeated" checks come from anyway), and no ordinary room can draw one.
local function is_miniboss_name(name)
  return EnemySanity.MINIBOSS_CHECK_NAMES[name] == true
end

local function induced_map(parsed)
  local out = {}
  for src, dst in pairs(parsed) do
    if not EnemySanity.SCRIPTED_ONLY_CHECK_NAMES[src] then
      local srcIsMiniboss = is_miniboss_name(src)
      local target, guard = dst, 0
      while target and guard < 512
            and (EnemySanity.SCRIPTED_ONLY_CHECK_NAMES[target]
                 or is_miniboss_name(target) ~= srcIsMiniboss) do
        target = parsed[target]
        guard = guard + 1
      end
      if target and target ~= src and not EnemySanity.SCRIPTED_ONLY_CHECK_NAMES[target]
         and is_miniboss_name(target) == srcIsMiniboss then
        out[src] = target
      end
    end
  end
  return out
end

local function shuffle_map()
  local raw = ItemManager.settings["enemysanity_shuffle_map"]
  if raw ~= _shuffle_map_raw then
    _shuffle_map_raw = raw
    local parsed = {}
    if type(raw) == "string" and raw ~= "" then
      for pair in raw:gmatch("[^,]+") do
        local a, b = pair:match("^(.-):(.*)$")
        if a and b and a ~= "" and b ~= "" then parsed[a] = b end
      end
    end
    _shuffle_map_cache = induced_map(parsed)
  end
  return _shuffle_map_cache
end

-- The check a NATIVE spawn of `name` produces this seed: its shuffle target in the shuffled
-- modes, the name itself otherwise. LocationManager's Cerberus release uses it, because the rare
-- slot is the Fields spawn (GeneratedH_Treant2/_Screamer2), not the creature. (Session F, 11/3.)
-- Refused the same way replacement_unit_id refuses (miniboss names, miniboss-room checks), so
-- the answer is the check that really spawns there, not just what the map says.
function EnemySanity.slot_check(name)
  if not EnemySanity.shuffled_mode() or type(name) ~= "string" then return name end
  if EnemySanity.MINIBOSS_CHECK_NAMES[name] then return name end
  if MinibossRooms and MinibossRooms.ROOM_CHECK_NAMES and MinibossRooms.ROOM_CHECK_NAMES[name] then
    return name
  end
  return shuffle_map()[name] or name
end

-- Bare-name roster for one route's pure_random pool, split by miniboss membership. Mirrors
-- Python enemy_locations_for(route)'s shape: Nightmare additionally pulls in the 12
-- SHARED_ENEMY_CHECKS names and King Vermin (its own ENEMY_CHECKS_BY_ROUTE list deliberately excludes them --
-- they already live in Underworld's list). Global scope pools all three routes' own lists
-- together WITHOUT re-adding SHARED_ENEMY_CHECKS a second time (they're already present via
-- Underworld's list, so re-adding would just double their odds).
local function pool_for(route, wantMiniboss)
  local names = {}
  local function add_list(list)
    for _, n in ipairs(list) do
      local isMB = EnemySanity.MINIBOSS_CHECK_NAMES[n] == true
      if isMB == wantMiniboss then table.insert(names, n) end
    end
  end
  -- "Dream" is not one of our rosters -- it's a ROUTE-SHAPED label Routes.current() returns for
  -- any room during a Dream Dive, whose regions are whole vanilla biomes drawn from every other
  -- route (DreamDiveTweaks' all_biomes = the 4 Underworld + 4 Surface letters, plus Zagreus'
  -- Journey's 4 when it's installed). ENEMY_CHECKS_BY_ROUTE["Dream"] is therefore nil, so
  -- pure_random inside a Dream run used to build an EMPTY pool and substitute nothing at all --
  -- enemysanity silently did nothing for the entire route. Pool the routes a Dream region can
  -- actually be, mirroring Python's own _dream_roster_counts (Underworld + Surface, plus
  -- Nightmare only when ZJ is really there to supply those unit ids).
  if route == "Dream" then
    add_list(LocationManager.ENEMY_CHECKS_BY_ROUTE["Underworld"] or {})
    add_list(LocationManager.ENEMY_CHECKS_BY_ROUTE["Surface"] or {})
    if ItemManager.nightmare_mod() ~= nil then
      add_list(LocationManager.ENEMY_CHECKS_BY_ROUTE["Nightmare"] or {})
    end
    return names
  end
  if global_scope() then
    for _, r in ipairs({ "Underworld", "Surface", "Nightmare" }) do
      add_list(LocationManager.ENEMY_CHECKS_BY_ROUTE[r] or {})
    end
  else
    add_list(LocationManager.ENEMY_CHECKS_BY_ROUTE[route] or {})
    if route == "Nightmare" then
      add_list(LocationManager.SHARED_ENEMY_CHECKS or {})
      add_list({ LocationManager.KING_VERMIN_CHECK })
    end
  end
  return names
end

-- Public: given the unit id that WOULD natively spawn and the current room's route (from
-- Routes.current()), return a replacement unit id to spawn instead, or nil for "spawn
-- natively" (vanilla modes, unmapped/unidentifiable units, or a miniboss slot when
-- include_minibosses is off). Called from reload.lua's StartEncounter wrap, once per
-- EnemySet entry, before the vanilla wave-spawn runs.
-- Turn a chosen replacement CHECK name into the concrete unit id to spawn, preserving whatever
-- variant tier (Elite/SuperElite/Shadow/Miniboss) the original spawn carried. Returns nil --
-- "leave the original spawn alone" -- whenever that can't be done safely: a scripted-only
-- target, no known unit id for the check, an id the game can't actually spawn, or a variant
-- spawn whose replacement has no equivalent variant. Fail-closed on purpose: skipping one
-- substitution is invisible, whereas spawning an unspawnable id stalls the wave and dropping an
-- enemy's variant tier silently guts the room it was placed in.
local function resolve_replacement(replacementCheck, suffix)
  if not replacementCheck then return nil end
  if EnemySanity.SCRIPTED_ONLY_CHECK_NAMES[replacementCheck] then return nil end
  local baseId = LocationManager.CHECK_TO_UNIT_ID[replacementCheck]
  if not spawnable(baseId) then return nil end
  local id = variant_of(baseId, suffix)
  if not spawnable(id) then return nil end
  return id
end

function EnemySanity.replacement_unit_id(originalUnitId, route)
  local mode = current_mode()
  if mode == MODE_VANILLA or mode == MODE_VANILLA_PLUS_LOCATIONS then return nil end
  if type(originalUnitId) ~= "string" then return nil end

  local origCheck = LocationManager.enemy_check_for_unit(originalUnitId)
  if not origCheck then return nil end -- unmapped unit: leave it alone, don't risk a bad swap
  if EnemySanity.SCRIPTED_ONLY_CHECK_NAMES[origCheck] then return nil end -- never substitute FROM these

  -- Variant tier of the SPAWN, not of the check: Elite/Miniboss ids share their base unit's AP
  -- check name by design (LocationManager.resolve_enemy_check strips the suffix), so the check
  -- name alone can't tell a miniboss-room spawn from ordinary trash.
  local _, suffix = split_variant(originalUnitId)

  -- Miniboss-classified names never substitute in either direction (8/16 ruling -- their ROOMS
  -- get shuffled instead; see substitute_encounter). This also covers the names that are
  -- miniboss-classified for LOGIC but still spawn as ordinary trash, like Thorn-Weeper, whose
  -- normal-room spawns were drawing real minibosses out of the miniboss pool.
  local isMiniboss = EnemySanity.MINIBOSS_CHECK_NAMES[origCheck] == true
  if isMiniboss then return nil end
  -- Checks owned by the miniboss-ROOM shuffle are held out of enemy substitution too, so exactly
  -- one system decides where each is obtainable (Python asserts the same disjointness at
  -- generation -- it fired on "Shadow-Spiller", F_MiniBoss02's miniboss, which reads as an
  -- ordinary name and so was in both pools). Only matters for pure_random here, since the
  -- generated map already omits them.
  if MinibossRooms and MinibossRooms.ROOM_CHECK_NAMES
     and MinibossRooms.ROOM_CHECK_NAMES[origCheck] then return nil end

  if mode == MODE_SHUFFLED or mode == MODE_SHUFFLED_PLUS_LOCATIONS then
    return resolve_replacement(shuffle_map()[origCheck], suffix)
  end

  if mode == MODE_PURE_RANDOM then
    local candidates = {}
    for _, n in ipairs(pool_for(route, isMiniboss)) do
      if n ~= origCheck then
        local id = resolve_replacement(n, suffix)
        if id then table.insert(candidates, id) end
      end
    end
    if #candidates == 0 then return nil end
    return candidates[RandomInt(1, #candidates)]
  end

  return nil
end

-- Make a substituted unit's art resident before it spawns. Hades II streams enemy art per
-- package and the game loads a spawn's package by UNIT ID -- RoomLogic.lua's LoadSpawnPackages
-- does exactly "for _, spawnData in pairs(encounter.Spawns) do LoadPackages({ Name =
-- spawnData.Name }) end" at room load. Our substitution rewrites spawnData.Name at StartEncounter,
-- AFTER that pass has already run against the original ids, so the replacement's package was
-- never requested and the engine draws the sprite as a flat untextured fill -- reported live 8/16
-- as a solid-black Bloat-Shade in Erebus and solid-yellow minibosses (two different fill colors,
-- same missing-texture cause; it is NOT how either enemy actually looks). IgnoreAssert because
-- plenty of unit ids have no package of their own, which is not an error -- same flag the game's
-- own speculative loads use (RoomLogic.lua:1473, BountyLogic.lua:804).
-- 8/16, second pass: the per-unit form of this was a silent no-op and the silhouettes came back.
-- Content/Packages/1080p holds 88 real .pkg files and NONE of them is named after an ordinary
-- enemy -- enemy art ships inside the BIOME packages (BiomeF/G/H/I for the Underworld,
-- BiomeN/O/P/Q for the Surface), with per-name packages existing only for gods/NPCs/bosses
-- (Scylla, Chronos, Hades...). RoomLogic.lua's own LoadSpawnPackages does call
-- LoadPackages({ Name = spawnData.Name }), but with those unit names resolving to no package it
-- is a no-op there too -- the art is already resident because the room loaded its own biome.
-- So the package to request is the one for the replacement's HOME biome, which is exactly what
-- ENEMY_HOME_TIER plus the unit's route gives us.
-- 9/24 corrections: (1) that guess is replaced by UnitArtPackages.lua wherever the game's own files
-- say otherwise -- see art_packages_for_unit below. (2) Zagreus' Journey DOES ship .pkg files (in
-- plugins_data/NikkelM-Zagreus_Journey/Content/Packages, loaded by name like any other); the old
-- "loose assets, always resident" note was wrong, so Nightmare units used to get no load at all.
local ROUTE_BIOME_LETTERS = {
  Underworld = { "F", "G", "H", "I" },
  Surface    = { "N", "O", "P", "Q" },
}

-- Zagreus' Journey's per-biome packages (its Game/MapGroups.sjson.lua maps A_*/X_*/Y_*/D_* to
-- these), by Nightmare zone.
local ZJ_BIOME_PACKAGES = {
  "TartarusModsNikkelMHadesBiomes", "AsphodelModsNikkelMHadesBiomes",
  "ElysiumModsNikkelMHadesBiomes", "StyxModsNikkelMHadesBiomes",
}
-- What every ZJ room loads on top of its biome's package (ZJ Scripts/RoomData.lua,
-- LoadModdedPackages). RoomManagerModsNikkelMHadesBiomes holds the shared Hades I enemy sprites.
local ZJ_ROOM_PACKAGES = {
  "RoomManagerModsNikkelMHadesBiomes", "NikkelM-HadesBiomesFxModded",
  "NikkelM-HadesBiomesGUIModded", "ModsNikkelMHadesBiomesGUIOriginal",
  -- 11/3: plus the two ZJ attaches to every one of its biome packages through
  -- rom.data.load_package_overrides_set (ZJ Scripts/Meta/Utils.lua SetBiomePackageLoadOverrides)
  -- rather than listing them per room. FxOriginal holds the Hades I enemy effects: the 10/5 and
  -- 10/12 logs' missing-texture lists were mostly from it (EnemySummonRune, EnemySummonSmoke,
  -- ShadeNakedFlame, EnemyLaserPreview, ChariotIdleTrail). Whether a by-name LoadPackages of the
  -- biome package triggers ZJ's override set is not something we can see from here, so ask for
  -- them by name; a package that is already resident is a no-op.
  "ModsNikkelMHadesBiomesFxOriginal", "ModsNikkelMHadesBiomesDevOriginal",
}

-- check name -> route, built lazily from the route rosters LocationManager already owns (it
-- fills them during our on_ready, so this can't be done at load time).
local _check_route = nil
local function route_of_check(check)
  if not _check_route then
    _check_route = {}
    for route, names in pairs(LocationManager.ENEMY_CHECKS_BY_ROUTE or {}) do
      for _, n in ipairs(names) do _check_route[n] = route end
    end
  end
  return _check_route[check]
end

-- Public: the biome art package a unit id needs ("BiomeH"), or nil when there isn't one.
function EnemySanity.biome_package_for_unit(id)
  local check = LocationManager.enemy_check_for_unit(id)
  if not check then return nil end
  local tier = EnemySanity.ENEMY_HOME_TIER[check]
  local letters = ROUTE_BIOME_LETTERS[route_of_check(check) or ""]
  if not tier or not letters or not letters[tier] then return nil end
  return "Biome" .. letters[tier]
end

-- Public: the packages to load for a unit id's art (possibly empty). 9/24: the home-biome guess
-- above is wrong for any unit whose textures ship elsewhere -- the Bloodless family (Asphodel
-- Anomaly) guessed BiomeG, but its textures are only in BiomeB/BiomeH. For Hades II units,
-- UnitArtPackages.lua (generated from the game's own model and package files by
-- tools/gen_unit_art_packages.py) lists the packages that really hold each unit's textures; the
-- home biome is still preferred when it is one of them, so nothing changes where the guess was
-- right, and units the table doesn't cover keep the guess. Nightmare (ZJ) units are 2D Hades I
-- sprites that ZJ builds at runtime from the Hades I install, so there is nothing static to scan:
-- they get exactly what ZJ itself loads for a room in that unit's home biome.
function EnemySanity.art_packages_for_unit(id)
  local check = LocationManager.enemy_check_for_unit(id)
  if check and route_of_check(check) == "Nightmare" then
    local tier = EnemySanity.ENEMY_HOME_TIER[check]
    if not tier or not ZJ_BIOME_PACKAGES[tier] then return {} end
    local out = { ZJ_BIOME_PACKAGES[tier] }
    for _, package in ipairs(ZJ_ROOM_PACKAGES) do out[#out + 1] = package end
    return out
  end
  local home = EnemySanity.biome_package_for_unit(id)
  local holders = UnitArtPackages and UnitArtPackages[id]
  if type(holders) ~= "table" or #holders == 0 then return home and { home } or {} end
  for _, package in ipairs(holders) do
    if package == home then return { home } end
  end
  return { holders[1] }
end

function EnemySanity.preload_unit_package(id)
  if type(id) ~= "string" or id == "" then return end
  -- A Nightmare unit's sounds live in ZJ's own banks, which nothing loads off its route.
  local check = LocationManager.enemy_check_for_unit(id)
  if check and route_of_check(check) == "Nightmare" then
    pcall(EnemySanity.load_zj_enemy_audio)
  else
    -- ...and a Hades II unit's live in its home biome's bank, loaded only in that biome.
    pcall(EnemySanity.load_h2_enemy_audio, id)
  end
  if type(LoadPackages) ~= "function" then return end
  local packages = EnemySanity.art_packages_for_unit(id)
  if #packages == 0 then return end
  -- IgnoreAssert: a package already resident (the room's own biome) or otherwise unavailable is
  -- not an error worth killing the spawn over -- same flag the game's own speculative loads use.
  pcall(LoadPackages, { Names = packages, IgnoreAssert = true })
end

-- Substitution decisions taken BEFORE spawn time, keyed by the spawn entry table itself. Two
-- reasons this is decided early rather than at the StartEncounter rewrite: it gives the package
-- load above a head start (room load instead of wave start), and it pins pure_random's roll so
-- the id we preloaded is the id that actually spawns -- re-rolling at StartEncounter would load
-- one enemy's art and then spawn a different one. Weak keys: these tables belong to the room's
-- encounter, and this cache must not be what keeps them alive.
local _planned = setmetatable({}, { __mode = "k" })

-- Public: rewrite every not-yet-substituted spawn entry in an encounter, in place.
--
-- 8/16, third pass (user-diagnosed): "the shuffler is only working when the enemies spawn in mid
-- combat, and not shuffling the enemies that are already there when I walk into the room." Exactly
-- right. Rooms with PreSpawnEnemies place their starting enemies through EncounterLogic.lua's
-- HandleEncounterPreSpawns, which runs at ROOM LOAD off SetupEncounter's output -- long before
-- StartEncounter, which was our only rewrite point. So pre-placed enemies kept their vanilla ids
-- (Wastrels and Caskets still standing in Erebus) while mid-combat waves shuffled correctly.
-- Hoisting the rewrite into a SetupEncounter wrap fixes both, since that is where SpawnWaves and
-- TotalCount are first populated -- earlier than either spawn path can read them.
--
-- Miniboss rooms are left entirely alone (8/16 user ruling: shuffle miniboss ROOMS, not the
-- minibosses in them). Classifying by check NAME cannot express "this spawn is the room's
-- miniboss", and both directions were observed breaking live in one room:
--   * SiegeVine resolves to "Thorn-Weeper", a miniboss-classified name, so its ordinary trash
--     spawns drew from the miniboss pool -- three Vampires appeared as the adds.
--   * FogEmitter_Elite, the room's actual miniboss, strips to "Shadow-Spiller" (a REGULAR
--     check), so the miniboss itself was replaced by a regular Lamia at elite tier.
-- Keying off the encounter instead is exact: every miniboss room's encounter inherits
-- MinibossEncounter (EncounterType "Miniboss", lowercase b), so its whole authored composition --
-- headline miniboss and adds alike -- stays vanilla. The name prefix alone misses the Summit's
-- BossTyphonTail01/BossTyphonEye01, whose adds come from GeneratedQ. Every substitution path
-- checks this (9/23: the StartEncounter and LoadSpawnPackages paths used to skip it and still
-- swapped the adds).
function EnemySanity.encounter_is_miniboss(encounter)
  if type(encounter) ~= "table" then return false end
  local name = encounter.Name
  local etype = encounter.EncounterType
  if etype == nil and type(name) == "string" and game.EncounterData and game.EncounterData[name] then
    etype = game.EncounterData[name].EncounterType
  end
  return etype == "Miniboss" or (type(name) == "string" and name:match("^MiniBoss") ~= nil)
end

-- Idempotent via spawnData._ap_substituted, so the later hooks can call it again harmlessly; that
-- also pins pure_random's roll to whichever call got there first, keeping the id we preloaded art
-- for and the id that actually spawns the same one.
function EnemySanity.substitute_encounter(encounter, route, room)
  if not EnemySanity.substitution_on() then return end
  if not encounter or not encounter.SpawnWaves then return end
  if not route then return end
  if EnemySanity.encounter_is_miniboss(encounter) then return end
  for _, wave in ipairs(encounter.SpawnWaves) do
    if wave.Spawns then
      for _, spawnData in ipairs(wave.Spawns) do
        if type(spawnData) == "table" and spawnData.Name and not spawnData._ap_substituted then
          local original = spawnData.Name
          local replacement = EnemySanity.replacement_unit_id(original, route)
          if replacement then
            EnemySanity.preload_unit_package(replacement)
            rom.log.info("[AP] enemysanity: substituted " .. original .. " -> " .. replacement)
            EnemySanity.rebalance_spawn_count(spawnData, original, replacement, room)
            spawnData.Name = replacement
            EnemySanity.mark_substituted(spawnData, original)
          end
        end
      end
    end
  end
end

-- Public: decide + preload every substitution for one encounter, mutating nothing. Safe to call
-- more than once against the same encounter (already-planned entries are left alone), which
-- matters because the room-load pass and StartEncounter can both see the same tables.
function EnemySanity.plan_encounter(encounter, route)
  if not EnemySanity.substitution_on() then return end
  if not encounter or not encounter.SpawnWaves then return end
  if not route then return end
  if EnemySanity.encounter_is_miniboss(encounter) then return end
  for _, wave in ipairs(encounter.SpawnWaves) do
    if wave.Spawns then
      for _, spawnData in ipairs(wave.Spawns) do
        if type(spawnData) == "table" and spawnData.Name and not spawnData._ap_substituted
           and _planned[spawnData] == nil then
          local replacement = EnemySanity.replacement_unit_id(spawnData.Name, route)
          -- false, not nil: "decided, and the answer is don't substitute". nil would read as
          -- "not yet decided" and let pure_random roll again at StartEncounter.
          _planned[spawnData] = replacement or false
          if replacement then EnemySanity.preload_unit_package(replacement) end
        end
      end
    end
  end
end

local function preload_substituted_spawns(encounter)
  if type(encounter) ~= "table" or type(encounter.SpawnWaves) ~= "table" then return end
  for _, wave in ipairs(encounter.SpawnWaves) do
    if type(wave) == "table" and wave.Spawns then
      for _, spawnData in ipairs(wave.Spawns) do
        if type(spawnData) == "table" and spawnData.Name
           and (spawnData._ap_substituted
                or (spawnData.SpawnOverrides and spawnData.SpawnOverrides.AP_EnemySanitySubstituted)) then
          EnemySanity.preload_unit_package(spawnData.Name)
        end
      end
    end
  end
end

-- Public: request the art for every spawn in this room that has ALREADY been substituted. 10/7,
-- live (0.10.0, Ephyra): substituted Brimstones were balls of light, other substitutes flat
-- yellow/black, and the log's missing-texture list was the substitutes' own sprites -- with not
-- one of their packages ever requested. Since the rewrite moved to SetupEncounter the only load
-- was issued there, which is while the room is still being built -- i.e. from the room BEFORE it,
-- one map load too early to count -- and plan_encounter skips entries that are already rewritten,
-- so the room's own load asked for nothing. A save loaded into the room never reaches either
-- point at all. Called from the LoadCurrentRoomResources wrap, which runs on every run-room map
-- load, fresh entry and save load alike. Not gated on substitution_on(): the flag on the spawn is
-- the fact, and on a save load the settings can arrive after the room does.
function EnemySanity.preload_room_art(room)
  if type(room) ~= "table" then return end
  preload_substituted_spawns(room.Encounter)
  if type(room.Encounters) == "table" then
    for _, encounter in ipairs(room.Encounters) do preload_substituted_spawns(encounter) end
  end
  if type(room.CageRewards) == "table" then
    for _, cageReward in ipairs(room.CageRewards) do
      if type(cageReward) == "table" then preload_substituted_spawns(cageReward.Encounter) end
    end
  end
end

-- Public: the decision already taken for this spawn entry. Returns (replacementOrNil, decided) --
-- the second value distinguishes "decided: leave it alone" from "never planned".
function EnemySanity.planned_replacement(spawnData)
  local v = _planned[spawnData]
  if v == nil then return nil, false end
  if v == false then return nil, true end
  return v, true
end

-- One enemy's difficulty rating as the GENERATOR values it. Prefers the game's own
-- CalculateEnemyDifficultyRating (RunLogic.lua:1468) because it folds in elite-attribute
-- multipliers, which matters since substitution preserves variant tiers -- falling back to the
-- raw GeneratorData figure when there's no room to evaluate against.
local function enemy_difficulty(id, room)
  if type(id) ~= "string" or EnemyData == nil or EnemyData[id] == nil then return nil end
  if room and type(CalculateEnemyDifficultyRating) == "function" then
    local ok, value = pcall(CalculateEnemyDifficultyRating, id, room)
    if ok and type(value) == "number" and value > 0 then return value end
  end
  local gd = EnemyData[id].GeneratorData
  if gd and type(gd.DifficultyRating) == "number" and gd.DifficultyRating > 0 then
    return gd.DifficultyRating
  end
  return nil
end

-- Public: keep a substituted spawn inside the difficulty budget the generator already spent on
-- the ORIGINAL enemy. RunLogic.lua's FillEnemyTypes sizes a wave by division --
-- "allowedCount = math.ceil(difficultySlice / spawnData.GeneratorData.DifficultyRating)" -- and
-- writes the result to spawnData.TotalCount, all inside SetupEncounter, well before our
-- StartEncounter rewrite. So a slot budgeted for twelve rating-18 Wastrels (216 points) silently
-- became twelve rating-70 Bloat-Shades (840) -- roughly 4x the room the generator intended.
-- Rescaling TotalCount by the inverse ratio restores it: 12 * 18/70 -> 3 shades, 210 points.
--
-- Only touches entries the generator itself produced (spawnData.Generated). Hand-authored
-- encounters carry deliberate CountMin/CountMax/TotalCount compositions that FillEnemyTypes
-- explicitly skips (it only accumulates their difficulty), and second-guessing an authored fight's
-- shape is not what this is for.
--
-- 10/4: the rating is each enemy's worth IN ITS HOME ZONE, but scale_unit then retunes the
-- replacement's health for the zone it lands in -- so the move was being paid for twice. Live:
-- Tartarus, "SwarmerClockwork x19 -> Guard x133 (rating 35 -> 5)" beside a second slot of 91, every
-- one of them at 6x health -- 205 Guards spawned in that room; and the other way round, seven
-- Oceanus enemies became a single Mourner at 0.56x health. zone_health_factor is the health
-- multiplier the replacement is about to get against the enemy it replaces, and the rating is
-- weighted by it: a Guard in Tartarus is worth 5 * 6 = 30, so 19 Swarmers come out as 22 Guards.
-- 11/3: the growth backstop was 4x the generator's count, and that was still the room the players
-- reported. A cheap enemy that replaces an expensive one is budget-correct at any count, but the
-- room is then a crowd: 0.10.0 logs show "BrokenHearted x9 -> Guard x68" in Fields with ZJ off and
-- no Vow of Hordes (quarth), and "SatyrRatCatcher x9 -> Guard x198" three times over in one
-- Tartarus room -- 425 Guards and 127 Zombies came out of it over four minutes before the player
-- gave up (RyoTsushigawa). 4x would still have made that room ~100 enemies. The ceiling is now
-- what the game itself lets a room grow by: Vow of Hordes at its top rank (1.6x, read from
-- MetaUpgradeData so a game update carries over). Whatever budget the cap leaves unspent stays
-- unspent -- the room comes out easier, never longer.
-- Hades I's Bone Dracon (RangedBurrower, the "Dracon" check) doesn't grow at all: it spends most
-- of a fight underground and out of reach, so a crowd of them is a room you wait out rather than
-- fight (NikkelM's report: the shuffle put more of them in Fields than Vow of Menace ever does).
-- Zagreus' Journey's own Vow of Menace brings them in one for one, in place of Brimstones (its
-- MetaUpgradeData nextbiomeShrineSwapMap), and so does this.
local DEFAULT_MAX_COUNT_GROWTH = 1.6
local ONE_FOR_ONE_CHECKS = { ["Dracon"] = true }

local function max_count_growth()
  local metaUpgrades = (game and game.MetaUpgradeData) or MetaUpgradeData
  local data = metaUpgrades and metaUpgrades.EnemyCountShrineUpgrade
  local best = nil
  if type(data) == "table" and type(data.Ranks) == "table" then
    for _, rank in ipairs(data.Ranks) do
      if type(rank) == "table" and type(rank.ChangeValue) == "number"
         and rank.ChangeValue > 1 and (best == nil or rank.ChangeValue > best) then
        best = rank.ChangeValue
      end
    end
  end
  return best or DEFAULT_MAX_COUNT_GROWTH
end

-- Public: the most spawns one generated slot may hold after substitution.
function EnemySanity.max_spawn_count(count, replacementId)
  local check = LocationManager.enemy_check_for_unit(replacementId)
  if check and ONE_FOR_ONE_CHECKS[check] then return count end
  return math.max(count, math.floor(count * max_count_growth() + 0.5))
end

local zone_health_factor -- defined below, next to the tier helpers scale_unit shares with it

function EnemySanity.rebalance_spawn_count(spawnData, originalId, replacementId, room)
  if type(spawnData) ~= "table" or not spawnData.Generated then return end
  local count = spawnData.TotalCount
  if type(count) ~= "number" or count < 1 then return end
  room = room or (game.CurrentRun and game.CurrentRun.CurrentRoom)
  local origRating = enemy_difficulty(originalId, room)
  local newRating = enemy_difficulty(replacementId, room)
  if not origRating or not newRating then return end

  local factor = 1
  local ok, value = pcall(function()
    local route, zoneIndex = Routes.for_room(room)
    return zone_health_factor(replacementId, originalId, route, zoneIndex)
  end)
  if ok and type(value) == "number" and value > 0 then factor = value end
  newRating = newRating * factor

  local scaled = math.floor(((count * origRating) / newRating) + 0.5)
  if scaled < 1 then scaled = 1 end -- the generator guarantees at least one of each type; match it
  local ceiling = EnemySanity.max_spawn_count(count, replacementId)
  if scaled > ceiling then scaled = ceiling end
  local gd = EnemyData[replacementId] and EnemyData[replacementId].GeneratorData
  if gd and type(gd.MaxCount) == "number" and scaled > gd.MaxCount then scaled = gd.MaxCount end

  -- GeneratorData on the entry still points at the ORIGINAL unit's table (FillEnemyTypes cached
  -- it there at generation time). Now that .Name is the replacement, anything reading it back
  -- should see the replacement's -- keep the two consistent.
  if gd then spawnData.GeneratorData = gd end
  if scaled ~= count then
    rom.log.info("[AP] enemysanity: count " .. tostring(originalId) .. " x" .. count .. " -> "
      .. tostring(replacementId) .. " x" .. scaled
      .. " (rating " .. string.format("%.0f", origRating) .. " -> " .. string.format("%.0f", newRating)
      .. ", zone health x" .. string.format("%.3f", factor) .. ")")
    spawnData.TotalCount = scaled
  end
end

-- The DESTINATION zone's tier out of a unit's DreamBiomeData, falling back to the deepest tier
-- the unit actually defines. Vanilla's own tables stop at tier 4 (confirmed by grepping the
-- whole of Content/Scripts/EnemyData.lua; DreamDiveTweaks extends many of them to 12), but a
-- Dream Dive seed can be configured with more regions than a unit has tiers, and
-- Routes.dream_current()'s zoneIndex is the real region-slot counter with no cap -- without the
-- fallback, a substituted enemy that deep gets no scaling at all rather than the closest
-- available (reported as substituted enemies keeping their origin-zone stats deep into a dive).
local function deepest_tier(dreamBiomeData, zoneIndex)
  local d = dreamBiomeData[zoneIndex]
  if d then return d end
  local maxTier = 0
  for tier in pairs(dreamBiomeData) do
    if type(tier) == "number" and tier > maxTier then maxTier = tier end
  end
  if maxTier == 0 then return nil end
  return dreamBiomeData[maxTier]
end

-- On a REAL Dream Dive run (game.CurrentRun.IsDreamRun), the game's own native code already
-- runs this exact DataOverrides/AddOutgoingDamageModifier block itself (RoomLogic.lua:3294-3308
-- inside SetupUnit), keyed by CurrentRun.EnteredBiomes -- the very number Routes.dream_current()
-- hands back as zoneIndex. OverwriteTableKeys-based DataOverrides are idempotent (same values,
-- harmless to reapply), but AddOutgoingDamageModifier is `table.insert`-additive
-- (CombatLogic.lua:169, confirmed STACKING, not an overwrite), so re-running it double-counts
-- that half and the unit hits harder than its tier implies. Native's gate is unconditional on
-- depth, so the only case it leaves undone is a tier its own lookup finds nil -- which is
-- exactly what this tests, rather than comparing against GameData.FullRunBiomeCount (that used
-- to read 4, but DreamDiveTweaks overwrites it with the configured region count, so the old
-- comparison no longer meant what the code assumed).
local function already_natively_scaled(dreamBiomeData, zoneIndex)
  local run = game.CurrentRun
  return (run and run.IsDreamRun and dreamBiomeData[zoneIndex] ~= nil) == true
end

-- Public: apply the destination zone's Dream Dive balance data to a unit EnemySanity actually
-- SUBSTITUTED in (flagged via SpawnOverrides at the StartEncounter substitution site, which
-- HandleNextSpawn copies onto the live unit -- see reload.lua).
-- The AP_EnemySanitySubstituted gate is the whole point and used to be missing: SetupUnit fires
-- for EVERY enemy the game spawns, so with substitution on this ran against natively-placed
-- enemies standing in their OWN home zone too. DreamBiomeData isn't a "make this fit zone N"
-- no-op at the enemy's native tier -- it's absolute Dream Dive tuning (BaseFEnemy tier 1 =
-- 1.25x health / 1.4x outgoing damage, BaseHEnemy tier 3 = 1.5x/1.5x, BaseIEnemy tier 4 =
-- 1.5x/1.35x), so every ordinary Underworld enemy in the game was silently buffed and every
-- Surface one nerfed the moment enemysanity left a vanilla mode. That difficulty distortion had
-- nothing to do with substitution and is the most likely source of "shuffled runs feel wrong".
-- 8/16: the absolute application described above is now taken RELATIVE, which is what makes it a
-- true no-op for an enemy standing in its own home zone (1.25/1.25 = 1.0) while still expressing
-- the full move for one that isn't. 9/26: the divisor is the destination zone's natives, not the
-- substitute's home tier -- see native_tier.
-- A multiplier the tier leaves blank means 1.0, not "no data". Vanilla comments the value out at
-- the tier where an archetype sits at its natural strength -- BasePEnemy tier 3 has
-- "--HealthMultiplier = 1" and "--PlayerMultiplier = 1", BaseQEnemy tier 4 the same. Reading
-- those as nil made scale_unit skip the stat entirely, so every Olympus and Summit enemy kept its
-- full health and damage wherever it was shuffled to (9/26, live: Mati, a Summit enemy, at its
-- full 1510 HP in the second room of Erebus).
local function tier_values(entry)
  if type(entry) ~= "table" then return nil, nil end
  local health = entry.DataOverrides and entry.DataOverrides.HealthMultiplier or 1
  local damage = entry.AddOutgoingDamageModifier and entry.AddOutgoingDamageModifier.PlayerMultiplier or 1
  return health, damage
end

-- The Dream table of the enemies that natively live in this zone, at this zone's own slot -- what
-- a substituted enemy's Dream value is divided by. 9/26: this used to divide by the SUBSTITUTE's
-- table at its own home tier instead, which only matches when both tiers carry the same Dream
-- baseline. The baseline is not flat -- 1.25 for the Underworld's first two zones, 1.5 for its last
-- two, 0.83 then 1.0 on the Surface, 1.15/1.1/1.3/1.35 in Zagreus' Journey -- so most cross-band
-- moves came out up to ~1.8x off. Dividing by the destination's natives is the comparison Dream
-- Dive itself makes: at any one slot, every archetype's table is tuned to the same difficulty.
-- Underworld and Surface zones read their Base<X>Enemy archetype. Zagreus' Journey hangs its
-- tables on each unit rather than an archetype, so Nightmare zones read the table of the enemy the
-- substitute replaced, which the game put there as a native of this zone. Dream regions return nil
-- (divide by 1): the Dream route uses PURE Dream stats (user ruling 9/26), the same values every
-- native enemy in the dive carries.
local function native_tier(route, zoneIndex, originalId)
  if route == "Dream" then return nil end
  local letters = ROUTE_BIOME_LETTERS[route]
  if letters and letters[zoneIndex] and EnemyData then
    local archetype = EnemyData["Base" .. letters[zoneIndex] .. "Enemy"]
    if archetype and archetype.DreamBiomeData then return archetype.DreamBiomeData[zoneIndex] end
  end
  local original = type(originalId) == "string" and EnemyData and EnemyData[originalId]
  if original and original.DreamBiomeData then return original.DreamBiomeData[zoneIndex] end
  return nil
end

-- The health multiplier a replacement is about to carry in this zone, against the enemy it
-- replaces -- the same division scale_unit makes for a live unit, taken from EnemyData so it can be
-- asked while the wave is still being sized (rebalance_spawn_count). On a dive both enemies carry
-- their own table's value for the region, so it is the ratio of the two. 1 whenever scale_unit
-- would leave the replacement alone.
zone_health_factor = function(replacementId, originalId, route, zoneIndex)
  if not route or type(zoneIndex) ~= "number" or zoneIndex < 1 or EnemyData == nil then return 1 end
  local data = EnemyData[replacementId] and EnemyData[replacementId].DreamBiomeData
  if type(data) ~= "table" then return 1 end
  local dest = deepest_tier(data, zoneIndex)
  if not dest then return 1 end
  local destHealth = tier_values(dest)
  local nativeHealth = 1
  if route == "Dream" then
    local origData = EnemyData[originalId] and EnemyData[originalId].DreamBiomeData
    if type(origData) == "table" and origData[zoneIndex] then nativeHealth = tier_values(origData[zoneIndex]) end
  else
    local native = native_tier(route, zoneIndex, originalId)
    if native then nativeHealth = tier_values(native) end
  end
  if type(destHealth) ~= "number" or type(nativeHealth) ~= "number" then return 1 end
  if destHealth <= 0 or nativeHealth <= 0 then return 1 end
  return destHealth / nativeHealth
end

-- A replacement's RequiredSpawnPoint is a fact about its HOME maps (Oceanus enemies surface from
-- its EnemyPointMelee/EnemyPointRanged water points), not about the room it lands in. 11/3, live
-- (0.10.0, pure_random, ZJ Tartarus): a Turtle_Elite in place of a PunchingBagUnitElite found no
-- usable point even after reload.lua's retry -- "encounter may stall" -- and the room sat at "foes
-- nearby" with nothing alive. The map had points of that type, so the 9/26 relax (which only acts
-- when it has none) never fired, and the retry can't help: HandleNextSpawn's ignoreSpawnPreferences
-- only clears PreferredSpawnPoint, after the point is already chosen. Vanilla's own cross-biome
-- swap settles it the same way: HandleNextSpawn's Vow of Menace branch sets every swapped spawn's
-- RequiredSpawnPoint to its SwapMap entry or "nil". So a substitute keeps a requirement only when
-- the enemy it replaces had the same one -- that enemy was spawning fine on this map -- and
-- otherwise falls back to its PreferredSpawnPoint, then any point. An override the encounter
-- authored on the slot itself is left alone.
local function substitute_spawn_point(spawnData, originalId)
  if spawnData.SpawnOverrides.RequiredSpawnPoint ~= nil or EnemyData == nil then return end
  local replacement = EnemyData[spawnData.Name]
  local required = replacement and replacement.RequiredSpawnPoint
  if type(required) ~= "string" or required == "nil" then return end
  local original = type(originalId) == "string" and EnemyData[originalId]
  if original and original.RequiredSpawnPoint == required then return end
  spawnData.SpawnOverrides.RequiredSpawnPoint = "nil" -- OverwriteTableKeys' literal for "clear"
end

-- Public: flag a spawn entry as substituted so scale_unit can find it on the live unit.
-- HandleNextSpawn copies SpawnOverrides onto the enemy it builds; the original id is what
-- native_tier falls back to in Zagreus' Journey zones. Call it after spawnData.Name is the
-- replacement.
function EnemySanity.mark_substituted(spawnData, originalId)
  spawnData._ap_substituted = true
  spawnData.SpawnOverrides = spawnData.SpawnOverrides or {}
  spawnData.SpawnOverrides.AP_EnemySanitySubstituted = true
  spawnData.SpawnOverrides.AP_EnemySanityOriginal = originalId
  substitute_spawn_point(spawnData, originalId)
end

-- Why a unit spawning now needs scaling, or nil when it doesn't. Two things put an enemy outside
-- its home zone: enemy substitution (flagged per spawn), and the miniboss ROOM shuffle, which
-- drops a whole foreign arena into the run -- its miniboss, its adds, and anything the miniboss
-- summons. 9/26, live: I_MiniBoss01 (The Verminancer, Tartarus) hosted in Erebus spawned at full
-- Tartarus strength, because only substituted spawns were ever scaled. Every enemy in a swapped
-- room qualifies; the ratio below comes out 1.0 for any that already belong to the host zone. Not
-- gated on substitution_on(): the room shuffle also runs under vanilla_plus_locations, where no
-- enemy is substituted.
local function scaling_reason(unit)
  if unit.AP_EnemySanitySubstituted and EnemySanity.substitution_on() then return "substituted" end
  local room = game.CurrentRun and game.CurrentRun.CurrentRoom
  if room and room.AP_MinibossRoomOrigin then return "miniboss room", room end
  return nil
end

-- For a unit in a swapped miniboss room: how far its own Dream table sits from its home zone's
-- regular enemies AT HOME, as (health, damage) factors that cancel that offset. The host-zone ratio
-- in scale_unit assumes the unit rides its home archetype's curve, which holds for most minibosses
-- (The Verminancer inherits BaseIEnemy -> factors 1, 1). Charybdis' parts and the two Typhon arena
-- pieces carry their OWN tables instead, tuned off-curve: Charybdis at home is 1.36x health / 1.56x
-- damage against BaseOEnemy tier 2, the Typhon Tail and Eye 0.87x damage against BaseQEnemy tier 4.
-- Without this they'd be retuned even in their own zone. The home zone is the swapped room's own
-- biome (the room keeps its native Name; RoomSetName is rewritten to the host).
local function home_offset(unit, room)
  local letter = MinibossRooms and MinibossRooms.ROOM_BIOME[room.Name]
  local info = letter and Routes.ROOMSET[letter]
  if not info then return 1, 1 end
  local own = unit.DreamBiomeData[info[2]]
  local native = native_tier(info[1], info[2], nil)
  if not own or not native then return 1, 1 end
  local ownHealth, ownDamage = tier_values(own)
  local nativeHealth, nativeDamage = tier_values(native)
  if ownHealth <= 0 or ownDamage <= 0 then return 1, 1 end
  return nativeHealth / ownHealth, nativeDamage / ownDamage
end

-- Worked example, the 9/26 report: Mati (BaseQEnemy) in Erebus gets tier 1 of its own table
-- (0.125x health, 0.4x damage), divided by Erebus's own tier 1 (1.25x, 1.4x) -> 0.1x health
-- (1510 -> 151 HP) and 0.29x damage. Same for a Wastrel in Tartarus: 9/1.5 = 6x health.
function EnemySanity.scale_unit(unit)
  if not unit or not unit.DreamBiomeData then return end
  local reason, swappedRoom = scaling_reason(unit)
  if not reason then return end
  local route, zoneIndex = Routes.current()
  if not zoneIndex or zoneIndex < 1 then return end
  -- Dream route, region the unit's table covers (every region up to 12 once DreamDiveTweaks has
  -- extended the tables): the game's own SetupUnit block applies the pure Dream values to this unit
  -- right after we return. Log them so a dive's substitutions can be checked the same way.
  if already_natively_scaled(unit.DreamBiomeData, zoneIndex) then
    local health, damage = tier_values(unit.DreamBiomeData[zoneIndex])
    rom.log.info(string.format("[AP] enemysanity: %s in %s %d (%s) gets the game's own Dream stats: health x%.3f, damage x%.3f",
      tostring(unit.Name), tostring(route), zoneIndex, reason, health, damage))
    return
  end

  local dest = deepest_tier(unit.DreamBiomeData, zoneIndex)
  if not dest then return end
  local destHealth, destDamage = tier_values(dest)
  local nativeHealth, nativeDamage = 1, 1
  local native = native_tier(route, zoneIndex, unit.AP_EnemySanityOriginal)
  if native then nativeHealth, nativeDamage = tier_values(native) end
  if nativeHealth <= 0 or nativeDamage <= 0 then return end
  local healthRatio = destHealth / nativeHealth
  local damageRatio = destDamage / nativeDamage
  if swappedRoom then
    local healthOffset, damageOffset = home_offset(unit, swappedRoom)
    healthRatio = healthRatio * healthOffset
    damageRatio = damageRatio * damageOffset
  end

  -- Health rides on HealthMultiplier, a field the game reads when it finalises the unit -- so
  -- COMPOSE with whatever is already there (elite attributes set it too) rather than clobbering.
  if healthRatio ~= 1 then
    OverwriteTableKeys(unit, { HealthMultiplier = (unit.HealthMultiplier or 1) * healthRatio })
  end

  -- AddOutgoingDamageModifier is additive (table.insert), so this is applied once, as a single
  -- modifier carrying the ratio -- never the raw destination value, which would re-apply the
  -- Dream baseline the division just cancelled.
  if damageRatio ~= 1 then
    AddOutgoingDamageModifier(unit, { PlayerMultiplier = damageRatio })
  end

  if healthRatio ~= 1 or damageRatio ~= 1 then
    rom.log.info(string.format("[AP] enemysanity: scaled %s in %s %d (%s): health x%.3f, damage x%.3f",
      tostring(unit.Name), tostring(route), zoneIndex, reason, healthRatio, damageRatio))
  end

  -- SpeedMultiplier / MoneyMultiplier are deliberately left alone: speed is a feel change the
  -- tier curve applies as an absolute (1.2x at tier 3 regardless of origin) rather than a
  -- displacement, and money is economy tuning that has nothing to do with where the enemy came
  -- from. Only the two stats that make a substituted enemy the wrong difficulty are corrected.
end

-- (EnemySanity.scale_encounter removed, along with its reload.lua SetupEncounter wrap.) It
-- mirrored RunLogic.lua:1107's encounter-level Dream override the same way scale_unit mirrors
-- the per-unit one -- but substitution only ever swaps individual spawns, never the encounter
-- itself, so no encounter is ever "from another zone" and there was nothing for it to correct.
-- All it actually did was re-tune every encounter in the game (ActiveEnemyCap, spawn intervals,
-- and whatever else that zone's DreamBiomeData DataOverrides carry) to Dream Dive values
-- whenever enemysanity was in a substitution mode, with no way to tell substituted content
-- apart -- the encounter-level twin of the scale_unit bug documented above, and unfixable by
-- the same flag since encounters carry no substitution provenance.

-- ---------------------------------------------------------------------------------------------
-- Zagreus' Journey's own enemy hooks, off its own route
-- ---------------------------------------------------------------------------------------------
-- 10/7. ZJ gates its handling of its Hades I enemies on CurrentRun.ModsNikkelMHadesBiomesIsModdedRun
-- -- 149 reads across ~40 of its scripts -- and that flag is only true on a run through ZJ's own
-- biomes. The shuffle puts those enemies on every other route, where they ran with none of it.
-- First seen as the Brimstone + Freeze crash (reload.lua's RootApplyPresentation guard); the same
-- cause left them with no death animation (ManualDeathAnimation is set on all of them and only
-- ZJ's KillPresentation wrap plays it), a Brimstone's crystals hanging in the air after it died,
-- the Brimstone lock-on tick dealing real damage, and ZJ's own Chariot AI never running.
--
-- Most of those 149 reads are about the RUN (room rewards, stores, exits, music, dialogue) and
-- must keep reading false here. The ones that matter are the per-unit ones, and nearly all of
-- those ask both questions on one line: "ZJ run AND one of my units". So, for exactly those
-- wraps, answer the first half yes and let ZJ's own unit check decide. Its code runs unmodified
-- and nothing of it is copied here.
--
-- How: the flag is simply absent from CurrentRun on a non-ZJ run, so an __index on CurrentRun
-- sees every read of it and can tell who is asking -- debug.getinfo gives the reading chunk and
-- line. The lines that get a yes are found by reading ZJ's installed scripts (below), so a ZJ
-- update that moves them needs nothing from us. Deciding by reader rather than by "a ZJ enemy is
-- being handled right now" is what keeps it exact: a kill resumes the encounter thread inside
-- KillEnemy's own call stack, and that thread goes on to build the next rooms -- anything scoped
-- to the call would have had ZJ's run-level hooks firing in there.
--
-- Deliberately NOT included:
--   * SetupUnit. On a ZJ run it adds 32-45% health and 9-20% armor to these enemies (ZJ
--     Meta/Constants.lua) and applies their Vow upgrades. That is tuning, not breakage, and it
--     is added to HealthMultiplier AFTER scale_unit has multiplied it -- so switching it on as
--     is would add a flat +0.38 to a multiplier we had just scaled down to 0.1. Needs a ruling
--     and a composed formula first.
--   * NarrativeLogic.lua (which lines ZJ's NPCs say) and the Hades-boss-only wraps.
--   * EffectLogic.lua's hero poison-immunity pairing: it rewrites the caller's args table.
local ZJ_RUN_FLAG = "ModsNikkelMHadesBiomesIsModdedRun"

-- ZJ script -> the wraps in it whose run check is really a question about one unit (or one
-- projectile). Keyed by file as well as wrap: RoomPresentation_Late.lua has a CreateAnimation
-- wrap too, and that one is about exit doors.
local ZJ_UNIT_WRAPS = {
  ["CombatLogic.lua"]             = { KillEnemy = true, CleanupEnemy = true, CheckImpactReaction = true },
  ["CombatPresentation.lua"]      = { KillPresentation = true },
  ["EffectPresentation.lua"]      = { EffectApplyPresentation = true, RootApplyPresentation = true },
  ["EffectPresentation_Late.lua"] = { SetColor = true, SetThingProperty = true },
  ["EffectLogic_Late.lua"]        = { CreateAnimation = true },
  ["EnemyAILogic.lua"]            = { AIFireWeapon = true, AIFireProjectile = true },
  ["Chariot.lua"]                 = { RamAILoop = true },
  ["PowersLogic.lua"]             = { AttachCastAtLocation = true },
  ["RoomLogic.lua"]               = { DisableTrap = true },
}

-- chunk source -> { [line] = true } for the flag reads inside those wraps, or false for a chunk
-- that has none (every vanilla script, our own, every other ZJ script). ENVY loads a plugin's
-- files with loadfile(<plugin folder>/<file>), so the source is "@" plus a path we can open.
local _zj_gate_lines = {}

local function scan_zj_gate_lines(source)
  if type(source) ~= "string" or source:sub(1, 1) ~= "@" then return false end
  if not source:find(Routes.NIGHTMARE_MOD_NAME, 1, true) then return false end
  local wraps = ZJ_UNIT_WRAPS[source:match("([^/\\]+)$") or ""]
  if not wraps then return false end
  local file = io.open(source:sub(2), "r")
  if not file then
    -- Once per script (the result is cached). Without the file there is nothing to go on, and
    -- these enemies fall back to running with none of ZJ's handling.
    rom.log.warning("[AP] ZJ unit hooks: could not read " .. source:sub(2)
      .. " -- Hades I enemies on other routes will misbehave")
    return false
  end
  local lines, wrap, n, found = {}, nil, 0, 0
  for line in file:lines() do
    n = n + 1
    -- A wrap's name holds until its closing "end)" at column 0. Context wraps are skipped
    -- themselves (the wraps nested inside them are what read the flag).
    if line:find("^end%)") or line:find("^function ") or line:find("^local function ")
       or line:find("Context%.Wrap") then
      wrap = nil
    end
    wrap = line:match('Path%.Wrap%(%s*"([%w_]+)"') or wrap
    if wrap and wraps[wrap] and line:find(ZJ_RUN_FLAG, 1, true) then
      lines[n] = true
      found = found + 1
    end
  end
  file:close()
  rom.log.info(string.format("[AP] ZJ unit hooks: %s -> %d per-unit run check(s) answered off-route",
    source:match("([^/\\]+)$") or "?", found))
  return lines
end

local function zj_run_flag_index(_, key)
  if key ~= ZJ_RUN_FLAG then return nil end
  local info = debug.getinfo(2, "Sl")
  if not info then return nil end
  local lines = _zj_gate_lines[info.source]
  if lines == nil then
    local ok, scanned = pcall(scan_zj_gate_lines, info.source)
    lines = ok and scanned or false
    _zj_gate_lines[info.source] = lines
  end
  if lines and lines[info.currentline] then return true end
  return nil
end

local ZJ_RUN_META = { __index = zj_run_flag_index }
-- Every run table carrying the metatable, so it can be taken off again: a finished run moves
-- into GameState.RunHistory, and nothing with a metatable should be handed to the save.
local _zj_meta_runs = setmetatable({}, { __mode = "k" })

function EnemySanity.zj_unit_hooks_detach()
  for run in pairs(_zj_meta_runs) do
    if getmetatable(run) == ZJ_RUN_META then setmetatable(run, nil) end
    _zj_meta_runs[run] = nil
  end
end

-- Public: make sure the live run answers ZJ's per-unit hooks. Cheap and idempotent -- called on
-- every room load and every unit setup, because CurrentRun is a new plain table after StartNewRun
-- and after every save load. Leaves a real ZJ run alone (the flag is a true field there and
-- __index never fires), and leaves the run alone entirely when ZJ isn't installed.
function EnemySanity.zj_unit_hooks_attach(run)
  if type(run) ~= "table" then return end
  if getmetatable(run) ~= ZJ_RUN_META then
    if getmetatable(run) ~= nil then return end -- someone else's metatable: not ours to replace
    if type(debug) ~= "table" or type(debug.getinfo) ~= "function" then return end
    if not ItemManager.nightmare_mod() then return end
    EnemySanity.zj_unit_hooks_detach()
    setmetatable(run, ZJ_RUN_META)
    _zj_meta_runs[run] = true
  end
  -- ZJ writes an explicit false when a Dream Dive moves from one of its biomes into a vanilla one
  -- (its RunLogic.lua ChooseStartingRoom wrap), and zerp-NPCRoomRandomizer writes one at room
  -- transitions on every route. __index only fires for an ABSENT key, and every reader of this
  -- flag across the installed mods treats false and absent alike (checked: no ==/~= compares, no
  -- rawget), so absent it is. This is why attach is called from the spawn and death paths too.
  if rawget(run, ZJ_RUN_FLAG) == false then rawset(run, ZJ_RUN_FLAG, nil) end
end

-- Sound. ZJ loads its enemy sound banks from its AudioStateInit wrap, on a ZJ run in a ZJ biome
-- only, so off-route every one of these enemies was silent -- the 10/7 log is 250-odd "Failed
-- playing event:/SFX/Enemy Sounds/Exalted/..." warnings from one Ephyra room. Same two banks
-- every ZJ room lists first in LoadModdedAudioBanks (its RoomData*.lua); the music and ambience
-- banks in that list are the room's, not the enemy's. Once per room: ZJ itself reloads them on
-- every map load.
local ZJ_ENEMY_AUDIO_BANKS = { "EnemiesModsNikkelMHadesBiomes", "SoundsModsNikkelMHadesBiomes" }
local _zj_audio_room = nil

function EnemySanity.load_zj_enemy_audio()
  local room = game.CurrentRun and game.CurrentRun.CurrentRoom
  if room ~= nil and room == _zj_audio_room then return end
  if not (rom.audio and rom.audio.load_bank and ItemManager.nightmare_mod()) then return end
  local own = _PLUGIN and _PLUGIN.plugins_data_mod_folder_path
  if type(own) ~= "string" then return end
  local folder = rom.path.combine(rom.path.get_parent(own), Routes.NIGHTMARE_MOD_NAME)
  for _, bank in ipairs(ZJ_ENEMY_AUDIO_BANKS) do
    pcall(rom.audio.load_bank, rom.path.combine(folder, "Content\\Audio\\Desktop\\" .. bank .. ".bank"))
  end
  _zj_audio_room = room
end

-- The same gap the other way round (11/6, from the 0.10.0 logs): a Hades II enemy away from its
-- home biome. The game loads one biome's sound bank (Content/Audio/Desktop/Biome<X>.bank) for the
-- biome you're in, so a substitute from another biome was silent -- Brice13's 10/12 log has
-- "Failed playing event:/SFX/Enemy Sounds/GuardSwipe" for a Guard_Elite in a Dream region, and
-- Satyr Ratcatchers in Hades I rooms fail the same way. Matched against the banks themselves (each
-- failing event's GUID from Content/Audio/GUIDs.txt, found in the bank files): GuardSwipe is in
-- BiomeF/G/O, SatyrRatcatcher/* in BiomeH/I -- each unit's home biome. ZJ does this for Charon's
-- fight (its RoomData.lua CharonFight01 LoadVanillaAudioBanks = { "BiomeG" }), and reloads banks on
-- every map load, so loading one that's already resident is harmless. Once per room per bank; the
-- room's own biome is skipped.
local _h2_audio_room, _h2_audio_banks = nil, {}

function EnemySanity.load_h2_enemy_audio(id)
  local bank = EnemySanity.biome_package_for_unit(id)
  if type(bank) ~= "string" then return end
  if not (rom.audio and rom.audio.load_bank and rom.paths and rom.paths.Content) then return end
  local room = game.CurrentRun and game.CurrentRun.CurrentRoom
  if room ~= _h2_audio_room then _h2_audio_room, _h2_audio_banks = room, {} end
  if _h2_audio_banks[bank] then return end
  _h2_audio_banks[bank] = true
  local roomSet = room and room.RoomSetName
  if type(roomSet) == "string" and "Biome" .. roomSet == bank then return end
  local ok = pcall(rom.audio.load_bank, rom.path.combine(rom.paths.Content(), "Audio\\Desktop\\" .. bank .. ".bank"))
  if ok then rom.log.info("[AP] enemysanity: loaded " .. bank .. ".bank for a substituted " .. tostring(id)) end
end
