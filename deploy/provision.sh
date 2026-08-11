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
#   __META_DATABASE__  __META_KEY__  __ACCOUNTS__  __REGION__
#   __POOL_DIGEST__  __META_VERIFY__
#   __ROLE__  __HOST__  __FRONT__
#
# The meta-layer's are, unlike the tokens, not minted per host: the database is
# one database however many hosts read it. They arrive the same way regardless,
# because a credential that is pasted onto a box after it boots is a credential
# a rebuilt box does not have. Accounts were live and undocumented on exactly
# that footing.
#
# __POOL_DIGEST__ and __META_VERIFY__ are the public halves of the two above,
# and they are here rather than in the catalog so that both halves of an
# identity travel together. The catalog names them with `env:` and this is what
# it finds. Publishing them costs nothing: a hash cannot be run backwards and a
# verifying key cannot sign.
#
# The last three say what this host is. __ROLE__ picks which compose files it
# runs; __HOST__ is the name it serves, which is not the machine it is (a
# central host answers for play.<domain> whichever instance is underneath it);
# and __FRONT__ is that front door, which an arena host elsewhere has to dial
# to reach the directory and the meta-layer.
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
	# The arena's WebTransport door, one UDP port per arena. QUIC cannot ride
	# through Caddy the way the WebSocket does, because the session is the
	# HTTP/3 connection itself, so an arena terminates its own; a firewall
	# that silently ate UDP would look exactly like every network that does:
	# the client would fall back to the WebSocket and nobody would know.
	#
	# This is half of it. The Vultr firewall group in front of the host
	# filters the same traffic and is not configured from here, so the same
	# port has to be accepted there too. Opening one and not the other looks
	# exactly like opening neither: the arena binds its endpoint and reports
	# itself listening either way, and every client quietly takes the socket.
	# That is an evening, and it has already been spent once.
	ufw allow 9443/udp >/dev/null 2>&1
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

# Caddy's certificates go on a block volume, not on the instance disk, because
# the instance disk is the thing a reinstall takes away. That is not a
# hypothetical: six reinstalls in one day re-requested the same names six times,
# Let's Encrypt allows five a week, and the game went dark while every check
# stayed green. A volume is a separate resource -- a reinstall does not touch it,
# and it can be detached and handed to a replacement instance.
#
# Formatted only on first use. `blkid` says nothing about a raw device and names
# a filesystem on a used one, which is the whole test.
CERT_DIR=/var/lib/caddy-data
CERT_DEV=/dev/disk/by-id/virtio-__CERT_MOUNT_ID__
[ -b "$CERT_DEV" ] || CERT_DEV=/dev/vdb
say "certificate volume: $CERT_DEV"
[ -b "$CERT_DEV" ] || die "no certificate volume attached; nothing at $CERT_DEV"
if ! blkid "$CERT_DEV" >/dev/null 2>&1; then
	say "formatting the certificate volume; this is its first use"
	mkfs.ext4 -q -L vwcerts "$CERT_DEV" || die "could not format $CERT_DEV"
fi
mkdir -p "$CERT_DIR"
grep -q " $CERT_DIR " /etc/fstab \
	|| echo "$CERT_DEV $CERT_DIR ext4 defaults,nofail 0 2" >>/etc/fstab
mountpoint -q "$CERT_DIR" || mount "$CERT_DEV" "$CERT_DIR" \
	|| die "could not mount the certificate volume"

# Refusing to continue is the point. The alternative is Caddy starting on an
# empty directory on the instance disk, which works, serves fine, and quietly
# spends one of five weekly issuances every time it happens -- which is precisely
# how the certificates were lost. A hard stop here is loud, is diagnosable
# because the bootstrap server is still serving this log, and costs nothing
# scarce. One API call fixes it.
mountpoint -q "$CERT_DIR" || die "$CERT_DIR is not a mount; refusing to issue onto the instance disk"
say "certificates will persist at $CERT_DIR"

# And the same guard at runtime rather than only at first boot: Docker will not
# start unless the mount is there, so a reboot with the volume detached cannot
# hand Caddy an empty certificate store.
mkdir -p /etc/systemd/system/docker.service.d
printf '[Unit]\nRequiresMountsFor=%s\n' "$CERT_DIR" \
	>/etc/systemd/system/docker.service.d/vw-certs.conf
systemctl daemon-reload

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

