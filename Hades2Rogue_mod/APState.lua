---@diagnostic disable: lowercase-global
-- APState.lua — persistent Archipelago progress.
--
-- Stored inside the game's GameState table, which is in the save system's
-- GlobalSaveWhitelist (SaveLogic.lua) and serialized whole into the save file.
-- That means our progress is per-save-slot and survives deaths, save-loads, and
-- our own mod reloads (the game restores GameState for us). All values are
-- plain numbers/booleans/tables so they pass the save's type validation.

APState = APState or {}

local DEFAULTS = {
  processed = 0,        -- count of received items already applied
  grasp_count = 0,      -- number of Progressive Grasp items received
  chronos_clears = 0,   -- total Chronos defeats (Underworld goal)
  typhon_clears = 0,    -- total Typhon defeats (Surface goal)
  hades_clears = 0,     -- total Hades defeats (Nightmare goal, opt-in third-party route)
  zagreus_clears = 0,   -- total Zagreus defeats (secret superboss goal)
  zagreus_weaken = 0,   -- Progressive Zagreus Weaken items received (Empowered mode)
  death_count = 0,      -- deaths since the last DeathLink was sent (deathlink_amount threshold)
  progressive_start = 0,-- Progressive Start items received (cumulative run-start buffs)
  rarity_increase = 0,  -- Rarity Increase filler items received (rarer-boon chance)
  major_finds = 0,      -- Increased Odds of Major Finds filler items (biases doors to Major Finds)
  help_odds = 0,        -- Increased Help Odds filler items received (shortens field-NPC cooldown)
  arachne_armor = 0,    -- Starting Arachne Armor items received (random armor at run start)
  medea_gift = 0,       -- Starting Medea Curse items received (random Curse at run start)
  icarus_gift = 0,      -- Starting Icarus Invention items received (random Benefit at run start)
  circe_gift = 0,       -- Starting Circe Blessing items received (random Blessing at run start)
  dionysus_gift = 0,    -- Starting Dionysus Boon items received (random signature Boon at run start)
  artemis_gift = 0,     -- Starting Artemis Boon items received (random signature Boon at run start)
  athena_gift = 0,      -- Starting Athena Boon items received (random signature Boon at run start)
  hades_gift = 0,       -- Starting Hades Boon items received (random signature Boon at run start)
  daedalus_upgrade = 0, -- Daedalus Upgrade items received (random hammer at run start)
  boon_level_bonus = 0, -- Progressive Boon Level items received (base level of leveled boons)
  max_health_items = 0, -- Max Health filler items received (+value starting max health)
  max_arcana_items = 0, -- Max Arcana filler items received (+value starting max Magick)
  gold_items = 0,       -- Gold filler items received (+value starting gold)
  armor_items = 0,      -- Armor filler items received (+value starting armor)
  starting_aspect_seeded = false, -- seed's starting Aspect written to LastWeaponUpgradeName once
                                  -- (persists in save); after that the player owns their Aspect
                                  -- choice, so we must NOT re-force it every room (swap-to-received
                                  -- -aspect bug -- see ItemManager.reassert_starting_aspect)
}

local ROUTES = { "Underworld", "Surface", "Nightmare" }

