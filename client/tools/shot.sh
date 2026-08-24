#!/bin/sh
# Screenshot the native client under a virtual display.
#
# The only honest way to check what this game looks like. A headless build
# draws nothing, and reading pixels back out of a WebGL context returns
# garbage once the frame has been composited, so the loop is: build debug,
# run it on an X server nobody is watching, and grab the root window.
#
#   client/tools/shot.sh out.png [seconds] [key ...]
#
# Extra arguments are keysyms sent with xdotool before the grab, which is how
# a shot of the arena rather than the start screen is taken.
#
# bob writes shaders into build/default/ compiled for whichever platform it was
# last asked about, so a wasm-web build in between leaves the desktop engine
# with shaders it cannot use: "Unable to get a valid shader from a ShaderDesc
# for this context", then a segfault. Build for this host first.
set -e
cd "$(dirname "$0")/.."

if [ "$#" -gt 0 ]; then OUT="$1"; shift; else OUT=/tmp/vectorwake.png; fi
if [ "$#" -gt 0 ]; then WAIT="$1"; shift; else WAIT=6; fi

PLATFORM="${VW_PLATFORM:-x86_64-linux}"
ENGINE_PATH="${VW_ENGINE:-./build/$PLATFORM/dmengine}"
PROJECT_PATH="${VW_PROJECT:-build/default/game.projectc}"
DISPLAY_NUM="${VW_DISPLAY:-:99}"
SIZE="${VW_SIZE:-1280x800x24}"
TMP_DIR=$(mktemp -d)
XVFB=""
ENGINE=""

cleanup() {
    if [ -n "$ENGINE" ]; then kill "$ENGINE" 2>/dev/null || true; fi
    if [ -n "$XVFB" ]; then kill "$XVFB" 2>/dev/null || true; fi
    wait 2>/dev/null || true
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT HUP INT TERM

for tool in Xvfb xdotool xwd xwdtopnm pnmtopng; do
    command -v "$tool" >/dev/null 2>&1 || {
        printf 'shot.sh: need %s\n' "$tool" >&2
        exit 1
    }
done
if [ ! -f "$ENGINE_PATH" ] || [ ! -f "$PROJECT_PATH" ]; then
    printf 'shot.sh: build a %s debug client first\n' "$PLATFORM" >&2
    exit 1
fi

Xvfb "$DISPLAY_NUM" -screen 0 "$SIZE" >"$TMP_DIR/xvfb.log" 2>&1 &
XVFB=$!
sleep 1

# bob writes the engine without the execute bit after every rebuild.
chmod +x "$ENGINE_PATH"
DISPLAY="$DISPLAY_NUM" "$ENGINE_PATH" "$PROJECT_PATH" \
    >"$TMP_DIR/engine.log" 2>&1 &
ENGINE=$!

sleep "$WAIT"
# Xvfb runs without a window manager, so nothing ever gives the engine window
# the input focus and an untargeted keystroke goes nowhere. Find the window
# and aim at it.
WID=$(DISPLAY="$DISPLAY_NUM" xdotool search --onlyvisible --name . 2>/dev/null \
      | tail -1)
if [ -n "$WID" ]; then
    DISPLAY="$DISPLAY_NUM" xdotool windowfocus "$WID" 2>/dev/null || true
    DISPLAY="$DISPLAY_NUM" xdotool windowactivate "$WID" 2>/dev/null || true
fi
# A bare keysym is a tap. Prefix it with + to hold it down for the rest of the
# run, which is the only way to photograph a thruster or a stream of fire.
for key in "$@"; do
    [ -n "$WID" ] || continue
    case "$key" in
      +*) DISPLAY="$DISPLAY_NUM" xdotool keydown --window "$WID" "${key#+}" \
              2>/dev/null || true ;;
      *)  DISPLAY="$DISPLAY_NUM" xdotool key --window "$WID" --clearmodifiers \
              "$key" 2>/dev/null || true ;;
    esac
    sleep 1.2
done

sleep "${VW_SETTLE:-0}"
DISPLAY="$DISPLAY_NUM" xwd -root -silent > "$TMP_DIR/frame.xwd"
xwdtopnm < "$TMP_DIR/frame.xwd" 2>/dev/null | pnmtopng > "$OUT" 2>/dev/null

kill "$ENGINE" 2>/dev/null || true
wait "$ENGINE" 2>/dev/null || true
ENGINE=""

printf 'wrote %s\n' "$OUT"
tail -20 "$TMP_DIR/engine.log"
