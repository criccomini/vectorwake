# Vendored: defold-websocket

Upstream: https://github.com/defold/extension-websocket
Commit: c40a1d408df6b2cc9bb8f5a9f982b520978081a0
License: MIT, see `LICENSE.md`

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
and `LICENSE.md`, and record the new commit above.