-- Returns the persistent AP table (back-filling defaults), or nil if no save
-- profile is loaded yet (e.g. at the main menu, before GameState exists).
function APState.get()
  local gs = game.GameState
  if not gs then return nil end
  local s = gs.Archipelago
  if not s then
    s = {}
    gs.Archipelago = s
  end
  for k, v in pairs(DEFAULTS) do
    if s[k] == nil then s[k] = v end
  end
  if s.vow_removals == nil then s.vow_removals = {} end       -- vow name -> levels removed
  if s.route_progress == nil then s.route_progress = {} end   -- route -> Progressive items received
  if s.weapons_cleared == nil then s.weapons_cleared = {} end -- route -> { weapon_id -> true }
  if s.score == nil then s.score = {} end                     -- route -> { points, next_check, last_depth }
  if s.aspect_progress == nil then s.aspect_progress = {} end -- weapon short-name -> Progressive Aspect count
  if s.per_aspect_progress == nil then s.per_aspect_progress = {} end -- internal aspect id -> Progressive count (aspectsanity=per_aspect)
  if s.aspect_ap_unlocked == nil then s.aspect_ap_unlocked = {} end -- internal aspect id -> true (AP granted it, or it's the seed's starting Aspect; so apply_aspect_base_lock never re-locks an earned Aspect of Melinoe -- aspectsanity=randomized)
  if s.familiar_progress == nil then s.familiar_progress = 0 end -- Progressive Familiar count
  if s.keepsake_progress == nil then s.keepsake_progress = 0 end -- Progressive Keepsake count
  if s.familiar_ap_granted == nil then s.familiar_ap_granted = {} end -- FamiliarName -> true (so the recruit block doesn't re-lock AP-granted pets)
  if s.unlocked_gods == nil then s.unlocked_gods = {} end     -- internal "<God>Upgrade" LootData key -> true (godsanity)
  if s.helper_npc_unlocked == nil then s.helper_npc_unlocked = {} end -- NPC display name -> true (helper_room_sanity items/items_random)
  if s.combat_helper_unlocked == nil then s.combat_helper_unlocked = {} end -- NPC display name -> true (combat_helper_sanity items/items_random)
  if s.keepsake_ap_granted == nil then s.keepsake_ap_granted = {} end -- keepsake trait -> true (gates equipping; gifting alone can't make it usable)
  if s.keepsake_check_sent == nil then s.keepsake_check_sent = {} end -- keepsake trait -> true (its check was sent; blocks re-gifting that NPC)
  if s.enemy_killed == nil then s.enemy_killed = {} end       -- enemy check name -> true (first-kill already sent; enemy_locations)
  if s.npc_met == nil then s.npc_met = {} end                 -- npc check name -> true (first-meet already sent; npc_locations)
  if s.combined_weapon == nil then s.combined_weapon = {} end -- weapon short-name -> Progressive <Weapon> count
  if s.weapon_ap_unlocked == nil then s.weapon_ap_unlocked = {} end -- weapon kit id -> true (AP-granted; so apply_initial_weapon won't re-lock it, Test Run 8 #4)
  -- separate_checks=combine_pools shared room pool (keyed on depth across both routes):
  -- room_high = highest depth cleared anywhere; weapon_high = per-weapon high (per_weapon).
  if s.combined_rooms == nil then s.combined_rooms = { room_high = 0, weapon_high = {} } end
  -- separate_checks=combine_pools shared POINT pool (point_based): one route-agnostic pool
  -- ("Score NNNN") that every route's cleared rooms bank into, so the whole pool can be
  -- earned on a single route. Same shape as a per-route s.score[route] entry; the per-route
  -- pools simply go unused in that mode.
  if s.combined_score == nil then
    s.combined_score = { points = 0, next_check = 1, last_depth = 0 }
  end
  for _, route in ipairs(ROUTES) do
    if s.route_progress[route] == nil then s.route_progress[route] = 0 end
    if s.weapons_cleared[route] == nil then s.weapons_cleared[route] = {} end
    if s.score[route] == nil then
      s.score[route] = { points = 0, next_check = 1, last_depth = 0 }
    end
    -- room_based / per_weapon_room_based high-water marks (per route, and per weapon).
    if s.score[route].room_high == nil then s.score[route].room_high = 0 end
    if s.score[route].weapon_high == nil then s.score[route].weapon_high = {} end
    -- Mod-maintained per-run "scored depth": increments once for each room that counts
    -- toward score (combat OR reward OR shop -- Test Run 6 #6), replacing the game's
    -- combat-only EncounterDepth. Reset to 0 at the start of every run; points/high-water
    -- marks above persist across runs as before.
    if s.score[route].depth_counter == nil then s.score[route].depth_counter = 0 end
  end
  return s
end
