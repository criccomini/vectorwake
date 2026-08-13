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

echo "fleet dry-run tests pass"
