#!/bin/sh
# Host lifecycle, as recipes over `vultr-cli`.
#
# Deploys are a git push and need nothing here. This is for the few times a year
# a host is created, drained or destroyed, which is the part that was console
# clicking and a remembered sequence. A host is an instance, a block volume, a
# firewall group membership and a DNS record, created in that order with names
# that have to match; doing it by hand is how the Vultr firewall group stayed
# half open for a day while ufw looked right and the arena reported listening.
#
# Deliberately not Terraform, and deliberately no state file of any kind. Every
# verb reads the authority that already exists, the provider's API, and
# reconciles by looking rather than by remembering; whether a host actually
# serves is the browse list any client sees. A tfstate would be a third opinion
# about questions already answered, and keeping it truthful is a job with its
# own failure mode. The plan/apply habit of recreating resources is also aimed
# squarely at this deployment's most expensive known mistake: a reinstall costs
# one of five weekly certificates, which is why deploys stopped being reinstalls
# in the first place. See docs/architecture/scaling-plan.md.
#
#   fleet.sh render <role> <name>     the user-data, to read before you send it
#   fleet.sh new    <role> <name> [region]
#   fleet.sh scrub  <name>            remove completed bootstrap user-data
#   fleet.sh firewall                 create or complete the firewall group
#   fleet.sh db [--url]               the managed database and its connection string
#   fleet.sh db create [region]       bring one up
#   fleet.sh db destroy               take it down, which is final
#   fleet.sh point  <name> <host>     move a name onto a host: the cutover
#   fleet.sh rm     <name>            the instance and its DNS record
#   fleet.sh secrets init [region]    the bucket the fleet's secrets live in
#   fleet.sh secrets put <NAME>       store one, value from stdin
#   fleet.sh secrets ls               names and dates, never values
#   fleet.sh secrets env              export lines: eval "$(fleet.sh secrets env)"
#
# --dry-run on any of them: every call printed, none made.
#
# Roles: `all` is the single host as it runs today, both shapes on one box.
# `central` is the front door (the directory, the meta-layer, the page) and
# `arena` is the games and their bots. The role picks the compose files and the
# Caddy routes, and it decides the name the host serves: central answers for
# play.<domain> whichever machine is underneath it, an arena for its own name.
set -eu

DOMAIN=${VW_DOMAIN:-vectorwake.net}
BRANCH=${VW_BRANCH:-main}
# The instance, per role. VW_PLAN overrides all of them.
#
# 1 GB at $5, measured rather than assumed: the game processes are 70 MB
# resident and Docker, Caddy and the base system bring the box to about
# 400 MB, over the 2 GB of swap provision.sh allocates regardless. The plan's
# 1 TB of included transfer carries a dozen or so concurrent players at the
# measured 30 KB/s each, and that transfer, not compute, is what an arena
# host runs out of first.
#
# The 512 MB family looks cheaper and is a trap with three doors. The $3.50
# vc2-1c-0.5gb is IPv4 but sold in ewr and nowhere else, so it cannot live in
# this fleet's region; the $2.50 -v6 is IPv6 only, and GitHub publishes no
# AAAA for ghcr.io or github.com, so a host on it can neither pull the image
# nor run the updater's fetch; the -free one has no transfer at all. Checked
# against the public plans API, not the pricing page, which shows the $3.50
# row without mentioning where it is sold.
PLAN_ALL=${VW_PLAN_ALL:-vc2-1c-1gb}
PLAN_CENTRAL=${VW_PLAN_CENTRAL:-vc2-1c-1gb}
PLAN_ARENA=${VW_PLAN_ARENA:-vc2-1c-1gb}
OS_ID=${VW_OS_ID:-2284}          # Ubuntu 24.04 LTS x64
CERT_GB=${VW_CERT_GB:-10}
FIREWALL=${VW_FIREWALL_GROUP:-}
# Where everything goes when nobody says: hosts, the database, and the secrets
# bucket. Atlanta is a base-rate egress region and a large eastern peering
# hub, and one of the three selling object storage on the Standard tier, the
# others being New Jersey and Silicon Valley. Sydney is the one region worth
# naming out loud before choosing it, at ten times the egress of everywhere
# else.
#
# One region for all three is a choice rather than a requirement. The bucket
# is reached over HTTPS from a laptop and could live anywhere; a bucket that
# already exists in another region keeps working untouched, since every verb
# finds it by listing. The database wants to be beside the central host,
# because every account operation crosses that distance.
#
# The region reaches the host as well as the API, because an arena reports its
# own region to the directory and a browse reply repeats it. An earlier
# provision.sh hardcoded this, so a host anywhere else registered as being in
# New Jersey; now that is only true when it is.
REGION=${VW_REGION:-atl}
# The fleet's front door: the name in the catalog's meta url, in the client's
# baked directory address, and the one an arena host anywhere dials to register.
# A central host serves it; an arena host serves its own name and points here.
FRONT=${VW_FRONT:-play.$DOMAIN}
# The site in front of the game. It rides with the front door but keeps the
# bare name, while the game stays at play.<domain> for its same-origin sockets.
SITE_HOST=${VW_SITE_HOST:-$DOMAIN}
# The admin panel's name. It rides with the front: both belong to whichever
# host is central, so `point` moves the pair together.
ADMIN_HOST=${VW_ADMIN_HOST:-admin.$DOMAIN}
DRY=0
TTL=${VW_TTL:-300}
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

die() { echo "fleet: $*" >&2; exit 1; }

# Never from CI. A machine appearing as a side effect of a push is the class of
# surprise this deployment keeps paying to remove, and the token that would let
# it happen has no business in a runner.
[ -z "${CI:-}" ] || die "not from CI. Machines are created from a laptop, on purpose."

need() {
	command -v "$1" >/dev/null 2>&1 || die "$2"
}

# The engine. One static Go binary, official, and it already speaks every
# resource a host is made of, which is why none of that is written here.
vultr() {
	need vultr-cli "vultr-cli is not installed. https://github.com/vultr/vultr-cli/releases"
	[ -n "${VULTR_API_KEY:-}" ] || die "VULTR_API_KEY is not set"
	vultr-cli "$@"
}

# A call that changes something, which is the only kind a dry run withholds.
#
# Reads still happen, because they are what every decision here is made from and
# they cost nothing: a dry run that guessed at them could not tell you whether
# it would reuse the certificate volume or create one, which is the answer most
# worth having before spending an issuance.
#
# What it cannot tell you is worth saying where somebody will read it. Ids and
# addresses do not exist yet, so anything downstream of a create prints a
# placeholder and the order after that point is asserted rather than observed.
# Every flag name, positional argument and JSON key here was checked against
# vultr-cli v3.11.0's source; what has still never run is the live API, whose
# answers are the one thing reading cannot verify.
vultr_do() {
	if [ "$DRY" = 1 ]; then
		echo "would: vultr-cli $*" >&2
		return 0
	fi
	vultr "$@"
}

# --- the user-data -----------------------------------------------------------