# What this host runs. `all` is both shapes on one box, which is what the fleet
# is today; `central` is the front door (the directory, the meta-layer, the
# page) and `arena` is the games and their bots.
#
# COMPOSE_FILE rather than a flag on every command, because compose reads it
# out of the env file the same way it reads everything else here. That keeps
# the role in one place: nothing below and nothing in the updater has to know
# which shape this host is, and a command typed by hand on the box gets it too.
ROLE=__ROLE__
case $ROLE in
central) COMPOSE=docker-compose.caddy.yml:docker-compose.central.yml
         ROUTES=central ;;
arena)   COMPOSE=docker-compose.caddy.yml:docker-compose.arena.yml
         ROUTES=arena ;;
*)       COMPOSE=docker-compose.caddy.yml:docker-compose.central.yml:docker-compose.arena.yml
         ROUTES= ;;
esac

# An arena host reaches the directory and the meta-layer through the front
# door's public wss, since neither of them is on this box. The token travels
# over TLS, which is what the directory's refusal of credentials in the clear
# requires. On the other two roles both are on loopback, and empty here means
# the compose files' own defaults, which say exactly that.
ARENA_DIRECTORY=
ARENA_META=
if [ "$ROLE" = arena ]; then
	ARENA_DIRECTORY=wss://__FRONT__/dir
	ARENA_META=https://__FRONT__/meta
fi

say "writing the environment; this host is a $ROLE serving __HOST__"
install -m 0600 /dev/null /opt/vectorwake/deploy/.env || die "cannot write .env"
cat >/opt/vectorwake/deploy/.env <<EOF
VW_ROLE=$ROLE
COMPOSE_FILE=$COMPOSE
VW_HOST=__HOST__
VW_ROUTES=$ROUTES
VW_DIRECTORY=$ARENA_DIRECTORY
VW_META=$ARENA_META
VW_REGION=__REGION__
VW_DEPLOY_LOG=$LOG
VW_CERT_DIR=$CERT_DIR
VW_POOL_TOKEN=__POOL_TOKEN__
VW_ADMIN_TOKEN=__ADMIN_TOKEN__
VW_META_DATABASE=__META_DATABASE__
VW_META_KEY=__META_KEY__
VW_POOL_DIGEST=__POOL_DIGEST__
VW_META_VERIFY=__META_VERIFY__
VW_ACCOUNTS=__ACCOUNTS__
EOF

# A dollar in any of those values is refused rather than escaped, and it is
# worth saying why the loud option won.
#
# Compose interpolates its own env file, so a `$` inside a token starts a
# variable reference: the token is truncated there, and compose prints the rest
# of it back as `the "..." variable is not set` on every command it runs. Those
# warnings land in the updater's log, and that log is served at /deploy to
# anyone who asks. One character in a credential is therefore most of that
# credential published. This is not a hypothetical; it is what a host was doing
# once a minute for an hour.
#
# Escaping the file with `$$` looks like the tidier fix and is not verifiable
# here: compose documents that escape for compose files and not for env files,
# `config` re-escapes on output so it cannot confirm what a container receives,
# and a wrong guess corrupts every secret on the host at once, silently. A
# refusal costs an operator one rotation and cannot be wrong.
if grep -q '\$' /opt/vectorwake/deploy/.env; then
	die "a credential contains a dollar sign, which compose reads as a
	variable and prints the rest of into a world-readable log. Rotate it,
	or percent-encode it if it is inside a URL, and provision again."
fi

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
# The script itself lives in the checkout, deploy/update.sh, so a push updates
# the updater along with everything else. This unit is the one piece written
# here, and it carries no logic to go stale: it names a path.
cat >/etc/systemd/system/vw-update.service <<'SVC'
[Unit]
Description=Pull vectorwake and redeploy if main moved
[Service]
Type=oneshot
ExecStart=/opt/vectorwake/deploy/update.sh
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
#
# Asked of the name this host serves rather than a name in the file, because
# those are not the same thing on a rebuild: a replacement central host serves
# play.<domain> and cannot get a certificate for it until the record moves, so
# a hardcoded check here would report on the box being replaced.
if curl -fsS -o /dev/null --max-time 10 "https://__HOST__/health" 2>/dev/null; then
	say "provisioning finished; https is answering for __HOST__"
else
	say "provisioning finished; https not answering for __HOST__ yet. If the"
	say "record does not point here yet, that is expected: Caddy retries, and"
	say "it succeeds the moment the name resolves to this host."
fi
