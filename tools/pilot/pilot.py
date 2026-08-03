#!/usr/bin/env python3
"""Fly real clients against a live vectorwake arena and report what happened.

Not a connectivity check. Each pilot joins, takes the map and the settings the
zone sends, flies with real inputs, and decodes every snapshot through the
simulation core itself -- so what is being verified is that ships move, energy
drains and recharges, weapons appear, kills land, and the numbers the server
sends are numbers the core accepts.

  pilot.py wss://directory.vectorwake.net war 4 30   # browse, then join
  pilot.py --direct ws://127.0.0.1:9001 "" 2 20      # dial one arena, no browse

Browsing rather than taking an address is not incidental. Which instance serves
which zone is decided by the instances themselves and differs between deploys,
so a harness with an address baked in tests whichever zone happens to be there
-- and gets a wrong-zone refusal for its trouble, which is the server being
right and the test being wrong.
"""
import asyncio, ctypes, os, random, struct, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import websockets

SO = os.path.join(os.path.dirname(os.path.abspath(__file__)), "libvwprobe.so")

C2S_JOIN, C2S_INPUT, C2S_SHIP = 1, 2, 5
(S2C_WELCOME, S2C_SNAPSHOT, S2C_ROSTER, S2C_KILL, S2C_BANNER,
 S2C_ZONE, S2C_DENIED, S2C_MAP, S2C_SETTINGS) = 1, 2, 3, 4, 5, 6, 7, 9, 10

BTN_LEFT, BTN_RIGHT, BTN_THRUST, BTN_REVERSE, BTN_FIRE, BTN_BOMB = 1, 2, 4, 8, 16, 32


def lib():
    l = ctypes.CDLL(SO)
    l.vw_new.restype = ctypes.c_void_p
    for n in ("vw_load_map", "vw_load_settings", "vw_apply"):
        getattr(l, n).argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
    l.vw_step.argtypes = [ctypes.c_void_p, ctypes.c_ubyte, ctypes.c_ushort]
    for n in ("vw_tick", "vw_map_fingerprint"):
        getattr(l, n).restype = ctypes.c_uint
        getattr(l, n).argtypes = [ctypes.c_void_p]
    for n in ("vw_ship_count", "vw_weapon_count", "vw_max_ships",
              "vw_spec_count", "vw_flag_count"):
        getattr(l, n).argtypes = [ctypes.c_void_p]
    for n in ("vw_active", "vw_alive", "vw_x", "vw_y", "vw_vx", "vw_vy",
              "vw_energy", "vw_kills", "vw_deaths", "vw_team", "vw_cls"):
        getattr(l, n).argtypes = [ctypes.c_void_p, ctypes.c_int]
    return l