# provision.sh and cloud-init.yml carry placeholders and no secrets, which is
# what lets them be committed. This is the only thing that fills them, and it
# writes to stdout so `render` can show an operator exactly what will be sent
# before anything is created. Everything substituted here ends up in the
# instance's user-data only for first boot. `new` waits for success and replaces
# it with an empty cloud config; `scrub` finishes that cleanup after a repaired
# provision.
# Everything an operator has to supply, checked before anything is created.
#
# Its own step because `new` allocates a volume before it renders, and a
# missing token discovered at render time is a volume nobody asked for and
# nobody will remember to delete.
check_secrets() {
	role=$1
	# The bucket first, so that on a laptop with nothing exported these checks
	# pass by looking rather than failing by forgetting. An exported value
	# still wins: the bucket fills only what is unset.
	secrets_fill "$role"

	# Then, and still before a host exists to leak from: a dollar in
	# any credential is refused here.
	#
	# These are written into the host's .env, and compose interpolates its env
	# file. A `$` starts a variable reference, so the value is truncated there
	# and compose prints the remainder back as `the "..." variable is not set`
	# on every command. Those warnings go to the updater's log, which is served
	# at /deploy over plain http to anybody. A single character in a token is
	# therefore most of that token published, once a minute, for as long as the
	# host runs.
	#
	# Refused rather than escaped on purpose. `$$` is documented as the escape
	# for compose files, not for env files; `docker compose config` re-escapes
	# on output, so it cannot tell you what a container actually received; and
	# a wrong guess rewrites every secret on the host silently. This costs one
	# rotation and cannot be wrong.
	for _n in VW_POOL_TOKEN VW_META_DATABASE VW_META_KEY \
		  VW_REGISTRY_TOKEN VW_REGISTRY_USER; do
		eval "_v=\${$_n:-}"
		case $_v in
		*'$'*) die "$_n contains a dollar sign. Compose reads it as a variable,
       truncates the value there, and prints the rest into a log this fleet
       serves publicly. Rotate it, or percent-encode it (%24) if it sits
       inside a URL." ;;
		esac
	done

	[ -n "${VW_POOL_TOKEN:-}" ] \
		|| die "VW_POOL_TOKEN is not set and the secrets bucket has no copy. It
       is the plaintext whose sha256 is the pool's token in
       catalog/catalog.toml, so an arena this host runs can register. Store
       it: fleet.sh secrets put VW_POOL_TOKEN"
	[ -n "${VW_DEPLOY_KEY:-}" ] \
		|| die "VW_DEPLOY_KEY is not set and the secrets bucket has no copy.
       Path to the read-only deploy key for this repository; the host clones
       with it and nothing else. Store the key itself:
       fleet.sh secrets put VW_DEPLOY_KEY < ~/.ssh/vw_deploy"
	[ -r "$VW_DEPLOY_KEY" ] || die "cannot read the deploy key at $VW_DEPLOY_KEY"

	# Optional, and empty is a meaning rather than an oversight: provision.sh
	# reads a blank pair as "the package is public, no login needed". A private
	# one wants a token with read:packages and nothing else, because the box
	# only ever reads.

	# The meta-layer's two, on the roles that run one. Neither is minted here
	# and that is the point: the database is one database however many hosts
	# read it, and the signing key's other half is the catalog's verifying key,
	# which is committed. Generating either per host would give this host a
	# private world nobody else can read a token from.
	#
	# A deployment with no accounts is a real configuration and has to say so,
	# because the meta-layer now refuses to start rather than serving a fleet
	# whose accounts silently do not exist.
	accounts=1
	case $role in
	all|central)
		if [ -z "${VW_META_DATABASE:-}" ]; then
			if [ "${VW_ACCOUNTS:-}" = 0 ]; then
				accounts=0
				echo "fleet: VW_ACCOUNTS=0; this host keeps no accounts" >&2
			else
				die "VW_META_DATABASE is not set and the secrets bucket has no
       copy. It is the managed database's connection string, user and password
       included, and the $role role runs the meta-layer that needs it. Store
       it (fleet.sh db --url | fleet.sh secrets put VW_META_DATABASE), or set
       VW_ACCOUNTS=0 to mean a deployment with no accounts; leaving it empty
       by accident is how a fleet comes up healthy with every pilot a guest."
			fi
		fi
		if [ "$accounts" = 1 ] && [ -z "${VW_META_KEY:-}" ]; then
			die "VW_META_KEY is not set. 64 hex from 'vectorwake-server metakey',
       whose other half is the catalog's [meta] verifying key. It pairs with
       the catalog rather than with this host, so it is not generated here."
		fi ;;
	esac

	case $role in
	all|central|arena)
		[ -f "$HERE/docker-compose.$role.yml" ] || [ "$role" = all ] || die \
			"deploy/docker-compose.$role.yml is missing from this checkout" ;;
	*) die "unknown role $role. One of: all, central, arena." ;;
	esac

}

# The name a host serves, which is not the machine it is.
#
# `play.<domain>` is in the catalog's meta url, in the client's baked directory
# address and in every arena's advertised address, so it belongs to whichever
# machine is currently the front door rather than to a machine. A central host
# takes that name and gets its certificate the moment `point` moves the record;
# until then it answers over plain http and says so in its log. An arena host
# serves its own name instead, which `new` creates a record for, so it is
# serving TLS within a minute of booting.
serves() {
	case $1 in
	arena) printf '%s.%s' "$2" "$DOMAIN" ;;
	*)     printf '%s' "$FRONT" ;;
	esac
}

render() {
	role=$1 name=$2 mount_id=${3:-} region=${4:-$REGION}

	check_secrets "$role"

	# The status topic is the outbound channel provision.sh talks over when
	# nothing can reach the box; it is random because anyone who learns it
	# can read it. Per host, so a leak names one machine.
	accounts=${accounts:-0}
	topic=vw-$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')

	# The meta-layer's two go only to a host that runs a meta-layer.
	#
	# An arena host has no such service, so these would sit in its .env and in
	# its metadata service being read by nothing, and the only thing they could
	# ever do there is widen what one compromised arena host gives away. Which
	# is the whole fleet: the database's password, and the key that signs every
	# session token, meaning any account including staff.
	#
	# They arrived on arena hosts by default rather than by decision, because
	# an operator building a central host has both exported and the substitution
	# did not care which role it was filling.
	case $role in
	arena) meta_db= meta_key= ;;
	*)     meta_db=${VW_META_DATABASE:-} meta_key=${VW_META_KEY:-} ;;
	esac

	# The public site's and panel's names go only to the host that serves them.
	# An arena host gets empty values, which compose turns into local names no
	# certificate authority sees.
	case $role in
	arena) site_host= admin_host= ;;
	*)     site_host=$SITE_HOST admin_host=$ADMIN_HOST ;;
	esac

	# The public halves, which the catalog names with `env:` rather than
	# carrying, so that minting an identity needs no commit and no image.
	#
	# Derived rather than stored, when they can be. The pool digest is the
	# sha256 of the token we already hold, so asking an operator to keep both
	# is asking them to keep two things that can disagree. The verifying key
	# cannot be derived in shell, since it is an Ed25519 public key rather than
	# a hash, so that one is kept beside its secret half and checked here.
	digest=${VW_POOL_DIGEST:-}
	if [ -z "$digest" ] && [ -n "${VW_POOL_TOKEN:-}" ]; then
		digest=sha256:$(printf '%s' "$VW_POOL_TOKEN" | sha256sum | cut -d' ' -f1)
	fi
	verify=${VW_META_VERIFY:-}
	case $role in
	arena) digest= verify= ;;
	*)
		if [ "${accounts:-0}" = 1 ] && [ -z "$verify" ]; then
			die "VW_META_VERIFY is not set and the secrets bucket has no copy.
       It is the 64 hex the second line of 'vectorwake-server metakey' prints,
       the public half of VW_META_KEY, and the catalog reads it by name rather
       than carrying it. Store it:
         fleet.sh secrets put VW_META_VERIFY"
		fi ;;
	esac

	# base64 without line breaks, which cloud-init needs and which `base64 -w0`
	# only spells that way on GNU.
	b64() { base64 < "$1" | tr -d '\n'; }

	prov=$(mktemp) || die "no temporary file"
	# The fetched deploy key too, when the bucket supplied one.
	trap 'rm -f "$prov" ${SECRET_KEY_FILE:-}' EXIT
	sed \
		-e "s|__POOL_TOKEN__|$VW_POOL_TOKEN|g" \
		-e "s|__ROLE__|$role|g" \
		-e "s|__HOST__|$(serves "$role" "$name")|g" \
		-e "s|__SITE_HOST__|$site_host|g" \
		-e "s|__ADMIN_HOST__|$admin_host|g" \
		-e "s|__FRONT__|$FRONT|g" \
		-e "s|__BRANCH__|$BRANCH|g" \
		-e "s|__STATUS_TOPIC__|$topic|g" \
		-e "s|__CERT_MOUNT_ID__|$mount_id|g" \
		-e "s|__REGISTRY_USER__|${VW_REGISTRY_USER:-}|g" \
		-e "s|__REGISTRY_TOKEN__|${VW_REGISTRY_TOKEN:-}|g" \
		-e "s|__META_DATABASE__|$meta_db|g" \
		-e "s|__META_KEY__|$meta_key|g" \
		-e "s|__POOL_DIGEST__|$digest|g" \
		-e "s|__META_VERIFY__|$verify|g" \
		-e "s|__ACCOUNTS__|$accounts|g" \
		-e "s|__REGION__|$region|g" \
		-e "s|__DEPLOY_KEY_B64__|$(b64 "$VW_DEPLOY_KEY")|g" \
		"$HERE/provision.sh" > "$prov"

	# Loud rather than silent. A placeholder that survives substitution reaches
	# the host as the literal string and fails in a way that reads like a bug in
	# provision.sh rather than a bug in this file.
	#
	# Digits in the class because __DEPLOY_KEY_B64__ has one, and without them
	# the one placeholder carrying a whole private key was the one this guard
	# could not see.
	if grep -q '__[A-Z0-9_]*__' "$prov"; then
		die "unsubstituted placeholder: $(grep -o '__[A-Z0-9_]*__' "$prov" | sort -u | tr '\n' ' ')"
	fi

	sed -e "s|__PROVISION_B64__|$(b64 "$prov")|" "$HERE/cloud-init.yml"

	# To stderr, so `render` can be piped somewhere and these still reach a
	# person. The topic is the only way to watch a host that never opens a port.
	echo "fleet: $name role=$role region=$region branch=$BRANCH" >&2
	echo "fleet: serves   $(serves "$role" "$name")" >&2
	echo "fleet: watch    https://ntfy.sh/$topic" >&2
}

