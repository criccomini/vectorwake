#!/usr/bin/env python3
"""Fly real clients against a live vectorwake arena and report what happened.

Not a connectivity check. Each pilot joins, takes the map and the settings the
zone sends, flies with real inputs, and decodes every snapshot through the
simulation core itself -- so what is being verified is that ships move, energy
drains and recharges, weapons appear, kills land, and the numbers the server
sends are numbers the core accepts.

  pilot.py wss://play.vectorwake.net/dir war 4 30    # browse, then join
  pilot.py --direct ws://127.0.0.1:9001 "" 2 20      # dial one arena, no browse
  pilot.py --direct --adapt ws://127.0.0.1:9001 "" 3 15   # steer the input clock

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
# The client wire's version, checked by the zone before it reads anything else
# in a join. Bumped when the join or the roster changes shape.
PROTOCOL = 7
(S2C_WELCOME, S2C_SNAPSHOT, S2C_ROSTER, S2C_KILL, S2C_BANNER,
 S2C_ZONE, S2C_DENIED, S2C_MAP, S2C_SETTINGS) = 1, 2, 3, 4, 5, 6, 7, 9, 10

BTN_LEFT, BTN_RIGHT, BTN_THRUST, BTN_REVERSE, BTN_FIRE, BTN_BOMB = 1, 2, 4, 8, 16, 32

# Where the clock wants to sit, in ticks of input lag. Negative is an input that
# reaches the server before the tick it belongs to, which is the point; two ticks
# of margin absorbs ordinary jitter without running so far ahead that remote
# ships have to coast for it. The slack is the width of the dead band, so a clock
# that is comfortably early is left alone rather than trimmed every snapshot.
LAG_TARGET, LAG_SLACK, LEAD_MAX = -2, 3, 40


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
    def __init__(self, url, zone, name, seconds, seed, lead=0, adapt=False):
        self.url, self.zone, self.name, self.seconds = url, zone, name, seconds
        self.rng = random.Random(seed)
        self.L = lib()
        self.c = ctypes.c_void_p(self.L.vw_new())
        self.me = None
        self.zone_name = None
        self.denied = None
        # Which room to ask for, and which the welcome says we got. A pilot
        # asks for none: the point of the harness is the game the fleet would
        # actually put a player in.
        self.room = 0
        self.landed = None
        self.n = dict(snaps=0, bytes=0, roster=0, kills=0, banner=0,
                      map=0, settings=0, bad=0)
        self.seen = dict(moved=False, fired=False, energy_lo=None, energy_hi=None,
                         ships=0, flags=0, my_kills=0, my_deaths=0)
        self.pred = dict(checks=0, worst=0, sum=0, corrections=0, worst_corr=0)
        # How many ticks after a client stamps an input the server is actually
        # running it. Both numbers are already on the wire: a snapshot carries
        # the server's own tick in its packed state and, in its header, the
        # highest input tick it has received from this client.
        #
        # This is the root cause of every timing artifact, so it is worth a
        # number of its own rather than being inferred from position error. A
        # held key that starts late costs sub-pixel accuracy, because thrust is
        # an acceleration; anything that sets velocity outright, which in this
        # game is the safe-zone brake, costs speed times this.
        self.lag = dict(n=0, sum=0, worst=0, best=None)
        # The server's clock as last seen, and when that was, which together
        # give `est_tick` its estimate of where the server is now.
        self.srv_tick = None
        self.srv_at = 0.0
        self.lead = lead
        self.adapt = adapt
        self.lead_seen = dict(lo=lead, hi=lead)
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
        # server's correction, so a discontinuity is expected behavior and
        # lumping it into the error hides how good the agreement actually is.
        self._pred = (self.L.vw_x(self.c, self.me), self.L.vw_y(self.c, self.me),
                      self.L.vw_alive(self.c, self.me),
                      self.L.vw_deaths(self.c, self.me))

    def est_tick(self):
        """Which server tick the input being sent now belongs to.

        The last snapshot said what tick the server was on when it packed it,
        and the simulation runs at a fixed 100 Hz, so the wall clock since then
        is the rest of the estimate. `lead` is how far ahead of that to aim: at
        zero the input is stamped for a tick the server has already run by the
        time it arrives, which is where this started.
        """
        if self.srv_tick is None:
            return 1
        elapsed = int((time.monotonic() - self.srv_at) * 100)
        return max(1, self.srv_tick + elapsed + 1 + self.lead)

    def note_input_lag(self, acked):
        """Ticks between stamping an input and the server running it.

        `acked` is the newest input tick this client sent that the server has
        seen; `vw_tick` after applying the snapshot is the tick the server was
        on when it packed it. The gap is the round trip expressed in the only
        unit that matters to the simulation.
        """
        # Not until the clock estimate has settled. The first inputs go out
        # stamped 1, before any snapshot has said what tick the server is on,
        # and counting those measures the join rather than the scheduling.
        if acked <= 1 or self.me is None or self.n["snaps"] < 10:
            return
        gap = self.srv_tick - acked
        # A client whose clock leads the server's reports a negative gap, which
        # is the input arriving before the tick it belongs to. That is the goal
        # state rather than an error, so it is recorded rather than clamped.
        self.lag["n"] += 1
        self.lag["sum"] += gap
        self.lag["worst"] = max(self.lag["worst"], gap)
        self.lag["best"] = gap if self.lag["best"] is None else min(self.lag["best"], gap)

        # The control law the client uses, run here first so it can be watched
        # converging against a real socket before it goes into Lua nobody can
        # unit test. One tick per snapshot, which is twenty a second: fast
        # enough to settle in under a second from a cold start, slow enough that
        # the clock never jumps, and a jump is itself a correction.
        if self.adapt:
            if gap > LAG_TARGET:
                self.lead += 1
            elif gap < LAG_TARGET - LAG_SLACK:
                self.lead -= 1
            self.lead = max(0, min(self.lead, LEAD_MAX))
            self.lead_seen["lo"] = min(self.lead_seen["lo"], self.lead)
            self.lead_seen["hi"] = max(self.lead_seen["hi"], self.lead)

    def note_snapshot(self, payload):
        if self.L.vw_apply(self.c, payload, len(payload)) != 0:
            self.n["bad"] += 1
            return
        # The server's clock, straight out of the state it just sent, and the
        # moment it landed here. Everything this harness says about timing is
        # measured from this pair.
        self.srv_tick = self.L.vw_tick(self.c)
        self.srv_at = time.monotonic()
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
            n = self.name.encode()
            # tag, hull, protocol, flags, then the lengths of the zone and the
            # name. The session token runs to the end and is empty here: a
            # pilot with no token is seated as an unknown guest, which is
            # exactly what this harness wants to be.
            # Room zero: whichever the fill ladder picks, which is what a
            # pilot that never read a room list asks for.
            await ws.send(bytes([C2S_JOIN, self.rng.randrange(8), PROTOCOL, 0,
                                 len(z), len(n), self.room or 0]) + z + n)

            async def drive():
                # Real flight: hold a turn for a while, thrust, and fire in
                # bursts. Held rather than tapped, because the server samples
                # buttons once a tick.
                #
                # The tick stamped on an input is the client's estimate of which
                # server tick it belongs to, which is what the real client sends
                # and what makes `input_lag` mean anything. It used to be a bare
                # counter from one, so the server echoed back a number with no
                # relation to its own clock and the harness could not have
                # noticed a scheduling problem if it tried.
                n, turn, fire = 0, BTN_LEFT, False
                while True:
                    n += 1
                    if n % 20 == 0:
                        turn = self.rng.choice([BTN_LEFT, BTN_RIGHT, 0])
                    if n % 12 == 0:
                        fire = not fire
                    b = turn | BTN_THRUST | (BTN_FIRE if fire else 0)
                    try:
                        await ws.send(struct.pack("<BHI", C2S_INPUT, b, self.est_tick()))
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
                        # Which room the server actually seated us in, which is
                        # not always the one asked for: it can fill in between.
                        if len(body) >= 7:
                            self.landed = body[5] | (body[6] << 8)
                    elif tag == S2C_SNAPSHOT:
                        self.n["snaps"] += 1
                        # One predicted tick from the state we already hold,
                        # measured against the truth this snapshot carries.
                        if self.n["snaps"] > 2:
                            self.predict_error(getattr(self, "last_buttons", 0))
                        self.n["bytes"] += len(m)
                        acked = struct.unpack("<I", body[1:5])[0]
                        self.note_snapshot(body[5:])   # ship, then last_input u32
                        self.note_input_lag(acked)
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
                f"(worst {self.pred['worst_corr']:.1f}px)"
                f" input_lag(mean/best/worst ticks)="
                f"{(self.lag['sum']/self.lag['n'] if self.lag['n'] else 0):.1f}/"
                f"{self.lag['best'] if self.lag['best'] is not None else 0}/"
                f"{self.lag['worst']}"
                f" lead={self.lead}"
                f"({self.lead_seen['lo']}..{self.lead_seen['hi']})")


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
    direct, lead = False, 0
    if args and args[0] == "--direct":
        direct, args = True, args[1:]
    # Ticks to stamp inputs ahead of the estimated server clock. Zero is a
    # client that aims at where the server already was, which is what the game
    # shipped with; a few ticks is what it takes for an input to arrive before
    # the tick it belongs to.
    if args and args[0] == "--lead":
        lead, args = int(args[1]), args[2:]
    adapt = False
    if args and args[0] == "--adapt":
        adapt, args = True, args[1:]
    url, zone, count, seconds = args[0], args[1], int(args[2]), float(args[3])
    if not direct:
        arena = await resolve(url, zone)
        print(f"=== directory {url} says {zone!r} is at {arena}")
        url = arena
    pilots = [Pilot(url, zone, f"probe{i:02d}", seconds, 1000 + i, lead, adapt)
              for i in range(count)]
    done = await asyncio.gather(*(p.fly() for p in pilots), return_exceptions=True)
    print(f"=== {count} pilots, {seconds:.0f}s, {url} zone={zone} "
          f"lead={lead}{' adaptive' if adapt else ''}")
    for d in done:
        print(d.report() if isinstance(d, Pilot) else f"  harness error: {d!r}")

asyncio.run(main())
