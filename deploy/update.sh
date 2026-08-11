#!/bin/sh
# Converge on what main and the registry say. Quiet when there is nothing to do.
#
# Run by the vw-update timer provision.sh installs, from this checkout rather
# than from a copy, and that location is the point: the updater used to be
# written to /usr/local/bin at first boot and never touched again, which made
# it the second file on a host a deploy could not update. Its first frozen bug
# read the running image off the a1 container, which a central host does not
# have, so every update line on such a host said "(image )" forever. Now the
# updater is repository content and fixes itself on the next converge.
#
# Two things can move and both are checked, because they move for different
# reasons. The checkout carries the compose files, the Caddy config and the
# client bundle, which are read from disk at container start. The image carries
# the binary and the catalog. A commit that only touches docs changes neither,
# and this exits without a word.
set -u
cd /opt/vectorwake || exit 0

before=$(git rev-parse HEAD)
GIT_SSH_COMMAND='ssh -i /root/.ssh/vw_deploy -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new' \
	git fetch --quiet origin main || exit 0
after=$(git rev-parse origin/main)
[ "$before" = "$after" ] || git reset --hard "$after" >/dev/null 2>&1 || exit 1

cd deploy || exit 1
LOG=/var/lib/vw-deploy/deploy/update.log

# Hosts provisioned before the admin panel have no VW_ADMIN_HOST in their
# .env, and compose then serves the panel's site block as admin.localhost.
# The name is the front door's domain with a different first label, so a
# host that serves the front can derive it; provision.sh writes it for new
# hosts and this appends it once for the ones that already exist. Central
# roles only: an arena host wants the variable absent, which the compose
# default already handles, and appending nothing is how absence stays.
if ! grep -q '^VW_ADMIN_HOST=' .env 2>/dev/null; then
	case $(sed -n 's/^VW_ROLE=//p' .env) in
	central|all)
		front=$(sed -n 's/^VW_HOST=//p' .env)
		[ -n "$front" ] && printf 'VW_ADMIN_HOST=admin.%s\n' "${front#*.}" >>.env
		;;
	esac
fi

# The running image, read off the first game container this host's role has.
# Central runs a directory and no arena, an arena host the reverse, so the
# services are tried in turn rather than assumed.
seat() {
	for svc in directory a1; do
		sid=$(docker compose --env-file .env ps -q "$svc" 2>/dev/null) || continue
		[ -n "$sid" ] || continue
		docker inspect --format '{{.Image}}' "$sid" 2>/dev/null
		return 0
	done
	return 0
}

# Pull, then converge. No condition around either, because `up -d` already is
# one: compose recreates a container only when its configuration or its image id
# actually differs, so this is a no-op on the minutes when nothing moved. An
# earlier version compared digests by hand to decide whether to run it at all,
# which is the same decision made twice and the second copy is the one that gets
# it wrong.
#
# And no --force-recreate, which is the important part: compose touches only what
# changed, so a server image change does not restart Caddy and therefore cannot
# disturb TLS. That is what keeps a deploy off the Let's Encrypt rate limit, and
# it is the whole reason deploying is this and not a reinstall.
was=$(seat)
docker compose --env-file .env pull --quiet >>"$LOG" 2>&1 || true
docker compose --env-file .env up -d >>"$LOG" 2>&1
now=$(seat)

# Reported after the fact rather than predicted. What this host is running is
# the only thing worth writing down, and the honest way to know is to look.
[ "$before" = "$after" ] && [ "$was" = "$now" ] && exit 0
logger -t vw-update "converged to $after, image ${now:-none}"
printf '%s  updated to %s (image %.19s)\n' "$(date -u +%H:%M:%SZ)" "$after" \
	"${now#sha256:}" >>/var/lib/vw-deploy/deploy/status