# --- verbs -------------------------------------------------------------------

cmd_render() {
	[ $# -eq 2 ] || die "usage: fleet.sh render <role> <name>"
	render "$1" "$2" ""
}

cmd_new() {
	[ $# -eq 2 ] || [ $# -eq 3 ] || die "usage: fleet.sh new <role> <name> [region]"
	role=$1 name=$2 region=${3:-$REGION}
	host=$name.$DOMAIN
	need jq "jq is not installed"

	# Before a single resource exists.
	check_secrets "$role"

	# Idempotent by looking, not by remembering: the API is asked whether this
	# host exists, every time, and running `new` twice is a sentence rather than
	# a second instance.
	if vultr instance list -o json | jq -e --arg l "$host" \
		'.instances[] | select(.label == $l)' >/dev/null 2>&1; then
		die "$host already exists; vultr-cli instance list shows it"
	fi

	# A volume that exists and is attached to something else is the one case
	# this cannot resolve by looking, and guessing either way is worse than
	# stopping: creating a second would spend an issuance, and stealing one
	# would take the certificates off a running host.
	# Filtered to this region, because block storage is region-locked: a
	# volume of the right label in the wrong region cannot be attached, and
	# a stray one left by a host built somewhere else must be invisible here
	# rather than found and fumbled.
	busy=$(vultr block-storage list -o json | jq -r --arg l "$host-certs" --arg r "$region" \
		'[.blocks[] | select(.label == $l and .region == $r and (.attached_to_instance // "") != "")][0].attached_to_instance // empty')
	if [ -n "$busy" ]; then
		die "a volume labeled $host-certs is attached to $busy already.
       Detach it, or destroy that host first. Creating a second would issue a
       fresh certificate and spend one of five for this week."
	fi

	# The certificate volume, because provision.sh refuses to continue
	# without one. That refusal is the point: Caddy starting on an empty
	# directory on the instance disk works, serves fine, and quietly spends one
	# of five weekly issuances every time it happens, which is precisely how
	# the certificates were lost.
	#
	# Reused when this name has had a host before, and this is the whole reason
	# `rm` leaves it behind. Let's Encrypt allows five certificates a week for
	# the same name; a host destroyed and recreated four times in an afternoon
	# is a name that cannot be served until the week turns, and creating a
	# second empty volume per attempt is exactly how to spend them. A volume
	# carried across brings a certificate that is still valid, so the
	# replacement issues nothing at all.
	vol=$(vultr block-storage list -o json | jq -r --arg l "$host-certs" --arg r "$region" \
		'[.blocks[] | select(.label == $l and .region == $r and (.attached_to_instance // "") == "")][0].id // empty')
	if [ -n "$vol" ]; then
		echo "fleet: reusing the certificate volume $host has had before ($vol)"
		echo "fleet: its certificates carry over, so this host issues none"
	else
		echo "fleet: creating the certificate volume"
		vol=$(vultr_do block-storage create --region "$region" --size "$CERT_GB" \
			--label "$host-certs" -o json | jq -r '.block.id' 2>/dev/null || true)
		if [ "$DRY" = 1 ]; then vol="<new-volume>"; fi
		if [ -z "$vol" ] || [ "$vol" = null ]; then die "no volume id came back"; fi
	fi


	# Vultr presents an attached volume at /dev/disk/by-id/virtio-<first 20 of
	# its id>. provision.sh falls back to /dev/vdb, so this is a nicety rather
	# than load bearing, and it is what makes the device name in the log
	# traceable to a resource in the console.
	mount_id=$(printf '%s' "$vol" | tr -d - | cut -c1-20)

	userdata=$(mktemp) || die "no temporary file"
	render "$role" "$name" "$mount_id" "$region" > "$userdata"

	echo "fleet: creating $host in $region"
	case $role in
	central) plan=$PLAN_CENTRAL ;;
	arena)   plan=$PLAN_ARENA ;;
	*)       plan=$PLAN_ALL ;;
	esac
	plan=${VW_PLAN:-$plan}
	echo "fleet: plan $plan"
	# By file rather than argv: the user-data carries every secret the host
	# gets, and an argument is readable in ps for as long as the call runs. The
	# CLI base64-encodes it either way.
	set -- --region "$region" --plan "$plan" --os "$OS_ID" \
		--host "$host" --label "$host" --userdata-file "$userdata"
	# The firewall group is not optional in any sense that matters. ufw and the
	# Vultr group both filter, both have to be open, and an instance outside the
	# group looks exactly like an instance inside a closed one: the arena binds,
	# reports listening, and nothing arrives.
	# Looked up by label when nobody named an id, because the group is a
	# property of the deployment rather than something an operator should be
	# carrying in their shell. A host outside it looks exactly like a host
	# inside a shut one.
	if [ -z "$FIREWALL" ]; then
		FIREWALL=$(vultr firewall group list -o json | jq -r --arg d "$FW_LABEL" \
			'[.firewall_groups[] | select(.description == $d)][0].id // empty')
	fi
	if [ -n "$FIREWALL" ]; then
		set -- "$@" --firewall-group "$FIREWALL"
	else
		die "no firewall group $FW_LABEL, and VW_FIREWALL_GROUP is unset.
       Run: fleet.sh firewall
       A host outside the group binds, reports listening, and receives nothing,
       which is indistinguishable from a host inside a shut one."
	fi
	id=$(vultr_do instance create "$@" -o json | jq -r '.instance.id' 2>/dev/null || true)
	rm -f "$userdata"
	if [ "$DRY" = 1 ]; then id="<new-instance>"; fi
	if [ -z "$id" ] || [ "$id" = null ]; then die "no instance id came back"; fi

	# A fresh instance refuses the attach twice over, in words learned one
	# each from the first two hosts this file built: "Server must be in an
	# active state" until its status flips, and "Server is currently locked"
	# for a window after that while Vultr finishes its own provisioning. The
	# status is pollable; the lock is not usefully, so the attach itself is
	# the probe, retried while the API names either gate and stopped cold on
	# any other refusal.
	#
	# The race with provision.sh runs opposite to how it reads. The host looks
	# for the volume a minute or more into first boot, after the firewall, the
	# swap and a docker install, and both gates clear well inside that. When
	# they do not, the failure is loud, is readable in the served log, and is
	# fixed by attaching and re-running provision on the box.
	echo "fleet: waiting for the instance to come active"
	st=""
	ip=""
	n=0
	if [ "$DRY" = 1 ]; then st=active ip="<new-ip>"; fi
	while [ "$st" != active ] && [ $n -lt 60 ]; do
		st=$(vultr instance get "$id" -o json | jq -r '.instance.status // empty')
		[ "$st" = active ] || { sleep 5; n=$((n + 1)); }
	done
	[ "$st" = active ] || die "the instance never came active, so the volume is
       not attached. When it does: vultr-cli block-storage attach $vol
       --instance $id, then re-run provision on the box."

	echo "fleet: attaching the certificate volume"
	if [ "$DRY" = 1 ]; then
		vultr_do block-storage attach "$vol" --instance "$id" >/dev/null
	else
		n=0
		until err=$(vultr block-storage attach "$vol" --instance "$id" 2>&1); do
			case $err in
			*"active state"*|*"currently locked"*)
				[ $n -eq 0 ] && echo "fleet: the server is not ready to take it; retrying"
				n=$((n + 1))
				[ $n -lt 30 ] || die "the volume would not attach after five minutes:
       $err
       When the server settles: vultr-cli block-storage attach $vol --instance $id"
				sleep 10 ;;
			*) die "could not attach the volume: $err" ;;
			esac
		done
	fi

	n=0
	while [ -z "$ip" ] && [ $n -lt 60 ]; do
		ip=$(vultr instance get "$id" -o json | jq -r '.instance.main_ip')
		if [ "$ip" = "0.0.0.0" ] || [ "$ip" = null ]; then ip=""; fi
		if [ -z "$ip" ]; then sleep 5; n=$((n + 1)); fi
	done
	[ -n "$ip" ] || die "the instance never reported an address"

	# DNS last, and pointed at an address that exists. A name that resolves
	# before the host answers is a certificate issued against a box that cannot
	# complete the challenge, which spends an issuance to learn nothing.
	echo "fleet: pointing $host at $ip"
	vultr_do dns record create "$DOMAIN" --type A --name "$name" \
		--data "$ip" --ttl "$TTL" >/dev/null

	echo "fleet: $host is $id at $ip"
	# The plain-http URL by IP, because the https one is role-dependent and was
	# once printed wrong: a central host serves the front door's name and never
	# gets a certificate for its own, so its machine name is http forever.
	echo "fleet: watch  http://$ip/deploy/status  (http: no certificate exists yet)"
	case $role in
	arena) echo "fleet: then   https://$host/deploy/status  once its certificate lands" ;;
	*)     echo "fleet: then   https://$FRONT/deploy/status  after: fleet.sh point ${FRONT%%.*} $name"
	       echo "fleet:        ($host itself stays http; a central host serves $FRONT, not its own name)" ;;
	esac

	if [ "$DRY" = 1 ]; then
		scrub_user_data "$id"
		return
	fi
	echo "fleet: waiting for provisioning to finish before removing bootstrap user-data"
	n=0
	until curl -fsS --max-time 5 "http://$ip/deploy/status" 2>/dev/null \
		| grep -q 'provisioning finished'; do
		n=$((n + 1))
		[ $n -lt 120 ] || die "provisioning did not finish within twenty minutes.
       The user-data is still present so the host can recover. After the status
       says provisioning finished, run: fleet.sh scrub $name"
		sleep 10
	done
	scrub_user_data "$id"
}

