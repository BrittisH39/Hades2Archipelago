---@diagnostic disable: lowercase-global
-- Bridge.lua — non-blocking TCP link to the Archipelago Python client.
-- Survives hot-reloads: state lives on the persistent `Bridge` table.

-- Hardcoded (NOT in config.lua) -- must exactly match Client.py's BRIDGE_HOST/BRIDGE_PORT.
-- config.lua is auto-exposed as an editable file in r2modman's config editor; a player who
-- changes host/port there breaks the connection with no error on either side (this happened
-- in the wild: TerraFire on Discord, 2026-07-03, changed the port and lost an hour to it).
local BRIDGE_HOST = "127.0.0.1"
local BRIDGE_PORT = 43055
Bridge = Bridge or {}

-- This mod's own version, read from the manifest.json r2modman installed next to these files, so
-- it can't drift from the package version the way a separate constant would. "unknown" if the file
-- can't be read (a hand-copied install without it); the client reports that instead of comparing.
local function read_mod_version()
  local folder = _PLUGIN and _PLUGIN.plugins_mod_folder_path
  if not folder then return "unknown" end
  local f = io.open(rom.path.combine(folder, "manifest.json"), "r")
  if not f then return "unknown" end
  local text = f:read("*a") or ""
  f:close()
  local v = text:match('"version_number"%s*:%s*"([^"]+)"')
  -- Keep it to version characters: it rides inside HELLO's comma-separated list.
  v = v and v:gsub("[^%w%.%-%+]", "")
  return (v and v ~= "") and v or "unknown"
end
local ok_version, mod_version = pcall(read_mod_version)
Bridge.mod_version = ok_version and mod_version or "unknown"

-- Sent on every (re)connect. The payload lists the optional messages this build understands, so a
-- client only sends them to a mod that handles them ("journal" = the JOURNAL tracker pages,
-- "alert" = ALERT banners; a mod without one would log each as an unhandled message), plus
-- "version=<manifest version>" for the client's version check. Older clients ignore the payload.
local HELLO = "HELLO:journal,alert,version=" .. Bridge.mod_version
Bridge.conn = Bridge.conn or nil
Bridge.state = Bridge.state or "disconnected"  -- disconnected | connecting | connected
Bridge.retry_frames = Bridge.retry_frames or 0  -- frames until next reconnect attempt
Bridge.handlers = Bridge.handlers or {}        -- command(string) -> function(payload)
Bridge.driver_started = Bridge.driver_started or false
-- The client's SEED payload (its multiworld's seed name) on the CURRENT connection; nil until it
-- arrives. Cleared on every disconnect, since the client may be on a different multiworld when the
-- link comes back. Nothing tied to a save (queued checks, VICTORY) is sent until the loaded save
-- has been matched against it -- see Bridge.verify_save.
Bridge.seed_id = Bridge.seed_id or nil

-- Diagnostics surfaced in the overlay (see Overlay.set_diag / reload.lua). last_error is
-- a human-readable reason for the most recent failure; trying_since is when the CURRENT
-- run of failed attempts started (cleared on a successful connect), so the overlay can
-- show "still trying after Ns" instead of alarming on every routine 1-frame reconnect.
Bridge.last_error = Bridge.last_error or nil
Bridge.attempts = Bridge.attempts or 0
Bridge.trying_since = Bridge.trying_since or os.clock()

local function log_info(msg) rom.log.info("[AP] " .. msg) end
local function log_error(msg) AP_log_error(msg) end

