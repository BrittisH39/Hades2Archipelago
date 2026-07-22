---@meta _
---@diagnostic disable: lowercase-global
-- One-time setup (not re-run on hot-reload). Load our modules once; all the
-- live wiring happens in reload.lua so it can be iterated on without restarting.

import 'APState.lua'
import 'Routes.lua'
import 'Overlay.lua'
import 'Notifications.lua'
import 'Bridge.lua'
import 'ItemManager.lua'
import 'LocationManager.lua'

rom.log.info("[AP] Hades II Archipelago plugin loaded.")

-- Apply the load-time-critical settings from the on-disk cache NOW, at boot, before the player can
-- start a new game. The live connection only delivers SETTINGS after a save loads (the socket poll
-- runs on the render loop, which doesn't tick at the menu), which is too late for a fresh save's
-- intro run -- so the starting weapon reads from the last session's cached settings here instead.
-- The cache also backstops the fresh-save intro redirect (ItemManager.redirect_intro_args reads
-- settings at StartNewRun if the live blocking fetch can't reach the client). Safe no-op if
-- there's no cache yet (first ever connect).
pcall(function() ItemManager.apply_cached_settings() end)