scrub_user_data() {
	su_id=$1
	su_stub=$(mktemp) || die "no temporary file for empty user-data"
	printf '#cloud-config\n' >"$su_stub"
	vultr_do instance user-data set "$su_id" --userdata "$su_stub" >/dev/null \
		|| { rm -f "$su_stub"; die "could not replace instance user-data"; }
	rm -f "$su_stub"
	echo "fleet: bootstrap user-data removed from $su_id"
}

cmd_scrub() {
	[ $# -eq 1 ] || die "usage: fleet.sh scrub <name>"
	name=$1
	host=$name.$DOMAIN
	need jq "jq is not installed"
	row=$(vultr instance list -o json | jq -c --arg l "$host" \
		'.instances[] | select(.label == $l)')
	[ -n "$row" ] || die "no instance labeled $host"
	id=$(printf '%s' "$row" | jq -r '.id')
	ip=$(printf '%s' "$row" | jq -r '.main_ip')
	if [ "$DRY" != 1 ] && ! curl -fsS --max-time 5 "http://$ip/deploy/status" 2>/dev/null \
		| grep -q 'provisioning finished'; then
		die "$host has not reported provisioning finished. Its bootstrap data is
       still needed if cloud-init has to resume."
	fi
	scrub_user_data "$id"
}

# Create or move one A record, quietly when it already points there. For the
# names that ride along with a cutover, after the cutover's own question has
# been asked and answered. Prefixed variables, because POSIX sh has no locals
# and the caller's are in use.
converge_record() {
	cr_name=$1 cr_ip=$2
	case $cr_name in
	@) cr_display=$DOMAIN ;;
	*) cr_display=$cr_name.$DOMAIN ;;
	esac
	cr_rec=$(vultr dns record list "$DOMAIN" -o json | jq -r --arg n "$cr_name" \
		'[.records[] | select(.name == $n and .type == "A")][0] // empty')
	cr_rid=$(printf '%s' "$cr_rec" | jq -r '.id // empty')
	cr_old=$(printf '%s' "$cr_rec" | jq -r '.data // empty')
	if [ -z "$cr_rid" ]; then
		vultr_do dns record create "$DOMAIN" --type A --name "$cr_name" \
			--data "$cr_ip" --ttl "$TTL" >/dev/null
		echo "fleet: $cr_display -> $cr_ip (created)"
	elif [ "$cr_old" != "$cr_ip" ]; then
		vultr_do dns record update "$DOMAIN" "$cr_rid" --data "$cr_ip" --ttl "$TTL" >/dev/null
		echo "fleet: $cr_display -> $cr_ip (moved from $cr_old)"
	fi
}

# The names that follow the front door wherever it points. The bare site and
# admin.<domain> belong to whichever host is central, so a cutover that moved
# only play.<domain> would strand both on the old box. Runs on every exit of
# cmd_point, including "already points there", which creates a missing record
# without adding another command.
ride_along() {
	if [ "$name.$DOMAIN" = "$FRONT" ]; then
		converge_record "@" "$1"
		converge_record "${ADMIN_HOST%%.*}" "$1"
	fi
}

