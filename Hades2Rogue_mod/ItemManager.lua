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
-- Weapon short-name -> its DEFAULT "Aspect of Melinoe" id (the always-unlocked, free aspect
-- and first WeaponUpgradeData.DisplayOrder entry). These are NOT all "Base*": only Staff/Coat
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
local ASPECT_MAX_RANK = 5  -- rank 1 (base) + 4 upgrades (<aspect>2..<aspect>5)

-- Weapon-shop purchase names to block (so aspects come only from AP items). The
-- base unlock names are blocked whenever aspectsanity is on; the upgrade names
-- (<aspect>2..5) are blocked only in progressive mode. Exposed for reload.lua.
ItemManager.ASPECT_UNLOCK_NAMES = {}
ItemManager.ASPECT_UPGRADE_NAMES = {}
for _, internal in pairs(ASPECT_ITEM_TO_ID) do
  ItemManager.ASPECT_UNLOCK_NAMES[internal] = true
  for rank = 2, ASPECT_MAX_RANK do
    ItemManager.ASPECT_UPGRADE_NAMES[internal .. rank] = true
  end
end
-- The default Aspect of Melinoe stays UNLOCKED (never blocked), but in progressive mode its
-- rank also comes from AP, so block its shop upgrades (<base>2..5) like the other aspects.
for _, base in pairs(ASPECT_BASE_BY_WEAPON) do
  for rank = 2, ASPECT_MAX_RANK do
    ItemManager.ASPECT_UPGRADE_NAMES[base .. rank] = true
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
}
ItemManager.INCANTATION_ITEM_TO_ID = INCANTATION_ITEM_TO_ID

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

-- Interpret a toggle-style setting (sent as 0/1) as a boolean.
function ItemManager.setting_on(key)
  local v = ItemManager.settings[key]
  return v == "1" or v == "true" or v == "True"
end

-- Interpret a multi-choice setting (sent as 0/1/2) as a number (default 0).
function ItemManager.setting_mode(key)
  return tonumber(ItemManager.settings[key]) or 0
end

-- Whether a route (Underworld/Surface) is part of this seed. Excluded routes still exist
-- in-game, but we must not send their (non-existent) checks. Defaults to active if the
-- flag is missing (older seeds).
function ItemManager.route_active(route)
  local key = (route == "Surface") and "surface_active" or "underworld_active"
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
function ItemManager.combine_active()
  return ItemManager.settings.separate_checks == "1"
    and ItemManager.route_active("Underworld") and ItemManager.route_active("Surface")
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

-- point_based: how many score checks a route has. split_pools: the full
-- score_rewards_amount. combine_pools: the total split across the two routes, Underworld
-- taking the remainder (matches the Python active_routes [Underworld, Surface] order).
function ItemManager.score_limit_for(route)
  local total = tonumber(ItemManager.settings.score_rewards_amount) or 0
  if not ItemManager.combine_active() then return total end
  local half = math.floor(total / 2)
  if route == "Underworld" then return half + (total % 2) else return half end
end

