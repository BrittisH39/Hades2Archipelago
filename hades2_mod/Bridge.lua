---@diagnostic disable: lowercase-global
-- Bridge.lua — non-blocking TCP link to the Archipelago Python client.
-- Survives hot-reloads: state lives on the persistent `Bridge` table.

Bridge = Bridge or {}
Bridge.conn = Bridge.conn or nil
Bridge.state = Bridge.state or "disconnected"  -- disconnected | connecting | connected
Bridge.retry_frames = Bridge.retry_frames or 0  -- frames until next reconnect attempt
Bridge.handlers = Bridge.handlers or {}        -- command(string) -> function(payload)
Bridge.driver_started = Bridge.driver_started or false

local function log_info(msg) rom.log.info("[AP] " .. msg) end
local function log_error(msg) rom.log.error("[AP] " .. msg) end

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
  if not socket_warned then
    socket_warned = true
    log_error("LuaSocket unavailable (require('socket') and rom['socket.core'] both failed).")
  end
  return false
end

-- delay_frames ~ 120 is about 2s at 60fps; we're driven once per render frame.
local function reset(delay_frames)
  if Bridge.state == "connected" then
    rom.log.info("[AP] bridge disconnected (will retry)")
  end
  if Bridge.conn then pcall(function() Bridge.conn:close() end) end
  Bridge.conn = nil
  Bridge.state = "disconnected"
  Bridge.retry_frames = delay_frames or 120
end

-- Register a handler for a client->mod command (e.g. "ITEMS", "SETTINGS").
function Bridge.on(command, fn)
  Bridge.handlers[command] = fn
end

-- Send one line to the client. Returns true on success.
function Bridge.send(line)
  if Bridge.state ~= "connected" or not Bridge.conn then return false end
  local ok = Bridge.conn:send(line .. "\n")
  if not ok then
    reset()
    return false
  end
  -- A check we send is surfaced when the client echoes CHECKED back with the
  -- "<player> - <item>" detail (see the CHECKED handler in reload.lua), so we can name
  -- who got what in the corner log — not here on the bare send.
  return true
end

function Bridge.is_connected()
  return Bridge.state == "connected"
end

local function start_connect()
  local sock = socket.tcp()
  if not sock then reset() return end
  sock:settimeout(0)               -- fully non-blocking
  sock:connect(config.host, config.port)  -- returns immediately while connecting
  Bridge.conn = sock
  Bridge.state = "connecting"
end

local function poll_connecting()
  -- The socket becomes writable once the connect attempt resolves.
  local _, writable = socket.select(nil, { Bridge.conn }, 0)
  if writable and writable[1] then
    if Bridge.conn:getpeername() then
      Bridge.state = "connected"
      log_info("Connected to Archipelago client.")
      Bridge.send("HELLO")
    else
      reset()  -- connect failed; back off and retry
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
        reset()          -- "closed" or socket error
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
    local ok = sock:connect(config.host, config.port)
    if not ok then pcall(function() sock:close() end); reset(); return false end
    Bridge.conn = sock
    Bridge.state = "connected"
    log_info("blocking connect (pre-run settings fetch).")
    Bridge.send("HELLO")
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
  end
end