# Move a name onto a host. This is the cutover, and it is the whole of it.
#
# `new` creates a record for the host it is creating and nothing else, which is
# deliberate: a fleet whose names and hosts are one to one needs nothing more.
# A rebuild is the case that does, because the name has to outlive the machine.
# `play.vectorwake.net` is in the catalog's meta url, in the client's baked
# directory address and in every arena's advertised address, so the name stays
# and the address under it moves.
#
# Updated rather than deleted and recreated. A record that briefly does not
# exist is a name that briefly does not resolve, and resolvers cache absence.
cmd_point() {
	[ $# -eq 2 ] || die "usage: fleet.sh point <name> <host>    e.g. point play ord1"
	name=$1 target=$2
	need jq "jq is not installed"

	ip=$(vultr instance list -o json | jq -r --arg l "$target.$DOMAIN" \
		'.instances[] | select(.label == $l) | .main_ip')
	[ -n "$ip" ] || die "no instance labeled $target.$DOMAIN"
	[ "$ip" != "0.0.0.0" ] || die "$target.$DOMAIN has no address yet"

	rec=$(vultr dns record list "$DOMAIN" -o json | jq -r --arg n "$name" \
		'[.records[] | select(.name == $n and .type == "A")][0] // empty')
	old=$(printf '%s' "$rec" | jq -r '.data // empty')
	rid=$(printf '%s' "$rec" | jq -r '.id // empty')
	oldttl=$(printf '%s' "$rec" | jq -r '.ttl // empty')

	if [ -z "$rid" ]; then
		echo "fleet: $name.$DOMAIN does not exist yet; creating it at $ip"
		vultr_do dns record create "$DOMAIN" --type A --name "$name" \
			--data "$ip" --ttl "$TTL" >/dev/null
		echo "fleet: $name.$DOMAIN -> $ip"
		ride_along "$ip"
		return 0
	fi

	if [ "$old" = "$ip" ]; then
		echo "fleet: $name.$DOMAIN already points at $ip"
		ride_along "$ip"
		return 0
	fi

	# The old TTL is the outage, not the new one: resolvers hold what they were
	# last told for as long as they were told to. Lowering it takes one old TTL
	# to take effect, so it is worth doing well before a cutover rather than as
	# part of one.
	if [ -n "$oldttl" ] && [ "$oldttl" -gt "$TTL" ] 2>/dev/null; then
		echo "fleet: the record's TTL is ${oldttl}s, so resolvers may hold the old"
		echo "       address that long after this. Lower it and wait one TTL if"
		echo "       the window matters."
	fi

	printf 'fleet: move %s.%s from %s to %s (%s)? [y/N] ' \
		"$name" "$DOMAIN" "$old" "$ip" "$target"
	read -r yes
	[ "$yes" = y ] || die "nothing done"

	vultr_do dns record update "$DOMAIN" "$rid" --data "$ip" --ttl "$TTL" >/dev/null
	echo "fleet: $name.$DOMAIN -> $ip"
	ride_along "$ip"
	# Said because it is the expensive part and it happens without being asked.
	# The host has been trying and failing to get this certificate for as long
	# as it has existed; the moment the name resolves here, it succeeds.
	echo "fleet: that host now issues the certificate for $name.$DOMAIN,"
	echo "       which is one of five for this name this week."
}

# --- the firewall group ------------------------------------------------------

# What has to be open, and nothing else. Two of these were learned the hard way
# and both are recorded where they were paid for: 22, 80 and 443 in
# provision.sh, and the WebTransport port in the Vultr group, which is a
# separate filter from ufw and looks exactly like ufw when it is the one that is
# shut. An arena binds, reports listening, and nothing arrives.
#
# One UDP port because one arena. A second one in docker-compose.arena.yml
# wants 9444 added here and in provision.sh; this verb only adds what is
# missing, so re-running it after the edit is the whole of the change.
FW_RULES="tcp:22 tcp:80 tcp:443 udp:9443"
FW_LABEL=${VW_FIREWALL_LABEL:-vectorwake}

# The group, created if it is not there and completed if it is half done.
#
# Idempotent by looking, like everything else here: the rules that exist are
# read back and only the missing ones are added, so running this after adding a
# port to the list is how the port gets added everywhere.
cmd_firewall() {
	need jq "jq is not installed"
	gid=$(vultr firewall group list -o json | jq -r --arg d "$FW_LABEL" \
		'[.firewall_groups[] | select(.description == $d)][0].id // empty')
	if [ -z "$gid" ]; then
		echo "fleet: creating the firewall group $FW_LABEL"
		gid=$(vultr_do firewall group create --description "$FW_LABEL" -o json \
			| jq -r '.firewall_group.id' 2>/dev/null || true)
		if [ "$DRY" = 1 ]; then gid="<new-group>"; fi
		[ -n "$gid" ] || die "no firewall group id came back"
	else
		echo "fleet: firewall group $FW_LABEL is $gid"
	fi

	have=$(vultr firewall rule list "$gid" -o json 2>/dev/null \
		| jq -r '.firewall_rules[] | "\(.protocol):\(.port)"' 2>/dev/null || true)
	for r in $FW_RULES; do
		proto=${r%%:*}
		port=${r#*:}
		# Vultr reports a range as "9443:9445" and a single port as "22", which
		# is the same shape this list is written in, so the comparison is direct.
		if printf '%s\n' "$have" | grep -qx "$proto:$port"; then
			echo "  ok      $proto $port"
		else
			echo "  adding  $proto $port"
			# "Anywhere" is spelled subnet 0.0.0.0 with a zero-bit mask. The CLI's
			# --source is a different thing (empty, or the word cloudflare) and
			# is left alone.
			vultr_do firewall rule create "$gid" --protocol "$proto" \
				--ip-type v4 --subnet 0.0.0.0 --size 0 --port "$port" >/dev/null
		fi
	done
	echo "fleet: VW_FIREWALL_GROUP=$gid"
	# Printed rather than remembered. `new` looks the group up by the same
	# label, so nobody has to carry this id around; it is here for a shell that
	# wants to export it.
}

# --- the database ------------------------------------------------------------

# The managed Postgres, which is the one resource in this deployment whose loss
# cannot be repaired by rebuilding. It belongs here for the same reason the rest
# does: a rebuild in a new region is a database as well as hosts, and the step
# that was left to the console is the step that gets done wrong at midnight.
#
# What is different about it is the cost of a mistake, so the verbs are shaped
# around that rather than around convenience. Bare `db` inspects and creates
# nothing, since the common use is reading the connection string; `db create`
# names the plan and the monthly bill before it asks; and `db destroy` wants the
# label typed out, because it is the only thing in this file that a rebuild
# cannot put back.
DB_LABEL=${VW_DB_LABEL:-vectorwake}
# The engine and the size. Overridable because these are the flags most likely
# to have drifted in vultr-cli, and a wrong one should be fixable from a shell
# rather than by editing this file.
DB_ENGINE=${VW_DB_ENGINE:-pg}
DB_VERSION=${VW_DB_VERSION:-16}
DB_PLAN=${VW_DB_PLAN:-vultr-dbaas-startup-cc-1-55-2}

# The database this deployment reads, by label.
db_row() {
	vultr database list -o json | jq -r --arg l "$DB_LABEL" \
		'[.databases[] | select(.label == $l)][0] // empty'
}

# The string the meta-layer wants, assembled rather than stored anywhere.
# `sslmode=require` is not decoration: Vultr signs each project's databases with
# its own CA, and without it the connection goes out in the clear and the
# meta-layer refuses to talk to it at all. The CA itself is committed at
# deploy/db-ca.pem and is not a secret.
db_url() {
	printf '%s' "$1" | jq -r '
		"postgres://\(.user):\(.password)@\(.host):\(.port)/\(.dbname)?sslmode=require"'
}

cmd_db() {
	need jq "jq is not installed"
	case ${1:-show} in
	create)  shift; db_create "$@" ;;
	destroy) shift; db_destroy "$@" ;;
	--url)   db_show --url ;;
	show)    db_show ;;
	*)       die "usage: fleet.sh db [show|--url|create [region]|destroy]" ;;
	esac
}

db_show() {
	db=$(db_row)
	if [ -z "$db" ]; then
		echo "fleet: no managed database labeled $DB_LABEL" >&2
		echo "       fleet.sh db create [region]" >&2
		return 1
	fi
	head=$(printf '%s' "$db" | jq -r '"fleet: \(.label)  \(.status)  \(.region)  \(.plan)"')
	url=$(db_url "$db")
	case $url in
	*null*) echo "$head" >&2
	        echo "fleet: the API returned no credentials for $DB_LABEL yet." >&2
	        echo "       A database still building has none; try again when it is" >&2
	        echo "       Running." >&2
	        return 1 ;;
	esac
	# Under --url the connection string is the output and the rest is commentary,
	# so the commentary goes to stderr. `VW_META_DATABASE=$(fleet.sh db --url)`
	# has to capture one line, and it captures whatever stdout holds.
	if [ "${1:-}" = --url ]; then
		echo "$head" >&2
		printf '%s\n' "$url"
	else
		echo "$head"
		echo "fleet: export VW_META_DATABASE='$url'"
	fi
}

