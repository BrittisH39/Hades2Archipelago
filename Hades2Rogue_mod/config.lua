return {
  version = 1;
  enabled = true;
  -- Where the Archipelago Python client is listening (see Client.py BRIDGE_*).
  host = "127.0.0.1";
  port = 43055;
  -- How often (seconds) to poll the socket and retry connections.
  poll_interval = 0.1;
  -- Keyboard shortcut to show/hide the on-screen Archipelago overlay (works mid-run, even with
  -- the mod menu closed). Hell2Modding keybind string: a key name, optionally with a modifier,
  -- e.g. "F8", "F7", "Ctrl O", "Shift Insert". Changing this needs a full game restart.
  overlay_toggle_key = "F8";
}
