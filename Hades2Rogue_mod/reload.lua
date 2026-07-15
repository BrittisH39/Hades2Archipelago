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
  ItemManager.apply_nightmare_start()      -- open the Nightmare Chaos Gate if the seed starts it unlocked
  ItemManager.apply_unlocked_modes()     -- force-unlock aspects/pets when set to "unlocked"
  ItemManager.apply_aspect_base_lock()   -- aspectsanity=randomized: take away the free Aspect of Melinoe (it's an item)
  ItemManager.apply_incantation_starts() -- grant the start-with incantations (QoL systems)
  ItemManager.apply_keepsake_reclaim()   -- re-lock pre-owned keepsakes so re-gifting checks
  ItemManager.apply_keepsake_rack_unlock() -- open the Crossroads keepsake rack (locked until Nectar gained)
end)
Bridge.on("ITEMS", function(payload)
  -- Do NOT apply inline. Receiving items runs live grants (the currency-gain presentation, the
  -- live rarity-trait mutation) that crash/softlock the game if they fire while a boon-selection
  -- screen or a scripted conversation/cutscene owns input -- the same class of bug as the boon
  -- banner softlock. So just stash the payload; ItemManager.drain_pending_items (render driver,
  -- below) applies it on the next SAFE frame. ITEMS is always the full ordered list and
  -- apply_full_list is idempotent (s.processed), so a newer payload simply supersedes a pending
  -- one -- no queue to manage.
  ItemManager.pending_items = payload
end)
Bridge.on("RESET", function() ItemManager.reset_applied() end)

-- Turn a raw location name into a short label for the corner log, matching the wishlist
-- mockup ("Sent Score Check 15 - Mario64 - Power Star").
local function check_label(loc)
  local n = loc:match("^[%a ]+ Score (%d+)$")               -- "Underworld/Nightmare Score 0015"
  if n then return "Score Check " .. tonumber(n) end
  local cn = loc:match("^Score (%d+)$")                      -- combine_pools shared "Score 0015"
  if cn then return "Score Check " .. tonumber(cn) end
  local route, depth, rest = loc:match("^([%a ]+) Room (%d+)(.*)$")  -- "Surface Room 0012 [Weapon]"
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
local SCORESYNC_ROUTE_KEY = { underworld = "Underworld", surface = "Surface", nightmare = "Nightmare" }
local SCORESYNC_ROOM_ROUTE_KEY = {
  underworld_room = "Underworld", surface_room = "Surface", nightmare_room = "Nightmare",
}
Bridge.on("SCORESYNC", function(payload)
  local s = APState.get()
  if not s then return end
  for pair in payload:gmatch("[^;]+") do
    local k, v = pair:match("^(.-)=(.*)$")
    local n = tonumber(v) or 0
    -- point_based keys: underworld / surface / nightmare (advance next_check past earned checks).
    local route = SCORESYNC_ROUTE_KEY[k]
    if route and s.score[route] and (n + 1) > s.score[route].next_check then
      s.score[route].next_check = n + 1
    end
    -- room_based keys: underworld_room / surface_room / nightmare_room (advance the room high-water mark).
    local room_route = SCORESYNC_ROOM_ROUTE_KEY[k]
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
  -- "combined" is combine_pools' shared route-agnostic "Score N" pool; the rest are the
  -- per-route split_pools ones. Only one kind is in play per seed, but parsing both is
  -- harmless and keeps this in step with whatever the client sends.
  local sets = { Underworld = {}, Surface = {}, Nightmare = {}, Combined = {} }
  for pair in payload:gmatch("[^;]+") do
    local k, v = pair:match("^(.-)=(.*)$")
    local pool_key = SCORESYNC_ROUTE_KEY[k] or (k == "combined" and Routes.COMBINED_SCORE_KEY)
    if pool_key and v then
      for num in v:gmatch("%d+") do sets[pool_key][tonumber(num)] = true end
    end
  end
  ItemManager.checked_score = sets
  -- Advance next_check now for whichever pool(s) can free-skip newly-checked numbers.
  local s = APState.get()
  if s then
    if ItemManager.combine_active() then
      pcall(function()
        LocationManager.score_skip_pass(Routes.COMBINED_SCORE_KEY, s.combined_score)
      end)
    else
      for _, route in ipairs({ "Underworld", "Surface", "Nightmare" }) do
        if s.score[route] and ItemManager.route_active(route) then
          pcall(function() LocationManager.score_skip_pass(route, s.score[route]) end)
        end
      end
    end
  end
  rom.log.info("[AP] checked score: " .. payload)
end)
Bridge.on("GOAL", function() rom.log.info("[AP] Goal reached — congratulations!") end)
Bridge.on("DEATH", function(payload)
  -- Incoming DeathLink. Don't apply it here -- the message can arrive at any moment
  -- (at the Crossroads with no live Hero, while the game is paused with all threads
  -- frozen, mid-load), and applying it then is either a no-op or a lost death. Instead
  -- just enqueue it; ItemManager.flush_pending_deathlink() (called every frame from the
  -- render driver) applies it the moment the player is actually in a killable, unpaused
  -- state. Counter, not a bool, so several DeathLinks in quick succession all land.
  -- payload is the sender's slot name (Client.py's DEATH:<source>); queued in its own FIFO
  -- alongside the counter so a burst of DeathLinks still pairs each kill with the right sender.
  local source = (payload ~= nil and payload ~= "") and payload or "Archipelago"
  ItemManager.pending_deathlinks = (ItemManager.pending_deathlinks or 0) + 1
  ItemManager.pending_deathlink_sources = ItemManager.pending_deathlink_sources or {}
  table.insert(ItemManager.pending_deathlink_sources, source)
  rom.log.info("[AP] DeathLink received from " .. source .. " -> queued (pending=" .. ItemManager.pending_deathlinks .. ")")
