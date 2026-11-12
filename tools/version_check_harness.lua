-- Offline check of Bridge.lua's version report and ALERT banner (0.11.0 group D).
--   lua tools/version_check_harness.lua
-- Loads the real Bridge.lua with stubbed rom/_PLUGIN/socket/Notifications, then checks that:
--   * the mod version comes from manifest.json, and "unknown" when there's no manifest;
--   * HELLO carries journal, alert and version=<that version>;
--   * ALERT:<text> queues a "warning" banner and logs it, once per game session: not again on the
--     same connection, after a save load (a fresh Lua state), or on a reconnect; again after a
--     game restart, and for a different text. A cache file it can't write shows it again.
local here = (arg and arg[0] or ""):match("^(.*)[/\\]") or "."
local MOD = here .. "/../Hades_2_Archipelago/Hades2Rogue_mod/"

local failures, passes = 0, 0
local function check(cond, label)
  if cond then passes = passes + 1 else failures = failures + 1; print("FAIL: " .. label) end
end

-- The game process: os.clock() counts from its start, and the cache file lives in config_dir.
local TEMP = (os.getenv("TEMP") or os.getenv("TMPDIR") or "."):gsub("\\", "/")
local config_dir = TEMP
local ALERTS = config_dir .. "/Hades2RogueArchipelago.apalerts"
os.remove(ALERTS)
local now, process_start = 1800000000, 1800000000 - 40
os.time = function() return now end
os.clock = function() return now - process_start + 0.37 end

local logs, sent, banners
local function load_bridge(mod_folder)
  logs, sent, banners = {}, {}, {}
  rom = {
    log = { info = function(m) logs[#logs + 1] = m end, warning = function(m) logs[#logs + 1] = m end },
    path = { combine = function(a, b) return a .. "/" .. b end },
    paths = { config = function() return config_dir end },
  }
  _PLUGIN = { plugins_mod_folder_path = mod_folder }
  function AP_log_error(m) logs[#logs + 1] = "ERROR " .. m end
  Notifications = { push = function(kind, text) banners[#banners + 1] = { kind = kind, text = text } end }
  -- A socket that connects at once and records every line sent.
  local conn = {
    settimeout = function() end, connect = function() return 1 end, close = function() end,
    getpeername = function() return "127.0.0.1" end,
    send = function(_, data, from) sent[#sent + 1] = data:sub(from or 1); return #data end,
    receive = function() return nil, "timeout" end,
  }
  local socket = { tcp = function() return conn end,
                   select = function(r, w) if w then return nil, { conn } end return {} end }
  package.loaded["socket"] = socket
  APState = { get = function() return nil end }
  Bridge = nil
  dofile(MOD .. "Bridge.lua")
  return logs, sent, banners
end
-- A save load: the game rebuilds the mod's whole Lua state, in the same process.
local function save_load() load_bridge(MOD) end

-- 1. Version from the real manifest.json.
local manifest = io.open(MOD .. "manifest.json"):read("*a")
local expected = manifest:match('"version_number"%s*:%s*"([^"]+)"')
load_bridge(MOD)
check(Bridge.mod_version == expected, "mod_version " .. tostring(Bridge.mod_version) .. " == manifest " .. tostring(expected))
local logged = false
for _, l in ipairs(logs) do if l:find("mod version: " .. expected, 1, true) then logged = true end end
check(logged, "startup log names the mod version")

-- 2. HELLO on connect.
Bridge.retry_frames = 0
Bridge.update()   -- disconnected -> connecting
Bridge.update()   -- connecting -> connected, sends HELLO
check(Bridge.state == "connected", "bridge connected (state " .. tostring(Bridge.state) .. ")")
local hello = sent[1] and sent[1]:gsub("\n$", "")
check(hello == "HELLO:journal,alert,version=" .. expected, "HELLO line: " .. tostring(hello))
local caps = {}
for c in (hello or ""):gsub("^HELLO:", ""):gmatch("[^,]+") do caps[c] = true end
check(caps["journal"] and caps["alert"] and caps["version=" .. expected], "HELLO capabilities parse")

-- 3. ALERT -> warning banner + log line.
Bridge.dispatch("ALERT:Version mismatch: mod 0.10.0, apworld 0.11.0, seed 0.11.0")
check(#banners == 1 and banners[1].kind == "warning", "ALERT queued one warning banner")
check(banners[1] and banners[1].text == "Version mismatch: mod 0.10.0, apworld 0.11.0, seed 0.11.0",
  "ALERT banner text passed through")
local alert_logged = false
for _, l in ipairs(logs) do if l:find("client alert: Version mismatch", 1, true) then alert_logged = true end end
check(alert_logged, "ALERT logged to LogOutput")
Bridge.dispatch("ALERT:")
check(#banners == 1, "empty ALERT ignored")

-- 4. Once per game session.
local X = "ALERT:Version mismatch: mod 0.10.0, apworld 0.11.0, seed 0.11.0"
Bridge.dispatch(X)
check(#banners == 1, "same text, same connection: not shown again")
now = now + 300
save_load()
Bridge.dispatch(X)
check(#banners == 0, "same text after a save load (fresh Lua state): not shown again")
Bridge.retry_frames = 0; Bridge.update(); Bridge.update()
Bridge.dispatch(X)
check(#banners == 0, "same text after a reconnect: not shown again")
Bridge.dispatch("ALERT:Check not in this seed: Surface Room 0001")
check(#banners == 1, "a different text: shown")
save_load()
Bridge.dispatch("ALERT:Check not in this seed: Surface Room 0001")
Bridge.dispatch(X)
check(#banners == 0, "both texts remembered across another save load")
now, process_start = now + 7200, now + 7200 - 25    -- quit and restart the game
save_load()
Bridge.dispatch(X)
check(#banners == 1, "after a game restart: shown again")
save_load()
Bridge.dispatch(X)
check(#banners == 0, "and remembered for the new session")
-- No usable cache file: never hide it, just don't repeat it within one Lua state.
os.remove(ALERTS)
config_dir = TEMP .. "/no_such_folder_h2r"
save_load()
Bridge.dispatch(X)
Bridge.dispatch(X)
check(#banners == 1, "no cache file: shown, once per Lua state")
save_load()
Bridge.dispatch(X)
check(#banners == 1, "no cache file: shown again after a save load (fails open)")
config_dir = TEMP
os.remove(ALERTS)

-- 5. No manifest -> "unknown", still a valid HELLO token.
load_bridge(here .. "/no_such_folder")
check(Bridge.mod_version == "unknown", "missing manifest gives unknown (" .. tostring(Bridge.mod_version) .. ")")
load_bridge(nil)
_PLUGIN = nil
Bridge = nil
dofile(MOD .. "Bridge.lua")
check(Bridge.mod_version == "unknown", "no _PLUGIN gives unknown")

print(string.format("%d passed, %d failed", passes, failures))
os.exit(failures == 0 and 0 or 1)
