#!/bin/sh
# Photograph the golden screens: every menu tab, the flight HUD, and as much
# of a match cycle as patience allows, into one directory for eyeballing or
# diffing against the last set.
#
#   client/tools/goldens.sh out_dir
#
# This is the net the podium chip bug fell through. The layer that decides
# what a screen holds is covered by tests reading the queued text and boxes,
# and the layer that turns them into pixels is not: a text pool overflow and
# a sub-pixel stroke both shipped drawing everything into the queue and less
# than everything onto the glass. Only pixels catch that class, so this
# produces the pixels; what shot.sh is to one screenshot, this is to the set.
#
# It wants what shot.sh wants (a debug build for this host, Xvfb, xdotool,
# xwd, netpbm) plus a fleet to photograph: a directory answering on
# ws://127.0.0.1:9000 with an arena and bots behind it, so the HUD frames
# hold a real fight. Keys are held ~400 ms, because a press faster than a
# frame never reaches the engine; see the input note in arena/arena.script.
# H is a toggle and escape closes the table before it opens the menu, so the
# help shot presses H twice rather than holding it: a table left up spends
# the next escape and the menu shot photographs the wrong screen.
#
# The match samples land wherever the room's clock happens to be, so a full
# run usually catches flying, a podium, and a death; read the clock in the
# corner of each frame to see which is which.
set -e
cd "$(dirname "$0")/.."

OUT="${1:?usage: goldens.sh out_dir}"
mkdir -p "$OUT"

PLATFORM="${VW_PLATFORM:-x86_64-linux}"
ENGINE_PATH="${VW_ENGINE:-./build/$PLATFORM/dmengine}"
PROJECT_PATH="${VW_PROJECT:-build/default/game.projectc}"
DISPLAY_NUM="${VW_DISPLAY:-:99}"
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
        printf 'goldens.sh: need %s\n' "$tool" >&2
        exit 1
    }
done
if [ ! -f "$ENGINE_PATH" ] || [ ! -f "$PROJECT_PATH" ]; then
    printf 'goldens.sh: build a %s debug client first\n' "$PLATFORM" >&2
    exit 1
fi

Xvfb "$DISPLAY_NUM" -screen 0 "${VW_SIZE:-1280x800x24}" \
    >"$TMP_DIR/xvfb.log" 2>&1 &
XVFB=$!
sleep 1

# One engine per sequence, because the menu remembers the last game and the
# arena remembers nothing: a fresh boot lands on the play page either way.
run() {
    STEPS="$1"
    chmod +x "$ENGINE_PATH"
    DISPLAY="$DISPLAY_NUM" "$ENGINE_PATH" "$PROJECT_PATH" \
        --config=vectorwake.directory="${VW_DIRECTORY:-ws://127.0.0.1:9000}" \
        >"$TMP_DIR/engine.log" 2>&1 &
    ENGINE=$!
    sleep "${VW_BOOT:-7}"
    WID=$(DISPLAY="$DISPLAY_NUM" xdotool search --onlyvisible --name . \
          2>/dev/null | tail -1)
    [ -n "$WID" ] && DISPLAY="$DISPLAY_NUM" xdotool windowfocus "$WID" \
        2>/dev/null || true
    OLDIFS=$IFS; IFS=';'
    for step in $STEPS; do
        IFS=$OLDIFS
        set -- $step
        case "$1" in
          shot)
            DISPLAY="$DISPLAY_NUM" xwd -root -silent > "$TMP_DIR/frame.xwd"
            xwdtopnm < "$TMP_DIR/frame.xwd" 2>/dev/null \
                | pnmtopng > "$OUT/$2.png" 2>/dev/null
            printf 'shot %s\n' "$OUT/$2.png" ;;
          key)
            DISPLAY="$DISPLAY_NUM" xdotool keydown --window "$WID" "$2" || true
            sleep 0.4
            DISPLAY="$DISPLAY_NUM" xdotool keyup --window "$WID" "$2" || true
            sleep 0.6 ;;
          hold)
            DISPLAY="$DISPLAY_NUM" xdotool keydown --window "$WID" "$2" || true
            sleep 0.4 ;;
          release)
            DISPLAY="$DISPLAY_NUM" xdotool keyup --window "$WID" "$2" || true
            sleep 0.3 ;;
          wait)
            sleep "$2" ;;
        esac
        IFS=';'
    done
    IFS=$OLDIFS
    kill "$ENGINE" 2>/dev/null || true
    wait "$ENGINE" 2>/dev/null || true
    ENGINE=""
}

# The tabs and the boards under settings.
# Two Ups out of the landing: the first can step the zone carousel (the
# cursor may open on a later zone), the second reaches the tab row.
run "shot menu-play;\
 key Up; key Up; key Right; key Down; shot menu-ship"
run "key Up; key Right; key Right;\
 key Down; shot menu-settings;\
 key Down; key Down; key Down; key Down; key Return; shot menu-controls;\
 key Down; key Down; key Down; key Return; shot menu-about"

# In a game: the HUD, its panels, the help table, and then a sample every
# twenty seconds across one full match cycle, which is long enough to cross
# a whistle wherever the room's clock stands.
run "key Return; wait 6; shot hud-flying;\
 key p; key Prior; shot hud-scoreboard;\
 key m; shot hud-map; key m; key p;\
 key h; shot hud-help; key h;\
 key Escape; shot hud-menu; key Escape;\
 wait 12; shot hud-t1; wait 20; shot hud-t2; wait 20; shot hud-t3;\
 wait 20; shot hud-t4; wait 20; shot hud-t5; wait 20; shot hud-t6;\
 wait 20; shot hud-t7; wait 20; shot hud-t8; wait 20; shot hud-t9;\
 wait 20; shot hud-t10"

printf 'goldens in %s\n' "$OUT"
