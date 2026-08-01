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

set -- --archive --platform "$PLATFORM" --variant "$VARIANT"
if [ "$TASK" = "bundle" ]; then
  set -- "$@" --bundle-output bundle/"$PLATFORM"
fi

exec "$JAVA" -jar "$BOB" "$@" resolve build "$TASK"
