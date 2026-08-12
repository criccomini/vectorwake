#!/bin/sh
# Build the Defold client.
#
# The simulation core is copied into the native extension rather than
# referenced, because Defold uploads an extension's directory to its build
# server and a symlink does not survive that trip. The copies are build
# artifacts: git ignores them, and this script refreshes them every run so
# they cannot drift from sim/.
#
#   ./client/build.sh                          # headless, this host
#   ./client/build.sh wasm-web                 # headless, browser engine only
#   ./client/build.sh wasm-web release bundle  # a bundle you can actually play
#
# Platform names are bob's, not the ones the web uses: the browser target is
# wasm-web. `js-web` is rejected outright.
#
# The headless variant has no renderer. It is what verifies determinism and
# networking from a terminal, and it is useless in a browser: to play, build
# `release` (or `debug`) and `bundle`.
set -e
cd "$(dirname "$0")"

PLATFORM="${1:-x86_64-linux}"
VARIANT="${2:-headless}"
TASK="${3:-build}"

# Both of these are positional, and getting them out of order fails silently:
# `build.sh wasm-web bundle` reads "bundle" as the variant, builds with a
# variant bob does not know, skips bundling entirely, and leaves the previous
# bundle on disk to be published as though it were the new one. It cost a
# release. Reject the mistake instead.
case "$VARIANT" in
  debug|release|headless) ;;
  *) echo "build.sh: unknown variant '$VARIANT'" >&2
     echo "usage: build.sh [platform] [debug|release|headless] [build|bundle]" >&2
     exit 2 ;;
esac
case "$TASK" in
  build|bundle) ;;
  *) echo "build.sh: unknown task '$TASK'" >&2
     echo "usage: build.sh [platform] [debug|release|headless] [build|bundle]" >&2
     exit 2 ;;
esac
JAVA="${JAVA_HOME:-/usr}/bin/java"
BOB="${BOB_JAR:-/tmp/bob.jar}"

mkdir -p ext/simcore/src ext/simcore/include/sim
cp ../sim/src/sim.c ../sim/src/baseline.c ../sim/src/pack.c ../sim/src/sintab.h ext/simcore/src/
cp ../sim/include/sim/*.h ext/simcore/include/sim/

# Stamp the build with the commit it came from, so the start screen can say
# which build a player is looking at. "Is this the old page" stops being a
# debate the moment the answer is printed on it. A dirty tree gets a "+".
STAMP="$(git rev-parse --short HEAD 2>/dev/null || echo dev)$(git diff --quiet 2>/dev/null || echo +)"

# In a directory of its own, not loose in /tmp, and this is not tidiness.
#
# bob resolves settings by walking the directory the settings file lives in, and
# its walk dereferences `listFiles()` without checking it for null. `listFiles()`
# returns null on any directory the process cannot read, so pointing bob at a
# shared /tmp means bob walks whatever else is in /tmp and dies on the first
# entry it lacks permission to list.
#
# That is invisible to anyone running as root, which is why this shipped: it
# built here for weeks and then failed the first time it ran on a GitHub runner,
# as the unprivileged `runner` user, against a /tmp holding root-owned 700
# directories. The error is a NullPointerException from inside bob with no path
# in it, which says nothing at all about permissions or about /tmp.
#
# mktemp -d gives a private directory holding exactly one file, so the walk has
# nothing else to trip over whoever is running it.
STAMP_DIR="$(mktemp -d)"
trap 'rm -rf "$STAMP_DIR"' EXIT
printf '[project]\nversion = %s\n' "$STAMP" > "$STAMP_DIR/vw-stamp.settings"

set -- --archive --platform "$PLATFORM" --variant "$VARIANT" \
       --settings "$STAMP_DIR/vw-stamp.settings"
if [ "$TASK" = "bundle" ]; then
  set -- "$@" --bundle-output bundle/"$PLATFORM"
fi

# Not exec'd. Replacing the shell here would drop the EXIT trap above with it,
# so every build that got this far -- which is every build that succeeds --
# left its stamp directory behind in /tmp. The trap only ever fired on the
# failures, which is the half that did not matter. `set -e` carries the exit
# status out of here unchanged.
"$JAVA" -jar "$BOB" "$@" resolve build "$TASK"