# Bring one up.
#
# In the same region as the central host by default, because every account
# operation crosses that distance and the target shape in hosting.md puts them
# together. It costs by the month from the moment it exists, so it says the
# plan and asks.
db_create() {
	region=${1:-$REGION}
	if [ -n "$(db_row)" ]; then
		echo "fleet: a database labeled $DB_LABEL already exists:"
		# Tolerated failing, because one still building has no credentials to
		# print and that is not an error here: the answer to `create` is that
		# there is nothing to create.
		db_show || true
		return 0
	fi
	printf 'fleet: create %s in %s, %s %s on %s? It bills monthly. [y/N] ' \
		"$DB_LABEL" "$region" "$DB_ENGINE" "$DB_VERSION" "$DB_PLAN"
	read -r yes
	[ "$yes" = y ] || die "nothing done"

	vultr_do database create --database-engine "$DB_ENGINE" \
		--database-engine-version "$DB_VERSION" --region "$region" \
		--plan "$DB_PLAN" --label "$DB_LABEL" >/dev/null
	if [ "$DRY" = 1 ]; then return 0; fi

	# Minutes, not seconds, and its credentials do not exist until it is up.
	echo "fleet: waiting for it to come up"
	n=0
	while [ $n -lt 120 ]; do
		st=$(db_row | jq -r '.status // empty')
		[ "$st" = Running ] && break
		sleep 10
		n=$((n + 1))
	done
	db_show || die "it did not come up in twenty minutes; look in the console"
	echo "fleet: the catalog's [meta] url is a separate thing and does not move"
	echo "       with this. Only VW_META_DATABASE does."
}

# Take one down. This is the most irreversible thing in this file.
#
# Every other verb here destroys something a rebuild replaces: a host is
# disposable, a volume holds certificates that reissue, a DNS record is one
# call. This holds every account, every rating and the whole rated history, and
# nothing in this repository is a copy of it. So it asks for the label to be
# typed rather than for a keystroke, and says what is inside first.
db_destroy() {
	db=$(db_row)
	[ -n "$db" ] || die "no managed database labeled $DB_LABEL"
	id=$(printf '%s' "$db" | jq -r '.id')
	printf '%s' "$db" | jq -r '"fleet: \(.label)  \(.status)  \(.region)  \(.plan)"'
	cat >&2 <<WARN
fleet: this holds every account, every rating and the rated event log.
       Nothing in this repository is a copy of it and no other verb here
       is this final. Confirm the managed database's automatic backup status
       in Vultr before continuing.
WARN
	printf 'fleet: type the label %s to destroy it: ' "$DB_LABEL"
	read -r typed
	[ "$typed" = "$DB_LABEL" ] || die "nothing done"
	vultr_do database delete "$id" >/dev/null
	if [ "$DRY" = 1 ]; then return 0; fi
	echo "fleet: $DB_LABEL is gone. Any host still holding its connection string"
	echo "       will refuse to start, which is the meta-layer working correctly."
}

# --- the secrets -------------------------------------------------------------

# Where the fleet's identity lives: one bucket, in Vultr object storage,
# reachable from the API key alone. The raw pool token and the meta signing key
# used to exist in exactly one place, the .env of a host built to be destroyed,
# and every rebuild began by remembering to rescue them.
#
# The hosts never see this bucket. Vultr object storage has one credential pair
# per subscription and no way to scope it, so a host that could pull anything
# would hold a credential that pulls everything, and an arena host must not be
# one curl away from the meta key. fleet.sh reads the bucket at render time and
# bakes into each host's user-data exactly what its role needs, which is the
# same delivery every host already gets.
#
# vultr-cli manages the subscription but does not speak S3, so the objects
# themselves go through `aws` pointed at the Vultr endpoint. The credentials
# come back from `object-storage list`, which is what makes VULTR_API_KEY the
# only thing an operator has to hold.
OS_LABEL=${VW_SECRETS_LABEL:-vectorwake-secrets}
# Bucket names share a namespace per cluster with every other customer, so a
# taken name is possible and this is the way out. The default is deliberately
# not the subscription's label: the first bucket was created under that name,
# the subscription holding it was destroyed in a rebuild, and Vultr frees a
# dead subscription's names on its own schedule, so the old default may be
# haunted for as long as that takes. This name only decides what init creates;
# every other verb discovers the bucket by listing.
BUCKET=${VW_SECRETS_BUCKET:-vw-secrets}

os_row() {
	vultr object-storage list -o json | jq -r --arg l "$OS_LABEL" \
		'[.object_storages[] | select(.label == $l)][0] // empty'
}

# The S3 side of a subscription row: endpoint, credentials, and the region
# string sigv4 wants, which is the cluster's own name off the front of its
# hostname (ewr1.vultrobjects.com signs as ewr1).
s3_env() {
	S3_HOST=$(printf '%s' "$1" | jq -r '.s3_hostname')
	S3_KEY=$(printf '%s' "$1" | jq -r '.s3_access_key')
	S3_SECRET=$(printf '%s' "$1" | jq -r '.s3_secret_key')
	S3_REGION=${S3_HOST%%.*}
}

s3() {
	need aws "the secrets bucket needs the aws CLI. https://aws.amazon.com/cli/"
	AWS_ACCESS_KEY_ID=$S3_KEY AWS_SECRET_ACCESS_KEY=$S3_SECRET \
	AWS_EC2_METADATA_DISABLED=true \
	aws --endpoint-url "https://$S3_HOST" --region "$S3_REGION" \
		--output json s3api "$@"
}

s3_do() {
	if [ "$DRY" = 1 ]; then
		echo "would: aws s3api $*" >&2
		return 0
	fi
	s3 "$@"
}

# Which bucket in the subscription is the fleet's. The name only matters at
# creation: ever after it is discovered by listing, because the subscription
# holds exactly one bucket and the name is the part that can be lost. A
# destroyed subscription keeps its bucket names until Vultr's cleanup runs, so
# a rebuild can find the default taken by its own ghost; picking another name
# at init is then a one-time choice rather than an environment variable every
# later command has to remember.
find_bucket() {
	if [ -n "${VW_SECRETS_BUCKET:-}" ]; then
		BUCKET=$VW_SECRETS_BUCKET
		return 0
	fi
	fb=$(s3 list-buckets 2>/dev/null | jq -r '.Buckets[]?.Name' || true)
	fb_n=$(printf '%s' "$fb" | grep -c . || true)
	case $fb_n in
	0) ;;
	1) BUCKET=$fb ;;
	*) die "the $OS_LABEL subscription holds several buckets:
$(printf '%s\n' "$fb" | sed 's/^/         /')
       VW_SECRETS_BUCKET says which one is the fleet's." ;;
	esac
}

# One object to stdout. The value arrives byte for byte in a file, and only
# string callers pass through a substitution that eats trailing newlines; the
# deploy key is moved as a file so it never does.
s3_get() {
	sg_t=$(mktemp) || return 1
	if s3 get-object --bucket "$BUCKET" --key "$1" "$sg_t" >/dev/null 2>&1; then
		cat "$sg_t"; rm -f "$sg_t"
	else
		rm -f "$sg_t"; return 1
	fi
}

# Fill what is unset from the bucket, before the checks that would die on it.
# Exported values win; the bucket is the fallback, not an authority over the
# shell. Quiet when there is nothing to do, and quiet when there is no API key
# or no bucket, because then the old checks say what is missing and how.
secrets_fill() {
	sf_role=$1
	sf_need=0
	[ -n "${VW_POOL_TOKEN:-}" ] && [ -n "${VW_DEPLOY_KEY:-}" ] || sf_need=1
	case $sf_role in
	all|central)
		if [ "${VW_ACCOUNTS:-}" != 0 ]; then
			[ -n "${VW_META_DATABASE:-}" ] && [ -n "${VW_META_KEY:-}" ] \
				&& [ -n "${VW_META_VERIFY:-}" ] || sf_need=1
		fi ;;
	esac
	[ "$sf_need" = 1 ] || return 0
	[ -n "${VULTR_API_KEY:-}" ] || return 0
	command -v vultr-cli >/dev/null 2>&1 || return 0
	need jq "jq is not installed"
	sf_row=$(os_row)
	[ -n "$sf_row" ] || return 0
	s3_env "$sf_row"
	find_bucket
	echo "fleet: filling missing secrets from the $OS_LABEL bucket" >&2
	[ -n "${VW_POOL_TOKEN:-}" ]    || VW_POOL_TOKEN=$(s3_get VW_POOL_TOKEN || true)
	[ -n "${VW_META_DATABASE:-}" ] || VW_META_DATABASE=$(s3_get VW_META_DATABASE || true)
	[ -n "${VW_META_KEY:-}" ]      || VW_META_KEY=$(s3_get VW_META_KEY || true)
	[ -n "${VW_META_VERIFY:-}" ]   || VW_META_VERIFY=$(s3_get VW_META_VERIFY || true)
	if [ -z "${VW_DEPLOY_KEY:-}" ]; then
		# The bucket holds the key material; the interface wants a path. A
		# 0600 temporary file bridges them, and render's exit trap removes it.
		SECRET_KEY_FILE=$(mktemp) || die "no temporary file"
		chmod 600 "$SECRET_KEY_FILE"
		if s3 get-object --bucket "$BUCKET" --key VW_DEPLOY_KEY \
			"$SECRET_KEY_FILE" >/dev/null 2>&1; then
			VW_DEPLOY_KEY=$SECRET_KEY_FILE
		else
			rm -f "$SECRET_KEY_FILE"; SECRET_KEY_FILE=
		fi
	fi
}

