return {
  version = 1;
  enabled = true;
  -- Keyboard shortcut to show/hide the on-screen Archipelago overlay (works mid-run, even with
  -- the mod menu closed). Hell2Modding keybind string: a key name, optionally with a modifier,
  -- e.g. "F8", "F7", "Ctrl O", "Shift Insert". Changing this needs a full game restart.
  overlay_toggle_key = "F8";
  -- NOTE: the bridge host/port is NOT here on purpose -- it's a hardcoded constant in Bridge.lua
  -- that must exactly match Client.py's BRIDGE_HOST/BRIDGE_PORT. This file is auto-exposed as an
  -- editable config (chalk.auto) in r2modman's config editor; a player who "just tried changing a
  -- setting" here silently breaks the connection with zero error on either side (confirmed: this
  -- happened in the wild -- TerraFire on Discord, 2026-07-03).
}
