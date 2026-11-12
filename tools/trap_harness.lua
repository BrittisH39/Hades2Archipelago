-- Harness for the mod's Traps.lua (ledger, queue, firing gate, and each trap's own rules).
--
-- Loads the real APState.lua and Traps.lua against a stubbed game, then walks the cases that
-- can't be allowed to go wrong in play: a trap fires once and only once, never outside a run,
-- never on top of a DeathLink, two of a kind take turns, and everything a trap holds is let go.
-- The engine side (what the game's own functions really do) is not covered here; that needs
-- the game.
--
-- Usage: lua trap_harness.lua <Hades2Rogue_mod folder>

local MOD = assert(arg[1], "pass the path to the Hades2Rogue_mod folder")

local failures = 0
local function check(ok, what)
  if not ok then
    failures = failures + 1
    print("FAIL: " .. what)
  end
end

-- ---- stubs ----------------------------------------------------------------------------------
local now = 100
os.clock = function() return now end

local logged = {}
rom = { log = {
  info = function(m) logged[#logged + 1] = m end,
  warning = function(m) logged[#logged + 1] = "WARN " .. m end,
} }
local errors = {}
function AP_log_error(m) errors[#errors + 1] = m end
function AP_try(_, fn) local ok, err = pcall(fn) if not ok then errors[#errors + 1] = err end end

local calls = {}
local function record(name) return function(...) calls[#calls + 1] = { name, ... } end end
local function called(name)
  local n = 0
  for _, c in ipairs(calls) do if c[1] == name then n = n + 1 end end
  return n
end

local applied = {}
local effect_takes = true
game = {
  GameState = {},
  MapState = {},
  ActiveScreens = {},
  AudioState = {},
  RequiredKillEnemies = {},
  CurrentHubRoom = nil,
  CurrentRun = nil,
  RoomThreadName = "RoomThread",
  Color = { ChronosVoice = {}, HadesVoice = {} },
  RoomEventData = { PauseMenuTakeOverAutoUnpause = { VoiceLines = {} } },
  RoomSetData = { Anomaly = { B_Combat01 = {} } },
  EnemyData = {
    Eagle = { Name = "Eagle" }, PolyphemusBoulders = { Name = "PolyphemusBoulders" },
    Guard = { Name = "Guard" }, Brawler = { Name = "Brawler" }, Hecate = { Name = "Hecate", IsBoss = true },
    Treant = { Name = "Treant" }, Talos = { Name = "Talos", IsBoss = false, SkipAISetupOnActivate = true },
  },
  wait = function() end,
  thread = function(fn, ...) fn(...) end,
  ApplyEffect = function(args)
    applied[#applied + 1] = args
    if effect_takes then game.MapState.HostilePolymorph = true end
  end,
  DeepCopyTable = function(t) local c = {} for k, v in pairs(t) do c[k] = v end return c end,
  SelectSpawnPoint = function() return 55 end,
  SpawnObstacle = function() return 77 end,
  GetBaseDataValue = function() return 300 end,
}
local spawned = {}
game.SpawnUnit = function(args) spawned[#spawned + 1] = args.Name return 1000 + #spawned end
for _, name in ipairs({ "LoadVoiceBanks", "LoadPackages", "HadesSpeakingPresentation", "SetPlayerFade",
    "ClearPlayerFade", "AddInputBlock", "RemoveInputBlock", "PlayVoiceLines", "PlaySound",
    "AdjustColorGrading", "AddSimSpeedChange", "RemoveSimSpeedChange", "UnequipWeaponUpgrade",
    "EquipWeaponUpgrade", "SetupUnit", "OlympusEaglePreSpawnPresentation", "OlympusEagleSpawnPresentation",
    "TyphonIncursionTailImpale", "TyphonIncursionArmSlam", "TyphonIncursionArmFlick",
    "AddEnemyHitShield", "SecretMusicPlayer", "StopSecretMusic", "ResumeMusic", "CreateAnimation",
    "StopAnimation", "CreateProjectileFromUnit", "PolyphemusBoulderIncomingPresentation",
    "UnequipKeepsake", "EquipKeepsake", "InCombatTextArgs" }) do
  game[name] = record(name)
end

local deathlink = "ready"
local reasserts = 0
ItemManager = {
  deathlink_state = function() return deathlink end,
  setting_mode = function() return 0 end,
  reassert_stat_bonuses = function() reasserts = reasserts + 1 end,
}
local on_route, biome = true, "F"
Routes = {
  current = function() if on_route then return "Underworld", 1 end end,
  current_room_set = function() return biome end,
}
UnitArtPackages = { Eagle = { "BiomeP" } }

assert(loadfile(MOD .. "/APState.lua"))()
assert(loadfile(MOD .. "/Traps.lua"))()

local function new_room(encounter)
  game.MapState = {}
  game.CurrentRun.CurrentRoom = { Name = "F_Combat01", Encounter = encounter or { Name = "GeneratedF" },
    ExitDoorRooms = {} }
end

local function start_run()
  game.CurrentHubRoom = nil
  game.CurrentRun = { Hero = { ObjectId = 7, ActiveEffects = {}, Traits = {} } }
  new_room()
end

local function foes(list)
  game.RequiredKillEnemies = {}
  for i, name in ipairs(list or {}) do game.RequiredKillEnemies[i] = { Name = name } end
end

-- Let the retry timer and the gap between traps pass, then run one pass.
local function tick()
  now = now + 2
  Traps.update()
end

local s = APState.get()

local function fresh()
  Traps.wipe()
  Traps.active, Traps.last_fired_at, Traps.shield_room, Traps.stats_dirty = {}, nil, nil, false
  calls, applied, logged, errors, spawned = {}, {}, {}, {}, {}
  reasserts = 0
  deathlink, on_route, biome = "ready", true, "F"
  ItemManager.pending_deathlink_source = nil
  game.ActiveScreens, game.AudioState = {}, {}
  start_run()
  foes({})
  now = now + 100
end

-- ---- receipt: ledger, no cap ------------------------------------------------------------------
fresh()
check(Traps.is_trap("Sheep Trap") and Traps.is_trap("Rarity Decrease") and not Traps.is_trap("Nectar"), "is_trap")
Traps.receive("Sheep Trap", "Ana", 5)
check(#s.trap_queue == 1 and s.trap_high_water == 5, "first receipt queues and marks the index")
Traps.receive("Sheep Trap", "Ana", 5)
Traps.receive("Sheep Trap", "Ana", 3)
check(#s.trap_queue == 1, "a replayed index (RESET) must not queue again")
for i = 6, 15 do Traps.receive("Sheep Trap", "Ben", i) end
check(#s.trap_queue == 11, "traps stack: none are dropped")

-- ---- gate: nowhere but a run with control -----------------------------------------------------
fresh()
foes({ "Guard" })
Traps.receive("Sheep Trap", "Ana", 1)
game.CurrentHubRoom = { Name = "Hub_Main" }
deathlink = "hub"
tick()
check(#applied == 0 and #s.trap_queue == 1, "nothing fires in the Crossroads")
game.CurrentHubRoom = nil
deathlink = "blocked"
tick()
check(#applied == 0, "nothing fires while a screen / cutscene / pause holds the game")
deathlink = "ready"
ItemManager.pending_deathlink_source = "Cy"
tick()
check(#applied == 0, "a pending DeathLink goes first")
ItemManager.pending_deathlink_source = nil
game.ActiveScreens = { InventoryScreen = {} }
tick()
check(#applied == 0, "nothing fires under an open screen")
game.ActiveScreens = {}
on_route = false
tick()
check(#applied == 0, "nothing fires off-route (Chaos, Anomaly)")
on_route = true
tick()
check(#applied == 1 and #s.trap_queue == 0, "and then it fires")

-- ---- Sheep: holds for combat, however long; two take turns ------------------------------------
fresh()
Traps.receive("Sheep Trap", "Ana", 1)
Traps.receive("Sheep Trap", "Ana", 2)
for _ = 1, 6 do new_room() tick() end
check(#applied == 0 and #s.trap_queue == 2, "Sheep holds through rooms without foes")
foes({ "Guard" })
tick()
check(#applied == 1 and #s.trap_queue == 1, "Sheep fires once foes are up")
local a = applied[1] or {}
check(a.EffectName == "HecatePolymorphStun" and a.Id == 7 and a.DataProperties.Duration
  and a.DataProperties.CanAffectInvulnerable == true, "Sheep applies Hecate's effect to the Hero")
tick()
check(#applied == 1, "the second Sheep waits while she is still a sheep")
game.MapState.HostilePolymorph = nil
tick()
check(#applied == 2 and #s.trap_queue == 0, "and fires once she is back")
check(not Traps.firing and #errors == 0, "fires complete cleanly")

fresh()
new_room({ Name = "BossHecate01" })
foes({ "Hecate" })
Traps.receive("Sheep Trap", "Ana", 1)
tick()
check(#applied == 1, "Sheep fires in a boss arena")

fresh()
foes({ "Guard" })
effect_takes = false
Traps.receive("Sheep Trap", "Ana", 1)
tick()
check(#applied == 1 and #s.trap_queue == 0 and #errors == 1, "a failed fire is logged and gone")
tick()
check(#applied == 1, "a failed trap is never retried")
effect_takes = true

-- ---- order: one waiting for combat doesn't hold up the rest ------------------------------------
fresh()
Traps.receive("Sheep Trap", "Ana", 1)
Traps.receive("Chronos Trap", "Ana", 2)
tick()
check(called("HadesSpeakingPresentation") == 1 and #s.trap_queue == 1 and s.trap_queue[1].name == "Sheep Trap",
  "Chronos fires past a Sheep that is waiting for combat")

-- ---- test fire ---------------------------------------------------------------------------------
fresh()
Traps.receive("Chronos Trap", "Ana", 1)
Traps.debug_fire("Pause Trap")
check(s.trap_queue[1].name == "Pause Trap" and s.trap_high_water == 1, "a test fire goes first and leaves the ledger alone")
Traps.debug_fire("No Such Trap")
check(#s.trap_queue == 2, "an unknown name queues nothing")
fresh()
Traps.debug_fire("Sheep Trap")
tick()
check(#applied == 0 and #s.trap_queue == 1, "a test Sheep waits for combat like a real one")

-- ---- Chronos: two take turns -------------------------------------------------------------------
fresh()
Traps.receive("Chronos Trap", "Ana", 1)
Traps.receive("Chronos Trap", "Ana", 2)
tick()
tick()
check(called("HadesSpeakingPresentation") == 1, "the second Chronos waits for the first to finish")
now = now + 10
tick()
check(called("HadesSpeakingPresentation") == 2, "then plays")

-- ---- Invisible ---------------------------------------------------------------------------------
fresh()
foes({ "Guard" })
Traps.debug_fire("Invisible Trap")
tick()
check(called("SetPlayerFade") == 1 and Traps.active.invisible ~= nil, "Invisible fades the Hero")
Traps.debug_fire("Chronos Trap")
tick()
check(called("HadesSpeakingPresentation") == 1, "a different trap fires while Invisible is in effect")
now = now + 30
tick()
check(called("ClearPlayerFade") == 1 and Traps.active.invisible == nil, "Invisible ends on its timer")
fresh()
foes({ "Guard" })
Traps.debug_fire("Invisible Trap")
tick()
new_room()
tick()
check(called("ClearPlayerFade") == 0 and Traps.active.invisible == nil, "Invisible ends with the room")

-- ---- Pause: everything it holds is released, on the real clock; two take turns ------------------
fresh()
Traps.receive("Pause Trap", "Ana", 1)
Traps.receive("Pause Trap", "Ana", 2)
Traps.receive("Chronos Trap", "Ana", 3)
tick()
check(called("AddInputBlock") == 1 and called("AddSimSpeedChange") == 1, "Pause holds input and the world")
now = now + 1
Traps.next_attempt_at = 0
Traps.update()
check(called("RemoveInputBlock") == 0 and called("HadesSpeakingPresentation") == 0, "nothing else fires during a Pause")
now = now + 5
tick()
check(called("RemoveInputBlock") == 1 and called("RemoveSimSpeedChange") == 1, "Pause releases input and the world")
tick()
tick()
check(called("AddInputBlock") == 2, "the second Pause follows the first")
fresh()
game.AddSimSpeedChange = function() error("boom") end
Traps.debug_fire("Pause Trap")
tick()
now = now + 5
tick()
check(called("RemoveInputBlock") == 1, "a Pause that errors halfway still releases input")
game.AddSimSpeedChange = record("AddSimSpeedChange")

-- ---- Asphodel ----------------------------------------------------------------------------------
fresh()
local picked = {}
game.ChooseNextRoomData = function(run, args)
  picked[#picked + 1] = args
  return { Name = "B_Combat01" }
end
game.CreateRoom = function(data) return { Name = data.Name, PrevRoomExitFunctionName = data.PrevRoomExitFunctionName } end
check(Traps.anomaly_swap(game.CurrentRun, {}, { Name = "F_Combat03" }) == nil, "no swap while unarmed")
Traps.debug_fire("Asphodel Trap")
tick()
check(game.CurrentRun.AP_AsphodelTrap == true, "Asphodel arms the run")
local swapped = Traps.anomaly_swap(game.CurrentRun, {}, { Name = "F_Combat03" })
check(swapped and swapped.Name == "B_Combat01" and swapped.PrevRoomExitFunctionName == "ExitToAnomalyPresentation",
  "an armed run swaps a combat door for the Anomaly")
check(picked[1] and picked[1].ForceNextRoomSet == "Anomaly", "the Anomaly room comes from the game's own picker")
check(Traps.anomaly_swap(game.CurrentRun, {}, { Name = "F_Boss01" }) == nil, "boss doors are left alone")
check(Traps.anomaly_swap(game.CurrentRun, {}, { Name = "F_Shop01" }) == nil, "shop doors are left alone")
check(Traps.anomaly_swap(game.CurrentRun, {}, { Name = "N_Combat03" }) == nil, "Ephyra doors are left alone")
check(Traps.anomaly_swap(game.CurrentRun, { ForceNextRoomSet = "Anomaly" }, { Name = "F_Combat03" }) == nil,
  "the picker's own call is not swapped again")
Traps.receive("Asphodel Trap", "Ana", 1)
tick()
check(#s.trap_queue == 1, "a second Asphodel waits for the first")
game.CurrentRun.CurrentRoom = { Name = "B_Combat01", Encounter = {}, ExitDoorRooms = {} }
tick()
check(game.CurrentRun.AP_AsphodelTrap == nil, "arriving in the Anomaly disarms it")
new_room()
tick()
check(game.CurrentRun.AP_AsphodelTrap == true and #s.trap_queue == 0, "then the second arms")

-- Doors that were already open when it arms.
fresh()
game.MapState.OfferedExitDoors = {
  [1] = { ObjectId = 1, Room = { Name = "F_Combat07", ChosenRewardType = "Boon", ForceLootName = "ZeusUpgrade" } },
  [2] = { ObjectId = 2, Room = { Name = "F_Shop01", ChosenRewardType = "Shop" } },
  [3] = { ObjectId = 3, Room = { Name = "F_Combat09", ChosenRewardType = "Devotion" } },
}
Traps.debug_fire("Asphodel Trap")
tick()
local doors = game.MapState.OfferedExitDoors
check(doors[1].Room.Name == "B_Combat01" and doors[1].Room.ChosenRewardType == "Boon"
  and doors[1].Room.ForceLootName == "ZeusUpgrade" and game.CurrentRun.CurrentRoom.ExitDoorRooms[1] == "B_Combat01",
  "an open combat door is re-pointed and keeps its reward")
check(doors[2].Room.Name == "F_Shop01" and doors[3].Room.Name == "F_Combat09",
  "a shop door and a reward the Anomaly can't hold are left alone")

fresh()
new_room({ Name = "ArtemisCombatIntro" })
game.CurrentRun.AP_AsphodelTrap = true
check(Traps.anomaly_swap(game.CurrentRun, {}, { Name = "F_Combat03" }) == nil, "no swap out of an Artemis room")

fresh()
game.CurrentRun.IsDreamRun = true
Traps.receive("Asphodel Trap", "Ana", 1)
tick()
check(s.trap_queue[1] and s.trap_queue[1].name == "Chronos Trap", "an Asphodel Trap on a dive becomes the stand-in")
tick()
check(called("HadesSpeakingPresentation") == 1 and not game.CurrentRun.AP_AsphodelTrap, "and the stand-in fires")

-- ---- Aspect ------------------------------------------------------------------------------------
fresh()
game.GetEquippedWeapon = function() return "WeaponStaffSwing" end
game.ScreenData = {
  WeaponUpgradeScreen = {
    FreeUnlocks = { WeaponStaffSwing = "BaseStaffAspect" },
    DisplayOrder = { WeaponStaffSwing = { "BaseStaffAspect", "StaffClearCastAspect", "StaffSelfHitAspect" } },
  },
  KeepsakeRack = { ItemOrder = { "KeepsakeA", "KeepsakeB", "KeepsakeC" } },
}
game.TraitData = {
  BaseStaffAspect = {}, StaffClearCastAspect = {}, StaffSelfHitAspect = {},
  HammerA = { GameStateRequirements = { "base only" } }, HammerB = {}, HammerC = {},
  KeepsakeA = {}, KeepsakeB = {}, KeepsakeC = {},
}
game.GameState.WeaponsUnlocked = { BaseStaffAspect = true, StaffClearCastAspect = true }
game.GameState.LastWeaponUpgradeName = {}
game.LootData = { WeaponUpgrade = { Traits = { "HammerA", "HammerB", "HammerC" } } }
local keepsakes_owned = { KeepsakeA = true, KeepsakeB = true }
game.GetKeepsakeData = function(name) return { GiftLevelData = { Gift = name, GameStateRequirements = name } } end
game.IsGameStateEligible = function(source, requirements)
  if type(requirements) == "string" then return keepsakes_owned[requirements] == true end
  return game.GameState.LastWeaponUpgradeName.WeaponStaffSwing == nil
end
game.IsTraitEligible = function(data) return data ~= game.TraitData.HammerA end
game.HeroHasTrait = function(name)
  for _, t in ipairs(game.CurrentRun.Hero.Traits) do if t.Name == name then return true end end
  return false
end
game.RemoveTrait = function(hero, name)
  for i, t in ipairs(hero.Traits) do if t.Name == name then table.remove(hero.Traits, i) return end end
end
game.AddTraitToHero = function(args) table.insert(game.CurrentRun.Hero.Traits, { Name = args.TraitName }) end
game.CurrentRun.Hero.Traits = { { Name = "HammerA" }, { Name = "HammerB" } }
game.CurrentRun.AP_DaedalusGranted = { "HammerA" }
new_room({ Name = "BossHecate01" })
Traps.debug_fire("Aspect Trap")
tick()
check(game.GameState.LastWeaponUpgradeName.WeaponStaffSwing == "StaffClearCastAspect",
  "Aspect picks the other owned Aspect, boss arena or not")
check(called("UnequipWeaponUpgrade") == 1 and called("EquipWeaponUpgrade") == 1, "Aspect re-equips through the game")
check(not game.HeroHasTrait("HammerA") and game.HeroHasTrait("HammerB") and game.HeroHasTrait("HammerC"),
  "the hammer the new Aspect rules out is re-rolled, the other is kept")
check(game.CurrentRun.AP_DaedalusGranted[1] == "HammerC", "the granted-hammer ledger follows the re-roll")
check(s.trap_aspect_restore and s.trap_aspect_restore.aspect == false, "the displaced Aspect is remembered")
new_room()
tick()
check(game.GameState.LastWeaponUpgradeName.WeaponStaffSwing == "StaffClearCastAspect", "it lasts past the room")
game.CurrentHubRoom = { Name = "Hub_Main" }
tick()
check(game.GameState.LastWeaponUpgradeName.WeaponStaffSwing == nil and s.trap_aspect_restore == nil,
  "the displaced Aspect is back in the Crossroads")
fresh()
game.GameState.WeaponsUnlocked = { BaseStaffAspect = true }
Traps.receive("Aspect Trap", "Ana", 1)
tick()
check(s.trap_queue[1] and s.trap_queue[1].name == "Chronos Trap", "an Aspect Trap with one Aspect owned becomes the stand-in")

-- ---- Keepsake ----------------------------------------------------------------------------------
fresh()
game.GameState.LastAwardTrait = "KeepsakeA"
Traps.debug_fire("Keepsake Trap")
tick()
check(game.GameState.LastAwardTrait == "KeepsakeB", "Keepsake swaps to the other owned one, never an unowned one")
check(called("UnequipKeepsake") == 1 and called("EquipKeepsake") == 1, "through the game's own equip")
game.CurrentHubRoom = { Name = "Hub_Main" }
tick()
check(game.GameState.LastAwardTrait == "KeepsakeA" and s.trap_keepsake_restore == nil, "the old Keepsake is back in the Crossroads")
fresh()
game.GameState.LastAwardTrait = "KeepsakeA"
Traps.debug_fire("Keepsake Trap")
tick()
game.GameState.LastAwardTrait = "KeepsakeC"   -- the player used a rack
game.CurrentHubRoom = { Name = "Hub_Main" }
tick()
check(game.GameState.LastAwardTrait == "KeepsakeC", "a Keepsake the player chose since is not overwritten")
fresh()
keepsakes_owned = { KeepsakeA = true }
game.GameState.LastAwardTrait = "KeepsakeA"
Traps.receive("Keepsake Trap", "Ana", 1)
tick()
check(s.trap_queue[1] and s.trap_queue[1].name == "Chronos Trap", "a Keepsake Trap with one Keepsake owned becomes the stand-in")

-- ---- Eagle, Typhon, Spawn: combat only ---------------------------------------------------------
fresh()
Traps.receive("Eagle Trap", "Ana", 1)
Traps.receive("Typhon Trap", "Ana", 2)
Traps.receive("Spawn Trap", "Ana", 3)
tick() tick() tick()
check(#spawned == 0 and #s.trap_queue == 3, "Eagle, Typhon and Spawn hold for combat")
foes({ "Guard", "Guard", "Brawler", "Hecate" })
tick()
check(spawned[1] == "Eagle" and called("OlympusEagleSpawnPresentation") == 1, "the Eagle arrives")
tick()
check(called("TyphonIncursionTailImpale") + called("TyphonIncursionArmSlam") + called("TyphonIncursionArmFlick") == 1,
  "Typhon strikes once")
local strike
for _, c in ipairs(calls) do if c[1]:match("^TyphonIncursion") then strike = c end end
check(strike and strike[3] and strike[3].DestinationId == 7, "aimed at the Hero")
tick()
local copies = {}
for i = 2, #spawned do copies[spawned[i]] = (copies[spawned[i]] or 0) + 1 end
check(#spawned == 4 and copies.Guard == 2 and copies.Brawler == 1, "Spawn copies each foe, not the boss")

-- Minibosses are copied too, except the ones built on the boss framework (BaseBossEnemy).
fresh()
foes({ "Treant", "Talos" })
Traps.receive("Spawn Trap", "Ana", 1)
tick()
check(#spawned == 1 and spawned[1] == "Treant", "Spawn copies a miniboss, but not a boss-framework one")
fresh()
foes({ "Talos" })
Traps.receive("Spawn Trap", "Ana", 1)
tick() tick()
check(#spawned == 0 and #s.trap_queue == 1, "Spawn waits when only a boss-framework miniboss is standing")

-- ---- Shield: the next room, and foes that arrive later ----------------------------------------
fresh()
foes({ "Guard" })
Traps.receive("Shield Trap", "Ana", 1)
Traps.receive("Shield Trap", "Ana", 2)
tick() tick()
check(game.CurrentRun.AP_ShieldTrap == 2 and called("AddEnemyHitShield") == 0, "Shield arms, and leaves this room alone")
new_room()
foes({ "Guard", "Brawler" })
tick()
check(called("AddEnemyHitShield") == 10 and game.CurrentRun.AP_ShieldTrap == 1, "five shields on each foe of the next room")
game.RequiredKillEnemies[3] = { Name = "Guard" }
tick()
check(called("AddEnemyHitShield") == 15, "and on a foe that spawns later")
tick()
check(called("AddEnemyHitShield") == 15, "but only once each")
new_room()
foes({ "Guard" })
tick()
check(called("AddEnemyHitShield") == 20 and game.CurrentRun.AP_ShieldTrap == 0, "the second one covers the room after")
new_room()
foes({ "Guard" })
tick()
check(called("AddEnemyHitShield") == 20, "and then it is over")

-- ---- Music -------------------------------------------------------------------------------------
fresh()
game.AudioState.SecretMusicId = 9
Traps.receive("Music Trap", "Ana", 1)
tick()
check(called("SecretMusicPlayer") == 0, "Music holds while the room has its own")
game.AudioState.SecretMusicId = nil
tick()
check(called("SecretMusicPlayer") == 1, "then a song starts")
local song
for _, c in ipairs(calls) do if c[1] == "SecretMusicPlayer" then song = c[2] end end
game.AudioState.SecretMusicName = song
now = now + 200
tick()
check(called("StopSecretMusic") == 0, "and plays for as long as the room lasts")
new_room()
tick()
check(called("StopSecretMusic") == 1 and called("ResumeMusic") == 1, "and stops with the room")

-- ---- Boulder -----------------------------------------------------------------------------------
fresh()
Traps.receive("Boulder Trap", "Ana", 1)
tick()
check(called("CreateProjectileFromUnit") == 3 and spawned[1] == "PolyphemusBoulders", "three boulders are thrown")

-- ---- Chaos Curse -------------------------------------------------------------------------------
fresh()
game.LootData.TrialUpgrade = { TemporaryTraits = { "ChaosSpeedCurse", "ChaosHealthCurse", "ChaosDashCurse" } }
game.TraitData.ChaosSpeedCurse, game.TraitData.ChaosHealthCurse, game.TraitData.ChaosDashCurse = {}, {}, {}
game.IsTraitEligible = function(data) return data ~= game.TraitData.ChaosDashCurse end
game.CurrentRun.Hero.MaxHealth = 30
Traps.receive("Chaos Curse Trap", "Ana", 1)
Traps.receive("Chaos Curse Trap", "Ana", 2)
tick()
check(game.HeroHasTrait("ChaosSpeedCurse") and #game.CurrentRun.Hero.Traits == 1,
  "a curse is added: not an ineligible one, not the health curse on a low-health Hero")
tick()
check(#game.CurrentRun.Hero.Traits == 1 and #s.trap_queue == 1, "a second waits when every curse left is already held")
game.CurrentRun.Hero.MaxHealth = 100
tick()
check(game.HeroHasTrait("ChaosHealthCurse") and #s.trap_queue == 0, "and takes a different curse when one is free")

-- ---- counter traps -----------------------------------------------------------------------------
fresh()
Traps.receive("Starting Max Health Loss", "Ana", 1)
Traps.receive("Starting Max Health Loss", "Ana", 2)
Traps.receive("Starting Mana Loss", "Ana", 3)
Traps.receive("Starting Armor Loss", "Ana", 4)
Traps.receive("Rarity Decrease", "Ana", 5)
Traps.receive("Rarity Decrease", "Ana", 5)
check(#s.trap_queue == 0, "counter traps are never queued")
check(Traps.stat_loss("health") == 2 and Traps.stat_loss("mana") == 1 and Traps.stat_loss("armor") == 1
  and Traps.stat_loss("rarity") == 1, "they count up, once per index")
tick()
check(reasserts == 1, "and the Hero's stats are brought in line")
tick()
check(reasserts == 1, "once")

fresh()
check(Traps.take_onion() == false, "no Onion without a trap")
Traps.receive("Onion Trap", "Ana", 1)
Traps.debug_fire("Onion Trap")
check(Traps.take_onion() and Traps.take_onion() and not Traps.take_onion(), "Onion Traps stack and are spent one door at a time")

-- ---- seed change, reload -----------------------------------------------------------------------
fresh()
Traps.receive("Sheep Trap", "Ana", 10)
Traps.receive("Onion Trap", "Ana", 11)
Traps.wipe()
check(s.trap_high_water == 0 and #s.trap_queue == 0 and Traps.stat_loss("onion") == 0, "wipe clears ledger, queue and counters")
Traps.receive("Sheep Trap", "Ana", 1)
assert(loadfile(MOD .. "/Traps.lua"))()
check(#APState.get().trap_queue == 1 and not Traps.firing, "queue is in the save, not the module")
check(#errors == 0, "no trap errored: " .. tostring(errors[1]))

if failures == 0 then
  print("TRAP HARNESS: all clean")
else
  print("TRAP HARNESS: " .. failures .. " failure(s)")
  os.exit(1)
end
