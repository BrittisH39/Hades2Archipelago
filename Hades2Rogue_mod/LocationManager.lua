---@diagnostic disable: lowercase-global
-- LocationManager.lua — turns in-game progress into Archipelago location checks.
--
-- Three location systems (settings.location_system, matching the Python world):
--   0 point_based: each room cleared adds "its depth" to a points pool that persists across
--      runs/deaths; whenever the pool covers the next check's cost, that check is earned and
--      the pool draws down. separate_checks decides the pool: split_pools gives each route its
--      own ("<Route> Score NNNN"), combine_pools one shared route-agnostic pool every route
--      banks into ("Score NNNN") -- see LocationManager.score_pool_for.
--   1 room_based: the first time you clear a room at depth N (per route) earns
--      "<route> Room NNNN".
--   2 per_weapon_room_based: like room_based, but per equipped weapon -
--      "<route> Room NNNN <Weapon>".
--   3 per_aspect_room_based: like per_weapon_room_based, but per (equipped weapon, equipped
--      Aspect) pair - "<Aspect> <Weapon> <route> Room DD" (2-digit depth; Aspect+Weapon are a
--      FRONT prefix here, unlike the trailing-weapon convention of systems 1/2).

LocationManager = LocationManager or {}
-- All persistent progress lives in APState (the game save). See APState.lua.

-- combine_pools' shared room pool depth. NOT any single route's count: the shared pool has to
-- be earnable on whichever single route the player is actually on -- hence the min across
-- active routes, computed Python-side (Locations._combined_room_count) and sent as its own
-- setting. The split-pool room systems cap per ZONE instead (Routes.zone_room_count). 0 (no
-- combined room checks) until settings arrive.
local function combined_room_limit()
  return tonumber(ItemManager.settings["combined_room_count"]) or 0
end

local function pad4(n)
  return string.format("%04d", n)
end

local function pad2(n)
  return string.format("%02d", n)
end

-- Dream Dive's three cumulative counter tiers. Declared up here (rather than beside
-- send_dream_tier_check, where they used to live) because do_resync_pass below needs them too.
local DREAM_TIER_PREFIX = { regular = "Dream Enemy", miniboss = "Dream Miniboss", boss = "Dream Boss" }
local DREAM_TIER_PAD = { regular = pad4, miniboss = pad2, boss = pad2 }
-- How many locations of each tier this seed actually generated (Locations.fill_dream_checks'
-- dream_enemy_count / dream_miniboss_count / dream_boss_count, sent verbatim in SETTINGS).
local DREAM_TIER_COUNT_KEY = {
  regular = "dream_enemy_count", miniboss = "dream_miniboss_count", boss = "dream_boss_count",
}
-- The tier's real location count, or nil when the setting hasn't arrived (treated as "no cap
-- known" -- don't block sends on a missing setting, same not-over-blocking convention used for
-- route gating elsewhere in this file).
function LocationManager.dream_tier_limit(tier)
  local key = DREAM_TIER_COUNT_KEY[tier]
  return key and tonumber(ItemManager.settings[key]) or nil
end

-- How many distinct species this tier has banked, i.e. the highest counter number earned.
local function dream_tier_count(s, tier)
  local seen = s and s.dream_species_seen and s.dream_species_seen[tier]
  if not seen then return 0 end
  local count = 0
  for _ in pairs(seen) do count = count + 1 end
  return count
end

-- Build a zone-relative room / per-weapon check name, matching the Python world's
-- Locations._room_name: "<Route> <Zone> Room NN[ +k][ Weapon]". local_depth is the depth
-- WITHIN zone_index (1..Routes.zone_room_count), not a route-wide running depth. slot 0 keeps
-- the bare name; slots >0 append " +k"; any weapon stays the LAST token so the rules'
-- last-token weapon parsing keeps working.
local function room_name(route, zone_index, local_depth, slot, weapon)
  local zone_display = Routes.zone_display_for(route, zone_index) or ""
  local name = route .. " " .. zone_display .. " Room " .. pad2(local_depth)
  if slot and slot > 0 then name = name .. " +" .. slot end
  if weapon then name = name .. " " .. weapon end
  return name
end

