---@diagnostic disable: lowercase-global
-- Traps.lua — trap items. Two kinds:
--   * Event traps happen exactly once: they are never "applied" on receipt, but queued in the
--     save and fired later from the render driver, on a frame where the player is in a run with
--     control (see Traps.update). Any number can wait; two of the same kind go one after the other.
--   * Counter traps are state, like the fillers they undo (Rarity Decrease, the Starting ... Loss
--     items) or a charge spent later (Onion Trap): receipt just raises a number in the save.
--
-- Save state (APState):
--   trap_high_water       -- the highest ITEMS index already taken in. The ITEMS list is replayed
--                            from index 1 by the RESET debug command (it zeroes `processed`), and
--                            without this every trap ever received would land again.
--   trap_queue            -- event traps waiting to fire, oldest first. Saved, so one received in
--                            the Crossroads or while the game was closed still lands on the next run.
--   trap_counts           -- counter traps received, by id.
--   trap_aspect_restore   -- the Aspect an Aspect Trap displaced, put back once the run is over.
--   trap_keepsake_restore -- the same for a Keepsake Trap.

Traps = Traps or {}

-- Item name -> trap id. Mirrors Python's Items.item_table_traps (tools/sync_check.py).
Traps.ITEMS = {
  ["Sheep Trap"] = "sheep",
  ["Chronos Trap"] = "chronos",
  ["Invisible Trap"] = "invisible",
  ["Pause Trap"] = "pause",
  ["Asphodel Trap"] = "asphodel",
  ["Aspect Trap"] = "aspect",
  ["Onion Trap"] = "onion",
  ["Keepsake Trap"] = "keepsake",
  ["Rarity Decrease"] = "rarity",
  ["Starting Max Health Loss"] = "health",
  ["Starting Armor Loss"] = "armor",
  ["Starting Mana Loss"] = "mana",
  ["Eagle Trap"] = "eagle",
  ["Typhon Trap"] = "typhon",
  ["Spawn Trap"] = "spawn",
  ["Shield Trap"] = "shield",
  ["Music Trap"] = "music",
  ["Boulder Trap"] = "boulder",
  ["Chaos Curse Trap"] = "curse",
}

-- The counter traps: no queue, no firing.
local COUNTERS = { onion = true, rarity = true, health = true, armor = true, mana = true }

-- What an event trap turns into when it can never fire on this run (Asphodel on a dive, Aspect
-- with one Aspect owned), so it doesn't sit in the queue for good.
local FALLBACK = "Chronos Trap"

-- A runaway guard, not pacing: traps stack, so a pile is expected.
local MAX_PENDING = 200
-- Seconds between one trap firing and the next.
local MIN_GAP_SECONDS = 1
-- How often the queue is looked at while anything is waiting.
local RETRY_SECONDS = 0.5
-- A fire thread that hasn't come back after this long was killed under us (a map load).
local FIRE_TIMEOUT_SECONDS = 10

-- Reset on every (re)load so a reload in the middle of a fire can't wedge it true.
Traps.firing = false
Traps.firing_since = nil
Traps.next_attempt_at = 0
Traps.last_fired_at = Traps.last_fired_at or nil
Traps.last_room = nil
-- The timed traps in effect right now, by trap id: { name, room, expires, undo }. A trap id in
-- here can't fire again until its entry ends, which is what makes two of a kind take turns.
-- Kept across a reload, since an undo still has to run.
Traps.active = Traps.active or {}
-- The room a Shield Trap is working in.
Traps.shield_room = nil
-- Counter traps changed since the Hero's stats were last brought in line.
Traps.stats_dirty = false

function Traps.is_trap(name)
  return Traps.ITEMS[name] ~= nil
end

local function counts(s)
  s.trap_counts = s.trap_counts or {}
  return s.trap_counts
end

local function add_counter(s, id)
  local c = counts(s)
  c[id] = (c[id] or 0) + 1
  Traps.stats_dirty = true
  return c[id]
end

-- How many of a counter trap have been received ("rarity", "health", "armor", "mana").
-- ItemManager subtracts these from the matching filler's count.
function Traps.stat_loss(id)
  local s = APState.get()
  return s and counts(s)[id] or 0
end

-- Spend one Onion Trap, if any is waiting. Called by the ChooseRoomReward wrap (reload.lua) for
-- a door that just rolled a Boon; true turns that door into an Onion.
function Traps.take_onion()
  local s = APState.get()
  if not s then return false end
  local c = counts(s)
  if (c.onion or 0) <= 0 then return false end
  c.onion = c.onion - 1
  rom.log.info("[AP] Onion Trap spent (" .. c.onion .. " left)")
  return true
end