cmd_secrets() {
	need jq "jq is not installed"
	case ${1:-ls} in
	init) shift; secrets_init "$@" ;;
	put)  shift; secrets_put "$@" ;;
	ls)   secrets_ls ;;
	env)  secrets_env ;;
	*)    die "usage: fleet.sh secrets [init [region]|put <NAME>|ls|env]" ;;
	esac
}

# The subscription and the bucket, created if absent and reported if not,
# which is the idempotence every other verb here has.
secrets_init() {
	region=${1:-$REGION}
	row=$(os_row)
	if [ -n "$row" ]; then
		printf '%s' "$row" | jq -r '"fleet: \(.label)  \(.status)  \(.region)"'
	else
		clusters=$(vultr object-storage cluster list -o json)
		ids=$(printf '%s' "$clusters" | jq -r --arg r "$region" \
			'.clusters[] | select(.region == $r) | .id')
		# Refused rather than guessed. Object storage clusters exist in a few
		# regions only, and a bucket quietly created on another continent is a
		# surprise with a monthly bill; the operator picks, knowing the list.
		[ -n "$ids" ] || die "no object storage cluster in $region. There are:
$(printf '%s' "$clusters" | jq -r '.clusters[] | "         \(.region)  (\(.hostname))"')
       Run: fleet.sh secrets init <region>"

		# Every tier of every cluster in the region, because a region can have
		# more than one and they do not sell the same menu. Atlanta has two,
		# and taking the first of them silently is how this offered a $50 tier
		# in a region that also sells a cheaper one. The whole menu is printed
		# for the same reason the region list above is: a bill nobody chose is
		# the failure this verb exists to prevent.
		#
		# The bucket holds five objects totaling under a kilobyte, so every
		# tier is overqualified and the difference is entirely the bill.
		menu=$(mktemp) || die "no temporary file"
		for c in $ids; do
			h=$(printf '%s' "$clusters" | jq -r --argjson c "$c" \
				'.clusters[] | select(.id == $c).hostname')
			vultr object-storage cluster tiers --cluster-id "$c" -o json \
				| jq -c --argjson c "$c" --arg h "$h" \
					'[.tiers[] | {cluster: $c, host: $h, tier: .id,
					              name: .sales_name, price: .price}]' >>"$menu"
		done
		tiers=$(jq -s -c 'add // [] | sort_by(.price)' <"$menu")
		rm -f "$menu"
		[ "$(printf '%s' "$tiers" | jq 'length')" -gt 0 ] \
			|| die "no tier came back for any cluster in $region"
		printf '%s' "$tiers" | jq -r \
			'.[] | "  \(.host)  tier \(.tier)  \(.name)  $\(.price)/mo"'

		pick=$tiers
		if [ -n "${VW_OS_CLUSTER_ID:-}" ]; then
			pick=$(printf '%s' "$pick" | jq -c --argjson c "$VW_OS_CLUSTER_ID" \
				'map(select(.cluster == $c))')
			[ "$(printf '%s' "$pick" | jq 'length')" -gt 0 ] \
				|| die "$region has no cluster $VW_OS_CLUSTER_ID; the hosts are above"
		fi
		if [ -n "${VW_OS_TIER_ID:-}" ]; then
			pick=$(printf '%s' "$pick" | jq -c --argjson t "$VW_OS_TIER_ID" \
				'map(select(.tier == $t))')
			[ "$(printf '%s' "$pick" | jq 'length')" -gt 0 ] \
				|| die "nothing in $region sells tier $VW_OS_TIER_ID; the ids are above"
		fi
		tier=$(printf '%s' "$pick" | jq -c '.[0]')
		cid=$(printf '%s' "$tier" | jq -r '.cluster')
		chost=$(printf '%s' "$tier" | jq -r '.host')
		tid=$(printf '%s' "$tier" | jq -r '.tier')
		# Said out loud when there was a choice, because the cheapest of an
		# expensive menu is still expensive.
		if [ "$(printf '%s' "$tiers" | jq 'length')" -gt 1 ] \
			&& [ -z "${VW_OS_TIER_ID:-}${VW_OS_CLUSTER_ID:-}" ]; then
			echo "fleet: taking the cheapest; VW_OS_CLUSTER_ID and VW_OS_TIER_ID pick another"
		fi
		printf 'fleet: create %s on %s, tier %s at $%s/mo? It bills monthly. [y/N] ' \
			"$OS_LABEL" "$chost" \
			"$(printf '%s' "$tier" | jq -r '.name')" \
			"$(printf '%s' "$tier" | jq -r '.price')"
		read -r yes
		[ "$yes" = y ] || die "nothing done"
		vultr_do object-storage create --cluster-id "$cid" --tier-id "$tid" \
			--label "$OS_LABEL" >/dev/null
		if [ "$DRY" = 1 ]; then
			echo "would: aws s3api create-bucket --bucket $BUCKET" >&2
			return 0
		fi
		echo "fleet: waiting for it to come up"
		n=0
		while [ $n -lt 60 ]; do
			st=$(os_row | jq -r '.status // empty')
			[ "$st" = active ] && break
			sleep 5
			n=$((n + 1))
		done
		row=$(os_row)
		[ "$(printf '%s' "$row" | jq -r '.status')" = active ] \
			|| die "it did not come up in five minutes; look in the console"
	fi
	s3_env "$row"
	find_bucket
	# Looking before creating is a race, and on a subscription that became
	# active seconds ago it is a race that loses: the head can miss a bucket
	# the create then finds, either because the CLI retried a create whose
	# reply was lost or because the endpoint was still settling. So the look is
	# only to choose the wording, and the create is allowed to say "already".
	#
	# S3 distinguishes a name you own from a name somebody else took, and Vultr
	# reports both as BucketAlreadyExists. The way to tell them apart is to ask
	# again: a bucket you can head is yours, whoever created it. One you cannot
	# belongs to another account, and that is the case VW_SECRETS_BUCKET is for,
	# since names are shared per cluster.
	if s3 head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
		echo "fleet: bucket $BUCKET exists"
	elif [ "$DRY" = 1 ]; then
		echo "would: aws s3api create-bucket --bucket $BUCKET" >&2
	elif err=$(s3 create-bucket --bucket "$BUCKET" 2>&1 >/dev/null); then
		echo "fleet: bucket $BUCKET created"
	else
		case $err in
		*BucketAlreadyExists*|*BucketAlreadyOwnedByYou*)
			if s3 head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
				echo "fleet: bucket $BUCKET was already there, and is ours"
			else
				die "the name $BUCKET is taken on $S3_HOST, and names are
       shared per cluster. If a subscription that held it was just destroyed,
       that is its ghost: Vultr frees a dead subscription's names when its
       cleanup runs, not when it dies. Either wait, or pick a name once:
         VW_SECRETS_BUCKET=<name> fleet.sh secrets init
       Later commands find the bucket by listing, so the variable is not
       needed again. Nothing was created."
			fi ;;
		*)
			die "could not create the bucket $BUCKET on $S3_HOST:
       $err" ;;
		esac
	fi
	echo "fleet: store things in it:"
	echo "         fleet.sh secrets put VW_POOL_TOKEN"
	echo "         fleet.sh secrets put VW_META_KEY"
	echo "         fleet.sh secrets put VW_META_VERIFY"
	echo "         fleet.sh db --url | fleet.sh secrets put VW_META_DATABASE"
	echo "         fleet.sh secrets put VW_DEPLOY_KEY < ~/.ssh/vw_deploy"
}

