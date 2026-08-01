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

OUT="${1:-/tmp/vectorwake.png}"
WAIT="${2:-6}"
shift 2 2>/dev/null || true

DISPLAY_NUM=":99"
SIZE="${VW_SIZE:-1280x800x24}"

Xvfb "$DISPLAY_NUM" -screen 0 "$SIZE" >/dev/null 2>&1 &
XVFB=$!
sleep 1

# bob writes the engine without the execute bit after every rebuild.
chmod +x ./build/x86_64-linux/dmengine
DISPLAY="$DISPLAY_NUM" ./build/x86_64-linux/dmengine build/default/game.projectc \
    >/tmp/vw-engine.log 2>&1 &
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
DISPLAY="$DISPLAY_NUM" xwd -root -silent > /tmp/vw.xwd
xwdtopnm < /tmp/vw.xwd 2>/dev/null | pnmtopng > "$OUT" 2>/dev/null

kill "$ENGINE" 2>/dev/null || true
kill "$XVFB" 2>/dev/null || true
wait 2>/dev/null || true

echo "wrote $OUT"
tail -20 /tmp/vw-engine.log