end)

-- ---- Game -> mod hooks ------------------------------------------------------
-- Wrapped once; guarded so hot-reloads don't stack duplicate wraps.
-- The wrapped function names below are CONFIRMED against the Hades II API
-- (SGG-Modding/Hades2GameDef). Data-value strings (resource keys, weapon ids)
-- still need confirming once the game is installed — see ItemManager.lua.

if not AP_hooks_installed then
  AP_hooks_installed = true

  -- game.UnlockRoomExits(run, room, delay) fires the instant a room's exits unlock (all its
  -- encounters completed -> reward spawns). Combat scoring no longer happens here -- it now
  -- happens per-ENCOUNTER (score_encounter, via the StartEncounter wrap below) so a room that
  -- chains several encounters (MultipleEncountersData) earns a check for each fight instead of
  -- one for the whole cluster on exit-unlock. This hook now only handles filler reasserts.
  pcall(function()
    modutil.mod.Path.Wrap("UnlockRoomExits", function(base, run, room, delay)
      -- Never let our logic break the game's room-clear flow.
      -- Also reassert the AP fillers here, not just on room entry: the AP bridge connects and
      -- delivers settings/items ASYNCHRONOUSLY (see the StartNewRun wrap below), so on a fresh
      -- launch it's possible to enter a room BEFORE APState has anything to read yet --
      -- reassert_stat_bonuses/apply_help_odds/apply_armor/grant_pending_daedalus silently no-op in
      -- that case (no settings = nothing to grant). A room takes real time to clear, so by the time
      -- this fires the connection has almost always finished -- this is what was making the bonus
      -- seem to only "appear" when a room is cleared and its reward spawns, rather than at entry.
      -- UnlockRoomExits fires the instant the room's last enemy dies -- which can land while the
      -- player has the Trait Tray (boon inventory) open reviewing their build mid-room. The trait
      -- grants below (AddTraitToHero) mutate CurrentRun.Hero.Traits out from under that screen's
      -- cached component list and softlock it, so hold them (like the item-receipt gate) while
      -- Notifications.blocked() says a boon/tray/conversation screen owns input. Self-healing:
      -- they're idempotent ledger top-ups that simply re-fire at the next room hook if skipped here.
      pcall(function() ItemManager.apply_help_odds() end)
      if not (Notifications and Notifications.blocked and Notifications.blocked()) then
        pcall(function() ItemManager.reassert_stat_bonuses() end)
        pcall(function() ItemManager.apply_armor() end)
        pcall(function() ItemManager.grant_pending_daedalus() end)
      end
      return base(run, room, delay)
    end)
  end)

  -- reverse_vow: re-assert the vows at the start of EVERY run. "Undo Night" and
  -- reloads can clear GameState.ShrineUpgrades, so set + extract them fresh here.
  pcall(function()
    modutil.mod.Path.Wrap("StartNewRun", function(base, prevRun, args)
      -- If this session hasn't gotten a LIVE settings message yet (only the boot-cache carryover,
      -- which can be a launch-old seed entirely -- see have_live_settings), pull them synchronously
      -- now -- BEFORE the hero is built -- so the starting weapon/aspect are right on a single
      -- launch, no connect-restart dance. Bounded (~1.5s) and guarded; if the client isn't up it
      -- falls through and we proceed as before.
      if not ItemManager.have_live_settings() then
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
        -- Arm the DeathLink intro guard (ItemManager.in_scripted_opening_room) for exactly this
        -- one room load -- see its comment in ItemManager.lua for why this can't be room-name
        -- matching. Cleared by the StartRoom wrap below the moment the room actually changes.
        ItemManager.in_boot_intro_run = true
        ItemManager.boot_intro_room_name = args.RoomName
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
      -- Clear the boot-intro DeathLink guard the moment the room actually changes away from the
      -- one room StartNewRun(prevRun=nil) armed it for -- see ItemManager.in_boot_intro_run.
      if ItemManager.in_boot_intro_run and currentRoom
          and currentRoom.Name ~= ItemManager.boot_intro_room_name then
        ItemManager.in_boot_intro_run = false
      end
      pcall(function() ItemManager.apply_all_vows(true) end)
      local ret = base(currentRun, currentRoom)
      -- Final Challenge: the build arrives intact now that SetupHeroForEnding is skipped for
      -- the contract-door transition (see that wrap below) -- just log the trait count on
      -- arrival so a playtest can verify from the log alone.
      pcall(function()
        if currentRoom and currentRoom.Name == "C_Boss01" then
          ItemManager.log_zagreus_arrival()
        end
      end)
      -- Re-assert the MaxHealth/MaxMana stat-bonus trait, rarity boost, and major-finds ratio on
      -- EVERY room, not just at StartNewRun: quitting to desktop and rejoining a run-in-progress
      -- never fires StartNewRun (the game only calls it for a genuinely new run), so a fresh Lua
      -- process's game.TraitData never gets ArchipelagoStatBonus/ArchipelagoRarityBoost registered
      -- again, and the game's own DoPatches strips those saved hero traits as unrecognized before
      -- this room ever renders. Calling it here heals that the moment the first room after a
      -- rejoin loads (same pattern as the armor/vow reasserts below).
      -- Guard on Notifications.blocked() same as the UnlockRoomExits hook above: the Trait Tray
      -- (boon inventory) can plausibly still be closing/reopening right at a room transition, and
      -- AddTraitToHero here would hit the same softlock. Idempotent/self-healing, so skipping just
      -- defers to the next room hook.
      local trait_tray_blocked = Notifications and Notifications.blocked and Notifications.blocked()
      if not trait_tray_blocked then
        pcall(function() ItemManager.reassert_stat_bonuses() end)
      end
      -- Increased Help Odds: RequirementsData is base-game Lua data, not save data, so a fresh
      -- process reload resets it to default -- reassert every room for the same rejoin reason.
      pcall(function() ItemManager.apply_help_odds() end)
      -- Nightmare Furies: RoomData is base Lua data too (reset on a fresh process), so re-strip the
      -- Alecto/Tisiphone rollout gates every room -- otherwise a mid-run rejoin would restore the
      -- "kill Megaera 4 times first" gate. Self-guards to a no-op when Nightmare isn't installed.
      pcall(function() ItemManager.apply_nightmare_fury_unlock() end)
      -- Starting Aspect (aspectsanity randomized/per_aspect modes): must run here, not from the
      -- SETTINGS handler -- see ItemManager.apply_initial_weapon's comment for why applying it
      -- before the run/hero exist crashes the game (MapState nil during vanilla's first-room
      -- hero setup). Idempotent, so safe to reassert every room.
      pcall(function() ItemManager.reassert_starting_aspect() end)
      -- aspectsanity=randomized: weapons don't get their Aspect of Melinoe for free (it's one of
      -- the 24 shuffled items). ScreenData.WeaponUpgradeScreen.FreeUnlocks is base Lua data, so a
      -- fresh process restores it -- re-strip every room, same as apply_help_odds above. Runs
      -- AFTER reassert_starting_aspect so a seed whose starting pick IS the Aspect of Melinoe has
      -- already been recorded as earned and is never stripped.
      pcall(function() ItemManager.apply_aspect_base_lock() end)
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
      -- Daedalus hammers: place any not-yet-spawned hammers for this run now that we're in a
      -- real room with LootPoints (spawning at StartNewRun was too early -- Test Run 5 #11).
      -- Both call AddTraitToHero -- hold them with the same Trait Tray guard as above.
      if not trait_tray_blocked then
        pcall(function() ItemManager.apply_armor() end)
        pcall(function() ItemManager.grant_pending_daedalus() end)
      end
      -- Boss "Met": fire when we actually enter the boss arena (this room), not on reaching the
      -- biome (Test Run 5 #7). on_room_started checks EncounterType == "Boss" internally.
      pcall(function() LocationManager.on_room_started(currentRoom) end)
      -- Score reward-only / shop rooms on ENTER (Test Run 6 #6): they have no enemies to clear,
      -- so there's no clear moment to hook. score_room only counts non-combat qualifying rooms
      -- here (combat rooms score per-encounter via score_encounter) and dedups per room.
      pcall(function() LocationManager.score_room(currentRoom) end)
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

  -- Quitting to desktop and rejoining a run-in-progress does NOT always call StartRoom above:
  -- OnAnyLoad (RoomLogic.lua ~233) calls RestoreUnlockRoomExits INSTEAD of StartRoom whenever the
  -- resumed room's exits were already unlocked (e.g. you quit after clearing the room, in the Hub,
  -- or generally anywhere past the room's opening beat -- a very common save point). Our StartRoom
  -- wrap never ran on that path, so none of the rejoin-heal reasserts fired -- this is why the
  -- Max Health/Magick fix "didn't work": it only covered half of the two paths the game actually
  -- uses to resume a room. Mirror the same reasserts here.
  pcall(function()
    modutil.mod.Path.Wrap("RestoreUnlockRoomExits", function(base, currentRun, currentRoom)
      local ret = base(currentRun, currentRoom)
      pcall(function() ItemManager.apply_help_odds() end)
      -- Same Trait Tray (boon inventory) guard as the StartRoom/UnlockRoomExits hooks -- these all
      -- call AddTraitToHero, which softlocks the tray if it's open when they land.
      if not (Notifications and Notifications.blocked and Notifications.blocked()) then
        pcall(function() ItemManager.reassert_stat_bonuses() end)
        pcall(function() ItemManager.apply_armor() end)
        -- Daedalus hammers: re-place any not-yet-spawned hammers for this run. Needed here too --
        -- without this hook, resuming into an already-unlocked room skipped grant_pending_daedalus
        -- entirely, which is why hammers appeared to "reset" on rejoin (never re-placed, not actually
        -- removed).
        pcall(function() ItemManager.grant_pending_daedalus() end)
      end
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

  -- Nightmare Chaos Gate lock (opt-in third-party "Zagreus' Journey" route). Separate from the
  -- UseEscapeDoor wrap above -- the Chaos Gate isn't a vanilla run-start door, it's that mod's
  -- own StartHadesRun function. No-ops cleanly if the mod isn't installed (see
  -- ItemManager.nightmare_mod's presence/validity check).
  pcall(function() ItemManager.install_nightmare_gate_lock() end)
  -- Nightmare run-clear detection, second path (see ItemManager.handle_nightmare_run_cleared for
  -- why this exists alongside the OpenRunClearScreen wrap further down).
  pcall(function() ItemManager.install_nightmare_run_clear_hook() end)
  -- Nightmare Furies: make Alecto + Tisiphone eligible as the Tartarus boss from run 1, instead of
  -- gating them behind 4 lifetime Megaera kills the way Zagreus' Journey ports Nightmare. Runs here
  -- (after ZJ's room data is loaded) AND per-room in the StartRoom wrap, since the boss-room
  -- eligibility is evaluated when the prior room's exits are chosen -- reasserting each room means
  -- a fresh-process rejoin (which reloads ZJ's static room data) can never restore the gate.
  pcall(function() ItemManager.apply_nightmare_fury_unlock() end)

  -- arcanasanity gating: cards are unlocked by AP items, so block buying a LOCKED
  -- card at the Altar (the unlock-purchase branch of MetaUpgradeCardAction).
  -- Equipping an already-unlocked card still works. FAIL-CLOSED on purpose: the mod is
  -- only ever meant to run with an AP session, so before settings arrive (nil ~= "0" is
  -- true) purchases stay blocked rather than letting an early buy slip through.
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
      -- Upgrades (<aspect>2..5, including the default Aspect's) are AP-gated in every mode but
      -- "unlocked" (0) -- progressive (2) and per_aspect (3) rank up an Aspect one item at a
      -- time, randomized (1) hands it straight to max, and either way every rank comes from an
      -- item. randomized especially: its starting Aspect begins at rank 1 and its item is what
      -- takes it to max, so a buyable upgrade would let the player skip that item entirely.
      local mode = ItemManager.setting_mode("aspectsanity")
      if item and mode ~= 0 then
        if ItemManager.ASPECT_UNLOCK_NAMES[item] or ItemManager.ASPECT_UPGRADE_NAMES[item] then
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
        if check and LocationManager.check_route_blocked(check) then
          -- This NPC's keepsake location isn't in the seed (its route is excluded), so
          -- there's no check to send or gate on -- let the gift behave vanilla instead.
          check = nil
        end
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
  -- Blocked UNCONDITIONALLY (not gated on have_settings): the mod is only ever meant to
  -- run with an AP session, and fail-closed means the Cauldron can't be used in the
  -- window before settings arrive.
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

  -- "Start with more unlocked" (wishlist): one central requirement-evaluator wrap drives the
  -- early Oath of the Unseen, the early field-NPC "helpers", early Chaos Gates, the early
  -- Fated List, and (wishlist "All gods are accessible from the beginning") every god that's
  -- normally introduced gradually. IsGameStateEligible (RequirementsLogic.lua:9) is the game's
  -- single gate for "is this content available right now" -- the Crossroads Oath obelisk
  -- (DeathLoopData Shrine object, gated NamedRequirements ShrineUnlocked, DestroyIfNotSetup),
  -- the Chaos Gate rooms (RoomData/RoomDataI/N/P, gated NamedRequirements
  -- {"ChaosUnlocked","NoRecentChaosEncounter"}), the Crossroads QuestLog/Fated List pedestal
  -- (HubRoomData.Hub_Main.ObstacleData[560662]), each helper's intro encounter, and each
  -- gated god's own boon/shop eligibility (LootData.<God>Upgrade.GameStateRequirements, or for
  -- Hermes/Selene their NamedRequirementsData entry) all flow through it.
  --   * Oath: when the requirements ARE the ShrineUnlocked named-requirement table, return
  --     true, so the obelisk appears from the start (vows are made view-only below).
  --   * Chaos Gates: when the requirements ARE the ChaosUnlocked named-requirement table
  --     (normally needs GameState.UseRecord.HermesUpgrade -- a Hermes Boon taken in some past
  --     run -- among other clauses), return true, so Chaos Gates can spawn from run 1.
  --     NoRecentChaosEncounter (per-run spacing cooldown) is untouched, so gates still don't
  --     spam back-to-back rooms.
  --   * Fated List: forces true on 3 tables -- the pedestal's own SetupGameStateRequirements
  --     (normally needs TextLinesRecord.MorosGrantsQuestLog, a story beat), its OverwriteSelf
  --     SetupEvents[1].GameStateRequirements (normally needs WorldUpgradesAdded.WorldUpgradeQuestLog,
  --     which actually wires up the UseQuestLog interaction), and the QuestLogUnlocked named
  --     requirement (gates the quest-tracking logic / codex menu icon, RequirementsData.lua:93).
  --     All three are one-time story flags with no per-run situational component, so forcing
  --     them true is as safe as the Oath/Chaos overrides.
  --   * Helpers: for the four gated intro encounters, evaluate with their story-unlock gates
  --     temporarily satisfied (ItemManager.eval_helper_intro) so they can show up the first
  --     time you're in their area, while keeping the natural depth/cooldown spawn cadence.
  --   * Gods: Zeus/Hera/Ares/Hestia/Aphrodite/Hephaestus each have a single story-flag gate
  --     with no per-run component (see FORCE_GOD_UPGRADES, ItemManager.lua), so they're forced
  --     true the same way as Oath/Chaos/QuestLog. Hermes and Selene use the identical
  --     mechanism but their NamedRequirementsData entries also carry per-run pacing (don't
  --     reoffer if already taken/in-store this run), so they go through the same "patch" path
  --     as the helper intros instead, preserving that pacing.
  -- Everything is identity-matched against the live game tables (resolved lazily) and only
  -- acts in a connected AP session; nothing is written to the save.
  pcall(function()
    modutil.mod.Path.Wrap("IsGameStateEligible", function(base, source, requirements, args)
      local ov = ItemManager.eligibility_override(requirements)
      if ov == "true" then return true end
      if ov == "false" then return false end
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
  -- deaths and send a DeathLink on every deathlink_amnesty-th death (0 = never send). The
  -- forcing_deathlink guard skips deaths WE caused from an incoming DeathLink.
  pcall(function()
    modutil.mod.Path.Wrap("KillHero", function(base, victim, triggerArgs)
      -- Final Challenge: the scripted "you return to the Crossroads" that normally follows
      -- Chronos'/Typhon's run-clear screen goes through this same KillHero entry point
      -- (win or lose, the run-end sequence is the same code -- see DeathLoopLogic.lua's
      -- KillHero checking CurrentRun.Cleared). Skipping base() entirely here (not just the
      -- DeathLink send below) means the Hero never actually dies -- they stay put, free to
      -- walk up to the Zagreus contract the OpenRunClearScreen wrap just spawned.
      if ItemManager.suppress_win_death then
        ItemManager.suppress_win_death = false
        -- won_run_pending was armed (if set) for THIS same suppressed event -- clear it too,
        -- so it doesn't linger and wrongly swallow the DeathLink for whatever later death
        -- (win or lose) actually ends the Zagreus fight.
        ItemManager.won_run_pending = false
        rom.log.info("[AP] Final Challenge: suppressed the scripted return-to-Crossroads death")
        return
      end
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
      local is_zagreus = false
      pcall(function()
        if victim and not (game.CurrentRun and victim == game.CurrentRun.Hero) then
          LocationManager.on_enemy_killed(victim)
          -- Zagreus goal: his death is the whole fight's win condition (no adds to track,
          -- unlike a normal boss room's "all enemies dead" check) -- same reliable hook as
          -- every other boss/enemy defeat, just routed to the goal tracker instead of (or
          -- in addition to) a "Defeated <enemy>" check.
          if victim.Name == "Zagreus" then
            LocationManager.on_zagreus_cleared()
            is_zagreus = true
          end
        end
      end)
      -- base(...) runs Zagreus's own OnDeathFunctionName (ZagreusKillPresentation) to
      -- completion first (it's called directly, not via thread(), so this blocks in our
      -- same coroutine) -- confetti/reward and all -- before we do anything below.
      local result = base(victim, triggerArgs)
      if is_zagreus then
        pcall(function()
          -- Final Challenge: the run-clear screen was deferred back when Chronos/Typhon
          -- fell (see the OpenRunClearScreen wrap) so the player could fight Zagreus first.
          -- Now that he's dead, show it for real -- the run still ends after Zagreus, same
          -- as it would have right after Chronos/Typhon in every other mode.
          if ItemManager.goal_includes_zagreus()
             and ItemManager.zagreus_mode() == ItemManager.ZAGREUS_MODE_FINAL_CHALLENGE then
            if ItemManager.setting_on("no_death_on_winning_runs") then
              ItemManager.won_run_pending = true
            end
            ItemManager.force_run_clear_screen = true
            game.OpenRunClearScreen()
          end
        end)
      end
      return result
    end)
  end)

  -- Empowered Zagreus mode: ActivatePrePlaced (EventLogic.lua:75) is the function that
  -- activates and sets up the pre-placed boss unit for BossZagreus01's
  -- StartRoomUnthreadedEvents (LegalTypes = {"Zagreus"}), returning the activated unit(s).
  -- Let the game finish its own normal spawn/setup first (base(...)), THEN scale the
  -- already-real base stats -- avoids racing the game's own threaded per-unit setup.
  pcall(function()
    modutil.mod.Path.Wrap("ActivatePrePlaced", function(base, eventSource, args)
      local activated = base(eventSource, args)
      pcall(function()
        if not (activated and ItemManager.goal_includes_zagreus()
                and ItemManager.zagreus_mode() == ItemManager.ZAGREUS_MODE_EMPOWERED) then
          return
        end
        local s = APState.get()
        local received = (s and s.zagreus_weaken) or 0
        local tiers = tonumber(ItemManager.settings.zagreus_weaken_tiers) or 5
        for _, unit in pairs(activated) do
          if unit and unit.Name == "Zagreus" then
            ItemManager.apply_zagreus_empower(unit, received, tiers)
          end
        end
      end)
      return activated
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

  -- Remove Eris' Underworld "Curse" ambush entirely (user request: never want to be cursed).
  -- Confirmed via game scripts (ShrineLogic.lua/RoomDataG,H,I.lua/NPCData_Eris.lua) this ambush
  -- is Underworld-only -- her real Surface boss fight never calls ApplyErisCurse, so there's no
  -- equivalent to worry about there. Two layers, both while an AP session is connected:
  --   1) SpawnErisForCurse (the StartUnthreadedEvents call in RoomDataG/H/I's intro room) is a
  --      no-op, so she never spawns for the ambush at all. The room already handles her absence
  --      gracefully in vanilla (there's a separate "ErisNotSightedVoiceLines" flavor line for
  --      when she isn't encountered), so nothing else breaks.
  --   2) ApplyErisCurse (every one of her ambush dialogue branches ends by calling this,
  --      regardless of how the conversation was entered) also never applies the actual curse
  --      trait, as a defense-in-depth backstop in case some other path into it exists.
  -- "Met Eris" tracking is untouched: it's Surface-gated (matches her real boss fight), and this
  -- ambush was only ever a redundant second way to trigger that same flag -- removing it doesn't
  -- drop any check.
  pcall(function()
    modutil.mod.Path.Wrap("SpawnErisForCurse", function(base, source, args)
      if ItemManager.have_settings() then
        rom.log.info("[AP] blocked Eris curse ambush spawn (removed by request)")
        return
      end
      return base(source, args)
    end)
  end)
  pcall(function()
    modutil.mod.Path.Wrap("ApplyErisCurse", function(base, source, args)
      pcall(function() LocationManager.on_eris_curse_applied() end)
      if ItemManager.have_settings() then
        -- Only skip the trait grant (AddTrait/CallFunctionName/UpdateTraitSummary) -- NOT the
        -- whole function. base() also runs ErisCurseAppliedPresentation, which is what makes
        -- Eris actually leave (animation, restores combat UI, removes her own AddInputBlock).
        -- An earlier version returned before calling base() at all: if SpawnErisForCurse had
        -- already let her spawn (a race -- the AP bridge can connect AFTER the room starts, see
        -- the wrap above), the player could still reach her dialogue and trigger this, and
        -- skipping the whole function left her stuck mid-interaction with nothing ever
        -- resolving her -- this, not the curse itself, is the likely cause of the freeze.
        rom.log.info("[AP] Eris curse trait suppressed (removed by request); still resolving her exit normally")
        pcall(function() game.ErisCurseAppliedPresentation(source, args) end)
        return
      end
      return base(source, args)
    end)
  end)

  -- AddInputBlock/RemoveInputBlock are the engine-native "a scripted sequence is playing,
  -- don't let the player act" signal -- used all over (boss-kill presentations, MapLoad,
  -- StartRoom, dream-run transitions, and Eris' curse cutscene above, if the have_settings()
  -- backstop above doesn't catch it in time). There's no Lua-readable global state for "is any
  -- input block active" the way ScreenAnchors/SessionMapState work, so mirror every named block
  -- into Notifications.active_input_blocks ourselves -- Notifications.update() holds the banner
  -- queue while any are set, instead of popping a banner mid-cutscene (see Notifications.lua).
  pcall(function()
    modutil.mod.Path.Wrap("AddInputBlock", function(base, args)
      pcall(function() Notifications.on_input_block(args and args.Name, true) end)
      return base(args)
    end)
  end)
  pcall(function()
    modutil.mod.Path.Wrap("RemoveInputBlock", function(base, args)
      local result = base(args)
      pcall(function()
        if args and args.All then
          Notifications.clear_input_blocks()
        else
          Notifications.on_input_block(args and args.Name, false)
        end
      end)
      return result
    end)
  end)

  -- npc_locations: meeting field NPCs (Artemis/Athena/Heracles/...). They're combat
  -- encounters, not conversations or loot, so UseNPC/HandleLootPickup never fired for them
  -- (Test Run 5 #3). StartEncounter(currentRun, currentRoom, encounter) is the encounter-start
  -- entry (RoomLogic.lua:1848); on_encounter_started reads SpeakerNames -> "Met <Name>".
  -- (Room-check scoring is NOT hooked here -- see the SpawnRoomReward wrap below. Raw
  -- encounter-completion over-counts: Mount Olympus "P_Combat01"-style rooms run a
  -- pre-combat wave (GeneratedP_PreCombat, EncounterRoomRewardOverride="Empty") before the
  -- real fight, and both are real combat encounters that "complete".)
  pcall(function()
    modutil.mod.Path.Wrap("StartEncounter", function(base, currentRun, currentRoom, encounter)
      pcall(function() LocationManager.on_encounter_started(encounter) end)
      return base(currentRun, currentRoom, encounter)
    end)
  end)

  -- Room-check trigger for combat rooms: fire when an encounter's reward actually spawns
  -- (RewardLogic.lua:SpawnRoomReward), the game's own definition of "this encounter paid out" --
  -- not just "combat finished" (see the StartEncounter comment above for why that over-counted).
  -- SpawnRoomReward returns the spawned reward object on its one real-spawn path and nil on
  -- every no-op path (Empty/Story/Shop/DeferReward/no reward chosen), so only score a real spawn.
  -- CurrentRun.CurrentRoom.Encounter is whichever encounter is currently resolving (RoomLogic.lua's
  -- multi-encounter loop reassigns it before each StartEncounter call), so this correctly attributes
  -- the check to that specific encounter, not the room as a whole.
  pcall(function()
    modutil.mod.Path.Wrap("SpawnRoomReward", function(base, eventSource, args)
      local reward = base(eventSource, args)
      if reward ~= nil then
        local room = game.CurrentRun and game.CurrentRun.CurrentRoom
        pcall(function() LocationManager.score_encounter(room, room and room.Encounter) end)
      end
      return reward
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

  -- game.OpenRunClearScreen() fires when a run is cleared (Chronos/Typhon defeated).
  pcall(function()
    modutil.mod.Path.Wrap("OpenRunClearScreen", function(base, ...)
      -- Final Challenge: this is US calling game.OpenRunClearScreen() a second time (the Kill
      -- wrap, once Zagreus dies) to show the screen that was deferred when Chronos/Typhon
      -- fell -- go straight to the real screen instead of re-running the redirect check below
      -- (which would otherwise fire again, since the goal/mode conditions are still true, and
      -- spawn a second contract instead of actually showing the screen).
      if ItemManager.force_run_clear_screen then
        ItemManager.force_run_clear_screen = false
        return base(...)
      end
      local redirect_to_zagreus = false
      pcall(function()
        -- Which route was cleared (Underworld=Chronos, Surface=Typhon, Nightmare=Hades) from
        -- the final boss room's biome, and the equipped weapon for the goal count. This is
        -- banked UNCONDITIONALLY, before anything about Final Challenge below -- a later
        -- Zagreus win/loss must never undo Chronos/Typhon/Hades's own AP credit.
        local route = Routes.current()
        local weapon_id = game.GameState and game.GameState.PrimaryWeaponName or nil
        if route == "Nightmare" then
          -- Nightmare's own custom run-clear function is ALSO wrapped directly (see
          -- ItemManager.handle_nightmare_run_cleared) -- route both through the same guarded
          -- handler so whichever actually fires first is the one that counts, never both.
          ItemManager.handle_nightmare_run_cleared()
        else
          LocationManager.on_run_cleared(route, weapon_id)
        end
        -- no_death_on_winning_runs: the return-to-Crossroads after a win can read as a
        -- death; flag it so the next KillHero doesn't broadcast a DeathLink.
        if ItemManager.setting_on("no_death_on_winning_runs") then
          ItemManager.won_run_pending = true
        end
        if ItemManager.goal_includes_zagreus()
           and ItemManager.zagreus_mode() == ItemManager.ZAGREUS_MODE_FINAL_CHALLENGE then
          redirect_to_zagreus = true
        end
      end)
      if redirect_to_zagreus then
        -- Final Challenge: instead of forcing a room transition ourselves, spawn the exact
        -- same "ZagContract" secret-door obstacle vanilla's SpawnZagContract (EventLogic.lua
        -- 1875) spawns, right here in Chronos'/Typhon's own boss room, at the Hero's current
        -- position (these rooms have no authored ZagContractDestinationId anchor point of
        -- their own). ZagContract InheritFrom = {"ExitDoor"} (ObstacleData.lua), so
        -- SetupObstacle wires up the normal "walk up, read the contract, get pulled into
        -- C_Boss01" interaction verbatim -- no hand-rolled LeaveRoom call, no guessing at
        -- room-transition internals. We also skip the vanilla run-clear screen entirely (no
        -- base() call below) and suppress the one KillHero that would otherwise follow it
        -- (see ItemManager.suppress_win_death / the KillHero wrap) -- that "you return to the
        -- Crossroads" is scripted as a death regardless of win/loss, and normally happens
        -- right after the run-clear screen closes; without suppressing it the player would be
        -- yanked back to the Crossroads before they ever get a chance to use the contract.
        local handled = false
        local ok, err = pcall(function()
          local currentRun = game.CurrentRun
          local obstacleData = game.ObstacleData and game.ObstacleData.ZagContract
          local roomData = game.RoomData and game.RoomData.C_Boss01
          if currentRun and currentRun.Hero and obstacleData and roomData
             and game.CreateRoom and game.AssignRoomToExitDoor and game.SpawnObstacle
             and game.SetupObstacle and game.DeepCopyTable then
            -- InterBiome is added unconditionally by Chronos'/Typhon's own kill presentation
            -- (PresentationBiomeI/Q) and normally only released by StartRoom's
            -- roomData.RemoveTimerBlock check on the NEXT normal biome room -- since the
            -- player is staying in the current room until they use the contract, release it
            -- now so timed buffs/keepsakes don't sit paused in the meantime.
            game.RemoveTimerBlock(currentRun, "InterBiome")
            local contractItem = game.DeepCopyTable(obstacleData)
            contractItem.ObjectId = game.SpawnObstacle({
              DestinationId = currentRun.Hero.ObjectId, Name = "ZagContract", Group = "Standing",
            })
            contractItem.RerollFunctionName = nil
            local nextRoom = game.CreateRoom(roomData)
            game.AssignRoomToExitDoor(contractItem, nextRoom)
            game.SetupObstacle(contractItem)
            ItemManager.suppress_win_death = true
            handled = true
            rom.log.info("[AP] Final Challenge: spawned the Zagreus contract in the boss room")
          end
        end)
        if handled then return end
        rom.log.warning("[AP] Final Challenge: spawning the Zagreus contract failed, falling back to the run-clear screen ("
          .. tostring(err) .. ")")
      end
      return base(...)
    end)
  end)

  -- Final Challenge boon-wipe root cause: SetupHeroForEnding (RoomLogic.lua) is the game's
  -- "strip the build for the ending cinematic" step -- its ClearUpgrades call empties Traits,
  -- OnFireWeapons, WeaponDataOverride, LastStands, and ManaRegenSources. It's wired into
  -- Chronos'/Typhon's boss rooms' LeavePostPresentationEvents (RoomDataI/RoomDataQ, gated on a
  -- first-ever clear), which fire for ANY door out of those rooms -- including our spawned
  -- ZagContract -- even though vanilla only ever reaches it en route to the I/Q_PostBoss01
  -- ending rooms (vanilla's own contract spawns in early F/G/O rooms, which don't carry the
  -- event). Skip the strip when the exit actually leads to the Zagreus fight; the normal ending
  -- door still runs it untouched. RunEventsGeneric calls this as (room, event.Args=nil,
  -- contextArgs={NextRoom=...}), hence the third parameter.
  pcall(function()
    modutil.mod.Path.Wrap("SetupHeroForEnding", function(base, room, args, contextArgs)
      local skip = false
      pcall(function()
        local nextRoom = contextArgs and contextArgs.NextRoom
        if nextRoom and nextRoom.Name == "C_Boss01"
           and ItemManager.goal_includes_zagreus()
           and ItemManager.zagreus_mode() == ItemManager.ZAGREUS_MODE_FINAL_CHALLENGE then
          skip = true
        end
      end)
      if skip then
        rom.log.info("[AP] Final Challenge: kept the run's build (skipped SetupHeroForEnding into C_Boss01)")
        return
      end
      return base(room, args, contextArgs)
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

    -- Apply any queued incoming DeathLink, but only when the player is in a killable,
    -- unpaused state (see ItemManager.flush_pending_deathlink). Called by table lookup so a
    -- hot-reload picks up a new version. Held DeathLinks retry themselves every few seconds.
    -- Logging failures here (like the Bridge.update() pcall above) matters: an unlogged error
    -- would silently wedge a queued DeathLink forever with zero trace in the log.
    local dl_ok, dl_err = pcall(function()
      if ItemManager.flush_pending_deathlink then ItemManager.flush_pending_deathlink() end
    end)
    if not dl_ok then rom.log.error("[AP] DeathLink flush error: " .. tostring(dl_err)) end

    -- Apply any stashed incoming items, but only on a frame where receiving is safe (not mid-boon
    -- selection / conversation / pause -- see ItemManager.receive_safe). Held payloads apply
    -- automatically once the player is back in normal control.
    pcall(function() if ItemManager.drain_pending_items then ItemManager.drain_pending_items() end end)

    -- Surface bridge-connection trouble: pinned in the corner overlay (never fades). We deliberately
    -- do NOT banner it -- the banner auto-dismisses too fast to read a diagnostic; the pinned corner
    -- line stays up until the bridge reconnects.
    local diag = Bridge.status_text and Bridge.status_text()
    if Overlay and Overlay.set_diag then Overlay.set_diag(diag) end
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
