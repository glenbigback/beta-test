#!/usr/bin/env python3
"""Gorilla room server.

A tiny relay: players connect over TCP, join a room by code (or a random public room),
and the server forwards everybody's pose to the others in the same room.
It runs no game logic and needs nothing but Python 3.8+ (standard library only).

    python3 gorilla_server.py --host 0.0.0.0 --port 7777

Protocol: one JSON object per line ("\\n" terminated), key "t" is the message type.

client -> server
    {"t":"join","code":"ABC123","name":"BOB","color":[0.5,0.2,0.9]|null}   code "" = random public room
    {"t":"leave"}
    {"t":"profile","name":"BOB","color":[r,g,b]|null}
    {"t":"pose","d":[21 numbers]}
    {"t":"ping"}

server -> client
    {"t":"hello","id":7,"max":10}
    {"t":"joined","code":"ABC123","id":7,"peers":[{"id":3,"name":"..","color":..}, ...]}
    {"t":"join_failed","msg":"ROOM FULL"}
    {"t":"peer_joined","id":3,"name":"..","color":..}
    {"t":"peer_left","id":3}
    {"t":"profile","id":3,"name":"..","color":..}
    {"t":"pose","id":3,"d":[...]}
    {"t":"left"}
    {"t":"pong"}
"""
import argparse
import asyncio
import json
import logging
import math
import random
import re
import string
import time

CODE_CHARS = string.ascii_uppercase + string.digits
MAX_CODE_LEN = 6
MAX_NAME_LEN = 12
POSE_LEN = 21               # see Scripts/player.gd get_net_pose()
MAX_LINE = 4096             # bytes; longer lines drop the client
IDLE_TIMEOUT = 20.0         # seconds without any message -> drop (clients ping every 5 s)
MAX_POSE_PER_SEC = 60       # clients send ~20; extra messages are ignored
SLOW_CLIENT_BYTES = 256 * 1024   # drop pose updates for clients that cannot keep up
DEAD_CLIENT_BYTES = 2 * 1024 * 1024

log = logging.getLogger("gorilla")


def clean_code(value):
    """Return an upper-case A-Z0-9 room code of at most 6 characters ('' if nothing usable)."""
    if not isinstance(value, str):
        return ""
    return "".join(c for c in value.upper() if c in CODE_CHARS)[:MAX_CODE_LEN]


def clean_name(value):
    if not isinstance(value, str):
        return "GORILLA"
    name = re.sub(r"[^A-Za-z0-9 ]", "", value).strip().upper()[:MAX_NAME_LEN]
    return name or "GORILLA"


def clean_color(value):
    """[r,g,b] with each channel clamped to 0..1, or None (= keep the model's own colour)."""
    if (isinstance(value, list) and len(value) == 3
            and all(isinstance(c, (int, float)) and not isinstance(c, bool) and math.isfinite(c) for c in value)):
        return [round(min(max(float(c), 0.0), 1.0), 3) for c in value]
    return None


def clean_pose(value):
    if not isinstance(value, list) or len(value) != POSE_LEN:
        return None
    out = []
    for v in value:
        if isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v) or abs(v) > 1_000_000:
            return None
        out.append(v)
    return out


class Client:
    def __init__(self, cid, writer):
        self.id = cid
        self.writer = writer
        self.room = None
        self.name = "GORILLA"
        self.color = None
        self.pose_window = time.monotonic()
        self.pose_count = 0
        self.closing = False

    def send(self, msg, droppable=False):
        if self.closing:
            return
        try:
            size = self.writer.transport.get_write_buffer_size()
            if size > DEAD_CLIENT_BYTES:
                self.closing = True
                self.writer.close()
                return
            if droppable and size > SLOW_CLIENT_BYTES:
                return
            self.writer.write((json.dumps(msg, separators=(",", ":")) + "\n").encode())
        except Exception:
            self.closing = True

    def info(self):
        return {"id": self.id, "name": self.name, "color": self.color}

    def allow_pose(self):
        now = time.monotonic()
        if now - self.pose_window >= 1.0:
            self.pose_window = now
            self.pose_count = 0
        self.pose_count += 1
        return self.pose_count <= MAX_POSE_PER_SEC


class Room:
    def __init__(self, code, public):
        self.code = code
        self.public = public
        self.clients = {}


