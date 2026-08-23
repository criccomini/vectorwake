#!/bin/sh
# Converge a host on one commit. The checkout, server image and client image
# move only after both immutable images for that commit are available.
set -u

ROOT=${VW_ROOT:-/opt/vectorwake}
STATE=${VW_UPDATE_STATE:-/var/lib/vw-deploy/deploy}
LOG=${VW_UPDATE_LOG:-$STATE/update.log}
RELEASE=${VW_RELEASE_FILE:-$STATE/release}
mkdir -p "$STATE"
cd "$ROOT" || exit 0

before=$(git rev-parse HEAD)
GIT_SSH_COMMAND='ssh -i /root/.ssh/vw_deploy -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new' \
	git fetch --quiet origin main || exit 0
after=$(git rev-parse origin/main)
deployed=$(cat "$RELEASE" 2>/dev/null || true)
[ "$deployed" = "$after" ] && exit 0

short=$(git rev-parse --short=12 "$after")
VW_IMAGE=ghcr.io/criccomini/vectorwake:sha-$short
VW_CLIENT_IMAGE=ghcr.io/criccomini/vectorwake-client:sha-$short
export VW_IMAGE VW_CLIENT_IMAGE

# A server workflow and a client workflow finish independently. Pull both
# immutable tags before changing the checkout, so the faster workflow can
# never put one half of a release live by itself.
if ! docker pull "$VW_IMAGE" >>"$LOG" 2>&1; then
	printf '%s  waiting for %s\n' "$(date -u +%H:%M:%SZ)" "$VW_IMAGE" >>"$LOG"
	exit 0
fi
if ! docker pull "$VW_CLIENT_IMAGE" >>"$LOG" 2>&1; then
	printf '%s  waiting for %s\n' "$(date -u +%H:%M:%SZ)" "$VW_CLIENT_IMAGE" >>"$LOG"
	exit 0
fi

[ "$before" = "$after" ] || git reset --hard "$after" >/dev/null 2>&1 || exit 1
cd deploy || exit 1

# Older hosts did not record these derived values. Append each once while the
# checkout is already at the release that knows how to use it.
if ! grep -q '^VW_HOST_ID=' .env 2>/dev/null; then
	id=$(curl -s --max-time 3 http://169.254.169.254/v1.json 2>/dev/null \
		| grep -o '"instance-v2-id"[^,]*' | cut -d'"' -f4)
	[ -n "$id" ] || id=$(curl -s --max-time 3 http://169.254.169.254/v1.json 2>/dev/null \
		| grep -o '"instanceid"[^,]*' | cut -d'"' -f4)
	printf 'VW_HOST_ID=%s\n' "$id" >>.env
fi

if ! grep -q '^VW_ADMIN_HOST=' .env 2>/dev/null; then
	case $(sed -n 's/^VW_ROLE=//p' .env) in
	central|all)
		front=$(sed -n 's/^VW_HOST=//p' .env)
		[ -n "$front" ] && printf 'VW_ADMIN_HOST=admin.%s\n' "${front#*.}" >>.env
		;;
	esac
fi

if ! grep -q '^VW_SITE_HOST=' .env 2>/dev/null; then
	case $(sed -n 's/^VW_ROLE=//p' .env) in
	central|all)
		front=$(sed -n 's/^VW_HOST=//p' .env)
		[ -n "$front" ] && printf 'VW_SITE_HOST=%s\n' "${front#*.}" >>.env
		;;
	esac
fi

if ! docker compose --env-file .env up -d >>"$LOG" 2>&1; then
	logger -t vw-update "release $after failed during compose converge"
	exit 1
fi

# The Caddyfile is bind-mounted from the checkout. Compose sees the same mount
# path after a route changes, so it correctly leaves Caddy running and Caddy
# correctly keeps serving the old config. Reload it in place: a new arena path
# becomes reachable without severing every socket already passing through it.
if ! docker compose --env-file .env exec -T caddy caddy reload \
	--config /etc/caddy/Caddyfile --adapter caddyfile >>"$LOG" 2>&1; then
	logger -t vw-update "release $after failed during Caddy reload"
	exit 1
fi

release_tmp=$RELEASE.tmp
printf '%s\n' "$after" >"$release_tmp" && mv -f "$release_tmp" "$RELEASE"
logger -t vw-update "converged to $after with paired sha-$short images"
printf '%s  updated to %s (paired sha-%s)\n' "$(date -u +%H:%M:%SZ)" "$after" "$short" \
	>>"$STATE/status"
