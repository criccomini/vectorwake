# Subspace and Continuum: the game

## Where it came from

Subspace began in 1995 as a project called Sniper, built to measure how badly
lag would break a massively multiplayer game over dial-up. The test turned into
a game. Public beta ran from February 1996, and Virgin Interactive shipped the
retail version in December 1997 at $27.99 with no subscription, an unusual model
at the time. Development was at Burst Studios, with Michael Simpson, Rod Humble,
and Jeff Petersen directing.

It sold badly. Players had two years of free beta behind them and many would not
pay; marketing was thin. Virgin dissolved in 1998, Electronic Arts bought most of
the US assets but not the Subspace license, and the official servers went dark.
Player-run servers kept the game alive with no company behind them, which is why
a 1997 game still has zones running in 2026.

The client everyone uses today is Continuum, released in 2001 by PriitK and Mr
Ekted. They reverse engineered the original client without source access, mainly
to close the cheating holes in it. Continuum became the client the central
billing server would accept. A fan-reconstructed Continuum reached Steam on
3 July 2015.

Two facts from that history matter to us. Subspace was designed around the
assumption that the network is bad, and it survived because the people running
zones could change the game without changing the engine.

## What a session looks like

You fly a small ship on a 1024x1024 tile map seen from above. There is no
friction. Thrust and rotation are the whole of movement, momentum never bleeds
off, and you cannot stop except in a safe zone. Walls bounce you rather than
kill you.

Energy is health and ammunition at once. Firing costs energy, damage subtracts
energy, and energy regenerates continuously. Reaching zero kills you. Every
tactical decision in the game comes out of that single pool: a player at low
energy cannot shoot without dying, so retreating is a real cost and chasing is a
real threat.

Prizes, called greens, litter the map. Flying over one grants a random upgrade
(more thrust, better recharge, an extra burst) or, occasionally, a penalty. Dying
strips them. Bounty rises as you collect greens and kill people, and your bounty
is what your killer is paid, so a player on a long streak becomes a target worth
hunting.

## The eight ships

Warbird, Javelin, Spider, Leviathan, Terrier, Weasel, Lancaster, Shark. Their
roles in most zones run roughly like this: Warbird as the fast interceptor,
Javelin as a bomber with a flat bomb arc, Spider as a rapid-fire skirmisher,
Leviathan as the slow heavy bomber, Terrier as the support ship other players
attach to, Weasel as a cloaked assassin, Lancaster as a close-range brawler, and
Shark as the mine-laying zone-denial ship.

Those roles are conventions, not properties of the engine. A ship's speed,
thrust, rotation rate, energy, recharge, weapon levels, and every special it can
hold are numbers in the arena configuration. The same client renders a
Warbird that is nimble in one zone and a brick in another. There are eight ship
slots, and everything else about them is content.

## Modes

Kill games are pure deathmatch, scored on bounty transfer.

Flag games come in several shapes. Warzone-style asks a team to hold every flag
at once, at which point the round ends and resets. Turf-style bolts flags to the
map and pays teams periodically for what they hold. Capture-the-flag style, in
Trench Wars and its imitators, is about carrying flags to a base and holding
them for a timer. The server ships two flag game modules, `fg_wz` and `fg_turf`,
and zones write their own for anything else.

Ball games put one to eight balls on the map. Powerball is soccer with dogfights
between goals; hockey assigns ship types to positions and plays on a rink map.
Balls are passed by firing them, can be set to bounce off walls or not, and can
be configured so that dying on a goal tile while carrying scores.

## Zones, arenas, and freqs

A zone is a server. An arena is a room inside it with its own map, settings, and
scores. A freq (frequency) is a team, identified by a number. Public freqs are
low-numbered and balanced by the server; anything above a configurable threshold
is a private freq that players form themselves, optionally password protected or
owned by whoever got there first.

Players move between arenas without reconnecting, chat spans the zone, and
spectators sit on a designated freq watching. This structure is the reason
Subspace felt like an MMO on a dial-up budget: the population is one social
space, but simulation only ever happens inside one arena at a time.

## Why zones diverged so far

Trench Wars, Chaos Zone, Hyperspace, Extreme Games, and Death Star Battle share
one executable and almost nothing else. A zone author controls ship physics,
weapon damage and cost, prize tables, flag and ball rules, radar behavior, spawn
points, doors, and the map itself. The engine supplies the primitives; the
config file supplies the game.

We should treat this as the headline design lesson rather than a curiosity. The
thing that kept Subspace alive for thirty years was not its netcode. It was that
one server binary could host a dozen genuinely different games, authored by
people who never compiled anything.
