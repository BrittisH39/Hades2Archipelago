---@diagnostic disable: lowercase-global
-- ItemManager.lua — applies items received from Archipelago and stores the
-- slot settings sent by the client.

ItemManager = ItemManager or {}
ItemManager.settings = ItemManager.settings or {}
-- The count of received items already applied lives in APState (the game save),
-- so re-receiving the full ITEMS list never double-grants consumable currencies.

-- Filler items (low-value): the meta currencies plus the start-boost / rarity / major-finds
-- fillers. Mirrors Python's item_table_filler + item_table_progressive_filler + the unuseful
-- entries of item_table_extras (Rarity Increase, Increased Odds of Major Finds). Receipts
-- of these go to the subtle corner log instead of the big banner (see Notifications.push).
local FILLER_NAMES = {
  ["Ashes"] = true, ["Psyche"] = true, ["Bones"] = true, ["Nectar"] = true,
  ["Moon Dust"] = true,
  ["Rarity Increase"] = true, ["Increased Help Odds"] = true,
  ["Increased Odds of Major Finds"] = true,
  ["Starting Max Health"] = true, ["Starting Max Magick"] = true,
  ["Starting Gold"] = true, ["Starting Armor"] = true,
}

-- Is `name` a filler item? Used to pick the notification tier.
function ItemManager.is_filler(name)
  return FILLER_NAMES[name] == true
end

-- The strings below are DATA values confirmed against the installed game's
-- Content/Scripts (WeaponSets.lua, CombatLogic.lua, ResourceData.lua, and the
-- HelpText localization). Note the resource keys are deliberately surprising.

-- Map a weapon-unlock item name to its in-game weapon kit id (the key used in
-- GameState.WeaponsUnlocked and CurrentRun.Hero.Weapons).
local WEAPON_ITEM_TO_ID = {
  ["Staff Weapon Unlock Item"]  = "WeaponStaffSwing", -- Witch's Staff (starter; kit id confirmed from WeaponShopData)
  ["Blades Weapon Unlock Item"] = "WeaponDagger",  -- Sister Blades
  ["Flames Weapon Unlock Item"] = "WeaponTorch",   -- Umbral Flames
  ["Axe Weapon Unlock Item"]    = "WeaponAxe",     -- Moonstone Axe
  ["Skull Weapon Unlock Item"]  = "WeaponLob",     -- Argent Skull
  ["Coat Weapon Unlock Item"]   = "WeaponSuit",    -- Black Coat
}

-- initial_weapon option value (0-5; see Python's InitialWeapon Choice) -> weapon kit id.
-- The chosen starting weapon is left OUT of the AP item pool, so the mod must unlock it
-- itself or a non-Staff roll is unobtainable (only the Staff is unlocked by default).
local INITIAL_WEAPON_TO_KIT = {
  [0] = "WeaponStaffSwing", -- Witch's Staff
  [1] = "WeaponDagger",     -- Sister Blades
  [2] = "WeaponTorch",      -- Umbral Flames
  [3] = "WeaponAxe",        -- Moonstone Axe
  [4] = "WeaponLob",        -- Argent Skull
  [5] = "WeaponSuit",       -- Black Coat
}

-- Weapon kit id -> the short name used as a per_weapon_room_based location suffix
-- (must match Python's WEAPON_SHORT_NAMES).
ItemManager.WEAPON_KIT_TO_SHORT = {
  WeaponStaffSwing = "Staff",
  WeaponDagger = "Blades",
  WeaponTorch  = "Flames",
  WeaponAxe    = "Axe",
  WeaponLob    = "Skull",
  WeaponSuit   = "Coat",
}
-- Inverse: weapon short-name -> kit id (for the combined "Progressive <Weapon>" item).
ItemManager.SHORT_TO_WEAPON_KIT = {}
for kit, short in pairs(ItemManager.WEAPON_KIT_TO_SHORT) do
  ItemManager.SHORT_TO_WEAPON_KIT[short] = kit
end

-- The short name of the weapon equipped in the current run (per_weapon_room_based), or nil.
function ItemManager.current_weapon_short()
  local kit = nil
  pcall(function()
    if game.GetEquippedWeapon then kit = game.GetEquippedWeapon() end
  end)
  if not kit and game.GameState then kit = game.GameState.PrimaryWeaponName end
  local short = kit and ItemManager.WEAPON_KIT_TO_SHORT[kit] or nil
  if kit and not short then
    -- Unmapped kit id: per_weapon room checks would silently drop, so make it loud.
    rom.log.warning("[AP] current_weapon_short: unmapped weapon kit '" .. tostring(kit)
      .. "' - per-weapon room checks can't fire until it's added to WEAPON_KIT_TO_SHORT")
  end
  return short
end

-- Map our filler item names to the game's resource keys. The internal names do
-- NOT match the display names (confirmed via HelpText.en.sjson):
--   Bones=MetaCurrency, Ashes=MetaCardPointsCommon, Psyche=MemPointsCommon, Nectar=GiftPoints
local RESOURCE_KEYS = {
  Ashes  = "MetaCardPointsCommon",
  Psyche = "MemPointsCommon",
  Bones  = "MetaCurrency",
  Nectar = "GiftPoints",
  ["Moon Dust"] = "CardUpgradePoints",  -- Arcana upgrade currency
}

-- Arcana item title -> internal MetaUpgrade (card) id. Item names are
-- "<Title> Arcana"; we strip the suffix and look up here.
local ARCANA_TITLE_TO_ID = {
  ["The Sorceress"]   = "ChanneledCast",
  ["Wayward Son"]     = "HealthRegen",
  ["Huntress"]        = "LowManaDamageBonus",
  ["Eternity"]        = "CastCount",
  ["Moon"]            = "SorceryRegenUpgrade",
  ["Furies"]          = "CastBuff",
  ["Persistence"]     = "BonusHealth",
  ["Messenger"]       = "BonusDodge",
  ["Unseen"]          = "ManaOverTime",
  ["Night"]           = "MagicCrit",
  ["Swift Runner"]    = "SprintShield",
  ["Death"]           = "LastStand",
  ["Centaur"]         = "MaxHealthPerRoom",
  ["Origination"]     = "StatusVulnerability",
  ["Lovers"]          = "ChanneledBlock",
  ["The Enchantress"] = "DoorReroll",
  ["Boatman"]         = "StartingGold",
  ["Artificer"]       = "MetaToRunUpgrade",
  ["Excellence"]      = "RarityBoost",
  ["Queen"]           = "BonusRarity",
  ["The Fates"]       = "TradeOff",
  ["Champions"]       = "ScreenReroll",
  ["Strength"]        = "LowHealthBonus",
  ["Divinity"]        = "EpicRarityBoost",
  ["Judgment"]        = "CardDraw",
}

-- Vow item name -> internal ShrineUpgrade id (stored in GameState.ShrineUpgrades).
-- "shadow"->MinibossCount is the least certain; verify in-game.
local VOW_NAME_TO_ID = {
  Pain    = "EnemyDamageShrineUpgrade",
  Grit    = "EnemyHealthShrineUpgrade",
  Wards   = "EnemyShieldShrineUpgrade",
  Frenzy  = "EnemySpeedShrineUpgrade",
  Hordes  = "EnemyCountShrineUpgrade",
  Menace  = "NextBiomeEnemyShrineUpgrade",
  Return  = "EnemyRespawnShrineUpgrade",
  Fangs   = "EnemyEliteShrineUpgrade",
  Scars   = "HealingReductionShrineUpgrade",
  Debt    = "ShopPricesShrineUpgrade",
  Shadow  = "MinibossCountShrineUpgrade",
  Forfeit = "BoonSkipShrineUpgrade",
  Time    = "BiomeSpeedShrineUpgrade",
  Void    = "LimitGraspShrineUpgrade",
  Hubris  = "BoonManaReserveShrineUpgrade",
  Denial  = "BanUnpickedBoonsShrineUpgrade",
  Rivals  = "BossDifficultyShrineUpgrade",
}

-- Aspect item (display title) -> internal aspect id. Aspects unlock through the
-- world-upgrade system (GameState.WorldUpgradesAdded), same as incantations, so the
-- grant reuses force_world_upgrade(). The 6 default "Aspect of Melinoe" stay unlocked
-- and are never items, so they are absent here.
local ASPECT_ITEM_TO_ID = {
  ["Aspect of Circe"]        = "StaffClearCastAspect",
  ["Aspect of Momus"]        = "StaffSelfHitAspect",
  ["Aspect of Anubis"]       = "StaffRaiseDeadAspect",
  ["Aspect of Pan"]          = "DaggerHomingThrowAspect",
  ["Aspect of Artemis"]      = "DaggerBlockAspect",
  ["Aspect of the Morrigan"] = "DaggerTripleAspect",
  ["Aspect of Medea"]        = "LobCloseAttackAspect",
  ["Aspect of Persephone"]   = "LobImpulseAspect",
  ["Aspect of Hel"]          = "LobGunAspect",
  ["Aspect of Eos"]          = "TorchSprintRecallAspect",
  ["Aspect of Moros"]        = "TorchDetonateAspect",
  ["Aspect of Supay"]        = "TorchAutofireAspect",
  ["Aspect of Charon"]       = "AxeArmCastAspect",
  ["Aspect of Thanatos"]     = "AxePerfectCriticalAspect",
  ["Aspect of Nergal"]       = "AxeRallyAspect",
  ["Aspect of Nyx"]          = "SuitMarkCritAspect",
  ["Aspect of Selene"]       = "SuitHexAspect",
  ["Aspect of Shiva"]        = "SuitComboAspect",
}

-- Weapon short-name -> its 3 non-default aspect ids, for progressive aspect mode
-- ("Progressive <Weapon> Aspect" unlocks/upgrades these together).
local ASPECTS_BY_WEAPON = {
  Staff  = { "StaffClearCastAspect", "StaffSelfHitAspect", "StaffRaiseDeadAspect" },
  Blades = { "DaggerHomingThrowAspect", "DaggerBlockAspect", "DaggerTripleAspect" },
  Skull  = { "LobCloseAttackAspect", "LobImpulseAspect", "LobGunAspect" },
  Flames = { "TorchSprintRecallAspect", "TorchDetonateAspect", "TorchAutofireAspect" },
  Axe    = { "AxeArmCastAspect", "AxePerfectCriticalAspect", "AxeRallyAspect" },
  Coat   = { "SuitMarkCritAspect", "SuitHexAspect", "SuitComboAspect" },
}
-- Aspect internal id -> weapon short-name (reverse of ASPECTS_BY_WEAPON), and Aspect display
-- title -> weapon short-name. Used by the randomized-mode cascade below (the first Aspect
-- item you get for a weapon also unlocks it).
local ASPECT_ID_TO_WEAPON = {}
for weapon, ids in pairs(ASPECTS_BY_WEAPON) do
  for _, internal in ipairs(ids) do ASPECT_ID_TO_WEAPON[internal] = weapon end
end
local ASPECT_TITLE_TO_WEAPON = {}
for title, internal in pairs(ASPECT_ITEM_TO_ID) do
  ASPECT_TITLE_TO_WEAPON[title] = ASPECT_ID_TO_WEAPON[internal]
end

-- Weapon short-name -> its DEFAULT "Aspect of Melinoe" id (vanilla's free aspect -- still free in
-- every mode except randomized, see ASPECT_BASE_ITEM_TO_ID below -- and the first
-- WeaponUpgradeData.DisplayOrder entry). These are NOT all "Base*": only Staff/Coat
-- use Base*; the others are named after a signature trait (verified in WeaponUpgradeData.lua
-- FreeUnlocks). Progressive/combine modes rank this default up alongside the 3 non-default
-- aspects, so an always-equipped Aspect of Melinoe actually levels (it has <id>2..5 upgrade
-- entries in WeaponShopData with TraitUpgrade=<id>, identical to the others).
local ASPECT_BASE_BY_WEAPON = {
  Staff  = "BaseStaffAspect",
  Blades = "DaggerBackstabAspect",
  Skull  = "LobAmmoBoostAspect",
  Flames = "TorchSpecialDurationAspect",
  Axe    = "AxeRecoveryAspect",
  Coat   = "BaseSuitAspect",
}

-- randomized mode (aspectsanity=1) ALSO shuffles the 6 default Aspects of Melinoe: weapons don't
-- come with theirs for free there (apply_aspect_base_lock takes it away; the item gives it back).
-- All six share the in-game title "Aspect of Melinoe", so the item name is qualified by weapon --
-- must match Python's Items.aspect_base_titles. Kept SEPARATE from ASPECT_ITEM_TO_ID because that
-- table also feeds PER_ASPECT_ITEM ("Progressive <title>"), where the 6 defaults have their own
-- distinct item names ("Progressive <Weapon> Base Aspect").
local ASPECT_BASE_ITEM_TO_ID = {}
local ASPECT_BASE_TITLE_TO_WEAPON = {}
for weapon, base_id in pairs(ASPECT_BASE_BY_WEAPON) do
  local title = "Aspect of Melinoe (" .. weapon .. ")"
  ASPECT_BASE_ITEM_TO_ID[title] = base_id
  ASPECT_BASE_TITLE_TO_WEAPON[title] = weapon
end

local ASPECT_MAX_RANK = 5  -- rank 1 (base) + 4 upgrades (<aspect>2..<aspect>5)

-- Weapon-shop purchase names to block (so aspects come only from AP items). The
-- base unlock names are blocked whenever aspectsanity is on; the upgrade names
-- (<aspect>2..5) are blocked in every mode but "unlocked". Exposed for reload.lua.
ItemManager.ASPECT_UNLOCK_NAMES = {}
ItemManager.ASPECT_UPGRADE_NAMES = {}
for _, internal in pairs(ASPECT_ITEM_TO_ID) do
  ItemManager.ASPECT_UNLOCK_NAMES[internal] = true
  for rank = 2, ASPECT_MAX_RANK do
    ItemManager.ASPECT_UPGRADE_NAMES[internal .. rank] = true
  end
end
-- The default Aspect of Melinoe's own unlock isn't a shop purchase at all (it's a FreeUnlock --
-- randomized locks it via apply_aspect_base_lock instead), but its RANK comes from AP in every
-- non-"unlocked" mode, so block its shop upgrades (<base>2..5) like the other aspects.
for _, base in pairs(ASPECT_BASE_BY_WEAPON) do
  for rank = 2, ASPECT_MAX_RANK do
    ItemManager.ASPECT_UPGRADE_NAMES[base .. rank] = true
  end
end

-- per_aspect mode (aspectsanity=3): every one of a weapon's 4 Aspects (its default Aspect of
-- Melinoe + its 3 alternates) is its own 5-copy progressive item ("Progressive Aspect of
-- <Name>" for the 18 alternates, "Progressive <Weapon> Base Aspect" for the 6 defaults).
-- Item display name -> { weapon = short-name, id = internal aspect id, is_base = bool }.
local PER_ASPECT_ITEM = {}
for weapon, base_id in pairs(ASPECT_BASE_BY_WEAPON) do
  PER_ASPECT_ITEM["Progressive " .. weapon .. " Base Aspect"] = { weapon = weapon, id = base_id, is_base = true }
end
do
  local aspect_id_to_weapon = {}
  for weapon, ids in pairs(ASPECTS_BY_WEAPON) do
    for _, internal in ipairs(ids) do aspect_id_to_weapon[internal] = weapon end
  end
  for title, internal in pairs(ASPECT_ITEM_TO_ID) do
    local weapon = aspect_id_to_weapon[internal]
    if weapon then
      PER_ASPECT_ITEM["Progressive " .. title] = { weapon = weapon, id = internal, is_base = false }
    end
  end
end

-- Familiar item (display name) -> internal FamiliarsUnlocked key. Familiars unlock
-- via GameState.FamiliarsUnlocked[name] (FamiliarRecruitPresentation), NOT the bond
-- shop (which only handles GameState.FamiliarUpgrades).
local FAMILIAR_ITEM_TO_ID = {
  ["Frinos"] = "FrogFamiliar",
  ["Toula"]  = "CatFamiliar",
  ["Raki"]   = "RavenFamiliar",
  ["Hecuba"] = "HoundFamiliar",
  ["Gale"]   = "PolecatFamiliar",
}
-- All familiar unlock keys (for petsanity=unlocked and the recruit block).
ItemManager.FAMILIAR_NAMES = { "FrogFamiliar", "CatFamiliar", "RavenFamiliar", "HoundFamiliar", "PolecatFamiliar" }

-- Helper Room Sanity: "<NPC> Room" item (display name) -> bare NPC cast name (matches
-- LocationManager.NPC_CAST / the UNIT_TO_NPC_CHECK parse in LocationManager.on_npc_interacted,
-- which derives the same bare name from unit.Name via "^NPC_(%a+)"). Exported on ItemManager
-- (not local) so reload.lua's UseNPC wrap can gate on it directly, same convention as
-- ItemManager.FAMILIAR_NAMES above.
local HELPER_NPC_ITEM_TO_ID = {
  ["Arachne Room"]   = "Arachne",
  ["Narcissus Room"] = "Narcissus",
  ["Echo Room"]      = "Echo",
  ["Hades Room"]     = "Hades",
  ["Medea Room"]     = "Medea",
  ["Circe Room"]     = "Circe",
  ["Dionysus Room"]  = "Dionysus",
  ["Sisyphus Room"]  = "Sisyphus",
  ["Eurydice Room"]  = "Eurydice",
  ["Patroclus Room"] = "Patroclus",
}
ItemManager.HELPER_NPC_NAME_SET = {}
for _, npc in pairs(HELPER_NPC_ITEM_TO_ID) do ItemManager.HELPER_NPC_NAME_SET[npc] = true end

-- Story-room key (RoomData name, e.g. "G_Story01") -> bare NPC cast name. Covers every room
-- zerp-NPCRoomRandomizer treats as a swappable story-room identity (its own `storyRooms` list,
-- ready.lua), including H_Bridge01/Echo -- that mod DOES let Echo be swapped into/out of other
-- doors despite her room being a mandatory bridge crossing structurally. Used by both the
-- eligibility gate (resolve_eligibility_tables/eligibility_override below, which deliberately
-- excludes H_Bridge01's OWN native eligibility -- can't hide a mandatory crossing) and the
-- SelectRandomStoryRoom candidate filter (reload.lua).
ItemManager.STORY_ROOM_TO_NPC = {
  F_Story01 = "Arachne", G_Story01 = "Narcissus", H_Bridge01 = "Echo",
  I_Story01 = "Hades",   N_Story01 = "Medea",      O_Story01  = "Circe", P_Story01 = "Dionysus",
  A_Story01 = "Sisyphus", X_Story01 = "Eurydice",  Y_Story01  = "Patroclus",
}

-- Combat Helper Sanity: "<NPC> Helper" item (display name) -> bare NPC cast name. Gates
-- ItemManager.combat_helper_eligible, checked by the Handle<God>Spawn wraps (reload.lua)
-- before letting a combat-assist encounter actually spawn its NPC. Nemesis is included
-- (her item still gates her own combat encounter) even though her Met/Keepsake LOCATION is
-- never rule-gated on it AP-side (Routes.COMBAT_HELPER_NPCS excludes her -- she's
-- KEEPSAKE_FREE, met at the Crossroads from the start regardless).
local COMBAT_HELPER_ITEM_TO_ID = {
  ["Artemis Helper"]  = "Artemis",
  ["Nemesis Helper"]  = "Nemesis",
  ["Heracles Helper"] = "Heracles",
  ["Icarus Helper"]   = "Icarus",
  ["Athena Helper"]   = "Athena",
  ["Thanatos Helper"] = "Thanatos",
}

-- God item ("<God> Unlock", display name) -> internal LootData key (RewardLogic.lua's
-- GetEligibleLootNames pool = every LootData entry with GodLoot=true; confirmed this is
-- exactly the 9 boon gods below, one entry each named "<God>Upgrade"). Order mirrors the
-- existing FORCE_GOD_UPGRADES table above for readability, not a functional requirement.
local GOD_ITEM_TO_ID = {
  ["Hephaestus Unlock"] = "HephaestusUpgrade",
  ["Zeus Unlock"]       = "ZeusUpgrade",
  ["Demeter Unlock"]    = "DemeterUpgrade",
  ["Aphrodite Unlock"]  = "AphroditeUpgrade",
  ["Poseidon Unlock"]   = "PoseidonUpgrade",
  ["Apollo Unlock"]     = "ApolloUpgrade",
  ["Hestia Unlock"]     = "HestiaUpgrade",
  ["Ares Unlock"]       = "AresUpgrade",
  ["Hera Unlock"]       = "HeraUpgrade",
}
ItemManager.GOD_ITEM_TO_ID = GOD_ITEM_TO_ID

-- Hermes/Selene (godsanity_shop_gods): a SEPARATE map from GOD_ITEM_TO_ID above -- deliberately
-- NOT merged into it, since ItemManager.unlocked_god_count() iterates GOD_ITEM_TO_ID's values
-- to build the no_waste_less_odds Boon-count scaling fraction, which is fixed at 9 (see
-- GODSANITY_TOTAL_GODS); Hermes/Selene don't participate in that Boon-door system at all (see
-- the eligibility_override block above), so they must never be counted toward it. Values here
-- are arbitrary keys (not LootData names) -- they only need to be unique and match what
-- eligibility_override/god_eligible look up.
local SHOP_GOD_ITEM_TO_ID = {
  ["Hermes Unlock"] = "Hermes",
  ["Selene Unlock"] = "Selene",
}
ItemManager.SHOP_GOD_ITEM_TO_ID = SHOP_GOD_ITEM_TO_ID

-- Combined God Unlock + Keepsake (Python's Items.GOD_KEEPSAKE_COMBINED_GODS/GOD_KEEPSAKE_TITLE):
-- when KeepsakeSanity=randomized AND GodSanity is active, these 11 gods' own "<God> Unlock"
-- item and keepsake item fuse into one "<God> Unlock + Keepsake" item in the pool instead.
-- `god` is the plain "<God> Unlock" name (a key into GOD_ITEM_TO_ID, or SHOP_GOD_ITEM_TO_ID
-- when shop=true), `keepsake` is the keepsake's display title (a key into KEEPSAKE_ITEM_TO_ID
-- below). Receiving the combined item runs both the existing unlock_god/unlock_shop_god AND
-- unlock_keepsake handlers (see unlock_god_keepsake_combined), so unlocked_god_count/
-- god_eligible/keepsake reclaim etc. all keep working unchanged -- they only look at the
-- internal state those handlers write, not which network item triggered it.
local GOD_KEEPSAKE_COMBINED = {
  ["Hephaestus Unlock + Keepsake"] = { god = "Hephaestus Unlock", keepsake = "Adamant Shard" },
  ["Zeus Unlock + Keepsake"]       = { god = "Zeus Unlock",       keepsake = "Cloud Bangle" },
  ["Demeter Unlock + Keepsake"]    = { god = "Demeter Unlock",    keepsake = "Barley Sheaf" },
  ["Aphrodite Unlock + Keepsake"]  = { god = "Aphrodite Unlock",  keepsake = "Beautiful Mirror" },
  ["Poseidon Unlock + Keepsake"]   = { god = "Poseidon Unlock",   keepsake = "Vivid Sea" },
  ["Apollo Unlock + Keepsake"]     = { god = "Apollo Unlock",     keepsake = "Harmonic Photon" },
  ["Hestia Unlock + Keepsake"]     = { god = "Hestia Unlock",     keepsake = "Everlasting Ember" },
  ["Ares Unlock + Keepsake"]       = { god = "Ares Unlock",       keepsake = "Sword Hilt" },
  ["Hera Unlock + Keepsake"]       = { god = "Hera Unlock",       keepsake = "Iridescent Fan" },
  ["Hermes Unlock + Keepsake"]     = { god = "Hermes Unlock",     keepsake = "Metallic Droplet", shop = true },
  ["Selene Unlock + Keepsake"]     = { god = "Selene Unlock",     keepsake = "Moon Beam",         shop = true },
}
ItemManager.GOD_KEEPSAKE_COMBINED = GOD_KEEPSAKE_COMBINED

-- Each familiar's bond-system base id + its 3 upgrade tracks (tier suffix "" / "2" / "3"),
-- for progressive pet bond upgrades (GameState.FamiliarUpgrades[...] = true).
local FAMILIAR_BOND = {
  FrogFamiliar    = { base = "BaseFrogUpgrade",    tracks = { "FrogHealthBonus", "FrogUses", "FrogDamage" } },
  CatFamiliar     = { base = "BaseCatUpgrade",     tracks = { "CatLastStandHeal", "CatUses", "CatAttack" } },
  RavenFamiliar   = { base = "BaseRavenUpgrade",   tracks = { "RavenCritChanceBonus", "RavenUses", "RavenAttack" } },
  HoundFamiliar   = { base = "BaseHoundUpgrade",   tracks = { "HoundManaBonus", "HoundUses", "HoundAttack" } },
  PolecatFamiliar = { base = "BasePolecatUpgrade", tracks = { "PolecatDodgeBonus", "PolecatUses", "PolecatDamage" } },
}

-- Keepsake item (display name) -> internal keepsake trait. Keepsakes are owned when
-- GameState.GiftPresentation[trait] is set (what gifting an NPC normally does).
local KEEPSAKE_ITEM_TO_ID = {
  ["Engraved Pin"]        = "BlockDeathKeepsake",
  ["Luckier Tooth"]       = "ReincarnationKeepsake",
  ["Ghost Onion"]         = "DoorHealReserveKeepsake",
  ["Evil Eye"]            = "DeathVengeanceKeepsake",
  ["White Antler"]        = "LowHealthCritKeepsake",
  ["Moon Beam"]           = "SpellTalentKeepsake",
  ["Gold Purse"]          = "BonusMoneyKeepsake",
  ["Knuckle Bones"]       = "BossPreDamageKeepsake",
  ["Silver Wheel"]        = "ManaOverTimeRefundKeepsake",
  ["Crystal Figurine"]    = "BossMetaUpgradeKeepsake",
  ["Aromatic Phial"]      = "FountainRarityKeepsake",
  ["Silken Sash"]         = "ArmorGainKeepsake",
  ["Experimental Hammer"] = "TempHammerKeepsake",
  ["Lion Fang"]           = "DecayingBoostKeepsake",
  ["Blackened Fleece"]    = "DamagedDamageBoostKeepsake",
  ["Discordant Bell"]     = "EscalatingKeepsake",
  ["Metallic Droplet"]    = "TimedBuffKeepsake",
  ["Concave Stone"]       = "UnpickedBoonKeepsake",
  ["Transcendent Embryo"] = "RandomBlessingKeepsake",
  ["Fig Leaf"]            = "SkipEncounterKeepsake",
  ["Gorgon Amulet"]       = "AthenaEncounterKeepsake",
  ["Calling Card"]        = "RarifyKeepsake",
  ["Jeweled Pom"]         = "HadesAndPersephoneKeepsake",
  ["Time Piece"]          = "GoldifyKeepsake",
  ["Adamant Shard"]       = "ForceHephaestusBoonKeepsake",
  ["Cloud Bangle"]        = "ForceZeusBoonKeepsake",
  ["Barley Sheaf"]        = "ForceDemeterBoonKeepsake",
  ["Beautiful Mirror"]    = "ForceAphroditeBoonKeepsake",
  ["Vivid Sea"]           = "ForcePoseidonBoonKeepsake",
  ["Harmonic Photon"]     = "ForceApolloBoonKeepsake",
  ["Everlasting Ember"]   = "ForceHestiaBoonKeepsake",
  ["Sword Hilt"]          = "ForceAresBoonKeepsake",
  ["Iridescent Fan"]      = "ForceHeraBoonKeepsake",
  -- Nightmare (Zagreus' Journey / zannc-SharedKeepsakePort). internalKeepsakeName confirmed
  -- directly from that mod's keepsakes/keepsake_<npc>.lua source (gods.CreateKeepsake calls).
  ["Shattered Shackle"]   = "SisyphusVanillaKeepsake",
  ["Evergreen Acorn"]     = "ShieldBossKeepsake",
  ["Broken Spearpoint"]   = "ShieldAfterHitKeepsake",
  ["Distant Memory"]      = "DistanceDamageKeepsake",
  ["Skull Earring"]       = "LowHealthDamageKeepsake",
  ["Pierced Butterfly"]   = "PerfectClearDamageBonusKeepsake",
  ["Myrmidon Bracer"]     = "DirectionalArmorKeepsake",
}

-- Keepsake trait -> the GameState.TextLinesRecord flag that marks it owned (each
-- keepsake's GiftLevelData.GameStateRequirements is a single PathTrue on this flag,
-- per KeepsakeData.lua). Granting sets the flag so the keepsake shows owned/equippable.
local KEEPSAKE_TRAIT_TO_OWNFLAG = {
  BlockDeathKeepsake          = "MorosGift01",
  ReincarnationKeepsake       = "SkellyGift01",
  DoorHealReserveKeepsake     = "DoraGift01",
  DeathVengeanceKeepsake      = "NemesisGift01",
  LowHealthCritKeepsake       = "ArtemisGift01",
  SpellTalentKeepsake         = "SeleneGift01",
  BonusMoneyKeepsake          = "CharonGift01",
  BossPreDamageKeepsake       = "OdysseusGift01",
  ManaOverTimeRefundKeepsake  = "HecateGift01",
  BossMetaUpgradeKeepsake     = "CirceGift01",
  FountainRarityKeepsake      = "NarcissusGift01",
  ArmorGainKeepsake           = "ArachneGift01",
  TempHammerKeepsake          = "IcarusGift01",
  DecayingBoostKeepsake       = "HeraclesGift01",
  DamagedDamageBoostKeepsake  = "MedeaGift01",
  EscalatingKeepsake          = "ErisGift01",
  TimedBuffKeepsake           = "HermesGift01",
  UnpickedBoonKeepsake        = "EchoGift01",
  RandomBlessingKeepsake      = "ChaosGift01",
  SkipEncounterKeepsake       = "DionysusGift01",
  AthenaEncounterKeepsake     = "AthenaGift01",
  RarifyKeepsake              = "ZagreusBossGrantsKeepsakeOutro01",
  HadesAndPersephoneKeepsake  = "HadesWithPersephoneGift01",
  GoldifyKeepsake             = "NeoChronosGift01",
  ForceHephaestusBoonKeepsake = "HephaestusGift01",
  ForceZeusBoonKeepsake       = "ZeusGift01",
  ForceDemeterBoonKeepsake    = "DemeterGift01",
  ForceAphroditeBoonKeepsake  = "AphroditeGift01",
  ForcePoseidonBoonKeepsake   = "PoseidonGift01",
  ForceApolloBoonKeepsake     = "ApolloGift01",
  ForceHestiaBoonKeepsake     = "HestiaGift01",
  ForceAresBoonKeepsake       = "AresGift01",
  ForceHeraBoonKeepsake       = "HeraGift01",
  -- Nightmare: confirmed from the SharedKeepsakePort source's own minReq (each keepsake's
  -- leveling gate checks the same "<NPC>Gift01" flag).
  SisyphusVanillaKeepsake        = "SisyphusGift01",
  ShieldBossKeepsake             = "EurydiceGift01",
  ShieldAfterHitKeepsake         = "PatroclusGift01",
  DistanceDamageKeepsake         = "OrpheusGift01",
  LowHealthDamageKeepsake        = "MegaeraGift01",
  PerfectClearDamageBonusKeepsake = "ThanatosGift01",
  DirectionalArmorKeepsake       = "AchillesGift01",
}

-- The Nightmare keepsakes come from the third-party zannc-SharedKeepsakePort plugin, which
-- registers every trait under its ReturnOfModding namespace: gods.CreateKeepsake builds the
-- real trait id as `<plugin guid>-<internalKeepsakeName>` (zannc-GodsAPI main.lua ~L982), so
-- the id the game actually uses -- the one PlayerReceivedGiftPresentation passes as giftName,
-- and the one in game.GiftData[...].Gift and game.TraitData -- is e.g.
-- "zannc-SharedKeepsakePort-PerfectClearDamageBonusKeepsake", NOT the bare name. The two tables
-- above spell the bare names for readability; rewrite the Nightmare entries in place to the
-- prefixed ids so the gift-check hook, the re-gift block, the ownflag lookup, and the AP grant
-- all key off the real trait. (Without this, every Nightmare NPC's keepsake gift missed
-- KEEPSAKE_TRAIT_TO_CHECK -> check=nil -> the hook fell through to vanilla and just handed you
-- the keepsake, sending no location. Confirmed from LogOutput.log:
--   giftName=zannc-SharedKeepsakePort-PerfectClearDamageBonusKeepsake -> check=nil )
-- The ownflag VALUES stay bare -- each keepsake's GiftLevelData GameStateRequirements is a
-- PathTrue on a plain "<NPC>Gift01" TextLinesRecord flag (see keepsake_*.lua minReq).
local NIGHTMARE_KEEPSAKE_PREFIX = "zannc-SharedKeepsakePort-"
local NIGHTMARE_KEEPSAKE_INTERNALS = {
  "SisyphusVanillaKeepsake", "ShieldBossKeepsake", "ShieldAfterHitKeepsake",
  "DistanceDamageKeepsake", "LowHealthDamageKeepsake", "PerfectClearDamageBonusKeepsake",
  "DirectionalArmorKeepsake",
}
do
  local bare_to_prefixed = {}
  for _, bare in ipairs(NIGHTMARE_KEEPSAKE_INTERNALS) do
    bare_to_prefixed[bare] = NIGHTMARE_KEEPSAKE_PREFIX .. bare
  end
  -- KEEPSAKE_ITEM_TO_ID: title -> trait (fix the trait VALUES).
  for title, trait in pairs(KEEPSAKE_ITEM_TO_ID) do
    if bare_to_prefixed[trait] then KEEPSAKE_ITEM_TO_ID[title] = bare_to_prefixed[trait] end
  end
  -- KEEPSAKE_TRAIT_TO_OWNFLAG: trait -> ownflag (re-key by the prefixed trait).
  for bare, prefixed in pairs(bare_to_prefixed) do
    local flag = KEEPSAKE_TRAIT_TO_OWNFLAG[bare]
    if flag then
      KEEPSAKE_TRAIT_TO_OWNFLAG[prefixed] = flag
      KEEPSAKE_TRAIT_TO_OWNFLAG[bare] = nil
    end
  end
end

-- All keepsake traits we manage, for the equip gate in reload.lua.
ItemManager.MANAGED_KEEPSAKES = {}
for _, trait in pairs(KEEPSAKE_ITEM_TO_ID) do ItemManager.MANAGED_KEEPSAKES[trait] = true end

-- Keepsake title -> the NPC who gives it. Check locations are named "<NPC> Keepsake"
-- (must match the Python world's location_keepsakes / KEEPSAKE_NPC).
local KEEPSAKE_TITLE_TO_NPC = {
  ["Engraved Pin"]        = "Moros",
  ["Luckier Tooth"]       = "Skelly",
  ["Ghost Onion"]         = "Dora",
  ["Evil Eye"]            = "Nemesis",
  ["White Antler"]        = "Artemis",
  ["Moon Beam"]           = "Selene",
  ["Gold Purse"]          = "Charon",
  ["Knuckle Bones"]       = "Odysseus",
  ["Silver Wheel"]        = "Hecate",
  ["Crystal Figurine"]    = "Circe",
  ["Aromatic Phial"]      = "Narcissus",
  ["Silken Sash"]         = "Arachne",
  ["Experimental Hammer"] = "Icarus",
  ["Lion Fang"]           = "Heracles",
  ["Blackened Fleece"]    = "Medea",
  ["Discordant Bell"]     = "Eris",
  ["Metallic Droplet"]    = "Hermes",
  ["Concave Stone"]       = "Echo",
  ["Transcendent Embryo"] = "Chaos",
  ["Fig Leaf"]            = "Dionysus",
  ["Gorgon Amulet"]       = "Athena",
  ["Calling Card"]        = "Zagreus",
  ["Jeweled Pom"]         = "Hades and Persephone",
  ["Time Piece"]          = "Chronos",
  ["Adamant Shard"]       = "Hephaestus",
  ["Cloud Bangle"]        = "Zeus",
  ["Barley Sheaf"]        = "Demeter",
  ["Beautiful Mirror"]    = "Aphrodite",
  ["Vivid Sea"]           = "Poseidon",
  ["Harmonic Photon"]     = "Apollo",
  ["Everlasting Ember"]   = "Hestia",
  ["Sword Hilt"]          = "Ares",
  ["Iridescent Fan"]      = "Hera",
  -- Nightmare keepsake-giving cast (must match Items.py's KEEPSAKE_NPC additions).
  ["Shattered Shackle"]   = "Sisyphus",
  ["Evergreen Acorn"]     = "Eurydice",
  ["Broken Spearpoint"]   = "Patroclus",
  ["Distant Memory"]      = "Orpheus",
  ["Skull Earring"]       = "Megaera",
  ["Pierced Butterfly"]   = "Thanatos",
  ["Myrmidon Bracer"]     = "Achilles",
}

-- Keepsake trait -> AP check location name, for the gift hook in reload.lua. Aspects
-- and familiars are items-only (no checks). These keepsakes have NO location (item-only,
-- can't be reliably earned by gifting): Time Piece (Chronos), Calling Card (Zagreus),
-- Jeweled Pom (Hades), and Skull Earring (Megaera -- her gift conditions are still not
-- understood; gifting her behaves vanilla, and any keepsake it awards gets re-locked by
-- apply_keepsake_reclaim on the next connect, so the keepsake stays item-gated).
-- Thanatos/Orpheus/Achilles were REMOVED from this set July 16: their keepsake locations
-- now exist Python-side (playtests confirmed SharedKeepsakePort gifting works), so their
-- gifts send checks again. Must match Python's KEEPSAKE_NO_LOCATION -- tools/sync_check.py
-- enforces that.
local KEEPSAKE_NO_LOCATION = {
  ["Time Piece"] = true, ["Calling Card"] = true, ["Jeweled Pom"] = true,
  ["Skull Earring"] = true,
}
ItemManager.KEEPSAKE_TRAIT_TO_CHECK = {}
for title, trait in pairs(KEEPSAKE_ITEM_TO_ID) do
  if not KEEPSAKE_NO_LOCATION[title] then
    ItemManager.KEEPSAKE_TRAIT_TO_CHECK[trait] = KEEPSAKE_TITLE_TO_NPC[title] .. " Keepsake"
  end
end

-- ---- Incantations -----------------------------------------------------------
-- The Cauldron is blocked, so these meta/QoL unlocks are delivered as AP items (or
-- auto-granted at connect). Each maps to a game WorldUpgrade id; granting one calls
-- force_world_upgrade() (sets GameState.WorldUpgrades directly, persists across runs).
-- Item display name -> internal WorldUpgrade id (must match Python's incantation lists).
local INCANTATION_ITEM_TO_ID = {
  -- Always in the pool
  ["Gathering of Ancient Bones"]      = "WorldUpgradeUnusedWeaponBonus",
  ["Doomed Beckoning"]                = "WorldUpgradeMorosUnlock",
  ["End to Deepest Slumber"]          = "WorldUpgradeWakeHypnos",
  ["End to Dearest Slumber"]          = "WorldUpgradeWakeHypnosT2",
  ["End to Dumbest Slumber"]          = "WorldUpgradeWakeHypnosT3",
  ["Divination of the Elements"]      = "WorldUpgradeElementalBoons",
  ["Rite of Vapor-Cleansing"]         = "WorldUpgradeBathHouse",
  ["Rite of Social Solidarity"]       = "WorldUpgradeTaverna",
  ["Rite of River-Fording"]           = "WorldUpgradeFishingPoint",
  ["Empath's Intuition"]              = "WorldUpgradeRelationshipBar",
  ["Rise of Stygian Wells"]           = "WorldUpgradeWellShops",
  ["Surge of Stygian Wells"]          = "WorldUpgradePostBossWellShops",
  ["Cleansing of Fountain-Waters"]    = "WorldUpgradeFountainUpgrade1",
  ["Purification of Fountain-Waters"] = "WorldUpgradeFountainUpgrade2",
  ["Kindred Keepsakes"]               = "WorldUpgradePostBossGiftRack",
  ["Propensity Toward Gold"]          = "WorldUpgradeBreakableValue1",
  ["Necromantic Influence"]           = "WorldUpgradeShadeMercs",
  ["Eyes of Night and Darkness"]      = "WorldUpgradeChallengeSwitchesExtra1",
  ["Summoning of Musical Rhapsody"]   = "WorldUpgradeMusicPlayer",
  ["Path to Desired Blessings"]       = "WorldUpgradePinningBoons",
  ["Shuffling of Noted Ballads"]      = "WorldUpgradeMusicPlayerShuffle",
  ["Bones of Arcane Wisdom"]          = "WorldUpgradeMetaCurrencyRunProgress",
  ["Gathering of Subterranean Riches"]= "WorldUpgradeUnusedWeaponBonusT2",
  ["Bounties of the Infinite Abyss"]  = "WorldUpgradeMetaRewardStands",
  ["Ashen Memories of Life"]          = "WorldUpgradeMetaCardPointsCommonRunProgress",
  ["Nectar of Godly Savor"]           = "WorldUpgradeGiftDropRunProgress",
  ["Augmentation of Bone Density"]    = "WorldUpgradeSkellyHealth",
  ["Alteration of Familiar Forms"]    = "WorldUpgradeFamiliarCostumeSystem",
  -- Underworld-gated
  ["Temporal Fluctuation"]            = "WorldUpgradeTimeSlowChronosFight",
  ["Circles of the Moon"]             = "WorldUpgradeSafeZoneSpellCharge",
  ["Woodsy Lifespring"]               = "WorldUpgradeErebusReprieve",
  ["Briny Lifespring"]                = "WorldUpgradeOceanusReprieve",
  ["Golden Lifespring"]               = "WorldUpgradeTartarusReprieve",
  ["Reviving a Mournful Husk"]        = "WorldUpgradeFieldsRewardFinder",
  ["Circles of Protection"]           = "WorldUpgradeErebusSafeZones",
  ["Exhumed Troves"]                  = "WorldUpgradeChallengeSwitches1",
  ["Surge of Desecrating Pools"]      = "WorldUpgradePostBossSellTraitShops",
  ["Revival of a Desecrating Pool"]   = "WorldUpgradeRestoreSellTraitShop",
  -- Surface-gated
  ["Surge of Fresh Air"]              = "WorldUpgradePostBossSurfaceShops",
  ["Summoning a Colony of Bats"]      = "WorldUpgradeEphyraZoomOut",
  ["Rush of Fresh Air"]               = "WorldUpgradeSurfaceShops",
  ["Sandy Lifespring"]                = "WorldUpgradeThessalyReprieve",
  ["Arisen Troves"]                   = "WorldUpgradeChallengeSwitchesSurface1",
  ["Frozen Lifespring"]               = "WorldUpgradeOlympusReprieve",
  ["Rage of the Elements"]            = "WorldUpgradeOlympusStatues",
  -- Keepsake-mode-gated
  ["Quickening of Sentimental Value"] = "WorldUpgradeDoubleAdvanceKeepsakes",
  -- Nightmare-gated (Zagreus' Journey). Internal names confirmed directly from that mod's
  -- Scripts/WorldUpgradeData.lua header comment. The first 3 are the mod's own "quest item"
  -- incantations (reunion questline beats) -- see the design plan's note that force-granting
  -- these is higher-risk than a normal flag flip; verify in-game.
  ["Reunite Orpheus and Eurydice"]        = "ModsNikkelMHadesBiomes_OrpheusEurydiceQuestItem",
  ["Release Sisyphus"]                    = "ModsNikkelMHadesBiomes_SisyphusQuestItem",
  ["Allow Orpheus to Spawn in Tartarus"]  = "ModsNikkelMHadesBiomes_OrpheusUnlockItem",
  ["Post-Boss Keepsake Rack"]             = "ModsNikkelMHadesBiomes_UnlockPostBossGiftRackIncantation",
  ["Well of Charon During Runs"]          = "ModsNikkelMHadesBiomes_UnlockInRunWellShopsIncantation",
  ["Well of Charon After Bosses"]         = "ModsNikkelMHadesBiomes_UnlockPostBossWellShopsIncantation",
  ["Sell Shops During Runs"]              = "ModsNikkelMHadesBiomes_UnlockInRunSellShopsIncantation",
  ["Sell Shops After Bosses"]             = "ModsNikkelMHadesBiomes_UnlockPostBossSellShopsIncantation",
  ["Tartarus Fountain Chamber"]           = "ModsNikkelMHadesBiomes_UnlockTartarusReprieveIncantation",
  ["Asphodel Fountain Chamber"]           = "ModsNikkelMHadesBiomes_UnlockAsphodelReprieveIncantation",
  ["Elysium Fountain Chamber"]            = "ModsNikkelMHadesBiomes_UnlockElysiumReprieveIncantation",
  ["Low-Value Gold Urns"]                 = "ModsNikkelMHadesBiomes_BreakableValue1Incantation",
  ["Medium-Value Gold Urns"]              = "ModsNikkelMHadesBiomes_BreakableValue2Incantation",
  ["High-Value Gold Urns"]                = "ModsNikkelMHadesBiomes_BreakableValue3Incantation",
  ["Infernal Troves"]                     = "ModsNikkelMHadesBiomes_UnlockInfernalTrovesIncantation",
  ["Moon Monuments"]                      = "ModsNikkelMHadesBiomes_UnlockMoonMonumentsIncantation",
  ["Erebus Gates"]                        = "ModsNikkelMHadesBiomes_UnlockShrinePointGatesIncantation",
  ["Hades Badges"]                        = "ModsNikkelMHadesBiomes_WorldUpgradeBadgeSeller",
  ["Orpheus' Lyre"]                       = "ModsNikkelMHadesBiomes_HouseLyre01",
  ["New Hades I Cosmetics"]               = "ModsNikkelMHadesBiomesUnlockCosmeticsIncantation",
  ["New Music for the Music Maker"]       = "WorldUpgradeMusicPlayerModsNikkelMUnlockHadesMusic",
}

-- Some world-upgrades only function with a parent flag also set. We force-grant the
-- direct flag, so add any non-item parents here. (Path to Desired Blessings = pinning
-- boons, which needs the base Pinning system; Insight into Offerings is a start-grant.)
local INCANTATION_PREREQS = {
  WorldUpgradePinningBoons = { "WorldUpgradePinning" },
}

-- Auto-granted at connect (not items): visibility/QoL systems. Consecration of Ashes
-- (CardUpgradeSystem) just lets players SEE arcana upgrade levels; the CanUpgradeMetaUpgrade
-- hook still blocks manual upgrades under Progressive arcana. Aspects of Night and Darkness
-- (WeaponUpgradeSystem) enables the aspect UI; aspect purchases stay blocked by aspectsanity.
-- July 19 cull added the 4 below (all seed-unconditional -- see Items.py's
-- INCANTATION_AUTO_GRANTED for the route/mode-scoped ones instead, granted separately by
-- apply_conditional_incantation_starts): Divination of the Elements (Elemental boon pool),
-- Empath's Intuition (relationship-bar UI, same visibility-only shape as Consecration of
-- Ashes), Path to Desired Blessings (boon pinning -- its WorldUpgradePinning prereq is
-- handled by grant_incantation_id, same as when it was a received item), Alteration of
-- Familiar Forms (pet costumes -- its unlock_all_familiar_costumes side effect is likewise
-- handled by grant_incantation_id).
local INCANTATION_START_IDS = {
  "WorldUpgradeCardUpgradeSystem",     -- Consecration of Ashes
  "WorldUpgradeWeaponUpgradeSystem",   -- Aspects of Night and Darkness
  "WorldUpgradeMetaUpgradeSaveLayout", -- Spreading of Ashes
  "WorldUpgradeKeepsakeSaveFirst",     -- Favored of All Keepsakes
  "WorldUpgradeBoonList",              -- Insight into Offerings
  "WorldUpgradeElementalBoons",        -- Divination of the Elements
  "WorldUpgradeRelationshipBar",       -- Empath's Intuition
  "WorldUpgradePinningBoons",          -- Path to Desired Blessings
  "WorldUpgradeFamiliarCostumeSystem", -- Alteration of Familiar Forms
}

-- ---- Slot settings ----------------------------------------------------------

function ItemManager.apply_settings(payload)
  -- payload: "key=value;key=value;..."
  for pair in payload:gmatch("[^;]+") do
    local k, v = pair:match("^(.-)=(.*)$")
    if k then ItemManager.settings[k] = v end
  end
  ItemManager._live_settings_received = true  -- see have_live_settings below
  rom.log.info("[AP] settings received: " .. payload)
end

-- ---- Cross-save settings cache ----------------------------------------------
-- The live client only delivers SETTINGS after a save has loaded (the socket poll runs on the
-- render loop, which doesn't tick at the main menu), so the load-time-critical settings -- the
-- starting weapon (HeroData.DefaultWeapon) and the surface-only first-run redirect
-- (RoomData.N_Opening01.GameStart) -- otherwise arrive too late for a fresh save's intro run. We
-- cache the raw SETTINGS line to disk whenever it arrives, and re-apply just those two at BOOT from
-- the cache, so the next launch has them ready before "New Game". Best-effort: a missing cache or a
-- read/parse failure simply falls back to the live SETTINGS path. The cache is one launch behind,
-- which is correct for a stable seed/config.
local SETTINGS_CACHE_FILE = "Hades2RogueArchipelago.apsettings"

local function settings_cache_path()
  local ok, p = pcall(function()
    return rom.path.combine(rom.paths.config(), SETTINGS_CACHE_FILE)
  end)
  return ok and p or nil
end

-- Persist the raw SETTINGS payload (a "k=v;k=v" line) for the next boot.
function ItemManager.cache_settings(payload)
  if not payload or payload == "" then return end
  local path = settings_cache_path()
  if not path then return end
  pcall(function()
    local f = io.open(path, "w")
    if f then
      f:write(payload)
      f:close()
      rom.log.info("[AP] settings cached to disk (" .. SETTINGS_CACHE_FILE .. ")")
    end
  end)
end

-- At boot, load cached settings and apply ONLY the load-time-critical bit (the starting
-- weapon: HeroData.DefaultWeapon is static data, safe at the menu where GameState is nil).
-- The cached settings ALSO feed the fresh-save intro redirect (redirect_intro_args reads
-- first_run_should_be_surface at StartNewRun) if the live blocking fetch can't reach the
-- client. The in-save SETTINGS handler re-applies everything authoritatively once connected.
-- Never overwrites a setting the live connection already delivered this session.
function ItemManager.apply_cached_settings()
  local path = settings_cache_path()
  if not path then return end
  local payload = nil
  pcall(function()
    local f = io.open(path, "r")
    if f then payload = f:read("*a"); f:close() end
  end)
  if not payload or payload == "" then return end
  for pair in payload:gmatch("[^;]+") do
    local k, v = pair:match("^(.-)=(.*)$")
    if k and ItemManager.settings[k] == nil then ItemManager.settings[k] = v end
  end
  rom.log.info("[AP] applying cached settings at boot (starting weapon)")
  pcall(function() ItemManager.apply_initial_weapon() end)
end

-- Whether any settings have been received yet (live this session or restored from the boot cache).
function ItemManager.have_settings()
  return next(ItemManager.settings) ~= nil
end

-- Whether the CURRENT connection has delivered a live SETTINGS message this session, as opposed
-- to only having the boot-time cache applied. The cache is deliberately "one launch behind" (see
-- apply_cached_settings) -- fine for a stable seed, but if the player switched to a different seed
-- since the last launch (a fresh save on a new multiworld, e.g. a new local test seed), the cached
-- blob is from the OLD seed entirely: wrong starting weapon, no starting_aspect_index, etc. Since
-- have_settings() is satisfied by that stale cache alone, the StartNewRun guard below used to skip
-- the blocking live fetch and build the very first hero from stale data before the real SETTINGS
-- line (already in flight) had a chance to land a few frames later -- Test Run 11 #1: a fresh save
-- started as the Staff with Melinoe's Aspect despite the seed rolling Umbral Flames + an alternate.
function ItemManager.have_live_settings()
  return ItemManager._live_settings_received == true
end

-- Interpret a toggle-style setting (sent as 0/1) as a boolean.
function ItemManager.setting_on(key)
  local v = ItemManager.settings[key]
  return v == "1" or v == "true" or v == "True"
end

-- Interpret a multi-choice setting (sent as 0/1/2) as a number (default 0).
function ItemManager.setting_mode(key)
  return tonumber(ItemManager.settings[key]) or 0
end

-- Whether the active goal requires beating Zagreus at all. Everything Zagreus-specific
-- (Vanilla eligibility override, Empowered stat scaling, Final Challenge redirect) is a
-- no-op when this is false, leaving his vanilla behavior completely untouched.
--
-- Reads the goal_requires_zagreus toggle directly. It used to key a hardcoded ZAGREUS_GOAL_IDS
-- set off a single combined `goal` enum, but the goal system was split into separate
-- goal_requires_<boss> toggles plus a goal_mode (any/all) selector -- there is no `goal` setting
-- sent anymore, so the old lookup always resolved to 0 -> false. That silently disabled the
-- entire Zagreus feature (most visibly: the Final Challenge redirect never fired, so clearing the
-- final boss dropped into vanilla's true-ending path and stranded the player in the boss room).
function ItemManager.goal_includes_zagreus()
  return ItemManager.setting_on("goal_requires_zagreus")
end

-- zagreus_encounter_mode values (match Options.ZagreusEncounterMode).
ItemManager.ZAGREUS_MODE_VANILLA = 0
ItemManager.ZAGREUS_MODE_EMPOWERED = 1
ItemManager.ZAGREUS_MODE_FINAL_CHALLENGE = 2

function ItemManager.zagreus_mode()
  return ItemManager.setting_mode("zagreus_encounter_mode")
end

-- Final Challenge boon-wipe, actual mechanism (found July 11): walking through the ZagContract
-- door out of Chronos'/Typhon's boss room runs that room's LeavePostPresentationEvents
-- (RoomLogic.lua LeaveRoom), and on a first-ever clear those include SetupHeroForEnding
-- (RoomDataI.lua/RoomDataQ.lua) -- the game's "strip the build for the ending cinematic" step.
-- Its ClearUpgrades call empties Traits, OnFireWeapons, WeaponDataOverride, LastStands, and
-- ManaRegenSources. Vanilla only ever offers the contract in early F/G/O rooms, which don't
-- carry that event, so this only ever bit our redirect. The old snapshot/restore workaround put
-- the Traits table back but none of the rest (and no HUD refresh), so the build still played as
-- wiped -- the fix is reload.lua's SetupHeroForEnding wrap, which skips the strip when the exit
-- leads to C_Boss01. This helper just logs the arrival state so a playtest can confirm the fix
-- from LogOutput.log alone.
function ItemManager.log_zagreus_arrival()
  if not ItemManager.goal_includes_zagreus()
     or ItemManager.zagreus_mode() ~= ItemManager.ZAGREUS_MODE_FINAL_CHALLENGE then return end
  local count = 0
  pcall(function()
    for _ in pairs(game.CurrentRun.Hero.Traits or {}) do count = count + 1 end
  end)
  rom.log.info("[AP] Final Challenge: arrived in C_Boss01 with " .. count .. " traits")
end

-- Whether a route (Underworld/Surface) is part of this seed. Excluded routes still exist
-- in-game, but we must not send their (non-existent) checks. Defaults to active if the
-- flag is missing (older seeds).
local ROUTE_ACTIVE_KEY = {
  Underworld = "underworld_active", Surface = "surface_active", Nightmare = "nightmare_active",
}
function ItemManager.route_active(route)
  local key = ROUTE_ACTIVE_KEY[route] or "underworld_active"
  local v = ItemManager.settings[key]
  return v == nil or v == "1" or v == "true" or v == "True"
end

-- Whether the player has actually UNLOCKED access to (route, zone) yet (Test Run 8 #1). This is
-- the SAME gate as the route-lock kill (reload.lua StartRoom): with lock_routes on, zone Z of a
-- route is reachable once route_progress >= (Z-1) + <route>_offset (a surface-start seed sets
-- underworld_offset=1, so its zone 1 needs the first Progressive Underworld). Used to block room
-- score checks for an area the player can't reach yet -- e.g. the surface-start seed's forced
-- Underworld intro must not send "Underworld Room 1" before the bounce-to-Crossroads death.
-- When lock_routes is off every active route is freely accessible, so nothing is gated.
-- A route the seed EXCLUDED entirely (route_active false) is never "unlocked" -- checked first and
-- independent of lock_routes, since exclusion isn't a progressive gate that opens later, it's
-- permanent. Without this, an excluded route's offset stays 0 (generation never assigns one to a
-- route outside active_routes), so have(0) >= (zone-1)+offset(0) reads as unlocked for zone 1 --
-- exactly the bug where a Nightmare-only seed's hardcoded Underworld boot intro neither redirected
-- nor killed the player.
function ItemManager.route_zone_unlocked(route, zone)
  if not route then return false end
  if not ItemManager.route_active(route) then return false end
  if not ItemManager.setting_on("lock_routes") then return true end
  if not zone then return true end                       -- unknown depth: don't over-block
  local s = APState.get()
  if not s or not s.route_progress then return true end  -- no save state: don't over-block
  local have = s.route_progress[route] or 0
  local offset = ItemManager.setting_mode(route:lower() .. "_offset")
  return have >= (zone - 1) + offset
end

-- Physical "ward" on a Crossroads run-start door (Test Run 8 #2). The two run doors call
-- UseEscapeDoor with args.StartingBiome ("F"=Underworld zone 1, "N"=Surface zone 1). When a
-- surface-start seed locks the Underworld (underworld_offset=1), the player could still walk through
-- the Underworld door and start a run -- the StartRoom route-lock kill only caught them AFTER the
-- biome loaded. door_route_zone maps the door's StartingBiome to (route, zone) via Routes.ROOMSET so
-- run_door_locked can decide; returns nil for non-route doors (Dream/test) so those are never warded.
function ItemManager.door_route_zone(args)
  local biome = args and args.StartingBiome
  local info = biome and Routes and Routes.ROOMSET and Routes.ROOMSET[biome]
  if not info then return nil end
  return info[1], info[2]
end

-- True when a run-start door should be warded shut: that route's zone isn't unlocked yet (same
-- route_zone_unlocked gate as the room-score block and the StartRoom kill, so the door, the kill,
-- and the check-suppression all agree -- including for a route the seed excluded entirely, which
-- route_zone_unlocked now locks regardless of lock_routes).
function ItemManager.run_door_locked(args)
  local route, zone = ItemManager.door_route_zone(args)
  if not route then return false end
  return not ItemManager.route_zone_unlocked(route, zone)
end

-- Repulse Melinoe from a warded run door instead of starting the locked run (the door's UseEscapeDoor
-- wrap returns early after this, so no run begins). Reuses the game's own warded-door presentation
-- (LockedSurfaceRunPresentation: repulse + "denied" sound + WardedDoorVoiceLines) -- literally the
-- ward that covers the surface gateway early game -- plus our "Route is Locked" banner. usee is the
-- door obstacle passed to UseEscapeDoor. All guarded so a missing game func can never break the door.
function ItemManager.block_run_door(usee, args)
  if Notifications then pcall(function() Notifications.push("locked", "Route is Locked") end) end
  pcall(function()
    if game.LockedSurfaceRunPresentation then
      game.LockedSurfaceRunPresentation(usee, args)
    end
  end)
  local route = ItemManager.door_route_zone(args)
  rom.log.info("[AP] warded run door: blocked " .. tostring(route) .. " (locked) - no run started")
end

-- Persistent VISUAL ward on AP-locked run doors, reusing the game's own Vow of Void presentation.
-- The game seals a run door two ways when your Grasp is too high (LimitGraspShrineUpgrade, a.k.a.
-- Vow of Void): it swaps the door's UseText/OnUsedFunction AND paints a warded sprite over the door
-- via SetAnimation (HubPresentation.UpdateEscapeDoorForLimitGraspShrineUpgrade). Our route lock only
-- ever handled the INTERACTION (UseEscapeDoor -> block_run_door repulse), so an AP-locked door still
-- LOOKED open -- a player on a seed that excludes / hasn't-unlocked the Underworld got no visual cue
-- it was sealed until they walked into it. Here we paint the exact same warded sprite the vow uses so
-- an AP-locked door reads as warded at a glance. VISUAL ONLY: we deliberately leave the door's
-- UseText/OnUsedFunction untouched, so interacting still routes through our UseEscapeDoor wrap (the
-- correct "Route is Locked" banner + ward repulse) rather than the vow's altar-pointing "Grasp too
-- high" hint. Same route_zone_unlocked gate as block_run_door, so the look always agrees with the
-- actual lock. Idempotent -- safe to run on every door refresh. Sprite names come straight from
-- UpdateEscapeDoorForLimitGraspShrineUpgrade (Surface door "N" -> ...NE, Underworld/other -> ...SW).
function ItemManager.ward_locked_run_doors(escapeDoorIds)
  local map = game.MapState
  if not map or not map.ActiveObstacles then return end
  for _, id in ipairs(escapeDoorIds or {}) do
    local door = map.ActiveObstacles[id]
    local biome = door and door.OnUsedFunctionArgs and door.OnUsedFunctionArgs.StartingBiome
    if door and not door.BlockedByNarrative and biome
        and ItemManager.run_door_locked({ StartingBiome = biome }) then
      local anim = (biome == "N") and "LimitGraspShrineUpgradeDoorExitLockedNE"
        or "LimitGraspShrineUpgradeDoorExitLockedSW"
      pcall(function() SetAnimation({ DestinationId = door.ObjectId, Name = anim }) end)
      rom.log.info("[AP] warded run door sprite on '" .. tostring(biome) .. "' (route locked)")
    end
  end
end

-- ---- Boss ingredient drops -> Nectar -----------------------------------------
-- Every zone's boss leaves behind a unique "Mixer" crafting ingredient used at Ephyra's cauldron
-- (Scylla's Pearl, Infested Cerberus's Tears, Chronos's Sand, etc.) via a plain
-- `room.ForcedReward = "Mixer<Zone>BossDrop"` string on the boss room's data (confirmed in
-- installed Content/Scripts/RoomData<Zone>.lua). Redirected to "GiftDrop" -- the vanilla
-- Nectar-bottle-in-the-world reward, already used natively as a real room reward in Elysium/Styx
-- and as a pool entry in many other biomes' shops/challenge rooms (StoreData.lua,
-- EncounterData_Challenge.lua, etc.) -- so the pickup keeps a real, asset-backed model/animation
-- instead of a bespoke item that might render with no sprite. Safe to redirect unconditionally:
-- ChooseRoomReward (RewardLogic.lua) returns `room.ForcedReward` directly with NO
-- GameStateRequirements/ResourceCosts check on the target consumable, so GiftDrop's own
-- Elysium/Styx-only gate and 75-Gold shop cost (both shop-purchase-path fields, irrelevant to a
-- forced room-clear reward) never apply here.
-- Q_Boss02 (Typhon repeat kills) has no LITERAL ForcedReward in the source -- it InheritFrom
-- Q_Boss01 and never overrides the field, so it only carries "MixerQBossDrop" via InheritFrom
-- flattening at data-load time. Listed explicitly anyway (rather than relied on inheritance)
-- since we overwrite the field directly.
local BOSS_INGREDIENT_ROOMS = {
  { zone = "F", room = "F_Boss01" },  -- Hecate
  { zone = "F", room = "F_Boss02" },
  { zone = "G", room = "G_Boss01" },  -- Scylla (Pearl)
  { zone = "G", room = "G_Boss02" },
  { zone = "H", room = "H_Boss01" },  -- Infested Cerberus (Tears)
  { zone = "H", room = "H_Boss02" },
  { zone = "I", room = "I_Boss01" },  -- Chronos
  { zone = "N", room = "N_Boss01" },  -- Polyphemus
  { zone = "N", room = "N_Boss02" },
  { zone = "O", room = "O_Boss01" },  -- Eris
  { zone = "O", room = "O_Boss02" },
  { zone = "P", room = "P_Boss01" },  -- Prometheus
  { zone = "Q", room = "Q_Boss01" },  -- Typhon
  { zone = "Q", room = "Q_Boss02" },
}
-- game.RoomData is base Lua data that resets on a fresh-process rejoin (same gotcha as every
-- other static-data patch in this file), so this must be reasserted every room, not just once at
-- boot -- see the StartRoom/RestoreUnlockRoomExits call sites below.
function ItemManager.apply_boss_drops_as_nectar()
  for _, entry in ipairs(BOSS_INGREDIENT_ROOMS) do
    local copies = {}
    if game.RoomData then copies[#copies + 1] = game.RoomData[entry.room] end
    if game.RoomSetData then
      local rsd = game.RoomSetData[entry.zone]
      copies[#copies + 1] = rsd and rsd[entry.room]
    end
    for _, room in ipairs(copies) do
      if room then
        if room.ForcedReward and room.ForcedReward ~= "GiftDrop" then
          room.ForcedReward = "GiftDrop"
        end
        -- Typhon's one-time "Storm Stop" bonus ingredient (CheckTyphonReward in
        -- PresentationBiomeQ.lua grants "MixerMythicDrop" the first time he's defeated with that
        -- world upgrade active) is a SEPARATE reward from the room's normal ForcedReward --
        -- redirect it too so it doesn't leak a boss ingredient item through the one path the
        -- ForcedReward rewrite above doesn't cover.
        local args = room.OnRoomRewardSpawnedFunctionArgs
        local loot = args and args.LootOptions and args.LootOptions[1]
        if loot and loot.Name == "MixerMythicDrop" then
          loot.Name = "GiftDrop"
        end
      end
    end
  end
end

-- ---- Nightmare (Zagreus' Journey) boss resource drops -> Nectar ---------------
-- Same idea as apply_boss_drops_as_nectar above, but for the Nightmare route's own zone bosses
-- (ported from Hades 1 by the third-party Zagreus' Journey mod). Confirmed in the mod's installed
-- RoomData<Zone>.lua: A_Boss01/X_Boss01/Y_Boss01/D_Boss01 each set
-- `ForcedReward = "ModsNikkelMHadesBiomes_BossResource<Zone>Drop"` and nil out
-- ForcedRewardStore/EligibleRewards/RewardConsumableOverrides/FirstClearRewardStore (the H1-style
-- meta-point reward those fields otherwise carry). A_Boss02/A_Boss03 (Alecto/Tisiphone, the other
-- two possible Fury bosses) and X_Boss02 (Hydra's Extreme Measures repeat arena) only carry
-- InheritFrom = {"A_Boss01"/"X_Boss01"} in the mod's own base H1 port data and are never
-- re-overridden with those same fields by the mod's own roomModifications layer -- rather than
-- depend on exactly when/whether that InheritFrom gets flattened relative to the mod's patch,
-- this forces the identical redirect onto all 7 room keys directly.
local NIGHTMARE_BOSS_RESOURCE_ROOMS = {
  { zone = "Tartarus", room = "A_Boss01" },  -- Megaera
  { zone = "Tartarus", room = "A_Boss02" },  -- Alecto
  { zone = "Tartarus", room = "A_Boss03" },  -- Tisiphone
  { zone = "Asphodel", room = "X_Boss01" },  -- Hydra
  { zone = "Asphodel", room = "X_Boss02" },  -- Hydra (Extreme Measures repeat)
  { zone = "Elysium",  room = "Y_Boss01" },  -- Theseus & Asterius
  { zone = "Styx",     room = "D_Boss01" },  -- Hades
}
function ItemManager.apply_nightmare_boss_drops_as_nectar()
  if not ItemManager.nightmare_mod() then return end
  for _, entry in ipairs(NIGHTMARE_BOSS_RESOURCE_ROOMS) do
    local copies = {}
    if game.RoomData then copies[#copies + 1] = game.RoomData[entry.room] end
    if game.RoomSetData then
      local rsd = game.RoomSetData[entry.zone]
      copies[#copies + 1] = rsd and rsd[entry.room]
    end
    for _, room in ipairs(copies) do
      if room then
        room.ForcedReward = "GiftDrop"
        room.ForcedRewardStore = nil
        room.EligibleRewards = nil
        room.RewardConsumableOverrides = nil
        room.FirstClearRewardStore = nil
      end
    end
  end
end

-- ---- Nightmare (opt-in third-party "Zagreus' Journey" mod integration) --------
-- This route only works if NikkelM-Zagreus_Journey is actually installed alongside us.
-- Every touch point below goes through this accessor + is pcall-guarded, so a seed with
-- nightmare_active=1 but the mod missing degrades to "that route's hooks never fire" instead
-- of crashing (see the design plan's compatibility section). Returns the mod's public table,
-- or nil if absent / not validly installed.
function ItemManager.nightmare_mod()
  local mods_table = rom and rom.mods
  if not mods_table then return nil end
  local zj = mods_table[Routes.NIGHTMARE_MOD_NAME]
  if not zj then return nil end
  -- def.lua only exposes `public.IsValidInstallation` (a plain flag, not a function) -- if
  -- that shape turns out wrong in-game, fall back to treating presence alone as "installed"
  -- rather than silently never installing our hooks.
  if zj.IsValidInstallation == false then return nil end
  return zj
end

-- Megaera (A_Boss01, ungated) is FORCED as the only eligible Tartarus boss until the 3rd
-- Nightmare boss (Theseus and Asterius, Elysium -- zone 3) is considered beatable, matching the
-- same threshold Rules.py's MINIBOSS_ZONE_OVERRIDE now uses for Alecto/Tisiphone's own
-- "Defeated" location logic (see Locations.py). Once that zone is unlocked, all three sisters
-- become boss-eligible and Zagreus' Journey's own random pick takes over.
-- A_Boss02 (Alecto) and A_Boss03 (Tisiphone) carry three rollout-gate fields: the mod's own
-- RequiredKills = { Harpy = 4 } (4 lifetime Megaera kills -- "Harpy" is her internal unit id,
-- see LocationManager.ENEMY_UNIT_OVERRIDE) plus two latent ones inherited from the vanilla
-- Hades room data it merges over (RequiredTextLinesPerMetaUpgradeLevel /
-- RequiredFalseTextLinesThisRun). Those two are always just stripped (pure narrative pacing,
-- not a real difficulty gate we want to preserve either direction). RequiredKills is different:
-- it's real save-persisted lifetime state, not base Lua data, so simply leaving vanilla's gate
-- alone while closed is NOT reliable -- a route_progress-based Nightmare unlock (Progressive
-- Nightmare items can arrive from any check, not just from actually fighting Megaera) could
-- reach the "3rd boss beatable" unlock point while the real kill count is still 0, or conversely
-- a long-lived save could rack up 4 real kills before we intend to open the gate. So both
-- directions are forced explicitly every room: closed -> pin RequiredKills to an impossible
-- target; open -> strip it entirely. RoomData is base Lua data (resets on a fresh process), so
-- this needs the same "reassert every room" treatment as the rest of this file's strips.
-- Touches both copies of the room data (game.RoomData + game.RoomSetData.Tartarus, usually the
-- same table refs), keeping the mod's own IsTartarusBossRoomEligible function requirement intact
-- (it handles forced-boss bounties and Dream Run eligibility). Idempotent, and a silent no-op
-- until the Zagreus' Journey room data actually exists -- so callers can run it at boot AND
-- per-room without harm.
local NIGHTMARE_FURY_LOCK_KILLS = 999999
function ItemManager.apply_nightmare_fury_unlock()
  if not ItemManager.nightmare_mod() then return end
  local unlocked = ItemManager.route_zone_unlocked("Nightmare", 3)
  for _, room_name in ipairs({ "A_Boss02", "A_Boss03" }) do
    local copies = {}
    if game.RoomData then copies[#copies + 1] = game.RoomData[room_name] end
    if game.RoomSetData then
      local rsd = game.RoomSetData.Tartarus
      copies[#copies + 1] = rsd and rsd[room_name]
    end
    for _, room in ipairs(copies) do
      local reqs = room and room.GameStateRequirements
      if reqs then
        reqs.RequiredTextLinesPerMetaUpgradeLevel = nil
        reqs.RequiredFalseTextLinesThisRun = nil
        if unlocked then
          if reqs.RequiredKills ~= nil then
            reqs.RequiredKills = nil
            rom.log.info("[AP] Nightmare: " .. room_name
              .. " fury rollout gate stripped (3rd boss beatable -- all three sisters boss-eligible)")
          end
        elseif not (reqs.RequiredKills and reqs.RequiredKills.Harpy == NIGHTMARE_FURY_LOCK_KILLS) then
          reqs.RequiredKills = { Harpy = NIGHTMARE_FURY_LOCK_KILLS }
          rom.log.info("[AP] Nightmare: " .. room_name
            .. " fury rollout gate forced closed (Megaera only -- 3rd boss not yet beatable)")
        end
      end
    end
  end
end

-- Nightmare-route counterpart to [[project_helper_npcs_any_location]]'s base-game work: the
-- "helper" story rooms (Sisyphus/Eurydice/Patroclus) and Thanatos (the combat-assist NPC who
-- "helps" by racing you to kill enemies -- Nightmare's version of Nemesis's compete variant)
-- use a completely different requirement DSL than the base game (RequiredMinBiomeDepth/
-- RequiredMinCompletedRuns/RequiredSeenRooms/RequireAnyEncounterCompleted -- flat named fields
-- ported straight from Hades 1, NOT the Path/PathTrue/NamedRequirements style our
-- IsGameStateEligible wrap intercepts). Whether that DSL even routes through the same global
-- IsGameStateEligible is unconfirmed, so -- exactly like apply_nightmare_fury_unlock above --
-- this strips the specific blocking fields directly off the merged data instead of trying to
-- reuse the eligibility-override mechanism. Per-run pacing fields (RequiredFalseTextLinesThisRun/
-- LastRun, RequiredAnyTextLines, the Elysium-intro's own RequiredFalseTextLines=ThanatosFirstAppearance)
-- are deliberately left alone, same "keep the natural cadence" precedent as the base-game helper
-- intros.
--   Story rooms (room key -> zone -> fields stripped, confirmed by reading the actual merged
--   GameStateRequirements in each zone's RoomData<Zone>.lua "roomReplacements" against the raw
--   ported data in HadesRoomData<Zone>.lua):
--     A_Story01 (Sisyphus, Tartarus): RequiredMinBiomeDepth=4, RequiredMinCompletedRuns=1,
--       RequiredSeenRooms={"A_Boss01"}
--     X_Story01 (Eurydice, Asphodel): RequiredMinBiomeDepth=2, RequiredMinCompletedRuns=1,
--       RequiredSeenEncounter="BossHydra" (ZJ's own modification already replaced the raw H1
--       RequiredSeenRooms with this)
--     Y_Story01 (Patroclus, Elysium): RequiredMinBiomeDepth=3, RequiredMinCompletedRuns=1,
--       RequiredSeenRooms={"C_Boss01"}
--   Thanatos (EncounterData, not room data -- InheritFrom is flattened at data-load time so
--   each Thanatos<Zone> entry already carries its own copies of BaseThanatos's fields, not a
--   live link to a shared table): RequiredMinCompletedRuns=1 (all 3), RequiredMinBiomeDepth
--   (9 in Tartarus -- functionally "never" at normal biome depths -- 2 in Asphodel, 3 in
--   Elysium), and RequireAnyEncounterCompleted={"ThanatosElysium","ThanatosElysiumIntro"} on
--   Tartarus+Asphodel only (the game's actual design: Thanatos first appears in Elysium, THEN
--   becomes eligible in earlier zones on a later run -- exactly the "any location, from the
--   beginning" gate the wishlist asked to remove). "Any location" needs no pool-injection the
--   way the base-game NPCs did: he's already wired into all three zones that have a matching
--   Default pool (game.EncounterSets.TartarusEncountersDefault/AsphodelEncountersDefault/
--   ElysiumEncountersDefault -- confirmed the SAME global EncounterSets table the base-game
--   any-location injection uses) -- Styx has no equivalent Default-style pool (only
--   StyxEncountersMini, a different room type) and Surface has none at all, so those two are
--   left uncovered; nothing to inject into.
local NIGHTMARE_STORY_ROOMS = {
  { zone = "Tartarus", room = "A_Story01",
    fields = { "RequiredMinBiomeDepth", "RequiredMinCompletedRuns", "RequiredSeenRooms" } },
  { zone = "Asphodel", room = "X_Story01",
    fields = { "RequiredMinBiomeDepth", "RequiredMinCompletedRuns", "RequiredSeenEncounter" } },
  { zone = "Elysium", room = "Y_Story01",
    fields = { "RequiredMinBiomeDepth", "RequiredMinCompletedRuns", "RequiredSeenRooms" } },
}
local NIGHTMARE_THANATOS_ENCOUNTERS = {
  { key = "ThanatosTartarus",
    fields = { "RequiredMinBiomeDepth", "RequiredMinCompletedRuns", "RequireAnyEncounterCompleted" } },
  { key = "ThanatosAsphodel",
    fields = { "RequiredMinBiomeDepth", "RequiredMinCompletedRuns", "RequireAnyEncounterCompleted" } },
  { key = "ThanatosElysium",
    fields = { "RequiredMinBiomeDepth", "RequiredMinCompletedRuns" } },
  { key = "ThanatosElysiumIntro",
    fields = { "RequiredMinBiomeDepth", "RequiredMinCompletedRuns" } },
}
function ItemManager.apply_nightmare_helpers_unlock()
  if not ItemManager.nightmare_mod() then return end
  for _, entry in ipairs(NIGHTMARE_STORY_ROOMS) do
    local copies = {}
    if game.RoomData then copies[#copies + 1] = game.RoomData[entry.room] end
    if game.RoomSetData then
      local rsd = game.RoomSetData[entry.zone]
      copies[#copies + 1] = rsd and rsd[entry.room]
    end
    for _, room in ipairs(copies) do
      local reqs = room and room.GameStateRequirements
      if reqs then
        local touched = false
        for _, field in ipairs(entry.fields) do
          if reqs[field] ~= nil then
            reqs[field] = nil
            touched = true
          end
        end
        if touched then
          rom.log.info("[AP] Nightmare: " .. entry.room .. " (" .. entry.zone
            .. ") helper-room story gate stripped (can appear the first time you reach that zone)")
        end
      end
      -- Selection-odds fix, same idea as F/G/I/N_Story01's own native pity timer (see
      -- apply_story_room_lifetime_unlock's header): an eligible room still just competes at
      -- random odds against every other room type at
      -- that door unless something guarantees it -- confirmed the SAME RunLogic.lua
      -- ChooseNextRoomData/IsRoomForced engine code governs Nightmare rooms too (it's base-game
      -- logic operating on whatever data table it's handed). None of these three carry a native
      -- ForceIfUnseenForRuns (confirmed absent in both the raw Hades 1 source and ZJ's port), so
      -- add the same pity timer the base game's own story rooms use elsewhere (occasional, not
      -- mandatory every run) rather than an unconditional AlwaysForce.
      if room and room.ForceIfUnseenForRuns ~= 3 then room.ForceIfUnseenForRuns = 3 end
    end
  end
  if game.EncounterData then
    for _, entry in ipairs(NIGHTMARE_THANATOS_ENCOUNTERS) do
      local enc = game.EncounterData[entry.key]
      local reqs = enc
      if reqs then
        local touched = false
        for _, field in ipairs(entry.fields) do
          if reqs[field] ~= nil then
            reqs[field] = nil
            touched = true
          end
        end
        if touched then
          rom.log.info("[AP] Nightmare: " .. entry.key .. " rollout gate stripped (Thanatos can appear from run 1)")
        end
      end
    end
  end
end

-- zerp-Extended_NPC_Encounters (the combat-assist NPC randomizer dependency): every encounter
-- it adds (ArtemisCombatH/I/O, HeraclesCombatF/G/H/I, ThanatosCombatF..P, the Nightmare-zone
-- variants, ...) carries LIFETIME GameState gates copied from the NPC's native encounter --
-- `PathTrue {GameState, EncountersCompletedCache, <NPC>CombatIntro}` ("you've completed this
-- NPC's intro encounter at least once, EVER") and for some NPCs `PathTrue {GameState,
-- TextLinesRecord, <line>}` story beats. On an AP save those intros may simply never have
-- fired (confirmed July 18: IcarusCombatIntro completed for the FIRST time that session, weeks
-- into the seed), which silently zeroes the whole "NPCs can appear in any zone" feature for
-- that NPC. Same class of gate this file already strips for story rooms
-- (apply_story_room_lifetime_unlock), minibosses (apply_miniboss_unlock) and ZJ's Thanatos
-- rollout (apply_nightmare_helpers_unlock) -- so strip exactly those lifetime entries from the
-- ADDED encounters only, leaving depth windows, per-run dedup (CurrentRun.* paths), config
-- toggles and the NoRecentFieldNPCEncounter pacing untouched. The NATIVE encounters keep their
-- vanilla gates (they demonstrably fire).
-- The added-encounter list comes from the dependency itself: its ready.lua records every name
-- it injects in `mod.NewNPCEncounters` on its registered ModUtil object
-- (modutil.mod.Mods.Data["zerp-Extended_NPC_Encounters"]). Idempotent; safe at boot + every
-- room (EncounterData is base Lua data, re-inherited by SetupRunData on each StartNewRun, so a
-- fresh process/rejoin restores the gates without the reassert).
function ItemManager.apply_extended_npc_unlock()
  local ok, zmod = pcall(function()
    return modutil and modutil.mod and modutil.mod.Mods
      and modutil.mod.Mods.Data and modutil.mod.Mods.Data["zerp-Extended_NPC_Encounters"]
  end)
  if not (ok and zmod and type(zmod.NewNPCEncounters) == "table") then return end
  if not (game.EncounterData) then return end
  for _, enc_name in ipairs(zmod.NewNPCEncounters) do
    local enc = game.EncounterData[enc_name]
    local reqs = enc and enc.GameStateRequirements
    if type(reqs) == "table" then
      local stripped = 0
      for i = #reqs, 1, -1 do
        local entry = reqs[i]
        local pt = type(entry) == "table" and entry.PathTrue
        if type(pt) == "table" and pt[1] == "GameState"
          and (pt[2] == "EncountersCompletedCache" or pt[2] == "TextLinesRecord") then
          table.remove(reqs, i)
          stripped = stripped + 1
        end
      end
      if stripped > 0 and not ItemManager._extended_npc_strip_logged then
        ItemManager._extended_npc_strip_logged = true
        rom.log.info("[AP] Extended NPC encounters: lifetime intro gates stripped (first: "
          .. enc_name .. ") -- combat-assist NPCs eligible in every zone from run 1")
      end
    end
  end
end

-- Lock the Zagreus' Journey Chaos Gate (the Nightmare route's run-start door) at the OBSTACLE
-- level. Unlike the base game's Vow of Void (LimitGraspShrineUpgrade), which keeps a locked run
-- door usable-but-denied (input-block + repulse + "exits blocked" text), we make this gate fully
-- uninteractable when AP-locked: nil UseText/OnUsedFunctionName means no "Press to use" prompt
-- ever appears and pressing interact does nothing at all (see update_nightmare_gate). Paired with
-- the SecretDoor_Closed animation so it also reads as shut, not just silently unresponsive. ZJ's
-- StartHadesRun never runs -- no Nightmare run begins.
--
-- Why this instead of wrapping StartHadesRun (the previous approach)? That function lives on
-- Zagreus' Journey's private ModUtil mod object, NOT on the `public` table rom.mods exposes (see
-- nightmare_mod() -- def.lua only publishes .config and .IsValidInstallation). So `zj.StartHadesRun`
-- was always nil and the wrap NEVER installed: LogOutput only ever showed "mod not present/valid
-- yet -- will retry", never "installed", and the gate stayed open the whole session. Mutating the
-- spawned obstacle's data sidesteps that entirely -- these are plain fields the interaction system
-- reads live, and ZJ explicitly built the gate for this path (it wires the grasp-lock updater
-- ModsNikkelMHadesBiomesUpdateEscapeDoorForLimitGraspShrineUpgrade as a SetupEvent AND
-- pre-populates OnUsedFunctionArgs.AltarId "for the DirectionHintPresentation if
-- LimitGraspShrineUpgradeEscapeDoorClosed is active"; DeathLoopData.lua).
--
-- APPLICATION TIMING (the July-18 refix -- why update_nightmare_gate exists): the July-16
-- obstacle seal was correct but NEVER RAN against a live gate. ZJ spawns the gate from a
-- Hub_PreRun StartUnthreadedEvent (SpawnHadesRunStartDoor), and the hub maps are entered via
-- map loads that never hit our StartRoom wrap -- so every existing call site ran either before
-- the gate existed (boot) or not at all (hub entry), and the scan found nothing, silently. A
-- whole playtest session showed zero "[AP] Nightmare Chaos Gate" lines with the gate wide open.
-- The reliable choke point is SetupObstacle: ZJ stamps ModsNikkelMHadesBiomesIsRunStartDoor on
-- the gate's table BEFORE calling game.SetupObstacle(chaosGate) (DeathLoopData.lua:84/101), so a
-- SetupObstacle wrap (reload.lua) sees the marked table the instant the gate spawns and seals it
-- there. ZJ's own grasp-updater (HubPresentation.lua LockHadesRunStartDoor, re-run on every
-- Grasp/hub refresh via its UpdateEscapeDoorForLimitGraspShrineUpgrade wrap) rewrites
-- UseText/OnUsedFunctionName back to the OPEN values whenever Grasp allows -- undoing any seal --
-- so our own outermost wrap of that same function re-applies the seal after every repaint (see
-- reload.lua's UpdateEscapeDoorForLimitGraspShrineUpgrade wrap), and the render-loop poll
-- (~0.5s, reload.lua) re-applies it too, so a seal can never be left clobbered for long even if
-- something else repaints the gate outside those two hook points.
--
-- Seal/open one Chaos Gate obstacle per the current lock state. Safe on any table; no-op unless
-- it carries ZJ's run-start-door marker.
function ItemManager.update_nightmare_gate(gate)
  if not (type(gate) == "table" and gate.ModsNikkelMHadesBiomesIsRunStartDoor) then return end
  if gate.BlockedByNarrative then return end
  if ItemManager.nightmare_run_locked() then
    -- Already sealed AND still nil live (nothing has clobbered it since): nothing to do. Checking
    -- the live field too, not just our own flag, matters because ZJ's own grasp-updater rewrites
    -- UseText/OnUsedFunctionName back to the OPEN values on every Grasp/hub repaint (see the wrap
    -- in reload.lua) -- if we only trusted our flag, that repaint would silently reopen the gate
    -- until the next room transition.
    if gate.ArchipelagoNightmareLocked and gate.OnUsedFunctionName == nil then return end
    -- Snapshot the open handler/text so we can restore them exactly if the route unlocks. Safe
    -- to redo on a re-seal (after ZJ clobbered the fields back open): the live values at that
    -- point are ZJ's own open handler/text again, same as what we'd already snapshotted.
    gate.ArchipelagoNightmareOrigOnUsed = gate.OnUsedFunctionName
    gate.ArchipelagoNightmareOrigUseText = gate.UseText
    -- Fully uninteractable, not the Vow-of-Void "door stays usable, denied-with-a-message on
    -- interact" pattern the previous version copied: nil OnUsedFunctionName makes
    -- InteractLogic's CallFunctionName a no-op (it only fires when non-nil), and nil UseText
    -- makes UILogic.GetUseText's final fallthrough return nil, which skips creating the
    -- "Press to use" prompt textbox entirely (RoomLogic: "if useText == nil then return end").
    -- No prompt appears and interacting does nothing at all.
    gate.OnUsedFunctionName = nil
    gate.UseText = nil
    gate.ArchipelagoNightmareLocked = true
    -- Visuals: mirror ZJ's OWN gate lock (HubPresentation.lua LockHadesRunStartDoor
    -- ShouldLock=true) -- this obstacle is a SecretDoor, not a vanilla run door, so the vanilla
    -- warded-door sprite doesn't exist on it; SecretDoor_Closed is this obstacle type's own
    -- vanilla closed-door animation (ObstacleData.lua SecretDoor.ExitDoorCloseAnimation).
    local anim_ok, anim_err = pcall(function()
      StopAnimation({ Names = { "ChaosDoorOpen", "ChaosDoorFloor" }, DestinationId = gate.ObjectId })
      SetAnimation({ DestinationId = gate.ObjectId, Name = "SecretDoor_Closed" })
    end)
    if not anim_ok then
      rom.log.warning("[AP] Nightmare Chaos Gate: closed-animation call failed (ObjectId="
        .. tostring(gate.ObjectId) .. "): " .. tostring(anim_err))
    end
    rom.log.info("[AP] Nightmare Chaos Gate: sealed (route not unlocked) -- closed and uninteractable")
  else
    -- Route is unlocked: a Nightmare run can be started from this gate, so clear the run-clear
    -- dedup guard here (the pre-run hub is the reliable "a new run is about to begin" beat --
    -- the old StartHadesRun wrap used to own this reset but never actually fired). See
    -- handle_nightmare_run_cleared.
    ItemManager.nightmare_run_clear_handled = false
    if gate.ArchipelagoNightmareLocked then
      gate.OnUsedFunctionName = gate.ArchipelagoNightmareOrigOnUsed
      gate.UseText = gate.ArchipelagoNightmareOrigUseText
      gate.ArchipelagoNightmareLocked = nil
      -- ZJ's revealed-gate animation (same one its own unlock branch uses).
      local anim_ok, anim_err = pcall(function()
        SetAnimation({ DestinationId = gate.ObjectId, Name = "ModsNikkelMHadesBiomes_SecretDoor_Revealed" })
      end)
      if not anim_ok then
        rom.log.warning("[AP] Nightmare Chaos Gate: reopen-animation call failed (ObjectId="
          .. tostring(gate.ObjectId) .. "): " .. tostring(anim_err))
      end
      rom.log.info("[AP] Nightmare Chaos Gate: reopened (route access granted)")
    end
  end
end

-- The Cauldron (GhostAdmin, DeathLoopData.lua id 558175) is disabled for the whole seed (see the
-- UseGhostAdmin/HandleGhostAdminPurchase wraps below). Vanilla already has a proper "not open yet"
-- presentation for it -- the SetupEvents entry "SetupCauldronLocked" (lid overlay obstacle +
-- locked interact prompt/voice line) -- but the engine only applies it while
-- GameState.CompletedRunsCache <= 0 (before your first completed run). Rather than leave the
-- object looking normal while our UseGhostAdmin wrap silently eats the interaction, force that
-- vanilla presentation permanently by re-invoking it ourselves on every spawn, regardless of
-- CompletedRunsCache. Same "reapply the vanilla locked look every spawn" approach as
-- update_nightmare_gate above.
function ItemManager.apply_cauldron_locked_visual(obstacle)
  if type(obstacle) ~= "table" then return end
  -- Match on both: ObjectId 558175 is the Cauldron's fixed persistent id in the Crossroads hub
  -- (DeathLoopData.lua), Name is the same entry's "GhostAdmin" field. Either is sufficient; check
  -- both in case one isn't copied onto the live obstacle table for some reason.
  if obstacle.ObjectId ~= 558175 and obstacle.Name ~= "GhostAdmin" then return end
  if type(SetupCauldronLocked) ~= "function" then return end
  pcall(function()
    SetupCauldronLocked(obstacle, {
      UseText = "UseGhostAdmin_Locked",
      UseSound = "/SFX/LavaBubbleBurst",
      OnUsedFunctionName = "UseLockedSystemObjectPresentation",
      OnUsedFunctionArgs = { VoiceLines = "LockedCauldronVoiceLines" },
    })
  end)
  rom.log.info("[AP] Cauldron: forced vanilla 'locked' presentation (lid + no-purchase voice lines)")
end

-- Scan-based application: walks the live obstacles looking for the gate. Kept for the room-hook /
-- boot reasserts and the post-repaint re-seal; the spawn moment itself is covered by the
-- SetupObstacle wrap (reload.lua), which hands the gate table to update_nightmare_gate directly.
function ItemManager.apply_nightmare_gate_lock()
  if not ItemManager.nightmare_mod() then return end
  local map = game.MapState
  if not (map and map.ActiveObstacles) then return end
  for _, gate in pairs(map.ActiveObstacles) do
    -- ModsNikkelMHadesBiomesIsRunStartDoor is set only on the Chaos Gate (DeathLoopData.lua) --
    -- a clean, unique marker for the run-start door among all the hub's obstacles.
    ItemManager.update_nightmare_gate(gate)
  end
end

-- Second, independent detection path for Nightmare's run-clear -- wraps the mod's own custom
-- run-clear function directly (see handle_nightmare_run_cleared for why both paths exist).
-- Idempotent one-time install, retried from the render loop while pending (retry_nightmare_mod_hooks).
function ItemManager.install_nightmare_run_clear_hook()
  if ItemManager.nightmare_run_clear_hook_installed then return end
  local zj = ItemManager.nightmare_mod()
  local fn_name = "ModsNikkelMHadesBiomesOpenRunClearScreen"
  if not (zj and zj[fn_name]) then
    if not ItemManager.nightmare_run_clear_hook_logged_missing then
      rom.log.info("[AP] Nightmare: mod not present/valid yet -- custom run-clear hook not installed, will retry")
      ItemManager.nightmare_run_clear_hook_logged_missing = true
    end
    return
  end
  pcall(function()
    zj[fn_name] = modutil.mod.Wrap(zj[fn_name], function(base, ...)
      pcall(function() ItemManager.handle_nightmare_run_cleared() end)
      return base(...)
    end)
  end)
  ItemManager.nightmare_run_clear_hook_installed = true
  rom.log.info("[AP] Nightmare: custom run-clear hook installed")
end

-- Called every ~0.5s from the render-loop driver (reload.lua). The Chaos Gate lock is no longer
-- a one-time install (it's applied per-room via apply_nightmare_gate_lock, which needs the live
-- gate obstacle); only the run-clear hook still installs once, so retry just that while it's
-- pending so a slow/delayed Zagreus' Journey install can't strand it uninstalled.
function ItemManager.retry_nightmare_mod_hooks()
  if not ItemManager.nightmare_run_clear_hook_installed then
    ItemManager.install_nightmare_run_clear_hook()
  end
  ItemManager.install_hades_exit_redirect()
end

-- Per user request 2026-07-19: after beating Hades, Zagreus' Journey's own D_Boss01 exit door
-- (its "FinalBossExitDoor") doesn't return you to the Crossroads -- on your first-ever clear it
-- forces you onward into ZJ's own "proceed to the Surface" epilogue (the Zagreus-and-Persephone
-- reunion content, reusing the base game's own E-lettered room/text namespace), and only drops
-- into a quick early-access screen on LATER clears. The user wants neither: every time, exiting
-- that door should just send Melinoe home exactly the way Chronos'/Typhon's own routes end.
--
-- Room.ExitFunctionName is a plain string key CallFunctionName resolves via _G[name] (confirmed
-- against EventLogic.lua's CallFunctionName -- it does a flat _G lookup, no dotted-path
-- resolution; ZJ's own "<guid>.<FuncName>" strings work because ModUtil registers each mod
-- function under that literal flat string). Overwriting the string on game.RoomData.D_Boss01
-- (confirmed reliably present -- same global table the boot HEALTH check already reads) sidesteps
-- needing rom.mods["NikkelM-Zagreus_Journey"] altogether, which was confirmed (2026-07-19 live
-- log) to silently fail to resolve for an entire session even while this exact room data loaded
-- and played fine -- see install_nightmare_run_clear_hook's own struggles with that same lookup.
function AP_Hades2Rogue_HadesReturnToCrossroads(currentRun, door, args)
  ItemManager.won_run_pending = true
  -- The same KillHero entry point every route's own ending funnels through (DeathLoopLogic.lua
  -- branches on CurrentRun.Cleared for the win case) -- ZJ's HadesKillPresentation already called
  -- RecordRunCleared/ModsNikkelMHadesBiomesOpenRunClearScreen when Hades died, so Cleared is
  -- already set by the time the player reaches this door.
  game.KillHero(currentRun.Hero, {})
end

function ItemManager.install_hades_exit_redirect()
  if ItemManager.hades_exit_redirect_installed then return end
  if not ItemManager.route_active("Nightmare") then return end
  local room = game.RoomData and game.RoomData.D_Boss01
  if not room then return end
  room.ExitFunctionName = "AP_Hades2Rogue_HadesReturnToCrossroads"
  ItemManager.hades_exit_redirect_installed = true
  rom.log.info("[AP] Nightmare: Hades exit door redirected straight to the Crossroads (Surface epilogue skipped)")
end

-- Whether the weapon currently equipped is one the player has AP-unlocked (Test Run 8 #1). Gates
-- per_weapon room checks so e.g. "Staff Underworld Room 1" can't fire while the forced intro has
-- Melinoe holding the (not-yet-unlocked) Staff. Returns true when it can't tell (no GameState), so
-- a normal run -- where enforce_equipped_weapon already guarantees an unlocked weapon -- is unaffected.
function ItemManager.equipped_weapon_unlocked()
  local short = ItemManager.current_weapon_short()
  if not short then return false end
  local kit = ItemManager.SHORT_TO_WEAPON_KIT[short]
  local wu = game.GameState and game.GameState.WeaponsUnlocked
  if not (kit and wu) then return true end               -- can't tell: don't over-block
  return wu[kit] == true
end

-- separate_checks=combine_pools is only in effect when BOTH routes are generated (with one
-- route there's nothing to combine, matching the Python world's combine_active()).
-- separate_checks=combine_pools only does anything when 2+ routes are actually active this
-- seed (with a single route there's nothing to combine), matching the Python world's
-- combine_active().
function ItemManager.combine_active()
  if ItemManager.settings.separate_checks ~= "1" then return false end
  local n = 0
  for _, route in ipairs({ "Underworld", "Surface", "Nightmare" }) do
    if ItemManager.route_active(route) then n = n + 1 end
  end
  return n > 1
end

-- Location auto-scaling: how many checks ("slots") each cleared room depth grants in the
-- room-based systems. When a seed has more items than rooms, the generator can't just raise
-- the room count (a run is only ~50 rooms), so each depth instead yields `location_multiplier`
-- checks -- slot 0 keeps the bare name, slots 1..m-1 append " +k" (see Locations._room_name).
-- Sent in slot_data as location_multiplier; defaults to 1 (older seeds / point_based, which
-- scales via score_rewards_amount instead). Clamped to >=1 so a missing/0 value never sends
-- nothing. The mod must emit ALL m slot checks per depth, else the "+k" locations never fill.
function ItemManager.location_multiplier()
  return math.max(1, tonumber(ItemManager.settings.location_multiplier) or 1)
end

-- point_based: how many score checks a score pool holds -- always the full
-- score_rewards_amount, whichever pool is asked about. split_pools gives each route its own
-- full-size pool; combine_pools has ONE shared full-size pool (Routes.COMBINED_SCORE_KEY) that
-- every route banks into, so the total is shared rather than divided (matches the Python
-- Locations._score_count_for / _combined_score_count).
function ItemManager.score_limit_for(_pool)
  return tonumber(ItemManager.settings.score_rewards_amount) or 0
end

-- point_based: the set of score checks the server ALREADY has (a finished player's
-- auto-released/collected checks, an admin !send_location, fresh-save recovery).
-- The client re-pushes this via CHECKEDSCORE on every connect/HELLO and whenever
-- checked_locations changes (RoomUpdate), so it is deliberately RUNTIME-ONLY (NOT persisted
-- to the save). Earning one of these advances next_check for FREE (no score spent, no CHECK
-- re-sent). Keyed pool -> { [number] = true }: a route name (split_pools) or
-- Routes.COMBINED_SCORE_KEY (combine_pools' shared "Score N" pool).
ItemManager.checked_score = ItemManager.checked_score
  or { Underworld = {}, Surface = {}, Nightmare = {}, Combined = {} }

-- Is point_based score check `n` in pool `pool` already checked on the server?
function ItemManager.is_score_checked(pool, n)
  local set = ItemManager.checked_score[pool]
  return set ~= nil and set[n] == true
end

-- ---- Granting items ---------------------------------------------------------

local function grant_currency(filler_name, amount)
  amount = tonumber(amount) or 0
  if amount <= 0 then return end
  local key = RESOURCE_KEYS[filler_name]
  if not key then return end
  -- game.AddResource(name, amount, source, args) is the confirmed grant API.
  pcall(function()
    game.AddResource(key, amount, "Archipelago", { Silent = false })
  end)
  rom.log.info("[AP] grant " .. key .. " x" .. amount)
end

-- Unlocks weapon kit `weapon_id` in-game and remembers that AP did it, so
-- apply_initial_weapon won't re-lock it on the next SETTINGS (the Staff is the only kit
-- it force-locks; this keeps a Staff unlock from being clobbered after a restart --
-- Test Run 8 #4). Shared by every path that can grant weapon access: the standalone
-- unlock item, progressive/combine, per_aspect, and the randomized-mode cascade.
local function mark_weapon_unlocked(weapon_id)
  pcall(function()
    if game.GameState and game.GameState.WeaponsUnlocked then
      game.GameState.WeaponsUnlocked[weapon_id] = true
    end
  end)
  local s = APState.get()
  if s then s.weapon_ap_unlocked[weapon_id] = true end
  -- AssignWeaponKits (Hub load) spawns every weapon's rack up front but leaves
  -- locked ones invisible/UseableOff; it doesn't re-run mid-visit. UpdateWeaponKits
  -- is the vanilla live-refresh -- re-toggles each already-spawned kit's visibility/
  -- interactability off the CURRENT WeaponsUnlocked state, so a rack that unlocks
  -- while you're already standing in the Hub shows up immediately instead of only
  -- after the next Hub load. Idempotent (safe if MapState.WeaponKits is nil/unset).
  pcall(function()
    if UpdateWeaponKits then UpdateWeaponKits() end
  end)
  -- UpdateWeaponKits alone isn't enough for a kit that spawned LOCKED this Hub visit:
  -- AssignWeaponKits is the ONLY place that sets weaponKit.OnUsedFunctionName =
  -- "UseWeaponKit" (only on its "Unlocked" branch, at Hub-load time), and
  -- UpdateWeaponKits never touches that field -- it only re-fades alpha/toggles
  -- Useable. So a kit unlocked mid-visit gets faded in and made "Useable" but its
  -- interact prompt calls nothing, until the player leaves and re-enters the Hub
  -- (AssignWeaponKits re-runs and finally sets it). Set it directly here so the rack
  -- responds to interaction immediately, matching the visual live-refresh above.
  pcall(function()
    local kits = game.MapState and game.MapState.WeaponKits
    if not kits then return end
    for _, weaponKit in pairs(kits) do
      if weaponKit.Name == weapon_id and weaponKit.OnUsedFunctionName == nil then
        weaponKit.OnUsedFunctionName = "UseWeaponKit"
      end
    end
  end)
end

local function unlock_weapon(item_name)
  local weapon_id = WEAPON_ITEM_TO_ID[item_name]
  if not weapon_id then return end
  mark_weapon_unlocked(weapon_id)
  rom.log.info("[AP] unlock weapon: " .. weapon_id)
end

local function grant_grasp()
  -- Track how many Progressive Grasp we've received; GetMaxMetaUpgradeCost is
  -- wrapped (reload.lua) to return grasp_count * grasp_intervals, so we just bump the
  -- count here.
  local s = APState.get()
  if not s then return end
  s.grasp_count = (s.grasp_count or 0) + 1
  rom.log.info("[AP] grasp +1 (now " .. s.grasp_count .. ")")
end

-- Unlock or upgrade an arcana card. Arcana mode ("1") has exactly one item per
-- card, so unlocking grants max level immediately. Progressive_Arcana mode ("2")
-- gets multiple items per card: first unlocks at Level 1, each subsequent one
-- raises its Level toward the card's max.
local function apply_arcana(title)
  local card_id = ARCANA_TITLE_TO_ID[title]
  if not card_id then return end
  pcall(function()
    local state = game.GameState and game.GameState.MetaUpgradeState
    local data = game.MetaUpgradeCardData
    if not state or not data or not data[card_id] then return end
    local card = state[card_id]
    if not card then card = {}; state[card_id] = card end
    local max_level = #data[card_id].UpgradeResourceCost + 1
    if not card.Unlocked then
      card.Unlocked = true
      card.Level = (ItemManager.settings.arcanasanity == "1") and max_level or 1
    else
      card.Level = math.min((card.Level or 1) + 1, max_level)
    end
    rom.log.info("[AP] arcana " .. card_id .. " -> level " .. card.Level)
  end)
end

-- reverse_vow: set every vow in GameState.ShrineUpgrades to its effective level,
-- i.e. the configured starting level minus the removals received so far.
-- With reverse_vow OFF, the apworld already zeroes every vow_* option (see
-- _normalize_route_options), so "configured" below is 0 for all vows -- this still
-- has to RUN (not early-return) so it force-clears any nonzero ShrineUpgrades left
-- over from vanilla play or a prior reverse_vow=on save/seed on the same file.
function ItemManager.apply_all_vows(quiet)
  if not ItemManager.have_settings() then return end
  local reverse_on = ItemManager.setting_on("reverse_vow")
  local s = APState.get()
  if not s then return end
  pcall(function()
    local gs = game.GameState
    if not gs then return end
    gs.ShrineUpgrades = gs.ShrineUpgrades or {}
    local parts = {}
    for vow, internal in pairs(VOW_NAME_TO_ID) do
      local configured = reverse_on and (tonumber(ItemManager.settings["vow_" .. vow:lower()]) or 0) or 0
      local removed = s.vow_removals[vow] or 0
      local effective = math.max(0, configured - removed)
      gs.ShrineUpgrades[internal] = effective
      -- Setting the level isn't enough; the game extracts each vow's effect
      -- magnitude (ChangeValue) from its rank data, exactly as the Oath UI does.
      pcall(function() game.ShrineUpgradeExtractValues(internal) end)
      -- MID-RUN removal (Test Run 9 #4/#5): "remove the vow for the run I'm in NOW".
      -- Writing GameState.ShrineUpgrades above only reaches vows that read it live (through
      -- GetNumShrineUpgrades / GetShrineUpgradeChangeValue). Two other paths need help, or the
      -- player feels nothing until the next run -- which read as "vow removal isn't working":
      --   1. CurrentRun.ShrineUpgradesCache is a per-run snapshot the game deep-copies from
      --      GameState.ShrineUpgrades at RunStart (RunLogic.lua:1957). Cache-reading vows
      --      (e.g. Rivals/BossDifficulty) never see our write unless we sync the snapshot.
      --   2. Some vows apply a PERSISTENT effect that must be actively undone when fully
      --      removed: Pain reserves an incoming-damage modifier on the Hero, Hubris reserves
      --      mana. The game's own mid-run remover (CirceRemoveShrineUpgrades, EventLogic.lua:1399)
      --      handles this by setting CurrentRun.ShrineUpgradesDisabled and calling the vow's
      --      OnDisabledFunctionName. We mirror that here for any vow reaching effective 0.
      -- Time keeps its own bespoke block below (timer re-arm logic), so it's excluded here.
      if vow ~= "Time" then
        pcall(function()
          if not game.CurrentRun then return end
          game.CurrentRun.ShrineUpgradesDisabled = game.CurrentRun.ShrineUpgradesDisabled or {}
          if game.CurrentRun.ShrineUpgradesCache then
            game.CurrentRun.ShrineUpgradesCache[internal] = effective
          end
          if configured > 0 and effective == 0 then
            game.CurrentRun.ShrineUpgradesDisabled[internal] = true
            -- Undo the vow's persistent effect immediately, exactly like Circe does. The handlers
            -- (RemoveEnemyDamageShrineUpgrade / RemoveBoonManaReserve) are idempotent, so the
            -- per-room re-assert this runs in is harmless.
            local data = game.MetaUpgradeData and game.MetaUpgradeData[internal]
            if data and data.OnDisabledFunctionName and game.CallFunctionName then
              game.CallFunctionName(data.OnDisabledFunctionName)
            end
            if not quiet then
              rom.log.info("[AP] vow " .. vow .. " fully removed mid-run (disabled "
                .. internal .. (data and data.OnDisabledFunctionName
                  and ", ran " .. data.OnDisabledFunctionName or "") .. ")")
            end
          else
            -- Still (partially) active: clear any disable so the reduced rank is honored.
            game.CurrentRun.ShrineUpgradesDisabled[internal] = nil
          end
        end)
      end
      -- Vow of Time (BiomeSpeedShrineUpgrade) timer control (Test Run 5 #16/#17, Test Run 6 #3).
      -- The game arms the timer at run start via ActiveBiomeTimer = GetNumShrineUpgrades > 0
      -- (RunLogic.lua:488) and then CONTINUOUSLY force-disables it whenever
      -- ShrineUpgradesDisabled["BiomeSpeedShrineUpgrade"] is set (PatchLogic.lua:1328). So:
      --   * Only set the disabled flag when the vow is GENUINELY, FULLY removed
      --     (configured > 0 and effective == 0). The old code's bare `effective == 0` also
      --     fired for a vow that isn't in the seed (configured 0) or before settings landed --
      --     a single such tick latched the timer off for the whole run, so it "showed up for a
      --     second then disappeared" even with Vow of Time on (Test Run 6 #3).
      --   * While the vow is still active (effective > 0), make sure nothing keeps it disabled:
      --     clear the flag AND re-arm ActiveBiomeTimer (the game's PatchLogic may already have
      --     flipped it off). Only re-arm inside a real biome room (Routes.current() ~= nil) and
      --     while alive, so we never fight the game's legitimate disables in the hub, on death,
      --     or during bounty/dream/cutscene presentations.
      if vow == "Time" then
        pcall(function()
          if not game.CurrentRun then return end
          game.CurrentRun.ShrineUpgradesDisabled = game.CurrentRun.ShrineUpgradesDisabled or {}
          if configured > 0 and effective == 0 then
            game.CurrentRun.ShrineUpgradesDisabled[internal] = true
            game.CurrentRun.ActiveBiomeTimer = false
          elseif effective > 0 then
            game.CurrentRun.ShrineUpgradesDisabled[internal] = nil
            local in_biome = Routes and Routes.current and Routes.current() ~= nil
            local alive = not (game.CurrentRun.Hero and game.CurrentRun.Hero.IsDead)
            if in_biome and alive then
              game.CurrentRun.ActiveBiomeTimer = true
            end
          end
          if not quiet then
            rom.log.info("[AP] vow Time: configured=" .. configured .. " removed=" .. removed
              .. " effective=" .. effective
              .. " ActiveBiomeTimer=" .. tostring(game.CurrentRun.ActiveBiomeTimer)
              .. " disabled=" .. tostring(game.CurrentRun.ShrineUpgradesDisabled[internal]))
          end
        end)
      end
      -- Diagnostic: for any vow that's configured or has been removed, report the full picture
      -- so a single log line proves whether removal actually landed -- configured (starting
      -- level from settings), removed (items received), effective (what we wrote to GameState),
      -- the live rank the game now reads, and the magnitude combat consumes
      -- (MetaUpgradeData[id].ChangeValue, e.g. RoomLogic enemy-health multiplier). If removal is
      -- "doing nothing", this line tells us which link is stale (settings vs removed vs ChangeValue).
      if configured > 0 or removed > 0 then
        local live_rank, change = "?", "?"
        pcall(function()
          if game.GetNumShrineUpgrades then live_rank = tostring(game.GetNumShrineUpgrades(internal)) end
          local md = game.MetaUpgradeData and game.MetaUpgradeData[internal]
          if md and md.ChangeValue ~= nil then change = tostring(md.ChangeValue) end
        end)
        parts[#parts + 1] = string.format("%s(cfg=%d rm=%d eff=%d rank=%s mag=%s)",
          vow, configured, removed, effective, live_rank, change)
      end
    end
    -- Refresh the cached "Fear" total that every UI reads (Test Run 10 #7). The displayed skull
    -- count is NOT computed live from GameState.ShrineUpgrades -- it's cached in
    -- GameState.SpentShrinePointsCache, which the game only rebuilds (via GetTotalSpentShrinePoints)
    -- on its own rank-up/down paths (ShrineLogic.lua:455/478) and patch migration. We edit
    -- ShrineUpgrades directly, bypassing all of those, so the in-run HUD trait-tray skull count
    -- (bound to GameState.SpentShrinePointsCache, TraitTrayData.lua) and the Oath altar skull-quest
    -- text (ShrineLogic.lua:902/910) stayed frozen at the run-start total -- the player never saw
    -- removals tick down. Recompute it from the freshly written ranks using the game's own function.
    pcall(function()
      if game.GetTotalSpentShrinePoints then
        local total = game.GetTotalSpentShrinePoints()
        game.GameState.SpentShrinePointsCache = total
        -- Per-run snapshot (RunLogic.lua:1956) used for this run's HUD + clear records. Keep it in
        -- step so the count drops as removals land and records credit the real (reduced) difficulty.
        if game.CurrentRun then
          game.CurrentRun.ShrinePointsCache = total
        end
        if not quiet then
          rom.log.info("[AP] vows: SpentShrinePointsCache refreshed -> " .. tostring(total))
        end
      end
    end)
    if not quiet then
      rom.log.info("[AP] vows: " .. (table.concat(parts, " ") ~= "" and table.concat(parts, " ") or "(none configured)"))
    end
  end)
end

local function apply_vow_removal(vow)
  if not VOW_NAME_TO_ID[vow] then
    rom.log.warning("[AP] vow removal IGNORED: unknown vow '" .. tostring(vow) .. "'")
    return
  end
  local s = APState.get()
  if not s then
    rom.log.warning("[AP] vow removal '" .. vow .. "' deferred: no save loaded (GameState nil)")
    return
  end
  s.vow_removals[vow] = (s.vow_removals[vow] or 0) + 1
  -- Surface the gate too: if reverse_vow isn't on, apply_all_vows treats every vow as
  -- configured=0 regardless of this removal count, so the removal has no visible effect --
  -- log that explicitly.
  rom.log.info("[AP] vow removal: " .. vow .. " (x" .. s.vow_removals[vow]
    .. ") reverse_vow=" .. tostring(ItemManager.setting_on("reverse_vow"))
    .. " vow_setting=" .. tostring(ItemManager.settings["vow_" .. vow:lower()]))
  ItemManager.apply_all_vows()
end

-- Open the Surface route by adding the "alt run door" world upgrade (what the
-- Witching-Wards incantation normally does). The forcing flag tells the
-- AddWorldUpgrade hook this is OUR unlock, not the player crafting it.
-- Force-add a world upgrade as OUR unlock (not the player crafting it). Sets the
-- persistent ownership flags directly -- GameState.WorldUpgrades[name] is the real
-- "owned" flag (GhostAdminLogic.AddWorldUpgrade line 553), and it lives in the save, so
-- the unlock survives across runs (fixes "surface not open on the second run"). We also
-- run the game's AddWorldUpgrade for its side effects, but never depend on it alone.
local function force_world_upgrade(name)
  ItemManager.forcing_surface = true
  pcall(function()
    local gs = game.GameState
    if gs then
      gs.WorldUpgrades = gs.WorldUpgrades or {}
      gs.WorldUpgradesAdded = gs.WorldUpgradesAdded or {}
      gs.WorldUpgradesViewed = gs.WorldUpgradesViewed or {}
      gs.WorldUpgradesRevealed = gs.WorldUpgradesRevealed or {}
      gs.WorldUpgrades[name] = true          -- current ownership (the flag the game reads)
      gs.WorldUpgradesAdded[name] = true      -- record of ever being added
      gs.WorldUpgradesViewed[name] = true     -- silences AddWorldUpgrade's debug assert
      gs.WorldUpgradesRevealed[name] = true
    end
    if game.CurrentRun then
      game.CurrentRun.WorldUpgradesAdded = game.CurrentRun.WorldUpgradesAdded or {}
      game.CurrentRun.WorldUpgradesAdded[name] = true
    end
    if game.AddWorldUpgrade then
      pcall(function() game.AddWorldUpgrade(name, { SkipQuestStatusCheck = true }) end)
    end
  end)
  ItemManager.forcing_surface = false
end

local function grant_surface_access()
  force_world_upgrade("WorldUpgradeAltRunDoor")
  rom.log.info("[AP] Surface Access -> surface door opened")
end

-- The surface curse is the "SurfacePenalty" trait, added on the first surface room only when
-- the cure World Upgrade is absent (EncounterData_Opening). Its StartSurfaceHealthPenalty setup
-- spawns a damage coroutine (MetaUpgrades.SurfaceHealthPenalty) that ticks every ~5s for the
-- rest of the run: the loop only stops on hero death and never re-checks the cure flag. So the
-- world-upgrade flag set above stops the curse for FUTURE rooms/runs but NOT the thread already
-- running this run. Clear it mid-run so receiving the cure feels immediate.
--
-- The coroutine is untagged (can't be killed by tag), but it closed over this trait instance's
-- SetupFunction.Args (a deep copy per TraitLogic.AddTraitToUnit, so safe to mutate) and reads
-- CurrentRun.SurfacePenaltyCumulativeDamage. Zero the damage and stretch the interval so it
-- deals 0 and effectively never wakes again, then drop the trait (clears the HUD icon + trait
-- dictionary). One harmless 0-damage tick may still fire from the wait already in flight (<=5s),
-- after which the thread sleeps for the rest of the session.
local function clear_active_surface_penalty()
  local run = game.CurrentRun
  local hero = run and run.Hero
  if not (hero and hero.Traits) then return end
  local had = false
  for _, trait in pairs(hero.Traits) do
    if trait and trait.Name == "SurfacePenalty" then
      had = true
      local sf = trait.SetupFunction
      if sf and sf.Args then
        sf.Args.Damage = 0
        sf.Args.DamageIncrementPerTick = nil
        sf.Args.Interval = 1e9
      end
    end
  end
  if not had then return end
  run.SurfacePenaltyCumulativeDamage = 0
  -- Remove every instance (RunOnce makes duplicates unlikely, but be defensive).
  local guard = 0
  while game.HeroHasTrait and game.HeroHasTrait("SurfacePenalty") and guard < 8 do
    guard = guard + 1
    pcall(function() game.RemoveTrait(hero, "SurfacePenalty") end)
  end
  rom.log.info("[AP] Surface Penalty Cure -> active surface curse cleared mid-run")
end

local function grant_penalty_cure()
  force_world_upgrade("WorldUpgradeSurfacePenaltyCure")
  clear_active_surface_penalty()
  rom.log.info("[AP] Surface Penalty Cure -> surface damage removed")
end

-- Vanilla only ever grants the SurfacePenalty trait from ONE place in the whole game
-- (EncounterData_Opening.lua's OpeningGeneratedN, on N_Opening01's first combat encounter), and
-- that encounter is itself conditional: N_Opening01's LegalEncounters is {OpeningEmpty,
-- OpeningGeneratedN}, and OpeningEmpty is AlwaysForce=true whenever UseRecord.ApolloUpgrade is
-- still false (or it's a dream run) -- i.e. whenever the save hasn't met Apollo in the Underworld
-- yet. A surface_start seed routes the player to the Surface before they've ever set foot in the
-- Underworld, so ApolloUpgrade is false, OpeningEmpty gets forced instead of OpeningGeneratedN, and
-- the curse is silently never granted for that entire run -- confirmed in testing (no curse damage
-- despite no cure). Enforce it ourselves on every Surface room entry instead of depending on that
-- vanilla precondition: HeroHasTrait guards against re-adding once it's active, and it naturally
-- stops granting the moment the cure's World Upgrade is owned. Self-healing / idempotent, same
-- pattern as the other per-room reasserts.
function ItemManager.enforce_surface_curse()
  local route = Routes.current()
  if route ~= "Surface" then return end
  local gs = game.GameState
  if gs and gs.WorldUpgrades and gs.WorldUpgrades.WorldUpgradeSurfacePenaltyCure then return end
  if not (game.AddTraitToHero and game.HeroHasTrait and game.CurrentRun and game.CurrentRun.Hero) then
    return
  end
  if game.HeroHasTrait("SurfacePenalty") then return end
  pcall(function() game.AddTraitToHero({ TraitName = "SurfacePenalty" }) end)
  rom.log.info("[AP] Surface curse enforced (cure absent, vanilla's own grant hadn't fired)")
end

-- Nightmare has no vanilla world-upgrade to piggyback on for its Chaos Gate (the mod always
-- spawns it) -- so "access granted" is purely our own persistent flag, checked by the
-- Chaos Gate lock wrap (see ItemManager.nightmare_run_locked, installed in reload.lua).
function ItemManager.grant_nightmare_access()
  local s = APState.get()
  if not s then return end
  s.nightmare_access_granted = true
  rom.log.info("[AP] Nightmare Access -> Chaos Gate unlocked")
end

function ItemManager.nightmare_run_locked()
  if not ItemManager.route_active("Nightmare") then return true end
  local s = APState.get()
  return not (s and s.nightmare_access_granted)
end

-- Run-clear detection for Nightmare is genuinely uncertain which of two paths actually fires in
-- practice (see the design plan's compatibility notes): vanilla's OpenRunClearScreen (which
-- this mod also wraps, purely for cosmetic badges, so it may or may not call all the way
-- through) or the mod's own ModsNikkelMHadesBiomesOpenRunClearScreen reimplementation (called
-- directly from HadesKillPresentation). Rather than bet on one, both wraps (reload.lua) route
-- through this single guarded handler so whichever fires first "wins" and a second firing for
-- the same clear is a safe no-op -- reset when a new Nightmare run can start (the pre-run hub's
-- unlocked-gate branch of apply_nightmare_gate_lock).
function ItemManager.handle_nightmare_run_cleared()
  if ItemManager.nightmare_run_clear_handled then return end
  ItemManager.nightmare_run_clear_handled = true
  local weapon_id = game.GameState and game.GameState.PrimaryWeaponName or nil
  LocationManager.on_run_cleared("Nightmare", weapon_id)
  -- The scripted return-to-Crossroads after a win reads as a death (KillHero). The vanilla
  -- OpenRunClearScreen wrap (reload.lua) already arms this itself, but when a Nightmare win
  -- is instead detected via the OTHER path -- the mod's own
  -- ModsNikkelMHadesBiomesOpenRunClearScreen, wrapped directly by install_nightmare_run_clear_hook
  -- -- that second wrap only ever called this function and never armed the flag, so a Nightmare
  -- win whose clear was detected that way sent an unwanted DeathLink for its own ending. Arming it
  -- here (the single guarded chokepoint both paths funnel through) covers both regardless of
  -- which one actually fires first.
  ItemManager.won_run_pending = true
end

local function apply_route_progress(name)
  local route = "Underworld"
  if name == "Progressive Surface" then route = "Surface"
  elseif name == "Progressive Nightmare" then route = "Nightmare"
  end
  local s = APState.get()
  if not s then return end
  s.route_progress[route] = (s.route_progress[route] or 0) + 1
  rom.log.info("[AP] route progress: " .. route .. " (x" .. s.route_progress[route] .. ")")
  -- Progressive Surface/Nightmare now OPEN their door on the first copy, not just the locked
  -- zones (Test Run 5 #14, user choice "first one opens the door"; extended to Nightmare).
  -- grant_surface_access/grant_nightmare_access are idempotent, so calling every copy is
  -- harmless. The Underworld is open by default, so Progressive Underworld only needs to
  -- bump the zone-unlock counter.
  if route == "Surface" then
    grant_surface_access()
  elseif route == "Nightmare" then
    ItemManager.grant_nightmare_access()
  end
end

-- Familiar costumes are themselves WorldUpgrades (a cosmetic-shop purchase = AddWorldUpgrade).
-- "Alteration of Familiar Forms" grants the costume system AND every familiar costume, read
-- live from ScreenData.FamiliarCostumeShop.ItemCategories so it tracks game updates.
local function unlock_all_familiar_costumes()
  pcall(function()
    local shop = game.ScreenData and game.ScreenData.FamiliarCostumeShop
    local cats = shop and shop.ItemCategories
    if not cats then return end
    local count = 0
    for _, list in pairs(cats) do
      for _, costumeName in ipairs(list) do
        force_world_upgrade(costumeName)
        count = count + 1
      end
    end
    rom.log.info("[AP] unlocked " .. count .. " familiar costumes")
  end)
end

-- Grant one incantation's world-upgrade (plus any parent prereq, plus the familiar-costume
-- special case).
local function grant_incantation_id(internal)
  local prereqs = INCANTATION_PREREQS[internal]
  if prereqs then
    for _, p in ipairs(prereqs) do force_world_upgrade(p) end
  end
  force_world_upgrade(internal)
  if internal == "WorldUpgradeFamiliarCostumeSystem" then
    unlock_all_familiar_costumes()
  end
end

local function grant_incantation(name)
  local internal = INCANTATION_ITEM_TO_ID[name]
  if not internal then return end
  grant_incantation_id(internal)
  rom.log.info("[AP] incantation: " .. name .. " (" .. internal .. ")")
end

-- Auto-grant the start-with incantations once a save profile is loaded (called on SETTINGS).
-- Routes through grant_incantation_id (not a raw force_world_upgrade loop) so prereqs
-- (Path to Desired Blessings' WorldUpgradePinning) and the familiar-costume special case
-- (Alteration of Familiar Forms) still fire, same as when these were received as items.
function ItemManager.apply_incantation_starts()
  for _, internal in ipairs(INCANTATION_START_IDS) do
    grant_incantation_id(internal)
  end
  rom.log.info("[AP] incantation starts granted (" .. #INCANTATION_START_IDS .. ")")
end

-- Auto-grant the route-/mode-scoped incantations (July 19 cull) -- unlike
-- INCANTATION_START_IDS above these are only relevant to some seeds, so granting them
-- unconditionally would flip flags for content the seed may not even include. Same call site
-- as apply_incantation_starts (after SETTINGS, so route_active/setting_mode are current).
-- Idempotent (force_world_upgrade just re-sets the same flags), so safe to call every connect.
function ItemManager.apply_conditional_incantation_starts()
  if ItemManager.route_active("Underworld") then
    grant_incantation_id("WorldUpgradeBreakableValue1")       -- Propensity Toward Gold
    grant_incantation_id("WorldUpgradeTimeSlowChronosFight")  -- Temporal Fluctuation
    grant_incantation_id("WorldUpgradeFieldsRewardFinder")    -- Reviving a Mournful Husk
  end
  if ItemManager.route_active("Surface") then
    grant_incantation_id("WorldUpgradeOlympusStatues")        -- Rage of the Elements
    grant_incantation_id("WorldUpgradeEphyraZoomOut")         -- Summoning a Colony of Bats
  end
  if ItemManager.route_active("Nightmare") then
    grant_incantation_id("ModsNikkelMHadesBiomes_OrpheusUnlockItem")               -- Allow Orpheus to Spawn in Tartarus
    grant_incantation_id("ModsNikkelMHadesBiomes_UnlockMoonMonumentsIncantation")  -- Moon Monuments
    grant_incantation_id("ModsNikkelMHadesBiomes_UnlockShrinePointGatesIncantation") -- Erebus Gates
  end
  if ItemManager.setting_mode("keepsakesanity") ~= 2 then
    grant_incantation_id("WorldUpgradeDoubleAdvanceKeepsakes") -- Quickening of Sentimental Value
  end
  rom.log.info("[AP] conditional incantation starts granted")
end

-- ---- Combined incantations (July 20 simplification pass) ---------------------------------
-- Several same-shape incantations (one per zone/route/tier) were collapsed into a single
-- item each: receiving it grants EVERY one of its underlying WorldUpgrade flags relevant to
-- this seed's active routes, all at once (not a multi-copy progressive item -- each of these
-- is a single item in the pool, see Items.py's combined_incantation_counts).

local function combined_stygian_wells_ids()
  local ids = { "WorldUpgradeWellShops", "WorldUpgradePostBossWellShops" }
  if ItemManager.route_active("Nightmare") then
    table.insert(ids, "ModsNikkelMHadesBiomes_UnlockInRunWellShopsIncantation")
    table.insert(ids, "ModsNikkelMHadesBiomes_UnlockPostBossWellShopsIncantation")
  end
  return ids
end

local function combined_lifespring_ids()
  local ids = {}
  if ItemManager.route_active("Underworld") then
    table.insert(ids, "WorldUpgradeErebusReprieve")
    table.insert(ids, "WorldUpgradeOceanusReprieve")
    table.insert(ids, "WorldUpgradeTartarusReprieve")
  end
  if ItemManager.route_active("Surface") then
    table.insert(ids, "WorldUpgradeThessalyReprieve")
    table.insert(ids, "WorldUpgradeOlympusReprieve")
  end
  if ItemManager.route_active("Nightmare") then
    table.insert(ids, "ModsNikkelMHadesBiomes_UnlockTartarusReprieveIncantation")
    table.insert(ids, "ModsNikkelMHadesBiomes_UnlockAsphodelReprieveIncantation")
    table.insert(ids, "ModsNikkelMHadesBiomes_UnlockElysiumReprieveIncantation")
  end
  return ids
end

local function combined_desecrating_pools_ids()
  local ids = {}
  if ItemManager.route_active("Underworld") then
    table.insert(ids, "WorldUpgradeRestoreSellTraitShop")
    table.insert(ids, "WorldUpgradePostBossSellTraitShops")
  end
  if ItemManager.route_active("Nightmare") then
    table.insert(ids, "ModsNikkelMHadesBiomes_UnlockInRunSellShopsIncantation")
    table.insert(ids, "ModsNikkelMHadesBiomes_UnlockPostBossSellShopsIncantation")
  end
  return ids
end

local function combined_shrine_of_hermes_ids()
  if ItemManager.route_active("Surface") then
    return { "WorldUpgradeSurfaceShops", "WorldUpgradePostBossSurfaceShops" }
  end
  return {}
end

local function combined_troves_ids()
  local ids = {}
  if ItemManager.route_active("Underworld") then table.insert(ids, "WorldUpgradeChallengeSwitches1") end
  if ItemManager.route_active("Surface") then table.insert(ids, "WorldUpgradeChallengeSwitchesSurface1") end
  if ItemManager.route_active("Nightmare") then
    table.insert(ids, "ModsNikkelMHadesBiomes_UnlockInfernalTrovesIncantation")
  end
  return ids
end

local function combined_keepsake_rack_ids()
  local ids = { "WorldUpgradePostBossGiftRack" }
  if ItemManager.route_active("Nightmare") then
    table.insert(ids, "ModsNikkelMHadesBiomes_UnlockPostBossGiftRackIncantation")
  end
  return ids
end

local function combined_gold_urns_ids()
  if ItemManager.route_active("Nightmare") then
    return {
      "ModsNikkelMHadesBiomes_BreakableValue1Incantation",
      "ModsNikkelMHadesBiomes_BreakableValue2Incantation",
      "ModsNikkelMHadesBiomes_BreakableValue3Incantation",
    }
  end
  return {}
end

-- Grants every flag in `ids` in one shot (grant_incantation_id per entry -- idempotent, so
-- harmless if this somehow fires more than once for the same item).
local function grant_combined_incantation(ids, display_name)
  for _, internal in ipairs(ids) do
    grant_incantation_id(internal)
  end
  rom.log.info("[AP] " .. display_name .. " -> granted " .. #ids .. " unlock(s)")
end

-- ---- aspectsanity ----------------------------------------------------------

-- Unlock one Aspect at rank 1. HasAnyAspectUnlocked gates on WorldUpgradesAdded; the
-- shop also flags WeaponsUnlocked[id], so set both.
local function unlock_aspect_id(internal)
  pcall(function()
    if game.GameState and game.GameState.WeaponsUnlocked then
      game.GameState.WeaponsUnlocked[internal] = true
    end
  end)
  force_world_upgrade(internal)
end

-- Best-effort: re-apply the CURRENTLY equipped Aspect at its new rank mid-run, so a rank
-- bump received during a run takes effect immediately instead of only on the next equip.
-- The game scales an aspect trait by its rank only at equip time (EquipWeaponUpgrade reads
-- GetWeaponUpgradeLevel -> Rarity); we mirror that by removing the live aspect trait and
-- letting EquipWeaponUpgrade re-add it at the new rank. Only fires when the equipped aspect
-- is one of `ids` (so we never needlessly re-equip an unrelated weapon's aspect), and only
-- inside a live run. Fully pcall-guarded -- if any game function is missing it silently
-- falls back to the old behavior (applies on next equip).
local function refresh_equipped_aspect(ids)
  if not (game.CurrentRun and game.CurrentRun.Hero) then return end
  pcall(function()
    local weapon = game.GetEquippedWeapon and game.GetEquippedWeapon()
    if not weapon then return end
    local lwun = game.GameState and game.GameState.LastWeaponUpgradeName
    local traitName = lwun and lwun[weapon]
    if not traitName then return end
    -- Only refresh if the equipped aspect is one we just re-ranked.
    local match = false
    for _, id in ipairs(ids) do if id == traitName then match = true break end end
    if not match then return end
    if game.HeroHasTrait and game.HeroHasTrait(traitName) and game.RemoveTrait then
      game.RemoveTrait(game.CurrentRun.Hero, traitName)
    end
    if game.EquipWeaponUpgrade then
      game.EquipWeaponUpgrade(game.CurrentRun.Hero,
        { SkipNewTraitHighlight = true, SkipUIUpdate = true, SkipQuestStatusCheck = true })
    end
    local lvl = game.GetWeaponUpgradeLevel and game.GetWeaponUpgradeLevel(traitName)
    rom.log.info("[AP]   refreshed equipped aspect " .. tostring(traitName)
      .. " mid-run -> level " .. tostring(lvl))
  end)
end

-- Raise the given Aspects to rank `n` by setting <aspect>2..<aspect>n in
-- GameState.WeaponsUnlocked. GetWeaponUpgradeLevel(aspect) counts exactly those keys
-- (WeaponShopData entries DaggerBlockAspect2.. have TraitUpgrade=DaggerBlockAspect), so this
-- is what the shop's "buy upgrade" does. `ids` includes the weapon's DEFAULT Aspect of Melinoe
-- (so the equipped default actually levels). An Aspect's rank is read when EQUIPPED, so for an
-- aspect that is NOT currently equipped the bump applies on the next equip/run; for the
-- currently equipped one we additionally refresh it live via refresh_equipped_aspect.
-- Logs the readback level for verification.
local function set_aspect_ranks(ids, n)
  pcall(function()
    local wu = game.GameState and game.GameState.WeaponsUnlocked
    if not wu then return end
    for _, internal in ipairs(ids) do
      for rank = 2, math.min(n, ASPECT_MAX_RANK) do wu[internal .. rank] = true end
    end
  end)
  -- Read the game's own level back so the log shows whether the rank actually registered.
  pcall(function()
    if game.GetWeaponUpgradeLevel and ids[1] then
      rom.log.info("[AP]   aspect " .. ids[1] .. " GetWeaponUpgradeLevel="
        .. tostring(game.GetWeaponUpgradeLevel(ids[1])) .. " (applies on next equip)")
    end
  end)
  -- Make the bump take effect immediately on the equipped aspect (if it's one of these).
  refresh_equipped_aspect(ids)
end

-- randomized (aspectsanity=1): one item per Aspect, for all 24 of them -- the 18 alternates
-- (ASPECT_ITEM_TO_ID) and the 6 default Aspects of Melinoe (ASPECT_BASE_ITEM_TO_ID), which this
-- mode doesn't hand out for free (apply_aspect_base_lock). Receiving the item unlocks that Aspect
-- at MAX rank: ranks aren't buyable in this mode (reload.lua blocks the Cauldron's <aspect>2..5
-- purchases), so the item is the ONLY way to level an Aspect. The seed's starting Aspect is the
-- one exception -- apply_starting_aspect seeds it at rank 1, and its item stays in the pool as
-- the way to take it the rest of the way up.
local function unlock_aspect(title)
  local internal = ASPECT_ITEM_TO_ID[title] or ASPECT_BASE_ITEM_TO_ID[title]
  if not internal then return end
  unlock_aspect_id(internal)
  set_aspect_ranks({ internal }, ASPECT_MAX_RANK)
  -- Record it so apply_aspect_base_lock never re-locks an Aspect of Melinoe that AP granted.
  local s = APState.get()
  if s then s.aspect_ap_unlocked[internal] = true end
  -- The first of this weapon's 4 Aspect items (its Aspect of Melinoe or one of its 3
  -- alternates) also unlocks the weapon itself -- only the Aspects actually received are
  -- usable, the rest stay locked until their own items arrive.
  if ItemManager.setting_mode("aspectsanity") == 1 then
    local weapon = ASPECT_TITLE_TO_WEAPON[title] or ASPECT_BASE_TITLE_TO_WEAPON[title]
    local kit = weapon and ItemManager.SHORT_TO_WEAPON_KIT[weapon]
    if kit then mark_weapon_unlocked(kit) end
  end
  rom.log.info("[AP] unlock aspect: " .. title .. " (" .. internal .. ") at max rank "
    .. ASPECT_MAX_RANK)
end

-- The full ranked id list for a weapon: its default Aspect of Melinoe first, then the 3
-- non-default aspects. Used so progressive/combine ranking levels the default too.
local function ranked_aspect_ids(weapon)
  local ids = ASPECTS_BY_WEAPON[weapon]
  if not ids then return nil end
  local out = {}
  local base = ASPECT_BASE_BY_WEAPON[weapon]
  if base then out[#out + 1] = base end
  for _, id in ipairs(ids) do out[#out + 1] = id end
  return out
end

-- Progressive aspect for a weapon: the 1st item unlocks that weapon's 3 Aspects (rank 1);
-- each later item raises all 3 by one rank.
local function apply_progressive_aspect(weapon)
  local ids = ASPECTS_BY_WEAPON[weapon]
  if not ids then return end
  local s = APState.get()
  if not s then return end
  s.aspect_progress[weapon] = (s.aspect_progress[weapon] or 0) + 1
  local n = s.aspect_progress[weapon]
  if n == 1 then
    -- The default Aspect of Melinoe is already unlocked; only the 3 non-default need unlocking.
    for _, internal in ipairs(ids) do unlock_aspect_id(internal) end
  elseif n <= ASPECT_MAX_RANK then
    set_aspect_ranks(ranked_aspect_ids(weapon), n)  -- ranks the default aspect too
  end
  rom.log.info("[AP] progressive " .. weapon .. " aspect -> rank " .. math.min(n, ASPECT_MAX_RANK))
end

-- "Progressive <Weapon>" fuses the weapon unlock and its Aspects. The 1st copy unlocks
-- the weapon kit AND all 3 of its non-default Aspects (rank 1); each later copy raises
-- those Aspects by one rank (like apply_progressive_aspect).
local function apply_progressive_weapon(weapon)
  local kit = ItemManager.SHORT_TO_WEAPON_KIT[weapon]
  local ids = ASPECTS_BY_WEAPON[weapon]
  if not kit or not ids then return end
  local s = APState.get()
  if not s then return end
  s.combined_weapon[weapon] = (s.combined_weapon[weapon] or 0) + 1
  local n = s.combined_weapon[weapon]
  if n == 1 then
    mark_weapon_unlocked(kit)
    -- The default Aspect of Melinoe is already unlocked; only the 3 non-default need unlocking.
    for _, internal in ipairs(ids) do unlock_aspect_id(internal) end
  elseif n <= ASPECT_MAX_RANK then
    set_aspect_ranks(ranked_aspect_ids(weapon), n)  -- ranks the default aspect too
  end
  rom.log.info("[AP] progressive " .. weapon .. " (weapon+aspect) -> step " .. n
    .. " (aspect rank " .. math.min(n, ASPECT_MAX_RANK) .. ")")
end

-- per_aspect (aspectsanity=3): each of a weapon's 4 Aspects levels independently, unlike
-- apply_progressive_weapon which ranks all 3 non-default Aspects together. The 1st copy of
-- ANY of a weapon's 4 aspect items (its Base Aspect or one of its 3 alternates) also
-- unlocks that weapon. Each later copy of THAT SAME aspect's item raises only that one
-- aspect by a rank.
-- unlock_aspect_id ALWAYS runs at n==1, base included (fixed 7/22 -- see below): its
-- WeaponsUnlocked[internal]=true write is a harmless no-op for the base id (already free
-- via the vanilla FreeUnlock), but its force_world_upgrade() call is NOT -- that's the only
-- thing that sets GameState.WorldUpgradesAdded[internal], which HasAnyAspectUnlocked
-- (WeaponUpgradeLogic.lua:1) reads to decide whether re-interacting with an already-picked-up
-- weapon's rack opens the Aspect screen at all (InteractLogic.UseWeaponKit silently no-ops
-- otherwise -- vanilla's own gate, normally satisfied by a real Cauldron-of-Nectar purchase,
-- which AP disables in every aspectsanity mode). Skipping it for is_base (the previous
-- behavior) meant a weapon whose ONLY received/precollected aspect was its Base Aspect --
-- including the starting weapon whenever the seed's starting_aspect_index rolls 0, the
-- default Melinoe pick -- left WorldUpgradesAdded empty for that weapon, so its rack stayed
-- permanently unopenable (no aspect picker, no aspect name/level display anywhere that reads
-- WorldUpgradesRevealed/Viewed) until an alternate Aspect item happened to arrive later and
-- flip the flag for the first time. Reported as "weapons only unlock once Melinoe's Aspect is
-- acquired" -- the fix makes the FIRST aspect item of any kind (base or alternate) flip it
-- immediately, matching randomized mode's unlock_aspect (which never had this asymmetry).
local function apply_per_aspect(weapon, internal, is_base)
  local kit = ItemManager.SHORT_TO_WEAPON_KIT[weapon]
  if not kit then return end
  local s = APState.get()
  if not s then return end
  s.per_aspect_progress[internal] = (s.per_aspect_progress[internal] or 0) + 1
  local n = s.per_aspect_progress[internal]
  if n == 1 then
    mark_weapon_unlocked(kit)
    unlock_aspect_id(internal)
  elseif n <= ASPECT_MAX_RANK then
    set_aspect_ranks({ internal }, n)
  end
  rom.log.info("[AP] per-aspect " .. weapon .. " " .. internal .. " -> rank "
    .. math.min(n, ASPECT_MAX_RANK) .. (n == 1 and " (weapon unlocked)" or "")
    .. (is_base and " (base)" or ""))
end

-- randomized (aspectsanity=1) only: weapons do NOT come with their default Aspect of Melinoe --
-- it's one of the 24 shuffled items. Vanilla gives it away two ways, so close both:
--   1. ScreenData.WeaponUpgradeScreen.FreeUnlocks[kit] -- OpenWeaponUpgradeScreen sets
--      GameState.WeaponsUnlocked[base] = true EVERY time the Aspect screen is opened
--      (WeaponUpgradeLogic.lua:63-66). That write is the actual "free" grant, so drop the entry.
--   2. A save that predates this mode (or one where the screen was opened before settings landed)
--      may already have WeaponsUnlocked[base] set -- clear it.
-- Fail closed: this runs for every base Aspect the player hasn't earned, where "earned" means AP
-- sent its item OR it's the seed's starting Aspect (both recorded in APState.aspect_ap_unlocked).
-- ScreenData is base-game Lua data, not save data, so a fresh process resets FreeUnlocks -- hence
-- reasserting every room, same as apply_help_odds / apply_nightmare_fury_unlock.
--
-- A weapon with NO Aspect unlocked is a safe, vanilla-supported state: the Aspect screen's button
-- loop simply skips locked entries (WeaponUpgradeLogic.lua:71) and can legitimately render empty,
-- and EquipWeaponUpgrade falls back to the weapon's DummyTraitName when LastWeaponUpgradeName is
-- nil (WeaponUpgradeLogic.lua:434) -- vanilla's own "never picked an Aspect" path. So the weapon
-- plays fine, just with no Aspect bonus until an item arrives.
function ItemManager.apply_aspect_base_lock()
  if ItemManager.setting_mode("aspectsanity") ~= 1 then return end
  local s = APState.get()
  if not s then return end
  local locked = {}
  for weapon, base_id in pairs(ASPECT_BASE_BY_WEAPON) do
    if not s.aspect_ap_unlocked[base_id] then
      pcall(function()
        local kit = ItemManager.SHORT_TO_WEAPON_KIT[weapon]
        local screen = game.ScreenData and game.ScreenData.WeaponUpgradeScreen
        if kit and screen and screen.FreeUnlocks then screen.FreeUnlocks[kit] = nil end
        if game.GameState and game.GameState.WeaponsUnlocked then
          game.GameState.WeaponsUnlocked[base_id] = nil
        end
      end)
      locked[#locked + 1] = weapon
    end
  end
  if #locked > 0 and not ItemManager._aspect_base_lock_logged then
    ItemManager._aspect_base_lock_logged = true   -- once per launch: this runs every room
    table.sort(locked)
    rom.log.info("[AP] aspectsanity=randomized -> Aspect of Melinoe locked (item-gated) for: "
      .. table.concat(locked, ", "))
  end
end

-- ---- petsanity -------------------------------------------------------------

-- Vanilla FamiliarOrderData (FamiliarLogic.lua AssignFamiliarKits) -- fixed spawn order, used
-- to index MapState.FamiliarKitIds by position below. NOT the same order as
-- ItemManager.FAMILIAR_NAMES (which doesn't need to match a physical slot).
local FAMILIAR_ORDER = { "CatFamiliar", "FrogFamiliar", "RavenFamiliar", "HoundFamiliar", "PolecatFamiliar" }

-- Hub_PreRun's AssignFamiliarKits only spawns a kit for a familiar whose GameStateRequirements
-- (a single PathTrue on GameState.FamiliarsUnlocked[name]) passes AT THAT MOMENT -- it runs once
-- per Hub visit (DeathLoopData.lua Hub_PreRun.StartUnthreadedEvents), unlike weapon racks, which
-- always exist and are merely hidden/UseableOff when locked (see mark_weapon_unlocked's
-- UpdateWeaponKits refresh). So a familiar unlocked while the player is ALREADY standing in the
-- Hub gets no kit at all until the next full Hub reload. This mirrors just the "spawn one
-- familiar's kit" slice of AssignFamiliarKits' per-entry body (the "not equipped" branch -- a
-- freshly-granted familiar is never auto-equipped, so this is the only branch that applies).
-- Skips IsGameStateEligible entirely since we just set the one flag it checks ourselves.
-- Every game accessor is existence-checked and the whole thing is one pcall: if any guess about
-- the exposed API is wrong, this silently no-ops and the kit still appears normally on the next
-- Hub load (today's behavior) -- no regression path either way.
-- HIGHEST-RISK element: thread(SetupUnit, ...), which vanilla uses to finish initializing a
-- freshly spawned unit (AI/collision/ActiveEnemies registration) -- this spins up a real
-- coroutine, unlike a plain synchronous call. It is safe ONLY because this function runs
-- synchronously off a real item-grant call (itself only reachable once a save is loaded) --
-- NEVER call this from the bridge's raw per-frame poll callback (see the POLL DRIVER note in
-- project memory: calling the game's thread()/wait() from that context previously froze the
-- game during a save-load).
-- UNVERIFIED -- needs an in-game playtest: receive a familiar's item while standing in the
-- Crossroads and confirm she appears without leaving/returning.
local function refresh_familiar_kit(internal)
  local ok, err = pcall(function()
    local ms = game.MapState
    local gs = game.GameState
    if not (ms and ms.FamiliarKits and ms.FamiliarKitIds and gs) then return end
    for _, existing in pairs(ms.FamiliarKits) do
      if existing.Name == internal then return end  -- already has a kit
    end
    local index = nil
    for i, orderName in ipairs(FAMILIAR_ORDER) do
      if orderName == internal then index = i break end
    end
    local kitId = index and ms.FamiliarKitIds[index]
    local familiarData = game.FamiliarData and game.FamiliarData[internal]
    local obstacleData = game.ObstacleData and game.ObstacleData.FamiliarKit
    if not (kitId and familiarData and obstacleData and game.DeepCopyTable
        and game.AttachLua and game.SpawnUnit and thread and SetupUnit) then
      return
    end

    local familiarKit = game.DeepCopyTable(obstacleData)
    game.AttachLua({ Id = kitId, Table = familiarKit })
    familiarKit.Name = internal
    familiarKit.ObjectId = kitId
    ms.FamiliarKits[kitId] = familiarKit

    local familiar = game.DeepCopyTable(familiarData)
    familiar.TargetSearchDistance = 3000  -- matches AssignFamiliarKits' Hub-load OverwriteSelf
    familiar.BlocksLootInteraction = false
    familiar.DisableAIWhenReady = true    -- unequipped branch: park at the kit, don't roam yet

    gs.FamiliarCostumes = gs.FamiliarCostumes or {}
    if gs.FamiliarCostumes[internal] == nil then
      gs.FamiliarCostumes[internal] = familiar.DefaultCostume
    end

    familiar.ObjectId = game.SpawnUnit({ Name = familiar.Name, Group = "Standing", DestinationId = kitId })
    familiar.AINotifyName = "WithinDistance_" .. familiar.Name .. "_" .. familiar.ObjectId
    thread(SetupUnit, familiar, game.CurrentRun)

    familiar.KitId = kitId
    familiarKit.Unit = familiar
    pcall(function() if SetAlpha then SetAlpha({ Id = kitId, Fraction = 0.0 }) end end)
    pcall(function() if UpdateFamiliarKits then UpdateFamiliarKits({ DoEquip = false }) end end)

    rom.log.info("[AP] familiar kit refreshed live in Hub: " .. internal)
  end)
  if not ok then
    rom.log.info("[AP] refresh_familiar_kit(" .. tostring(internal) .. ") failed: " .. tostring(err))
  end
end

local function unlock_familiar_id(internal)
  pcall(function()
    local gs = game.GameState
    if gs then
      gs.FamiliarsUnlocked = gs.FamiliarsUnlocked or {}
      gs.FamiliarsUnlocked[internal] = true
    end
    if game.CurrentRun and game.CurrentRun.FamiliarsUnlocked then
      game.CurrentRun.FamiliarsUnlocked[internal] = true
    end
  end)
  -- Record that AP granted this familiar, so the recruit-block hook won't re-lock it.
  local s = APState.get()
  if s then s.familiar_ap_granted[internal] = true end
  refresh_familiar_kit(internal)
end

-- GodSanity: record that this seed has unlocked `name`'s god. See ItemManager.god_eligible
-- (below) and the SpawnRoomReward wrap (reload.lua) for how this actually gates boon spawns.
local function unlock_god(name)
  local internal = GOD_ITEM_TO_ID[name]
  if not internal then return end
  local s = APState.get()
  if not s then return end
  s.unlocked_gods[internal] = true
  rom.log.info("[AP] god unlocked: " .. name .. " (" .. internal .. ")")
end

-- Hermes/Selene (godsanity_shop_gods): same s.unlocked_gods table as unlock_god above, just a
-- different source map (SHOP_GOD_ITEM_TO_ID) so unlocked_god_count's 9-god denominator is
-- unaffected -- see SHOP_GOD_ITEM_TO_ID's own comment.
local function unlock_shop_god(name)
  local internal = SHOP_GOD_ITEM_TO_ID[name]
  if not internal then return end
  local s = APState.get()
  if not s then return end
  s.unlocked_gods[internal] = true
  rom.log.info("[AP] shop god unlocked: " .. name .. " (" .. internal .. ")")
end

-- Whether `lootName` (an internal "<God>Upgrade" LootData key, e.g. from GetEligibleLootNames)
-- should count as eligible right now under GodSanity. godsanity=unlocked (0, the default "off"
-- state) or no active AP session: always true, native behavior untouched. Otherwise: only true
-- once its "<God> Unlock" item has been received.
function ItemManager.god_eligible(lootName)
  if not ItemManager.have_settings() then return true end
  if ItemManager.setting_mode("godsanity") == 0 then return true end
  local s = APState.get()
  if not s then return true end
  return s.unlocked_gods[lootName] == true
end

-- How many of the 9 boon gods this seed has unlocked so far (godsanity != unlocked).
function ItemManager.unlocked_god_count()
  local s = APState.get()
  if not s then return 0 end
  local n = 0
  for _, internal in pairs(GOD_ITEM_TO_ID) do
    if s.unlocked_gods[internal] then n = n + 1 end
  end
  return n
end

-- Helper Room Sanity: record that this seed has unlocked `name`'s helper NPC (bare cast
-- name, e.g. "Arachne"). See ItemManager.helper_npc_eligible and the UseNPC wrap (reload.lua)
-- for how this actually gates a helper's dialogue/buff and "Met"/keepsake checks.
local function unlock_helper_npc(name)
  local internal = HELPER_NPC_ITEM_TO_ID[name]
  if not internal then return end
  local s = APState.get()
  if not s then return end
  s.helper_npc_unlocked[internal] = true
  rom.log.info("[AP] helper NPC room unlocked: " .. name .. " (" .. internal .. ")")
end

-- IncludeZagreusJourney: whether this seed wants any Zagreus' Journey-derived content at all
-- (the Nightmare route and its cast -- Sisyphus/Eurydice/Patroclus/Thanatos being randomized
-- into other routes' rooms, the 7 Nightmare keepsakes). No active AP session: always true,
-- native (current default) behavior. See ItemManager.combat_helper_eligible's Thanatos
-- special-case and the SelectRandomStoryRoom intercept (reload.lua) for how this is enforced.
function ItemManager.zj_content_enabled()
  if not ItemManager.have_settings() then return true end
  return ItemManager.setting_on("include_zagreus_journey")
end

-- Whether `npcName` (a bare cast name, e.g. "Arachne") should be treated as met/gifted right
-- now under Helper Room Sanity. Modes 0/2 (unlocked / unlocked_random) or no active AP
-- session: always true, native behavior untouched. Modes 1/3 (items / items_random): only
-- true once its own "<NPC> Room" item has been received.
function ItemManager.helper_npc_eligible(npcName)
  if not ItemManager.have_settings() then return true end
  local mode = ItemManager.setting_mode("helper_room_sanity")
  if mode == 0 or mode == 2 then return true end
  local s = APState.get()
  if not s then return true end
  return s.helper_npc_unlocked[npcName] == true
end

-- Whether ANY helper NPC has been unlocked yet under Helper Room Sanity. Modes 0/2 (unlocked /
-- unlocked_random) or no active AP session: always true (native). Mode 1 (items): irrelevant --
-- gated per-door on that door's own native NPC (helper_npc_eligible), not this. Mode 3
-- (items_random): used by the story-room eligibility gate (eligibility_override below) to decide
-- whether a story room should be allowed to appear ANYWHERE this run -- if nobody's unlocked yet,
-- no story room should surface at all, since SelectRandomStoryRoom (reload.lua) would otherwise
-- have no unlocked identity to swap it into.
function ItemManager.any_helper_npc_unlocked()
  if not ItemManager.have_settings() then return true end
  local mode = ItemManager.setting_mode("helper_room_sanity")
  if mode == 0 or mode == 2 then return true end
  local s = APState.get()
  if not s then return true end
  for npc in pairs(ItemManager.HELPER_NPC_NAME_SET) do
    if s.helper_npc_unlocked[npc] then return true end
  end
  return false
end

-- Whether zerp-NPCRoomRandomizer should be allowed to swap a story room's NPC identity right
-- now. Modes 2/3 (unlocked_random / items_random) or no active AP session: yes, native
-- (current default) behavior. Modes 0/1 (unlocked / items): no -- each door should keep its
-- own native helper. See the SelectRandomStoryRoom intercept (reload.lua).
function ItemManager.helper_room_random_allowed()
  if not ItemManager.have_settings() then return true end
  local mode = ItemManager.setting_mode("helper_room_sanity")
  return mode == 2 or mode == 3
end

-- Combat Helper Sanity: record that this seed has unlocked `name`'s combat-assist NPC (bare
-- cast name, e.g. "Artemis"). See ItemManager.combat_helper_eligible and the Handle<God>Spawn
-- wraps (reload.lua) for how this actually gates whether the NPC's encounter can fire.
local function unlock_combat_helper(name)
  local internal = COMBAT_HELPER_ITEM_TO_ID[name]
  if not internal then return end
  local s = APState.get()
  if not s then return end
  s.combat_helper_unlocked[internal] = true
  rom.log.info("[AP] combat helper unlocked: " .. name .. " (" .. internal .. ")")
end

-- Whether `npcName` (a bare cast name, e.g. "Artemis") should be allowed to actually spawn
-- as a combat-assist encounter right now under Combat Helper Sanity. Modes 0/2 (unlocked /
-- unlocked_random) or no active AP session: always true, native behavior untouched. Modes
-- 1/3 (items / items_random): only true once its own "<NPC> Helper" item has been received.
-- Thanatos is a special case: his spawn (native Nightmare-zone AND zerp's foreign-zone
-- additions) calls through Zagreus' Journey's own HandleThanatosSpawn (reload.lua), so he's
-- never eligible at all when IncludeZagreusJourney is off, regardless of this option's mode.
function ItemManager.combat_helper_eligible(npcName)
  if npcName == "Thanatos" and not ItemManager.zj_content_enabled() then return false end
  if not ItemManager.have_settings() then return true end
  local mode = ItemManager.setting_mode("combat_helper_sanity")
  if mode == 0 or mode == 2 then return true end
  local s = APState.get()
  if not s then return true end
  return s.combat_helper_unlocked[npcName] == true
end

-- Combat Helper Sanity, "any location" toggle: unlike zerp-NPCRoomRandomizer (a single
-- SelectRandomStoryRoom function to intercept, see helper_room_random_allowed above),
-- zerp-Extended_NPC_Encounters gates each foreign-zone encounter it adds through its OWN
-- live config table, re-checked fresh on every eligibility roll (each such encounter's
-- GameStateRequirements carries a PathTrue = {guid, "config", <npc>, <zone>} entry) -- so
-- instead of wrapping a function, this flips the SAME booleans that mod's own settings UI
-- would, live, via its registered mod object (confirmed the same live table its own
-- main.lua exposes: `mod.config = config`, reached the same way reload.lua already reaches
-- zerp-NPCRoomRandomizer's function table: modutil.mod.Mods.Data[guid]). No restart needed;
-- called once per SETTINGS receipt (reload.lua) -- self-heals across a rejoin/mode change
-- the same way the rest of this mod's settings do.
-- Zone key lists per NPC = every foreign-zone flag that mod's own <npc>.lua actually checks
-- (verified by reading each file directly, not just its config.lua defaults). Includes
-- Athena's tartarus_nightmare/asphodel/elysium: her own athena.lua DOES define those 3
-- encounters, but config.lua ships them commented out, so she's never had Nightmare
-- coverage the other 5 NPCs already have -- enabling them here is a real coverage fix, not
-- just parity busywork. Fields(H)/Thessaly(O) are absent for Athena on purpose: her file
-- has no AthenaCombatH/AthenaCombatO defined at all, so there's no flag to set either way.
local COMBAT_HELPER_RANDOM_ZONES = {
  Artemis  = { "fields", "tartarus", "thessaly", "olympus", "tartarus_nightmare", "elysium" },
  Heracles = { "erebus", "oceanus", "fields", "tartarus", "tartarus_nightmare", "asphodel", "elysium" },
  Icarus   = { "erebus", "oceanus", "fields", "tartarus", "ephyra", "ephyra_sideroom", "asphodel", "elysium" },
  Nemesis  = { "ephyra", "thessaly", "olympus", "tartarus_nightmare", "asphodel", "elysium" },
  Athena   = { "erebus", "oceanus", "tartarus", "ephyra", "tartarus_nightmare", "asphodel", "elysium" },
  Thanatos = { "erebus", "oceanus", "tartarus", "ephyra", "olympus" },
}
function ItemManager.apply_combat_helper_random()
  local mode = ItemManager.have_settings() and ItemManager.setting_mode("combat_helper_sanity") or 2
  local allow = (mode == 2 or mode == 3)
  -- Thanatos has no true native zone without Nightmare (his "native" spawns are Zagreus'
  -- Journey's own Nightmare-zone encounters -- see the HandleThanatosSpawn intercept, reload.lua).
  -- When ZJ content is enabled but Nightmare itself isn't part of this seed (apworld's
  -- Routes.combat_helper_native_fallback), native-only modes 0/1 would otherwise strand him with
  -- nowhere to ever spawn -- force his own foreign-zone flags (Underworld/Surface) on regardless
  -- of mode in exactly that situation, so he can still turn up there instead (July 22).
  local thanatos_forced = ItemManager.zj_content_enabled() and not ItemManager.route_active("Nightmare")
  local ok, err = pcall(function()
    local zmod = modutil and modutil.mod and modutil.mod.Mods and modutil.mod.Mods.Data
      and modutil.mod.Mods.Data['zerp-Extended_NPC_Encounters']
    local cfg = zmod and zmod.config
    if not cfg then
      rom.log.error("[AP] combat_helper_sanity: zerp-Extended_NPC_Encounters config not found "
        .. "-- any-location control inactive this session (falls back to that mod's own default)")
      return
    end
    for npc, zones in pairs(COMBAT_HELPER_RANDOM_ZONES) do
      local sub = cfg[npc:lower()]
      if sub then
        local npc_allow = allow or (npc == "Thanatos" and thanatos_forced)
        for _, zone in ipairs(zones) do sub[zone] = npc_allow end
      end
    end
    rom.log.info("[AP] combat_helper_sanity: any-location = " .. tostring(allow)
      .. ", Thanatos forced = " .. tostring(thanatos_forced))
  end)
  if not ok then
    rom.log.warning('[AP] apply_combat_helper_random errored: ' .. tostring(err))
  end
end

-- no_waste_less_odds: how many of a reward store's native "Boon" copies should survive this
-- run, out of how many it actually has (RunProgress has 4, HubRewards has 5 -- read directly
-- off the entry so this doesn't hardcode either number and stays correct if vanilla's own
-- counts ever change). Eases in rather than a straight line -- more Boon slots earlier than
-- 9ths-of-the-way-there would give, full native count once every god is unlocked -- per user
-- request ("roughly linear, but have more spawn earlier").
local GODSANITY_TOTAL_GODS = 9
-- How many of a reward store's native "Boon" copies should survive this run, out of how many
-- it actually has (read directly off the entry by the caller, not hardcoded).
--   mode 2 (no_waste_less_odds): eases in rather than a straight line -- more Boon slots
--     earlier than 9ths-of-the-way-there would give, full native count once every god is
--     unlocked -- per user request ("roughly linear, but have more spawn earlier").
--   mode 1 (onions) / mode 3 (no_waste_same_odds): the door-frequency itself isn't meant to
--     scale with unlock count -- BUT a "Boon" door with zero unlocked gods to offer would have
--     nothing eligible to give, so this is the one case both modes also thin to 0: it's cheaper
--     and more correct to simply never let the door become "Boon" in the first place than to
--     intercept it after SetupRoomReward has already resolved a reward (see GetEligibleLootNames
--     below for the same reasoning applied to WHICH god, once >=1 is unlocked). Full native
--     count the instant any god is unlocked.
local function godsanity_boon_fraction(mode)
  local unlocked = ItemManager.unlocked_god_count()
  if mode == 2 then
    return 1 - (1 - unlocked / GODSANITY_TOTAL_GODS) ^ 2
  end
  if unlocked == 0 then return 0 end
  return 1
end

local function godsanity_boon_target(native_count, mode)
  return math.floor(native_count * godsanity_boon_fraction(mode) + 0.5)
end

-- MiniBoss encounters (every zone's RoomData -- confirmed via RoomDataF/G/H/I/N/O/P.lua) hardcode
-- EligibleRewards = { "Boon" } on their reward room, a SEPARATE native filter
-- (RewardLogic.IsRoomRewardEligible) that rejects every non-Boon candidate regardless of how few
-- Boon copies scale_boon_entries left in the store. Since godsanity_boon_target never rounds back
-- to 0 once any god is unlocked, these rooms end up 100% Boon forever under no_waste_less_odds,
-- completely bypassing its curve (confirmed live 2026-07-21 alongside the accumulation fix below).
-- Runs the SAME fraction as an independent per-room coin flip instead; the ChooseRoomReward wrap
-- (reload.lua) temporarily clears EligibleRewards on a miss so the room falls through to its
-- normal (already-thinned) pool. Naturally a no-op for modes 1/3 once >=1 god is unlocked (their
-- fraction is always 1 there), matching their own documented "native odds" design.
function ItemManager.godsanity_boon_roll_allowed(mode)
  return math.random() < godsanity_boon_fraction(mode)
end

-- Several RunProgress/HubRewards entries besides Boon carry their OWN native GameStateRequirements
-- gate (WeaponUpgrade/HammerLootRequirements, HermesUpgrade/HermesUpgradeRequirements, SpellDrop/
-- SpellDropRequirements, Devotion/its own Poseidon-devotion gate) that's normally unmet for most
-- of an early run -- vanilla's own ChooseRoomReward already filters these OUT of the eligible
-- candidate set before it ever rolls, so they're already "free" dead weight in a normal-sized
-- store. But scale_boon_entries' padding (below) picks NEW copies from `rest` to fill the gap left
-- by thinned Boons -- if it picks one of these gated entries, that slot is ALSO filtered out
-- downstream, silently shrinking the true eligible pool even further and concentrating weight
-- onto whichever entries happen to be ungated (MaxHealthDrop/MaxManaDrop -- confirmed live
-- 2026-07-21: this is why "no god boons" was overwhelmingly reading as "all heals" even after
-- padding, an eligible-vs-total mismatch, not a sampling-fairness bug). Filters padding
-- candidates down to currently-eligible entries only, so a locked god's boon slot becomes
-- something the room could ACTUALLY hand out right now.
local function reward_entry_currently_eligible(entry)
  if not entry.GameStateRequirements then return true end
  local ok, eligible = pcall(game.IsGameStateEligible, nil, entry.GameStateRequirements, nil)
  if not ok then return true end -- can't tell -- don't make things worse, assume eligible
  return eligible ~= false
end

-- Extra padding candidates that aren't necessarily part of a given store's own native array, but
-- are always safe to hand out regardless of run progress or which store is being padded -- gold,
-- regular Max Health, and regular Max Mana in particular: RunProgress lists all three natively,
-- but HubRewards only ever had the Big variants (which vanilla itself only wants one real distinct
-- pickup of at a time -- see the pad_needed comment below), and none of the three have a god/story
-- prerequisite or a plausible "only one can ever exist" reason to be scarce the way Boon is. Exists
-- so padding always has somewhere safe to fall back to even when a store's own eligible siblings
-- are too few/too capped, especially for a many-exit room/hub once Boon is correctly thinned to
-- near-zero (confirmed live 2026-07-21).
local BONUS_PADDING_ENTRIES = {
  { Name = "RoomMoneyDrop" },
  { Name = "MaxHealthDrop" },
  { Name = "MaxManaDrop" },
}

-- Rebuild `storeData` (a RewardStoreData-shaped array of {Name=..., ...} entries, as returned
-- by the native GetRewardStoreData) with its "Boon" entries thinned or padded to
-- godsanity_boon_target's count. Returns a NEW array -- never mutates `storeData` in place,
-- since GetRewardStoreData can return the raw global RewardStoreData[storeName] template
-- itself (RewardLogic.lua's callers only DeepCopyTable it AFTER calling this), and permanently
-- shrinking the shared template would corrupt every future run/session, not just this one.
function ItemManager.scale_boon_entries(storeData, mode, storeName)
  local boon_entry, boon_count = nil, 0
  local rest = {}
  for _, entry in ipairs(storeData) do
    if entry.Name == "Boon" then
      boon_count = boon_count + 1
      boon_entry = boon_entry or entry
    else
      table.insert(rest, entry)
    end
  end
  if boon_count == 0 then return storeData end -- unexpected shape -- leave untouched

  -- eligible_rest is used ONLY to pick safe padding duplicates below -- it must NOT be used to
  -- build `result` itself. An earlier version dropped currently-ineligible native entries
  -- (WeaponUpgrade/HammerLootRequirements, HermesUpgrade/its own gate, SpellDrop/its own gate,
  -- Devotion/its own gate) out of the array entirely, on the theory that vanilla's own
  -- ChooseRoomReward already filters these at roll time so removing them here was "free." In
  -- practice this used reward_entry_currently_eligible's simplified nil-source
  -- IsGameStateEligible call (not vanilla's real in-context roll-time check) to decide, and once
  -- an entry was judged ineligible at GetRewardStoreData time it was gone from the store for
  -- that call -- confirmed 2026-07-21 this is why Daedalus Hammer (WeaponUpgrade) doors stopped
  -- appearing at all under GodSanity. `result` below now keeps every original `rest` entry
  -- unconditionally (exactly like vanilla's own array), and only the PADDING pool (new
  -- duplicate slots filling the gap left by thinned Boons) is restricted to currently-eligible
  -- siblings, so padding still can't land on a dead duplicate without also hiding the real thing.
  local eligible_rest = {}
  for _, entry in ipairs(rest) do
    if reward_entry_currently_eligible(entry) then table.insert(eligible_rest, entry) end
  end

  local target = math.min(boon_count, godsanity_boon_target(boon_count, mode))

  -- GetRewardStoreData is also called by vanilla's own mid-run refill (RewardLogic.lua
  -- ChooseRoomReward, once the live store empties) -- which CONCATENATES a fresh batch onto
  -- whatever's still sitting in the live array (game.CurrentRun.RewardStores[storeName]), never
  -- replacing it. Boon copies carry AllowDuplicates=true and are heavily outnumbered by filler,
  -- so they're rarely the one actually drawn -- left alone, every refill adds ANOTHER `target`
  -- Boon copies on top of whatever un-drawn ones already survived earlier refills, so the live
  -- pool's Boon concentration only grows across a run instead of staying capped at the intended
  -- odds. Confirmed live 2026-07-21: the same store refilled 5x within 12ms while assigning one
  -- hub's several doors, each logging target=1 in isolation, but stacking to as many as 5 un-drawn
  -- Boon copies at once -- this is what made non-MiniBoss rooms show up Boon far more than the
  -- curve implies. Count what's already live and only top up the gap; once the pool already has
  -- enough, add zero more until some get drawn.
  if storeName and game.CurrentRun and game.CurrentRun.RewardStores then
    local live_store = game.CurrentRun.RewardStores[storeName]
    if live_store then
      local already_present = 0
      for _, entry in ipairs(live_store) do
        if entry.Name == "Boon" then already_present = already_present + 1 end
      end
      target = math.max(0, target - already_present)
    end
  end

  local result = {}
  for _, entry in ipairs(rest) do table.insert(result, entry) end
  for _ = 1, target do table.insert(result, boon_entry) end

  -- Every thinned Boon slot needs to become SOMETHING, or the store collapses toward
  -- empty/all-ineligible -- which falls through to vanilla's own last-resort
  -- RoomRewardConsolationPrize/generic heal filler every time (RewardLogic.lua's
  -- SpawnPerfectClearRoomReward pattern). Pad back up using this store's own CURRENTLY eligible
  -- siblings PLUS the always-safe BONUS_PADDING_ENTRIES (gold) -- confirmed live 2026-07-21 that
  -- restricting padding to only a store's own siblings isn't enough on its own: HubRewards' only
  -- two ungated siblings are Max Health/Max Mana Big, which still only produced one real distinct
  -- pickup of each in practice (consistent with vanilla only ever wanting one Big-upgrade pickup
  -- live at a time), so most of the remaining pad slots need somewhere else to go besides
  -- duplicating those two. Restricted to eligible_rest (not the full `rest`, which is already
  -- unconditionally in `result` above) so padding never adds a SECOND copy of something that's
  -- currently ineligible on top of the original -- that duplicate would just be dead weight.
  --   Sampling is WITHOUT REPLACEMENT (a shuffled pass through pad_pool, reshuffling once a full
  -- pass is used up), not independent math.random(#pad_pool) draws per slot: confirmed live
  -- 2026-07-21 that independent draws can and did cluster onto the same one name for most of a
  -- pad even when a perfect one-of-each was available every time. A deterministic index cycle
  -- (rest[i % #rest], always starting at index 1 on every call) had the opposite problem --
  -- entries past the first `removed` never appeared at all, all run.
  local pad_pool = {}
  for _, entry in ipairs(eligible_rest) do table.insert(pad_pool, entry) end
  for _, entry in ipairs(BONUS_PADDING_ENTRIES) do table.insert(pad_pool, entry) end
  local pad_needed = boon_count - target
  -- GodSanity correctly suppressing Boon toward 0 (0 unlocked gods, or the accumulation cap
  -- above) removes vanilla's OWN mechanism for a many-exit room/hub to fill every door: native
  -- Boon carries AllowDuplicates=true specifically so it can repeat across as many doors as
  -- needed, but our pad_pool entries (native siblings AND BONUS_PADDING_ENTRIES) don't -- so once
  -- a hub with, say, 9 exits exhausts its ~3 truly-distinct early-game options (MaxHealthDrop/
  -- MaxManaDrop/RoomMoneyDrop -- their OWN "second copy" entries are gated behind having received
  -- >=1 god upgrade, which never happens at 0 unlocked gods), the remaining exits have nothing
  -- left ChooseRoomReward considers non-duplicate, cascading through 2 refills into vanilla's
  -- hardcoded last-resort "RoomRewardHealDrop" for every one of them (confirmed live 2026-07-21:
  -- a 9-exit hub showing the heal icon on 6+ doors instead of a health/mana/gold mix). Insert a
  -- shallow copy with AllowDuplicates forced on for pad slots specifically (never mutate the
  -- shared native entry in place -- see this function's own header) so our padding can actually
  -- repeat the way Boon used to.
  if pad_needed > 0 and #pad_pool > 0 then
    local shuffled, pos = {}, 1
    for _ = 1, pad_needed do
      if pos > #shuffled then
        shuffled = {}
        for i, entry in ipairs(pad_pool) do shuffled[i] = entry end
        for i = #shuffled, 2, -1 do
          local j = math.random(i)
          shuffled[i], shuffled[j] = shuffled[j], shuffled[i]
        end
        pos = 1
      end
      local pick = shuffled[pos]
      table.insert(result, {
        Name = pick.Name,
        AllowDuplicates = true,
        GameStateRequirements = pick.GameStateRequirements,
      })
      pos = pos + 1
    end
  end
  rom.log.info(string.format(
    "[AP] scale_boon_entries: store=%s mode=%s boon_count=%d target=%d rest=%d eligible_rest=%d "
      .. "pad_pool=%d pad_needed=%d result=%d",
    tostring(storeName), tostring(mode), boon_count, target, #rest, #eligible_rest, #pad_pool, pad_needed, #result))
  return result
end

local function unlock_familiar(name)
  local internal = FAMILIAR_ITEM_TO_ID[name]
  if not internal then return end
  unlock_familiar_id(internal)
  -- petsanity=randomized grants each familiar at MAX bond (Options.PetSanity's own
  -- docstring: "unlock each at maximum bond when you receive its item") -- this only used
  -- to set the unlock flag and leave bond at 0, contradicting that. Mirrors
  -- apply_progressive_familiar's per-tier loop, but maxes every track for just this one
  -- familiar in a single step instead of walking it up gradually.
  pcall(function()
    local fu = game.GameState and game.GameState.FamiliarUpgrades
    local b = FAMILIAR_BOND[internal]
    if fu and b then
      fu[b.base] = true
      for _, track in ipairs(b.tracks) do
        fu[track] = true
        fu[track .. "2"] = true
        fu[track .. "3"] = true
      end
    end
  end)
  rom.log.info("[AP] unlock familiar: " .. name .. " (" .. internal .. ") at max bond")
end

-- Progressive familiar: the 1st item unlocks all familiars (+ their bond base); each
-- later item grants the next bond tier (suffix ""/"2"/"3") across every familiar's tracks.
local function apply_progressive_familiar()
  local s = APState.get()
  if not s then return end
  s.familiar_progress = (s.familiar_progress or 0) + 1
  local n = s.familiar_progress
  if n == 1 then
    for _, internal in ipairs(ItemManager.FAMILIAR_NAMES) do unlock_familiar_id(internal) end
    pcall(function()
      local fu = game.GameState and game.GameState.FamiliarUpgrades
      if fu then for _, b in pairs(FAMILIAR_BOND) do fu[b.base] = true end end
    end)
  else
    local tier = n - 1
    local suffix = (tier == 1) and "" or tostring(tier)
    pcall(function()
      local fu = game.GameState and game.GameState.FamiliarUpgrades
      if fu then
        for _, b in pairs(FAMILIAR_BOND) do
          for _, track in ipairs(b.tracks) do fu[track .. suffix] = true end
        end
      end
    end)
  end
  rom.log.info("[AP] progressive familiar -> step " .. n)
end

-- ---- keepsakesanity --------------------------------------------------------

-- GameState.GiftPresentation[trait] is the canonical "earned this keepsake" flag
-- (what gifting an NPC sets); NewKeepsakeItem is the "new!" badge.
--
-- IMPORTANT: do NOT set GiftPresentation[trait] here. The keepsake rack's "owned/
-- equippable" gate is TextLinesRecord[flag] alone (confirmed via KeepsakeData.lua --
-- every keepsake's GiftLevelData.GameStateRequirements is a PathTrue on that flag,
-- never on GiftPresentation). But GiveGift (GiftLogic.lua) guards its own award with
-- `if not GameState.GiftPresentation[gift] and IsGameStateEligible(...)` -- if we
-- pre-set GiftPresentation here, the NPC's actual in-game gift interaction silently
-- no-ops (money spent, no keepsake awarded) because the base game thinks the gift
-- was already presented, and PlayerReceivedGiftPresentation never fires, so our
-- check-send hook (reload.lua) never runs and the location can never be sent. Leaving
-- GiftPresentation unset lets the normal gift flow complete once (the NPC still
-- "gives" it), which fires our hook -> sends the check -> block_keepsake_award() then
-- no-ops because keepsake_ap_granted is already true, so ownership stays intact.
local function unlock_keepsake_trait(trait)
  pcall(function()
    local gs = game.GameState
    if gs then
      -- The ownership gate is the keepsake's gift text-line flag (its GiftLevelData
      -- GameStateRequirements). Set it so the keepsake shows owned + equippable.
      local flag = KEEPSAKE_TRAIT_TO_OWNFLAG[trait]
      if flag then
        gs.TextLinesRecord = gs.TextLinesRecord or {}
        gs.TextLinesRecord[flag] = true
      end
      gs.NewKeepsakeItem = gs.NewKeepsakeItem or {}
      gs.NewKeepsakeItem[trait] = true
    end
  end)
  -- Mark AP-granted so the equip gate (reload.lua) lets this keepsake be equipped.
  local s = APState.get()
  if s then s.keepsake_ap_granted[trait] = true end
end

local function unlock_keepsake(title)
  local trait = KEEPSAKE_ITEM_TO_ID[title]
  if not trait then return end
  unlock_keepsake_trait(trait)
  rom.log.info("[AP] unlock keepsake: " .. title .. " (" .. trait .. ")")
end

-- Combined God Unlock + Keepsake item: grants both halves at once by re-using the existing
-- god/keepsake handlers (see GOD_KEEPSAKE_COMBINED's own comment).
local function unlock_god_keepsake_combined(name)
  local info = GOD_KEEPSAKE_COMBINED[name]
  if not info then return end
  if info.shop then unlock_shop_god(info.god) else unlock_god(info.god) end
  unlock_keepsake(info.keepsake)
  rom.log.info("[AP] combined god+keepsake unlocked: " .. name)
end

-- keepsakesanity: when an NPC would award a keepsake we DON'T have the AP item for, clear
-- its ownership (gift text-line flag + the new/presentation flags) so it stays locked --
-- unselectable in the keepsake menu, hence never equipped. This replaces the old equip
-- gate, which crashed KeepsakeScreenClose by making EquipKeepsake a no-op. If the keepsake
-- is already AP-granted, leave it owned.
function ItemManager.block_keepsake_award(trait)
  local s = APState.get()
  if s and s.keepsake_ap_granted[trait] then return end
  pcall(function()
    local gs = game.GameState
    if gs then
      local flag = KEEPSAKE_TRAIT_TO_OWNFLAG[trait]
      if flag and gs.TextLinesRecord then gs.TextLinesRecord[flag] = nil end
      if gs.GiftPresentation then gs.GiftPresentation[trait] = nil end
      if gs.NewKeepsakeItem then gs.NewKeepsakeItem[trait] = nil end
    end
  end)
end

-- keepsakesanity: on connect, re-lock every managed keepsake the player neither received
-- the AP item for nor already sent the check for. On an EXISTING save a keepsake may already
-- be owned (its GiftPresentation flag set from a prior gift), so the game never re-fires
-- PlayerReceivedGiftPresentation and the check never sends (Test Run 4 #10: Hestia/Charon).
-- Clearing ownership makes re-gifting that NPC fire the check. Idempotent; skips AP-granted
-- and already-sent keepsakes. No-op until a save profile is loaded (GameState exists).
function ItemManager.apply_keepsake_reclaim()
  if ItemManager.setting_mode("keepsakesanity") == 0 then return end
  local s = APState.get()
  if not s then return end
  local n = 0
  for _, trait in pairs(KEEPSAKE_ITEM_TO_ID) do
    if not s.keepsake_ap_granted[trait] and not s.keepsake_check_sent[trait] then
      ItemManager.block_keepsake_award(trait)
      n = n + 1
    end
  end
  rom.log.info("[AP] keepsake reclaim: re-locked " .. n .. " keepsakes (re-gift the NPC to send its check)")
end

-- keepsakesanity: the Crossroads keepsake rack (GiftRack in DeathLoopData.lua) runs
-- SetupLockedGiftRack -> UseableOff whenever GameState.LifetimeResourcesGained.GiftPoints < 1,
-- i.e. until the player has gained Nectar at least once. With keepsakesanity the player earns
-- keepsakes as AP items and never touches Nectar, so the rack stays permanently locked and the
-- keepsakes can never be equipped. Bump lifetime GiftPoints to 1 (a cumulative counter, not
-- spendable currency) so the lock requirement fails and the rack stays useable. Idempotent.
-- Takes effect on the next Crossroads entry (SetupEvents re-run on each hub-room load).
function ItemManager.apply_keepsake_rack_unlock()
  if ItemManager.setting_mode("keepsakesanity") == 0 then return end
  pcall(function()
    local gs = game.GameState
    if not gs then return end
    gs.LifetimeResourcesGained = gs.LifetimeResourcesGained or {}
    if (gs.LifetimeResourcesGained.GiftPoints or 0) < 1 then
      gs.LifetimeResourcesGained.GiftPoints = 1
      rom.log.info("[AP] keepsake rack unlock: bumped LifetimeResourcesGained.GiftPoints -> 1 (re-enter Crossroads to open the rack)")
    end
  end)
end

-- Progressive keepsake: 1st item unlocks all keepsakes; the next two raise every
-- keepsake's level (KeepsakeChambers >= 25 for level 2, >= 50 for level 3).
local KEEPSAKE_LEVEL_CHAMBERS = { 0, 25, 50 }
local function apply_progressive_keepsake()
  local s = APState.get()
  if not s then return end
  s.keepsake_progress = (s.keepsake_progress or 0) + 1
  local n = s.keepsake_progress
  if n == 1 then
    for _, trait in pairs(KEEPSAKE_ITEM_TO_ID) do unlock_keepsake_trait(trait) end
  else
    local chambers = KEEPSAKE_LEVEL_CHAMBERS[n] or 50
    pcall(function()
      local gs = game.GameState
      if gs then
        gs.KeepsakeChambers = gs.KeepsakeChambers or {}
        for _, trait in pairs(KEEPSAKE_ITEM_TO_ID) do gs.KeepsakeChambers[trait] = chambers end
      end
    end)
  end
  rom.log.info("[AP] progressive keepsake -> step " .. n)
end

-- ---- "unlocked" modes (everything available, no items) ----------------------
-- Called once settings arrive: force-unlock all Aspects / Familiars when their
-- sanity is set to "unlocked" (mode 0).
function ItemManager.apply_unlocked_modes()
  if ItemManager.setting_mode("aspectsanity") == 0 then
    for _, ids in pairs(ASPECTS_BY_WEAPON) do
      for _, internal in ipairs(ids) do unlock_aspect_id(internal) end
    end
    rom.log.info("[AP] aspectsanity=unlocked -> all Aspects unlocked")
  end
  if ItemManager.setting_mode("petsanity") == 0 then
    for _, internal in ipairs(ItemManager.FAMILIAR_NAMES) do unlock_familiar_id(internal) end
    rom.log.info("[AP] petsanity=unlocked -> all Familiars unlocked")
  end
end

-- ---- "Start with more unlocked" (wishlist) ----------------------------------
-- QoL unlocks driven entirely from the IsGameStateEligible wrap (reload.lua), so they cost
-- nothing until a requirement actually references the gated content and never touch the save:
-- (1) the Oath of the Unseen obelisk shows up in the Crossroads from the start, (2) the
-- "helper" field-NPC encounters (Artemis/Heracles/Icarus/Nemesis) can show up the first time
-- you're in their area instead of after several runs / story beats, (3) all the gods that
-- are normally introduced gradually (Zeus/Hera/Ares/Hestia/Aphrodite/Hephaestus/Hermes/Selene)
-- are eligible to appear as boon/shop rewards from run 1 -- see "All gods available" below,
-- (4) the Arachne/Narcissus/Echo "give a gift" story rooms lose their extra story-progress
-- gate on top of just reaching their zone, and (5) Artemis/Heracles/Icarus/Nemesis/Athena's
-- combat-assist encounters can appear in every Underworld/Surface zone, not just their native
-- ones -- see "Helper encounters from the start" + "any location" below for (4)/(5).
-- Athena is intentionally absent from HELPER_INTRO_KEYS -- her intro has no story gate, so
-- she's already available; her own gap was zone coverage, handled by (5) instead.
local HELPER_INTRO_KEYS = {
  "ArtemisCombatIntro", "HeraclesCombatIntro", "IcarusCombatIntro", "NemesisCombatIntro",
}
-- Combat Helper Sanity cross-check: bare NPC cast name for each intro key above, so
-- eligibility_override can also block encounter SELECTION (not just spawn) while the
-- matching "<NPC> Helper" item hasn't arrived yet under combat_helper_sanity modes 1/3. See
-- eligibility_override's _helper_intro_reqs branch for why this is required, not optional --
-- the reload.lua HandleXSpawn no-op alone let the encounter still get chosen and crash later.
local HELPER_INTRO_KEY_TO_NPC = {
  ArtemisCombatIntro = "Artemis", HeraclesCombatIntro = "Heracles",
  IcarusCombatIntro = "Icarus", NemesisCombatIntro = "Nemesis",
}
-- Combat Helper Sanity, ALL locations (not just first-time intros): zerp-Extended_NPC_Encounters
-- adds many more per-NPC combat variants beyond *CombatIntro (e.g. NemesisCombatN/O/P/Tartarus/
-- Asphodel, ArtemisCombatH/I/O/P/Tartarus/Elysium, AthenaCombatF/G/I/N/Tartarus/Asphodel/Elysium,
-- ThanatosCombatN...), and reload.lua's HandleXSpawn wrap no-ops the SAME base spawn function for
-- every one of them, not just the Intro variant (its own comment: "Nemesis and Athena need only
-- one wrap each... native AND foreign zones already call the SAME base-game function"). So any of
-- these keys getting selected while combat_helper_eligible(npc) is false hits the identical fatal
-- "attempt to index local 'nemesis' (a nil value)" crash the Intro-only fix addressed -- confirmed
-- live 2026-07-21 ~3:17pm via NemesisCombatN (not NemesisCombatIntro), which the narrow
-- HELPER_INTRO_KEYS list above never covered. Scanned by key prefix against game.EncounterData
-- (resolve_eligibility_tables below) instead of hardcoding every variant, so new zerp additions are
-- covered automatically. Athena has no Intro key (see comment above) but her non-intro combat
-- encounters carry the exact same crash risk, so she's included here even though she's absent above.
local HELPER_COMBAT_PREFIXES = {
  Artemis = "ArtemisCombat", Heracles = "HeraclesCombat", Icarus = "IcarusCombat",
  Nemesis = "NemesisCombat", Athena = "AthenaCombat", Thanatos = "ThanatosCombat",
}
-- The god first-pickup/first-meeting narrative flags: Artemis's helper-intro gate counts
-- these (needs >= 4), and (per "All gods available" below) Hermes' and Selene's own unlock
-- gates need them too, so patching them all here covers both uses for free.
local HELPER_GOD_PICKUPS = {
  "PoseidonFirstPickUp", "DemeterFirstPickUp", "HestiaFirstPickUp",
  "AphroditeFirstPickUp", "ZeusFirstPickUp", "HephaestusFirstPickUp",
  "HermesFirstPickUp", "ArtemisFirstMeeting", "SeleneFirstPickUp",
}

-- All gods available from the start (wishlist "All gods are accessible from the beginning"):
-- normally most gods only enter the Boon/shop rotation after a story-gated "first meeting"
-- (Apollo/Poseidon/Demeter have no such gate and are already available from run 1). The
-- remaining gods' own LootData.GameStateRequirements (or, for Hermes/Selene, their
-- NamedRequirementsData entry) check a persistent GameState.TextLinesRecord/UseRecord flag
-- set by that first encounter. None of these have a per-run situational component (unlike
-- Hermes/Selene below, which also gate on per-run pacing we want to keep), so their whole
-- requirements table can just be forced true, like the Oath/Chaos/QuestLog overrides above.
local FORCE_GOD_UPGRADES = {
  "ZeusUpgrade", "HeraUpgrade", "AresUpgrade", "HestiaUpgrade", "AphroditeUpgrade", "HephaestusUpgrade",
}
-- Hermes (shop) and Selene (spell shop) use the same story-gate mechanism, but their named
-- requirements also carry per-run pacing (don't reoffer if already used/in-store this run) that
-- should stay intact, so they go through the "patch" path (eval_helper_intro) instead of a
-- full force-true.
local PATCH_NAMED_REQUIREMENTS = { "HermesUpgradeRequirements", "SpellDropRequirements" }

-- GodSanity (F_Opening01 intro chain): the very first Underworld room (RoomDataF.lua
-- F_Opening01, GameStart=true) carries its OWN ForcedRewards array -- an entire native
-- "next new god to meet" sequencing chain (Zeus, Demeter, Poseidon x2, Hestia, Aphrodite,
-- Hera, Ares, Hephaestus, Selene/SpellDrop, Hermes-in-person), each entry gated on a plain
-- UseRecord/NamedRequirements condition, resolved by RewardLogic.lua's forcedRewards loop
-- (first entry whose GameStateRequirements passes wins, LootName taken directly -- same
-- ChooseLoot/GetEligibleLootNames bypass as F_Combat01's single Apollo entry below).
-- A prior comment here claimed "F_Opening01 has no ForcedRewards field at all" -- that was
-- wrong (confirmed live 2026-07-21 by re-reading the actual installed RoomDataF.lua: it
-- starts at line 478) -- a locked god (e.g. Demeter, once the save's lifetime
-- UseRecord.ApolloUpgrade is set from any earlier run) was being force-handed out on run 1
-- of a fresh GodSanity save with nothing blocking it. Unlike F_Combat01 (its room's ONLY
-- reward path, needing a redirect to an alternate reward type), this array has many entries
-- AND the room's own ForcedRewardStore="RunProgress" as an ultimate fallback -- both already
-- safely gated elsewhere -- so simply returning "false" for a locked entry is enough: the
-- native forcedRewards loop just moves on to the next entry (see eligibility_override).
local FORCED_INTRO_GOD_KEY_BY_LOOT = {
  ZeusUpgrade = "ZeusUpgrade", DemeterUpgrade = "DemeterUpgrade", PoseidonUpgrade = "PoseidonUpgrade",
  HestiaUpgrade = "HestiaUpgrade", AphroditeUpgrade = "AphroditeUpgrade", HephaestusUpgrade = "HephaestusUpgrade",
  HeraUpgrade = "HeraUpgrade", AresUpgrade = "AresUpgrade", ApolloUpgrade = "ApolloUpgrade",
  HermesUpgrade = "Hermes",
}

-- ---- "Helper encounters from the start" + "any location" (wishlist) --------------------------
-- Two distinct kinds of Underworld/Surface NPC content, per user clarification:
--   (1) "Helper" STORY rooms -- empty rooms with one ally NPC who gives a gift/keepsake, no
--       combat: Arachne(F)/Narcissus(G)/Echo(H) in the Underworld, Hades(I)/Medea(N)/Circe(O)/
--       Dionysus(P). Arachne/Narcissus/Echo additionally have a real story-progress gate
--       (BiomeDepthCache range + that zone's miniboss/boss clear + a first-meeting flag) on top
--       of just reaching their zone -- collect_story_room_force_keys forces those true.
--       BUT (correction after user playtest report: Medea/Dionysus "never" showing up, Echo
--       also affected) having no such gate does NOT mean a room reliably appears -- passing
--       GameStateRequirements only gets a room into the `eligibleRooms` CANDIDATE pool for its
--       door (RunLogic.lua ChooseNextRoomData/IsRoomEligible); it then competes at ordinary
--       random odds against every other room type UNLESS a separate mechanism guarantees
--       selection (IsRoomForced). F/G/I/N_Story01 rely on `ForceIfUnseenForRuns` natively (a
--       genuine pity timer -- guaranteed once unseen for N runs, not every run) --
--       F(3)/G(6)/I(6)/N(3), which just never got a real chance to fire while the
--       GameStateRequirements gate was blocking eligibility for run after run -- now that the
--       gate's forced true, the timer can finally count from run 1. O(Circe)/P(Dionysus) have NO
--       such fallback at all in the game's own data -- pure random competition, forever -- and a
--       same-session attempt to add one (matching the other 4) was explicitly REVERTED per user
--       request (2026-07-17): both keep pure native odds, no pity timer, by choice.
--       H_Bridge01 (Echo's room) is structurally different: it's ALREADY `AlwaysForce=true`
--       natively (a guaranteed "bridge crossing"), so its selection was never the issue -- Echo's
--       problem was purely the GameStateRequirements gate on its "Story" reward slot, already
--       fixed by collect_story_room_force_keys; no pity timer needed there.
--   (2) Combat-ASSIST NPCs -- Artemis/Heracles/Icarus/Nemesis/Athena (base game) + Thanatos
--       (Nightmare route, see apply_nightmare_helpers_unlock), who show up to help fight (or, for
--       Nemesis, sometimes clear the room before you arrive -- NemesisRandomEvent, her second,
--       non-combat variant). Each is native to only 1-4 of the 10 total zones across all 3
--       routes (F/G/H/I Erebus/Oceanus/Fields/Tartarus[Underworld], N/O/P
--       Ephyra/Thessaly/Olympus[Surface], Tartarus/Asphodel/Elysium[Nightmare, Thanatos-only]).
--       Rather than trying to get a foreign zone's pool to accept a guest encounter (five
--       increasingly-elaborate attempts at that, see [[project_helper_npcs_any_location]] passes
--       1-5, then a working-but-narrower Handle<God>Spawn function-redirect pass), which god
--       appears in which zone is now delegated to the third-party `zerp-Extended_NPC_Encounters`
--       dependency, which covers all 6 NPCs (including Thanatos) across all zones in both
--       directions, including Nightmare -- see the header comment further down where the
--       redirect_helper_spawn machinery used to live.
-- The Nightmare-route helpers (Sisyphus/Eurydice/Patroclus) are a SEPARATE mod (Zagreus'
-- Journey) with its own data-loading pipeline -- see apply_nightmare_helpers_unlock, which
-- mirrors the story-room fixes above (gate-stripping + pity-timer) for that route's equivalents.

-- H_Bridge01's Story-reward sub-gate and Story_Echo_01's own gate (Echo doubly-gated: the Bridge
-- room only OFFERS its "Story" reward slot once RoomsEntered.H_Boss01 is true, and the encounter
-- itself re-checks the same flag). Both are one-time story flags with no per-run situational
-- component, so force-true is as safe as the Oath/Chaos/QuestLog overrides above. (Which NPC
-- actually appears in H_Bridge01 -- Echo vs. a different story NPC -- is now the
-- zerp-NPCRoomRandomizer dependency's job, not ours; this just keeps her eligible.)
local function collect_story_room_force_keys(rsd, ed, out)
  local hBridge = rsd and rsd.H and rsd.H.H_Bridge01
  local storyReward = hBridge and hBridge.ForcedRewards and hBridge.ForcedRewards[1]
  if storyReward and storyReward.Name == "Story" and storyReward.GameStateRequirements then
    out[storyReward.GameStateRequirements] = true
  end
  local echo = ed.Story_Echo_01
  if echo and echo.GameStateRequirements then out[echo.GameStateRequirements] = true end
end

-- REDESIGNED per user feedback -- a same-session flat "% chance, replacing the whole table" layer
-- (ChanceToPlay-style) was tried first and reverted: "I think we're remaking the wheel here.
-- Can't we just use the exact same odds that they already have built in for these rooms, and then
-- just randomize which rooms show up?" Investigating WHY these felt like "always the literal
-- first room" confirmed exactly that diagnosis: F_Story01/G_Story01's own native
-- GameStateRequirements is NOT just the BiomeDepthCache window (4-8 / 3-6) -- it ALSO gates on two
-- GameState (lifetime, whole-save) progression flags an AP player has no natural way to have
-- earned yet: RoomsEntered.F_Boss01/G_Boss01 (cleared that zone's boss at least once, EVER) and
-- TextLinesRecord.ArtemisFirstMeeting (Artemis's own first-meeting beat has fired at least once,
-- EVER). The ORIGINAL pass-1 fix for this feature force-bypassed the ENTIRE table to solve that --
-- which also bypassed the depth window, making the room eligible from depth 1, not just 4-8/3-6.
-- Combined with the native ForceIfUnseenForRuns pity timer, that's precisely "forced at literally
-- the zone's first door, every time it's due."
-- Fix: same surgical technique already used for MiniBoss rooms (apply_miniboss_unlock, right
-- below) -- strip ONLY the specific lifetime-flag array entries, leaving the BiomeDepthCache
-- window, the CURRENT-run "haven't already triggered this beat this run" dedup, and
-- NamedRequirementsFalse all genuinely native/untouched. No eligibility_override entry needed for
-- F/G at all anymore -- IsGameStateEligible evaluates their (now-trimmed) table completely
-- normally, through base(), exactly like any other room in the game.
-- I_Story01(Hades)/N_Story01(Medea)/O_Story01(Circe)/P_Story01(Dionysus) need nothing here: they
-- never had a GameStateRequirements table at all (confirmed pass 1) and stay that way -- pure
-- native pool competition, same as vanilla. I/N carry a native ForceIfUnseenForRuns pity timer;
-- O/P don't, and (per user request 2026-07-17) that's staying as pure native odds, not being
-- patched to match.
-- Nightmare's A/X/Y_Story01 are untouched by any of this -- separate DSL, see
-- apply_nightmare_helpers_unlock.
local STORY_ROOM_LIFETIME_GATES = {
  { zone = "F", room = "F_Story01", paths = {
      { "GameState", "RoomsEntered", "F_Boss01" },
      { "GameState", "TextLinesRecord", "ArtemisFirstMeeting" },
  } },
  { zone = "G", room = "G_Story01", paths = {
      { "GameState", "RoomsEntered", "G_Boss01" },
  } },
}
local function path_equals(a, b)
  if not (a and b) or #a ~= #b then return false end
  for i = 1, #a do
    if a[i] ~= b[i] then return false end
  end
  return true
end
local function is_targeted_lifetime_gate(cond, paths)
  if type(cond) ~= "table" then return false end
  for _, p in ipairs(paths) do
    if path_equals(cond.PathTrue, p) or path_equals(cond.Path, p) then return true end
  end
  return false
end
local function apply_story_room_lifetime_unlock(rsd)
  for _, entry in ipairs(STORY_ROOM_LIFETIME_GATES) do
    local copies = {}
    if game.RoomData then copies[#copies + 1] = game.RoomData[entry.room] end
    local zoneData = rsd and rsd[entry.zone]
    if zoneData then copies[#copies + 1] = zoneData[entry.room] end
    for _, room in ipairs(copies) do
      local reqs = room and room.GameStateRequirements
      if reqs then
        local touched = false
        for i = #reqs, 1, -1 do
          if is_targeted_lifetime_gate(reqs[i], entry.paths) then
            table.remove(reqs, i)
            touched = true
          end
        end
        if touched then
          rom.log.info("[AP] " .. entry.room .. " story-room lifetime gate(s) stripped"
            .. " (native depth window + pity timer are now the only remaining gate)")
        end
      end
    end
  end
end

-- Selection-odds pity timer for O_Story01(Circe)/P_Story01(Dionysus) -- REMOVED per user request
-- (2026-07-17): both keep pure native pool competition with no `ForceIfUnseenForRuns`, same as
-- they always did without this feature, unlike F/G/I/N which carry one natively. (Previously this
-- added `ForceIfUnseenForRuns=3` to both, matching the other 4 base-game story rooms' own native
-- pity timers, so Circe/Dionysus couldn't go unseen indefinitely by pure bad luck -- removed by
-- explicit choice, not a bug.)

-- Wishlist: "make it so that all minibosses are equally likely to spawn at the very beginning as
-- they would be in the endgame, making locations like Master-Slicer achievable when the logic
-- thinks they should be." Confirmed against the real game source (RoomData<Zone>.lua): most
-- MiniBoss rooms have no cross-run gate and are already equally likely from run 1 -- but six carry
-- a `GameStateRequirements` entry that reads GameState.EncountersCompletedCache/
-- EncountersOccurredCache (LIFETIME meta-progress, unlike the CurrentRun.RoomsEntered
-- self-exclusion entries every MiniBoss room also carries to avoid offering two minibosses off the
-- same door), so the room can't even be SELECTED until the player has already cleared other
-- content across past runs:
--   F_MiniBoss02 (MiniBossFogEmitter):        EncountersCompletedCache.MiniBossTreant >= 2
--   F_MiniBoss03 (MiniBossAssassin/Master-Slicer): same, + HasAll{BossChronos01,BossPolyphemus01,ZombieAssassinIntro}
--   G_MiniBoss02 (MiniBossCrawler/King Vermin): EncountersCompletedCache.{MiniBossWaterUnit,MiniBossJellyfish} both true
--   O_MiniBoss02 (MiniBossCaptain):            EncountersCompletedCache.MiniBossCharybdis >= 1
--   Q_MiniBoss04 (BossTyphonEye01):            EncountersCompletedCache.BossTyphonTail01 true
--   Q_MiniBoss05 (MiniBossStalker/Twins of Typhon): EncountersCompletedCache.MiniBossBrute true
-- Strips ONLY the matching entries (by Path/PathTrue/PathFalse prefix) from each room's
-- GameStateRequirements, leaving every other entry (CurrentRun self-exclusion, O's
-- BiomeDepthCache range) intact so normal per-run room selection is otherwise unchanged. A room
-- left with an empty GameStateRequirements table is a normal, already-used state elsewhere in the
-- game's own data (e.g. MiniBossDragon), so that's safe. O_MiniBoss01's separate
-- AlwaysForceRequirements (a "guarantee it the very first time" pity mechanic, not a gate) is
-- deliberately untouched.
--
-- Crash postmortem (2026-07-18, ~8:05pm): stripping the ROOM gate isn't the whole story for
-- G_MiniBoss02. Its LegalEncounters entry, MiniBossCrawler (EncounterData_MiniBoss.lua), carries
-- its OWN separate GameStateRequirements (PathTrue EncountersCompletedCache.MiniBossWaterUnit)
-- that the room-level strip never touched. On a fresh profile the room becomes selectable but
-- ChooseEncounter's LegalEncounters={"MiniBossCrawler"} pool still filters down to zero eligible
-- entries, GetRandomValue returns nil, and vanilla ChooseEncounter hard-crashes indexing
-- encounterData.EnemySet (RunLogic.lua:1079) -- exactly the crash our ChooseEncounter pcall guard
-- (below) exists to catch. The guard falls back to a generic GeneratedG encounter so the run
-- survives, but that means MiniBossCrawler's own StartRoomUnthreadedEvents (which sets
-- GameState.EncountersOccurredCache.MiniBossCrawler) never runs -- while the ROOM's presentation
-- script (PresentationBiomeG.lua:255/287) still fires the Crawler intro cutscene regardless of
-- which encounter filled the room, and does a raw `EncountersOccurredCache.MiniBossCrawler > 1`
-- comparison. nil > 1 is a hard Lua error with no pcall around it -- THIS is what actually crashed
-- the game. Fix: strip the matching lifetime entries from the ENCOUNTER data too (same filter,
-- applied to game.EncounterData[name] instead of the room), so ChooseEncounter never fails for
-- MiniBossCrawler in the first place and the whole fallback path is never entered. The other five
-- rooms' own encounters carry no such gate today (verified against game source) so this is a
-- no-op for them -- kept anyway as a cheap guard against the same class of bug if that changes.
local MINIBOSS_UNLOCK_ROOMS = {
  { zone = "F", room = "F_MiniBoss02", encounters = { "MiniBossFogEmitter", "MiniBossFogEmitter_Shrine" } },
  { zone = "F", room = "F_MiniBoss03", encounters = { "MiniBossAssassin" } },
  { zone = "G", room = "G_MiniBoss02", encounters = { "MiniBossCrawler" } },
  { zone = "O", room = "O_MiniBoss02", encounters = { "MiniBossCaptain" } },
  { zone = "Q", room = "Q_MiniBoss04", encounters = { "BossTyphonEye01" } },
  { zone = "Q", room = "Q_MiniBoss05", encounters = { "MiniBossStalker" } },
}
local function is_lifetime_encounter_path(path)
  return path and path[1] == "GameState"
    and (path[2] == "EncountersCompletedCache" or path[2] == "EncountersOccurredCache")
end
local function strip_lifetime_gate(reqs)
  if not reqs then return false end
  local touched = false
  for i = #reqs, 1, -1 do
    local cond = reqs[i]
    if type(cond) == "table" and (is_lifetime_encounter_path(cond.Path)
        or is_lifetime_encounter_path(cond.PathTrue)
        or is_lifetime_encounter_path(cond.PathFalse)) then
      table.remove(reqs, i)
      touched = true
    end
  end
  return touched
end
local function apply_miniboss_unlock(rsd)
  for _, entry in ipairs(MINIBOSS_UNLOCK_ROOMS) do
    local copies = {}
    if game.RoomData then copies[#copies + 1] = game.RoomData[entry.room] end
    local zoneData = rsd and rsd[entry.zone]
    if zoneData then copies[#copies + 1] = zoneData[entry.room] end
    for _, room in ipairs(copies) do
      if strip_lifetime_gate(room and room.GameStateRequirements) then
        rom.log.info("[AP] " .. entry.room
          .. " miniboss lifetime-progress gate stripped (equally likely from run 1)")
      end
    end
    if game.EncounterData then
      for _, encounterName in ipairs(entry.encounters or {}) do
        local encounterDef = game.EncounterData[encounterName]
        if strip_lifetime_gate(encounterDef and encounterDef.GameStateRequirements) then
          rom.log.info("[AP] " .. encounterName
            .. " encounter lifetime-progress gate stripped (own-encounter eligibility, room "
            .. entry.room .. ")")
        end
      end
    end
  end
end

-- Artemis/Heracles/Icarus/Nemesis/Athena "any location" -- REMOVED per user request (session
-- 2026-07-17) in favor of the third-party `zerp-Extended_NPC_Encounters` mod (added as a manifest
-- dependency). See [[project_helper_npcs_any_location]] for the full history of our own version
-- (5 redesign passes fighting the game's zone-pool eligibility system, then a Handle<God>Spawn
-- function-redirect that DID work but only covered 5 gods across the 7 base zones -- never
-- Nightmare, never Thanatos). Extended_NPC_Encounters covers strictly more: all 6 NPCs (adds
-- Thanatos) with per-zone config toggles including Nightmare's 3 zones both directions (the 5 base
-- gods appearing in Tartarus/Asphodel/Elysium, AND Thanatos appearing in the 7 base zones), a
-- per-NPC weight, and a `dream_dive_only` option -- a strict superset of what redirect_helper_spawn
-- did. apply_nightmare_helpers_unlock (below) is UNRELATED and unchanged -- that's the "eligible
-- from run 1" gate-stripping feature, not the cross-NPC redirect this replaces.

-- Category 1 -- static "story" helper rooms (Arachne/Narcissus/Echo/Hades/Medea/Circe/Dionysus +
-- Nightmare's Sisyphus/Eurydice/Patroclus), cross-NPC randomization. Previously implemented here
-- as a homegrown whole-room CreateRoom substitution (redirect_static_helper_room) -- see
-- [[project_helper_npcs_any_location]] for that whole history, including two rounds of bugs found
-- via playtest (Soul Pylon direction, and Medea's native LinkedRoom="N_Hub" hijacking the "return
-- to your real zone" exit routing). REMOVED per user request in favor of the third-party
-- `zerp-NPCRoomRandomizer` mod (added as a manifest dependency), which already solves the exact
-- same problem more thoroughly -- it covers all 10 rooms including Echo (H_Bridge01, deliberately
-- left out of our own version), has native Zagreus' Journey support, and its changelog shows
-- several already-fixed edge cases (Soul Pylon handling, Charon-fight transitions, Chaos/Erebus
-- gate transitions, reward previews, ModsNikkelMHadesBiomesIsModdedRun toggling) that our own
-- version either hadn't hit yet or had only partially patched. Category 2 (combat-assist NPCs) is
-- ALSO now delegated to a third-party dependency (`zerp-Extended_NPC_Encounters`, see the comment
-- above) instead of our own redirect_helper_spawn -- neither category has any homegrown redirect
-- code left in this file.
-- collect_story_room_force_keys / apply_story_room_lifetime_unlock (above) are a SEPARATE,
-- unrelated feature (making these rooms eligible from run 1) and are kept as-is -- NPCRoomRandomizer
-- only decides WHICH NPC appears once the game has already decided "a story room happens here,"
-- same division of responsibility Extended_NPC_Encounters has for Category 2. (The O/P pity-timer
-- piece of this same feature was removed per user request 2026-07-17 -- see
-- apply_story_room_lifetime_unlock's own header for detail.)

-- Lazily resolve (and cache) the exact game requirement TABLES we override, by identity.
-- Done on first use because the game's data tables (NamedRequirementsData / EncounterData)
-- are populated at boot, before any hub/encounter requirement is evaluated. _resolved stays
-- false until both tables exist so a too-early call simply passes through (no override yet).
-- QuestLog (Fated List) crossroads pedestal = HubRoomData.Hub_Main.ObstacleData[560662]
-- (DeathLoopData.lua ~4195). Two anonymous (non-named) gates control it:
--   .SetupGameStateRequirements            -> PathTrue TextLinesRecord.MorosGrantsQuestLog
--   .SetupEvents[1].GameStateRequirements  -> PathTrue WorldUpgradesAdded.WorldUpgradeQuestLog
--     (the OverwriteSelf that actually wires UseText/OnUsedFunctionName=UseQuestLog; without
--     this the pedestal can appear but do nothing when interacted with)
-- Both are simple one-time story flags (no per-run situational component like the helper
-- intros), so force-true is safe. Separately, QuestLogUnlocked (RequirementsData.lua:93, a
-- NAMED requirement) gates the Fated List's LOGIC (CodexLogic menu icon, QuestLogLogic
-- CheckQuestStatus/HasActiveQuestForName) -- force that true too so quest tracking/menu access
-- works immediately, not just the pedestal's presence.
local QUESTLOG_OBJECT_ID = 560662

ItemManager._elig_resolved = false
ItemManager._force_true_reqs = nil        -- set: { [<requirements table>] = true }
ItemManager._helper_intro_reqs = nil      -- set: { [<intro>.GameStateRequirements] = true }
ItemManager._helper_combat_reqs = nil     -- map: { [<any Combat variant>.GameStateRequirements] = "<NPC>" }, block-only (no "patch")
ItemManager._god_upgrade_reqs = nil       -- map: { [<requirements table>] = "<God>Upgrade" (FORCE_GOD_UPGRADES entry) }
ItemManager._apollo_intro_reqs = nil      -- set: { [ForcedRewards GameStateRequirements identity] = true }, F_Combat01 + ZJ's RoomSimple01 (see below)
ItemManager._forced_intro_god_reqs = nil  -- map: { [F_Opening01 ForcedRewards entry's GameStateRequirements] = god_eligible key }

local function resolve_eligibility_tables()
  if ItemManager._elig_resolved then return true end
  local nrd = game.NamedRequirementsData
  local ed = game.EncounterData
  local hrd = game.HubRoomData
  local ld = game.LootData
  local rsd = game.RoomSetData
  local es = game.EncounterSets
  if not (nrd and ed and hrd and ld and rsd and es) then return false end
  local force = {}
  collect_story_room_force_keys(rsd, ed, force)
  apply_story_room_lifetime_unlock(rsd)
  apply_miniboss_unlock(rsd)
  -- Combat-assist helper redirect (Category 2) is not resolved here at all anymore -- it's
  -- handled by the zerp-Extended_NPC_Encounters dependency, not a table mutation on any of the
  -- tables this resolver touches.
  if nrd.ShrineUnlocked then force[nrd.ShrineUnlocked] = true end
  if nrd.ChaosUnlocked then force[nrd.ChaosUnlocked] = true end
  if nrd.QuestLogUnlocked then force[nrd.QuestLogUnlocked] = true end
  local hubMain = hrd.Hub_Main
  local qlObj = hubMain and hubMain.ObstacleData and hubMain.ObstacleData[QUESTLOG_OBJECT_ID]
  if qlObj then
    if qlObj.SetupGameStateRequirements then force[qlObj.SetupGameStateRequirements] = true end
    local overwriteSelf = qlObj.SetupEvents and qlObj.SetupEvents[1]
    if overwriteSelf and overwriteSelf.GameStateRequirements then
      force[overwriteSelf.GameStateRequirements] = true
    end
  end
  -- GodSanity: these 9 gates are NOT added to `force` (unconditional true) -- unlike
  -- Oath/Chaos/QuestLog above, whether a god's native story-gate should be bypassed depends on
  -- live GodSanity state (locked until its "<God> Unlock" item arrives), so each is cached by
  -- identity here and resolved per-check in eligibility_override below, the same pattern already
  -- used for Hermes/Selene (_hermes_upgrade_req/_selene_spelldrop_req). Note: a prior bug where
  -- these WERE added to `force` unconditionally let a locked god's boon
  -- (e.g. Zeus) into GetEligibleLootNames' pool from run 1 regardless of GodSanity, bypassing the
  -- SpawnRoomReward reroll (reload.lua) entirely for "Devotion" (duo/companion) boon doors, which
  -- have no such correction hook.
  local godUpgradeReqs = {}
  local godsForced = 0
  for _, name in ipairs(FORCE_GOD_UPGRADES) do
    local loot = ld[name]
    if loot and loot.GameStateRequirements then
      godUpgradeReqs[loot.GameStateRequirements] = name
      godsForced = godsForced + 1
    end
  end
  ItemManager._god_upgrade_reqs = godUpgradeReqs
  -- Cached separately (not added to `force` here): only forced true conditionally, when
  -- Zagreus is part of the goal and Vanilla is the chosen encounter mode. See
  -- eligibility_override below for why this is InfernalContractUnlocked specifically and not
  -- the outer StoreData.ZagreusContractRequirement.
  ItemManager._infernal_contract_req = nrd.InfernalContractUnlocked
  -- Outer table, identity-matched separately so it can be forced false for Vanilla/Empowered too
  -- (see eligibility_override) -- ItemManager.apply_zagreus_contract_everywhere supersedes this
  -- vanilla mechanism entirely, so it must never ALSO fire. game.StoreData may not exist on every
  -- build; nil here just means that override never matches, same as any other lazily-resolved
  -- table below.
  local sd = game.StoreData
  ItemManager._zagreus_contract_req = sd and sd.ZagreusContractRequirement
  -- Moros hub appearance: Doomed Beckoning force-grants WorldUpgradeMorosUnlock (fires the
  -- incantation cutscene), but Moros only SPAWNS in the Crossroads when his NPC
  -- ActivateRequirements pass -- and those resolve NamedRequirementsData.MorosUnlockedInHub,
  -- which ALSO demands WorldUpgradeQuestLog, the TextLinesRecord story beats MorosGrantsQuestLog
  -- + MorosSecondAppearance, and ScreensViewed.QuestLog. An AP player never earns those from the
  -- item alone (the Fated List is opened via THIS eligibility override, not by writing those
  -- GameState flags), so vanilla evaluates MorosUnlockedInHub false and he never shows. Cached
  -- separately and forced true only once Doomed Beckoning has actually been received (see
  -- eligibility_override), so he still stays hidden until the item arrives.
  ItemManager._moros_hub_req = nrd.MorosUnlockedInHub
  -- GodSanity (Hermes/Selene): cached separately by identity, same shape as _moros_hub_req,
  -- so eligibility_override can block them outright (return "false") while not yet unlocked,
  -- ahead of the existing "patch" handling below that only ever relaxes their PACING gates
  -- (per-run cooldowns etc.), never their existence.
  ItemManager._hermes_upgrade_req = nrd.HermesUpgradeRequirements
  ItemManager._selene_spelldrop_req = nrd.SpellDropRequirements
  -- GodSanity (F_Combat01 intro): RoomDataF.lua F_Combat01 -- LootName="ApolloUpgrade",
  -- GameStateRequirements PathFalse UseRecord.ApolloUpgrade, i.e. "force Apollo until the save
  -- has ever gotten an Apollo boon, ever" -- the room's ONLY defined reward path, hence the
  -- redirect-to-alt-reward handling in eligibility_override below (see
  -- redirect_apollo_intro_reward's own comment). Cached by identity like Moros/Hermes/Selene
  -- above so eligibility_override can skip it outright.
  -- Zagreus' Journey (Nightmare route) carries its OWN copy of this exact same forced-Apollo
  -- entry: RoomDataTartarus.lua's RoomSimple01 ("Mirrors vanilla ForcedRewards on fresh file"),
  -- same LootName/PathFalse-UseRecord.ApolloUpgrade shape, registered under
  -- game.RoomSetData.Tartarus (not rsd.F) -- a totally separate table identity from F_Combat01's,
  -- so the single-value cache never matched it. Confirmed live 2026-07-22: a fresh Nightmare-start
  -- run (godsanity=2, Apollo not unlocked) got a real unblocked Apollo boon via RoomSimple01
  -- (RunDepth=3, EnemyIntroFight01) exactly like the F_Combat01 leak this section was already
  -- fixed for. Both rooms' entries are now collected into one identity SET so
  -- eligibility_override can block/redirect either.
  local apolloReqs = {}
  local fCombat01 = rsd.F and rsd.F.F_Combat01
  local apolloForced = fCombat01 and fCombat01.ForcedRewards and fCombat01.ForcedRewards[1]
  if apolloForced and apolloForced.GameStateRequirements then
    apolloReqs[apolloForced.GameStateRequirements] = true
  end
  local zjRoomSimple01 = rsd.Tartarus and rsd.Tartarus.RoomSimple01
  local zjApolloForced = zjRoomSimple01 and zjRoomSimple01.ForcedRewards and zjRoomSimple01.ForcedRewards[1]
  if zjApolloForced and zjApolloForced.GameStateRequirements then
    apolloReqs[zjApolloForced.GameStateRequirements] = true
  end
  ItemManager._apollo_intro_reqs = apolloReqs
  -- GodSanity (F_Opening01/02/03 intro chain): see FORCED_INTRO_GOD_KEY_BY_LOOT's own comment
  -- above. F_Opening02/03 (RoomDataF.lua) are `InheritFrom = { "F_Opening01", "BaseF" }` and
  -- never redeclare their own ForcedRewards, so at a data-authoring level all three share the
  -- "same" chain -- but confirmed live 2026-07-21 (a locked Poseidon boon handed out via
  -- F_Opening02, room-scoped log line "RoomName=F_Opening02", right after the F_Opening01-only
  -- version of this fix shipped) that the game's InheritFrom resolution deep-copies inherited
  -- fields per room rather than sharing the table reference -- so F_Opening02/03's entries have
  -- their OWN distinct GameStateRequirements identities, never matched by a cache built only
  -- from F_Opening01. Scanned separately per room instead of assuming a shared identity.
  local openingForced = {}
  for _, roomName in ipairs({ "F_Opening01", "F_Opening02", "F_Opening03" }) do
    local room = rsd.F and rsd.F[roomName]
    if room and room.ForcedRewards then
      for _, entry in ipairs(room.ForcedRewards) do
        local godKey
        if entry.Name == "Boon" and entry.LootName then
          godKey = FORCED_INTRO_GOD_KEY_BY_LOOT[entry.LootName]
        elseif entry.Name == "SpellDrop" then
          godKey = "Selene"
        end
        if godKey and entry.GameStateRequirements then
          openingForced[entry.GameStateRequirements] = godKey
        end
      end
    end
  end
  ItemManager._forced_intro_god_reqs = openingForced
  ItemManager._force_true_reqs = force
  local set = {}
  for _, key in ipairs(HELPER_INTRO_KEYS) do
    local e = ed[key]
    if e and e.GameStateRequirements then
      set[e.GameStateRequirements] = HELPER_INTRO_KEY_TO_NPC[key]
    end
  end
  for _, key in ipairs(PATCH_NAMED_REQUIREMENTS) do
    if nrd[key] then set[nrd[key]] = true end
  end
  ItemManager._helper_intro_reqs = set
  -- Combat Helper Sanity, ALL locations: block-only companion to the set above (see
  -- HELPER_COMBAT_PREFIXES). Every EncounterData key is checked once here (cheap, cached behind
  -- _elig_resolved) instead of hardcoding each zerp-added variant by name.
  local combatSet = {}
  local combatCount = 0
  for key, e in pairs(ed) do
    if e and e.GameStateRequirements and type(key) == "string" then
      for npc, prefix in pairs(HELPER_COMBAT_PREFIXES) do
        if key:sub(1, #prefix) == prefix then
          combatSet[e.GameStateRequirements] = npc
          combatCount = combatCount + 1
          break
        end
      end
    end
  end
  ItemManager._helper_combat_reqs = combatSet
  -- Helper Room Sanity (items/items_random): each of the 6 base-game story rooms' own native
  -- GameStateRequirements table, by identity, so eligibility_override can block a story room
  -- from ever becoming eligible while the NPC it would resolve to isn't unlocked -- see that
  -- function's own comment for the full rationale (this replaces the old interaction-only lock,
  -- which caused a real softlock). Deliberately covers only F/G/I/N/O/P_Story01: Nightmare's
  -- A/X/Y_Story01 use Zagreus' Journey's own flat H1-ported requirement DSL (RequiredMinBiomeDepth
  -- etc. as top-level room fields, no nested GameStateRequirements table -- see
  -- apply_nightmare_helpers_unlock's header), so there's no identity to cache here; those 3 rely
  -- on the SelectRandomStoryRoom filter alone (reload.lua) plus its safe fallback. H_Bridge01/Echo
  -- also excluded: a mandatory bridge crossing can never be hidden.
  local storyRoomReqs = {}
  local storyRoomsGated = 0
  for _, key in ipairs({ "F_Story01", "G_Story01", "I_Story01", "N_Story01", "O_Story01", "P_Story01" }) do
    local npc = ItemManager.STORY_ROOM_TO_NPC[key]
    local zoneData = rsd[key:sub(1, 1)]
    local copies = {}
    if zoneData and zoneData[key] then copies[#copies + 1] = zoneData[key] end
    if game.RoomData and game.RoomData[key] then copies[#copies + 1] = game.RoomData[key] end
    for _, room in ipairs(copies) do
      if room.GameStateRequirements then
        storyRoomReqs[room.GameStateRequirements] = npc
        storyRoomsGated = storyRoomsGated + 1
      end
    end
  end
  ItemManager._story_room_native_reqs = storyRoomReqs
  ItemManager._elig_resolved = true
  rom.log.info("[AP] eligibility overrides resolved (ShrineUnlocked="
    .. tostring(nrd.ShrineUnlocked ~= nil)
    .. ", ChaosUnlocked=" .. tostring(nrd.ChaosUnlocked ~= nil)
    .. ", QuestLogUnlocked=" .. tostring(nrd.QuestLogUnlocked ~= nil)
    .. ", QuestLog pedestal=" .. tostring(qlObj ~= nil)
    .. ", god upgrade gates resolved=" .. godsForced .. "/" .. #FORCE_GOD_UPGRADES
    .. ", helper/god-shop intros=" .. tostring(next(set) ~= nil)
    .. ", helper combat variants gated=" .. combatCount
    .. ", story-room force keys=" .. tostring(next(force) ~= nil)
    .. ", story-room native eligibility gates=" .. storyRoomsGated .. "/6)")
  return true
end

-- F_Combat01's ForcedRewards entry (see the apollo_intro_req branch of eligibility_override
-- below) is the ONLY defined reward path for that room -- blocking its eligibility with nothing
-- else set leaves SetupRoomReward with nothing to give, which vanilla resolves to
-- RoomRewardConsolationPrize (a fixed small-heal "Onion") by default, same as scale_boon_entries'
-- own doc explains for a Boon-only store elsewhere. Unlike a normal store roll, this specific
-- room never reaches GetRewardStoreData on its own to give scale_boon_entries a chance to pad
-- it, so this reroutes concretely: pick a real alternate reward from the room's own live
-- RewardStoreName store instead (excluding Boon, respecting the room's own Eligible/
-- IneligibleRewards filters, same shape as the room's normal reward resolution would use).
-- No-ops (leaves the Onion fallback in place) only if that store is truly unavailable or has
-- nothing else in it.
function ItemManager.redirect_apollo_intro_reward()
  local room = game.CurrentRun and game.CurrentRun.CurrentRoom
  if not room then return end
  local storeName = room.RewardStoreName
  local store = storeName and game.CurrentRun.RewardStores and game.CurrentRun.RewardStores[storeName]
  if not store then return end
  local altNames = {}
  for _, entry in ipairs(store) do
    local n = entry.Name
    if n and n ~= "Boon"
        and (room.EligibleRewards == nil or Contains(room.EligibleRewards, n))
        and (room.IneligibleRewards == nil or not Contains(room.IneligibleRewards, n)) then
      table.insert(altNames, n)
    end
  end
  if #altNames > 0 then
    room.ChangeReward = altNames[math.random(#altNames)]
  end
end

-- Classify a requirements table for the IsGameStateEligible wrap:
--   "true"  -> force eligible unconditionally (Oath/ShrineUnlocked, Chaos Gates/ChaosUnlocked,
--              Fated List pedestal + QuestLogUnlocked, and each force-unlocked god's own
--              LootData.GameStateRequirements -- see FORCE_GOD_UPGRADES)
--   "patch" -> evaluate normally but with the helper/god story-unlock gates temporarily
--              satisfied (helper NPC intros, and Hermes'/Selene's NamedRequirementsData
--              entries -- these keep their per-run pacing checks, unlike a full force-true)
--   nil     -> not ours; pass through untouched (this now includes F_Story01/G_Story01 --
--              apply_story_room_lifetime_unlock strips only their specific lifetime-progress
--              gates, so the rest of their table evaluates completely natively, no override needed)
-- Only acts once settings are present (an active AP session) so non-AP / menu play is untouched.
function ItemManager.eligibility_override(requirements)
  if requirements == nil then return nil end
  if not ItemManager.have_settings() then return nil end
  -- On a brand-new save, IsGameStateEligible can be called from inside vanilla's StartNewRun
  -- during the engine's PostLoad phase, BEFORE RoomLogic.MapStateInit() has run for the very
  -- first room (MapStateInit is fired later via the OnAnyLoad trigger). Forcing a god upgrade
  -- eligible that early makes vanilla StartNewRun try to grant/highlight it immediately via
  -- AddTraitToHero, which unconditionally writes MapState.PriorityTraitInfoHighlight -- a fatal
  -- "attempt to index global 'MapState' (a nil value)" engine crash on first launch. Passing
  -- through untouched here until MapState exists costs a single frame on a fresh save; every
  -- later eligibility check (once the room is loaded) still gets the full override.
  if MapState == nil then return nil end
  if not resolve_eligibility_tables() then return nil end
  if ItemManager._force_true_reqs[requirements] then
    return "true"
  end
  -- GodSanity (the 9 boon gods, "start with more unlocked"): only bypass this god's native
  -- story-gate if GodSanity would also consider it eligible right now (god_eligible no-ops true
  -- when GodSanity is "unlocked" or no AP session is active, so this still force-unlocks from
  -- run 1 in that case, same as before). If GodSanity has it locked, pass through (nil) instead
  -- of forcing false -- vanilla's own gate is already unmet on a fresh AP save, so it naturally
  -- evaluates not-eligible without us needing to say so.
  do
    local godName = ItemManager._god_upgrade_reqs[requirements]
    if godName then
      if ItemManager.god_eligible(godName) then return "true" end
      return nil
    end
  end
  -- Helper Room Sanity (items/items_random): block a story room's own native eligibility
  -- outright while the NPC it would resolve to isn't unlocked yet -- this is what actually
  -- keeps the room from appearing at all, upstream of the SelectRandomStoryRoom identity swap
  -- (reload.lua). Replaces the old design (block only the UseNPC interaction once already
  -- standing in the room), which caused a real softlock: several of these rooms' exit doors
  -- only unlock once the NPC's gift/dialogue completes, so blocking JUST the interaction left
  -- the player stuck with no way to open the door. Mode 1 (items, no randomization): gate on
  -- THIS door's own native NPC. Mode 3 (items_random): gate on whether ANY helper is unlocked
  -- yet at all (any_helper_npc_unlocked) -- the specific identity that ends up here is then
  -- narrowed to an unlocked one by the SelectRandomStoryRoom filter, not by this eligibility
  -- check alone. See ItemManager.STORY_ROOM_TO_NPC's header for why Nightmare's A/X/Y_Story01
  -- and H_Bridge01/Echo aren't covered by this specific cache.
  do
    local storyNpc = ItemManager._story_room_native_reqs[requirements]
    if storyNpc then
      local mode = ItemManager.setting_mode("helper_room_sanity")
      if mode == 1 and not ItemManager.helper_npc_eligible(storyNpc) then
        return "false"
      end
      if mode == 3 and not ItemManager.any_helper_npc_unlocked() then
        return "false"
      end
      return nil
    end
  end
  -- GodSanity (Hermes/Selene): block their shop-reward entry outright while not yet unlocked,
  -- ahead of the generic _helper_intro_reqs "patch" below (which only relaxes their per-run
  -- PACING gates and would otherwise let them appear from run 1 regardless of GodSanity, same
  -- as it does today when GodSanity is off). god_eligible already no-ops (returns true) when
  -- GodSanity is "unlocked" or no AP session is active, so this is a pure pass-through then.
  if requirements == ItemManager._hermes_upgrade_req and not ItemManager.god_eligible("Hermes") then
    return "false"
  end
  if requirements == ItemManager._selene_spelldrop_req and not ItemManager.god_eligible("Selene") then
    return "false"
  end
  do
    local intro_npc = ItemManager._helper_intro_reqs[requirements]
    if intro_npc then
      -- Combat Helper Sanity (items/items_random): ChooseEncounter picking this intro and
      -- then HandleNemesisCombatSpawn/etc. (reload.lua) silently no-oping the spawn is NOT
      -- equivalent to a native low roll -- EncounterPresentation's NemesisSpawnPresentation
      -- still runs and indexes the never-created NPC unit, a fatal nil-index crash (confirmed
      -- live 2026-07-21 ~12:02pm; the received "Beautiful Mirror" item was an innocent
      -- bystander in the same batch, unrelated). Blocking SELECTION here, not just spawn, is
      -- the actual native-low-roll equivalent.
      if intro_npc ~= true and not ItemManager.combat_helper_eligible(intro_npc) then
        return "false"
      end
      return "patch"
    end
  end
  -- Combat Helper Sanity, ALL locations: block-only companion to the Intro branch above -- covers
  -- every OTHER zerp-Extended_NPC_Encounters combat variant for these NPCs (NemesisCombatN/O/P/
  -- Tartarus/Asphodel, ArtemisCombatH/I/O/P/Tartarus/Elysium, AthenaCombat*, ThanatosCombatN, ...).
  -- These share the exact same crash risk as the Intro keys (reload.lua's HandleXSpawn wrap no-ops
  -- the same base spawn function for all of them), confirmed live 2026-07-21 ~3:17pm via
  -- NemesisCombatN. Unlike the Intro branch, this never returns "patch" -- these keys gate on
  -- per-run pacing (e.g. "haven't already had a Nemesis encounter this run"), not a story-unlock
  -- gate, so once eligible we just fall through (nil) and let that native logic run untouched.
  do
    local combat_npc = ItemManager._helper_combat_reqs[requirements]
    if combat_npc and not ItemManager.combat_helper_eligible(combat_npc) then
      return "false"
    end
  end
  -- GodSanity (F_Combat01 forced-Apollo intro): vanilla guarantees the second Underworld room's
  -- Boon is Apollo on a totally fresh save (RoomDataF.lua F_Combat01 ForcedRewards, gated only by
  -- the lifetime UseRecord.ApolloUpgrade flag -- fires once, ever, then never again; F_Opening01
  -- has its OWN separate ForcedRewards chain for the OTHER 8 gods -- see
  -- FORCED_INTRO_GOD_KEY_BY_LOOT's comment and the _forced_intro_god_reqs branch below). Every
  -- active GodSanity mode needs the same skip here: this room's reward is assigned via a literal
  -- LootName on the ForcedRewards entry, which SetupRoomReward/ChooseLoot take directly rather
  -- than ever calling GetEligibleLootNames -- so it bypasses BOTH normal protections
  -- (GetRewardStoreData's thinning/padding AND GetEligibleLootNames' per-god filter) regardless
  -- of mode, including onions. The "onions' own 'become Onions' mechanism already covers it"
  -- reasoning this used to exclude onions (mode 1) under was wrong for this specific room --
  -- that mechanism lives in GetRewardStoreData, which this room never reaches on its own.
  -- Confirmed live 2026-07-21 (a no_waste_less_odds run got a real, unblocked Apollo boon here
  -- despite 0 gods unlocked) that this was ALSO broken for modes 2/3 the whole time, for an
  -- unrelated reason: the cache above was reading rsd.F.F_Opening01 instead of rsd.F.F_Combat01,
  -- so _apollo_intro_req was always nil and this identity check never matched, ever, for any mode.
  -- (That same misreading is what led to the "F_Opening01 has no ForcedRewards" claim below and
  -- in resolve_eligibility_tables -- both wrong, fixed same session the F_Opening01 leak itself
  -- was caught live: a locked Demeter boon handed out on run 1 with 2 unrelated gods unlocked.)
  -- Now a set (_apollo_intro_reqs) covering both F_Combat01 AND Zagreus' Journey's RoomSimple01 --
  -- see resolve_eligibility_tables above for the second live leak this caught 2026-07-22.
  if ItemManager._apollo_intro_reqs and ItemManager._apollo_intro_reqs[requirements] then
    local mode = ItemManager.setting_mode("godsanity")
    if mode ~= 0 and not ItemManager.god_eligible("ApolloUpgrade") then
      ItemManager.redirect_apollo_intro_reward()
      return "false"
    end
    return nil
  end
  -- GodSanity (F_Opening01 intro chain): unlike F_Combat01 above, this room's forcedRewards
  -- loop (RewardLogic.lua) tries each array entry in order and just moves on when one isn't
  -- eligible -- no redirect needed, "false" alone lets the next god in the chain (or the
  -- room's own ForcedRewardStore="RunProgress" fallback, already gated by scale_boon_entries/
  -- GetEligibleLootNames) take over correctly.
  do
    local godKey = ItemManager._forced_intro_god_reqs and ItemManager._forced_intro_god_reqs[requirements]
    if godKey then
      local mode = ItemManager.setting_mode("godsanity")
      if mode ~= 0 and not ItemManager.god_eligible(godKey) then
        return "false"
      end
      return nil
    end
  end
  -- Moros in the hub: force MorosUnlockedInHub true, but ONLY after the player has received
  -- Doomed Beckoning (force_world_upgrade set GameState.WorldUpgradesAdded.WorldUpgradeMorosUnlock).
  -- Before the item, pass through so he stays hidden exactly as vanilla dictates.
  if requirements == ItemManager._moros_hub_req then
    local gs = game.GameState
    local added = gs and gs.WorldUpgradesAdded
    if added and added.WorldUpgradeMorosUnlock then
      return "true"
    end
    return nil
  end
  -- Zagreus Vanilla/Empowered modes: force the persistent "have reached the true ending once"
  -- gate (NamedRequirementsData.InfernalContractUnlocked) true, so the fight can appear from
  -- run 1. Since IsGameStateEligible resolves `NamedRequirements = {"InfernalContractUnlocked"}`
  -- by recursing into itself (RequirementsLogic.lua:45), that recursive call is intercepted by
  -- this same wrap and returns true here, while the outer StoreData.ZagreusContractRequirement
  -- check (handled separately below, by identity) still runs through `base()` for its other
  -- clauses. Only active when Zagreus is actually part of the goal.
  -- Empowered was originally left out on the theory that it should "appear how it normally
  -- does" -- but on a fresh AP save nobody has legitimately earned InfernalContractUnlocked
  -- yet, so that left Zagreus unable to ever appear in Empowered mode at all (the one thing
  -- that's actually supposed to differ in Empowered is his stat scaling via
  -- apply_zagreus_empower, not his eligibility) -- so it gets the same eligibility override as
  -- Vanilla.
  if requirements == ItemManager._infernal_contract_req
     and ItemManager.goal_includes_zagreus() then
    local mode = ItemManager.zagreus_mode()
    if mode == ItemManager.ZAGREUS_MODE_VANILLA or mode == ItemManager.ZAGREUS_MODE_EMPOWERED then
      -- Proves the override actually fired (vs. the contract's carrier Shop room simply never
      -- spawning that run -- see [[project_zagreus_vanilla_empowered_shop_rarity]]).
      rom.log.info("[AP] Zagreus InfernalContractUnlocked forced true (mode=" .. mode .. ")")
      return "true"
    end
    -- Final Challenge mode: Zagreus is only ever reached via the automatic
    -- Chronos/Typhon-clear redirect, never the normal secret-contract path (door in the
    -- world, or the shop pedestal offer -- both gated by this same NamedRequirement). If
    -- the player's real save has already naturally earned InfernalContractUnlocked (e.g.
    -- reached the true ending in a past playthrough before this seed), that would otherwise
    -- let Zagreus keep appearing the normal way alongside the Final Challenge redirect.
    -- Force this false so only the redirect can trigger him.
    if mode == ItemManager.ZAGREUS_MODE_FINAL_CHALLENGE then
      return "false"
    end
  end
  -- Vanilla/Empowered, cont'd: force the OUTER StoreData.ZagreusContractRequirement false too
  -- (same as Final Challenge above). The vanilla per-room mechanism this table gates
  -- (RunLogic.lua:652) only ever exists in ~4 specific Shop rooms and rolls a ChanceToPlay=0.4 on
  -- top of that (see [[project_zagreus_vanilla_empowered_shop_rarity]]) -- per user request
  -- 2026-07-17 ("spawn it in every shop"), ItemManager.apply_zagreus_contract_everywhere
  -- (reload.lua's StartRoom hook) now spawns the contract directly in EVERY real shop room
  -- instead, superseding this table entirely. Forcing it false here prevents the vanilla
  -- mechanism from ALSO firing in the ~4 rooms it natively covers, which would otherwise
  -- double-spawn the contract there.
  if requirements == ItemManager._zagreus_contract_req
     and ItemManager.goal_includes_zagreus() then
    local mode = ItemManager.zagreus_mode()
    if mode == ItemManager.ZAGREUS_MODE_VANILLA or mode == ItemManager.ZAGREUS_MODE_EMPOWERED then
      return "false"
    end
  end
  return nil
end

-- Evaluate a helper-intro's (or Hermes'/Selene's) requirements with ONLY its story-unlock
-- gates temporarily satisfied, leaving the per-run situational conditions (biome depth, NPC
-- cooldown, active bounty, health, already-used-this-run, etc.) intact so the content still
-- appears naturally -- "the first time you're in the area" for helpers, "not already taken this
-- run" for Hermes/Selene -- rather than ignoring run pacing entirely. Nothing is persisted:
-- every field is restored immediately after the base evaluation (even on error). The patched
-- gates:
--   CompletedRunsCache >= 7        -> Artemis (>=1) and Nemesis (>=7) run-count gates
--   TextLinesRecord.<god>FirstPickUp -> Artemis's "met >= 4 gods" count, and (per HELPER_GOD_PICKUPS)
--                                       Hermes'/Selene's own first-meeting gates
--   TextLinesRecord.HeraclesFirstMeeting -> Heracles's first-meeting gate
--   BiomeVisits.O >= 2             -> Icarus (> 1) gate
--   RoomCountCache.G_Intro = true  -> Nemesis intro gate
function ItemManager.eval_helper_intro(base, source, requirements, args)
  local gs = game.GameState
  if not gs then return base(source, requirements, args) end
  gs.TextLinesRecord = gs.TextLinesRecord or {}
  gs.BiomeVisits = gs.BiomeVisits or {}
  gs.RoomCountCache = gs.RoomCountCache or {}
  local tlr, bv, rcc = gs.TextLinesRecord, gs.BiomeVisits, gs.RoomCountCache
  -- save
  local saved_runs = gs.CompletedRunsCache
  local saved_heracles = tlr.HeraclesFirstMeeting
  local saved_biomeO = bv.O
  local saved_gintro = rcc.G_Intro
  local saved_gods = {}
  for _, g in ipairs(HELPER_GOD_PICKUPS) do saved_gods[g] = tlr[g] end
  -- patch (only ever raises a gate toward "satisfied"; never lowers existing progress)
  gs.CompletedRunsCache = math.max(saved_runs or 0, 7)
  tlr.HeraclesFirstMeeting = true
  bv.O = math.max(bv.O or 0, 2)
  rcc.G_Intro = true
  for _, g in ipairs(HELPER_GOD_PICKUPS) do tlr[g] = true end
  -- evaluate
  local ok, result = pcall(base, source, requirements, args)
  -- restore
  gs.CompletedRunsCache = saved_runs
  tlr.HeraclesFirstMeeting = saved_heracles
  bv.O = saved_biomeO
  rcc.G_Intro = saved_gintro
  for _, g in ipairs(HELPER_GOD_PICKUPS) do tlr[g] = saved_gods[g] end
  if ok then return result end
  return false
end

-- Vanilla/Empowered, per user request 2026-07-17 ("spawn it in every shop, unless they've
-- already encountered him"): the vanilla contract mechanism only ever exists in ~4 specific Shop
-- rooms (F/G/O/P) and is gated behind a further ChanceToPlay=0.4 roll on top of that -- see
-- [[project_zagreus_vanilla_empowered_shop_rarity]] for why that made him extremely rare to ever
-- see. Spawn the same "ZagContract" secret-door obstacle vanilla's own SpawnZagContract
-- (EventLogic.lua:1875) spawns, at the most natural spot each shop room actually has
-- (2026-07-18 anchor audit of the game scripts), tried in order:
--   1. roomData.ZagContractDestinationId -- the authored contract point in F/G/O/P_Shop01. We
--      set room.ZagreusContractSuccess (the RunLogic.lua:652 flag our eligibility_override
--      keeps vanilla from ever setting) and call vanilla's SpawnZagContract itself, so the
--      "Contract" prop group activation and FlipZagContract orientation come along for free.
--   2. roomData.ZagContractRewardDestinationId -- every *_PreBoss shop (all 9: F/G/H/N/I(x2)/
--      O/P/Q) has this authored anchor, where Zagreus' post-victory free-item pedestal spawns
--      (SpawnZagContractRewards, same file). It is provably empty whenever the contract can
--      appear: the reward needs InfernalContractBoon (won the fight THIS run), while we only
--      spawn before RoomCountCache.C_Boss01 exists (fight not yet taken this run).
--   3. An unused LootPoint -- in-world shops lay their wares onto sorted LootPoint ids
--      (StoreLogic.lua:594) and WorldShop only stocks 3, so a spare pedestal in the wares row
--      sits empty all room (RestockWorldItem reuses the same kitId). Covers I_Shop01/N_Shop01,
--      the two world shops with no authored Zag anchor at all. Only tried when the room really
--      has in-world wares (Store.SpawnedStoreItems), so kiosk rooms skip to 4.
--   4. Beside the well/sell/surface kiosk -- those rooms keep their kiosk's ObjectId on the
--      room instance (RoomLogic.lua:4894), offset 150 + ForceToValidLocation.
-- There is deliberately NO Hero/Charon last-resort anchor: if none of tiers 1-4 match, the room
-- has no real shop fixture and we spawn nothing. A dedicated shop is fully set up by base() before
-- this runs, so it always offers a tier 1-4 anchor; the only rooms that reach the fall-through are
-- ordinary combat rooms that merely rolled a Stygian Well this room (WellShopChanceSuccess sets
-- room.Store -> room_is_shop true) whose well hasn't spawned yet -- the old Hero fallback dropped
-- a contract door into the middle of those (observed: F_Combat02, anchor=hero, 2026-07-18).
-- Dedup guard is scoped to the CURRENT room instance (currentRun.APZagContractRoomInstance,
-- a direct reference to the room table, not just its Name), not "ever spawned this run":
-- 2026-07-19 bug -- Nightmare's Styx hub (D_Hub) rebuilds as a brand-new room instance every
-- time you return from a wing (confirmed via the Zagreus' Journey mod's own StoreLogic.lua,
-- which re-hydrates D_Hub's shop *options* from CurrentRun.ModsNikkelMHadesBiomesPersistentStore
-- but still spawns fresh world objects into a fresh room table each visit -- RoomHistory holds
-- multiple separate D_Hub entries). A run-wide "already spawned once" flag would see the old
-- spawn, block a new one, and then the player returns to a rebuilt D_Hub with no contract in it
-- and no way to ever get one for the rest of the run -- exactly what got reported. Any door out
-- of a room is one-way in this engine, so the moment currentRoom stops matching the instance we
-- spawned into, that contract is unreachable and should stop blocking a fresh offer elsewhere.
-- This same identity check also covers the original save/quit/reload concern this guard was
-- first written for: a reload deserializes a new room table too, so it naturally falls into the
-- same "instance changed, offer again" path instead of eating the contract.
-- Called from reload.lua's StartRoom hook for every room; no-ops unless the room actually
-- qualifies as a real shop (LocationManager.room_is_shop) and Zagreus hasn't already been fought
-- this run. The corresponding eligibility_override branches force the native RunLogic.lua:652
-- mechanism false for these two modes so it never ALSO fires on its own.
local function zag_contract_already_present(currentRun, currentRoom)
  if currentRun.APZagContractRoomInstance == currentRoom then return true end
  local map = game.MapState
  if map and map.ActiveObstacles then
    for _, obs in pairs(map.ActiveObstacles) do
      if obs and obs.Name == "ZagContract" then return true end
    end
  end
  return false
end

-- Shared spawn tail (mirrors vanilla SpawnZagContract minus the anchor choice): spawnArgs
-- carries the anchor (DestinationId + optional offsets); Name/Group are filled in here.
local function spawn_zag_contract_at(spawnArgs)
  local obstacleData = game.ObstacleData and game.ObstacleData.ZagContract
  local bossRoomData = game.RoomData and game.RoomData.C_Boss01
  if not (obstacleData and bossRoomData and game.CreateRoom and game.AssignRoomToExitDoor
      and game.SpawnObstacle and game.SetupObstacle and game.DeepCopyTable) then
    return false, "game functions unavailable"
  end
  return pcall(function()
    local contractItem = game.DeepCopyTable(obstacleData)
    spawnArgs.Name = "ZagContract"
    spawnArgs.Group = "Standing"
    contractItem.ObjectId = game.SpawnObstacle(spawnArgs)
    contractItem.RerollFunctionName = nil
    local nextRoom = game.CreateRoom(bossRoomData)
    game.AssignRoomToExitDoor(contractItem, nextRoom)
    game.SetupObstacle(contractItem)
    -- RoomLogic.lua's DoUnlockRoomExits (native) is what normally flips an exit door's
    -- ReadyToUse to true, but it only walks the snapshot of MapState.OfferedExitDoors it took at
    -- room-start -- and it has ALREADY run and returned by the time this StartRoom hook fires
    -- (we're called after base(), see reload.lua's StartRoom wrap). AssignRoomToExitDoor above
    -- still registers us into MapState.OfferedExitDoors, but nothing will ever revisit that table
    -- to set ReadyToUse for an entry added this late -- AttemptUseDoor (RoomLogic.lua:757) then
    -- always falls into CannotUseDoorPresentation ("Exit Blocked!"/ExitNotActive) forever. Set it
    -- ourselves so the door is actually usable the instant it appears.
    contractItem.ReadyToUse = true
  end)
end

function ItemManager.apply_zagreus_contract_everywhere(currentRoom)
  if not ItemManager.goal_includes_zagreus() then return end
  local mode = ItemManager.zagreus_mode()
  if mode ~= ItemManager.ZAGREUS_MODE_VANILLA and mode ~= ItemManager.ZAGREUS_MODE_EMPOWERED then
    return
  end
  if not (LocationManager and LocationManager.room_is_shop and LocationManager.room_is_shop(currentRoom)) then
    return
  end
  local currentRun = game.CurrentRun
  if not currentRun then return end
  if currentRun.APZagContractRoomInstance and currentRun.APZagContractRoomInstance ~= currentRoom then
    -- Left behind the room that held our last spawn (e.g. a rebuilt hub instance) -- it's
    -- unreachable now, so don't let it keep blocking a fresh offer.
    currentRun.APZagContractRoomInstance = nil
  end
  if zag_contract_already_present(currentRun, currentRoom) then return end
  local rcc = currentRun.RoomCountCache
  if rcc and rcc.C_Boss01 then return end
  local roomData = (game.RoomData and currentRoom.Name and game.RoomData[currentRoom.Name])
    or currentRoom

  -- Tier 1: authored contract point -- let vanilla's own spawner do the whole job.
  if roomData.ZagContractDestinationId and game.SpawnZagContract then
    local ok, err = pcall(function()
      currentRoom.ZagreusContractSuccess = true
      game.SpawnZagContract(currentRoom, { ActivateGroups = { "Contract" } })
      -- Same ReadyToUse gap as spawn_zag_contract_at (see its comment): vanilla's own
      -- SpawnZagContract (EventLogic.lua:1875) never sets ReadyToUse either -- it normally gets
      -- away with that because it's called from the room's own SetupEvents chain, BEFORE
      -- DoUnlockRoomExits runs and walks MapState.OfferedExitDoors. We call it late (after
      -- base(), from the StartRoom hook), so that walk has already happened. SpawnZagContract
      -- doesn't hand back the obstacle it created, so fetch it back out of MapState.ActiveObstacles.
      if game.MapState and game.MapState.ActiveObstacles then
        for _, obs in pairs(game.MapState.ActiveObstacles) do
          if obs and obs.Name == "ZagContract" then
            obs.ReadyToUse = true
            break
          end
        end
      end
    end)
    if ok then
      currentRun.APZagContractRoomInstance = currentRoom
      rom.log.info("[AP] Zagreus contract spawned in shop room " .. tostring(currentRoom.Name)
        .. " (mode=" .. mode .. ", anchor=authored contract point)")
      return
    end
    rom.log.warning("[AP] Zagreus contract: vanilla SpawnZagContract failed in "
      .. tostring(currentRoom.Name) .. " (" .. tostring(err) .. "), trying fallback anchors")
  end

  local spawnArgs, anchor
  -- Tier 2: the authored reward pedestal every *_PreBoss shop carries.
  if roomData.ZagContractRewardDestinationId then
    spawnArgs = { DestinationId = roomData.ZagContractRewardDestinationId }
    anchor = "authored reward pedestal"
  end
  -- Tier 3: a spare pedestal in the wares row (only when this room has in-world wares).
  if not spawnArgs and game.GetIdsByType and currentRoom.Store
      and currentRoom.Store.SpawnedStoreItems and currentRoom.Store.SpawnedStoreItems[1] then
    pcall(function()
      local kitIds = game.GetIdsByType({ Name = "LootPoint" }) or {}
      table.sort(kitIds)
      local used = (game.MapState and game.MapState.RewardPointsUsed) or {}
      for _, kitId in ipairs(kitIds) do
        if not used[kitId] then
          spawnArgs = { DestinationId = kitId }
          anchor = "unused shop pedestal (LootPoint " .. tostring(kitId) .. ")"
          return
        end
      end
    end)
  end
  -- Tier 4: beside this room's shop kiosk (post-boss well rooms etc.).
  if not spawnArgs then
    local kiosk = currentRoom.WellShop or currentRoom.SellTraitShop or currentRoom.SurfaceShop
    if kiosk and kiosk.ObjectId then
      spawnArgs = { DestinationId = kiosk.ObjectId, OffsetX = 150, OffsetY = 0,
        ForceToValidLocation = true }
      anchor = "beside shop kiosk"
    end
  end
  -- No Charon/Hero last-resort anchor: reaching here means the room has NO real shop fixture
  -- yet (tiers 1-4 all missed). That happens in ordinary combat rooms that merely rolled a
  -- Stygian Well this room (WellShopChanceSuccess -> RunShopGeneration sets room.Store, so
  -- LocationManager.room_is_shop reports true), but the well kiosk/wares don't spawn until the
  -- encounter is cleared -- long after this StartRoom pass. Anchoring to the Hero there dropped a
  -- contract door in the middle of a combat room (observed: F_Combat02, anchor=hero). A dedicated
  -- shop room is fully set up by base() before we run, so it always has a tier 1-4 anchor; if none
  -- is present, this isn't a real shop yet and we spawn nothing.
  if not spawnArgs then return end

  local ok, err = spawn_zag_contract_at(spawnArgs)
  if ok then
    currentRun.APZagContractRoomInstance = currentRoom
    rom.log.info("[AP] Zagreus contract spawned in shop room " .. tostring(currentRoom.Name)
      .. " (mode=" .. mode .. ", anchor=" .. anchor .. ")")
  else
    rom.log.warning("[AP] Zagreus contract spawn failed in " .. tostring(currentRoom.Name)
      .. ": " .. tostring(err))
  end
end

-- ---- Run-start stat fillers (New Filler Checks) -----------------------------
-- Apply the granular run-start buffs at StartNewRun (after base, so CurrentRun.Hero
-- exists). Progressive Start is gone -- each buff now comes from its own filler item,
-- scaled by (items received) * (its configured *_value):
--   Max Health -> bump HeroData.MaxHealth base (ValidateMaxHealth recomputes from it)
--   Gold       -> CurrentRun.Money += bonus (in-run gold; NOT a GameState meta resource)
--   Max Arcana -> set CurrentRun.Hero.MaxMana directly (flat field, no recompute)
--   Daedalus   -> grant_pending_daedalus (random hammer trait, from the StartRoom hook)
--   Rarity     -> one hidden trait with a summed RarityBonus across Rare/Epic/Heroic (ramps all tiers)
-- Armor lives in ItemManager.apply_armor() (called from the StartRoom hook), since it needs a
-- real biome room; it's a permanent one-time grant via AddArmor (Test Run 6 #10), not here.
-- Rarity Increase: boost boon-rarity chances across the whole power ladder -- Rare AND Epic AND
-- Heroic, not just Rare. How the game rolls a boon's rarity (TraitLogic.SetTraitsOnLoot): it walks
-- that boon's RarityRollOrder ascending (per-god, e.g. Athena = Common/Rare/Epic/Heroic, Artemis
-- caps at Common/Rare/Epic) and keeps the HIGHEST tier whose chance passes RandomChance; a chance
-- >= 1.0 always passes (RandomChance is `rng:Random() <= chance`). GetRarityChances (RoomLogic.lua:2159-2168)
-- calls GetHeroTraitValues("RarityBonus", ...) and, for each name in TraitRarityData.RarityValues
-- ("Common"/"Rare"/"Epic"/"Heroic"), adds rarityTraitData[rarityName] -- i.e. the BARE tier name,
-- NOT "<Tier>Bonus" (confirmed against the actual game source; an earlier version of this code used
-- RareBonus/EpicBonus/HeroicBonus sub-keys, which GetRarityChances never reads, so the bonus was
-- always summing nil and every boon stayed Common no matter how many items were stacked). So a
-- single hidden trait carrying the summed bonus under the bare tier names is all that's needed. Per
-- item we add a per-tier increment; the tiers
-- saturate at different rates (Rare fastest, Heroic slowest) for a natural ramp, and by ~100 items
-- every tier is >= 1.0 so every boon rolls its max available rarity ("heroic that can be" -- a god
-- that caps at Epic still maxes at Epic). Legendary/Duo are separate gated boons (not power tiers),
-- so we deliberately don't touch them. One trait with the summed bonus (not rarity_count copies)
-- keeps the add O(1) instead of O(n^2) UpdateHeroTraitDictionary rebuilds.
-- Shared by apply_progressive_start (run start) and the "Rarity Increase" item handler (mid-run,
-- so the boost is live immediately instead of banked until the next run -- see Wishlist).
function ItemManager.refresh_rarity_boost(rarity_count)
  if not (rarity_count and rarity_count > 0 and game.AddTraitToHero and game.TraitData
      and game.CurrentRun and game.CurrentRun.Hero) then
    return
  end
  local RARE_PER, EPIC_PER, HEROIC_PER = 0.05, 0.03, 0.015  -- per item; 100 items -> 5.0/3.0/1.5
  -- AddTraitToHero (TraitLogic.lua AddTraitData) unconditionally table.insert()s a new trait --
  -- it never finds-and-replaces an existing one of the same Name. This function is called again
  -- every time a "Rarity Increase" item is received mid-run (see the item handler below), each
  -- time with the new CUMULATIVE bonus. Without stripping the previous copy first, every past
  -- copy stays in Hero.Traits and GetRarityChances sums ALL of them (TraitLogic.lua
  -- GetHeroTraitValues), so the bonus compounds like a triangular number instead of just
  -- reflecting the current total (e.g. 3 items in one run would apply 1x+2x+3x = 6x the
  -- per-item bonus instead of 3x). RemoveTrait only strips the first match per call, so loop
  -- until every stale copy is gone.
  while game.HeroHasTrait and game.RemoveTrait and game.HeroHasTrait("ArchipelagoRarityBoost") do
    game.RemoveTrait(game.CurrentRun.Hero, "ArchipelagoRarityBoost")
  end
  -- Same DoPatches trait-stripping issue as ArchipelagoStatBonus above -- must be registered in
  -- the global TraitData table, not passed inline, or it gets silently removed on room load.
  game.TraitData["ArchipelagoRarityBoost"] = {
    Name = "ArchipelagoRarityBoost",
    Hidden = true,                 -- no HUD icon / "new trait" highlight
    ExcludeFromRarityCount = true, -- don't skew GodBoonRarities bookkeeping
    -- Sub-keys MUST be the BARE tier names ("Rare"/"Epic"/"Heroic"), matching
    -- TraitRarityData.RarityValues -- GetRarityChances does rarityTraitData[rarityName], not
    -- rarityTraitData[rarityName .. "Bonus"]. Confirmed against RoomLogic.lua:2159-2168.
    RarityBonus = {
      Rare   = rarity_count * RARE_PER,
      Epic   = rarity_count * EPIC_PER,
      Heroic = rarity_count * HEROIC_PER,
    },
  }
  pcall(function()
    game.AddTraitToHero({ TraitName = "ArchipelagoRarityBoost" })
  end)
end

-- ---- Empowered Zagreus mode --------------------------------------------------
-- Zagreus (EnemyData_Zagreus.lua) has no built-in difficulty knob, so scaling him uses the
-- same field the game's own difficulty-shrine health scaling uses on any enemy unit
-- (RoomLogic.lua SetupUnit: unit.MaxHealth = unit.MaxHealth * healthMultiplier;
-- unit.Health = unit.MaxHealth) -- applied directly to the activated unit rather than via a
-- TraitData multiplier, since that per-unit field is what actually drives enemy HP here (a
-- live trait-based multiplier is the hero-side mechanism, not the enemy one).
-- Starts at 2.0x (+100%); each Progressive Zagreus Weaken item received steps the
-- multiplier down by 1.2/tiers, landing at 0.8x (-20%, "beneath base") once all are
-- collected. unit.APBaseMaxHealth caches the ORIGINAL base so repeated calls (a mid-fight
-- item pickup) recompute from that base instead of compounding on an already-scaled value.
local function zagreus_multiplier(received, tiers)
  tiers = (tiers and tiers > 0) and tiers or 5
  return 2.0 - (1.2 / tiers) * math.min(received or 0, tiers)
end

function ItemManager.apply_zagreus_empower(unit, received, tiers)
  if not (unit and unit.MaxHealth) then return end
  unit.APBaseMaxHealth = unit.APBaseMaxHealth or unit.MaxHealth
  local mult = zagreus_multiplier(received, tiers)
  local fraction = (unit.MaxHealth > 0) and (unit.Health / unit.MaxHealth) or 1
  unit.MaxHealth = math.floor(unit.APBaseMaxHealth * mult)
  unit.Health = math.max(1, math.floor(unit.MaxHealth * fraction))
  rom.log.info("[AP] Zagreus empowered x" .. string.format("%.2f", mult)
    .. " MaxHealth (weaken " .. (received or 0) .. "/" .. (tiers or 5) .. ")")
end

-- Mid-run pickup: if Zagreus is currently active in his room, reapply immediately instead
-- of leaving the new weaken tier banked until the next fight (mirrors refresh_rarity_boost).
function ItemManager.refresh_zagreus_empower(received)
  local room = game.CurrentRun and game.CurrentRun.CurrentRoom
  if not (room and room.Name == "C_Boss01" and game.ActiveEnemies) then return end
  local tiers = tonumber(ItemManager.settings.zagreus_weaken_tiers) or 5
  for _, unit in pairs(game.ActiveEnemies) do
    if unit and unit.Name == "Zagreus" then
      ItemManager.apply_zagreus_empower(unit, received, tiers)
    end
  end
end

-- Tops up the AP MaxHealth/MaxMana bonus, the rarity-boost trait, and the major-finds
-- reward-ratio override to match the CURRENT item counts. Split out of apply_progressive_start so
-- it can also be called from every room-entry hook (StartRoom / RestoreUnlockRoomExits, reload.lua),
-- not just StartNewRun -- StartNewRun never fires for a continued run (RunLogic.lua StartNewGame
-- only calls it when CurrentRun == nil), so quitting to desktop and rejoining a run-in-progress
-- needs this reasserted from whatever room-entry path the game actually takes on resume (there are
-- two -- see the RestoreUnlockRoomExits wrap in reload.lua).
--
-- IMPORTANT DESIGN NOTE: this function is PURELY ADDITIVE and self-healing -- it never removes,
-- rebuilds, or recomputes-from-scratch anything. Instead of tracking "how much have I granted" in
-- Lua memory (which resets to zero every process restart and was the cause of duplicate/compounding
-- grants on rejoin -- see [[project_rejoin_midrun_bug]]), it reads the ACTUAL current total straight
-- off the hero's own trait list -- summing every existing ArchipelagoStatBonus stack's PropertyChanges
-- -- and grants exactly ONE more stack covering whatever shortfall remains. This is the same thing
-- every other permanent mid-run stat boost in the game does: `AddTraitData` (TraitLogic.lua:879)
-- deep-copies the trait definition into the hero's OWN Traits list at grant time, so each stack is
-- independently baked and survives on its own -- exactly like a real boon or Daedalus hammer pickup
-- -- and `ValidateMaxHealth`/`ValidateMaxMana` (RoomLogic.lua) sum ALL matching stacks regardless of
-- how many there are. So multiple stacks are not a bug here, they're the intended mechanism; the
-- fix is deriving "how much so far" from the real, current, save-consistent state instead of a
-- separate counter that can drift out of sync with it.
function ItemManager.reassert_stat_bonuses()
  local s = APState.get()
  if not s then return end
  if not (game.CurrentRun and game.CurrentRun.Hero) then return end
  local hero = game.CurrentRun.Hero
  local function setting_val(key) return tonumber(ItemManager.settings[key]) or 0 end
  local hp_target     = (s.max_health_items or 0) * setting_val("starting_health_value")
  local arcana_target = (s.max_arcana_items or 0) * setting_val("starting_magick_value")
  local rarity_count = s.rarity_increase or 0
  local major_finds_count = s.major_finds or 0

  pcall(function()
    -- Starting Max Health + Max Magick: BOTH come from one arcana -- Persistence (the BonusHealth
    -- card), whose HealthManaBonusMetaUpgrade trait Adds to MaxHealth AND MaxMana via PropertyChanges
    -- (TraitData_MetaUpgrade.lua). This is the same real mechanism: a hero trait carrying MaxHealth/
    -- MaxMana Adds, summed by ValidateMaxHealth/ValidateMaxMana.
    if game.AddTraitToHero and game.TraitData then
      -- How much of each stat bonus the hero ALREADY carries, summed across every existing
      -- ArchipelagoStatBonus stack. This is the single source of truth -- not a separate counter.
      local have_hp, have_mana = 0, 0
      for _, trait in ipairs(hero.Traits or {}) do
        if trait.Name == "ArchipelagoStatBonus" and trait.PropertyChanges then
          for _, pc in ipairs(trait.PropertyChanges) do
            if pc.LuaProperty == "MaxHealth" then have_hp = have_hp + (pc.ChangeValue or 0) end
            if pc.LuaProperty == "MaxMana" then have_mana = have_mana + (pc.ChangeValue or 0) end
          end
        end
      end
      local hp_delta = hp_target - have_hp
      local mana_delta = arcana_target - have_mana
      if hp_delta > 0 or mana_delta > 0 then
        -- Grant exactly ONE new stack covering the shortfall -- never touch/replace any existing
        -- stack. Always register BOTH PropertyChanges entries (0 for whichever isn't short) so
        -- every stack, past and future, has the SAME shape: DoPatches (PatchLogic.lua ~1099) only
        -- flags a trait for resync when its PropertyChanges COUNT differs from the current
        -- TraitData registration, so a constant shape means it never touches the values already
        -- independently baked into earlier stacks.
        game.TraitData["ArchipelagoStatBonus"] = {
          Name = "ArchipelagoStatBonus",
          Hidden = true,                 -- no HUD icon / "new trait" highlight
          ExcludeFromRarityCount = true,
          PropertyChanges = {
            { LuaProperty = "MaxHealth", ChangeValue = math.max(0, hp_delta), ChangeType = "Add" },
            { LuaProperty = "MaxMana", ChangeValue = math.max(0, mana_delta), ChangeType = "Add" },
          },
        }
        pcall(function()
          game.AddTraitToHero({ TraitName = "ArchipelagoStatBonus" })
        end)
        -- Recompute the caps so the new stack's Adds take effect now.
        pcall(function() if game.ValidateMaxHealth then game.ValidateMaxHealth() end end)
        pcall(function() if game.ValidateMaxMana then game.ValidateMaxMana() end end)
        -- Heal by exactly the amount just granted, like a real Max-Health-up pickup would -- NOT a
        -- full top-off, so a mid-run/rejoin correction can never act as a free full heal.
        if hp_delta > 0 then hero.Health = math.min(hero.Health + hp_delta, hero.MaxHealth) end
        if mana_delta > 0 then hero.Mana = math.min(hero.Mana + mana_delta, hero.MaxMana) end
        pcall(function() if game.UpdateManaMeterUI then game.UpdateManaMeterUI() end end)
        pcall(function() if game.FrameState then game.FrameState.RequestUpdateHealthUI = true end end)
        rom.log.info("[AP] stat bonus: granted +" .. math.max(0, hp_delta) .. " MaxHealth +"
          .. math.max(0, mana_delta) .. " MaxMana (now " .. tostring(hero.MaxHealth) .. "/"
          .. tostring(hero.MaxMana) .. ", target " .. hp_target .. "/" .. arcana_target .. ")")
      end
    end
    -- Rarity Increase: see ItemManager.refresh_rarity_boost above for the full mechanism/field-name
    -- notes (this call just (re)builds the trait for the current run's total rarity_count).
    ItemManager.refresh_rarity_boost(rarity_count)
    -- Increased Odds of Major Finds: bias exit-door rewards toward Major Finds (the RunProgress
    -- store -- boons, Daedalus hammers, Centaur Hearts) and away from Minor Finds (the MetaProgress
    -- store -- Ash/Bones/Nectar/etc.). ChooseNextRewardStore (RoomLogic) decides each door by
    -- RandomChance(TargetMetaRewardsRatio); a hit makes that door a Minor Find. HeroData's base is
    -- 0.45, and the Hero is rebuilt every run, so capture the unmodified base once and set MaxMana-
    -- style absolutely each run: each item shrinks the minor-find chance multiplicatively toward 0
    -- (0.85^n), so more items -> more Major Finds. Per-room overrides (CurrentRoom.TargetMetaRewards-
    -- Ratio, set by a handful of special rooms) still win, so those rooms keep their intended ratio.
    if (major_finds_count > 0 or ItemManager.base_meta_rewards_ratio)
        and game.CurrentRun and game.CurrentRun.Hero then
      ItemManager.base_meta_rewards_ratio = ItemManager.base_meta_rewards_ratio
        or game.CurrentRun.Hero.TargetMetaRewardsRatio
      if ItemManager.base_meta_rewards_ratio then
        local MINOR_KEEP = 0.85  -- per item: minor-find chance *= 0.85 (100 items -> ~0)
        game.CurrentRun.Hero.TargetMetaRewardsRatio =
          ItemManager.base_meta_rewards_ratio * (MINOR_KEEP ^ major_finds_count)
      end
    end
  end)
end

-- Progressive Boon Level: called from two wraps in reload.lua -- the AddTraitToHero wrap (catches
-- TraitName-shaped fresh grants, e.g. NPC-gifted boons) and the CreateUpgradeChoiceButton wrap
-- (catches the pedestal/door/shop choice-menu path, the dominant way players actually get a new
-- boon -- see that wrap's comment for why AddTraitToHero alone doesn't cover it) -- on every fresh
-- boon grant, to decide the StackNum it should start at. Returns nil (start at the normal level 1)
-- once no Progressive Boon Level items have been received; otherwise 1 + however many have.
-- Deliberately does not touch boons already held -- only a brand-new grant reaches either wrap at
-- all -- so already-acquired boons level up purely through normal play.
function ItemManager.boon_level_start()
  local s = APState.get()
  local bonus = s and (s.boon_level_bonus or 0) or 0
  if bonus <= 0 then return nil end
  return 1 + bonus
end

function ItemManager.apply_progressive_start()
  local s = APState.get()
  if not s then return end
  local function setting_val(key) return tonumber(ItemManager.settings[key]) or 0 end
  local hp_bonus     = (s.max_health_items or 0) * setting_val("starting_health_value")
  local gold_bonus   = (s.gold_items or 0)       * setting_val("starting_gold_value")
  local arcana_bonus = (s.max_arcana_items or 0) * setting_val("starting_magick_value")
  local rarity_count = s.rarity_increase or 0
  local major_finds_count = s.major_finds or 0
  -- Daedalus hammers (grant_pending_daedalus) and Armor (apply_armor) both track "how much
  -- already granted" on game.CurrentRun now (see their own comments), which is a fresh table for
  -- every new run automatically -- no manual per-run reset needed here anymore.
  -- Reset the mod-maintained per-run "scored depth" so room depths restart at 1 each run
  -- (point_based points and room high-water marks persist across runs -- Test Run 6 #6).
  for _, route in ipairs({ "Underworld", "Surface", "Nightmare" }) do
    if s.score and s.score[route] then s.score[route].depth_counter = 0 end
  end
  if Overlay and Overlay.set_room then Overlay.set_room(0) end

  -- reassert_stat_bonuses is additive/self-healing (see its own comment): on a genuine new run the
  -- hero starts with no ArchipelagoStatBonus stacks yet, so it naturally grants the FULL target as
  -- one stack and heals by that same amount from the hero's already-full starting Health/Mana --
  -- landing exactly at the new caps, no separate top-off needed.
  pcall(function()
    ItemManager.reassert_stat_bonuses()
    ItemManager.apply_gold()
  end)
  rom.log.info(string.format(
    "[AP] run-start fillers: +%dHP +%dgold +%darcana rarity+%d majorfinds+%d (daedalus=%d spawned at StartRoom)",
    hp_bonus, gold_bonus, arcana_bonus, rarity_count, major_finds_count, s.daedalus_upgrade or 0))
end

-- Starting Gold, ledger-based like apply_armor below: top this run's granted gold up to the
-- current target (items x starting_gold_value). Hades 2 has NO CurrentRun.Money -- run gold is
-- GameState.Resources.Money, and the game grants its own starting gold at the END of
-- StartNewRun with AddResource("Money", CalculateStartingMoney(), "RunStart") (RunLogic.lua),
-- so AddResource is the correct, proven path (it updates the money HUD itself); Silent skips
-- the resource-gain VO/popup. The ledger lives on game.CurrentRun (real, saved run state --
-- survives quit/rejoin without re-granting, same pattern as AP_ArmorGranted), which also makes
-- a MID-RUN receipt land immediately: the ITEMS hook (reload.lua) calls this inside a biome
-- room. It deliberately does NOT run at the hub -- the hub's CurrentRun is still the PREVIOUS
-- run, so an instant grant there would double up with the next run's full run-start grant.
-- (A run started before this ledger existed re-grants once on its next call -- one-time,
-- money-only migration artifact.)
function ItemManager.apply_gold()
  local s = APState.get()
  if not s then return end
  local target = (s.gold_items or 0) * (tonumber(ItemManager.settings["starting_gold_value"]) or 0)
  if target <= 0 then return end
  if not (game.CurrentRun and game.CurrentRun.Hero and game.AddResource) then return end
  local granted = game.CurrentRun.AP_GoldGranted or 0
  local delta = target - granted
  if delta <= 0 then return end
  pcall(function()
    game.AddResource("Money", delta, "RunStart", { Silent = true })
    game.CurrentRun.AP_GoldGranted = target
    rom.log.info("[AP] starting gold: granted +" .. delta .. " (total " .. target .. ")")
  end)
end

-- Starting Armor filler: a PERMANENT armor grant, topped up to match the current item count --
-- it must persist across rooms and only deplete when you take damage (Test Run 6 #10). The
-- earlier AddHealthBuffer approach keyed MapState.HealthBufferSources, which RoomLogic.MapStateInit
-- wipes on every room load, so the armor vanished the moment you entered the next room. The game's
-- real persistent-armor primitive is AddArmor (RoomLogic.lua:2772): it grants/extends the
-- MinorArmorBoon trait (CurrentArmor), a HERO TRAIT that carries across rooms and only goes down as
-- damage eats it -- exactly "armor is permanent, only lost by taking enough damage".
--
-- How much AP has already granted THIS run is tracked on game.CurrentRun (real, saved run state),
-- NOT a Lua-memory flag: a memory flag resets to false on every process restart, so rejoining a
-- run-in-progress re-granted the FULL armor amount on top of whatever was already there every
-- single time -- "adding armor each time" (see [[project_rejoin_midrun_bug]]). CurrentRun persists
-- correctly across quit/rejoin (it's saved wholesale while active), so this now only tops up
-- whatever shortfall remains, additive-only, same as a real armor pickup would.
function ItemManager.apply_armor()
  local s = APState.get()
  if not s then return end
  local armor_target = (s.armor_items or 0) * (tonumber(ItemManager.settings["starting_armor_value"]) or 0)
  if armor_target <= 0 then return end
  -- Needs only a live hero -- AddArmor (RoomLogic.lua) just grants the MinorArmorBoon trait; no
  -- biome room required.
  if not (game.CurrentRun and game.CurrentRun.Hero) then return end
  if not game.AddArmor then
    rom.log.warning("[AP] armor: game.AddArmor is nil -- cannot apply persistent armor")
    return
  end
  local granted = game.CurrentRun.AP_ArmorGranted or 0
  local delta = armor_target - granted
  if delta <= 0 then return end                                -- already fully topped up
  pcall(function()
    -- Delay 0 (no stagger), Silent so it doesn't play the armor-gain VO/flash on spawn.
    game.AddArmor(delta, { Delay = 0, Silent = true })
    -- The HUD armor pips cache their value; refresh so the bar shows the granted armor.
    pcall(function() if game.FrameState then game.FrameState.RequestUpdateHealthUI = true end end)
    game.CurrentRun.AP_ArmorGranted = armor_target
    rom.log.info("[AP] starting armor: granted +" .. delta .. " (total " .. armor_target
      .. ", Hero.HealthBuffer=" .. tostring(game.CurrentRun.Hero.HealthBuffer) .. ")")
  end)
end

-- Grant the Daedalus Hammers the player owns for THIS run. Test Run 6 #9: instead of spawning the
-- WeaponUpgrade loot (which only appears after the room is cleared and makes the player pick), directly
-- give a RANDOM hammer upgrade, no choice -- like the Experimental Hammer keepsake, but permanent.
-- The hammer pool is game.LootData.WeaponUpgrade.Traits (the real Daedalus hammer trait list, e.g.
-- StaffDoubleAttackTrait), filtered with game.IsTraitEligible(TraitData[name]) -- exactly how the game's
-- own random-hammer code does it (TraitLogic.lua ~2585, Chaos Hammer). IsTraitEligible reads
-- CurrentRun.Hero, so it only offers hammers valid for the CURRENTLY equipped weapon AND aspect.
-- Test Run 8 #3/#6: the original pool was ScreenData.WeaponUpgradeScreen.DisplayOrder, which is the
-- ASPECT list (BaseStaffAspect, ...) -- NOT hammers, so it swapped the player's aspect and never gave a
-- hammer. Fixed to use WeaponUpgrade.Traits.
-- Test Run 8 (follow-up): granting once-per-run in the run's first room was unreliable -- on a surface
-- run that first room is the prologue opening (N_Opening01), and the N_Opening01 -> N_PreHub01 transition
-- rebuilds the hero, stripping any trait we added there, so the hammer never reached real combat. So this
-- is SELF-HEALING: we remember the exact hammer trait names we granted and on EVERY room we
-- (1) re-apply any of those the hero no longer has (undoing a rebuild wipe) and (2) grant new ones until
-- we've granted `owned` of them. Each AddTraitToHero is followed by a HeroHasTrait readback we LOG, so the
-- log proves whether the trait actually stuck (vs. AddTraitToHero silently no-opping).
--
-- The granted-names record lives on game.CurrentRun (real, saved run state), NOT Lua-module memory:
-- a memory-only list resets to empty on every process restart, so rejoining a run-in-progress made
-- step (2) below think it hadn't granted ANY hammers yet and hand out a fresh batch on top of the
-- ones already on the hero from before quitting -- "adding more and more" every rejoin/room
-- (see [[project_rejoin_midrun_bug]]). CurrentRun persists correctly across quit/rejoin (saved
-- wholesale while active), so this now only tops up the shortfall between owned and granted.
function ItemManager.grant_pending_daedalus()
  local s = APState.get()
  if not s then return end
  local owned = s.daedalus_upgrade or 0
  if owned <= 0 then return end
  -- Only inside an actual run biome room (Routes.current() ~= nil excludes the Crossroads/hub),
  -- with a live hero (so the equipped weapon and trait system exist).
  if not (game.CurrentRun and game.CurrentRun.Hero) then return end
  if not (Routes and Routes.current and Routes.current()) then return end
  if not (game.AddTraitToHero and game.HeroHasTrait) then
    rom.log.warning("[AP] daedalus: AddTraitToHero/HeroHasTrait nil -- cannot grant hammer")
    return
  end
  -- The Daedalus hammer trait pool (NOT the aspect-selection DisplayOrder -- see note above).
  local pool = game.LootData and game.LootData.WeaponUpgrade and game.LootData.WeaponUpgrade.Traits
  if type(pool) ~= "table" or #pool == 0 then
    rom.log.warning("[AP] daedalus: LootData.WeaponUpgrade.Traits unavailable -- cannot grant hammer")
    return
  end
  -- Record of the exact hammer trait names WE granted, kept on CurrentRun (see comment above).
  game.CurrentRun.AP_DaedalusGranted = game.CurrentRun.AP_DaedalusGranted or {}
  local granted = game.CurrentRun.AP_DaedalusGranted
  local function is_granted(name)
    for _, n in ipairs(granted) do if n == name then return true end end
    return false
  end
  -- Self-heal the ledger itself: adopt any pool hammer the hero already, verifiably holds but
  -- isn't in the record yet (e.g. a save from before this fix), instead of granting ANOTHER one
  -- on top of it. Keeps #granted an honest count of "how many the hero actually has" from here on.
  for _, traitName in ipairs(pool) do
    local has = false
    pcall(function() has = game.HeroHasTrait(traitName) end)
    if has and not is_granted(traitName) then
      granted[#granted + 1] = traitName
    end
  end
  -- Equipped weapon, for logging context only (eligibility comes from IsTraitEligible).
  local weapon = nil
  pcall(function() if game.GetEquippedWeapon then weapon = game.GetEquippedWeapon() end end)
  -- Add a named hammer and read back whether it stuck. Returns the readback bool.
  local function add_hammer(name)
    pcall(function() game.AddTraitToHero({ TraitName = name }) end)
    local has = false
    pcall(function() has = game.HeroHasTrait(name) end)
    return has
  end

  -- 1) Re-apply any hammer we granted earlier this run that the hero no longer has (rebuild wiped it).
  for _, name in ipairs(granted) do
    local has = false
    pcall(function() has = game.HeroHasTrait(name) end)
    if not has then
      local now = add_hammer(name)
      rom.log.info("[AP] daedalus re-apply " .. name .. " (" .. tostring(weapon)
        .. ") hasTrait=" .. tostring(now))
    end
  end

  -- 2) Grant new hammers until we've granted `owned` of them this run.
  while #granted < owned do
    -- Hammers valid for the current weapon/aspect, not already on the hero or already granted by us.
    local choices = {}
    for _, traitName in ipairs(pool) do
      local eligible = false
      pcall(function()
        local td = game.TraitData and game.TraitData[traitName]
        if td and game.IsTraitEligible and game.IsTraitEligible(td)
            and not game.HeroHasTrait(traitName) and not is_granted(traitName) then
          eligible = true
        end
      end)
      if eligible then choices[#choices + 1] = traitName end
    end
    if #choices == 0 then                       -- nothing eligible (all owned, or hero not ready)
      rom.log.warning("[AP] daedalus: no eligible hammer for current weapon/aspect ("
        .. tostring(weapon) .. ")")
      break
    end
    local pick = choices[math.random(#choices)]
    local now = add_hammer(pick)
    granted[#granted + 1] = pick                 -- record it so we maintain/re-heal it all run
    rom.log.info("[AP] Daedalus hammer granted: " .. pick .. " (" .. tostring(weapon)
      .. ") hasTrait=" .. tostring(now))
  end
end

-- NPC Gifts (single unlock, one per NPC): if you have the item, start each run with ONE
-- random pick from that NPC's own trait pool -- the same kind of bonus you'd get from
-- giving them the right present in their vanilla gift dialogue. Every pool below is
-- exhaustive: every trait defined in the game's TraitData_<NPC>.lua, apart from the shared
-- "Base<NPC>" template all of them InheritFrom. Arachne/Medea/Icarus/Circe each have their
-- own dedicated gift-trait pool (armor/curses/inventions/blessings); Dionysus/Artemis/
-- Athena/Hades don't have a separate gift mechanic in-game, so their pool is just their own
-- signature Boon set instead (see Options.StartingNpcGifts). Stacks on top of anything else
-- that grants the same trait type (intended -- e.g. Arachne's costume stacks with Melinoe's
-- own silk armor if she has one; only one costume shows visually). VERIFY in-game.
local NPC_GIFT_POOLS = {
  Arachne = {
    "AgilityCostume", "CastDamageCostume", "ManaCostume", "VitalityCostume",
    "HighArmorCostume", "IncomeCostume", "SpellCostume", "EscalatingCostume",
  },
  Medea = {
    "HealingOnDeathCurse", "MoneyOnDeathCurse", "ManaOverTimeCurse", "SpawnDamageCurse",
    "ArmorPenaltyCurse", "SlowProjectileCurse", "DeathDefianceRetaliateCurse", "NewStatusDamage",
  },
  Icarus = {
    "FocusAttackDamageTrait", "FocusSpecialDamageTrait", "OmegaExplodeBoon", "CastHazardBoon",
    "BreakExplosiveArmorBoon", "BreakInvincibleArmorBoon", "SupplyDropBoon", "UpgradeHammerBoon",
  },
  Circe = {
    "RandomArcanaTrait", "RemoveShrineTrait", "DoubleFamiliarTrait", "HealAmplifyTrait",
    "ArcanaRarityTrait", "CirceEnlargeTrait", "CirceShrinkTrait", "CirceSorceryDamageBoon",
    "ExPolymorphBoon",
  },
  Dionysus = {
    "CastLobBoon", "HiddenMaxHealthBoon", "FirstHangoverBoon", "PowerDrinkBoon",
    "CombatEncounterHealBoon", "FogDamageBonusBoon", "BankBoon", "RandomBaseDamageBoon",
  },
  Artemis = {
    "InsideCastCritBoon", "OmegaCastVolleyBoon", "HighHealthCritBoon", "CritBonusBoon",
    "DashOmegaBuffBoon", "SupportingFireBoon", "TimedCritVulnerabilityBoon", "FocusCritBoon",
    "SorceryCritBoon",
  },
  Athena = {
    "InvulnerabilityDashBoon", "RetaliateInvulnerabilityBoon", "FocusLastStandBoon",
    "AthenaProjectileBoon", "DeathDefianceRefillBoon", "InvulnerabilityCastBoon",
    "ManaSpearBoon", "OlympianSpellCountBoon",
  },
  Hades = {
    "HadesLifestealBoon", "HadesCastProjectileBoon", "HadesPreDamageBoon", "HadesChronosDebuffBoon",
    "HadesDashSweepBoon", "HadesInvisibilityRetaliateBoon", "HadesDeathDefianceDamageBoon",
    "HadesManaUrnBoon",
  },
}

-- NPC name -> its APState counter field (how many "Starting <NPC> <Gift>" items received).
local NPC_GIFT_STATE_KEY = {
  Arachne = "arachne_armor", Medea = "medea_gift", Icarus = "icarus_gift", Circe = "circe_gift",
  Dionysus = "dionysus_gift", Artemis = "artemis_gift", Athena = "athena_gift", Hades = "hades_gift",
}

function ItemManager.apply_npc_gift(npc)
  local s = APState.get()
  local stateKey = NPC_GIFT_STATE_KEY[npc]
  if not s or (s[stateKey] or 0) <= 0 then return end  -- you don't have the item
  pcall(function()
    if not (game.CurrentRun and game.CurrentRun.Hero) then return end
    -- Once per run: the random pick is NOT idempotent, and this is now also called from the
    -- ITEMS hook (mid-run receipt applies immediately) -- the CurrentRun flag stops every
    -- later ITEMS sync from stacking another pick. Saved run state, so quit/rejoin of a
    -- post-grant run doesn't re-grant either.
    local flag = "AP_" .. npc .. "GiftGranted"
    if game.CurrentRun[flag] then return end
    local pool = NPC_GIFT_POOLS[npc]
    local pick = pool[math.random(#pool)]
    game.AddTraitToHero({ TraitName = pick })
    game.CurrentRun[flag] = true
    rom.log.info("[AP] " .. npc .. " gift: granted random " .. pick)
  end)
end

function ItemManager.apply_all_npc_gifts()
  for npc in pairs(NPC_GIFT_POOLS) do
    ItemManager.apply_npc_gift(npc)
  end
end

-- Increased Help Odds filler: special field-NPC combat encounters (Artemis/Athena/Icarus/
-- Heracles, etc.) are gated by the NoRecentFieldNPCEncounter requirement -- a cooldown of
-- SumPrevRooms (6) rooms between them. Each item shortens that cooldown, so they appear
-- more often. Applied each run (the requirement data resets on reload). VERIFY in-game.
function ItemManager.apply_help_odds()
  local s = APState.get()
  if not s then return end
  local n = s.help_odds or 0
  -- "Increased Help Odds" is stubbed out of the item pool (see Items.py), so n is 0 on
  -- current seeds: skip the per-room requirement rewrite + log line entirely. The item
  -- counter and this handler stay dormant so an old save that received some still works.
  if n <= 0 then return end
  pcall(function()
    local rd = game.RequirementsData and game.RequirementsData.NoRecentFieldNPCEncounter
    local entry = rd and rd[1]
    if entry and entry.SumPrevRooms then
      ItemManager.base_field_npc_cooldown = ItemManager.base_field_npc_cooldown or entry.SumPrevRooms
      entry.SumPrevRooms = math.max(1, ItemManager.base_field_npc_cooldown - n)
      rom.log.info("[AP] help odds: field-NPC cooldown " .. ItemManager.base_field_npc_cooldown
        .. " -> " .. entry.SumPrevRooms .. " (help_odds=" .. n .. ")")
    end
  end)
end

-- If the seed starts with the surface unlocked, open the door once settings arrive. The
-- Penalty Cure is always precollected as a real AP item too (arrives via the normal item
-- path), but grant it here as well so a surface start isn't waiting on item sync.
function ItemManager.apply_surface_start()
  if ItemManager.setting_on("surface_start") then
    grant_surface_access()
    grant_penalty_cure()
  end
end

function ItemManager.apply_nightmare_start()
  if ItemManager.setting_on("nightmare_start") then
    ItemManager.grant_nightmare_access()
  end
end

-- The Crossroads' Surface run door is actually TWO separate placed obstacles in
-- HubRoomData.Hub_PreRun.ObstacleData (verified against the real game's DeathLoopData.lua
-- ~6919-6968): 558268 ("locked", UseText=UseLockedSurfaceRunDoor / OnUsedFunctionName=
-- LockedSurfaceRunPresentation, spawned when WorldUpgrades.WorldUpgradeAltRunDoor is FALSE) and
-- 555784 ("unlocked", OnUsedFunctionName=UseEscapeDoor, spawned when it's TRUE). Each has
-- DestroyIfNotSetup=true + a SetupGameStateRequirements check on that exact flag -- vanilla only
-- ever evaluates that pair when the room's obstacles are set up (RoomLogic.lua's map-load loop:
-- DeepCopyTable the definition, stamp the fixed ObjectId, call SetupObstacle, which destroys the
-- loser and wires up the winner). There is NO live re-check. So if the flag flips while the
-- player is already standing in Hub_PreRun (e.g. a Progressive Surface resolves mid-session
-- while they're in that room), the locked obstacle stays spawned and the unlocked one never gets
-- wired up until the room itself reloads -- our WorldUpgrades write is correct (matches vanilla's
-- own AddWorldUpgrade, GhostAdminLogic.lua ~553), it's the room's already-spawned obstacle that's
-- stale. Force the exact same re-evaluation vanilla's own map-load loop does, for just this door
-- pair, so a live grant takes effect immediately instead of waiting for a room transition that may
-- never come. Idempotent (SetupObstacle re-affirms an already-correct state harmlessly), so safe
-- to call on every reassert. Nightmare's Chaos Gate doesn't need this: it's our own always-present
-- obstacle toggled directly by apply_nightmare_gate_lock, not a vanilla two-variant spawn choice.
local SURFACE_DOOR_OBSTACLE_IDS = { 555784, 558268 }
function ItemManager.refresh_surface_door(currentRoom)
  currentRoom = currentRoom or (game.CurrentRun and game.CurrentRun.CurrentRoom)
  if not (currentRoom and currentRoom.Name == "Hub_PreRun") then return end
  local defs = game.HubRoomData and game.HubRoomData.Hub_PreRun and game.HubRoomData.Hub_PreRun.ObstacleData
  if not (defs and game.SetupObstacle and game.DeepCopyTable) then return end
  for _, id in ipairs(SURFACE_DOOR_OBSTACLE_IDS) do
    local def = defs[id]
    if def then
      local obstacle = game.DeepCopyTable(def)
      obstacle.ObjectId = id
      pcall(function() game.SetupObstacle(obstacle, true) end)
    end
  end
  rom.log.info("[AP] Surface door: refreshed live (Hub_PreRun obstacle re-evaluated)")
end

-- Re-open the door for any route the player has ALREADY progressed into. grant_surface_access /
-- grant_nightmare_access run exactly once -- the moment their Progressive/Access item is applied --
-- and set a persistent flag (WorldUpgradeAltRunDoor for the Surface; our own flag for Nightmare).
-- apply_full_list is idempotent (s.processed), so on a reboot/reconnect that one-time grant never
-- fires again: the open door then depends entirely on GameState.WorldUpgrades having persisted the
-- flag. If that write didn't stick (the item landed during the reboot gap before GameState was the
-- loaded save, or a save quirk dropped it), nothing re-applies it and the route stays locked with no
-- self-heal -- "worked before, randomly locked now". route_progress IS persisted in our own APState,
-- so treat it as the source of truth: any route with progress > 0 must have its door open. The
-- grant_* helpers only set flags (idempotent), so this is safe to run every room like the armor /
-- stat-bonus / aspect / Nightmare-gate reasserts. surface_start / nightmare_start seeds are covered
-- by apply_surface_start / apply_nightmare_start, which the same hooks already call.
function ItemManager.reassert_route_access(currentRoom)
  local s = APState.get()
  if not s or not s.route_progress then return end
  if (s.route_progress.Surface or 0) > 0 then
    grant_surface_access()
    pcall(function() ItemManager.refresh_surface_door(currentRoom) end)
  end
  if (s.route_progress.Nightmare or 0) > 0 then ItemManager.grant_nightmare_access() end
end

-- Apply the seed's starting weapon. weaponsanity gates every weapon behind an AP item and
-- the Python world leaves the chosen starting weapon out of the pool, so the mod must:
--   1. Unlock the chosen weapon kit (else a non-Staff roll is never obtainable).
--   2. Make it the hero's DefaultWeapon, so the very first run - which has no previous run
--      to copy its loadout from - starts with it instead of the Staff. CreateNewHero reads
--      HeroData.DefaultWeapon for that first hero (RunLogic.CreateNewHero).
--   3. Lock EVERY other weapon that AP hasn't unlocked yet, so weaponsanity gates them like
--      any other item. The weapon rack / equip checks gate purely on GameState.WeaponsUnlocked
--      (UpgradeLogic.IsWeaponUnlocked), so clearing a flag removes that weapon from selection.
--      This must cover all kits, not just the Staff: a real save carried over from normal play
--      already has several weapons unlocked, and leaving them set let the player use (and even
--      auto-equip via PrimaryWeaponName) a weapon before its AP item arrived.
-- Takes effect on the next CreateNewHero, so it must arrive before the first run is started
-- (the normal flow: connect the client, then begin a run).

-- Whether AP has already unlocked weapon kit `w` this seed (so apply_initial_weapon must NOT
-- re-lock it on a later SETTINGS). weapon_ap_unlocked covers both sanity modes going forward;
-- the combined_weapon clause self-heals older combine saves that predate weapon_ap_unlocked.
local function weapon_ap_unlocked(s, w)
  if not s then return false end
  if s.weapon_ap_unlocked and s.weapon_ap_unlocked[w] then return true end
  local short = ItemManager.WEAPON_KIT_TO_SHORT[w]
  if s.combined_weapon and short and (s.combined_weapon[short] or 0) > 0 then return true end
  return false
end

-- aspectsanity's randomized/per_aspect modes give the starting weapon a random Aspect
-- (Python's starting_aspect_index: 0 = the default Aspect of Melinoe, 1-3 = one of its 3
-- alternates in ASPECTS_BY_WEAPON order -- see __init__._main_pool_item_names) already
-- active on the very first run, instead of always Melinoe's.
-- Two halves to that: UNLOCKING the Aspect, and making the game actually EQUIP it.
--   Unlock: per_aspect precollects the Aspect's first Progressive copy, so the normal ITEMS path
--     (apply_per_aspect) handles it. randomized precollects NOTHING -- the pick starts at rank 1
--     and its item stays in the pool to max it out later -- so the rank-1 unlock happens here.
--   Equip: EquipWeaponUpgrade (WeaponUpgradeLogic.lua) reads GameState.LastWeaponUpgradeName
--     [weapon] to pick the active Aspect, and nothing sets that for a weapon that was never bought
--     through the shop (only a real purchase does, in DoWeaponShopPurchase). Force it here,
--     mirroring how DefaultWeapon forces the starting weapon itself.
-- UNVERIFIED in-game -- confirm a fresh randomized/per_aspect seed actually starts equipped with
-- the picked Aspect.
local function apply_starting_aspect(kit)
  local asp = ItemManager.setting_mode("aspectsanity")
  if asp ~= 1 and asp ~= 3 then return end
  local short = ItemManager.WEAPON_KIT_TO_SHORT[kit]
  if not short then return end
  local index = ItemManager.setting_mode("starting_aspect_index")
  local internal
  if index == 0 then
    internal = ASPECT_BASE_BY_WEAPON[short]
  else
    local alts = ASPECTS_BY_WEAPON[short]
    internal = alts and alts[index]
  end
  if not internal then return end
  -- randomized: grant the pick at rank 1 (unlock only -- no <internal>2..5 keys, so
  -- GetWeaponUpgradeLevel stays 1). Recorded in aspect_ap_unlocked so apply_aspect_base_lock
  -- won't re-lock it when the pick IS that weapon's Aspect of Melinoe, and so this only fires
  -- once. Deliberately ahead of the LastWeaponUpgradeName guard below: the seed says you own this
  -- Aspect at rank 1 regardless of which Aspect a carried-over save already has on record.
  if asp == 1 then
    local s = APState.get()
    if s and not s.aspect_ap_unlocked[internal] then
      unlock_aspect_id(internal)
      s.aspect_ap_unlocked[internal] = true
      rom.log.info("[AP] starting aspect " .. internal .. " unlocked at RANK 1 for " .. short
        .. " (its item is still in the pool and maxes it out)")
    end
  end
  -- Guard on the game's OWN record, not just APState.starting_aspect_seeded: logs from the
  -- field show the seeded flag failing to stick across room transitions (it re-fired on ~131
  -- of ~140 rooms in one session instead of once), continually stomping LastWeaponUpgradeName
  -- back to the seed's starting Aspect. That fed the vanilla WeaponUpgrade (Daedalus Hammer)
  -- reward screen, which reads this same field to filter eligible hammers -- so the player kept
  -- getting hammer choices for the SEED aspect instead of whatever Aspect they'd actually
  -- equipped. GameState.LastWeaponUpgradeName is core save data (aspect selection has always
  -- persisted through it), so checking it directly is self-healing regardless of why our own
  -- Archipelago-table flag doesn't hold: once ANY aspect (ours or the player's own pick) is on
  -- record for this weapon, never touch it again.
  if game.GameState and game.GameState.LastWeaponUpgradeName
      and game.GameState.LastWeaponUpgradeName[kit] ~= nil then
    return
  end
  pcall(function()
    if game.GameState then
      game.GameState.LastWeaponUpgradeName = game.GameState.LastWeaponUpgradeName or {}
      game.GameState.LastWeaponUpgradeName[kit] = internal
    end
  end)
  rom.log.info("[AP] starting aspect for " .. short .. " -> " .. internal .. " (index " .. index .. ")")
end

function ItemManager.apply_initial_weapon()
  local kit = INITIAL_WEAPON_TO_KIT[ItemManager.setting_mode("initial_weapon")]
  if not kit then return end
  ItemManager._weapons_locked = {}   -- reset each call so the log below reflects THIS run
  pcall(function()
    -- The chosen weapon becomes the run-start default.
    if game.HeroData then game.HeroData.DefaultWeapon = kit end
    if game.CurrentRun and game.CurrentRun.Hero then
      game.CurrentRun.Hero.DefaultWeapon = kit
    end
    local wu = game.GameState and game.GameState.WeaponsUnlocked
    if wu then
      wu[kit] = true
      -- Lock every other weapon AP hasn't unlocked yet. apply_initial_weapon runs on EVERY
      -- SETTINGS, so the weapon_ap_unlocked guard keeps a kit the player already earned from
      -- being re-locked after a restart (the idempotent ITEMS resend never restores it -- Test
      -- Run 8 #4). INITIAL_WEAPON_TO_KIT is the canonical full kit list, so this doesn't depend
      -- on game.WeaponSets being loaded at boot.
      local s = APState.get()
      local locked = {}
      for _, w in pairs(INITIAL_WEAPON_TO_KIT) do
        if w ~= kit and wu[w] and not weapon_ap_unlocked(s, w) then
          wu[w] = nil
          locked[#locked + 1] = ItemManager.WEAPON_KIT_TO_SHORT[w] or w
        end
      end
      table.sort(locked)
      ItemManager._weapons_locked = locked
    end
  end)
  -- NOTE: apply_starting_aspect is NOT called here. This function runs synchronously inside
  -- the SETTINGS handler, which on a fresh launch fires from a blocking pre-run fetch BEFORE
  -- vanilla's StartNewRun ever runs (see reload.lua Bridge.on("SETTINGS", ...)). Writing
  -- GameState.LastWeaponUpgradeName that early makes vanilla's own hero-setup code reactively
  -- re-equip the aspect via AddTraitToHero while building the very first room -- before
  -- RoomLogic.MapStateInit() has run for that room -- which crashes with "attempt to index
  -- global 'MapState' (a nil value)" (TraitLogic.lua:922). Call ItemManager.reassert_starting_aspect()
  -- from the StartRoom hook instead, where MapState is already known to exist (that's where
  -- apply_armor/grant_pending_daedalus safely run today).
  local locked = ItemManager._weapons_locked or {}
  rom.log.info("[AP] initial weapon: " .. kit
    .. (#locked > 0 and " (locked: " .. table.concat(locked, ", ") .. ")" or ""))
end

-- Seed the run's starting Aspect ONCE (see apply_starting_aspect above for why this must run from
-- StartRoom, not the SETTINGS handler). It is NOT safe to re-force every room: LastWeaponUpgradeName
-- is GameState (save) data, so once written it persists across rooms, runs, and quit/rejoin -- and
-- from the very first run onward the player picks their Aspect at the weapon-select screen. Re-forcing
-- it every room clobbered that choice, yanking the player back to the seed's starting Aspect the
-- instant they equipped a different Aspect they'd unlocked from an AP item (reported "weapon aspect
-- randomly swapped to a received Aspect" bug -- the received Aspect being the precollected starting
-- one). Guard on a persistent flag so we only seed the first run's opening loadout, then leave the
-- player's Aspect selection alone. (Surface-start's intro room is bounced/killed, but the seeded value
-- persists into the real first run, so seeding there is fine.)
--
-- FUTURE FEATURE: an opt-in "aspect shuffle / received-aspect auto-equip" could deliberately re-point
-- LastWeaponUpgradeName[weapon] to an Aspect the moment its AP item is received (i.e. turn this swap
-- into an intentional mechanic). If added, gate it behind its own setting and drive it from the ITEMS
-- path (unlock_aspect / apply_per_aspect), NOT from this every-room reassert.
function ItemManager.reassert_starting_aspect()
  local kit = INITIAL_WEAPON_TO_KIT[ItemManager.setting_mode("initial_weapon")]
  if not kit then return end
  local s = APState.get()
  if s and s.starting_aspect_seeded then return end
  apply_starting_aspect(kit)
  if s then s.starting_aspect_seeded = true end
end

-- Make sure the run starts equipped with the weapon the player actually intends (Test Run 6 #2,
-- still wrong in Test Run 7). Two game behaviours fight us:
--   1. On an existing save (prevRun ~= nil) CreateNewHero COPIES the whole previous weapon set
--      (RunLogic.lua:17), so the hero carries every weapon, not just the chosen one.
--   2. GetEquippedWeapon (WeaponUpgradeLogic.lua:363) returns the FIRST HeroPrimaryWeapons entry
--      present in Hero.Weapons, and WeaponStaffSwing is first in that list (WeaponSets.lua) -- so
--      whenever the Staff is present it "wins", regardless of the weapon-rack pick.
-- The weapon rack / altar writes the player's choice to GameState.PrimaryWeaponName
-- (CombatLogic.EquipPlayerWeapon:4715). The old version ignored that and keyed off sort order,
-- bailing out whenever the sort-first weapon happened to be unlocked -- so a rack pick of, say, the
-- Axe was silently overridden by the Staff. Fix: choose the target by INTENT, then normalize the
-- loadout to exactly that one primary so GetEquippedWeapon resolves to it.
-- Target priority: (1) the rack choice (PrimaryWeaponName) if AP-unlocked, (2) the configured
-- initial weapon if unlocked, (3) the first unlocked primary. Call at StartNewRun after base (hero
-- exists, runs on the game thread so EquipPlayerWeapon's presentation thread is safe).
function ItemManager.enforce_equipped_weapon()
  if not (game.CurrentRun and game.CurrentRun.Hero) then return end
  local hero = game.CurrentRun.Hero
  local wu = (game.GameState and game.GameState.WeaponsUnlocked) or {}
  local primaries = (game.WeaponSets and game.WeaponSets.HeroPrimaryWeapons) or {}
  hero.Weapons = hero.Weapons or {}
  local function is_primary(name)
    for _, w in ipairs(primaries) do if w == name then return true end end
    return false
  end
  -- What the game currently considers equipped (first primary present, sort order).
  local equipped = nil
  for _, w in ipairs(primaries) do
    if hero.Weapons[w] then equipped = w; break end
  end
  -- Resolve the intended target.
  local target = nil
  local choice = game.GameState and game.GameState.PrimaryWeaponName
  if choice and is_primary(choice) and wu[choice] then
    target = choice                                   -- honor the player's rack/altar pick
  end
  if not target then
    local init = INITIAL_WEAPON_TO_KIT[ItemManager.setting_mode("initial_weapon")]
    if init and wu[init] then target = init end       -- the seed's starting weapon
  end
  if not target then
    for _, w in ipairs(primaries) do                  -- any unlocked primary as a fallback
      if wu[w] then target = w; break end
    end
  end
  if not target then
    rom.log.warning("[AP] enforce weapon: no unlocked primary weapon found (equipped="
      .. tostring(equipped) .. ", choice=" .. tostring(choice) .. ")")
    return
  end
  if equipped == target then
    if game.GameState then game.GameState.PrimaryWeaponName = target end
    return                                            -- already correct: leave the loadout alone
  end
  -- Normalize to exactly the target primary (+ its secondary) so GetEquippedWeapon resolves to it.
  for _, w in ipairs(primaries) do
    if w ~= target then hero.Weapons[w] = nil end
  end
  hero.Weapons[target] = true
  local secondary = game.WeaponData and game.WeaponData[target]
    and game.WeaponData[target].SecondaryWeapon
  if secondary then hero.Weapons[secondary] = true end
  pcall(function()
    if game.EquipPlayerWeapon and game.WeaponData and game.WeaponData[target] then
      game.EquipPlayerWeapon(game.WeaponData[target], { SkipPresentation = true })
    end
  end)
  if game.GameState then game.GameState.PrimaryWeaponName = target end
  rom.log.info("[AP] enforce equipped weapon -> " .. target .. " (was " .. tostring(equipped)
    .. ", choice=" .. tostring(choice) .. ")")
end

-- ---- Fresh-save intro redirect (surface starts) -------------------------------
-- The brand-new-save intro map is HARDCODED IN THE ENGINE BINARY: Hades2.exe itself contains
-- "F_Opening01" and always loads it for a fresh save -- no Lua data flag can pre-empt that
-- load (the old approach set RoomData.N_Opening01.GameStart/Starting, but the GameStart flag
-- is only read by OnAnyLoad's "Illegal DirectLoad" save-validation, never for map CHOICE, so
-- it did nothing; N_Opening01 already carries Starting=true natively anyway -- it's vanilla's
-- own first-Surface-run opener). What IS Lua-side is everything after the load: OnAnyLoad
-- (RoomLogic.lua) sees GameState==nil and calls StartNewGame(mapName) -> StartNewRun(nil,
-- { RoomName = mapName, StartingBiome = "F" }), and StartNewRun builds the run around
-- args.RoomName (RunLogic.lua: CreateRoom(RoomData[args.RoomName])). So the redirect is:
--   1. redirect_intro_args (StartNewRun wrap, pre-base): rewrite args.RoomName/StartingBiome
--      to N_Opening01/"N", so the run is built NATIVELY around the Surface opening -- room,
--      biome tracking, and RoomHistory all correct from the start.
--   2. complete_intro_redirect (StartRoom wrap, pre-base): the engine's F_Opening01 map is
--      still the one on screen, so when OnAnyLoad reaches StartRoom for our N room, swap the
--      actual map exactly the way the game's own hub->run flow does (DeathLoopLogic's
--      "StartOver": build the run, then LoadMap its CurrentRoom.Name) -- LoadMap yields, the
--      N_Opening01 map loads next frame, and its OnAnyLoad calls StartRoom again properly
--      (CurrentRoom.Name == mapName path). The mismatched first StartRoom call never runs.
-- The result: a surface-start seed's very first run IS vanilla's own Surface opening run --
-- no forced Underworld visit, no bounce-kill. The kill (below) remains only as a fallback for
-- the vanishingly-unlikely case that the redirect can't arm/complete.
function ItemManager.redirect_intro_args(args)
  if not args or args.RoomName == "N_Opening01" then return false end
  -- Only arm when everything the swap needs is present; otherwise leave the old kill path.
  if not (game.RoomData and game.RoomData.N_Opening01 and game.LoadMap and game.CreateRoom) then
    rom.log.warning("[AP] intro redirect unavailable (RoomData.N_Opening01/LoadMap missing)")
    return false
  end
  args.RoomName = "N_Opening01"
  args.StartingBiome = "N"
  ItemManager.intro_map_redirect_pending = true
  ItemManager.intro_redirect_is_nightmare = false   -- surface uses the LoadMap branch
  return true
end

-- Consume the one mismatched StartRoom call after redirect_intro_args (see above). Returns
-- true when the call was consumed (the wrap must then skip base -- the real StartRoom runs
-- from the next map load's OnAnyLoad instead).
function ItemManager.complete_intro_redirect(currentRoom, currentRun)
  if not ItemManager.intro_map_redirect_pending then return false end
  ItemManager.intro_map_redirect_pending = false
  local is_nightmare = ItemManager.intro_redirect_is_nightmare
  ItemManager.intro_redirect_is_nightmare = false
  currentRun = currentRun or game.CurrentRun
  local ok = false
  if is_nightmare then
    -- Nightmare (Zagreus' Journey): DO NOT LoadMap. ZJ's Hades-1 room-entrance content -- the
    -- ported audio banks (AudioLogic.AudioStateInit), biome music, RoomOpening's entrance drop
    -- (EntranceFunctionName = RoomEntranceDropRoomOpening), and the exit-door reward previews --
    -- all fire only through the canonical LeaveRoom transition and are gated on
    -- ModsNikkelMHadesBiomesIsModdedRun/RoomSetName. A bare LoadMap loads the geometry but skips
    -- every one of those hooks, so the door shows no reward and the H1 audio never loads. Replicate
    -- ZJ's own fresh-file sequence verbatim (its RoomPresentation.lua StartRoomPresentation wrap):
    -- re-choose the Tartarus starting room and walk into it via LeaveRoom, using a throwaway
    -- F_Opening01 as the room we leave FROM. This reuses the exact path ZJ's speedrun-fresh-file
    -- feature is proven on, so every ZJ hook fires in the order/state it was written for.
    pcall(function()
      rom.log.info("[AP] nightmare intro redirect: entering RoomOpening/Tartarus via ZJ's LeaveRoom"
        .. " fresh-file sequence so ported audio + reward previews load")
      local nextRoom = game.ChooseStartingRoom(currentRun, { StartingBiome = "Tartarus" })
      currentRun.CurrentRoom = game.CreateRoom(game.RoomData["F_Opening01"], { StartingBiome = "F" }) or {}
      currentRun.CurrentRoom.ExitFunctionName = "FastExitPresentation"
      game.LeaveRoom(currentRun, { Room = nextRoom })
      ok = true
    end)
  else
    -- Surface: vanilla N_Opening01 has no modded room-entrance dependencies, so the cheap LoadMap
    -- swap is fine (its OnAnyLoad calls StartRoom properly on the next frame).
    pcall(function()
      rom.log.info("[AP] intro redirect: loading map " .. tostring(currentRoom and currentRoom.Name)
        .. " for the run the engine's hardcoded F_Opening01 load ignored")
      game.LoadMap({ Name = currentRoom.Name, ResetBinks = true })
      ok = true
    end)
  end
  if not ok then
    -- Should be unreachable (the redirect_*_intro_args arming checks verified the needed game.*
    -- functions exist). Last resort: the old intro kill, so the player still reaches the Crossroads
    -- and takes the Surface door / Chaos Gate from there.
    rom.log.error("[AP] intro redirect failed -- falling back to the intro kill")
    ItemManager.forcing_deathlink = true
    pcall(function()
      if game.CurrentRun and game.CurrentRun.Hero then
        game.Kill(game.CurrentRun.Hero, { Name = "Archipelago Intro Start" })
      end
    end)
    ItemManager.forcing_deathlink = false
  end
  return true
end

-- True when the player's FIRST run should be a Surface run: the Surface is unlocked at the start and
-- the Underworld is NOT freely available. Covers both "Surface only" seeds (Underworld excluded) and
-- the common "start on the Surface, Underworld locked" seed (included_routes=both, starting_route=
-- surface, lock_routes on). starting_route: 1=underworld, 2=surface, 3=both. A "random"
-- choice is already resolved to a concrete route by Python's _normalize_route_options
-- before slot_data is filled, so the value here is never 0.
function ItemManager.first_run_should_be_surface()
  if not ItemManager.setting_on("surface_start") then return false end       -- Surface not started
  if not ItemManager.route_active("Underworld") then return true end          -- Underworld excluded
  -- Underworld exists but is locked at the start (lock_routes) and isn't a starting route.
  return ItemManager.setting_on("lock_routes")
    and ItemManager.setting_mode("starting_route") == 2                        -- explicitly Surface
end

-- Nightmare counterpart to first_run_should_be_surface. True when the player's FIRST run should be
-- a Nightmare run: Nightmare is unlocked at the start (nightmare_start) and the Underworld is NOT
-- freely available. Covers both "Nightmare only" seeds (Underworld excluded) and the "start on
-- Nightmare, Underworld locked" seed (included_routes include Underworld, starting_route=nightmare,
-- lock_routes on). starting_route: 1=underworld, 2=surface, 3=all, 4=nightmare (random already
-- resolved to a concrete route by Python before slot_data is filled, so never 0).
function ItemManager.first_run_should_be_nightmare()
  if not ItemManager.setting_on("nightmare_start") then return false end       -- Nightmare not started
  if not ItemManager.route_active("Underworld") then return true end            -- Underworld excluded
  -- Underworld exists but is locked at the start (lock_routes) and isn't a starting route.
  return ItemManager.setting_on("lock_routes")
    and ItemManager.setting_mode("starting_route") == 4                         -- explicitly Nightmare
end

-- ---- Fresh-save intro redirect (Nightmare starts) -----------------------------
-- The Nightmare counterpart to redirect_intro_args (Surface). Contrary to an earlier belief that
-- "Zagreus' Journey has no opening map", ZJ's Nightmare opening IS a normal room -- "RoomOpening"
-- in the "Tartarus" biome (Scripts/RoomDataTartarus.lua) -- and starting a Nightmare run is just a
-- vanilla UseEscapeDoor into that biome (the Crossroads Chaos Gate wraps exactly that in a dive
-- animation; DeathLoopData.StartHadesRun -> UseEscapeDoor{ StartingBiome = "Tartarus" }). So we
-- redirect the same way the Surface does: rewrite the fresh-save run args to RoomOpening/Tartarus.
-- The engine still loads its hardcoded F_Opening01, but StartNewRun builds the run around these args
-- (and ZJ's ChooseStartingRoom wrap then flags it a modded run from StartingBiome="Tartarus"), so the
-- run IS a Nightmare/Tartarus run from the start; only the on-screen MAP is still the Erebus opening.
--
-- The consume step (complete_intro_redirect, is_nightmare branch) enters RoomOpening by replicating
-- ZJ's OWN fresh-file sequence -- game.ChooseStartingRoom{StartingBiome="Tartarus"} + a throwaway
-- F_Opening01 + game.LeaveRoom into the chosen room -- rather than a bare game.LoadMap. This is
-- deliberate: ZJ's ported audio banks, biome music, RoomOpening entrance drop, and exit-door reward
-- previews all hang off the canonical LeaveRoom room-entrance pipeline and no-op under a raw LoadMap
-- (that was the "nothing loads" bug: blank reward door + no Hades-1 audio).
--
-- (History: an even earlier attempt set ZJ's own mod.NeedsFreshFileMapReload flag through our
-- nightmare_mod() handle. That failed because ZJ reads that flag off its internal ModUtil object
-- (`mod = modutil.mod.Mod.Register(guid)`), NOT the rom.mods[guid] table our handle returns. The
-- LoadMap workaround that replaced it got the run labeled Tartarus but skipped ZJ's entrance hooks --
-- hence this LeaveRoom version, which calls the same game.* functions ZJ's feature does and needs no
-- access to ZJ's private flag table.)
function ItemManager.redirect_nightmare_intro_args(args)
  if not args then return false end
  -- Only arm when the destination room actually exists (ZJ loaded); otherwise leave the bounce-kill
  -- fallback. ZJ merges its rooms into game.RoomData; check RoomSetData.Tartarus too, just in case.
  local have_room = (game.RoomData and game.RoomData.RoomOpening)
    or (game.RoomSetData and game.RoomSetData.Tartarus and game.RoomSetData.Tartarus.RoomOpening)
  -- The redirect enters via the LeaveRoom sequence (see complete_intro_redirect), so require the
  -- game.* functions THAT path uses (not game.LoadMap), plus the throwaway F_Opening01 room data.
  local have_fns = game.ChooseStartingRoom and game.CreateRoom and game.LeaveRoom
    and game.RoomData and game.RoomData.F_Opening01
  if not (ItemManager.nightmare_mod() and have_room and have_fns) then
    rom.log.warning("[AP] nightmare intro redirect unavailable (ZJ/RoomOpening/LeaveRoom fns missing)")
    return false
  end
  args.RoomName = "RoomOpening"
  args.StartingBiome = "Tartarus"
  ItemManager.intro_map_redirect_pending = true
  ItemManager.intro_redirect_is_nightmare = true   -- consume via ZJ's LeaveRoom sequence, not LoadMap
  return true
end

-- FALLBACK ONLY for the Surface (see the intro-redirect block above -- the redirect makes this
-- obsolete for the Surface in normal operation): if the redirect couldn't arm, let the intro run
-- start, then instantly kill Melinoe -- which routes through the game's OWN first-death ->
-- Crossroads flow -- so she lands in the hub and takes the Surface door from there. Set by the
-- StartNewRun hook on the surface-start intro; fired once from StartRoom.
ItemManager.pending_surface_intro_kill = ItemManager.pending_surface_intro_kill or false

-- FALLBACK ONLY for the Nightmare (mirrors the Surface fallback above): used only when
-- redirect_nightmare_intro_args couldn't arm (ZJ not present/loaded yet, or RoomOpening missing).
-- Kills Melinoe once at the forced Underworld boot intro so the game's own first-death -> Crossroads
-- flow lands her in the hub, where the (already-unlocked) Chaos Gate begins the Nightmare run.
ItemManager.pending_nightmare_intro_kill = ItemManager.pending_nightmare_intro_kill or false

-- True only during the ONE special room load described below: the game's own StartNewRun fired
-- with prevRun == nil (a genuinely-fresh session boot, not just "first room of a run" -- every
-- run's first room can be named "X_OpeningNN" under some routes/integrations, that's normal and
-- perfectly killable). Set by reload.lua's StartNewRun wrap; cleared by the StartRoom wrap the
-- moment the room actually changes away from that one intro room. See in_scripted_opening_room.
ItemManager.in_boot_intro_run = false
ItemManager.boot_intro_room_name = nil

-- Queued incoming DeathLinks (see reload.lua's "DEATH" handler). Applied one-per-frame by
-- flush_pending_deathlink below, only once the player is in a state where a kill actually
-- lands AND presents. Persist across hot-reloads so a queued death isn't dropped on reload.
ItemManager.pending_deathlinks = ItemManager.pending_deathlinks or 0
-- FIFO of sender slot names, one per queued DeathLink above (see reload.lua's DEATH handler).
-- Persisted across hot-reloads for the same reason pending_deathlinks is.
ItemManager.pending_deathlink_sources = ItemManager.pending_deathlink_sources or {}
-- Guards flush_pending_deathlink against spawning a second kill thread while one is still
-- resolving. Reset to false on every (re)load so a hot-reload mid-death can't wedge it true.
ItemManager.deathlink_in_progress = false
-- os.clock() timestamp of the next allowed attempt. 0 means "try right now" -- a DeathLink
-- always gets one immediate attempt the moment it's queued; only a FAILED attempt schedules
-- the next one 3s out, so we're not silently re-checking (and re-failing) every single render
-- frame with no trace of it. See flush_pending_deathlink.
ItemManager.deathlink_next_attempt_at = 0
local DEATHLINK_RETRY_SECONDS = 3

-- True only when applying a DeathLink right now would actually work: a live Hero exists, is
-- not already dying, has HP to lose, the death handler isn't mid-sequence, no scripted input
-- block is up, and the game is NOT paused. During the pause menu all game threads are frozen,
-- so a Kill/CheckLastStand issued then does nothing (or worse, resolves on unpause in a
-- half-state) -- so we hold the DeathLink and let the next frame retry once the player unpauses.
-- SessionMapState.IsPaused is the game's own pause flag (set true on PauseScreen open, cleared
-- on close -- UILogic.lua).
--
-- The active-input-block check covers room transitions: walking through a door runs a scripted
-- MapLoad/LeaveRoom sequence that holds a named input block start to finish. A DeathLink that
-- flushes mid-transition resolves in a half-state -- the death collides with the transition and
-- its input block is never removed, leaving the player stuck-at-1-HP and unable to move on the
-- far side of the door. Notifications.active_input_blocks mirrors every named engine input block
-- (see reload.lua's AddInputBlock/RemoveInputBlock wraps), so holding while any is set defers the
-- DeathLink to a clean, unblocked, movable frame -- same principle as the pause guard.
-- The scripted, session-boot intro room (StartNewRun fired with prevRun == nil). On a genuinely
-- fresh session this is the ONLY room loaded, and its death flow is NOT a normal Crossroads
-- respawn -- it feeds the scripted intro continuation. A DeathLink that kills Melinoe here lands
-- the kill but the death->transition never resolves, so the game locks up (reported: deathlink
-- right after loading a new save, killed her, then froze). The mod's own intro kill
-- (kill_surface_intro) is safe only because it fires at one controlled StartRoom moment through
-- the game's first-death path; an arbitrary render frame here is not. So we hold the DeathLink
-- and let it land the moment she's in a real, killable room -- same principle as the pause /
-- input-block guards below.
--
-- NOT room-name matching (tried "F_Opening01"/"N_Opening01" exact-match, and before that a
-- "_Opening%d*" wildcard -- both wrong). The Zagreus Journey integration names the first room of
-- EVERY run "X_OpeningNN" (F_Opening02, N_Opening01, ...) as normal, perfectly-killable room
-- naming, not just the one-time boot intro -- either match held every DeathLink for that room's
-- whole ~40s duration on every single run, only releasing at the next room transition. The real
-- signal is ItemManager.in_boot_intro_run, set only by the actual prevRun == nil StartNewRun call
-- (reload.lua) and cleared the moment the room changes (StartRoom wrap), so it can never apply to
-- an ordinary run's first room.
local function in_scripted_opening_room()
  return ItemManager.in_boot_intro_run == true
end

-- Returns can_apply, reason. reason is only meaningful when can_apply is false -- it's what
-- flush_pending_deathlink logs so a held DeathLink is diagnosable instead of silently stuck.
local function deathlink_can_apply()
  if not (game.CurrentRun and game.CurrentRun.Hero) then return false, "no live Hero" end
  local hero = game.CurrentRun.Hero
  if hero.IsDead then return false, "Hero already dead" end
  if (hero.Health or 0) <= 0 then return false, "Hero at 0 HP" end
  if in_scripted_opening_room() then return false, "scripted opening room" end
  if game.SessionMapState and game.SessionMapState.HandlingDeath then return false, "HandlingDeath" end
  if game.SessionMapState and game.SessionMapState.IsPaused then return false, "game paused" end
  -- Boon selection (ScreenAnchors.ChoiceScreen) + any scripted input block (conversations,
  -- cutscenes, room transitions) both block a clean kill. Notifications.blocked() covers both --
  -- the ChoiceScreen half is the newly-closed gap: a DeathLink flushing mid-boon-selection would
  -- kill Melinoe with the choice modal still open (same unsafe moment the item gate guards).
  if Notifications and Notifications.blocked and Notifications.blocked() then return false, "screen/input blocked" end
  return true
end

-- Apply at most one queued DeathLink. Lose deathlink_percent% of max health; percent <= 0 is
-- special and kills outright (ignoring Death Defiance). We mirror the game's own death path
-- (CombatLogic.lua:1392-1410): subtract Health directly (bypassing the invulnerability gate in
-- Damage(), so it still lands at Chaos gates / reward screens and through shields), then
-- DamageHero purely for the hurt flash + sound, then CheckLastStand (honors Death Defiance) and
-- finally Kill if no defiance remains. forcing_deathlink stops our own KillHero hook from echoing
-- this back out as a fresh DeathLink.
--
-- CRITICAL: the kill MUST run inside a real game thread. Kill()->KillPresentation()/KillHero()
-- (and DeathPresentation/StartDeathLoop underneath them) call wait(), which is coroutine.yield().
-- This function is driven from ReturnOfModding's render callback (reload.lua's add_always_draw_imgui)
-- -- NOT a game coroutine -- so a wait() there throws "attempt to yield across C-call boundary",
-- our pcall swallows it, and the death sequence aborts half-done: the hero is left dead-in-place
-- with the MapLoad input block never applied/removed and no Crossroads respawn -> the game locks up
-- (exactly the reported freeze; the log showed the death firing then the run tearing down to the
-- main menu). game.thread() schedules the body on the game's own scheduler, where wait() resolves
-- and the full death -> DeathPresentation -> respawn plays out normally.
function ItemManager.flush_pending_deathlink()
  if (ItemManager.pending_deathlinks or 0) <= 0 then return end
  if ItemManager.deathlink_in_progress then return end   -- a kill thread is still running
  if os.clock() < (ItemManager.deathlink_next_attempt_at or 0) then return end  -- retry cadence
  local can_apply, reason = deathlink_can_apply()
  if not can_apply then
    -- Hold the death until the state is ready. Logged (and re-checked only every
    -- DEATHLINK_RETRY_SECONDS, not every render frame) so a held DeathLink is visible in the
    -- log instead of silently doing nothing -- see reload.lua's call site for why that mattered.
    ItemManager.deathlink_next_attempt_at = os.clock() + DEATHLINK_RETRY_SECONDS
    rom.log.info("[AP] DeathLink held (" .. tostring(reason) .. ") -- retrying in "
      .. DEATHLINK_RETRY_SECONDS .. "s (pending=" .. tostring(ItemManager.pending_deathlinks) .. ")")
    return
  end
  ItemManager.pending_deathlinks = ItemManager.pending_deathlinks - 1
  ItemManager.deathlink_in_progress = true
  local percent = tonumber(ItemManager.settings and ItemManager.settings.deathlink_percent)
  if percent == nil then percent = 100 end
  -- FIFO alongside the counter (see reload.lua's DEATH handler) so a burst of queued
  -- DeathLinks still pairs each kill with the sender who actually caused it.
  local sources = ItemManager.pending_deathlink_sources
  local source = (sources and table.remove(sources, 1)) or "Archipelago"

  game.thread(function()
    -- forcing_deathlink must be set when KillHero is *entered* (its send-decision happens
    -- synchronously before the first wait), so setting it here inside the thread is enough.
    ItemManager.forcing_deathlink = true
    local ok, err = pcall(function()
      local hero = game.CurrentRun and game.CurrentRun.Hero
      if not hero or hero.IsDead then return end
      -- The vanilla death screen's own flavor line (e.g. "Time cannot be stopped.") comes from
      -- a VO subtitle system that can only show pre-registered, localized lines -- it can't
      -- render an arbitrary runtime string like a slot name. So instead of fighting that system,
      -- show who actually killed us with our own banner (Notifications already proves this works
      -- for dynamic text -- see the "Received: " / DeathLink-sent banners).
      if Notifications then pcall(function() Notifications.push("death", source .. " Killed You") end) end
      if percent <= 0 then
        game.Kill(hero, { Name = "Archipelago DeathLink", SourceName = source })
      else
        local maxh = hero.MaxHealth or 50
        local dmg = math.max(1, math.floor(maxh * percent / 100))
        local ta = { DamageAmount = dmg, Name = "Archipelago DeathLink", SourceName = source }
        hero.Health = (hero.Health or maxh) - dmg
        if hero.Health <= 0 then
          ta.OverkillAmount = -hero.Health
          hero.Health = 0
        end
        -- Hurt flash + sound: HeroDamagePresentation runs inside DamageHero. DamageHero does
        -- NOT itself subtract Health (we already did) -- it's the reaction/presentation only.
        pcall(function() game.DamageHero(hero, ta) end)
        if hero.Health <= 0 then
          if not game.CheckLastStand(hero, ta) then   -- Death Defiance? if none, force the death
            ta.Killed = true
            game.Kill(hero, ta)
          end
        end
        if game.FrameState then game.FrameState.RequestUpdateHealthUI = true end
      end
    end)
    ItemManager.forcing_deathlink = false
    ItemManager.deathlink_in_progress = false
    if not ok then
      rom.log.error("[AP] DeathLink apply error: " .. tostring(err))
    else
      rom.log.info("[AP] applied DeathLink from " .. tostring(source) .. " (" .. tostring(percent)
        .. "% max health; pending=" .. tostring(ItemManager.pending_deathlinks) .. ")")
    end
  end)
end

-- Returns true if it killed this frame, so the StartRoom hook can skip scoring/grants for the
-- doomed intro room (otherwise the first room counts as cleared and sends a check before she dies).
function ItemManager.kill_surface_intro()
  if not ItemManager.pending_surface_intro_kill then return false end
  if not (game.CurrentRun and game.CurrentRun.Hero) then return false end
  ItemManager.pending_surface_intro_kill = false   -- one-shot
  rom.log.info("[AP] surface-start intro: killing Melinoe to bounce to the Crossroads (no DeathLink)")
  ItemManager.forcing_deathlink = true             -- this death must NOT broadcast a DeathLink
  pcall(function() game.Kill(game.CurrentRun.Hero, { Name = "Archipelago Surface Start" }) end)
  ItemManager.forcing_deathlink = false
  return true
end

-- Nightmare counterpart to kill_surface_intro (see pending_nightmare_intro_kill). FALLBACK ONLY --
-- used when redirect_nightmare_intro_args couldn't arm. Kill Melinoe once at the forced Underworld
-- boot intro so the game's own first-death -> Crossroads flow takes over, and from the Crossroads
-- the player takes the (already-unlocked) Chaos Gate to begin their Nightmare run. Returns true if
-- it killed this frame, so the StartRoom hook can skip scoring/grants for the doomed intro room.
function ItemManager.kill_nightmare_intro()
  if not ItemManager.pending_nightmare_intro_kill then return false end
  if not (game.CurrentRun and game.CurrentRun.Hero) then return false end
  ItemManager.pending_nightmare_intro_kill = false   -- one-shot
  rom.log.info("[AP] nightmare-start intro: killing Melinoe to bounce to the Crossroads (no DeathLink)")
  ItemManager.forcing_deathlink = true               -- this death must NOT broadcast a DeathLink
  pcall(function() game.Kill(game.CurrentRun.Hero, { Name = "Archipelago Nightmare Start" }) end)
  ItemManager.forcing_deathlink = false
  return true
end

function ItemManager.apply_item(name)
  if WEAPON_ITEM_TO_ID[name] then
    unlock_weapon(name)
  elseif PER_ASPECT_ITEM[name] then
    -- Checked before the "^Progressive .+ Aspect$" pattern below: "Progressive <Weapon>
    -- Base Aspect" would otherwise mismatch into apply_progressive_aspect.
    local info = PER_ASPECT_ITEM[name]
    apply_per_aspect(info.weapon, info.id, info.is_base)
  elseif name == "Progressive Underworld" or name == "Progressive Surface"
      or name == "Progressive Nightmare" then
    apply_route_progress(name)
  elseif name == "Surface Access" then
    grant_surface_access()
  elseif name == "Surface Penalty Cure" then
    grant_penalty_cure()
  elseif name == "Nightmare Access" then
    ItemManager.grant_nightmare_access()
  elseif name == "Progressive Grasp" then
    grant_grasp()
  elseif name:match(" Vow Removal$") then
    apply_vow_removal((name:gsub(" Vow Removal$", "")))
  elseif name:match(" Arcana$") then
    -- Handles both "<Card> Arcana" and "Progressive <Card> Arcana" (same effect).
    apply_arcana((name:gsub("^Progressive ", ""):gsub(" Arcana$", "")))
  elseif name:match("^Progressive .+ Aspect$") then
    apply_progressive_aspect((name:match("^Progressive (.+) Aspect$")))
  elseif name == "Progressive Familiar" then
    apply_progressive_familiar()
  elseif name == "Progressive Keepsake" then
    apply_progressive_keepsake()
  elseif name:match("^Progressive ") and ItemManager.SHORT_TO_WEAPON_KIT[name:match("^Progressive (.+)$") or ""] then
    -- "Progressive <Weapon>" (unlocks weapon + its Aspects).
    apply_progressive_weapon(name:match("^Progressive (.+)$"))
  elseif ASPECT_ITEM_TO_ID[name] or ASPECT_BASE_ITEM_TO_ID[name] then
    unlock_aspect(name)
  elseif FAMILIAR_ITEM_TO_ID[name] then
    unlock_familiar(name)
  elseif GOD_KEEPSAKE_COMBINED[name] then
    unlock_god_keepsake_combined(name)
  elseif GOD_ITEM_TO_ID[name] then
    unlock_god(name)
  elseif SHOP_GOD_ITEM_TO_ID[name] then
    unlock_shop_god(name)
  elseif KEEPSAKE_ITEM_TO_ID[name] then
    unlock_keepsake(name)
  elseif HELPER_NPC_ITEM_TO_ID[name] then
    unlock_helper_npc(name)
  elseif COMBAT_HELPER_ITEM_TO_ID[name] then
    unlock_combat_helper(name)
  elseif name == "Progressive Start" then
    local s = APState.get()
    if s then
      s.progressive_start = (s.progressive_start or 0) + 1
      rom.log.info("[AP] Progressive Start received (now " .. s.progressive_start .. ")")
    end
  elseif name == "Rarity Increase" then
    local s = APState.get()
    if s then
      s.rarity_increase = (s.rarity_increase or 0) + 1
      rom.log.info("[AP] Rarity Increase received (now " .. s.rarity_increase .. ")")
      -- Refresh the live trait immediately so a mid-run pickup takes effect right away instead
      -- of sitting banked until the next StartNewRun (see Wishlist/Rarity Increase...).
      pcall(function() ItemManager.refresh_rarity_boost(s.rarity_increase) end)
    end
  elseif name == "Increased Odds of Major Finds" then
    local s = APState.get()
    if s then
      s.major_finds = (s.major_finds or 0) + 1
      rom.log.info("[AP] Increased Odds of Major Finds received (now " .. s.major_finds .. ")")
    end
  elseif name == "Increased Help Odds" then
    local s = APState.get()
    if s then
      s.help_odds = (s.help_odds or 0) + 1
      rom.log.info("[AP] Increased Help Odds received (now " .. s.help_odds .. ")")
    end
  elseif name == "Starting Arachne Armor" then
    local s = APState.get()
    if s then
      s.arachne_armor = (s.arachne_armor or 0) + 1
      rom.log.info("[AP] Starting Arachne Armor received (now " .. s.arachne_armor .. ")")
    end
  elseif name == "Starting Medea Curse" then
    local s = APState.get()
    if s then
      s.medea_gift = (s.medea_gift or 0) + 1
      rom.log.info("[AP] Starting Medea Curse received (now " .. s.medea_gift .. ")")
    end
  elseif name == "Starting Icarus Invention" then
    local s = APState.get()
    if s then
      s.icarus_gift = (s.icarus_gift or 0) + 1
      rom.log.info("[AP] Starting Icarus Invention received (now " .. s.icarus_gift .. ")")
    end
  elseif name == "Starting Circe Blessing" then
    local s = APState.get()
    if s then
      s.circe_gift = (s.circe_gift or 0) + 1
      rom.log.info("[AP] Starting Circe Blessing received (now " .. s.circe_gift .. ")")
    end
  elseif name == "Starting Dionysus Boon" then
    local s = APState.get()
    if s then
      s.dionysus_gift = (s.dionysus_gift or 0) + 1
      rom.log.info("[AP] Starting Dionysus Boon received (now " .. s.dionysus_gift .. ")")
    end
  elseif name == "Starting Artemis Boon" then
    local s = APState.get()
    if s then
      s.artemis_gift = (s.artemis_gift or 0) + 1
      rom.log.info("[AP] Starting Artemis Boon received (now " .. s.artemis_gift .. ")")
    end
  elseif name == "Starting Athena Boon" then
    local s = APState.get()
    if s then
      s.athena_gift = (s.athena_gift or 0) + 1
      rom.log.info("[AP] Starting Athena Boon received (now " .. s.athena_gift .. ")")
    end
  elseif name == "Starting Hades Boon" then
    local s = APState.get()
    if s then
      s.hades_gift = (s.hades_gift or 0) + 1
      rom.log.info("[AP] Starting Hades Boon received (now " .. s.hades_gift .. ")")
    end
  elseif name == "Daedalus Upgrade" then
    local s = APState.get()
    if s then
      s.daedalus_upgrade = (s.daedalus_upgrade or 0) + 1
      rom.log.info("[AP] Daedalus Upgrade received (now " .. s.daedalus_upgrade .. ")")
    end
  elseif name == "Progressive Boon Level" then
    local s = APState.get()
    if s then
      s.boon_level_bonus = (s.boon_level_bonus or 0) + 1
      rom.log.info("[AP] Progressive Boon Level received (now " .. s.boon_level_bonus .. ")")
      -- No refresh call needed here: nothing is cached. ItemManager.boon_level_start reads this
      -- counter fresh from the AddTraitToHero wrap (reload.lua) at the moment of every future
      -- boon pickup, so a mid-run receipt takes effect on the very next boon grant.
    end
  elseif name == "Progressive Zagreus Weaken" then
    local s = APState.get()
    if s then
      s.zagreus_weaken = (s.zagreus_weaken or 0) + 1
      rom.log.info("[AP] Progressive Zagreus Weaken received (now " .. s.zagreus_weaken .. ")")
      -- Refresh the live trait immediately if Zagreus is already active in his room
      -- (mirrors Rarity Increase's mid-run refresh).
      pcall(function() ItemManager.refresh_zagreus_empower(s.zagreus_weaken) end)
    end
  elseif name == "Starting Max Health" or name == "Starting Max Magick" or name == "Starting Gold" or name == "Starting Armor" then
    -- Granular run-start stat fillers; applied (scaled by their *_value) at StartNewRun.
    local s = APState.get()
    if s then
      local key = ({ ["Starting Max Health"] = "max_health_items", ["Starting Max Magick"] = "max_arcana_items",
                     ["Starting Gold"] = "gold_items", ["Starting Armor"] = "armor_items" })[name]
      s[key] = (s[key] or 0) + 1
      rom.log.info("[AP] " .. name .. " received (now " .. s[key] .. ")")
    end
  elseif name == "Stygian Wells" then
    grant_combined_incantation(combined_stygian_wells_ids(), "Stygian Wells")
  elseif name == "Lifespring/Fountain Rooms" then
    grant_combined_incantation(combined_lifespring_ids(), "Lifespring/Fountain Rooms")
  elseif name == "Desecrating Pools" then
    grant_combined_incantation(combined_desecrating_pools_ids(), "Desecrating Pools")
  elseif name == "Shrine of Hermes" then
    grant_combined_incantation(combined_shrine_of_hermes_ids(), "Shrine of Hermes")
  elseif name == "Troves" then
    grant_combined_incantation(combined_troves_ids(), "Troves")
  elseif name == "Keepsake Rack" then
    grant_combined_incantation(combined_keepsake_rack_ids(), "Keepsake Rack")
  elseif name == "Gold Urns" then
    grant_combined_incantation(combined_gold_urns_ids(), "Gold Urns")
  elseif INCANTATION_ITEM_TO_ID[name] then
    grant_incantation(name)
  elseif name == "Ashes" then
    grant_currency("Ashes", ItemManager.settings.ashes_pack_value)
  elseif name == "Psyche" then
    grant_currency("Psyche", ItemManager.settings.psyche_pack_value)
  elseif name == "Bones" then
    grant_currency("Bones", ItemManager.settings.bones_pack_value)
  elseif name == "Nectar" then
    grant_currency("Nectar", ItemManager.settings.nectar_pack_value)
  elseif name == "Moon Dust" then
    grant_currency("Moon Dust", ItemManager.settings.moon_dust_pack_value)
  else
    rom.log.warning("[AP] unknown item: " .. tostring(name))
    return false
  end
  return true
end

-- Debug: clear all AP-applied state so the next ITEMS list re-applies from scratch
-- (resets the processed count, Grasp, and re-locks the arcana we may have unlocked).
function ItemManager.reset_applied()
  local s = APState.get()
  if not s then rom.log.info("[AP] reset: no save loaded"); return end
  s.processed = 0
  s.grasp_count = 0
  s.vow_removals = {}
  s.route_progress = { Underworld = 0, Surface = 0, Nightmare = 0 }
  s.chronos_clears = 0
  s.typhon_clears = 0
  s.hades_clears = 0
  s.zagreus_clears = 0
  s.zagreus_weaken = 0
  s.nightmare_access_granted = nil
  s.weapons_cleared = { Underworld = {}, Surface = {}, Nightmare = {} }
  s.score = {
    Underworld = { points = 0, next_check = 1, last_depth = 0, room_high = 0, weapon_high = {} },
    Surface = { points = 0, next_check = 1, last_depth = 0, room_high = 0, weapon_high = {} },
    Nightmare = { points = 0, next_check = 1, last_depth = 0, room_high = 0, weapon_high = {} },
  }
  s.aspect_progress = {}
  s.per_aspect_progress = {}
  s.familiar_progress = 0
  s.keepsake_progress = 0
  s.familiar_ap_granted = {}
  s.unlocked_gods = {}
  s.keepsake_ap_granted = {}
  s.keepsake_check_sent = {}
  s.progressive_start = 0
  s.rarity_increase = 0
  s.major_finds = 0
  s.help_odds = 0
  s.arachne_armor = 0
  s.medea_gift = 0
  s.icarus_gift = 0
  s.circe_gift = 0
  s.dionysus_gift = 0
  s.artemis_gift = 0
  s.athena_gift = 0
  s.hades_gift = 0
  s.daedalus_upgrade = 0
  s.boon_level_bonus = 0
  s.max_health_items = 0
  s.max_arcana_items = 0
  s.gold_items = 0
  s.armor_items = 0
  s.enemy_killed = {}
  s.npc_met = {}
  s.combined_weapon = {}
  s.weapon_ap_unlocked = {}
  s.combined_rooms = { room_high = 0, weapon_high = {} }
  pcall(function()
    local state = game.GameState and game.GameState.MetaUpgradeState
    local data = game.MetaUpgradeCardData
    if state and data then
      for _, card_id in pairs(ARCANA_TITLE_TO_ID) do
        if state[card_id] then
          if not (data[card_id] and data[card_id].StartUnlocked) then
            state[card_id].Unlocked = false
          end
          state[card_id].Level = 1
        end
      end
    end
  end)
  -- Re-lock aspects / familiars / keepsakes granted by AP.
  pcall(function()
    local gs = game.GameState
    if gs then
      for _, internal in pairs(ASPECT_ITEM_TO_ID) do
        if gs.WorldUpgradesAdded then gs.WorldUpgradesAdded[internal] = nil end
        if gs.WeaponsUnlocked then
          gs.WeaponsUnlocked[internal] = nil
          for rank = 2, ASPECT_MAX_RANK do gs.WeaponsUnlocked[internal .. rank] = nil end
        end
      end
      -- The default Aspect of Melinoe stays unlocked (it's free), but clear the rank
      -- upgrades (<base>2..5) we granted via progressive/combine so it resets to rank 1.
      for _, base in pairs(ASPECT_BASE_BY_WEAPON) do
        if gs.WeaponsUnlocked then
          for rank = 2, ASPECT_MAX_RANK do gs.WeaponsUnlocked[base .. rank] = nil end
        end
      end
      for _, internal in ipairs(ItemManager.FAMILIAR_NAMES) do
        if gs.FamiliarsUnlocked then gs.FamiliarsUnlocked[internal] = nil end
      end
      if gs.FamiliarUpgrades then
        for _, b in pairs(FAMILIAR_BOND) do
          gs.FamiliarUpgrades[b.base] = nil
          for _, track in ipairs(b.tracks) do
            gs.FamiliarUpgrades[track] = nil
            gs.FamiliarUpgrades[track .. "2"] = nil
            gs.FamiliarUpgrades[track .. "3"] = nil
          end
        end
      end
      for _, trait in pairs(KEEPSAKE_ITEM_TO_ID) do
        if gs.GiftPresentation then gs.GiftPresentation[trait] = nil end
        if gs.NewKeepsakeItem then gs.NewKeepsakeItem[trait] = nil end
        if gs.KeepsakeChambers then gs.KeepsakeChambers[trait] = nil end
        local flag = KEEPSAKE_TRAIT_TO_OWNFLAG[trait]
        if flag and gs.TextLinesRecord then gs.TextLinesRecord[flag] = nil end
      end
    end
  end)
  ItemManager.apply_all_vows()  -- back to full configured vow levels
  rom.log.info("[AP] RESET applied-item state (processed=0, grasp=0, arcana/aspects/familiars/keepsakes re-locked, vows reset)")
end

-- Stashed ITEMS payload awaiting a safe frame to apply (set by reload.lua's ITEMS handler,
-- consumed by drain_pending_items). Persist across hot-reloads so a reload between receipt and
-- apply can't drop it; the client also resends the full list on reconnect as a backstop.
ItemManager.pending_items = ItemManager.pending_items or nil

-- True only when applying received items right now is safe: a save is loaded, we're not paused, and
-- no modal screen or scripted input block owns the game. Receiving runs live grants (the currency
-- presentation, the rarity-trait mutation) that collide with the UI if they fire mid-boon-selection
-- or mid-conversation -- the same failure the boon banner hit -- so we hold until control is normal.
-- Notifications.blocked() is the shared "conversation or boon screen up?" test the banner uses.
function ItemManager.receive_safe()
  if not game.GameState then return false end   -- no save loaded yet: hold the payload
  if game.SessionMapState and game.SessionMapState.IsPaused then return false end
  if Notifications and Notifications.blocked and Notifications.blocked() then return false end
  return true
end

-- Driven every render frame from reload.lua. Applies the stashed ITEMS payload (and the immediate
-- run-start filler reasserts) the first frame receive_safe() passes, then clears it. Holding the
-- WHOLE receipt -- not just the banner -- is what keeps any live grant from firing while a boon
-- screen / conversation / pause is active.
function ItemManager.drain_pending_items()
  local payload = ItemManager.pending_items
  if payload == nil then return end
  if not ItemManager.receive_safe() then return end   -- hold until control is normal
  ItemManager.pending_items = nil
  pcall(function() ItemManager.apply_full_list(payload) end)
  -- Apply the run-start fillers the moment the item counts are available, instead of only on the
  -- next room-entry/room-clear hook (those StartRoom/RestoreUnlockRoomExits wraps reassert too --
  -- this just makes it immediate). Formerly inline in reload.lua's ITEMS handler.
  pcall(function() ItemManager.reassert_stat_bonuses() end)
  pcall(function() ItemManager.apply_help_odds() end)
  pcall(function() ItemManager.apply_armor() end)
  pcall(function() ItemManager.grant_pending_daedalus() end)
  -- Starting Gold / NPC Gifts also land mid-run, but ONLY inside a real biome room: at the hub
  -- the CurrentRun is still the PREVIOUS run, so an instant grant there would double up with the
  -- next run's full run-start grant (both are ledgered per run on CurrentRun).
  pcall(function()
    if Routes and Routes.current and Routes.current() then
      ItemManager.apply_gold()
      ItemManager.apply_all_npc_gifts()
    end
  end)
end

-- Called for every ITEMS message (the full ordered received list). We apply only
-- the entries past our saved processed index, so resends are safe. Deferred until
-- a save profile is loaded (GameState exists), since grants modify the save; the
-- client resends the full list when we reconnect after a profile loads.
function ItemManager.apply_full_list(payload)
  local s = APState.get()
  if not s then
    rom.log.info("[AP] ITEMS ignored: no save profile loaded (GameState nil)")
    return
  end
  local list = {}
  for n in payload:gmatch("[^|]+") do list[#list + 1] = n end
  rom.log.info("[AP] ITEMS received: " .. #list .. " items, already-applied=" .. s.processed)
  local new_count = #list - s.processed
  -- A fresh save's first sync is the *starting state* (precollected start-inventory items
  -- like the Surface Penalty Cure, plus anything the multiworld already released), not
  -- live receipts - so apply them silently. Later batches (processed > 0) still banner.
  local initial_sync = (s.processed == 0)
  for i = s.processed + 1, #list do
    local name = list[i]:match("^%s*(.-)%s*$")  -- trim stray whitespace (robust to typos)
    local recognized = ItemManager.apply_item(name)
    -- Notify only for recognized, in-the-moment receipts (skip the initial sync, backlog
    -- catch-ups, and unknowns).
    if Notifications and recognized and not initial_sync and new_count <= 5 then
      Notifications.push("received", name)
    end
  end
  if #list > s.processed then
    s.processed = #list
  end
  -- Re-assert the vow levels (also sets them on first connect when none removed).
  ItemManager.apply_all_vows()
end
