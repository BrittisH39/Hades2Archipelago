---@meta _
---@diagnostic disable: lowercase-global
-- Live wiring — safe to re-run on every hot-reload.

-- ---- Client -> mod message handlers -----------------------------------------

Bridge.on("SETTINGS", function(payload)
  ItemManager.apply_settings(payload)
  ItemManager.cache_settings(payload)    -- persist for next boot (load-time settings apply at the menu)
  ItemManager.apply_all_vows()           -- enforce vows once settings arrive (if in a save)
  ItemManager.apply_initial_weapon()     -- unlock the seed's starting weapon (else non-Staff rolls are unobtainable)
  ItemManager.apply_first_run_route()    -- surface-only seeds: steer the hardcoded intro run onto the Surface
  ItemManager.apply_surface_start()      -- open the surface if the seed starts it unlocked
  ItemManager.apply_unlocked_modes()     -- force-unlock aspects/pets when set to "unlocked"
  ItemManager.apply_incantation_starts() -- grant the start-with incantations (QoL systems)
  ItemManager.apply_keepsake_reclaim()   -- re-lock pre-owned keepsakes so re-gifting checks
end)
Bridge.on("ITEMS", function(payload) ItemManager.apply_full_list(payload) end)
Bridge.on("RESET", function() ItemManager.reset_applied() end)

