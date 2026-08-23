# Vendored: defold-websocket

Upstream: https://github.com/defold/extension-websocket
Commit: d8c3ececc7ab2aa097b2aff9f9f273f2bf7da2ca
License: MIT, see `LICENSE.md`

## Local changes

- Lua callbacks run from `OnUpdate`, including the browser's open event.
- Status formatting uses scratch storage because its arguments may point into
  the destination buffer.
- Native sends return partial progress to wslay and wait between handshake
  retries instead of spinning on socket backpressure.
- The receive backlog has a configurable byte cap. Crossing it disconnects the
  socket with an error instead of letting the process grow without bound.

Only the `websocket/` subdirectory of that repository is here. Its examples,
docs, and test project are not, because nothing here builds them.

## Why vendored rather than declared

Defold resolves dependencies from GitHub archive URLs. Those are blocked in
this environment while `git clone` is not, so a `dependencies` entry in
`game.project` cannot resolve and the build fails before it starts.

## Why this path

`client/websocket`, not `client/ext/websocket`. The extension's own manifest
hardcodes its include path as `upload/websocket/include/wslay`, which is the
path Defold's build server sees after uploading a directory named
`websocket`. Renaming the directory breaks the include on the server, and it
breaks there rather than here.

## Updating

Clone upstream, copy its `websocket/` directory over this one, keep this file
and `LICENSE.md`, and record the new commit above. Reapply the local changes
listed here, then run `make -C client/websocket check` before accepting the
update.
