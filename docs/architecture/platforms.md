# Platform targets

vectorwake targets the browser, desktop through Steam, mobile, and eventually
consoles. Defold reaches all of them, which is most of why it was chosen, but
each target constrains the architecture differently and the differences are not
evenly distributed.

## Priority

1. **Browser.** A link is the distribution plan. A multiplayer game with no
   installed base cannot ask for a download before the first match.
2. **Desktop, published on Steam.** Where the game plays best: mouse and
   keyboard, UDP, no battery, a store that finds players for us.
3. **Mobile.** Large audience, unsolved control problem. Not on the critical
   path until the game is good.
4. **Consoles.** Real but distant. The decisions that keep them possible cost
   nothing today, so we make them today and defer the work.

## Per-platform reality

| Target | Defold status | Transport | Input | Identity |
|---|---|---|---|---|
| Web (WASM) | Supported, HTML5 build | WebSocket only | Keyboard and mouse | Guest, email, or linked account |
| Windows, macOS, Linux | Supported | UDP | Keyboard and mouse | Steam or account |
| Android, iOS | Supported | UDP | Touch, unsolved | Platform account |
| Switch, PS4, PS5 | Supported, gated | UDP | Controller | Platform account, required |
| Xbox | Announced, verify | UDP | Controller | Platform account, required |

Console access works through the manufacturer. Defold keeps console-specific
code in private repositories and gives approved developers the plugin plus a
build server token; without both, a console build cannot be produced. Approval
comes from Nintendo, Sony, or Microsoft, not from Defold. Xbox was announced for
mid-2024 and its current state should be verified when it matters rather than
assumed.

Steam integration goes through Defold's `extension-steam`, which wraps the
Steamworks SDK and was tracking Steam SDK 1.62 as of mid-2025.

## What each platform forces on the architecture

**The browser forces the transport split.** Browsers cannot open UDP sockets, so
web clients speak WebSocket over TCP while native clients speak UDP. This is
already in [networking.md](networking.md), and it is the single largest
concession any platform extracts from us.

The browser also validates the decision to keep the simulation out of Lua.
Defold's HTML5 builds run Lua 5.1.4 rather than LuaJIT, so a Lua simulation
would be slowest exactly where we most need it to be fast. The same applies to
iOS and Switch, where JIT compilation is prohibited outright. A C core compiled
to WebAssembly and to each native ABI has no JIT to lose.

**Consoles force portability discipline on the sim core.** Console toolchains are
conservative and their SDKs are not ours to inspect ahead of time. Plain C99
with no dependencies, no threads inside the core, no allocation, and no platform
headers is the version of the simulation most likely to compile on a toolchain
we have never seen. This is worth more than any single language feature we give
up.

**Consoles also force a decision about community content.** Our zone model lets
anybody host a server with their own maps, modules, and chat. On a console that
is user-generated content flowing through a certified application, and every
manufacturer has moderation and safety obligations attached to it. The likely
shape is that console builds see a curated zone list and platform-native chat
restrictions, while web and desktop builds see everything. Deciding this late
would be expensive, so the server browser is designed from the start to serve
different zone lists to different client classes.

**Mobile forces a control scheme we do not have.** Subspace-style flight needs
continuous rotation, thrust, and fire, with precision. Touch gives us none of
that for free, and the honest answer is that a virtual stick will feel bad. This
is a design problem rather than an architecture problem, but it decides whether
mobile is a real target or a spectator client.

Mobile also brings network transitions. A phone that moves from wifi to cellular
changes address mid-match, so sessions are identified by a token rather than by
an address, and the server accepts a rebind from a client that proves it holds
the session.

**Controllers forced an aiming decision, and it is made.** Mouse aim and stick
aim are not equivalent, and a game where one input class reliably beats another
splits the population. The original avoided the problem entirely: guns fire
where your nose points, so turning is aiming and every input device steers the
same nose. We keep that, per [decision 17](decisions.md). No aim assist, no
segregated arenas, no per-class tuning, because there is no aim channel for any
of them to act on.

## Fairness across screens

Subspace's settings include `MaxXres` and `MaxYres` because a bigger monitor
literally showed you more of the map, and an arena could refuse to let you use
one. That fix belongs in a world where the client draws pixels one to one with
map pixels.

We use a different one: the camera shows a fixed area of the world, measured in
tiles, regardless of resolution or aspect ratio. A phone and an ultrawide
monitor see the same amount of game, drawn at different sizes. Aspect ratio
still varies, so the visible area is defined by a diagonal bound with limits on
extreme ratios.

This also makes the radar the primary information display rather than the
window, which is how the original actually played.

## Build and CI matrix

The determinism harness described in [simulation-core.md](simulation-core.md)
runs the sim core on every ABI we ship to, because a platform whose arithmetic
diverges is a platform whose players desync. That means Linux x86-64 and arm64,
WebAssembly, macOS arm64, Windows x86-64, Android arm64, and iOS arm64, with
console targets added if and when we have access.

Client bundles are produced by Defold's build server for each target. The web
bundle has a size budget, since the first-time load is the first impression, and
the sim core's WASM contribution to it is measured on every build.

## Open questions

Whether mobile is a playing client or a spectating and social client. Decide
after the touch prototype, not before.

Whether console builds justify their certification and moderation work at all,
or whether the answer is a curated first-party zone and nothing else.

Whether WebTransport arrives broadly enough to give browsers unreliable
datagrams, which would erase the transport split and let one code path serve
every platform.