-- Turn a raw location name into a short label for the corner log, matching the wishlist
-- mockup ("Sent Score Check 15 - Mario64 - Power Star").
local function check_label(loc)
  local n = loc:match("^%a+ Score (%d+)$")                 -- "Underworld Score 0015"
  if n then return "Score Check " .. tonumber(n) end
  local route, depth, rest = loc:match("^(%a+) Room (%d+)(.*)$")  -- "Surface Room 0012 [Weapon]"
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
-- The client tells us the highest score check the server already has, so a fresh save
-- doesn't re-send / re-notify "Clear Score" checks it re-earns from depth 0.
Bridge.on("SCORESYNC", function(payload)
  local s = APState.get()
  if not s then return end
  for pair in payload:gmatch("[^;]+") do
    local k, v = pair:match("^(.-)=(.*)$")
    local n = tonumber(v) or 0
    -- point_based keys: underworld / surface (advance next_check past earned checks).
    local route = (k == "underworld") and "Underworld" or (k == "surface") and "Surface" or nil
    if route and s.score[route] and (n + 1) > s.score[route].next_check then
      s.score[route].next_check = n + 1
    end
    -- room_based keys: underworld_room / surface_room (advance the room high-water mark).
    local room_route = (k == "underworld_room") and "Underworld"
      or (k == "surface_room") and "Surface" or nil
    if room_route and s.score[room_route] and n > (s.score[room_route].room_high or 0) then
      s.score[room_route].room_high = n
    end
    -- combine_pools shared room pool: advance the combined high-water mark.
    if k == "combined_room" and s.combined_rooms and n > (s.combined_rooms.room_high or 0) then
      s.combined_rooms.room_high = n
    end
  end
  rom.log.info("[AP] score sync: " .. payload)
end)
-- point_based: the client tells us which "<route> Score N" checks the server ALREADY has (a
-- finished player's released/collected checks, an admin !send_location, fresh-save recovery).
-- We REPLACE the runtime set, then run a skip pass on each active route so a check that JUST
-- became checked (a player finished mid-session) advances next_check immediately without
-- waiting for a room clear. Earning a checked one costs ZERO score and re-sends nothing.
-- Parsing mirrors the SCORESYNC handler above; empty lists (underworld=;surface=) are allowed.
Bridge.on("CHECKEDSCORE", function(payload)
  local sets = { Underworld = {}, Surface = {} }
  for pair in payload:gmatch("[^;]+") do
    local k, v = pair:match("^(.-)=(.*)$")
    local route = (k == "underworld") and "Underworld" or (k == "surface") and "Surface" or nil
    if route and v then
      for num in v:gmatch("%d+") do sets[route][tonumber(num)] = true end
    end
  end
  ItemManager.checked_score = sets
  -- Advance next_check now for any route whose pool can free-skip newly-checked numbers.
  local s = APState.get()
  if s then
    for _, route in ipairs({ "Underworld", "Surface" }) do
      if s.score[route] and ItemManager.route_active(route) then
        pcall(function() LocationManager.score_skip_pass(route, s.score[route]) end)
      end
    end
  end
  rom.log.info("[AP] checked score: " .. payload)
end)
Bridge.on("GOAL", function() rom.log.info("[AP] Goal reached — congratulations!") end)
Bridge.on("DEATH", function()
  -- Incoming DeathLink. Lose deathlink_percent% of max health; 0 is special and kills
  -- outright (ignoring Death Defiance). forcing_deathlink stops the KillHero hook from
  -- echoing this back out as our own death. Exact DamageHero arg shape: verify in-game.
  if not (game.CurrentRun and game.CurrentRun.Hero) then return end
  local hero = game.CurrentRun.Hero
  local percent = tonumber(ItemManager.settings.deathlink_percent)
  if percent == nil then percent = 100 end
  ItemManager.forcing_deathlink = true
  pcall(function()
    if percent <= 0 then
      game.Kill(hero, { Name = "Archipelago DeathLink" })
    else
      local maxh = hero.MaxHealth or 50
      local dmg = math.max(1, math.floor(maxh * percent / 100))
      game.DamageHero(hero, { DamageAmount = dmg, Name = "Archipelago DeathLink", SourceName = "Archipelago" })
    end
  end)
  ItemManager.forcing_deathlink = false
  rom.log.info("[AP] received DeathLink (" .. tostring(percent) .. "% max health)")
end)

-- ---- Game -> mod hooks ------------------------------------------------------
-- Wrapped once; guarded so hot-reloads don't stack duplicate wraps.
-- The wrapped function names below are CONFIRMED against the Hades II API
-- (SGG-Modding/Hades2GameDef). Data-value strings (resource keys, weapon ids)
-- still need confirming once the game is installed — see ItemManager.lua.

if not AP_hooks_installed then
  AP_hooks_installed = true

  -- game.UnlockRoomExits(run, room, delay) fires the instant a room is cleared
  -- (all required enemies dead -> exits unlock and the reward spawns). That's
  -- when the player earns the check, not when they leave. It can fire more than
  -- once per room, so score_room guards against double-counting (room._ap_scored).
  pcall(function()
    modutil.mod.Path.Wrap("UnlockRoomExits", function(base, run, room, delay)
      -- Never let our logic break the game's room-clear flow.
      -- A room is CLEARED here (all required enemies dead -> exits unlock). Score it via the
      -- mod's own depth counter, which counts combat OR reward OR shop rooms (Test Run 6 #6),
      -- not just the game's combat-only EncounterDepth. Combat rooms score here; reward-only and
      -- shop rooms score on entry (the StartRoom hook). score_room dedups per room.
      pcall(function() LocationManager.score_room(room, true) end)
      return base(run, room, delay)
    end)
  end)

  -- reverse_vow: re-assert the vows at the start of EVERY run. "Undo Night" and
  -- reloads can clear GameState.ShrineUpgrades, so set + extract them fresh here.
  pcall(function()
    modutil.mod.Path.Wrap("StartNewRun", function(base, prevRun, args)
      -- If we still have no settings (no boot cache, and the per-frame poll hasn't connected yet
      -- because it only runs once gameplay renders), pull them synchronously now -- BEFORE the hero
      -- is built -- so the starting weapon is right on a single launch, no connect-restart dance.
      -- Bounded (~1.5s) and guarded; if the client isn't up it falls through and we proceed as before.
      if not ItemManager.have_settings() then
        pcall(function() Bridge.fetch_blocking(1.5) end)
      end
      pcall(function() ItemManager.apply_all_vows() end)
      ItemManager.won_run_pending = false  -- a new run starting clears any stale win-flag
      -- Surface-only seeds: the intro run (prevRun==nil) is hardcoded to the Underworld
      -- (StartingBiome="F"). apply_first_run_route flags N_Opening01 as the game-start map so the
      -- engine loads the Surface opening; if that took, correct StartingBiome to "N" here so biome
      -- tracking matches. Only acts when the loaded room is actually the Surface opening, so a
      -- failed redirect safely falls back to the normal Underworld intro (no geometry mismatch).
      if prevRun == nil and args then
        rom.log.info("[AP] FIRST RUN: RoomName=" .. tostring(args.RoomName)
          .. " StartingBiome=" .. tostring(args.StartingBiome))
        if args.RoomName == "N_Opening01" then
          -- (Only if the engine ever honors the GameStart flag.) Match biome tracking.
          args.StartingBiome = "N"
          rom.log.info("[AP] first run starting on Surface (StartingBiome=N, room=N_Opening01)")
        elseif ItemManager.first_run_should_be_surface() then
          -- The engine forced the Underworld intro despite the flag. Arm a one-shot kill at the
          -- first room so the game's own first-death -> Crossroads flow takes over (Surface start).
          ItemManager.pending_surface_intro_kill = true
          rom.log.info("[AP] surface-start: engine forced Underworld intro; will kill to reach Crossroads")
        end
      end
      local ret = base(prevRun, args)
      -- Make sure the run starts on an AP-unlocked weapon (Test Run 6 #2): the new hero copies
      -- the previous run's weapon set, so the chosen starting weapon / a now-locked weapon needs
      -- correcting here. No-op if the equipped weapon is already a valid unlocked one.
      pcall(function() ItemManager.enforce_equipped_weapon() end)
      -- New Filler Checks: apply run-start buffs once the run/hero exist.
      pcall(function() ItemManager.apply_progressive_start() end)
      pcall(function() ItemManager.apply_arachne_armor() end)
      pcall(function() ItemManager.apply_help_odds() end)
      -- Starting Armor at run start (hero exists) so it's present in the opening room, not a room
      -- late (Test Run 10 #3). Self-guarded (once per run); the StartRoom call below stays as a
      -- fallback for the surface-intro hero rebuild.
      pcall(function() ItemManager.apply_armor() end)
      return ret
    end)
  end)

  -- Also set the vows at the top of every StartRoom, since the biome timer and
  -- other per-room vow effects read them there (and that runs before/independent
  -- of StartNewRun's set). Quiet to avoid per-room log spam.
  pcall(function()
    modutil.mod.Path.Wrap("StartRoom", function(base, currentRun, currentRoom)
      pcall(function() ItemManager.apply_all_vows(true) end)
      local ret = base(currentRun, currentRoom)
      -- Surface-start seeds: the engine forces an Underworld intro, so bounce off it by instantly
      -- killing Melinoe here (no DeathLink) -> the game's first-death flow lands her in the Crossroads,
      -- where she takes the Surface door. One-shot + self-guarded, so it only fires on that intro room.
      -- If we kill, RETURN NOW: this room is doomed, so skip scoring it (else the intro room counts as
      -- cleared and sends a check before she dies) and skip the per-room grants.
      local killed = false
      pcall(function() killed = ItemManager.kill_surface_intro() end)
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
      pcall(function() ItemManager.apply_armor() end)
      -- Daedalus hammers: place any not-yet-spawned hammers for this run now that we're in a
      -- real room with LootPoints (spawning at StartNewRun was too early -- Test Run 5 #11).
      pcall(function() ItemManager.grant_pending_daedalus() end)
      -- Boss "Met": fire when we actually enter the boss arena (this room), not on reaching the
      -- biome (Test Run 5 #7). on_room_started checks EncounterType == "Boss" internally.
      pcall(function() LocationManager.on_room_started(currentRoom) end)
      -- Score reward-only / shop rooms on ENTER (Test Run 6 #6): they have no enemies to clear,
      -- so UnlockRoomExits is the wrong moment. score_room only counts non-combat qualifying rooms
      -- here (combat rooms wait for their clear) and dedups per room.
      pcall(function() LocationManager.score_room(currentRoom, false) end)
      -- Route locking: if this zone isn't unlocked yet, kill Melinoe (no DeathLink). Uses the same
      -- ItemManager.route_zone_unlocked gate as the room-score block (Test Run 8 #1), so a zone that
      -- kills you can never also send a room check for itself.
      pcall(function()
        if ItemManager.setting_on("lock_routes") then
          local route, zone = Routes.current()
          if route and zone and not ItemManager.route_zone_unlocked(route, zone) then
            local s = APState.get()
            local have = (s and s.route_progress[route]) or 0
            local offset = tonumber(ItemManager.settings[route:lower() .. "_offset"]) or 0
            local need = (zone - 1) + offset
            rom.log.info("[AP] LOCKED " .. route .. " z" .. zone
              .. " (have " .. have .. " < need " .. need .. ") - killing Melinoe")
            if game.CurrentRun and game.CurrentRun.Hero then
              if Notifications then
                Notifications.push("locked", "Route is Locked")
              end
              -- A route-lock death is not a "real" death: don't send a DeathLink for it.
              ItemManager.forcing_deathlink = true
              game.Kill(game.CurrentRun.Hero, { Name = "Archipelago Route Lock" })
              ItemManager.forcing_deathlink = false
            end
          end
        end
      end)
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
        pcall(function() ItemManager.block_run_door(usee, args) end)
        return
      end
      return base(usee, args)
    end)
  end)

  -- arcanasanity gating: cards are unlocked by AP items, so block buying a LOCKED
  -- card at the Altar (the unlock-purchase branch of MetaUpgradeCardAction).
  -- Equipping an already-unlocked card still works.
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
      local mode = ItemManager.setting_mode("aspectsanity")
      if item and mode ~= 0 then
        if ItemManager.ASPECT_UNLOCK_NAMES[item]
            or (mode == 2 and ItemManager.ASPECT_UPGRADE_NAMES[item]) then
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

  -- petsanity progressive: bonds come from Progressive Familiar items, so block the bond
  -- shop's purchases. Randomized leaves bonds alone (only the unlock itself is gated).
  pcall(function()
    modutil.mod.Path.Wrap("HandleFamiliarShopPurchase", function(base, screen, button)
      if ItemManager.setting_mode("petsanity") == 2 then
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
      if ItemManager.setting_mode("keepsakesanity") ~= 0 then
        -- Diagnostic: log EVERY gift presentation so we can see whether Charon's keepsake gift
        -- routes through here at all (Test Run 5 #4: Charon's keepsake check didn't fire on the
        -- first Nectar gift). npc.Name + giftName reveal the real trait id / NPC if unmapped.
        rom.log.info("[AP] gift presentation: npc=" .. tostring(npc and npc.Name)
          .. " giftName=" .. tostring(giftName)
          .. " -> check=" .. tostring(ItemManager.KEEPSAKE_TRAIT_TO_CHECK[giftName]))
        local check = ItemManager.KEEPSAKE_TRAIT_TO_CHECK[giftName]
        if check then
          pcall(function() Bridge.send("CHECK:" .. check) end)
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

  -- keepsakesanity: once an NPC's keepsake check has been sent, block re-gifting them
  -- (no point spending more Nectar, and it makes it clear who you've already done).
  pcall(function()
    modutil.mod.Path.Wrap("CanReceiveGift", function(base, target)
      if ItemManager.setting_mode("keepsakesanity") ~= 0 and target then
        local name = target.GiftName or target.Name
        local gd = name and game.GiftData and game.GiftData[name]
        local trait = gd and gd[1] and gd[1].Gift
        if trait and ItemManager.MANAGED_KEEPSAKES[trait] then
          local s = APState.get()
          if s and s.keepsake_check_sent[trait] then
            return false
          end
        end
      end
      return base(target)
    end)
  end)

  -- keepsakesanity progressive: keepsake levels come from Progressive Keepsake items,
  -- so block normal leveling.
  pcall(function()
    modutil.mod.Path.Wrap("AdvanceKeepsake", function(base, fromTrait)
      if ItemManager.setting_mode("keepsakesanity") == 2 then
        return
      end
      return base(fromTrait)
    end)
  end)

  -- The Cauldron is disabled in this Archipelago (incantationsanity was dropped). Its menu is
  -- the "GhostAdmin" system: UseGhostAdmin opens it, HandleGhostAdminPurchase crafts an
  -- incantation (-> AddWorldUpgrade). Block BOTH so it can't be opened or crafted. Surface
  -- access / penalty cure still come from AP items (force_world_upgrade calls AddWorldUpgrade
  -- directly, not via this menu, so it's unaffected).
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

  -- graspsanity: override the max-Grasp computation to grasp_count * grasp_intervals
  -- (you start at 0 and Progressive Grasp items raise it), instead of the normal
  -- StartingMetaUpgradeLimit + purchased levels.
  pcall(function()
    modutil.mod.Path.Wrap("GetMaxMetaUpgradeCost", function(base, ...)
      if ItemManager.setting_on("graspsanity") then
        local s = APState.get()
        local interval = tonumber(ItemManager.settings.grasp_intervals) or 0
        local value = (s and s.grasp_count or 0) * interval
        if game.GameState then game.GameState.MaxMetaUpgradeCostCache = value end
        return value
      end
      return base(...)
    end)
  end)

  -- reverse_rivals: the Vow of Rivals (BossDifficultyShrineUpgrade) normally strengthens
  -- the FIRST N bosses (active while rank >= CurrentRun.EnteredBiomes, per
  -- ShrineLogic.IsBossDifficultyShrineUpgradeActive). With reverse_rivals on, strengthen
  -- the LAST N instead (active while EnteredBiomes >= total - rank + 1). Both routes are 4
  -- biomes to the final boss. Best-effort: omits the dream-run nuance; verify in-game.
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
      if entered < (total - rank + 1) then return false end
      return true
    end)
  end)

  -- "Start with more unlocked" (wishlist): one central requirement-evaluator wrap drives both
  -- the early Oath of the Unseen and the early field-NPC "helpers". IsGameStateEligible
  -- (RequirementsLogic.lua:9) is the game's single gate for "is this content available right
  -- now" -- the Crossroads Oath obelisk (DeathLoopData Shrine object, gated NamedRequirements
  -- ShrineUnlocked, DestroyIfNotSetup) and each helper's intro encounter both flow through it.
  --   * Oath: when the requirements ARE the ShrineUnlocked named-requirement table, return
  --     true, so the obelisk appears from the start (vows are made view-only below).
  --   * Helpers: for the four gated intro encounters, evaluate with their story-unlock gates
  --     temporarily satisfied (ItemManager.eval_helper_intro) so they can show up the first
  --     time you're in their area, while keeping the natural depth/cooldown spawn cadence.
  -- Everything is identity-matched against the live game tables (resolved lazily) and only
  -- acts in a connected AP session; nothing is written to the save.
  pcall(function()
    modutil.mod.Path.Wrap("IsGameStateEligible", function(base, source, requirements, args)
      local ov = ItemManager.eligibility_override(requirements)
      if ov == "true" then return true end
      if ov == "patch" then return ItemManager.eval_helper_intro(base, source, requirements, args) end
      return base(source, requirements, args)
    end)
  end)

  -- Oath view-only: the player can OPEN the Oath of the Unseen and see what vows are affecting
  -- them, but cannot change ranks -- in Archipelago the Oath is driven by reverse_vow items, not
  -- manual edits. ShrineScreenRankUp/RankDown (ShrineLogic.lua:461/439) and ShrineLogicResetAll
  -- (the "Reset All" button, :875) are the only ways to mutate GameState.ShrineUpgrades from the
  -- screen; no-op all three while connected (vanilla play, before settings, is untouched). The
  -- screen still opens, scrolls, and displays the active vows normally.
  for _, fn in ipairs({ "ShrineScreenRankUp", "ShrineScreenRankDown", "ShrineLogicResetAll" }) do
    pcall(function()
      modutil.mod.Path.Wrap(fn, function(base, screen, button)
        if ItemManager.have_settings() then return end
        return base(screen, button)
      end)
    end)
  end

  -- DeathLink (outgoing): KillHero is the confirmed hero-death entry point. Count our
  -- deaths and send a DeathLink on every deathlink_amount-th death (0 = never send). The
  -- forcing_deathlink guard skips deaths WE caused from an incoming DeathLink.
  pcall(function()
    modutil.mod.Path.Wrap("KillHero", function(base, victim, triggerArgs)
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
      return base(victim, triggerArgs)
    end)
  end)

  -- enemy_locations: every unit death routes through game.Kill (the same entry the
  -- incoming-DeathLink path uses on the hero). Send the first-defeat check for foes we map;
  -- the hero is skipped, and unmapped foes are logged once for discovery (LocationManager).
  pcall(function()
    modutil.mod.Path.Wrap("Kill", function(base, victim, triggerArgs)
      pcall(function()
        if victim and not (game.CurrentRun and victim == game.CurrentRun.Hero) then
          LocationManager.on_enemy_killed(victim)
        end
      end)
      return base(victim, triggerArgs)
    end)
  end)

  -- npc_locations: talking to an NPC. UseNPC(npc, args, user) is the confirmed conversation
  -- entry point (InteractLogic.lua:61) - every cast interaction routes through it. The handler
  -- maps npc.Name -> "Met <Name>" (first time only) and is harmless on anything unmapped. Boss
  -- "Met" checks DON'T use this - they fire reliably from on_room_cleared (reaching the layer).
  pcall(function()
    modutil.mod.Path.Wrap("UseNPC", function(base, npc, args, user)
      pcall(function() LocationManager.on_npc_interacted(npc) end)
      return base(npc, args, user)
    end)
  end)

  -- npc_locations: meeting field NPCs (Artemis/Athena/Heracles/...). They're combat
  -- encounters, not conversations or loot, so UseNPC/HandleLootPickup never fired for them
  -- (Test Run 5 #3). StartEncounter(currentRun, currentRoom, encounter) is the encounter-start
  -- entry (RoomLogic.lua:1848); on_encounter_started reads SpeakerNames -> "Met <Name>".
  pcall(function()
    modutil.mod.Path.Wrap("StartEncounter", function(base, currentRun, currentRoom, encounter)
      pcall(function() LocationManager.on_encounter_started(encounter) end)
      return base(currentRun, currentRoom, encounter)
    end)
  end)

  -- npc_locations: meeting boon gods. Olympians aren't NPC conversations - their boon is a
  -- loot pickup, routed through HandleLootPickup(currentRun, loot, args) (InteractLogic.lua:693),
  -- which plays the god's greeting on interact. on_loot_pickup maps "<God>Upgrade" -> "Met <God>".
  pcall(function()
    modutil.mod.Path.Wrap("HandleLootPickup", function(base, currentRun, loot, args)
      pcall(function() LocationManager.on_loot_pickup(loot) end)
      return base(currentRun, loot, args)
    end)
  end)

  -- npc_locations: story-beat intro checks fired off named text-line sets. PlayTextLines
  -- (NarrativeLogic.lua:190) records GameState.TextLinesRecord[textLines.Name] for every
  -- conversation, so matching the set name is a reliable trigger (Test Run 5 #8: these
  -- locations existed but had no caller).
  --   "SHUSH Homer"   <- the Homer narrator reveal at the Crossroads inspect point
  --                      (InspectHomerReveal01).
  --   "Find Hecate 1/2/3" <- the Hecate hide-and-seek beats (HecateHideAndSeek01/02/03).
  -- If your intended triggers differ, adjust the matched names below.
  pcall(function()
    modutil.mod.Path.Wrap("PlayTextLines", function(base, source, textLines, args)
      pcall(function()
        local nm = textLines and textLines.Name
        if type(nm) == "string" then
          if nm:find("InspectHomerReveal") then
            LocationManager.send_npc_check("SHUSH Homer")
          else
            local n = nm:match("^HecateHideAndSeek0(%d)$")
            if n then LocationManager.send_npc_check("Find Hecate " .. n) end
          end
        end
      end)
      return base(source, textLines, args)
    end)
  end)

  -- game.OpenRunClearScreen() fires when a run is cleared (Chronos defeated).
  pcall(function()
    modutil.mod.Path.Wrap("OpenRunClearScreen", function(base, ...)
      pcall(function()
        -- Which route was cleared (Underworld=Chronos, Surface=Typhon) from the
        -- final boss room's biome, and the equipped weapon for the goal count.
        local route = Routes.current()
        local weapon_id = game.GameState and game.GameState.PrimaryWeaponName or nil
        LocationManager.on_run_cleared(route, weapon_id)
        -- no_death_on_winning_runs: the return-to-Crossroads after a win can read as a
        -- death; flag it so the next KillHero doesn't broadcast a DeathLink.
        if ItemManager.setting_on("no_death_on_winning_runs") then
          ItemManager.won_run_pending = true
        end
      end)
      return base(...)
    end)
  end)
end

-- ---- Socket polling driver --------------------------------------------------
-- Driven from ReturnOfModding's render loop via add_always_draw_imgui, which
-- fires every frame regardless of game state. We deliberately do NOT use the
-- game's thread()/wait(): those are coupled to game session state (SessionMapState)
-- and throw during save loads, which froze the game. Registered once.

if not Bridge.driver_started then
  Bridge.driver_started = true
  -- ReturnOfModding's render-loop callback: fires every frame regardless of game
  -- state, decoupled from the game's thread()/wait() (which are coupled to session/map
  -- state and throw during load transitions). We use it purely as a frame driver now.
  rom.gui.add_always_draw_imgui(function()
    -- Heartbeat: log every ~10s (assuming ~60fps) so the log shows whether this render driver is
    -- still ticking after the first run (Test Run 6 #1: the overlay vanished after run one -- if
    -- the heartbeat stops, the driver itself died and we re-register; if it keeps going, the
    -- overlay draw is at fault). Cheap modulo, no per-frame logging.
    AP_render_frames = (AP_render_frames or 0) + 1
    if AP_render_frames % 600 == 0 then
      rom.log.info("[AP] render driver alive (frame " .. AP_render_frames .. ")")
    end
    -- Poll the socket every frame.
    local ok, err = pcall(Bridge.update)
    if not ok then rom.log.error("[AP] update error: " .. tostring(err)) end
    -- Drain the in-game notification queue (native banners). Guarded internally.
    pcall(function() if Notifications then Notifications.update() end end)
    -- Draw the Archipelago overlay (score + sent/filler feed). Guarded internally.
    pcall(function() if Overlay then Overlay.draw() end end)
  end)
end

-- ---- Overlay show/hide shortcut ---------------------------------------------
-- A global keyboard shortcut to toggle the overlay (so it can be reopened after the "x" close
-- button hides it). rom.inputs.on_key_pressed fires even while the game is focused and the mod
-- menu is closed -- the same input system that owns the Insert menu-toggle and the debug keys.
-- Guarded by a plugin global so a hot-reload doesn't stack duplicate handlers (the key only
-- re-registers, with the latest config value, on a full game restart).
if not AP_overlay_key_registered and rom.inputs and rom.inputs.on_key_pressed then
  local key = (config and config.overlay_toggle_key) or "F8"
  local ok, handle = pcall(function()
    return rom.inputs.on_key_pressed{ key, Name = "Archipelago: Toggle Overlay", function()
      if Overlay then Overlay.toggle() end
    end }
  end)
  if ok then
    AP_overlay_key_registered = true
    AP_overlay_key_handle = handle
    rom.log.info("[AP] overlay toggle key registered: " .. tostring(key))
  else
    rom.log.error("[AP] overlay toggle key registration failed: " .. tostring(handle))
  end
end

-- A menu-bar entry (visible when the Hell2Modding menu / Insert is open) as a discoverable,
-- no-keyboard way to show the overlay again and a reminder of the shortcut. Registered once.
if not AP_menu_bar_registered and rom.gui and rom.gui.add_to_menu_bar then
  rom.gui.add_to_menu_bar(function()
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
  end)
  AP_menu_bar_registered = true
end
