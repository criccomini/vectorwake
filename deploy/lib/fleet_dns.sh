# DNS record lookup and convergence.

# Vultr stores the apex under an omitted or empty name. Normalize it to `@` so
# lookup, creation, and update all speak one name.
a_record() {
	vultr dns record list "$DOMAIN" -o json | jq -r --arg n "$1" \
		'[.records[] | select(.type == "A")
		  | select((if (.name // "") == "" then "@" else .name end) == $n)][0]
		 // empty'
}

converge_record() {
	cr_name=$1 cr_ip=$2
	case $cr_name in
	@) cr_display=$DOMAIN ;;
	*) cr_display=$cr_name.$DOMAIN ;;
	esac
	cr_rec=$(a_record "$cr_name")
	cr_rid=$(printf '%s' "$cr_rec" | jq -r '.id // empty')
	cr_old=$(printf '%s' "$cr_rec" | jq -r '.data // empty')
	if [ -z "$cr_rid" ]; then
		vultr_do dns record create "$DOMAIN" --type A --name "$cr_name" \
			--data "$cr_ip" --ttl "$TTL" >/dev/null
		echo "fleet: $cr_display -> $cr_ip (created)"
	elif [ "$cr_old" != "$cr_ip" ]; then
		vultr_do dns record update "$DOMAIN" "$cr_rid" \
			--data "$cr_ip" --ttl "$TTL" >/dev/null
		echo "fleet: $cr_display -> $cr_ip (moved from $cr_old)"
	fi
}

# The bare site and admin name follow the front door on every cutover path.
ride_along() {
	if [ "$name.$DOMAIN" = "$FRONT" ]; then
		converge_record "@" "$1"
		converge_record "${ADMIN_HOST%%.*}" "$1"
	fi
}