class Server:
    def __init__(self, max_players=10, max_clients=500):
        self.max_players = max_players
        self.max_clients = max_clients
        self.rooms = {}
        self.clients = {}
        self.next_id = 1

    # --- rooms -------------------------------------------------------------------------------

    def random_code(self):
        while True:
            code = "".join(random.choice(CODE_CHARS) for _ in range(MAX_CODE_LEN))
            if code not in self.rooms:
                return code

    def find_public_room(self):
        open_rooms = [r for r in self.rooms.values() if r.public and len(r.clients) < self.max_players]
        if not open_rooms:
            return None
        return max(open_rooms, key=lambda r: len(r.clients))  # fill the busiest room first

    def join(self, client, raw_code, name, color):
        self.leave(client)
        client.name = clean_name(name)
        client.color = clean_color(color)
        if isinstance(raw_code, str) and raw_code.strip() == "":
            room = self.find_public_room()
            if room is None:
                room = Room(self.random_code(), public=True)
                self.rooms[room.code] = room
        else:
            code = clean_code(raw_code)
            if not code:
                client.send({"t": "join_failed", "msg": "BAD ROOM CODE"})
                return
            room = self.rooms.get(code)
            if room is None:
                room = Room(code, public=False)  # custom codes are private rooms
                self.rooms[code] = room
            elif len(room.clients) >= self.max_players:
                client.send({"t": "join_failed", "msg": "ROOM FULL"})
                return
        peers = [c.info() for c in room.clients.values()]
        room.clients[client.id] = client
        client.room = room
        client.send({"t": "joined", "code": room.code, "id": client.id, "peers": peers})
        for other in room.clients.values():
            if other is not client:
                other.send({"t": "peer_joined", **client.info()})
        log.info("client %d joined %s (%d/%d)", client.id, room.code, len(room.clients), self.max_players)

    def leave(self, client):
        room = client.room
        if room is None:
            return
        client.room = None
        room.clients.pop(client.id, None)
        for other in room.clients.values():
            other.send({"t": "peer_left", "id": client.id})
        if not room.clients:
            self.rooms.pop(room.code, None)
        log.info("client %d left %s (%d left)", client.id, room.code, len(room.clients))

    # --- messages ----------------------------------------------------------------------------

    def handle(self, client, msg):
        kind = msg.get("t")
        if kind == "pose":
            room = client.room
            pose = clean_pose(msg.get("d"))
            if room is None or pose is None or not client.allow_pose():
                return
            out = {"t": "pose", "id": client.id, "d": pose}
            for other in room.clients.values():
                if other is not client:
                    other.send(out, droppable=True)
        elif kind == "join":
            self.join(client, msg.get("code", ""), msg.get("name"), msg.get("color"))
        elif kind == "leave":
            self.leave(client)
            client.send({"t": "left"})
        elif kind == "profile":
            client.name = clean_name(msg.get("name"))
            client.color = clean_color(msg.get("color"))
            if client.room is not None:
                for other in client.room.clients.values():
                    if other is not client:
                        other.send({"t": "profile", **client.info()})
        elif kind == "ping":
            client.send({"t": "pong"})

    async def serve_client(self, reader, writer):
        if len(self.clients) >= self.max_clients:
            writer.close()
            return
        client = Client(self.next_id, writer)
        self.next_id += 1
        self.clients[client.id] = client
        peer = writer.get_extra_info("peername")
        log.info("client %d connected from %s", client.id, peer)
        client.send({"t": "hello", "id": client.id, "max": self.max_players})
        try:
            while not client.closing:
                try:
                    line = await asyncio.wait_for(reader.readline(), IDLE_TIMEOUT)
                except (asyncio.TimeoutError, ValueError, ConnectionError):
                    break  # idle, oversize line or reset
                if not line or not line.endswith(b"\n"):
                    break
                try:
                    msg = json.loads(line)
                except ValueError:
                    continue
                if isinstance(msg, dict):
                    self.handle(client, msg)
        finally:
            client.closing = True
            self.leave(client)
            self.clients.pop(client.id, None)
            try:
                writer.close()
            except Exception:
                pass
            log.info("client %d disconnected", client.id)


async def run(host, port, max_players, max_clients):
    server = Server(max_players, max_clients)
    tcp = await asyncio.start_server(server.serve_client, host, port, limit=MAX_LINE)
    log.info("listening on %s:%d (max %d players per room)", host, port, max_players)
    async with tcp:
        await tcp.serve_forever()


def main():
    ap = argparse.ArgumentParser(description="Gorilla room server")
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=7777)
    ap.add_argument("--max-players", type=int, default=10, help="players per room")
    ap.add_argument("--max-clients", type=int, default=500, help="connections in total")
    args = ap.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
    try:
        asyncio.run(run(args.host, args.port, args.max_players, args.max_clients))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