-- point_based: the set of "<route> Score N" checks the server ALREADY has (a finished
-- player's auto-released/collected checks, an admin !send_location, fresh-save recovery).
-- The client re-pushes this via CHECKEDSCORE on every connect/HELLO and whenever
-- checked_locations changes (RoomUpdate), so it is deliberately RUNTIME-ONLY (NOT persisted
-- to the save). Earning one of these advances next_check for FREE (no score spent, no CHECK
-- re-sent). Keyed Route -> { [number] = true }.
ItemManager.checked_score = ItemManager.checked_score or { Underworld = {}, Surface = {} }

-- Is point_based score check `n` for `route` already checked on the server?
function ItemManager.is_score_checked(route, n)
  local set = ItemManager.checked_score[route]
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

local function unlock_weapon(item_name)
  local weapon_id = WEAPON_ITEM_TO_ID[item_name]
  if not weapon_id then return end
  -- TODO(game): mark `weapon_id` unlocked/usable and refresh the hub. The unlock
  -- mechanism (GameState flag vs. an unlock function) must be confirmed in-game.
  pcall(function()
    if game.GameState and game.GameState.WeaponsUnlocked then
      game.GameState.WeaponsUnlocked[weapon_id] = true
    end
  end)
  -- Remember that AP unlocked this kit, so apply_initial_weapon won't re-lock it on the next
  -- SETTINGS (the Staff is the only kit it force-locks; this keeps a Staff unlock from being
  -- clobbered after a restart -- Test Run 8 #4).
  local s = APState.get()
  if s then s.weapon_ap_unlocked[weapon_id] = true end
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
function ItemManager.apply_all_vows(quiet)
  if not ItemManager.setting_on("reverse_vow") then return end
  local s = APState.get()
  if not s then return end
  pcall(function()
    local gs = game.GameState
    if not gs then return end
    gs.ShrineUpgrades = gs.ShrineUpgrades or {}
    local parts = {}
    for vow, internal in pairs(VOW_NAME_TO_ID) do
      local configured = tonumber(ItemManager.settings["vow_" .. vow:lower()]) or 0
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
  -- Surface the gate too: if reverse_vow isn't on in the settings the mod sees, apply_all_vows
  -- below is a no-op and the removal silently does nothing -- log that explicitly.
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

local function apply_route_progress(name)
  local route = (name == "Progressive Surface") and "Surface" or "Underworld"
  local s = APState.get()
  if not s then return end
  s.route_progress[route] = (s.route_progress[route] or 0) + 1
  rom.log.info("[AP] route progress: " .. route .. " (x" .. s.route_progress[route] .. ")")
  -- Progressive Surface now OPENS the surface door, not just the locked zones (Test Run 5 #14,
  -- user choice "first one opens the door"). grant_surface_access is idempotent, so calling it
  -- on every Progressive Surface is harmless; the first receipt opens the door (the Python world
  -- no longer ships a separate "Surface Access" item when routes are locked). The Underworld is
  -- open by default, so Progressive Underworld only needs to bump the zone-unlock counter.
  if route == "Surface" then
    grant_surface_access()
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

local function unlock_aspect(title)
  local internal = ASPECT_ITEM_TO_ID[title]
  if not internal then return end
  unlock_aspect_id(internal)
  rom.log.info("[AP] unlock aspect: " .. title .. " (" .. internal .. ")")
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
    pcall(function()
      if game.GameState and game.GameState.WeaponsUnlocked then
        game.GameState.WeaponsUnlocked[kit] = true   -- unlock the weapon itself
      end
    end)
    s.weapon_ap_unlocked[kit] = true   -- so apply_initial_weapon won't re-lock it (Test Run 8 #4)
    -- The default Aspect of Melinoe is already unlocked; only the 3 non-default need unlocking.
    for _, internal in ipairs(ids) do unlock_aspect_id(internal) end
  elseif n <= ASPECT_MAX_RANK then
    set_aspect_ranks(ranked_aspect_ids(weapon), n)  -- ranks the default aspect too
  end
  rom.log.info("[AP] progressive " .. weapon .. " (weapon+aspect) -> step " .. n
    .. " (aspect rank " .. math.min(n, ASPECT_MAX_RANK) .. ")")
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
      gs.GiftPresentation = gs.GiftPresentation or {}
      gs.GiftPresentation[trait] = true
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
-- Two QoL unlocks driven entirely from the IsGameStateEligible wrap (reload.lua), so they
-- cost nothing until a requirement actually references the gated content and never touch the
-- save: (1) the Oath of the Unseen obelisk shows up in the Crossroads from the start, and
-- (2) the "helper" field-NPC encounters (Artemis/Heracles/Icarus/Nemesis) can show up the
-- first time you're in their area instead of after several runs / story beats.
-- Athena is intentionally absent -- her intro has no story gate, so she's already available.
local HELPER_INTRO_KEYS = {
  "ArtemisCombatIntro", "HeraclesCombatIntro", "IcarusCombatIntro", "NemesisCombatIntro",
}
-- The god first-pickup narrative flags Artemis's intro counts (needs >= 4 of these).
local HELPER_GOD_PICKUPS = {
  "PoseidonFirstPickUp", "DemeterFirstPickUp", "HestiaFirstPickUp",
  "AphroditeFirstPickUp", "ZeusFirstPickUp", "HephaestusFirstPickUp",
}

-- Lazily resolve (and cache) the exact game requirement TABLES we override, by identity.
-- Done on first use because the game's data tables (NamedRequirementsData / EncounterData)
-- are populated at boot, before any hub/encounter requirement is evaluated. _resolved stays
-- false until both tables exist so a too-early call simply passes through (no override yet).
ItemManager._elig_resolved = false
ItemManager._shrine_unlock_req = nil      -- NamedRequirementsData.ShrineUnlocked (the Oath gate)
ItemManager._helper_intro_reqs = nil      -- set: { [<intro>.GameStateRequirements] = true }

local function resolve_eligibility_tables()
  if ItemManager._elig_resolved then return true end
  local nrd = game.NamedRequirementsData
  local ed = game.EncounterData
  if not (nrd and ed) then return false end
  ItemManager._shrine_unlock_req = nrd.ShrineUnlocked or false
  local set = {}
  for _, key in ipairs(HELPER_INTRO_KEYS) do
    local e = ed[key]
    if e and e.GameStateRequirements then set[e.GameStateRequirements] = true end
  end
  ItemManager._helper_intro_reqs = set
  ItemManager._elig_resolved = true
  rom.log.info("[AP] eligibility overrides resolved (ShrineUnlocked="
    .. tostring(ItemManager._shrine_unlock_req ~= false)
    .. ", helper intros=" .. tostring(next(set) ~= nil) .. ")")
  return true
end

-- Classify a requirements table for the IsGameStateEligible wrap:
--   "true"  -> force eligible unconditionally (the Oath / ShrineUnlocked gate)
--   "patch" -> evaluate normally but with the helper story-unlock gates temporarily satisfied
--   nil     -> not ours; pass through untouched
-- Only acts once settings are present (an active AP session) so non-AP / menu play is untouched.
function ItemManager.eligibility_override(requirements)
  if requirements == nil then return nil end
  if not ItemManager.have_settings() then return nil end
  if not resolve_eligibility_tables() then return nil end
  if ItemManager._shrine_unlock_req and requirements == ItemManager._shrine_unlock_req then
    return "true"
  end
  if ItemManager._helper_intro_reqs[requirements] then
    return "patch"
  end
  return nil
end

-- Evaluate a helper-intro's requirements with ONLY its story-unlock gates temporarily
-- satisfied, leaving the per-run situational conditions (biome depth, NPC cooldown, active
-- bounty, health, etc.) intact so the helper still appears naturally "the first time you're
-- in the area" rather than spawning at depth 1 or back-to-back. Nothing is persisted: every
-- field is restored immediately after the base evaluation (even on error). The patched gates:
--   CompletedRunsCache >= 7        -> Artemis (>=1) and Nemesis (>=7) run-count gates
--   TextLinesRecord.<god>FirstPickUp -> Artemis's "met >= 4 gods" count
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
function ItemManager.apply_progressive_start()
  local s = APState.get()
  if not s then return end
  local function setting_val(key) return tonumber(ItemManager.settings[key]) or 0 end
  local hp_bonus     = (s.max_health_items or 0) * setting_val("starting_health_value")
  local gold_bonus   = (s.gold_items or 0)       * setting_val("starting_gold_value")
  local arcana_bonus = (s.max_arcana_items or 0) * setting_val("starting_magick_value")
  local rarity_count = s.rarity_increase or 0
  local major_finds_count = s.major_finds or 0
  -- Daedalus hammers are spawned from the StartRoom hook (grant_pending_daedalus) instead of
  -- here: at StartNewRun the first room's LootPoint objects don't exist yet, so GiveLoot only
  -- played the pickup sound and never placed a hammer (Test Run 5 #11). Reset the per-run record of
  -- which hammer traits we've granted so grant_pending_daedalus re-rolls + re-heals fresh this run.
  ItemManager._daedalus_granted = {}
  -- Starting Armor is a ONE-TIME grant at the start of the run (not every room). Clear the
  -- per-run flag so apply_armor grants it once in this run's first real room (Test Run 5 #2).
  ItemManager._armor_applied_run = false
  -- Reset the mod-maintained per-run "scored depth" so room depths restart at 1 each run
  -- (point_based points and room high-water marks persist across runs -- Test Run 6 #6).
  for _, route in ipairs({ "Underworld", "Surface" }) do
    if s.score and s.score[route] then s.score[route].depth_counter = 0 end
  end

  pcall(function()
    -- Starting Max Health + Max Magick: BOTH come from one arcana -- Persistence (the BonusHealth
    -- card), whose HealthManaBonusMetaUpgrade trait Adds to MaxHealth AND MaxMana via PropertyChanges
    -- (TraitData_MetaUpgrade.lua). ValidateMaxHealth / ValidateMaxMana (RoomLogic.lua) recompute the
    -- caps as HeroData.Max* (base) + the SUM of every hero trait's MaxHealth/MaxMana PropertyChange
    -- .ChangeValue. So the game-native, survives-everything way to raise the starting caps is to put
    -- ONE hero trait carrying those Adds on Melinoe, then revalidate. (The old approach -- bumping
    -- HeroData.MaxHealth and setting Hero.MaxMana directly -- was wiped the next time ValidateMax* ran
    -- or the opening-room hero rebuild happened, which is why neither ever stuck.) AddTraitToHero with
    -- an inline TraitData skips the BaseValue->ChangeValue processing, so we set ChangeValue directly.
    -- Built fresh each run; traits don't carry across runs, so a count of 0 = no trait (clean removal,
    -- no base bookkeeping needed).
    if (hp_bonus > 0 or arcana_bonus > 0) and game.AddTraitToHero
        and game.CurrentRun and game.CurrentRun.Hero then
      local changes = {}
      if hp_bonus > 0 then
        changes[#changes + 1] = { LuaProperty = "MaxHealth", ChangeValue = hp_bonus, ChangeType = "Add" }
      end
      if arcana_bonus > 0 then
        changes[#changes + 1] = { LuaProperty = "MaxMana", ChangeValue = arcana_bonus, ChangeType = "Add" }
      end
      pcall(function()
        game.AddTraitToHero({ TraitData = {
          Name = "ArchipelagoStatBonus",
          Hidden = true,                 -- no HUD icon / "new trait" highlight
          ExcludeFromRarityCount = true,
          PropertyChanges = changes,
        } })
      end)
      local hero = game.CurrentRun.Hero
      -- Recompute the caps so the trait's Adds take effect now (the game calls these on room loads;
      -- we call them immediately so the bonus is live in the opening room).
      pcall(function() if game.ValidateMaxHealth then game.ValidateMaxHealth() end end)
      pcall(function() if game.ValidateMaxMana then game.ValidateMaxMana() end end)
      -- Start the run topped off at the new caps and refresh the gauges (they cache their max --
      -- Test Run 5 #12: without a mana-meter rebuild the bigger pool isn't shown or usable).
      if hp_bonus > 0 then hero.Health = hero.MaxHealth end
      if arcana_bonus > 0 then hero.Mana = hero.MaxMana end
      pcall(function() if game.UpdateManaMeterUI then game.UpdateManaMeterUI() end end)
      pcall(function() if game.FrameState then game.FrameState.RequestUpdateHealthUI = true end end)
      rom.log.info("[AP] stat bonus trait: +" .. hp_bonus .. " MaxHealth +" .. arcana_bonus
        .. " MaxMana (health items=" .. (s.max_health_items or 0) .. " magick items="
        .. (s.max_arcana_items or 0) .. ") -> MaxHealth " .. tostring(hero.MaxHealth)
        .. " MaxMana " .. tostring(hero.MaxMana))
    end
    -- Starting Gold: Hades 2 has NO CurrentRun.Money -- run gold is GameState.Resources.Money. The
    -- game grants starting gold at the END of StartNewRun (RunLogic.lua) with
    --   AddResource("Money", CalculateStartingMoney(), "RunStart")
    -- where CalculateStartingMoney = GetTotalHeroTraitValue("BonusMoney") -- the Boatman arcana's
    -- StartingGoldMetaUpgrade trait. We run at that same point, so AddResource is the correct, proven
    -- path (it updates the money HUD itself); Silent skips the resource-gain VO/popup. The earlier
    -- CurrentRun.Money write (Test Run 9) targeted a field that does NOT exist in Hades 2, so it
    -- silently did nothing -- that's why gold never appeared.
    if gold_bonus > 0 and game.AddResource then
      pcall(function() game.AddResource("Money", gold_bonus, "RunStart", { Silent = true }) end)
    end
    -- Rarity Increase: boost boon-rarity chances across the whole power ladder -- Rare AND Epic AND
    -- Heroic, not just Rare. How the game rolls a boon's rarity (TraitLogic.SetTraitsOnLoot): it walks
    -- that boon's RarityRollOrder ascending (per-god, e.g. Athena = Common/Rare/Epic/Heroic, Artemis
    -- caps at Common/Rare/Epic) and keeps the HIGHEST tier whose chance passes RandomChance; a chance
    -- >= 1.0 always passes (RandomChance is `rng:Random() <= chance`). GetRarityChances (RoomLogic)
    -- builds those chances by summing each hero trait's RarityBonus.<Tier>Bonus (RareBonus/EpicBonus/
    -- HeroicBonus -- the "Bonus" suffix matters), so a single hidden trait carrying the summed bonus is
    -- all that's needed. Per item we add a per-tier increment; the tiers
    -- saturate at different rates (Rare fastest, Heroic slowest) for a natural ramp, and by ~100 items
    -- every tier is >= 1.0 so every boon rolls its max available rarity ("heroic that can be" -- a god
    -- that caps at Epic still maxes at Epic). Legendary/Duo are separate gated boons (not power tiers),
    -- so we deliberately don't touch them. One trait with the summed bonus (not rarity_count copies)
    -- keeps the add O(1) instead of O(n^2) UpdateHeroTraitDictionary rebuilds.
    if rarity_count > 0 and game.AddTraitToHero
        and game.CurrentRun and game.CurrentRun.Hero then
      local RARE_PER, EPIC_PER, HEROIC_PER = 0.05, 0.03, 0.015  -- per item; 100 items -> 5.0/3.0/1.5
      pcall(function()
        game.AddTraitToHero({ TraitData = {
          Name = "ArchipelagoRarityBoost",
          Hidden = true,                 -- no HUD icon / "new trait" highlight
          ExcludeFromRarityCount = true, -- don't skew GodBoonRarities bookkeeping
          -- Sub-keys MUST be named <Tier>Bonus: GetRarityChances reads each rarity trait's
          -- RarityBonus.RareBonus / .EpicBonus / .HeroicBonus (NOT .Rare/.Epic/.Heroic). Using
          -- the bare tier names makes the engine read nil and add zero, so every boon stays
          -- Common no matter how many items you stack.
          RarityBonus = {
            RareBonus   = rarity_count * RARE_PER,
            EpicBonus   = rarity_count * EPIC_PER,
            HeroicBonus = rarity_count * HEROIC_PER,
          },
        } })
      end)
    end
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
  rom.log.info(string.format(
    "[AP] run-start fillers: +%dHP +%dgold +%darcana rarity+%d majorfinds+%d (daedalus=%d spawned at StartRoom)",
    hp_bonus, gold_bonus, arcana_bonus, rarity_count, major_finds_count, s.daedalus_upgrade or 0))
end

-- Starting Armor filler: a ONE-TIME, PERMANENT armor grant at the start of the run -- it must
-- persist across rooms and only deplete when you take damage (Test Run 6 #10). The earlier
-- AddHealthBuffer approach keyed MapState.HealthBufferSources, which RoomLogic.MapStateInit wipes
-- on every room load, so the armor vanished the moment you entered the next room. The game's real
-- persistent-armor primitive is AddArmor (RoomLogic.lua:2772): it grants/extends the MinorArmorBoon
-- trait (CurrentArmor), a HERO TRAIT that carries across rooms and only goes down as damage eats it
-- -- exactly "armor is permanent, only lost by taking enough damage". Granted once per run, guarded
-- by a per-run flag (_armor_applied_run, reset at StartNewRun) in the run's first real biome room.
-- Bonus = armor_items * starting_armor_value; no-op when 0, already applied, or not in a run.
function ItemManager.apply_armor()
  local s = APState.get()
  if not s then return end
  if ItemManager._armor_applied_run then return end           -- already granted this run
  local armor_bonus = (s.armor_items or 0) * (tonumber(ItemManager.settings["starting_armor_value"]) or 0)
  if armor_bonus <= 0 then return end
  -- Needs only a live hero -- AddArmor (RoomLogic.lua) just grants the MinorArmorBoon trait; no
  -- biome room required. This now runs at StartNewRun too (reload.lua), so the armor is present in
  -- the opening room instead of a room late (Test Run 10 #3). The old Routes.current() gate forced
  -- it to wait for a mapped biome room, which is why it only appeared after the first room. The
  -- _armor_applied_run guard above keeps it to once per run across the StartNewRun + StartRoom calls.
  if not (game.CurrentRun and game.CurrentRun.Hero) then return end
  if not game.AddArmor then
    rom.log.warning("[AP] armor: game.AddArmor is nil -- cannot apply persistent armor")
    return
  end
  pcall(function()
    -- Delay 0 (no stagger), Silent so it doesn't play the armor-gain VO/flash on spawn.
    game.AddArmor(armor_bonus, { Delay = 0, Silent = true })
    -- The HUD armor pips cache their value; refresh so the bar shows the granted armor.
    pcall(function() if game.FrameState then game.FrameState.RequestUpdateHealthUI = true end end)
    ItemManager._armor_applied_run = true
    rom.log.info("[AP] starting armor granted (permanent, once this run): +" .. armor_bonus
      .. " (Hero.HealthBuffer=" .. tostring(game.CurrentRun.Hero.HealthBuffer) .. ")")
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
-- is now SELF-HEALING: we remember the exact hammer trait names we granted this run
-- (ItemManager._daedalus_granted, reset each StartNewRun in apply_progressive_start) and on EVERY room we
-- (1) re-apply any of those the hero no longer has (undoing a rebuild wipe) and (2) grant new ones until
-- we've granted `owned` of them. Each AddTraitToHero is followed by a HeroHasTrait readback we LOG, so the
-- log proves whether the trait actually stuck (vs. AddTraitToHero silently no-opping).
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
  -- Per-run record of the exact hammer trait names WE granted (reset at StartNewRun).
  ItemManager._daedalus_granted = ItemManager._daedalus_granted or {}
  local granted = ItemManager._daedalus_granted
  local function is_granted(name)
    for _, n in ipairs(granted) do if n == name then return true end end
    return false
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
    local pick = ARACHNE_COSTUMES[math.random(#ARACHNE_COSTUMES)]
    game.AddTraitToHero({ TraitName = pick })
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
  local locked = ItemManager._weapons_locked or {}
  rom.log.info("[AP] initial weapon: " .. kit
    .. (#locked > 0 and " (locked: " .. table.concat(locked, ", ") .. ")" or ""))
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
-- surface, lock_routes on). starting_route: 1=underworld, 2=surface, 3=both, 0=random.
-- NOTE: a RANDOM starting route that resolves to Surface isn't detectable here (slot_data carries the
-- raw 0, not the resolved value) -- if that case matters, add a resolved flag in Python generate_early.
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
  elseif name == "Progressive Underworld" or name == "Progressive Surface" then
    apply_route_progress(name)
  elseif name == "Surface Access" then
    grant_surface_access()
  elseif name == "Surface Penalty Cure" then
    grant_penalty_cure()
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
  elseif ASPECT_ITEM_TO_ID[name] then
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
  s.route_progress = { Underworld = 0, Surface = 0 }
  s.chronos_clears = 0
  s.typhon_clears = 0
  s.weapons_cleared = { Underworld = {}, Surface = {} }
  s.score = {
    Underworld = { points = 0, next_check = 1, last_depth = 0, room_high = 0, weapon_high = {} },
    Surface = { points = 0, next_check = 1, last_depth = 0, room_high = 0, weapon_high = {} },
  }
  s.aspect_progress = {}
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
