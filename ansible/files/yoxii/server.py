#!/usr/bin/env python3
"""Yoxii multiplayer server: rooms, matchmaking and the rules.

The server is AUTHORITATIVE. Clients send intents ("move the totem here",
"place this piece there") and the server decides. Nothing is trusted from the
browser, so a modified client cannot cheat: it can only be told no.

Matchmaking, as specified:
  - the first visitor opens a room and plays White,
  - the second joins that room and plays Red,
  - anyone arriving while every room is full opens a new one.

Rules: official Cosmoludo rulebook (Tom Delahaye & Jeremy Partinico, 2022).
"""

import asyncio
import itertools
import json
import logging
import os
import signal

import websockets

LOG = logging.getLogger("yoxii")

# ------------------------------------------------------------------- Board ---

# 7x7 with the four corners cut: 3-5-7-7-7-5-3 = 37 cells. The printed board
# uses those corners for the value legend, which is why they are not playable.
LAYOUT = (
    "..###..",
    ".#####.",
    "#######",
    "#######",
    "#######",
    ".#####.",
    "..###..",
)
SIZE = 7
CENTRE = "3,3"

CELLS = frozenset(
    f"{r},{c}" for r in range(SIZE) for c in range(SIZE) if LAYOUT[r][c] == "#"
)
DIRS = ((-1, -1), (-1, 0), (-1, 1), (0, -1), (0, 1), (1, -1), (1, 0), (1, 1))

# Five each of 1, 2 and 3, three of 4 = 18 pieces per player.
RESERVE = {1: 5, 2: 5, 3: 5, 4: 3}
SIDES = ("W", "R")


def parse(cell):
    r, c = cell.split(",")
    return int(r), int(c)


def neighbours(cell):
    r, c = parse(cell)
    out = []
    for dr, dc in DIRS:
        n = f"{r + dr},{c + dc}"
        if n in CELLS:
            out.append(n)
    return out


# -------------------------------------------------------------------- Game ---


class Game:
    def __init__(self):
        self.reset()

    def reset(self):
        self.pieces = {}  # cell -> {"owner": side, "value": int}
        self.totem = CENTRE
        self.turn = "W"  # white opens
        self.phase = "move"  # then "place"
        self.reserve = {s: dict(RESERVE) for s in SIDES}
        self.history = []
        self.finished = False
        self.pending = None

    # ---- legality ----

    def totem_moves(self):
        """One step onto a free neighbour, or a jump over an unbroken line of the
        mover's OWN pieces onto the first free cell beyond. Jumping over the
        opponent is forbidden."""
        tr, tc = parse(self.totem)
        moves = []
        for dr, dc in DIRS:
            r, c = tr + dr, tc + dc
            cell = f"{r},{c}"
            if cell not in CELLS:
                continue
            if cell not in self.pieces:
                moves.append({"to": cell, "jumped": 0})
                continue
            jumped = 0
            while cell in CELLS and self.pieces.get(cell, {}).get("owner") == self.turn:
                jumped += 1
                r, c = r + dr, c + dc
                cell = f"{r},{c}"
            if jumped and cell in CELLS and cell not in self.pieces:
                moves.append({"to": cell, "jumped": jumped})
        return moves

    def placements(self):
        """Around the totem; when every neighbour is taken, anywhere free."""
        around = [n for n in neighbours(self.totem) if n not in self.pieces]
        if around:
            return around, False
        free = [c for c in sorted(CELLS) if c != self.totem and c not in self.pieces]
        return free, True

    def has_pieces(self, side):
        return any(self.reserve[side].values())

    # ---- moves ----

    def move_totem(self, side, to):
        if self.finished:
            return "La partie est terminée."
        if side != self.turn:
            return "Ce n'est pas votre tour."
        if self.phase != "move":
            return "Vous devez d'abord poser une pièce."
        if to not in {m["to"] for m in self.totem_moves()}:
            return "Déplacement du Totem interdit."
        self.pending = (self.totem, to)
        self.totem = to
        self.phase = "place"
        return None

    def place_piece(self, side, cell, value):
        if self.finished:
            return "La partie est terminée."
        if side != self.turn:
            return "Ce n'est pas votre tour."
        if self.phase != "place":
            return "Vous devez d'abord déplacer le Totem."
        if value not in RESERVE:
            return "Valeur de pièce inconnue."
        if self.reserve[side][value] <= 0:
            return "Plus de pièce de cette valeur."
        allowed, _ = self.placements()
        if cell not in allowed:
            return "Pose interdite sur cette case."

        self.pieces[cell] = {"owner": side, "value": value}
        self.reserve[side][value] -= 1
        self.history.append(
            {
                "player": side,
                "text": f"Totem {coord(self.pending[0])} → {coord(self.pending[1])}, "
                f"{GLYPH[value]} en {coord(cell)}",
            }
        )

        self.turn = "R" if side == "W" else "W"
        self.phase = "move"
        self.pending = None

        # The game ends the moment the player to move cannot move the totem.
        if not self.totem_moves():
            self.finished = True
        return None

    # ---- scoring ----

    def score(self):
        """Only the pieces adjacent to the totem count."""
        out = {s: {"points": 0, "count": 0} for s in SIDES}
        for n in neighbours(self.totem):
            p = self.pieces.get(n)
            if p:
                out[p["owner"]]["points"] += p["value"]
                out[p["owner"]]["count"] += 1
        return out

    def outcome(self):
        s = self.score()
        if s["W"]["points"] != s["R"]["points"]:
            winner = "W" if s["W"]["points"] > s["R"]["points"] else "R"
            return {"winner": winner, "reason": "points", "score": s}
        if s["W"]["count"] != s["R"]["count"]:
            # The rulebook breaks a tie on "the dominant colour" without defining
            # it; read here as the greater number of pieces around the totem.
            winner = "W" if s["W"]["count"] > s["R"]["count"] else "R"
            return {"winner": winner, "reason": "pieces", "score": s}
        return {"winner": None, "reason": "draw", "score": s}

    # ---- wire format ----

    def snapshot(self):
        moves = [] if self.finished or self.phase != "move" else self.totem_moves()
        places, anywhere = ([], False)
        if not self.finished and self.phase == "place":
            places, anywhere = self.placements()
        return {
            "pieces": self.pieces,
            "totem": self.totem,
            "turn": self.turn,
            "phase": self.phase,
            "reserve": self.reserve,
            "history": self.history[-12:],
            "finished": self.finished,
            "legal": {"moves": moves, "places": places, "anywhere": anywhere},
            "score": self.score(),
            "outcome": self.outcome() if self.finished else None,
        }


