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
JAVA="${JAVA_HOME:-/usr}/bin/java"
BOB="${BOB_JAR:-/tmp/bob.jar}"

mkdir -p ext/simcore/src ext/simcore/include/sim
cp ../sim/src/sim.c ../sim/src/baseline.c ../sim/src/pack.c ../sim/src/sintab.h ext/simcore/src/
cp ../sim/include/sim/*.h ext/simcore/include/sim/

set -- --archive --platform "$PLATFORM" --variant "$VARIANT"
if [ "$TASK" = "bundle" ]; then
  set -- "$@" --bundle-output bundle/"$PLATFORM"
fi

exec "$JAVA" -jar "$BOB" "$@" resolve build "$TASK"
