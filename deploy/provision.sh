#!/bin/sh
# Everything a vectorwake host needs, from a bare Ubuntu to a running game.
#
# Run once by cloud-init at first boot. It is a script rather than a list of
# runcmd entries for one reason: every line's output lands in one log that is
# already being served, so a failure says which step and why. The first attempt
# at this was sixteen runcmd entries whose only diagnostic channel was a file
# served by a proxy that started after the step that failed, which is a way of
# saying there was no diagnostic channel.
#
# Placeholders substituted before submission, none committed:
#   __POOL_TOKEN__  __ADMIN_TOKEN__  __BRANCH__  __DEPLOY_KEY_B64__
set -u

DIR=/var/lib/vw-deploy          # served by the bootstrap server, at /
LOG=$DIR/deploy                 # served by Caddy, at /deploy
mkdir -p "$LOG"
exec >>"$LOG/provision.log" 2>&1

say() {
	printf '%s  %s\n' "$(date -u +%H:%M:%SZ)" "$*" >>"$LOG/status"
	echo "=== $*"
}

# The log is served by a python one-liner until Caddy takes the port. Both of
# these exist because the first version killed the bootstrap server and then
# started Caddy: when Caddy did not come up, the box went silent at exactly the
# moment it had something to say, and the only way to read the reason was a VNC
# console. A host that cannot report its own failure is a host you debug by
# guessing.
bootstrap_up() {
	[ -f /tmp/bootstrap-http.pid ] && kill -0 "$(cat /tmp/bootstrap-http.pid)" 2>/dev/null && return
	( cd "$DIR" && nohup python3 -m http.server 80 --bind 0.0.0.0 >/dev/null 2>&1 &
	  echo $! >/tmp/bootstrap-http.pid )
	sleep 1
}
bootstrap_down() {
	[ -f /tmp/bootstrap-http.pid ] && kill "$(cat /tmp/bootstrap-http.pid)" 2>/dev/null
	rm -f /tmp/bootstrap-http.pid
	sleep 1
}
die() {
	say "FAILED: $*"
	say "the full output is at /deploy/provision.log"
	# Whatever went wrong, leave something serving the reason.
	bootstrap_up
	exit 1
}

# Visibility before anything that can fail. python3 is in the base image, so
# this needs no package, no network and no repository -- which is the point,
# since the steps most likely to break are the ones that need all three. Caddy
# replaces it on the same port once there is something to reverse-proxy.
say "provisioning started; serving this log on port 80"
bootstrap_up

# Swap before the build. cargo linking tokio and rustls is the peak memory of
# this host's life by a wide margin, and a linker killed by the OOM reaper is
# the worst failure available on a box nobody can log into. The fstab line is
# guarded: written unconditionally it produces a duplicate entry and systemd
# complains about it every ten seconds forever.
if ! swapon --show=NAME --noheadings | grep -q /swapfile; then
	say "adding 2G of swap"
	fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile \
		&& swapon /swapfile || die "could not create swap"
fi
grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab

say "installing docker"
curl -fsSL https://get.docker.com | sh || die "docker install"
systemctl enable --now docker || die "docker would not start"

# The repository is private, so the host authenticates with a read-only deploy
# key scoped to it. accept-new rather than a pinned host key: pinning a
# fingerprint this script cannot itself verify trades a real failure mode for a
# theatrical one, and the window is a single fetch on a fresh host.
say "installing the deploy key"
install -d -m 0700 /root/.ssh
printf '%s' '__DEPLOY_KEY_B64__' | base64 -d >/root/.ssh/vw_deploy
chmod 600 /root/.ssh/vw_deploy
export GIT_SSH_COMMAND='ssh -i /root/.ssh/vw_deploy -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new'

say "cloning the repository"
git clone --depth 1 --branch '__BRANCH__' \
	git@github.com:criccomini/vectorwake.git /opt/vectorwake \
	|| die "clone; is the deploy key on the repository?"

say "writing the environment"
install -m 0600 /dev/null /opt/vectorwake/deploy/.env || die "cannot write .env"
cat >/opt/vectorwake/deploy/.env <<EOF
VW_DOMAIN=vectorwake.net
VW_REGION=ewr
VW_DEPLOY_LOG=$LOG
VW_POOL_TOKEN=__POOL_TOKEN__
VW_ADMIN_TOKEN=__ADMIN_TOKEN__
EOF

# The proxy before the game, so the log stays readable across the slow part and
# port 80 answers ACME the moment DNS points here.
say "starting the proxy"
cd /opt/vectorwake/deploy || die "no deploy directory in the clone"
bootstrap_down
docker compose --env-file .env up -d caddy || die "caddy would not start"
# Started is not listening. Caddy exiting on a bad config leaves the port dead
# and, with the bootstrap server gone, the box mute -- so this is checked rather
# than assumed, and the fallback is to hand the port back to python and say so.
i=0
while [ $i -lt 20 ]; do
	curl -fsS -o /dev/null http://127.0.0.1/deploy/status 2>/dev/null && break
	i=$((i + 1))
	sleep 2
done
if [ $i -ge 20 ]; then
	say "caddy started but nothing answers on port 80; its log follows"
	docker compose --env-file .env logs --no-color caddy 2>&1 | tail -40
	die "caddy is not serving"
fi
say "proxy is answering on port 80"

say "building the server; about ten minutes on one core"
docker compose --env-file .env up -d --build || die "build; see provision.log"

say "up:"
docker compose --env-file .env ps --format '{{.Service}} {{.State}}' >>"$LOG/status"
say "certificates arrive once vectorwake.net delegates to Vultr; Caddy retries on its own"
