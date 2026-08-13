# Managed Postgres inspection, creation, and destruction.

DB_LABEL=${VW_DB_LABEL:-vectorwake}
DB_ENGINE=${VW_DB_ENGINE:-pg}
DB_VERSION=${VW_DB_VERSION:-16}
DB_PLAN=${VW_DB_PLAN:-vultr-dbaas-startup-cc-1-55-2}

db_row() {
	vultr database list -o json | jq -r --arg l "$DB_LABEL" \
		'[.databases[] | select(.label == $l)][0] // empty'
}

# The meta-layer requires TLS. The project CA is committed separately at
# deploy/db-ca.pem.
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
	if [ "${1:-}" = --url ]; then
		echo "$head" >&2
		printf '%s\n' "$url"
	else
		echo "$head"
		echo "fleet: export VW_META_DATABASE='$url'"
	fi
}

db_create() {
	region=${1:-$REGION}
	if [ -n "$(db_row)" ]; then
		echo "fleet: a database labeled $DB_LABEL already exists:"
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

# This is the one resource a rebuild cannot replace, so destruction requires
# typing its full label even during a dry run.
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
