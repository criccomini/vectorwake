# Secret validation and object-storage persistence.

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
		# 0600 temporary file bridges them. Install cleanup here, before any
		# later check can stop the command on its way to render.
		SECRET_KEY_FILE=$(mktemp) || die "no temporary file"
		trap 'rm -f "${SECRET_KEY_FILE:-}"' EXIT
		trap 'rm -f "${SECRET_KEY_FILE:-}"; exit 1' HUP INT TERM
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