GLYPH = {1: "O", 2: "II", 3: "Y", 4: "X"}


def coord(cell):
    r, c = parse(cell)
    return f"{chr(97 + c)}{SIZE - r}"


# -------------------------------------------------------------------- Room ---


class Room:
    counter = itertools.count(1)

    def __init__(self):
        self.id = f"S{next(Room.counter)}"
        self.game = Game()
        self.players = {}  # side -> websocket

    @property
    def full(self):
        return len(self.players) >= 2

    @property
    def empty(self):
        return not self.players

    def free_side(self):
        # White first: the opener of a room plays White, as specified.
        for side in SIDES:
            if side not in self.players:
                return side
        return None

    async def broadcast(self, payload):
        dead = []
        for side, ws in self.players.items():
            try:
                await ws.send(json.dumps(payload))
            except Exception:
                dead.append(side)
        for side in dead:
            self.players.pop(side, None)


ROOMS = []


def find_room():
    """First room with a free seat, otherwise a new one. A room whose player has
    left frees its seat again rather than lingering half-used."""
    for room in ROOMS:
        if not room.full:
            return room
    room = Room()
    ROOMS.append(room)
    return room


async def push_state(room, extra=None):
    payload = {"type": "state", "state": room.game.snapshot(), "room": room.id,
               "players": sorted(room.players)}
    if extra:
        payload.update(extra)
    await room.broadcast(payload)


# ----------------------------------------------------------------- Handler ---


async def handler(ws, *_):
    room = find_room()
    side = room.free_side()
    room.players[side] = ws
    LOG.info("join room=%s side=%s (rooms=%d)", room.id, side, len(ROOMS))

    await ws.send(
        json.dumps(
            {
                "type": "welcome",
                "room": room.id,
                "side": side,
                "state": room.game.snapshot(),
                "players": sorted(room.players),
            }
        )
    )
    await push_state(room)

    try:
        async for raw in ws:
            try:
                msg = json.loads(raw)
            except json.JSONDecodeError:
                continue

            kind = msg.get("type")
            error = None

            if kind == "move":
                error = room.game.move_totem(side, str(msg.get("to", "")))
            elif kind == "place":
                error = room.game.place_piece(
                    side, str(msg.get("cell", "")), int(msg.get("value", 0))
                )
            elif kind == "restart":
                # Only allowed once the game is over, so a losing player cannot
                # wipe the board mid-game.
                if room.game.finished:
                    room.game.reset()
                else:
                    error = "La partie est en cours."
            else:
                error = "Message inconnu."

            if error:
                await ws.send(json.dumps({"type": "error", "message": error}))
            else:
                await push_state(room)

    except websockets.ConnectionClosed:
        pass
    finally:
        room.players.pop(side, None)
        LOG.info("leave room=%s side=%s", room.id, side)
        if room.empty:
            if room in ROOMS:
                ROOMS.remove(room)
            LOG.info("room %s closed (rooms=%d)", room.id, len(ROOMS))
        else:
            await push_state(room, {"peerLeft": True})


async def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    host = os.environ.get("YOXII_HOST", "127.0.0.1")
    port = int(os.environ.get("YOXII_PORT", "8765"))

    stop = asyncio.get_running_loop().create_future()
    for sig in (signal.SIGINT, signal.SIGTERM):
        asyncio.get_running_loop().add_signal_handler(sig, lambda: stop.set_result(None))

    async with websockets.serve(handler, host, port, ping_interval=20, ping_timeout=20):
        LOG.info("yoxii server on ws://%s:%d", host, port)
        await stop
    LOG.info("stopped")


if __name__ == "__main__":
    asyncio.run(main())
