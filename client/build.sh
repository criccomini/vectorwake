#!/bin/sh
# Build the Defold client.
#
# The simulation core is copied into the native extension rather than
# referenced, because Defold uploads an extension's directory to its build
# server and a symlink does not survive that trip. The copies are build
# artifacts: git ignores them, and this script refreshes them every run so
# they cannot drift from sim/.
#
#   ./client/build.sh                 # build for this host
#   ./client/build.sh wasm-web        # build for the browser
#
# Platform names are bob's, not the ones the web uses: the browser target is
# wasm-web. `js-web` is rejected outright.
set -e
cd "$(dirname "$0")"

PLATFORM="${1:-x86_64-linux}"
JAVA="${JAVA_HOME:-/usr}/bin/java"
BOB="${BOB_JAR:-/tmp/bob.jar}"

mkdir -p ext/simcore/src ext/simcore/include/sim
cp ../sim/src/sim.c ../sim/src/baseline.c ../sim/src/pack.c ../sim/src/sintab.h ext/simcore/src/
cp ../sim/include/sim/*.h ext/simcore/include/sim/

exec "$JAVA" -jar "$BOB" \
  --archive --platform "$PLATFORM" \
  --variant headless \
  resolve build
