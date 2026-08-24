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
# The certificate volume, and the one thing about it that is regional.
#
# Vultr sells block storage in two tiers and not every region sells both.
# High-performance starts at 10 GB, which is nine and a half more than a
# certificate directory will ever want, and is what the fleet has always taken.
# Storage-optimized starts at 40 GB. Dallas sells only the second, so asking
# for the default there fails on the first call of `new` with "unable to find a
# block storage cluster in that location", which reads like the region is
# unsupported rather than like the tier is.
#
# Overridable per region rather than detected, because the API advertises the
# tiers under names (`block_storage_high_perf`, `block_storage_storage_opt`)
# that would have to be mapped here anyway, and a fleet adds a region about
# once a year. Both values move together: 10 GB is refused on the optimized
# tier as surely as the tier is refused in Dallas.
#
#   VW_BLOCK_TYPE=storage_opt VW_CERT_GB=40 fleet.sh new arena dfw-a1 dfw
CERT_GB=${VW_CERT_GB:-10}
BLOCK_TYPE=${VW_BLOCK_TYPE:-high_perf}
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

. "$HERE/lib/fleet_provider.sh"
. "$HERE/lib/fleet_dns.sh"
. "$HERE/lib/fleet_database.sh"
. "$HERE/lib/fleet_secrets.sh"
. "$HERE/lib/fleet_instance.sh"

# Never from CI. A machine appearing as a side effect of a push is the class of
# surprise this deployment keeps paying to remove, and the token that would let
# it happen has no business in a runner.
[ -z "${CI:-}" ] || die "not from CI. Machines are created from a laptop, on purpose."

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
