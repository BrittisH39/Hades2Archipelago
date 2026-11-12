-- Harness for the 0.11.0 group E fixes: keepsake levels, the GodSanity god-keepsake gate,
-- the Thanatos combat-helper gate, and the Patroclus nil-Victim guard.
--
-- Lifts the changed code out of ItemManager.lua / reload.lua and runs it against the installed
-- game's own functions (KeepsakeLogic.lua GetKeepsakeLevel / IsKeepsakeMaxed, RewardLogic.lua
-- SetupRoomReward) and zannc-SharedKeepsakePort's own PatroclusRetaliate.
--
-- Usage: lua keepsake_harness.lua <Hades2Rogue_mod dir> <zannc-SharedKeepsakePort dir>

local SCRIPTS = [[C:\Program Files (x86)\Steam\steamapps\common\Hades II\Content\Scripts\]]
local MOD_DIR = assert(arg[1], "pass the Hades2Rogue_mod directory")
local SKP_DIR = assert(arg[2], "pass the zannc-SharedKeepsakePort plugin directory")

local function read(path)
  local f = assert(io.open(path, "rb"), path)
  local src = f:read("a"); f:close()
  return (src:gsub("^\239\187\191", ""))
end

-- Text from the line holding `first` up to (not including) the line holding `stop`.
local function slice(src, first, stop)
  local a = assert(src:find(first, 1, true), "not found: " .. first)
  a = src:sub(1, a):match(".*\n()") or 1
  local b = assert(src:find(stop, a + #first, true), "not found: " .. stop)
  return src:sub(a, b - 1)
end

-- A whole top-level `function NAME(...) ... end` block.
local function func_block(src, name)
  src = "\n" .. src
  local a = assert(src:find("\nfunction " .. name .. "%s*%("), "no function " .. name)
  local b = assert(src:find("\nend\r?\n", a + 1), "no end for " .. name)
  return src:sub(a + 1, b + 4)
end

local function run(chunk, name, env)
  setmetatable(env, { __index = _G })
  local f = assert(load(chunk, "@" .. name, "t", env))
  f()
  return env
end

local failures, passes = 0, 0
local function check(cond, msg)
  if cond then passes = passes + 1 else failures = failures + 1 end
  print((cond and "PASS  " or "FAIL  ") .. msg)
end

local IM = read(MOD_DIR .. [[\ItemManager.lua]])
local RL = read(MOD_DIR .. [[\reload.lua]])

-- ---- 1. keepsake levels -----------------------------------------------------
do
  local env = {
    TraitData = {
      VanillaKeepsake = { ChamberThresholds = { 25, 50 } },
      ["zannc-SharedKeepsakePort-DirectionalArmorKeepsake"] = { ChamberThresholds = { 25, 50 } },
    },
    GameState = { KeepsakeChambers = {} },
    SessionState = {},
    HasHeroTraitValue = function() return false end,
    HeroHasTrait = function() return false end,
    GetHeroTrait = function() return nil end,
  }
  run(func_block(read(SCRIPTS .. "KeepsakeLogic.lua"), "GetKeepsakeLevel")
    .. func_block(read(SCRIPTS .. "KeepsakeLogic.lua"), "IsKeepsakeMaxed"), "KeepsakeLogic.lua", env)
  local mod = run(slice(IM, "local DEFAULT_KEEPSAKE_THRESHOLDS", "local function apply_progressive_keepsake")
    .. "\nreturn_fn = keepsake_step_chambers", "ItemManager.lua", { game = env })
  local step = mod.return_fn
  check(step("NotYetRegistered", 2) == 25 and step("NotYetRegistered", 3) == 75,
    "trait missing from TraitData falls back to { 25, 50 } -> 25 / 75")
  for _, trait in ipairs({ "VanillaKeepsake", "zannc-SharedKeepsakePort-DirectionalArmorKeepsake" }) do
    for n, want in ipairs({ 1, 2, 3 }) do
      env.GameState.KeepsakeChambers[trait] = step(trait, n)
      check(env.GetKeepsakeLevel(trait, true) == want,
        ("%s step %d -> %d chambers -> rank %d (want %d)"):format(trait, n, step(trait, n),
          env.GetKeepsakeLevel(trait, true), want))
    end
    check(env.IsKeepsakeMaxed(trait), trait .. " is maxed after the last step")
  end
  -- The 0.10.0 value, to show the bug the fix removes.
  env.GameState.KeepsakeChambers.VanillaKeepsake = 50
  check(env.GetKeepsakeLevel("VanillaKeepsake", true) == 2 and not env.IsKeepsakeMaxed("VanillaKeepsake"),
    "old 50 chambers reads as rank 2, not maxed (the reported 'level 2.5')")
  check(step("VanillaKeepsake", 9) == 75, "steps past the last rank stay at 75 chambers")
end

-- ---- 2. GodSanity: god keepsake can't force a locked god ---------------------
do
  local unlocked = {}
  local ItemManager = {
    have_settings = function() return true end,
    setting_mode = function() return 3 end,
    god_eligible = function(n) return unlocked[n] == true end,
  }
  local poseidon = { Name = "ForcePoseidonBoonKeepsake", ForceBoonName = "PoseidonUpgrade", Uses = 1 }
  local game = { CurrentRun = { Hero = { Traits = { { Name = "SomeBoon" }, poseidon } } } }
  run(slice(IM, "function ItemManager.hide_locked_force_boons", "-- How many of the 9 boon gods"),
    "ItemManager.lua", { ItemManager = ItemManager, game = game })

  local wraps = {}
  local env = {
    CurrentRun = game.CurrentRun,
    CheckPreviousReward = function() return nil end,
    RewardData = {},
    ChooseLoot = function(exclude) return { Name = "ZeusUpgrade" } end,
    Contains = function(t, v) for _, x in pairs(t or {}) do if x == v then return true end end return false end,
  }
  run(func_block(read(SCRIPTS .. "RewardLogic.lua"), "SetupRoomReward"), "RewardLogic.lua", env)
  run(slice(RL, "-- GodSanity: a god keepsake's ForceBoonName must not force", "-- The Cauldron is disabled"),
    "reload.lua", {
      ItemManager = ItemManager,
      modutil = { mod = { Path = { Wrap = function(name, fn) wraps[name] = fn end } } },
    })
  local wrapped = assert(wraps.SetupRoomReward, "SetupRoomReward wrap not registered")
  local function door()
    local room = { ChosenRewardType = "Boon", ForcedBoonNames = {} }
    wrapped(env.SetupRoomReward, game.CurrentRun, room, {}, {})
    return room
  end

  local r = door()
  check(r.ForceLootName == "ZeusUpgrade", "Poseidon locked: door rolls a normal god (" .. tostring(r.ForceLootName) .. ")")
  check(poseidon.ForceBoonName == "PoseidonUpgrade" and poseidon.Uses == 1, "keepsake restored, use not spent")
  local plain = { ChosenRewardType = "Boon", ForcedBoonNames = {} }
  env.SetupRoomReward(game.CurrentRun, plain, {}, {})
  check(plain.ForceLootName == "PoseidonUpgrade", "control: unwrapped vanilla forces Poseidon (the leak)")
  unlocked.PoseidonUpgrade = true
  r = door()
  check(r.ForceLootName == "PoseidonUpgrade", "Poseidon unlocked: keepsake forces him again")
  unlocked.PoseidonUpgrade = nil
  local erred = pcall(wrapped, function() error("boom") end, game.CurrentRun, {}, {}, {})
  check(not erred and poseidon.ForceBoonName == "PoseidonUpgrade", "base throwing still restores the keepsake")
end

-- ---- 3 + 4. Thanatos gate and Patroclus guard (reload.lua installers) ---------
do
  local log = {}
  local eligible = false
  local hud = 0
  local zjmod = {}
  function zjmod.ThanatosPreSpawnPresentation(e) hud = hud - 1; log[#log + 1] = "intro" end
  function zjmod.HandleThanatosSpawn(e) log[#log + 1] = "spawn"; hud = hud + 1 end -- ShowCombatUI lives here
  function zjmod.ThanatosEncounterStartPresentation(e) log[#log + 1] = "start" end

  -- zannc-SharedKeepsakePort's own handler, loaded from its file.
  local skp = {}
  local skp_src = read(SKP_DIR .. [[\keepsakes\keepsake_patroclus.lua]])
  run(func_block("\n" .. skp_src, "mod.PatroclusRetaliate"), "keepsake_patroclus.lua", {
    mod = skp, CheckCooldown = function() return true end, EffectData = { x = { DataProperties = {} } },
    ShallowCopyTable = function(t) return t end, ApplyEffect = function() end,
    GetHeroTrait = function() return nil end, CurrentRun = { Hero = { ObjectId = 1 } },
  })
  local native_patroclus = skp.PatroclusRetaliate
  local timer_args = { SourceWeapon = "BiomeTimer", DamageAmount = 10, PureDamage = true, Silent = true }
  local ok, err = pcall(native_patroclus, nil, { Cooldown = 7 }, timer_args)
  -- SharedKeepsakePort 1.4.4 (2026-10-30) moved its nil check above line 87 upstream, so the
  -- control only reproduces the crash against 1.4.3 or older. Our guard stays for players still
  -- on those versions; against a fixed upstream the control is reported, not failed.
  if ok then
    print("note  control: this SharedKeepsakePort no longer crashes on Vow of Time damage (fixed upstream in 1.4.4)")
  else
    check(tostring(err):find("victim"), "control: unguarded Patroclus crashes on Vow of Time damage")
  end

  local env = run(slice(RL, "local function install_thanatos_combat_helper_gate", "-- Called every ~0.5s from the render-loop driver"),
    "reload.lua", {
      HELPER_GATE_INSTALLED = {}, HELPER_GATE_LOGGED_MISSING = {},
      dependency_mod_enabled = function() return true end,
      modutil = { mod = { Mods = { Data = { ["NikkelM-Zagreus_Journey"] = zjmod, ["zannc-SharedKeepsakePort"] = skp } } } },
      ItemManager = { combat_helper_eligible = function(n) return n == "Thanatos" and eligible end },
      rom = { log = { info = function() end } },
      AP_log_error = function(m) print("  log error: " .. m) end,
      game = { EncounterAudio = function() log[#log + 1] = "audio" end },
    })

  local function encounter()
    log, hud = {}, 0
    local e = {}
    zjmod.ThanatosPreSpawnPresentation(e)
    zjmod.HandleThanatosSpawn(e)
    zjmod.ThanatosEncounterStartPresentation(e)
    return table.concat(log, ","), hud
  end
  local seq, h = encounter()
  check(seq == "audio" and h == 0, "Thanatos locked: no intro, HUD untouched, normal audio (" .. seq .. ")")
  eligible = true
  seq, h = encounter()
  check(seq == "intro,spawn,start" and h == 0, "Thanatos unlocked: full vanilla sequence (" .. seq .. ")")
  -- Item arrives mid-intro: the decision taken at the intro holds for the rest of the encounter.
  eligible = false
  log, hud = {}, 0
  local e = {}
  zjmod.ThanatosPreSpawnPresentation(e)
  eligible = true
  zjmod.HandleThanatosSpawn(e)
  check(table.concat(log, ",") == "audio" and hud == 0, "unlock mid-intro: no stray spawn without its intro")

  ok = pcall(skp.PatroclusRetaliate, nil, { Cooldown = 7 }, timer_args)
  check(ok, "guarded Patroclus returns quietly on Vow of Time damage")
  local real = { Victim = { ObjectId = 1, Health = 10 }, DamageAmount = 5 }
  local guard = skp.PatroclusRetaliate
  check(guard ~= native_patroclus, "guard installed over the native handler")
  check(pcall(guard, nil, { Cooldown = 7, EffectName = "x" }, real), "guarded Patroclus still runs on a real hit")
end

print(("%d passed, %d failed"):format(passes, failures))
os.exit(failures == 0 and 0 or 1)
