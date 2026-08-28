#!/bin/sh
# Prove that one published image cannot move a host, while a complete pair can.
set -eu

UPDATE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/update.sh
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP/bin" "$TMP/root/deploy" "$TMP/state"
printf 'VW_ROLE=arena\nVW_HOST_ID=test\nVW_META=https://meta.example/meta\n' \
	>"$TMP/root/deploy/.env"

cat >"$TMP/bin/git" <<'SH'
#!/bin/sh
case "$*" in
"rev-parse HEAD") echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;;
"rev-parse origin/main") echo bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ;;
"rev-parse --short=12 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb") echo bbbbbbbbbbbb ;;
"fetch --quiet origin main"|"reset --hard bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb") ;;
*) echo "unexpected git: $*" >&2; exit 2 ;;
esac
SH

cat >"$TMP/bin/docker" <<'SH'
#!/bin/sh
printf '%s|%s|%s\n' "${VW_IMAGE:-}" "${VW_CLIENT_IMAGE:-}" "$*" >>"$CALLS"
case "$*" in
"pull ghcr.io/criccomini/vectorwake-client:sha-bbbbbbbbbbbb")
	[ "${FAIL_CLIENT:-0}" = 1 ] && exit 1 ;;
"compose --env-file .env exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile")
	[ "${FAIL_RELOAD:-0}" = 1 ] && exit 1 ;;
esac
exit 0
SH

cat >"$TMP/bin/curl" <<'SH'
#!/bin/sh
case "$*" in
"-fsS --max-time 5 https://meta.example/meta/v1/health")
	[ "${FAIL_VERIFY:-0}" = 1 ] && exit 1
	printf '%s\n' '{"service":"meta","verifying_key":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' ;;
*) exit 1 ;;
esac
SH

cat >"$TMP/bin/logger" <<'SH'
#!/bin/sh
exit 0
SH

chmod +x "$TMP/bin/git" "$TMP/bin/docker" "$TMP/bin/curl" "$TMP/bin/logger"
export PATH=$TMP/bin:$PATH
export VW_ROOT=$TMP/root
export VW_UPDATE_STATE=$TMP/state
export CALLS=$TMP/calls

FAIL_CLIENT=1; export FAIL_CLIENT
"$UPDATE"
[ ! -e "$TMP/state/release" ]
! grep -q '|compose ' "$CALLS"

: >"$CALLS"
FAIL_CLIENT=0; export FAIL_CLIENT
FAIL_VERIFY=1; export FAIL_VERIFY
"$UPDATE"
[ ! -e "$TMP/state/release" ]
! grep -q '|compose ' "$CALLS"
! grep -q '^VW_META_VERIFY=' "$TMP/root/deploy/.env"

: >"$CALLS"
FAIL_VERIFY=0; export FAIL_VERIFY
FAIL_RELOAD=1; export FAIL_RELOAD
if "$UPDATE"; then
	echo "test failed: a failed Caddy reload published the release" >&2
	exit 1
fi
[ ! -e "$TMP/state/release" ]
grep -q '^VW_META_VERIFY=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa$' \
	"$TMP/root/deploy/.env"
grep -q 'compose --env-file .env up -d --remove-orphans' "$CALLS"
grep -q 'compose --env-file .env exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile' "$CALLS"

: >"$CALLS"
FAIL_RELOAD=0; export FAIL_RELOAD
"$UPDATE"
[ "$(cat "$TMP/state/release")" = bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ]
grep -q 'ghcr.io/criccomini/vectorwake:sha-bbbbbbbbbbbb|ghcr.io/criccomini/vectorwake-client:sha-bbbbbbbbbbbb|compose --env-file .env up -d --remove-orphans' "$CALLS"
grep -q 'compose --env-file .env exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile' "$CALLS"

# A release that stops declaring a service has to stop its container. Left
# running, a dropped arena keeps its registration and holds a zone in the
# fleet's view that no player can reach, and every other arena stands down
# from a game that looks served.
grep -q -- '--remove-orphans' "$CALLS"
echo "paired release and Caddy reload gate passed"
