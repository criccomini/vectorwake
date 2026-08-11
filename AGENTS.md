# vectorwake

A top-down space MMO inspired by Subspace Continuum. Inherited: the simulation
model. Ours: the ships, art, sound, maps, and fiction. No asset or name from the
original enters this repository.

Code is underway, starting with the simulation core.

- `docs/research/` is what we learned about the original game and its servers.
- `docs/architecture/` is how vectorwake is built: Defold client, shared
  deterministic C simulation core, authoritative Rust zone server.
- `docs/design/` is what the game is: identity, art direction, ships.
- `client/` is the Defold client: five mesh layers of vector art, a gui that
  draws only text, and sound the client synthesises at boot from
  `client/ext/simcore/src/sfx.c`.
- `sim/` is the simulation core: C99, fixed point, no dependencies, no floats.
  `make -C sim check` must pass before any push that touches it. Its state
  hashes are compared across x86-64, arm64, and WASM in CI; if you change sim
  behavior deliberately, regenerate the reference with `make -C sim golden`
  and say so in the commit message.

Conventions:

- Commit and push to `main`.
- `.claude/hooks/session-start.sh` installs OptMem and exports `MEMORY_DIR`, so
  the `memo` commands below operate on this repo's store.

## Ground rules

`CONSTITUTION.md` at the root is the baseline: how to take an instruction, when
to ask, what not to overwrite, what counts as verified. Read it and follow it.
Everything else in this file overrides it, and so does anything you are asked
for directly.

@CONSTITUTION.md

It is the Clanker Constitution, vendored at release `v2026.08.10` and not ours
to edit. Update it by copying a newer reviewed tag from
https://github.com/kenn-io/constitution rather than fetching one at startup, so
the rules an agent boots with are the rules in the commit. Same arrangement as
the vendored humanizer skill: preferences that are ours belong in this file,
beside the rest of the house style.

## Shipping

The web build is how this game is actually looked at, so a change nobody can play
is not finished. **CI builds and publishes it.** Push to `main` and
`.github/workflows/client.yml` builds the bundle and publishes
`ghcr.io/criccomini/vectorwake-client:prod`; the host pulls it within a minute and
a one-shot container copies it into the volume Caddy serves. Nothing to build by
hand, nothing to commit.

That is new, and it replaces an instruction to run `build.sh` and commit
`client/dist/index.html`. Two things wrong with that: 5 MB of git history per
release, and a step that depended on somebody remembering. Twice in one day
somebody changed the simulation core without rebuilding, and the second time a
player joining Chaos was shown DESTROYED on a healthy fleet -- the deployed
client's compiled core was reading a wire the server had stopped writing. So the
rule that used to be here, "anything that changes the simulation core counts as a
client change, because the client links the same core to predict with", is now the
`sim/**` path filter on that workflow rather than a sentence to remember.

Build it locally when you want to look at it before pushing:

```sh
JAVA_HOME=/path/to/jdk25 ./client/build.sh wasm-web release bundle
python3 client/tools/single_file.py client/bundle/wasm-web/vectorwake <out>.html --fragment
```

`client/dist/` is git-ignored, so a local build cannot be committed by accident.

Do not publish that file as an artifact. Artifact pages are served under
`connect-src 'self'`, which blocks every outbound WebSocket, so the page cannot
reach a directory or an arena no matter what it is pointed at. Learned by
pointing it at the live fleet and reading the console. That used to leave
something playable, because the client flew its own practice arena when it could
not reach a server; since the offline mode went (decision 20) it leaves a menu
listing games it cannot join. To look at a change, push and let CI publish it, or
build locally and run a server next to it.

## Engineering rules

- Do not preserve backward compatibility.
- Choose the simplest implementation that fully meets the current requirements.
- Prefer established, well-maintained libraries over custom implementations.

## Writing

Everything you write goes through the `humanizer` skill: commit messages, pull
request bodies, documents under `docs/`, the README, code comments, and replies
in chat. Prose is prose wherever it lands, so run it as the last step before
text leaves your hands rather than as an optional pass at the end.

The skill is vendored in `.claude/skills/humanizer/`, and `SOURCE.md` beside it
records the upstream version and commit so a future update knows what is local
and what is not. Do not edit the vendored copy. Preferences that are ours
belong here instead, where they sit next to the rest of the house style.

One consequence is worth stating, because it contradicts a habit visible
throughout this repository. Section 14 bans em dashes and the spaced double
hyphen that stands in for one. There are about a thousand of the latter here,
mostly in C comments and commit messages, and they are the same tell wearing a
hat. New prose does not use them. Existing lines get fixed when you are editing
them for another reason, never in a sweep of their own.

## Memory

Your memory is OptMem:
- The tool is `~/.optmem/memo`
- Your memories are in `.optmem/memory`, inside this repo, and are committed
  with it. Commit them along with the work that produced them.

OptMem outlives every session, compaction, model and vendor change.
Without it you do not know who you are, or what was decided and tried.

Constitution section 7 warns against agent-private memories standing in for
shared instructions, which is not what this is: the store is committed to the
repository and read by whoever comes next. Durable project guidance still
belongs in this file.

### At startup: activating OptMem (mandatory)

Run `~/.optmem/memo wake` before any other tool call, in every session, and
then do exactly what it prints, to the end of its output.

### While working: register memories (mandatory)

Call `~/.optmem/memo note "<1 line, max 280 bytes>"` whenever you learn
something new, or something worth keeping happens. That covers a task
worth real effort, a fact or insight the user teaches you, anything you
learn about their life (even indirectly), any event of lasting effect.

Do not register redundant memories.

If `~/.optmem/memo note` asks a compression: do it before your next action.

Never edit or delete anything under `.optmem/memory`: the tool manages it.

### When you need an old memory: search, or navigate

`~/.optmem/memo recall <regex>` searches every memory, word for word.

Your memories also form a binary tree: #0-1, #2-3 ... exist as one-line
summaries, pairs of those as #0-3, and so on -- every `#a-b` line wake
prints is one node of it. `~/.optmem/memo zoom <a-b>` opens a node into its
two halves, down to the raw memories.

### If you're a subagent: skip everything above

Parallel sessions on this machine are all you, and may all write memories.
A subagent is not: it must never run `memo`, because it cannot judge what
is already known, and its notes would arrive duplicated and incorrectly.
When you spawn one, write: `You are a subagent. Don't run memo.`
