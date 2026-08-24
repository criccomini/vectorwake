# Host rendering, creation, cutover, firewall, scrubbing, and removal.

# --- the user-data -----------------------------------------------------------

# provision.sh and cloud-init.yml carry placeholders and no secrets, which is
# what lets them be committed. This is the only thing that fills them, and it
# writes to stdout so `render` can show an operator exactly what will be sent
# before anything is created. Everything substituted here ends up in the
# instance's user-data only for first boot. `new` waits for success and replaces
# it with an empty cloud config; `scrub` finishes that cleanup after a repaired
# provision.
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
	trap 'rm -f "$prov" "${SECRET_KEY_FILE:-}"' EXIT
	trap 'rm -f "$prov" "${SECRET_KEY_FILE:-}"; exit 1' HUP INT TERM
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
			--block-type "$BLOCK_TYPE" \
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
	# `--file`, which is what the flag is actually called. It was `--userdata`
	# here and the whole verb failed on the first live run, leaving the
	# bootstrap secrets readable from inside the instance, which is the one
	# thing this function exists to prevent.
	vultr_do instance user-data set "$su_id" --file "$su_stub" >/dev/null \
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

	rec=$(a_record "$name")
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