class Pilot:
    def __init__(self, url, zone, name, seconds, seed):
        self.url, self.zone, self.name, self.seconds = url, zone, name, seconds
        self.rng = random.Random(seed)
        self.L = lib()
        self.c = ctypes.c_void_p(self.L.vw_new())
        self.me = None
        self.zone_name = None
        self.denied = None
        self.n = dict(snaps=0, bytes=0, roster=0, kills=0, banner=0,
                      map=0, settings=0, bad=0)
        self.seen = dict(moved=False, fired=False, energy_lo=None, energy_hi=None,
                         ships=0, flags=0, my_kills=0, my_deaths=0)
        self.pred = dict(checks=0, worst=0, sum=0, corrections=0, worst_corr=0)
        self.first_snap_at = None
        self.last_snap_at = None
        self.map_fp = None
        self.max_ships = None
        self.specs = None

    def predict_error(self, buttons):
        """Step the core forward one tick and remember where it thinks we are.

        The next snapshot says where the server actually put us. A client that
        predicts correctly sees these agree to within a pixel or two; a wire
        format or a settings mismatch shows up here as a growing divergence,
        which no amount of "it connected" would reveal.
        """
        if self.me is None:
            return
        self.L.vw_step(self.c, self.me, buttons)
        # Remember the ship's liveness with the prediction. A death and respawn
        # teleports the ship, and comparing a still-flying prediction against a
        # fresh spawn point measures the teleport, not the prediction. Those are
        # counted separately: the client's contract is that it accepts the
        # server's correction, so a discontinuity is expected behaviour and
        # lumping it into the error hides how good the agreement actually is.
        self._pred = (self.L.vw_x(self.c, self.me), self.L.vw_y(self.c, self.me),
                      self.L.vw_alive(self.c, self.me),
                      self.L.vw_deaths(self.c, self.me))

    def note_snapshot(self, payload):
        if self.L.vw_apply(self.c, payload, len(payload)) != 0:
            self.n["bad"] += 1
            return
        if getattr(self, "_pred", None) is not None and self.me is not None:
            px, py, palive, pdeaths = self._pred
            ax, ay = self.L.vw_x(self.c, self.me), self.L.vw_y(self.c, self.me)
            # Q12 fixed point: 4096 units to the pixel.
            err = max(abs(px - ax), abs(py - ay)) / 4096.0
            respawned = (self.L.vw_deaths(self.c, self.me) != pdeaths
                         or self.L.vw_alive(self.c, self.me) != palive)
            if respawned:
                self.pred["corrections"] += 1
                self.pred["worst_corr"] = max(self.pred["worst_corr"], err)
            else:
                self.pred["checks"] += 1
                self.pred["sum"] += err
                self.pred["worst"] = max(self.pred["worst"], err)
            self._pred = None
        now = time.monotonic()
        self.first_snap_at = self.first_snap_at or now
        self.last_snap_at = now
        self.seen["ships"] = max(self.seen["ships"], self.L.vw_ship_count(self.c))
        self.seen["flags"] = max(self.seen["flags"], self.L.vw_flag_count(self.c))
        if self.L.vw_weapon_count(self.c) > 0:
            self.seen["fired"] = True
        if self.me is not None:
            e = self.L.vw_energy(self.c, self.me)
            lo, hi = self.seen["energy_lo"], self.seen["energy_hi"]
            self.seen["energy_lo"] = e if lo is None else min(lo, e)
            self.seen["energy_hi"] = e if hi is None else max(hi, e)
            self.seen["my_kills"] = self.L.vw_kills(self.c, self.me)
            self.seen["my_deaths"] = self.L.vw_deaths(self.c, self.me)
            p = (self.L.vw_x(self.c, self.me), self.L.vw_y(self.c, self.me))
            if getattr(self, "_p0", None) is None:
                self._p0 = p
            elif abs(p[0] - self._p0[0]) + abs(p[1] - self._p0[1]) > 4096:
                self.seen["moved"] = True

    async def fly(self):
        try:
            ws = await websockets.connect(self.url, max_size=None, open_timeout=25)
        except Exception as e:
            self.denied = f"connect: {type(e).__name__}"
            return self
        async with ws:
            z = self.zone.encode()
            await ws.send(bytes([C2S_JOIN, self.rng.randrange(8), 1, len(z)])
                          + z + self.name.encode())

            async def drive():
                # Real flight: hold a turn for a while, thrust, and fire in
                # bursts. Held rather than tapped, because the server samples
                # buttons once a tick.
                t, turn, fire = 0, BTN_LEFT, False
                while True:
                    t += 1
                    if t % 20 == 0:
                        turn = self.rng.choice([BTN_LEFT, BTN_RIGHT, 0])
                    if t % 12 == 0:
                        fire = not fire
                    b = turn | BTN_THRUST | (BTN_FIRE if fire else 0)
                    try:
                        await ws.send(struct.pack("<BHI", C2S_INPUT, b, t))
                        self.last_buttons = b
                    except Exception:
                        return
                    await asyncio.sleep(0.05)

            pump = asyncio.create_task(drive())
            end = time.monotonic() + self.seconds
            try:
                while time.monotonic() < end:
                    try:
                        m = await asyncio.wait_for(ws.recv(), timeout=2)
                    except asyncio.TimeoutError:
                        continue
                    if not isinstance(m, bytes) or not m:
                        continue
                    tag, body = m[0], m[1:]
                    if tag == S2C_DENIED:
                        self.denied = f"code {body[0]}: {body[1:].decode(errors='replace')}"
                        break
                    elif tag == S2C_ZONE:
                        self.zone_name = body.decode(errors="replace").split("\n")[0]
                    elif tag == S2C_MAP:
                        self.n["map"] += 1
                        if self.L.vw_load_map(self.c, body, len(body)) != 0:
                            self.n["bad"] += 1
                        else:
                            self.map_fp = self.L.vw_map_fingerprint(self.c)
                    elif tag == S2C_SETTINGS:
                        self.n["settings"] += 1
                        if self.L.vw_load_settings(self.c, body, len(body)) != 0:
                            self.n["bad"] += 1
                        else:
                            self.max_ships = self.L.vw_max_ships(self.c)
                            self.specs = self.L.vw_spec_count(self.c)
                    elif tag == S2C_WELCOME:
                        self.me = body[0]
                    elif tag == S2C_SNAPSHOT:
                        self.n["snaps"] += 1
                        # One predicted tick from the state we already hold,
                        # measured against the truth this snapshot carries.
                        if self.n["snaps"] > 2:
                            self.predict_error(getattr(self, "last_buttons", 0))
                        self.n["bytes"] += len(m)
                        self.note_snapshot(body[5:])   # ship, then last_input u32
                    elif tag == S2C_ROSTER:
                        self.n["roster"] += 1
                    elif tag == S2C_KILL:
                        self.n["kills"] += 1
                    elif tag == S2C_BANNER:
                        self.n["banner"] += 1
            finally:
                pump.cancel()
        return self

    def report(self):
        if self.denied:
            return f"  {self.name}: DENIED/ERROR {self.denied}"
        s, n = self.seen, self.n
        dur = (self.last_snap_at - self.first_snap_at) if self.first_snap_at else 0
        rate = n["snaps"] / dur if dur > 0.5 else 0
        kbps = n["bytes"] / dur / 1024 if dur > 0.5 else 0
        return (f"  {self.name}: zone={self.zone_name!r} ship={self.me} "
                f"snaps={n['snaps']} ({rate:.1f}/s, {kbps:.1f} KB/s) "
                f"ships={s['ships']} flags={s['flags']} "
                f"moved={'yes' if s['moved'] else 'NO'} "
                f"weapons_seen={'yes' if s['fired'] else 'NO'} "
                f"energy={s['energy_lo']}..{s['energy_hi']} "
                f"k/d={s['my_kills']}/{s['my_deaths']} "
                f"killfeed={n['kills']} roster={n['roster']} "
                f"map={n['map']}(fp={self.map_fp}) settings={n['settings']}"
                f"(max_ships={self.max_ships},specs={self.specs}) "
                f"malformed={n['bad']} "
                f"predict_err(worst/mean px)="
                f"{self.pred['worst']:.2f}/"
                f"{(self.pred['sum']/self.pred['checks'] if self.pred['checks'] else 0):.2f}"
                f" over {self.pred['checks']}"
                f" corrections={self.pred['corrections']}"
                f"(worst {self.pred['worst_corr']:.1f}px)")


