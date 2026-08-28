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

# Arena hosts provisioned before the pilot-attestation gate do not have its
# public key. New hosts receive the pinned value from the secrets bucket. This
# one-time bridge asks the deployment's existing HTTPS meta endpoint for the
# same public half, writes it with the rest of the host credentials, and never
# asks again once a value is present.
meta_verify=$(sed -n 's/^VW_META_VERIFY=//p' .env 2>/dev/null | tail -n 1)
if [ -z "$meta_verify" ] && [ "$(sed -n 's/^VW_ROLE=//p' .env)" = arena ]; then
	meta=$(sed -n 's/^VW_META=//p' .env | tail -n 1)
	health=
	if [ -n "$meta" ]; then
		health=$(curl -fsS --max-time 5 "${meta%/}/v1/health" 2>>"$LOG") || health=
	fi
	meta_verify=$(printf '%s' "$health" \
		| grep -oE '"verifying_key":"[0-9a-fA-F]{64}"' \
		| head -n 1 | cut -d'"' -f4)
	if ! printf '%s' "$meta_verify" | grep -qiE '^[0-9a-f]{64}$'; then
		printf '%s  waiting for the public verifier from %s\n' \
			"$(date -u +%H:%M:%SZ)" "${meta:-the meta endpoint}" >>"$LOG"
		exit 0
	fi
	env_tmp=.env.vw-update.$$
	if grep -q '^VW_META_VERIFY=' .env; then
		(umask 077; sed "s/^VW_META_VERIFY=.*/VW_META_VERIFY=$meta_verify/" \
			.env >"$env_tmp") || { rm -f "$env_tmp"; exit 1; }
	else
		(umask 077; { cat .env; printf 'VW_META_VERIFY=%s\n' "$meta_verify"; } \
			>"$env_tmp") || { rm -f "$env_tmp"; exit 1; }
	fi
	mv -f "$env_tmp" .env || { rm -f "$env_tmp"; exit 1; }
fi

# `--remove-orphans` because a release that drops a service has to drop its
# container too. Without it the container keeps running on the image it was
# started with, and an arena is the worst thing to leave behind: it is still
# registered, so the fleet's own view counts it as covering a zone, while the
# Caddy route the same release deleted means no player can reach it. Every
# other arena then reads that zone as served and stands down, and the games
# list goes empty while every process looks healthy. That is how removing a
# second arena took the fleet down for three hours.
#
# Scoped to this host's own COMPOSE_FILE, which `.env` pins per role, so what
# it removes is what this role stopped declaring and nothing else.
if ! docker compose --env-file .env up -d --remove-orphans >>"$LOG" 2>&1; then
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
