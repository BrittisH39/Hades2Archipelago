"""
Standalone bridge test server — stands in for the real Archipelago client.

It listens on the bridge port, prints every message the Hades II mod sends, and
lets you type messages to send back. No Archipelago install required, so it's a
clean way to verify the in-game socket bridge on its own.

The mod reconnects whenever the game does a major reload (e.g. loading a save),
so this server accepts reconnections continuously and always talks to the most
recent connection.

Usage:
    python tools/fake_client.py

Then launch Hades II (with the mod installed). You should see "HELLO" arrive.
Type commands at the prompt to push state to the game, e.g.:
    SETTINGS:ashes_pack_value=100;psyche_pack_value=20;bones_pack_value=20;nectar_pack_value=2
    ITEMS:Nectar
    ITEMS:Nectar|Bones|Staff Weapon Unlock Item
    DEATH:SomePlayer
    TRAP:Sheep Trap                                 (fire a trap now, as a test; no item needed)
    CHECKEDSCORE:underworld=100,101;surface=        (point_based: skip these for free)
    ALERT:Version mismatch test                     (big in-game banner; needs a 0.11.0+ mod.
                                                     Each text shows once per game session: sending
                                                     it again, or after a save load, shows nothing;
                                                     restart the game or change the text to see it)
The game's HELLO shows its version: HELLO:journal,alert,version=<manifest.json version>.
Type 'quit' to exit.

To test "sent score checks don't consume score" (point_based): with score_rewards_amount
high enough, send e.g. `CHECKEDSCORE:underworld=100;surface=` and clear rooms in-game. When
the route's pool reaches check 99 it sends 99 (paid), free-skips 100 (already checked -> no
CHECK arrives here for it), and lands on 101. The mod stops at the first UNCHECKED number it
can't yet afford. The set is replaced on each CHECKEDSCORE you send.

See hades_2/PROTOCOL.md for the full message protocol.
"""
import socket
import threading

HOST = "127.0.0.1"
PORT = 43055

# Sent automatically when the mod connects, so item grants have pack values.
DEFAULT_SETTINGS = ("SETTINGS:initial_weapon=0;score_rewards_amount=150;weaponsanity=1;"
                    "graspsanity=1;grasp_intervals=5;arcanasanity=2;"
                    "aspectsanity=2;keepsakesanity=1;petsanity=1;"
                    "reverse_vow=1;reverse_rivals=1;"
                    "vow_pain=1;vow_grit=1;vow_wards=1;vow_frenzy=1;vow_hordes=1;"
                    "vow_menace=1;vow_return=1;vow_fangs=1;vow_scars=1;vow_debt=1;"
                    "vow_shadow=0;vow_forfeit=0;vow_time=1;vow_void=2;vow_hubris=1;"
                    "vow_denial=0;vow_rivals=2;"
                    "goal=0;starting_route=3;lock_routes=0;"
                    "underworld_offset=0;surface_offset=0;surface_start=1;"
                    "underworld_wins_needed=1;surface_wins_needed=1;weapons_clears_needed=1;"
                    "ashes_pack_value=100;psyche_pack_value=20;bones_pack_value=20;"
                    "nectar_pack_value=2;death_link=1;deathlink_percent=50;deathlink_amount=1")

# The most recent live connection from the game; replaced on every reconnect.
current_conn: socket.socket | None = None
lock = threading.Lock()

# Cumulative received-items list, like the real AP client. Typing `ITEMS:x` appends
# x and re-sends the whole list, so new items always land past the mod's processed
# index. Cleared by RESET. Re-sent whenever the game (re)connects.
sent_items: list = []


def describe_send(msg: str) -> str:
    """A friendly confirmation of what we just sent to the game."""
    command, _, payload = msg.partition(":")
    command = command.upper()
    if command == "RESET":
        return ">> Resetting applied-item state..."
    if command == "ITEMS":
        items = [p for p in payload.split("|") if p]
        if not items:
            return ">> Sending empty item list."
        return ">> Sending items: " + ", ".join(items)
    if command == "SETTINGS":
        return ">> Sending slot settings."
    if command == "DEATH":
        return ">> Sending DeathLink (kill Melinoe)."
    if command == "CHECKEDSCORE":
        return ">> Sending point_based already-checked score set (mod skips these for free)."
    if command == "GOAL":
        return ">> Sending goal acknowledgement."
    return ">> Sent: " + msg


def reader_thread(conn: socket.socket) -> None:
    buffer = ""
    while True:
        try:
            data = conn.recv(4096)
        except OSError:
            break
        if not data:
            break
        buffer += data.decode("utf-8", errors="replace")
        while "\n" in buffer:
            line, buffer = buffer.split("\n", 1)
            line = line.strip()
            if line:
                print(f"\n<< from game: {line}\n> ", end="", flush=True)
                if line.startswith("CHECK:"):
                    # Echo CHECKED back with a fake "<player> - <item>" so the in-game
                    # corner log shows the wishlist format (real client uses scout data).
                    loc = line[len("CHECK:"):]
                    try:
                        conn.sendall((f"CHECKED:{loc}|Mario64 - Power Star\n").encode("utf-8"))
                    except OSError:
                        pass
                if line.split(":", 1)[0] == "HELLO":    # "HELLO" or "HELLO:<capabilities>"
                    try:
                        conn.sendall((DEFAULT_SETTINGS + "\n").encode("utf-8"))
                        with lock:
                            items = list(sent_items)
                        if items:
                            conn.sendall(("ITEMS:" + "|".join(items) + "\n").encode("utf-8"))
                        print(f">> auto-sent settings + {len(items)} item(s)\n> ", end="", flush=True)
                    except OSError:
                        pass
    print("\n[game disconnected]\n> ", end="", flush=True)


def accept_thread(server: socket.socket) -> None:
    global current_conn
    while True:
        try:
            conn, addr = server.accept()
        except OSError:
            break
        with lock:
            if current_conn is not None:
                try:
                    current_conn.close()
                except OSError:
                    pass
            current_conn = conn
        print(f"\n[game connected from {addr}]\n> ", end="", flush=True)
        threading.Thread(target=reader_thread, args=(conn,), daemon=True).start()


def main() -> None:
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((HOST, PORT))
    server.listen(5)
    print(f"Fake AP client listening on {HOST}:{PORT}. Waiting for the game...")
    threading.Thread(target=accept_thread, args=(server,), daemon=True).start()

    while True:
        try:
            msg = input("> ").strip()
        except (EOFError, KeyboardInterrupt):
            return
        if msg.lower() in ("quit", "exit"):
            return
        if not msg:
            continue
        with lock:
            conn = current_conn
        if conn is None:
            print("[no game connected yet]")
            continue

        command, _, payload = msg.partition(":")
        cmd = command.upper()
        if cmd == "ITEMS":
            new_items = [p.strip() for p in payload.split("|") if p.strip()]
            with lock:
                sent_items.extend(new_items)
                outgoing = "ITEMS:" + "|".join(sent_items)
                total = len(sent_items)
            confirm = (">> Added: " + ", ".join(new_items) + f"  (total {total} item(s))"
                       if new_items else ">> (no items given)")
        elif cmd == "RESET":
            with lock:
                sent_items.clear()
            outgoing = "RESET"
            confirm = ">> Resetting applied-item state (and clearing the local item list)."
        else:
            outgoing = msg
            confirm = describe_send(msg)

        try:
            conn.sendall((outgoing + "\n").encode("utf-8"))
            print(confirm)
        except OSError:
            print("[send failed — game may have disconnected]")


if __name__ == "__main__":
    main()
