#!/usr/bin/env python3
"""Runs the room server in-process and drives it with real TCP clients.  python3 test_server.py"""
import asyncio
import json

import gorilla_server as gs

POSE = [0.1 * i for i in range(gs.POSE_LEN)]


class Bot:
    def __init__(self, reader, writer):
        self.r, self.w = reader, writer

    @classmethod
    async def connect(cls, port):
        r, w = await asyncio.open_connection("127.0.0.1", port)
        bot = cls(r, w)
        hello = await bot.recv()
        assert hello["t"] == "hello", hello
        bot.id = hello["id"]
        return bot

    def send(self, **msg):
        self.w.write((json.dumps(msg) + "\n").encode())

    async def recv(self, timeout=2.0):
        line = await asyncio.wait_for(self.r.readline(), timeout)
        assert line, "server closed the connection"
        return json.loads(line)

    async def expect(self, kind, timeout=2.0):
        msg = await self.recv(timeout)
        assert msg["t"] == kind, f"expected {kind}, got {msg}"
        return msg

    async def silent(self, timeout=0.3):
        try:
            msg = await self.recv(timeout)
        except asyncio.TimeoutError:
            return True
        raise AssertionError(f"unexpected message {msg}")

    async def closed(self, timeout=2.0):
        line = await asyncio.wait_for(self.r.readline(), timeout)
        return line == b""

    def close(self):
        self.w.close()


async def main():
    srv = gs.Server(max_players=3)
    tcp = await asyncio.start_server(srv.serve_client, "127.0.0.1", 0, limit=gs.MAX_LINE)
    port = tcp.sockets[0].getsockname()[1]

    a, b, c, d = [await Bot.connect(port) for _ in range(4)]

    # custom code: lower case and junk are cleaned, first player gets an empty roster
    a.send(t="join", code="ab-12!", name="alice <b>", color=[0.5, 2, -1])
    m = await a.expect("joined")
    assert m["code"] == "AB12" and m["peers"] == [] and m["id"] == a.id, m

    b.send(t="join", code="ab12", name="Bob", color=None)
    m = await b.expect("joined")
    assert m["code"] == "AB12" and len(m["peers"]) == 1, m
    assert m["peers"][0] == {"id": a.id, "name": "ALICE B", "color": [0.5, 1.0, 0.0]}, m["peers"]
    m = await a.expect("peer_joined")
    assert m["id"] == b.id and m["name"] == "BOB" and m["color"] is None, m

    # pose relay: others get it, the sender does not
    a.send(t="pose", d=POSE)
    m = await b.expect("pose")
    assert m["id"] == a.id and m["d"] == POSE, m
    assert await a.silent()

    # bad poses are ignored
    a.send(t="pose", d=[1, 2, 3])
    a.send(t="pose", d=["x"] * gs.POSE_LEN)
    a.send(t="pose", d=[1e12] * gs.POSE_LEN)
    assert await b.silent()

    # a player outside the room never sees it
    c.send(t="join", code="ZZ", name="carl")
    await c.expect("joined")
    a.send(t="pose", d=POSE)
    await b.expect("pose")
    assert await c.silent()

    # profile change reaches the room
    b.send(t="profile", name="Robert", color=[1, 0, 0])
    m = await a.expect("profile")
    assert m["id"] == b.id and m["name"] == "ROBERT" and m["color"] == [1.0, 0.0, 0.0], m

    # room capacity (3 per room in this test)
    c.send(t="leave")
    await c.expect("left")
    c.send(t="join", code="AB12", name="carl")
    await c.expect("joined")
    await a.expect("peer_joined")
    await b.expect("peer_joined")
    d.send(t="join", code="AB12", name="dave")
    m = await d.expect("join_failed")
    assert m["msg"] == "ROOM FULL", m

    # bad code
    d.send(t="join", code="!!!", name="dave")
    assert (await d.expect("join_failed"))["msg"] == "BAD ROOM CODE"

    # random public rooms: d creates one, nobody else is in it; custom rooms are never matched
    d.send(t="join", code="", name="dave")
    m = await d.expect("joined")
    assert len(m["code"]) == 6 and m["peers"] == [], m
    pub = m["code"]
    srv_room = srv.rooms[pub]
    assert srv_room.public and not srv.rooms["AB12"].public

    # leaving announces peer_left; a disconnect does too
    c.send(t="leave")
    await c.expect("left")
    assert (await a.expect("peer_left"))["id"] == c.id
    b.close()
    assert (await a.expect("peer_left"))["id"] == b.id

    # a second random joiner lands in the same public room
    c.send(t="join", code="", name="carl")
    m = await c.expect("joined")
    assert m["code"] == pub and len(m["peers"]) == 1, m
    await d.expect("peer_joined")

    # empty rooms are deleted
    a.close()
    c.close()
    d.close()
    await asyncio.sleep(0.3)
    assert srv.rooms == {} and srv.clients == {}, (srv.rooms, srv.clients)

    # garbage does not crash anything; oversize line drops the client
    e = await Bot.connect(port)
    e.w.write(b"not json\n[]\n123\n{\"t\":\"nope\"}\n")
    e.send(t="ping")
    await e.expect("pong")
    e.w.write(b"x" * (gs.MAX_LINE * 3) + b"\n")
    assert await e.closed()

    tcp.close()
    await tcp.wait_closed()
    print("all server tests passed")


asyncio.run(main())
