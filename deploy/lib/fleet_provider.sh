# Provider command adapters. Reads always execute; mutations pass through the
# dry-run gate.

need() {
	command -v "$1" >/dev/null 2>&1 || die "$2"
}

vultr() {
	need vultr-cli "vultr-cli is not installed. https://github.com/vultr/vultr-cli/releases"
	[ -n "${VULTR_API_KEY:-}" ] || die "VULTR_API_KEY is not set"
	vultr-cli "$@"
}

vultr_do() {
	if [ "$DRY" = 1 ]; then
		echo "would: vultr-cli $*" >&2
		return 0
	fi
	vultr "$@"
}
