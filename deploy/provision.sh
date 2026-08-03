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

# Progress goes three places: the served log, the journal, and outbound to a
# throwaway ntfy topic.
#
# The third one is not redundancy, it is the only channel that does not depend on
# this host being reachable. Two deploys were lost to exactly that: something
# dropped inbound 80 and the log explaining why was behind the port that was
# dropped. Outbound https works from anywhere, so the box can always talk even
# when nothing can talk to it. The topic is random per host and carries no
# secrets, because anyone who learns it can read it.
TOPIC=__STATUS_TOPIC__
say() {
	printf '%s  %s\n' "$(date -u +%H:%M:%SZ)" "$*" >>"$LOG/status"
	echo "=== $*"
	[ -n "$TOPIC" ] && curl -fsS --max-time 8 -d "$*" "https://ntfy.sh/$TOPIC" >/dev/null 2>&1
	return 0
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
	# The two questions asked of every failure so far, answered in the log
	# rather than needing a console: what is running, and who has the ports.
	echo "--- docker ps -a"; docker ps -a 2>&1
	echo "--- listening sockets"; ss -lntp 2>&1
	say "the full output is at /deploy/provision.log"
	# Whatever went wrong, leave something serving the reason.
	bootstrap_up
	exit 1
}

# Visibility before anything that can fail. python3 is in the base image, so
# this needs no package, no network and no repository -- which is the point,
# since the steps most likely to break are the ones that need all three. Caddy
# replaces it on the same port once there is something to reverse-proxy.
say "provisioning started"

# Before anything binds a port, make the ports reachable. Vultr's Ubuntu images
# ship ufw enabled with ssh alone permitted, which drops inbound 80 and 443 and
# looks exactly like a service that failed to start: connections time out rather
# than being refused, so there is nothing to distinguish it from a dead listener.
# Two deploys were spent on that. The state goes in the log either way.
say "host firewall before: $(ufw status 2>/dev/null | head -1 || echo 'no ufw')"
if command -v ufw >/dev/null 2>&1; then
	ufw allow 80/tcp >/dev/null 2>&1
	ufw allow 443/tcp >/dev/null 2>&1
	ufw allow 22/tcp >/dev/null 2>&1
fi
echo "--- ufw"; ufw status verbose 2>&1
echo "--- iptables INPUT"; iptables -S INPUT 2>&1

say "serving this log on port 80"
bootstrap_up

# Swap. This was here for the build: cargo linking tokio and rustls was the peak
# memory of this host's life by a wide margin, and a linker killed by the OOM
# reaper is the worst failure available on a box nobody can log into. The build
# has moved to CI, so that reason is gone and this stays for a smaller one --
# headroom on a box that is meant to shrink to 1 GB now that it holds no
# toolchain, where extracting an image layer is the largest thing left.
#
# The fstab line is guarded: written unconditionally it produces a duplicate
# entry and systemd complains about it every ten seconds forever.
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

# A credential, if the package is private. Empty placeholders mean it is public
# and no login is needed, which is the only difference between the two cases.
#
# `docker login` writes /root/.docker/config.json, which outlives reboots, so the
# updater's own pull needs nothing further. The token wants `read:packages` and
# nothing else: this box only ever reads.
REGISTRY_USER='__REGISTRY_USER__'
REGISTRY_TOKEN='__REGISTRY_TOKEN__'
if [ -n "$REGISTRY_TOKEN" ]; then
	say "logging in to ghcr"
	printf '%s' "$REGISTRY_TOKEN" \
		| docker login ghcr.io -u "$REGISTRY_USER" --password-stdin \
		|| die "ghcr login; is the token scoped read:packages?"
fi

# Pulled rather than built, which is the difference between ten minutes and one.
say "pulling the server image"
docker compose --env-file .env pull --quiet || die "pull; see provision.log"
docker compose --env-file .env up -d || die "start; see provision.log"

say "up:"
docker compose --env-file .env ps --format '{{.Service}} {{.State}}' >>"$LOG/status"

# From here on, deploying is a git push and this box pulls it. That is not a
# convenience; it is what stops the certificates being destroyed.
#
# Reinstall was the only lever available before, and a reinstall wipes the disk,
# including the volume Caddy keeps its certificates in. Six deploys in a day
# re-requested the same names six times, Let's Encrypt allows five a week, and
# three of four names ran out -- the game went dark while every check stayed
# green. A pull touches nothing but the checkout and the containers.
say "installing the updater; deploys are a git push from now on"
cat >/usr/local/bin/vw-update <<'UPD'
#!/bin/sh
# Converge on what main and the registry say. Quiet when there is nothing to do.
#
# Two things can move and both are checked, because they move for different
# reasons. The checkout carries the compose file, the Caddyfile and the client
# bundle, which are read from disk at container start. The image carries the
# binary and the catalog. A commit that only touches docs changes neither, and
# this exits without a word.
set -u
cd /opt/vectorwake || exit 0

before=$(git rev-parse HEAD)
GIT_SSH_COMMAND='ssh -i /root/.ssh/vw_deploy -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new' \
	git fetch --quiet origin main || exit 0
after=$(git rev-parse origin/main)
[ "$before" = "$after" ] || git reset --hard "$after" >/dev/null 2>&1 || exit 1

cd deploy || exit 1
LOG=/var/lib/vw-deploy/deploy/update.log
seat() { docker compose --env-file .env ps -q a1 2>/dev/null \
	| xargs -r docker inspect --format '{{.Image}}' 2>/dev/null; }

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

# Reported after the fact rather than predicted. What an arena is running is the
# only thing worth writing down, and the honest way to know is to look.
[ "$before" = "$after" ] && [ "$was" = "$now" ] && exit 0
logger -t vw-update "converged to $after, image ${now:-none}"
printf '%s  updated to %s (image %.19s)\n' "$(date -u +%H:%M:%SZ)" "$after" \
	"${now#sha256:}" >>/var/lib/vw-deploy/deploy/status
UPD
chmod +x /usr/local/bin/vw-update

cat >/etc/systemd/system/vw-update.service <<'SVC'
[Unit]
Description=Pull vectorwake and redeploy if main moved
[Service]
Type=oneshot
ExecStart=/usr/local/bin/vw-update
SVC

cat >/etc/systemd/system/vw-update.timer <<'TMR'
[Unit]
Description=Check for a new vectorwake every minute
[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
AccuracySec=15s
[Install]
WantedBy=timers.target
TMR
systemctl daemon-reload
systemctl enable --now vw-update.timer || say "WARNING: the updater timer did not start"

# Said last, and only what is true. This used to claim certificates were still
# waiting on DNS delegation, which stopped being true after the first deploy and
# read as a warning forever after.
if curl -fsS -o /dev/null --max-time 10 "https://play.vectorwake.net/health" 2>/dev/null; then
	say "provisioning finished; https is answering"
else
	say "provisioning finished; https not answering yet, Caddy retries on its own"
fi
