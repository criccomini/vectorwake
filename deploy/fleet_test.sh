#!/bin/sh
# Dry-run regression coverage for the sourceable fleet domains.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
DRY=1
DOMAIN=vectorwake.net
FRONT=play.vectorwake.net
ADMIN_HOST=admin.vectorwake.net
TTL=300
REGION=atl
BRANCH=main

die() {
	echo "test failed: $*" >&2
	exit 1
}

contains() {
	case $1 in
	*"$2"*) ;;
	*) die "expected [$2] in [$1]" ;;
	esac
}

. "$ROOT/lib/fleet_provider.sh"
. "$ROOT/lib/fleet_dns.sh"
. "$ROOT/lib/fleet_database.sh"
HERE=$ROOT
. "$ROOT/lib/fleet_secrets.sh"
. "$ROOT/lib/fleet_instance.sh"

# An arena gets the public verifier from the bucket without fetching either
# meta-layer secret. The runtime needs the verifier before it receives a
# catalog, while the signing key and database credential never belong there.
TEST_TMP=$(mktemp -d)
TEST_KEY=$TEST_TMP/deploy-key
trap 'rm -rf "$TEST_TMP"' EXIT HUP INT TERM
printf '%s\n' "private deploy key" >"$TEST_KEY"
: >"$TEST_TMP/vultr-cli"
chmod +x "$TEST_TMP/vultr-cli"
PATH=$TEST_TMP:$PATH
VW_POOL_TOKEN=pool-token
VW_DEPLOY_KEY=$TEST_KEY
VULTR_API_KEY=test
TEST_VERIFY=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
unset VW_META_DATABASE VW_META_KEY VW_META_VERIFY
os_row() { printf '%s\n' '{}'; }
s3_env() { :; }
find_bucket() { :; }
s3_get() {
	case $1 in
	VW_META_VERIFY) printf '%s' "$TEST_VERIFY" ;;
	*) die "an arena fetched $1 from the secrets bucket" ;;
	esac
}
secrets_fill arena
[ "$VW_META_VERIFY" = "$TEST_VERIFY" ] \
	|| die "an arena did not fetch the public verifier"
[ -z "${VW_META_KEY:-}" ] && [ -z "${VW_META_DATABASE:-}" ] \
	|| die "an arena fetched a meta-layer secret"

# The rendered host keeps that public verifier and blanks the two credentials
# that would let a compromised arena sign sessions or read player data.
VW_META_KEY=private-signing-key
VW_META_DATABASE=postgres://private-database
cloud=$(render arena edge "" atl 2>/dev/null)
encoded=$(printf '%s\n' "$cloud" | sed -n 's/^    content: //p' | tail -1)
provision=$(printf '%s' "$encoded" | base64 -d)
contains "$provision" "VW_META_VERIFY=$TEST_VERIFY"
contains "$provision" "VW_META_KEY="
contains "$provision" "VW_META_DATABASE="
case $provision in
*private-signing-key*|*postgres://private-database*)
	die "an arena render carried a meta-layer secret" ;;
esac
unset VULTR_API_KEY VW_META_DATABASE VW_META_KEY

[ "$(serves central play)" = "$FRONT" ] \
	|| die "a central host no longer serves the front door"
[ "$(serves arena edge)" = "edge.$DOMAIN" ] \
	|| die "an arena host no longer serves its own name"

# A mutation in dry-run mode must never reach the provider adapter.
vultr() {
	die "dry run called the provider: $*"
}
out=$(vultr_do instance delete instance-1 2>&1)
contains "$out" "would: vultr-cli instance delete instance-1"

# Reads still execute. The apex arrives without a name and is normalized to @.
VULTR_REPLY='{"records":[{"id":"apex-1","type":"A","data":"192.0.2.1"}]}'
vultr() {
	printf '%s\n' "$VULTR_REPLY"
}
record=$(a_record "@")
[ "$(printf '%s' "$record" | jq -r '.id')" = apex-1 ] \
	|| die "the apex record was not normalized"

# Creation and update both preserve their exact provider command while doing
# no mutation.
VULTR_REPLY='{"records":[]}'
out=$(converge_record edge 192.0.2.2 2>&1)
contains "$out" \
	"would: vultr-cli dns record create vectorwake.net --type A --name edge --data 192.0.2.2 --ttl 300"
contains "$out" "fleet: edge.vectorwake.net -> 192.0.2.2 (created)"

VULTR_REPLY='{"records":[{"id":"record-7","type":"A","name":"edge","data":"192.0.2.1"}]}'
out=$(converge_record edge 192.0.2.2 2>&1)
contains "$out" \
	"would: vultr-cli dns record update vectorwake.net record-7 --data 192.0.2.2 --ttl 300"

# A front-door cutover still carries both the apex and admin name with it.
name=play
VULTR_REPLY='{"records":[]}'
out=$(ride_along 192.0.2.9 2>&1)
contains "$out" "--name @ --data 192.0.2.9"
contains "$out" "--name admin --data 192.0.2.9"

database='{"user":"pilot","password":"secret","host":"db.example","port":16751,"dbname":"vectorwake"}'
[ "$(db_url "$database")" = \
	"postgres://pilot:secret@db.example:16751/vectorwake?sslmode=require" ] \
	|| die "the database URL changed"

db_row() {
	printf '%s' ""
}
out=$(printf 'y\n' | db_create dfw 2>&1)
contains "$out" \
	"would: vultr-cli database create --database-engine pg --database-engine-version 16 --region dfw --plan vultr-dbaas-startup-cc-1-55-2 --label vectorwake"

# The split secrets module still validates a render before any host exists.
VW_POOL_TOKEN=pool-token
VW_DEPLOY_KEY=$TEST_KEY
secrets_fill() { :; }
check_secrets arena

# Object storage mutations obey the same dry-run gate as provider mutations.
s3() {
	die "dry run called object storage: $*"
}
out=$(s3_do put-object --bucket bucket --key key --body file 2>&1)
contains "$out" "would: aws s3api put-object --bucket bucket --key key --body file"

# Host removal remains a provider read followed by gated mutations. The
# certificate volume is reported and left alone.
vultr() {
	case "$*" in
	"instance list -o json")
		printf '%s\n' '{"instances":[{"id":"instance-7","label":"edge.vectorwake.net"}]}' ;;
	"dns record list vectorwake.net -o json")
		printf '%s\n' '{"records":[{"id":"record-7","name":"edge","type":"A"}]}' ;;
	"block-storage list -o json")
		printf '%s\n' '{"blocks":[{"id":"volume-7","label":"edge.vectorwake.net-certs","size_gb":10}]}' ;;
	*) die "unexpected provider read: $*" ;;
	esac
}
out=$(printf 'y\n' | cmd_rm edge 2>&1)
contains "$out" "would: vultr-cli dns record delete vectorwake.net record-7"
contains "$out" "would: vultr-cli instance delete instance-7"
contains "$out" "volume-7"

echo "fleet dry-run tests pass"