-- Called from ItemManager.apply_full_list for each trap entry past `processed`. `index` is the
-- entry's position in the ITEMS list.
function Traps.receive(name, sender, index)
  local s = APState.get()
  if not s then return end
  if index <= s.trap_high_water then return end   -- taken in once already (RESET replay)
  s.trap_high_water = index
  local id = Traps.ITEMS[name]
  if COUNTERS[id] then
    rom.log.info("[AP] " .. name .. " received (now " .. add_counter(s, id) .. ")")
    return
  end
  if #s.trap_queue >= MAX_PENDING then
    rom.log.info("[AP] " .. name .. " dropped (" .. MAX_PENDING .. " traps already waiting)")
    return
  end
  table.insert(s.trap_queue, { name = name, sender = sender or "" })
  rom.log.info("[AP] " .. name .. " queued (" .. #s.trap_queue .. " waiting)")
end

-- Debug lines for a test-fired trap also go to the corner log, where the tester can see them.
local function debug_note(text)
  rom.log.info("[AP] " .. text)
  pcall(function() if Overlay and Overlay.push then Overlay.push(text, Overlay.COLOR.warning) end end)
end

-- The TRAP bridge message (Cheats tab, /trap, tools/fake_client.py): a named trap without an
-- item behind it. It skips the ledger and goes to the front of the queue; from there it is
-- treated like any other, and the corner log says what it is waiting for.
function Traps.debug_fire(name)
  local s = APState.get()
  if not s then return end
  local id = Traps.ITEMS[name]
  if not id then
    local known = {}
    for item in pairs(Traps.ITEMS) do known[#known + 1] = item end
    table.sort(known)
    debug_note("unknown trap '" .. tostring(name) .. "' (have: " .. table.concat(known, ", ") .. ")")
    return
  end
  if COUNTERS[id] then
    debug_note(name .. " test (now " .. add_counter(s, id) .. ")")
    return
  end
  table.insert(s.trap_queue, 1, { name = name, sender = "Test", debug = true })
  Traps.next_attempt_at = 0
  debug_note(name .. " test queued")
end

local restore_aspect, restore_keepsake   -- defined with their traps below

-- A save reused for a different seed (Bridge.verify_save): the old seed's ledger means nothing
-- against the new ITEMS list.
function Traps.wipe()
  local s = APState.get()
  if not s then return end
  pcall(restore_aspect, s)
  pcall(restore_keepsake, s)
  s.trap_high_water = 0
  s.trap_queue = {}
  s.trap_counts = {}
  Traps.stats_dirty = true
end

local function foes_alive()
  local required = game.RequiredKillEnemies
  return type(required) == "table" and next(required) ~= nil
end

local function morphed()
  local hero = game.CurrentRun.Hero
  if game.MapState and game.MapState.HostilePolymorph then return true end
  return hero.ActiveEffects ~= nil and hero.ActiveEffects["HecatePolymorphStun"] ~= nil
end

-- A timed trap takes effect: nothing of the same kind fires until it ends. `undo` (optional)
-- runs when the time is up, and also when the room ends first if `undo_on_room_change`.
local function begin(id, entry, seconds, undo, undo_on_room_change)
  Traps.active[id] = {
    name = entry.name,
    room = game.CurrentRun.CurrentRoom,
    expires = os.clock() + seconds,
    undo = undo,
    undo_on_room_change = undo_on_room_change,
  }
end

-- Chronos speaks from anywhere: the same two loads vanilla does before his death taunt
-- (RoomPresentation.lua, "Chronos Death Taunt"). His intercom lines are in one bank, his
-- boss-fight lines in the other.
local function load_chronos()
  game.LoadVoiceBanks({ "Intercom", "Chronos" }, nil, true)
  game.LoadPackages({ Names = "Chronos", IgnoreAssert = true })
end

-- A unit from another biome needs that biome's art package (UnitArtPackages.lua).
local function load_unit_art(unit)
  local packages = UnitArtPackages and UnitArtPackages[unit]
  if type(packages) == "table" and packages[1] then
    game.LoadPackages({ Names = { packages[1] }, IgnoreAssert = true })
  end
end

-- Each event trap: can_fire(entry) -> ok, reason, hopeless. `hopeless` means no later room of
-- this run can change the answer. fire(entry) runs on a game thread and must come back quickly:
-- anything long goes on a thread of its own, and anything to undo goes through begin().
-- "Combat" traps hold until there are foes alive, however many rooms that takes.

-- ---- Sheep Trap (combat) ------------------------------------------------------
-- The effect Hecate's Polymorph projectile carries. EffectData.HecatePolymorphStun's apply /
-- clear functions (EffectLogic.lua) do all of it: model swap, morph weapons, slow, Hecate's
-- line, and putting Melinoe back. They also pick sheep / pig / rat the way her cast does.
-- Not arena-only in vanilla either: the "Hex" elite affix fires the same effect in other biomes
-- (EliteHex, Enemy_General_Projectiles.sjson), and the property list below is that projectile's.
-- Leaving the room and dying both clear every effect on the Hero (LeaveRoom, KillHero), so
-- there is nothing of ours to undo.
local SHEEP_EFFECT = "HecatePolymorphStun"
local SHEEP_SECONDS = 8

local Sheep = {}

function Sheep.can_fire(entry)
  -- Boss arenas included (user ruling 10/9). Their own grabs set the same MapState flag, so
  -- one in progress holds the trap until it ends.
  if morphed() then return false, "already transformed" end
  if not foes_alive() then return false, "waiting for combat" end
  return true
end

function Sheep.fire(entry)
  local hero = game.CurrentRun.Hero
  game.ApplyEffect({
    Id = hero.ObjectId, DestinationId = hero.ObjectId, EffectName = SHEEP_EFFECT,
    DataProperties = {
      Duration = SHEEP_SECONDS,
      Type = "SPEED",
      Modifier = 1,
      DisableMove = false,
      DisableRotate = false,
      DisableAttack = false,
      Active = true,
      CanAffectInvulnerable = true,
    },
  })
  game.wait(0.2)
  if not (game.MapState and game.MapState.HostilePolymorph) then
    error(SHEEP_EFFECT .. " did not take hold")
  end
end

-- ---- Chronos Trap -------------------------------------------------------------
-- The Tartarus announcement: portrait overlay, time-slow sting and one of his intercom lines.
-- Same call and arguments as the encounter event that plays it there (EncounterData_Generated.lua,
-- "ChronosAlertVoiceLines"), without its music change. The line set picks for itself: Hypnos on
-- a dive, and after the true ending vanilla hands the same set to Hades, mirrored here.
local Chronos = {}

function Chronos.can_fire(entry)
  return true
end

function Chronos.fire(entry)
  load_chronos()
  local args = {
    LineHistoryName = "NPC_Chronos_01", SubtitleColor = game.Color.ChronosVoice,
    BlockColorGrade = true, OverlayAnim = "ChronosOverlay",
    VoiceLines = { GlobalVoiceLines = "ChronosAlertVoiceLines" },
    StartSound = "/SFX/TimeSlowStart", StartDelay = 0.1,
  }
  if game.GameState.ReachedTrueEnding and not game.CurrentRun.IsDreamRun then
    args.LineHistoryName = "NPC_LordHades_01"
    args.SubtitleColor = game.Color.HadesVoice
    args.OverlayAnim = "HadesOverlay"
    args.StartSound = "/SFX/SurvivalChallengeStart"
  end
  begin("chronos", entry, 6)   -- the portrait and line run about that long
  game.thread(game.HadesSpeakingPresentation, {}, args)
end

-- ---- Invisible Trap (combat) --------------------------------------------------
-- The game's flag-based fade (SetPlayerFade / ClearPlayerFade, EventPresentation.lua) under a
-- flag of our own: Melinoe can't be seen, and nothing else about her changes. Not the stealth
-- effect, which also makes foes lose her. Ends on a timer or with the room, whichever is first:
-- the fade flags live in MapState and the next room builds a fresh Hero object.
local INVISIBLE_FLAG = "AP_InvisibleTrap"
local INVISIBLE_SECONDS = 25

local Invisible = {}

function Invisible.can_fire(entry)
  if morphed() then return false, "transformed" end
  if not foes_alive() then return false, "waiting for combat" end
  return true
end

function Invisible.fire(entry)
  begin("invisible", entry, INVISIBLE_SECONDS, function() game.ClearPlayerFade(INVISIBLE_FLAG, 0.3) end)
  game.SetPlayerFade({ Flag = INVISIBLE_FLAG, Fraction = 0, Duration = 0.3 })
end

-- ---- Pause Trap ---------------------------------------------------------------
-- Vanilla only reacts to the player pausing during the Chronos fight; nothing in the scripts
-- opens the pause screen. So this is our own stop: the world held at a crawl with input
-- blocked, his time-stop colour and sting, and one of the lines he answers a pause with
-- (RoomEventData.PauseMenuTakeOverAutoUnpause). Released by the render driver on the real
-- clock, since nothing that waits on game time comes back while the world is held.
local PAUSE_FLAG = "AP_PauseTrap"
local PAUSE_SECONDS = 3.5

local Pause = {}

function Pause.can_fire(entry)
  return true
end

local function pause_release()
  pcall(function() game.RemoveSimSpeedChange(PAUSE_FLAG, { LerpTime = 0.3 }) end)
  pcall(function() game.AdjustColorGrading({ Name = "Off", Duration = 0.3 }) end)
  pcall(function() game.RemoveInputBlock({ Name = PAUSE_FLAG }) end)
end

function Pause.fire(entry)
  load_chronos()
  -- Registered before anything is held, so a step failing below still gets released.
  begin("pause", entry, PAUSE_SECONDS, pause_release, true)
  game.AddInputBlock({ Name = PAUSE_FLAG })
  -- The line starts before the world stops: its own lead-in waits on game time.
  game.thread(game.PlayVoiceLines, game.RoomEventData.PauseMenuTakeOverAutoUnpause.VoiceLines, false,
    { LineHistoryName = "NPC_Chronos_01", SubtitleColor = game.Color.ChronosVoice })
  game.wait(0.1)
  game.PlaySound({ Name = "/SFX/TimeSlowStart" })
  game.AdjustColorGrading({ Name = "ChronosTimeSlow", Duration = 0.05 })
  game.AddSimSpeedChange(PAUSE_FLAG, { Fraction = 0.01, LerpTime = 0 })
end

-- ---- Asphodel Trap ------------------------------------------------------------
-- The vanilla Anomaly: Chronos pulls Melinoe out of the next door into one Asphodel room, and
-- its exit drops her back where she was headed. Vanilla rolls it on Oceanus combat doors only
-- (RoomLogic.lua DoAnomalies + RunLogic.lua ChooseNextRoomData, AllowAnomalyReplacement). The
-- trap arms a flag on the run, and Traps.anomaly_swap (called from our ChooseNextRoomData wrap)
-- makes the same replacement on the next ordinary combat door of these biomes. Doors that are
-- already open when it arms are re-pointed on the spot. Ephyra and the Summit are left out:
-- their rooms hang off a hub and a climb, not a chain of doors.
local ASPHODEL_BIOMES = { F = true, G = true, H = true, I = true, O = true, P = true }
-- Encounters vanilla bars it after (AnomalyDoorRequirements names Oceanus' two).
local ASPHODEL_BLOCKED_ENCOUNTERS = { "^ArtemisCombat", "^NemesisRandomEvent" }
-- What a door's room already carries about the reward shown on it.
local DOOR_REWARD_FIELDS = {
  "ChosenRewardType", "RewardStoreName", "ForceLootName", "Reward", "RewardOverrides",
  "ForcedReward", "RewardPreviewOverride", "RewardPreviewIcon", "RewardBoostedAnimation",
  "BoonRaritiesOverride", "UseOptionalOverrides", "OptionalOverrides", "NoReward",
}

local Asphodel = {}

function Asphodel.can_fire(entry)
  local run = game.CurrentRun
  if run.IsDreamRun then return false, "not on a Dream Dive", true end
  if run.ModsNikkelMHadesBiomesIsModdedRun then return false, "not on a Nightmare run", true end
  if run.AP_AsphodelTrap then return false, "one is already armed" end
  if game.RoomSetData.Anomaly[run.CurrentRoom.Name] then return false, "already in Asphodel" end
  if not ASPHODEL_BIOMES[Routes.current_room_set() or ""] then return false, "not in this biome" end
  return true
end

-- Called with the room ChooseNextRoomData settled on for a door. Returns the Anomaly room to
-- use instead, or nil to leave the door alone.
function Traps.anomaly_swap(currentRun, args, result)
  if not (currentRun and currentRun.AP_AsphodelTrap) then return nil end
  if args and args.ForceNextRoomSet then return nil end   -- includes our own call below
  local room = currentRun.CurrentRoom
  if not room or game.RoomSetData.Anomaly[room.Name] then return nil end
  local biome = type(result.Name) == "string" and result.Name:match("^(%a)_Combat%d+$")
  if not (biome and ASPHODEL_BIOMES[biome]) then return nil end
  local encounter = room.Encounter and room.Encounter.Name or ""
  for _, pattern in ipairs(ASPHODEL_BLOCKED_ENCOUNTERS) do
    if encounter:match(pattern) then return nil end
  end
  local anomaly = game.ChooseNextRoomData(currentRun, { ForceNextRoomSet = "Anomaly" })
  if not (anomaly and game.RoomSetData.Anomaly[anomaly.Name]) then return nil end
  anomaly.PrevRoomExitFunctionName = "ExitToAnomalyPresentation"
  rom.log.info("[AP] Asphodel Trap: door to " .. tostring(result.Name) .. " now leads to " .. tostring(anomaly.Name))
  return anomaly
end

-- The room's exits were rolled before the trap armed: point each ordinary combat door at the
-- Anomaly now, the way DoUnlockRoomExits builds a door's room, keeping the reward it shows.
local function repoint_open_doors()
  local run = game.CurrentRun
  local swapped = 0
  for _, door in pairs(game.MapState.OfferedExitDoors or {}) do
    local old = door.Room
    local reward = old and old.ChosenRewardType
    if old and reward ~= "Devotion" and reward ~= "SpellDrop" then   -- the Anomaly's IneligibleRewards
      local ok, err = pcall(function()
        local anomaly = Traps.anomaly_swap(run, {}, old)
        if not anomaly then return end
        local new = game.CreateRoom(anomaly, {
          SkipChooseReward = true, SkipChooseEncounter = true, RoomOverrides = run.CurrentRoom.NextRoomOverrides,
        })
        for _, field in ipairs(DOOR_REWARD_FIELDS) do new[field] = old[field] end
        new.NeedsReward = false
        door.Room = new
        run.CurrentRoom.ExitDoorRooms[door.ObjectId] = new.Name
        swapped = swapped + 1
      end)
      if not ok then AP_log_error("[AP] Asphodel Trap: could not re-point an open door: " .. tostring(err)) end
    end
  end
  return swapped
end

function Asphodel.fire(entry)
  load_chronos()
  game.CurrentRun.AP_AsphodelTrap = true
  local swapped = repoint_open_doors()
  rom.log.info("[AP] Asphodel Trap armed (" .. swapped .. " open door(s) re-pointed)")
end

-- ---- Aspect Trap --------------------------------------------------------------
-- Same weapon, a different Aspect the player owns, for the rest of the run. The swap is the
-- Aspect screen's own (WeaponShopLogic.lua: UnequipWeaponUpgrade, set LastWeaponUpgradeName,
-- EquipWeaponUpgrade). Daedalus upgrades gate on GameState.LastWeaponUpgradeName, so any the
-- new Aspect doesn't allow are swapped for ones it does. Room checks read the same field, so
-- the rest of the run counts as the new Aspect. LastWeaponUpgradeName is the player's saved
-- Aspect choice: the one displaced is remembered in the save and put back in the Crossroads,
-- the way vanilla's Chaos Trials restore it (BountyLogic.lua StoredGameState).
local Aspect = {}

-- The Aspects the Aspect screen would list for this weapon (WeaponUpgradeLogic.lua), minus the
-- one equipped.
local function other_owned_aspects(weapon)
  local screen = game.ScreenData.WeaponUpgradeScreen
  local current = game.GameState.LastWeaponUpgradeName[weapon] or screen.FreeUnlocks[weapon]
  local out = {}
  for _, name in ipairs(screen.DisplayOrder[weapon] or {}) do
    if name ~= current and game.TraitData[name] and game.GameState.WeaponsUnlocked[name] then
      out[#out + 1] = name
    end
  end
  return out
end

function Aspect.can_fire(entry)
  if morphed() then return false, "transformed" end
  local weapon = game.GetEquippedWeapon()
  if not weapon then return false, "no weapon" end
  if #other_owned_aspects(weapon) == 0 then return false, "no other Aspect owned for this weapon", true end
  return true
end

-- Replace every Daedalus upgrade the Hero holds that the equipped Aspect no longer allows.
local function reroll_hammers()
  local hero = game.CurrentRun.Hero
  local pool = game.LootData.WeaponUpgrade.Traits
  local in_pool = {}
  for _, name in ipairs(pool) do in_pool[name] = true end
  local invalid = {}
  for _, trait in ipairs(hero.Traits) do
    local data = in_pool[trait.Name] and game.TraitData[trait.Name]
    if data and data.GameStateRequirements
        and not game.IsGameStateEligible(trait, data.GameStateRequirements) then
      invalid[#invalid + 1] = trait.Name
    end
  end
  -- grant_pending_daedalus re-adds any hammer on this list the Hero has lost.
  local granted = game.CurrentRun.AP_DaedalusGranted or {}
  for _, old in ipairs(invalid) do
    game.RemoveTrait(hero, old)
    local choices = {}
    for _, name in ipairs(pool) do
      if game.IsTraitEligible(game.TraitData[name]) and not game.HeroHasTrait(name) then
        choices[#choices + 1] = name
      end
    end
    local new = choices[math.random(math.max(#choices, 1))]
    if new then game.AddTraitToHero({ TraitName = new }) end
    for i = #granted, 1, -1 do
      if granted[i] == old then
        if new then granted[i] = new else table.remove(granted, i) end
      end
    end
    rom.log.info("[AP] Aspect Trap: Daedalus upgrade " .. old .. " -> " .. tostring(new))
  end
end

function Aspect.fire(entry)
  local s = APState.get()
  local weapon = game.GetEquippedWeapon()
  local choices = other_owned_aspects(weapon)
  local pick = choices[math.random(#choices)]
  local lwun = game.GameState.LastWeaponUpgradeName
  -- Only the first trap of a run records: a second one would save the first one's pick.
  if not s.trap_aspect_restore then
    s.trap_aspect_restore = { weapon = weapon, aspect = lwun[weapon] or false }
  end
  game.UnequipWeaponUpgrade()
  lwun[weapon] = pick
  game.EquipWeaponUpgrade(game.CurrentRun.Hero, {})
  rom.log.info("[AP] Aspect Trap: " .. weapon .. " -> " .. pick)
  reroll_hammers()
end

-- Put the displaced Aspect back. Called once the run is over (Crossroads) and on a seed wipe.
restore_aspect = function(s)
  local saved = s.trap_aspect_restore
  if not saved then return end
  s.trap_aspect_restore = nil
  local lwun = game.GameState and game.GameState.LastWeaponUpgradeName
  if not lwun then return end
  lwun[saved.weapon] = saved.aspect or nil
  rom.log.info("[AP] Aspect Trap: restored " .. saved.weapon .. " -> " .. tostring(saved.aspect or "none"))
  -- The Crossroads Hero was built with the trap's Aspect still selected.
  if game.CurrentHubRoom and game.CurrentRun and game.CurrentRun.Hero
      and game.GetEquippedWeapon() == saved.weapon then
    game.thread(function()
      pcall(function()
        game.UnequipWeaponUpgrade()
        game.EquipWeaponUpgrade(game.CurrentRun.Hero, { SkipUIUpdate = true, SkipQuestStatusCheck = true })
      end)
    end)
  end
end

-- ---- Keepsake Trap ------------------------------------------------------------
-- The equipped Keepsake is swapped for another one the player owns, until a rack replaces it or
-- the run ends. The swap is vanilla's own random-Keepsake rack from the Chaos Trials
-- (KeepsakeLogic.lua GiftRackEquipRandomKeepsake), without locking the rack or the old Keepsake.
-- GameState.LastAwardTrait is the player's saved choice, so it is restored like the Aspect is,
-- unless they have picked something else since.
local Keepsake = {}

local function other_owned_keepsakes()
  local s = APState.get()
  local sanity = ItemManager.setting_mode("keepsakesanity") ~= 0
  local current = game.GameState.LastAwardTrait
  local out = {}
  for _, name in ipairs(game.ScreenData.KeepsakeRack.ItemOrder or {}) do
    local data = name ~= current and game.GetKeepsakeData(name)
    if data and game.TraitData[name]
        and game.IsGameStateEligible(data.GiftLevelData, data.GiftLevelData.GameStateRequirements)
        and (not sanity or (s.keepsake_ap_granted and s.keepsake_ap_granted[name])) then
      out[#out + 1] = name
    end
  end
  return out
end

function Keepsake.can_fire(entry)
  if #other_owned_keepsakes() == 0 then return false, "no other Keepsake owned", true end
  return true
end

function Keepsake.fire(entry)
  local s = APState.get()
  local hero = game.CurrentRun.Hero
  local choices = other_owned_keepsakes()
  local pick = choices[math.random(#choices)]
  local previous = game.GameState.LastAwardTrait
  if not s.trap_keepsake_restore then
    s.trap_keepsake_restore = { original = previous or false }
  end
  s.trap_keepsake_restore.pick = pick
  if previous then game.UnequipKeepsake(hero, previous) end
  game.GameState.LastAwardTrait = pick
  game.EquipKeepsake(hero, pick, { FromLoot = true, AddToCache = true })
  game.thread(game.InCombatTextArgs, {
    TargetId = hero.ObjectId, Text = "KeepsakeRandomized", LuaKey = "TempTextData",
    LuaValue = { Name = pick }, Duration = 1.8,
  })
  game.PlaySound({ Name = "/SFX/Menu Sounds/ChaosBoonChange" })
  rom.log.info("[AP] Keepsake Trap: " .. tostring(previous) .. " -> " .. pick)
end

restore_keepsake = function(s)
  local saved = s.trap_keepsake_restore
  if not saved then return end
  s.trap_keepsake_restore = nil
  local gs = game.GameState
  if not gs or gs.LastAwardTrait ~= saved.pick then return end   -- the player chose since
  local hero = game.CurrentRun and game.CurrentRun.Hero
  local function apply()
    if hero then game.UnequipKeepsake(hero, saved.pick) end
    gs.LastAwardTrait = saved.original or nil
    if hero and saved.original then game.EquipKeepsake(hero, saved.original) end
  end
  if hero and game.CurrentHubRoom then
    game.thread(function() pcall(apply) end)
  else
    gs.LastAwardTrait = saved.original or nil
  end
  rom.log.info("[AP] Keepsake Trap: restored " .. tostring(saved.original or "none"))
end

-- ---- Eagle Trap (combat) ------------------------------------------------------
-- Prometheus' Eagle the way it drops into Olympus rooms (EventLogic.lua OlympusEagleSpawn): it
-- dives in, makes a few passes, and leaves by itself (EnemyAILogic.lua EagleAttackAndFlee). It
-- is not a required kill, so it never holds a room. Vanilla keeps it to outdoor rooms and trims
-- the encounter's foe cap to make space; neither is done here.
local EAGLE_SECONDS = 45

local Eagle = {}

function Eagle.can_fire(entry)
  if not foes_alive() then return false, "waiting for combat" end
  return true
end

function Eagle.fire(entry)
  load_unit_art("Eagle")
  begin("eagle", entry, EAGLE_SECONDS)
  local room = game.CurrentRun.CurrentRoom
  game.thread(function()
    game.thread(game.OlympusEaglePreSpawnPresentation)
    game.wait(2, game.RoomThreadName)
    local hero = game.CurrentRun.Hero
    local eagle = game.DeepCopyTable(game.EnemyData.Eagle)
    eagle.BlocksLootInteraction = false
    eagle.UseActivatePresentation = false
    eagle.AIOptions = { "EagleAttackAndFlee" }
    local point = game.SelectSpawnPoint(room, eagle,
      { SpawnNearId = hero.ObjectId, SpawnRadius = 900, SpawnRadiusMin = 300 }) or hero.ObjectId
    eagle.ObjectId = game.SpawnUnit({ Name = "Eagle", DestinationId = point, Group = "Standing" })
    game.SetupUnit(eagle)
    eagle.Encounter = room.Encounter
    game.OlympusEagleSpawnPresentation(eagle)
  end)
end

-- ---- Typhon Trap (combat) -----------------------------------------------------
-- One of the Summit's incursions: a tail impale, an arm slam or an arm flick out of the sky
-- (PresentationBiomeQ.lua TyphonIncursion*). Vanilla aims them at map points only Summit rooms
-- have; each takes a DestinationId instead, and gets Melinoe's position when it fires.
local TYPHON_INCURSIONS = {
  { fn = "TyphonIncursionTailImpale", unit = "TyphonTail_Incursion" },
  { fn = "TyphonIncursionArmSlam", unit = "TyphonArm_Incursion" },
  { fn = "TyphonIncursionArmFlick", unit = "TyphonArm_Incursion" },
}

local Typhon = {}

function Typhon.can_fire(entry)
  if not foes_alive() then return false, "waiting for combat" end
  return true
end

function Typhon.fire(entry)
  local pick = TYPHON_INCURSIONS[math.random(#TYPHON_INCURSIONS)]
  load_unit_art(pick.unit)
  begin("typhon", entry, 8)
  -- No CameraMotion: it zooms by the room's ZoomFraction, which not every room sets.
  game.thread(game[pick.fn], game.CurrentRun.CurrentRoom.Encounter,
    { DestinationId = game.CurrentRun.Hero.ObjectId })
  rom.log.info("[AP] Typhon Trap: " .. pick.fn)
end

-- ---- Spawn Trap (combat) ------------------------------------------------------
-- One more of every foe standing in the room, spawned the way the game's own debug spawner
-- does (Debug.lua DebugSpawnEnemy): a spawn point from the room, SpawnUnit, SetupUnit. Bosses
-- and unit groups are not copied.
--   Minibosses are copied (user ruling 10/9), except the ones built on the boss framework:
-- King Vermin, the Erymanthian Boar, Charybdis and its tentacles, Talos, and Typhon's Spawn,
-- Tail, Eye and Twins. Those are set pieces placed in their arena and woken by its encounter,
-- with a kill presentation that ends the fight, and a copy dropped on a spawn point gets none
-- of that. They all inherit EnemyData.BaseBossEnemy, the only place SkipAISetupOnActivate is
-- set (IsBoss can't tell them apart: each sets it back to false).
local SPAWN_MAX = 8

local Spawn = {}

local function spawnable_foes()
  local out = {}
  for _, enemy in pairs(game.RequiredKillEnemies or {}) do
    local data = type(enemy) == "table" and enemy.Name and game.EnemyData[enemy.Name]
    if data and not enemy.IsDead and not data.IsBoss and not enemy.IsBoss and not data.IsUnitGroup
        and not data.SkipAISetupOnActivate then
      out[#out + 1] = enemy.Name
    end
  end
  return out
end

function Spawn.can_fire(entry)
  if #spawnable_foes() == 0 then return false, "waiting for combat" end
  return true
end

function Spawn.fire(entry)
  local names = spawnable_foes()
  local room = game.CurrentRun.CurrentRoom
  begin("spawn", entry, 3)
  game.thread(function()
    for i = 1, math.min(#names, SPAWN_MAX) do
      local enemy = game.DeepCopyTable(game.EnemyData[names[i]])
      local point = game.SelectSpawnPoint(room, enemy, {}, { CycleSpawnPoints = true })
        or game.CurrentRun.Hero.ObjectId
      enemy.ObjectId = game.SpawnUnit({ Name = names[i], Group = "Standing", DestinationId = point })
      enemy.OccupyingSpawnPointId = point
      game.SetupUnit(enemy, game.CurrentRun, {})
      game.wait(0.1, game.RoomThreadName)
    end
  end)
  rom.log.info("[AP] Spawn Trap: " .. math.min(#names, SPAWN_MAX) .. " more foe(s)")
end

-- ---- Shield Trap --------------------------------------------------------------
-- The blue hit-shield pips (CombatLogic.lua AddEnemyHitShield: each one eats a hit). Arms the
-- run; in the next room entered, every foe gets SHIELD_HITS of them, including ones that spawn
-- later in that room. Two armed cover two rooms. Handed out from Traps.update.
local SHIELD_HITS = 5

local Shield = {}

function Shield.can_fire(entry)
  return true
end

function Shield.fire(entry)
  local run = game.CurrentRun
  run.AP_ShieldTrap = (run.AP_ShieldTrap or 0) + 1
  rom.log.info("[AP] Shield Trap armed for the next room (" .. run.AP_ShieldTrap .. " waiting)")
end

local function update_shields(room)
  if Traps.shield_room ~= room or not room then return end
  for id, enemy in pairs(game.RequiredKillEnemies or {}) do
    if type(enemy) == "table" and not enemy.AP_TrapShielded and not enemy.IsDead then
      enemy.AP_TrapShielded = true
      for _ = 1, SHIELD_HITS do pcall(game.AddEnemyHitShield, enemy) end
    end
  end
end

-- ---- Music Trap ---------------------------------------------------------------
-- One of Scylla and the Sirens' songs over the room, on the game's second music channel
-- (AudioLogic.lua SecretMusicPlayer, which pauses the biome's track). Stopped when the room
-- ends. Holds while a room is using that channel itself (minibosses, Chaos, the Anomaly).
local SCYLLA_SONGS = {
  "/Music/IrisMusicScylla1_MC", "/Music/IrisMusicScylla2_MC",
  "/Music/IrisMusicScylla3_MC", "/Music/IrisMusicScylla4_MC",
}
local MUSIC_SECONDS = 3600   -- the room ends it

local Music = {}

function Music.can_fire(entry)
  if game.AudioState.SecretMusicId ~= nil then return false, "the room has its own music" end
  return true
end

function Music.fire(entry)
  local song = SCYLLA_SONGS[math.random(#SCYLLA_SONGS)]
  begin("music", entry, MUSIC_SECONDS, function()
    if game.AudioState.SecretMusicName == song then
      game.StopSecretMusic(true)
      game.ResumeMusic()
    end
  end, true)
  game.SecretMusicPlayer(song, { ParamNames = { "Guitar", "Drums", "Bass", "Keys", "Vocals" } })
  rom.log.info("[AP] Music Trap: " .. song)
end

-- ---- Boulder Trap -------------------------------------------------------------
-- Polyphemus' boulders out of the sky, as in Ephyra (RoomLogic.lua PolyphemusBoulderManager).
-- Vanilla drops them on map points only Ephyra has; here each one is aimed at where Melinoe is
-- standing when its warning circle appears. Same warning, fuse and projectile.
local BOULDER_COUNT = 3
local BOULDER_FUSE = 3.0
local BOULDER_PROJECTILE = "PolyphemusBoulderSky"
local BOULDER_RETICLE = "PolyphemusBoulderWarningDecal"

local Boulder = {}

function Boulder.can_fire(entry)
  return true
end

function Boulder.fire(entry)
  game.LoadPackages({ Names = { "BiomeN" }, IgnoreAssert = true })
  game.LoadVoiceBanks({ "Polyphemus" }, nil, true)
  begin("boulder", entry, BOULDER_COUNT * (BOULDER_FUSE + 1.5))
  local room = game.CurrentRun.CurrentRoom
  game.thread(function()
    local hero = game.CurrentRun.Hero
    local thrower = game.DeepCopyTable(game.EnemyData.PolyphemusBoulders)
    thrower.ObjectId = game.SpawnUnit({ Name = "PolyphemusBoulders", Group = "Standing", DestinationId = hero.ObjectId })
    game.thread(game.SetupUnit, thrower, game.CurrentRun)
    -- The game clears these away with the encounter.
    if room.Encounter then
      room.Encounter.PassiveRoomWeapons = room.Encounter.PassiveRoomWeapons or {}
      table.insert(room.Encounter.PassiveRoomWeapons, thrower.ObjectId)
    end
    local radius = game.GetBaseDataValue({ Type = "Projectile", Name = BOULDER_PROJECTILE, Property = "DamageRadius" })
    for _ = 1, BOULDER_COUNT do
      if hero.IsDead then return end
      local target = game.SpawnObstacle({ Name = "BlankObstacle", DestinationId = hero.ObjectId, Group = "Scripting" })
      game.CreateAnimation({ Name = BOULDER_RETICLE, DestinationId = target, ScaleRadius = radius })
      game.thread(game.PolyphemusBoulderIncomingPresentation)
      game.wait(BOULDER_FUSE, game.RoomThreadName)
      game.CreateProjectileFromUnit({ Name = BOULDER_PROJECTILE, Id = thrower.ObjectId, DestinationId = target, FireFromTarget = true })
      game.StopAnimation({ Name = BOULDER_RETICLE, DestinationId = target })
      game.wait(1.5, game.RoomThreadName)
    end
  end)
end

-- ---- Chaos Curse Trap ---------------------------------------------------------
-- The curse half of a Chaos boon with no blessing behind it. Vanilla builds the pair by hanging
-- the blessing on the curse's OnExpire (UpgradeChoiceLogic.lua, "TransformingTrait"); added by
-- itself, the curse runs out after its 3-5 encounters (ChaosCurseRemainingEncounters) and is
-- simply gone. The pool is Chaos' own list (LootData.TrialUpgrade.TemporaryTraits), filtered the
-- way a Chaos offer is: eligible, and not one already held. Several different ones can run at once.
local Curse = {}

local function eligible_curses()
  local hero = game.CurrentRun.Hero
  local out = {}
  for _, name in ipairs(game.LootData.TrialUpgrade.TemporaryTraits or {}) do
    local data = game.TraitData[name]
    -- The health curse takes 20-29 max health: not from a Hero who has no more than that.
    local survivable = name ~= "ChaosHealthCurse" or (hero.MaxHealth or 0) > 40
    if data and survivable and not game.HeroHasTrait(name) and game.IsTraitEligible(data) then
      out[#out + 1] = name
    end
  end
  return out
end

function Curse.can_fire(entry)
  if #eligible_curses() == 0 then return false, "every curse is already in effect" end
  return true
end

function Curse.fire(entry)
  local choices = eligible_curses()
  local pick = choices[math.random(#choices)]
  game.LoadVoiceBanks({ "Chaos" }, nil, true)
  game.AddTraitToHero({ TraitName = pick })
  if not game.HeroHasTrait(pick) then error(pick .. " did not take hold") end
  rom.log.info("[AP] Chaos Curse Trap: " .. pick)
end

local DEFS = {
  curse = Curse,
  sheep = Sheep, chronos = Chronos, invisible = Invisible, pause = Pause,
  asphodel = Asphodel, aspect = Aspect, keepsake = Keepsake, eagle = Eagle, typhon = Typhon,
  spawn = Spawn, shield = Shield, music = Music, boulder = Boulder,
}

-- nil on a frame where firing a trap is safe: in a run, alive, in control, nothing else of
-- ours mid-flight. Otherwise what is in the way. Same test an incoming DeathLink uses, and a
-- DeathLink goes first.
local function gate_blocked()
  if ItemManager.pending_deathlink_source or ItemManager.deathlink_in_progress then return "DeathLink pending" end
  if Traps.active.pause then return "paused" end
  local state = ItemManager.deathlink_state()
  if state ~= "ready" then return state == "hub" and "waiting for a run" or "no control" end
  if game.ActiveScreens and next(game.ActiveScreens) ~= nil then return "a screen is open" end
  if not (Routes and Routes.current and Routes.current()) then return "not on a route" end
  if Traps.last_fired_at and os.clock() - Traps.last_fired_at < MIN_GAP_SECONDS then return "a trap just fired" end
  return nil
end

-- End each timed trap once its time is up or its room is gone. Undos run on a game thread.
local function update_active(room)
  for id, active in pairs(Traps.active) do
    local room_gone = room ~= active.room or game.CurrentHubRoom ~= nil
    if room_gone or os.clock() >= active.expires then
      Traps.active[id] = nil
      if active.undo and (not room_gone or active.undo_on_room_change) then
        game.thread(function()
          local ok, err = pcall(active.undo)
          if not ok then AP_log_error("[AP] " .. active.name .. " undo failed: " .. tostring(err)) end
        end)
      end
      rom.log.info("[AP] " .. active.name .. " ended")
    end
  end
end

-- Counter traps changed: bring the live Hero in line (the same calls the fillers they undo
-- make on receipt). Only in a run; the next run start applies them anyway.
local function update_stats()
  if not Traps.stats_dirty then return end
  if not (game.CurrentRun and game.CurrentRun.Hero) or game.CurrentHubRoom ~= nil then return end
  if ItemManager.deathlink_state() ~= "ready" then return end
  Traps.stats_dirty = false
  AP_try("Traps stats: reassert_stat_bonuses", ItemManager.reassert_stat_bonuses)
end

-- Driven every render frame from reload.lua. Fires at most one queued trap per pass, on a real
-- game thread: the render callback is not a coroutine, so anything that waits can't run here
-- (see ItemManager.flush_pending_deathlink).
function Traps.update()
  local s = APState.get()
  if not s then return end

  local run = game.CurrentRun
  local room = run and run.CurrentRoom
  update_active(room)
  if game.CurrentHubRoom ~= nil then
    if s.trap_aspect_restore then restore_aspect(s) end
    if s.trap_keepsake_restore then restore_keepsake(s) end
  end
  if room and run.AP_AsphodelTrap and game.RoomSetData.Anomaly[room.Name] then
    run.AP_AsphodelTrap = nil   -- arrived
  end

  if room ~= Traps.last_room then
    -- nil on the first frame after a (re)load: not a room change.
    if Traps.last_room ~= nil and room ~= nil and game.CurrentHubRoom == nil
        and (run.AP_ShieldTrap or 0) > 0 then
      run.AP_ShieldTrap = run.AP_ShieldTrap - 1
      Traps.shield_room = room
      rom.log.info("[AP] Shield Trap: this room's foes are shielded")
    end
    Traps.last_room = room
  end

  if Traps.firing then
    if os.clock() - (Traps.firing_since or 0) < FIRE_TIMEOUT_SECONDS then return end
    AP_log_error("[AP] trap fire thread never returned; releasing the queue")
    Traps.firing = false
    Traps.last_fired_at = os.clock()
  end

  if os.clock() < Traps.next_attempt_at then return end
  Traps.next_attempt_at = os.clock() + RETRY_SECONDS

  if game.CurrentHubRoom == nil then update_shields(room) end
  update_stats()
  if #s.trap_queue == 0 then return end

  local blocked = gate_blocked()
  -- The first trap in the queue that can fire now goes; one waiting for combat doesn't hold up
  -- the ones behind it.
  for i = 1, #s.trap_queue do
    local entry = s.trap_queue[i]
    local id = Traps.ITEMS[entry.name]
    local def = DEFS[id]
    if not def then
      table.remove(s.trap_queue, i)
      rom.log.warning("[AP] unknown trap dropped: " .. tostring(entry.name))
      return
    end
    local ok, reason, hopeless = false, blocked, false
    if not blocked then
      if Traps.active[id] then
        reason = "the last one is still going"
      else
        ok, reason, hopeless = def.can_fire(entry)
      end
    end
    if ok then
      -- Off the queue before it fires: a trap that errors is logged and gone, never retried.
      table.remove(s.trap_queue, i)
      Traps.firing = true
      Traps.firing_since = os.clock()
      game.thread(function()
        local fired, err = pcall(def.fire, entry)
        Traps.firing = false
        Traps.last_fired_at = os.clock()
        if fired then
          rom.log.info("[AP] " .. entry.name .. " fired (from " .. tostring(entry.sender) .. ")")
          if entry.debug then debug_note(entry.name .. " fired") end
        else
          AP_log_error("[AP] " .. entry.name .. " failed: " .. tostring(err))
        end
      end)
      return
    end
    if hopeless then
      if entry.debug then
        table.remove(s.trap_queue, i)
        debug_note(entry.name .. " can't fire on this run: " .. tostring(reason))
      else
        rom.log.info("[AP] " .. entry.name .. " can't fire (" .. tostring(reason) .. "); it becomes a " .. FALLBACK)
        entry.name = FALLBACK
      end
      return
    end
    if entry.debug and entry.note ~= reason then
      entry.note = reason
      debug_note(entry.name .. " held: " .. tostring(reason))
    end
  end
end