async def resolve(directory, zone):
    """Ask the directory where this zone is, exactly as a client does."""
    async with websockets.connect(directory, max_size=None, open_timeout=25) as ws:
        await ws.send(bytes([4]))                      # C2S_STATUS
        for _ in range(20):
            m = await asyncio.wait_for(ws.recv(), timeout=10)
            if isinstance(m, bytes) and m and m[0] == 8:
                import json
                for z in json.loads(m[1:])["zones"]:
                    if z["name"] == zone:
                        if not z["instances"]:
                            raise SystemExit(f"nobody is running {zone!r}")
                        # The head of the list: the directory has already put the
                        # fullest instance with room there.
                        return z["instances"][0]["address"]
                raise SystemExit(f"no zone {zone!r} in the browse reply")
    raise SystemExit("the directory never answered")


async def main():
    args = sys.argv[1:]
    direct = False
    if args and args[0] == "--direct":
        direct, args = True, args[1:]
    url, zone, count, seconds = args[0], args[1], int(args[2]), float(args[3])
    if not direct:
        arena = await resolve(url, zone)
        print(f"=== directory {url} says {zone!r} is at {arena}")
        url = arena
    pilots = [Pilot(url, zone, f"probe{i:02d}", seconds, 1000 + i) for i in range(count)]
    done = await asyncio.gather(*(p.fly() for p in pilots), return_exceptions=True)
    print(f"=== {count} pilots, {seconds:.0f}s, {url} zone={zone}")
    for d in done:
        print(d.report() if isinstance(d, Pilot) else f"  harness error: {d!r}")

asyncio.run(main())