secrets_put() {
	[ $# -eq 1 ] || die "usage: fleet.sh secrets put <NAME>    (value on stdin)"
	name=$1
	# Env-var shaped and VW_-prefixed, because `secrets env` prints these as
	# export lines a shell will eval, and a name is the one part of that line
	# no quoting protects.
	printf '%s' "$name" | grep -qE '^VW_[A-Z0-9_]+$' \
		|| die "secret names are VW_UPPER_SNAKE, not $name"
	row=$(os_row)
	[ -n "$row" ] || die "no secrets bucket. Run: fleet.sh secrets init"
	s3_env "$row"
	find_bucket
	# Reading to end-of-file is what lets a pipe and a key file work, and it is
	# also an invisible hang to anybody typing, so a terminal is told. Enter
	# does not end it; Ctrl-D does.
	if [ -t 0 ]; then
		echo "fleet: reading the value from stdin. Paste it, then press Ctrl-D." >&2
	fi
	tmp=$(mktemp) || die "no temporary file"
	cat > "$tmp"
	[ -s "$tmp" ] || { rm -f "$tmp"; die "nothing on stdin; nothing stored"; }

	# The values this fleet actually uses have known shapes, and the failure a
	# wrong one buys is remote and quiet: a digest stored as the raw token is a
	# fleet whose arenas are refused hours later with nothing pointing here. So
	# the known names are checked now, when the person who pasted is looking.
	# Unknown VW_ names pass through; this is a secrets store, not a schema.
	val=$(tr -d '\n' < "$tmp")
	case $name in
	VW_POOL_TOKEN|VW_META_KEY|VW_META_VERIFY)
		case $val in
		sha256:*)
			rm -f "$tmp"
			die "$name wants the raw 64 hex value, and that is a sha256: digest.
       The digest is derived from the raw token; storing it here would have
       every arena present a digest as its credential and be refused.
       'vectorwake-server token' prints the raw value: the bare hex line." ;;
		esac
		printf '%s' "$val" | grep -qiE '^[0-9a-f]{64}$' || { rm -f "$tmp"; \
			die "$name should be exactly 64 hex characters; this is $(printf '%s' "$val" | wc -c | tr -d ' ') of something else. Nothing stored."; }
		# Single-line values are stored without the newline a paste brings.
		printf '%s' "$val" > "$tmp" ;;
	VW_META_DATABASE)
		case $val in
		postgres://*|postgresql://*) printf '%s' "$val" > "$tmp" ;;
		*) rm -f "$tmp"
		   die "VW_META_DATABASE should be a postgres:// connection string;
       'fleet.sh db --url' prints it. Nothing stored." ;;
		esac ;;
	VW_DEPLOY_KEY)
		if ! grep -q "PRIVATE KEY" "$tmp"; then
			rm -f "$tmp"
			die "VW_DEPLOY_KEY wants the private key file, and this is not one.
       A .pub pasted here would leave every host unable to clone. Store the
       other file: fleet.sh secrets put VW_DEPLOY_KEY < ~/.ssh/vw_deploy"
		fi ;;
	esac
	s3_do put-object --bucket "$BUCKET" --key "$name" --body "$tmp" >/dev/null \
		|| { rm -f "$tmp"; die "the put failed"; }
	rm -f "$tmp"
	[ "$DRY" = 1 ] || echo "fleet: $name stored"
}

secrets_ls() {
	row=$(os_row)
	[ -n "$row" ] || die "no secrets bucket. Run: fleet.sh secrets init"
	s3_env "$row"
	find_bucket
	out=$(s3 list-objects-v2 --bucket "$BUCKET" \
		| jq -r '.Contents[]? | "  \(.Key)  \(.Size)B  \(.LastModified)"')
	if [ -n "$out" ]; then printf '%s\n' "$out"; else echo "fleet: the bucket is empty"; fi
}

# Every VW_ object as an export line, values quoted, to be eval'd:
#
#   eval "$(fleet.sh secrets env)"
#
# The deploy key is material in the bucket and a path in the interface, so it
# lands in a 0600 file that outlives this run, because the shell that eval'd
# the exports is about to use it.
secrets_env() {
	row=$(os_row)
	[ -n "$row" ] || die "no secrets bucket. Run: fleet.sh secrets init"
	s3_env "$row"
	find_bucket
	names=$(s3 list-objects-v2 --bucket "$BUCKET" \
		| jq -r '.Contents[]?.Key' | grep -E '^VW_[A-Z0-9_]+$' || true)
	[ -n "$names" ] || { echo "fleet: the bucket is empty" >&2; return 1; }
	for n in $names; do
		if [ "$n" = VW_DEPLOY_KEY ]; then
			kf=${TMPDIR:-/tmp}/vw-deploy-key
			umask_was=$(umask); umask 077
			s3 get-object --bucket "$BUCKET" --key VW_DEPLOY_KEY "$kf" \
				>/dev/null 2>&1 || { umask "$umask_was"; continue; }
			umask "$umask_was"
			printf "export VW_DEPLOY_KEY='%s'\n" "$kf"
		else
			v=$(s3_get "$n") || continue
			printf "export %s='%s'\n" "$n" "$(printf '%s' "$v" | sed "s/'/'\\\\''/g")"
		fi
	done
}

cmd_rm() {
	[ $# -eq 1 ] || die "usage: fleet.sh rm <name>"
	name=$1
	host=$name.$DOMAIN
	need jq "jq is not installed"

	# Arena hosts are the disposable ones. The central host holds the address
	# baked into every client and the meta URL riding the catalog, so destroying
	# it is not a fleet operation and should not be one keystroke.
	case $name in
	play|central|"") die "refusing: $host is the central host. Do that deliberately, by hand." ;;
	esac

	id=$(vultr instance list -o json | jq -r --arg l "$host" \
		'.instances[] | select(.label == $l) | .id')
	[ -n "$id" ] || die "no instance labeled $host"

	printf 'fleet: destroy %s (%s) and its DNS record? [y/N] ' "$host" "$id"
	read -r yes
	[ "$yes" = y ] || die "nothing done"

	rec=$(vultr dns record list "$DOMAIN" -o json | jq -r --arg n "$name" \
		'.records[] | select(.name == $n and .type == "A") | .id')
	if [ -n "$rec" ]; then vultr_do dns record delete "$DOMAIN" "$rec" >/dev/null; fi
	vultr_do instance delete "$id" >/dev/null

	# The volume outlives it on purpose: it holds the certificates, a reinstall
	# does not touch it, and it can be handed to the replacement. Deleting it is
	# a separate decision, so it is a sentence here rather than a call.
	echo "fleet: $host is gone. Its certificate volume survives:"
	vultr block-storage list -o json | jq -r --arg l "$host-certs" \
		'.blocks[] | select(.label == $l) | "  \(.id)  \(.label)  \(.size_gb)GB  attached_to=\(.attached_to_instance // "-")"'
}

# The dry run is a flag rather than a verb, because it is a property of a run
# and not a different thing to do.
for a in "$@"; do
	[ "$a" = --dry-run ] && DRY=1
done
if [ "$DRY" = 1 ]; then
	set -- $(for a in "$@"; do [ "$a" = --dry-run ] || printf '%s ' "$a"; done)
	echo "fleet: dry run. Reads happen; nothing is created, moved or destroyed." >&2
fi

case ${1:-} in
render)   shift; cmd_render "$@" ;;
firewall) shift; cmd_firewall "$@" ;;
db)       shift; cmd_db "$@" ;;
secrets)  shift; cmd_secrets "$@" ;;
point)  shift; cmd_point "$@" ;;
new)    shift; cmd_new "$@" ;;
scrub)  shift; cmd_scrub "$@" ;;
rm)     shift; cmd_rm "$@" ;;
*)      sed -n '2,42p' "$0" | sed 's/^# \{0,1\}//' ; exit 2 ;;
esac
