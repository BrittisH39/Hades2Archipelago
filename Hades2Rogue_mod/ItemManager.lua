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
-- Inverse: weapon short-name -> kit id (for weapon_aspect_combine's "Progressive <Weapon>").
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
-- title -> weapon short-name. Used by weapon_aspect_combine's randomized-mode cascade below
-- (the first Aspect item you get for a weapon also unlocks it).
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
-- Jeweled Pom (Hades). Must match Python's KEEPSAKE_NO_LOCATION.
local KEEPSAKE_NO_LOCATION = {
  ["Time Piece"] = true, ["Calling Card"] = true, ["Jeweled Pom"] = true,
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
local INCANTATION_START_IDS = {
  "WorldUpgradeCardUpgradeSystem",     -- Consecration of Ashes
  "WorldUpgradeWeaponUpgradeSystem",   -- Aspects of Night and Darkness
  "WorldUpgradeMetaUpgradeSaveLayout", -- Spreading of Ashes
  "WorldUpgradeKeepsakeSaveFirst",     -- Favored of All Keepsakes
  "WorldUpgradeBoonList",              -- Insight into Offerings
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

-- At boot, load cached settings and apply ONLY the load-time-critical bits. GameState is nil at the
-- menu, so apply_initial_weapon/apply_first_run_route touch only static data (HeroData/RoomData);
-- the in-save SETTINGS handler re-applies everything authoritatively once connected. Never
-- overwrites a setting the live connection already delivered this session.
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
  rom.log.info("[AP] applying cached settings at boot (starting weapon + surface redirect)")
  pcall(function() ItemManager.apply_initial_weapon() end)
  pcall(function() ItemManager.apply_first_run_route() end)
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
function ItemManager.route_zone_unlocked(route, zone)
  if not route then return false end
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

-- True when a run-start door should be warded shut: lock_routes on AND that route's zone isn't
-- unlocked yet (same route_zone_unlocked gate as the room-score block and the StartRoom kill, so the
-- door, the kill, and the check-suppression all agree).
function ItemManager.run_door_locked(args)
  if not ItemManager.setting_on("lock_routes") then return false end
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

-- Make Alecto and Tisiphone eligible as the Tartarus boss from the very first run. Zagreus'
-- Journey ports Nightmare's slow rollout: A_Boss02 (Alecto) and A_Boss03 (Tisiphone) require 4
-- lifetime Megaera kills (its RoomDataTartarus.lua: RequiredKills = { Harpy = 4 }), and the
-- vanilla Hades room data it merges over contributes two more latent gates
-- (RequiredTextLinesPerMetaUpgradeLevel / RequiredFalseTextLinesThisRun). For AP the full
-- sister pool should be live immediately -- the Alecto/Tisiphone enemy checks shouldn't hide
-- behind 4 Megaera runs (the apworld logic already treats them as reachable whenever the
-- route is). Strips ONLY those rollout gates from both copies of the room data
-- (game.RoomData + game.RoomSetData.Tartarus, usually the same table refs), keeping the
-- mod's own IsTartarusBossRoomEligible function requirement intact (it handles forced-boss
-- bounties and Dream Run eligibility). Idempotent, and a silent no-op until the Zagreus'
-- Journey room data actually exists -- so callers can run it at boot AND per-room without harm.
function ItemManager.apply_nightmare_fury_unlock()
  if not ItemManager.nightmare_mod() then return end
  for _, room_name in ipairs({ "A_Boss02", "A_Boss03" }) do
    local copies = {}
    if game.RoomData then copies[#copies + 1] = game.RoomData[room_name] end
    if game.RoomSetData then
      local rsd = game.RoomSetData.Tartarus
      copies[#copies + 1] = rsd and rsd[room_name]
    end
    for _, room in ipairs(copies) do
      local reqs = room and room.GameStateRequirements
      if reqs and (reqs.RequiredKills ~= nil
          or reqs.RequiredTextLinesPerMetaUpgradeLevel ~= nil
          or reqs.RequiredFalseTextLinesThisRun ~= nil) then
        reqs.RequiredKills = nil
        reqs.RequiredTextLinesPerMetaUpgradeLevel = nil
        reqs.RequiredFalseTextLinesThisRun = nil
        rom.log.info("[AP] Nightmare: " .. room_name
          .. " fury rollout gate stripped (all three sisters boss-eligible from run 1)")
      end
    end
  end
end

-- HIGHEST-RISK, unverified in-game (see design plan): whether ModUtil.mod.Wrap (direct
-- value-wrap, not the Path-based wrap used everywhere else in this file since Path always
-- resolves from _G and the Zagreus' Journey mod's functions live on its own private table,
-- not as bare globals) can successfully wrap and reassign a function living on ANOTHER
-- mod's table. Installs the Chaos Gate lock: reuses the same "warded door" concept as
-- run_door_locked/block_run_door, gated on ItemManager.nightmare_run_locked() instead of the
-- vanilla route-offset mechanism (Nightmare has its own Access item, no offset).
function ItemManager.install_nightmare_gate_lock()
  local zj = ItemManager.nightmare_mod()
  if not (zj and zj.StartHadesRun) then
    rom.log.info("[AP] Nightmare: mod not present/valid -- Chaos Gate lock not installed")
    return
  end
  pcall(function()
    zj.StartHadesRun = modutil.mod.Wrap(zj.StartHadesRun, function(base, ...)
      if ItemManager.nightmare_run_locked() then
        pcall(function() ItemManager.block_nightmare_run() end)
        return
      end
      -- A new Nightmare run is actually starting -- clear the run-clear dedup guard so this
      -- run's eventual clear can be counted (see handle_nightmare_run_cleared).
      ItemManager.nightmare_run_clear_handled = false
      return base(...)
    end)
  end)
  rom.log.info("[AP] Nightmare: Chaos Gate lock installed")
end

-- Second, independent detection path for Nightmare's run-clear -- wraps the mod's own custom
-- run-clear function directly (see handle_nightmare_run_cleared for why both paths exist).
function ItemManager.install_nightmare_run_clear_hook()
  local zj = ItemManager.nightmare_mod()
  local fn_name = "ModsNikkelMHadesBiomesOpenRunClearScreen"
  if not (zj and zj[fn_name]) then
    rom.log.info("[AP] Nightmare: mod not present/valid -- custom run-clear hook not installed")
    return
  end
  pcall(function()
    zj[fn_name] = modutil.mod.Wrap(zj[fn_name], function(base, ...)
      pcall(function() ItemManager.handle_nightmare_run_cleared() end)
      return base(...)
    end)
  end)
  rom.log.info("[AP] Nightmare: custom run-clear hook installed")
end

-- Block the Chaos Gate run start when Nightmare isn't unlocked yet. Unlike block_run_door,
-- there's no vanilla "warded door" presentation for this gate (it's the third-party mod's
-- own obstacle, not a vanilla UseEscapeDoor door), so this just pushes our banner and logs --
-- the run simply doesn't start (StartHadesRun's wrap returns early, base() never runs).
function ItemManager.block_nightmare_run()
  if Notifications then pcall(function() Notifications.push("locked", "Route is Locked") end) end
  rom.log.info("[AP] Nightmare Chaos Gate: blocked (locked) - no run started")
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
-- unlock item, progressive/combine, per_aspect, and the randomized weapon_aspect_combine
-- cascade.
local function mark_weapon_unlocked(weapon_id)
  -- TODO(game): mark `weapon_id` unlocked/usable and refresh the hub. The unlock
  -- mechanism (GameState flag vs. an unlock function) must be confirmed in-game.
  pcall(function()
    if game.GameState and game.GameState.WeaponsUnlocked then
      game.GameState.WeaponsUnlocked[weapon_id] = true
    end
  end)
  local s = APState.get()
  if s then s.weapon_ap_unlocked[weapon_id] = true end
end

local function unlock_weapon(item_name)
  local weapon_id = WEAPON_ITEM_TO_ID[item_name]
  if not weapon_id then return end
  mark_weapon_unlocked(weapon_id)
  rom.log.info("[AP] unlock weapon: " .. weapon_id)
end

local function grant_grasp()
  -- Track how many Progressive Grasp we've received; GetMaxMetaUpgradeCost is
  -- wrapped (reload.lua) to return grasp_count * grasp_intervals when graspsanity
  -- is on, so we just bump the count here.
  local s = APState.get()
  if not s then return end
  s.grasp_count = (s.grasp_count or 0) + 1
  rom.log.info("[AP] grasp +1 (now " .. s.grasp_count .. ")")
end

-- Unlock or upgrade an arcana card. First application unlocks it (Level 1); each
-- subsequent one raises its Level toward the card's max (Progressive_Arcana mode).
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
      card.Level = 1
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
-- the same clear is a safe no-op -- reset when a new Nightmare run actually starts (see
-- install_nightmare_gate_lock).
function ItemManager.handle_nightmare_run_cleared()
  if ItemManager.nightmare_run_clear_handled then return end
  ItemManager.nightmare_run_clear_handled = true
  local weapon_id = game.GameState and game.GameState.PrimaryWeaponName or nil
  LocationManager.on_run_cleared("Nightmare", weapon_id)
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
function ItemManager.apply_incantation_starts()
  for _, internal in ipairs(INCANTATION_START_IDS) do
    force_world_upgrade(internal)
  end
  rom.log.info("[AP] incantation starts granted (" .. #INCANTATION_START_IDS .. ")")
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
  -- weapon_aspect_combine: the first of this weapon's 4 Aspect items (its Aspect of Melinoe or
  -- one of its 3 alternates) also unlocks the weapon itself -- only the Aspects actually received
  -- are usable, the rest stay locked until their own items arrive (Options.WeaponAspectCombine).
  if ItemManager.setting_on("weapon_aspect_combine") and ItemManager.setting_mode("aspectsanity") == 1 then
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

-- weapon_aspect_combine: "Progressive <Weapon>" fuses the weapon unlock and its Aspects.
-- The 1st copy unlocks the weapon kit AND all 3 of its non-default Aspects (rank 1); each
-- later copy raises those Aspects by one rank (like apply_progressive_aspect).
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
-- apply_progressive_weapon which ranks all 3 non-default Aspects together. With
-- weapon_aspect_combine on, the 1st copy of ANY of a weapon's 4 aspect items (its Base
-- Aspect or one of its 3 alternates) also unlocks that weapon; with it off, the weapon needs
-- its own standalone unlock item instead (Options.WeaponAspectCombine). Either way, each
-- later copy of THAT SAME aspect's item raises only that one aspect by a rank.
local function apply_per_aspect(weapon, internal, is_base)
  local kit = ItemManager.SHORT_TO_WEAPON_KIT[weapon]
  if not kit then return end
  local s = APState.get()
  if not s then return end
  s.per_aspect_progress[internal] = (s.per_aspect_progress[internal] or 0) + 1
  local n = s.per_aspect_progress[internal]
  local combine_on = ItemManager.setting_on("weapon_aspect_combine")
  if n == 1 then
    if combine_on then
      mark_weapon_unlocked(kit)
    end
    -- The default Aspect of Melinoe is inherent to owning the weapon; only alternates unlock.
    if not is_base then unlock_aspect_id(internal) end
  elseif n <= ASPECT_MAX_RANK then
    set_aspect_ranks({ internal }, n)
  end
  rom.log.info("[AP] per-aspect " .. weapon .. " " .. internal .. " -> rank "
    .. math.min(n, ASPECT_MAX_RANK) .. (n == 1 and combine_on and " (weapon unlocked)" or ""))
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
end

local function unlock_familiar(name)
  local internal = FAMILIAR_ITEM_TO_ID[name]
  if not internal then return end
  unlock_familiar_id(internal)
  rom.log.info("[AP] unlock familiar: " .. name .. " (" .. internal .. ")")
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
-- you're in their area instead of after several runs / story beats, and (3) all the gods that
-- are normally introduced gradually (Zeus/Hera/Ares/Hestia/Aphrodite/Hephaestus/Hermes/Selene)
-- are eligible to appear as boon/shop rewards from run 1 -- see "All gods available" below.
-- Athena is intentionally absent -- her intro has no story gate, so she's already available.
local HELPER_INTRO_KEYS = {
  "ArtemisCombatIntro", "HeraclesCombatIntro", "IcarusCombatIntro", "NemesisCombatIntro",
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

local function resolve_eligibility_tables()
  if ItemManager._elig_resolved then return true end
  local nrd = game.NamedRequirementsData
  local ed = game.EncounterData
  local hrd = game.HubRoomData
  local ld = game.LootData
  if not (nrd and ed and hrd and ld) then return false end
  local force = {}
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
  local godsForced = 0
  for _, name in ipairs(FORCE_GOD_UPGRADES) do
    local loot = ld[name]
    if loot and loot.GameStateRequirements then
      force[loot.GameStateRequirements] = true
      godsForced = godsForced + 1
    end
  end
  -- Cached separately (not added to `force` here): only forced true conditionally, when
  -- Zagreus is part of the goal and Vanilla is the chosen encounter mode. See
  -- eligibility_override below for why this is InfernalContractUnlocked specifically and not
  -- the outer StoreData.ZagreusContractRequirement.
  ItemManager._infernal_contract_req = nrd.InfernalContractUnlocked
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
  ItemManager._force_true_reqs = force
  local set = {}
  for _, key in ipairs(HELPER_INTRO_KEYS) do
    local e = ed[key]
    if e and e.GameStateRequirements then set[e.GameStateRequirements] = true end
  end
  for _, key in ipairs(PATCH_NAMED_REQUIREMENTS) do
    if nrd[key] then set[nrd[key]] = true end
  end
  ItemManager._helper_intro_reqs = set
  ItemManager._elig_resolved = true
  rom.log.info("[AP] eligibility overrides resolved (ShrineUnlocked="
    .. tostring(nrd.ShrineUnlocked ~= nil)
    .. ", ChaosUnlocked=" .. tostring(nrd.ChaosUnlocked ~= nil)
    .. ", QuestLogUnlocked=" .. tostring(nrd.QuestLogUnlocked ~= nil)
    .. ", QuestLog pedestal=" .. tostring(qlObj ~= nil)
    .. ", gods forced=" .. godsForced .. "/" .. #FORCE_GOD_UPGRADES
    .. ", helper/god-shop intros=" .. tostring(next(set) ~= nil) .. ")")
  return true
end

-- Classify a requirements table for the IsGameStateEligible wrap:
--   "true"  -> force eligible unconditionally (Oath/ShrineUnlocked, Chaos Gates/ChaosUnlocked,
--              Fated List pedestal + QuestLogUnlocked, and each force-unlocked god's own
--              LootData.GameStateRequirements -- see FORCE_GOD_UPGRADES)
--   "patch" -> evaluate normally but with the helper/god story-unlock gates temporarily
--              satisfied (helper NPC intros, and Hermes'/Selene's NamedRequirementsData
--              entries -- these keep their per-run pacing checks, unlike a full force-true)
--   nil     -> not ours; pass through untouched
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
  if ItemManager._helper_intro_reqs[requirements] then
    return "patch"
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
  -- Zagreus Vanilla mode: force ONLY the persistent "have reached the true ending once" gate
  -- (NamedRequirementsData.InfernalContractUnlocked) true, so the fight can appear from run 1.
  -- IMPORTANT: this must NOT force the outer StoreData.ZagreusContractRequirement true (that
  -- table also has a `PathFalse RoomCountCache.C_Boss01` clause -- "only offer if you haven't
  -- already cleared his boss room (C_Boss01) this run" -- and a ChanceToPlay=0.4 roll; forcing
  -- the whole table bypassed both, so Zagreus kept reappearing in every later shop even after
  -- being defeated once, instead of vanilla's "once per run, ~40% chance" pacing). Since
  -- IsGameStateEligible resolves `NamedRequirements = {"InfernalContractUnlocked"}` by
  -- recursing into itself (RequirementsLogic.lua:45), that recursive call is intercepted by
  -- this same wrap and returns true here, while the outer ZagreusContractRequirement check
  -- still runs through `base()` normally for its other clauses. Only active when Zagreus is
  -- actually part of the goal and Vanilla is the chosen encounter mode.
  if requirements == ItemManager._infernal_contract_req
     and ItemManager.goal_includes_zagreus() then
    local mode = ItemManager.zagreus_mode()
    if mode == ItemManager.ZAGREUS_MODE_VANILLA then
      return "true"
    end
    -- Final Challenge mode: Zagreus is only ever reached via the automatic
    -- Chronos/Typhon-clear redirect, never the normal secret-contract path (door in the
    -- world, or the shop pedestal offer -- both gated by this same NamedRequirement). If
    -- the player's real save has already naturally earned InfernalContractUnlocked (e.g.
    -- reached the true ending in a past playthrough before this seed), that would otherwise
    -- let Zagreus keep appearing the normal way alongside the Final Challenge redirect.
    -- Force this false so only the redirect can trigger him. Empowered mode is untouched --
    -- its whole point is "appears how it normally does", so it must keep reading the real
    -- game state here.
    if mode == ItemManager.ZAGREUS_MODE_FINAL_CHALLENGE then
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

-- Arachne Armor (single unlock): if you have the item, start each run with ONE random
-- Arachne armor (the 8 "Costume" traits in TraitData_Arachne). Stacks on top of Melinoe's
-- own silk armor if she has one (intended -- both bonuses apply; one costume shows visually).
-- VERIFY in-game (these traits may assume Arachne is freed).
local ARACHNE_COSTUMES = {
  "AgilityCostume", "CastDamageCostume", "ManaCostume", "VitalityCostume",
  "HighArmorCostume", "IncomeCostume", "SpellCostume", "EscalatingCostume",
}
function ItemManager.apply_arachne_armor()
  local s = APState.get()
  if not s or (s.arachne_armor or 0) <= 0 then return end  -- you don't have the item
  pcall(function()
    if not (game.CurrentRun and game.CurrentRun.Hero) then return end
    -- Once per run: the random pick is NOT idempotent, and this is now also called from the
    -- ITEMS hook (mid-run receipt applies immediately) -- the CurrentRun flag stops every
    -- later ITEMS sync from stacking another costume. Saved run state, so quit/rejoin of a
    -- post-grant run doesn't re-grant either.
    if game.CurrentRun.AP_ArachneGranted then return end
    local pick = ARACHNE_COSTUMES[math.random(#ARACHNE_COSTUMES)]
    game.AddTraitToHero({ TraitName = pick })
    game.CurrentRun.AP_ArachneGranted = true
    rom.log.info("[AP] Arachne armor: granted random " .. pick)
  end)
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
-- penalty cure is only granted here when start_with_surface_cure is on; when it's off the
-- cure is a real AP item (arrives via the normal item path) so we must NOT pre-grant it.
function ItemManager.apply_surface_start()
  if ItemManager.setting_on("surface_start") then
    grant_surface_access()
    if ItemManager.setting_on("start_with_surface_cure") then
      grant_penalty_cure()
    end
  end
end

function ItemManager.apply_nightmare_start()
  if ItemManager.setting_on("nightmare_start") then
    ItemManager.grant_nightmare_access()
  end
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

-- Steer the very first run onto the Surface for surface-only seeds (Surface active, Underworld
-- excluded). The hardcoded intro run is Underworld: StartNewGame forces StartingBiome="F" and the
-- engine picks the new-game map by the RoomData GameStart flag, which only F_Opening01 carries
-- (RoomLogic.lua:151). We additively flag the Surface opening room N_Opening01 as a game-start room
-- too. ADDITIVE on purpose -- we do NOT clear F_Opening01.GameStart, so if the engine instead
-- hardcodes the Underworld start the worst case is "no redirect" with saving still enabled (that
-- validation only disables saving when the LOADED room lacks GameStart). The StartNewRun wrap
-- corrects StartingBiome to "N" when the engine actually loads N_Opening01. UNVERIFIED in-game:
-- confirm a fresh surface-only save opens on the Surface (and that saving stays enabled).
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

function ItemManager.apply_first_run_route()
  if not ItemManager.first_run_should_be_surface() then
    return
  end
  pcall(function()
    local rd = game.RoomData
    if rd and rd.N_Opening01 then
      rd.N_Opening01.GameStart = true
      rd.N_Opening01.Starting = true
      rom.log.info("[AP] surface-only seed: flagged N_Opening01 as a game-start room "
        .. "(first run -> Surface)")
    else
      rom.log.warning("[AP] apply_first_run_route: RoomData.N_Opening01 not found")
    end
  end)
end

-- The engine ignores the N_Opening01 GameStart flag and always forces the brand-new-save intro run
-- into the Underworld (confirmed: FIRST RUN is always F_Opening01). We can't safely rebuild the run
-- or load the Crossroads directly (the hub entry needs the scripted death->hub transition). So for a
-- surface-start seed we let the intro run start, then instantly kill Melinoe -- which routes through
-- the game's OWN first-death -> Crossroads flow -- so she lands in the hub and takes the Surface door
-- from there. Set by the StartNewRun hook on the surface-start intro; fired once from StartRoom.
ItemManager.pending_surface_intro_kill = ItemManager.pending_surface_intro_kill or false

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
    -- weapon_aspect_combine: "Progressive <Weapon>" (unlocks weapon + its Aspects).
    apply_progressive_weapon(name:match("^Progressive (.+)$"))
  elseif ASPECT_ITEM_TO_ID[name] or ASPECT_BASE_ITEM_TO_ID[name] then
    unlock_aspect(name)
  elseif FAMILIAR_ITEM_TO_ID[name] then
    unlock_familiar(name)
  elseif KEEPSAKE_ITEM_TO_ID[name] then
    unlock_keepsake(name)
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
  elseif name == "Daedalus Upgrade" then
    local s = APState.get()
    if s then
      s.daedalus_upgrade = (s.daedalus_upgrade or 0) + 1
      rom.log.info("[AP] Daedalus Upgrade received (now " .. s.daedalus_upgrade .. ")")
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
  s.keepsake_ap_granted = {}
  s.keepsake_check_sent = {}
  s.progressive_start = 0
  s.rarity_increase = 0
  s.major_finds = 0
  s.help_odds = 0
  s.arachne_armor = 0
  s.daedalus_upgrade = 0
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
  -- Starting Gold / Arachne Armor also land mid-run, but ONLY inside a real biome room: at the hub
  -- the CurrentRun is still the PREVIOUS run, so an instant grant there would double up with the
  -- next run's full run-start grant (both are ledgered per run on CurrentRun).
  pcall(function()
    if Routes and Routes.current and Routes.current() then
      ItemManager.apply_gold()
      ItemManager.apply_arachne_armor()
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