-- per_aspect_room_based equivalent: "<Aspect> <Weapon> <Route> <Zone> Room NN[ +k]" --
-- Aspect+Weapon are a FRONT prefix (unlike room_name's trailing weapon).
local function aspect_room_name(route, zone_index, local_depth, slot, weapon, aspect_key)
  local zone_display = Routes.zone_display_for(route, zone_index) or ""
  local name = aspect_key .. " " .. weapon .. " " .. route .. " " .. zone_display
    .. " Room " .. pad2(local_depth)
  if slot and slot > 0 then name = name .. " +" .. slot end
  return name
end

-- combine_pools' shared pool keeps the ROUTE-AGNOSTIC, route-wide-depth "Room NNNN" shape
-- (Locations._flat_room_name) -- it has no zone identity of its own, and is deliberately out
-- of scope for the per-zone renumbering.
local function combined_room_name(depth, slot, weapon)
  local name = Routes.COMBINED_ROOM_PREFIX .. " " .. pad4(depth)
  if slot and slot > 0 then name = name .. " +" .. slot end
  if weapon then name = name .. " " .. weapon end
  return name
end

local function combined_aspect_room_name(depth, slot, weapon, aspect_key)
  local name = aspect_key .. " " .. weapon .. " " .. Routes.COMBINED_ROOM_PREFIX .. " " .. pad2(depth)
  if slot and slot > 0 then name = name .. " +" .. slot end
  return name
end

-- Send every location-multiplier "slot" check for one cleared room depth (location
-- auto-scaling). Each depth grants m checks: slot 0 is the bare name, slots 1..m-1 the " +k"
-- variants, weapon (if any) staying last. Returns the count sent. Used by BOTH the live
-- room-clear hooks and the boss cascade so they scale identically.
local function send_room_slots(route, zone_index, local_depth, weapon)
  local m = ItemManager.location_multiplier()
  for slot = 0, m - 1 do
    local check = room_name(route, zone_index, local_depth, slot, weapon)
    rom.log.info("[AP] check: " .. check .. " (zone " .. tostring(zone_index)
      .. " room " .. local_depth .. " slot " .. slot
      .. (weapon and (" " .. weapon) or "") .. ")")
    Bridge.send_check(check)
  end
  return m
end

-- per_aspect_room_based equivalent of send_room_slots.
local function send_aspect_room_slots(route, zone_index, local_depth, weapon, aspect_key)
  local m = ItemManager.location_multiplier()
  for slot = 0, m - 1 do
    local check = aspect_room_name(route, zone_index, local_depth, slot, weapon, aspect_key)
    rom.log.info("[AP] check: " .. check .. " (zone " .. tostring(zone_index)
      .. " room " .. local_depth .. " slot " .. slot
      .. " " .. weapon .. " " .. aspect_key .. ")")
    Bridge.send_check(check)
  end
  return m
end

-- combine_pools counterparts (flat, route-wide depth).
local function send_combined_room_slots(depth, weapon)
  local m = ItemManager.location_multiplier()
  for slot = 0, m - 1 do
    local check = combined_room_name(depth, slot, weapon)
    rom.log.info("[AP] check: " .. check .. " (combined room " .. depth .. " slot " .. slot
      .. (weapon and (" " .. weapon) or "") .. ")")
    Bridge.send_check(check)
  end
  return m
end

local function send_combined_aspect_room_slots(depth, weapon, aspect_key)
  local m = ItemManager.location_multiplier()
  for slot = 0, m - 1 do
    local check = combined_aspect_room_name(depth, slot, weapon, aspect_key)
    rom.log.info("[AP] check: " .. check .. " (combined room " .. depth .. " slot " .. slot
      .. " " .. weapon .. " " .. aspect_key .. ")")
    Bridge.send_check(check)
  end
  return m
end

-- point_based draw-down / skip pass. Walks next_check upward, deciding each one:
--   * already checked on the server (CHECKEDSCORE) -> advance for FREE (no points, no resend)
--   * enough points banked              -> spend points and send the CHECK
--   * otherwise                          -> stop (wait for more depth)
-- Gap-safe: a checked 0017 while 0015 is unchecked only frees 0017 when next_check reaches it;
-- it never skips the unchecked 0015. Reusable so the CHECKEDSCORE handler (reload.lua) can
-- advance immediately when a check JUST became checked, without waiting for a room clear.
-- Every pool holds the full score_rewards_amount: split_pools gives each route its own,
-- combine_pools has one shared route-agnostic pool (see LocationManager.score_pool_for).
function LocationManager.score_skip_pass(pool_key, pool)
  local limit = ItemManager.score_limit_for(pool_key)
  while pool.next_check <= limit do
    if ItemManager.is_score_checked(pool_key, pool.next_check) then
      pool.next_check = pool.next_check + 1            -- already sent on the server: free skip
    elseif pool.points >= pool.next_check then
      pool.points = pool.points - pool.next_check
      local check = Routes.SCORE_PREFIX[pool_key] .. " " .. pad4(pool.next_check)
      rom.log.info("[AP] check: " .. check .. " (" .. pool_key .. ")")
      Bridge.send_check(check)
      pool.next_check = pool.next_check + 1
    else
      break
    end
  end
end

-- Which point_based pool a route's cleared rooms bank into, as (pool_key, pool).
--   split_pools:   that route's own pool -> "<Route> Score NNNN".
--   combine_pools: ONE shared route-agnostic pool -> "Score NNNN". Every active route feeds
--     the same points and the same next_check, so the whole pool is earnable on a single
--     route (Python: Locations.combined_score_table / Rules._set_combined_score_rules).
-- The per-route s.score[route] pools simply go unused under combine_pools (and vice versa),
-- so switching the option mid-seed can't corrupt either -- though it would strand progress.
function LocationManager.score_pool_for(route, s)
  if ItemManager.combine_active() then
    return Routes.COMBINED_SCORE_KEY, s.combined_score
  end
  return route, s.score[route]
end

-- Shared body for the one-time-per-save recovery passes below: re-queue (via Bridge.send_check,
-- so it's subject to the same reliable-delivery guarantee as a live check) every check the
-- mod's OWN bookkeeping believes has already been earned. Safe to run even when nothing was
-- ever lost: the AP server ignores a check it already has, and Bridge.send_check's own
-- per-name dedup means queuing something already pending is a no-op.
-- ROUTES here (not just the original 3) matters: Dream was missing from this list until 8/5,
-- so any Dream room/score progress banked before that fix was silently excluded from recovery
-- too -- see [[project_dream_depth_counter_never_reset_fix]].
local RESYNC_ROUTES = { "Underworld", "Surface", "Nightmare", "Dream" }
local function do_resync_pass(s)
  local queued = 0

  -- Dedup-set checks: the key IS the exact check name already (send_first stores it verbatim).
  for name in pairs(s.enemy_killed) do Bridge.send_check(name); queued = queued + 1 end
  for name in pairs(s.npc_met) do Bridge.send_check(name); queued = queued + 1 end
  for giftName in pairs(s.keepsake_check_sent) do
    local check = ItemManager.KEEPSAKE_TRAIT_TO_CHECK and ItemManager.KEEPSAKE_TRAIT_TO_CHECK[giftName]
    if check then Bridge.send_check(check); queued = queued + 1 end
  end
  -- Dream's three cumulative counters. Unlike every other dedup set above, these don't STORE
  -- their check names -- dream_species_seen holds species, and the check earned is the running
  -- COUNT ("Dream Enemy 0001".."NNNN"), so the names have to be rebuilt from that count. They
  -- were missing from this pass entirely, which meant a Dream Enemy/Miniboss/Boss check lost to
  -- a disconnect was marked earned in the save and then never replayed by anything.
  if ItemManager.route_active("Dream") then
    for tier in pairs(s.dream_species_seen or {}) do
      local limit = LocationManager.dream_tier_limit(tier)
      local count = dream_tier_count(s, tier)
      if limit then count = math.min(count, limit) end
      for i = 1, count do
        Bridge.send_check(DREAM_TIER_PREFIX[tier] .. " " .. DREAM_TIER_PAD[tier](i))
        queued = queued + 1
      end
    end
  end

  -- Room-based / per_weapon_room_based / per_aspect_room_based (systems 1-3): replay every
  -- depth up to each high-water mark. send_room_slots/send_aspect_room_slots already cover
  -- every location_multiplier slot per depth, matching exactly how the names were first built.
  local system = ItemManager.setting_mode("location_system")
  if system == 1 or system == 2 or system == 3 then
    if ItemManager.combine_active() then
      local cr = s.combined_rooms
      for depth = 1, (cr.room_high or 0) do queued = queued + send_combined_room_slots(depth) end
      for weapon, high in pairs(cr.weapon_high or {}) do
        for depth = 1, high do queued = queued + send_combined_room_slots(depth, weapon) end
      end
      for key, high in pairs(cr.aspect_high or {}) do
        local weapon, aspect_key = key:match("^(.-)|(.*)$")
        if weapon and aspect_key then
          for depth = 1, high do
            queued = queued + send_combined_aspect_room_slots(depth, weapon, aspect_key)
          end
        end
      end
    else
      -- Split pools: high-water marks are per ZONE, so replay walks each zone's own 1..high
      -- (keys are "<zone>", "<zone>|<weapon>", "<zone>|<weapon>|<aspect>" -- see on_room_room
      -- and friends). tonumber() on the zone key because Lua table keys round-trip as strings
      -- through the save serializer.
      for _, route in ipairs(RESYNC_ROUTES) do
        local pool = s.score[route]
        if pool and ItemManager.route_active(route) then
          for zone_index, high in pairs(pool.zone_room_high or {}) do
            local z = tonumber(zone_index)
            if z then
              for depth = 1, high do queued = queued + send_room_slots(route, z, depth) end
            end
          end
          for key, high in pairs(pool.zone_weapon_high or {}) do
            local z, weapon = key:match("^(%d+)|(.*)$")
            z = tonumber(z)
            if z and weapon then
              for depth = 1, high do queued = queued + send_room_slots(route, z, depth, weapon) end
            end
          end
          for key, high in pairs(pool.zone_aspect_high or {}) do
            local z, weapon, aspect_key = key:match("^(%d+)|(.-)|(.*)$")
            z = tonumber(z)
            if z and weapon and aspect_key then
              for depth = 1, high do
                queued = queued + send_aspect_room_slots(route, z, depth, weapon, aspect_key)
              end
            end
          end
        end
      end
    end
  elseif system == 0 then
    -- point_based: replay every number below next_check, skipping ones the server has already
    -- confirmed (CHECKEDSCORE) purely to cut queue noise -- resending those would be harmless too.
    if ItemManager.combine_active() then
      local pool = s.combined_score
      for n = 1, (pool.next_check or 1) - 1 do
        if not ItemManager.is_score_checked(Routes.COMBINED_SCORE_KEY, n) then
          Bridge.send_check(Routes.SCORE_PREFIX[Routes.COMBINED_SCORE_KEY] .. " " .. pad4(n))
          queued = queued + 1
        end
      end
    else
      for _, route in ipairs(RESYNC_ROUTES) do
        local pool = s.score[route]
        if pool and ItemManager.route_active(route) then
          for n = 1, (pool.next_check or 1) - 1 do
            if not ItemManager.is_score_checked(route, n) then
              Bridge.send_check(Routes.SCORE_PREFIX[route] .. " " .. pad4(n))
              queued = queued + 1
            end
          end
        end
      end
    end
  end

  return queued
end

-- v1: exists to recover checks lost BEFORE Bridge.send_check existed -- back when a check was
-- marked done in APState the instant it was earned, with the actual Bridge.send call's
-- success/failure never checked, so a check earned during a disconnect (or the gap around a
-- mid-run mod update) was marked sent forever with nothing having actually reached the client.
-- Gated by s.resync_v1_done (see APState.lua), which ItemManager.reset_applied() clears in
-- lockstep with the bookkeeping this reads -- so a save reused for a genuinely different seed
-- gets one fresh pass against that seed's own zeroed state, never a replay of the old one's.
function LocationManager.resync_all_checks()
  local s = APState.get()
  if not s or s.resync_v1_done then return end
  s.resync_v1_done = true
  local queued = do_resync_pass(s)
  rom.log.info("[AP] resync: re-queued " .. queued .. " previously-earned check(s) for delivery confirmation")
end

-- point_based: accumulate depth into the pool and draw down per earned check.
local function on_room_point(route, depth, s)
  local pool_key, pool = LocationManager.score_pool_for(route, s)
  if not pool then return end
  if depth <= 1 then pool.last_depth = 0 end       -- fresh run
  if depth <= pool.last_depth then return end       -- already scored this room
  pool.last_depth = depth
  pool.points = pool.points + depth

  LocationManager.score_skip_pass(pool_key, pool)

  -- Wishlist "Score X/Y" readout: after clearing a room, pin the pool vs the next check's
  -- cost at the top of the overlay (always visible, never fades -- Test Run 6 #1). The
  -- "Sent Score Check N - ..." line comes from the client's CHECKED echo (see reload.lua).
  local limit = ItemManager.score_limit_for(pool_key)
  if Overlay and Overlay.set_score and pool.next_check <= limit then
    Overlay.set_score("Score " .. pool.points .. "/" .. pool.next_check, Overlay.COLOR.score)
  end
end

-- room_based: send "<Route> <Zone> Room NN" (+ its " +k" multiplier slots) the first time that
-- many rooms are cleared INSIDE zone_index, in one run. High-water is tracked per zone
-- (pool.zone_room_high[zone_index]) rather than one number per route, so each zone's checks
-- are earned by playing that zone -- which is exactly what the AP logic gates them on.
-- Returns the zone's high-water mark AFTER this call (whether or not a check was actually sent
-- this time).
local function on_room_room(route, zone_index, local_depth, pool)
  local limit = Routes.zone_room_count(route, zone_index)
  pool.zone_room_high = pool.zone_room_high or {}
  local high_before = pool.zone_room_high[zone_index] or 0
  if local_depth <= limit and local_depth > high_before then
    pool.zone_room_high[zone_index] = local_depth
    send_room_slots(route, zone_index, local_depth)
  else
    -- Diagnostic (8/5): room-based checks send only when THIS depth beats the zone's lifetime
    -- high-water mark (it persists across runs/deaths by design -- Test Run 6 #6). Log the
    -- no-send case so a zone that silently never earns a check (e.g. an old save whose mark is
    -- already above what today's runs reach) is visible instead of invisible.
    rom.log.info("[AP] room_based: " .. route .. " zone=" .. tostring(zone_index)
      .. " depth=" .. local_depth .. " did NOT beat zone high=" .. high_before
      .. " (limit=" .. limit .. ") - no check sent")
  end
  return pool.zone_room_high[zone_index] or 0
end

-- per_weapon_room_based: same per-zone counting as on_room_room, tracked per
-- "<zone>|<weapon>". Returns that pair's high-water mark (nil if no weapon is equipped).
local function on_room_per_weapon(route, zone_index, local_depth, pool)
  local weapon = ItemManager.current_weapon_short()
  if not weapon then return nil end
  pool.zone_weapon_high = pool.zone_weapon_high or {}
  local key = zone_index .. "|" .. weapon
  local limit = Routes.zone_room_count(route, zone_index)
  if local_depth <= limit and local_depth > (pool.zone_weapon_high[key] or 0) then
    pool.zone_weapon_high[key] = local_depth
    send_room_slots(route, zone_index, local_depth, weapon)
  end
  return pool.zone_weapon_high[key] or 0
end

-- per_aspect_room_based: same per-zone counting, tracked per "<zone>|<weapon>|<aspect_key>".
-- Returns that triple's high-water mark (nil if no weapon/Aspect equipped).
local function on_room_per_aspect(route, zone_index, local_depth, pool)
  local weapon, aspect_key = ItemManager.current_aspect_key()
  if not weapon or not aspect_key then return nil end
  pool.zone_aspect_high = pool.zone_aspect_high or {}
  local key = zone_index .. "|" .. weapon .. "|" .. aspect_key
  local limit = Routes.zone_room_count(route, zone_index)
  if local_depth <= limit and local_depth > (pool.zone_aspect_high[key] or 0) then
    pool.zone_aspect_high[key] = local_depth
    send_aspect_room_slots(route, zone_index, local_depth, weapon, aspect_key)
  end
  return pool.zone_aspect_high[key] or 0
end

-- combine_pools room_based: one SHARED "Room NNNN" pool keyed on depth only. The first
-- time depth N is cleared on EITHER route earns it (dedup via the shared high-water mark).
-- Returns the shared high-water mark after this call.
local function on_room_room_combined(depth)
  local s = APState.get()
  local cr = s.combined_rooms
  local limit = combined_room_limit()
  if depth <= limit and depth > (cr.room_high or 0) then
    cr.room_high = depth
    send_combined_room_slots(depth)
  end
  return cr.room_high or 0
end

-- combine_pools per_weapon_room_based: shared "Room NNNN <Weapon>" pool, per-weapon
-- high-water shared across routes. Returns that weapon's shared high-water mark.
local function on_room_per_weapon_combined(depth)
  local weapon = ItemManager.current_weapon_short()
  if not weapon then return nil end
  local s = APState.get()
  local cr = s.combined_rooms
  cr.weapon_high = cr.weapon_high or {}
  local limit = combined_room_limit()
  if depth <= limit and depth > (cr.weapon_high[weapon] or 0) then
    cr.weapon_high[weapon] = depth
    send_combined_room_slots(depth, weapon)
  end
  return cr.weapon_high[weapon] or 0
end

-- combine_pools per_aspect_room_based: shared "<Aspect> <Weapon> Room DD" pool, per-(weapon,
-- Aspect) high-water shared across routes. Returns that pair's shared high-water mark.
local function on_room_per_aspect_combined(depth)
  local weapon, aspect_key = ItemManager.current_aspect_key()
  if not weapon or not aspect_key then return nil end
  local s = APState.get()
  local cr = s.combined_rooms
  cr.aspect_high = cr.aspect_high or {}
  local key = weapon .. "|" .. aspect_key
  local limit = combined_room_limit()
  if depth <= limit and depth > (cr.aspect_high[key] or 0) then
    cr.aspect_high[key] = depth
    send_combined_aspect_room_slots(depth, weapon, aspect_key)
  end
  return cr.aspect_high[key] or 0
end

-- Push the overlay's pinned "Room ##" readout to match the number the room-check logic itself
-- just used (user's explicit call -- previously this was a separate literal "rooms entered"
-- counter, native_room_counter/track_native_room, now removed; see reload.lua/Overlay.lua).
-- The number is THIS RUN's counter from advance_depth, read straight off `pool` -- the
-- zone-local depth for split pools, the route-wide depth for combine_pools -- i.e. the NN of
-- the check the last scored room earned (or re-earned). It used to be the lifetime high-water
-- mark instead, but that mark is raised to the zone's full count the first time the zone's boss
-- dies (on_zone_boss_defeated) and to the shared limit by the goal cascade (flush_route_checks),
-- so from then on the readout sat at "Region 1 Room 12" for the whole zone no matter which room
-- the player was actually in.
-- Capped at the number of checks that exist (a zone can score more encounters than it has room
-- checks -- an Olympus-shaped Dream region runs to 17-18 against 12), so the readout never names
-- a check that isn't in the seed.
-- Called on every scored room AND on every room entry (score_room), so the zone half follows
-- the player into a new zone at once; until something scores there it shows the zone alone.
-- combine_pools' shared pool has no per-route zone identity of its own (its check names stay
-- flat "Room NNNN", out of scope for the per-zone renumbering), so it shows a bare number
-- instead of a zone label. point_based (system 0) never calls this -- Score checks are out of
-- scope.
local function update_room_overlay(route, zone_index, pool, combine)
  if not pool or not (Overlay and Overlay.set_room) then return end
  if combine then
    local n = math.min(pool.depth_counter or 0, combined_room_limit())
    if n > 0 then Overlay.set_room("Room " .. n) end
    return
  end
  local zone_display = Routes.zone_display_for(route, zone_index)
  if not zone_display then return end
  local n = math.min(pool.zone_depth and pool.zone_depth[zone_index] or 0,
    Routes.zone_room_count(route, zone_index))
  Overlay.set_room(n > 0 and (zone_display .. " Room " .. n) or zone_display)
end

-- Advance this run's depth counters for one scored room/encounter. Returns:
--   depth       -- route-wide depth this run (still needed by point_based, which scores a room
--                  by how deep into the RUN it is, and by combine_pools' flat shared pool)
--   local_depth -- depth within `zone` this run (nil if the room has no routable zone), which
--                  is what the per-zone room checks are named and gated on
-- Both reset every run (ItemManager.apply_progressive_start); the high-water marks the checks
-- actually key on persist across runs.
local function advance_depth(pool, zone)
  pool.depth_counter = (pool.depth_counter or 0) + 1
  -- zone < 1 is not a real zone (see Routes.zone_display_for) -- 0 is truthy in Lua, so this
  -- has to be an explicit range test, not just a nil check.
  if not zone or zone < 1 then return pool.depth_counter, nil end
  pool.zone_depth = pool.zone_depth or {}
  pool.zone_depth[zone] = (pool.zone_depth[zone] or 0) + 1
  return pool.depth_counter, pool.zone_depth[zone]
end

-- Route one scored room/encounter to the right location system, then refresh the overlay.
-- Shared by score_room and score_encounter so the two can't drift apart.
local function dispatch_room_score(route, zone, depth, local_depth, pool, s, system)
  local combine = ItemManager.combine_active()
  if system == 0 then
    on_room_point(route, depth, s)      -- picks the per-route or shared pool itself
    return
  end
  -- Split pools name checks "<Route> <Zone> Room NN", so a room with no routable zone (the
  -- Zagreus' Journey "Challenge" roomset carries no zone index) can't be named at all -- skip
  -- rather than invent one. combine_pools is zone-agnostic and is unaffected.
  if not combine and not local_depth then
    rom.log.info("[AP] score: " .. route .. " room has no zone index - no per-zone room check")
    return
  end
  if system == 1 then
    if combine then on_room_room_combined(depth)
    else on_room_room(route, zone, local_depth, pool) end
  elseif system == 2 then
    if combine then on_room_per_weapon_combined(depth)
    else on_room_per_weapon(route, zone, local_depth, pool) end
  elseif system == 3 then
    if combine then on_room_per_aspect_combined(depth)
    else on_room_per_aspect(route, zone, local_depth, pool) end
  end
  update_room_overlay(route, zone, pool, combine)
end

-- Combat = an Encounter whose EncounterType isn't "NonCombat" (EncounterData.lua). Resolve
-- EncounterType through EncounterData for inherited encounters. Shared by room_has_combat
-- (room.Encounter, used for the reward/shop gate) and score_encounter (any individual
-- encounter instance, including the extra ones in a multi-encounter room).
local function encounter_is_combat(enc)
  if not enc then return false end
  local etype = enc.EncounterType
    or (enc.Name and game.EncounterData and game.EncounterData[enc.Name]
        and game.EncounterData[enc.Name].EncounterType)
  return etype ~= nil and etype ~= "NonCombat"
end

-- A room counts toward score if it has a COMBAT encounter, OR grants a REWARD, OR is a SHOP
-- (Test Run 6 #6 -- the pre-boss reward room and shops should score, not just combat rooms).
-- reward = room.ChosenRewardType is set; shop = room.Store exists or its reward type is "Shop"
-- (RoomLogic.lua:278). Pure transition/hub rooms (no encounter, no reward, no store) used to
-- never score -- ruled 8/4 that they should too (every room entered in an active, unlocked
-- zone is a location, not just the ones that happen to fight something or pay out), so
-- score_room no longer gates on room_qualifies_for_score -- see its call site.
local function room_has_combat(room)
  return encounter_is_combat(room and room.Encounter)
end

-- room.Store isn't a reliable "this is a real shop" signal on its own: post-boss rest
-- rooms (F_PostBoss01 / G / H / Dream biomes) carry a static ForceWellShop/ForceSellShop
-- RoomData flag that makes the game's IsWellShopEligible() short-circuit true on EVERY
-- visit (RoomLogic.lua), so room.Store gets populated even when the kiosk itself never
-- activates. That kiosk is separately gated on GameState.WorldUpgrades
-- .WorldUpgradePostBossWellShops / .WorldUpgradePostBossSellTraitShops (both AP items --
-- "Surge of Stygian Wells" / "Surge of Desecrating Pools" in ItemManager.WORLD_UPGRADE_ITEMS)
-- -- check that instead of trusting room.Store for these rooms.
local function room_is_shop(room)
  if room == nil then return false end
  if room.ChosenRewardType == "Shop" then return true end
  if room.Store == nil then return false end
  if room.ForceWellShop or room.ForceSellShop then
    local wu = game.GameState and game.GameState.WorldUpgrades
    return wu ~= nil and (wu.WorldUpgradePostBossWellShops == true
      or wu.WorldUpgradePostBossSellTraitShops == true)
  end
  return true
end
-- Exposed publicly: ItemManager's Zagreus-contract-in-every-shop feature
-- (see reload.lua's StartRoom hook) reuses this same real-shop check.
LocationManager.room_is_shop = room_is_shop

-- =============================================================================
-- enemysanity / npc_locations  (More Locations.txt)
-- =============================================================================

-- Every enemy first-defeat check, by bare enemy name, grouped by owning route. The AP
-- location is "<Enemy> Defeated" (the " Defeated" suffix is added at send time); these bare
-- names mirror the Python world's ENEMY_LAYERS so unit-id matching stays simple. A check
-- only exists in the seed when its route is active (Python enemy_locations_for), so sends
-- are gated per route -- see ROUTE_GATED_CHECKS below. The 12 names Nightmare shares with the
-- Underworld roster live in the Underworld list and get dual-route membership via
-- SHARED_ENEMY_CHECKS (mirrors Python Locations.SHARED_ENEMY_ZONES).
local ENEMY_CHECKS_BY_ROUTE = {
  Underworld = {
    "Casket", "Lanthorn", "Sister of the Dead", "Spindle", "Wailer", "Wastrel",
    "Whisper", "Thorn-Weeper", "Root-Stalker", "Shadow-Spiller", "Headmistress Hecate",
    "Master-Slicer",
    "Hippo", "Lurker", "Pinhead", "Sea-Serpent", "Shellback", "Sop-Spindle",
    "Wet-Whisper", "Wretched Pest", "Deep Serpent", "Hellifish", "King Vermin",
    "Scylla", "Roxy", "Jetty",
    -- Asphodel (Anomaly detour) -- shares the Oceanus sphere (Test Run 5 #13)
    "Wretched Witch", "Bloodless", "Bone-Raker", "Wave-Maker", "Inferno-Bomber",
    "Slam-Dancer", "Burn-Flinger",
    -- Dread-Wailer (Screamer2) really spawns in Mourning Fields (Biome H), not Erebus --
    -- see Locations.py ENEMY_LAYERS comment.
    "Bawlder", "Blight-Shade", "Bloat-Shade", "Blood-Shade", "Canine", "Holeheart",
    "Lamia", "Lycaon", "Mourner", "Smacker", "Sorrow-Spiller", "Phantom",
    "Queen Lamia", "Brush-Stalker", "Infernal Beast", "Dread-Wailer",
    "Crawler", "Goldwraith", "Numbskull", "Sandskull", "Satyr Hoplite",
    "Satyr Supplicant", "Satyr Vierophant", "Tempus", "Wretched Thug", "Goldwrath",
    "The Verminancer", "Wringer", "Chronos",
  },
  Surface = {
    "Bronzebeak", "Cutthroat", "Eidolon", "Lubber", "Shambler", "Tombstone",
    "Satyr Champion", "Erymanthian Boar", "The Cyclops Polyphemus",
    "Anchor", "Blasket", "Boozer", "Droplet", "Harpy Talon", "Sea-Shambler",
    "Seesword", "Stickler", "Charybdis", "The Yargonaut", "Eris",
    "Auto-Forcer", "Auto-Seeker", "Auto-Watcher", "Harpy Raptor", "Satyr Goldpike",
    "Satyr Raider", "Satyr Sapper", "Sky-Dracon", "Snow-Shambler", "Mega-Dracon",
    "Talos", "Prometheus",
    "Eyesore", "Headstone", "Horror", "Land-Dracon", "Polyp", "Stalker",
    "Eye of Typhon", "Spawn of Typhon", "Tail of Typhon", "Twins of Typhon", "Typhon",
  },
  -- Nightmare (opt-in third-party "Zagreus' Journey" route). Real unit ids for most of these
  -- are in ENEMY_UNIT_OVERRIDE below (verified July 11); identity holds only for
  -- Theseus/Hades.
  Nightmare = {
    "Skullomat", "Wretched Lout", "Brimstone", "Dire Inferno-Bomber", "Doomstone",
    "Wretched Sneak", "Megaera", "Alecto", "Tisiphone",
    "Spreader", "Voidstone", "Skull-Crusher", "Gorgon", "Dracon", "Megagorgon",
    "Dire Spreader", "Bone Hydra",
    "Splitter", "Nemean Chariot", "Flame Wheel", "Brightsword", "Longspear",
    "Strongbow", "Greatshield", "Soul Catcher", "Theseus", "Asterius",
    "Gigantic Vermin", "Bother", "Snakestone", "Satyr Cultist", "Hades",
  },
}
-- Exposed for EnemySanity.lua (per-route roster for pure_random pool-building / shuffle-map
-- validation). Read-only in practice -- nothing outside this file should mutate it.
LocationManager.ENEMY_CHECKS_BY_ROUTE = ENEMY_CHECKS_BY_ROUTE

-- Mirrors Python Locations.SHARED_ENEMY_ZONES: as of July 18 these checks exist only when
-- the NIGHTMARE route is in the seed (see the ROUTE_GATED_CHECKS loop below) -- but when it
-- is, a kill on either route still satisfies them.
local SHARED_ENEMY_CHECKS = {
  "Numbskull", "Wringer", "Wretched Thug", "Crawler", "Wretched Witch", "Wretched Pest",
  "Bloodless", "Bone-Raker", "Wave-Maker", "Inferno-Bomber", "Slam-Dancer", "Burn-Flinger",
}
LocationManager.SHARED_ENEMY_CHECKS = SHARED_ENEMY_CHECKS

-- King Vermin is a miniboss on both routes (Oceanus' G_MiniBoss02, Styx's HadesCrawlerMiniBoss).
-- Mirrors Python Locations.KING_VERMIN_LOCATION: an Underworld Oceanus check that moves to
-- Nightmare's Styx when only Nightmare is in the seed. Exists when either route is; a kill on
-- either route sends it.
local KING_VERMIN_CHECK = "King Vermin"
LocationManager.KING_VERMIN_CHECK = KING_VERMIN_CHECK

-- ⚠ In-game unit ids (the `.Name` on a slain unit / EnemyData key) usually DON'T match the
-- AP display names above. Map the real id -> AP check name here. When enemysanity is a
-- "_plus_locations" mode
-- and an unmapped enemy dies, on_enemy_killed() logs its real id ONCE so you can fill this
-- table by playing. Identity (unit id == AP name) is assumed for anything not overridden.
-- Built from the game's own data (HelpText.en.sjson Id->DisplayName + CodexData unit lists,
-- June 27). Key = the spawned unit's `.Name` (EnemyData/UnitSetData key); value = AP check.
-- Enemies whose unit key already equals the AP name (Crawler, Stalker, Lamia, Mourner,
-- Stickler, Talos, Charybdis, Chronos, Eris, Prometheus, Wringer) are handled by identity below.
LocationManager.ENEMY_UNIT_OVERRIDE = LocationManager.ENEMY_UNIT_OVERRIDE or {
  ["AutomatonBeamer"] = "Auto-Watcher",
  ["AutomatonEnforcer"] = "Auto-Forcer",
  -- Asphodel "Anomaly" detour foes (Test Run 5 #13). Both the base and _Elite spawns map to
  -- the same AP check so either variant counts as the first defeat.
  ["SpreadShotUnit"] = "Wretched Witch",
  ["SpreadShotUnit_Elite"] = "Wretched Witch",
  ["BloodlessNaked"] = "Bloodless",
  ["BloodlessNaked_Elite"] = "Bloodless",
  ["BloodlessBerserker"] = "Bone-Raker",
  ["BloodlessBerserker_Elite"] = "Bone-Raker",
  ["BloodlessWaveFist"] = "Wave-Maker",
  ["BloodlessWaveFist_Elite"] = "Wave-Maker",
  ["BloodlessGrenadier"] = "Inferno-Bomber",
  ["BloodlessGrenadier_Elite"] = "Inferno-Bomber",
  ["BloodlessSelfDestruct"] = "Slam-Dancer",
  ["BloodlessSelfDestruct_Elite"] = "Slam-Dancer",
  ["BloodlessPitcher"] = "Burn-Flinger",
  ["BloodlessPitcher_Elite"] = "Burn-Flinger",
  ["Boar"] = "Erymanthian Boar",   -- City of Ephyra miniboss (spawned unit .Name is "Boar")
  ["Brawler"] = "Wastrel",
  ["BrokenHearted"] = "Smacker",
  ["Brute"] = "Horror",
  ["Brute_Miniboss"] = "Spawn of Typhon",
  ["Captain"] = "The Yargonaut",
  ["Carrion"] = "Bronzebeak",
  ["ClockworkHeavyMelee"] = "Wretched Thug",
  ["CorruptedShadeLarge"] = "Bloat-Shade",
  ["CorruptedShadeMedium"] = "Blood-Shade",
  ["CorruptedShadeSmall"] = "Blight-Shade",
  ["CrawlerMiniboss"] = "King Vermin",
  ["DespairElemental"] = "Bawlder",
  ["Dragon"] = "Sky-Dracon",
  ["DragonBurrower"] = "Land-Dracon",
  ["Dragon_MiniBoss"] = "Mega-Dracon",
  ["Drunk"] = "Boozer",
  ["EarthElemental"] = "Headstone",
  ["FishSwarmer"] = "Pinhead",
  ["FishmanMelee"] = "Lurker",
  ["FishmanRanged"] = "Hippo",
  ["FogEmitter"] = "Shadow-Spiller",
  ["FogEmitter2"] = "Sorrow-Spiller",
  ["GoldElemental"] = "Goldwraith",
  ["GoldElemental_MiniBoss"] = "Goldwrath",
  ["Guard"] = "Whisper",
  ["Guard2"] = "Wet-Whisper",
  ["HarpyCutter"] = "Harpy Talon",
  ["HarpyDropper"] = "Harpy Raptor",
  ["Hecate"] = "Headmistress Hecate",
  ["InfestedCerberus"] = "Infernal Beast",
  ["Lamia_Miniboss"] = "Queen Lamia",
  ["LightRanged"] = "Sister of the Dead",
  ["Lovesick"] = "Holeheart",
  ["LycanSwarmer"] = "Canine",
  ["Lycanthrope"] = "Lycaon",
  ["Mage"] = "Casket",
  ["Mage2"] = "Blasket",
  ["Mati"] = "Eyesore",
  ["Mudman"] = "Eidolon",
  ["Octofish_Miniboss"] = "Hellifish",
  ["Polyphemus"] = "The Cyclops Polyphemus",
  ["Radiator"] = "Spindle",
  ["Radiator2"] = "Sop-Spindle",
  ["SatyrCrossbow"] = "Satyr Champion",
  ["SatyrCrossbow2"] = "Satyr Raider",
  ["SatyrCultist"] = "Satyr Supplicant",
  ["SatyrLancer"] = "Satyr Hoplite",
  ["SatyrLancer2"] = "Satyr Goldpike",
  ["SatyrRatCatcher"] = "Satyr Vierophant",
  ["SatyrRatCatcher_Miniboss"] = "The Verminancer", -- own HelpText entry, not base "Satyr Vierophant"
  ["SatyrSapper"] = "Satyr Sapper",
  ["Scimiterror"] = "Seesword",
  ["Screamer"] = "Wailer",
  ["Screamer2"] = "Dread-Wailer",
  -- "Scylla" needs no entry here -- its unit id already equals the AP check name, handled by
  -- identity below. Her two bandmates (EncounterData_Boss.lua's BossScylla01/02, unit ids
  -- confirmed against the installed game) are nicknamed "Roxy" (drummer) and "Jetty"
  -- (keytarist) in her own hype voice lines -- that's what their checks are named.
  ["SentryBot"] = "Auto-Seeker",
  ["SiegeVine"] = "Thorn-Weeper",
  ["Simple"] = "Polyp",
  ["SirenDrummer"] = "Roxy",
  ["SirenKeytarist"] = "Jetty",
  ["Stalker_Miniboss"] = "Twins of Typhon",
  ["Swab"] = "Anchor",
  ["Swarmer"] = "Numbskull",
  ["SwarmerClockwork"] = "Sandskull",
  ["ThiefMineLayer"] = "Wretched Pest",
  ["TimeElemental"] = "Tempus",
  ["Treant"] = "Root-Stalker",
  ["Treant2"] = "Brush-Stalker",
  ["Turtle"] = "Shellback",
  ["TyphonEye"] = "Eye of Typhon",
  ["TyphonHead"] = "Typhon",
  ["TyphonTail"] = "Tail of Typhon",
  ["Vampire"] = "Phantom",
  ["WaterElemental"] = "Droplet",
  ["WaterUnit"] = "Sea-Serpent",
  ["WaterUnitMiniboss"] = "Deep Serpent",
  ["Wisp"] = "Lanthorn",
  ["Zombie"] = "Shambler",
  ["ZombieAssassin"] = "Cutthroat",
  ["ZombieAssassin_Miniboss"] = "Master-Slicer",
  ["ZombieCrewman"] = "Sea-Shambler",
  ["ZombieHeavyRanged"] = "Lubber",
  ["ZombieOlympus"] = "Snow-Shambler",
  ["ZombieSpawner"] = "Tombstone",
  -- Nightmare (Zagreus' Journey). Unit ids verified two ways (July 11): the mod's own
  -- Scripts/Meta/NameMappingData.lua "EnemyNameMappings" is the COMPLETE list of ids that
  -- get a "Hades"-prefix rename (only ids that also exist natively in H2 are renamed;
  -- everything else spawns bare), and display names come from the actual Hades 1 install's
  -- HelpText.en.sjson Id->DisplayName table (the port keeps H1's names). Elite tiers here
  -- use NO underscore (SwarmerElite, RatThugMiniboss...) unlike native H2's "_Elite"; the
  -- suffix-strip fallback in on_enemy_killed covers every tier not explicitly listed.
  -- Tartarus
  ["HadesSwarmer"] = "Numbskull",          -- bare SwarmerElite/SuperElite strip to native Swarmer, same check
  ["SwarmerHelmeted"] = "Numbskull",
  ["HadesLightRanged"] = "Wretched Witch", -- H1 LightRanged = "Wretched Witch"; only the base tier is renamed,
  ["LightRangedElite"] = "Wretched Witch", -- so its bare elite tiers MUST stay explicit: suffix-stripping them
  ["LightRangedSuperElite"] = "Wretched Witch", -- would hit native H2 LightRanged ("Sister of the Dead") instead
  ["HadesThiefMineLayer"] = "Wretched Pest",
  ["HadesThiefMineLayerElite"] = "Wretched Pest",
  ["PunchingBagUnit"] = "Wretched Lout",
  ["WretchAssassin"] = "Wretched Sneak",
  ["WretchAssassinMiniboss"] = "Wretched Sneak", -- the Tartarus miniboss proper
  ["LightSpawner"] = "Skullomat",
  ["DisembodiedHand"] = "Wringer",
  ["HeavyMelee"] = "Wretched Thug",
  ["HeavyRanged"] = "Brimstone",
  ["HeavyRangedSplitterMiniboss"] = "Doomstone",
  ["Harpy"] = "Megaera",                   -- the Furies boss: one random sister per run
  ["Harpy2"] = "Alecto",
  ["Harpy3"] = "Tisiphone",
  -- Asphodel. The Bloodless family + SpreadShotUnit are renamed (native H2 reuses those
  -- ids); the Berserker and all SuperElite tiers spawn bare (not in the rename list).
  ["HadesBloodlessNaked"] = "Bloodless",
  ["HadesBloodlessNakedElite"] = "Bloodless",
  ["BloodlessNakedBerserker"] = "Bone-Raker",
  ["HadesBloodlessGrenadier"] = "Inferno-Bomber",
  ["HadesBloodlessGrenadierElite"] = "Dire Inferno-Bomber", -- own check: the Tartarus MiniBossGrenadier pair
  ["HadesBloodlessSelfDestruct"] = "Slam-Dancer",
  ["HadesBloodlessSelfDestructElite"] = "Slam-Dancer",
  ["HadesBloodlessPitcher"] = "Burn-Flinger",
  ["HadesBloodlessPitcherElite"] = "Burn-Flinger",
  ["HadesBloodlessWaveFist"] = "Wave-Maker",
  ["HadesBloodlessWaveFistElite"] = "Wave-Maker",
  ["HadesSpreadShotUnit"] = "Spreader",    -- H1's SpreadShotUnit = "Spreader"; H2's own = "Wretched Witch" (different check!)
  ["HadesSpreadShotUnitElite"] = "Spreader",
  ["SpreadShotUnitMiniboss"] = "Dire Spreader", -- own check: Asphodel MiniBossSpreadShot
  ["FreezeShotUnit"] = "Gorgon",
  ["CrusherUnit"] = "Skull-Crusher",
  ["RangedBurrower"] = "Dracon",
  ["HitAndRunUnit"] = "Megagorgon",
  ["ShieldRanged"] = "Voidstone",          -- intro encounter is Asphodel; also appears in Elysium
  -- The Bone Hydra spawns as one of five behavior variants -- each IS the boss. The mortal
  -- side heads (HydraHeadDartmaker/Lavamaker/...) die mid-fight and must NOT map here.
  ["HydraHeadImmortal"] = "Bone Hydra",
  ["HydraHeadImmortalLavamaker"] = "Bone Hydra",
  ["HydraHeadImmortalSummoner"] = "Bone Hydra",
  ["HydraHeadImmortalSlammer"] = "Bone Hydra",
  ["HydraHeadImmortalWavemaker"] = "Bone Hydra",
  -- Elysium
  ["SplitShotUnit"] = "Splitter",
  ["Chariot"] = "Nemean Chariot",
  ["ChariotSuicide"] = "Flame Wheel",
  ["ShadeSwordUnit"] = "Brightsword",
  ["ShadeSpearUnit"] = "Longspear",
  ["ShadeBowUnit"] = "Strongbow",
  ["ShadeShieldUnit"] = "Greatshield",
  ["FlurrySpawner"] = "Soul Catcher",
  ["Theseus2"] = "Theseus",                -- Extreme Measures chariot Theseus
  ["Minotaur"] = "Asterius",               -- confirmed unit id (also his Elysium Warden miniboss appearance)
  ["Minotaur2"] = "Asterius",              -- Extreme Measures Asterius
  -- Styx. Hades (the final boss) spawns as plain "Hades" -- identity via ENEMY_CHECKS_BY_ROUTE.
  ["HadesCrawler"] = "Crawler",
  ["HadesCrawlerMiniBoss"] = "King Vermin",
  ["RatThug"] = "Gigantic Vermin",
  ["ThiefImpulseMineLayer"] = "Bother",
  ["HeavyRangedForked"] = "Snakestone",
  ["SatyrRanged"] = "Satyr Cultist",       -- NOT native H2's SatyrCultist id (= "Satyr Supplicant")
}

local UNIT_TO_ENEMY_CHECK = {}
for _, _names in pairs(ENEMY_CHECKS_BY_ROUTE) do
  for _, name in ipairs(_names) do UNIT_TO_ENEMY_CHECK[name] = name end
end
for unit, name in pairs(LocationManager.ENEMY_UNIT_OVERRIDE) do UNIT_TO_ENEMY_CHECK[unit] = name end
LocationManager.UNIT_TO_ENEMY_CHECK = UNIT_TO_ENEMY_CHECK

-- Reverse of UNIT_TO_ENEMY_CHECK: check name -> one concrete spawnable unit id, for
-- EnemySanity.lua's substitution (given a replacement check name, what do we actually spawn?).
-- Many unit ids share one check (Elite/SuperElite/Shadow tiers, multiple Nightmare rename
-- variants), so pick a single canonical id per check: identity (unit id == check name) wins
-- outright since it's always the plain base spawn; otherwise prefer any override whose id
-- doesn't look like a suffixed variant, and among those a Hades II unit (one UnitArtPackages
-- knows the art for) over a Zagreus' Journey one. 9/26: the 12 names both games share
-- (Numbskull = Swarmer / HadesSwarmer / SwarmerHelmeted, Wretched Witch = SpreadShotUnit /
-- HadesLightRanged, ...) had two or three plain ids and the pick fell to pairs() order -- and a
-- ZJ id there gets the Hades II biome package preloaded (these checks sit in the Underworld
-- roster), so its sprite would draw untextured outside a ZJ room. Ties go to the smaller id so
-- the result doesn't depend on pairs() order.
local ENEMYSANITY_SUFFIXES = { "_SuperElite", "_Elite", "_Shadow", "SuperElite", "Elite", "Miniboss", "MiniBoss" }
local function _looks_suffixed_variant(unitId)
  for _, suffix in ipairs(ENEMYSANITY_SUFFIXES) do
    if #unitId > #suffix and unitId:sub(-#suffix) == suffix then return true end
  end
  return false
end
-- The identity pre-seed loop above (UNIT_TO_ENEMY_CHECK[name] = name, one per
-- ENEMY_CHECKS_BY_ROUTE entry) assumes every check name is ALSO a real spawnable unit id --
-- true for native H2 names reused as-is (Talos, Wringer, Scylla, Chronos...), but false for
-- check names that exist ONLY as ENEMY_UNIT_OVERRIDE targets (e.g. "Doomstone", "Erymanthian
-- Boar", "Splitter", "Satyr Cultist", "Soul Catcher" -- none of these strings appear anywhere
-- in the game's own Content/Scripts; confirmed via grep against the installed game). For
-- those, the bogus self-mapping ("Doomstone" -> "Doomstone") would otherwise win the "identity
-- wins outright" tie-break below over the real override-based unit id, and EnemySanity
-- substitution would write that fake id into spawnData.Name -- crashing
-- EncounterLogic.lua's "Back Compat" fallback (EnemyData[name] == nil -> TableLength on a nil
-- EnemySet -> "attempt to compare number with nil"). Filtered out here via a real EnemyData
-- lookup (the game's own global unit table, already populated before any mod loads).
local function _unit_id_rank(unitId, checkName)
  if unitId == checkName then return 3 end
  if _looks_suffixed_variant(unitId) then return 0 end
  if UnitArtPackages and UnitArtPackages[unitId] then return 2 end
  return 1
end
local CHECK_TO_UNIT_ID = {}
for unitId, checkName in pairs(UNIT_TO_ENEMY_CHECK) do
  local isBogusIdentity = (unitId == checkName) and (EnemyData == nil or EnemyData[checkName] == nil)
  if not isBogusIdentity then
    local current = CHECK_TO_UNIT_ID[checkName]
    local rank = _unit_id_rank(unitId, checkName)
    local currentRank = current and _unit_id_rank(current, checkName)
    if not current or rank > currentRank or (rank == currentRank and unitId < current) then
      CHECK_TO_UNIT_ID[checkName] = unitId
    end
  end
end
LocationManager.CHECK_TO_UNIT_ID = CHECK_TO_UNIT_ID

-- Surface any enemy check that ended up with no CHECK_TO_UNIT_ID entry at all: EnemySanity.
-- replacement_unit_id will silently leave that unit's spawn untouched (fail-closed, by design),
-- but that's a "safe but silent" fallback worth knowing about rather than discovering the hard
-- way that a check can never be substituted in. One aggregated warning, not one per name.
do
  local _unmapped = {}
  for _, _names in pairs(ENEMY_CHECKS_BY_ROUTE) do
    for _, _name in ipairs(_names) do
      if not CHECK_TO_UNIT_ID[_name] then table.insert(_unmapped, _name) end
    end
  end
  if #_unmapped > 0 then
    rom.log.warning("[AP] enemysanity: no CHECK_TO_UNIT_ID mapping for: " .. table.concat(_unmapped, ", "))
  end
end

-- Route boss "Met" checks, keyed by (route, zone). Fired the first time you clear a combat
-- room in that boss's layer (access = reaching the layer, matching the Python region gating).
-- A zone's entry is normally a single check name; Nightmare's zone 3 (Elysium) has TWO --
-- Theseus and Asterius are fought together but tracked as separate "Met" checks -- so that
-- entry is a list instead (send_boss_met handles both shapes).
-- "Met Megaera" (zone 1) exists Python-side as an NPC_BOSS_MEET tuple (appended after the
-- other boss meets so ids stayed stable). Zone 4's "Met Hades" is deliberately the SAME
-- name as the Underworld's "Met Hades" (Jeweled Pom keepsake-giver): one shared location,
-- whichever route reaches him first sends it (Python Routes.NPC_MULTI_ROUTE_LOCK /
-- Rules._set_hades_met_rule).
local BOSS_MET_BY_ZONE = {
  Underworld = { [1] = "Met Hecate", [2] = { "Met Scylla", "Met Roxy", "Met Jetty" }, [3] = "Met Cerberus", [4] = "Met Chronos" },
  Surface    = { [1] = "Met Polyphemus", [2] = "Met Eris", [3] = "Met Prometheus", [4] = "Met Typhon" },
  Nightmare    = { [1] = "Met Megaera", [2] = "Met Bone Hydra",
                 [3] = { "Met Theseus", "Met Asterius" }, [4] = "Met Hades" },
}

-- Vow of Rivals (BossDifficultyShrineUpgrade) swaps a boss's fight to its "02" encounter
-- (SGG's ShrineData.lua Encounter/AltEncounter pairs), and three of those "02" variants add
-- a second named NPC into the arena via an extra ActivatePrePlaced LegalTypes entry
-- (EncounterData_Boss.lua, confirmed against the installed game's Content/Scripts): Medea
-- joins Polyphemus, Heracles joins Prometheus, Chronos joins Typhon. That rival is never in
-- SpeakerNames and isn't the zone's own route boss, so send_boss_met alone never sent their
-- "Met" check even though they're standing right there.
-- 7/31 these fired unconditionally with the zone's boss "Met", so "Met Medea" sent at every
-- Polyphemus fight without the Vow (reports 10/4, 10/24; user 10/24: not intended). Now they
-- fire only when the rival unit is actually activated in a boss arena
-- (LocationManager.on_units_activated, from reload.lua's ActivatePrePlaced wrap). That gates on
-- the rival being present, not on the Vow setting, and logic never relied on this trigger: all
-- three names have their own Rules.py access rule (randomized-helper reachability for
-- Medea/Heracles, the hecate_pred rule for Chronos), reached by the normal meeting.
-- Keyed by unit name (EnemyData key) -> NPC_CAST_SET key.
local BOSS_RIVAL_UNITS = {
  Medea = "Medea", Heracles = "Heracles", Chronos_TyphonFight = "Chronos",
}

-- Bosses you meet regardless of route (Hecate mentors you at the Crossroads from the start).
-- Their "Met" location is always generated and start-reachable (Python ALWAYS_MET_BOSSES), so it
-- must NOT be route-gated here. Keep in sync with Python: add "Met Eris" if Eris is confirmed
-- meetable off the Surface.
local ALWAYS_MET_BOSS = { ["Met Hecate"] = true }

-- NPCs met on only one route (mirrors Python Routes.NPC_ROUTE_LOCK): their "Met <NPC>" and
-- "<NPC> Keepsake" locations only exist in the seed when that route is active.
-- July 18: shrank from 17 entries to 4, mirroring the Python-side change. The story-room
-- NPCs (zerp-NPCRoomRandomizer shuffles who appears in every story slot, across routes --
-- Patroclus really was met in an Underworld run replacing Arachne, and his check was
-- silently dropped by this very gate) and the combat-assist NPCs (zerp-Extended_NPC_
-- Encounters covers every route's zones) moved to Python's NPC_RANDOMIZED_HELPERS: their
-- locations now exist on EVERY seed, so they must never be send-blocked here. What stays:
-- Eris (Surface boss/bath only), Orpheus (ZJ Tartarus rooms only), and Megaera as a
-- Lua-only defensive entry -- her "Met" is boss-met machinery and her keepsake is
-- item-only, so that just stops any stray send when Nightmare content isn't loaded.
-- Achilles used to be here too (native Nightmare Elysium progression only) but his "Met
-- Achilles"/"Achilles Keepsake" were removed as locations entirely July 31 (user ruling,
-- mirrors Python's Locations.NPC_EXTRA_CAST / Items.KEEPSAKE_NO_LOCATION) -- he's no
-- longer in NPC_CAST below, so he never resolves to a check name in the first place.
local NPC_ROUTE_LOCK = {
  Eris = "Surface",
  Orpheus = "Nightmare", Megaera = "Nightmare",
}

-- Full check name -> the route(s) whose activation gates its existence in the seed. Checks
-- can be reached through un-route-gated paths (hub chat, field encounter, boon pickup, a
-- gift, a shared enemy killed on the other route) -- when every route a check belongs to is
-- excluded, the location was never generated, so sending it makes the client log "Unknown
-- location checked by game". Gate at the send sites instead (send_first /
-- check_route_blocked). Covers every enemy "Defeated" check, route boss "Met"s (except
-- always-met ones, whose location always exists), and route-locked cast "Met"s + their
-- "<NPC> Keepsake" checks.
local ROUTE_GATED_CHECKS = {}
for _route, _names in pairs(ENEMY_CHECKS_BY_ROUTE) do
  for _, _name in ipairs(_names) do
    ROUTE_GATED_CHECKS[_name .. " Defeated"] = { _route }
  end
end
-- July 18 (user ruling): the 12 shared H1-callback checks only EXIST in a seed when the
-- Nightmare route is active (their Underworld-side spawns -- Asphodel-anomaly detours and
-- the odd H2 callback -- are too rare to justify pool membership on their own). Gate their
-- existence on Nightmare alone; when Nightmare IS in the seed, a kill on EITHER route
-- still sends (this gate is seed-level, never current-route).
for _, _name in ipairs(SHARED_ENEMY_CHECKS) do
  ROUTE_GATED_CHECKS[_name .. " Defeated"] = { "Nightmare" }
end
ROUTE_GATED_CHECKS[KING_VERMIN_CHECK .. " Defeated"] = { "Underworld", "Nightmare" }
for _route, _byzone in pairs(BOSS_MET_BY_ZONE) do
  for _, _check in pairs(_byzone) do
    local _names = (type(_check) == "table") and _check or { _check }
    for _, _name in ipairs(_names) do
      if not ALWAYS_MET_BOSS[_name] then ROUTE_GATED_CHECKS[_name] = { _route } end
    end
  end
end
for _npc, _route in pairs(NPC_ROUTE_LOCK) do
  ROUTE_GATED_CHECKS["Met " .. _npc] = { _route }
  ROUTE_GATED_CHECKS[_npc .. " Keepsake"] = { _route }
end
-- Clears the single-route gate the BOSS_MET_BY_ZONE loop above set for "Met Hades"
-- (Nightmare's final boss): as of July 18 he's a randomized helper (his I_Story01 story
-- room shuffles into any route's story slots), so his location exists on EVERY seed and
-- must never be send-blocked.
ROUTE_GATED_CHECKS["Met Hades"] = nil

-- Boss "Met" checks a Dream seed generates even with the boss's own route left out (mirrors
-- Python's Locations.DREAM_MET_ROUTES / dream_boss_met_locations_for): a Dream region is a
-- whole Underworld or Surface biome played to its own boss, so a dive meets those bosses
-- anyway. Only on a seed that says so (dream_met_checks) -- one generated before 9/30 has no
-- such locations. Nightmare's bosses aren't here: with the Nightmare route in the
-- seed the plain route gate already passes them, and without it (a dive still deals Zagreus'
-- Journey's biomes when the seed includes that mod) no such locations are generated.
local DREAM_MET_ROUTES = { "Underworld", "Surface" }
local DREAM_MET_CHECKS = {}
for _, _route in ipairs(DREAM_MET_ROUTES) do
  for _, _check in pairs(BOSS_MET_BY_ZONE[_route]) do
    local _names = (type(_check) == "table") and _check or { _check }
    for _, _name in ipairs(_names) do DREAM_MET_CHECKS[_name] = true end
  end
end

-- True when `name` is route-gated and none of its routes are in this seed. Used by
-- send_first and by reload.lua's keepsakesanity gift hook (which sends its check directly).
function LocationManager.check_route_blocked(name)
  local routes = ROUTE_GATED_CHECKS[name]
  if not routes then return false end
  for _, r in ipairs(routes) do
    if ItemManager.route_active(r) then return false end
  end
  if DREAM_MET_CHECKS[name] and ItemManager.route_active("Dream")
      and ItemManager.setting_on("dream_met_checks") then
    return false
  end
  return true
end

-- Crossroads cast "Met" checks (must match the Python NPC_CAST). Keyed by the AP check name.
-- As with enemies, map the real in-game NPC id -> "Met <Name>" here; on_npc_interacted()
-- logs unmapped ids when npc_locations is on. Identity is assumed otherwise.
local NPC_CAST = {
  "Moros", "Skelly", "Dora", "Nemesis", "Artemis", "Selene", "Charon", "Odysseus",
  "Circe", "Narcissus", "Arachne", "Icarus", "Heracles", "Medea", "Hermes", "Echo",
  -- Zagreus stays out of this table (Python NPC_NO_MEET / not in NPC_CAST): the Crossroads
  -- cast's UseNPC-based "Met" doesn't apply to him. His real "Met Zagreus" check (added July
  -- 17, Locations.py ZAGREUS_MET_LOCATION) is sent separately by on_zagreus_met() below, fired
  -- from reload.lua on arrival in his C_Boss01 fight room (works across all 3 encounter modes).
  "Chaos", "Dionysus", "Athena", "Hades", "Hephaestus", "Zeus", "Demeter",
  "Aphrodite", "Poseidon", "Apollo", "Hestia", "Ares", "Hera",
  -- Non-keepsake meet-able NPC (Test Run 5 #5): met by talking to NPC_Hypnos_01 once awake.
  "Hypnos",
  -- Nightmare keepsake-giving cast (Megaera excluded -- she's boss-gated via BOSS_MET_BY_ZONE
  -- instead, same convention as Hecate/Eris not being double-listed here). Orpheus/Thanatos
  -- have real Python-side locations as of July 16 (unit ids NPC_Orpheus_01,
  -- NPC_Thanatos_01/_Field_01 -- all parse via the NPC_<Char>_ fallback). Achilles
  -- (NPC_Achilles_01) was here too but was removed July 31 -- "Met Achilles" is no longer
  -- a location, so he deliberately falls through to the unmapped-id log instead.
  "Sisyphus", "Eurydice", "Patroclus", "Orpheus", "Thanatos",
}
LocationManager.NPC_UNIT_OVERRIDE = LocationManager.NPC_UNIT_OVERRIDE or {
  -- ["NPC_Hecate_01"] = "Met Hecate",   -- example
  -- Explicit (not relying on the "NPC_<Char>_.." parse fallback): the Underworld "Curse of
  -- Eris" ambush spawns unit id "NPC_Eris_01" (RoomDataG/H/I.lua SpawnErisForCurse), same id
  -- used for her Crossroads/bath appearances. "Met Eris" stays Surface-gated (send_first's
  -- ROUTE_GATED_CHECKS gate), so this only actually sends when Surface is part of the seed.
  ["NPC_Eris_01"] = "Met Eris",
  -- Nightmare: Megaera's conversation appearances use "FurySister", which the NPC_<Char>_
  -- pattern can't match to her cast name. Route-gated via ROUTE_GATED_CHECKS in send_first.
  ["NPC_FurySister_01"] = "Met Megaera",
  ["NPC_FurySister_Story_01"] = "Met Megaera",
}
local UNIT_TO_NPC_CHECK = {}
for _, name in ipairs(NPC_CAST) do UNIT_TO_NPC_CHECK[name] = "Met " .. name end
for unit, name in pairs(LocationManager.NPC_UNIT_OVERRIDE) do UNIT_TO_NPC_CHECK[unit] = name end

-- In-game NPC unit ids follow the pattern NPC_<Char>_<variant> (e.g. NPC_Nemesis_01,
-- NPC_Hades_Field_01, NPC_Zeus_Story_01 - confirmed across NPCData*.lua). So rather than
-- hand-listing every unit id, we parse <Char> out of the name and match it to the cast.
-- Bosses (Hecate, Scylla, ...) are included too: the wishlist says their "Met" check fires
-- "however they first meet them", so talking to one at the Crossroads counts as well as
-- reaching their layer (send_first dedups whichever happens first).
local NPC_CAST_SET = {}
for _, name in ipairs(NPC_CAST) do NPC_CAST_SET[name] = "Met " .. name end
for _, byzone in pairs(BOSS_MET_BY_ZONE) do
  for _, check in pairs(byzone) do
    -- A zone entry can be a list (Nightmare's Elysium: Theseus + Asterius) -- normalize to a
    -- list either way so this loop handles both shapes without calling :match on a table.
    local checks = (type(check) == "table") and check or { check }
    for _, name in ipairs(checks) do
      local char = name:match("^Met (%a+)$")
      if char then NPC_CAST_SET[char] = name end
    end
  end
end

local _logged_unmapped_enemies = {}
local _logged_unmapped_npcs = {}

-- Send a check once: guarded by a per-save set so a re-kill / re-talk never re-sends.
local function send_first(set, name)
  local s = APState.get()
  if not s or not s[set] then return end
  if s[set][name] then return end
  -- Route-gated checks (enemy kills, boss/cast "Met"s) don't exist in a seed that excludes
  -- every route they belong to -- skip the send. Don't poison the dedup set: leave it unset
  -- so a legit send can still fire later (e.g. after reconnecting under a different seed).
  if LocationManager.check_route_blocked(name) then return end
  s[set][name] = true
  Bridge.send_check(name)
  rom.log.info("[AP] check: " .. name .. " (" .. set .. ")")
end

-- Resolve a spawned unit id to its bare AP enemy-check name (no " Defeated" suffix), or nil if
-- unmapped. Shared by on_enemy_killed (send-on-death) and the miniboss-forcing lookup in
-- reload.lua's ChooseEncounter wrap (need-to-know "is this candidate already defeated?").
local function resolve_enemy_check(id)
  if type(id) ~= "string" then return nil end
  local check = UNIT_TO_ENEMY_CHECK[id]
  if not check then
    -- Elite spawns share their base unit's AP check. Native H2 always underscores its
    -- variant suffixes -- "_Elite" (Brawler_Elite, Guard_Elite...), "_SuperElite" (Screamer2_
    -- SuperElite, Boar_SuperElite, Lamia_SuperElite...), and "_Shadow" (the shrine-upgrade
    -- reskin used by MiniBossTreant_Shrine/MiniBossFogEmitter_Shrine once the player has taken
    -- the "MinibossCountShrineUpgradeActive" upgrade -- Treant_Shadow, FogEmitter_Shadow,
    -- Screamer_Shadow, ...). The ported Nightmare content instead uses bare "Elite"/"SuperElite"/
    -- "Miniboss" with NO underscore (SwarmerElite, RatThugMiniboss; WretchAssassinMiniboss
    -- SuperElite strips to the explicitly-mapped WretchAssassinMiniboss). Try the underscored
    -- (native) forms first since they're unambiguous; explicit ENEMY_UNIT_OVERRIDE entries
    -- always win over stripping regardless -- required where the stripped base id belongs to a
    -- DIFFERENT native-H2 enemy (see the LightRangedElite note in the table above).
    for _, suffix in ipairs({ "_Elite", "_SuperElite", "_Shadow", "SuperElite", "Elite", "Miniboss", "MiniBoss" }) do
      if #id > #suffix and id:sub(-#suffix) == suffix then
        check = UNIT_TO_ENEMY_CHECK[id:sub(1, #id - #suffix)]
        if check then break end
      end
    end
  end
  return check
end

-- Unit ids that count toward a check when KILLED but stay out of UNIT_TO_ENEMY_CHECK, so enemy
-- substitution and art preloading never treat them as that species. 10/4: the Tempus that Chronos
-- and Typhon summon mid-fight (WeaponData_Chronos / EnemyData_TyphonHead SpawnerOptions) are
-- their own unit ids, logged as "unmapped foe id 'TimeElemental2'"; CodexData counts all of them
-- toward the one Tempus entry.
local KILL_ONLY_UNIT_CHECK = {
  ["TimeElemental2"] = "Tempus",
  ["TimeElemental2_EM"] = "Tempus",
  ["TimeElemental2_Typhon"] = "Tempus",
}
local function resolve_kill_check(id)
  return resolve_enemy_check(id) or KILL_ONLY_UNIT_CHECK[id]
end

-- Public: same resolution on_enemy_killed uses, exposed so other systems (the miniboss-forcing
-- ChooseEncounter hook in reload.lua) can ask "what check would killing THIS unit id satisfy?"
-- without duplicating the override table / suffix-strip rules.
function LocationManager.enemy_check_for_unit(id)
  return resolve_enemy_check(id)
end

-- Public: has this bare enemy-check name (e.g. "King Vermin", no " Defeated" suffix) already
-- been sent this save? Used by the miniboss-forcing hook to tell "already killed" candidates
-- apart from ones still worth guaranteeing. Route-blocked/unknown names read as "not defeated"
-- (never true), which is the safe default -- it just means that candidate stays eligible.
function LocationManager.enemy_check_defeated(name)
  local s = APState.get()
  return (s and s.enemy_killed and s.enemy_killed[name .. " Defeated"]) == true
end

-- Public: would killing this miniboss (bare check name) on the CURRENT run still earn something?
-- Read by the miniboss door marker (MinibossRooms.door_marker). A Dream Dive never sends the
-- named "X Defeated" check -- it counts each species once toward the "Dream Miniboss NNN" tier
-- (on_dream_enemy_killed) -- so there the answer is whether Dream has counted this species yet.
function LocationManager.miniboss_check_pending(name)
  if game.CurrentRun and game.CurrentRun.IsDreamRun then
    local s = APState.get()
    local seen = s and s.dream_species_seen and s.dream_species_seen.miniboss
    return not (seen and seen[name])
  end
  return not LocationManager.enemy_check_defeated(name)
end

-- Dream Dive boss-tier classification. No longer inferred from Locations.py's inline
-- "boss-identical" comments (which are inconsistently applied) -- derived instead from what a
-- Dream region actually IS: DreamDiveTweaks routes each region slot to a whole vanilla biome
-- (EnterNextDreamBiome -> ChooseStartingRoom with that biome letter), which the player plays
-- through to that biome's own boss; the post-boss room's DreamPointsDrop is what ends the
-- region (DreamRunLogic.CheckDreamBiomeCompletion). So the Dream "boss" tier is exactly the set
-- of the 12 eligible biomes' bosses: Hecate, Scylla, Cerberus, Chronos, Polyphemus, Eris, Prometheus, Typhon, and -- with Zagreus' Journey
-- in the Dream pool -- Megaera/Alecto/Tisiphone, Bone Hydra, Theseus, and Hades.
-- "Infernal Beast" is Cerberus (its enemy-check name differs from its boss-event name, which is
-- why it was missed here): without it the Fields of Mourning region's own boss kill fell through
-- to the Miniboss tier instead of the Boss tier.
local DREAM_BOSS_NAMES = {
  -- 10/4 (user ruling): Scylla's bandmates Roxy and Jetty are NOT here. One fight was taking
  -- three Boss slots; they count on the Miniboss tier instead (both are in MINIBOSS_CHECK_NAMES).
  -- 11/3 (user ruling, same reason): Asterius isn't either. The Theseus fight is Theseus' one
  -- Boss slot; Asterius counts on the Miniboss tier there and in Elysium's Warden room alike
  -- (0.10.0 log, 10/31: the Warden fight took a Dream Boss slot).
  ["Headmistress Hecate"] = true, ["Scylla"] = true,
  ["Infernal Beast"] = true,
  ["Chronos"] = true, ["The Cyclops Polyphemus"] = true, ["Eris"] = true, ["Prometheus"] = true,
  ["Typhon"] = true, ["Megaera"] = true, ["Alecto"] = true, ["Tisiphone"] = true,
  ["Bone Hydra"] = true, ["Theseus"] = true, ["Hades"] = true,
}

-- Whether the current room's encounter is a boss arena (EncounterType "Boss", the same test
-- on_room_started uses). Read by on_units_activated.
local function in_boss_arena()
  local room = game.CurrentRun and game.CurrentRun.CurrentRoom
  local enc = room and room.Encounter
  if not enc then return false end
  local etype = enc.EncounterType
    or (enc.Name and game.EncounterData and game.EncounterData[enc.Name]
        and game.EncounterData[enc.Name].EncounterType)
  return etype == "Boss"
end

-- Send the next unclaimed "Dream <Tier> NNN" location the first time `speciesName` is ever
-- defeated in a Dream run (global dedup across ALL regions/attempts -- user-confirmed design:
-- a species counts once, ever, regardless which region slot it's fought in). Numbering is by
-- how many DISTINCT species this tier has ever seen, not species identity -- "no matter which
-- enemy you defeat first, it sends Dream Enemy 001".
local function send_dream_tier_check(tier, speciesName)
  local s = APState.get()
  if not s or not s.dream_species_seen then return end
  local seen = s.dream_species_seen[tier]
  if not seen or seen[speciesName] then return end
  seen[speciesName] = true
  local count = dream_tier_count(s, tier)
  -- The counter is "how many DISTINCT species this tier has ever seen", but the seed only
  -- generated as many locations as (roster / regions_available) * dream_enemy_locations -- e.g.
  -- 70 "Dream Enemy" locations off a 105-name roster. Past that the species keep coming and this
  -- kept naming checks that exist in no seed ("Dream Enemy 0071"...), which the client answers
  -- with "Unknown location checked by game" forever. Keep counting (so the dedup set stays
  -- honest) but stop sending.
  local limit = LocationManager.dream_tier_limit(tier)
  if limit and count > limit then
    rom.log.info("[AP] dream " .. tier .. ": species " .. count .. " exceeds this seed's "
      .. limit .. " location(s) - nothing left to send")
    return
  end
  local name = DREAM_TIER_PREFIX[tier] .. " " .. DREAM_TIER_PAD[tier](count)
  if LocationManager.check_route_blocked(name) then return end
  Bridge.send_check(name)
  rom.log.info("[AP] check: " .. name .. " (dream " .. tier .. ", species=" .. speciesName .. ")")
end

-- Goal-cascade counterpart of flush_route_enemy_checks for Dream's three cumulative counters:
-- release every "Dream Enemy/Miniboss/Boss NNN" location the seed generated but the player
-- hasn't reached yet. Dream's enemy locations are a flat count, not per-species names, so the
-- name-keyed flush the other routes use has nothing to iterate here.
local function flush_dream_enemy_checks()
  if not EnemySanity.locations_on() then return end
  local s = APState.get()
  if not s or not s.dream_species_seen then return end
  local include_minibosses = ItemManager.setting_on("include_minibosses")
  local sent = 0
  for tier in pairs(s.dream_species_seen) do
    if tier ~= "miniboss" or include_minibosses then
      local limit = LocationManager.dream_tier_limit(tier)
      if limit then
        local count = dream_tier_count(s, tier)
        for i = count + 1, limit do
          local name = DREAM_TIER_PREFIX[tier] .. " " .. DREAM_TIER_PAD[tier](i)
          if not LocationManager.check_route_blocked(name) then
            Bridge.send_check(name)
            sent = sent + 1
          end
        end
      end
    end
  end
  rom.log.info("[AP] goal cascade: flushed " .. sent .. " Dream enemy-counter checks")
end

-- Dream Dive enemy tracking: fully separate from the normal per-species enemy_locations
-- pool (user-confirmed: a Dream kill does NOT also count toward that species' normal
-- "X Defeated" check). Classifies via the SAME unit-id resolver as normal routes (species
-- identity is route-agnostic), then routes into one of 3 flat cumulative tiers instead of a
-- fixed named check. include_minibosses off drops ONLY the Miniboss tier entirely (matches
-- filter_minibosses' existing behavior) -- the Boss tier always exists regardless.
function LocationManager.on_dream_enemy_killed(unit)
  if not ItemManager.route_active("Dream") then return end  -- Dream not part of this seed
  local id = unit and unit.Name
  if not id then return end
  local check = resolve_kill_check(id)
  if not check then return end
  if check == "Scylla" then
    -- Same WipeEnemiesOnKill gap as on_enemy_killed below: finishing Scylla first removes her
    -- bandmates without killing them, and they'd miss their two Miniboss-tier counts.
    if ItemManager.setting_on("include_minibosses") then
      send_dream_tier_check("miniboss", "Roxy")
      send_dream_tier_check("miniboss", "Jetty")
    end
  end
  local tier
  if DREAM_BOSS_NAMES[check] then
    tier = "boss"
  elseif EnemySanity.MINIBOSS_CHECK_NAMES[check] then
    if not ItemManager.setting_on("include_minibosses") then return end
    tier = "miniboss"
  else
    tier = "regular"
  end
  send_dream_tier_check(tier, check)
end

-- Wrapped on every unit death (reload.lua). If enemysanity is vanilla_plus_locations (1) or
-- shuffled_plus_locations (3) and the unit maps to an enemy check, send it (first time only).
-- Tracking is by the actual creature killed, unaffected by whether EnemySanity substituted it
-- in -- see project plan's "Location tracking" note. Unmapped enemies are logged once for
-- discovery. Miniboss checks are skipped entirely when include_minibosses is off (mirrors
-- Python's Locations.filter_minibosses -- those locations don't exist in this seed's table).
function LocationManager.on_enemy_killed(unit)
  if game.CurrentRun and game.CurrentRun.IsDreamRun then
    if Routes.past_last_zone(Routes.dream_current()) then return end  -- Dream endless
    if EnemySanity.locations_on() then LocationManager.on_dream_enemy_killed(unit) end
    return
  end
  if not EnemySanity.locations_on() then return end
  local id = unit and unit.Name
  if not id then return end
  local check = resolve_kill_check(id)
  if check and EnemySanity.MINIBOSS_CHECK_NAMES[check] and not ItemManager.setting_on("include_minibosses") then
    return
  end
  if check then
    -- Python location names are "<Enemy> Defeated"; UNIT_TO_ENEMY_CHECK holds the bare
    -- enemy name (so unit-id matching stays simple), so add the suffix at send time.
    send_first("enemy_killed", check .. " Defeated")
    if check == "Scylla" then
      -- EncounterData_Boss.lua's BossScylla01/02 sets WipeEnemiesOnKill = "Scylla": the
      -- instant Scylla dies, the fight ends and any bandmate still alive gets force-removed
      -- ("wiped"), not killed -- so their own on_enemy_killed never fires if the player
      -- finishes Scylla before them. Both bandmates are guaranteed present in every Scylla
      -- fight, and the fight can't end without her dead, so it's safe to award both the
      -- moment she dies regardless of kill order (send_first no-ops if a bandmate already
      -- died normally first).
      send_first("enemy_killed", "Roxy Defeated")
      send_first("enemy_killed", "Jetty Defeated")
    end
  else
    -- No mapping. Surface the real id once so ENEMY_UNIT_OVERRIDE can be completed in-game.
    -- The old heuristic only logged units with EnemyData/AIData; minibosses and special foes
    -- can carry their data elsewhere, so they slipped through silently (Test Run 5 #18). Treat
    -- anything with combat fields, or a name that looks like a foe/miniboss, as loggable.
    local looks_like_foe = unit.EnemyData or unit.AIData or unit.MaxHealth or unit.WeaponData
      or (type(id) == "string" and (id:find("Miniboss") or id:find("MiniBoss") or id:find("_Boss")))
    if looks_like_foe and not _logged_unmapped_enemies[id] then
      _logged_unmapped_enemies[id] = true
      rom.log.info("[AP] enemy_locations: unmapped foe id '" .. tostring(id)
        .. "' (add it to LocationManager.ENEMY_UNIT_OVERRIDE to make it a check)")
    end
  end
end

-- Wrapped on UseNPC (reload.lua) - the confirmed conversation entry point. Sends
-- "Met <Name>" the first time you talk to each cast member. Resolution order:
--   1. explicit NPC_UNIT_OVERRIDE / identity match on the raw unit id, then
--   2. parse NPC_<Char>_... and match <Char> against the cast list.
-- Anything that looks like an NPC but maps to nothing is logged once for discovery.
function LocationManager.on_npc_interacted(unit)
  if not ItemManager.setting_on("npc_locations") then return end
  local id = unit and unit.Name
  if not id then return end
  local check = UNIT_TO_NPC_CHECK[id]
  if not check then
    local char = id:match("^NPC_(%a+)")
    if char then check = NPC_CAST_SET[char] end
  end
  if check then
    send_first("npc_met", check)
  elseif id:match("^NPC_") and not _logged_unmapped_npcs[id] then
    _logged_unmapped_npcs[id] = true
    rom.log.info("[AP] npc_locations: unmapped NPC id '" .. tostring(id)
      .. "' (add it to LocationManager.NPC_UNIT_OVERRIDE as \"Met <Name>\")")
  end
end

-- Wrapped on HandleLootPickup (reload.lua). Boon gods aren't NPC conversations - they're
-- loot interactions, so UseNPC never fires for them. The boon's loot.Name is "<God>Upgrade"
-- (ZeusUpgrade, HeraUpgrade, ...). Interacting plays the god's greeting (GodLootPickupPresentation)
-- BEFORE the boon menu, so this is the "meet" moment. First time only; dedups with the
-- Crossroads cast meet via the shared npc_met set.
-- Loot names that don't follow the "<God>Upgrade" pattern and can't be trusted to carry a
-- live loot.SpeakerName at runtime (confirmed 2026-07-15: a Selene SpellDrop pickup logged
-- zero output from on_loot_pickup -- neither a send nor an "unmapped loot" fallback -- while
-- the exact same code path fired correctly for a ZeusUpgrade pickup moments later, because
-- "ZeusUpgrade" resolves via the Upgrade-suffix parse alone and never needed SpeakerName at
-- all. Every other tracked god/NPC loot matches that suffix; only these two don't, so they were
-- silently 100% dependent on a field that isn't reliably present on the runtime instance).
local LOOT_NAME_OVERRIDE = { SpellDrop = "Selene", TrialUpgrade = "Chaos" }
function LocationManager.on_loot_pickup(loot)
  if not ItemManager.setting_on("npc_locations") then return end
  if not loot then return end
  local id = loot.Name
  local who = LOOT_NAME_OVERRIDE[id] or loot.SpeakerName
  if not (who and NPC_CAST_SET[who]) and id then
    who = id:match("^(%a+)Upgrade$")
  end
  -- NOTE: no shop guard here (unlike on_encounter_started below). HandleLootPickup only ever
  -- fires from UseLoot on an actual completed interact/purchase (InteractLogic.lua -- SpendResources
  -- happens before HandleLootPickup is called), never from merely being in/near a shop room. So
  -- every call here is already a genuine meet, whether or not the room is a "Shop". A shop guard
  -- was mistakenly copy-pasted onto this hook too (Test Run 6 #5); it silently ate every real
  -- purchase-based meet forever, including Selene's own paid SpellDrop node and buying her Hex
  -- from a general shop (both confirmed 2026-07-15: game log shows zero "loot meet" output for
  -- either). The room-entry false-positive that #5 actually reported can only have come from
  -- on_encounter_started (StartEncounter fires on mere room entry, listing every seller) -- that
  -- guard stays below.
  if who and NPC_CAST_SET[who] then
    rom.log.info("[AP] loot meet: who=" .. tostring(who) .. " loot=" .. tostring(id)
      .. " SpeakerName=" .. tostring(loot.SpeakerName))
    send_first("npc_met", NPC_CAST_SET[who])
  elseif (loot.GodLoot or loot.SpeakerName) and id and not _logged_unmapped_npcs[id] then
    -- A god/NPC boon we don't have a cast entry for: log once for discovery.
    _logged_unmapped_npcs[id] = true
    rom.log.info("[AP] npc_locations: unmapped loot '" .. tostring(id)
      .. "' SpeakerName='" .. tostring(loot.SpeakerName)
      .. "' (add the name to NPC_CAST or map it as \"Met <Name>\")")
  end
end

-- Wrapped on OpenSpellScreen (reload.lua). Selene's Hex ("SpellDrop") doesn't go through the
-- generic UseLoot/HandleLootPickup path at all -- her loot object's OnUsedFunctionName is
-- "OpenSpellScreen" (SpellScreenLogic.lua), called directly from the engine's OnUsed dispatch
-- the instant the player interacts with her, BEFORE the affordability check and BEFORE
-- SpendResources. So on_loot_pickup (which only fires after a completed purchase) never sees a
-- real interaction that the player couldn't afford or backed out of -- confirmed 2026-07-15: a
-- field SpellDrop reward was interacted with but not purchased, and zero "Met Selene" fired.
-- Firing here instead, on interaction rather than purchase, matches how every other NPC gets
-- credit just for talking. First time only (send_first dedups with on_loot_pickup, whichever
-- wins first).
function LocationManager.on_spell_screen_opened(spellItem)
  if not ItemManager.setting_on("npc_locations") then return end
  if not (spellItem and spellItem.Name == "SpellDrop") then return end
  rom.log.info("[AP] spell screen meet: who=Selene loot=" .. tostring(spellItem.Name))
  send_first("npc_met", NPC_CAST_SET["Selene"])
end

-- Fire the route boss "Met" check for a (route, zone), first time only. Declared before
-- on_encounter_started (which calls it) so it's in lexical scope there, not a nil global.
-- A Vow of Rivals rival's "Met" is NOT sent here -- see on_units_activated.
local function send_boss_met(route, zone)
  if not ItemManager.setting_on("npc_locations") then return end
  local byzone = BOSS_MET_BY_ZONE[route]
  local name = byzone and byzone[zone]
  if name then
    if type(name) == "table" then
      for _, n in ipairs(name) do send_first("npc_met", n) end
    else
      send_first("npc_met", name)
    end
  end
end

-- Called with ActivatePrePlaced's result (reload.lua): the units the game just woke up, keyed by
-- object id, and its eventSource (the room's encounter, RoomLogic's StartRoomUnthreadedEvents).
-- A Vow of Rivals rival (BOSS_RIVAL_UNITS) activated in a boss arena is standing in the fight,
-- so its "Met" sends now. First time only; send_first drops it on a seed without it.
function LocationManager.on_units_activated(units, source)
  if not ItemManager.setting_on("npc_locations") then return end
  if type(units) ~= "table" then return end
  local boss = type(source) == "table" and source.EncounterType == "Boss"
  if not (boss or in_boss_arena()) then return end
  for _, unit in pairs(units) do
    local rival = type(unit) == "table" and BOSS_RIVAL_UNITS[unit.Name]
    local check = rival and NPC_CAST_SET[rival]
    if check then
      rom.log.info("[AP] boss rival present: " .. tostring(unit.Name) .. " -> " .. check)
      send_first("npc_met", check)
    end
  end
end

-- The (route, zone) whose boss "Met" the boss arena we're standing in should send, or nil.
-- On an ordinary run that's simply where we are. On a Dream Dive, Routes.current() answers
-- ("Dream", region slot) and BOSS_MET_BY_ZONE has no Dream row -- which boss a slot holds is
-- rerolled every attempt -- so every boss fought in a dive used to send nothing (confirmed live
-- 9/30: "boss encounter start: name=BossPrometheus01 route=Dream zone=1", no check). A region
-- IS a whole vanilla biome played to its own boss, so resolve the biome's native (route, zone)
-- instead. That route needn't be in the seed: send_first drops whatever this seed never
-- generated (check_route_blocked).
local function boss_met_route_zone()
  local route, zone = Routes.current()
  if not route or not ItemManager.route_active(route) then return nil end
  if route == "Dream" then return Routes.biome_current() end
  return route, zone
end

-- Wrapped on StartEncounter (reload.lua). Field-NPC combat encounters (Artemis, Athena,
-- Heracles, ... -- EncounterData_<Name>.lua) carry SpeakerNames = { "<Name>" }. Those NPCs
-- aren't conversations (UseNPC) or loot (HandleLootPickup), so neither hook fired for them
-- (Test Run 5 #3: "Met Artemis didn't fire" in the underworld field encounter). Firing on the
-- encounter start is the moment you meet them. First time only (send_first dedups).
function LocationManager.on_encounter_started(encounter)
  if not ItemManager.setting_on("npc_locations") then return end
  if not encounter then return end
  local data = (encounter.Name and game.EncounterData and game.EncounterData[encounter.Name])
    or encounter
  local speakers = data and data.SpeakerNames
  if type(speakers) == "table" then
    -- Same shop guard as on_loot_pickup (Test Run 6 #5): a SHOP room lists every selling god/NPC
    -- in its encounter SpeakerNames, so walking into e.g. Charon's shop (F_Shop01), where Selene
    -- sells Hexes, fired "Met Selene" prematurely -- before you actually met her. Don't count an
    -- encounter meet while in a shop; the real meet still fires via UseNPC / a non-shop hex pickup
    -- / her own field encounter. (Boss meets below are unaffected -- bosses never spawn in shops.)
    -- 10/4: the "Shop" encounter itself counts as a shop whatever the room rolled. Pre-boss rooms
    -- always run it, and when one rolls a plain reward instead of Charon (F_PreBoss01 with a Pom,
    -- Zagreus' Journey's X_PreBoss01 with a Hammer) there is no Store and the reward isn't "Shop",
    -- so walking in sent "Met Selene" (live 10/3: F_PreBoss01, reward=StackUpgrade).
    local room = game.CurrentRun and game.CurrentRun.CurrentRoom
    local in_shop = encounter.Name == "Shop"
      or (room ~= nil and (room.Store ~= nil or room.ChosenRewardType == "Shop"))
    for _, who in ipairs(speakers) do
      if NPC_CAST_SET[who] then
        if in_shop then
          rom.log.info("[AP] encounter meet suppressed in shop: who=" .. tostring(who)
            .. " encounter=" .. tostring(encounter.Name)
            .. " RoomSetName=" .. tostring(room and room.RoomSetName)
            .. " reward=" .. tostring(room and room.ChosenRewardType))
        else
          rom.log.info("[AP] encounter meet: who=" .. tostring(who)
            .. " encounter=" .. tostring(encounter.Name)
            .. " RoomSetName=" .. tostring(room and room.RoomSetName)
            .. " reward=" .. tostring(room and room.ChosenRewardType))
          send_first("npc_met", NPC_CAST_SET[who])
        end
      end
    end
  end

  -- Boss "Met" (Test Run 6 #7: "Met Hecate" didn't fire in her boss fight). Reading
  -- EncounterType at StartRoom (on_room_started) was unreliable -- the encounter isn't always
  -- resolved that early. Here at StartEncounter the encounter is fully built, and every boss
  -- arena encounter inherits EncounterType == "Boss" (BossEncounter base, EncounterData.lua:913).
  -- Fire the route's zone boss "Met" when a Boss encounter starts. send_first dedups with
  -- on_room_started (whichever wins first).
  local etype = encounter.EncounterType or (data and data.EncounterType)
  if etype == "Boss" then
    local route, zone = Routes.current()
    local met_route, met_zone = boss_met_route_zone()
    rom.log.info("[AP] boss encounter start: name=" .. tostring(encounter.Name)
      .. " route=" .. tostring(route) .. " zone=" .. tostring(zone)
      .. " met=" .. tostring(met_route) .. "/" .. tostring(met_zone))
    if met_route then
      pcall(function() send_boss_met(met_route, met_zone) end)
    end
  end
end

-- Fire a fixed-name NPC/intro check directly (e.g. story beats "SHUSH Homer",
-- "Find Hecate 1"). First time only.
function LocationManager.send_npc_check(name)
  if not ItemManager.setting_on("npc_locations") then return end
  send_first("npc_met", name)
end

-- Wrapped on ApplyErisCurse (reload.lua) - fires once the Underworld "Curse of Eris" ambush's
-- dialogue resolves (ShrineLogic.lua), a reliable meet-signal independent of whether UseNPC
-- fired for that scripted spawn. Same dedup/gate as everything else: send_first only actually
-- sends "Met Eris" when Surface is part of the seed (ROUTE_GATED_CHECKS), so this is a no-op on an
-- Underworld-only seed where the location doesn't exist.
function LocationManager.on_eris_curse_applied()
  if not ItemManager.setting_on("npc_locations") then return end
  send_first("npc_met", "Met Eris")
end

-- The EncounterType of a room's encounter ("Boss", "Miniboss", normal, ...). Boss arenas are
-- the only rooms with EncounterType == "Boss".
local function room_encounter_type(room)
  local enc = room and room.Encounter
  if not enc then return nil end
  return enc.EncounterType
    or (enc.Name and game.EncounterData and game.EncounterData[enc.Name]
        and game.EncounterData[enc.Name].EncounterType)
end

-- Call when a room STARTS (StartRoom hook). Boss "Met" must fire when you actually meet the
-- boss -- i.e. walk into its arena -- NOT the moment you reach the boss's biome (Test Run 5
-- #7: "Met Scylla fired well before I actually met her"). Only the boss arena room has
-- EncounterType == "Boss", so gate on that. First time only (send_first dedups).
function LocationManager.on_room_started(room)
  if not ItemManager.setting_on("npc_locations") then return end
  room = room or (game.CurrentRun and game.CurrentRun.CurrentRoom)
  if room_encounter_type(room) ~= "Boss" then return end
  local route, zone = boss_met_route_zone()
  if not route then return end
  pcall(function() send_boss_met(route, zone) end)
end

-- Clear the overlay's pinned "Room ##" readout when the player is back in the Crossroads hub
-- (sitting there before a run starts, or just dumped back after a run ends). The readout is now
-- driven by the AP room-check logic itself (score_room/score_encounter -> update_room_overlay),
-- which only ever SETS it and never fires in the hub -- so without this explicit clear it would
-- keep showing the last run's number forever. Replaces the old native_room_counter/
-- track_native_room design (a separate literal "rooms entered" counter, independent of AP
-- checks -- see project plan's Overlay decision for why that changed).
function LocationManager.clear_room_overlay_on_hub(room)
  room = room or (game.CurrentRun and game.CurrentRun.CurrentRoom)
  if not room then return end
  local name = room.Name and tostring(room.Name)
  if name and name:match("^Hub") and Overlay and Overlay.set_room then
    Overlay.set_room(nil)
  end
end

-- Score a NON-COMBAT room (reward-only, shop -- Test Run 6 #6 -- or a pure transition/Intro
-- room, ruled 8/4) on ENTER (StartRoom) -- there's no enemy to clear so there's no
-- encounter-clear moment to hook. Combat rooms are scored per-ENCOUNTER
-- instead (see score_encounter below), not here: a room can run several encounters back-to-back
-- (RoomLogic.lua currentRoom.Encounters / MultipleEncountersData) before its exits ever unlock,
-- and each one should earn its own check the moment IT clears rather than making the player wait
-- for the whole cluster. Each room is counted at most once via a flag on the room table
-- (room._ap_scored), so a repeated StartRoom call (e.g. a rejoin) never double-counts.
function LocationManager.score_room(room)
  local s = APState.get()
  if not s then
    rom.log.info("[AP] score room: no save state (APState.get nil) - skipping")
    return
  end
  room = room or (game.CurrentRun and game.CurrentRun.CurrentRoom)
  if not room then return end
  local route, zone = Routes.current()
  if not route then return end                              -- hub / Chaos / non-scored biome
  if not ItemManager.route_active(route) then return end    -- excluded route: no checks
  if Routes.past_last_zone(route, zone) then return end     -- Dream endless: no checks exist
  -- Dream_Intro is a fixed lobby/narration screen (NoReward=true, BlockCombat=true,
  -- SelectNextDreamBiome picks THIS attempt's actual biome from here) that the player passes
  -- through on EVERY Dream Dive attempt, including a bare restart after a death/DeathLink --
  -- unlike every other route's zone-1 room, which is a freshly randomized real room each attempt.
  -- Scoring it here would hand out a free "Dream Room" check on every single restart with zero
  -- actual play (confirmed 8/5: DeathLink death -> immediate restart -> "Dream Room 0004" fired
  -- before the player had done anything but load back into this same static room).
  if route == "Dream" and room.Name == "Dream_Intro" then
    rom.log.info("[AP] score room: Dream_Intro lobby (re-entered every attempt) - no room check")
    return
  end
  -- Don't send room checks for an area the player hasn't unlocked yet (Test Run 8 #1). The
  -- surface-start seed's forced Underworld intro is here before its bounce-to-Crossroads death;
  -- without this it sends "Underworld Room 1" for a zone the player has no access to. Same gate as
  -- the route-lock kill, so a zone that would kill you also never scores.
  if not ItemManager.route_zone_unlocked(route, zone) then
    rom.log.info("[AP] score room: " .. route .. " z" .. tostring(zone)
      .. " not unlocked yet - no room check")
    return
  end
  local system = ItemManager.setting_mode("location_system")
  -- Room entry: move the "Room ##" readout onto the zone the player is standing in now, before
  -- anything in it has scored (a combat room scores only once its encounter clears, so the
  -- readout would otherwise keep naming the previous zone through a new zone's first fight).
  if system == 1 or system == 2 or system == 3 then
    update_room_overlay(route, zone, s.score[route], ItemManager.combine_active())
  end
  if room._ap_scored then return end                        -- already counted this room

  if room_has_combat(room) then return end                  -- combat rooms score via score_encounter

  -- per_weapon/per_aspect checks ("<route> Room NNNN <Weapon>" / "<Aspect> <Weapon> <route>
  -- Room DD") additionally require the equipped weapon to be AP-unlocked (Test Run 8 #1): no
  -- "Staff Underworld Room 1" while the forced intro holds a Staff the player hasn't unlocked.
  -- Checked before counting the room so the depth counter stays in sync.
  if (system == 2 or system == 3) and not ItemManager.equipped_weapon_unlocked() then
    rom.log.info("[AP] score room: equipped weapon not AP-unlocked - no per-weapon/aspect room check")
    return
  end

  room._ap_scored = true
  local pool = s.score[route]
  local depth, local_depth = advance_depth(pool, zone)

  rom.log.info("[AP] score room: RoomSetName=" .. tostring(room.RoomSetName)
    .. " RoomName=" .. tostring(room.Name)
    .. " reward=" .. tostring(room.ChosenRewardType)
    .. " shop=" .. tostring(room_is_shop(room)) .. " -> route=" .. route
    .. " zone=" .. tostring(zone) .. " zone_depth=" .. tostring(local_depth)
    .. " run_depth=" .. depth .. " system=" .. tostring(system))

  -- Boss "Met" fires from on_encounter_started (entering the boss arena), not here.

  dispatch_room_score(route, zone, depth, local_depth, pool, s, system)
end

-- Score ONE encounter the instant it actually PAYS OUT (not when the room finally unlocks its
-- exits, and not merely when combat ends). RoomLogic.lua's StartEncounter loops
-- currentRoom.Encounters for rooms with MultipleEncountersData (confirmed in the installed game's
-- RoomDataO/P.lua -- several Surface/Underworld rooms chain 2+ combat encounters), and exits stay
-- locked (CheckRoomExitsReady) until ALL of them finish. Waiting for UnlockRoomExits meant a
-- multi-encounter room only ever earned ONE check no matter how many fights it actually took.
-- Called from the StartEncounter wrap (reload.lua) the moment each wave is killed -- every
-- completed combat encounter scores (user ruling 8/4), which also covers the rooms that never
-- spawn a reward (Thessaly's NoReward O_Combat rooms, Styx's DeferReward wing rooms, Tartarus'
-- Empty-reward rooms) -- and from the SpawnRoomReward wrap. Dedup'd per encounter instance (encounter._ap_scored) so a re-entrant call is a no-op,
-- same pattern as room._ap_scored.
function LocationManager.score_encounter(room, encounter)
  local s = APState.get()
  if not s then return end
  if not room or not encounter then return end
  if encounter._ap_scored then return end
  if not encounter_is_combat(encounter) then return end     -- NonCombat encounters don't score
  -- Boss phases don't score (user ruling 10/4). A boss summons its add waves as their own
  -- encounters mid-fight (EnemyData SpawnEncounter: HecateSpawns01/02, CerberusSpawns0N, Zagreus'
  -- Journey's HydraHeadsN), so Hecate's arena was worth three rooms and Chronos' one. In a boss
  -- arena only the room's own encounter counts.
  if room_encounter_type(room) == "Boss" and encounter ~= room.Encounter
     and encounter.Name ~= (room.Encounter and room.Encounter.Name) then
    return
  end

  local route, zone = Routes.current()
  if not route then return end                              -- hub / Chaos / non-scored biome
  if not ItemManager.route_active(route) then return end    -- excluded route: no checks
  if Routes.past_last_zone(route, zone) then return end     -- Dream endless: no checks exist
  -- Same unlocked-zone gate as score_room (Test Run 8 #1): never score an area the player hasn't
  -- unlocked yet (e.g. the surface-start seed's forced Underworld intro).
  if not ItemManager.route_zone_unlocked(route, zone) then
    rom.log.info("[AP] score encounter: " .. route .. " z" .. tostring(zone)
      .. " not unlocked yet - no room check")
    return
  end

  local system = ItemManager.setting_mode("location_system")
  -- per_weapon/per_aspect checks additionally require the equipped weapon to be AP-unlocked
  -- (Test Run 8 #1).
  if (system == 2 or system == 3) and not ItemManager.equipped_weapon_unlocked() then
    rom.log.info("[AP] score encounter: equipped weapon not AP-unlocked - no per-weapon/aspect room check")
    return
  end

  encounter._ap_scored = true
  local pool = s.score[route]
  local depth, local_depth = advance_depth(pool, zone)

  rom.log.info("[AP] score encounter: RoomName=" .. tostring(room.Name)
    .. " EncounterName=" .. tostring(encounter.Name) .. " -> route=" .. route
    .. " zone=" .. tostring(zone) .. " zone_depth=" .. tostring(local_depth)
    .. " run_depth=" .. depth .. " system=" .. tostring(system))

  dispatch_room_score(route, zone, depth, local_depth, pool, s, system)
end

-- How many times the route's final boss must be defeated before its goal cascade fires
-- (YAML underworld_wins_needed / surface_wins_needed / nightmare_wins_needed). Defaults to
-- 1 if unset.
local DEFEATS_NEEDED_KEY = {
  Underworld = "underworld_wins_needed", Surface = "surface_wins_needed",
  Nightmare = "nightmare_wins_needed", Dream = "dream_wins_needed",
}
local function defeats_needed(route)
  local key = DEFEATS_NEEDED_KEY[route] or "underworld_wins_needed"
  return tonumber(ItemManager.settings[key]) or 1
end

-- The route's total final-boss clears so far (persisted in APState).
local function route_clears(s, route)
  if route == "Surface" then return s.typhon_clears end
  if route == "Nightmare" then return s.hades_clears end
  -- Dream has no named final boss (its last region's boss is whatever landed in that slot), so
  -- its "clears" counter is full-length run completions -- see on_dream_run_cleared. Without
  -- this branch the fallthrough handed back chronos_clears for Dream, so Dream's goal cascade
  -- would have keyed off the Underworld's progress.
  if route == "Dream" then return s.dream_clears or 0 end
  return s.chronos_clears
end

-- Whether EVERY route that's both active in this seed and required by the goal
-- (goal_requires_chronos/typhon/hades) has independently reached ITS OWN defeats_needed.
-- Under combine_pools the Score/Room pool flushed by flush_route_checks is ONE pool shared
-- by every route, not "that route's own" checks -- so cascading it the moment any single
-- required route finishes (the old behavior) hands out checks that were meant to be earned
-- by continued play on the OTHER, still-in-progress required route(s), then leaves nothing
-- left to earn for the rest of the seed. Gate the shared-pool flush on this instead; the
-- per-route enemy-check flush (flush_route_enemy_checks, genuinely route-scoped by name)
-- is unaffected and still fires as soon as its own route finishes.
-- Keyed per ROUTE, matching the flags Client.encode_settings derives from the goals_required
-- OptionSet. The previous keys here ("goal_requires_chronos"/"_typhon"/"_hades") were named
-- after BOSSES and were never present in any SETTINGS payload, so every lookup read nil and
-- this whole gate silently passed -- see the note in encode_settings. Dream is included now
-- that it has a real cascade of its own (on_dream_run_cleared).
local ROUTE_GOAL_REQUIRED_KEY = {
  Underworld = "goal_requires_underworld", Surface = "goal_requires_surface",
  Nightmare = "goal_requires_nightmare", Dream = "goal_requires_dream",
}
-- A seed generated before those flags existed sends none of them. Don't silently start gating
-- such a seed on "nothing is required" (which reads the same as the old always-true behavior
-- anyway) OR on "everything is required" -- detect their absence explicitly and keep the old
-- permissive result, so only seeds that actually carry the flags get the real check.
local function goals_required_known()
  for _, key in pairs(ROUTE_GOAL_REQUIRED_KEY) do
    if ItemManager.settings[key] ~= nil then return true end
  end
  return false
end
local function all_required_goals_met(s)
  if not goals_required_known() then return true end
  for r, key in pairs(ROUTE_GOAL_REQUIRED_KEY) do
    if ItemManager.route_active(r) and ItemManager.setting_on(key)
       and route_clears(s, r) < defeats_needed(r) then
      return false
    end
  end
  return true
end

-- Goal cascade: once the route's final boss has been defeated the YAML-specified number of
-- times (underworld_wins_needed / surface_wins_needed / nightmare_wins_needed, default 1),
-- the player has
-- "completed" that route's goal, so release every remaining Score/Room check for it instead
-- of making them grind RNG for the last few. point_based flushes every remaining "<route>
-- Score N" (bypassing the points requirement); room_based flushes the route's shared room
-- checks; per_weapon_room_based flushes only the weapon that just cleared the run.
local function flush_route_checks(route, pool)
  local system = ItemManager.setting_mode("location_system")
  if system == 0 then
    -- combine_pools: there are no per-route score checks to flush -- clearing a route's goal
    -- releases the one shared pool instead (the same checks any route would have earned).
    local pool_key, score_pool = LocationManager.score_pool_for(route, APState.get())
    if not score_pool then return end
    local limit = ItemManager.score_limit_for(pool_key)
    local sent = 0
    while score_pool.next_check <= limit do
      if not ItemManager.is_score_checked(pool_key, score_pool.next_check) then
        local check = Routes.SCORE_PREFIX[pool_key] .. " " .. pad4(score_pool.next_check)
        rom.log.info("[AP] check: " .. check .. " (" .. route .. " goal cascade)")
        Bridge.send_check(check)
        sent = sent + 1
      end
      score_pool.next_check = score_pool.next_check + 1
    end
    rom.log.info("[AP] goal cascade: flushed " .. sent .. " " .. pool_key
      .. " score checks (up to " .. limit .. ")")
    return
  end
  -- Split-pool room checks are released per zone when that zone's boss dies
  -- (LocationManager.on_zone_boss_defeated), so only combine_pools' shared pool is left here.
  if not ItemManager.combine_active() then return end
  -- The shared pool's depth is the min across active routes, NOT this route's own count (see
  -- combined_room_limit) -- flushing to the route's own room total here would emit combined checks past
  -- the shared pool's real size for any route deeper than the shallowest one.
  local limit = combined_room_limit()
  -- Each depth releases all location_multiplier slot checks, so a scaled seed's "+k" room
  -- locations are flushed too, not just slot 0.
  if system == 1 then
    do
      -- One shared pool: flush the combined "Room NNNN" checks once (either final boss).
      local cr = APState.get().combined_rooms
      local sent = 0
      for depth = (cr.room_high or 0) + 1, limit do
        sent = sent + send_combined_room_slots(depth)
      end
      cr.room_high = math.max(cr.room_high or 0, limit)
      rom.log.info("[AP] goal cascade: flushed " .. sent .. " combined room checks (up to " .. limit .. ")")
    end
  elseif system == 2 then
    local weapon = ItemManager.current_weapon_short()
    if not weapon then return end
    do
      local cr = APState.get().combined_rooms
      cr.weapon_high = cr.weapon_high or {}
      local sent = 0
      for depth = (cr.weapon_high[weapon] or 0) + 1, limit do
        sent = sent + send_combined_room_slots(depth, weapon)
      end
      cr.weapon_high[weapon] = math.max(cr.weapon_high[weapon] or 0, limit)
      rom.log.info("[AP] goal cascade: flushed " .. sent .. " combined " .. weapon
        .. " room checks (up to " .. limit .. ")")
    end
  elseif system == 3 then
    local weapon, aspect_key = ItemManager.current_aspect_key()
    if not weapon or not aspect_key then return end
    do
      local cr = APState.get().combined_rooms
      cr.aspect_high = cr.aspect_high or {}
      local ckey = weapon .. "|" .. aspect_key
      local sent = 0
      for depth = (cr.aspect_high[ckey] or 0) + 1, limit do
        sent = sent + send_combined_aspect_room_slots(depth, weapon, aspect_key)
      end
      cr.aspect_high[ckey] = math.max(cr.aspect_high[ckey] or 0, limit)
      rom.log.info("[AP] goal cascade: flushed " .. sent .. " combined " .. weapon .. " " .. aspect_key
        .. " room checks (up to " .. limit .. ")")
    end
  end
end

-- Spawn slots too rare to farm, released when their zone's boss falls. Python gates the check
-- each slot yields on that boss (Locations.SPAWN_SLOT_BOSS_GATE, Rules._set_spawn_slot_gates).
-- Fields of Mourning's GeneratedH_Treant2 / GeneratedH_Screamer2 are one reward cage in ten from
-- depth 4, once per run. Zone indices are 1-based (Fields = 3). In shuffled modes the slot
-- yields its shuffle target, so the check sent is EnemySanity.slot_check(slot), not the slot.
local BOSS_RELEASE_SLOTS = {
  Underworld = { [3] = { "Brush-Stalker", "Dread-Wailer" } },
}

local function release_boss_slot_checks(route, zone)
  if not EnemySanity.locations_on() then return end
  local slots = BOSS_RELEASE_SLOTS[route] and BOSS_RELEASE_SLOTS[route][zone]
  if not slots then return end
  for _, slot in ipairs(slots) do
    local check = EnemySanity.slot_check(slot) .. " Defeated"
    send_first("enemy_killed", check)
    rom.log.info("[AP] boss release: " .. route .. " zone " .. zone .. " -> " .. check)
  end
end

-- Zone cascade (2026-09-22): beating a zone's boss sends every unsent room check 1..N in that
-- zone for the lane in use -- plain (room_based), the current weapon (per_weapon) or the current
-- weapon+Aspect (per_aspect) -- and raises that lane's high-water to N. Logic only promises rooms
-- 1..K on zone access (Rules._set_room_tail_rules); K+1..N need the boss, and this is what makes
-- them always obtainable. Split pools only: combine_pools' shared pool and point_based keep
-- the route-goal cascade (flush_route_checks). Idempotent -- a second call finds nothing left.
function LocationManager.on_zone_boss_defeated(route, zone)
  if not route or not zone or zone < 1 then return end
  if Routes.past_last_zone(route, zone) then return end
  -- Every location system: the boss-gated spawn slots above.
  pcall(function() release_boss_slot_checks(route, zone) end)
  if ItemManager.combine_active() then return end
  local system = ItemManager.setting_mode("location_system")
  if system ~= 1 and system ~= 2 and system ~= 3 then return end
  -- Same gates as score_room/score_encounter: no checks for an excluded/locked zone, and no
  -- per-weapon/per-aspect checks on a weapon that isn't AP-unlocked (forced intro runs).
  if not ItemManager.route_active(route) or not ItemManager.route_zone_unlocked(route, zone) then return end
  if (system == 2 or system == 3) and not ItemManager.equipped_weapon_unlocked() then return end
  local s = APState.get()
  local pool = s and s.score and s.score[route]
  if not pool then return end
  local zlimit = Routes.zone_room_count(route, zone)
  local sent, lane = 0, ""
  if system == 1 then
    pool.zone_room_high = pool.zone_room_high or {}
    for depth = (pool.zone_room_high[zone] or 0) + 1, zlimit do
      sent = sent + send_room_slots(route, zone, depth)
    end
    pool.zone_room_high[zone] = math.max(pool.zone_room_high[zone] or 0, zlimit)
  elseif system == 2 then
    local weapon = ItemManager.current_weapon_short()
    if not weapon then return end
    lane = " " .. weapon
    pool.zone_weapon_high = pool.zone_weapon_high or {}
    local key = zone .. "|" .. weapon
    for depth = (pool.zone_weapon_high[key] or 0) + 1, zlimit do
      sent = sent + send_room_slots(route, zone, depth, weapon)
    end
    pool.zone_weapon_high[key] = math.max(pool.zone_weapon_high[key] or 0, zlimit)
  else
    local weapon, aspect_key = ItemManager.current_aspect_key()
    if not weapon or not aspect_key then return end
    lane = " " .. weapon .. " " .. aspect_key
    pool.zone_aspect_high = pool.zone_aspect_high or {}
    local key = zone .. "|" .. weapon .. "|" .. aspect_key
    for depth = (pool.zone_aspect_high[key] or 0) + 1, zlimit do
      sent = sent + send_aspect_room_slots(route, zone, depth, weapon, aspect_key)
    end
    pool.zone_aspect_high[key] = math.max(pool.zone_aspect_high[key] or 0, zlimit)
  end
  if sent > 0 then
    rom.log.info("[AP] zone cascade: " .. route .. " zone " .. zone .. lane .. " -> sent " .. sent
      .. " room checks (up to " .. zlimit .. ")")
  end
end

-- Goal cascade (continued): release every remaining enemy "Defeated" check owned by a
-- completed route, the same way flush_route_checks releases its Score/Room checks -- once
-- you've beaten the route's final boss enough times, don't force grinding out the last few
-- enemy RNG spawns either. Shared-zone enemies (SHARED_ENEMY_CHECKS) are flushed on a
-- NIGHTMARE clear only (July 18): they now exist in the pool only when Nightmare is in the
-- seed (ROUTE_GATED_CHECKS gates them on Nightmare alone), so Nightmare is their owning
-- route for cascade purposes. send_first (existing dedup + route-block guard) does the
-- actual work; this just walks every name the route owns.
local function flush_route_enemy_checks(route)
  if not EnemySanity.locations_on() then return end
  local s = APState.get()
  if not s or not s.enemy_killed then return end
  local include_minibosses = ItemManager.setting_on("include_minibosses")
  local sent = 0
  local function flush_list(names)
    for _, name in ipairs(names) do
      if include_minibosses or not EnemySanity.MINIBOSS_CHECK_NAMES[name] then
        local check = name .. " Defeated"
        if not s.enemy_killed[check] then
          send_first("enemy_killed", check)
          if s.enemy_killed[check] then sent = sent + 1 end
        end
      end
    end
  end
  flush_list(ENEMY_CHECKS_BY_ROUTE[route] or {})
  if route == "Nightmare" then
    flush_list(SHARED_ENEMY_CHECKS)
    -- King Vermin belongs to Nightmare only in a seed without the Underworld route.
    if not ItemManager.route_active("Underworld") then flush_list({ KING_VERMIN_CHECK }) end
  end
  rom.log.info("[AP] goal cascade: flushed " .. sent .. " " .. route .. " enemy checks")
end

-- weapons_clears_needed (Options.py's WeaponsClearsNeeded) is a single variety count shared
-- across every boss, not a per-route quota -- its own docstring's example is "defeating
-- Chronos with the axe and Typhon with the blades would count as 2 weapons," i.e. the union
-- of weapons across ALL route clears. So this unions s.weapons_cleared across Underworld/
-- Surface/Nightmare/Dream instead of counting each route's set on its own (which used to force
-- clearing EVERY route with N different weapons independently -- unsatisfiable for most
-- players at higher settings, and not what the option describes). Dream counts like any other
-- route: generation (Rules._hades2_can_get_victory) already required the weapon variety for a
-- Dream goal, so leaving Dream clears out made a Dream-only seed's count stuck at 0.
local function distinct_weapons_combined(s)
  local seen = {}
  for _, route in ipairs({ "Underworld", "Surface", "Nightmare", "Dream" }) do
    for weapon_id in pairs(s.weapons_cleared[route] or {}) do
      seen[weapon_id] = true
    end
  end
  local n = 0
  for _ in pairs(seen) do n = n + 1 end
  return n
end

-- The goal state line: Chronos clears / distinct weapons, Typhon clears / weapons, Zagreus
-- clears (no weapon-variety requirement -- see Client.py evaluate_goal), then Hades clears /
-- weapons appended last (matches the VICTORY payload's fixed positional order both sides agree on).
-- The weapon-count field is the SAME combined number in all three slots (see
-- distinct_weapons_combined) since it's one shared requirement, not three independent ones.
function LocationManager.victory_payload(s)
  local weapons = distinct_weapons_combined(s)
  -- dream_clears appended as an 8th field (matches Client.py's evaluate_goal parsing, which
  -- reads the first 7 fields via parts[:7] regardless -- so an out-of-date client build still
  -- parses this fine, it just won't see Dream's clear count).
  return "VICTORY:" .. s.chronos_clears .. "-" .. weapons
    .. "-" .. s.typhon_clears .. "-" .. weapons
    .. "-" .. (s.zagreus_clears or 0)
    .. "-" .. (s.hades_clears or 0) .. "-" .. weapons
    .. "-" .. (s.dream_clears or 0)
end

-- Report the goal state after a win. Queued in the save rather than sent bare: Bridge.send drops
-- the line when the client isn't connected, and nothing else re-sends VICTORY until the next win,
-- so a win while the client was closed never registered. Bridge.flush_pending_victory delivers it
-- once connected and the save is verified against the client's seed.
function LocationManager.send_victory()
  local s = APState.get()
  if not s then return end
  s.victory_pending = true
  Bridge.flush_pending_victory()
end

-- Call on arrival in C_Boss01, the Zagreus fight room (reload.lua's SetCurrentRoom hook) --
-- reached by Vanilla/Empowered's contract door and by the Final Challenge redirect alike, so
-- this one hook covers "Met Zagreus" regardless of encounter mode. Mirrors ZAGREUS_MET_LOCATION's
-- npc_locations + goal_requires_zagreus gate (Locations.py setup_location_table_with_settings)
-- -- the latter also matches goal_includes_zagreus() already no-opping the contract spawn/redirect
-- that's the only way into this room, so this location can't exist in the pool without also being
-- reachable. First time only.
function LocationManager.on_zagreus_met()
  if not ItemManager.setting_on("npc_locations") then return end
  if not ItemManager.goal_includes_zagreus() then return end
  send_first("npc_met", "Met Zagreus")
end

-- Call when the secret Zagreus superboss fight is cleared (any encounter mode).
function LocationManager.on_zagreus_cleared()
  local s = APState.get()
  if not s then return end
  s.zagreus_clears = (s.zagreus_clears or 0) + 1
  rom.log.info("[AP] Zagreus cleared (now " .. s.zagreus_clears .. ")")
  -- "Zagreus Defeated" (ZAGREUS_DEFEATED_LOCATION) is a real check distinct from the VICTORY
  -- goal payload below -- mirrors ZAGREUS_MET_LOCATION's npc_locations + goal_requires_zagreus
  -- gate (enemysanity's "_plus_locations" modes here instead of npc_locations).
  if EnemySanity.locations_on() and ItemManager.goal_includes_zagreus() then
    send_first("enemy_killed", "Zagreus Defeated")
  end
  LocationManager.send_victory()
end

-- Call when a full-length Dream Dive run completes (all configured regions cleared without
-- dying). No explicit "Beat Dream" check-send needed -- like every other route's "Beat <Boss>"
-- event location, it's a pure AP-internal event auto-resolved by the generation-time region
-- graph (state.has("Dream Victory", player) becomes true once its access_rule is satisfiable
-- from items the player has already received) -- the mod never Bridge.send_checks any "Beat "
-- name for any route, confirmed by grepping this whole codebase. Only dream_clears (feeding
-- dream_wins_needed client-side, purely for the real "you've won" signal) needs updating here.
-- `weapon_id` is the weapon used, for the shared weapons_clears_needed count (same as
-- on_run_cleared).
function LocationManager.on_dream_run_cleared(weapon_id)
  if not ItemManager.route_active("Dream") then return end
  local s = APState.get()
  if not s then return end
  s.dream_clears = (s.dream_clears or 0) + 1
  if weapon_id then
    s.weapons_cleared["Dream"] = s.weapons_cleared["Dream"] or {}
    s.weapons_cleared["Dream"][weapon_id] = true
  end
  rom.log.info("[AP] Dream run cleared (now " .. s.dream_clears .. ", weapon "
    .. tostring(weapon_id) .. ")")
  -- Goal cascade, same contract every other route gets from on_run_cleared: once Dream has been
  -- completed dream_wins_needed times, release the rest of its Score (and combine_pools Room) checks and its
  -- Enemy/Miniboss/Boss counter locations rather than making the player grind region RNG for the
  -- tail. Dream was the one route with no cascade at all, so a seed could leave its deepest
  -- regions' checks permanently out of reach.
  if s.score["Dream"] and route_clears(s, "Dream") >= defeats_needed("Dream") then
    pcall(function() flush_dream_enemy_checks() end)
    if not ItemManager.combine_active() or all_required_goals_met(s) then
      pcall(function() flush_route_checks("Dream", s.score["Dream"]) end)
    end
  end
  LocationManager.send_victory()
end

-- Call when a run is cleared (final boss defeated). `route` is Underworld (Chronos),
-- Surface (Typhon), or Nightmare (Hades); `weapon_id` is the weapon used, for the goal weapon count.
function LocationManager.on_run_cleared(route, weapon_id)
  local s = APState.get()
  if not s then return end
  -- A Dream Dive's clear belongs to on_dream_run_cleared alone. The else branch below used to
  -- bank it as a Chronos clear (reload.lua's OpenRunClearScreen wrap passed "Dream" here).
  if route == "Dream" then
    rom.log.info("[AP] run cleared: Dream - left to on_dream_run_cleared")
    return
  end
  if route == "Surface" then
    s.typhon_clears = s.typhon_clears + 1
  elseif route == "Nightmare" then
    s.hades_clears = (s.hades_clears or 0) + 1
  else
    s.chronos_clears = s.chronos_clears + 1
  end
  if route and weapon_id then
    s.weapons_cleared[route] = s.weapons_cleared[route] or {}
    s.weapons_cleared[route][weapon_id] = true
  end
  rom.log.info("[AP] run cleared: " .. tostring(route) .. " (weapon " .. tostring(weapon_id) .. ")")
  -- Backstop for the zone cascade (normally fired by the boss encounter's completion): the final
  -- boss is zone 4's boss.
  if route then pcall(function() LocationManager.on_zone_boss_defeated(route, 4) end) end
  -- Goal cascade: once the route's final boss has been defeated the YAML-specified number
  -- of times, release the rest of its Score/Room checks. Idempotent past that point (the
  -- flush already caught everything up to the limit on the run it first triggered).
  -- Under combine_pools the Score/Room side of that flush touches the ONE pool every active
  -- route shares, so it's gated on ALL required routes being done (all_required_goals_met),
  -- not just this one -- see that function's comment. split_pools has no such pool overlap
  -- (each route's checks are genuinely its own), so it still flushes immediately as before.
  -- The enemy-check flush is always route-scoped by name, so it's never gated on the others.
  if route and ItemManager.route_active(route) and s.score[route]
     and route_clears(s, route) >= defeats_needed(route) then
    pcall(function() flush_route_enemy_checks(route) end)
    if not ItemManager.combine_active() or all_required_goals_met(s) then
      pcall(function() flush_route_checks(route, s.score[route]) end)
    end
  end
  LocationManager.send_victory()
end
