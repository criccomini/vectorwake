# What this means for vectorwake

Conclusions from the reading, stated as positions we can argue with later rather
than as decisions already made.

## Take: the game is a settings file

One binary hosting Trench Wars, Chaos Zone, and a hockey rink is the reason
Subspace outlived its publisher. Zone authors changed ship physics, weapons,
scoring, and win conditions without compiling anything.

For us that means the simulation should read every tunable from configuration,
and the set of tunables should be large enough that a zone author never needs
our source. Roughly 300 arena settings plus 88 per-ship settings is the scale
Subspace found necessary, and it did not feel excessive when we read the
reference.

Open question: whether to stay compatible with the INI format. Compatibility
buys thirty years of existing zone configurations and an audience that already
knows the key names. It costs us a 1997 schema with implied fixed-point scales
baked into the wire format. A reasonable middle path is a native format plus an
importer that reads `arena.conf` and `svs/`.

## Take: degrade laggy players, do not ban them

The four-metric, four-threshold model in ASSS is better than anything we would
have invented. Force to spectator, disallow flag and ball pickup, and ignore a
proportional share of weapons, with the share interpolated between two
thresholds and taken as the maximum across metrics. C2S loss never triggers
weapon ignoring because it already hurts the player.

Copy this nearly verbatim. It encodes a decade of operational experience about
what makes a laggy player unfair rather than just unlucky.

## Take: capabilities, not ranks

Named capabilities assigned to groups, with per-arena overrides and a global
section. Commands imply two capabilities each, public and private. This is
strictly better than a moderator ladder and costs nothing to build early. Adding
it later means auditing every command.

## Take: bots are first-class

Most zone-specific gameplay in Subspace runs in bots that connect as players.
Leagues, duels, matchmaking, and events all live outside the server. Any engine
we build should have a documented, supported path for a program to connect with
elevated rights, rather than treating that as an exploit of the player protocol.

## Drop: client-authoritative damage

The victim reports its own death and names its killer, and the server checks
only that the named killer exists and is in the arena. That was the right call
for 1997 modems and it is indefensible now. Continuum's response was attestation
(executable, settings, and map checksums) rather than authority, and attestation
is a treadmill.

The server should simulate weapons and own damage. Clients predict locally and
reconcile. Subspace's frictionless movement is unusually kind to prediction:
with no drag term, a ship's future position is a closed-form function of thrust
input and wall geometry, so rollback is cheap and mispredictions are small.

## Drop: server-side effects the client cannot see

Regions that silently clear your antiwarp bit while your HUD still shows it
active, and weapon suppression where you see your own shots fire and do nothing.
The manual itself flags these as things to design around. If the server
suppresses something, the client should be told.

## Open: the simulation loop

Subspace runs on 1/100 second ticks with fixed-point integer state. That is not
nostalgia, it is what makes the client and server agree bit for bit and what
lets a position packet fit in 22 bytes.

Whether vectorwake keeps fixed-point determinism or moves to floats with a
tolerance is the largest open question in this document. Fixed-point gives us
cheap desync detection and exact replays. Floats give us easier code and easier
interop with any engine we might adopt. nullspace uses floats and reproduces the
feel closely enough to be a drop-in client, which is evidence that exact
determinism is not required for fidelity.

## Open: how much of the protocol to keep

Keeping the Subspace wire protocol would let existing Continuum clients connect
to our server on day one, which is an enormous shortcut to having anyone to play
with. It would also lock us into `i16` pixel positions, a 1024x1024 tile world,
eight ship slots, a fixed settings struct, and 40 discrete headings.

Worth prototyping the compatibility path before deciding, because "you can point
Continuum at it" is the difference between a project with players and a project
without.

## Next steps

1. Build a settings model and an `arena.conf` importer, since almost everything
   else depends on knowing what is configurable.
2. Prototype the movement and energy model against the units in
   [protocol-and-simulation.md](protocol-and-simulation.md), and compare it to
   nullspace's behavior.
3. Decide the determinism question with a measurement rather than an argument.
4. Sketch the server module boundaries, borrowing ASSS's decomposition and its
   adviser pattern for zone-specific overrides.