-- Log the target address unconditionally, once, regardless of how the connect goes -- so a
-- LogOutput.log dump always shows what the mod is configured for, not just whether it worked.
-- (This alone would've immediately caught a player-edited port instead of an hour of guessing.)
if not Bridge.startup_logged then
  Bridge.startup_logged = true
  log_info("bridge target: " .. BRIDGE_HOST .. ":" .. BRIDGE_PORT)
  log_info("mod version: " .. Bridge.mod_version)
end

-- LuaSocket access path varies in ReturnOfModding (rom.socket may be nil; the
-- library is also exposed via require). Resolve it lazily and cache it, so a
-- momentary nil never crashes the mod.
local socket = nil
local socket_warned = false

local function ensure_socket()
  if socket then return true end
  -- Hell2Modding exposes the high-level module via require('socket') and the
  -- low-level C core on the rom table under the literal key "socket.core".
  -- Either has tcp()/select()/connect()/buffered receive, which is all we use.
  local ok, lib = pcall(require, "socket")
  if ok and type(lib) == "table" and lib.tcp then
    socket = lib
    log_info("LuaSocket acquired via require('socket').")
    return true
  end
  if rom and rom["socket.core"] and rom["socket.core"].tcp then
    socket = rom["socket.core"]
    log_info("LuaSocket acquired via rom['socket.core'].")
    return true
  end
  if rom and rom.socket and rom.socket.tcp then
    socket = rom.socket
    log_info("LuaSocket acquired via rom.socket.")
    return true
  end
  Bridge.last_error = "LuaSocket unavailable (Hell2Modding install may be missing/outdated)"
  if not socket_warned then
    socket_warned = true
    log_error("LuaSocket unavailable (require('socket') and rom['socket.core'] both failed).")
  end
  return false
end

-- delay_frames ~ 120 is about 2s at 60fps; we're driven once per render frame.
-- reason (optional): human-readable cause, surfaced by Bridge.status_text() in the overlay.
local function reset(delay_frames, reason)
  if Bridge.state == "connected" then
    rom.log.info("[AP] bridge disconnected (will retry)")
  end
  if Bridge.conn then pcall(function() Bridge.conn:close() end) end
  Bridge.conn = nil
  Bridge.state = "disconnected"
  Bridge.seed_id = nil
  Bridge.retry_frames = delay_frames or 120
  Bridge.attempts = Bridge.attempts + 1
  if reason then Bridge.last_error = reason end
  if not Bridge.trying_since then Bridge.trying_since = os.clock() end
end

-- Register a handler for a client->mod command (e.g. "ITEMS", "SETTINGS").
function Bridge.on(command, fn)
  Bridge.handlers[command] = fn
end

-- Each ALERT text is shown once per game session. The client resends it on every bridge connection,
-- and the mod's whole Lua state (this table included) is rebuilt on every save load, so what was
-- shown is kept in a file next to the settings cache, tagged with when this game process started:
-- os.clock() counts from process start (wall time on Windows, as Bridge.status_text assumes), so
-- os.time() - os.clock() holds for the whole session and changes after a restart. Anything that
-- goes wrong here shows the banner again rather than hiding it.
local ALERTS_FILE = "Hades2RogueArchipelago.apalerts"
Bridge.alerts_shown = Bridge.alerts_shown or {}   -- fallback when the file can't be used

local function game_session_start()
  return math.floor(os.time() - os.clock() + 0.5)
end

local function alerts_path()
  local ok, p = pcall(function() return rom.path.combine(rom.paths.config(), ALERTS_FILE) end)
  return ok and p or nil
end

-- The texts already shown this session, from the file (empty if it's from an earlier session).
local function load_alerts_shown(path, start)
  local shown = {}
  local f = path and io.open(path, "r")
  if not f then return shown end
  local first = f:read("*l")
  if tonumber(first) and math.abs(tonumber(first) - start) <= 2 then
    for line in f:lines() do shown[line] = true end
  end
  f:close()
  return shown
end

local function save_alerts_shown(path, start, shown)
  local f = path and io.open(path, "w")
  if not f then return end
  f:write(tostring(start), "\n")
  for text in pairs(shown) do f:write(text, "\n") end
  f:close()
end

-- ALERT:<text> -- something the player has to fix outside the game (a mod/apworld/seed version
-- mismatch, a check the seed doesn't know). The client writes the text; we show it on the big
-- banner and log it, so it is in LogOutput.log when the player sends logs.
Bridge.on("ALERT", function(payload)
  if not payload or payload == "" then return end
  payload = payload:gsub("[\r\n]", " ")
  if Bridge.alerts_shown[payload] then return end
  local path, start = alerts_path(), game_session_start()
  local ok, shown = pcall(load_alerts_shown, path, start)
  if ok and shown[payload] then
    Bridge.alerts_shown[payload] = true
    return
  end
  Bridge.alerts_shown[payload] = true
  if ok then
    shown[payload] = true
    pcall(save_alerts_shown, path, start, shown)
  end
  log_error("client alert: " .. payload)
  if Notifications then Notifications.push("warning", payload) end
end)

-- Send one line to the client. Returns true on success.
-- (A check we send is surfaced when the client echoes CHECKED back with the
-- "<player> - <item>" detail — see the CHECKED handler in reload.lua — so we can name
-- who got what in the corner log, not here on the bare send.)
function Bridge.send(line)
  if Bridge.state ~= "connected" or not Bridge.conn then return false end
  local data = line .. "\n"
  -- A non-blocking send can stop partway (nil, "timeout", <bytes sent>) if the OS buffer
  -- is momentarily full; sending only the head of a line would corrupt the newline-delimited
  -- protocol. Resume from the last sent byte, briefly waiting for writability. On loopback
  -- with short lines this loop is all but theoretical, but correctness is cheap.
  local from = 1
  for _ = 1, 20 do
    local last, err, partial = Bridge.conn:send(data, from)
    if last then return true end
    if err ~= "timeout" then
      reset(nil, "send failed: " .. tostring(err))
      return false
    end
    from = (partial or (from - 1)) + 1
    socket.select(nil, { Bridge.conn }, 0.05)   -- wait (<=50ms) until writable again
  end
  reset(nil, "send stalled (client not reading)")   -- couldn't flush one line after ~1s
  return false
end

function Bridge.is_connected()
  return Bridge.state == "connected"
end

-- Queue a location check for GUARANTEED eventual delivery, instead of firing Bridge.send and
-- discarding the result. Bridge.send returns false immediately whenever the socket isn't
-- connected (line ~98) -- every direct "CHECK:" caller used to ignore that, so a check earned
-- during a disconnect (or the brief gap right after a mid-run mod update/reload) got permanently
-- marked "already sent" in the caller's own dedup/high-water-mark bookkeeping in APState, with
-- nothing ever having reached the client. That bookkeeping already advanced by the time this is
-- called (it has to -- it's what makes re-clearing the same room idempotent) and is correct as-is;
-- the fix is to decouple DELIVERY from it. Queued in APState.pending_checks (part of the actual
-- game save), so this survives disconnects, reconnects, and full game restarts -- flush_pending_checks
-- keeps retrying every entry until it's actually sent, however long that takes.
function Bridge.send_check(name)
  local s = APState.get()
  if not s then return end          -- no save loaded (shouldn't happen -- callers already needed one)
  s.pending_checks = s.pending_checks or {}
  for _, n in ipairs(s.pending_checks) do
    if n == name then return end    -- already queued, don't double up
  end
  table.insert(s.pending_checks, name)
  -- Try to flush right away -- the common case (connected, save verified) sends it this same call
  -- with zero added delay; otherwise this just leaves it queued for later.
  Bridge.flush_pending_checks()
end

-- True once the loaded save has been matched against this connection's SEED by Bridge.verify_save,
-- the only place that sets last_seed_id to the live seed.
function Bridge.save_verified(s)
  return s ~= nil and Bridge.seed_id ~= nil and s.last_seed_id == Bridge.seed_id
end

-- Match the loaded save against this connection's SEED. A save last synced to a different seed was
-- reused across multiworlds, so its AP state is wiped (the RESET debug command's wipe) before any of
-- it can leak into this seed. A save that has never seen a SEED (brand new, or older than the SEED
-- message) is adopted as-is, but a VICTORY it still owes is dropped: nothing ties its recorded clears
-- to this seed, and a goal completion can't be undone. No-op until both a save and a SEED exist, so
-- the SEED handler (reload.lua) and Bridge.update's per-frame call together cover a save loaded
-- after SEED arrived (the bridge can connect at the main menu). Returns true when it wiped the save.
function Bridge.verify_save()
  local s = APState.get()
  if not s or Bridge.seed_id == nil or s.last_seed_id == Bridge.seed_id then return false end
  local wiped = false
  if s.last_seed_id then
    log_info("seed changed (" .. tostring(s.last_seed_id) .. " -> " .. Bridge.seed_id
      .. ") -- this save was tracking a different multiworld; wiping AP state before it applies")
    -- reset_applied zeroes the counters and queues before its game-state re-locks, so a failure
    -- there still leaves nothing stale to send. Marking the save below either way keeps this from
    -- retrying (and logging) every frame.
    local ok, err = pcall(ItemManager.reset_applied)
    if not ok then log_error("seed-change wipe failed: " .. tostring(err)) end
    -- Not part of reset_applied: the RESET debug command replays the same seed's ITEMS list,
    -- and the trap ledger is what keeps that from firing every trap again.
    if Traps then pcall(Traps.wipe) end
    wiped = true
  elseif s.victory_pending then
    s.victory_pending = false
    log_info("save had no seed on record; dropped its unsent VICTORY rather than report it to seed "
      .. Bridge.seed_id)
  end
  s.last_seed_id = Bridge.seed_id
  return wiped
end

-- Drain the pending-checks queue in order. Stops at the first failed send: Bridge.send's own
-- reset() already tears the connection down on failure, so state flips to "disconnected" and
-- every subsequent attempt this pass would fail identically -- no point spinning through the rest.
-- Safe to call every frame (Bridge.update). Holds everything until the save is verified against
-- this connection's SEED, so a save reused from another multiworld can't check this one's
-- same-named locations before the SEED handler wipes its queue.
function Bridge.flush_pending_checks()
  if Bridge.state ~= "connected" then return end
  local s = APState.get()
  if not s or not s.pending_checks or not Bridge.save_verified(s) then return end
  while #s.pending_checks > 0 do
    local name = s.pending_checks[1]
    if not Bridge.send("CHECK:" .. name) then break end
    table.remove(s.pending_checks, 1)
    rom.log.info("[AP] check flushed from queue: " .. name)
  end
end

-- Deliver the goal state owed since the last win (LocationManager.send_victory sets
-- victory_pending). The payload is built now, so several wins while offline go out as one report
-- of the latest counts. Same verified-save gate as checks.
function Bridge.flush_pending_victory()
  if Bridge.state ~= "connected" then return end
  local s = APState.get()
  if not s or not s.victory_pending or not Bridge.save_verified(s) then return end
  local line = LocationManager.victory_payload(s)
  if Bridge.send(line) then
    s.victory_pending = false
    log_info("sent " .. line)
  end
end

-- One-line diagnostic for the overlay/UI: nil while connected (or still within the first
-- few seconds of trying, so a normal client-boot race doesn't flash a scary message).
-- Otherwise "<reason> (Ns, N attempts)" from the most recent failure.
local DIAG_GRACE_SECONDS = 8
function Bridge.status_text()
  if Bridge.state == "connected" then return nil end
  local since = Bridge.trying_since or os.clock()
  local elapsed = os.clock() - since
  if elapsed < DIAG_GRACE_SECONDS then return nil end
  local why = Bridge.last_error or ("no response from " .. tostring(BRIDGE_HOST) .. ":" .. tostring(BRIDGE_PORT))
  return string.format("Not connected to AP client (%ds, %d attempt%s): %s",
    math.floor(elapsed), Bridge.attempts, Bridge.attempts == 1 and "" or "s", why)
end

local function start_connect()
  local sock = socket.tcp()
  if not sock then reset(nil, "socket.tcp() failed") return end
  sock:settimeout(0)               -- fully non-blocking
  sock:connect(BRIDGE_HOST, BRIDGE_PORT)  -- returns immediately while connecting
  Bridge.conn = sock
  Bridge.state = "connecting"
end

local function poll_connecting()
  -- The socket becomes writable once the connect attempt resolves.
  local _, writable = socket.select(nil, { Bridge.conn }, 0)
  if writable and writable[1] then
    if Bridge.conn:getpeername() then
      Bridge.state = "connected"
      Bridge.attempts = 0
      Bridge.last_error = nil
      Bridge.trying_since = nil
      log_info("Connected to Archipelago client.")
      -- The client answers with SEED; any backlog from the outage drains once that verifies the
      -- save (Bridge.update, same frame as the SEED line is read).
      Bridge.send(HELLO)
    else
      -- getpeername() fails when the connect itself failed (refused/unreachable) rather
      -- than the link dropping later, so this is almost always "no client listening yet".
      reset(nil, "connection refused (no Archipelago client listening on "
        .. tostring(BRIDGE_HOST) .. ":" .. tostring(BRIDGE_PORT) .. ")")
    end
  end
end

local function poll_connected()
  local readable = socket.select({ Bridge.conn }, nil, 0)
  if readable and readable[1] then
    while true do
      local line, err = Bridge.conn:receive("*l")
      if line then
        Bridge.dispatch(line)
      elseif err == "timeout" then
        break            -- no more complete lines buffered right now
      else
        reset(nil, err == "closed" and "client closed the connection" or ("socket error: " .. tostring(err)))
        return
      end
    end
  end
end

function Bridge.dispatch(line)
  local command, payload = line:match("^([^:]*):?(.*)$")
  local handler = Bridge.handlers[command]
  if handler then
    local ok, err = pcall(handler, payload)
    if not ok then log_error("handler '" .. tostring(command) .. "' error: " .. tostring(err)) end
  else
    log_info("unhandled message: " .. line)
  end
end

-- Synchronously (blocking, bounded) ensure a connection and pull the SETTINGS line right now.
-- The per-frame poll driver only runs once the game renders GAMEPLAY (the render callback doesn't
-- tick at the main menu or during loads), so without this the mod has no settings until after the
-- first run is already built -- too late for the starting weapon. Called from the StartNewRun hook
-- when settings are still missing. Safe: a bounded LuaSocket timeout, NOT the game's thread()/wait()
-- (which is what froze loads before); a synchronous socket read just blocks up to `total_timeout`.
function Bridge.fetch_blocking(total_timeout)
  total_timeout = total_timeout or 1.5
  if not ensure_socket() then return false end
  if Bridge.state ~= "connected" or not Bridge.conn then
    if Bridge.conn then pcall(function() Bridge.conn:close() end) end
    local sock = socket.tcp()
    if not sock then reset(); return false end
    sock:settimeout(total_timeout)
    local ok = sock:connect(BRIDGE_HOST, BRIDGE_PORT)
    if not ok then pcall(function() sock:close() end); reset(); return false end
    Bridge.conn = sock
    Bridge.state = "connected"
    log_info("blocking connect (pre-run settings fetch).")
    Bridge.send(HELLO)
  end
  -- Read lines until SETTINGS has been dispatched (and the follow-up ITEMS/score lines drained),
  -- or the budget runs out. First read waits up to the full budget (covers the HELLO round-trip);
  -- once data flows, short per-read timeouts drain the rest without stalling.
  local got = false
  pcall(function() Bridge.conn:settimeout(total_timeout) end)
  for _ = 1, 100 do
    local line, err = Bridge.conn:receive("*l")
    if line then
      Bridge.dispatch(line)
      if line:sub(1, 9) == "SETTINGS:" then got = true end
      pcall(function() Bridge.conn:settimeout(0.3) end)
    elseif err == "timeout" then
      break
    else
      reset()
      break
    end
  end
  if Bridge.conn then pcall(function() Bridge.conn:settimeout(0) end) end  -- restore non-blocking
  return got
end

-- Drive the connection state machine. Called once per render frame (reload.lua).
function Bridge.update()
  if not ensure_socket() then return end
  if Bridge.state == "disconnected" then
    Bridge.retry_frames = Bridge.retry_frames - 1
    if Bridge.retry_frames <= 0 then
      start_connect()
    end
  elseif Bridge.state == "connecting" then
    poll_connecting()
  elseif Bridge.state == "connected" then
    poll_connected()
    -- A save loaded after this connection's SEED is matched here. If that wiped it, ask for a fresh
    -- sync so SETTINGS/ITEMS re-apply to the wiped save (the SEED handler's own wipe is always
    -- followed by SETTINGS; this one isn't).
    if Bridge.verify_save() then Bridge.send(HELLO) end
    Bridge.flush_pending_checks()   -- safety net: catches anything still queued between sends
    Bridge.flush_pending_victory()
  end
end
