#!/bin/bash
# SessionStart hook: install OptMem and point it at the repo's .optmem store.
#
# OptMem (github.com/VictorTaelin/OptMem) is a single Python file that keeps an
# append-only memory log. By default it stores memories in ~/.optmem/memory,
# which dies with an ephemeral container. We set MEMORY_DIR to .optmem/memory
# inside the repo so memories are committed and travel with the project.
set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
TOOL_DIR="$HOME/.optmem"
TOOL="$TOOL_DIR/memo"
MEMORY_DIR="$PROJECT_DIR/.optmem/memory"
SRC_URL="https://raw.githubusercontent.com/VictorTaelin/OptMem/main/memo"

command -v python3 >/dev/null || {
  echo "OptMem needs python3, which is not on this machine." >&2
  exit 0
}

# Fetch the tool. If the network is down but we already have a copy, keep it.
mkdir -p "$TOOL_DIR"
if curl -fsSL --max-time 30 "$SRC_URL" -o "$TOOL_DIR/memo.new"; then
  mv "$TOOL_DIR/memo.new" "$TOOL"
  chmod +x "$TOOL"
elif [ -x "$TOOL" ]; then
  rm -f "$TOOL_DIR/memo.new"
  echo "Could not reach GitHub; keeping the installed OptMem." >&2
else
  rm -f "$TOOL_DIR/memo.new"
  echo "Could not reach GitHub and OptMem is not installed; skipping." >&2
  exit 0
fi

# `init` only creates what is missing, so this is safe on every session.
MEMORY_DIR="$MEMORY_DIR" "$TOOL" init >/dev/null

# Every later Bash call in this session inherits MEMORY_DIR, so a bare
# `~/.optmem/memo wake` reads the repo's store rather than the home one.
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo "export MEMORY_DIR=\"$MEMORY_DIR\"" >> "$CLAUDE_ENV_FILE"
fi

echo "OptMem ready: $TOOL, memories in $MEMORY_DIR"
