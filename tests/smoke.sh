#!/usr/bin/env bash
#
# Smoke test for a running OCM stack.
#
#   docker compose up -d && tests/smoke.sh
#
# Checks that the application starts, that a session can be established, and
# that the main authenticated pages render. It is not a functional test suite —
# it is the floor: enough to catch a backport that breaks the login path or
# white-screens a page.
#
# Env:
#   OCM_URL         default http://127.0.0.1:8080/cms
#   OCM_USER        default admin
#   OCM_PASSWORD    default: read from the app container log
#   COMPOSE_PROJECT default: docker compose's own default
set -uo pipefail

# Fixtures live beside this script, which may be run from anywhere.
SMOKE_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "${SMOKE_DIR}/.." && pwd)"

# ── .env ───────────────────────────────────────────────────────────────────
# The database checks need the same credentials compose was started with, and
# for a Docker install those live in .env next to docker-compose.yml. Read them
# from there rather than making the caller export them again, so that a plain
# `docker compose up -d && tests/smoke.sh` runs the whole suite instead of
# skipping every section that needs a query.
#
# Only these names are read, and only when not already set in the environment,
# so an explicit export still wins. The file is parsed, never sourced: a .env is
# data for compose, not a shell script, and sourcing one would execute whatever
# it happens to contain.
if [ -f "${REPO_DIR}/.env" ]; then
	while IFS='=' read -r env_key env_val; do
		case "$env_key" in
			DB_NAME|DB_USER|DB_PASSWORD|DB_ROOT_PASSWORD|ADMIN_USER|ADMIN_PASSWORD)
				;;
			*) continue ;;
		esac
		
		# Strip one layer of matching quotes, the way compose does.
		case "$env_val" in
			\"*\") env_val="${env_val#\"}"; env_val="${env_val%\"}" ;;
			"'"*"'") env_val="${env_val#\'}"; env_val="${env_val%\'}" ;;
		esac
		
		if [ -z "$(eval "printf '%s' \"\${${env_key}:-}\"")" ]; then
			eval "${env_key}=\$env_val"
		fi
	done < <(sed -E 's/\r$//; s/^[[:space:]]*(export[[:space:]]+)?//' "${REPO_DIR}/.env" \
		| grep -E '^[A-Za-z_][A-Za-z0-9_]*=')
	unset env_key env_val
fi

# Compose defaults, mirrored here so the fallbacks match what the stack was
# actually built with. docker-compose.yml uses DB_PASSWORD for the root password
# when DB_ROOT_PASSWORD is unset.
DB_NAME="${DB_NAME:-cms}"
DB_USER="${DB_USER:-ocm}"
DB_PASSWORD="${DB_PASSWORD:-}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-$DB_PASSWORD}"

OCM_URL="${OCM_URL:-http://127.0.0.1:8080/cms}"
OCM_USER="${OCM_USER:-${ADMIN_USER:-admin}}"
COOKIES="$(mktemp)"
BODY="$(mktemp)"
trap 'rm -f "$COOKIES" "$BODY"' EXIT

pass=0
fail=0
HAVE_DB=0
ok()   { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

# ── Password ───────────────────────────────────────────────────────────────
# ADMIN_PASSWORD in .env is the same credential under compose's name for it.
if [ -z "${OCM_PASSWORD:-}" ] && [ -n "${ADMIN_PASSWORD:-}" ]; then
	OCM_PASSWORD="$ADMIN_PASSWORD"
fi
if [ -z "${OCM_PASSWORD:-}" ]; then
	compose_args=()
	[ -n "${COMPOSE_PROJECT:-}" ] && compose_args=(-p "$COMPOSE_PROJECT")
	OCM_PASSWORD="$(docker compose "${compose_args[@]}" logs app 2>/dev/null \
		| grep -oE 'password: [A-Za-z0-9]+' | tail -1 | cut -d' ' -f2)"
fi
if [ -z "${OCM_PASSWORD:-}" ]; then
	echo "smoke: no password. Set OCM_PASSWORD, or ADMIN_PASSWORD in .env." >&2
	exit 2
fi

# ── Re-authentication helper ───────────────────────────────────────────────
# A password change, a user edit and a settings change all ask the signed-in
# administrator for the password again before the change takes effect. See
# section 39. A test that drives one of those forms has to answer the
# challenge the way a person does. The challenge carries the in-flight fields
# forward, so replaying the same body with the scope and the password added
# finishes the original request. The grant lasts five minutes per scope, so
# only the first post in a section meets the challenge.
#
# Usage: sm_reauth_post <scope> <url> [curl -d args ...]
# The reply body is left in $BODY, with two differences from a plain curl.
# $BODY is truncated before the FIRST transfer, so no page from an earlier
# request survives it. A transfer that fails part way through still leaves
# the bytes it did write. The challenge-answering transfer has no truncation
# of its own, but it writes to the same -o file, and curl truncates that
# file at the first byte of the second response's body -- and also when that
# transfer completes carrying no body at all. So the challenge page is
# still there only when the second transfer failed before any of its body
# arrived; a second response that broke off part way through has already
# replaced it with its own partial page.
# The helper's own status is not curl's either: it returns 0 where
# the page needed no challenge, and the second curl's status where one was
# answered. A first transfer that failed before the challenge field
# arrived also returns 0, but one that failed after writing that field
# takes the challenge path, so what comes back is the second curl's
# status. A caller that needs to know whether its request arrived has to
# capture the status of a curl it made itself.
sm_reauth_post() {
	sm_ra_scope="$1"
	sm_ra_url="$2"
	shift 2
	# Truncate first. A transfer that fails before any of the body
	# arrives does not write to $BODY at all, leaving the previous page
	# there, and if that page happened to be a reauth prompt this would
	# post a token belonging to an earlier request.
	: > "$BODY"
	curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" "$@" "$sm_ra_url" >/dev/null
	if grep -q 'name="_reauth_scope"' "$BODY"; then
		sm_ra_tok="$(grep -oE 'name="_csrf" value="[0-9a-f]{64}"' "$BODY" \
			| head -1 | sed -e 's/.*value="//' -e 's/"$//')"
		curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" "$@" \
			-d "_reauth_scope=${sm_ra_scope}" \
			-d "_csrf=${sm_ra_tok}" \
			--data-urlencode "_reauth_password=${OCM_PASSWORD}" \
			"$sm_ra_url" >/dev/null
	fi
}

echo "smoke: $OCM_URL as $OCM_USER"

# Confirm a fixture's identity before testing a different password rule.
# Do not carry candidate passwords into the challenge response.
sm_auth_grant() {
	local jar="$1" password="$2" scope="$3" url="$4" token
	curl -sL --max-time 30 -c "$jar" -b "$jar" -o "$BODY" "$OCM_URL/password.php" >/dev/null
	token="$(grep -oE 'name="_csrf" value="[0-9a-f]{64}"' "$BODY" \
		| head -1 | sed -e 's/.*value="//' -e 's/"$//')"
	curl -sL --max-time 30 -c "$jar" -b "$jar" -o "$BODY" \
		--data-urlencode "_csrf=${token}" --data-urlencode "_reauth_scope=${scope}" \
		--data-urlencode "_reauth_password=${password}" "$url" >/dev/null
}

# Submit the password form, answer its challenge without candidate secrets,
# then reenter the original form with the new CSRF token.
sm_password_post() {
	local jar="$1" password="$2" token
	shift 2
	curl -sL --max-time 30 -c "$jar" -b "$jar" -o "$BODY" "$@" >/dev/null
	if grep -q 'name="_reauth_scope" value="password_change"' "$BODY"; then
		if grep -qE 'name="(oldpass|newpass1|newpass2)"' "$BODY"; then
			bad "the password-change challenge carries a password field"
		fi
		sm_auth_grant "$jar" "$password" password_change "$OCM_URL/password.php"
		token="$(grep -oE 'name="_csrf" value="[0-9a-f]{64}"' "$BODY" \
			| head -1 | sed -e 's/.*value="//' -e 's/"$//')"
		curl -sL --max-time 30 -c "$jar" -b "$jar" -o "$BODY" "$@" \
			--data-urlencode "_csrf=${token}" >/dev/null
	fi
}

# ── 1. The login page is served ────────────────────────────────────────────
code="$(curl -s -o "$BODY" -w '%{http_code}' "$OCM_URL/")"
if [ "$code" = 200 ] && grep -q 'login_pass' "$BODY"; then
	ok "login page renders"
else
	bad "login page: status $code, login form found: $(grep -c login_pass "$BODY")"
	echo "smoke: cannot continue without a login page" >&2
	exit 1
fi

# ── 2. A wrong password is refused ─────────────────────────────────────────
# Guards against a change that makes authenticate() succeed unconditionally.
curl -sL -c "$COOKIES" -b "$COOKIES" -o "$BODY" \
	-X POST -d "login_user=${OCM_USER}&login_pass=definitely-not-the-password&auth_id=1" \
	"$OCM_URL/" >/dev/null
if grep -q 'login_pass' "$BODY"; then
	ok "wrong password is refused"
else
	bad "wrong password was ACCEPTED — the login form is gone after a bad login"
fi
: > "$COOKIES"

# ── 3. The real password establishes a session ──────────────────────────────
curl -sL -c "$COOKIES" -b "$COOKIES" -o "$BODY" \
	-X POST -d "login_user=${OCM_USER}&login_pass=${OCM_PASSWORD}&auth_id=1" \
	"$OCM_URL/" >/dev/null
if ! grep -q 'login_pass' "$BODY" && grep -qi 'logout' "$BODY"; then
	ok "login succeeds and the session lands on the home page"
else
	bad "login failed: login form present: $(grep -c login_pass "$BODY"), logout link: $(grep -ci logout "$BODY")"
	echo "smoke: cannot continue without a session" >&2
	exit 1
fi

# ── 4. The authenticated pages render ──────────────────────────────────────
# A PHP fatal error in this application returns HTTP 200 with a short or empty
# body, so status alone proves nothing. Require a plausible body size and no
# PHP error text.
# pika_cms.php is deliberately absent: it is a library that index.php includes,
# not a page. The home page is "/".
#
# -L is required. cases.php redirects to case_list.php and reports/ needs its
# trailing slash, so a bare status check reports a false failure.
for page in \
	"" \
	case_list.php \
	cases.php \
	addressbook.php \
	cal_day.php \
	cal_week.php \
	search.php \
	site_map.php \
	prefs.php \
	transfers.php \
	system-users.php \
	system-settings.php \
	system-groups.php \
	reports/ \
	; do
	label="${page:-/ (home)}"
	code="$(curl -sL -b "$COOKIES" -o "$BODY" -w '%{http_code}' "$OCM_URL/$page")"
	size="$(wc -c < "$BODY")"
	if [ "$code" != 200 ]; then
		bad "$label: status $code"
	elif [ "$size" -lt 500 ]; then
		bad "$label: status 200 but only $size bytes (likely a PHP fatal)"
	elif grep -qiE 'Fatal error|Parse error|Uncaught (Exception|Error)|on line [0-9]+ in /var/www' "$BODY"; then
		bad "$label: PHP error in the body — $(grep -ioE 'Fatal error[^<]{0,80}|Parse error[^<]{0,80}' "$BODY" | head -1)"
	elif grep -q 'login_pass' "$BODY"; then
		bad "$label: bounced back to the login form — the session was dropped"
	else
		ok "$label renders ($size bytes)"
	fi
done

# ── 4b. AJAX fragment endpoints ────────────────────────────────────────────
# These render a partial, not a page, so the size floor above does not apply.
# documents.php sets PL_DISABLE_DISPLAY_LOGIN and prints nothing rather than
# redirecting when there is no session, so it needs its own two checks: it must
# work with a session, and it must reveal nothing without one.
for page in documents.php autocomplete.php; do
	code="$(curl -sL -b "$COOKIES" -o "$BODY" -w '%{http_code}' "$OCM_URL/$page")"
	if [ "$code" != 200 ]; then
		bad "$page (fragment): status $code"
	elif grep -qiE 'Fatal error|Parse error|Uncaught (Exception|Error)' "$BODY"; then
		bad "$page (fragment): PHP error in the body"
	else
		ok "$page (fragment) responds ($(wc -c < "$BODY") bytes)"
	fi
done

# Same endpoints with no cookie jar. A file list returned here would be an
# unauthenticated read of client document metadata.
for page in documents.php autocomplete.php; do
	curl -sL -o "$BODY" "$OCM_URL/$page" >/dev/null
	if grep -qiE 'fileList\(|doc_id|<tr' "$BODY"; then
		bad "$page LEAKS CONTENT WITHOUT A SESSION"
	else
		ok "$page reveals nothing without a session"
	fi
done

# ── 5. The config directory is not readable over HTTP ──────────────────────
# It holds the database password.
for path in \
	/cms-custom/config/settings.php \
	/cms-custom/config/ \
	; do
	base="${OCM_URL%/cms}"
	code="$(curl -s -o "$BODY" -w '%{http_code}' "${base}${path}")"
	if [ "$code" = 403 ] || [ "$code" = 404 ]; then
		ok "$path is not served (status $code)"
	elif grep -q 'db_password' "$BODY"; then
		bad "$path LEAKS THE DATABASE PASSWORD (status $code)"
	else
		bad "$path is reachable, status $code"
	fi
done

# ── 6. The audit log records privileged actions ────────────────────────────
# The two login attempts in sections 2 and 3 above must have left rows. This
# is checked in the database rather than through the viewer page so a broken
# viewer and a broken writer are distinguishable failures.
#
# Needs the db container to reach the database; skipped when the suite is
# pointed at a host it cannot query.
#
# COMPOSE_PROJECT is only needed when the stack was started under a name other
# than compose's own default. Unset, COMPOSE_ARGS is empty and docker compose uses
# the project it would use for this directory, which is what an ordinary
# `docker compose up -d && tests/smoke.sh` produces.
COMPOSE_ARGS=()
[ -n "${COMPOSE_PROJECT:-}" ] && COMPOSE_ARGS=(-p "$COMPOSE_PROJECT")

# Whether there is a stack here at all. The sections that reach into the
# container are gated on this rather than on COMPOSE_PROJECT being set, so the
# suite runs in full for a plain `docker compose up -d && tests/smoke.sh`.
# Collected without a pipe into grep -q: under `set -o pipefail`, grep exiting
# on its first match closes the pipe, and the whole pipeline then reports the
# failure of the writer rather than the success of the match.
HAVE_COMPOSE=0
if command -v docker >/dev/null 2>&1; then
	COMPOSE_SERVICES="$(docker compose "${COMPOSE_ARGS[@]}" ps --services 2>/dev/null)"
	
	case "
${COMPOSE_SERVICES}
" in
		*"
app
"*) HAVE_COMPOSE=1 ;;
	esac
fi

if [ "$HAVE_COMPOSE" = 1 ]; then
	# The password goes in MYSQL_PWD, never in a -p argument. `mariadb -p`
	# with an empty value does not mean "no password" -- it means "prompt for
	# one", and under `exec -T` there is no terminal to answer, so the client
	# blocks forever and the whole suite hangs with no output. Setting the
	# variable to an empty string is an actual empty password.
	#
	# `< /dev/null` for the same reason: nothing here should ever be able to
	# wait on stdin.
	adb() {
		docker compose "${COMPOSE_ARGS[@]}" exec -T \
			-e MYSQL_PWD="$DB_PASSWORD" db \
			mariadb -u"$DB_USER" -N -B \
			-e "$1" "$DB_NAME" </dev/null 2>/dev/null
	}
	if [ -z "$(adb 'SELECT 1')" ]; then
		# Fall back to root, which the compose file always sets.
		adb() {
			docker compose "${COMPOSE_ARGS[@]}" exec -T \
				-e MYSQL_PWD="$DB_ROOT_PASSWORD" db \
				mariadb -uroot -N -B \
				-e "$1" "$DB_NAME" </dev/null 2>/dev/null
		}
	fi

	if [ -z "$(adb 'SELECT 1')" ]; then
		printf '  skip audit log checks (cannot reach the database)\n'
	else
		HAVE_DB=1
		if [ -n "$(adb "SELECT 1 FROM audit_log LIMIT 1")" ] \
			|| [ -n "$(adb "SHOW TABLES LIKE 'audit_log'")" ]; then
			ok "audit_log table exists"
		else
			bad "audit_log table is MISSING (add_audit_log.sql did not run)"
		fi

		# Section 2 posted a deliberately wrong password; section 3 a correct
		# one. Both must be on the record, with the acting username attached.
		for action in login.failure login.success; do
			n="$(adb "SELECT COUNT(*) FROM audit_log WHERE action='${action}' AND username='${OCM_USER}'")"
			if [ "${n:-0}" -ge 1 ]; then
				ok "audit_log recorded ${action} for ${OCM_USER}"
			else
				bad "audit_log has no ${action} row for ${OCM_USER}"
			fi
		done

		# A row with no actor means pl_audit's actor resolution regressed.
		# It reads the global $auth_row, not $_SESSION, which OCM never
		# persists across requests.
		orphans="$(adb "SELECT COUNT(*) FROM audit_log WHERE action='login.success' AND user_id IS NULL")"
		if [ "${orphans:-0}" -eq 0 ]; then
			ok "audit_log login rows carry an actor"
		else
			bad "audit_log has ${orphans} login.success row(s) with no user_id"
		fi

		# The viewer must be system-only. An anonymous request that returns
		# audit content is a disclosure of the security event stream.
		curl -sL -o "$BODY" "$OCM_URL/system-audit.php" >/dev/null
		if grep -qE 'login\.(success|failure)|audit_id' "$BODY"; then
			bad "system-audit.php LEAKS THE AUDIT LOG WITHOUT A SESSION"
		else
			ok "system-audit.php reveals nothing without a session"
		fi

		# ...and must render the real rows for an authenticated admin.
		code="$(curl -sL -b "$COOKIES" -o "$BODY" -w '%{http_code}' "$OCM_URL/system-audit.php")"
		if [ "$code" = 200 ] && grep -q 'login\.success' "$BODY"; then
			ok "system-audit.php renders the log for an admin ($(wc -c < "$BODY") bytes)"
		else
			bad "system-audit.php did not render the log for an admin (status $code, $(wc -c < "$BODY") bytes)"
		fi
	fi
else
	printf '  skip audit log checks (needs a running docker compose stack)\n'
fi

# ── 7. CSRF ────────────────────────────────────────────────────────────────
# Two properties matter here and they fail in opposite directions.
#
# Under-enforcement: a state-changing request succeeds without the session's
# token, which is the vulnerability.
#
# Over-enforcement: a legitimate form renders without a token — because a
# template lost its %%[csrf_field]%% tag, or the tag resolved to nothing — and
# then every real user's save returns 403. That is the more likely regression
# and the harder one to notice, so it is checked first.
#
# system-maint.php is the probe for the POST path. It is CSRF-gated, and an
# unrecognised action falls through its switch to the default branch, which
# renders the page and changes nothing. So the accept case can be tested for
# real without a mutation to undo afterwards.
MAINT="$OCM_URL/system-maint.php"

# 7a. A rendered form carries a resolved 64-hex token.
curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" "$MAINT" >/dev/null
CSRF_TOKEN="$(grep -oE 'name="_csrf" value="[0-9a-f]*"' "$BODY" \
	| head -1 | sed -E 's/.*value="([0-9a-f]*)".*/\1/')"
if [ "${#CSRF_TOKEN}" -eq 64 ]; then
	ok "system-maint.php form carries a 64-hex CSRF token"
else
	bad "system-maint.php form has no usable CSRF token (got ${#CSRF_TOKEN} chars)"
fi

# 7b. No POST form anywhere renders without a token, and no template leaks the
# raw tag. An unresolved tag or an empty value is the over-enforcement failure:
# the page looks fine and every save from it is refused.
for page in \
	"" \
	system-maint.php \
	system-settings.php \
	system-users.php \
	prefs.php \
	password.php \
	search.php \
	addressbook.php \
	; do
	label="${page:-/ (home)}"
	curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" "$OCM_URL/$page" >/dev/null
	# Only POST forms need a token; GET forms are deliberately excluded so the
	# token never lands in a URL or a browser history entry.
	post_forms="$(grep -oiE '<form[^>]*method=["'"'"']?post' "$BODY" | wc -l)"
	tokens="$(grep -oE 'name="_csrf" value="[0-9a-f]{64}"' "$BODY" | wc -l)"
	if grep -q '%%\[csrf_field\]%%' "$BODY"; then
		bad "$label: literal %%[csrf_field]%% in the output — the tag did not resolve"
	elif grep -qE 'name="_csrf" value=""' "$BODY"; then
		bad "$label: a _csrf field rendered EMPTY — every POST from this page will 403"
	elif [ "$post_forms" -gt "$tokens" ]; then
		bad "$label: $post_forms POST form(s) but only $tokens token(s)"
	else
		ok "$label: $post_forms POST form(s), $tokens token(s)"
	fi
done

# 7c. A POST with no token is refused.
code="$(curl -s --max-time 30 -b "$COOKIES" -o "$BODY" -w '%{http_code}' \
	-X POST -d 'action=smoke-no-token' "$MAINT")"
if [ "$code" = 403 ] && grep -q 'CSRF validation failed' "$BODY"; then
	ok "POST without a token is refused (403)"
else
	bad "POST WITHOUT A TOKEN WAS NOT REFUSED (status $code, $(wc -c < "$BODY") bytes)"
fi

# 7d. A POST with a well-formed but wrong token, from a logged-in user, gets
# the recovery form rather than a bare 403, so an expired token does not
# discard the work in the form.
bogus="$(printf 'a%.0s' $(seq 64))"
curl -s --max-time 30 -b "$COOKIES" -o "$BODY" \
	-X POST -d "action=smoke-bad-token&_csrf=${bogus}" "$MAINT" >/dev/null
if grep -q 'Confirm your save' "$BODY" && grep -q '_csrf_recovery' "$BODY"; then
	ok "a stale token offers the recovery form, not a dead end"
elif grep -q 'CSRF validation failed' "$BODY"; then
	bad "a stale token gave a bare 403 — the recovery path did not fire"
else
	bad "a stale token gave neither recovery nor refusal ($(wc -c < "$BODY") bytes)"
fi

# 7e. The real token is accepted.
if [ "${#CSRF_TOKEN}" -eq 64 ]; then
	code="$(curl -s --max-time 30 -b "$COOKIES" -o "$BODY" -w '%{http_code}' \
		-X POST -d "action=smoke-valid-token&_csrf=${CSRF_TOKEN}" "$MAINT")"
	if [ "$code" = 200 ] \
		&& ! grep -q 'CSRF validation failed' "$BODY" \
		&& ! grep -q 'Confirm your save' "$BODY" \
		&& grep -q 'Truncate SSNs' "$BODY"; then
		ok "POST with the session token is processed"
	else
		bad "POST with a VALID token was rejected (status $code, $(wc -c < "$BODY") bytes)"
	fi
else
	bad "cannot test the accept path: no token was extracted in 7a"
fi

# 7f. Pages that change state on a GET cannot carry a hidden field, so they
# fall back to the request's own provenance. system-groups.php is one of them.
# Not GROUPS: that is a read-only bash special variable holding the
# caller's group ids, and assigning to it fails silently.
GROUPS_URL="$OCM_URL/system-groups.php"
code="$(curl -s --max-time 30 -b "$COOKIES" -o "$BODY" -w '%{http_code}' \
	-H 'Sec-Fetch-Site: cross-site' "$GROUPS_URL")"
if [ "$code" = 403 ] && grep -q 'came from another site' "$BODY"; then
	ok "a cross-site GET to a GET-mutating page is refused (Sec-Fetch-Site)"
else
	bad "a cross-site GET was ALLOWED (status $code)"
fi

code="$(curl -s --max-time 30 -b "$COOKIES" -o "$BODY" -w '%{http_code}' \
	-H 'Origin: https://evil.example' "$GROUPS_URL")"
if [ "$code" = 403 ]; then
	ok "a foreign Origin on a GET-mutating page is refused"
else
	bad "a foreign Origin was ALLOWED (status $code)"
fi

# ...and a request with no provenance headers at all must still work. Old
# browsers and bookmarks send neither header, and locking them out would be a
# self-inflicted outage, so 'unknown' is allowed through on purpose.
code="$(curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" -w '%{http_code}' "$GROUPS_URL")"
size="$(wc -c < "$BODY")"
if [ "$code" = 200 ] && [ "$size" -gt 500 ]; then
	ok "a request with no provenance headers is still served ($size bytes)"
else
	bad "a plain request to $GROUPS_URL was blocked (status $code, $size bytes)"
fi

# 7g. The refusals above are on the record, and the token really is the one in
# the database rather than a value the page invented.
if [ "$HAVE_DB" = 1 ]; then
	if [ -n "$(adb "SHOW TABLES LIKE 'csrf_tokens'")" ]; then
		ok "csrf_tokens table exists"
	else
		bad "csrf_tokens table is MISSING (add_csrf_tokens_table.sql did not run)"
	fi

	if [ "${#CSRF_TOKEN}" -eq 64 ]; then
		n="$(adb "SELECT COUNT(*) FROM csrf_tokens WHERE token='${CSRF_TOKEN}'")"
		if [ "${n:-0}" -ge 1 ]; then
			ok "the rendered token matches its csrf_tokens row"
		else
			bad "the rendered token is in no csrf_tokens row — the token is not persisted"
		fi
	fi

	# recovery=0 is 7c, recovery=1 is 7d. Both must be distinguishable in the
	# log, because one is a likely attack and the other is a user whose token
	# expired.
	for want in 0 1; do
		n="$(adb "SELECT COUNT(*) FROM audit_log WHERE action='csrf.rejected' AND details LIKE '%\"recovery\":${want}%'")"
		if [ "${n:-0}" -ge 1 ]; then
			ok "audit_log recorded csrf.rejected with recovery=${want}"
		else
			bad "audit_log has no csrf.rejected row with recovery=${want}"
		fi
	done

	n="$(adb "SELECT COUNT(*) FROM audit_log WHERE action='csrf.cross_site_get'")"
	if [ "${n:-0}" -ge 1 ]; then
		ok "audit_log recorded csrf.cross_site_get"
	else
		bad "audit_log has no csrf.cross_site_get row"
	fi
else
	printf '  skip CSRF database checks (needs a running docker compose stack)\n'
fi


# ── 8. Default-deny gates and the server-level error pages ─────────────────
# Everything here fails open, so the assertions are written the same way as
# section 7: the refusal is checked, and so is the case that must still work,
# because a gate that refuses everything is as broken as one that refuses
# nothing.

# 8a. ops/upload_document.php had no authorization at all. It now denies by
# default, so an unrecognised doc_type must be refused even for the admin.
UPLOAD="$OCM_URL/ops/upload_document.php"
if [ "${#CSRF_TOKEN}" -eq 64 ]; then
	code="$(curl -s --max-time 30 -b "$COOKIES" -o "$BODY" -w '%{http_code}' \
		-X POST -d "doc_type=Z&_csrf=${CSRF_TOKEN}" "$UPLOAD")"
	if [ "$code" = 403 ] && grep -q 'Access denied' "$BODY"; then
		ok "upload_document.php refuses an unknown doc_type (403)"
	else
		bad "UPLOAD WITH AN UNKNOWN doc_type WAS NOT REFUSED (status $code, $(wc -c < "$BODY") bytes)"
	fi

	# 8b. A case document names a case, so a case_id that resolves to no row
	# has nothing to authorize against and must not fall through.
	code="$(curl -s --max-time 30 -b "$COOKIES" -o "$BODY" -w '%{http_code}' \
		-X POST -d "doc_type=C&case_id=999999999&_csrf=${CSRF_TOKEN}" "$UPLOAD")"
	if [ "$code" = 403 ] && grep -q 'Access denied' "$BODY"; then
		ok "upload_document.php refuses a case document for an unknown case (403)"
	else
		bad "UPLOAD FOR AN UNKNOWN CASE WAS NOT REFUSED (status $code, $(wc -c < "$BODY") bytes)"
	fi
else
	bad "cannot test the upload gate: no token was extracted in 7a"
fi

# 8c. documents.php update and delete are POST-only now. A GET must be refused
# with 405 rather than performed, and the refusal has to name the method that
# works or the next caller has to guess.
DOCS="$OCM_URL/documents.php"
for act in update delete; do
	code="$(curl -s --max-time 30 -b "$COOKIES" -D "$BODY" -o /dev/null \
		-w '%{http_code}' "$DOCS?action=$act&doc_id=1")"
	if [ "$code" = 405 ] && grep -qi '^Allow: *POST' "$BODY"; then
		ok "documents.php refuses a GET $act (405, Allow: POST)"
	else
		bad "documents.php GET $act WAS NOT REFUSED (status $code)"
	fi
done

# 8d. services/date_selector-server.php echoes field_name back into HTML
# attributes, so it pins that value to the shape a form field name can have.
# Both checks matter: a malformed field name is refused, and a real one still
# renders the calendar. Both carry this run's session, because the endpoint now
# requires one -- section 102 is what checks that it does.
CAL="$OCM_URL/services/date_selector-server.php"
code="$(curl -s --max-time 30 -b "$COOKIES" -o "$BODY" -w '%{http_code}' \
	--get --data-urlencode 'field_name="><script>x</script>' \
	--data-urlencode 'container=date_selector-00001' "$CAL")"
cal_bad_curl=$?
if [ "$cal_bad_curl" != 0 ]; then
	bad "date_selector-server.php could not be read with a malformed field_name (curl exit $cal_bad_curl), so this run says nothing about what it does with one"
elif [ "$code" = 400 ] && grep -q 'Invalid field_name' "$BODY"; then
	ok "date_selector-server.php refuses a malformed field_name (400)"
else
	bad "date_selector-server.php did not refuse a malformed field_name with HTTP 400 and 'Invalid field_name.' (status $code)"
fi

code="$(curl -s --max-time 30 -b "$COOKIES" -o "$BODY" -w '%{http_code}' \
	"$CAL?field_name=open_date&container=date_selector-00001&month=1&year=2020")"
cal_curl=$?
# A transfer that failed part way can leave this file stale or absent. The
# stderr redirect goes BEFORE the input redirect: bash applies redirections left
# to right, so the other order still prints the missing file. The exit status
# above is what decides whether any of these values mean anything.
size="$(wc -c 2>/dev/null < "$BODY")"
# Everything below is read out of ONE table, the calendar, and not out of the
# page. Starting a new line at every opening table tag puts each table on a line
# of its own; keeping the lines whose tag carries the class token leaves the
# calendars. There has to be exactly one. A reply holding TWO calendars -- one
# for the field that was asked for, drawn for February, and one for another
# field, drawn for January -- passed when the dates were counted over the page
# while the field and the container were read from the first table. Neither half
# was wrong on its own; they were about different tables.
#
# The class token has to follow whitespace, so that data-class="js-date-selector"
# is not read as a class attribute.
CALT="$(mktemp)"
sed 's|<table|\n<table|g' "$BODY" 2>/dev/null \
	| grep -E '<table[^>]*[[:space:]]class="([^"]+ )?js-date-selector( [^"]+)?"' > "$CALT" 2>/dev/null
cal_count="$(wc -l 2>/dev/null < "$CALT" | tr -d ' ')"
# Whether the calendar closes is a property of the calendar. A closing tag
# somewhere in the reply said nothing about the table being read here.
cal_closed=0
grep -q '</table>' "$CALT" 2>/dev/null && cal_closed=1
# Drop whatever follows the calendar's own closing tag, so what is counted below
# is inside it.
sed -i 's|</table>.*||' "$CALT" 2>/dev/null
cal_tag="$(grep -o '<table[^>]*>' "$CALT" 2>/dev/null | head -1)"
cal_field=0
cal_cont=0
case "$cal_tag" in
*' data-field-name="&quot;open_date&quot;"'*) cal_field=1 ;;
esac
case "$cal_tag" in
*' data-container-name="&quot;date_selector-00001&quot;"'*) cal_cont=1 ;;
esac
# The select anchors of that calendar, and the distinct January days they carry.
# The anchor is part of the pattern because the client binds to anchors: the same
# calendar drawn with buttons passed while holding no select anchor at all.
# Requiring a real January day rules out days numbered 31 to 61, which read as 31
# distinct dates while the day was matched as two digits.
cal_days="$(grep -o '<a data-date-action="select" data-date="01/[0-9][0-9]/2020">' "$CALT" 2>/dev/null | wc -l | tr -d ' ')"
cal_dates="$(grep -oE '<a data-date-action="select" data-date="01/(0[1-9]|[12][0-9]|3[01])/2020">' "$CALT" 2>/dev/null | sort -u | wc -l | tr -d ' ')"
# A status, a byte count and one marker do not say a calendar arrived. A body
# cut off part way through still carries the opening tag, and curl reports HTTP
# 200 for a reply whose transfer then failed, so its exit status is part of the
# answer. What is asserted is text. One table carries the class, it closes, its
# own tag names the field and the container that were asked for, and inside it
# are 31 select anchors carrying the 31 distinct days of January 2020: that rules
# out a prefix of a calendar, a calendar for another month or another field,
# anchors that all select the same day, invented days, a second calendar beside
# the right one, and a page that merely mentions the class. The container is
# checked because the client reads it to navigate and to close. What none of it
# shows is that the calendar WORKS in a browser -- that needs a client test,
# which this suite does not have.
#
# These patterns are written for the markup the bundled plugin emits, and they
# are strict about its spelling: double quotes, &quot; around the two JSON
# values, single spaces between class tokens, and data-date-action immediately
# before data-date in the anchor. A site that overrides
# template_plugins/date_selector.php may spell the same calendar with single
# quotes, numeric entities, a tab between class tokens or the anchor's two
# attributes the other way round; each of those is a working calendar that this
# check reports as a failure, and would have to update it.
if [ "$cal_curl" != 0 ]; then
	bad "date_selector-server.php could not be read for a LEGITIMATE field (curl exit $cal_curl), so this run says nothing about it"
elif [ "$code" = 200 ] && [ "$cal_count" = 1 ] && [ "$cal_closed" = 1 ] \
	&& [ "$cal_days" = 31 ] && [ "$cal_dates" = 31 ] \
	&& [ "$cal_field" = 1 ] && [ "$cal_cont" = 1 ]; then
	ok "date_selector-server.php renders one calendar, tagged with the field and the container that were asked for, holding the 31 days of January 2020 as select anchors ($size bytes)"
else
	bad "date_selector-server.php did not render January 2020 for a LEGITIMATE field (status $code, $size bytes, $cal_count tables carrying the calendar class, closed $cal_closed, $cal_days select anchors, $cal_dates distinct January dates, field in the calendar tag $cal_field, container in it $cal_cont, tag ${cal_tag:-absent})"
fi
rm -f "$CALT"

# 8e. reports/index.php filters the list by the per-report permission. The admin
# must still see reports; an empty list here is the over-enforcement failure.
code="$(curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" -w '%{http_code}' \
	"$OCM_URL/reports/")"
if [ "$code" = 200 ] && ! grep -q 'not authorized to run any reports' "$BODY"; then
	ok "reports/index.php still lists reports for a permitted user"
else
	bad "reports/index.php listed NOTHING for the admin (status $code)"
fi

# 8e2. Every shipped report has to open on a stock database. Eleven of them read
# `cases` columns, a pb_attorneys column, the pension_plans table or menu_*
# lookups that only a program doing pension counselling has, and no install or
# upgrade script creates any of it. The SELECT failed, and the trigger_error()
# after it halts the request, so the report was a blank HTTP 500.
# pika_report_require_schema() now asks the database first and explains instead.
# A twelfth, lsc_gap, failed for a different reason: MariaDB rejects WITH ROLLUP
# combined with ORDER BY. This walks every report directory, so a new report
# that cannot open on the schema this project installs is caught too.
for rpt_dir in "${REPO_DIR}"/cms/reports/*/report.php; do
	[ -f "$rpt_dir" ] || continue
	rpt="$(basename "$(dirname "$rpt_dir")")"
	code="$(curl -sL --max-time 60 -b "$COOKIES" -o "$BODY" -w '%{http_code}' \
		-X POST \
		-d "report_format=html" \
		-d "date_start=01/01/2000" -d "date_end=12/31/2030" \
		-d "report_output=1" \
		-d "close_date_begin=01/01/2000" -d "close_date_end=12/31/2030" \
		-d "open_date_begin=01/01/2000" -d "open_date_end=12/31/2030" \
		"$OCM_URL/reports/$rpt/report.php")"
	if [ "$code" = 500 ]; then
		bad "REPORT $rpt RETURNED HTTP 500 ON A STOCK DATABASE"
	elif grep -qi "Unknown column\|Unknown table" "$BODY"; then
		bad "REPORT $rpt LEAKED A MISSING-SCHEMA SQL ERROR TO THE PAGE"
	else
		ok "report $rpt opens on a stock database (status $code)"
	fi
done

# 8f. The branded error documents. A 404 has to be the project's page, not
# Apache's, and it must not carry the server version or echo the path back.
ROOT_URL="${OCM_URL%/cms}"
code="$(curl -s --max-time 30 -o "$BODY" -w '%{http_code}' \
	"$OCM_URL/no-such-page-smoke-test.php")"
if [ "$code" = 404 ] && grep -q 'Error 404' "$BODY"; then
	ok "a missing page gets the branded 404"
else
	bad "a missing page did not get the branded 404 (status $code, $(wc -c < "$BODY") bytes)"
fi
if grep -qE 'Apache/[0-9]|no-such-page-smoke-test' "$BODY"; then
	bad "the 404 page leaks the server version or echoes the requested path"
else
	ok "the 404 page names neither the server version nor the requested path"
fi

code="$(curl -s --max-time 30 -o "$BODY" -w '%{http_code}' "$ROOT_URL/errors/error.css")"
if [ "$code" = 200 ] && grep -q 'ocm-err-card' "$BODY"; then
	ok "the error stylesheet is served"
else
	bad "the error stylesheet is NOT served (status $code) — the pages render unstyled"
fi

# The config directory is denied (section 5), so it is also the handiest probe
# for the 403 document.
code="$(curl -s --max-time 30 -o "$BODY" -w '%{http_code}' "$ROOT_URL/cms-custom/")"
if [ "$code" = 403 ] && grep -q 'Error 403' "$BODY"; then
	ok "a denied path gets the branded 403"
else
	bad "a denied path did not get the branded 403 (status $code, $(wc -c < "$BODY") bytes)"
fi

# 8g. The upload refusals in 8a and 8b are on the record, and the two reasons
# are distinguishable: one is someone probing an unknown type, the other is a
# stale case link.
if [ "$HAVE_DB" = 1 ]; then
	for want in unsupported_doc_type unknown_case; do
		n="$(adb "SELECT COUNT(*) FROM audit_log WHERE action='document.upload.denied' AND details LIKE '%\"reason\":\"${want}\"%'")"
		if [ "${n:-0}" -ge 1 ]; then
			ok "audit_log recorded document.upload.denied with reason=${want}"
		else
			bad "audit_log has no document.upload.denied row with reason=${want}"
		fi
	done
else
	printf '  skip upload-gate database checks (needs a running docker compose stack)\n'
fi


# ── 9. The intake permission on unassigned cases ───────────────────────────
# pika_authorize() used to grant read_case AND edit_case to every
# authenticated user for any case with a NULL user_id or a NULL office. That
# grant now requires groups.intake.
#
# Everything above this point runs as the admin, who is in the `system` group
# and short-circuits pika_authorize() to true on its first line -- so nothing
# above can test authorization at all. This section makes a throwaway group
# with no permissions, a throwaway user in it, and one unassigned case, and
# checks both directions: refused without the flag, allowed with it. All three
# rows are removed at the end whether the assertions pass or fail.
if [ "$HAVE_DB" = 1 ]; then
	if [ -n "$(adb "SHOW COLUMNS FROM \`groups\` LIKE 'intake'")" ]; then
		ok "groups.intake column exists"
	else
		bad "groups.intake column is MISSING (add_groups_intake.sql did not run)"
	fi

	SMOKE_GROUP='zz_smoke_grp'
	SMOKE_USER='zz_smoke_user'
	SMOKE_PASS='zz-smoke-Passw0rd'
	SMOKE_JAR="$(mktemp)"

	cleanup_intake() {
		adb "DELETE FROM cases WHERE number = 'ZZ-SMOKE-1'" >/dev/null
		adb "DELETE FROM users WHERE username = '${SMOKE_USER}'" >/dev/null
		adb "DELETE FROM \`groups\` WHERE group_id = '${SMOKE_GROUP}'" >/dev/null
		rm -f "$SMOKE_JAR"
	}
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_intake' EXIT

	# Start from a clean slate in case an earlier interrupted run left rows.
	cleanup_intake

	# A group with nothing: no read_all, no edit_all, no offices, no reports,
	# no intake. Under the old code this group could still read and edit every
	# unassigned case in the system.
	adb "INSERT INTO \`groups\` (group_id, read_office, read_all, edit_office, edit_all, users, pba, motd, intake, reports)
		VALUES ('${SMOKE_GROUP}', NULL, 0, NULL, 0, 0, 0, 0, 0, NULL)" >/dev/null

	# The hash is generated by the application's own PHP so it matches whatever
	# algorithm password_hash() defaults to in this image.
	SMOKE_HASH="$(docker compose "${COMPOSE_ARGS[@]}" exec -T app \
		php -r 'echo password_hash($argv[1], PASSWORD_DEFAULT);' "$SMOKE_PASS" </dev/null 2>/dev/null)"
	SMOKE_UID="$(adb "SELECT COALESCE(MAX(user_id), 0) + 1 FROM users")"
	adb "INSERT INTO users (user_id, username, password, enabled, group_id, password_expire)
		VALUES (${SMOKE_UID}, '${SMOKE_USER}', '${SMOKE_HASH}', 1, '${SMOKE_GROUP}', 0)" >/dev/null

	# The case the old grant handed out: no handler, no office.
	SMOKE_CASE="$(adb "SELECT COALESCE(MAX(case_id), 0) + 1 FROM cases")"
	adb "INSERT INTO cases (case_id, number, user_id, office, status)
		VALUES (${SMOKE_CASE}, 'ZZ-SMOKE-1', NULL, NULL, '1')" >/dev/null

	if [ -z "$SMOKE_HASH" ] || [ -z "${SMOKE_UID:-}" ] || [ -z "${SMOKE_CASE:-}" ]; then
		bad "could not seed the intake fixtures (hash/user/case)"
	else
		# Same POST the suite's own login uses: login_user / login_pass /
		# auth_id. A fresh jar each time, because the only thing that
		# survives a request in this application is $_SESSION['SID'].
		smoke_login_asuser() {
			: > "$SMOKE_JAR"
			curl -sL --max-time 30 -c "$SMOKE_JAR" -b "$SMOKE_JAR" -o "$BODY" \
				-X POST -d "login_user=${SMOKE_USER}&login_pass=${SMOKE_PASS}&auth_id=1" \
				"$OCM_URL/" >/dev/null
		}

		smoke_login_asuser
		if grep -q 'login_pass' "$BODY"; then
			bad "the throwaway intake user could not log in - the rest of section 9 is untested"
		else
			ok "the throwaway no-permission user can log in"

			# 9a. Refused with intake = 0. This is the vulnerability.
			curl -sL --max-time 30 -b "$SMOKE_JAR" -o "$BODY" \
				"$OCM_URL/case.php?case_id=${SMOKE_CASE}" >/dev/null
			if grep -q 'This case is not viewable' "$BODY"; then
				ok "an unassigned case is NOT readable without the intake flag"
			elif grep -q 'ZZ-SMOKE-1' "$BODY"; then
				bad "AN UNASSIGNED CASE IS READABLE BY A USER WITH NO PERMISSIONS (CWE-639)"
			else
				bad "case.php gave neither the case nor the refusal ($(wc -c < "$BODY") bytes)"
			fi

			# 9b. Allowed with intake = 1. A flag that refuses in both states
			# would pass 9a while breaking every intake worker, so the accept
			# case has to be checked too.
			adb "UPDATE \`groups\` SET intake = 1 WHERE group_id = '${SMOKE_GROUP}'" >/dev/null
			smoke_login_asuser
			curl -sL --max-time 30 -b "$SMOKE_JAR" -o "$BODY" \
				"$OCM_URL/case.php?case_id=${SMOKE_CASE}" >/dev/null
			if grep -q 'ZZ-SMOKE-1' "$BODY"; then
				ok "the intake flag grants the unassigned case back"
			else
				bad "the intake flag did NOT grant the case (status page $(wc -c < "$BODY") bytes)"
			fi

			# 9c. The flag is scoped to unassigned cases. Point the same case
			# at a different handler and an office; an intake user must lose
			# it, or `intake` is just read_all under another name.
			adb "UPDATE cases SET user_id = 1, office = 'zzz' WHERE case_id = ${SMOKE_CASE}" >/dev/null
			curl -sL --max-time 30 -b "$SMOKE_JAR" -o "$BODY" \
				"$OCM_URL/case.php?case_id=${SMOKE_CASE}" >/dev/null
			if grep -q 'This case is not viewable' "$BODY"; then
				ok "the intake flag does not reach a case that has a handler and an office"
			else
				bad "THE INTAKE FLAG READS AN ASSIGNED CASE OUTSIDE THE GROUP'S OFFICES"
			fi
		fi
	fi

	cleanup_intake
	trap 'rm -f "$COOKIES" "$BODY"' EXIT
else
	printf '  skip intake permission checks (needs a running docker compose stack)\n'
fi


# ── 9B. The per-report permission reaches a real group ─────────────────
# 8e above only proves the admin sees reports, and the admin is in the `system`
# group, which pika_report_authorize() short-circuits to true on its first
# line. So 8e passes no matter what the permission does, and it did: the list
# was keyed by report directory name, pikaMisc::reportList() ended with sort(),
# and sort() throws the keys away and reindexes from 0. A group granted one
# report by name then matched nothing and saw the refusal, while the group
# editor offered the sort positions as its checkbox values, so a grant saved
# there pointed at a position rather than a report.
#
# This checks the permission the way a deployment uses it: a throwaway group
# with one report named in groups.reports, a throwaway user in it, and the
# listing that user actually gets. Both rows are removed at the end whether
# the assertions pass or fail.
if [ "$HAVE_DB" = 1 ] && [ "$HAVE_COMPOSE" = 1 ]; then
	RGROUP='zz_rpt_grp'
	RUSER='zz_rpt_user'
	RPASS='zz-rpt-Passw0rd'
	RJAR="$(mktemp)"
	RREPORT='megareport'

	cleanup_rpt() {
		adb "DELETE FROM users WHERE username = '${RUSER}'" >/dev/null
		adb "DELETE FROM \`groups\` WHERE group_id = '${RGROUP}'" >/dev/null
		rm -f "$RJAR"
	}
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_rpt' EXIT
	cleanup_rpt

	# read_all/edit_all so nothing else refuses the page first. The only
	# thing under test here is groups.reports.
	adb "INSERT INTO \`groups\` (group_id, read_office, read_all, edit_office, edit_all, users, pba, motd, reports)
		VALUES ('${RGROUP}', NULL, 1, NULL, 1, 0, 0, 0, '${RREPORT}')" >/dev/null
	RHASH="$(docker compose "${COMPOSE_ARGS[@]}" exec -T app \
		php -r 'echo password_hash($argv[1], PASSWORD_DEFAULT);' "$RPASS" </dev/null 2>/dev/null)"
	RUID="$(adb "SELECT COALESCE(MAX(user_id), 0) + 1 FROM users")"
	adb "INSERT INTO users (user_id, username, password, enabled, group_id, password_expire)
		VALUES (${RUID}, '${RUSER}', '${RHASH}', 1, '${RGROUP}', 0)" >/dev/null

	if [ -z "$RHASH" ] || [ -z "${RUID:-}" ]; then
		bad "could not seed the report permission fixtures (hash/user)"
	else
		: > "$RJAR"
		curl -sL --max-time 30 -c "$RJAR" -b "$RJAR" -o "$BODY" \
			-X POST -d "login_user=${RUSER}&login_pass=${RPASS}&auth_id=1" \
			"$OCM_URL/" >/dev/null
		if grep -q 'login_pass' "$BODY"; then
			bad "the throwaway report user could not log in - section 9B is untested"
		else
			ok "the throwaway report user can log in"

			curl -sL --max-time 30 -b "$RJAR" -o "$BODY" "$OCM_URL/reports/" >/dev/null
			if grep -q 'not authorized to run any reports' "$BODY"; then
				bad "A GROUP GRANTED ${RREPORT} BY NAME WAS DENIED EVERY REPORT (reportList() lost its keys)"
			elif grep -q "${RREPORT}" "$BODY"; then
				ok "a group granted ${RREPORT} by name gets it"
			else
				bad "reports/index.php gave neither ${RREPORT} nor the refusal ($(wc -c < "$BODY") bytes)"
			fi

			# ...and only that one. A list that ignores the grant in the
			# other direction would pass the check above.
			if grep -q 'reports/demographics/' "$BODY"; then
				bad "THE REPORT LIST INCLUDED A REPORT THE GROUP WAS NOT GRANTED"
			else
				ok "the report list leaves out a report the group was not granted"
			fi

			# The group editor's checkbox values are what an administrator
			# saves into groups.reports, so they have to be report names.
			# Integers here mean a grant points at a sort position.
			curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" \
				"$OCM_URL/system-groups.php?action=add" >/dev/null
			ropts="$(grep -oE '<option[^>]*value="[A-Za-z0-9_-]+"' "$BODY" \
				| sed -e 's/.*value="//' -e 's/"$//' | sort -u)"
			if printf '%s\n' "$ropts" | grep -qx "$RREPORT"; then
				ok "the group editor offers report names as its option values"
			else
				bad "THE GROUP EDITOR DOES NOT OFFER ${RREPORT} AS AN OPTION VALUE (keys lost)"
			fi
		fi
	fi

	cleanup_rpt
	trap 'rm -f "$COOKIES" "$BODY"' EXIT
else
	printf '  skip report permission checks (needs a running docker compose stack)\n'
fi


# ── 10. SQL injection through the list sort and calendar filters ───────────
# The list builders interpolated ?order_field= and ?order= straight into
# ORDER BY, and pikaCms::fetchActivitiesCaseClient() interpolated the calendar
# filter values into WHERE. pl_grab_var() lets a single quote through, so
# cal_week.php?user_id=office_' OR 1=1 -- was a working injection.
#
# What is checked: the payload page still renders as a page (so the fix did
# not just replace an injection with a broken query), it is not the Pika Error
# page (a MySQL syntax error lands there), and a legitimate sort still works.
# The rejection is then confirmed in the application log, which is the only
# positive proof that the allowlist ran rather than the payload being harmless
# by accident.

# A payload that MySQL would accept, and one it would choke on. The first
# would have leaked; the second would have produced the error page.
sqli_probe() {
	# $1 label, $2 url (already encoded)
	curl -sL --max-time 60 -b "$COOKIES" -o "$BODY" "$OCM_URL/$2" >/dev/null
	size="$(wc -c < "$BODY")"
	if [ "$size" -lt 500 ]; then
		bad "$1: only $size bytes (PHP fatal?)"
	elif grep -q 'Pika Error' "$BODY"; then
		bad "$1: the payload reached MySQL and errored (Pika Error page)"
	elif grep -qiE 'You have an error in your SQL syntax|SQLSTATE|check the manual that corresponds to your (MariaDB|MySQL)' "$BODY"; then
		bad "$1: SQL error text in the body"
	elif grep -q 'login_pass' "$BODY"; then
		bad "$1: bounced to the login form"
	else
		ok "$1 ($size bytes)"
	fi
}

sqli_probe "case list survives an ORDER BY subquery payload" \
	"case_list.php?order_field=%28SELECT+1%29&order=ASC"
sqli_probe "case list survives an unbalanced ORDER BY payload" \
	"case_list.php?order_field=open_date%29--+&order=ASC"
sqli_probe "user list survives a payload in the sort DIRECTION" \
	"system-users.php?order_field=user_id&order=ASC%2C%28SELECT+1%29"
sqli_probe "activity search survives an ORDER BY payload" \
	"search.php?m=A&s=zzzz&order_field=%28SELECT+1%29"
sqli_probe "the weekly calendar survives a quote in the office filter" \
	"cal_week.php?user_id=office_%27+OR+1%3D1+--+"
sqli_probe "the weekly calendar survives a UNION in user_id" \
	"cal_week.php?user_id=1%27+UNION+SELECT+password+FROM+users+--+"

# The positive control: a real sort column must still sort, or the allowlist
# has broken the feature it is protecting.
sqli_probe "a legitimate sort column still renders the case list" \
	"case_list.php?order_field=open_date&order=DESC"
sqli_probe "a legitimate dotted sort column still renders the case list" \
	"case_list.php?order_field=contacts.last_name&order=ASC"

# The allowlist logs every rejection. Without this the probes above would also
# pass on a build where the payload simply happened not to break anything.
if [ "$HAVE_COMPOSE" = 1 ]; then
	# Collect the log first, then search it. Piping straight into `grep -q`
	# makes this check flaky: grep exits on the first match, `docker compose
	# logs` then dies of SIGPIPE with 141, and `set -o pipefail` reports the
	# whole pipeline as failed even though the pattern WAS found. It only
	# shows up once the log is long enough for grep to win the race.
	APPLOG="$(mktemp)"
	docker compose "${COMPOSE_ARGS[@]}" logs app >"$APPLOG" 2>/dev/null
	
	if grep -q 'invalid SQL identifier rejected by allowlist' "$APPLOG"; then
		ok "the identifier allowlist logged the rejected sort columns"
	else
		bad "no allowlist rejection in the app log - pl_safe_order_by() did not run"
	fi
	
	# Every audited action above wrote a row. mysqli's get_result() returns
	# false for a statement with no result set, so DB::preparedQuery() used to
	# report every successful INSERT as a failure and pl_audit() logged it --
	# an error log that said auditing was broken on a deployment where it was
	# working.
	if grep -q 'pl_audit insert failed' "$APPLOG"; then
		bad "the app log claims audit inserts failed for rows that were written"
	else
		ok "audit inserts are not reported as failures"
	fi
	
	rm -f "$APPLOG"
else
	printf '  skip allowlist log check (needs a running docker compose stack)\n'
fi


# ── 11. The free-text search is scoped to readable cases ───────────────────
# pikaMisc::getActivitiesByText() and pikaDocument::getDocumentsByText() query
# every row on the box: neither has an office or ownership predicate. search.php
# used to print whatever came back, so the search box handed any user who could
# log in the activity summaries and document names of every case in every
# office. Both loops now drop rows that fail pl_case_readable().
#
# The fixture is a case that belongs to somebody else, in an office the
# throwaway group cannot read, with one activity and one document carrying a
# token that nothing else in the database contains.
if [ "$HAVE_DB" = 1 ]; then
	SGROUP='zz_smoke_grp2'
	SUSER='zz_smoke_user2'
	SPASS='zz-smoke-Passw0rd2'
	STOKEN='zzsmoketoken'
	SJAR="$(mktemp)"

	cleanup_search() {
		adb "DELETE FROM activities WHERE summary LIKE '%${STOKEN}%'" >/dev/null
		adb "DELETE FROM doc_storage WHERE doc_name LIKE '%${STOKEN}%'" >/dev/null
		adb "DELETE FROM cases WHERE number = 'ZZ-SMOKE-2'" >/dev/null
		adb "DELETE FROM users WHERE username = '${SUSER}'" >/dev/null
		adb "DELETE FROM \`groups\` WHERE group_id = '${SGROUP}'" >/dev/null
		rm -f "$SJAR"
	}
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_search' EXIT
	cleanup_search

	# No read_all, no offices, no intake: this group may read nothing at all.
	adb "INSERT INTO \`groups\` (group_id, read_office, read_all, edit_office, edit_all, users, pba, motd, intake, reports)
		VALUES ('${SGROUP}', NULL, 0, NULL, 0, 0, 0, 0, 0, NULL)" >/dev/null

	SHASH="$(docker compose "${COMPOSE_ARGS[@]}" exec -T app \
		php -r 'echo password_hash($argv[1], PASSWORD_DEFAULT);' "$SPASS" </dev/null 2>/dev/null)"
	SUID="$(adb "SELECT COALESCE(MAX(user_id), 0) + 1 FROM users")"
	adb "INSERT INTO users (user_id, username, password, enabled, group_id, password_expire)
		VALUES (${SUID}, '${SUSER}', '${SHASH}', 1, '${SGROUP}', 0)" >/dev/null

	# Somebody else's case, in an office this group has no claim on.
	SCASE="$(adb "SELECT COALESCE(MAX(case_id), 0) + 1 FROM cases")"
	adb "INSERT INTO cases (case_id, number, user_id, office, status)
		VALUES (${SCASE}, 'ZZ-SMOKE-2', 1, 'zzz', '1')" >/dev/null

	SACT="$(adb "SELECT COALESCE(MAX(act_id), 0) + 1 FROM activities")"
	adb "INSERT INTO activities (act_id, case_id, user_id, act_date, act_type, completed, summary, notes)
		VALUES (${SACT}, ${SCASE}, 1, CURDATE(), 'A', 0, '${STOKEN} summary', '${STOKEN} notes')" >/dev/null

	# getDocumentsByText() only looks at loose case documents.
	SDOC="$(adb "SELECT COALESCE(MAX(doc_id), 0) + 1 FROM doc_storage")"
	adb "INSERT INTO doc_storage (doc_id, doc_name, doc_type, description, created, case_id, user_id, folder)
		VALUES (${SDOC}, '${STOKEN}.txt', 'C', '${STOKEN} description', CURDATE(), ${SCASE}, 1, 0)" >/dev/null

	if [ -z "$SHASH" ] || [ -z "${SUID:-}" ] || [ -z "${SCASE:-}" ]; then
		bad "could not seed the search-scoping fixtures"
	else
		# 11a. Positive control. The admin is in the `system` group, so if the
		# admin cannot see the fixture the test proves nothing about scoping.
		for mode in A D; do
			curl -sL --max-time 60 -b "$COOKIES" -o "$BODY" \
				"$OCM_URL/search.php?m=${mode}&s=${STOKEN}" >/dev/null
			if grep -q 'ZZ-SMOKE-2' "$BODY"; then
				ok "the admin's search finds the fixture (mode ${mode})"
			else
				bad "the admin's search does NOT find the fixture (mode ${mode}) - 11b proves nothing"
			fi
		done

		: > "$SJAR"
		curl -sL --max-time 30 -c "$SJAR" -b "$SJAR" -o "$BODY" \
			-X POST -d "login_user=${SUSER}&login_pass=${SPASS}&auth_id=1" \
			"$OCM_URL/" >/dev/null
		if grep -q 'login_pass' "$BODY"; then
			bad "the throwaway search user could not log in - the rest of section 11 is untested"
		else
			ok "the throwaway search user can log in"

			# 11b. The leak. A user with no read permission at all must get
			# neither the activity nor the document.
			for mode in A D; do
				curl -sL --max-time 60 -b "$SJAR" -o "$BODY" \
					"$OCM_URL/search.php?m=${mode}&s=${STOKEN}" >/dev/null
				if grep -q 'ZZ-SMOKE-2' "$BODY"; then
					bad "SEARCH LEAKS ANOTHER OFFICE'S CASE TO A USER WITH NO PERMISSIONS (mode ${mode})"
				elif grep -q "$STOKEN" "$BODY"; then
					# The search box echoes the term back, which is fine; the
					# case number and the document name are what must be gone.
					if grep -qE "${STOKEN}\.txt|${STOKEN} summary|${STOKEN} description" "$BODY"; then
						bad "SEARCH LEAKS THE MATCHED ROW ITSELF TO A USER WITH NO PERMISSIONS (mode ${mode})"
					else
						ok "search shows no unreadable case (mode ${mode}, term echoed only)"
					fi
				else
					ok "search shows no unreadable case (mode ${mode})"
				fi
			done
		fi
	fi

	cleanup_search
	trap 'rm -f "$COOKIES" "$BODY"' EXIT
else
	printf '  skip search scoping checks (needs a running docker compose stack)\n'
fi


# ── 12. The calendar user_id is reflected ──────────────────────────────────
# cal_week.php and cal_day.php echoed ?user_id= into a dozen single-quoted
# hrefs, an <img src> and an RSS <link>. pl_grab_var() encodes < and > but not
# quotes, so a quote broke out of the attribute. Both pages now check the shape
# of the value and fall back to the current user, so nothing is echoed back.
for probe in \
	"cal_week.php|%27+onmouseover%3Dalert%281%29+x%3D%27|onmouseover=alert(1)" \
	"cal_day.php|%27+onmouseover%3Dalert%281%29+x%3D%27|onmouseover=alert(1)" \
	"cal_week.php|zzunexpected|zzunexpected" \
	"cal_day.php|zzunexpected|zzunexpected" \
	; do
	page="${probe%%|*}"
	rest="${probe#*|}"
	payload="${rest%%|*}"
	marker="${rest#*|}"
	curl -sL --max-time 60 -b "$COOKIES" -o "$BODY" \
		"$OCM_URL/$page?user_id=$payload" >/dev/null
	size="$(wc -c < "$BODY")"
	if [ "$size" -lt 500 ]; then
		bad "$page with a bad user_id: only $size bytes"
	elif grep -qF "$marker" "$BODY"; then
		bad "$page REFLECTS an unvalidated user_id back into the page ($marker)"
	else
		ok "$page does not reflect a bad user_id ($size bytes)"
	fi
done

# The office view is the reason the value cannot simply be cast to (int): the
# private build did that and silently broke its own office calendar filter.
curl -sL --max-time 60 -b "$COOKIES" -o "$BODY" \
	"$OCM_URL/cal_week.php?user_id=office_zzz" >/dev/null
if grep -qF 'user_id=office_zzz' "$BODY"; then
	ok "the weekly calendar still keeps an office filter"
else
	bad "the office calendar filter was dropped by the user_id shape check"
fi

# And a plain user id still drives the day view.
curl -sL --max-time 60 -b "$COOKIES" -o "$BODY" \
	"$OCM_URL/cal_day.php?user_id=1" >/dev/null
if [ "$(wc -c < "$BODY")" -ge 500 ] && grep -qF 'user_id=1' "$BODY"; then
	ok "the day calendar still accepts a numeric user id"
else
	bad "a numeric user id no longer reaches the day calendar"
fi


# 13. The server-side tree is not served.
#
# cms/app/ holds the library classes, the SQL schema and the maintenance
# scripts. Every .php file in it used to be a URL, and the scripts under
# app/scripts/ do their work at top level with no authentication check because
# they were written for cron and a shell prompt.
echo
echo "13. cms/app is not reachable over HTTP"

for path in \
	app/scripts/checksum.php \
	app/scripts/fs2db.php \
	app/scripts/forms2db.php \
	app/lib/pl.php \
	app/lib/DB.php \
	app/extralib/lib/pikaCms.php \
	app/sql/install/new_install.sql \
	app/ \
	; do
	code="$(curl -s --max-time 30 -o "$BODY" -w '%{http_code}' "$OCM_URL/$path")"
	if [ "$code" = 403 ]; then
		ok "/cms/$path is refused (403)"
	else
		bad "/cms/$path answered $code, not 403 ($(wc -c < "$BODY") bytes)"
	fi
done

# The refusal must be the branded document, not Apache's, and it must not name
# the path it just refused.
code="$(curl -s --max-time 30 -o "$BODY" -w '%{http_code}' \
	"$OCM_URL/app/scripts/checksum.php")"
if [ "$code" = 403 ] && grep -q 'Error 403' "$BODY"; then
	ok "a denied cms/app path gets the branded 403"
else
	bad "a denied cms/app path did not get the branded 403 (status $code)"
fi
if grep -qE 'Apache/[0-9]|checksum\.php' "$BODY"; then
	bad "the cms/app 403 leaks the server version or echoes the script name"
else
	ok "the cms/app 403 names neither the server version nor the script"
fi

# Second lock. The Apache rule is one line in one vhost; the scripts also refuse
# a non-CLI SAPI themselves, so they stay safe behind a vhost that lacks it.
# This image has no CGI SAPI to drive them through, so the check is that the
# guard is in every script rather than that it fires.
scripts_root="$(cd "$(dirname "$0")/.." && pwd)/cms/app/scripts"
if [ -d "$scripts_root" ]; then
	missing=""
	for f in "$scripts_root"/*.php; do
		[ -e "$f" ] || continue
		if ! grep -q "PHP_SAPI !== 'cli'" "$f"; then
			missing="$missing $(basename "$f")"
		fi
	done
	if [ -z "$missing" ]; then
		ok "every script in cms/app/scripts refuses a non-CLI SAPI"
	else
		bad "no CLI-only guard in cms/app/scripts:$missing"
	fi
else
	bad "cms/app/scripts not found at $scripts_root - CLI guards unchecked"
fi

# The application itself still works. A deny rule on a parent path is easy to
# write too wide.
curl -sL --max-time 60 -b "$COOKIES" -o "$BODY" "$OCM_URL/case_list.php" >/dev/null
if [ "$(wc -c < "$BODY")" -ge 500 ] && ! grep -qF 'Pika Error' "$BODY"; then
	ok "the case list still renders with cms/app denied ($(wc -c < "$BODY") bytes)"
else
	bad "the case list broke when cms/app was denied ($(wc -c < "$BODY") bytes)"
fi

# 14. A request cannot choose the primary key of a row it creates.
#
# plBase::__construct(null) takes the new row's id from the counters table and
# stores it in $this->values. setValues() then walks the request array and
# writes every key that matches a column, so a request carrying case_id or
# contact_id used to overwrite the id that was just allocated. Pick an id just
# above the counter and the next legitimate intake is the request that fails.
echo
echo "14. mass assignment on the case and contact insert paths"

# Fetch the token fresh rather than reusing the one from section 7: that one has
# already been spent on a POST, and a single-use scheme would make every
# assertion below pass for the wrong reason.
curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" "$MAINT" >/dev/null
MASS_TOKEN="$(grep -oE 'name="_csrf" value="[0-9a-f]*"' "$BODY" \
	| head -1 | sed -E 's/.*value="([0-9a-f]*)".*/\1/')"

if [ "$HAVE_DB" = 1 ] && [ "${#MASS_TOKEN}" -eq 64 ]; then
	MASS_ID=987654321

	cleanup_mass() {
		mass_case="$(adb "SELECT case_id FROM cases WHERE number LIKE 'ZZMASS%'" | tr '\n' ',' | sed 's/,$//')"
		if [ -n "$mass_case" ]; then
			adb "DELETE FROM conflict WHERE case_id IN ($mass_case)" >/dev/null
		fi
		adb "DELETE FROM cases WHERE number LIKE 'ZZMASS%' OR case_id = $MASS_ID" >/dev/null
		adb "DELETE FROM contacts WHERE last_name LIKE 'ZZMASS%' OR contact_id = $MASS_ID" >/dev/null
		adb "DELETE FROM conflict WHERE contact_id = $MASS_ID OR conflict_id = 88888888" >/dev/null
	}
	cleanup_mass
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_mass' EXIT

	# The eligibility-intake handler creates a case from the query string.
	curl -sL --max-time 60 -b "$COOKIES" -o "$BODY" \
		"$OCM_URL/ops/new_case_no_client.php?screen=elig&number=ZZMASS1&case_id=$MASS_ID" \
		>/dev/null
	planted="$(adb "SELECT COUNT(*) FROM cases WHERE case_id = $MASS_ID")"
	created="$(adb "SELECT COUNT(*) FROM cases WHERE number = 'ZZMASS1'")"
	if [ "${planted:-1}" = 0 ]; then
		ok "a chosen case_id in the query string is ignored"
	else
		bad "A REQUEST PLANTED A CASE AT case_id=$MASS_ID"
	fi
	if [ "${created:-0}" -ge 1 ]; then
		ok "the eligibility intake still creates its case"
	else
		bad "the eligibility intake no longer creates a case — the strip is too wide"
	fi

	# The case-contact handler creates a contact from the POST body. It needs a
	# real case to hang it on, so use the one just created.
	case_id="$(adb "SELECT case_id FROM cases WHERE number = 'ZZMASS1' LIMIT 1")"
	if [ -n "$case_id" ]; then
		curl -s --max-time 60 -b "$COOKIES" -o "$BODY" -X POST \
			-d "_csrf=$MASS_TOKEN" \
			-d "case_id=$case_id" \
			-d 'relation_code=2' \
			-d 'last_name=ZZMASS2' \
			-d 'first_name=Smoke' \
			-d "contact_id=$MASS_ID" \
			"$OCM_URL/ops/add_case_new_contact.php" >/dev/null
		planted="$(adb "SELECT COUNT(*) FROM contacts WHERE contact_id = $MASS_ID")"
		created="$(adb "SELECT COUNT(*) FROM contacts WHERE last_name = 'ZZMASS2'")"
		if [ "${planted:-1}" = 0 ]; then
			ok "a chosen contact_id in the POST body is ignored"
		else
			bad "A REQUEST PLANTED A CONTACT AT contact_id=$MASS_ID"
		fi
		if [ "${created:-0}" -ge 1 ]; then
			ok "the case-contact handler still creates its contact"
		else
			bad "the case-contact handler no longer creates a contact"
		fi

		# relation_code went from the POST body into an unescaped INSERT in
		# pikaCase::addContact(). pl_clean_form_input() encodes only < and >,
		# so the quote arrived intact and the payload below appended a second
		# VALUES tuple: an arbitrary contact attached to an arbitrary case in
		# the conflict table, which is what the conflict-of-interest check
		# reads. This handler redirects and prints nothing, so the assertion
		# has to be on the table, not on the response body.
		curl -s --max-time 60 -b "$COOKIES" -o "$BODY" -X POST \
			-d "_csrf=$MASS_TOKEN" \
			-d "case_id=$case_id" \
			-d "relation_code=2'),('88888888','7','7','9" \
			-d 'last_name=ZZMASS3' \
			-d 'first_name=Smoke' \
			"$OCM_URL/ops/add_case_new_contact.php" >/dev/null
		rogue="$(adb "SELECT COUNT(*) FROM conflict WHERE conflict_id = 88888888")"
		if [ "${rogue:-1}" = 0 ]; then
			ok "a quoted relation_code inserts no rogue conflict row"
		else
			bad "A QUOTED relation_code INSERTED $rogue ROGUE conflict ROW(S)"
		fi
		adb "DELETE FROM conflict WHERE conflict_id = 88888888" >/dev/null

		# Positive control: an ordinary relation_code still links the contact.
		curl -s --max-time 60 -b "$COOKIES" -o "$BODY" -X POST \
			-d "_csrf=$MASS_TOKEN" \
			-d "case_id=$case_id" \
			-d 'relation_code=2' \
			-d 'last_name=ZZMASS4' \
			-d 'first_name=Smoke' \
			"$OCM_URL/ops/add_case_new_contact.php" >/dev/null
		linked="$(adb "SELECT COUNT(*) FROM conflict WHERE case_id = $case_id AND contact_id IN (SELECT contact_id FROM contacts WHERE last_name = 'ZZMASS4')")"
		if [ "${linked:-0}" -ge 1 ]; then
			ok "an ordinary relation_code still links the contact to the case"
		else
			bad "the conflict INSERT no longer links a contact - the escape is too tight"
		fi
	else
		bad "no ZZMASS1 case to hang the contact tests on"
	fi

	cleanup_mass
	trap 'rm -f "$COOKIES" "$BODY"' EXIT
elif [ "$HAVE_DB" = 1 ]; then
	# The database is reachable, so the missing piece is the token itself.
	bad "section 14 could not run: the admin session rendered no CSRF token"
else
	printf '  skip section 14 (needs a running stack and the database)\n'
fi

# ── 15. A template tag typed into a form does not resolve into a secret ────
#
# pl_template_sub() falls back to pl_settings_get_all() for any tag it
# cannot find in the page data, and its last line calls itself on the
# string it just built, so a substituted value is scanned again. Together
# those two made every reflection an oracle for the settings table:
# search.php puts ?s= into $content_t['search_value'] and
# subtemplates/search_screen.html renders it into a value= attribute, so
# GET search.php?s=%%[db_password]%% came back carrying the real database
# password. Escaping does not help - htmlspecialchars() leaves %, [ and ]
# alone.
#
# Both directions are asserted. The block has to hold, and it must not
# blank the admin pages that legitimately render the same labels: those
# put the value into the page data explicitly, so it resolves from the
# template-data branch that runs first.
echo
echo "15. a template tag does not resolve into a settings secret"

# The value to look for is the password this stack actually runs on, so
# the test cannot pass by accident against some placeholder.
SECRET="${DB_PASSWORD:-}"

curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" \
	"$OCM_URL/search.php?s=%25%25%5Bdb_password%5D%25%25" >/dev/null
if [ -s "$BODY" ] && ! grep -q '%%\[db_password\]%%' "$BODY" \
	&& { [ -z "$SECRET" ] || ! grep -qF "$SECRET" "$BODY"; }
then
	ok "a db_password tag in the search box resolves to nothing"
else
	bad "search.php reflected the db_password setting or left the tag intact"
fi

# These three come from cms-custom/config/settings.php, so they always
# hold a value and the check cannot pass by finding nothing there. Each
# one was confirmed to come back in the value= attribute before the fix.
for label in db_host db_user base_directory; do
	curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" \
		"$OCM_URL/search.php?s=%25%25%5B${label}%5D%25%25" >/dev/null
	# The tag renders empty, so the field comes back as value="".
	if grep -q 'name="s" size="48" value=""' "$BODY"; then
		ok "a $label tag in the search box resolves to nothing"
	else
		bad "search.php resolved the $label setting: $(grep -o 'name="s" size="48" value="[^\"]*"' "$BODY" | head -1)"
	fi
done

# The credentials system-sms.php writes live in the settings table and are
# empty on a fresh install, so each one is seeded with a marker first.
# Without that the check passes on an unfixed build by finding nothing to
# leak, which is the failure mode this whole section exists to catch.
if [ "$HAVE_DB" = 1 ]; then
	for label in twilio_auth_token sparkpost_api_key; do
		adb "DELETE FROM settings WHERE label = '$label'" >/dev/null
		adb "INSERT INTO settings (label, value) VALUES ('$label', 'ZZLEAK-$label')" >/dev/null
		curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" \
			"$OCM_URL/search.php?s=%25%25%5B${label}%5D%25%25" >/dev/null
		if grep -q "ZZLEAK-$label" "$BODY"; then
			bad "search.php reflected the configured $label"
		else
			ok "a configured $label is not reflected by search.php"
		fi
		adb "DELETE FROM settings WHERE label = '$label'" >/dev/null
	done
else
	printf '  skip section 15 the credential checks (needs a running stack and the database)\n'
fi

# Positive control on the fallback itself. base_url is resolved through
# it by templates on every page, so blocking too much would blank the
# chrome everywhere.
curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" "$OCM_URL/search.php?s=abcd" >/dev/null
if grep -q "search.php?s=abcd&m=D" "$BODY"; then
	ok "the app-settings fallback still resolves base_url"
else
	bad "base_url no longer resolves - the settings denylist is too wide"
fi

# A blocked label still has to render on the page that configures it.
# system-sms.php assigns each one to $html, so it resolves from the page
# data rather than the fallback.
if [ "$HAVE_DB" = 1 ]; then
	adb "DELETE FROM settings WHERE label = 'twilio_account_sid'" >/dev/null
	adb "INSERT INTO settings (label, value) VALUES ('twilio_account_sid', 'ACzzzSMOKE')" >/dev/null
	curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" "$OCM_URL/system-sms.php" >/dev/null
	if grep -q 'ACzzzSMOKE' "$BODY"; then
		ok "a blocked setting still renders on its own admin page"
	else
		bad "system-sms.php no longer shows twilio_account_sid - the denylist reaches the page data"
	fi
	# And that same value must not come back through a reflection.
	curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" \
		"$OCM_URL/search.php?s=%25%25%5Btwilio_account_sid%5D%25%25" >/dev/null
	if grep -q 'ACzzzSMOKE' "$BODY"; then
		bad "search.php reflected the configured twilio_account_sid"
	else
		ok "a configured twilio_account_sid is not reflected by search.php"
	fi
	adb "DELETE FROM settings WHERE label = 'twilio_account_sid'" >/dev/null
else
	printf '  skip section 15 the admin-page control (needs a running stack and the database)\n'
fi

# The template plugin loader only accepts a PHP identifier, so a
# directive carrying ../ cannot make require_once() leave
# template_plugins/.
templib="$(cd "$(dirname "$0")/.." && pwd)/cms/app/lib/pikaTempLib.php"
if [ -f "$templib" ] && grep -qF "preg_match('/^[A-Za-z_][A-Za-z0-9_]*\\z/'" "$templib"; then
	ok "pikaTempLib::loadModule constrains the plugin name to an identifier"
else
	bad "pikaTempLib::loadModule no longer checks the plugin name"
fi

echo
echo "16. an activity with no owner is not readable by everybody"

# read_act and edit_act used to grant on strlen($row['user_id']) == 0, with the
# comment "should only be PB". An activity gets a blank user_id for reasons that
# have nothing to do with pro bono work -- an import, a row left by a deleted
# user, a row written by an integration -- and each of those became readable and
# editable by every authenticated user, whatever their office scope.
#
# The fixture is a case this group cannot read, holding two activities with no
# staff owner: one with no pba_id (an orphan, must be refused) and one with a
# pba_id (a real pro bono row, must still be allowed).
if [ "$HAVE_DB" = 1 ]; then
	AGROUP='zz_act_grp'
	AUSER='zz_act_user'
	APASS='zz-act-Passw0rd'
	AJAR="$(mktemp)"

	cleanup_act() {
		adb "DELETE FROM activities WHERE notes LIKE 'ZZACT-%'" >/dev/null
		adb "DELETE FROM pb_attorneys WHERE last_name = 'ZZACTPBA'" >/dev/null
		adb "DELETE FROM cases WHERE number = 'ZZ-ACT-1'" >/dev/null
		adb "DELETE FROM users WHERE username = '${AUSER}'" >/dev/null
		adb "DELETE FROM \`groups\` WHERE group_id = '${AGROUP}'" >/dev/null
		rm -f "$AJAR"
	}
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_act' EXIT
	cleanup_act

	adb "INSERT INTO \`groups\` (group_id, read_office, read_all, edit_office, edit_all, users, pba, motd, intake, reports)
		VALUES ('${AGROUP}', NULL, 0, NULL, 0, 0, 0, 0, 0, NULL)" >/dev/null

	AHASH="$(docker compose "${COMPOSE_ARGS[@]}" exec -T app \
		php -r 'echo password_hash($argv[1], PASSWORD_DEFAULT);' "$APASS" </dev/null 2>/dev/null)"
	AUID="$(adb "SELECT COALESCE(MAX(user_id), 0) + 1 FROM users")"
	adb "INSERT INTO users (user_id, username, password, enabled, group_id, password_expire)
		VALUES (${AUID}, '${AUSER}', '${AHASH}', 1, '${AGROUP}', 0)" >/dev/null

	# The case names a handler and an office, so no intake or office grant can
	# reach it either.
	ACASE="$(adb "SELECT COALESCE(MAX(case_id), 0) + 1 FROM cases")"
	adb "INSERT INTO cases (case_id, number, user_id, office, status)
		VALUES (${ACASE}, 'ZZ-ACT-1', 1, 'ZZOFF', '1')" >/dev/null

	AORPHAN="$(adb "SELECT COALESCE(MAX(act_id), 0) + 1 FROM activities")"
	adb "INSERT INTO activities (act_id, case_id, user_id, pba_id, act_date, act_type, completed, summary, notes)
		VALUES (${AORPHAN}, ${ACASE}, NULL, NULL, CURDATE(), 'N', 0, 'ZZACT orphan', 'ZZACT-ORPHAN-SECRET')" >/dev/null

	APBA="$(adb "SELECT COALESCE(MAX(pba_id), 0) + 1 FROM pb_attorneys")"
	adb "INSERT INTO pb_attorneys (pba_id, first_name, last_name, enabled)
		VALUES (${APBA}, 'Zz', 'ZZACTPBA', 1)" >/dev/null

	APB="$(adb "SELECT COALESCE(MAX(act_id), 0) + 1 FROM activities")"
	adb "INSERT INTO activities (act_id, case_id, user_id, pba_id, act_date, act_type, completed, summary, notes)
		VALUES (${APB}, ${ACASE}, NULL, ${APBA}, CURDATE(), 'N', 0, 'ZZACT pro bono', 'ZZACT-PROBONO-OK')" >/dev/null

	if [ -z "$AHASH" ] || [ -z "${AORPHAN:-}" ] || [ -z "${APB:-}" ] || [ -z "${APBA:-}" ]; then
		bad "could not seed the activity authorization fixtures"
	else
		# Positive controls on the fixture itself. activity.php picks the
		# subtemplate section from act_type, so a row with a code that
		# subtemplates/activity.html does not define renders an empty page
		# and every check below would pass without proving anything.
		for pair in "${AORPHAN}:ZZACT-ORPHAN-SECRET" "${APB}:ZZACT-PROBONO-OK"; do
			curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" \
				"$OCM_URL/activity.php?act_id=${pair%%:*}" >/dev/null
			if grep -q "${pair#*:}" "$BODY"; then
				ok "the admin sees the ${pair#*:} fixture"
			else
				bad "the admin does NOT see the ${pair#*:} fixture - section 16 proves nothing"
			fi
		done

		: > "$AJAR"
		curl -sL --max-time 30 -c "$AJAR" -b "$AJAR" -o "$BODY" \
			-X POST -d "login_user=${AUSER}&login_pass=${APASS}&auth_id=1" \
			"$OCM_URL/" >/dev/null
		if grep -q 'login_pass' "$BODY"; then
			bad "the throwaway activity user could not log in - section 16 is untested"
		else
			ok "the throwaway activity user can log in"

			# Positive control on the fixture. If this user could read the case
			# itself then nothing below says anything about read_act.
			curl -sL --max-time 30 -b "$AJAR" -o "$BODY" \
				"$OCM_URL/case.php?case_id=${ACASE}" >/dev/null
			if grep -q 'This case is not viewable' "$BODY"; then
				ok "the fixture case is refused to this user"
			else
				bad "the fixture case is readable by this user - section 16 proves nothing"
			fi

			curl -sL --max-time 30 -b "$AJAR" -o "$BODY" \
				"$OCM_URL/activity.php?act_id=${AORPHAN}" >/dev/null
			if grep -q 'ZZACT-ORPHAN-SECRET' "$BODY"; then
				bad "AN UNOWNED ACTIVITY ON AN UNREADABLE CASE IS READABLE BY A USER WITH NO PERMISSIONS"
			else
				ok "an unowned activity is not readable by a user with no permissions"
			fi

			# And the grant the original comment was actually aiming at still
			# works, so refusing the orphans has not broken pro bono access.
			curl -sL --max-time 30 -b "$AJAR" -o "$BODY" \
				"$OCM_URL/activity.php?act_id=${APB}" >/dev/null
			if grep -q 'ZZACT-PROBONO-OK' "$BODY"; then
				ok "a pro bono activity is still readable"
			else
				bad "a pro bono activity is no longer readable - the fix is too wide"
			fi
		fi
	fi

	cleanup_act
	trap 'rm -f "$COOKIES" "$BODY"' EXIT
else
	printf '  skip activity authorization checks (needs a running docker compose stack)\n'
fi

echo
echo "17. a menu name cannot carry SQL into the table-name position"

# pikaMenu puts $menu_name straight into FROM, and system-menus.php takes it
# off the query string. A table name is not quoted, so DB::escapeString() did
# nothing there. Before the fix this URL printed every user's password hash
# into the menu editor.
MENU_INJ='close_code%20WHERE%201=0%20UNION%20SELECT%20username%20AS%20value,%20password%20AS%20label,%201%20AS%20menu_order%20FROM%20users'
curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" \
	"$OCM_URL/system-menus.php?action=edit_menu&menu_name=${MENU_INJ}" >/dev/null
if grep -q '\$2y\$' "$BODY"; then
	bad "THE MENU EDITOR LEAKS PASSWORD HASHES THROUGH menu_name"
elif grep -q 'Invalid menu name' "$BODY" || grep -q 'Pika Error' "$BODY"; then
	ok "an injected menu name is refused"
else
	bad "an injected menu name neither leaked nor errored - check pikaMenu"
fi

# Quotes survive pl_clean_form_input(), so the same value must not reach an
# HTML attribute either.
curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" \
	"$OCM_URL/system-menus.php?action=edit_menu&menu_name=close_code%22%20onmouseover%3D%22zzXSS()" >/dev/null
if grep -qF 'onmouseover="zzXSS()' "$BODY"; then
	bad "menu_name breaks out of an HTML attribute on system-menus.php"
else
	ok "a quote in menu_name does not reach an HTML attribute"
fi

# Positive control: a real menu still lists its rows, so the allowlist has
# not simply broken the page.
curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" \
	"$OCM_URL/system-menus.php?action=edit_menu&menu_name=close_code" >/dev/null
if grep -q 'menu_name=close_code' "$BODY" && ! grep -q 'Pika Error' "$BODY" \
	&& ! grep -q 'Invalid menu name' "$BODY"; then
	ok "a real menu name still opens in the editor"
else
	bad "the close_code menu no longer opens - the identifier allowlist is too tight"
fi

echo
echo "18. document assembly authorizes the case and the form"

# cms/ops/docgen.php had no pika_authorize call anywhere in it. The case row was
# loaded under the comment "needs security enforcement" and used as-is, and
# form_id was never checked at all, so an authenticated user with no read
# permission on anything could merge any case into a document, and could read
# any stored document verbatim by posting its doc_storage id as form_id.
if [ "$HAVE_DB" = 1 ]; then
	DGROUP='zz_dg_grp'
	DUSER='zz_dg_user'
	DPASS='zz-dg-Passw0rd'
	DJAR="$(mktemp)"

	cleanup_dg() {
		adb "DELETE FROM doc_storage WHERE doc_name LIKE 'ZZDG%'" >/dev/null
		adb "DELETE FROM cases WHERE number IN ('ZZ-DG-SECRET', 'ZZ-DG-MINE')" >/dev/null
		adb "DELETE FROM users WHERE username = '${DUSER}'" >/dev/null
		adb "DELETE FROM \`groups\` WHERE group_id = '${DGROUP}'" >/dev/null
		rm -f "$DJAR"
	}
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_dg' EXIT
	cleanup_dg

	adb "INSERT INTO \`groups\` (group_id, read_office, read_all, edit_office, edit_all, users, pba, motd, intake, reports)
		VALUES ('${DGROUP}', NULL, 0, NULL, 0, 0, 0, 0, 0, NULL)" >/dev/null

	DHASH="$(docker compose "${COMPOSE_ARGS[@]}" exec -T app \
		php -r 'echo password_hash($argv[1], PASSWORD_DEFAULT);' "$DPASS" </dev/null 2>/dev/null)"
	DUID="$(adb "SELECT COALESCE(MAX(user_id), 0) + 1 FROM users")"
	adb "INSERT INTO users (user_id, username, password, enabled, group_id, password_expire)
		VALUES (${DUID}, '${DUSER}', '${DHASH}', 1, '${DGROUP}', 0)" >/dev/null

	# One case this user has no claim on, and one it owns, because the CSRF
	# token has to be read out of a form the user is allowed to load.
	DCASE="$(adb "SELECT COALESCE(MAX(case_id), 0) + 1 FROM cases")"
	adb "INSERT INTO cases (case_id, number, user_id, office, status)
		VALUES (${DCASE}, 'ZZ-DG-SECRET', 1, 'ZZOFF', '1')" >/dev/null
	DMINE="$(adb "SELECT COALESCE(MAX(case_id), 0) + 1 FROM cases")"
	adb "INSERT INTO cases (case_id, number, user_id, office, status)
		VALUES (${DMINE}, 'ZZ-DG-MINE', ${DUID}, 'ZZMINE', '1')" >/dev/null

	# A form template (doc_type F) and a private case document (doc_type C).
	# doc_data is gzcompress()ed binary, so PHP inside the container writes the
	# UPDATE and mariadb reads it back rather than passing it through a shell.
	seed_doc_body() {
		docker compose "${COMPOSE_ARGS[@]}" exec -T app php -r '
			file_put_contents("/tmp/zzsmokedoc.sql",
				"UPDATE doc_storage SET doc_data=\x27"
				. addslashes(gzcompress($argv[2]))
				. "\x27 WHERE doc_id=" . $argv[1] . ";");
		' "$1" "$2" </dev/null
		docker compose "${COMPOSE_ARGS[@]}" exec -T app \
			sh -c 'cat /tmp/zzsmokedoc.sql' </dev/null > "$BODY"
		docker compose "${COMPOSE_ARGS[@]}" exec -T \
			-e MYSQL_PWD="$DB_ROOT_PASSWORD" db \
			mariadb -uroot "$DB_NAME" < "$BODY"
	}

	DFORM="$(adb "SELECT COALESCE(MAX(doc_id), 0) + 1 FROM doc_storage")"
	adb "INSERT INTO doc_storage (doc_id, doc_name, doc_type, description, created, case_id, user_id, folder, mime_type)
		VALUES (${DFORM}, 'ZZDGform.txt', 'F', 'ZZDG form', CURDATE(), NULL, 1, 0, 'text/plain')" >/dev/null
	seed_doc_body "$DFORM" 'ZZDGFORM number=%%[number]%%'

	DDOC="$(adb "SELECT COALESCE(MAX(doc_id), 0) + 1 FROM doc_storage")"
	adb "INSERT INTO doc_storage (doc_id, doc_name, doc_type, description, created, case_id, user_id, folder, mime_type)
		VALUES (${DDOC}, 'ZZDGdoc.txt', 'C', 'ZZDG doc', CURDATE(), ${DCASE}, 1, 0, 'text/plain')" >/dev/null
	seed_doc_body "$DDOC" 'ZZDGDOC-SECRET private case document body'

	if [ -z "$DHASH" ] || [ -z "${DFORM:-}" ] || [ -z "${DDOC:-}" ]; then
		bad "could not seed the document generation fixtures"
	else
		# Positive control. The admin can read every case, so the legitimate
		# path must still merge the case number into the generated document.
		# The docgen form lives on the case Documents tab, which is screen=docs.
		ATOK="$(curl -sL --max-time 30 -b "$COOKIES" \
			"$OCM_URL/case.php?case_id=${DCASE}&screen=docs" \
			| grep -o 'name="_csrf" value="[^"]*"' | head -1 | sed 's/.*value="//;s/"//')"
		curl -s --max-time 60 -b "$COOKIES" -o "$BODY" -X POST \
			-d "_csrf=${ATOK}&case_id=${DCASE}&form_id=${DFORM}" \
			"$OCM_URL/ops/docgen.php" >/dev/null
		if [ "${#ATOK}" -eq 64 ] && grep -q 'ZZ-DG-SECRET' "$BODY"; then
			ok "the admin still generates a document from a form template"
		else
			bad "the admin cannot generate a document - the docgen gate is too tight"
		fi

		: > "$DJAR"
		curl -sL --max-time 30 -c "$DJAR" -b "$DJAR" -o "$BODY" \
			-X POST -d "login_user=${DUSER}&login_pass=${DPASS}&auth_id=1" \
			"$OCM_URL/" >/dev/null
		if grep -q 'login_pass' "$BODY"; then
			bad "the throwaway docgen user could not log in - section 18 is untested"
		else
			ok "the throwaway docgen user can log in"

			# The token has to come from a form this user is allowed to load,
			# or every check below is refused by pl_csrf_check() instead of by
			# the authorization gate and proves nothing.
			DTOK="$(curl -sL --max-time 30 -b "$DJAR" \
				"$OCM_URL/case.php?case_id=${DMINE}&screen=docs" \
				| grep -o 'name="_csrf" value="[^"]*"' | head -1 | sed 's/.*value="//;s/"//')"
			if [ "${#DTOK}" -eq 64 ]; then
				ok "the throwaway docgen user holds a CSRF token"
			else
				bad "no CSRF token for the docgen user - section 18 is untested"
			fi

			curl -s --max-time 60 -b "$DJAR" -o "$BODY" -X POST \
				-d "_csrf=${DTOK}&case_id=${DCASE}&form_id=${DFORM}" \
				"$OCM_URL/ops/docgen.php" >/dev/null
			if grep -q 'ZZ-DG-SECRET' "$BODY"; then
				bad "DOCUMENT ASSEMBLY MERGES A CASE THE USER CANNOT READ"
			else
				ok "document assembly refuses a case the user cannot read"
			fi

			# form_id names a row in doc_storage, and docgen decompresses it and
			# writes it to the response. Only doc_type F belongs there.
			curl -s --max-time 60 -b "$DJAR" -o "$BODY" -X POST \
				-d "_csrf=${DTOK}&case_id=${DMINE}&form_id=${DDOC}" \
				"$OCM_URL/ops/docgen.php" >/dev/null
			if grep -q 'ZZDGDOC-SECRET' "$BODY"; then
				bad "form_id READS AN ARBITRARY STORED DOCUMENT OUT OF doc_storage"
			else
				ok "form_id cannot name a document that is not a form template"
			fi
		fi
	fi

	cleanup_dg
	trap 'rm -f "$COOKIES" "$BODY"' EXIT
else
	printf '  skip document generation checks (needs a running docker compose stack)\n'
fi

echo
echo "19. pro bono assignment authorizes the case and the target column"

# cms/assign_pba.php had no pika_authorize call either. The assign action
# redirects into ops/update_case.php with a case id and a field name taken from
# the query string, so it both stamped an assignment onto any case in the org
# and offered that handler's mass assignment an arbitrary column name.
if [ "$HAVE_DB" = 1 ]; then
	PGROUP='zz_pba_grp'
	PUSER='zz_pba_user'
	PPASS='zz-pba-Passw0rd'
	PJAR="$(mktemp)"

	cleanup_pba() {
		adb "DELETE FROM pb_attorneys WHERE last_name = 'ZZPBAATTY'" >/dev/null
		adb "DELETE FROM cases WHERE number = 'ZZ-PBA-SECRET'" >/dev/null
		adb "DELETE FROM users WHERE username = '${PUSER}'" >/dev/null
		adb "DELETE FROM \`groups\` WHERE group_id = '${PGROUP}'" >/dev/null
		rm -f "$PJAR"
	}
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_pba' EXIT
	cleanup_pba

	# pba = 0 as well, so the bare pro bono directory is out of reach too.
	adb "INSERT INTO \`groups\` (group_id, read_office, read_all, edit_office, edit_all, users, pba, motd, intake, reports)
		VALUES ('${PGROUP}', NULL, 0, NULL, 0, 0, 0, 0, 0, NULL)" >/dev/null

	PHASH="$(docker compose "${COMPOSE_ARGS[@]}" exec -T app \
		php -r 'echo password_hash($argv[1], PASSWORD_DEFAULT);' "$PPASS" </dev/null 2>/dev/null)"
	PUID="$(adb "SELECT COALESCE(MAX(user_id), 0) + 1 FROM users")"
	adb "INSERT INTO users (user_id, username, password, enabled, group_id, password_expire)
		VALUES (${PUID}, '${PUSER}', '${PHASH}', 1, '${PGROUP}', 0)" >/dev/null

	PCASE="$(adb "SELECT COALESCE(MAX(case_id), 0) + 1 FROM cases")"
	adb "INSERT INTO cases (case_id, number, user_id, office, status, pba_id1)
		VALUES (${PCASE}, 'ZZ-PBA-SECRET', 1, 'ZZOFF', '1', NULL)" >/dev/null

	PPBA="$(adb "SELECT COALESCE(MAX(pba_id), 0) + 1 FROM pb_attorneys")"
	adb "INSERT INTO pb_attorneys (pba_id, first_name, last_name, county, enabled)
		VALUES (${PPBA}, 'Zz', 'ZZPBAATTY', 'ZZCOUNTY', 1)" >/dev/null

	if [ -z "$PHASH" ] || [ -z "${PCASE:-}" ] || [ -z "${PPBA:-}" ]; then
		bad "could not seed the pro bono assignment fixtures"
	else
		: > "$PJAR"
		curl -sL --max-time 30 -c "$PJAR" -b "$PJAR" -o "$BODY" \
			-X POST -d "login_user=${PUSER}&login_pass=${PPASS}&auth_id=1" \
			"$OCM_URL/" >/dev/null
		if grep -q 'login_pass' "$BODY"; then
			bad "the throwaway pro bono user could not log in - section 19 is untested"
		else
			ok "the throwaway pro bono user can log in"

			curl -sL --max-time 30 -b "$PJAR" -o "$BODY" \
				"$OCM_URL/assign_pba.php?case_id=${PCASE}&field=pba_id1&screen=pb" >/dev/null
			if grep -q 'ZZPBAATTY' "$BODY"; then
				bad "THE PRO BONO PICKER OPENS ON A CASE THE USER CANNOT EDIT"
			else
				ok "the pro bono picker refuses a case the user cannot edit"
			fi

			curl -s --max-time 30 -b "$PJAR" -o "$BODY" \
				"$OCM_URL/assign_pba.php?action=assign_pba&case_id=${PCASE}&pba_id=${PPBA}&field=pba_id1&screen=pb" >/dev/null
			if [ "$(adb "SELECT COALESCE(pba_id1, 'none') FROM cases WHERE case_id = ${PCASE}")" = 'none' ]; then
				ok "a pro bono attorney cannot be assigned to a case the user cannot edit"
			else
				bad "A PRO BONO ATTORNEY WAS ASSIGNED TO A CASE THE USER CANNOT EDIT"
			fi

			# field named the column update_case.php would write. Only the three
			# pro bono slots belong there.
			curl -s --max-time 30 -b "$PJAR" -o "$BODY" \
				"$OCM_URL/assign_pba.php?action=assign_pba&case_id=${PCASE}&pba_id=${PPBA}&field=user_id&screen=pb" >/dev/null
			if [ "$(adb "SELECT user_id FROM cases WHERE case_id = ${PCASE}")" = '1' ]; then
				ok "field cannot name a case column outside the pro bono slots"
			else
				bad "field REWROTE AN ARBITRARY CASE COLUMN THROUGH update_case.php"
			fi

			# With no case_id it is the plain directory, gated on the group flag.
			curl -sL --max-time 30 -b "$PJAR" -o "$BODY" \
				"$OCM_URL/assign_pba.php" >/dev/null
			if grep -q 'ZZPBAATTY' "$BODY"; then
				bad "the pro bono directory is readable with the pba flag off"
			else
				ok "the pro bono directory is refused with the pba flag off"
			fi
		fi

		# Positive controls. The admin can edit every case, so the picker must
		# still list attorneys and the assignment must still land.
		curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" \
			"$OCM_URL/assign_pba.php?case_id=${PCASE}&field=pba_id1&screen=pb" >/dev/null
		if grep -q 'ZZPBAATTY' "$BODY"; then
			ok "the admin still sees the pro bono picker"
		else
			bad "the admin cannot open the pro bono picker - the gate is too tight"
		fi

		curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" \
			"$OCM_URL/assign_pba.php?action=assign_pba&case_id=${PCASE}&pba_id=${PPBA}&field=pba_id1&screen=pb" >/dev/null
		if [ "$(adb "SELECT COALESCE(pba_id1, 'none') FROM cases WHERE case_id = ${PCASE}")" = "$PPBA" ]; then
			ok "the admin still assigns a pro bono attorney"
		else
			bad "the admin can no longer assign a pro bono attorney - the gate is too tight"
		fi

	fi

	cleanup_pba
	trap 'rm -f "$COOKIES" "$BODY"' EXIT
else
	printf '  skip pro bono assignment checks (needs a running docker compose stack)\n'
fi

echo
echo "20. the template plugin layer escapes what it renders"

# The plugins in cms/template_plugins draw nearly every field in the app and
# most of them interpolated straight into the markup. input_text.php escaped
# nothing at all, so any value carrying a double quote closed value=" and
# grafted its own attributes onto the input. input_textarea.php wrote the body
# raw, so a value carrying "</textarea" closed the field early.
#
# Both checks carry a positive control, because an escaping check passes
# vacuously if the value never reaches the page at all.

# A. Reflected filter value in an attribute. No fixture needed: the pro bono
# directory reflects the county filter back into an input_text.
curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" \
	"$OCM_URL/assign_pba.php?county=zz%22+onmouseover%3D%22zzXSS%28%29" >/dev/null
if grep -qF 'onmouseover="zzXSS()' "$BODY"; then
	bad "A FILTER VALUE BREAKS OUT OF AN ATTRIBUTE AND ADDS AN EVENT HANDLER"
elif grep -qF 'value="zz&quot;' "$BODY"; then
	ok "a double quote in a text field is encoded inside the attribute"
else
	bad "the county filter never reached the page - check A is untested"
fi

curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" \
	"$OCM_URL/assign_pba.php?county=Lancaster" >/dev/null
if grep -qF 'value="Lancaster"' "$BODY"; then
	ok "an ordinary filter value still round-trips unchanged"
else
	bad "an ordinary filter value no longer round-trips - the escaping is wrong"
fi

# B. Stored activity notes in a textarea body. activities.notes is the widest
# writable text field in the app.
if [ "$HAVE_DB" = 1 ]; then
	cleanup_ta() {
		adb "DELETE FROM activities WHERE summary = 'ZZTA activity'" >/dev/null
		adb "DELETE FROM cases WHERE number = 'ZZ-TA-CASE'" >/dev/null
	}
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_ta' EXIT
	cleanup_ta

	TCASE="$(adb "SELECT COALESCE(MAX(case_id), 0) + 1 FROM cases")"
	adb "INSERT INTO cases (case_id, number, user_id, office, status)
		VALUES (${TCASE}, 'ZZ-TA-CASE', 1, 'ZZOFF', '1')" >/dev/null
	TACT="$(adb "SELECT COALESCE(MAX(act_id), 0) + 1 FROM activities")"
	adb "INSERT INTO activities (act_id, case_id, user_id, act_date, act_type, completed, summary, notes)
		VALUES (${TACT}, ${TCASE}, 1, CURDATE(), 'C', 0, 'ZZTA activity',
			'ZZTA-START</textarea><zzxss>ZZTA-END and ZZTA & PLAIN')" >/dev/null

	if [ -z "${TACT:-}" ]; then
		bad "could not seed the textarea fixture"
	else
		curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" \
			"$OCM_URL/activity.php?act_id=${TACT}" >/dev/null
		if grep -qF '</textarea><zzxss>' "$BODY"; then
			bad "A STORED NOTE CLOSES THE TEXTAREA AND ADDS MARKUP TO THE PAGE"
		elif grep -qF '&lt;/textarea&gt;' "$BODY"; then
			ok "a note carrying </textarea is encoded inside the textarea body"
		else
			bad "the seeded note never reached the page - check B is untested"
		fi

		if grep -qF 'ZZTA &amp; PLAIN' "$BODY"; then
			ok "ordinary note text still reaches the textarea"
		else
			bad "ordinary note text no longer reaches the textarea"
		fi
	fi

	cleanup_ta
	trap 'rm -f "$COOKIES" "$BODY"' EXIT
else
	printf '  skip the stored textarea check (needs a running docker compose stack)\n'
fi

echo
echo "21. the Twilio webhook requires a signed POST"

# cms/services/twilio.php runs with PL_DISABLE_SECURITY, so nothing else in
# the request path checks anything. Before the signature gate it accepted any
# POST: an activity record with attacker-chosen notes on any open case whose
# client phone number the caller could guess, an email to the case handlers
# about it, and a reply whose wording said whether that number belongs to a
# client of this organisation.
#
# The endpoint parses the number as +1AAAPPPNNNN: area code from offset 2,
# then PPP-NNNN from offset 5.
if [ "$HAVE_DB" = 1 ]; then
	TW_TOKEN='zz_twilio_token'
	TW_URL="${OCM_URL}/services/twilio.php"

	cleanup_tw() {
		adb "DELETE FROM activities WHERE notes LIKE 'ZZTW-%'" >/dev/null
		adb "DELETE FROM conflict WHERE contact_id IN
			(SELECT contact_id FROM contacts WHERE last_name = 'ZZTWCONTACT')" >/dev/null
		adb "DELETE FROM cases WHERE number = 'ZZ-TW-CASE'" >/dev/null
		adb "DELETE FROM contacts WHERE last_name = 'ZZTWCONTACT'" >/dev/null
		adb "DELETE FROM settings WHERE label = 'twilio_auth_token'" >/dev/null
	}
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_tw' EXIT
	cleanup_tw

	WCONTACT="$(adb "SELECT COALESCE(MAX(contact_id), 0) + 1 FROM contacts")"
	adb "INSERT INTO contacts (contact_id, first_name, last_name, area_code, phone)
		VALUES (${WCONTACT}, 'Zz', 'ZZTWCONTACT', '555', '123-4567')" >/dev/null
	WCASE="$(adb "SELECT COALESCE(MAX(case_id), 0) + 1 FROM cases")"
	adb "INSERT INTO cases (case_id, number, user_id, office, status, client_id)
		VALUES (${WCASE}, 'ZZ-TW-CASE', 1, 'ZZOFF', '1', ${WCONTACT})" >/dev/null
	adb "INSERT INTO conflict (case_id, contact_id, relation_code)
		VALUES (${WCASE}, ${WCONTACT}, 1)" >/dev/null

	if [ -z "${WCASE:-}" ]; then
		bad "could not seed the Twilio webhook fixtures"
	else
		# A GET is not a webhook.
		WCODE="$(curl -s --max-time 30 -o "$BODY" -w '%{http_code}' "$TW_URL")"
		if [ "$WCODE" = '405' ]; then
			ok "the Twilio webhook refuses a GET"
		else
			bad "the Twilio webhook answered a GET with ${WCODE}"
		fi

		# No auth token configured: refuse rather than accept unsigned.
		curl -s --max-time 30 -o "$BODY" -X POST \
			-d 'From=%2B15551234567' -d 'Body=ZZTW-UNCONFIGURED' "$TW_URL" >/dev/null
		if [ "$(adb "SELECT COUNT(*) FROM activities WHERE notes = 'ZZTW-UNCONFIGURED'")" = '0' ]; then
			ok "the Twilio webhook refuses a POST when no auth token is configured"
		else
			bad "THE TWILIO WEBHOOK WROTE AN ACTIVITY WITH NO AUTH TOKEN CONFIGURED"
		fi

		adb "INSERT INTO settings (label, value) VALUES ('twilio_auth_token', '${TW_TOKEN}')
			ON DUPLICATE KEY UPDATE value = '${TW_TOKEN}'" >/dev/null

		# Configured, but the request carries no signature.
		curl -s --max-time 30 -o "$BODY" -X POST \
			-d 'From=%2B15551234567' -d 'Body=ZZTW-UNSIGNED' "$TW_URL" >/dev/null
		if [ "$(adb "SELECT COUNT(*) FROM activities WHERE notes = 'ZZTW-UNSIGNED'")" = '0' ]; then
			ok "the Twilio webhook refuses an unsigned POST"
		else
			bad "THE TWILIO WEBHOOK WROTE AN ACTIVITY FROM AN UNSIGNED POST"
		fi

		# A signature over the right body but computed with the wrong token.
		WBAD="$(docker compose "${COMPOSE_ARGS[@]}" exec -T app php -r \
			'echo base64_encode(hash_hmac("sha1", $argv[1] . "Body" . $argv[2] . "From" . $argv[3], "wrong_token", true));' \
			"$TW_URL" 'ZZTW-BADSIG' '+15551234567' </dev/null 2>/dev/null)"
		curl -s --max-time 30 -o "$BODY" -X POST -H "X-Twilio-Signature: ${WBAD}" \
			--data-urlencode 'From=+15551234567' --data-urlencode 'Body=ZZTW-BADSIG' "$TW_URL" >/dev/null
		if [ "$(adb "SELECT COUNT(*) FROM activities WHERE notes = 'ZZTW-BADSIG'")" = '0' ]; then
			ok "the Twilio webhook refuses a signature made with the wrong token"
		else
			bad "THE TWILIO WEBHOOK ACCEPTED A SIGNATURE MADE WITH THE WRONG TOKEN"
		fi

		# Positive control: a correctly signed webhook must still work, or the
		# three checks above only prove the endpoint is broken. Twilio signs
		# the full URL followed by each POST name and value in name order.
		WSIG="$(docker compose "${COMPOSE_ARGS[@]}" exec -T app php -r \
			'echo base64_encode(hash_hmac("sha1", $argv[1] . "Body" . $argv[2] . "From" . $argv[3], $argv[4], true));' \
			"$TW_URL" 'ZZTW-SIGNED' '+15551234567' "$TW_TOKEN" </dev/null 2>/dev/null)"
		curl -s --max-time 30 -o "$BODY" -H "X-Twilio-Signature: ${WSIG}" -X POST \
			--data-urlencode 'From=+15551234567' --data-urlencode 'Body=ZZTW-SIGNED' "$TW_URL" >/dev/null
		if [ "$(adb "SELECT COUNT(*) FROM activities WHERE notes = 'ZZTW-SIGNED' AND case_id = ${WCASE}")" = '1' ]; then
			ok "a correctly signed Twilio webhook still records the message"
		else
			bad "a correctly signed Twilio webhook no longer records the message"
		fi
	fi

	cleanup_tw
	trap 'rm -f "$COOKIES" "$BODY"' EXIT
else
	printf '  skip the Twilio webhook checks (needs a running docker compose stack)\n'
fi

echo
echo "22. force_https redirects instead of serving the page over plain HTTP"

# cms/pika-danio.php sent the 302 and then built and served the whole page
# anyway: there was no exit() after the header, so every side effect of the
# request still ran over the insecure connection force_https exists to
# prevent. Measured before the fix: 302 with a 3425-byte login page attached.
#
# The redirect target also came from $_SERVER['SERVER_NAME'], which Apache
# fills from the request's Host header, and it was built as "https://" . that,
# so it now goes through pl_canonical_origin('https') instead.
if [ "$HAVE_DB" = 1 ]; then
	FH_HDR="${BODY}.hdr"

	restore_https() {
		adb "UPDATE settings SET value='0' WHERE label='force_https'" >/dev/null
		rm -f "$FH_HDR"
	}
	trap 'rm -f "$COOKIES" "$BODY"; restore_https' EXIT

	# The session cookie must NOT be marked Secure on a plain-HTTP request.
	# php.ini deliberately leaves session.cookie_secure unset, because a
	# browser will not send a Secure cookie back over http:// and a local
	# install would then never log in. SameSite and HttpOnly are unconditional.
	restore_https
	curl -s -D "$FH_HDR" -o "$BODY" --max-time 30 "${OCM_URL}/" >/dev/null
	FH_COOKIE="$(grep -i '^set-cookie' "$FH_HDR" | head -1)"

	case "$FH_COOKIE" in
		*[Ss]ecure*) bad "the session cookie is marked Secure over plain HTTP" ;;
		'')          bad "no session cookie was set at all" ;;
		*)           ok "the session cookie is not marked Secure over plain HTTP" ;;
	esac

	case "$FH_COOKIE" in
		*HttpOnly*) ok "the session cookie is HttpOnly" ;;
		*)          bad "the session cookie is not HttpOnly" ;;
	esac

	case "$FH_COOKIE" in
		*SameSite=Lax*) ok "the session cookie is SameSite=Lax" ;;
		*)              bad "the session cookie is not SameSite=Lax (rebuild the image?)" ;;
	esac

	adb "UPDATE settings SET value='1' WHERE label='force_https'" >/dev/null
	FH_CODE="$(curl -s -D "$FH_HDR" -o "$BODY" -w '%{http_code}' --max-time 30 "${OCM_URL}/")"
	FH_LOC="$(grep -i '^location:' "$FH_HDR" | tr -d '\r')"

	if [ "$FH_CODE" = '302' ]; then
		ok "a plain-HTTP request is redirected when force_https is on"
	else
		bad "a plain-HTTP request is not redirected when force_https is on (${FH_CODE})"
	fi

	# The redirect must go to https, or it points at the page it is already on
	# and the browser loops.
	case "$FH_LOC" in
		*https://*) ok "the force_https redirect targets https" ;;
		*)          bad "the force_https redirect does not target https (${FH_LOC})" ;;
	esac

	if [ "$(wc -c < "$BODY")" -eq 0 ]; then
		ok "the redirect serves no page body over plain HTTP"
	else
		bad "the redirect still serves a page body over plain HTTP ($(wc -c < "$BODY") bytes)"
	fi

	# Positive control: with the setting back off the page must still render,
	# or the checks above only prove the site is down.
	restore_https
	FH_OFF="$(curl -s -o "$BODY" -w '%{http_code}' --max-time 30 "${OCM_URL}/")"

	if [ "$FH_OFF" = '200' ] && [ "$(wc -c < "$BODY")" -gt 500 ]; then
		ok "the login page still renders with force_https off"
	else
		bad "the login page no longer renders with force_https off (${FH_OFF})"
	fi

	trap 'rm -f "$COOKIES" "$BODY"' EXIT
	rm -f "$FH_HDR"
else
	printf '  skip the force_https checks (needs a running docker compose stack)\n'
fi

echo
echo "23. dataops.php authorizes and validates its own handlers"

# dataops.php is the write handler for nearly everything that is not a case.
# The only authorization gate in the file ran when the request carried a
# case_id, so a contact update, an alias, a timeslip delete or a pro bono
# attorney write skipped it entirely by leaving that parameter out.
#
# Its set_password handler was worse: it compared the stored hash to the
# submitted plaintext with !=, and neither guard had an exit() after its
# redirect, so a wrong current password still changed the password and the
# browser was then sent to the error page.
if [ "$HAVE_DB" = 1 ]; then
	DGROUP='zz_dops_grp'
	DUSER='zz_dops_user'
	DPASS='zz-dops-Passw0rd'
	DNEW='zz-dops-Changed1'
	DJAR="$(mktemp)"

	cleanup_dops() {
		adb "DELETE FROM activities WHERE summary LIKE 'ZZDOPSREDIR%'" >/dev/null
		adb "DELETE FROM pb_attorneys WHERE last_name = 'ZZDOPSATTY'" >/dev/null
		adb "DELETE FROM cases WHERE number = 'ZZ-DOPS-CASE'" >/dev/null
		adb "DELETE FROM users WHERE username = '${DUSER}'" >/dev/null
		adb "DELETE FROM \`groups\` WHERE group_id = '${DGROUP}'" >/dev/null
		rm -f "$DJAR"
	}
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_dops' EXIT
	cleanup_dops

	# No edit_all, no pba: this user may not touch the pro bono directory.
	adb "INSERT INTO \`groups\` (group_id, read_office, read_all, edit_office, edit_all, users, pba, motd, intake, reports)
		VALUES ('${DGROUP}', NULL, 1, NULL, 0, 0, 0, 0, 0, NULL)" >/dev/null

	DHASH="$(docker compose "${COMPOSE_ARGS[@]}" exec -T app \
		php -r 'echo password_hash($argv[1], PASSWORD_DEFAULT);' "$DPASS" </dev/null 2>/dev/null)"
	DUID="$(adb "SELECT COALESCE(MAX(user_id), 0) + 1 FROM users")"
	adb "INSERT INTO users (user_id, username, password, enabled, group_id, password_expire)
		VALUES (${DUID}, '${DUSER}', '${DHASH}', 1, '${DGROUP}', 0)" >/dev/null

	# A case this user handles, with a co-counsel already in the second slot.
	DCASE="$(adb "SELECT COALESCE(MAX(case_id), 0) + 1 FROM cases")"
	adb "INSERT INTO cases (case_id, number, user_id, cocounsel1, office, status)
		VALUES (${DCASE}, 'ZZ-DOPS-CASE', ${DUID}, 1, 'ZZOFF', '1')" >/dev/null

	dops_login() {
		: > "$DJAR"
		curl -sL --max-time 30 -c "$DJAR" -b "$DJAR" -o "$BODY" \
			-X POST -d "login_user=$1&login_pass=$2&auth_id=1" "$OCM_URL/" >/dev/null
		! grep -q 'login_pass' "$BODY"
	}

	# The post-login landing page carries no _csrf field, so the token has to
	# come from a page that renders a form. password.php is the one page every
	# user can always load regardless of group. Take a fresh token before each
	# POST: pl_csrf_check() may consume it, and a spent token would make every
	# assertion below pass because the request was refused, not because the
	# handler checked anything.
	dops_token() {
		curl -sL --max-time 30 -c "$DJAR" -b "$DJAR" "$OCM_URL/password.php" \
			| grep -oE 'name="_csrf" value="[0-9a-f]{64}"' \
			| head -1 | sed -e 's/.*value="//' -e 's/"$//'
	}

	if [ -z "$DHASH" ] || [ -z "${DCASE:-}" ]; then
		bad "could not seed the dataops fixtures"
	elif ! dops_login "$DUSER" "$DPASS"; then
		bad "the throwaway dataops user could not log in - section 23 is untested"
	else
		ok "the throwaway dataops user can log in"

		DTOKEN="$(dops_token)"

		if [ "${#DTOKEN}" -ne 64 ]; then
			bad "no CSRF token for the dataops user - section 23 is untested"
		else
			# --- set_password: a wrong current password must change nothing ---
			DHASH_BEFORE="$(adb "SELECT password FROM users WHERE user_id = ${DUID}")"
			curl -s --max-time 30 -c "$DJAR" -b "$DJAR" -o "$BODY" -X POST \
				-d "action=set_password&oldpass=totally-wrong&newpass1=${DNEW}&newpass2=${DNEW}&_csrf=${DTOKEN}" \
				"$OCM_URL/dataops.php" >/dev/null
			if [ "$(adb "SELECT password FROM users WHERE user_id = ${DUID}")" = "$DHASH_BEFORE" ]; then
				ok "a wrong current password does not change the password"
			else
				bad "a wrong current password STILL changes the password"
			fi

			# --- set_password: mismatched new passwords must change nothing ---
			DTOKEN="$(dops_token)"
			curl -s --max-time 30 -c "$DJAR" -b "$DJAR" -o "$BODY" -X POST \
				-d "action=set_password&oldpass=${DPASS}&newpass1=${DNEW}&newpass2=something-else&_csrf=${DTOKEN}" \
				"$OCM_URL/dataops.php" >/dev/null
			if [ "$(adb "SELECT password FROM users WHERE user_id = ${DUID}")" = "$DHASH_BEFORE" ]; then
				ok "two new passwords that do not match change nothing"
			else
				bad "two new passwords that do not match STILL change the password"
			fi

			# --- positive control: the real change must still work ---
			DTOKEN="$(dops_token)"
			curl -s --max-time 30 -c "$DJAR" -b "$DJAR" -o "$BODY" -X POST \
				-d "action=set_password&oldpass=${DPASS}&newpass1=${DNEW}&newpass2=${DNEW}&_csrf=${DTOKEN}" \
				"$OCM_URL/dataops.php" >/dev/null
			if [ "$(adb "SELECT password FROM users WHERE user_id = ${DUID}")" != "$DHASH_BEFORE" ] \
				&& dops_login "$DUSER" "$DNEW"; then
				ok "the correct current password still changes the password"
			else
				bad "the correct current password no longer changes the password"
			fi

			# The login above reset the jar, so take a fresh token with it.
			DTOKEN="$(dops_token)"

			# --- set_case_user: an empty user_id must not clear a slot ---
			# && binds tighter than ||, so the presence check only covered the
			# handling-attorney field. Naming a co-counsel field with an empty
			# user_id wrote '' into it, and case access is granted off those
			# two columns, so clearing one revoked a staffer's access.
			DTOKEN="$(dops_token)"
			curl -s --max-time 30 -c "$DJAR" -b "$DJAR" -o "$BODY" -X POST \
				-d "action=set_case_user&case_id=${DCASE}&user_id=&field=cocounsel1&_csrf=${DTOKEN}" \
				"$OCM_URL/dataops.php" >/dev/null
			if [ "$(adb "SELECT cocounsel1 FROM cases WHERE case_id = ${DCASE}")" = '1' ]; then
				ok "an empty user_id does not clear the co-counsel slot"
			else
				bad "an empty user_id STILL clears the co-counsel slot"
			fi

			# --- open redirect ---
			# act_url arrives from the request and reaches a Location header
			# twice in the add_activity handler: on the cancel branch, and on
			# the branch that runs once the activity has been written. The
			# second one is the line SnykCode alert 975 names, and the check
			# that was here only ever posted the first. Both go through
			# safe_redirect_url(), so both are tested.
			#
			# pl_safe_redirect_path() either refuses a request-supplied return
			# path or hands back a local path. A value that reads as a local
			# path -- a name, optionally a path below it, optionally a query
			# string and a fragment, and no ".." in the path part -- is what
			# comes back. Everything else comes back as '', and this file then
			# emits "{base_url}/": the site root. Each check below says which
			# of the two results it wants.
			#
			# What comes back is not always byte-for-byte what was sent: the
			# guard trims the value and drops control characters before it
			# reads it, so a payload carrying either can come back shorter. No
			# payload below depends on that, and every one holding a space or a
			# tab is refused.
			#
			# The guard used to be a list of what to reject, and shapes got out
			# of it twice. The first was an absolute URL behind one slash: the
			# slash hid the scheme from the test, and the strip that ran
			# afterwards removed it. The second was the same thing behind a
			# slash and a space, found once the strip had been moved in front of
			# the test -- stripping the slash exposed the space, a pattern
			# anchored at the first character does not match a string that
			# starts with one, and a browser reading a Location header ignores
			# leading whitespace. That is why the list of rejections was
			# replaced rather than patched a third time. Both shapes are in the
			# set below.
			#
			# Section 34i checks the same form field in
			# ops/update_activity.php, where base_url is prepended to whatever
			# the guard returns.
			#
			# The close_act branch writes an activity row per request, so
			# every request carries a marker summary and cleanup_dops deletes
			# them.
			DR_SUM='ZZDOPSREDIR'
			# The date the database session is keeping. It only goes into a
			# payload that the guard has to refuse or return whole, so the
			# database and PHP disagreeing across midnight cannot change the
			# result. Section 34 takes its dates from PHP instead, because
			# there the date decides what the handler does.
			DRDATE="$(adb "SELECT CURDATE()")"
			# base_url as this deployment writes it, read off OCM_URL so the
			# check does not have to know it: http://host:port/cms -> /cms.
			# An install serving the application at the domain root writes ''
			# here, and then a refusal is '/'.
			DBASE="$(printf '%s' "$OCM_URL" \
				| sed -e 's#^[A-Za-z][A-Za-z0-9+.-]*://[^/]*##' -e 's#/*$##')"

			# $1 branch field, $2 act_url. Leaves the response headers in
			# $DR_HDR, the count of Location headers in $DR_COUNT and the
			# first Location value in $DR_LOC.
			dops_redirect() {
				DR_HDR="$(curl -s --max-time 30 -c "$DJAR" -b "$DJAR" -o /dev/null -D - -X POST \
					--data-urlencode "_csrf=$(dops_token)" \
					-d "action=add_activity" -d "$1=1" \
					-d "user_id=${DUID}" -d "case_id=${DCASE}" \
					-d "act_type=C" -d "hours=0.25" \
					--data-urlencode "act_date=${DRDATE}" \
					--data-urlencode "summary=${DR_SUM} $1" \
					--data-urlencode "act_url=$2" \
					"$OCM_URL/dataops.php")"
				DR_COUNT="$(printf '%s\n' "$DR_HDR" | grep -ci '^location:')"
				DR_LOC="$(printf '%s\n' "$DR_HDR" | grep -i '^location:' | tr -d '\r' \
					| head -1 | sed -e 's/^[Ll][Oo][Cc][Aa][Tt][Ii][Oo][Nn]: *//')"
			}

			# $1 branch field, $2 act_url, $3 expected answer, $4 what to
			# call the payload. $3 is one of:
			#   root   the header must be exactly "{base_url}/"
			#   exact  the header must be exactly the value that was sent
			#
			# Both kinds name the one value they will accept. An earlier
			# version had a third kind that passed on anything without a
			# scheme or a leading slash, and an empty Location header answers
			# that description, as does a redirect to the wrong page.
			dops_redirect_check() {
				dops_redirect "$1" "$2"

				if [ "$DR_COUNT" = 0 ]; then
					bad "dataops.php sent no Location header for $4 on the $1 branch, so nothing was tested"
				elif [ "$DR_COUNT" != 1 ]; then
					bad "dataops.php sent ${DR_COUNT} Location headers for $4 on the $1 branch - act_url split the header"
				elif printf '%s\n' "$DR_HDR" | grep -qi '^x-zz-injected:'; then
					bad "$4 added a header of its own through act_url on the $1 branch"
				elif [ -z "$DR_LOC" ]; then
					bad "dataops.php sent an empty Location header for $4 on the $1 branch"
				elif printf '%s' "$DR_LOC" | grep -qE '^[A-Za-z][A-Za-z0-9+.-]*:'; then
					bad "dataops.php redirects to a URL carrying a scheme for $4 on the $1 branch (${DR_LOC})"
				elif [ "$3" = root ]; then
					if [ "$DR_LOC" = "${DBASE}/" ]; then
						ok "dataops.php refuses $4 and sends the browser to the site root, on the $1 branch"
					else
						bad "dataops.php did not refuse $4 on the $1 branch (${DR_LOC})"
					fi
				elif printf '%s' "$DR_LOC" | grep -qE '^[/\\]'; then
					bad "dataops.php answered ${DR_LOC} for $4 on the $1 branch - the guard returned a value starting with a separator, which it has no shape for"
				elif [ "$3" = exact ]; then
					if [ "$DR_LOC" = "$2" ]; then
						ok "a real act_url ($4) still reaches the page it names, on the $1 branch"
					else
						bad "a real act_url ($4) no longer reaches its page on the $1 branch (${DR_LOC})"
					fi
				else
					bad "dops_redirect_check was called with the unknown kind $3"
				fi
			}

			# Real control bytes, so the handler sees the characters
			# themselves rather than the text %0D%0A or %09.
			#
			# CR LF is the header-splitting pair. The guard strips every
			# control character before it reads the value, so the header cannot
			# split whatever else the value carries; the check still asserts
			# that no second header and no injected header appeared.
			#
			# The tab is the shape a scheme test cannot see: a browser's URL
			# parser deletes tabs before it reads the scheme, so
			# "ht<TAB>tps://host" is an absolute URL to a browser while a test
			# reading it literally sees a relative path. Stripping the controls
			# first means the guard reads the string the browser will read.
			#
			# The space shapes are the second way round the old scheme test.
			# Stripping the leading slash off "/ http://host" exposed a space,
			# the trim at the top of the guard had already run, and a pattern
			# anchored at the first character does not match a string that
			# starts with one -- while a browser ignores leading whitespace in a
			# Location value and read the scheme behind it.
			DR_CRLF="$(printf '/steal\r\nX-Zz-Injected: yes')"
			DR_TAB="$(printf 'ht\tps://zz-evil.example/steal')"
			DR_SP_ABS="$(printf '/ http://zz-evil.example/steal')"
			DR_SP_JS="$(printf '/ javascript:alert(1)')"
			DR_SP_REL="$(printf '/ //zz-evil.example/steal')"
			DR_SP_TAB="$(printf '/\thttp://zz-evil.example/steal')"

			for DR_BRANCH in cancel close_act; do
				# A scheme, plainly.
				dops_redirect_check "$DR_BRANCH" 'https://zz-evil.example/steal' \
					root 'an absolute URL'
				dops_redirect_check "$DR_BRANCH" 'http:/\zz-evil.example/steal' \
					root 'a scheme with mixed slashes'
				dops_redirect_check "$DR_BRANCH" 'javascript:alert(1)' \
					root 'a javascript: URL'
				dops_redirect_check "$DR_BRANCH" "$DR_TAB" \
					root 'a tab inside the scheme'
				dops_redirect_check "$DR_BRANCH" "$DR_CRLF" \
					root 'a CR LF in act_url'
				# A scheme with something in front of it that a scheme test will
				# not look past. All eight were live open redirects on master.
				# The three carrying a space were still live after the first
				# attempt to fix the other five.
				dops_redirect_check "$DR_BRANCH" '/http://zz-evil.example/steal' \
					root 'an absolute URL behind one slash'
				dops_redirect_check "$DR_BRANCH" '\http://zz-evil.example/steal' \
					root 'an absolute URL behind one backslash'
				dops_redirect_check "$DR_BRANCH" '/\/https://zz-evil.example/steal' \
					root 'an absolute URL behind mixed slashes'
				dops_redirect_check "$DR_BRANCH" '/javascript:alert(1)' \
					root 'a javascript: URL behind one slash'
				dops_redirect_check "$DR_BRANCH" "$DR_SP_ABS" \
					root 'an absolute URL behind a slash and a space'
				dops_redirect_check "$DR_BRANCH" "$DR_SP_JS" \
					root 'a javascript: URL behind a slash and a space'
				dops_redirect_check "$DR_BRANCH" "$DR_SP_TAB" \
					root 'an absolute URL behind a slash and a tab'
				dops_redirect_check "$DR_BRANCH" "$DR_SP_REL" \
					root 'a protocol-relative URL behind a slash and a space'
				# No scheme, but a leading separator pair, which a browser
				# reads as the start of a host name. The old guard reduced
				# these to a path that still carried the attacker's hostname;
				# they are refused outright now.
				dops_redirect_check "$DR_BRANCH" '//zz-evil.example/steal' \
					root 'a protocol-relative URL'
				dops_redirect_check "$DR_BRANCH" '\\zz-evil.example\steal' \
					root 'a pair of backslashes'
				dops_redirect_check "$DR_BRANCH" '/\zz-evil.example/steal' \
					root 'a slash and a backslash'
				dops_redirect_check "$DR_BRANCH" '///zz-evil.example/steal' \
					root 'three leading slashes'
				# On this site, but not a page name. A value starting at the
				# site root is refused rather than reduced: the caller resolves
				# what comes back against the application directory, so
				# dropping the leading slash made "/cms/cms/case.php".
				dops_redirect_check "$DR_BRANCH" "${DBASE}/case.php?case_id=${DCASE}" \
					root 'a path starting at the site root'
				dops_redirect_check "$DR_BRANCH" '../../etc/passwd' \
					root 'a path walking up out of the application directory'
				# The positive controls: the two shapes the application itself
				# puts in this field have to survive the guard byte for byte.
				# activity.php defaults it to cal_day.php and modules/case-act.php
				# builds the case.php form. Without these every check above
				# would pass on a handler that refused everything it was sent.
				dops_redirect_check "$DR_BRANCH" 'cal_day.php' \
					exact 'cal_day.php'
				dops_redirect_check "$DR_BRANCH" "case.php?case_id=${DCASE}&screen=act" \
					exact 'the case activity screen'
			done

			# The close_act branch writes one activity per request, so 21
			# requests should leave 21 rows carrying the marker. This is a
			# total and not a result per request: it catches a branch that was
			# refused before it ever reached the redirect, but it cannot say
			# which request is missing, and one request writing twice would
			# cover for one writing not at all. cleanup_dops clears the marker
			# rows before this block runs, so the count belongs to this run.
			DR_WROTE="$(adb "SELECT COUNT(*) FROM activities WHERE summary = '${DR_SUM} close_act'")"
			if [ "$DR_WROTE" = 21 ]; then
				ok "the close_act requests left 21 marker activities, one per request"
			else
				bad "the close_act branch wrote ${DR_WROTE} marker activities, not 21 - at least one request never reached the redirect"
			fi

			# --- add_pb without the pba flag ---
			DTOKEN="$(dops_token)"
			curl -s --max-time 30 -c "$DJAR" -b "$DJAR" -o "$BODY" -X POST \
				-d "action=add_pb&first_name=Zz&last_name=ZZDOPSATTY&_csrf=${DTOKEN}" \
				"$OCM_URL/dataops.php" >/dev/null
			if [ "$(adb "SELECT COUNT(*) FROM pb_attorneys WHERE last_name = 'ZZDOPSATTY'")" = '0' ]; then
				ok "a user without the pba flag cannot create a pro bono attorney"
			else
				bad "a user without the pba flag STILL creates a pro bono attorney"
			fi

			# --- the dead criminal-charges handlers are gone ---
			DTOKEN="$(dops_token)"
			DCH="$(curl -s --max-time 30 -c "$DJAR" -b "$DJAR" -o "$BODY" -w '%{http_code}' -X POST \
				-d "action=update_case_charges&_csrf=${DTOKEN}" "$OCM_URL/dataops.php")"
			if ! grep -qi "SQL\|case_charges" "$BODY"; then
				ok "the removed charges handler reaches no SQL (${DCH})"
			else
				bad "the removed charges handler still reaches case_charges SQL"
			fi
		fi
	fi

	cleanup_dops
	trap 'rm -f "$COOKIES" "$BODY"' EXIT
else
	printf '  skip the dataops handler checks (needs a running docker compose stack)\n'
fi

# ── 24. Repeated failed logins are locked out ──────────────────────────────
# Runs last on purpose. The per-IP counter is shared by every account, so a
# lockout raised here would refuse the admin logins the earlier sections rely
# on. The counters are files under the container's temp directory, so this
# needs a compose project to be able to clear them.
echo
echo "24. repeated failed logins are locked out"
if [ "$HAVE_COMPOSE" = 1 ] && command -v docker >/dev/null 2>&1; then
	RLJAR="$(mktemp)"
	trap 'rm -f "$COOKIES" "$BODY" "$RLJAR"' EXIT

	# Wipe the counters. Also done at the start: a previous run of this suite
	# leaves this IP locked out, and then every assertion below would pass
	# for the wrong reason.
	rl_clear() {
		docker compose "${COMPOSE_ARGS[@]}" exec -T app \
			rm -rf /tmp/ocm_auth_rl >/dev/null 2>&1 || true
	}
	rl_try() {
		# $1 username, $2 password. Prints nothing; leaves the body in $BODY.
		: > "$RLJAR"
		curl -sL --max-time 30 -c "$RLJAR" -b "$RLJAR" -o "$BODY" -X POST \
			-d "login_user=$1&login_pass=$2&auth_id=1" "$OCM_URL/" >/dev/null
	}
	RL_MSG='Too many recent failed login attempts'

	rl_clear

	# The threshold is 10 failures in 5 minutes. Nine must NOT lock out: an
	# off-by-one that locks at the first failure would make every check below
	# pass while breaking every real login.
	i=1
	while [ "$i" -le 9 ]; do
		rl_try zz_lockout_user "wrong-${i}"
		i=$((i+1))
	done
	if grep -q "$RL_MSG" "$BODY"; then
		bad "the lockout fired after 9 failures — the threshold is too low"
	else
		ok "nine failed logins do not lock the account out"
	fi

	rl_try zz_lockout_user wrong-10
	rl_try zz_lockout_user wrong-11
	if grep -q "$RL_MSG" "$BODY"; then
		ok "the tenth failed login locks further attempts out"
	else
		bad "no lockout after 11 failed logins — the login form is still an unlimited password oracle"
	fi

	# The per-IP key is what stops credential stuffing that rotates the
	# username, so the correct admin password must be refused too while the
	# lockout stands. This is also the check that would catch a per-account
	# key being counted but never read.
	rl_try "$OCM_USER" "$OCM_PASSWORD"
	if grep -q "$RL_MSG" "$BODY"; then
		ok "the lockout also refuses a valid password from the same address"
	else
		bad "a valid password is still accepted from a locked-out address — the per-IP key is not enforced"
	fi

	rl_clear
	rl_try "$OCM_USER" "$OCM_PASSWORD"
	if ! grep -q 'login_pass' "$BODY" && grep -qi 'logout' "$BODY"; then
		ok "clearing the counters lets the admin log in again"
	else
		bad "the admin cannot log in after the counters were cleared"
	fi

	# auth_ip_lockout_threshold=0 is the escape hatch for an organisation
	# whose whole staff shares one office address. With it set, twelve
	# failures against one username must not touch anybody else's login.
	if [ "$HAVE_DB" = 1 ]; then
		adb "DELETE FROM settings WHERE label='auth_ip_lockout_threshold'" >/dev/null
		adb "INSERT INTO settings (label, value) VALUES ('auth_ip_lockout_threshold','0')" >/dev/null
		rl_clear
		i=1
		while [ "$i" -le 12 ]; do
			rl_try zz_lockout_user "wrong-${i}"
			i=$((i+1))
		done
		rl_try "$OCM_USER" "$OCM_PASSWORD"
		if ! grep -q 'login_pass' "$BODY" && grep -qi 'logout' "$BODY"; then
			ok "auth_ip_lockout_threshold=0 keeps one user's failures off everybody else"
		else
			bad "auth_ip_lockout_threshold=0 did NOT disable the per-IP lockout"
		fi
		adb "DELETE FROM settings WHERE label='auth_ip_lockout_threshold'" >/dev/null
	fi

	# Leave nothing behind: the next run of this suite starts from zero, and a
	# developer running it against their own stack is not locked out of it.
	rl_clear
	rm -f "$RLJAR"
	trap 'rm -f "$COOKIES" "$BODY"' EXIT
else
	printf '  skip the login lockout checks (needs a running docker compose stack)\n'
fi

echo
echo "25. multi-factor authentication"
# The whole loop: an administrator turns the requirement on, the account holder
# enrols a device on enroll_mfa.php and is held there until they do, the login
# form then wants a code as well as a password, a used code cannot be replayed,
# and the administrator can reset or turn it off again. The codes are generated
# here by an independent RFC 6238 implementation in python, so this section
# fails if the application's own generator drifts.
if [ "$HAVE_DB" = 1 ] && [ "$HAVE_COMPOSE" = 1 ] && command -v python3 >/dev/null 2>&1; then
	if [ -n "$(adb "SHOW COLUMNS FROM users LIKE 'totp_secret'")" ]; then
		ok "users.totp_secret column exists"
	else
		bad "users.totp_secret column is MISSING (add_totp.sql did not run)"
	fi
	if [ -n "$(adb "SHOW TABLES LIKE 'menu_totp_enabled'")" ]; then
		ok "menu_totp_enabled table exists"
	else
		bad "menu_totp_enabled table is MISSING (add_totp.sql did not run)"
	fi

	MFA_GROUP='zz_mfa_grp'
	MFA_USER='zz_mfa_user'
	MFA_PASS='zz-mfa-Passw0rd'
	MFA_JAR="$(mktemp)"
	MFA_PY="$(mktemp)"


	mfa_code()   { python3 "$MFA_PY" "$1" "${2:-0}"; }
	# The window and its code from one run. Two shell commands can be split
	# by a boundary and then disagree about which window is current.
	mfa_code_pair() { python3 "$MFA_PY" "$1" "${2:-0}" pair; }
	mfa_window() { python3 -c 'import time; print(int(time.time()) // 30)'; }
	# Block until the current 30-second window has just begun, leaving at
	# least 17 seconds before the next one starts. Without it the window a
	# code was built for and the window the server is in when it reads the
	# code differ at random, which is what made the enrollment checks below
	# pass or fail by luck. It is slack, not a guarantee: a long enough
	# pause still crosses the boundary, and the iteration cap below can
	# return without a fresh window at all. So no caller trusts it. The
	# enrollment loop decides from the stored row and the login loop
	# re-reads the window, and both retry rather than assert on an unstable
	# pass. Capped: a stopped clock must not hang the suite.
	mfa_wait_fresh() {
		mfa_fresh_waited=0
		while [ "$(python3 -c 'import time; print(int(time.time()) % 30)')" -gt 12 ] \
			&& [ "$mfa_fresh_waited" -lt 31 ]; do
			sleep 1
			mfa_fresh_waited=$((mfa_fresh_waited+1))
		done
	}
	# The login form is rate limited per address. This section produces several
	# deliberate failures, so clear the counters between steps or a later
	# assertion passes because everything is locked out.
	mfa_rl_clear() {
		docker compose "${COMPOSE_ARGS[@]}" exec -T app \
			rm -rf /tmp/ocm_auth_rl >/dev/null 2>&1 || true
	}

	cleanup_mfa() {
		adb "DELETE FROM users WHERE username = '${MFA_USER}'" >/dev/null
		adb "DELETE FROM \`groups\` WHERE group_id = '${MFA_GROUP}'" >/dev/null
		mfa_rl_clear
		rm -f "$MFA_JAR" "$MFA_PY"
	}
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_mfa' EXIT

	cleanup_mfa

# Unindented: a quoted heredoc keeps the body verbatim, tabs included.
cat > "$MFA_PY" <<'MFAPY'
import base64, hmac, hashlib, struct, sys, time

secret = sys.argv[1].strip().upper().replace(' ', '')
offset = int(sys.argv[2]) if len(sys.argv) > 2 else 0
pad = '=' * ((8 - len(secret) % 8) % 8)
key = base64.b32decode(secret + pad)
counter = int(time.time()) // 30 + offset
digest = hmac.new(key, struct.pack('>Q', counter), hashlib.sha1).digest()
start = digest[19] & 0x0f
value = struct.unpack('>I', digest[start:start + 4])[0] & 0x7fffffff
code = '%06d' % (value % 1000000)

if len(sys.argv) > 3 and sys.argv[3] == 'pair':
	sys.stdout.write('%d %s' % (counter, code))
else:
	sys.stdout.write(code)
MFAPY

	# read_all so that a successful sign-in lands on a page this section can
	# tell apart from the enrollment page.
	adb "INSERT INTO \`groups\` (group_id, read_office, read_all, edit_office, edit_all, users, pba, motd, intake, reports)
		VALUES ('${MFA_GROUP}', NULL, 1, NULL, 0, 0, 0, 0, 0, NULL)" >/dev/null
	MFA_HASH="$(docker compose "${COMPOSE_ARGS[@]}" exec -T app \
		php -r 'echo password_hash($argv[1], PASSWORD_DEFAULT);' "$MFA_PASS" </dev/null 2>/dev/null)"
	MFA_UID="$(adb "SELECT COALESCE(MAX(user_id), 0) + 1 FROM users")"
	adb "INSERT INTO users (user_id, username, password, enabled, group_id, password_expire)
		VALUES (${MFA_UID}, '${MFA_USER}', '${MFA_HASH}', 1, '${MFA_GROUP}', 0)" >/dev/null

	mfa_admin_edit() {
		: > "$BODY"
		curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" \
			"$OCM_URL/system-users.php?action=edit&user_id=${MFA_UID}" >/dev/null
	}
	# Post the account form with one MFA value. The form is the only way an
	# administrator can reach these columns, so drive it rather than the table.
	mfa_admin_set() {
		mfa_admin_edit
		mfa_admin_set_got=$?
		mfa_tok="$(grep -oE 'name="_csrf" value="[0-9a-f]*"' "$BODY" \
			| head -1 | sed -E 's/.*value="([0-9a-f]*)".*/\1/')"
		# Without a token the update below is refused for that reason,
		# and the checks that read the row afterwards would blame the
		# form for not saving a value it was never asked to save.
		if [ "$mfa_admin_set_got" != 0 ] || [ -z "$mfa_tok" ]; then
			bad "the account form could not be fetched with a CSRF token (curl exit ${mfa_admin_set_got}) - the MFA value was not posted"
			return 1
		fi
		sm_reauth_post user_admin "$OCM_URL/system-users.php" \
			-d "action=update&user_id=${MFA_UID}&_csrf=${mfa_tok}" \
			-d "username=${MFA_USER}&enabled=1&group_id=${MFA_GROUP}" \
			-d "totp_enabled=$1"
	}
	# Truncate the body first. A transfer that fails before any of the
	# response body arrives does not touch curl's -o file at all, so
	# without this a grep below reads the page the PREVIOUS request left
	# there and reports on that page instead of this one. One that breaks
	# off part way through does overwrite it, with its own partial page.
	mfa_login() {
		: > "$MFA_JAR"
		: > "$BODY"
		curl -sL --max-time 30 -c "$MFA_JAR" -b "$MFA_JAR" -o "$BODY" \
			-d "login_user=${MFA_USER}&login_pass=${MFA_PASS}&auth_id=1&totp=${1:-}" \
			"$OCM_URL/" >/dev/null
	}
	# Fetch one page as the fixture's own session. Returns curl's
	# status, so a page that refused is not confused with a fetch that
	# failed, and truncates the body first, because a transfer that fails
	# before any of the body arrives does not touch curl's -o file.
	mfa_jar_get() {
		: > "$BODY"
		curl -sL --max-time 30 -b "$MFA_JAR" -o "$BODY" "$1" >/dev/null
	}

	if [ -z "$MFA_HASH" ] || [ -z "${MFA_UID:-}" ]; then
		bad "could not seed the MFA fixtures (hash/user)"
	else
		# 25a. The control renders, and the account's own secret does not.
		mfa_admin_edit
		mfa_admin_got=$?
		# Two of the four checks below pass on an absent string, so an
		# empty body answers them both. A fetch that did not complete
		# would report that the form carries no secret input and offers
		# no reset without either page having been seen.
		if [ "$mfa_admin_got" != 0 ]; then
			bad "fetching the account form did not complete (curl exit ${mfa_admin_got}) - the four MFA control checks were not run"
		else
			if grep -q 'Multi-Factor Authentication' "$BODY" \
				&& grep -q 'name="totp_enabled"' "$BODY"; then
				ok "the account form carries the MFA control"
			else
				bad "the account form has no MFA control - pl_mfa_admin_control() rendered nothing"
			fi
			if grep -q 'Off. This account signs in with a password only.' "$BODY"; then
				ok "a new account reports MFA off"
			else
				bad "a new account does not report MFA off"
			fi
			if grep -q 'name="totp_secret"' "$BODY"; then
				bad "the account form carries a totp_secret input - an admin page must never handle the secret"
			else
				ok "the account form carries no totp_secret input"
			fi
			if grep -q '>Reset<' "$BODY"; then
				bad "the account form offers a reset for an account with no enrolled device"
			else
				ok "the account form offers no reset before a device is enrolled"
			fi
		fi

		# 25b. Turning it on writes the flag and nothing else.
		mfa_admin_set 1
		if [ "$(adb "SELECT totp_enabled FROM users WHERE user_id = ${MFA_UID}")" = 1 ]; then
			ok "the admin form turns MFA on"
		else
			bad "the admin form did not turn MFA on"
		fi
		if [ -z "$(adb "SELECT totp_secret FROM users WHERE user_id = ${MFA_UID} AND LENGTH(totp_secret) > 0")" ]; then
			ok "turning MFA on stores no secret"
		else
			bad "turning MFA on stored a secret - the secret must come from the user, not the admin"
		fi
		if [ -n "$(adb "SELECT 1 FROM audit_log WHERE action = 'user.mfa_enabled' LIMIT 1")" ]; then
			ok "audit_log recorded user.mfa_enabled"
		else
			bad "audit_log has no user.mfa_enabled row"
		fi

		# 25c. The gate holds the account on the enrollment page.
		mfa_rl_clear
		mfa_login
		mfa_gate_got=$?
		if [ "$mfa_gate_got" != 0 ]; then
			bad "the pre-enrollment login did not complete (curl exit ${mfa_gate_got}) - the gate was not checked"
		elif grep -q 'Set up Multi-Factor Authentication' "$BODY"; then
			ok "a user with MFA on and no device lands on the enrollment page"
		else
			bad "the enrollment gate did not fire - a user with MFA on reached the application"
		fi
		# The login above leaves the enrollment page behind, and that
		# page carries the very string this check greps for. A fetch
		# that did not complete used to leave it there and pass, so the
		# gate could be absent for every request but the login itself
		# and nothing here would say so.
		mfa_jar_get "$OCM_URL/case_list.php"
		mfa_gate_page=$?
		if [ "$mfa_gate_page" != 0 ]; then
			bad "fetching case_list.php did not complete (curl exit ${mfa_gate_page}) - the gate was not checked on an ordinary page"
		elif grep -q 'Set up Multi-Factor Authentication' "$BODY"; then
			ok "the gate also holds an ordinary page request"
		else
			bad "case_list.php was served to an un-enrolled account"
		fi

		# 25d. Enrolment: the page hands out a key, a wrong code is refused
		# and stores nothing, the right code stores the secret encrypted.
		# The pending secret rides in the encrypted enroll_token, so an
		# earlier render of this page carries a matched key, token and
		# CSRF triple. A fetch that did not complete used to leave one
		# behind, and the whole of 25d would then run on a page this
		# run never received.
		mfa_jar_get "$OCM_URL/enroll_mfa.php"
		mfa_enrol_page=$?
		MFA_SECRET="$(sed -n 's/.*class="enroll-key">\([A-Z2-7]*\)<.*/\1/p' "$BODY" | head -1)"
		MFA_TOKEN="$(grep -oE 'name="enroll_token" value="[^"]*"' "$BODY" \
			| head -1 | sed -E 's/.*value="([^"]*)".*/\1/')"
		MFA_CSRF="$(grep -oE 'name="_csrf" value="[0-9a-f]*"' "$BODY" \
			| head -1 | sed -E 's/.*value="([0-9a-f]*)".*/\1/')"
		# Both checks below read this one response, so both belong under
		# its completion. The sign-out link was scraped from $BODY after
		# the branch above had already reported the fetch as lost, and a
		# partial response that happened to carry the link passed.
		if [ "$mfa_enrol_page" != 0 ]; then
			bad "fetching the enrollment page did not complete (curl exit ${mfa_enrol_page}) - neither its fields nor its way out was checked"
		else
			if [ "${#MFA_SECRET}" -ge 16 ] && [ -n "$MFA_TOKEN" ] && [ "${#MFA_CSRF}" -eq 64 ]; then
				ok "the enrollment page renders a key, a pending token and a CSRF token"
			else
				bad "the enrollment page is incomplete (key ${#MFA_SECRET} chars, token ${#MFA_TOKEN} chars, csrf ${#MFA_CSRF} chars)"
			fi

			# The way out. An account that is held on the enrollment page
			# has exactly one other link, and the enrollment gate lets
			# exactly one other page through. A link that 404s leaves a
			# user who cannot enrol -- lost phone, no authenticator app
			# yet -- with no way to end the session at all. Follow the
			# link the page actually renders rather than reading the
			# source, so a future edit that points it somewhere else is
			# caught too.
			MFA_OUT="$(sed -n 's/.*<a href="\([^"]*logout[^"]*\)".*/\1/p' "$BODY" | head -1)"
			# base_url is a path, not an absolute URL, on a stock install.
			case "$MFA_OUT" in
				http*) ;;
				/*) MFA_OUT="$(printf '%s' "$OCM_URL" | sed -E 's#^(https?://[^/]+).*#\1#')${MFA_OUT}" ;;
			esac
			# Without the fixture's cookies: following it with them would
			# end the session the rest of this section still needs.
			# Whether the URL exists is the whole question. curl prints
			# 000 and exits non-zero for a request that did not arrive,
			# and 000 is not 404, so the status has to be read too or a
			# probe that never got there counts as a working link.
			if [ -z "$MFA_OUT" ]; then
				bad "the enrollment page renders no sign-out link"
			else
				mfa_out_code="$(curl -s --max-time 30 -o /dev/null -w '%{http_code}' "$MFA_OUT")"
				mfa_out_got=$?
				if [ "$mfa_out_got" != 0 ]; then
					bad "probing the sign-out link did not complete (curl exit ${mfa_out_got}) - whether it resolves was not checked"
				elif [ "$mfa_out_code" = 404 ]; then
					bad "the enrollment page's sign-out link is broken (${MFA_OUT} answered 404)"
				else
					ok "the enrollment page's sign-out link resolves"
				fi
			fi
		fi

		mfa_enroll_post() {
			: > "$BODY"
			curl -sL --max-time 30 -b "$MFA_JAR" -o "$BODY" \
				--data-urlencode "enroll_token=${MFA_TOKEN}" \
				--data-urlencode "_csrf=${MFA_CSRF}" \
				--data-urlencode "mfa_code=$1" \
				"$OCM_URL/enroll_mfa.php" >/dev/null
		}
		# Where the enrolled session stands, asked with a fresh request.
		# A received application reply would be evidence too, but a POST
		# whose reply was lost supplies none, and the already-enrolled
		# redirect will not read a code again to produce another. Returns
		# curl's status, which says whether the transfer completed, so a
		# page that refused is not confused with a fetch that failed.
		mfa_app_get() {
			mfa_jar_get "$OCM_URL/"
		}
		# 'enc:' for an encrypted secret, 'none' for no secret, another
		# prefix for a value this check does not expect, and empty only
		# for a row that was not read: adb() suppresses errors, so a
		# dropped connection and a missing row both come back empty and
		# neither may be taken for an account not yet enrolled.
		mfa_enrol_state() {
			adb "SELECT IF(totp_secret IS NULL OR totp_secret = '', 'none', LEFT(totp_secret, 4)) FROM users WHERE user_id = ${MFA_UID}"
		}

		if [ "${#MFA_SECRET}" -lt 16 ]; then
			bad "no enrollment key - the rest of section 25 is untested"
		else
			mfa_enroll_post 000000
			mfa_enrol_seed=$?
			# A refusal counts only if the code got there. The POST helper
			# truncates the body first, so no earlier page can supply the
			# refusal text; a transfer that failed part way through can
			# still leave bytes of its own, so the status is what decides
			# this and not the body. Without it the server would be
			# accused of accepting a code it never received.
			if [ "$mfa_enrol_seed" != 0 ]; then
				bad "the wrong-code enrollment POST did not complete (curl exit ${mfa_enrol_seed}) - it was not checked"
			elif grep -q 'That code did not match' "$BODY" \
				&& [ -z "$(adb "SELECT totp_secret FROM users WHERE user_id = ${MFA_UID} AND LENGTH(totp_secret) > 0")" ]; then
				ok "a wrong enrollment code is refused and stores nothing"
			else
				bad "a wrong enrollment code was accepted, or stored a secret anyway"
			fi

			# Enroll with the code for the PREVIOUS window. It is inside
			# pl_totp_verify_window()'s one-window tolerance, so enrollment
			# still succeeds, and it makes the window the server ought to
			# record differ from the window it is in while recording it --
			# the only way to see which of the two it stores. The window and
			# the code come from one python run, so a boundary cannot land
			# between them. A boundary that falls before the server verifies
			# the code makes it two windows old and refused, so the POST is
			# retried: the enroll_token and the _csrf field survive a refusal,
			# which the wrong-code check above has just used them for.
			mfa_enrol_try=0
			mfa_enrol_done=0
			mfa_enrol_opened=0
			mfa_enrol_got=0
			mfa_enrol_early=0
			mfa_enrol_unread=0
			mfa_enrol_unsent=0
			mfa_enrol_outside=0
			MFA_ENROL_WINDOW=''
			# A wrong-code POST whose transfer did not complete may still
			# be running, and its code is not certainly wrong: the
			# generator takes value % 1000000, so 000000 is a code some
			# secret and window produce. It carried a pending secret of
			# its own, so it can enroll the account at any point after
			# this -- including between a read and a POST below, where
			# neither would show it. Every check in this block rests on
			# knowing which POST enrolled the account, and nothing here
			# can wait for that one, so the retry loop does not run.
			# mfa_enrol_done then stays 0, which is what makes each check
			# needing an enrolled account report itself unchecked rather
			# than decide from an account that never enrolled.
			mfa_enrol_seed_lost=0
			if [ "$mfa_enrol_seed" != 0 ]; then
				mfa_enrol_seed_lost=1
			fi
			while [ "$mfa_enrol_try" -lt 3 ] && [ "$mfa_enrol_done" = 0 ] \
				&& [ "$mfa_enrol_early" = 0 ] && [ "$mfa_enrol_unread" = 0 ] \
				&& [ "$mfa_enrol_seed_lost" = 0 ] \
				&& [ "$mfa_enrol_outside" = 0 ] \
				&& [ "$mfa_enrol_unsent" = 0 ]; do
				mfa_enrol_try=$((mfa_enrol_try+1))
				mfa_enrol_row="$(mfa_enrol_state)"
				if [ "$mfa_enrol_row" = 'enc:' ]; then
					# Nothing this loop sent can have put a secret here.
					# enroll_mfa.php runs its UPDATE before it answers --
					# DB::preparedQuery() executes the statement
					# synchronously and the connection autocommits -- so a
					# POST that completed and left the row reading 'none'
					# wrote nothing, and the read after every POST below
					# says exactly that. A POST whose transfer did not
					# complete stops the loop rather than being retried,
					# and a wrong-code POST that did not complete has
					# already stopped the whole block. From the second
					# try on that leaves nothing inside this run that
					# could have written the secret, so it came from
					# outside. On the first try the seed POST is a
					# candidate too: its 000000 is a code the generator
					# can produce, so a server that took it enrolled the
					# account before the loop began. A row an earlier
					# run left behind is not a candidate on any try --
					# the fixture is read by user_id, and that id is
					# MAX(user_id) + 1 read after the delete, so no row
					# that already existed holds it, whether or not the
					# delete did anything. A second run working the same
					# database at the same time can be. Posting again
					# would answer the
					# already-enrolled redirect without the code being
					# read, and leave MFA_ENROL_WINDOW holding a window
					# nothing verified, so stop. The two cases are
					# reported apart because they say different things
					# about the starting state: on the first try the
					# secret was already there before any real enrollment
					# code was sent, and after it the secret appeared
					# while the run was working.
					if [ "$mfa_enrol_try" != 1 ]; then
						mfa_enrol_outside=1
					else
						mfa_enrol_early=1
					fi
					break
				fi
				if [ "$mfa_enrol_row" != 'none' ]; then
					# Neither answer: the row was not read, or it holds
					# something this check does not recognise. Treating
					# that as "not enrolled yet" is what would let a stored
					# secret this loop cannot see be followed by a second
					# POST, and the window the comparison below then
					# expects would belong to a code the server never
					# verified.
					mfa_enrol_unread=1
					break
				fi
				mfa_wait_fresh
				MFA_ENROL_PAIR="$(mfa_code_pair "$MFA_SECRET" -1)"
				MFA_ENROL_WINDOW="${MFA_ENROL_PAIR%% *}"
				MFA_ENROL_CODE="${MFA_ENROL_PAIR#* }"
				if [ -z "$MFA_ENROL_WINDOW" ] || [ -z "$MFA_ENROL_CODE" ]; then
					# The generator produced nothing. Posting an empty
					# code would spend a try and answer nothing.
					mfa_enrol_unsent=1
					break
				fi
				mfa_enroll_post "$MFA_ENROL_CODE"
				mfa_enrol_sent=$?
				if [ "$mfa_enrol_sent" != 0 ]; then
					# A POST whose transfer did not complete may still be
					# running. Retrying it is what let a stalled POST
					# store its own window after the retry had replaced
					# the window this check compares against, which made
					# a wrong stored window agree with the expectation.
					# Nothing this check can wait for settles it.
					mfa_enrol_unsent=1
					break
				fi
				# The row, not the page: the page cannot tell "this code
				# enrolled the account" from "it was already enrolled".
				# Reading it here is also what attributes the secret to
				# the code just sent. enroll_mfa.php writes the row before
				# it answers and the connection autocommits, so every
				# earlier POST of this loop that completed and was
				# followed by 'none' wrote nothing; a POST whose transfer
				# did not complete stops the loop, and a read that
				# answered neither stops it too. Reaching 'enc:' here
				# therefore leaves the code sent just above as the only
				# candidate. Round 64 dropped the window whenever more
				# than one POST had been sent, on the belief that a POST
				# could commit after answering. It cannot, and the retry
				# this loop is built around made that the ordinary path: a
				# correct server reported the window unchecked every time
				# a code aged out and was resent.
				mfa_enrol_row="$(mfa_enrol_state)"
				if [ "$mfa_enrol_row" = 'enc:' ]; then
					mfa_enrol_done=1
				elif [ "$mfa_enrol_row" != 'none' ]; then
					mfa_enrol_unread=1
				fi
			done
			if [ "$mfa_enrol_done" = 1 ]; then
				mfa_app_get
				mfa_enrol_got=$?
				if [ "$mfa_enrol_got" = 0 ] && grep -qi 'logout' "$BODY" \
					&& ! grep -q 'Set up Multi-Factor Authentication' "$BODY"; then
					mfa_enrol_opened=1
				fi
			fi
			if [ "$mfa_enrol_done" = 1 ] && [ "$mfa_enrol_opened" = 1 ]; then
				ok "the right enrollment code finishes enrollment and opens the application"
			elif [ "$mfa_enrol_done" = 1 ] && [ "$mfa_enrol_got" != 0 ]; then
				bad "the account enrolled but fetching the application did not complete (curl exit ${mfa_enrol_got}) - it was not checked"
			elif [ "$mfa_enrol_done" = 1 ]; then
				bad "the account enrolled but the application page did not come back signed in"
			elif [ "$mfa_enrol_early" = 1 ]; then
				bad "the account was already enrolled before any real enrollment code was sent"
			elif [ "$mfa_enrol_outside" = 1 ]; then
				bad "a secret appeared while this run was enrolling and no code it sent was accepted - something outside the run wrote the row"
			elif [ "$mfa_enrol_seed_lost" = 1 ]; then
				bad "the wrong-code enrollment POST did not complete, so it may still enroll the account with a code of its own - every check below that needs an enrolled account reports itself unchecked"
			elif [ "$mfa_enrol_unread" = 1 ]; then
				bad "the enrollment state came back as '${mfa_enrol_row}', which is neither the enc: prefix of an encrypted secret nor the 'none' this check expects for an empty one - the row was not read, or it holds something else, and every check below it is unreliable"
			elif [ "$mfa_enrol_unsent" = 1 ]; then
				bad "no enrollment code was built, or its POST did not complete - what reached the server is unknown and every check below it is unreliable"
			else
				bad "the right enrollment code did not finish enrollment after 3 tries"
			fi
			# The replay bound seeded at enrollment. This is the assertion
			# that catches storing floor(time()/30) instead of the matched
			# window. It is claimed only where a POST of this run wrote the
			# secret: MFA_ENROL_WINDOW then belongs to that POST, because
			# the read before it said there was none, that POST returned a
			# reply of its own, and the window came out of the same python
			# run as the code it sent. Anything else is reported as
			# unchecked rather than compared -- two empty strings match, so
			# an unenrolled account and an unreadable bound would otherwise
			# agree. An unreadable bound reads back as the empty string
			# and is not compared at all: it is not a wrong window, and
			# reporting it as one would accuse the server on no
			# evidence. A wrong window is reported by direction, because
			# the two directions are opposite defects. Above the accepted
			# code's window, the code a synchronized authenticator shows
			# is refused until the clock passes the stored window -- but
			# not every code the account has: the window after the stored
			# one clears the bound a window early, because the verifier
			# tries the clock's window plus one. Below it, and where no
			# bound was stored at all, nothing closes the code just
			# accepted and it stays usable for the rest of the verifier's
			# tolerance. Equality is the correct outcome and is reported
			# as one above, so neither direction covers it. The 25e login
			# below sees neither defect where it could read the bound: it
			# then waits the clock past that bound before sending
			# anything. Where every read failed it reports that instead
			# of judging the refusal.
			mfa_enrol_bound="$(adb "SELECT IF(totp_last_used IS NULL, 'null', totp_last_used) FROM users WHERE user_id = ${MFA_UID}")"
			if [ "$mfa_enrol_done" = 0 ]; then
				bad "the stored enrollment window was not checked - this run did not confirm an enrolled account"
			elif [ -z "$MFA_ENROL_WINDOW" ]; then
				bad "the stored enrollment window was not checked - the window the accepted code came from was not recorded"
			elif [ -z "$mfa_enrol_bound" ]; then
				bad "the stored enrollment window could not be read - it was not checked"
			elif [ "$mfa_enrol_bound" = "$MFA_ENROL_WINDOW" ]; then
				ok "enrollment records the window the accepted code belonged to"
			elif [ "$mfa_enrol_bound" = 'null' ]; then
				bad "enrollment stored no replay bound - nothing closes the code it just accepted and it stays usable for the rest of the verifier's tolerance"
			else
				case "$mfa_enrol_bound" in
					*[!0-9]*)
						bad "enrollment stored a replay bound that is not a window number (${mfa_enrol_bound})"
						;;
					*)
						# Both operands, not one. A non-numeric window on
						# the right made [ exit 2, which takes the else
						# and reports the "above" direction without
						# having compared anything.
						case "$MFA_ENROL_WINDOW" in
							*[!0-9]*)
								bad "the window the accepted code came from is not a window number (${MFA_ENROL_WINDOW}), so the stored bound ${mfa_enrol_bound} could not be compared with it"
								;;
							*)
								if [ "$mfa_enrol_bound" -lt "$MFA_ENROL_WINDOW" ]; then
									bad "enrollment recorded a window below the code it accepted - nothing closes that code and it stays usable for the rest of the verifier's tolerance"
								else
									bad "enrollment recorded a window above the code it accepted - the code a synchronized authenticator shows is refused until the clock passes that window"
								fi
								;;
						esac
						;;
				esac
			fi
			# Everything from here to the end of 25f asks what an enrolled
			# account does, and none of it was gated on the enrollment
			# having happened. An account with no secret answers that the
			# secret is not encrypted and that the enrollment page handed
			# out a second key -- neither of which is the server's fault
			# -- and Reset's two checks below passed for free, because
			# there was nothing there to reset. Each group that decides
			# something about an enrolled account now reports itself
			# unchecked instead of deciding from a premise the run failed
			# to establish. The audit row for the reset action is left
			# ungated on purpose: Reset writes that row whether or not a
			# device was enrolled, so enrollment is not a premise it
			# needs. It is not scoped to this run either -- the query
			# matches any user at any time, and nothing in this section
			# clears audit_log, so a row an earlier run left behind
			# answers it. The enrollment failure itself is already
			# reported above, so these lines say what was lost rather
			# than reporting a second server failure for one cause.
			if [ "$mfa_enrol_done" = 0 ]; then
				bad "this run did not confirm an enrolled account, so whether the stored secret is encrypted at rest was not checked"
			elif [ "$(adb "SELECT LEFT(totp_secret, 4) FROM users WHERE user_id = ${MFA_UID}")" = 'enc:' ]; then
				ok "the stored secret is encrypted at rest"
			else
				bad "the stored secret is not in the enc: format - it may be cleartext"
			fi
			if [ "$mfa_enrol_done" = 0 ]; then
				bad "this run did not confirm an enrolled account, so whether audit_log records user.totp_self_enrolled was not checked"
			elif [ -n "$(adb "SELECT 1 FROM audit_log WHERE action = 'user.totp_self_enrolled' LIMIT 1")" ]; then
				ok "audit_log recorded user.totp_self_enrolled"
			else
				bad "audit_log has no user.totp_self_enrolled row"
			fi
			# This one looks for a string that must be absent, so an
			# empty body answers it. Truncating alone would turn a lost
			# fetch into a pass; the status is what decides it.
			mfa_jar_get "$OCM_URL/enroll_mfa.php"
			mfa_reissue_got=$?
			if [ "$mfa_enrol_done" = 0 ]; then
				bad "this run did not confirm an enrolled account, so whether the enrollment page refuses to re-issue a key was not checked"
			elif [ "$mfa_reissue_got" != 0 ]; then
				bad "re-fetching the enrollment page did not complete (curl exit ${mfa_reissue_got}) - it was not checked"
			elif grep -q 'class="enroll-key"' "$BODY"; then
				bad "enroll_mfa.php hands out a second key to an already-enrolled account"
			else
				ok "enroll_mfa.php refuses to re-issue a key to an enrolled account"
			fi

			# 25e. The login form now needs the code.
			mfa_rl_clear
			mfa_login
			mfa_pw_got=$?
			if [ "$mfa_enrol_done" = 0 ]; then
				bad "this run did not confirm an enrolled account, so neither the password-only refusal nor its wording was checked"
			elif [ "$mfa_pw_got" != 0 ]; then
				bad "the password-only login did not complete (curl exit ${mfa_pw_got}) - neither check below it was run"
			else
				if grep -q 'login_pass' "$BODY"; then
					ok "the password alone no longer signs the account in"
				else
					bad "the password alone still signs an MFA account in"
				fi
				if grep -q 'The credentials you supplied are invalid' "$BODY"; then
					ok "the refusal does not say which factor was wrong"
				else
					bad "the refusal message names the failing factor"
				fi
			fi

			# A current code signs in, and then the same code is refused.
			# Both are decided in one pass, and the result is accepted only
			# if the window did not move across the two requests. A code
			# stays valid into the next window -- the verifier's -1 offset --
			# and expires only after two, so a refusal from a later window
			# could come from the bound or from age. Holding both requests
			# inside one window removes the question. A refusal is never
			# asserted on without that stability, so it cannot be blamed
			# on the server for the wrong reason. An accepted sign-in is
			# asserted on where the replay request was lost, because a
			# code the server took is not ambiguous the way a refusal is.
			# Where the loop instead ran out of tries, both halves are
			# reported unchecked together, the accepted sign-in included.
			mfa_pair_try=0
			mfa_pair_stable=0
			mfa_pair_in=0
			mfa_pair_out=0
			mfa_pair_lost=0
			mfa_pair_sent=0
			mfa_pair_back=0
			# The window a code must exceed is the highest of the bounds
			# this loop has read and the windows it picked to send. A read
			# replaces the value only with a number above it, or with any
			# number while it is still empty. The exit status is not looked
			# at, so a failed read that prints a higher number still counts.
			# Remembering only the previous one is not enough: a clock that
			# moves back two windows produces a code the server still
			# refuses, and the login half would then report that a correct
			# server rejected a valid code.
			#
			# A bound that could not be read is not the same as no bound.
			# With no bound nothing is spent, so a fresh code must be
			# accepted and a refusal is the server's to answer for. With
			# an unreadable one this loop does not know which windows are
			# spent, so it cannot tell a replay refusal it caused itself
			# from a wrong one. The two are separated here, and the
			# second is reported instead of blamed on the server.
			mfa_pair_read() {
				adb "SELECT IF(totp_last_used IS NULL, 'null', totp_last_used) FROM users WHERE user_id = ${MFA_UID}"
			}
			# The clock this loop judges a window by. Anything carrying a
			# character that is not a digit is blanked, and every use is
			# guarded on the result being non-empty. For output like
			# 'abc' the filter only suppresses the shell's diagnostic:
			# the bare comparison exits 2, which reads as false, and the
			# guarded one is false as well. For '-1', '+1' or a space-padded '1' it does
			# change the answer, because the shell accepts all three as
			# integers and would compare them. That is deliberate: a
			# clock that did not print an unsigned decimal cannot be used
			# to judge a window, and an unsigned decimal is all
			# mfa_window() prints. What keeps a spent window out of a
			# request is the break below, which compares the generated
			# window against that same highest of the bounds read and the
			# windows picked.
			mfa_pair_clock() {
				mfa_pair_now="$(mfa_window)"
				case "$mfa_pair_now" in
					*[!0-9]*) mfa_pair_now='' ;;
				esac
			}
			# mfa_pair_nobound records whether any re-read inside the
			# loop ever answered. The seed read does not clear it and no
			# later read sets it again, so cleared means at least one
			# in-loop read answered and set means none did -- not that
			# the read on the try which sent the code answered. The
			# unchecked-result branch below exists for a loop that cannot
			# tell a replay refusal it caused itself from a wrong one,
			# and only a bound this loop read can decide that.
			# Letting the seed clear the flag reported an undecidable
			# refusal as a correct server refusing a valid code: with
			# every in-loop read failing the spent window stays at the
			# seed until the first send raises it, so the loop can send a
			# window the server has since closed.
			mfa_pair_nobound=1
			mfa_pair_spent=''
			mfa_pair_seed="$(mfa_pair_read)"
			case "$mfa_pair_seed" in
				'') ;;
				*[!0-9]*) ;;
				*) mfa_pair_spent="$mfa_pair_seed" ;;
			esac
			while [ "$mfa_enrol_done" = 1 ] && [ "$mfa_pair_try" -lt 3 ] \
				&& [ "$mfa_pair_stable" = 0 ]; do
				mfa_pair_try=$((mfa_pair_try+1))
				# Re-read it, do not trust the seed. A server that stores
				# the clock's window at login too raises its bound above
				# every window this loop sent, so the window after the one
				# spent here is refused for the server's reason and the
				# login half would call that a correct code refused.
				# Raising the spent window to whatever the server now
				# holds asks the next question above both of them.
				mfa_pair_live="$(mfa_pair_read)"
				# 'null' or a number is an answer about what the server
				# holds; anything else, the empty string included, means
				# the row was not read. Only a number is a bound, and
				# only a number may reach the comparisons below, which
				# would exit 2 rather than answer on anything else.
				case "$mfa_pair_live" in
					null) mfa_pair_nobound=0; mfa_pair_live='' ;;
					'') mfa_pair_live='' ;;
					*[!0-9]*) mfa_pair_live='' ;;
					*) mfa_pair_nobound=0 ;;
				esac
				if [ -n "$mfa_pair_live" ] \
					&& { [ -z "$mfa_pair_spent" ] \
						|| [ "$mfa_pair_live" -gt "$mfa_pair_spent" ]; }; then
					mfa_pair_spent="$mfa_pair_live"
				fi
				mfa_wait_fresh
				# A retry must not send a code from a window already
				# spent: that is refused as a replay, which is the opposite
				# of what the login half is asking. Wait the clock past it.
				mfa_pair_waited=0
				mfa_pair_clock
				while [ -n "$mfa_pair_spent" ] && [ -n "$mfa_pair_now" ] \
					&& [ "$mfa_pair_now" -le "$mfa_pair_spent" ] \
					&& [ "$mfa_pair_waited" -lt 35 ]; do
					sleep 1
					mfa_pair_waited=$((mfa_pair_waited+1))
					mfa_pair_clock
				done
				# The cap is not a guarantee: a clock that stops at or
				# below the spent window reaches it and returns. Sending
				# that window's code would be refused as a replay, which is
				# exactly the answer the login half must not be given, so
				# leave both checks unclaimed rather than ask a question
				# with a known wrong answer.
				if [ -n "$mfa_pair_spent" ] && [ -n "$mfa_pair_now" ] \
					&& [ "$mfa_pair_now" -le "$mfa_pair_spent" ]; then
					break
				fi
				# One run for both, so the window this try is judged against
				# is the code's own window and not a separate clock reading.
				mfa_pair_set="$(mfa_code_pair "$MFA_SECRET")"
				mfa_pair_window="${mfa_pair_set%% *}"
				mfa_pair_code="${mfa_pair_set#* }"
				# The clock can also move back between the check above and
				# this run, so what was generated is compared as well, and
				# the spent window only ever rises. A generator that
				# produced nothing stops the loop for the same reason:
				# there is no code to ask the question with, and a window
				# that is not a plain number is no more usable than a
				# missing one -- it would make the comparison below exit 2
				# instead of answering, and the loop would then send a code
				# from a window it never checked was unspent.
				case "$mfa_pair_window" in
					*[!0-9]*) mfa_pair_window='' ;;
				esac
				if [ -z "$mfa_pair_window" ]; then
					break
				fi
				if [ -n "$mfa_pair_spent" ] \
					&& [ "$mfa_pair_window" -le "$mfa_pair_spent" ]; then
					break
				fi
				mfa_pair_spent="$mfa_pair_window"
				mfa_rl_clear
				mfa_login "$mfa_pair_code"
				mfa_pair_sent=$?
				mfa_pair_in=0
				if [ "$mfa_pair_sent" = 0 ] \
					&& ! grep -q 'login_pass' "$BODY" \
					&& grep -qi 'logout' "$BODY"; then
					mfa_pair_in=1
				fi
				# mfa_login truncates the cookie jar, so this is a fresh
				# sign-in attempt and not a request inside the session the
				# line above opened.
				mfa_rl_clear
				mfa_login "$mfa_pair_code"
				mfa_pair_back=$?
				mfa_pair_out=0
				if [ "$mfa_pair_back" = 0 ] && grep -q 'login_pass' "$BODY"; then
					mfa_pair_out=1
				fi
				# Either transfer failing ends the loop. The guards above
				# would hold a retry back until the clock passed a window
				# this loop knows it spent, but a request that did not
				# arrive spends nothing the loop can see, so what the
				# server now holds is unknown -- and the page left behind
				# says nothing about a request that never got there.
				if [ "$mfa_pair_sent" != 0 ] || [ "$mfa_pair_back" != 0 ]; then
					mfa_pair_lost=1
					break
				fi
				if [ "$(mfa_window)" = "$mfa_pair_window" ]; then
					mfa_pair_stable=1
				fi
			done
			# Which half a lost transfer costs depends on which one it
			# was. A sign-in that completed and succeeded is a sign-in,
			# whatever happened to the replay request after it, so that
			# answer is kept. A sign-in that completed and was refused
			# is not an answer here, because the window was never
			# confirmed to have held still and the code may simply have
			# aged out.
			if [ "$mfa_enrol_done" = 0 ]; then
				bad "this run did not confirm an enrolled account, so neither signing in with a current code nor refusing that code a second time was checked"
			elif [ "$mfa_pair_lost" = 1 ] && [ "$mfa_pair_sent" != 0 ]; then
				bad "the sign-in request did not complete, so neither the sign-in nor the replay was checked"
			elif [ "$mfa_pair_lost" = 1 ] && [ "$mfa_pair_in" = 1 ]; then
				ok "the password and a current code sign the account in"
			elif [ "$mfa_pair_lost" = 1 ]; then
				bad "the replay request did not complete and the sign-in before it was refused - whether the window held still is unknown, so neither was checked"
			elif [ "$mfa_pair_stable" = 0 ]; then
				bad "a login and a replay never landed in one unspent 30-second window - neither signing in with a current code nor refusing that code a second time was checked"
			elif [ "$mfa_pair_in" = 1 ]; then
				ok "the password and a current code sign the account in"
			elif [ "$mfa_pair_nobound" = 1 ]; then
				bad "the code was refused and the replay bound could not be read on any try, so a refusal this run caused itself cannot be told from a wrong one - neither check was decided"
			else
				bad "a valid password and a valid code were refused"
			fi
			# Claimed only where the code was accepted first. Refusing a code
			# that was never accepted says nothing about replay.
			#
			# A sign-in that completed and succeeded is kept as an answer
			# above even when the replay request after it was lost. This
			# half is not: its reply did not arrive, so whether the guard
			# ran is unknown -- the request itself may well have been
			# processed. Saying so is what makes the region emit two
			# assertions on that path. Without it the sign-in's ok was the
			# only line, and a run whose replay request timed out passed
			# with the replay guard -- the control this check exists for --
			# never evaluated. A sign-in that was refused needs the same
			# line for the same reason: the block above answers only the
			# sign-in half, so without this the region printed one
			# assertion and named nothing for the other.
			if [ "$mfa_pair_lost" = 1 ] && [ "$mfa_pair_sent" = 0 ] \
				&& [ "$mfa_pair_in" = 1 ]; then
				bad "the replay request did not complete, so whether a used code is refused a second time was not checked"
			elif [ "$mfa_enrol_done" = 1 ] && [ "$mfa_pair_lost" = 0 ] \
				&& [ "$mfa_pair_stable" = 1 ] && [ "$mfa_pair_in" = 0 ] \
				&& [ "$mfa_pair_nobound" = 0 ]; then
				bad "the code was refused, so whether a used code is refused a second time was not checked"
			elif [ "$mfa_pair_lost" = 0 ] && [ "$mfa_pair_stable" = 1 ] \
				&& [ "$mfa_pair_in" = 1 ]; then
				if [ "$mfa_pair_out" = 1 ]; then
					ok "the same code is refused a second time inside its own window"
				else
					bad "a used code was accepted a second time - the replay guard is not working"
				fi
			fi

			# 25f. The admin sees the enrolled state, and Reset sends the
			# account back to enrollment without turning the requirement off.
			mfa_admin_edit
			mfa_admin_got2=$?
			if [ "$mfa_enrol_done" = 0 ]; then
				bad "this run did not confirm an enrolled account, so neither the enrolled-state report nor the reset option was checked"
			elif [ "$mfa_admin_got2" != 0 ]; then
				bad "fetching the account form did not complete (curl exit ${mfa_admin_got2}) - neither enrolled-state check was run"
			else
				if grep -q 'An authenticator is enrolled' "$BODY"; then
					ok "the account form reports the enrolled device"
				else
					bad "the account form does not report the enrolled device"
				fi
				if grep -q '>Reset<' "$BODY"; then
					ok "the account form offers the reset option once a device is enrolled"
				else
					bad "the account form offers no reset option for an enrolled device"
				fi
			fi

			mfa_admin_set 2
			# An account with no secret passes the emptiness test for
			# free, so without an enrollment this reported that Reset had
			# dropped a device that was never there.
			if [ "$mfa_enrol_done" = 0 ]; then
				bad "this run did not confirm an enrolled account, so whether Reset drops the device and keeps the requirement was not checked"
			elif [ -z "$(adb "SELECT totp_secret FROM users WHERE user_id = ${MFA_UID} AND LENGTH(totp_secret) > 0")" ] \
				&& [ "$(adb "SELECT totp_enabled FROM users WHERE user_id = ${MFA_UID}")" = 1 ]; then
				ok "reset drops the device and keeps the requirement"
			else
				bad "reset did not drop the device, or turned the requirement off"
			fi
			if [ -n "$(adb "SELECT 1 FROM audit_log WHERE action = 'user.mfa_reset' LIMIT 1")" ]; then
				ok "audit_log recorded user.mfa_reset"
			else
				bad "audit_log has no user.mfa_reset row"
			fi
			mfa_rl_clear
			mfa_login
			mfa_reset_got=$?
			# An account that never enrolled is held at the enrollment
			# page after a Reset that did nothing, so this passed without
			# testing the reset. That is not true of whatever Reset did:
			# one that also turned the requirement off would have let the
			# account in, and this check would have detected that.
			if [ "$mfa_enrol_done" = 0 ]; then
				bad "this run did not confirm an enrolled account, so whether a reset account is sent back to the enrollment page was not checked"
			elif [ "$mfa_reset_got" != 0 ]; then
				bad "the login after a reset did not complete (curl exit ${mfa_reset_got}) - it was not checked"
			elif grep -q 'Set up Multi-Factor Authentication' "$BODY"; then
				ok "a reset account is sent back to the enrollment page"
			else
				bad "a reset account reached the application without enrolling"
			fi

			# 25g. Turning it off restores the plain password login.
			mfa_admin_set 0
			if [ "$(adb "SELECT totp_enabled FROM users WHERE user_id = ${MFA_UID}")" = 0 ]; then
				ok "the admin form turns MFA off"
			else
				bad "the admin form did not turn MFA off"
			fi
			if [ -n "$(adb "SELECT 1 FROM audit_log WHERE action = 'user.mfa_disabled' LIMIT 1")" ]; then
				ok "audit_log recorded user.mfa_disabled"
			else
				bad "audit_log has no user.mfa_disabled row"
			fi
			mfa_rl_clear
			mfa_login
			mfa_off_got=$?
			if [ "$mfa_off_got" != 0 ]; then
				bad "the login after MFA was turned off did not complete (curl exit ${mfa_off_got}) - it was not checked"
			elif ! grep -q 'login_pass' "$BODY" && grep -qi 'logout' "$BODY"; then
				ok "the account signs in with a password again"
			else
				bad "the account cannot sign in after MFA was turned off"
			fi
		fi

		# 25h. The key that encrypts the secrets stays in the settings file.
		# pl_settings_save() copies the merged settings array into the table,
		# so a missing unset() there would publish it to every admin page.
		if [ -z "$(adb "SELECT 1 FROM settings WHERE label = 'totp_encryption_key'")" ]; then
			ok "totp_encryption_key is not in the settings table"
		else
			bad "totp_encryption_key was written to the settings table - it belongs only in the settings file"
		fi
		# The value looked for is the key this stack actually runs on, so the
		# check cannot pass against a placeholder.
		MFA_KEY="$(docker compose "${COMPOSE_ARGS[@]}" exec -T app \
			cat /var/www/html/cms-custom/config/totp_encryption_key 2>/dev/null \
			| tr -d '\r\n')"
		: > "$BODY"
		curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" \
			"$OCM_URL/search.php?s=%25%25%5Btotp_encryption_key%5D%25%25" >/dev/null
		mfa_key_got=$?
		if [ "$mfa_key_got" != 0 ]; then
			bad "fetching the search page did not complete (curl exit ${mfa_key_got}) - the key tag was not checked"
		elif grep -q 'name="s" size="48" value=""' "$BODY" \
			&& { [ -z "$MFA_KEY" ] || ! grep -qF "$MFA_KEY" "$BODY"; }
		then
			ok "a totp_encryption_key tag in the search box resolves to nothing"
		else
			bad "search.php resolved the totp_encryption_key setting"
		fi
	fi

	cleanup_mfa
	trap 'rm -f "$COOKIES" "$BODY"' EXIT
else
	printf '  skip the MFA checks (needs a running stack, the database and python3)\n'
fi

echo
echo "26. single sign-on"
# The whole authorization-code flow, driven end to end against a fake OpenID
# Connect provider this section installs into the container and deletes again.
# There is no browser: curl follows the two redirects, which is all a browser
# contributes to this flow.
#
# The point of a fake provider rather than a mock inside the application is
# that every check the application makes is exercised against a real signature
# over a real JWT: the provider signs with an RSA key it generates, publishes
# the matching JWKS, and enforces PKCE. It can also be told to misbehave, one
# word per behaviour in a flags file, so the section proves the application
# refuses a bad token as well as accepting a good one.
if [ "$HAVE_DB" = 1 ] && [ "$HAVE_COMPOSE" = 1 ]; then
	if [ -n "$(adb "SHOW COLUMNS FROM users LIKE 'sso_subject'")" ]; then
		ok "users.sso_subject column exists"
	else
		bad "users.sso_subject column is MISSING (add_sso.sql did not run)"
	fi
	if [ -n "$(adb "SHOW COLUMNS FROM users LIKE 'auth_method'")" ]; then
		ok "users.auth_method column exists"
	else
		bad "users.auth_method column is MISSING (add_sso.sql did not run)"
	fi
	if [ -n "$(adb "SHOW TABLES LIKE 'pika_sso_oidc_state'")" ]; then
		ok "pika_sso_oidc_state table exists"
	else
		bad "pika_sso_oidc_state table is MISSING (add_sso.sql did not run)"
	fi
	if [ "$(adb "SELECT COUNT(*) FROM settings WHERE label LIKE 'sso\\_%'")" -ge 11 ]; then
		ok "the sso_ settings rows are seeded"
	else
		bad "add_sso.sql did not seed the sso_ settings rows"
	fi

	SSO_GROUP='zz_sso_grp'
	SSO_USER='zz_sso_user'
	SSO_PASS='zz-sso-Passw0rd'
	SSO_SUB='zz-idp-subject-0001'
	SSO_MAIL='zz_sso_user@zz-sso.example'
	SSO_BIND_USER='zz_sso_bind'
	SSO_BIND_SUB='zz-idp-subject-0002'
	SSO_BIND_MAIL='zz_sso_bind@zz-sso.example'
	SSO_CLIENT='zz-ocm-ci-client'
	SSO_SECRET='zz-ocm-ci-secret'
	SSO_JAR="$(mktemp)"
	SSO_IDP='/var/www/html/cms/zz_test_idp.php'
	SSO_DIR='/tmp/zz_test_idp'
	# The container reaches itself on port 80; the test reaches it on the
	# published port. The provider's discovery document hands each side the
	# base it can actually use, which is why it needs both.
	SSO_PATH="$(printf '%s' "$OCM_URL" | sed -E 's#^[a-z]+://[^/]*##')"
	SSO_BROWSER="${OCM_URL}/zz_test_idp.php"
	SSO_SERVER="http://localhost${SSO_PATH}/zz_test_idp.php"
	SSO_ISSUER="http://localhost${SSO_PATH}/zz_test_idp"

	dex() { docker compose "${COMPOSE_ARGS[@]}" exec -T app "$@"; }
	sso_set() { adb "UPDATE settings SET value = '$2' WHERE label = '$1'" >/dev/null; }
	# One word per requested misbehaviour, or nothing for a well-behaved
	# provider. Written on every call so a flag cannot leak into a later step.
	sso_flags() { printf '%s' "${1:-}" | dex sh -c "cat > ${SSO_DIR}/flags"; }

	cleanup_sso() {
		adb "DELETE FROM users WHERE username IN ('${SSO_USER}', '${SSO_BIND_USER}')" >/dev/null
		adb "DELETE FROM \`groups\` WHERE group_id = '${SSO_GROUP}'" >/dev/null
		adb "DELETE FROM pika_sso_oidc_state" >/dev/null
		adb "UPDATE settings SET value = '' WHERE label LIKE 'sso\\_%'" >/dev/null
		adb "UPDATE settings SET value = '0' WHERE label IN
			('sso_enabled', 'sso_autobind_by_email', 'sso_allow_insecure_transport')" >/dev/null
		dex rm -rf "$SSO_IDP" "$SSO_DIR" >/dev/null 2>&1 || true
		rm -f "$SSO_JAR"
	}
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_sso' EXIT

	cleanup_sso
	# Created by docker exec, which is root; written by the provider, which runs
	# as the web server user. The directory holds nothing but throwaway
	# authorization codes inside a test container.
	dex mkdir -p "$SSO_DIR" >/dev/null 2>&1
	dex chmod 0777 "$SSO_DIR" >/dev/null 2>&1

	# 26a. Nothing is offered and nothing is reachable before it is set up.
	curl -s --max-time 30 -o "$BODY" "$OCM_URL/" >/dev/null
	if grep -q 'id="sso_login"' "$BODY"; then
		bad "the login page offers single sign-on while it is switched off"
	else
		ok "the login page offers no SSO button while SSO is off"
	fi
	code="$(curl -s --max-time 30 -o "$BODY" -w '%{http_code}' "$OCM_URL/services/sso/login.php")"
	if [ "$code" = 404 ]; then
		ok "services/sso/login.php is a 404 while SSO is not configured"
	else
		bad "services/sso/login.php answered $code with SSO unconfigured - it must look like a build without the feature"
	fi

	# Install the provider and point the application at it.
	dex sh -c "cat > ${SSO_IDP}" < "${SMOKE_DIR}/fixtures/zz_test_idp.php"
	dex sh -c "cat > ${SSO_DIR}/config.json" <<SSOCFG
{
	"issuer": "${SSO_ISSUER}",
	"browser_base": "${SSO_BROWSER}",
	"server_base": "${SSO_SERVER}",
	"client_id": "${SSO_CLIENT}",
	"client_secret": "${SSO_SECRET}",
	"sub": "${SSO_SUB}",
	"email": "${SSO_MAIL}"
}
SSOCFG
	sso_flags ''

	sso_set sso_provider generic
	sso_set sso_issuer_url "$SSO_ISSUER"
	sso_set sso_discovery_url "${SSO_SERVER}?ep=discovery"
	sso_set sso_client_id "$SSO_CLIENT"
	sso_set sso_client_secret "$SSO_SECRET"
	# http endpoints, for this harness only. There is no field for this on any
	# admin screen; see cms/app/sql/upgrades/add_sso.sql.
	sso_set sso_allow_insecure_transport 1
	sso_set sso_enabled 1

	# read_all so a signed-in session lands on a page with content in it.
	adb "INSERT INTO \`groups\` (group_id, read_office, read_all, edit_office, edit_all, users, pba, motd, intake, reports)
		VALUES ('${SSO_GROUP}', NULL, 1, NULL, 0, 0, 0, 0, 0, NULL)" >/dev/null
	SSO_HASH="$(dex php -r 'echo password_hash($argv[1], PASSWORD_DEFAULT);' "$SSO_PASS" </dev/null 2>/dev/null)"
	SSO_UID="$(adb "SELECT COALESCE(MAX(user_id), 0) + 1 FROM users")"
	adb "INSERT INTO users (user_id, username, password, enabled, group_id, password_expire,
			email, auth_method, sso_subject)
		VALUES (${SSO_UID}, '${SSO_USER}', '${SSO_HASH}', 1, '${SSO_GROUP}', 0,
			'${SSO_MAIL}', 'sso', '${SSO_SUB}')" >/dev/null

	# The provider is only useful if it is actually serving. Check that before
	# blaming the application for anything below.
	curl -s --max-time 30 -o "$BODY" "${SSO_BROWSER}?ep=discovery" >/dev/null
	if grep -q '"authorization_endpoint"' "$BODY"; then
		ok "the test identity provider serves its discovery document"
	else
		bad "the test identity provider did not serve a discovery document - the rest of this section cannot be trusted"
	fi

	# Drive the whole flow: login.php -> authorize -> callback -> home page.
	# $1 is the flags string handed to the provider.
	sso_flow() {
		sso_flags "${1:-}"
		: > "$SSO_JAR"
		curl -sL --max-time 30 -c "$SSO_JAR" -b "$SSO_JAR" -o "$BODY" \
			-w '%{http_code}' "$OCM_URL/services/sso/login.php"
	}

	if [ -z "${SSO_UID:-}" ] || [ -z "$SSO_HASH" ]; then
		bad "could not seed the SSO fixtures (user/hash)"
	else
		# 26b. The login page now offers it, and the redirect carries the
		# three values that make the round trip safe.
		curl -s --max-time 30 -o "$BODY" "$OCM_URL/" >/dev/null
		if grep -q 'id="sso_login"' "$BODY" && grep -q 'services/sso/login.php' "$BODY"; then
			ok "the login page offers single sign-on once it is configured"
		else
			bad "the login page offers no SSO button with SSO configured"
		fi

		: > "$SSO_JAR"
		SSO_REDIRECT="$(curl -s --max-time 30 -c "$SSO_JAR" -b "$SSO_JAR" \
			-o /dev/null -w '%{redirect_url}' "$OCM_URL/services/sso/login.php")"
		case "$SSO_REDIRECT" in
			*ep=authorize*state=*) ok "login.php redirects to the provider with a state" ;;
			*) bad "login.php did not redirect to the authorize endpoint with a state: ${SSO_REDIRECT}" ;;
		esac
		case "$SSO_REDIRECT" in
			*code_challenge_method=S256*) ok "the redirect carries a PKCE S256 challenge" ;;
			*) bad "the redirect carries no PKCE challenge - an intercepted code would be enough on its own" ;;
		esac
		case "$SSO_REDIRECT" in
			*nonce=*) ok "the redirect carries a nonce" ;;
			*) bad "the redirect carries no nonce - an ID token from an earlier sign-in could be replayed" ;;
		esac
		case "$SSO_REDIRECT" in
			*client_secret*) bad "the redirect leaks the client secret into the browser" ;;
			*) ok "the redirect carries no client secret" ;;
		esac
		if [ "$(adb "SELECT COUNT(*) FROM pika_sso_oidc_state")" = 3 ]; then
			ok "the handshake stored a state, a nonce and a verifier"
		else
			bad "pika_sso_oidc_state holds $(adb "SELECT COUNT(*) FROM pika_sso_oidc_state") rows, expected 3"
		fi

		# 26c. The happy path signs the account in.
		# The step above started a handshake and walked away from it, in a
		# session of its own. Clear it, so that what is left in the table after
		# the flow below is only what that flow left.
		adb "DELETE FROM pika_sso_oidc_state" >/dev/null
		code="$(sso_flow '')"
		if [ "$code" = 200 ] && ! grep -q 'login_pass' "$BODY" && grep -qi 'logout' "$BODY"; then
			ok "a well-formed SSO sign-in lands on the application"
		else
			bad "the SSO sign-in did not reach the application (status $code)"
		fi
		if [ -n "$(adb "SELECT 1 FROM audit_log WHERE action = 'sso.login.success' LIMIT 1")" ]; then
			ok "audit_log recorded sso.login.success"
		else
			bad "audit_log has no sso.login.success row"
		fi
		# The session must survive the redirect, not just render one page.
		curl -sL --max-time 30 -b "$SSO_JAR" -c "$SSO_JAR" -o "$BODY" "$OCM_URL/case_list.php" >/dev/null
		if ! grep -q 'login_pass' "$BODY"; then
			ok "the SSO session is still valid on the next request"
		else
			bad "the SSO session did not survive one further request"
		fi
		if [ "$(adb "SELECT COUNT(*) FROM pika_sso_oidc_state")" = 0 ]; then
			ok "the handshake rows are deleted once the callback has read them"
		else
			bad "pika_sso_oidc_state still holds rows after a completed sign-in - a code could be replayed"
		fi

		# 26d. Every way the provider can misbehave is refused.
		sso_refused() {
			code="$(sso_flow "$2")"
			if [ "$code" != 200 ] && ! grep -qi 'logout' "$BODY"; then
				ok "$1"
			else
				bad "$1 - the sign-in was accepted (status $code)"
			fi
		}
		sso_refused "a token signed with an unpublished key is refused" wrongkey
		sso_refused "a token with an unknown kid is refused" badkid
		sso_refused "a token signed with HS256 is refused" badalg
		sso_refused "a token with the wrong nonce is refused" badnonce
		sso_refused "a token with the wrong issuer is refused" badissuer
		sso_refused "a token with the wrong audience is refused" badaudience
		sso_refused "an expired token is refused" expired
		sso_refused "a token with no subject claim is refused" nosub
		sso_refused "a callback whose state does not match is refused" badstate

		# The reasons are in the log, not in the response.
		if [ -n "$(adb "SELECT 1 FROM audit_log WHERE action = 'sso.login.failure' LIMIT 1")" ]; then
			ok "audit_log recorded the refusals as sso.login.failure"
		else
			bad "audit_log has no sso.login.failure row - the reasons went nowhere"
		fi
		if grep -qE 'bad_signature|bad_nonce|bad_issuer|unknown_signing_key' "$BODY"; then
			bad "the refusal page names the specific reason - that belongs in the log only"
		else
			ok "the refusal page does not name the specific reason"
		fi

		# 26e. A callback with no handshake behind it is refused, and a
		# replayed code is exactly that case.
		sso_flags ''
		code="$(curl -s --max-time 30 -o "$BODY" -w '%{http_code}' \
			"$OCM_URL/services/sso/callback.php?code=zzfake&state=zzfake")"
		if [ "$code" = 400 ]; then
			ok "a callback with no stored handshake is refused"
		else
			bad "a callback with no stored handshake answered $code"
		fi

		# 26f. The password form will not take this account.
		mfa_rl_clear 2>/dev/null || dex rm -rf /tmp/ocm_auth_rl >/dev/null 2>&1 || true
		: > "$SSO_JAR"
		curl -sL --max-time 30 -c "$SSO_JAR" -b "$SSO_JAR" -o "$BODY" \
			-d "login_user=${SSO_USER}&login_pass=${SSO_PASS}&auth_id=1" "$OCM_URL/" >/dev/null
		if grep -q 'login_pass' "$BODY"; then
			ok "the password form refuses an account whose method is SSO"
		else
			bad "the password form signed in an account whose method is SSO - a second way in"
		fi
		# The refusal must be the same page a name that is not a user at all
		# gets. Anything that differs -- wording, a hint, a different length --
		# tells whoever is asking that this name is an account here and that it
		# has been moved to single sign-on.
		SSO_REFUSAL="$(mktemp)"
		sed -E 's/[0-9a-f]{64}//g' "$BODY" > "$SSO_REFUSAL"
		mfa_rl_clear 2>/dev/null || dex rm -rf /tmp/ocm_auth_rl >/dev/null 2>&1 || true
		: > "$SSO_JAR"
		curl -sL --max-time 30 -c "$SSO_JAR" -b "$SSO_JAR" -o "$BODY" \
			-d "login_user=zz_no_such_account&login_pass=${SSO_PASS}&auth_id=1" "$OCM_URL/" >/dev/null
		if sed -E 's/[0-9a-f]{64}//g' "$BODY" | diff -q - "$SSO_REFUSAL" >/dev/null; then
			ok "the refusal is the same page an unknown username gets"
		else
			bad "the SSO account's refusal page differs from an unknown username's - that is an enumeration oracle"
		fi
		rm -f "$SSO_REFUSAL"
		if [ -n "$(adb "SELECT 1 FROM audit_log WHERE action = 'login.failure'
			AND details LIKE '%auth_method_sso%' LIMIT 1")" ]; then
			ok "audit_log recorded the refusal with reason auth_method_sso"
		else
			bad "audit_log has no login.failure row with reason auth_method_sso"
		fi

		# 26g. Automatic binding, which is off by default and refuses
		# everything while the domain list is empty.
		adb "INSERT INTO users (user_id, username, password, enabled, group_id,
				password_expire, email, auth_method)
			VALUES (${SSO_UID} + 1, '${SSO_BIND_USER}', '${SSO_HASH}', 1, '${SSO_GROUP}', 0,
				'${SSO_BIND_MAIL}', 'password')" >/dev/null
		SSO_BIND_UID="$(adb "SELECT user_id FROM users WHERE username = '${SSO_BIND_USER}'")"
		dex sh -c "cat > ${SSO_DIR}/config.json" <<SSOCFG2
{
	"issuer": "${SSO_ISSUER}",
	"browser_base": "${SSO_BROWSER}",
	"server_base": "${SSO_SERVER}",
	"client_id": "${SSO_CLIENT}",
	"client_secret": "${SSO_SECRET}",
	"sub": "${SSO_BIND_SUB}",
	"email": "${SSO_BIND_MAIL}"
}
SSOCFG2

		code="$(sso_flow '')"
		if [ "$code" != 200 ] || grep -q 'login_pass' "$BODY"; then
			ok "an unknown subject is refused while automatic binding is off"
		else
			bad "an unknown subject was signed in with automatic binding off"
		fi

		sso_set sso_autobind_by_email 1
		code="$(sso_flow '')"
		if [ "$code" != 200 ] || grep -q 'login_pass' "$BODY"; then
			ok "automatic binding is refused while the domain list is empty"
		else
			bad "automatic binding accepted a domain with an empty allowlist - the empty list must refuse everything"
		fi

		sso_set sso_autobind_domains 'zz-somewhere-else.example'
		code="$(sso_flow '')"
		if [ "$code" != 200 ] || grep -q 'login_pass' "$BODY"; then
			ok "automatic binding is refused for a domain not on the list"
		else
			bad "automatic binding accepted a domain that is not on the allowlist"
		fi

		sso_set sso_autobind_domains 'zz-sso.example'
		code="$(sso_flow '')"
		if [ "$code" = 200 ] && ! grep -q 'login_pass' "$BODY" && grep -qi 'logout' "$BODY"; then
			ok "automatic binding signs in a matching account on the allowed domain"
		else
			bad "automatic binding did not sign in a matching account (status $code)"
		fi
		if [ "$(adb "SELECT sso_subject FROM users WHERE user_id = ${SSO_BIND_UID}")" = "$SSO_BIND_SUB" ]; then
			ok "the bound account carries the provider's subject"
		else
			bad "the bound account did not record the subject"
		fi
		if [ "$(adb "SELECT auth_method FROM users WHERE user_id = ${SSO_BIND_UID}")" = 'sso' ]; then
			ok "the bound account's method is now SSO"
		else
			bad "the bound account still signs in with a password"
		fi
		if [ -z "$(adb "SELECT password FROM users WHERE user_id = ${SSO_BIND_UID}")" ]; then
			ok "binding removed the account's password"
		else
			bad "binding left the password hash in place - a second way in that nobody is watching"
		fi
		if [ -n "$(adb "SELECT 1 FROM audit_log WHERE action = 'sso.autobind' LIMIT 1")" ]; then
			ok "audit_log recorded sso.autobind"
		else
			bad "audit_log has no sso.autobind row"
		fi

		# A disabled account is refused even with a subject already on it.
		adb "UPDATE users SET enabled = 0 WHERE user_id = ${SSO_BIND_UID}" >/dev/null
		code="$(sso_flow '')"
		if [ "$code" != 200 ] || grep -q 'login_pass' "$BODY"; then
			ok "a disabled account is refused at the callback"
		else
			bad "a disabled account was signed in through SSO"
		fi
		adb "UPDATE users SET enabled = 1 WHERE user_id = ${SSO_BIND_UID}" >/dev/null

		# 26h. The client secret does not leave the server.
		# Sections above have logged other accounts in and out; take a fresh
		# admin session rather than trusting the one from section 3.
		: > "$COOKIES"
		curl -sL --max-time 30 -c "$COOKIES" -b "$COOKIES" -o /dev/null \
			-d "login_user=${OCM_USER}&login_pass=${OCM_PASSWORD}&auth_id=1" "$OCM_URL/" >/dev/null
		curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" "$OCM_URL/system-settings.php" >/dev/null
		if grep -qF "$SSO_SECRET" "$BODY"; then
			bad "system-settings.php renders the SSO client secret"
		else
			ok "system-settings.php does not render the SSO client secret"
		fi
		curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" \
			"$OCM_URL/search.php?s=%25%25%5Bsso_client_secret%5D%25%25" >/dev/null
		if grep -q 'name="s" size="48" value=""' "$BODY" && ! grep -qF "$SSO_SECRET" "$BODY"; then
			ok "an sso_client_secret tag in the search box resolves to nothing"
		else
			bad "search.php resolved the sso_client_secret setting"
		fi
		# Saving the settings form without retyping the secret must keep it.
		curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" "$OCM_URL/system-settings.php" >/dev/null
		sso_tok="$(grep -oE 'name="_csrf" value="[0-9a-f]*"' "$BODY" \
			| head -1 | sed -E 's/.*value="([0-9a-f]*)".*/\1/')"
		sm_reauth_post settings "$OCM_URL/system-settings.php" \
			-d "action=update&_csrf=${sso_tok}" \
			-d "sso_client_secret="
		if [ "$(adb "SELECT value FROM settings WHERE label = 'sso_client_secret'")" = "$SSO_SECRET" ]; then
			ok "saving the form with the secret field blank keeps the stored secret"
		else
			bad "an empty secret field erased the stored client secret"
		fi
	fi

	cleanup_sso
	trap 'rm -f "$COOKIES" "$BODY"' EXIT
else
	printf '  skip the SSO checks (needs a running stack and the database)\n'
fi

# ── 27. Peer case transfer ─────────────────────────────────────────────────
# cms/services/transfer_case.php takes a case, a contact or an activity pushed
# in by another OCM installation, authenticated with HTTP Basic. The body used
# to be read with unserialize(), which lets whoever holds a peer password name
# the classes this server builds. It now wants signed JSON, and the old format
# is refused unless an operator turns it back on.
#
# Needs the database: the settings the endpoint reads are rows, and the
# assertions about what was audited are rows too.
echo
echo "27. peer case transfer"
if [ "$HAVE_DB" = 1 ]; then
	PT_URL="$OCM_URL/services/transfer_case.php"
	PT_LSXML_URL="$OCM_URL/services/transfer_case_lsxml.php"
	PT_SECRET='smoke-peer-transfer-secret'
	lsxml_case_id=''
	xss_case_id=''
	# judge_name is a plain varchar on cases, so a value written through the
	# endpoint can be read straight back out and compared.
	PT_BODY='{"judge_name":"SmokePeerTransfer","court_city":"Smokeville"}'

	pt_settings_save() {
		PT_OLD_SECRET="$(adb "SELECT value FROM settings WHERE label = 'peer_transfer_shared_secret'")"
		PT_OLD_LEGACY="$(adb "SELECT value FROM settings WHERE label = 'peer_transfer_allow_legacy_unserialize'")"
	}
	pt_settings_restore() {
		adb "UPDATE settings SET value = '$(printf '%s' "$PT_OLD_SECRET" | sed "s/'/''/g")' WHERE label = 'peer_transfer_shared_secret'" >/dev/null
		adb "UPDATE settings SET value = '$(printf '%s' "$PT_OLD_LEGACY" | sed "s/'/''/g")' WHERE label = 'peer_transfer_allow_legacy_unserialize'" >/dev/null
	}
	pt_set() { adb "UPDATE settings SET value = '$2' WHERE label = '$1'" >/dev/null; }

	# The signature the sending side computes, over the three fields together.
	pt_sign() {
		printf '%s\n%s\n%s' "$1" "$2" "$3" \
			| openssl dgst -sha256 -hmac "$PT_SECRET" -r | cut -d' ' -f1
	}

	# POST a signed JSON packet. $1 action, $2 payload, $3 ts, $4 signature.
	# Prints the status code; the body lands in $BODY.
	pt_post_json() {
		curl -s --max-time 30 -o "$BODY" -w '%{http_code}' \
			-u "${OCM_USER}:${OCM_PASSWORD}" \
			--data-urlencode "action=$1" \
			--data-urlencode "payload=$2" \
			--data-urlencode 'format=json' \
			--data-urlencode "ts=$3" \
			--data-urlencode "signature=$4" \
			"$PT_URL"
	}

	# POST an old-style serialize() packet, with no format field at all.
	pt_post_legacy() {
		curl -s --max-time 30 -o "$BODY" -w '%{http_code}' \
			-u "${OCM_USER}:${OCM_PASSWORD}" \
			--data-urlencode "action=$1" \
			--data-urlencode "payload=$2" \
			"$PT_URL"
	}

	if ! command -v openssl >/dev/null 2>&1; then
		printf '  skip the peer transfer checks (needs openssl to sign a packet)\n'
	elif [ -z "$(adb "SELECT 1 FROM settings WHERE label = 'peer_transfer_shared_secret'")" ]; then
		bad "the settings table has no peer_transfer_shared_secret row — add_peer_transfer.sql did not run"
	else
		pt_settings_save

		# 27a. The state a fresh install is in: no secret, legacy off. Both
		# body formats must be refused, so an installation whose operator has
		# never heard of peer transfer is not running a deserializer for
		# anybody who guesses a password.
		pt_set peer_transfer_shared_secret ''
		pt_set peer_transfer_allow_legacy_unserialize '0'

		code="$(pt_post_legacy newCase 'a:1:{s:10:"judge_name";s:5:"Smoke";}')"
		if [ "$code" = 403 ] && grep -q 'legacy_unserialize_disabled' "$BODY"; then
			ok "a serialize() body is refused by default"
		else
			bad "a serialize() body was not refused by default (status $code)"
		fi

		ts="$(date +%s)"
		code="$(pt_post_json newCase "$PT_BODY" "$ts" "$(pt_sign newCase "$PT_BODY" "$ts")")"
		if [ "$code" = 403 ] && grep -q 'shared_secret_not_configured' "$BODY"; then
			ok "a signed packet is refused while no shared secret is set"
		else
			bad "a signed packet was accepted with no shared secret configured (status $code)"
		fi

		if [ -n "$(adb "SELECT 1 FROM audit_log WHERE action = 'peer_transfer.rejected' LIMIT 1")" ]; then
			ok "audit_log recorded peer_transfer.rejected"
		else
			bad "audit_log has no peer_transfer.rejected row"
		fi

		# 27b. With a secret configured, a correctly signed packet works.
		pt_set peer_transfer_shared_secret "$PT_SECRET"

		ts="$(date +%s)"
		code="$(pt_post_json newCase "$PT_BODY" "$ts" "$(pt_sign newCase "$PT_BODY" "$ts")")"
		new_case_id="$(cat "$BODY")"
		case "$new_case_id" in
			''|*[!0-9]*) new_case_id='' ;;
		esac
		if [ "$code" = 200 ] && [ -n "$new_case_id" ]; then
			ok "a correctly signed newCase packet is accepted (case $new_case_id)"
		else
			bad "a correctly signed newCase packet was refused (status $code, body $(head -c 80 "$BODY"))"
		fi
		if [ -n "$(adb "SELECT 1 FROM audit_log WHERE action = 'peer_transfer.accepted' LIMIT 1")" ]; then
			ok "audit_log recorded peer_transfer.accepted"
		else
			bad "audit_log has no peer_transfer.accepted row"
		fi
		if [ -n "$new_case_id" ] \
			&& [ "$(adb "SELECT judge_name FROM cases WHERE case_id = ${new_case_id}")" = 'SmokePeerTransfer' ]; then
			ok "the transferred case row carries the values from the JSON body"
		else
			bad "the transferred case row does not carry the values from the JSON body"
		fi

		# 27c. Every way of getting the signature wrong.
		ts="$(date +%s)"
		good_sig="$(pt_sign newCase "$PT_BODY" "$ts")"

		# Change the last character to one it is not. Flipping it to a fixed
		# '0' passed the good signature back unchanged whenever the digest
		# happened to end in '0', which is one run in sixteen.
		case "$good_sig" in
			*0) bad_sig="${good_sig%?}1" ;;
			*)  bad_sig="${good_sig%?}0" ;;
		esac
		code="$(pt_post_json newCase "$PT_BODY" "$ts" "$bad_sig")"
		if [ "$code" = 403 ] && grep -q 'bad_signature' "$BODY"; then
			ok "a packet with one flipped signature character is refused"
		else
			bad "a packet with a wrong signature was accepted (status $code)"
		fi

		code="$(pt_post_json newCase "$PT_BODY" "$ts" '')"
		if [ "$code" = 403 ]; then
			ok "a packet with an empty signature is refused"
		else
			bad "a packet with an empty signature was accepted (status $code)"
		fi

		# The signature covers the action as well as the body, so a captured
		# packet cannot be replayed under a different action.
		code="$(pt_post_json newContact "$PT_BODY" "$ts" "$good_sig")"
		if [ "$code" = 403 ] && grep -q 'bad_signature' "$BODY"; then
			ok "a signature from one action does not authorise another"
		else
			bad "a newCase signature was accepted for newContact (status $code)"
		fi

		# ...and it covers the timestamp, so the window cannot be widened by
		# editing ts and keeping the signature.
		old_ts=$(( $(date +%s) - 400 ))
		code="$(pt_post_json newCase "$PT_BODY" "$old_ts" "$(pt_sign newCase "$PT_BODY" "$old_ts")")"
		if [ "$code" = 403 ] && grep -q 'ts_out_of_window' "$BODY"; then
			ok "a correctly signed packet 400 seconds old is refused"
		else
			bad "a packet 400 seconds old was accepted (status $code)"
		fi

		code="$(pt_post_json newCase "$PT_BODY" 'not-a-number' "$good_sig")"
		if [ "$code" = 403 ] && grep -q 'invalid_ts' "$BODY"; then
			ok "a non-numeric timestamp is refused"
		else
			bad "a non-numeric timestamp was accepted (status $code)"
		fi

		# A body that is not JSON at all.
		ts="$(date +%s)"
		code="$(pt_post_json newCase 'not json' "$ts" "$(pt_sign newCase 'not json' "$ts")")"
		if [ "$code" = 403 ] && grep -q 'bad_json_payload' "$BODY"; then
			ok "a signed body that is not JSON is refused"
		else
			bad "a signed body that is not JSON was accepted (status $code)"
		fi

		# 27d. The legacy path, once an operator has turned it on, still must
		# not build an object out of the wire. allowed_classes => false makes
		# a serialized object come out as __PHP_Incomplete_Class, which is not
		# an array, so the endpoint refuses it.
		pt_set peer_transfer_allow_legacy_unserialize '1'

		code="$(pt_post_legacy newCase 'O:8:"pikaCase":0:{}')"
		if [ "$code" = 403 ] && grep -q 'bad_serialized_payload' "$BODY"; then
			ok "a serialized object is refused even on the legacy path"
		else
			bad "a serialized object was accepted on the legacy path (status $code) — object injection"
		fi

		code="$(pt_post_legacy newCase 'a:1:{s:10:"judge_name";s:11:"SmokeLegacy";}')"
		legacy_case_id="$(cat "$BODY")"
		case "$legacy_case_id" in
			''|*[!0-9]*) legacy_case_id='' ;;
		esac
		if [ "$code" = 200 ] && [ -n "$legacy_case_id" ]; then
			ok "a serialized array still works once legacy is turned on"
		else
			bad "the legacy path is broken for a plain array (status $code)"
		fi

		pt_set peer_transfer_allow_legacy_unserialize '0'

		# 27e. The shared secret does not come back out of the application.
		# Anybody holding it can sign a case of their choosing into this
		# installation, so it belongs in the same class as the SSO secret.
		: > "$COOKIES"
		curl -sL --max-time 30 -c "$COOKIES" -b "$COOKIES" -o /dev/null \
			-d "login_user=${OCM_USER}&login_pass=${OCM_PASSWORD}&auth_id=1" "$OCM_URL/" >/dev/null
		curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" "$OCM_URL/system-settings.php" >/dev/null
		if grep -qF "$PT_SECRET" "$BODY"; then
			bad "system-settings.php renders the peer transfer shared secret"
		else
			ok "system-settings.php does not render the peer transfer shared secret"
		fi

		# But it does have to offer somewhere to type it, because the wiki
		# tells the operator to set both of these under System Settings.
		if grep -q 'name="peer_transfer_shared_secret"' "$BODY" \
			&& grep -q 'A shared secret is stored' "$BODY"; then
			ok "system-settings.php offers a write-only shared secret field"
		else
			bad "system-settings.php has no peer transfer shared secret field"
		fi

		# The checkbox needs its hidden 0 companion. Without it an unchecked
		# box posts nothing, the isset() test in system-settings.php skips
		# the key, and the setting can be turned on but never off.
		if grep -q '<input type="hidden" name="peer_transfer_allow_legacy_unserialize" value="0"' "$BODY" \
			&& grep -q '<input type="checkbox" name="peer_transfer_allow_legacy_unserialize"' "$BODY"; then
			ok "the legacy transfer format checkbox can be turned back off"
		else
			bad "peer_transfer_allow_legacy_unserialize has no off state on the form"
		fi

		curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" \
			"$OCM_URL/search.php?s=%25%25%5Bpeer_transfer_shared_secret%5D%25%25" >/dev/null
		if grep -qF "$PT_SECRET" "$BODY"; then
			bad "search.php resolved the peer transfer shared secret into the page"
		else
			ok "a peer_transfer_shared_secret tag in the search box resolves to nothing"
		fi

		# 27f. The LSXML variant of the same endpoint. Two things: an XML
		# document may not make this server read a file of the sender's
		# choosing, and the reply is the new case id rather than a dump of
		# every column of the row we just wrote.
		code="$(curl -s --max-time 30 -o "$BODY" -w '%{http_code}' \
			-u "${OCM_USER}:${OCM_PASSWORD}" \
			--data-urlencode 'lsxml=<?xml version="1.0"?><!DOCTYPE r [<!ENTITY xx SYSTEM "file:///etc/passwd">]><ClientIntake><Client><NameFirst>&xx;</NameFirst></Client></ClientIntake>' \
			"$PT_LSXML_URL")"
		if grep -q 'root:x:' "$BODY"; then
			bad "the LSXML endpoint READ /etc/passwd out of a DOCTYPE declaration"
		elif [ "$code" = 400 ]; then
			ok "the LSXML endpoint refuses a document with a DOCTYPE declaration"
		else
			bad "an XML document with a DOCTYPE was not refused (status $code)"
		fi

		code="$(curl -s --max-time 30 -o "$BODY" -w '%{http_code}' \
			-u "${OCM_USER}:${OCM_PASSWORD}" \
			--data-urlencode 'lsxml=<?xml version="1.0"?><ClientIntake><CaseInformation><LSCProblemCode>01</LSCProblemCode></CaseInformation><Client><NameFirst>Smoke</NameFirst><NameLast>Lsxml</NameLast></Client></ClientIntake>' \
			"$PT_LSXML_URL")"
		if [ "$code" != 200 ]; then
			bad "a valid LSXML document was not imported (status $code)"
		elif grep -qiE 'pikaCase Object|\[db_row\]|\[values\]' "$BODY"; then
			bad "the LSXML endpoint dumps the whole case row back to the sender"
		elif grep -qE '^\[[0-9]+\]$' "$BODY"; then
			ok "the LSXML endpoint answers with the new case id and nothing else"
			lsxml_case_id="$(tr -dc '0-9' < "$BODY")"
		else
			bad "the LSXML endpoint answered something unexpected: $(head -c 80 "$BODY")"
		fi

		# 27g. What the peer is allowed to write. Everything a user types
		# reaches a column through pl_grab_var(), which rewrites < and > on
		# the way in; this endpoint went from json_decode() straight to
		# setValues(), so a peer installation was the one writer on the box
		# that could put a raw < into a column. plTable draws cell values as
		# they come out of the row, so that text ran as script on the screen
		# of whoever searched for the record.
		PT_XSS_BODY='{"judge_name":"<script>zzptxss()</script>","court_city":"Smokeville"}'
		ts="$(date +%s)"
		code="$(pt_post_json newCase "$PT_XSS_BODY" "$ts" "$(pt_sign newCase "$PT_XSS_BODY" "$ts")")"
		xss_case_id="$(cat "$BODY")"
		case "$xss_case_id" in
			''|*[!0-9]*) xss_case_id='' ;;
		esac
		if [ "$code" != 200 ] || [ -z "$xss_case_id" ]; then
			bad "a signed packet holding markup was refused outright (status $code) - cannot test what it stored"
		else
			stored="$(adb "SELECT judge_name FROM cases WHERE case_id = ${xss_case_id}")"
			case "$stored" in
				*'<script'*)
					bad "a peer packet wrote a raw <script> into the case row: $stored" ;;
				*'&lt;script'*)
					ok "a peer packet cannot write a raw < into a column" ;;
				*)
					bad "the peer packet stored something unexpected in judge_name: $stored" ;;
			esac
		fi

		pt_settings_restore

		# Leave the tables as they were found.
		for cid in $new_case_id $legacy_case_id $lsxml_case_id $xss_case_id; do
			adb "DELETE FROM cases WHERE case_id = ${cid}" >/dev/null
		done
		adb "DELETE FROM cases WHERE judge_name IN ('SmokePeerTransfer','SmokeLegacy','Smoke')" >/dev/null
		adb "DELETE FROM audit_log WHERE action LIKE 'peer_transfer.%' OR action = 'lsxml_transfer.rejected'" >/dev/null
	fi

	# Section 27e replaced the admin session; put one back for anything after.
	: > "$COOKIES"
	curl -sL --max-time 30 -c "$COOKIES" -b "$COOKIES" -o /dev/null \
		-d "login_user=${OCM_USER}&login_pass=${OCM_PASSWORD}&auth_id=1" "$OCM_URL/" >/dev/null
else
	printf '  skip the peer transfer checks (needs the database)\n'
fi

echo
echo "28. the ops/ handlers gated in the authz batch"

# Nine handlers in this section ran on nothing but an id out of the request.
# cms/ops/{duplicate_case,add_case_contact,add_case_new_contact,update_contact}
# .php each changed a case without asking pika_authorize about it;
# cms/ops/{update_zipcode,upload_report}.php wrote shared administrator data
# with no check at all; documents.php?action=download served any row in
# doc_storage by doc_id; and ops/update_case.php let the request name
# intake_user_id, which is the column that records who took the intake.
if [ "$HAVE_DB" = 1 ]; then
	AZGROUP='zz_az_grp'
	AZUSER='zz_az_user'
	AZPASS='zz-az-Passw0rd'
	AZJAR="$(mktemp)"

	cleanup_az() {
		adb "DELETE FROM doc_storage WHERE doc_name LIKE 'ZZAZ%' OR report_name = 'ZZAZREPORT'" >/dev/null
		adb "DELETE FROM conflict WHERE contact_id IN (SELECT contact_id FROM contacts WHERE last_name LIKE 'ZZAZ%')" >/dev/null
		adb "DELETE FROM contacts WHERE last_name LIKE 'ZZAZ%'" >/dev/null
		adb "DELETE FROM cases WHERE number IN ('ZZ-AZ-SECRET', 'ZZ-AZ-MINE')" >/dev/null
		adb "DELETE FROM zip_codes WHERE city = 'ZZAZCITY'" >/dev/null
		adb "DELETE FROM users WHERE username = '${AZUSER}'" >/dev/null
		adb "DELETE FROM \`groups\` WHERE group_id = '${AZGROUP}'" >/dev/null
		rm -f "$AZJAR"
	}
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_az' EXIT
	cleanup_az

	# Every flag off. This user may edit the cases it owns and nothing else,
	# and holds none of the administrator capabilities.
	adb "INSERT INTO \`groups\` (group_id, read_office, read_all, edit_office, edit_all, users, pba, motd, intake, reports)
		VALUES ('${AZGROUP}', NULL, 0, NULL, 0, 0, 0, 0, 0, NULL)" >/dev/null

	AZHASH="$(docker compose "${COMPOSE_ARGS[@]}" exec -T app \
		php -r 'echo password_hash($argv[1], PASSWORD_DEFAULT);' "$AZPASS" </dev/null 2>/dev/null)"
	AZUID="$(adb "SELECT COALESCE(MAX(user_id), 0) + 1 FROM users")"
	adb "INSERT INTO users (user_id, username, password, enabled, group_id, password_expire)
		VALUES (${AZUID}, '${AZUSER}', '${AZHASH}', 1, '${AZGROUP}', 0)" >/dev/null

	# One case this user has no claim on, and one it owns. The owned case is
	# where the mass assignment check runs: the gate has to let the write
	# through so that the denylist is what refuses the column.
	# Ids come from the `counters` row as well as from MAX(). plBase::getNextID
	# hands out the next primary key from counters, not from the table, so a
	# fixture inserted at MAX()+1 alone can sit on an id the application is
	# about to allocate, and the save that lands on it fails on a duplicate
	# key. Take the higher of the two and move the counter up behind it.
	az_next_id() {
		adb "SELECT GREATEST(
			COALESCE((SELECT MAX(${2}) FROM \`${1}\`), 0),
			COALESCE((SELECT count FROM counters WHERE id = '${1}'), 0)) + 1"
	}
	az_bump_counter() {
		adb "UPDATE counters SET count = GREATEST(count, ${2}) WHERE id = '${1}'" >/dev/null
	}

	AZCASE="$(az_next_id cases case_id)"
	adb "INSERT INTO cases (case_id, number, user_id, office, status, intake_user_id)
		VALUES (${AZCASE}, 'ZZ-AZ-SECRET', 1, 'ZZOFF', '1', 1)" >/dev/null
	az_bump_counter cases "$AZCASE"
	AZMINE="$(az_next_id cases case_id)"
	adb "INSERT INTO cases (case_id, number, user_id, office, status, intake_user_id)
		VALUES (${AZMINE}, 'ZZ-AZ-MINE', ${AZUID}, 'ZZMINE', '1', 1)" >/dev/null
	az_bump_counter cases "$AZMINE"

	AZCON="$(az_next_id contacts contact_id)"
	adb "INSERT INTO contacts (contact_id, first_name, last_name)
		VALUES (${AZCON}, 'Zz', 'ZZAZCONTACT')" >/dev/null
	az_bump_counter contacts "$AZCON"

	# A document on the case this user cannot read. doc_data is gzcompress()ed
	# binary, so PHP inside the container writes the UPDATE and mariadb reads
	# it back rather than passing it through a shell.
	AZDOC="$(az_next_id doc_storage doc_id)"
	adb "INSERT INTO doc_storage (doc_id, doc_name, doc_type, description, created, case_id, user_id, folder, mime_type)
		VALUES (${AZDOC}, 'ZZAZdoc.txt', 'C', 'ZZAZ doc', CURDATE(), ${AZCASE}, 1, 0, 'text/plain')" >/dev/null
	az_bump_counter doc_storage "$AZDOC"
	az_seed_doc() {
		docker compose "${COMPOSE_ARGS[@]}" exec -T app php -r '
			file_put_contents("/tmp/zzazdoc.sql",
				"UPDATE doc_storage SET doc_data=\x27"
				. addslashes(gzcompress($argv[2]))
				. "\x27 WHERE doc_id=" . $argv[1] . ";");
		' "$1" "$2" </dev/null
		docker compose "${COMPOSE_ARGS[@]}" exec -T app \
			sh -c 'cat /tmp/zzazdoc.sql' </dev/null > "$BODY"
		docker compose "${COMPOSE_ARGS[@]}" exec -T \
			-e MYSQL_PWD="$DB_ROOT_PASSWORD" db \
			mariadb -uroot "$DB_NAME" < "$BODY"
	}
	az_seed_doc "$AZDOC" 'ZZAZDOC-SECRET private case document body'

	# password.php is the one form every user can load whatever their group,
	# so it is where a token comes from. Take a fresh one before each POST:
	# a spent token would make every assertion below pass because the request
	# was refused by pl_csrf_check(), not because the handler checked anything.
	az_token() {
		curl -sL --max-time 30 -c "$1" -b "$1" "$OCM_URL/password.php" \
			| grep -oE 'name="_csrf" value="[0-9a-f]{64}"' \
			| head -1 | sed -e 's/.*value="//' -e 's/"$//'
	}

	if [ -z "$AZHASH" ] || [ -z "${AZCASE:-}" ] || [ -z "${AZDOC:-}" ] || [ -z "${AZCON:-}" ]; then
		bad "could not seed the ops authorization fixtures"
	else
		: > "$AZJAR"
		curl -sL --max-time 30 -c "$AZJAR" -b "$AZJAR" -o "$BODY" \
			-X POST -d "login_user=${AZUSER}&login_pass=${AZPASS}&auth_id=1" \
			"$OCM_URL/" >/dev/null
		if grep -q 'login_pass' "$BODY"; then
			bad "the throwaway ops user could not log in - section 28 is untested"
		else
			ok "the throwaway ops user can log in"

			AZTOK="$(az_token "$AZJAR")"
			if [ "${#AZTOK}" -eq 64 ]; then
				ok "the throwaway ops user holds a CSRF token"
			else
				bad "no CSRF token for the ops user - section 28 is untested"
			fi

			# Retired questionnaire actions must not bypass the system gate.
			# The refusal must also be visible: this check used to accept an
			# empty body, because the gate called pl_template() without echoing
			# it and threw its own "Permission denied" page away. That made the
			# denial indistinguishable from a crash, so the check now demands
			# the words, and rejects an empty body outright.
			for rq_action in save_questionnaire add_questionnaire toggle_questionnaires diag update_answers; do
				AZTOK="$(az_token "$AZJAR")"
				code="$(curl -s --max-time 30 -b "$AZJAR" -o "$BODY" -w '%{http_code}' \
					--data-urlencode "action=${rq_action}" -d "_csrf=${AZTOK}" \
					"$OCM_URL/system-ops.php")"
				if [ "${#AZTOK}" -ne 64 ] || [ "$code" != 200 ]; then
					bad "$rq_action did not reach the system permission gate (status $code)"
				elif [ ! -s "$BODY" ]; then
					bad "$rq_action was denied with an empty body, so the user cannot tell a refusal from a crash"
				elif grep -qi 'Fatal error\|Uncaught ' "$BODY"; then
					# The refusal has to be the whole answer. A body that carries the
					# words and a PHP error beside them would satisfy the check below
					# while the handler was still running past its own gate.
					bad "$rq_action printed a PHP error beside its refusal"
				elif grep -qi 'Permission denied' "$BODY"; then
					ok "$rq_action is denied to a non-admin user, and says so"
				else
					bad "$rq_action answered a non-admin user something other than a refusal"
				fi
			done

			# 28a. duplicate_case.php copies the whole case record into a new
			# one the caller then owns.
			curl -sL --max-time 30 -b "$AZJAR" -o "$BODY" \
				"$OCM_URL/ops/duplicate_case.php?case_id=${AZCASE}" >/dev/null
			if [ "$(adb "SELECT COUNT(*) FROM cases WHERE number = 'ZZ-AZ-SECRET'")" = 1 ]; then
				ok "a case cannot be duplicated by a user who cannot edit it"
			else
				bad "A CASE THE USER CANNOT EDIT WAS COPIED BY duplicate_case.php"
			fi

			# 28b. add_case_contact.php links an existing contact to a case.
			AZTOK="$(az_token "$AZJAR")"
			curl -s --max-time 30 -b "$AZJAR" -o "$BODY" -X POST \
				-d "_csrf=${AZTOK}&case_id=${AZCASE}&relation_code=7&thiscon=${AZCON}&screen=act" \
				"$OCM_URL/ops/add_case_contact.php" >/dev/null
			if [ "$(adb "SELECT COUNT(*) FROM conflict WHERE case_id = ${AZCASE}")" = 0 ]; then
				ok "a contact cannot be attached to a case the user cannot edit"
			else
				bad "A CONTACT WAS ATTACHED TO A CASE THE USER CANNOT EDIT"
			fi

			# 28c. add_case_new_contact.php creates the contact as well.
			AZTOK="$(az_token "$AZJAR")"
			curl -s --max-time 30 -b "$AZJAR" -o "$BODY" -X POST \
				-d "_csrf=${AZTOK}&case_id=${AZCASE}&relation_code=7&first_name=Zz&last_name=ZZAZNEW&screen=act" \
				"$OCM_URL/ops/add_case_new_contact.php" >/dev/null
			if [ "$(adb "SELECT COUNT(*) FROM contacts WHERE last_name = 'ZZAZNEW'")" = 0 ]; then
				ok "a new contact cannot be created onto a case the user cannot edit"
			else
				bad "A CONTACT WAS CREATED ONTO A CASE THE USER CANNOT EDIT"
			fi

			# 28d. update_contact.php rewrites a contact row - a client's
			# name, address, date of birth - from a case screen.
			AZTOK="$(az_token "$AZJAR")"
			curl -s --max-time 30 -b "$AZJAR" -o "$BODY" -X POST \
				-d "_csrf=${AZTOK}&contact_id=${AZCON}&case_id=${AZCASE}&first_name=Zz&last_name=ZZAZHACKED" \
				"$OCM_URL/ops/update_contact.php" >/dev/null
			if [ "$(adb "SELECT last_name FROM contacts WHERE contact_id = ${AZCON}")" = 'ZZAZCONTACT' ]; then
				ok "a contact cannot be rewritten from a case the user cannot edit"
			else
				bad "A CONTACT WAS REWRITTEN FROM A CASE THE USER CANNOT EDIT"
			fi

			# 28e. documents.php?action=download had no permission check at
			# all, so a doc_id walk read every client's papers.
			curl -sL --max-time 30 -b "$AZJAR" -o "$BODY" \
				"$OCM_URL/documents.php?action=download&doc_id=${AZDOC}" >/dev/null
			if grep -q 'ZZAZDOC-SECRET' "$BODY"; then
				bad "A DOCUMENT ON A CASE THE USER CANNOT READ WAS DOWNLOADED"
			else
				ok "a document on a case the user cannot read is refused"
			fi

			# 28f. update_zipcode.php writes the shared zip code table. The
			# screen it serves is behind pika_authorize('system'); the handler
			# was not.
			AZTOK="$(az_token "$AZJAR")"
			curl -s --max-time 30 -b "$AZJAR" -o "$BODY" -X POST \
				-d "_csrf=${AZTOK}&screen_name=edit&zipcode=99999&state=ZZ&city=ZZAZCITY&county=ZZAZCOUNTY&area_code=999" \
				"$OCM_URL/ops/update_zipcode.php" >/dev/null
			if [ "$(adb "SELECT COUNT(*) FROM zip_codes WHERE city = 'ZZAZCITY'")" = 0 ]; then
				ok "the zip code table is refused to a user without system rights"
			else
				bad "A NON-ADMIN REWROTE THE SHARED ZIP CODE TABLE"
			fi

			# 28g. upload_report.php installs a report definition, which is a
			# document every user of the site then runs.
			AZTOK="$(az_token "$AZJAR")"
			curl -s --max-time 30 -b "$AZJAR" -o "$BODY" -X POST \
				-H 'Content-Type: text/xml' -H "X-CSRF-Token: ${AZTOK}" \
				--data-binary '<?xml version="1.0"?><form name="zzaz"></form>' \
				"$OCM_URL/ops/upload_report.php?report_name=ZZAZREPORT&doc_name=ZZAZreport.xml" >/dev/null
			if [ "$(adb "SELECT COUNT(*) FROM doc_storage WHERE report_name = 'ZZAZREPORT'")" = 0 ]; then
				ok "a report definition is refused to a user without system rights"
			else
				bad "A NON-ADMIN INSTALLED A SAVED REPORT DEFINITION"
			fi

			# 28h. ops/update_case.php writes any cases column the request
			# carries. intake_user_id records who took the intake, and no case
			# screen offers it, so a value for it can only have been added by
			# hand. Run on the case this user owns, so that the edit_case gate
			# lets the save through and the denylist is what refuses the field.
			AZTOK="$(az_token "$AZJAR")"
			curl -s --max-time 30 -b "$AZJAR" -o "$BODY" -X POST \
				-d "_csrf=${AZTOK}&case_id=${AZMINE}&screen=info&intake_user_id=${AZUID}&good_story=1" \
				"$OCM_URL/ops/update_case.php" >/dev/null
			if [ "$(adb "SELECT intake_user_id FROM cases WHERE case_id = ${AZMINE}")" = 1 ]; then
				ok "intake_user_id cannot be rewritten by posting it to update_case.php"
			else
				bad "A POSTED intake_user_id REWROTE THE CASE INTAKE RECORD"
			fi

			# Positive control for 28h: an ordinary field on the same POST has
			# to land, or the check above passes because the whole save was
			# refused rather than because the column was dropped.
			if [ "$(adb "SELECT good_story FROM cases WHERE case_id = ${AZMINE}")" = 1 ]; then
				ok "an ordinary field on the same save still lands"
			else
				bad "the update_case denylist blocked the whole save - it is too tight"
			fi
		fi

		# Positive controls. The admin holds every right, so each of these
		# must still work; an authorization check that refuses everybody
		# passes the negatives above for the wrong reason.
		curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" \
			"$OCM_URL/documents.php?action=download&doc_id=${AZDOC}" >/dev/null
		if grep -q 'ZZAZDOC-SECRET' "$BODY"; then
			ok "the admin still downloads a case document"
		else
			bad "the admin cannot download a case document - the gate is too tight"
		fi

		ADMTOK="$(az_token "$COOKIES")"
		curl -s --max-time 30 -b "$COOKIES" -o "$BODY" -X POST \
			-d "_csrf=${ADMTOK}&case_id=${AZCASE}&relation_code=7&thiscon=${AZCON}&screen=act" \
			"$OCM_URL/ops/add_case_contact.php" >/dev/null
		if [ "$(adb "SELECT COUNT(*) FROM conflict WHERE case_id = ${AZCASE}")" -ge 1 ]; then
			ok "the admin still attaches a contact to a case"
		else
			bad "the admin cannot attach a contact to a case - the gate is too tight"
		fi

		ADMTOK="$(az_token "$COOKIES")"
		curl -s --max-time 30 -b "$COOKIES" -o "$BODY" -X POST \
			-d "_csrf=${ADMTOK}&screen_name=edit&zipcode=99999&state=ZZ&city=ZZAZCITY&county=ZZAZCOUNTY&area_code=999" \
			"$OCM_URL/ops/update_zipcode.php" >/dev/null
		if [ "$(adb "SELECT COUNT(*) FROM zip_codes WHERE city = 'ZZAZCITY'")" = 1 ]; then
			ok "the admin still writes the zip code table"
		else
			bad "the admin cannot write the zip code table - the gate is too tight"
		fi

		# The save_report flow sends its parameters as a raw text/xml body, so
		# there is no _csrf field in $_POST and the token has to travel in an
		# X-CSRF-Token header. Without the header handling in
		# ops/upload_report.php this POST is refused by pl_csrf_check() and
		# saving a report is broken for everybody, admin included.
		ADMTOK="$(az_token "$COOKIES")"
		curl -s --max-time 30 -b "$COOKIES" -o "$BODY" -X POST \
			-H 'Content-Type: text/xml' -H "X-CSRF-Token: ${ADMTOK}" \
			--data-binary '<?xml version="1.0"?><form name="zzaz"></form>' \
			"$OCM_URL/ops/upload_report.php?report_name=ZZAZREPORT&doc_name=ZZAZreport.xml" >/dev/null
		if [ "$(adb "SELECT COUNT(*) FROM doc_storage WHERE report_name = 'ZZAZREPORT'")" = 1 ]; then
			ok "the admin still saves a report definition over a raw XML body"
		else
			bad "the admin cannot save a report definition - the CSRF header path is broken"
		fi

		# And the token has to be on the report page for the browser to find.
		curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" \
			"$OCM_URL/reports/megareport/" >/dev/null
		if grep -qE 'name="_csrf" value="[0-9a-f]{64}"' "$BODY"; then
			ok "the report page carries a CSRF token for save_report.js"
		else
			bad "the report page has no CSRF token - save_report.js cannot send one"
		fi
	fi

	cleanup_az
	trap 'rm -f "$COOKIES" "$BODY"' EXIT
else
	printf '  skip the ops authorization checks (needs the database)\n'
fi

# ── 32. The poverty guideline and the two password policy settings ─────────
# Both of these are the same mistake in two languages: a value that holds a
# number is used where the code assumed a number, and a value that does not
# parse takes the whole screen with it.
if [ "$HAVE_DB" = 1 ]; then
	ELIG_CASE="$(adb "SELECT COALESCE(MAX(case_id), 0) + 1 FROM cases")"
	POV_WAS="$(adb "SELECT label FROM menu_poverty WHERE value = '0'")"
	PW_USER='zz_pw_user'
	PW_GROUP='zz_pw_grp'
	PW_OLD='zz-pw-Passw0rd'
	PW_NEW='zz-pw-N3wPassword'
	PW_JAR="$(mktemp)"
	PWLEN_WAS="$(adb "SELECT value FROM settings WHERE label = 'pass_min_length'")"
	PWSTR_WAS="$(adb "SELECT value FROM settings WHERE label = 'pass_min_strength'")"

	cleanup_pol() {
		adb "DELETE FROM cases WHERE number = 'ZZ-ELIG-1'" >/dev/null
		adb "DELETE FROM users WHERE username = '${PW_USER}'" >/dev/null
		adb "DELETE FROM \`groups\` WHERE group_id = '${PW_GROUP}'" >/dev/null
		adb "DELETE FROM settings WHERE label IN ('pass_min_length', 'pass_min_strength')" >/dev/null
		if [ -n "${PWLEN_WAS}" ]; then
			adb "INSERT INTO settings (label, value) VALUES ('pass_min_length', '${PWLEN_WAS}')" >/dev/null
		fi
		if [ -n "${PWSTR_WAS}" ]; then
			adb "INSERT INTO settings (label, value) VALUES ('pass_min_strength', '${PWSTR_WAS}')" >/dev/null
		fi
		if [ -n "${POV_WAS}" ]; then
			adb "UPDATE menu_poverty SET label = '${POV_WAS}' WHERE value = '0'" >/dev/null
		fi
		rm -f "$PW_JAR"
	}
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_pol' EXIT

	adb "DELETE FROM cases WHERE number = 'ZZ-ELIG-1'" >/dev/null
	adb "DELETE FROM users WHERE username = '${PW_USER}'" >/dev/null
	adb "DELETE FROM \`groups\` WHERE group_id = '${PW_GROUP}'" >/dev/null

	# 31a. A poverty guideline typed the way the federal table prints it.
	# cms/js/case-elig.js is a template, and the menu value is written into its
	# source, so calc_poverty() read
	#     g[0] = 9,999;
	# which is the JavaScript comma operator: g[0] got 999. The Calculate
	# button then measured every household against a tenth of the real figure.
	adb "INSERT INTO cases (case_id, number, user_id, office, status)
		VALUES (${ELIG_CASE}, 'ZZ-ELIG-1', 1, NULL, '1')" >/dev/null
	adb "UPDATE menu_poverty SET label = '9,999' WHERE value = '0'" >/dev/null

	curl -sL --max-time 60 -b "$COOKIES" -o "$BODY" \
		"$OCM_URL/case.php?case_id=${ELIG_CASE}&screen=elig" >/dev/null
	if ! grep -q 'calc_poverty' "$BODY"; then
		bad "the eligibility tab did not render its script ($(wc -c < "$BODY") bytes)"
	elif grep -qE 'g\[0\] = 9,999;' "$BODY"; then
		bad "the poverty guideline reaches the page unquoted - a comma in the value breaks the calculation"
	elif grep -qF '(""+"9,999")' "$BODY"; then
		ok "a comma-formatted poverty guideline reaches the page as a string"
	else
		bad "the poverty guideline is not on the eligibility tab in either form"
	fi

	adb "UPDATE menu_poverty SET label = '${POV_WAS}' WHERE value = '0'" >/dev/null

	# 31b. The two password policy settings hold a menu code, and password.php
	# compared each against a number the code produces. A settings row that
	# holds the display label instead - which a hand-written UPDATE or a row
	# restored from an older schema can leave behind - made PHP 8 compare an
	# integer against a non-numeric string as strings: 4 < 'Strong' is true, so
	# no password could satisfy the form and the only thing on the screen was
	# the strength complaint, over and over.
	PW_HASH="$(docker compose "${COMPOSE_ARGS[@]}" exec -T app \
		php -r 'echo password_hash($argv[1], PASSWORD_DEFAULT);' "$PW_OLD" </dev/null 2>/dev/null)"
	PW_UID="$(adb "SELECT COALESCE(MAX(user_id), 0) + 1 FROM users")"
	adb "INSERT INTO \`groups\` (group_id, read_office, read_all, edit_office, edit_all, users, pba, motd, intake, reports)
		VALUES ('${PW_GROUP}', NULL, 0, NULL, 0, 0, 0, 0, 0, NULL)" >/dev/null
	adb "INSERT INTO users (user_id, username, password, enabled, group_id, password_expire)
		VALUES (${PW_UID}, '${PW_USER}', '${PW_HASH}', 1, '${PW_GROUP}', 0)" >/dev/null

	# $1 label, $2 old password, $3 new password, $4 pass|fail
	pw_change() {
		: > "$PW_JAR"
		curl -sL --max-time 30 -c "$PW_JAR" -b "$PW_JAR" -o /dev/null \
			-X POST -d "login_user=${PW_USER}&login_pass=$2&auth_id=1" \
			"$OCM_URL/" >/dev/null
		curl -sL --max-time 30 -b "$PW_JAR" -o "$BODY" "$OCM_URL/password.php" >/dev/null
		pw_token="$(grep -oE 'name="_csrf" value="[0-9a-f]*"' "$BODY" \
			| head -n 1 | sed -E 's/.*value="([0-9a-f]*)".*/\1/')"
		if [ -z "$pw_token" ]; then
			bad "$1: password.php rendered no CSRF token"
			return
		fi
		sm_password_post "$PW_JAR" "$2" \
			--data-urlencode "action=update" \
			--data-urlencode "oldpass=$2" \
			--data-urlencode "newpass1=$3" \
			--data-urlencode "newpass2=$3" \
			--data-urlencode "_csrf=${pw_token}" \
			"$OCM_URL/password.php" >/dev/null
		# pikaTempLib's red_flag plugin replaces every space with &nbsp;, so
		# the message has to be read with the entities turned back into spaces.
		sed 's/&nbsp;/ /g' "$BODY" > "${BODY}.txt"
		if grep -qF 'Password updated successfully' "${BODY}.txt"; then
			if [ "$4" = pass ]; then
				ok "$1: the password change went through"
			else
				bad "$1: THE PASSWORD CHANGE WENT THROUGH AND SHOULD NOT HAVE"
			fi
		elif grep -qF 'does not meet' "${BODY}.txt"; then
			if [ "$4" = fail ]; then
				ok "$1: refused by the policy"
			else
				bad "$1: the policy refused a password that satisfies it"
			fi
		else
			bad "$1: neither outcome on the page ($(wc -c < "$BODY") bytes)"
		fi
		rm -f "${BODY}.txt"
	}

	if [ -z "$PW_HASH" ] || [ -z "${PW_UID:-}" ]; then
		bad "could not seed the password policy fixtures (hash/user)"
	else
		# The requirement still bites when the setting holds the code it is
		# supposed to hold. Without this the cast below would pass by turning
		# the policy off.
		adb "DELETE FROM settings WHERE label IN ('pass_min_length', 'pass_min_strength')" >/dev/null
		adb "INSERT INTO settings (label, value) VALUES ('pass_min_length', '8')" >/dev/null
		pw_change "a short password against a length of 8" "$PW_OLD" 'zz-1' fail

		# The same policy, spelled as the label. This is the state that locked
		# every user out of their own password.
		adb "DELETE FROM settings WHERE label IN ('pass_min_length', 'pass_min_strength')" >/dev/null
		adb "INSERT INTO settings (label, value)
			VALUES ('pass_min_length', '8 or More'), ('pass_min_strength', 'Strong')" >/dev/null
		pw_change "a good password against policy settings holding labels" "$PW_OLD" "$PW_NEW" pass
	fi

	cleanup_pol
	trap 'rm -f "$COOKIES" "$BODY"' EXIT
else
	printf '  skip the guideline and password policy checks (needs the database)\n'
fi

# ---------------------------------------------------------------------------
# 32. cms/transfers.php and cms/system-outcomes.php build their POST forms in
# PHP rather than in a template, and both files enforce pl_csrf_check() on
# POST, but neither emitted a token. So both forms were dead: the holding-tank
# Accept and Reject buttons and the outcome-goal save were all refused with a
# CSRF error. Section 7b did not catch it because its page list is fixed and
# both of these forms need state to render at all.
#
# The transfer payload is JSON that a PEER installation sent us. It never went
# through pl_clean_form_input(), and this page wrote it straight into the
# markup, so a peer could store script in a client name and run it in the
# browser of whoever reviewed the transfer.
echo
echo "== 32. the two hand-built POST forms =="

if [ "$HAVE_DB" = 1 ] && [ "$HAVE_COMPOSE" = 1 ]; then
	TX_ID=""
	TX_XSS='<script>zzTxXss()</script>'

	cleanup_tx() {
		if [ -n "${TX_ID:-}" ]; then
			adb "DELETE FROM transfers WHERE transfer_id = ${TX_ID}" >/dev/null 2>&1
		fi
	}
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_tx' EXIT

	# A pending transfer is accepted = 2. The payload carries the tag in a
	# field the list page prints and in a field only the detail page prints.
	TX_ID="$(adb "SELECT COALESCE(MAX(transfer_id),0)+1 FROM transfers")"
	TX_JSON="$(printf '%s' '{"client":{"last_name":"ZZTX<script>zzTxXss()</script>","first_name":"Zz&Amp","county":"zz","city":"zz","problem_code":"zz"},"notes":{"notes0":"ZZTXNOTE<script>zzTxXss()</script>"},"case":{},"op":{},"opa":{}}' \
		| sed "s/'/''/g")"
	adb "INSERT INTO transfers (transfer_id, user_id, json_data, created, accepted)
		VALUES (${TX_ID}, 1, '${TX_JSON}', NOW(), 2)" >/dev/null 2>&1

	if [ -z "$TX_ID" ]; then
		bad "could not seed a pending transfer fixture"
	else
		: > "$COOKIES"
		curl -s --max-time 30 -c "$COOKIES" -o /dev/null "$OCM_URL/index.php"
		curl -s --max-time 30 -c "$COOKIES" -b "$COOKIES" -o /dev/null \
			-X POST -d "login_user=admin&login_pass=${OCM_PASSWORD}&auth_id=1" \
			"$OCM_URL/index.php"

		# 32a. The holding-tank list must not print the peer's tag raw.
		curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" "$OCM_URL/transfers.php" >/dev/null
		if ! grep -q 'ZZTX' "$BODY"; then
			bad "the pending transfer is not on the holding-tank list at all"
		elif grep -qF '<script>zzTxXss()</script>' "$BODY"; then
			bad "THE HOLDING-TANK LIST PRINTS A PEER'S SCRIPT TAG RAW"
		elif grep -qF 'Zz&Amp' "$BODY"; then
			bad "a bare ampersand in a peer field reaches the page unescaped"
		elif grep -qF 'ZZTX&lt;script&gt;' "$BODY"; then
			ok "the holding-tank list escapes the peer-supplied client name"
		else
			bad "the peer-supplied name is neither raw nor escaped on the list page"
		fi

		# 32b. Same for the detail page, which prints every payload field.
		curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" \
			"$OCM_URL/transfers.php?transfer_id=${TX_ID}" >/dev/null
		if ! grep -q 'ZZTXNOTE' "$BODY"; then
			bad "the transfer detail page does not show the payload notes"
		elif grep -qF '<script>zzTxXss()</script>' "$BODY"; then
			bad "THE TRANSFER DETAIL PAGE PRINTS A PEER'S SCRIPT TAG RAW"
		else
			ok "the transfer detail page escapes every peer-supplied field"
		fi

		# 32c. The Accept/Reject form has to carry a token, or both buttons are
		# refused by the check at the top of the same file.
		TX_TOKEN="$(grep -oE 'name="_csrf" value="[0-9a-f]{64}"' "$BODY" \
			| head -1 | sed -e 's/.*value="//' -e 's/"$//')"
		if [ "${#TX_TOKEN}" -eq 64 ]; then
			ok "the Accept/Reject form carries a 64-hex CSRF token"
		else
			bad "the Accept/Reject form has no usable token (got ${#TX_TOKEN} chars)"
		fi

		# 32d. transfer_id is an int primary key. A tag in it used to be
		# decoded back to < and > and printed in the heading.
		curl -sLG --max-time 30 -b "$COOKIES" -o "$BODY" \
			--data-urlencode 'transfer_id=<script>zzTxXss()</script>' \
			"$OCM_URL/transfers.php" >/dev/null
		if grep -qF '<script>zzTxXss()</script>' "$BODY"; then
			bad "A TAG IN transfer_id IS REFLECTED INTO THE TRANSFER PAGE"
		elif grep -q 'not a transfer record number' "$BODY"; then
			ok "a transfer_id that is not a number is refused"
		else
			bad "a non-numeric transfer_id was neither refused nor reflected"
		fi

		# 32e. Reject with no token: refused. Reject with the token: it lands.
		code="$(curl -s --max-time 30 -b "$COOKIES" -o "$BODY" -w '%{http_code}' \
			-X POST -d "transfer_id=${TX_ID}&reject=Reject" "$OCM_URL/transfers.php")"
		still_pending="$(adb "SELECT accepted FROM transfers WHERE transfer_id = ${TX_ID}")"
		if [ "$code" = 403 ] && [ "$still_pending" = 2 ]; then
			ok "a Reject with no token is refused and the transfer stays pending"
		else
			bad "a tokenless Reject was not refused (status $code, accepted=$still_pending)"
		fi

		# The refused POST above hands back the recovery form, which carries a
		# fresh token, so the one scraped earlier is stale by now.
		curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" \
			"$OCM_URL/transfers.php?transfer_id=${TX_ID}" >/dev/null
		TX_TOKEN="$(grep -oE 'name="_csrf" value="[0-9a-f]{64}"' "$BODY" \
			| head -1 | sed -e 's/.*value="//' -e 's/"$//')"
		curl -s --max-time 30 -b "$COOKIES" -o "$BODY" \
			-X POST -d "_csrf=${TX_TOKEN}&transfer_id=${TX_ID}&reject=Reject" \
			"$OCM_URL/transfers.php" >/dev/null
		# 0 is rejected. It used to land as NULL, which is the column default
		# and so indistinguishable from a row nobody had touched.
		if [ "$(adb "SELECT accepted FROM transfers WHERE transfer_id = ${TX_ID}")" = 0 ]; then
			ok "a Reject carrying the form's own token goes through and records a 0"
		else
			bad "REJECT IS STILL BROKEN WITH THE TOKEN THE FORM SUPPLIED"
		fi

		# 32f. The outcome-goal editor is the same bug in a second file.
		TX_OUTCOME="$(adb "SELECT problem FROM outcome_goals WHERE active = 1 LIMIT 1")"
		if [ -z "$TX_OUTCOME" ]; then
			TX_OUTCOME=01
		fi
		curl -sLG --max-time 30 -b "$COOKIES" -o "$BODY" \
			-d action=edit --data-urlencode "outcome=${TX_OUTCOME}" \
			"$OCM_URL/system-outcomes.php" >/dev/null
		if grep -qE 'name="_csrf" value="[0-9a-f]{64}"' "$BODY"; then
			ok "the outcome-goal editor carries a CSRF token so the save can work"
		else
			bad "the outcome-goal editor has no token - saving goals returns 403"
		fi
	fi

	cleanup_tx
	trap 'rm -f "$COOKIES" "$BODY"' EXIT
else
	printf '  skip the hand-built POST form checks (needs the database)\n'
fi

echo
echo "33. the menu editor refuses duplicate values"

# A menu table has no primary key on `value`, so nothing in the database
# stops two rows sharing one. The classic editor keyed its parse array by
# value, so a value typed twice overwrote the earlier line and the menu came
# back shorter than what was submitted, with no message. The item editor had
# the matching hole: pikaMenu::save() deletes old_value and inserts the new
# one, so renaming an item onto a value already in use left two identical
# values and no way to tell them apart.
if [ "$HAVE_DB" = 1 ]; then
	MN_NAME='zzmn'
	MN_TABLE="menu_${MN_NAME}"

	cleanup_mn() {
		adb "DROP TABLE IF EXISTS \`${MN_TABLE}\`" >/dev/null
	}
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_mn' EXIT
	cleanup_mn

	adb "CREATE TABLE \`${MN_TABLE}\` (
		\`value\` char(8) NOT NULL DEFAULT '',
		\`label\` char(65) NOT NULL DEFAULT '',
		\`menu_order\` tinyint(4) NOT NULL DEFAULT 0,
		KEY \`label\` (\`label\`),
		KEY \`val\` (\`value\`),
		KEY \`menu_order\` (\`menu_order\`)
	)" >/dev/null

	# The classic editor posts to system-menus.php, which enforces the token,
	# so scrape a fresh one off the page that carries the form. A refused POST
	# hands back a recovery page with a different token, so re-read the form
	# page before each submit rather than reusing one.
	mn_token() {
		curl -sL --max-time 30 -b "$COOKIES" \
			"$OCM_URL/system-menus.php?action=edit_menu_classic&menu_name=${MN_NAME}" \
			| grep -oE 'name="_csrf" value="[0-9a-f]{64}"' \
			| head -1 | sed -e 's/.*value="//' -e 's/"$//'
	}

	# $1 is the textarea body. Response lands in $BODY.
	mn_save_classic() {
		curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" -X POST \
			--data-urlencode "_csrf=$(mn_token)" \
			--data-urlencode "values=$1" \
			"$OCM_URL/system-menus.php?action=update_classic&menu_name=${MN_NAME}" >/dev/null
	}

	mn_rows() { adb "SELECT COUNT(*) FROM \`${MN_TABLE}\`"; }

	# 33a. A clean save is still a save, and the blank lines a textarea always
	# sends no longer become a menu row with an empty value and empty label.
	mn_save_classic 'ZZA | Alpha

ZZB | Bravo
'
	if [ "$(mn_rows)" = 2 ] \
		&& [ "$(adb "SELECT label FROM \`${MN_TABLE}\` WHERE value = 'ZZB'")" = 'Bravo' ]; then
		ok "the classic menu editor saves and drops the blank lines"
	else
		bad "the classic menu editor lost a row or kept a blank one ($(mn_rows) rows)"
	fi

	# 33b. Two lines with the same value are refused, and nothing is written.
	mn_save_classic 'ZZA | Alpha
ZZB | Bravo
ZZA | Alpha Again'
	if grep -q 'Duplicate value' "$BODY"; then
		ok "the classic menu editor names the duplicate value"
	else
		bad "the classic menu editor accepted a duplicate value with no message"
	fi
	if [ "$(adb "SELECT label FROM \`${MN_TABLE}\` WHERE value = 'ZZA'")" = 'Alpha' ]; then
		ok "the refused classic save left the menu alone"
	else
		bad "the refused classic save still rewrote the menu"
	fi

	# 33c. The refusal page hands the submitted text back so the edit is not
	# lost. Without this the admin retypes the whole menu.
	if grep -q 'Alpha Again' "$BODY"; then
		ok "the refusal page keeps the submitted menu text"
	else
		bad "the refusal page threw away what the admin typed"
	fi

	# 33d. Renaming one item onto a value another item already holds is
	# refused, and neither row moves.
	curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" \
		"$OCM_URL/system-menus.php?action=update&menu_name=${MN_NAME}&old_value=ZZB&value=ZZA&label=Bravo" >/dev/null
	if grep -q 'already exists' "$BODY"; then
		ok "the item editor refuses a rename onto an existing value"
	else
		bad "the item editor renamed an item onto a value already in use"
	fi
	if [ "$(mn_rows)" = 2 ] \
		&& [ "$(adb "SELECT label FROM \`${MN_TABLE}\` WHERE value = 'ZZA'")" = 'Alpha' ] \
		&& [ "$(adb "SELECT label FROM \`${MN_TABLE}\` WHERE value = 'ZZB'")" = 'Bravo' ]; then
		ok "the refused rename left both menu items where they were"
	else
		bad "the refused rename still changed the menu"
	fi

	# 33e. A rename to a value nobody holds, and a label-only edit, both still
	# go through. The guard only fires when the value is changing.
	curl -sL --max-time 30 -b "$COOKIES" -o /dev/null \
		"$OCM_URL/system-menus.php?action=update&menu_name=${MN_NAME}&old_value=ZZB&value=ZZC&label=Bravo" >/dev/null
	curl -sL --max-time 30 -b "$COOKIES" -o /dev/null \
		"$OCM_URL/system-menus.php?action=update&menu_name=${MN_NAME}&old_value=ZZA&value=ZZA&label=Alpha%20Edited" >/dev/null
	if [ "$(adb "SELECT label FROM \`${MN_TABLE}\` WHERE value = 'ZZC'")" = 'Bravo' ] \
		&& [ "$(adb "SELECT label FROM \`${MN_TABLE}\` WHERE value = 'ZZA'")" = 'Alpha Edited' ]; then
		ok "a free rename and a label-only edit both still save"
	else
		bad "the duplicate guard blocked an edit it should have let through"
	fi

	# 33f. pikaMenu::save() used to echo the DELETE and the INSERT it had just
	# run, so every menu save answered with the table name, the column list and
	# the values ahead of its Location header. Not script injection -- the
	# request values arrive with < and > already entities, and a browser
	# discards a 302 body -- but curl, a proxy log and any error page that
	# renders the body do not.
	#
	# -s and not -sL on purpose: following the redirect would fetch the page
	# after the save and throw away the body being checked.
	curl -s --max-time 30 -b "$COOKIES" -o "$BODY" \
		"$OCM_URL/system-menus.php?action=update&menu_name=${MN_NAME}&old_value=ZZA&value=ZZA&label=Alpha%20Again" >/dev/null
	if grep -qE "INSERT ${MN_TABLE}|DELETE FROM ${MN_TABLE}" "$BODY"
	then
		bad "system-menus.php prints the SQL it just ran into the save response"
	else
		ok "system-menus.php does not print the SQL it just ran"
	fi
	if [ "$(adb "SELECT label FROM \`${MN_TABLE}\` WHERE value = 'ZZA'")" = 'Alpha Again' ]
	then
		ok "the save behind that check still saved"
	else
		bad "the save behind the SQL-echo check did not save"
	fi

	cleanup_mn
	trap 'rm -f "$COOKIES" "$BODY"' EXIT
else
	printf '  skip the menu editor checks (needs the database)\n'
fi

echo
echo "34. calendar time entries and the activity backdating lock"

# Two faults in the same handler. The Calendar entry form (act_type 'C',
# subtemplates/activityC.html) captures Start Time and End Time and has no
# hours field, and ops/update_activity.php read hours straight out of the
# POST - so calendar-entered time saved as 0 hours and was invisible on
# every timekeeping total. And activity.php greyed out the date, funding
# and hours fields once a record passed activity_lock_max_days, but that
# was a disabled attribute in the markup with nothing behind it: a POST
# that did not come from that form saved whatever date it liked.
if [ "$HAVE_DB" = 1 ]; then
	LKGROUP='zz_lk_grp'
	LKUSER='zz_lk_user'
	LKPASS='zz-Lk-Passw0rd'
	LKJAR="$(mktemp)"
	# These dates must be the application's, not the shell's. pika_init()
	# calls date_default_timezone_set() with the time_zone setting and
	# defaults it to America/New_York, so between midnight UTC and that
	# offset the shell's today is the application's tomorrow. A
	# future-dated entry is a scheduled appointment the handler
	# deliberately leaves at 0 hours, so reading the date from the shell
	# made 34a pass all afternoon and fail every run made at night.
	LK_DATES="$(docker compose "${COMPOSE_ARGS[@]}" exec -T app php -r '
		define("PL_DISABLE_SECURITY", true);
		chdir("/var/www/html/cms");
		require_once("pika-danio.php");
		pika_init();
		echo date("Y-m-d"), " ",
			date("Y-m-d", strtotime("-30 days")), " ",
			date("Y-m-d", strtotime("+3 days"));
	' </dev/null 2>/dev/null)"
	LK_TODAY="$(printf '%s' "$LK_DATES" | awk '{print $1}')"
	LK_OLD="$(printf '%s' "$LK_DATES" | awk '{print $2}')"
	LK_FUTURE="$(printf '%s' "$LK_DATES" | awk '{print $3}')"

	cleanup_lk() {
		adb "DELETE FROM activities WHERE summary LIKE 'ZZLK%'" >/dev/null
		adb "DELETE FROM users WHERE username = '${LKUSER}'" >/dev/null
		adb "DELETE FROM \`groups\` WHERE group_id = '${LKGROUP}'" >/dev/null
		adb "DELETE FROM settings WHERE label = 'activity_lock_max_days'" >/dev/null
		if [ -n "${LK_OLD_LOCK:-}" ]; then
			adb "INSERT INTO settings (label, value) VALUES ('activity_lock_max_days', '${LK_OLD_LOCK}')" >/dev/null
		fi
		rm -f "$LKJAR"
	}
	LK_OLD_LOCK="$(adb "SELECT value FROM settings WHERE label = 'activity_lock_max_days'")"
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_lk' EXIT

	adb "DELETE FROM activities WHERE summary LIKE 'ZZLK%'" >/dev/null
	adb "DELETE FROM users WHERE username = '${LKUSER}'" >/dev/null
	adb "DELETE FROM \`groups\` WHERE group_id = '${LKGROUP}'" >/dev/null

	# A user who may edit activities but is not in the 'system' group, which
	# is the group the lock exempts.
	adb "INSERT INTO \`groups\` (group_id, read_office, read_all, edit_office, edit_all, users, pba, motd, intake, reports)
		VALUES ('${LKGROUP}', NULL, 1, NULL, 1, 0, 0, 0, 0, NULL)" >/dev/null
	LKHASH="$(docker compose "${COMPOSE_ARGS[@]}" exec -T app \
		php -r 'echo password_hash($argv[1], PASSWORD_DEFAULT);' "$LKPASS" </dev/null 2>/dev/null)"
	LKUID="$(adb "SELECT COALESCE(MAX(user_id), 0) + 1 FROM users")"
	adb "INSERT INTO users (user_id, username, password, enabled, group_id, password_expire)
		VALUES (${LKUID}, '${LKUSER}', '${LKHASH}', 1, '${LKGROUP}', 0)" >/dev/null

	: > "$LKJAR"
	curl -sL --max-time 30 -c "$LKJAR" -b "$LKJAR" -o /dev/null \
		-X POST -d "login_user=${LKUSER}&login_pass=${LKPASS}&auth_id=1" \
		"$OCM_URL/" >/dev/null

	# ops/update_activity.php enforces the token, and a refused POST hands
	# back a page carrying a different one, so read a fresh token off the
	# entry form before every save.
	lk_token() {
		curl -sL --max-time 30 -b "$1" "$OCM_URL/activity.php?act_type=C" \
			| grep -oE 'name="_csrf" value="[0-9a-f]{64}"' \
			| head -1 | sed -e 's/.*value="//' -e 's/"$//'
	}

	# $1 cookie jar, $2.. extra -d arguments. Prints the status code.
	lk_save() {
		lk_jar="$1"
		shift
		curl -s --max-time 30 -b "$lk_jar" -o "$BODY" -w '%{http_code}' -X POST \
			--data-urlencode "_csrf=$(lk_token "$lk_jar")" \
			-d "act_type=C" -d "close_act=1" -d "user_id=${LKUID}" \
			"$@" "$OCM_URL/ops/update_activity.php"
	}

	lk_hours() { adb "SELECT hours FROM activities WHERE summary = '$1'"; }

	if [ -z "$LKHASH" ]; then
		bad "could not seed the activity lock fixtures"
	else
		# 34a. A calendar entry with a start and an end and no hours field
		# now records the span it covers.
		lk_save "$LKJAR" -d "act_date=${LK_TODAY}" -d "act_time=09:00" \
			-d "act_end_time=11:30" --data-urlencode "summary=ZZLK span" >/dev/null
		if [ "$(lk_hours 'ZZLK span')" = '2.50' ]; then
			ok "a calendar time entry records the hours between start and end"
		else
			bad "a calendar time entry saved $(lk_hours 'ZZLK span') hours, not 2.50"
		fi

		# 34b. An hours value the user typed is never overwritten. plBase has
		# __get but no __isset, so a guard written with isset() on the magic
		# property would silently lose this.
		lk_save "$LKJAR" -d "act_date=${LK_TODAY}" -d "act_time=09:00" \
			-d "act_end_time=11:30" -d "hours=0.75" \
			--data-urlencode "summary=ZZLK explicit" >/dev/null
		if [ "$(lk_hours 'ZZLK explicit')" = '0.75' ]; then
			ok "an hours value the user typed wins over the derived one"
		else
			bad "the derived hours overwrote what the user typed ($(lk_hours 'ZZLK explicit'))"
		fi

		# 34c. A future date with a time range is an appointment, not work
		# that has been done, so nothing is derived onto it.
		lk_save "$LKJAR" -d "act_date=${LK_FUTURE}" -d "act_time=09:00" \
			-d "act_end_time=11:30" --data-urlencode "summary=ZZLK future" >/dev/null
		if [ "$(lk_hours 'ZZLK future')" = '0.00' ]; then
			ok "a future appointment does not derive hours"
		else
			bad "a future appointment derived $(lk_hours 'ZZLK future') hours"
		fi

		# The lock is off until the setting is on, which is the default.
		adb "DELETE FROM settings WHERE label = 'activity_lock_max_days'" >/dev/null
		adb "INSERT INTO settings (label, value) VALUES ('activity_lock_max_days', '5')" >/dev/null

		# 34d. A backdated new record is refused by the handler, not just
		# greyed out in the form.
		lk_status="$(lk_save "$LKJAR" -d "act_date=${LK_OLD}" -d "act_time=09:00" \
			-d "act_end_time=10:00" --data-urlencode "summary=ZZLK backdated")"
		if [ "$(adb "SELECT COUNT(*) FROM activities WHERE summary = 'ZZLK backdated'")" = 0 ]; then
			ok "the handler refuses a backdated activity (status ${lk_status})"
		else
			bad "a backdated activity was saved past the lock"
		fi

		# 34e. And a record already inside the locked window cannot be
		# dragged forward to a date that is not locked.
		LKACT="$(adb "SELECT COALESCE(MAX(act_id), 0) + 1 FROM activities")"
		adb "INSERT INTO activities (act_id, act_type, act_date, act_time, hours, summary, user_id, completed)
			VALUES (${LKACT}, 'C', '${LK_OLD}', '09:00:00', 1.00, 'ZZLK old record', ${LKUID}, 1)" >/dev/null
		lk_save "$LKJAR" -d "act_id=${LKACT}" -d "act_date=${LK_TODAY}" -d "hours=8.00" \
			--data-urlencode "summary=ZZLK moved" >/dev/null
		if [ "$(adb "SELECT summary FROM activities WHERE act_id = ${LKACT}")" = 'ZZLK old record' ]; then
			ok "a locked activity cannot be edited onto an unlocked date"
		else
			bad "a locked activity was edited past the lock"
		fi

		# 34f. The refusal says why. Without the banner the form simply
		# comes back empty and the user retypes it.
		curl -sL --max-time 30 -b "$LKJAR" -o "$BODY" \
			"$OCM_URL/activity.php?date_lock_error=1&act_type=C" >/dev/null
		if grep -q 'locked for editing' "$BODY"; then
			ok "the refusal page says the date is locked"
		else
			bad "the refusal page gives no reason"
		fi

		# 34g. The read side still greys the fields out, and still exempts
		# the system group. Both come from the same helper now.
		curl -sL --max-time 30 -b "$LKJAR" -o "$BODY" \
			"$OCM_URL/activity.php?act_id=${LKACT}&act_type=C" >/dev/null
		if grep -q 'disabled name="act_date"' "$BODY"; then
			ok "a locked activity still renders with the date field disabled"
		else
			bad "the locked activity form is no longer greyed out"
		fi

		# 34h. The system group is exempt on both sides.
		curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" \
			"$OCM_URL/activity.php?act_id=${LKACT}&act_type=C" >/dev/null
		if grep -q 'disabled name="act_date"' "$BODY"; then
			bad "the lock greys the form out for a system user"
		else
			ok "the lock exempts the system group on the read side"
		fi
		curl -s --max-time 30 -b "$COOKIES" -o "$BODY" -X POST \
			--data-urlencode "_csrf=$(lk_token "$COOKIES")" \
			-d "act_type=C" -d "close_act=1" -d "user_id=${LKUID}" \
			-d "act_id=${LKACT}" -d "act_date=${LK_OLD}" -d "hours=8.00" \
			--data-urlencode "summary=ZZLK admin edit" \
			"$OCM_URL/ops/update_activity.php" >/dev/null
		if [ "$(adb "SELECT summary FROM activities WHERE act_id = ${LKACT}")" = 'ZZLK admin edit' ]; then
			ok "a system user still saves inside the locked window"
		else
			bad "the lock also refuses the system group, which it must not"
		fi

		# 34i. ops/update_activity.php must not let act_url reach outside
		# this site.
		#
		# The form carries act_url, the page to return to once the save
		# finishes, and three redirects put it straight into a Location
		# header as "{base_url}/{act_url}". base_url comes from
		# cms-custom/config/settings.php, so it is "/cms" here and under
		# Docker, and on that deployment "/cms" . "/" . "//host" is
		# "/cms///host" -- still a path on this host, and not a way out.
		#
		# It is a way out where base_url is "", which is what an install
		# serving the application at the domain root writes (the shipped
		# settings.php.example carries 'base_url' => "/cms" for a subdirectory
		# install, and that value is edited per deployment). There
		# "" . "/" . "//host" is "///host", and a browser resolves that to
		# http://host/ -- the URL parser skips the extra slashes before
		# reading the authority. A request that set act_url then chose the
		# next page a logged-in staff member saw, and the
		# credential-phishing page it lands on was reached by following a
		# real link inside the application they already trust. Confirmed by
		# hand against this stack with base_url emptied.
		#
		# So this asserts on what the code appends rather than on where the
		# header happens to point, which is the part the fix controls and the
		# only part that is the same on both deployments: after base_url
		# there must be exactly one slash. Two would be the request's own
		# slashes surviving.
		#
		# pl_safe_redirect_path() refuses a value it cannot read as a page in
		# this application, and an off-site act_url is one of those, so what
		# it returns is '' and the whole header is base_url and the slash
		# this file adds. An earlier version of the guard reduced the value
		# to a path that still carried the attacker's hostname, and this
		# check accepted that; it does not any more.
		ULOC="$(curl -s --max-time 30 -b "$COOKIES" -o /dev/null -D - -X POST \
			--data-urlencode "_csrf=$(lk_token "$COOKIES")" \
			-d "act_type=C" -d "close_act=1" -d "user_id=${LKUID}" \
			-d "act_id=${LKACT}" -d "act_date=${LK_OLD}" -d "hours=8.00" \
			--data-urlencode "summary=ZZLK admin edit" \
			--data-urlencode "act_url=//zz-evil.example/steal" \
			"$OCM_URL/ops/update_activity.php" \
			| grep -i '^location:' | tr -d '\r' | head -1)"
		UTARGET="$(printf '%s' "$ULOC" | sed -e 's/^[Ll][Oo][Cc][Aa][Tt][Ii][Oo][Nn]: *//')"
		# The path base_url gives this deployment, taken from OCM_URL so the
		# check does not have to know it: "http://host:port/cms" -> "/cms".
		UBASE="$(printf '%s' "$OCM_URL" \
			| sed -e 's#^[A-Za-z][A-Za-z0-9+.-]*://[^/]*##' -e 's#/*$##')"
		case "$UTARGET" in
			'')
				bad "ops/update_activity.php sent no Location header at all" ;;
			*://*)
				bad "ops/update_activity.php still redirects to an absolute URL (${ULOC})" ;;
			//*)
				bad "ops/update_activity.php still redirects off-site, protocol-relative (${ULOC})" ;;
			"${UBASE}//"*)
				bad "ops/update_activity.php still appends act_url's leading slashes, which is an off-site redirect wherever base_url is empty (${ULOC})" ;;
			"${UBASE}/")
				ok "ops/update_activity.php refuses an off-site act_url and sends the browser to the site root" ;;
			*)
				bad "ops/update_activity.php redirected somewhere unexpected (${ULOC})" ;;
		esac

		# Positive control: an act_url the form really does send must still
		# reach the page it names, or the check above only proves the
		# redirect is broken.
		ULOC="$(curl -s --max-time 30 -b "$COOKIES" -o /dev/null -D - -X POST \
			--data-urlencode "_csrf=$(lk_token "$COOKIES")" \
			-d "act_type=C" -d "close_act=1" -d "user_id=${LKUID}" \
			-d "act_id=${LKACT}" -d "act_date=${LK_OLD}" -d "hours=8.00" \
			--data-urlencode "summary=ZZLK admin edit" \
			--data-urlencode "act_url=cal_day.php" \
			"$OCM_URL/ops/update_activity.php" \
			| grep -i '^location:' | tr -d '\r' | head -1)"
		# The whole target, not a substring. A match on "/cal_day.php?cal_date="
		# would also accept https://evil.example/cal_day.php?cal_date= with no
		# date on the end of it. cal_(day|week|adv) is the branch at
		# ops/update_activity.php:344-348, and it appends the posted act_date.
		UWANT="${UBASE}/cal_day.php?cal_date=${LK_OLD}"
		UTARGET="$(printf '%s' "$ULOC" \
			| sed -e 's/^[Ll][Oo][Cc][Aa][Tt][Ii][Oo][Nn]: *//')"
		if [ "$UTARGET" = "$UWANT" ]; then
			ok "a real act_url still redirects to the page it names"
		else
			bad "a real act_url no longer reaches its page (wanted ${UWANT}, got ${UTARGET})"
		fi
	fi

	cleanup_lk
	trap 'rm -f "$COOKIES" "$BODY"' EXIT
else
	printf '  skip the calendar hours and activity lock checks (needs the database)\n'
fi

echo
echo "35. cross-site GETs that used to mutate"

# pl_csrf_check() does two jobs. On a POST it validates the per-session
# token; on any other method it falls through to
# pl_request_cross_site_verdict() and refuses a 'cross' verdict. Most
# handlers wrap the call in a REQUEST_METHOD === 'POST' test, which drops
# the second half. That is right for a read page and wrong for the three
# handlers that dispatch a write out of the query string.
if [ "$HAVE_DB" = 1 ]; then
	XSMENU='menu_zzxs'

	cleanup_xs() {
		adb "DROP TABLE IF EXISTS \`${XSMENU}\`" >/dev/null
		adb "DELETE FROM outcome_goals WHERE goal LIKE 'ZZXS%'" >/dev/null
	}
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_xs' EXIT
	cleanup_xs

	adb "CREATE TABLE \`${XSMENU}\` (
		value char(12) NOT NULL DEFAULT '',
		label char(65) NOT NULL DEFAULT '',
		menu_order tinyint(4) DEFAULT NULL,
		KEY value (value)
	)" >/dev/null
	adb "INSERT INTO \`${XSMENU}\` (value, label, menu_order) VALUES ('zzkeep', 'Keep Me', 1)" >/dev/null
	# problem is char(2), and outcome_goal_id is NOT NULL with no
	# auto_increment, so both have to be supplied by hand.
	XSPROB='ZZ'
	XSGOAL="$(adb "SELECT COALESCE(MAX(outcome_goal_id), 0) + 1 FROM outcome_goals")"
	adb "INSERT INTO outcome_goals (outcome_goal_id, problem, goal, active, outcome_goal_order)
		VALUES (${XSGOAL}, '${XSPROB}', 'ZZXS goal', 1, 0)" >/dev/null

	# $1 the Sec-Fetch-Site value, $2 the path and query. Prints the status.
	xs_get() {
		curl -s --max-time 30 -b "$COOKIES" -o "$BODY" -w '%{http_code}' \
			-H "Sec-Fetch-Site: $1" "$OCM_URL/$2"
	}

	# 35a. The worst of the three. ?action=update_pba mass-assigns $_GET onto
	# a pb_attorneys row, and a password in the query string is hashed and
	# written, so a link opened by an administrator reset that attorney's
	# password.
	if [ "$(xs_get cross-site 'pb_attorneys.php?action=update_pba&pba_id=1&password=zzforged')" = 403 ]; then
		ok "a cross-site GET cannot reset a pro bono attorney password"
	else
		bad "pb_attorneys.php?action=update_pba still runs for a cross-site GET"
	fi

	# 35b. And the refusal has to happen before the write, not after it.
	xs_get cross-site "system-menus.php?action=delete&menu_name=${XSMENU}&value=zzkeep" >/dev/null
	if [ "$(adb "SELECT COUNT(*) FROM \`${XSMENU}\` WHERE value = 'zzkeep'")" = 1 ]; then
		ok "a cross-site GET cannot delete a menu row"
	else
		bad "a cross-site GET deleted a menu row"
	fi

	# 35c. system-outcomes.php runs UPDATE outcome_goals SET active = 0
	# before it reads the submitted list, so a GET carrying no values
	# deactivated every goal for the named problem.
	xs_get cross-site "system-outcomes.php?action=update&outcome=${XSPROB}" >/dev/null
	if [ "$(adb "SELECT active FROM outcome_goals WHERE outcome_goal_id = ${XSGOAL}")" = 1 ]; then
		ok "a cross-site GET cannot deactivate the goals for a problem"
	else
		bad "a cross-site GET deactivated the goals for a problem"
	fi

	# 35d. A request that started on one of our own pages is untouched. The
	# check refuses a 'cross' verdict only; a typed URL, a bookmark and an
	# emailed link all read as 'unknown' and still go through.
	xs_status="$(xs_get same-origin "system-menus.php?action=delete&menu_name=${XSMENU}&value=zzkeep")"
	if [ "$(adb "SELECT COUNT(*) FROM \`${XSMENU}\` WHERE value = 'zzkeep'")" = 0 ]; then
		ok "a same-site GET still deletes a menu row (status ${xs_status})"
	else
		bad "the cross-site check also refuses a same-site menu delete"
	fi
	xs_status="$(curl -s --max-time 30 -b "$COOKIES" -o "$BODY" -w '%{http_code}' \
		"$OCM_URL/system-menus.php?menu_name=${XSMENU}")"
	if [ "$xs_status" = 200 ]; then
		ok "a GET with no Sec-Fetch-Site header still reaches the menu editor"
	else
		bad "the cross-site check refuses a plain GET (status ${xs_status})"
	fi

	# 35e. Left-over debugging in the same handler printed the submitted and
	# the stored goal lists to the browser. Because it wrote output before
	# the header("Location: ...") at the end of the case, the redirect never
	# fired either.
	xs_status="$(curl -s --max-time 30 -b "$COOKIES" -o "$BODY" -w '%{http_code}' \
		-H 'Sec-Fetch-Site: same-origin' \
		"$OCM_URL/system-outcomes.php?action=update&outcome=${XSPROB}")"
	if [ "$xs_status" = 302 ] && ! grep -q '<pre>' "$BODY"; then
		ok "the outcome goal save redirects and prints no debug dump"
	else
		bad "system-outcomes.php?action=update still dumps output (status ${xs_status})"
	fi

	cleanup_xs
	trap 'rm -f "$COOKIES" "$BODY"' EXIT
else
	printf '  skip the cross-site GET checks (needs the database)\n'
fi

# 37. The advanced calendar staff filter.
#
# The Staff and Pro Bono pickers on cal_adv.php are checkbox_list plugins.
# That plugin keeps the selection in a single hidden field holding a
# comma-separated list of ids, so the value arrives as a string, not as a
# name[] array. sizeof() on a string is a fatal TypeError on PHP 8, so every
# click of the View button returned a blank page.
#
# The same section covers the mega party report, which reached sizeof() with
# the null that pl_grab_post() returns for a field that was never submitted.
echo
echo "checking the advanced calendar staff filter"

cleanup_cal_adv()
{
	if [ "$HAVE_DB" != 1 ]; then
		return
	fi
	adb "DELETE FROM activities WHERE summary LIKE 'ZZCAL%'" >/dev/null 2>&1
	adb "DELETE FROM users WHERE last_name = 'ZZCALSTAFF'" >/dev/null 2>&1
}

if [ "$HAVE_DB" = 1 ] && [ "$HAVE_COMPOSE" = 1 ]; then
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_cal_adv' EXIT
	cleanup_cal_adv

	CALUSER="$(adb "SELECT COALESCE(MAX(user_id), 0) + 1 FROM users")"
	adb "INSERT INTO users (user_id, username, password, enabled, group_id, last_name, first_name)
		VALUES (${CALUSER}, 'zzcalstaff', '', 1, 'system', 'ZZCALSTAFF', 'Other')" >/dev/null

	# act_id is a primary key with no AUTO_INCREMENT, so pick the ids here.
	CALACT="$(adb "SELECT COALESCE(MAX(act_id), 0) + 1 FROM activities")"
	CALACT2=$((CALACT + 1))
	CALDAY="$(date +%Y-%m-%d)"
	adb "INSERT INTO activities (act_id, act_date, act_time, hours, completed, act_type, user_id, summary)
		VALUES (${CALACT}, '${CALDAY}', '09:00:00', 1.00, 1, 'T', 1, 'ZZCALADMIN')" >/dev/null
	adb "INSERT INTO activities (act_id, act_date, act_time, hours, completed, act_type, user_id, summary)
		VALUES (${CALACT2}, '${CALDAY}', '10:00:00', 1.00, 1, 'T', ${CALUSER}, 'ZZCALOTHER')" >/dev/null

	# An empty picker is what the form submits when nothing is checked.
	CALCODE="$(curl -s --max-time 30 -b "$COOKIES" -o "$BODY" -w '%{http_code}' \
		"$OCM_URL/cal_adv.php?action=run_report&user_list=&pba_list=&start_date=${CALDAY}&end_date=${CALDAY}")"
	if [ "$CALCODE" = "200" ] && [ -s "$BODY" ]; then
		ok "the advanced calendar runs with an empty staff selection"
	else
		bad "the advanced calendar returned ${CALCODE} for an empty staff selection"
	fi

	# With nothing checked the page defaults to the signed-in user, so the
	# other staff member's activity must not be on it.
	if grep -q 'ZZCALADMIN' "$BODY" && ! grep -q 'ZZCALOTHER' "$BODY"; then
		ok "an empty staff selection lists only the signed-in user"
	else
		bad "an empty staff selection did not default to the signed-in user"
	fi

	# The hidden field has to come back with the selection in it, or the
	# checkboxes redraw empty and the next View discards the filter.
	if grep -qE 'name="user_list"[^>]*value="1"' "$BODY"; then
		ok "the staff picker redraws with the selection still in it"
	else
		bad "the staff picker lost its selection on redraw"
	fi

	CALCODE="$(curl -s --max-time 30 -b "$COOKIES" -o "$BODY" -w '%{http_code}' \
		"$OCM_URL/cal_adv.php?action=run_report&user_list=${CALUSER}&pba_list=&start_date=${CALDAY}&end_date=${CALDAY}")"
	if [ "$CALCODE" = "200" ] && grep -q 'ZZCALOTHER' "$BODY" && ! grep -q 'ZZCALADMIN' "$BODY"; then
		ok "picking one staff member lists only that staff member"
	else
		bad "picking one staff member did not filter the listing (HTTP ${CALCODE})"
	fi

	# The mega party report with no columns checked.
	curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" "$OCM_URL/reports/megapartyreport/" >/dev/null
	CALTOK="$(grep -oE 'name="_csrf" value="[0-9a-f]{64}"' "$BODY" | head -1 | sed -e 's/.*value="//' -e 's/"$//')"
	curl -s --max-time 30 -b "$COOKIES" -o "$BODY" -X POST \
		-d "_csrf=${CALTOK}&report_format=html" \
		"$OCM_URL/reports/megapartyreport/report.php" >/dev/null
	if grep -q 'you need to check off the fields' "$BODY"; then
		ok "the mega party report explains an empty column list"
	else
		bad "the mega party report returned a blank page for an empty column list"
	fi

	cleanup_cal_adv
	trap 'rm -f "$COOKIES" "$BODY"' EXIT
else
	printf '  skip the advanced calendar checks (needs the database)\n'
fi

echo
echo "38. a password change ends the account's other sessions"

# A stolen session cookie used to survive the one thing an account holder is
# told to do about it. cms/password.php and the administrator reset in
# cms/system-users.php now call pl_user_sessions_invalidate_others(), which
# marks every other user_sessions row logout = 1; pikaAuth::authenticate()
# refuses a row in that state on the next request.
if [ "$HAVE_DB" = 1 ] && [ "$HAVE_COMPOSE" = 1 ]; then
	PWUSER='zz_pw_user'
	PWPASS='zz-pw-Passw0rd'
	PWNEW='zz-pw-N3wPassw0rd'
	PWJARA="$(mktemp)"
	PWJARB="$(mktemp)"

	cleanup_pw() {
		adb "DELETE FROM user_sessions WHERE user_id IN (SELECT user_id FROM users WHERE username = '${PWUSER}')" >/dev/null
		adb "DELETE FROM users WHERE username = '${PWUSER}'" >/dev/null
		adb "DELETE FROM \`groups\` WHERE group_id = 'zz_pw_grp'" >/dev/null
		rm -f "$PWJARA" "$PWJARB"
	}
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_pw' EXIT
	cleanup_pw

	adb "INSERT INTO \`groups\` (group_id, read_office, read_all, edit_office, edit_all, users, pba, motd, intake, reports)
		VALUES ('zz_pw_grp', NULL, 0, NULL, 0, 0, 0, 0, 0, NULL)" >/dev/null

	# password_expire is an int-ish column. A date literal truncates to its
	# leading digits and the account reads as expired, so the login below
	# would fail for a reason that has nothing to do with this section.
	PWHASH="$(docker compose "${COMPOSE_ARGS[@]}" exec -T app \
		php -r 'echo password_hash($argv[1], PASSWORD_DEFAULT);' "$PWPASS" </dev/null 2>/dev/null)"
	PWUID="$(adb "SELECT COALESCE(MAX(user_id), 0) + 1 FROM users")"
	adb "INSERT INTO users (user_id, username, password, enabled, group_id, password_expire)
		VALUES (${PWUID}, '${PWUSER}', '${PWHASH}', 1, 'zz_pw_grp', 0)" >/dev/null

	pw_login() {
		: > "$1"
		curl -sL --max-time 30 -c "$1" -b "$1" -o /dev/null \
			-X POST -d "login_user=${PWUSER}&login_pass=${2}&auth_id=1" \
			"$OCM_URL/" >/dev/null
	}

	# The login form is what an evicted session gets back, and it is the only
	# page in this flow that carries a login_pass field.
	pw_signed_in() {
		curl -sL --max-time 30 -c "$1" -b "$1" -o "$BODY" "$OCM_URL/password.php" >/dev/null
		! grep -q 'name="login_pass"' "$BODY"
	}

	pw_token() {
		curl -sL --max-time 30 -c "$1" -b "$1" "$OCM_URL/password.php" \
			| grep -oE 'name="_csrf" value="[0-9a-f]{64}"' \
			| head -1 | sed -e 's/.*value="//' -e 's/"$//'
	}

	if [ -z "$PWHASH" ] || [ -z "${PWUID:-}" ]; then
		bad "could not seed the password change fixtures"
	else
		pw_login "$PWJARA" "$PWPASS"
		pw_login "$PWJARB" "$PWPASS"

		if pw_signed_in "$PWJARA" && pw_signed_in "$PWJARB"; then
			ok "the throwaway user holds two sessions at once"
		else
			bad "the throwaway user could not open two sessions - section 38 is untested"
		fi

		# Count the audit rows first. user_id values are reused once the
		# fixture user is deleted, so a row left behind by an earlier run of
		# this section would make the assertion below pass on its own.
		PWAUDIT0="$(adb "SELECT COUNT(*) FROM audit_log WHERE action = 'password.self_change_invalidated_sessions' AND object_id = '${PWUID}'")"

		PWTOK="$(pw_token "$PWJARA")"
		sm_password_post "$PWJARA" "$PWPASS" \
			-d "_csrf=${PWTOK}&action=update&oldpass=${PWPASS}&newpass1=${PWNEW}&newpass2=${PWNEW}" \
			"$OCM_URL/password.php" >/dev/null
		if sed 's/&nbsp;/ /g' "$BODY" | grep -q 'Password updated successfully'; then
			ok "the self-service password change is accepted"
		else
			bad "the self-service password change was refused - section 38 is untested"
		fi

		if ! pw_signed_in "$PWJARB"; then
			ok "the other session is signed out by the password change"
		else
			bad "A SESSION OPENED WITH THE OLD PASSWORD SURVIVED THE PASSWORD CHANGE"
		fi

		# The session that made the change has to stay: signing the account
		# holder out of their own browser is not the fix, and a helper that
		# logs out everybody would pass the assertion above for free.
		if pw_signed_in "$PWJARA"; then
			ok "the session that changed the password stays signed in"
		else
			bad "the password change signed the account holder out of their own session"
		fi

		PWAUDIT1="$(adb "SELECT COUNT(*) FROM audit_log WHERE action = 'password.self_change_invalidated_sessions' AND object_id = '${PWUID}'")"
		if [ "${PWAUDIT1:-0}" -gt "${PWAUDIT0:-0}" ]; then
			ok "the evicted sessions are recorded in the audit log"
		else
			bad "no audit row for the sessions the password change ended"
		fi

		# The administrator reset is the other half. It runs against a user
		# who is not the administrator, so every session that user holds has
		# to go, not all but one.
		pw_login "$PWJARB" "$PWNEW"
		if pw_signed_in "$PWJARB"; then
			ok "the throwaway user signs back in with the new password"
		else
			bad "the throwaway user cannot sign in with the new password"
		fi

		ADMTOK="$(pw_token "$COOKIES")"
		sm_auth_grant "$COOKIES" "$OCM_PASSWORD" user_admin "$OCM_URL/system-users.php"
		ADMTOK="$(pw_token "$COOKIES")"
		curl -sL --max-time 30 -c "$COOKIES" -b "$COOKIES" -o "$BODY" -X POST \
			-d "_csrf=${ADMTOK}&action=update&user_id=${PWUID}&username=${PWUSER}&group_id=zz_pw_grp&enabled=1&password=zz-pw-Adm1nReset" \
			"$OCM_URL/system-users.php" >/dev/null

		if [ "$(adb "SELECT COUNT(*) FROM user_sessions WHERE user_id = ${PWUID} AND logout = 0")" = 0 ]; then
			ok "an administrator password reset ends every session the user holds"
		else
			bad "A SESSION SURVIVED AN ADMINISTRATOR PASSWORD RESET"
		fi

		if pw_signed_in "$COOKIES"; then
			ok "the administrator keeps their own session through the reset"
		else
			bad "the administrator was signed out by resetting somebody else's password"
		fi
	fi

	cleanup_pw
	trap 'rm -f "$COOKIES" "$BODY"' EXIT
else
	printf '  skip the password change session checks (needs the database)\n'
fi

# ── 40. The session address pin ────────────────────────────────────────────
# A signed-in session is tied to the browser and the network it was made
# from. The 2019 code accepted either one on its own, and a user agent
# string is not a secret, so a stolen cookie was enough. These checks drive
# the pin through a real session: the fixture signs in, the stored address
# on its own user_sessions row is rewritten, and the next request says
# whether the session survived.
echo
echo "40. the session address pin"
if [ "$HAVE_DB" = 1 ] && [ "$HAVE_COMPOSE" = 1 ]; then
	PINGROUP="zz_pin_grp"
	PINUSER="zz_pin_user"
	PINPASS="zz-pin-Passw0rd"
	PINJAR="$(mktemp)"
	PINMODE="$(adb "SELECT value FROM settings WHERE label = 'session_ip_pin'")"

	cleanup_pin() {
		adb "DELETE FROM user_sessions WHERE user_id = ${PINUID:-0}" >/dev/null
		adb "DELETE FROM users WHERE username = '${PINUSER}'" >/dev/null
		adb "DELETE FROM \`groups\` WHERE group_id = '${PINGROUP}'" >/dev/null
		adb "UPDATE settings SET value = '${PINMODE:-network}' WHERE label = 'session_ip_pin'" >/dev/null
		rm -f "$PINJAR"
	}
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_pin' EXIT

	adb "INSERT INTO \`groups\` (group_id, read_office, read_all, edit_office, edit_all, users, pba, motd, intake, reports)
		VALUES ('${PINGROUP}', NULL, 1, NULL, 0, 0, 0, 0, 0, NULL)" >/dev/null
	PINHASH="$(docker compose "${COMPOSE_ARGS[@]}" exec -T app \
		php -r 'echo password_hash($argv[1], PASSWORD_DEFAULT);' "$PINPASS" </dev/null 2>/dev/null)"
	PINUID="$(adb "SELECT COALESCE(MAX(user_id), 0) + 1 FROM users")"
	adb "INSERT INTO users (user_id, username, password, enabled, group_id, password_expire)
		VALUES (${PINUID}, '${PINUSER}', '${PINHASH}', 1, '${PINGROUP}', 0)" >/dev/null

	# Sign the fixture in and hand back the user_sessions row it minted.
	# $1 is the user agent to sign in with.
	pin_login() {
		: > "$PINJAR"
		curl -s --max-time 30 -c "$PINJAR" -b "$PINJAR" -o /dev/null -A "$1" "$OCM_URL/" >/dev/null
		curl -sL --max-time 30 -c "$PINJAR" -b "$PINJAR" -o /dev/null -A "$1" \
			-d "login_user=${PINUSER}&login_pass=${PINPASS}&auth_id=1" "$OCM_URL/" >/dev/null
		adb "SELECT user_session_id FROM user_sessions
			WHERE user_id = ${PINUID} AND (logout IS NULL OR logout = 0)
			ORDER BY user_session_id DESC LIMIT 1"
	}

	# Make one more request on the fixture's session and say whether it is
	# still signed in. "yes" means the application answered; "no" means it
	# put the login form up instead. $1 is the user agent.
	pin_still_in() {
		curl -sL --max-time 30 -c "$PINJAR" -b "$PINJAR" -o "$BODY" -A "$1" \
			"$OCM_URL/password.php" >/dev/null
		if grep -q 'login_pass' "$BODY"; then
			printf 'no\n'
		else
			printf 'yes\n'
		fi
	}

	if [ -z "$PINHASH" ] || [ -z "${PINUID:-}" ]; then
		bad "could not seed the session pin fixtures (hash/user)"
	else
		# 40a. The ordinary case. An address that moves inside the network
		# the session was made on is not a hijack, and signing people out
		# for it is what makes an office turn the whole control off.
		PINSID="$(pin_login 'smoke-pin-agent')"
		PINIP="$(adb "SELECT ip_address FROM user_sessions WHERE user_session_id = ${PINSID}")"
		PINNET="$(printf '%s' "$PINIP" | cut -d. -f1-3)"
		adb "UPDATE user_sessions SET ip_address = '${PINNET}.222' WHERE user_session_id = ${PINSID}" >/dev/null
		if [ "$(pin_still_in 'smoke-pin-agent')" = yes ]; then
			ok "a session continues from another address on the same network"
		else
			bad "a session was refused for moving inside its own network"
		fi

		# 40b. A different network is refused even though the user agent
		# still matches. This is the half the old rule gave away: it
		# accepted a matching address OR a matching user agent, and a user
		# agent string is one header to copy, so a stolen cookie replayed
		# from anywhere was enough.
		PINSID="$(pin_login 'smoke-pin-agent')"
		adb "UPDATE user_sessions SET ip_address = '10.99.99.99' WHERE user_session_id = ${PINSID}" >/dev/null
		if [ "$(pin_still_in 'smoke-pin-agent')" = no ]; then
			ok "a session from a different network is refused"
		else
			bad "a session was accepted from a different network"
		fi

		# 40c. And the other half: the right address is not enough either.
		PINSID="$(pin_login 'smoke-pin-agent')"
		if [ "$(pin_still_in 'smoke-pin-other-agent')" = no ]; then
			ok "a matching address alone does not carry a session"
		else
			bad "a matching address alone still carries a session"
		fi

		# 40d. An office whose public address will not hold still has to be
		# able to turn the address half off, or it turns off sign-in
		# security altogether by other means.
		adb "UPDATE settings SET value = 'off' WHERE label = 'session_ip_pin'" >/dev/null
		PINSID="$(pin_login 'smoke-pin-agent')"
		adb "UPDATE user_sessions SET ip_address = '10.99.99.99' WHERE user_session_id = ${PINSID}" >/dev/null
		if [ "$(pin_still_in 'smoke-pin-agent')" = yes ]; then
			ok "session_ip_pin=off lets a moved address through"
		else
			bad "session_ip_pin=off did not turn the address check off"
		fi

		# 40e. The user agent pin is not part of the setting, so it still
		# applies with the address check off.
		PINSID="$(pin_login 'smoke-pin-agent')"
		if [ "$(pin_still_in 'smoke-pin-other-agent')" = no ]; then
			ok "session_ip_pin=off leaves the user agent pin in place"
		else
			bad "session_ip_pin=off also turned the user agent pin off"
		fi
		adb "UPDATE settings SET value = 'network' WHERE label = 'session_ip_pin'" >/dev/null

		# 40f. The column has to hold an address. At VARCHAR(15) an IPv6
		# client's address is silently cut to its first 15 characters, the
		# next request compares the piece against the whole, and the user
		# is bounced back to the sign-in page every time they sign in.
		PINSID="$(pin_login 'smoke-pin-agent')"
		PINV6='2001:0db8:85a3:0000:0000:8a2e:0370:7334'
		adb "UPDATE user_sessions SET ip_address = '${PINV6}' WHERE user_session_id = ${PINSID}" >/dev/null
		if [ "$(adb "SELECT ip_address FROM user_sessions WHERE user_session_id = ${PINSID}")" = "$PINV6" ]; then
			ok "user_sessions.ip_address holds a full IPv6 address"
		else
			bad "user_sessions.ip_address truncates an IPv6 address"
		fi

		# 40g. An administrator has to be able to find the switch.
		curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" "$OCM_URL/system-settings.php" >/dev/null
		if grep -q 'name="session_ip_pin"' "$BODY"; then
			ok "system-settings.php offers the session address pin control"
		else
			bad "system-settings.php has no session address pin control"
		fi
	fi

	cleanup_pin
	trap 'rm -f "$COOKIES" "$BODY"' EXIT
else
	printf '  skip the session address pin checks (needs the database)\n'
fi

# ── 41. The forced password change ─────────────────────────────────────────
# A password somebody else chose - the container entrypoint's generated
# bootstrap value, or one an administrator typed on the user form - is a
# credential the account holder does not own. users.must_change_password
# marks that, and every page except password.php, enroll_mfa.php and
# logout.php sends the account back to password.php until it is cleared.
# These checks drive it through a real session.
echo
echo "41. the forced password change"
if [ "$HAVE_DB" = 1 ] && [ "$HAVE_COMPOSE" = 1 ]; then
	MCPGROUP="zz_mcp_grp"
	MCPUSER="zz_mcp_user"
	MCPPASS="zz-mcp-Passw0rd"
	MCPNEW="zz-mcp-Newpass1"
	MCPJAR="$(mktemp)"

	cleanup_mcp() {
		adb "DELETE FROM user_sessions WHERE user_id = ${MCPUID:-0}" >/dev/null
		adb "DELETE FROM users WHERE username = '${MCPUSER}'" >/dev/null
		adb "DELETE FROM \`groups\` WHERE group_id = '${MCPGROUP}'" >/dev/null
		rm -f "$MCPJAR"
	}
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_mcp' EXIT

	# read_all so the fixture has somewhere to be redirected away from.
	adb "INSERT INTO \`groups\` (group_id, read_office, read_all, edit_office, edit_all, users, pba, motd, intake, reports)
		VALUES ('${MCPGROUP}', NULL, 1, NULL, 0, 0, 0, 0, 0, NULL)" >/dev/null
	MCPHASH="$(docker compose "${COMPOSE_ARGS[@]}" exec -T app \
		php -r 'echo password_hash($argv[1], PASSWORD_DEFAULT);' "$MCPPASS" </dev/null 2>/dev/null)"
	MCPUID="$(adb "SELECT COALESCE(MAX(user_id), 0) + 1 FROM users")"
	adb "INSERT INTO users (user_id, username, password, enabled, group_id, password_expire, must_change_password)
		VALUES (${MCPUID}, '${MCPUSER}', '${MCPHASH}', 1, '${MCPGROUP}', 0, 1)" >/dev/null

	# Sign the fixture in. Echoes the URL the browser ended on, which is the
	# whole point: a flagged account is redirected off the page it asked for.
	mcp_login() {
		: > "$MCPJAR"
		curl -s --max-time 30 -c "$MCPJAR" -b "$MCPJAR" -o /dev/null "$OCM_URL/" >/dev/null
		curl -sL --max-time 30 -c "$MCPJAR" -b "$MCPJAR" -o "$BODY" -w '%{url_effective}' \
			-d "login_user=${MCPUSER}&login_pass=${MCPPASS}&auth_id=1" "$OCM_URL/"
	}

	# The CSRF token off whatever page the fixture is looking at.
	mcp_token() {
		grep -oE 'name="_csrf" value="[0-9a-f]{64}"' "$BODY" \
			| head -1 | sed -e 's/.*value="//' -e 's/"$//'
	}

	if [ -z "$MCPHASH" ] || [ -z "${MCPUID:-}" ]; then
		bad "could not build the forced-password-change fixture - section 41 is untested"
	else
		# The column the whole feature rests on. Without the upgrade applied
		# the gate is a no-op and every other check here passes vacuously.
		if [ "$(adb "SELECT COUNT(*) FROM information_schema.columns
			WHERE table_schema = DATABASE() AND table_name = 'users'
			AND column_name = 'must_change_password'")" = 1 ]; then
			ok "users carries the must_change_password column"
		else
			bad "users has no must_change_password column - add_must_change_password.sql was not applied"
		fi

		# The login POST is the request that trips the gate most often. It
		# has to arrive at password.php, not at the home page, and not at an
		# error: a 302 here would make the browser repeat the login POST
		# against password.php, where it is refused for carrying no CSRF
		# token. The gate answers 303 for that reason.
		MCPLANDED="$(mcp_login)"
		case "$MCPLANDED" in
			*password.php*)
				ok "a flagged account lands on the password page after signing in" ;;
			*)
				bad "a flagged account signed in and landed on ${MCPLANDED}" ;;
		esac

		if grep -q 'newpass1' "$BODY"; then
			ok "the password page renders for a flagged account"
		else
			bad "a flagged account cannot reach the form that would clear the flag"
		fi

		# Every other page. system-maint.php is a plain authenticated page
		# the fixture's group can otherwise load.
		MCPLANDED="$(curl -sL --max-time 30 -b "$MCPJAR" -c "$MCPJAR" -o "$BODY" \
			-w '%{url_effective}' "$OCM_URL/system-maint.php")"
		case "$MCPLANDED" in
			*password.php*)
				ok "a flagged account is turned back from another page" ;;
			*)
				bad "a flagged account reached ${MCPLANDED} without changing its password" ;;
		esac

		# Most of the reads and writes in this application go through
		# services/*-server-ajax.php. A gate that only covers the front door
		# would leave a flagged account free to drive the whole application
		# from there. The answer has to be JSON: an ajax caller parses a
		# redirect body as if it were the reply.
		MCPCODE="$(curl -s --max-time 30 -b "$MCPJAR" -o "$BODY" -w '%{http_code}' \
			"$OCM_URL/services/cases-lookup-ajax.php?q=zz")"
		if [ "$MCPCODE" = 403 ] && grep -q 'password_change_required' "$BODY"; then
			ok "an ajax endpoint refuses a flagged account in JSON"
		else
			bad "the ajax endpoint answered a flagged account with ${MCPCODE} and no JSON refusal"
		fi

		# Now clear it the way a person does.
		sm_auth_grant "$MCPJAR" "$MCPPASS" password_change "$OCM_URL/password.php"
		MCPTOK="$(mcp_token)"
		MCPBEFORE="$(adb "SELECT password FROM users WHERE user_id = ${MCPUID}")"
		curl -sL --max-time 30 -b "$MCPJAR" -c "$MCPJAR" -o "$BODY" \
			-d "action=update" -d "_csrf=${MCPTOK}" \
			--data-urlencode "oldpass=${MCPPASS}" \
			--data-urlencode "newpass1=${MCPPASS}" \
			--data-urlencode "newpass2=${MCPPASS}" "$OCM_URL/password.php" >/dev/null
		if [ -n "$MCPBEFORE" ] \
			&& [ "$(adb "SELECT password FROM users WHERE user_id = ${MCPUID}")" = "$MCPBEFORE" ] \
			&& [ "$(adb "SELECT must_change_password FROM users WHERE user_id = ${MCPUID}")" = 1 ] \
			&& ! sed 's/&nbsp;/ /g' "$BODY" | grep -q 'Password updated successfully'; then
			ok "reusing a forced-change password leaves the hash and flag unchanged"
		else
			bad "reusing the current password cleared the forced-change flag or changed the hash"
		fi
		curl -sL --max-time 30 -b "$MCPJAR" -c "$MCPJAR" -o "$BODY" \
			"$OCM_URL/password.php" >/dev/null
		MCPTOK="$(mcp_token)"
		curl -sL --max-time 30 -b "$MCPJAR" -c "$MCPJAR" -o "$BODY" \
			-d "action=update" -d "_csrf=${MCPTOK}" \
			--data-urlencode "oldpass=${MCPPASS}" \
			--data-urlencode "newpass1=${MCPNEW}" \
			--data-urlencode "newpass2=${MCPNEW}" \
			"$OCM_URL/password.php" >/dev/null

		MCPAFTER="$(adb "SELECT password FROM users WHERE user_id = ${MCPUID}")"
		MCPNEWOK="$(docker compose "${COMPOSE_ARGS[@]}" exec -T app \
			php -r 'echo password_verify($argv[1], $argv[2]) ? "1" : "0";' "$MCPNEW" "$MCPAFTER" </dev/null 2>/dev/null)"
		if [ "$(adb "SELECT must_change_password FROM users WHERE user_id = ${MCPUID}")" = 0 ] \
			&& [ "$MCPAFTER" != "$MCPBEFORE" ] && [ "$MCPNEWOK" = 1 ]; then
			ok "changing the password clears the flag"
		else
			bad "the flag survived a password change - the account is stuck on the password page"
		fi

		MCPLANDED="$(curl -sL --max-time 30 -b "$MCPJAR" -c "$MCPJAR" -o "$BODY" \
			-w '%{url_effective}' "$OCM_URL/system-maint.php")"
		case "$MCPLANDED" in
			*system-maint.php*)
				ok "the account reaches other pages once its password is its own" ;;
			*)
				bad "the account still cannot leave the password page: ${MCPLANDED}" ;;
		esac

		# And the other half: an administrator setting somebody's password
		# has to raise the flag, or the admin-known value stays in service.
		sm_auth_grant "$COOKIES" "$OCM_PASSWORD" user_admin "$OCM_URL/system-users.php"
		curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" \
			"$OCM_URL/system-users.php?action=edit&user_id=${MCPUID}" >/dev/null
		MCPTOK="$(mcp_token)"
		curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" \
			-d "action=update" -d "_csrf=${MCPTOK}" -d "user_id=${MCPUID}" \
			-d "username=${MCPUSER}" -d "group_id=${MCPGROUP}" -d "enabled=1" \
			--data-urlencode "password=zz-mcp-Adminset1" \
			"$OCM_URL/system-users.php" >/dev/null

		if [ "$(adb "SELECT must_change_password FROM users WHERE user_id = ${MCPUID}")" = 1 ]; then
			ok "a password an administrator sets is marked for replacement"
		else
			bad "an admin-set password was not marked - it stays a credential two people know"
		fi
	fi

	cleanup_mcp
	trap 'rm -f "$COOKIES" "$BODY"' EXIT
else
	printf '  skip the forced password change (needs the database and compose)\n'
fi

echo
echo "44. the case lookup service answers only for cases the caller may read"

# services/cases-lookup-ajax.php asked pika_authorize('read_case', ...) and
# then emitted the whole case row either way -- the else branch was a copy of
# the branch above it. Any signed-in user could walk case_id from 1 upwards
# and read every field of every case, whatever their office or assignment.
#
# cases.office and cases.funding are char(3), and CI runs a non-strict
# sql_mode, so a longer marker in either column is silently cut to three
# characters and an assertion looking for the whole marker passes without
# testing anything. The markers below live in cases.number, which is
# varchar(24).
if [ "$HAVE_DB" = 1 ]; then
	CLGROUP='zz_cl_grp'
	CLUSER='zz_cl_user'
	CLPASS='zz-cl-Passw0rd'
	CLJAR="$(mktemp)"

	cleanup_cl() {
		adb "DELETE FROM audit_log WHERE action = 'case.read_denied'" >/dev/null
		adb "DELETE FROM cases WHERE number IN ('ZZ-CL-SECRET', 'ZZ-CL-OTHER', 'ZZ-CL-MINE')" >/dev/null
		adb "DELETE FROM users WHERE username = '${CLUSER}'" >/dev/null
		adb "DELETE FROM \`groups\` WHERE group_id = '${CLGROUP}'" >/dev/null
		rm -f "$CLJAR" "${BODY}.cl"
	}
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_cl' EXIT
	cleanup_cl

	# Every flag off: this user may reach its own cases and nothing else.
	adb "INSERT INTO \`groups\` (group_id, read_office, read_all, edit_office, edit_all, users, pba, motd, intake, reports)
		VALUES ('${CLGROUP}', NULL, 0, NULL, 0, 0, 0, 0, 0, NULL)" >/dev/null

	CLHASH="$(docker compose "${COMPOSE_ARGS[@]}" exec -T app \
		php -r 'echo password_hash($argv[1], PASSWORD_DEFAULT);' "$CLPASS" </dev/null 2>/dev/null)"
	CLUID="$(adb "SELECT COALESCE(MAX(user_id), 0) + 1 FROM users")"
	adb "INSERT INTO users (user_id, username, password, enabled, group_id, password_expire)
		VALUES (${CLUID}, '${CLUSER}', '${CLHASH}', 1, '${CLGROUP}', 0)" >/dev/null

	cl_seed_case() {
		# $1 case number, $2 owning user_id -> echoes the new case_id
		local cid
		cid="$(adb "SELECT GREATEST(
			COALESCE((SELECT MAX(case_id) FROM cases), 0),
			COALESCE((SELECT count FROM counters WHERE id = 'cases'), 0)) + 1")"
		adb "INSERT INTO cases (case_id, number, user_id, office, status, intake_user_id)
			VALUES (${cid}, '${1}', ${2}, 'ZZO', '1', 1)" >/dev/null
		adb "UPDATE counters SET count = GREATEST(count, ${cid}) WHERE id = 'cases'" >/dev/null
		echo "$cid"
	}

	# Two cases owned by somebody else and one owned by the caller.
	CLSECRET="$(cl_seed_case ZZ-CL-SECRET 1)"
	CLOTHER="$(cl_seed_case ZZ-CL-OTHER 1)"
	CLMINE="$(cl_seed_case ZZ-CL-MINE "$CLUID")"

	cl_lookup() {
		curl -sL --max-time 30 -b "$2" -o "$BODY" \
			"$OCM_URL/services/cases-lookup-ajax.php?case_id=${1}" >/dev/null
	}

	if [ -z "$CLHASH" ] || [ -z "${CLSECRET:-}" ] || [ -z "${CLOTHER:-}" ] || [ -z "${CLMINE:-}" ]; then
		bad "could not seed the case lookup fixtures"
	else
		: > "$CLJAR"
		curl -sL --max-time 30 -c "$CLJAR" -b "$CLJAR" -o "$BODY" \
			-X POST -d "login_user=${CLUSER}&login_pass=${CLPASS}&auth_id=1" \
			"$OCM_URL/" >/dev/null
		if grep -q 'login_pass' "$BODY"; then
			bad "the throwaway lookup user could not log in - section 44 is untested"
		else
			ok "the throwaway lookup user can log in"

			# 44a. The case this user owns still answers, so the fix did not
			# simply turn the endpoint off.
			cl_lookup "$CLMINE" "$CLJAR"
			if grep -q 'ZZ-CL-MINE' "$BODY"; then
				ok "a case the caller owns still returns its fields"
			else
				bad "the caller's own case no longer returns anything"
			fi

			# 44b. The case this user has no claim on must give up nothing.
			cl_lookup "$CLSECRET" "$CLJAR"
			if grep -q 'ZZ-CL-SECRET' "$BODY"; then
				bad "a case the caller cannot read returned its case number"
			else
				ok "a case the caller cannot read gives up no case number"
			fi
			if grep -qE '<(client_id|intake_user_id|user_id)>' "$BODY"; then
				bad "a case the caller cannot read returned case fields"
			else
				ok "a case the caller cannot read returns no case fields at all"
			fi

			# 44c. Still XML, so the caller's parser does not choke.
			if grep -q '<pikaCase' "$BODY"; then
				ok "the refusal is still a parseable pikaCase document"
			else
				bad "the refusal is not a pikaCase document"
			fi

			# 44d. Two different refused cases answer with the same bytes, so
			# the body carries nothing about which case was asked for.
			cp "$BODY" "${BODY}.cl"
			cl_lookup "$CLOTHER" "$CLJAR"
			if cmp -s "$BODY" "${BODY}.cl"; then
				ok "two different refused cases answer with identical bytes"
			else
				bad "the refusal body differs between two refused cases"
			fi
			rm -f "${BODY}.cl"

			# 44e. Both attempts are recorded, against the id that was asked for.
			if [ "$(adb "SELECT COUNT(*) FROM audit_log
					WHERE action = 'case.read_denied'
						AND object_id = ${CLSECRET}")" -ge 1 ] \
				&& [ "$(adb "SELECT COUNT(*) FROM audit_log
					WHERE action = 'case.read_denied'
						AND object_id = ${CLOTHER}")" -ge 1 ]; then
				ok "audit_log recorded case.read_denied for both refused cases"
			else
				bad "audit_log has no case.read_denied row for a refused case"
			fi
			if [ "$(adb "SELECT COUNT(*) FROM audit_log
					WHERE action = 'case.read_denied'
						AND object_id = ${CLMINE}")" = 0 ]; then
				ok "the case the caller owns is not recorded as a refusal"
			else
				bad "reading an allowed case was recorded as a refusal"
			fi

			# 44f. The administrator reads any case, as before.
			cl_lookup "$CLSECRET" "$COOKIES"
			if grep -q 'ZZ-CL-SECRET' "$BODY"; then
				ok "the admin still reads the case the other user cannot"
			else
				bad "the admin can no longer read the case - the gate is too tight"
			fi
		fi
	fi

	cleanup_cl
	trap 'rm -f "$COOKIES" "$BODY"' EXIT
else
	printf '  skip the case lookup checks (needs the database)\n'
fi

echo
echo "45. the stored and reflected XSS batch"

# plFlexList has two row entry points. addRow() escapes its cells with
# pl_clean_html_array(); addHtmlRow() deliberately does not, so that a caller
# can put real markup in a cell. Four list pages used addHtmlRow() and never
# escaped their own data columns, so a case number, a contact address or a
# red-flag name holding markup ran in the session of whoever opened the page.
#
# htmlContactList() is the reflected half. pl_clean_form_input() rewrites < and
# > on every request value but leaves quotes alone, and the contact-search
# subtemplates write the filter values into value="%%[field]%%" attributes, so
# one double quote closed the attribute and added an event handler to the
# search box.
#
# These are behavioural checks: seed a row through the database, fetch the
# page as the admin, and count live markup against escaped markup in what came
# back. A grep of the source would pass on a file that had the call and never
# reached it.
XSSPAY='<svg onload=alert(1)>'
XSSREF='zz" autofocus onfocus="alert(1)'
XSSREFQ='zz%22%20autofocus%20onfocus=%22alert(1)'

if [ "$HAVE_DB" = 1 ]; then
	cleanup_xss() {
		adb "DELETE FROM aliases WHERE last_name = 'ZZXSSDUPE'" >/dev/null
		adb "DELETE FROM contacts WHERE last_name = 'ZZXSSDUPE'" >/dev/null
		adb "DELETE FROM cases WHERE judge_name = 'ZZXSS'" >/dev/null
		adb "DELETE FROM pb_attorneys WHERE last_name = 'ZZXSSATTY'" >/dev/null
		adb "DELETE FROM flags WHERE name = 'zzxssflag'" >/dev/null
	}
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_xss' EXIT
	cleanup_xss

	# plBase::getNextID allocates from the counters table, not from MAX() of
	# the table, so a fixture placed at MAX()+1 alone can sit on an id the
	# application is about to hand out. Take the higher of the two and push
	# the counter up behind the row.
	xss_next_id() {
		adb "SELECT GREATEST(
			COALESCE((SELECT MAX(${2}) FROM \`${1}\`), 0),
			COALESCE((SELECT count FROM counters WHERE id = '${1}'), 0)) + 1"
	}
	xss_bump_counter() {
		adb "UPDATE counters SET count = GREATEST(count, ${2}) WHERE id = '${1}'" >/dev/null
	}

	# cases.number is varchar(24) and the CI database runs a non-strict
	# sql_mode, so an over-length payload would be truncated on the way in
	# without an error and the check would pass on a value that never held
	# the markup. The payload is 21 characters.
	XSSATTY="$(xss_next_id pb_attorneys pba_id)"
	adb "INSERT INTO pb_attorneys (pba_id, first_name, last_name, enabled)
		VALUES (${XSSATTY}, 'Zz', 'ZZXSSATTY', 1)" >/dev/null
	xss_bump_counter pb_attorneys "$XSSATTY"

	XSSCASE="$(xss_next_id cases case_id)"
	adb "INSERT INTO cases (case_id, number, user_id, office, status, intake_user_id, judge_name, pba_id1)
		VALUES (${XSSCASE}, '${XSSPAY}', 1, 'ZZO', '1', 1, 'ZZXSS', ${XSSATTY})" >/dev/null
	xss_bump_counter cases "$XSSCASE"

	XSSNUM="$(adb "SELECT number FROM cases WHERE case_id = ${XSSCASE}")"
	if [ "$XSSNUM" = "$XSSPAY" ]; then
		ok "the case fixture kept the whole payload in cases.number"
	else
		bad "cases.number truncated the payload to '${XSSNUM}' - the case checks below prove nothing"
	fi

	# --- 45a. cms/case_list.php ---------------------------------------------
	curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" "$OCM_URL/case_list.php" >/dev/null
	if grep -qF "case_id=${XSSCASE}" "$BODY"; then
		if grep -qF "$XSSPAY" "$BODY"; then
			bad "case_list.php renders a case number as live markup"
		else
			ok "case_list.php escapes a case number that holds markup"
		fi
		if grep -qF '%%[' "$BODY"; then
			bad "case_list.php left an unresolved %%[ template tag - the escape broke the render"
		else
			ok "case_list.php still resolves every template tag"
		fi
	else
		bad "the fixture case is not on case_list.php - 45a proves nothing"
	fi

	# --- 45b. cms/pb_attorneys.php ------------------------------------------
	curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" \
		"$OCM_URL/pb_attorneys.php?screen=edit_pb&pba_id=${XSSATTY}" >/dev/null
	if grep -qF "&lt;svg onload=alert(1)&gt;" "$BODY"; then
		ok "pb_attorneys.php escapes a case number that holds markup"
	else
		bad "pb_attorneys.php does not show the escaped fixture case - 45b proves nothing"
	fi
	if grep -qF "$XSSPAY" "$BODY"; then
		bad "pb_attorneys.php renders a case number as live markup"
	else
		ok "pb_attorneys.php has no live markup from the case number"
	fi
	# The link_target cell is assembled markup and has to survive the escape:
	# it moved below the pl_clean_html_array() call for exactly this reason.
	if grep -qF '%%[' "$BODY"; then
		bad "pb_attorneys.php left an unresolved %%[ template tag"
	else
		ok "pb_attorneys.php still resolves every template tag"
	fi

	# --- 45c. cms/merge_contacts.php ----------------------------------------
	# metaphoneContactCheck() selects from aliases and requires BOTH mp_last
	# and mp_first to match exactly - no wildcards - so the two fixture
	# aliases have to carry the same pair of metaphone codes or the page
	# renders "No records" and the check passes on an empty table.
	XSSC1="$(xss_next_id contacts contact_id)"
	adb "INSERT INTO contacts (contact_id, first_name, last_name, mp_first, mp_last, address, city, state, zip, area_code, phone)
		VALUES (${XSSC1}, 'Ada', 'ZZXSSDUPE', 'AT', 'SKSSTP', '${XSSPAY}', '<b>Zc</b>', 'NE', '68101', '402', '5550101')" >/dev/null
	xss_bump_counter contacts "$XSSC1"
	XSSC2="$(xss_next_id contacts contact_id)"
	adb "INSERT INTO contacts (contact_id, first_name, last_name, mp_first, mp_last, state)
		VALUES (${XSSC2}, 'Ada', 'ZZXSSDUPE', 'AT', 'SKSSTP', 'NE')" >/dev/null
	xss_bump_counter contacts "$XSSC2"

	XSSA1="$(xss_next_id aliases alias_id)"
	adb "INSERT INTO aliases (alias_id, contact_id, primary_name, first_name, last_name, mp_first, mp_last)
		VALUES (${XSSA1}, ${XSSC1}, 1, 'Ada', 'ZZXSSDUPE', 'AT', 'SKSSTP')" >/dev/null
	xss_bump_counter aliases "$XSSA1"
	XSSA2="$(xss_next_id aliases alias_id)"
	adb "INSERT INTO aliases (alias_id, contact_id, primary_name, first_name, last_name, mp_first, mp_last)
		VALUES (${XSSA2}, ${XSSC2}, 1, 'Ada', 'ZZXSSDUPE', 'AT', 'SKSSTP')" >/dev/null
	xss_bump_counter aliases "$XSSA2"

	curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" \
		"$OCM_URL/merge_contacts.php?contact_id=${XSSC2}" >/dev/null
	if grep -qF 'ZZXSSDUPE' "$BODY" && grep -qF 'merge_these[]' "$BODY"; then
		if grep -qF "$XSSPAY" "$BODY" || grep -qF '<b>Zc</b>' "$BODY"; then
			bad "merge_contacts.php renders a contact address as live markup"
		else
			ok "merge_contacts.php escapes a contact address that holds markup"
		fi
		# text_address in output=html mode interleaves <br/> between the
		# address lines. Escaping the finished string instead of its parts
		# would show that as a literal &lt;br/&gt;, so check the break is
		# still a break.
		if grep -qF '&lt;br/&gt;' "$BODY"; then
			bad "merge_contacts.php escaped the address line breaks - the whole string was escaped, not its parts"
		else
			ok "merge_contacts.php keeps the address line breaks as markup"
		fi
	else
		bad "the duplicate fixture is not on merge_contacts.php - 45c proves nothing"
	fi

	# --- 45d. cms/system-red_flags.php ---------------------------------------
	XSSFLAG="$(xss_next_id flags flag_id)"
	adb "INSERT INTO flags (flag_id, name, description, rules, enabled)
		VALUES (${XSSFLAG}, 'zzxssflag', '${XSSPAY}', '', 0)" >/dev/null
	xss_bump_counter flags "$XSSFLAG"

	curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" "$OCM_URL/system-red_flags.php" >/dev/null
	if grep -qF 'zzxssflag' "$BODY"; then
		if grep -qF "$XSSPAY" "$BODY"; then
			bad "system-red_flags.php renders a flag description as live markup"
		else
			ok "system-red_flags.php escapes a flag description that holds markup"
		fi
	else
		bad "the fixture flag is not on system-red_flags.php - 45d proves nothing"
	fi

	# --- 45e. htmlContactList(), reflected ----------------------------------
	# One page per caller of htmlContactList(): the address book, the intake
	# search and the case contact search. Every filter field is rendered into
	# a quoted attribute by all three subtemplates.
	for xss_page in "addressbook.php?first_name=${XSSREFQ}" \
		"intake2.php?last_name=${XSSREFQ}" \
		"case_contact.php?case_id=${XSSCASE}&last_name=${XSSREFQ}"; do
		curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" "$OCM_URL/$xss_page" >/dev/null
		if grep -qF "$XSSREF" "$BODY"; then
			bad "${xss_page%%\?*} lets a search value close its value= attribute"
		else
			ok "${xss_page%%\?*} escapes a quote in a search value"
		fi
	done

	# The escape is quotes only, on purpose. pl_clean_form_input() has already
	# written < and > as entities and leaves a bare & alone, so running the
	# value through htmlspecialchars() as well would turn &lt; into &amp;lt;
	# and show a user who typed a<b & c their own text back double encoded.
	curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" \
		"$OCM_URL/addressbook.php?first_name=a%3Cb%20%26%20c" >/dev/null
	if grep -qF 'value="a&lt;b &amp; c"' "$BODY"; then
		bad "addressbook.php double encodes a search value that holds & and <"
	elif grep -qF 'value="a&lt;b & c"' "$BODY"; then
		ok "addressbook.php echoes a search value without double encoding it"
	else
		bad "addressbook.php did not echo the search value back at all"
	fi

	# And an apostrophe still searches, rather than searching for &#039;.
	curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" \
		"$OCM_URL/addressbook.php?last_name=O%27Brian" >/dev/null
	if grep -qF "value=\"O&#039;Brian\"" "$BODY"; then
		ok "addressbook.php escapes an apostrophe in the rendered search box"
	else
		bad "addressbook.php does not escape an apostrophe in the search box"
	fi

	cleanup_xss
	trap 'rm -f "$COOKIES" "$BODY"' EXIT
else
	printf '  skip the XSS checks (needs the database)\n'
fi

echo
echo "47. document downloads cannot be rendered as active content"

# A case document is served back to the reader by cms/documents.php, and the
# Content-Type it is served with used to be whatever the uploading client
# claimed in the multipart part. Upload a file declaring text/html and the
# download came back as text/html with "Content-Disposition: inline", so the
# file ran as a page on this application's own origin, in the session of
# whoever opened it. Uploading a case document is a routine right; reading one
# is done by supervisors and administrators.
#
# Behavioural throughout: every check drives the real upload handler and the
# real download handler and reads the response headers off the wire. Nothing
# here greps a source file.
if [ "$HAVE_DB" = 1 ] && [ "$HAVE_COMPOSE" = 1 ]; then
	MDCASE=""
	MDDOCS=""
	
	cleanup_md() {
		if [ -n "${MDCASE:-}" ]; then
			adb "DELETE FROM doc_storage WHERE case_id = ${MDCASE}" >/dev/null
			adb "DELETE FROM cases WHERE case_id = ${MDCASE}" >/dev/null
		fi
		rm -f "${SMOKE_DIR}/zzmd.html" "${SMOKE_DIR}/zzmd.svg" \
			"${SMOKE_DIR}/zzmd.pdf" "${SMOKE_DIR}/zzmd1.txt" "${SMOKE_DIR}/zzmd2.txt" \
			"${BODY}.dl"
	}
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_md' EXIT
	
	# Ids come from the `counters` row as well as from MAX(), for the reason
	# spelled out in section 28: plBase::getNextID allocates from counters.
	md_next_id() {
		adb "SELECT GREATEST(
			COALESCE((SELECT MAX(${2}) FROM \`${1}\`), 0),
			COALESCE((SELECT count FROM counters WHERE id = '${1}'), 0)) + 1"
	}
	md_bump_counter() {
		adb "UPDATE counters SET count = GREATEST(count, ${2}) WHERE id = '${1}'" >/dev/null
	}
	
	MDCASE="$(md_next_id cases case_id)"
	adb "INSERT INTO cases (case_id, number, user_id, office, status, intake_user_id)
		VALUES (${MDCASE}, 'ZZ-MD-DOCS', 1, 'ZZM', '1', 1)" >/dev/null
	md_bump_counter cases "$MDCASE"
	
	# The upload form's token. ops/upload_document.php checks it on every POST.
	curl -sL --max-time 30 -b "$COOKIES" -c "$COOKIES" -o "$BODY" \
		"$OCM_URL/case.php?case_id=${MDCASE}&screen=docs" >/dev/null
	MDTOK="$(grep -oE 'name="_csrf" value="[0-9a-f]{64}"' "$BODY" | head -1 | sed -e 's/.*value="//' -e 's/"$//')"
	
	printf '<script>alert(1)</script>ZZMDMARKER\n' > "${SMOKE_DIR}/zzmd.html"
	printf '<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>\n' > "${SMOKE_DIR}/zzmd.svg"
	printf '%%PDF-1.4\n1 0 obj<</Type/Catalog>>endobj\ntrailer<</Root 1 0 R>>\n%%%%EOF\n' > "${SMOKE_DIR}/zzmd.pdf"
	printf 'ZZMDONE\n' > "${SMOKE_DIR}/zzmd1.txt"
	printf 'ZZMDTWO longer body so the two sizes differ\n' > "${SMOKE_DIR}/zzmd2.txt"
	
	md_upload() {
		# $1 local file, $2 declared MIME type
		curl -sL --max-time 60 -b "$COOKIES" -c "$COOKIES" -o "$BODY" \
			-F "_csrf=${MDTOK}" -F "case_id=${MDCASE}" -F "doc_type=C" \
			-F "description=ZZMD fixture" \
			-F "doc_upload=@${1};type=${2}" \
			"$OCM_URL/ops/upload_document.php" >/dev/null
	}
	
	md_stored_type() {
		adb "SELECT mime_type FROM doc_storage WHERE case_id = ${MDCASE} AND doc_name = '${1}'"
	}
	md_doc_id() {
		adb "SELECT doc_id FROM doc_storage WHERE case_id = ${MDCASE} AND doc_name = '${1}'"
	}
	
	if [ -z "${MDTOK:-}" ] || [ -z "${MDCASE:-}" ]; then
		bad "could not seed the document download fixtures"
	else
		md_upload "${SMOKE_DIR}/zzmd.html" "text/html"
		md_upload "${SMOKE_DIR}/zzmd.svg" "image/svg+xml"
		md_upload "${SMOKE_DIR}/zzmd.pdf" "application/pdf"
		
		MDHTML="$(md_doc_id zzmd.html)"
		MDSVG="$(md_doc_id zzmd.svg)"
		MDPDF="$(md_doc_id zzmd.pdf)"
		
		if [ -n "$MDHTML" ] && [ -n "$MDSVG" ] && [ -n "$MDPDF" ]; then
			ok "the three fixture documents uploaded"
		else
			bad "the fixture documents did not upload - the rest of this section proves nothing"
		fi
		
		# --- what the upload stores -------------------------------------
		
		# image/svg+xml is not on pikaDocument::allowedMimeTypes(). An SVG is
		# a script host, and a stored type this application does not file
		# should not survive into a response header.
		if [ "$(md_stored_type zzmd.svg)" = "application/octet-stream" ]; then
			ok "an SVG upload is stored as application/octet-stream, not as its declared type"
		else
			bad "an SVG upload kept its declared type: $(md_stored_type zzmd.svg)"
		fi
		
		# A type that IS on the allowlist is kept, so the document list and
		# any later export still say what the file is.
		if [ "$(md_stored_type zzmd.pdf)" = "application/pdf" ]; then
			ok "a PDF upload keeps application/pdf"
		else
			bad "a PDF upload lost its type: $(md_stored_type zzmd.pdf)"
		fi
		
		# --- what the download sends ------------------------------------
		
		# The one that matters. text/html is an allowed thing to file, so it
		# is still stored as text/html; the download is where it is refused.
		curl -s --max-time 30 -b "$COOKIES" -c "$COOKIES" -D "$BODY" -o "${BODY}.dl" \
			"$OCM_URL/documents.php?action=download&doc_id=${MDHTML}" >/dev/null
		if grep -qiE '^content-type:[[:space:]]*application/octet-stream' "$BODY"; then
			ok "a document uploaded as HTML is served as application/octet-stream"
		else
			bad "a document uploaded as HTML is still served as HTML: $(grep -i '^content-type:' "$BODY" | tr -d '\r')"
		fi
		
		if grep -qiE '^content-disposition:[[:space:]]*attachment' "$BODY"; then
			ok "a document uploaded as HTML is served as an attachment, not inline"
		else
			bad "a document uploaded as HTML is still served inline - it renders on this origin"
		fi
		
		if grep -qiE '^x-content-type-options:[[:space:]]*nosniff' "$BODY"; then
			ok "the download carries X-Content-Type-Options: nosniff"
		else
			bad "the download has no nosniff header - the browser may sniff the body as HTML anyway"
		fi
		
		# Refusing to render it must not mean refusing to hand it over.
		if grep -qF 'ZZMDMARKER' "${BODY}.dl"; then
			ok "the document body is still delivered intact"
		else
			bad "the document body was altered or lost by the download headers"
		fi
		
		# A PDF still previews in the browser. This is the line the fix is not
		# allowed to cross: forcing every download to an attachment would
		# close the hole and break the way staff read court papers.
		curl -s --max-time 30 -b "$COOKIES" -c "$COOKIES" -D "$BODY" -o /dev/null \
			"$OCM_URL/documents.php?action=download&doc_id=${MDPDF}" >/dev/null
		if grep -qiE '^content-type:[[:space:]]*application/pdf' "$BODY" \
			&& grep -qiE '^content-disposition:[[:space:]]*inline' "$BODY"; then
			ok "a PDF is still served inline as application/pdf"
		else
			bad "a PDF is no longer previewable - the download gate is too tight"
		fi
		
		# The SVG follows its stored type into the attachment branch.
		curl -s --max-time 30 -b "$COOKIES" -c "$COOKIES" -D "$BODY" -o /dev/null \
			"$OCM_URL/documents.php?action=download&doc_id=${MDSVG}" >/dev/null
		if grep -qiE '^content-disposition:[[:space:]]*attachment' "$BODY"; then
			ok "an SVG is served as an attachment"
		else
			bad "an SVG is served inline - it can script on this origin"
		fi
		
		# --- header injection through the file name ---------------------
		
		# The uploader names the file. A name carrying a carriage return ends
		# the header block, and everything after it is a header the uploader
		# wrote into another user's download. curl will not send such a name
		# in a multipart part, so this row is written straight to the table.
		adb "UPDATE doc_storage SET doc_name = 'zzmd.html\r\nZZMD-Injected: yes'
			WHERE doc_id = ${MDHTML}" >/dev/null
		curl -s --max-time 30 -b "$COOKIES" -c "$COOKIES" -D "$BODY" -o /dev/null \
			"$OCM_URL/documents.php?action=download&doc_id=${MDHTML}" >/dev/null
		if grep -qi '^ZZMD-Injected:' "$BODY"; then
			bad "a document file name can write a header into the download response"
		else
			ok "a line break in a document file name does not split the response headers"
		fi
		adb "UPDATE doc_storage SET doc_name = 'zzmd.html' WHERE doc_id = ${MDHTML}" >/dev/null
		
		# --- the multi-file upload path ---------------------------------
		
		# Uploading several files at once rebuilt the $_FILES entry by hand
		# and left 'size' out of it, so every document that came in through
		# the multi-file form was stored with an empty size while the same
		# file uploaded on its own got the right one.
		curl -sL --max-time 60 -b "$COOKIES" -c "$COOKIES" -o "$BODY" \
			-F "_csrf=${MDTOK}" -F "case_id=${MDCASE}" -F "doc_type=C" \
			-F "description=ZZMD multi" \
			-F "doc_upload[]=@${SMOKE_DIR}/zzmd1.txt;type=text/plain" \
			-F "doc_upload[]=@${SMOKE_DIR}/zzmd2.txt;type=text/plain" \
			"$OCM_URL/ops/upload_document.php" >/dev/null
		MDSIZES="$(adb "SELECT COUNT(*) FROM doc_storage
			WHERE case_id = ${MDCASE} AND doc_name IN ('zzmd1.txt','zzmd2.txt') AND doc_size > 0")"
		if [ "$MDSIZES" = "2" ]; then
			ok "a multi-file upload records the size of each document"
		else
			bad "a multi-file upload stored ${MDSIZES}/2 documents with a size"
		fi
	fi
	
	cleanup_md
	trap 'rm -f "$COOKIES" "$BODY"' EXIT
else
	printf '  skip the document download checks (needs the database and compose)\n'
fi

echo
echo "49. the output encoding helpers in pl.php"

# Every menu, every address block and every widget rendered by a %%[tag]%%
# wrote database text straight into markup. pl_html_menu() interpolated the
# option keys, the option labels and the field name into a <select> unescaped;
# pl_html_address() interpolated the six address components; pl_template_sub()
# escaped nothing in its radio, vradio, option and text modes; and
# pl_clean_html_array(), which is what plFlexList::addRow() runs, encoded its
# values differently from pl_clean_html(), so the same stored bracket read
# correctly on a detail screen and as a literal "&lt;" in the list beside it.
#
# The fixtures below put hostile text where each of those helpers reads from:
# a funding menu label, an office menu label, a case-status menu *value*, a
# staff surname, a contact's address components, a gender menu label, and a
# case number holding the "&lt;" that pl_clean_form_input() writes on input.
if [ "$HAVE_DB" = 1 ]; then
	OE_BODY="${BODY}.oe"
	
	cleanup_oe() {
		adb "DELETE FROM conflict WHERE contact_id IN (SELECT contact_id FROM contacts WHERE last_name = 'ZZ49CONTACT')" >/dev/null
		adb "DELETE FROM contacts WHERE last_name = 'ZZ49CONTACT'" >/dev/null
		adb "DELETE FROM cases WHERE number = 'ZZ49&lt;A'" >/dev/null
		adb "DELETE FROM users WHERE username = 'zz49user'" >/dev/null
		adb "DELETE FROM menu_funding WHERE value = 'Z9'" >/dev/null
		adb "DELETE FROM menu_office WHERE value = 'Z8'" >/dev/null
		adb "DELETE FROM menu_case_status WHERE label = 'ZZ49quotevalue'" >/dev/null
		adb "DELETE FROM menu_gender WHERE value = 'Z'" >/dev/null
		rm -f "$OE_BODY"
	}
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_oe' EXIT
	cleanup_oe
	
	oe_next_id() {
		adb "SELECT GREATEST(
			COALESCE((SELECT MAX(${2}) FROM \`${1}\`), 0),
			COALESCE((SELECT count FROM counters WHERE id = '${1}'), 0)) + 1"
	}
	oe_bump_counter() {
		adb "UPDATE counters SET count = GREATEST(count, ${2}) WHERE id = '${1}'" >/dev/null
	}
	
	# A label carrying a tag, a label that is already an entity on purpose, and
	# a menu *value* holding the quote that would end the value="" attribute.
	adb "INSERT INTO menu_funding (value, label, menu_order)
		VALUES ('Z9', 'ZZ49<img src=x onerror=alert(1)>', 99)" >/dev/null
	adb "INSERT INTO menu_office (value, label, menu_order)
		VALUES ('Z8', 'ZZ49&gt;preencoded', 99)" >/dev/null
	adb "INSERT INTO menu_case_status (value, label, menu_order)
		VALUES ('\"', 'ZZ49quotevalue', 99)" >/dev/null
	adb "INSERT INTO menu_gender (value, label, menu_order)
		VALUES ('Z', 'ZZ49<b>genderlabel</b>', 99)" >/dev/null
	
	# pikaMisc::fetchStaffArray() builds the staff menu labels out of the name
	# columns, so a surname is a menu label too. Login disabled: this row only
	# has to appear in the menu.
	OEUID="$(oe_next_id users user_id)"
	adb "INSERT INTO users (user_id, username, password, enabled, group_id, last_name, first_name, password_expire)
		VALUES (${OEUID}, 'zz49user', 'x', 0, 'system', 'ZZ49\"><svg onload=alert(2)>', 'T', 0)" >/dev/null
	oe_bump_counter users "$OEUID"
	
	OECON="$(oe_next_id contacts contact_id)"
	adb "INSERT INTO contacts (contact_id, first_name, last_name, org, address, address2, city, state, zip, gender)
		VALUES (${OECON}, 'Zz', 'ZZ49CONTACT', 'ZZ49ORG\"><i>', 'ZZ49ADDR\"><img src=y>', 'ZZ49A2', 'ZZ49CITY<u>', 'ZZ49ST', '12345', 'Z')" >/dev/null
	oe_bump_counter contacts "$OECON"
	
	# The case number holds a literal "&lt;", which is what a submitted "<"
	# becomes: pl_clean_form_input() converts it on the way in. Whether the
	# list shows "&lt;" or "&amp;lt;" is the pl_clean_html_array() question.
	OECASE="$(oe_next_id cases case_id)"
	adb "INSERT INTO cases (case_id, number, user_id, office, status, intake_user_id)
		VALUES (${OECASE}, 'ZZ49&lt;A', 1, 'ZZO', '1', 1)" >/dev/null
	oe_bump_counter cases "$OECASE"
	
	OECF="$(oe_next_id conflict conflict_id)"
	adb "INSERT INTO conflict (conflict_id, contact_id, case_id, relation_code)
		VALUES (${OECF}, ${OECON}, ${OECASE}, 1)" >/dev/null
	oe_bump_counter conflict "$OECF"
	
	# 49a. pl_html_menu() - the advanced case list form draws four menus.
	curl -sL --max-time 30 -b "$COOKIES" -o "$OE_BODY" \
		"$OCM_URL/case_list.php?mode=advanced" >/dev/null
	
	if grep -qF -- 'onerror=alert(1)>' "$OE_BODY"; then
		bad "a funding menu label reaches the case list form as live markup"
	else
		ok "a funding menu label cannot put a tag in the case list form"
	fi
	
	if grep -qF -- 'ZZ49&lt;img src=x onerror=alert(1)&gt;' "$OE_BODY"; then
		ok "the funding menu label is still readable, escaped"
	else
		bad "the funding menu label is missing from the case list form"
	fi
	
	if grep -qF -- 'svg onload=alert(2)>' "$OE_BODY"; then
		bad "a staff surname reaches the case list form as live markup"
	else
		ok "a staff surname cannot put a tag in the case list form"
	fi
	
	if grep -qF -- 'ZZ49&quot;&gt;&lt;svg onload=alert(2)&gt;' "$OE_BODY"; then
		ok "the staff surname is still readable, escaped"
	else
		bad "the staff surname is missing from the case list form"
	fi
	
	# The menu key lands in value="", so a quote in it used to end the
	# attribute and let the rest of the key become attributes of its own.
	if grep -qF -- '<option value="&quot;">ZZ49quotevalue' "$OE_BODY"; then
		ok "a quote in a menu value is escaped inside the value attribute"
	else
		bad "a quote in a menu value is not escaped inside the value attribute"
	fi
	
	if grep -qE '<option value="""' "$OE_BODY"; then
		bad "a menu value with a quote breaks out of the value attribute"
	else
		ok "no option tag has a value attribute ended by its own contents"
	fi
	
	# The other half of the decision: a label is allowed to arrive already
	# encoded. menu_comparison_sql ships labels that are literally "&lt;" and
	# "&gt;", and an author who needs a comma in a label has to write "&#44;"
	# because the %%[tag]%% parser splits on commas. Escaping those again would
	# show the user "&amp;gt;". pl_html_escape_label() is what keeps them.
	if grep -qF -- 'ZZ49&gt;preencoded' "$OE_BODY" \
		&& ! grep -qF -- 'ZZ49&amp;gt;preencoded' "$OE_BODY"; then
		ok "a menu label that is already an entity is not encoded twice"
	else
		bad "a pre-encoded menu label is double-encoded and shows its own entity"
	fi
	
	# pl_template_sub()'s vradio mode wrote tabindex with no quotes around it
	# in the multiselect sibling; check the radio widget renders a quoted one.
	if grep -qF -- 'class="plradio" tabindex="1"' "$OE_BODY"; then
		ok "the radio widget writes a quoted tabindex attribute"
	else
		bad "the radio widget does not write a quoted tabindex attribute"
	fi
	
	# 49b. pl_html_address(), pl_template_sub() text mode, and the
	# pl_clean_html_array() path that plFlexList::addRow() runs.
	curl -sL --max-time 30 -b "$COOKIES" -o "$OE_BODY" \
		"$OCM_URL/contact_pop_up.php?contact_id=${OECON}" >/dev/null
	
	if grep -qF -- 'img src=y>' "$OE_BODY"; then
		bad "a contact address line reaches the page as live markup"
	else
		ok "a contact address line cannot put a tag on the page"
	fi
	
	if grep -qF -- 'ZZ49ADDR&quot;&gt;&lt;img src=y&gt;' "$OE_BODY"; then
		ok "the address line is still readable, escaped"
	else
		bad "the address line is missing from the contact screen"
	fi
	
	if grep -qF -- 'ZZ49CITY&lt;u&gt;, ZZ49ST 12345' "$OE_BODY"; then
		ok "the city, state and zip components are escaped individually"
	else
		bad "the city/state/zip line is not escaped as separate components"
	fi
	
	# The escaping goes on the components, not the finished string: this
	# function interleaves <br> tags with the data, so escaping the result
	# would print the tags instead of applying them.
	if grep -qF -- 'ZZ49ORG&quot;&gt;&lt;i&gt;<br>' "$OE_BODY"; then
		ok "the line breaks between address components are still tags"
	else
		bad "pl_html_address escaped its own <br> separators"
	fi
	
	if grep -qF -- '<b>genderlabel</b>' "$OE_BODY"; then
		bad "a menu label in text mode reaches the page as live markup"
	else
		ok "a menu label in text mode cannot put a tag on the page"
	fi
	
	if grep -qF -- 'ZZ49&lt;b&gt;genderlabel&lt;/b&gt;' "$OE_BODY"; then
		ok "the text-mode menu label is still readable, escaped"
	else
		bad "the text-mode menu label is missing from the contact screen"
	fi
	
	# plFlexList::addRow() runs pl_clean_html_array(). It used to skip the
	# step that turns a stored "&lt;" back into "<" before escaping, so the
	# list printed "&amp;lt;" where the detail screen printed "&lt;" -- the
	# same value, shown two ways on two screens.
	if grep -qF -- 'ZZ49&lt;A' "$OE_BODY" \
		&& ! grep -qF -- 'ZZ49&amp;lt;A' "$OE_BODY"; then
		ok "a list row encodes a stored bracket the same way a detail screen does"
	else
		bad "a list row double-encodes a stored bracket the detail screen shows once"
	fi
	
	# 49c. Two helpers no template reaches over HTTP. pl_js_escape() is new,
	# and pl_template_sub()'s option mode had "$x .- " where the append
	# operator belongs, which is a fatal TypeError on PHP 8 -- so any template
	# using that mode white-screened. Both are exercised in the container.
	if [ "$HAVE_COMPOSE" = 1 ]; then
		OE_PHP="$(docker compose "${COMPOSE_ARGS[@]}" exec -T \
			-w /var/www/html/cms app php -r '
			define("PL_DISABLE_SECURITY", true);
			require_once("pika-danio.php");
			pika_init();
			echo "JS:", (function_exists("pl_js_escape")
				? pl_js_escape("</script><a href=\"x\">&|") : "missing"), "\n";
			echo "OPT:[", pl_template_sub("%%[gender option]%%",
				array("gender" => "Z")), "]\n";
			' </dev/null 2>/dev/null)"
		
		# json_encode with the four HEX flags. None of < > & " or | survives as
		# itself, so the value cannot close the script element, cannot close a
		# quoted attribute and cannot end the JavaScript string it sits in.
		if printf '%s' "$OE_PHP" | grep -qF -- 'JS:"\u003C\/script\u003E'; then
			ok "pl_js_escape hex-encodes a closing script tag"
		else
			bad "pl_js_escape does not hex-encode a closing script tag: ${OE_PHP}"
		fi
		
		if printf '%s' "$OE_PHP" | grep -qE 'JS:.*\\u0022.*\\u0026'; then
			ok "pl_js_escape hex-encodes the quote and the ampersand"
		else
			bad "pl_js_escape leaves a quote or an ampersand as itself"
		fi
		
		if printf '%s' "$OE_PHP" | grep -qF -- 'OPT:[<option value="F">'; then
			ok "the option tag mode emits its options instead of throwing"
		else
			bad "the option tag mode emits nothing: ${OE_PHP}"
		fi
		
		if printf '%s' "$OE_PHP" | grep -qF -- '<option value="Z">ZZ49&lt;b&gt;genderlabel&lt;/b&gt;</option>'; then
			ok "the option tag mode escapes its key and its label"
		else
			bad "the option tag mode does not escape its label"
		fi
	else
		printf '  skip the pl_js_escape and option-mode checks (needs compose)\n'
	fi
	
	cleanup_oe
	trap 'rm -f "$COOKIES" "$BODY"' EXIT
else
	printf '  skip the output encoding checks (needs the database)\n'
fi

echo
echo "50. the iCalendar feeds escape their TEXT values"

# cms/services/calendar.php and cms/services/calendar-4.php each carried their
# own ical_text_mogrify(): it deleted CR and turned LF into a literal \n, and
# stopped there. RFC 5545 section 3.3.11 reserves backslash, semicolon and
# comma as well, and case notes are prose - most contain a comma, which a
# reader that parses the property as a value list truncates the note at.
# Worse, four of the values assembled into DESCRIPTION never went through
# mogrify at all: the three menu labels and the case number. A case number
# holding a line ending therefore closed the DESCRIPTION property and opened a
# forged one, which is calendar-feed injection, not just malformed output.
# Escaping now lives in cms/app/lib/plIcalText.php so the two feeds share one
# copy of the rule.
if [ "$HAVE_DB" = 1 ]; then
	IC_BODY="${BODY}.ical"

	cleanup_ic() {
		adb "DELETE FROM activities WHERE summary LIKE 'ZZ50%'" >/dev/null
		adb "DELETE FROM cases WHERE number LIKE 'ZZ50%'" >/dev/null
		adb "DELETE FROM menu_funding WHERE value = 'Z7'" >/dev/null
		rm -f "$IC_BODY"
	}
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_ic' EXIT
	cleanup_ic

	ic_next_id() {
		adb "SELECT GREATEST(
			COALESCE((SELECT MAX(${2}) FROM \`${1}\`), 0),
			COALESCE((SELECT count FROM counters WHERE id = '${1}'), 0)) + 1"
	}
	ic_bump_counter() {
		adb "UPDATE counters SET count = GREATEST(count, ${2}) WHERE id = '${1}'" >/dev/null
	}

	# A funding label with a comma in it. Menu labels are prose too, and this
	# one is written into DESCRIPTION through pl_array_lookup().
	adb "INSERT INTO menu_funding (value, label, menu_order)
		VALUES ('Z7', 'ZZ50,fundlabel', 97)" >/dev/null

	# The case number carries a CRLF followed by what looks like a calendar
	# property. On the unfixed feed this reaches the client as a real line
	# ending, so X-INJ:1 arrives as a property of the event.
	ICCASE="$(ic_next_id cases case_id)"
	adb "INSERT INTO cases (case_id, number, user_id, office, status, intake_user_id)
		VALUES (${ICCASE}, CONCAT('ZZ50,C', CHAR(13), CHAR(10), 'X-INJ:1'), 1, 'ZZO', '1', 1)" >/dev/null
	ic_bump_counter cases "$ICCASE"

	# act_type has to be C or K: cms/services/calendar.php only publishes
	# appointments and tickles. The summary and the notes between them cover
	# every character the escape set has to handle, including a lone CR, which
	# the old code deleted rather than folded.
	ICUID="$(adb "SELECT user_id FROM users WHERE username = '${OCM_USER}'")"
	ICAID="$(ic_next_id activities act_id)"
	adb "INSERT INTO activities
			(act_id, act_date, act_time, act_end_time, hours, completed,
			 act_type, funding, case_id, user_id, summary, notes, last_changed)
		VALUES (${ICAID}, CURDATE(), '09:00:00', '10:00:00', 1.0, 1,
			'C', 'Z7', ${ICCASE}, ${ICUID},
			CONCAT('ZZ50SUM,semi;back', CHAR(92), 'slash'),
			CONCAT('ZZ50NOTE,comma;semi C:', CHAR(92), 'temp',
				CHAR(13), 'CRLINE', CHAR(10), 'LFLINE'),
			NOW())" >/dev/null
	ic_bump_counter activities "$ICAID"

	# The feed authenticates over HTTP basic auth (PL_HTTP_SECURITY). debug=1
	# suppresses the attachment headers and nothing else.
	curl -s --max-time 30 -u "${OCM_USER}:${OCM_PASSWORD}" -o "$IC_BODY" \
		"$OCM_URL/services/calendar.php?debug=1" >/dev/null

	if grep -qa 'ZZ50SUM' "$IC_BODY"; then
		ok "the calendar feed publishes the test appointment"
	else
		bad "the calendar feed does not carry the test appointment - the rest of this section proves nothing"
	fi

	if grep -qaF -- 'SUMMARY:ZZ50SUM\,semi\;back\\slash' "$IC_BODY"; then
		ok "SUMMARY escapes comma, semicolon and backslash"
	else
		bad "SUMMARY does not escape comma, semicolon or backslash"
	fi

	if grep -qaF -- 'SUMMARY:ZZ50SUM,semi' "$IC_BODY"; then
		bad "SUMMARY still carries a raw comma"
	else
		ok "SUMMARY carries no raw comma"
	fi

	if grep -qaF -- 'ZZ50NOTE\,comma\;semi C:\\temp' "$IC_BODY"; then
		ok "the notes escape comma, semicolon and backslash in DESCRIPTION"
	else
		bad "the notes reach DESCRIPTION with reserved characters unescaped"
	fi

	# A lone CR used to be deleted, which joined the two lines into one word.
	if grep -qaF -- 'temp\nCRLINE\nLFLINE' "$IC_BODY"; then
		ok "a lone CR folds to an escaped newline"
	else
		bad "a lone CR is dropped instead of folded - two lines arrive as one word"
	fi

	if grep -qaF -- 'tempCRLINE' "$IC_BODY"; then
		bad "the CR was deleted and glued two lines together"
	else
		ok "no two lines were glued together"
	fi

	if grep -qaF -- 'Funding: ZZ50\,fundlabel' "$IC_BODY"; then
		ok "a menu label with a comma is escaped in DESCRIPTION"
	else
		bad "a menu label reaches DESCRIPTION with a raw comma"
	fi

	if grep -qaF -- 'Case: ZZ50\,C\nX-INJ:1' "$IC_BODY"; then
		ok "the case number is escaped, line ending and all"
	else
		bad "the case number is not escaped into the DESCRIPTION value"
	fi

	# The point of the previous check: on the unfixed feed the CRLF in the case
	# number ends the DESCRIPTION line, and X-INJ:1 becomes a property of the
	# event rather than part of a value.
	if grep -qa '^X-INJ:1' "$IC_BODY"; then
		bad "a case number forged a calendar property - the feed is injectable"
	else
		ok "no value forged a calendar property"
	fi

	# The values that must NOT be escaped: the timestamps and the link. An
	# escape here would break the property, not protect it.
	if grep -qaE '^DTSTART;TZID=[^:]+:[0-9]{8}T[0-9]{6}' "$IC_BODY"; then
		ok "DTSTART is still a plain iCalendar date-time"
	else
		bad "DTSTART is malformed"
	fi

	if grep -qa "act_id=${ICAID}" "$IC_BODY"; then
		ok "the activity link is still intact"
	else
		bad "the activity link was mangled"
	fi

	if [ "$HAVE_COMPOSE" = 1 ]; then
		# pl_ical_text_escape() by itself. The order of the replacements is the
		# part that is easy to get wrong: backslash has to be escaped before
		# the characters whose escapes introduce backslashes of their own, or
		# a comma comes out as \\, and the reader sees a literal backslash
		# followed by an unescaped comma.
		docker compose "${COMPOSE_ARGS[@]}" exec -T -w /var/www/html/cms app \
			php -r '
				require_once("app/lib/plIcalText.php");
				echo "A:[", pl_ical_text_escape("a" . chr(92) . ",b"), "]\n";
				echo "B:[", pl_ical_text_escape(null), "]\n";
				echo "C:[", pl_ical_text_escape("x\r\ny"), "]\n";
				echo "D:[", pl_ical_text_escape(42), "]\n";
			' </dev/null > "$IC_BODY" 2>/dev/null

		if grep -qaF -- 'A:[a\\\,b]' "$IC_BODY"; then
			ok "pl_ical_text_escape escapes the backslash before the comma"
		else
			bad "pl_ical_text_escape escapes in the wrong order - it double-escapes its own backslashes"
		fi

		if grep -qaF -- 'B:[]' "$IC_BODY"; then
			ok "pl_ical_text_escape turns null into an empty value"
		else
			bad "pl_ical_text_escape does not handle a null column"
		fi

		if grep -qaF -- 'C:[x\ny]' "$IC_BODY"; then
			ok "CRLF folds to one escaped newline, not two"
		else
			bad "CRLF folds to two escaped newlines"
		fi

		if grep -qaF -- 'D:[42]' "$IC_BODY"; then
			ok "pl_ical_text_escape accepts a non-string column"
		else
			bad "pl_ical_text_escape mangles a non-string column"
		fi
	fi

	cleanup_ic
	trap 'rm -f "$COOKIES" "$BODY"' EXIT
else
	printf '  skip the iCalendar escaping checks (needs the database)\n'
fi

echo
echo "51. the case screen authorizes before it loads and writes"

# cms/case.php read the primary client's contact record, and cached a
# computed client_age onto the case row, BEFORE it asked pika_authorize()
# about the case. It also answered a case_id with no row differently from a
# case_id the caller may not read, which tells an attacker which numbers are
# real cases. The delete confirmation screen opened for anyone who could read
# the case, though only the `system` group can carry the delete out. And
# `screen` was passed through pl_clean_file_name(), a blocklist, on its way
# into three include() calls.
if [ "$HAVE_DB" = 1 ]; then
	CSGROUP='zz_cs_grp'
	CSUSER='zz_cs_user'
	CSPASS='zz-cs-Passw0rd'
	CSJAR="$(mktemp)"
	CSB1="$(mktemp)"
	CSB2="$(mktemp)"

	cleanup_cs() {
		adb "DELETE FROM cases WHERE number IN ('ZZ-CS-SECRET', 'ZZ-CS-MINE')" >/dev/null
		adb "DELETE FROM contacts WHERE last_name = 'ZZCSCLIENT'" >/dev/null
		adb "DELETE FROM users WHERE username = '${CSUSER}'" >/dev/null
		adb "DELETE FROM \`groups\` WHERE group_id = '${CSGROUP}'" >/dev/null
		rm -f "$CSJAR" "$CSB1" "$CSB2"
	}
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_cs' EXIT
	cleanup_cs

	# read_all off, no read_office, intake off: this user may read the cases
	# it owns and nothing else.
	adb "INSERT INTO \`groups\` (group_id, read_office, read_all, edit_office, edit_all, users, pba, motd, intake, reports)
		VALUES ('${CSGROUP}', NULL, 0, NULL, 0, 0, 0, 0, 0, NULL)" >/dev/null

	CSHASH="$(docker compose "${COMPOSE_ARGS[@]}" exec -T app \
		php -r 'echo password_hash($argv[1], PASSWORD_DEFAULT);' "$CSPASS" </dev/null 2>/dev/null)"
	CSUID="$(adb "SELECT COALESCE(MAX(user_id), 0) + 1 FROM users")"
	adb "INSERT INTO users (user_id, username, password, enabled, group_id, password_expire)
		VALUES (${CSUID}, '${CSUSER}', '${CSHASH}', 1, '${CSGROUP}', 0)" >/dev/null

	# plBase::getNextID hands out primary keys from the `counters` row rather
	# than from the table, so a fixture has to sit above both and move the
	# counter up behind it.
	cs_next_id() {
		adb "SELECT GREATEST(
			COALESCE((SELECT MAX(${2}) FROM \`${1}\`), 0),
			COALESCE((SELECT count FROM counters WHERE id = '${1}'), 0)) + 1"
	}
	cs_bump_counter() {
		adb "UPDATE counters SET count = GREATEST(count, ${2}) WHERE id = '${1}'" >/dev/null
	}

	# The client whose age the case screen used to cache on the way past the
	# permission check. birth_date is what makes calcAge() return a number.
	CSCON="$(cs_next_id contacts contact_id)"
	adb "INSERT INTO contacts (contact_id, first_name, last_name, birth_date)
		VALUES (${CSCON}, 'Zz', 'ZZCSCLIENT', '1980-01-01')" >/dev/null
	cs_bump_counter contacts "$CSCON"

	# One case owned by admin with a primary client and no cached client_age,
	# and one owned by the throwaway user so the delete screen can be asked
	# for by someone who is allowed to read the case.
	CSCASE="$(cs_next_id cases case_id)"
	adb "INSERT INTO cases (case_id, number, user_id, office, status, client_id, open_date, client_age, unread_sms)
		VALUES (${CSCASE}, 'ZZ-CS-SECRET', 1, 'ZZA', '1', ${CSCON}, '2019-01-01', NULL, 3)" >/dev/null
	cs_bump_counter cases "$CSCASE"
	CSMINE="$(cs_next_id cases case_id)"
	adb "INSERT INTO cases (case_id, number, user_id, office, status, open_date)
		VALUES (${CSMINE}, 'ZZ-CS-MINE', ${CSUID}, 'ZZB', '1', '2019-01-01')" >/dev/null
	cs_bump_counter cases "$CSMINE"

	# A case_id no row uses, for the enumeration check.
	CSGONE="$(adb "SELECT COALESCE(MAX(case_id), 0) + 5000 FROM cases")"

	if [ -z "$CSHASH" ] || [ -z "${CSCASE:-}" ] || [ -z "${CSMINE:-}" ] || [ -z "${CSGONE:-}" ]; then
		bad "could not seed the case screen fixtures"
	else
		: > "$CSJAR"
		curl -sL --max-time 30 -c "$CSJAR" -b "$CSJAR" -o "$BODY" \
			-X POST -d "login_user=${CSUSER}&login_pass=${CSPASS}&auth_id=1" \
			"$OCM_URL/" >/dev/null
		if grep -q 'login_pass' "$BODY"; then
			bad "the throwaway case user could not log in - section 51 is untested"
		else
			ok "the throwaway case user can log in"

			# 51a. The case it does not own is refused.
			curl -sL --max-time 30 -b "$CSJAR" -o "$CSB1" \
				"$OCM_URL/case.php?case_id=${CSCASE}" >/dev/null
			if grep -q 'not viewable' "$CSB1"; then
				ok "a case outside the user's group is not viewable"
			else
				bad "A CASE OUTSIDE THE USER'S GROUP WAS SERVED BY case.php"
			fi

			# 51b. The case number is not on the refusal page. It used to be,
			# in the heading and the breadcrumb, both built before the check.
			if grep -q 'ZZ-CS-SECRET' "$CSB1"; then
				bad "THE REFUSAL PAGE CARRIES THE CASE NUMBER IT IS REFUSING"
			else
				ok "the refusal page does not name the case"
			fi

			# 51c. A case_id with no row answers exactly the same way. It used
			# to reach plBase::__construct(), which trigger_error()s "No such
			# record found." and gets the generic unavailable-page screen -
			# a different answer, so case_id could be walked for real cases.
			curl -sL --max-time 30 -b "$CSJAR" -o "$CSB2" \
				"$OCM_URL/case.php?case_id=${CSGONE}" >/dev/null
			if cmp -s "$CSB1" "$CSB2"; then
				ok "a case_id with no row is answered like one that is refused"
			else
				bad "A MISSING case_id IS DISTINGUISHABLE FROM A REFUSED ONE"
			fi

			# 51d. Nothing was written for either request. client_age was
			# computed and UPDATEd onto the case row before the permission
			# check, so an unauthorized request wrote to the case.
			if [ "$(adb "SELECT COUNT(*) FROM cases WHERE case_id = ${CSCASE} AND client_age IS NULL")" = 1 ]; then
				ok "a refused request does not cache client_age on the case"
			else
				bad "A REFUSED REQUEST WROTE client_age ONTO THE CASE ROW"
			fi

			# 51e. The delete confirmation screen asks for the permission the
			# delete itself asks for, which in this application is the
			# `system` group. This user owns the case and can read it.
			curl -sL --max-time 30 -b "$CSJAR" -o "$BODY" \
				"$OCM_URL/case.php?case_id=${CSMINE}&screen=confirm_delete" >/dev/null
			if grep -q 'not authorized to delete' "$BODY"; then
				ok "the delete confirmation screen is refused without delete_case"
			else
				bad "THE DELETE CONFIRMATION SCREEN OPENED WITHOUT delete_case"
			fi
		fi

		# The rest runs as the administrator, who can read the case.
		curl -sL --max-time 30 -b "$COOKIES" -o "$CSB1" \
			"$OCM_URL/case.php?case_id=${CSCASE}" >/dev/null
		if grep -q 'ZZ-CS-SECRET' "$CSB1"; then
			ok "the case screen still renders for a user who may read it"
		else
			bad "THE CASE SCREEN NO LONGER RENDERS FOR AN AUTHORIZED USER"
		fi

		# 51f. The positive control for 51d: the same page, requested by
		# someone who may read it, does cache the age. Without this, 51d
		# would pass on a case screen that had stopped working.
		if [ "$(adb "SELECT COUNT(*) FROM cases WHERE case_id = ${CSCASE} AND client_age > 0")" = 1 ]; then
			ok "an authorized request still caches client_age"
		else
			bad "the client_age write is gone - 51d proves nothing"
		fi

		# 51g. screen= reaches three include() calls. Anything outside
		# [A-Za-z0-9_-] falls back to the default tab, and the page is the
		# page the default tab draws.
		#
		# Two things on this page are deliberately different on every render
		# and are not part of what the page drew: the date-picker's element
		# id, and the Content-Security-Policy nonce on each script block.
		# Both are normalised before the comparison, or every request differs
		# from every other and the check can never pass.
		cs_normalise() {
			sed -E 's/date_selector-[0-9]+/date_selector-ID/g; s/nonce="[^"]*"/nonce="NONCE"/g' "$1"
		}

		curl -sL --max-time 30 -b "$COOKIES" -o "$CSB2" \
			"$OCM_URL/case.php?case_id=${CSCASE}&screen=../../etc/passwd" >/dev/null
		if cs_normalise "$CSB1" | cmp -s - <(cs_normalise "$CSB2"); then
			ok "a traversal in screen= falls back to the default tab"
		else
			bad "screen=../../etc/passwd CHANGED WHAT case.php DREW"
		fi

		curl -sL --max-time 30 -b "$COOKIES" -o "$CSB2" \
			"$OCM_URL/case.php?case_id=${CSCASE}&screen=act%00.php" >/dev/null
		if cs_normalise "$CSB1" | cmp -s - <(cs_normalise "$CSB2"); then
			ok "a null byte in screen= falls back to the default tab"
		else
			bad "A NULL BYTE IN screen= CHANGED WHAT case.php DREW"
		fi

		if grep -qF -- 'root:' "$CSB2"; then
			bad "case.php INCLUDED A FILE FROM OUTSIDE THE APPLICATION"
		else
			ok "case.php did not include a file from outside the application"
		fi

		# 51h. case_id used is_numeric(), which accepts '1e3' and '12.0', and
		# passed both on to SQL. They now redirect to the calendar, the same
		# answer a missing case_id gets. A negative id does too.
		for CSBAD in '1e3' '12.0' '408abc' '-408'; do
			CSCODE="$(curl -s --max-time 30 -b "$COOKIES" -o /dev/null \
				-w '%{http_code}' "$OCM_URL/case.php?case_id=${CSBAD}")"
			if [ "$CSCODE" = 302 ]; then
				ok "case_id=${CSBAD} is refused as a non-integer"
			else
				bad "case_id=${CSBAD} WAS ACCEPTED BY case.php (HTTP ${CSCODE})"
			fi
		done

		# 51i. The unread-SMS link was written "{$base_url}\case.php", with a
		# literal backslash, so the link did not work.
		if grep -qF -- '\case.php' "$CSB1"; then
			bad "THE SMS REMINDER LINK STILL HAS A LITERAL BACKSLASH"
		else
			ok "the SMS reminder link has no literal backslash"
		fi

		if grep -qF -- 'screen=sms' "$CSB1"; then
			ok "the unread-SMS notice links to the SMS tab"
		else
			bad "the unread-SMS notice is missing - 51i proves nothing"
		fi
	fi

	cleanup_cs
	trap 'rm -f "$COOKIES" "$BODY"' EXIT
else
	printf '  skip the case screen checks (needs the database)\n'
fi

echo
echo "52. contact aliases are authorized"

# cms/alias.php had no permission check. Any authenticated user could add,
# rewrite or delete an alias on any contact_id, and nothing tied the alias_id
# in the request to the contact_id beside it, so one contact's alias could be
# re-pointed or deleted from another contact's page. The alias tables are what
# the conflict check searches.
if [ "$HAVE_DB" = 1 ]; then
	ALGROUP='zz_al_grp'
	ALUSER='zz_al_user'
	ALPASS='zz-al-Passw0rd'
	ALJAR="$(mktemp)"

	cleanup_al() {
		adb "DELETE FROM aliases WHERE last_name LIKE 'ZZAL%'" >/dev/null
		adb "DELETE FROM conflict WHERE contact_id IN (SELECT contact_id FROM contacts WHERE last_name LIKE 'ZZAL%')" >/dev/null
		adb "DELETE FROM cases WHERE number = 'ZZ-AL-CASE'" >/dev/null
		adb "DELETE FROM contacts WHERE last_name LIKE 'ZZAL%'" >/dev/null
		adb "DELETE FROM users WHERE username = '${ALUSER}'" >/dev/null
		adb "DELETE FROM \`groups\` WHERE group_id = '${ALGROUP}'" >/dev/null
		rm -f "$ALJAR"
	}
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_al' EXIT
	cleanup_al

	# edit_all off and no offices: this user may edit the cases it owns, and
	# so the contacts on those cases, and nothing else.
	adb "INSERT INTO \`groups\` (group_id, read_office, read_all, edit_office, edit_all, users, pba, motd, intake, reports)
		VALUES ('${ALGROUP}', NULL, 0, NULL, 0, 0, 0, 0, 0, NULL)" >/dev/null

	ALHASH="$(docker compose "${COMPOSE_ARGS[@]}" exec -T app \
		php -r 'echo password_hash($argv[1], PASSWORD_DEFAULT);' "$ALPASS" </dev/null 2>/dev/null)"
	ALUID="$(adb "SELECT COALESCE(MAX(user_id), 0) + 1 FROM users")"
	adb "INSERT INTO users (user_id, username, password, enabled, group_id, password_expire)
		VALUES (${ALUID}, '${ALUSER}', '${ALHASH}', 1, '${ALGROUP}', 0)" >/dev/null

	al_next_id() {
		adb "SELECT GREATEST(
			COALESCE((SELECT MAX(${2}) FROM \`${1}\`), 0),
			COALESCE((SELECT count FROM counters WHERE id = '${1}'), 0)) + 1"
	}
	al_bump_counter() {
		adb "UPDATE counters SET count = GREATEST(count, ${2}) WHERE id = '${1}'" >/dev/null
	}

	# Two contacts, each the primary client on a case owned by admin. A
	# contact on no case at all is editable by anyone who can create one, so
	# the case is what makes edit_contact answer no for the throwaway user.
	ALCON1="$(al_next_id contacts contact_id)"
	adb "INSERT INTO contacts (contact_id, first_name, last_name)
		VALUES (${ALCON1}, 'Zz', 'ZZALTARGET')" >/dev/null
	al_bump_counter contacts "$ALCON1"
	ALCON2="$(al_next_id contacts contact_id)"
	adb "INSERT INTO contacts (contact_id, first_name, last_name)
		VALUES (${ALCON2}, 'Zz', 'ZZALOTHER')" >/dev/null
	al_bump_counter contacts "$ALCON2"

	ALCASE="$(al_next_id cases case_id)"
	adb "INSERT INTO cases (case_id, number, user_id, office, status, client_id, open_date)
		VALUES (${ALCASE}, 'ZZ-AL-CASE', 1, 'ZZA', '1', ${ALCON1}, '2019-01-01')" >/dev/null
	al_bump_counter cases "$ALCASE"
	adb "INSERT INTO conflict (conflict_id, case_id, contact_id, relation_code)
		VALUES ($(al_next_id conflict conflict_id), ${ALCASE}, ${ALCON2}, 7)" >/dev/null

	# One alias on each contact.
	ALIAS1="$(al_next_id aliases alias_id)"
	adb "INSERT INTO aliases (alias_id, contact_id, primary_name, first_name, last_name)
		VALUES (${ALIAS1}, ${ALCON1}, 0, 'Zz', 'ZZALONE')" >/dev/null
	al_bump_counter aliases "$ALIAS1"
	ALIAS2="$(al_next_id aliases alias_id)"
	adb "INSERT INTO aliases (alias_id, contact_id, primary_name, first_name, last_name)
		VALUES (${ALIAS2}, ${ALCON2}, 0, 'Zz', 'ZZALTWO')" >/dev/null
	al_bump_counter aliases "$ALIAS2"

	if [ -z "$ALHASH" ] || [ -z "${ALCON1:-}" ] || [ -z "${ALIAS1:-}" ] || [ -z "${ALIAS2:-}" ]; then
		bad "could not seed the alias fixtures"
	else
		: > "$ALJAR"
		curl -sL --max-time 30 -c "$ALJAR" -b "$ALJAR" -o "$BODY" \
			-X POST -d "login_user=${ALUSER}&login_pass=${ALPASS}&auth_id=1" \
			"$OCM_URL/" >/dev/null
		if grep -q 'login_pass' "$BODY"; then
			bad "the throwaway alias user could not log in - section 52 is untested"
		else
			ok "the throwaway alias user can log in"

			# 52a. The edit form.
			curl -sL --max-time 30 -b "$ALJAR" -o "$BODY" \
				"$OCM_URL/alias.php?action=edit&contact_id=${ALCON1}" >/dev/null
			if grep -q 'not authorized to edit this contact' "$BODY"; then
				ok "the alias edit form is refused without edit_contact"
			else
				bad "THE ALIAS EDIT FORM OPENED WITHOUT edit_contact"
			fi

			# 52b. The write.
			curl -sL --max-time 30 -b "$ALJAR" -o "$BODY" \
				"$OCM_URL/alias.php?action=update&contact_id=${ALCON1}&first_name=Zz&last_name=ZZALNEW" >/dev/null
			if [ "$(adb "SELECT COUNT(*) FROM aliases WHERE last_name = 'ZZALNEW'")" = 0 ]; then
				ok "an alias cannot be added to a contact the user cannot edit"
			else
				bad "AN ALIAS WAS ADDED TO A CONTACT THE USER CANNOT EDIT"
			fi

			# 52c. The delete.
			curl -sL --max-time 30 -b "$ALJAR" -o "$BODY" \
				"$OCM_URL/alias.php?action=delete&contact_id=${ALCON1}&alias_id=${ALIAS1}" >/dev/null
			if [ "$(adb "SELECT COUNT(*) FROM aliases WHERE alias_id = ${ALIAS1}")" = 1 ]; then
				ok "an alias cannot be deleted from a contact the user cannot edit"
			else
				bad "AN ALIAS WAS DELETED FROM A CONTACT THE USER CANNOT EDIT"
			fi

			# 52d. Reading the list is not gated: pika_authorize() has no
			# read_contact case and the address book is readable instance-wide.
			curl -sL --max-time 30 -b "$ALJAR" -o "$BODY" \
				"$OCM_URL/alias.php?contact_id=${ALCON1}" >/dev/null
			if grep -q 'ZZALONE' "$BODY"; then
				ok "the alias list still renders for a user who can read contacts"
			else
				bad "THE ALIAS LIST NO LONGER RENDERS - 52a to 52c prove nothing"
			fi
		fi

		# The rest runs as the administrator, who is in the system group.
		# 52e. The positive control: the write path still works.
		curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" \
			"$OCM_URL/alias.php?action=update&contact_id=${ALCON1}&first_name=Zz&last_name=ZZALADMIN" >/dev/null
		if [ "$(adb "SELECT COUNT(*) FROM aliases WHERE last_name = 'ZZALADMIN' AND contact_id = ${ALCON1}")" = 1 ]; then
			ok "an authorized user still adds an alias"
		else
			bad "the alias write path is broken - 52b proves nothing"
		fi

		# 52f. alias_id and contact_id have to name the same row. This request
		# is the contact_id of one contact and the alias_id of another.
		curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" \
			"$OCM_URL/alias.php?action=delete&contact_id=${ALCON1}&alias_id=${ALIAS2}" >/dev/null
		if [ "$(adb "SELECT COUNT(*) FROM aliases WHERE alias_id = ${ALIAS2}")" = 1 ]; then
			ok "an alias belonging to another contact is not deleted"
		else
			bad "ANOTHER CONTACT'S ALIAS WAS DELETED THROUGH alias.php"
		fi

		if grep -q 'does not belong to this contact' "$BODY"; then
			ok "the mismatched alias_id is refused by name"
		else
			bad "the mismatched alias_id was not refused by name"
		fi

		# 52g. Re-pointing that alias by posting an update is refused too.
		curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" \
			"$OCM_URL/alias.php?action=update&contact_id=${ALCON1}&alias_id=${ALIAS2}&first_name=Zz&last_name=ZZALTWO" >/dev/null
		if [ "$(adb "SELECT COUNT(*) FROM aliases WHERE alias_id = ${ALIAS2} AND contact_id = ${ALCON2}")" = 1 ]; then
			ok "an alias cannot be re-pointed at another contact"
		else
			bad "AN ALIAS WAS RE-POINTED AT ANOTHER CONTACT"
		fi

		# 52h. The positive control for 52c and 52f: the delete still works
		# when the two ids agree and the user may edit the contact.
		curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" \
			"$OCM_URL/alias.php?action=delete&contact_id=${ALCON1}&alias_id=${ALIAS1}" >/dev/null
		if [ "$(adb "SELECT COUNT(*) FROM aliases WHERE alias_id = ${ALIAS1}")" = 0 ]; then
			ok "an authorized user still deletes an alias"
		else
			bad "the alias delete path is broken - 52c proves nothing"
		fi
	fi

	cleanup_al
	trap 'rm -f "$COOKIES" "$BODY"' EXIT
else
	printf '  skip the alias authorization checks (needs the database)\n'
fi

echo
echo "53. the case list filters"

# cms/case_list.php builds its filter array straight out of the query string and
# hands it to pikaMisc::getCases(). Four of the filters - supervisor, closer,
# unit and subunit - name columns that only some installations have, and a
# request that set one of them on an installation without the column produced
# SQL naming a column that is not there. The query threw, which this
# application answers with HTTP 500 and an empty body, so the whole case list
# stopped working for anyone who followed a link carrying the parameter.
# getCases() now asks the schema first.
#
# The same request also decides the type of every value that reaches the SQL
# builder. user_id and show_cases name integer columns and are now read in
# 'number' mode; office, status, funding and sp_problem are char columns
# holding letter codes and are deliberately not, because 'number' mode nulls a
# letter code and the filter would silently drop, listing every case instead of
# the ones asked for.
#
# Needs the database: the checks count rows in the rendered list, so they need
# two cases with known filter values.
if [ "$HAVE_DB" = 1 ]; then
	cleanup_cl() {
		adb "DELETE FROM cases WHERE number IN ('ZZ-CL-A', 'ZZ-CL-B')" >/dev/null
	}
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_cl' EXIT
	cleanup_cl

	# Ids come from the `counters` row as well as from MAX(). plBase::getNextID
	# hands out the next primary key from counters, not from the table, so a
	# fixture inserted at MAX()+1 alone can sit on an id the application is
	# about to allocate.
	cl_next_id() {
		adb "SELECT GREATEST(
			COALESCE((SELECT MAX(${2}) FROM \`${1}\`), 0),
			COALESCE((SELECT count FROM counters WHERE id = '${1}'), 0)) + 1"
	}

	cl_bump_counter() {
		adb "UPDATE counters SET count = GREATEST(count, ${2}) WHERE id = '${1}'" >/dev/null
	}

	# Two open cases owned by the admin user, differing in every char filter.
	# close_date stays NULL so both appear under the default list mode, which
	# asks getCases() for open cases only.
	CLCASEA="$(cl_next_id cases case_id)"
	CLCASEB="$((CLCASEA + 1))"
	adb "INSERT INTO cases (case_id, number, user_id, office, status, funding, sp_problem, open_date)
		VALUES (${CLCASEA}, 'ZZ-CL-A', 1, 'ZZA', 'A', 'ZZA', 'ZZA', CURDATE()),
			(${CLCASEB}, 'ZZ-CL-B', 1, 'ZZB', 'B', 'ZZB', 'ZZB', CURDATE())" >/dev/null
	cl_bump_counter cases "$CLCASEB"

	if [ -z "${CLCASEA:-}" ] || [ -z "$(adb "SELECT case_id FROM cases WHERE number = 'ZZ-CL-A'")" ]; then
		bad "could not seed the case list fixtures"
	else
		# GET the case list with a query string and report the status code.
		cl_get() {
			curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" -w '%{http_code}' \
				"$OCM_URL/case_list.php?$1"
		}

		# Each of the four optional columns used to end the request with a 500
		# and an empty body.
		for cl_col in supervisor closer unit subunit; do
			code="$(cl_get "${cl_col}=1")"
			if [ "$code" = 200 ]; then
				ok "case_list.php?${cl_col}=1 answers 200"
			else
				bad "case_list.php?${cl_col}=1 answers ${code}"
			fi

			if grep -q 'ZZ-CL-A' "$BODY"; then
				ok "case_list.php?${cl_col}=1 still lists cases"
			else
				bad "case_list.php?${cl_col}=1 lists no cases"
			fi
		done

		# The char filters have to keep filtering. 'number' mode would null
		# each of these values and the WHERE clause would never be built.
		for cl_pair in 'office=ZZA' 'status=A' 'funding=ZZA' 'sp_problem=ZZA'; do
			code="$(cl_get "$cl_pair")"
			if [ "$code" = 200 ] && grep -q 'ZZ-CL-A' "$BODY" \
				&& ! grep -q 'ZZ-CL-B' "$BODY"; then
				ok "case_list.php?${cl_pair} lists only the matching case"
			else
				bad "case_list.php?${cl_pair} did not filter (${code})"
			fi
		done

		# A quote in a char filter must not widen the result set.
		code="$(cl_get "office=ZZA%27+OR+%271%27%3D%271")"
		if [ "$code" = 200 ] && ! grep -q 'ZZ-CL-' "$BODY"; then
			ok "a quoted OR in the office filter matches nothing"
		else
			bad "a quoted OR in the office filter widened the list (${code})"
		fi

		# user_id names an int column. A non-numeric value now arrives as null
		# and the filter drops, instead of being compared against the column as
		# text.
		code="$(cl_get 'user_id=abc')"
		if [ "$code" = 200 ] && grep -q 'ZZ-CL-A' "$BODY"; then
			ok "case_list.php?user_id=abc lists cases"
		else
			bad "case_list.php?user_id=abc lists nothing (${code})"
		fi

		# Positive control: a numeric user_id still selects on the owner.
		code="$(cl_get 'user_id=999999')"
		if [ "$code" = 200 ] && ! grep -q 'ZZ-CL-' "$BODY"; then
			ok "case_list.php?user_id=999999 lists no cases"
		else
			bad "the user_id filter no longer selects on the owner (${code})"
		fi

		# An absent column alongside a real filter leaves the real one working.
		code="$(cl_get 'supervisor=1&office=ZZA')"
		if [ "$code" = 200 ] && grep -q 'ZZ-CL-A' "$BODY" \
			&& ! grep -q 'ZZ-CL-B' "$BODY"; then
			ok "an absent column filter does not disturb the office filter"
		else
			bad "supervisor=1 with office=ZZA did not filter (${code})"
		fi
	fi

	cleanup_cl
	trap 'rm -f "$COOKIES" "$BODY"' EXIT
else
	printf '  skip the case list filter checks (needs the database)\n'
fi

echo
echo "54. the extension loader"

# cms/pm.php turns a request path into a require(). Two rules decide what may
# be loaded: the directory has to be named in the 'extensions' setting, and the
# file has to end in .php.
#
# The first rule was asked with strpos(), which only wants the requested name to
# appear ANYWHERE in the setting. With 'extensions' set to '/billing', a request
# for the directory 'bill' passed; a directory named across the separator, as in
# 'billing:intake', sat inside the setting string and passed too. Any directory
# under cms-custom/extensions whose name is a substring of the setting could be
# loaded. The check now compares against the parsed list, exactly.
#
# The setting itself is written by ops/update_extensions.php, which joins the
# names an administrator ticked with ':', each one carrying the leading '/' that
# the folder scan in system-extensions.php produced. So '/zzextra:/zzother' is
# the shape the application actually stores, and the fixture below uses it.
# pl_enabled_extensions() in app/lib/pl.php is the one reader of that shape.
#
# Separately, every extension that DID load ended the request with HTTP 500:
# the trailing pika_exit() was called with no argument and pika_exit() takes
# one, so the page printed its output and then died on ArgumentCountError.
#
# Needs the database for the setting row, and the container to write the
# extension directory - cms-custom is a named volume, not a bind mount.
if [ "$HAVE_DB" = 1 ] && [ "$HAVE_COMPOSE" = 1 ]; then
	# Keep whatever this deployment already had in the setting.
	PMPREV="$(adb "SELECT value FROM settings WHERE label = 'extensions'")"

	# The case fixture for the gate checks further down.
	PMG=zz_pm_grp
	PMRD=zz_pm_reader
	PMOW=zz_pm_owner
	PMPWD='zz-pm-Passw0rd'
	PMNUM=ZZ-PM-1
	# The mixed-source checks need a case that EXISTS and that the caller may
	# not read. With a case_id nothing owns, a gate that only checked the row
	# exists would pass them, and they would not be about authorization at all.
	PMNUM2=ZZ-PM-2

	cleanup_pm() {
		adb "DELETE FROM settings WHERE label = 'extensions'" >/dev/null
		if [ -n "${PMPREV:-}" ]; then
			adb "INSERT INTO settings (label, value) VALUES ('extensions', '${PMPREV}')" >/dev/null
		fi
		# Only the four fixture directories, never the whole extensions tree.
		docker compose "${COMPOSE_ARGS[@]}" exec -T app rm -rf \
			/var/www/html/cms-custom/extensions/zzextra \
			/var/www/html/cms-custom/extensions/zzext \
			/var/www/html/cms-custom/extensions/zzcasex \
			"/var/www/html/cms-custom/extensions/zzextra:zzother" </dev/null >/dev/null 2>&1

		# The case fixture the gate checks below need. csrf_tokens is deleted by
		# literal session id: its session_id column is utf8mb4_unicode_ci while
		# user_sessions.session_id takes the database default, so comparing the
		# two answers "Illegal mix of collations" and, with adb sending stderr
		# to /dev/null, would remove nothing and say nothing.
		# The fixture's own ids, read before anything is deleted. Counting
		# sessions through a subquery on the users table answered 0 as soon as
		# those users were gone, so a session delete that removed nothing still
		# looked like a clean sweep.
		pm_uids="$(adb "SELECT user_id FROM users
			WHERE username IN ('${PMRD}', '${PMOW}')" | paste -sd, -)"
		pm_sids=''
		if [ -n "$pm_uids" ]; then
			pm_sids="$(adb "SELECT CONCAT(CHAR(39), session_id, CHAR(39)) FROM user_sessions
				WHERE user_id IN (${pm_uids})" | paste -sd, -)"
		fi
		if [ -n "$pm_sids" ]; then
			adb "DELETE FROM csrf_tokens WHERE session_id IN (${pm_sids})" >/dev/null
		fi
		if [ -n "$pm_uids" ]; then
			adb "DELETE FROM user_sessions WHERE user_id IN (${pm_uids})" >/dev/null
		fi
		adb "DELETE FROM cases WHERE number IN ('${PMNUM}', '${PMNUM2}')" >/dev/null
		adb "DELETE FROM users WHERE username IN ('${PMRD}', '${PMOW}')" >/dev/null
		adb "DELETE FROM \`groups\` WHERE group_id = '${PMG}'" >/dev/null

		# audit_log keeps its login rows on purpose. Everything else the fixture
		# made has to be gone, or the next run measures this one's leftovers.
		# Sessions and CSRF rows are counted by the ids captured above: by now the
		# users table cannot answer for them either way.
		pm_left="$(adb "SELECT COUNT(*) FROM users WHERE username IN ('${PMRD}', '${PMOW}')")"
		pm_left="${pm_left}$(adb "SELECT COUNT(*) FROM cases
			WHERE number IN ('${PMNUM}', '${PMNUM2}')")"
		pm_left="${pm_left}$(adb "SELECT COUNT(*) FROM \`groups\` WHERE group_id = '${PMG}'")"
		if [ -n "$pm_uids" ]; then
			pm_left="${pm_left}$(adb "SELECT COUNT(*) FROM user_sessions
				WHERE user_id IN (${pm_uids})")"
		else
			pm_left="${pm_left}0"
		fi
		if [ -n "$pm_sids" ]; then
			pm_left="${pm_left}$(adb "SELECT COUNT(*) FROM csrf_tokens
				WHERE session_id IN (${pm_sids})")"
		else
			pm_left="${pm_left}0"
		fi
		if [ -n "${pm_swept:-}" ] && [ "$pm_left" != "00000" ]; then
			bad "the extension case fixture could not be removed (users, case, group, sessions, csrf rows still present: ${pm_left})"
		fi
	}
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_pm' EXIT
	cleanup_pm

	# Two entries, so a directory named across the ':' that separates them can
	# be tried below.
	adb "DELETE FROM settings WHERE label = 'extensions'" >/dev/null
	adb "INSERT INTO settings (label, value) VALUES ('extensions', '/zzextra:/zzother:/zzcasex')" >/dev/null

	# zzextra is enabled. zzext is a prefix of it and is NOT enabled.
	# 'zzextra:zzother' spans the separator and is not one of the names.
	docker compose "${COMPOSE_ARGS[@]}" exec -T app sh -s >/dev/null 2>&1 <<'PMSEED'
D=/var/www/html/cms-custom/extensions
mkdir -p "$D/zzextra" "$D/zzext" "$D/zzextra:zzother"
printf '<?php echo "ZZPM-ENABLED-OK";\n' > "$D/zzextra/zzhello.php"
printf '<?php echo "ZZPM-SUBSTRING-OK";\n' > "$D/zzext/zzhello.php"
printf '<?php echo "ZZPM-SPAN-OK";\n' > "$D/zzextra:zzother/zzhello.php"
printf 'ZZPM-SECRET-TXT\n' > "$D/zzextra/zzsecret.txt"
mkdir -p "$D/zzcasex"
cat > "$D/zzcasex/zzcase.php" <<'PMPHP'
<?php
/*	A case-scoped extension report, the shape a deployment writes. It reads
	nothing but case_id, which is the point: pm.php has to decide whether the
	caller may see this case, because this file is not in the repository and
	cannot be made to.
*/
$q = DB::query("SELECT number FROM cases WHERE case_id = " . (int) pl_grab_var('case_id') . " LIMIT 1");

if ($q && DBResult::numRows($q) > 0)
{
	$r = DBResult::fetchRow($q);
	echo "ZZPM-CASE-NUMBER:" . $r['number'];
}

else
{
	echo "ZZPM-NO-CASE";
}
PMPHP
cat > "$D/zzcasex/zzcaseget.php" <<'PMGETPHP'
<?php
/*	The same report, reading $_GET instead of $_REQUEST. A deployment picks its
	own getter, and the two disagree: with request_order at its "GP" default a
	POST body wins in $_REQUEST, so a gate reading $_REQUEST saw a blank case_id
	while this file still read the one in the query string.
*/
$q = DB::query("SELECT number FROM cases WHERE case_id = " . (int) pl_grab_get('case_id') . " LIMIT 1");

if ($q && DBResult::numRows($q) > 0)
{
	$r = DBResult::fetchRow($q);
	echo "ZZPM-CASE-NUMBER:" . $r['number'];
}

else
{
	echo "ZZPM-NO-CASE";
}
PMGETPHP
PMSEED

	# --path-as-is: the fixture paths are the point, curl must not normalise
	# them.
	pm_get() {
		curl -s --max-time 30 -b "$COOKIES" -o "$BODY" -w '%{http_code}' \
			--path-as-is "$OCM_URL/pm.php/$1"
	}

	if [ -z "$(docker compose "${COMPOSE_ARGS[@]}" exec -T app \
		sh -c 'ls /var/www/html/cms-custom/extensions/zzextra/zzhello.php' </dev/null 2>/dev/null)" ]; then
		bad "could not seed the extension fixtures"
	else
		# Positive control, and the 500 the trailing pika_exit() used to raise.
		code="$(pm_get 'zzextra/zzhello.php')"
		if [ "$code" = 200 ] && grep -q 'ZZPM-ENABLED-OK' "$BODY"; then
			ok "an enabled extension loads and answers 200"
		else
			bad "an enabled extension answers ${code}"
		fi

		# A directory whose name is a prefix of the setting is not enabled.
		code="$(pm_get 'zzext/zzhello.php')"
		if ! grep -q 'ZZPM-SUBSTRING-OK' "$BODY"; then
			ok "a directory named as a substring of the setting is refused"
		else
			bad "a directory named as a substring of the setting was loaded"
		fi

		# Nor is a directory whose name spans the ':' that separates the
		# entries. The name sits inside the setting string, which is what
		# strpos() used to accept, but it is not one of the names in it.
		code="$(pm_get 'zzextra%3Azzother/zzhello.php')"
		if ! grep -q 'ZZPM-SPAN-OK' "$BODY"; then
			ok "a directory named across the setting's separator is refused"
		else
			bad "a directory named across the setting's separator was loaded"
		fi

		# The .php rule still holds inside an enabled extension.
		code="$(pm_get 'zzextra/zzsecret.txt')"
		if ! grep -q 'ZZPM-SECRET-TXT' "$BODY"; then
			ok "a non-.php file in an enabled extension is refused"
		else
			bad "a non-.php file in an enabled extension was served"
		fi

		# The reports branch takes the same two rules and the same exit.
		code="$(pm_get 'reports/zzextra/zzhello.php')"
		if [ "$code" = 200 ] && grep -q 'ZZPM-ENABLED-OK' "$BODY"; then
			ok "an enabled extension report loads and answers 200"
		else
			bad "an enabled extension report answers ${code}"
		fi

		code="$(pm_get 'reports/zzext/zzhello.php')"
		if ! grep -q 'ZZPM-SUBSTRING-OK' "$BODY"; then
			ok "a substring directory is refused on the reports path too"
		else
			bad "a substring directory was loaded on the reports path"
		fi

		# Both require() calls in pm.php load a deployment's own extension,
		# which is not in this repository, so the gate has to be in pm.php.
		# Before it, the file asked only pika_init() - is the caller signed in -
		# and handed the request, case_id and all, to the extension. Measured
		# with this fixture on the unpatched file: a user whose group grants no
		# case access read ZZPM-CASE-NUMBER:ZZ-PM-1 with HTTP 200 on both paths,
		# while case.php answered the same user 403.
		#
		# pika_authorize() short-circuits to true for the system group, so the
		# reader below cannot be an administrator.
		pm_swept=1
		adb "INSERT INTO \`groups\` (group_id, read_office, read_all, edit_office, edit_all, users, pba, motd, intake, reports)
			VALUES ('${PMG}', NULL, 0, NULL, 0, 0, 0, 0, 0, NULL)" >/dev/null
		PMHASH="$(docker compose "${COMPOSE_ARGS[@]}" exec -T app \
			php -r 'echo password_hash($argv[1], PASSWORD_DEFAULT);' "$PMPWD" </dev/null 2>/dev/null)"
		PMRDID="$(adb "SELECT COALESCE(MAX(user_id), 0) + 1 FROM users")"
		PMOWID=$((PMRDID + 1))
		adb "INSERT INTO users (user_id, username, password, enabled, group_id, password_expire, must_change_password)
			VALUES (${PMRDID}, '${PMRD}', '${PMHASH}', 1, '${PMG}', 0, 0),
				(${PMOWID}, '${PMOW}', '${PMHASH}', 1, '${PMG}', 0, 0)" >/dev/null
		PMCASE="$(adb "SELECT COALESCE(MAX(case_id), 0) + 1 FROM cases")"
		# cases.office is char(3): a longer name is truncated on the shipped
		# non-strict database and rejected under strict SQL mode.
		adb "INSERT INTO cases (case_id, number, user_id, office, open_date, status)
			VALUES (${PMCASE}, '${PMNUM}', ${PMOWID}, 'ZZO', CURDATE(), 'O')" >/dev/null
		PMCASE2=$((PMCASE + 1))
		adb "INSERT INTO cases (case_id, number, user_id, office, open_date, status)
			VALUES (${PMCASE2}, '${PMNUM2}', ${PMRDID}, 'ZZO', CURDATE(), 'O')" >/dev/null

		PMRJAR="$(mktemp)"
		PMOJAR="$(mktemp)"

		# Every request checks curl's exit status. Without that a transfer that
		# died after the refusal text had arrived would read as a refusal.
		pm_as() {
			: > "$BODY"
			pm_code="$(curl -s --max-time 60 -b "$1" -o "$BODY" -w '%{http_code}' \
				--path-as-is "$OCM_URL/$2")"
			pm_curl=$?
			[ "$pm_curl" = 0 ]
		}

		pm_login() {
			: > "$1"
			: > "$BODY"
			pm_code="$(curl -sL --max-time 30 -c "$1" -b "$1" -o "$BODY" -w '%{http_code}' \
				-X POST -d "login_user=${2}&login_pass=${PMPWD}&auth_id=1" "$OCM_URL/")"
			pm_curl=$?
			[ "$pm_curl" = 0 ] && [ "$pm_code" = 200 ] && [ -s "$BODY" ] \
				&& ! grep -q 'login_pass' "$BODY"
		}

		if [ -z "$PMHASH" ] || [ -z "$PMCASE" ]; then
			bad "could not seed the extension case fixture"
		elif ! pm_login "$PMRJAR" "$PMRD"; then
			bad "the throwaway extension reader could not log in (status ${pm_code}, curl ${pm_curl})"
		elif ! pm_login "$PMOJAR" "$PMOW"; then
			bad "the throwaway case owner could not log in (status ${pm_code}, curl ${pm_curl})"
		else
			ok "both throwaway extension users can log in"

			# The reader has to be refused on both of pm.php's branches.
			for pm_path in "reports/zzcasex/zzcase.php" "zzcasex/zzcase.php"; do
				if ! pm_as "$PMRJAR" "pm.php/${pm_path}?case_id=${PMCASE}"; then
					bad "the reader's request for pm.php/${pm_path} failed (curl exit $pm_curl)"
				elif grep -qF "$PMNUM" "$BODY"; then
					bad "pm.php/${pm_path} PRINTED CASE ${PMNUM} TO A USER WHO CANNOT READ IT"
				elif [ "$pm_code" = 403 ] && grep -q 'This case is not viewable' "$BODY"; then
					ok "pm.php/${pm_path} refuses a case the caller cannot read"
				else
					bad "pm.php/${pm_path} answered the reader ${pm_code} instead of the refusal"
				fi
			done

			pm_post() {
				: > "$BODY"
				pm_code="$(curl -s --max-time 60 -b "$1" -o "$BODY" -w '%{http_code}' \
					--path-as-is -X POST -d "$3" "$OCM_URL/$2")"
				pm_curl=$?
				[ "$pm_curl" = 0 ]
			}

			# zzcaseget.php reads the query string, so a POST body that blanks
			# case_id hid the case from a gate reading the merged $_REQUEST array
			# while the extension still read it. Both branches.
			for pm_path in "reports/zzcasex/zzcaseget.php" "zzcasex/zzcaseget.php"; do
				if ! pm_post "$PMRJAR" "pm.php/${pm_path}?case_id=${PMCASE}" 'case_id='; then
					bad "the reader's POST to pm.php/${pm_path} failed (curl exit $pm_curl)"
				elif grep -qF "$PMNUM" "$BODY"; then
					bad "pm.php/${pm_path} PRINTED CASE ${PMNUM} TO A USER WHO CANNOT READ IT WHEN A POST BODY BLANKED THE case_id IN THE QUERY STRING"
				elif [ "$pm_code" = 403 ] && grep -q 'This case is not viewable' "$BODY"; then
					ok "pm.php/${pm_path} refuses when a POST body blanks the case_id in the query string"
				else
					bad "pm.php/${pm_path} answered a blanked POST body ${pm_code} instead of the refusal"
				fi
			done

			# A POST body naming a case id of 0 next to a real one in the query
			# string. Both reasons to refuse are present here -- 0 is not a case
			# id, and this reader may not read the case in the query string --
			# so this check does not isolate either rule. It is kept because it
			# is the shape that exposed the gate reading only $_REQUEST.
			if ! pm_post "$PMRJAR" "pm.php/zzcasex/zzcase.php?case_id=${PMCASE}" 'case_id=0'; then
				bad "the reader's POST with a second case_id failed (curl exit $pm_curl)"
			elif grep -qF "$PMNUM" "$BODY"; then
				bad "pm.php PRINTED CASE ${PMNUM} TO A USER WHO CANNOT READ IT WHEN THE QUERY STRING AND THE POST BODY NAMED DIFFERENT CASES"
			elif [ "$pm_code" = 403 ] && grep -q 'This case is not viewable' "$BODY"; then
				ok "pm.php refuses a request whose query string and POST body name different cases"
			else
				bad "pm.php answered two different case_id values ${pm_code} instead of the refusal"
			fi

			# Send the jar's cookies by hand so an extra case_id cookie can ride
			# along with the session. curl's -b file and -H Cookie: cannot be
			# combined: the header replaces the jar, and the session goes with it.
			# The #HttpOnly_ prefix is stripped because the session cookie carries
			# it, and a line starting with # would otherwise look like a comment.
			pm_cookie() {
				pm_pairs="$(sed 's/^#HttpOnly_//' "$1" \
					| awk 'BEGIN { FS = "\t" } !/^#/ && NF >= 7 { printf "%s=%s; ", $6, $7 }')"
				: > "$BODY"
				pm_code="$(curl -s --max-time 60 -o "$BODY" -w '%{http_code}' \
					--path-as-is -H "Cookie: ${pm_pairs}$3" "$OCM_URL/$2")"
				pm_curl=$?
				[ "$pm_curl" = 0 ] && [ -n "$pm_pairs" ]
			}

			# Controls for the second case. Without these the two mixed-source
			# checks below could pass because the row was never inserted, which
			# is the same silence the missing-case branch produces.
			if ! pm_as "$PMRJAR" "pm.php/zzcasex/zzcase.php?case_id=${PMCASE2}"; then
				bad "the reader's request for its own case failed (curl exit $pm_curl)"
			elif [ "$pm_code" = 200 ] && grep -qF "ZZPM-CASE-NUMBER:${PMNUM2}" "$BODY"; then
				ok "the second case exists and its own owner reads it"
			else
				bad "THE SECOND CASE FIXTURE DID NOT RENDER FOR ITS OWNER (status ${pm_code}), SO THE MIXED-SOURCE CHECKS PROVE NOTHING"
			fi

			if ! pm_as "$PMOJAR" "pm.php/zzcasex/zzcase.php?case_id=${PMCASE2}"; then
				bad "the handler's request for the other case failed (curl exit $pm_curl)"
			elif [ "$pm_code" = 403 ] && grep -q 'This case is not viewable' "$BODY"; then
				ok "the second case is refused to the first case's handler"
			else
				bad "pm.php ANSWERED CASE ${PMNUM2} ${pm_code} TO A USER WHO CANNOT READ IT"
			fi

			# request_order is unset in the shipped container, so $_REQUEST is
			# built in variables_order -- EGPCS -- and a cookie overwrites the
			# query string and the body both. A gate reading only $_GET and
			# $_POST sees no case at all here, while pl_grab_var() in the
			# extension reads the one in the cookie.
			if ! pm_cookie "$PMRJAR" "pm.php/zzcasex/zzcase.php" "case_id=${PMCASE}"; then
				bad "the reader's cookie request to pm.php failed (curl exit $pm_curl)"
			elif grep -qF "$PMNUM" "$BODY"; then
				bad "pm.php PRINTED CASE ${PMNUM} TO A USER WHO CANNOT READ IT WHEN THE case_id ARRIVED ONLY IN A COOKIE"
			elif [ "$pm_code" = 403 ] && grep -q 'This case is not viewable' "$BODY"; then
				ok "pm.php refuses a case_id that arrives only in a cookie"
			else
				bad "pm.php answered a cookie-only case_id ${pm_code} instead of the refusal"
			fi

			# The case's own handler, with a readable case in the query string and
			# a case it may not read in a second source. Authorizing only the
			# first value found would let these through, and the extension may
			# read either one. The second id names a real row, so a refusal here
			# is a refusal on permission and not on a missing case.
			if ! pm_cookie "$PMOJAR" "pm.php/zzcasex/zzcase.php?case_id=${PMCASE}" "case_id=${PMCASE2}"; then
				bad "the handler's mixed cookie request to pm.php failed (curl exit $pm_curl)"
			elif [ "$pm_code" = 403 ] && grep -q 'This case is not viewable' "$BODY"; then
				ok "pm.php refuses a readable case in the query string beside an unreadable one in a cookie"
			else
				bad "pm.php ANSWERED A READABLE case_id BESIDE AN UNREADABLE ONE IN A COOKIE ${pm_code} INSTEAD OF THE REFUSAL, SO ONLY THE FIRST SOURCE IS AUTHORIZED"
			fi

			if ! pm_post "$PMOJAR" "pm.php/zzcasex/zzcase.php?case_id=${PMCASE}" "case_id=${PMCASE2}"; then
				bad "the handler's mixed POST to pm.php failed (curl exit $pm_curl)"
			elif [ "$pm_code" = 403 ] && grep -q 'This case is not viewable' "$BODY"; then
				ok "pm.php refuses a readable case in the query string beside an unreadable one in the POST body"
			else
				bad "pm.php ANSWERED A READABLE case_id BESIDE AN UNREADABLE ONE IN THE POST BODY ${pm_code} INSTEAD OF THE REFUSAL, SO ONLY THE FIRST SOURCE IS AUTHORIZED"
			fi

			# One case, two spellings. The getters trim and so does filter_var(),
			# so ' 42 ' and '42' are the same case and the handler keeps the
			# report. Comparing the raw strings instead refused this.
			if ! pm_post "$PMOJAR" "pm.php/zzcasex/zzcase.php?case_id=${PMCASE}" "case_id=%20${PMCASE}%20"; then
				bad "the handler's spaced-value POST to pm.php failed (curl exit $pm_curl)"
			elif [ "$pm_code" = 403 ] || grep -q 'This case is not viewable' "$BODY"; then
				bad "pm.php refused the case's own handler for spelling one case id two ways (status ${pm_code})"
			elif [ "$pm_code" = 200 ] && grep -qF "ZZPM-CASE-NUMBER:${PMNUM}" "$BODY"; then
				ok "pm.php allows two spellings of one case the caller may read"
			else
				bad "pm.php answered two spellings of one readable case ${pm_code} without the report"
			fi

			# A leading zero is the same case to every reader of case_id, because
			# they all cast to int. filter_var() disagrees, so the gate has to
			# normalize before it compares, or it refuses the case's own handler.
			if ! pm_post "$PMOJAR" "pm.php/zzcasex/zzcase.php?case_id=${PMCASE}" "case_id=0${PMCASE}"; then
				bad "the handler's leading-zero POST to pm.php failed (curl exit $pm_curl)"
			elif [ "$pm_code" = 200 ] && grep -qF "ZZPM-CASE-NUMBER:${PMNUM}" "$BODY"; then
				ok "pm.php reads a leading-zero case id as the case it names"
			else
				bad "pm.php refused the case's own handler for writing its case id with a leading zero (status ${pm_code})"
			fi

			# The same extension, read by the case's own handler: the gate must not
			# have cost the $_GET reader its report.
			if ! pm_as "$PMOJAR" "pm.php/zzcasex/zzcaseget.php?case_id=${PMCASE}"; then
				bad "the owner's request for the query-string extension report failed (curl exit $pm_curl)"
			elif [ "$pm_code" = 200 ] && grep -qF "ZZPM-CASE-NUMBER:${PMNUM}" "$BODY"; then
				ok "the case's own handler still gets a report that reads the query string"
			else
				bad "the query-string extension report answered the case's own handler ${pm_code}"
			fi

			# An id that names no case, and an id that is not a case id at all,
			# have to answer the same way as a case the reader may not read.
			# Otherwise the answer tells a caller which case ids are real.
			pm_none="$(adb "SELECT COALESCE(MAX(case_id), 0) + 500 FROM cases")"
			for pm_id in "$pm_none" '0' '1e3'; do
				if ! pm_as "$PMRJAR" "pm.php/reports/zzcasex/zzcase.php?case_id=${pm_id}"; then
					bad "the reader's request for case_id='${pm_id}' failed (curl exit $pm_curl)"
				elif [ "$pm_code" = 403 ] && grep -q 'This case is not viewable' "$BODY"; then
					ok "pm.php answers case_id='${pm_id}' the same refusal an existing case gets"
				else
					bad "pm.php ANSWERED case_id='${pm_id}' WITH ${pm_code} INSTEAD OF THE REFUSAL AN EXISTING CASE GETS, SO A SIGNED-IN USER CAN TELL REAL CASE IDS FROM INVENTED ONES"
				fi
			done

			# An extension that names no case is not case-scoped and must still
			# run. This is the check that fails if the gate refuses too much.
			if ! pm_as "$PMRJAR" "pm.php/zzcasex/zzcase.php"; then
				bad "the reader's request for an extension with no case_id failed (curl exit $pm_curl)"
			elif [ "$pm_code" = 200 ] && grep -q 'ZZPM-NO-CASE' "$BODY"; then
				ok "an extension that names no case still runs"
			else
				bad "an extension with no case_id answered ${pm_code} instead of running"
			fi

			# The case's own handler still gets the report.
			if ! pm_as "$PMOJAR" "pm.php/reports/zzcasex/zzcase.php?case_id=${PMCASE}"; then
				bad "the owner's request for the extension report failed (curl exit $pm_curl)"
			elif [ "$pm_code" = 200 ] && grep -qF "ZZPM-CASE-NUMBER:${PMNUM}" "$BODY"; then
				ok "the case's own handler still gets the extension report"
			else
				bad "the extension report answered the case's own handler ${pm_code}"
			fi

			# So does an administrator.
			if ! pm_as "$COOKIES" "pm.php/reports/zzcasex/zzcase.php?case_id=${PMCASE}"; then
				bad "the admin's request for the extension report failed (curl exit $pm_curl)"
			elif [ "$pm_code" = 200 ] && grep -qF "ZZPM-CASE-NUMBER:${PMNUM}" "$BODY"; then
				ok "the admin still gets the extension report"
			else
				bad "the extension report answered the admin ${pm_code}"
			fi
		fi

		rm -f "$PMRJAR" "$PMOJAR"
	fi

	cleanup_pm
	trap 'rm -f "$COOKIES" "$BODY"' EXIT
else
	printf '  skip the extension loader checks (needs the database and the container)\n'
fi

echo
echo "55. the case transfer page"

# cms/transfer.php printed three values into the page without encoding them.
# case_id came straight out of the query string and landed inside the href of
# the breadcrumb link and inside two value="..." attributes in
# subtemplates/transfer.html; pl_clean_form_input() encodes < and > but not
# quotes, and pl_template_sub() substitutes the value as it stands, so a quote
# closed the attribute early and the rest of the parameter became markup. An
# event handler needs no tag of its own, so autofocus onfocus= ran on load.
# MySQL reads the leading digits when it compares an int column against a
# string, so a payload beginning with a real case id still found the case and
# the page still rendered. case_id and transfer_option_id are now read in
# 'number' mode.
#
# The stored values had the same problem: cases.number and
# transfer_options.label are both typed by a user and both were printed as
# they stood. Each is now encoded once, where it is read.
#
# Loading the page also used to consume a case number. pikaCase treats a null
# id as a new case and gives a new case its number straight away, which draws
# the next value from the 'case_number' counter - and nothing here saves the
# case, so the number was simply lost. The lookup now only runs when the
# request named a case.
#
# Needs the database: the checks read a seeded case number and agency label
# back out of the rendered page, and watch the counter.
if [ "$HAVE_DB" = 1 ]; then
	cleanup_tr() {
		adb "DELETE FROM cases WHERE number = 'ZZ-TR<b>zz'" >/dev/null
		adb "DELETE FROM transfer_options WHERE label = 'ZZTR<b>opt'" >/dev/null
	}
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_tr' EXIT
	cleanup_tr

	# Ids come from the `counters` row as well as from MAX(), because
	# plBase::getNextID hands out the next primary key from counters.
	tr_next_id() {
		adb "SELECT GREATEST(
			COALESCE((SELECT MAX(${2}) FROM \`${1}\`), 0),
			COALESCE((SELECT count FROM counters WHERE id = '${1}'), 0)) + 1"
	}

	tr_bump_counter() {
		adb "UPDATE counters SET count = GREATEST(count, ${2}) WHERE id = '${1}'" >/dev/null
	}

	# The case number and the agency label both carry a tag. cases.number is
	# varchar(24), so the marker is short enough to survive the insert whole.
	TRCASE="$(tr_next_id cases case_id)"
	adb "INSERT INTO cases (case_id, number, user_id, open_date)
		VALUES (${TRCASE}, 'ZZ-TR<b>zz', 1, CURDATE())" >/dev/null
	tr_bump_counter cases "$TRCASE"

	TROPT="$(tr_next_id transfer_options transfer_option_id)"
	adb "INSERT INTO transfer_options (transfer_option_id, label, url, transfer_mode)
		VALUES (${TROPT}, 'ZZTR<b>opt', 'http://127.0.0.1/zztr', 1)" >/dev/null
	tr_bump_counter transfer_options "$TROPT"

	# GET the transfer page with a query string and report the status code.
	tr_get() {
		curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" -w '%{http_code}' \
			"$OCM_URL/transfer.php?$1"
	}

	if [ -z "$(adb "SELECT case_id FROM cases WHERE number = 'ZZ-TR<b>zz'")" ]; then
		bad "could not seed the case transfer fixtures"
	else
		# The counter has to stand still across a request that names no case
		# and a request that names something that is not a case id.
		TRCOUNT_BEFORE="$(adb "SELECT count FROM counters WHERE id = 'case_number'")"

		# The page used to answer a request with no case_id by drawing the
		# transfer form under the label 'No Case #'. It now requires
		# edit_case on a real case, so there is nothing to draw and nothing
		# to say: both of these get the shared case refusal instead. Every
		# link into the page carries a case_id, so no working flow loses.
		code="$(tr_get '')"
		if [ "$code" = 403 ] && ! grep -qF 'No Case #' "$BODY"; then
			ok "transfer.php with no case is refused"
		else
			bad "transfer.php with no case answers ${code}, expected 403"
		fi

		code="$(tr_get 'case_id=zznotanumber')"
		if [ "$code" = 403 ] && ! grep -qF 'No Case #' "$BODY"; then
			ok "transfer.php with a non-numeric case_id is refused"
		else
			bad "transfer.php with a non-numeric case_id answers ${code}, expected 403"
		fi

		TRCOUNT_AFTER="$(adb "SELECT count FROM counters WHERE id = 'case_number'")"
		if [ "$TRCOUNT_BEFORE" = "$TRCOUNT_AFTER" ]; then
			ok "the transfer page does not consume a case number"
		else
			bad "the transfer page consumed case numbers (${TRCOUNT_BEFORE} -> ${TRCOUNT_AFTER})"
		fi

		# A quote in case_id used to break out of the breadcrumb href.
		code="$(curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" -w '%{http_code}' \
			-G --data-urlencode "case_id=${TRCASE}\" onfocus=\"zztralert()\" autofocus x=\"" \
			"$OCM_URL/transfer.php")"
		if [ "$code" = 403 ] && ! grep -qF 'onfocus' "$BODY"; then
			ok "a quote in case_id does not reach the page"
		else
			bad "a quote in case_id answers ${code} and reaches the page as an event handler"
		fi

		# The stored case number, in the breadcrumb and in the page body.
		code="$(tr_get "case_id=${TRCASE}")"
		if [ "$code" = 200 ] && grep -qF 'ZZ-TR&lt;b&gt;zz' "$BODY"; then
			ok "the case number is encoded on the transfer page"
		else
			bad "the case number is not encoded on the transfer page (${code})"
		fi

		if grep -qF 'ZZ-TR<b>zz' "$BODY"; then
			bad "the case number reaches the transfer page as markup"
		else
			ok "the case number does not reach the transfer page as markup"
		fi

		if grep -qF 'ZZTR&lt;b&gt;opt' "$BODY"; then
			ok "the agency label is encoded in the transfer option list"
		else
			bad "the agency label is not encoded in the transfer option list"
		fi

		# The confirmation screen, which prints the label twice.
		code="$(tr_get "case_id=${TRCASE}&action=pika&transfer_option_id=${TROPT}")"
		if [ "$code" = 200 ] && ! grep -qF 'ZZTR<b>opt' "$BODY"; then
			ok "the agency label is encoded on the confirmation screen"
		else
			bad "the agency label reaches the confirmation screen as markup (${code})"
		fi

		code="$(tr_get "case_id=${TRCASE}&action=pika&transfer_option_id=zznotanumber")"
		if [ "$code" = 200 ]; then
			ok "a non-numeric transfer_option_id still renders the page"
		else
			bad "a non-numeric transfer_option_id answers ${code}"
		fi
	fi

	cleanup_tr
	trap 'rm -f "$COOKIES" "$BODY"' EXIT
else
	printf '  skip the case transfer checks (needs the database)\n'
fi

echo
echo "56. a stored preference cannot name a file, reach SQL, or become PHP"

# A preference is a request value that is stored and then used with nothing
# checking it again. cms/prefs.php wrote whatever the request offered into
# users.session_data, pikaDefPrefs::initPrefs() put that back into $_SESSION
# on every later request, and cms/pika_cms.php then include()d
# themes/<theme>.php and interpolated the paging count straight into a LIMIT
# clause - so a theme name holding '../' ran any .php file on the server as
# part of the page, a font size that was not one of the four names took every
# page with it, and a paging count that was not a number made the attorney
# search answer HTTP 500 with an empty body.
#
# cms/system-default_prefs.php writes the same values into
# cms-custom/config/default_prefs.php, which every request includes.
# pikaFileArray::array2Php() built the PHP literals by hand, so a value
# holding a double quote closed its own string and added an expression of its
# own to that file.
if [ "$HAVE_DB" = 1 ]; then
	PRSD=""
	PRDEF=""
	PRCASE=""
	PRCASEOWNED=0
	PRCASEMARK="ZZPRPREFS$$"
	PRDEFFILE=/var/www/html/cms-custom/config/default_prefs.php

	cleanup_pr() {
		if [ "$PRCASEOWNED" = 1 ]; then
			adb "DELETE FROM cases WHERE case_id = ${PRCASE} AND number = '${PRCASEMARK}'" >/dev/null
			PRCASEOWNED=0
		fi
		if [ -n "$PRSD" ]; then
			adb "UPDATE users SET session_data = '${PRSD}' WHERE user_id = 1" >/dev/null
		fi
		if [ "$HAVE_COMPOSE" = 1 ] && [ -n "$PRDEF" ]; then
			printf '%s' "$PRDEF" | docker compose "${COMPOSE_ARGS[@]}" exec -T app \
				sh -c "base64 -d > ${PRDEFFILE}" >/dev/null 2>&1
			docker compose "${COMPOSE_ARGS[@]}" exec -T app \
				rm -f /tmp/zzpr_pwned.txt >/dev/null 2>&1
		fi
	}
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_pr' EXIT

	# The admin's own preferences, and the defaults file, are what these
	# checks overwrite. Keep both so the stack is handed back as it was.
	PRSD="$(adb "SELECT session_data FROM users WHERE user_id = 1")"

	pr_token() {
		curl -sL --max-time 30 -b "$COOKIES" "$OCM_URL/prefs.php" \
			| grep -oE 'name="_csrf" value="[0-9a-f]{64}"' \
			| head -1 | sed -e 's/.*value="//' -e 's/"$//'
	}

	pr_session_data() {
		adb "SELECT session_data FROM users WHERE user_id = 1"
	}

	# A theme name that walks out of themes/, a font size that is not one of
	# the four the application draws, and a paging count that is not a number.
	PRTOK="$(pr_token)"
	curl -s --max-time 30 -b "$COOKIES" -o "$BODY" -X POST \
		--data-urlencode "action=update_prefs" \
		--data-urlencode "_csrf=${PRTOK}" \
		--data-urlencode "theme=../themes/Red" \
		--data-urlencode "font_size=zzjunk" \
		--data-urlencode "paging=abc" \
		"$OCM_URL/prefs.php" >/dev/null

	PRSTORED="$(pr_session_data)"

	case "$PRSTORED" in
		*"../"*) bad "prefs.php stored a theme name that walks out of themes/" ;;
		*) ok "prefs.php refuses a theme name that walks out of themes/" ;;
	esac

	case "$PRSTORED" in
		*zzjunk*) bad "prefs.php stored a font size the application cannot draw" ;;
		*) ok "prefs.php refuses a font size the application cannot draw" ;;
	esac

	case "$PRSTORED" in
		*abc*) bad "prefs.php stored a paging count that is not a number" ;;
		*) ok "prefs.php refuses a paging count that is not a number" ;;
	esac

	# Positive control. A filter that threw everything away would pass the
	# three checks above without the preferences screen working at all.
	PRTOK="$(pr_token)"
	curl -s --max-time 30 -b "$COOKIES" -o "$BODY" -X POST \
		--data-urlencode "action=update_prefs" \
		--data-urlencode "_csrf=${PRTOK}" \
		--data-urlencode "theme=Red" \
		--data-urlencode "font_size=Large" \
		--data-urlencode "paging=25" \
		"$OCM_URL/prefs.php" >/dev/null

	PRSTORED="$(pr_session_data)"

	if printf '%s' "$PRSTORED" | grep -qF '"Red"' \
		&& printf '%s' "$PRSTORED" | grep -qF '"Large"' \
		&& printf '%s' "$PRSTORED" | grep -qF '"25"'; then
		ok "prefs.php still stores a theme, font size and paging count that are real"
	else
		bad "prefs.php no longer stores valid preferences: ${PRSTORED}"
	fi

	# The screen is not the only way a value gets into the session: one stored
	# before this fix is still there. Write the traversal straight into
	# users.session_data, the way pikaDefPrefs::initPrefs() will hand it back,
	# and load a page that includes cms/pika_cms.php.
	#
	# '../themes/Red' names a file that exists, so following it is visible in
	# the page: themes/Red.php is the only theme that paints #990000. A theme
	# that is refused falls back to Blue, which adds no CSS of its own.
	adb "UPDATE users SET session_data = 'a:2:{s:5:\"theme\";s:13:\"../themes/Red\";s:9:\"font_size\";s:6:\"zzjunk\";}' WHERE user_id = 1" >/dev/null

	PRCODE="$(curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" -w '%{http_code}' \
		"$OCM_URL/cal_day.php")"

	if grep -qF '#990000' "$BODY"; then
		bad "a theme name holding ../ was included from outside themes/"
	else
		ok "a theme name holding ../ is not included"
	fi

	if [ "$PRCODE" = 200 ] && grep -q 'Pika Home' "$BODY"; then
		ok "a page falls back to a theme that ships with the application"
	else
		bad "cal_day.php answered ${PRCODE} with a theme name it could not include"
	fi

	if grep -qiE 'failed to open stream|include\(|Undefined (array key|index)' "$BODY"; then
		bad "the theme and font size fallbacks left a PHP error on the page"
	else
		ok "no PHP error reaches the page from the theme or font size preference"
	fi

	# The paging preference is the second argument of a LIMIT clause in
	# pika_get_attorneys(). assign_atty.php needs a case, a field and one
	# filter before it runs the search, and the offset comes off the query
	# string, so this is the request that used to answer 500 with no body.
	# Use our own row so this check also runs on an empty database.
	PRCASE="$(adb "SELECT GREATEST(
		COALESCE((SELECT MAX(case_id) FROM cases), 0),
		COALESCE((SELECT count FROM counters WHERE id = 'cases'), 0)) + 1")"
	adb "INSERT INTO cases (case_id, number, user_id, office, status, intake_user_id)
		VALUES (${PRCASE}, '${PRCASEMARK}', 1, 'ZZO', '1', 1)" >/dev/null
	PRCASEOWNED=1
	adb "UPDATE counters SET count = GREATEST(count, ${PRCASE}) WHERE id = 'cases'" >/dev/null

	PRCODE="$(curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" -w '%{http_code}' \
		"$OCM_URL/assign_atty.php?case_id=${PRCASE}&field=pba_id&last_name=a&offset=abc")"

	if [ "$PRCODE" = 200 ] && grep -qF 'Assign an Attorney' "$BODY" \
		&& ! grep -qE 'Need more information\.|Access denied' "$BODY"; then
		ok "an offset that is not a number does not break the attorney search"
	else
		bad "assign_atty.php answered ${PRCODE} for a non-numeric offset"
	fi

	# ops/update_prefs.php writes the same names straight into the session.
	# It has to survive junk rather than carry it.
	PRTOK="$(pr_token)"
	PRCODE="$(curl -s --max-time 30 -b "$COOKIES" -o "$BODY" -w '%{http_code}' -X POST \
		--data-urlencode "_csrf=${PRTOK}" \
		--data-urlencode "theme=../themes/Red" \
		--data-urlencode "paging=1 UNION SELECT 1" \
		--data-urlencode "font_size=zzjunk" \
		"$OCM_URL/ops/update_prefs.php")"

	PRCODE2="$(curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" -w '%{http_code}' \
		"$OCM_URL/prefs.php")"

	if { [ "$PRCODE" = 302 ] || [ "$PRCODE" = 200 ]; } \
		&& [ "$PRCODE2" = 200 ] && grep -q 'Pika Home' "$BODY"; then
		ok "ops/update_prefs.php takes junk without carrying it into the session"
	else
		bad "ops/update_prefs.php answered ${PRCODE} and left prefs.php at ${PRCODE2}"
	fi

	# The defaults file is PHP source that every request includes, so the
	# screen that writes it is a code execution sink if a value can stop being
	# a string. These checks need the container to read the file back.
	if [ "$HAVE_COMPOSE" = 1 ]; then
		PRDEF="$(docker compose "${COMPOSE_ARGS[@]}" exec -T app \
			base64 -w 0 "$PRDEFFILE" </dev/null 2>/dev/null)"

		if [ -z "$PRDEF" ]; then
			printf '  skip the default preferences checks (cannot read the defaults file)\n'
		else
			PRTOK="$(pr_token)"
			curl -s --max-time 30 -b "$COOKIES" -o "$BODY" -X POST \
				--data-urlencode "action=update_prefs" \
				--data-urlencode "_csrf=${PRTOK}" \
				--data-urlencode 'theme=Purple" . file_put_contents("/tmp/zzpr_pwned.txt", "pwned") . "' \
				"$OCM_URL/system-default_prefs.php" >/dev/null

			# The file is included on the next request, not on the one that
			# wrote it, so load a page before looking for the payload. The
			# sleep is opcache: validate_timestamps checks a file it has
			# already compiled at most once every revalidate_freq seconds, so
			# a request made immediately after the write can still run the
			# copy from before it.
			sleep 3
			curl -sL --max-time 30 -b "$COOKIES" -o /dev/null "$OCM_URL/" >/dev/null

			if docker compose "${COMPOSE_ARGS[@]}" exec -T app \
				test -f /tmp/zzpr_pwned.txt </dev/null >/dev/null 2>&1; then
				bad "a default preference ran as PHP out of the defaults file"
			else
				ok "a default preference does not run as PHP out of the defaults file"
			fi

			if docker compose "${COMPOSE_ARGS[@]}" exec -T app \
				grep -qF 'file_put_contents' "$PRDEFFILE" </dev/null >/dev/null 2>&1; then
				bad "the defaults file holds an expression a request put there"
			else
				ok "the defaults file holds no expression a request put there"
			fi

			# A quote in a preference the application does not recognise still
			# has to leave the file as valid PHP that means the string given.
			PRTOK="$(pr_token)"
			curl -s --max-time 30 -b "$COOKIES" -o "$BODY" -X POST \
				--data-urlencode "action=update_prefs" \
				--data-urlencode "_csrf=${PRTOK}" \
				--data-urlencode 'def_office=Z'"'"'"\ZZ' \
				"$OCM_URL/system-default_prefs.php" >/dev/null

			if docker compose "${COMPOSE_ARGS[@]}" exec -T app \
				php -l "$PRDEFFILE" </dev/null >/dev/null 2>&1; then
				ok "a quote in a default preference leaves the defaults file valid PHP"
			else
				bad "a quote in a default preference broke the defaults file"
			fi

			# Past the opcache window again, so this reads the file that was
			# just written rather than the one before it.
			sleep 3
			PRCODE="$(curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" -w '%{http_code}' \
				"$OCM_URL/")"

			if [ "$PRCODE" = 200 ] && grep -q 'Pika Home' "$BODY"; then
				ok "the application still starts after that default is written"
			else
				bad "the home page answered ${PRCODE} after a quote was stored in the defaults"
			fi

			# Positive control for the same screen.
			PRTOK="$(pr_token)"
			curl -s --max-time 30 -b "$COOKIES" -o "$BODY" -X POST \
				--data-urlencode "action=update_prefs" \
				--data-urlencode "_csrf=${PRTOK}" \
				--data-urlencode "theme=Clover" \
				"$OCM_URL/system-default_prefs.php" >/dev/null

			if docker compose "${COMPOSE_ARGS[@]}" exec -T app \
				grep -qF 'Clover' "$PRDEFFILE" </dev/null >/dev/null 2>&1; then
				ok "a real theme name still saves as a default preference"
			else
				bad "a real theme name no longer saves as a default preference"
			fi
		fi
	else
		printf '  skip the default preferences checks (needs docker compose)\n'
	fi

	cleanup_pr
	trap 'rm -f "$COOKIES" "$BODY"' EXIT
else
	printf '  skip the stored preference checks (needs the database)\n'
fi

echo
echo "57. the RSS feed reader is gone"

# The home page used to render entries fetched from third party feeds, which an
# administrator subscribed to on system-feeds.php. That reader was the worst
# input this application accepted: a remote party chose the markup, and it was
# filtered with strip_tags(), which keeps every attribute on the tags it
# allows. The whole feature is removed - the reader, the admin page, the
# pikaRssFeed library, the outbound services/cal-rss.php calendar feed, the
# rss_feeds table and the per-user feed interval preference.
#
# These checks are about absence, so each one also proves it reached a real
# page: an absence check against a 404 or a login form proves nothing.

# 1. Neither entry point exists any more.
for rss_page in system-feeds.php services/cal-rss.php; do
	code="$(curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" -w '%{http_code}' \
		"$OCM_URL/${rss_page}")"
	if [ "$code" = 404 ]; then
		ok "${rss_page} is not served"
	else
		bad "${rss_page} still answers $code"
	fi
done

# 2. The home page draws, and carries none of the feature's markup.
code="$(curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" -w '%{http_code}' \
	"$OCM_URL/index.php")"
if [ "$code" = 200 ] && grep -q 'Learn to Use Pika' "$BODY"; then
	ok "the home page still draws"
else
	bad "the home page answered $code without its own content"
fi
if grep -q 'Learn to Use Pika' "$BODY" \
	&& ! grep -qiE 'toggleFeed|id="feed|feed-summary-|feed-content-' "$BODY"; then
	ok "the home page carries no feed markup and no toggleFeed handler"
else
	bad "the home page still carries the feed markup"
fi
if grep -q 'Learn to Use Pika' "$BODY" \
	&& ! grep -qiE 'Fatal error|Warning:|Notice:|pikaRssFeed|rss_feeds' "$BODY"; then
	ok "removing the reader left no warning or undefined reference behind"
else
	bad "the home page reports an error after the feed removal"
fi

# 3. The mobile home page too. It built the same markup from the same feeds.
code="$(curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" -w '%{http_code}' \
	"$OCM_URL/m/index.php")"
if [ "$code" = 200 ] \
	&& ! grep -qiE 'Fatal error|Warning:|Notice:|pikaRssFeed|toggleFeed' "$BODY"; then
	ok "the mobile home page draws with no feed code left in it"
else
	bad "the mobile home page answered $code or still names the feed reader"
fi

# 4. No page advertises a feed of OCM's own data. cases-rss.php never existed
#    in this tree, so case_list.php was advertising a 404 as well.
for rss_page in "cal_day.php?user_id=1" "case_list.php?mode=open" "m/case_list_mobile.php?mode=open"; do
	code="$(curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" -w '%{http_code}' \
		"$OCM_URL/${rss_page}")"
	if [ "$code" = 200 ] && ! grep -qiE 'application/rss\+xml|cal-rss\.php|cases-rss\.php' "$BODY"; then
		ok "${rss_page%%\?*} advertises no RSS feed"
	else
		bad "${rss_page%%\?*} answered $code or still advertises a feed"
	fi
done

# 5. The site map no longer offers the admin page.
code="$(curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" -w '%{http_code}' \
	"$OCM_URL/site_map.php")"
if [ "$code" = 200 ] && grep -qi 'Site Map' "$BODY" \
	&& ! grep -qiE 'system-feeds\.php|>RSS Feeds<' "$BODY"; then
	ok "the site map does not link the removed admin page"
else
	bad "the site map answered $code or still links RSS Feeds"
fi

# 6. The preference control is gone and its <head> slot is not left unresolved.
code="$(curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" -w '%{http_code}' \
	"$OCM_URL/prefs.php")"
if [ "$code" = 200 ] && grep -qi 'Case List Length' "$BODY" \
	&& ! grep -qiE 'RSS Interval|def_rss_interval' "$BODY"; then
	ok "the preferences form offers no RSS interval"
else
	bad "prefs.php answered $code or still offers the RSS interval"
fi
if ! grep -qF '%%[rss]%%' "$BODY" && ! grep -qF '%%[head_extra]%%' "$BODY"; then
	ok "the renamed <head> slot resolves on a page that does not set it"
else
	bad "an unresolved template tag reached the page"
fi

if [ "$HAVE_DB" = 1 ]; then
	# 7. The table and its counter row are dropped on an upgraded install.
	if [ -z "$(adb "SHOW TABLES LIKE 'rss_feeds'")" ]; then
		ok "the rss_feeds table is dropped"
	else
		bad "the rss_feeds table is still present"
	fi
	if [ "$(adb "SELECT COUNT(*) FROM counters WHERE id = 'rss_feeds'")" = 0 ]; then
		ok "the rss_feeds counter row is dropped"
	else
		bad "the rss_feeds counter row survives"
	fi
else
	printf '  skip the rss_feeds schema checks (needs the database)\n'
fi

echo
echo "58. the case page hardening pass"
# ── 58. The case page hardening pass ───────────────────────────────────────
# cms/case.php did four things wrong at once, all four checked here against a
# throwaway group, user, case and pair of contacts.
#
#  a) Contact rows went to the page unescaped. $case_row was cleaned with
#     pl_clean_html_array() but the per-contact $row in the contact loop was
#     not, and every contact that is not the primary client renders through
#     the 'contacts' subtemplate from that raw row. A name written by the
#     LSXML transfer endpoint or an import tool became markup on the case page.
#  b) The `screen` parameter reached file_exists() and the page body after only
#     pl_clean_file_name(), which strips `;`, `/` and `..` and nothing else. A
#     NUL byte and a double quote both went through into the output and into
#     the include path construction. It is now held to [A-Za-z0-9_-].
#  c) The read_case gate ran at line 122, after the block at lines 54-95 had
#     already loaded the primary contact, taken a client data snapshot and
#     called $case1->save() to write cases.client_age. A user who was refused
#     the case still wrote to its row. The gate now runs immediately after the
#     case record is read.
#  d) screen=confirm_delete opened the delete confirmation to anybody who
#     could read the case. ops/delete_case.php checks delete_case, which is
#     system-group only, so the screen was offering an action the handler
#     would refuse. The screen now checks the same permission.
if [ "$HAVE_DB" = 1 ] && [ "$HAVE_COMPOSE" = 1 ]; then
	CPGROUP='zz_cp_grp'
	CPUSER='zz_cp_user'
	CPPASS='zz-cp-Passw0rd'
	CPJAR="$(mktemp)"
	CPXSS='ZZCP<img src=x onerror=zzcpx>'

	cleanup_cp() {
		adb "DELETE FROM conflict WHERE contact_id IN
			(SELECT contact_id FROM contacts WHERE last_name IN ('ZZCPCLIENT', '${CPXSS}'))" >/dev/null
		adb "DELETE FROM cases WHERE number IN ('ZZ-CP-DENY', 'ZZ-CP-READ')" >/dev/null
		adb "DELETE FROM contacts WHERE last_name IN ('ZZCPCLIENT', '${CPXSS}')" >/dev/null
		adb "DELETE FROM users WHERE username = '${CPUSER}'" >/dev/null
		adb "DELETE FROM \`groups\` WHERE group_id = '${CPGROUP}'" >/dev/null
		rm -f "$CPJAR"
	}
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_cp' EXIT
	cleanup_cp

	# Same id rule as section 28: take the higher of MAX() and the counters
	# row so a fixture never sits on a key plBase::getNextID is about to hand
	# out, and move the counter up behind it.
	cp_next_id() {
		adb "SELECT GREATEST(
			COALESCE((SELECT MAX(${2}) FROM \`${1}\`), 0),
			COALESCE((SELECT count FROM counters WHERE id = '${1}'), 0)) + 1"
	}
	cp_bump_counter() {
		adb "UPDATE counters SET count = GREATEST(count, ${2}) WHERE id = '${1}'" >/dev/null
	}

	# read_all starts at 1 so the user can reach the case at all. It is not
	# the `system` group, so pika_authorize() refuses delete_case -- that is
	# the whole point of check (d). read_all is flipped off for check (c).
	adb "INSERT INTO \`groups\` (group_id, read_office, read_all, edit_office, edit_all, users, pba, motd, intake, reports)
		VALUES ('${CPGROUP}', NULL, 1, NULL, 0, 0, 0, 0, 0, NULL)" >/dev/null

	CPHASH="$(docker compose "${COMPOSE_ARGS[@]}" exec -T app \
		php -r 'echo password_hash($argv[1], PASSWORD_DEFAULT);' "$CPPASS" </dev/null 2>/dev/null)"
	CPUID="$(cp_next_id users user_id)"
	adb "INSERT INTO users (user_id, username, password, enabled, group_id, password_expire)
		VALUES (${CPUID}, '${CPUSER}', '${CPHASH}', 1, '${CPGROUP}', 0)" >/dev/null
	cp_bump_counter users "$CPUID"

	# The primary client, with a birth date and an open date so that the
	# client_age calculation in the pre-gate block has something to write.
	CPCLIENT="$(cp_next_id contacts contact_id)"
	adb "INSERT INTO contacts (contact_id, first_name, last_name, birth_date)
		VALUES (${CPCLIENT}, 'Zz', 'ZZCPCLIENT', '1990-01-01')" >/dev/null
	cp_bump_counter contacts "$CPCLIENT"

	# The opposing party, whose last name is markup. relation_code 2 keeps it
	# out of the 'client' branch, so it renders from the raw contact row.
	CPOPP="$(cp_next_id contacts contact_id)"
	adb "INSERT INTO contacts (contact_id, first_name, last_name)
		VALUES (${CPOPP}, 'Zz', '${CPXSS}')" >/dev/null
	cp_bump_counter contacts "$CPOPP"

	# Two cases: one for the refused-write check, one for everything else.
	CPDENY="$(cp_next_id cases case_id)"
	adb "INSERT INTO cases (case_id, number, user_id, office, status, client_id, open_date, client_age)
		VALUES (${CPDENY}, 'ZZ-CP-DENY', 1, 'ZZCPOFF', '1', ${CPCLIENT}, '2020-01-01', NULL)" >/dev/null
	cp_bump_counter cases "$CPDENY"
	CPREAD="$(cp_next_id cases case_id)"
	adb "INSERT INTO cases (case_id, number, user_id, office, status, client_id, open_date)
		VALUES (${CPREAD}, 'ZZ-CP-READ', 1, 'ZZCPOFF', '1', ${CPCLIENT}, '2020-01-01')" >/dev/null
	cp_bump_counter cases "$CPREAD"

	CPCONF="$(cp_next_id conflict conflict_id)"
	adb "INSERT INTO conflict (conflict_id, case_id, contact_id, relation_code)
		VALUES (${CPCONF}, ${CPREAD}, ${CPCLIENT}, 1)" >/dev/null
	cp_bump_counter conflict "$CPCONF"
	CPCONF2="$(cp_next_id conflict conflict_id)"
	adb "INSERT INTO conflict (conflict_id, case_id, contact_id, relation_code)
		VALUES (${CPCONF2}, ${CPREAD}, ${CPOPP}, 2)" >/dev/null
	cp_bump_counter conflict "$CPCONF2"

	cp_login() {
		: > "$CPJAR"
		curl -sL --max-time 30 -c "$CPJAR" -b "$CPJAR" -o /dev/null \
			-X POST -d "login_user=${CPUSER}&login_pass=${CPPASS}&auth_id=1" \
			"$OCM_URL/" >/dev/null
	}

	if [ -z "$CPHASH" ] || [ -z "${CPREAD:-}" ] || [ -z "${CPDENY:-}" ]; then
		bad "could not seed the case page fixtures (hash/cases/contacts)"
	else
		cp_login
		curl -sL --max-time 30 -b "$CPJAR" -o "$BODY" \
			"$OCM_URL/case.php?case_id=${CPREAD}" >/dev/null

		if grep -q 'ZZ-CP-READ' "$BODY"; then
			ok "the throwaway read_all user can open the seeded case"
		else
			bad "the throwaway user could not open the seeded case - most of section 58 is untested"
		fi

		# 58a. The opposing party's name must arrive escaped, not as a tag.
		if grep -qF 'ZZCP<img src=x onerror=zzcpx>' "$BODY"; then
			bad "A CONTACT NAME RENDERS AS LIVE MARKUP ON THE CASE PAGE (CWE-79, stored)"
		elif grep -qF 'ZZCP&lt;img src=x onerror=zzcpx&gt;' "$BODY"; then
			ok "a contact name holding markup is escaped on the case page"
		else
			bad "the seeded opposing party did not render at all ($(wc -c < "$BODY") bytes)"
		fi

		# 58b. `screen` is held to [A-Za-z0-9_-]. A NUL byte used to reach
		# both file_exists() and the response body; a double quote was
		# echoed back raw. Neither is a proven injection on its own, which is
		# why this checks the bytes rather than an exploit.
		curl -sL --max-time 30 -b "$CPJAR" -o "$BODY" \
			"$OCM_URL/case.php?case_id=${CPREAD}&screen=act%00x" >/dev/null
		if [ "$(tr -dc '\000' < "$BODY" | wc -c)" -eq 0 ]; then
			ok "a NUL byte in screen= does not reach the page"
		else
			bad "A NUL BYTE IN screen= IS REFLECTED INTO THE PAGE AND INTO file_exists()"
		fi

		curl -sL --max-time 30 -b "$CPJAR" -o "$BODY" \
			"$OCM_URL/case.php?case_id=${CPREAD}&screen=a%22b" >/dev/null
		if grep -qF 'screen mode (a"b)' "$BODY"; then
			bad "A RAW DOUBLE QUOTE IN screen= IS ECHOED BACK UNESCAPED"
		else
			ok "a double quote in screen= is not echoed back raw"
		fi

		# A valid screen name still has to work, or the allowlist is just an
		# outage. The activity tab is the page default.
		curl -sL --max-time 30 -b "$CPJAR" -o "$BODY" \
			"$OCM_URL/case.php?case_id=${CPREAD}&screen=act" >/dev/null
		if grep -q 'Invalid screen mode' "$BODY"; then
			bad "the screen allowlist refuses the stock 'act' tab"
		else
			ok "the stock 'act' screen still loads through the allowlist"
		fi

		# 58d. confirm_delete is offered only to a group that can delete.
		CPCODE="$(curl -sL --max-time 30 -b "$CPJAR" -o "$BODY" -w '%{http_code}' \
			"$OCM_URL/case.php?case_id=${CPREAD}&screen=confirm_delete")"
		if [ "$CPCODE" = 403 ] && grep -qE '(permission|authorized) to delete this case' "$BODY"; then
			ok "the delete confirmation screen refuses a user without delete_case"
		elif grep -q 'ops/delete_case.php' "$BODY"; then
			bad "THE DELETE CONFIRMATION SCREEN OPENS TO ANY USER WHO CAN READ THE CASE"
		else
			bad "case.php gave neither the delete form nor the refusal ($(wc -c < "$BODY") bytes)"
		fi

		# The same request as the system group has to still reach the form,
		# or the gate is refusing everybody. $COOKIES is the admin session.
		curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" \
			"$OCM_URL/case.php?case_id=${CPREAD}&screen=confirm_delete" >/dev/null
		if grep -q 'ops/delete_case.php' "$BODY"; then
			ok "the system group still reaches the delete confirmation form"
		else
			bad "the delete gate refuses the system group too"
		fi

		# 58c. Drop read_all and the case becomes unreadable. The refused
		# request must not write cases.client_age.
		adb "UPDATE \`groups\` SET read_all = 0 WHERE group_id = '${CPGROUP}'" >/dev/null
		adb "UPDATE cases SET client_age = NULL WHERE case_id = ${CPDENY}" >/dev/null
		cp_login
		curl -sL --max-time 30 -b "$CPJAR" -o "$BODY" \
			"$OCM_URL/case.php?case_id=${CPDENY}" >/dev/null

		if grep -q 'This case is not viewable' "$BODY"; then
			ok "the case is refused once read_all is dropped"
		else
			bad "the case was not refused after dropping read_all - 58c is untested"
		fi

		CPAGE="$(adb "SELECT COALESCE(client_age, 'NULL') FROM cases WHERE case_id = ${CPDENY}")"
		if [ "$CPAGE" = 'NULL' ]; then
			ok "a refused case page does not write cases.client_age"
		else
			bad "A REFUSED CASE PAGE STILL WROTE cases.client_age (${CPAGE}) - the authz gate runs too late"
		fi

		# And the write must still happen for a user who is allowed in, or
		# the gate has broken the feature it was placed in front of.
		adb "UPDATE \`groups\` SET read_all = 1 WHERE group_id = '${CPGROUP}'" >/dev/null
		adb "UPDATE cases SET client_age = NULL WHERE case_id = ${CPDENY}" >/dev/null
		cp_login
		curl -sL --max-time 30 -b "$CPJAR" -o "$BODY" \
			"$OCM_URL/case.php?case_id=${CPDENY}" >/dev/null
		CPAGE2="$(adb "SELECT COALESCE(client_age, 'NULL') FROM cases WHERE case_id = ${CPDENY}")"
		if [ "$CPAGE2" != 'NULL' ] && [ "$CPAGE2" -gt 0 ] 2>/dev/null; then
			ok "an authorized case page still writes cases.client_age (${CPAGE2})"
		else
			bad "an authorized case page no longer writes cases.client_age (got '${CPAGE2}')"
		fi

		# case_id is validated as a positive integer now. A non-numeric one
		# redirects rather than building a query out of it.
		CPCODE="$(curl -s --max-time 30 -b "$CPJAR" -o /dev/null -w '%{http_code}' \
			"$OCM_URL/case.php?case_id=abc")"
		if [ "$CPCODE" = '302' ]; then
			ok "a non-numeric case_id redirects instead of loading a case"
		else
			bad "case.php?case_id=abc answered ${CPCODE}, not a redirect"
		fi
	fi

	cleanup_cp
	trap 'rm -f "$COOKIES" "$BODY"' EXIT
else
	printf '  skip the case page hardening checks (needs the database and compose)\n'
fi


echo
echo "59. case_contact.php authorization and case_id validation"
# ── 59. case_contact.php authorization and case_id validation ──────────────
# case_contact.php had no case_id validation and no authorization check of any
# kind, and pikaMisc::htmlContactList('case_contact') does not merely read:
# it builds a pikaCase out of the query string and calls
# resetConflictStatus(false), which ends in $this->save().
#
#  a) With a case_id the caller could not read, the request wrote
#     cases.poten_conflicts on that case.
#  b) With no case_id at all, `new pikaCase(null)` is a NEW record, so the
#     save INSERTed a case row -- and plBase::getNextID() had already taken the
#     next case number out of `counters` to build it, so every hit also
#     consumed a case number from the organisation's numbering sequence.
#
# The page now validates case_id as a positive integer and authorizes
# edit_case, which is what ops/add_case_contact.php -- the handler behind this
# form -- already checks.
if [ "$HAVE_DB" = 1 ] && [ "$HAVE_COMPOSE" = 1 ]; then
	KCGROUP='zz_kc_grp'
	KCUSER='zz_kc_user'
	KCPASS='zz-kc-Passw0rd'
	KCJAR="$(mktemp)"

	cleanup_kc() {
		adb "DELETE FROM conflict WHERE contact_id IN
			(SELECT contact_id FROM contacts WHERE last_name = 'ZZKCCONTACT')" >/dev/null
		adb "DELETE FROM contacts WHERE last_name = 'ZZKCCONTACT'" >/dev/null
		adb "DELETE FROM cases WHERE number = 'ZZ-KC-1'" >/dev/null
		adb "DELETE FROM users WHERE username = '${KCUSER}'" >/dev/null
		adb "DELETE FROM \`groups\` WHERE group_id = '${KCGROUP}'" >/dev/null
		rm -f "$KCJAR"
	}
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_kc' EXIT
	cleanup_kc

	kc_next_id() {
		adb "SELECT GREATEST(
			COALESCE((SELECT MAX(${2}) FROM \`${1}\`), 0),
			COALESCE((SELECT count FROM counters WHERE id = '${1}'), 0)) + 1"
	}
	kc_bump_counter() {
		adb "UPDATE counters SET count = GREATEST(count, ${2}) WHERE id = '${1}'" >/dev/null
	}

	# A group with nothing at all, and a case with a handler and an office so
	# that neither the intake branch nor read_office can reach it.
	adb "INSERT INTO \`groups\` (group_id, read_office, read_all, edit_office, edit_all, users, pba, motd, intake, reports)
		VALUES ('${KCGROUP}', NULL, 0, NULL, 0, 0, 0, 0, 0, NULL)" >/dev/null

	KCHASH="$(docker compose "${COMPOSE_ARGS[@]}" exec -T app \
		php -r 'echo password_hash($argv[1], PASSWORD_DEFAULT);' "$KCPASS" </dev/null 2>/dev/null)"
	KCUID="$(kc_next_id users user_id)"
	adb "INSERT INTO users (user_id, username, password, enabled, group_id, password_expire)
		VALUES (${KCUID}, '${KCUSER}', '${KCHASH}', 1, '${KCGROUP}', 0)" >/dev/null
	kc_bump_counter users "$KCUID"

	KCCASE="$(kc_next_id cases case_id)"
	adb "INSERT INTO cases (case_id, number, user_id, office, status, poten_conflicts)
		VALUES (${KCCASE}, 'ZZ-KC-1', 1, 'ZZKCOFF', '1', 0)" >/dev/null
	kc_bump_counter cases "$KCCASE"

	# One contact on two roles on the same case, so fuzzyConflictCheck finds a
	# potential conflict and resetConflictStatus() actually has a value to
	# write. Without this the flag would stay 0 for the harmless reason.
	KCCON="$(kc_next_id contacts contact_id)"
	adb "INSERT INTO contacts (contact_id, first_name, last_name)
		VALUES (${KCCON}, 'Zz', 'ZZKCCONTACT')" >/dev/null
	kc_bump_counter contacts "$KCCON"
	KCK1="$(kc_next_id conflict conflict_id)"
	adb "INSERT INTO conflict (conflict_id, case_id, contact_id, relation_code)
		VALUES (${KCK1}, ${KCCASE}, ${KCCON}, 1)" >/dev/null
	kc_bump_counter conflict "$KCK1"
	KCK2="$(kc_next_id conflict conflict_id)"
	adb "INSERT INTO conflict (conflict_id, case_id, contact_id, relation_code)
		VALUES (${KCK2}, ${KCCASE}, ${KCCON}, 2)" >/dev/null
	kc_bump_counter conflict "$KCK2"

	if [ -z "$KCHASH" ] || [ -z "${KCCASE:-}" ]; then
		bad "could not seed the case_contact fixtures (hash/case/contact)"
	else
		: > "$KCJAR"
		curl -sL --max-time 30 -c "$KCJAR" -b "$KCJAR" -o "$BODY" \
			-X POST -d "login_user=${KCUSER}&login_pass=${KCPASS}&auth_id=1" \
			"$OCM_URL/" >/dev/null
		if grep -q 'login_pass' "$BODY"; then
			bad "the throwaway case_contact user could not log in - section 59 is untested"
		else
			ok "the throwaway no-permission user can log in"

			# The case has to be out of reach, or 59a proves nothing.
			curl -sL --max-time 30 -b "$KCJAR" -o "$BODY" \
				"$OCM_URL/case.php?case_id=${KCCASE}" >/dev/null
			if grep -q 'This case is not viewable' "$BODY"; then
				ok "the seeded case is out of the throwaway user's reach"
			else
				bad "the seeded case is readable by the throwaway user - 59a proves nothing"
			fi

			# 59a. The refused request must not write to the case row.
			adb "UPDATE cases SET poten_conflicts = 0 WHERE case_id = ${KCCASE}" >/dev/null
			curl -sL --max-time 30 -b "$KCJAR" -o "$BODY" \
				"$OCM_URL/case_contact.php?case_id=${KCCASE}" >/dev/null

			if grep -q 'This case is not viewable' "$BODY"; then
				ok "case_contact.php refuses a case the user cannot edit"
			else
				bad "CASE_CONTACT.PHP HAS NO AUTHORIZATION CHECK (CWE-862)"
			fi

			KCFLAG="$(adb "SELECT COALESCE(poten_conflicts, 'NULL') FROM cases WHERE case_id = ${KCCASE}")"
			if [ "$KCFLAG" = '0' ]; then
				ok "the refused request did not write cases.poten_conflicts"
			else
				bad "A REFUSED case_contact.php REQUEST WROTE cases.poten_conflicts (${KCFLAG})"
			fi

			# 59b. No case_id must not create a case, and must not burn a case
			# number out of the counters table.
			KCBEFORE="$(adb "SELECT COUNT(*) FROM cases")"
			KCCOUNTER="$(adb "SELECT COALESCE(count, 0) FROM counters WHERE id = 'cases'")"
			KCCODE="$(curl -s --max-time 30 -b "$KCJAR" -o /dev/null -w '%{http_code}' \
				"$OCM_URL/case_contact.php")"
			KCAFTER="$(adb "SELECT COUNT(*) FROM cases")"
			KCCOUNTER2="$(adb "SELECT COALESCE(count, 0) FROM counters WHERE id = 'cases'")"

			if [ "$KCCODE" = '302' ]; then
				ok "case_contact.php with no case_id redirects"
			else
				bad "case_contact.php with no case_id answered ${KCCODE}, not a redirect"
			fi

			if [ "$KCBEFORE" = "$KCAFTER" ]; then
				ok "case_contact.php with no case_id does not create a case row"
			else
				bad "CASE_CONTACT.PHP WITH NO case_id CREATED A CASE (${KCBEFORE} -> ${KCAFTER})"
			fi

			if [ "$KCCOUNTER" = "$KCCOUNTER2" ]; then
				ok "case_contact.php with no case_id does not consume a case number"
			else
				bad "CASE_CONTACT.PHP CONSUMED A CASE NUMBER (counters.cases ${KCCOUNTER} -> ${KCCOUNTER2})"
			fi

			# 59c. The page still works for a user who may edit the case, or
			# the gate has replaced a vulnerability with an outage. $COOKIES
			# is the admin session, which is in the `system` group.
			KCCODE="$(curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" -w '%{http_code}' \
				"$OCM_URL/case_contact.php?case_id=${KCCASE}")"
			if [ "$KCCODE" = '200' ] && ! grep -q 'This case is not viewable' "$BODY" \
				&& grep -q 'case_contact.php' "$BODY"; then
				ok "an authorized user still gets the add-contact form"
			else
				bad "the authorized add-contact form is broken (${KCCODE}, $(wc -c < "$BODY") bytes)"
			fi

			# And the write it is supposed to do still happens for that user.
			KCFLAG="$(adb "SELECT COALESCE(poten_conflicts, 'NULL') FROM cases WHERE case_id = ${KCCASE}")"
			if [ "$KCFLAG" = '1' ]; then
				ok "an authorized request still sets cases.poten_conflicts"
			else
				bad "an authorized request no longer sets cases.poten_conflicts (got '${KCFLAG}')"
			fi

			# A non-numeric case_id must not reach `new pikaCase()` either.
			KCCODE="$(curl -s --max-time 30 -b "$COOKIES" -o /dev/null -w '%{http_code}' \
				"$OCM_URL/case_contact.php?case_id=abc")"
			if [ "$KCCODE" = '302' ]; then
				ok "a non-numeric case_id redirects instead of building a case"
			else
				bad "case_contact.php?case_id=abc answered ${KCCODE}, not a redirect"
			fi
		fi
	fi

	cleanup_kc
	trap 'rm -f "$COOKIES" "$BODY"' EXIT
else
	printf '  skip the case_contact authorization checks (needs the database and compose)\n'
fi


echo
echo "62. the extension allowlist on pm.php"

# ── 62. pm.php: which extension directories may run ─────────────────────────
#
# pm.php builds a require() target out of the request path. The reports branch
# checks the requested directory against the enabled names with in_array();
# the other branch asked
#
#     strpos(pl_settings_get('extensions'), $filepath) === false
#
# which is whether the name appears ANYWHERE in the setting, not whether it is
# one of the names in it. So any substring of the setting ran -- with
# 'extensions' set to '/project', cms-custom/extensions/pro was reachable, and a
# directory named after two enabled extensions joined by the ':' that separates
# them was reachable too.
#
# ops/update_extensions.php writes the setting as the ticked names joined with
# ':', each carrying the leading '/' the folder scan gave it, so '/a:/b' is the
# shape stored. pl_enabled_extensions() in app/lib/pl.php is the one reader.
if [ "$HAVE_DB" = 1 ] && [ "$HAVE_COMPOSE" = 1 ]; then
	# 'zzpmext' and 'zzpmb' are enabled. 'zzpm' is a substring of the setting
	# and is NOT enabled; neither is 'zzpmext:zzpmb', which spans the ':' that
	# separates the two entries and so sits inside the setting string.
	#
	# The stored value carries a space after the separator on purpose. An
	# administrator never types this setting by hand, but a value edited in
	# the settings page can pick one up, and a name must still match with it
	# there.
	PMEXT='zzpmext'
	PMSUB='zzpm'
	PMSECOND='zzpmb'
	PMSPAN='zzpmext:zzpmb'
	PMSETTING='/zzpmext: /zzpmb'
	PMROOT='/var/www/html/cms-custom/extensions'

	cleanup_pm() {
		docker compose "${COMPOSE_ARGS[@]}" exec -T app \
			sh -c "rm -rf ${PMROOT}/${PMEXT} ${PMROOT}/${PMSUB} ${PMROOT}/${PMSECOND} '${PMROOT}/${PMSPAN}'" </dev/null >/dev/null 2>&1
		adb "DELETE FROM settings WHERE label = 'extensions'" >/dev/null
		if [ -n "${PMSAVED:-}" ]; then
			adb "INSERT INTO settings (label, value) VALUES ('extensions', '${PMSAVED}')" >/dev/null
		fi
	}
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_pm' EXIT

	PMSAVED="$(adb "SELECT value FROM settings WHERE label = 'extensions'")"
	cleanup_pm

	adb "DELETE FROM settings WHERE label = 'extensions'" >/dev/null
	adb "INSERT INTO settings (label, value) VALUES ('extensions', '${PMSETTING}')" >/dev/null

	# Four plants: both enabled extensions, a directory whose name is a
	# substring of the setting, and a directory whose name spans the ':' that
	# separates the two entries.
	docker compose "${COMPOSE_ARGS[@]}" exec -T app sh -c "
		mkdir -p ${PMROOT}/${PMEXT} ${PMROOT}/${PMSUB} ${PMROOT}/${PMSECOND} '${PMROOT}/${PMSPAN}' &&
		printf '<?php echo \"ZZPM-ENABLED-RAN\";'  > ${PMROOT}/${PMEXT}/ok.php &&
		printf '<?php echo \"ZZPM-SECOND-RAN\";'   > ${PMROOT}/${PMSECOND}/ok.php &&
		printf '<?php echo \"ZZPM-SUBSTRING-RAN\";' > ${PMROOT}/${PMSUB}/ok.php &&
		printf '<?php echo \"ZZPM-SPAN-RAN\";'     > '${PMROOT}/${PMSPAN}/ok.php' &&
		printf 'not php'                           > ${PMROOT}/${PMEXT}/ok.txt
	" </dev/null >/dev/null 2>&1

	pm_get() {
		curl -sL --max-time 30 -b "$COOKIES" "$OCM_URL/pm.php${1}" 2>/dev/null \
			| grep -o 'ZZPM-[A-Z-]*' | head -1
	}

	# 62a. Control: the enabled extension still runs, on both branches.
	if [ "$(pm_get "/${PMEXT}/ok.php")" = "ZZPM-ENABLED-RAN" ]; then
		ok "an enabled extension still runs"
	else
		bad "an enabled extension no longer runs — the allowlist is too strict"
	fi

	if [ "$(pm_get "/reports/${PMEXT}/ok.php")" = "ZZPM-ENABLED-RAN" ]; then
		ok "an enabled extension still runs through the reports branch"
	else
		bad "the reports branch no longer runs an enabled extension"
	fi

	# 62b. The bug: a directory the operator did not enable, whose name happens
	# to sit inside the setting string.
	if [ -z "$(pm_get "/${PMSUB}/ok.php")" ]; then
		ok "a directory that is only a substring of the setting is refused"
	else
		bad "AN EXTENSION THAT IS NOT ENABLED RAN — its name is a substring of the setting (CWE-98)"
	fi

	# 62c. And the same name through the branch that was already correct, so
	# the two branches are shown to agree.
	if [ -z "$(pm_get "/reports/${PMSUB}/ok.php")" ]; then
		ok "the reports branch refuses the same substring name"
	else
		bad "the reports branch ran an extension that is not enabled"
	fi

	# 62d. The other reachable shape of the same bug: a directory whose name
	# spans the separator between two entries. It is inside the setting
	# string, so strpos() accepted it, but it is not one of the names the
	# setting lists.
	if [ -z "$(pm_get "/zzpmext%3Azzpmb/ok.php")" ]; then
		ok "a directory named across the setting's separator is refused"
	else
		bad "AN EXTENSION THAT IS NOT ENABLED RAN — its name spans the separator in the setting (CWE-98)"
	fi

	# 62e. Control: the setting is a ':' list, and a space left after the
	# separator must not stop the second name matching.
	if [ "$(pm_get "/${PMSECOND}/ok.php")" = "ZZPM-SECOND-RAN" ]; then
		ok "the second name in the list still runs, despite the space"
	else
		bad "a list entry with a leading space no longer runs"
	fi

	# 62f. Control on the other rule in this file: the target must be PHP.
	if [ -z "$(pm_get "/${PMEXT}/ok.txt")" ]; then
		ok "a target that is not a .php file is refused"
	else
		bad "a non-.php target was included"
	fi

	cleanup_pm
	trap 'rm -f "$COOKIES" "$BODY"' EXIT
else
	printf '  skip the pm.php allowlist checks (needs the database and compose)\n'
fi

# ── 29. Case tabs, the id counter, transfers and duplicate matching ────────
echo
echo "29. case tabs, the id counter and duplicate matching"

if [ "$HAVE_DB" = 1 ]; then
	cleanup_ct() {
		adb "DELETE FROM case_tabs WHERE name LIKE 'ZZCT%' OR name LIKE '%zzctxss%'" >/dev/null
		adb "DELETE FROM case_tabs WHERE tab_id = 120" >/dev/null
		# case_tabs.tab_id is a tinyint, so the highest id an install can hold
		# is 127. A run that is interrupted between the add checks and this
		# cleanup leaves a tab behind, and a blank row takes the column
		# default name, so it does not match the ZZCT prefix above. Left
		# alone those rows climb towards 127, and once MAX(tab_id) reaches it
		# the counter repair below allocates 128, the column clamps that back
		# to 127 and every add dies on a duplicate key.
		adb "DELETE FROM case_tabs WHERE tab_id > 100 AND (file IS NULL OR name = 'New Tab')" >/dev/null
		# Put the id counter back level with the rows. The counter check
		# further down sets it to 1 itself, so this hides nothing; it only
		# stops one run's leftovers from deciding what the next run allocates.
		adb "UPDATE counters SET count = (SELECT COALESCE(MAX(tab_id), 0) FROM case_tabs)
			WHERE id = 'case_tabs'" >/dev/null
		adb "DELETE FROM aliases WHERE last_name LIKE 'ZZCT%' OR first_name = 'ZZCTBLANK'" >/dev/null
		adb "DELETE FROM contacts WHERE last_name LIKE 'ZZCT%' OR notes = 'ZZCTFIXTURE'" >/dev/null
	}
	cleanup_ct

	# A tab module that is actually installed, so the allowlist accepts it.
	CTFILE="$(basename "$(ls "${REPO_DIR}"/cms/modules/case-*.php 2>/dev/null | head -1)")"

	if [ -z "$CTFILE" ]; then
		printf '  skip the case tab checks (no case-*.php modules found)\n'
	else
		# ── The add form must not write a row just for being looked at ──
		# It used to: the edit branch save()d a brand new object on every GET
		# of "Add New Case Tab", which left blank tabs in the list and failed
		# outright wherever the counters row had fallen behind MAX(tab_id).
		CTBEFORE="$(adb "SELECT COUNT(*) FROM case_tabs")"
		curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" \
			"$OCM_URL/system-case_tabs.php?action=edit" >/dev/null
		CTAFTER="$(adb "SELECT COUNT(*) FROM case_tabs")"
		if [ "${CTBEFORE:-0}" = "${CTAFTER:-1}" ]; then
			ok "opening the Add New Case Tab form writes no row"
		else
			bad "opening the Add New Case Tab form INSERTed a row (${CTBEFORE} -> ${CTAFTER})"
		fi

		if grep -qE 'name="action"[^>]*value="add"' "$BODY"; then
			ok "the empty form submits the add action"
		else
			bad "the empty form does not submit action=add - the new tab has no write path"
		fi

		if grep -qE 'name="tab_id"[^>]*value=""' "$BODY"; then
			ok "the empty form carries no tab_id"
		else
			bad "the empty form carries a tab_id for a row that does not exist"
		fi

		# ── The add action writes exactly one row ──
		curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" \
			"$OCM_URL/system-case_tabs.php?action=add&name=ZZCTTAB&file=${CTFILE}&enabled=1&tab_row=1&autosave=0" >/dev/null
		if [ "$(adb "SELECT COUNT(*) FROM case_tabs WHERE name='ZZCTTAB'")" = 1 ]; then
			ok "the add action writes the new case tab once"
		else
			bad "the add action did not write the new case tab"
		fi

		# ── A tab file that is not installed is refused ──
		# The value goes into a link and into a JavaScript string on every
		# case screen, and a tab pointing at a missing module is a dead link.
		curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" \
			"$OCM_URL/system-case_tabs.php?action=add&name=ZZCTBADFILE&file=case-zz-not-installed.php&enabled=1&tab_row=1" >/dev/null
		if [ "$(adb "SELECT COUNT(*) FROM case_tabs WHERE name='ZZCTBADFILE'")" = 0 ]; then
			ok "a case tab file that is not installed is refused"
		else
			bad "a case tab was saved pointing at a module that is not installed"
		fi

		# ── An update naming no existing row writes nothing ──
		# plBase reads a missing id as "new record", so this used to INSERT.
		curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" \
			"$OCM_URL/system-case_tabs.php?action=update&tab_id=126&name=ZZCTGHOST&file=${CTFILE}&enabled=1&tab_row=1" >/dev/null
		if [ "$(adb "SELECT COUNT(*) FROM case_tabs WHERE name='ZZCTGHOST'")" = 0 ]; then
			ok "an update naming a case tab that is not there writes nothing"
		else
			bad "an update with an unknown tab_id INSERTed a new row"
		fi

		# ── A counter behind the rows still allocates a usable id ──
		# This is the shape a restored dump leaves behind: counters.count
		# lower than MAX(tab_id), so every INSERT dies on a duplicate key and
		# the page comes back empty until somebody edits counters by hand.
		CTMAX="$(adb "SELECT MAX(tab_id) FROM case_tabs")"
		adb "INSERT INTO counters (id,count) VALUES ('case_tabs',1) ON DUPLICATE KEY UPDATE count=1" >/dev/null
		curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" \
			"$OCM_URL/system-case_tabs.php?action=add&name=ZZCTCOUNTER&file=${CTFILE}&enabled=1&tab_row=1" >/dev/null
		CTNEW="$(adb "SELECT tab_id FROM case_tabs WHERE name='ZZCTCOUNTER'")"
		if [ -n "$CTNEW" ] && [ "${CTNEW:-0}" -gt "${CTMAX:-0}" ]; then
			ok "a counter behind the rows still allocates an unused id"
		else
			bad "a counter behind MAX(tab_id) blocked the INSERT (max ${CTMAX}, got '${CTNEW}')"
		fi

		# ── The tab name and the tab file reach the case screen escaped ──
		# Both are written straight into the tab bar by
		# template_plugins/case_tabs.php: the name into the link text, the
		# file into the href and into a single-quoted JavaScript string.
		# Write them with SQL, because the admin form escapes < and > on the
		# way in and that would hide the defect being tested for.
		# A case to open. Earlier sections remove their own case fixtures, so
		# there may well be none left by the time this section runs.
		CTCASE=9990001
		adb "INSERT INTO cases (case_id,number,status,problem) VALUES
			(${CTCASE},'ZZCT-0001','1','ZZ')
			ON DUPLICATE KEY UPDATE number='ZZCT-0001'" >/dev/null
		CTFIX=
		if [ "$(adb "SELECT COUNT(*) FROM cases WHERE case_id=${CTCASE}")" != 1 ]; then
			printf '  skip the case tab bar escaping checks (could not write a case)\n'
		else
			# case.php keys the tab list by the file name, so the fixture
			# needs a file of its own or one of the tabs added above wins the
			# key and this proves nothing. tab_id is a tinyint.
			CTFIX=120
			if [ "$(adb "SELECT COUNT(*) FROM case_tabs WHERE tab_id=${CTFIX}")" != 0 ]; then
				CTFIX=
			fi
		fi

		if [ -z "${CTFIX:-}" ]; then
			printf '  skip the case tab bar escaping checks (no fixture slot)\n'
		else
			adb "INSERT INTO case_tabs (tab_id,name,file,enabled,tab_order,autosave,tab_row)
				VALUES (${CTFIX},'<script>zzctxss()</script>','case-zzctfixture.php',1,99,0,1)" >/dev/null
			curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" \
				"$OCM_URL/case.php?case_id=${CTCASE}" >/dev/null
			if grep -q 'zzctxss' "$BODY"; then
				if grep -q '<script>zzctxss' "$BODY"; then
					bad "a case tab name put an unescaped <script> on the case screen"
				else
					ok "a case tab name reaches the case screen escaped"
				fi
			else
				bad "the fixture case tab did not render - the escaping check proved nothing"
			fi

			adb "UPDATE case_tabs SET name='ZZCTJS', file='case-zz\"onmouseover=zzctjs().php' WHERE tab_id=${CTFIX}" >/dev/null
			curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" \
				"$OCM_URL/case.php?case_id=${CTCASE}" >/dev/null
			if grep -q 'zzonmouseoverzzctjs' "$BODY"; then
				if grep -q 'onmouseover=zzctjs' "$BODY"; then
					bad "a case tab file name added its own attribute to the tab link"
				else
					ok "a case tab file name cannot add attributes to the tab link"
				fi
			else
				bad "the fixture tab file did not render - the sanitiser check proved nothing"
			fi
		fi
	fi

	# ── ops/transfer_case.php only answers a POST ──
	# It reads pl_grab_post(), so a GET arrived with no case_id at all and ran
	# the whole transfer against a brand new empty case object.
	CTCASES="$(adb "SELECT COUNT(*) FROM cases")"
	code="$(curl -s --max-time 30 -b "$COOKIES" -o "$BODY" -w '%{http_code}' \
		"$OCM_URL/ops/transfer_case.php")"
	if [ "$code" = 405 ]; then
		ok "a GET of the case transfer handler is refused with 405"
	else
		bad "a GET of the case transfer handler answered $code, not 405"
	fi
	if [ "$(adb "SELECT COUNT(*) FROM cases")" = "$CTCASES" ]; then
		ok "the refused transfer created no case row"
	else
		bad "the refused transfer left a new case row behind"
	fi

	# ── Duplicate matching does not key on a blank or placeholder SSN ──
	# metaphoneContactCheck() searched aliases.ssn = '' for a contact with no
	# name, which matches nearly every contact in the address book, and it
	# treated "XXX-XX-XXXX" as a number, which matches every other record
	# carrying the same placeholder. Both flooded the merge screen with
	# unrelated people.
	adb "INSERT INTO contacts (contact_id,first_name,last_name,ssn,notes) VALUES
		(9990001,'','','','ZZCTFIXTURE'),
		(9990002,'Zz','ZZCTFINDME','','ZZCTFIXTURE'),
		(9990003,'Zz','ZZCTPLACEA','XXX-XX-XXXX','ZZCTFIXTURE'),
		(9990004,'Zz','ZZCTPLACEB','XXX-XX-XXXX','ZZCTFIXTURE')" >/dev/null
	adb "INSERT INTO aliases (alias_id,contact_id,primary_name,first_name,last_name,mp_first,mp_last,ssn) VALUES
		(9990001,9990001,1,'','','','',''),
		(9990002,9990002,1,'Zz','ZZCTFINDME','S','SKTFNTM',''),
		(9990003,9990003,1,'Zz','ZZCTPLACEA','S','SKTPLK','XXX-XX-XXXX'),
		(9990004,9990004,1,'Zz','ZZCTPLACEB','S','SKTPLKB','XXX-XX-XXXX')" >/dev/null

	if [ "$(adb "SELECT COUNT(*) FROM contacts WHERE notes='ZZCTFIXTURE'")" = 4 ]; then
		curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" \
			"$OCM_URL/merge_contacts.php?contact_id=9990001" >/dev/null
		if grep -q 'ZZCTFINDME' "$BODY"; then
			bad "a contact with no name and no SSN was matched against the address book"
		else
			ok "a contact with no name and no SSN matches nothing"
		fi

		curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" \
			"$OCM_URL/merge_contacts.php?contact_id=9990003" >/dev/null
		if grep -q 'ZZCTPLACEB' "$BODY"; then
			bad "a placeholder SSN matched an unrelated contact carrying the same placeholder"
		else
			ok "a placeholder SSN with no digits in it matches nothing"
		fi

		# Positive control: a real number still finds the other record, so
		# the two checks above are not passing because matching is broken.
		adb "UPDATE contacts SET ssn='555-00-9911' WHERE contact_id IN (9990003,9990004)" >/dev/null
		adb "UPDATE aliases SET ssn='555-00-9911' WHERE contact_id IN (9990003,9990004)" >/dev/null
		curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" \
			"$OCM_URL/merge_contacts.php?contact_id=9990003" >/dev/null
		if grep -q 'ZZCTPLACEB' "$BODY"; then
			ok "a real SSN still matches the other record with that number"
		else
			bad "a real SSN no longer matches - the placeholder guard is too tight"
		fi
	else
		printf '  skip the duplicate matching checks (could not write the fixture)\n'
	fi

	cleanup_ct
	adb "DELETE FROM aliases WHERE alias_id BETWEEN 9990001 AND 9990004" >/dev/null
	adb "DELETE FROM contacts WHERE contact_id BETWEEN 9990001 AND 9990004" >/dev/null
	adb "DELETE FROM cases WHERE case_id = 9990001" >/dev/null
else
	printf '  skip the case tab and duplicate matching checks (needs the database)\n'
fi

echo
echo "30. the caseless pop-up timer"

# cms/timer.php supports a timer with no case attached - it prints
# "(No Case #)" for one. pl_clean_form_input() copies only the keys that were
# submitted, so on that path there was no case_id key and both reads of it were
# undefined-key warnings. Nothing about the page changed, so the only way to see
# the fix is in the log.
if [ "$HAVE_COMPOSE" = 1 ]; then
	TIMERLOG="$(mktemp)"
	docker compose "${COMPOSE_ARGS[@]}" logs app >"$TIMERLOG" 2>/dev/null
	timer_log_before="$(wc -l < "$TIMERLOG")"
	
	curl -sL --max-time 30 -b "$COOKIES" -c "$COOKIES" -o "$BODY" "$OCM_URL/timer.php" >/dev/null
	
	if grep -q '(No Case #)' "$BODY"; then
		ok "a timer with no case still draws, labelled (No Case #)"
	else
		bad "the caseless timer did not draw (size $(wc -c < "$BODY"))"
	fi
	
	docker compose "${COMPOSE_ARGS[@]}" logs app >"$TIMERLOG" 2>/dev/null
	timer_new="$(tail -n "+$((timer_log_before + 1))" "$TIMERLOG" \
		| grep -c 'Undefined array key "case_id".*timer\.php' || true)"
	if [ "${timer_new:-0}" -eq 0 ]; then
		ok "the caseless timer logged no undefined case_id key"
	else
		bad "the caseless timer logged ${timer_new} undefined case_id warnings"
	fi
	
	rm -f "$TIMERLOG"
else
	printf '  skip the timer check (needs a running docker compose stack)\n'
fi

echo
echo "31. the conflict of interest check"

# The check reads its values out of the tables, which is not the same thing as
# safe: aliases.ssn is eleven characters of free text an intake user fills in,
# and the social security block put it into two statements as text. It also
# measured strlen($row['ssn'] > 0) instead of the length of the number, threw
# away the statement of each pair that reads the contacts table, and searched
# for an empty metaphone key. Every one of those made the report name people
# who are not conflicts, or miss people who are.
#
# The fixture below is three cases whose parties are arranged so that each
# check fails for exactly one reason. Both copies of the function are
# exercised: cms/app/lib/pikaCase.php through case.php, and
# cms/app/extralib/lib/pikaCms.php through the report under cms/reports/.
if [ "$HAVE_DB" = 1 ]; then
	cleanup_cf() {
		adb "DELETE FROM conflict WHERE case_id BETWEEN 9991001 AND 9991099" >/dev/null
		adb "DELETE FROM aliases WHERE contact_id BETWEEN 9991001 AND 9991099" >/dev/null
		adb "DELETE FROM contacts WHERE contact_id BETWEEN 9991001 AND 9991099" >/dev/null
		adb "DELETE FROM cases WHERE case_id BETWEEN 9991001 AND 9991099" >/dev/null
	}
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_cf' EXIT
	cleanup_cf

	adb "INSERT INTO cases (case_id,number,user_id,office,status,problem) VALUES
		(9991001,'ZZ-CONF-A',1,'ZZOFF','1','ZZ'),
		(9991002,'ZZ-CONF-B',1,'ZZOFF','1','ZZ'),
		(9991003,'ZZ-CONF-C',1,'ZZOFF','1','ZZ'),
		(9991004,'ZZ-CONF-D',1,'ZZOFF','1','ZZ')" >/dev/null

	# ZZCONFONE is two records for the same person, one on case A and one on
	# case D. Contact 9991002, the one on D, deliberately has no aliases row:
	# that is the shape a data migration leaves, and the party read used to
	# reach contacts through aliases, so such a party carried no name and no
	# number into the searches at all. It is alone on a case of its own so that
	# nothing else on that case can report the conflict for it.
	# ZZCONFIVE shares a real number with ZZCONFONE under a different surname,
	# which is what a genuine social security match looks like.
	# ZZCONFTRE and ZZCONFOUR both carry a placeholder in the number column.
	# ZZORGONE and ZZORGTWO are organisations, so they have no metaphone key.
	# ZZCONFTWO's number column holds SQL.
	adb "INSERT INTO contacts (contact_id,first_name,last_name,mp_first,mp_last,ssn,notes) VALUES
		(9991001,'Alpha','ZZCONFONE','ALF','SSKNFN','111223333','ZZCFFIXTURE'),
		(9991002,'Alpha','ZZCONFONE','ALF','SSKNFN','111223333','ZZCFFIXTURE'),
		(9991003,'Beta','ZZCONFTWO','BT','SSKNFT','1'' OR 1=1#','ZZCFFIXTURE'),
		(9991004,'Gamma','ZZCONFTRE','KM','SSKNFTR','XXX-XX-XXXX','ZZCFFIXTURE'),
		(9991005,'Delta','ZZCONFOUR','TLT','SSKNFR','XXX-XX-XXXX','ZZCFFIXTURE'),
		(9991006,'','ZZORGONE','','',NULL,'ZZCFFIXTURE'),
		(9991007,'','ZZORGTWO','','',NULL,'ZZCFFIXTURE'),
		(9991008,'Echo','ZZCONFIVE','AK','SSKNF','111223333','ZZCFFIXTURE')" >/dev/null

	# aliases.alias_id is NOT NULL DEFAULT 0, so a multi-row INSERT has to name
	# every one of them or the second row is a duplicate key.
	adb "INSERT INTO aliases (alias_id,contact_id,primary_name,first_name,last_name,mp_first,mp_last,ssn) VALUES
		(9991001,9991001,1,'Alpha','ZZCONFONE','ALF','SSKNFN','111223333'),
		(9991003,9991003,1,'Beta','ZZCONFTWO','BT','SSKNFT','1'' OR 1=1#'),
		(9991004,9991004,1,'Gamma','ZZCONFTRE','KM','SSKNFTR','XXX-XX-XXXX'),
		(9991005,9991005,1,'Delta','ZZCONFOUR','TLT','SSKNFR','XXX-XX-XXXX'),
		(9991006,9991006,1,'','ZZORGONE','','',NULL),
		(9991007,9991007,1,'','ZZORGTWO','','',NULL),
		(9991008,9991008,1,'Echo','ZZCONFIVE','AK','SSKNF','111223333')" >/dev/null

	# Case A holds relation code 1, cases B, C and D hold 2, so a party on one
	# case can be a conflict with a party on another.
	adb "INSERT INTO conflict (conflict_id,case_id,contact_id,relation_code) VALUES
		(9991001,9991001,9991001,1),
		(9991004,9991001,9991004,1),
		(9991006,9991001,9991006,1),
		(9991005,9991002,9991005,2),
		(9991007,9991002,9991007,2),
		(9991008,9991002,9991008,2),
		(9991003,9991003,9991003,2),
		(9991002,9991004,9991002,2)" >/dev/null

	if [ "$(adb "SELECT COUNT(*) FROM contacts WHERE notes='ZZCFFIXTURE'")" != 8 ]; then
		printf '  skip the conflict check checks (could not write the fixture)\n'
	else
		CFREP="$OCM_URL/reports/conflict/conflict.php"

		# ── A real number still matches, so the checks below mean something ──
		curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" "${CFREP}?case_id=9991001" >/dev/null
		if grep -q 'ZZCONFIVE' "$BODY"; then
			ok "a shared social security number is still reported as a conflict"
		else
			bad "a shared social security number is no longer reported - the checks below prove nothing"
		fi

		# ── A placeholder in the number column is not a number ──
		# ZZCONFOUR sits on another case carrying the same "XXX-XX-XXXX" as a
		# party on this one. strlen($row['ssn'] > 0) is 1 for that value.
		if grep -q 'ZZCONFOUR' "$BODY"; then
			bad "a placeholder social security number matched an unrelated party"
		else
			ok "a placeholder social security number matches nobody"
		fi

		# ── An empty metaphone key is not a name ──
		# ZZORGTWO is an organisation on another case, so it has no key, and so
		# does the organisation on this one.
		if grep -q 'ZZORGTWO' "$BODY"; then
			bad "a party with no metaphone key matched every other record without one"
		else
			ok "a party with no metaphone key matches nobody by name"
		fi

		# ── The number column cannot carry SQL into the search ──
		# Case C's only party holds "1' OR 1=1#" there. Interpolated, that
		# neutralises the WHERE clause and lists every party on every other
		# case, whatever their number or name.
		curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" "${CFREP}?case_id=9991003" >/dev/null
		if grep -q 'ZZCONFONE\|ZZCONFTRE\|ZZORGONE' "$BODY"; then
			bad "SQL in the social security column widened the conflict search"
		else
			ok "SQL in the social security column is searched for, not run"
		fi

		# ── A party with no aliases row is still checked by name ──
		# Case D's only party is the second ZZCONFONE record, which has no
		# aliases row. The party read reached contacts through aliases, so it
		# carried nothing to search on; and the one statement of the name pair
		# that reads contacts was overwritten before it ran. So this case
		# reported nothing, though the same person is a party on case A.
		curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" "${CFREP}?case_id=9991004" >/dev/null
		if grep -q 'ZZCONFONE' "$BODY"; then
			ok "a party with no aliases row is still checked by name"
		else
			bad "a party with no aliases row was checked by contact id alone"
		fi

		# ── The case screen agrees with the report ──
		# cms/app/lib/pikaCase.php holds the copy that page uses. The two
		# cannot share one implementation, because pika_cms.php does not put
		# app/lib on the include path, so both are checked here.
		curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" \
			"$OCM_URL/case.php?case_id=9991001&screen=conflict" >/dev/null
		if grep -q 'ZZCONFIVE' "$BODY" && ! grep -q 'ZZCONFOUR' "$BODY"; then
			ok "the conflict tab on the case screen reports the same conflicts"
		else
			bad "the conflict tab on the case screen disagrees with the report"
		fi

		# ── The report logs nothing ──
		# resetConflictStatus() returned the tally of the last party looked at,
		# which is an undefined variable on a case with no parties, and the
		# name search read the length of a null.
		if [ "$HAVE_COMPOSE" = 1 ]; then
			CFLOG="$(mktemp)"
			docker compose "${COMPOSE_ARGS[@]}" logs app >"$CFLOG" 2>/dev/null
			cf_before="$(wc -l < "$CFLOG")"
			curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" "${CFREP}?case_id=9991001" >/dev/null
			curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" "${CFREP}?case_id=9991099" >/dev/null
			docker compose "${COMPOSE_ARGS[@]}" logs app >"$CFLOG" 2>/dev/null
			cf_new="$(tail -n "+$((cf_before + 1))" "$CFLOG" \
				| grep -c 'pikaCms\.php\|pika_cms\.php' || true)"
			if [ "${cf_new:-0}" -eq 0 ]; then
				ok "the conflict report logs no warnings, with parties and without"
			else
				bad "the conflict report logged ${cf_new} warnings"
			fi
			rm -f "$CFLOG"
		else
			printf '  skip the conflict report log check (needs a running docker compose stack)\n'
		fi
	fi

	cleanup_cf
	trap 'rm -f "$COOKIES" "$BODY"' EXIT
else
	printf '  skip the conflict check checks (needs the database)\n'
fi

# ── 30. Another user's calendar ────────────────────────────────────────────
# cal_day.php, cal_week.php and cal_adv.php took a user id off the query string
# and drew that user's activities, with the summary and the notes, for anyone
# who asked. A fourth page, services/cal-rss.php, did not even require a login:
# it set PL_DISABLE_SECURITY, so an unauthenticated GET returned a week of a
# named user's appointments and case notes as XML. That feed has since been
# removed outright; section 57 checks that it is gone.
#
# The three remaining pages now ask pl_can_view_user_calendar()
# (cms/pika-danio.php):
# your own calendar always, another user's with a read-all group always,
# another user's without one only while the enable_shared_calendars setting is
# not 0. A missing setting row reads as open, which is what the application
# always did, so an installation that has not applied
# cms/app/sql/upgrades/add_shared_calendars.sql keeps its old behaviour.
#
# Three states are checked for each page, because a gate that refuses in every
# state would pass the refusal assertion while taking colleague calendars away
# from every office that wants them.
if [ "$HAVE_DB" = 1 ] && [ "$HAVE_COMPOSE" = 1 ]; then
	CAL_GROUP='zz_cal_grp'
	CAL_USER='zz_cal_user'
	CAL_PASS='zz-cal-Passw0rd'
	CAL_JAR="$(mktemp)"
	# What this installation had before the section touched it, so the value
	# an operator chose survives a test run.
	CAL_SETTING_WAS="$(adb "SELECT value FROM settings WHERE label = 'enable_shared_calendars'")"

	cleanup_cal() {
		adb "DELETE FROM activities WHERE summary IN ('ZZ-CAL-PRIVATE', 'ZZ-CAL-REDACT')" >/dev/null
		adb "DELETE FROM cases WHERE number = 'ZZ-CAL-CASE'" >/dev/null
		adb "DELETE FROM users WHERE username = '${CAL_USER}'" >/dev/null
		adb "DELETE FROM \`groups\` WHERE group_id = '${CAL_GROUP}'" >/dev/null
		adb "DELETE FROM settings WHERE label = 'enable_shared_calendars'" >/dev/null
		if [ -n "${CAL_SETTING_WAS}" ]; then
			adb "INSERT INTO settings (label, value)
				VALUES ('enable_shared_calendars', '${CAL_SETTING_WAS}')" >/dev/null
		fi
		rm -f "$CAL_JAR"
	}
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_cal' EXIT

	adb "DELETE FROM activities WHERE summary IN ('ZZ-CAL-PRIVATE', 'ZZ-CAL-REDACT')" >/dev/null
	adb "DELETE FROM cases WHERE number = 'ZZ-CAL-CASE'" >/dev/null
	adb "DELETE FROM users WHERE username = '${CAL_USER}'" >/dev/null
	adb "DELETE FROM \`groups\` WHERE group_id = '${CAL_GROUP}'" >/dev/null

	# One appointment on the admin's calendar, today, with a note. Every
	# assertion below is about whether this string comes back.
	CAL_ACT="$(adb "SELECT COALESCE(MAX(act_id), 0) + 1 FROM activities")"
	adb "INSERT INTO activities (act_id, user_id, act_date, summary, notes, completed)
		VALUES (${CAL_ACT}, 1, CURDATE(), 'ZZ-CAL-PRIVATE', 'ZZ-CAL-PRIVATE note', 0)" >/dev/null

	# A second appointment on the admin's calendar, this one on a case in an
	# office the fixture group does not have. pika_authorize('read_act') refuses
	# it, so cal_day.php and cal_week.php draw their redacted row for it: the
	# time and the owner, and nothing else.
	#
	# The appointment is scheduled an hour from now rather than at a fixed
	# clock time. cal_day.php splits the day into a pending table
	# (getActivitiesPending, act_time LATER than date("H:i:00")) and an overdue
	# table (getActivitiesOverdue, which also demands act_type = 'K'). An
	# untyped appointment earlier today is in neither, so a fixed time made
	# this check pass or fail depending on the hour the suite ran.
	#
	# The clock that matters is the container's PHP clock, because that is what
	# renders the page and what the pending query compares against. Both pages
	# are then asked for that date explicitly.
	CAL_CASE="$(adb "SELECT COALESCE(MAX(case_id), 0) + 1 FROM cases")"
	adb "INSERT INTO cases (case_id, number, user_id, office, status)
		VALUES (${CAL_CASE}, 'ZZ-CAL-CASE', 1, 'zzz', '1')" >/dev/null
	CAL_WHEN="$(docker compose "${COMPOSE_ARGS[@]}" exec -T app php -r \
		'$t = time() + 3600; echo date("Y-m-d", $t), "|", date("H:i:00", $t), "|", date("g:i A", $t);' \
		</dev/null 2>/dev/null)"
	CAL_RDATE="${CAL_WHEN%%|*}"
	CAL_RTIME="${CAL_WHEN#*|}"
	CAL_RTIME="${CAL_RTIME%%|*}"
	CAL_RLABEL="${CAL_WHEN##*|}"

	CAL_ACT2="$(adb "SELECT COALESCE(MAX(act_id), 0) + 1 FROM activities")"
	adb "INSERT INTO activities (act_id, user_id, case_id, act_date, act_time, summary, notes, completed)
		VALUES (${CAL_ACT2}, 1, ${CAL_CASE}, '${CAL_RDATE}', '${CAL_RTIME}', 'ZZ-CAL-REDACT', 'ZZ-CAL-REDACT note', 0)" >/dev/null

	# 30a. The unauthenticated feed. This one needs no fixture user: before the
	# feed was removed, this exact request returned the row seeded above to
	# anybody on the network. The request is still made, because a deployment
	# that upgrades by copying files over an old tree can leave the old script
	# behind, and it must not answer with case data if it does.
	CAL_RSS_CODE="$(curl -s --max-time 30 -o "$BODY" -w '%{http_code}' \
		"$OCM_URL/services/cal-rss.php?user_id=1")"
	if grep -qF 'ZZ-CAL-PRIVATE' "$BODY"; then
		bad "cal-rss.php SERVES A USER'S APPOINTMENTS AND NOTES WITH NO LOGIN (CWE-306)"
	elif [ "$CAL_RSS_CODE" = 404 ]; then
		ok "the anonymous calendar feed is gone (404)"
	else
		bad "cal-rss.php answered ${CAL_RSS_CODE}, not 404 ($(wc -c < "$BODY") bytes)"
	fi

	# A group with no permissions at all: no read_all, no offices, no reports.
	adb "INSERT INTO \`groups\` (group_id, read_office, read_all, edit_office, edit_all, users, pba, motd, intake, reports)
		VALUES ('${CAL_GROUP}', NULL, 0, NULL, 0, 0, 0, 0, 0, NULL)" >/dev/null

	CAL_HASH="$(docker compose "${COMPOSE_ARGS[@]}" exec -T app \
		php -r 'echo password_hash($argv[1], PASSWORD_DEFAULT);' "$CAL_PASS" </dev/null 2>/dev/null)"
	CAL_UID="$(adb "SELECT COALESCE(MAX(user_id), 0) + 1 FROM users")"
	adb "INSERT INTO users (user_id, username, password, enabled, group_id, password_expire)
		VALUES (${CAL_UID}, '${CAL_USER}', '${CAL_HASH}', 1, '${CAL_GROUP}', 0)" >/dev/null

	cal_login() {
		: > "$CAL_JAR"
		curl -sL --max-time 30 -c "$CAL_JAR" -b "$CAL_JAR" -o "$BODY" \
			-X POST -d "login_user=${CAL_USER}&login_pass=${CAL_PASS}&auth_id=1" \
			"$OCM_URL/" >/dev/null
	}

	# $1 label, $2 path with query string, $3 allow|deny
	cal_probe() {
		curl -sL --max-time 60 -b "$CAL_JAR" -o "$BODY" "$OCM_URL/$2" >/dev/null
		size="$(wc -c < "$BODY")"
		if [ "$size" -lt 500 ]; then
			bad "$1: only $size bytes (PHP fatal?)"
		elif grep -qF 'not viewable' "$BODY"; then
			if [ "$3" = deny ]; then
				ok "$1: refused"
			else
				bad "$1: REFUSED a calendar this user is allowed to see"
			fi
		elif [ "$3" = deny ]; then
			bad "$1: ANOTHER USER'S CALENDAR IS READABLE BY A USER WITH NO PERMISSIONS (CWE-639)"
		else
			ok "$1: drawn ($size bytes)"
		fi
	}

	if [ -z "$CAL_HASH" ] || [ -z "${CAL_UID:-}" ] || [ -z "${CAL_ACT:-}" ] \
		|| [ -z "${CAL_CASE:-}" ] || [ -z "${CAL_ACT2:-}" ] || [ -z "${CAL_RLABEL:-}" ]; then
		bad "could not seed the calendar fixtures (hash/user/activity)"
	else
		cal_login
		if grep -q 'login_pass' "$BODY"; then
			bad "the throwaway calendar user could not log in - the rest of section 30 is untested"
		else
			ok "the throwaway no-permission calendar user can log in"

			# 30b. No setting row: the 2019 behaviour, kept on purpose. An
			# upgrade must not take colleague calendars away on its own.
			adb "DELETE FROM settings WHERE label = 'enable_shared_calendars'" >/dev/null
			cal_probe "cal_day with no setting row" "cal_day.php?user_id=1" allow
			cal_probe "cal_week with no setting row" "cal_week.php?user_id=1" allow

			# The row for an activity on a case this group may not read shows
			# the time and no case text. Both pages used to print $z there,
			# which is set inside the authorized branch, so the cell held the
			# time of the last activity the caller WAS allowed to read; two of
			# the four copies also printed the summary of the activity they
			# were redacting.
			for page in cal_day.php cal_week.php; do
				curl -sL --max-time 60 -b "$CAL_JAR" -o "$BODY" \
					"$OCM_URL/${page}?user_id=1&cal_date=${CAL_RDATE}" >/dev/null
				if grep -qF 'ZZ-CAL-REDACT' "$BODY"; then
					bad "${page} PRINTS THE SUMMARY OF AN ACTIVITY THE CALLER MAY NOT READ"
				elif grep -qF "$CAL_RLABEL" "$BODY"; then
					ok "${page} shows the time of an unreadable activity and no case text"
				else
					bad "${page} drew neither the time nor the summary of the redacted row"
				fi
			done

			# 30c. The setting at 0: refused on all four pages.
			adb "REPLACE INTO settings (label, value) VALUES ('enable_shared_calendars', '0')" >/dev/null
			cal_probe "cal_day with sharing off" "cal_day.php?user_id=1" deny
			cal_probe "cal_week with sharing off" "cal_week.php?user_id=1" deny
			cal_probe "cal_adv with sharing off" "cal_adv.php?user_list%5B%5D=1" deny

			# The same request as a signed-in user with no permissions. The
			# feed is gone, so this is a second check that it cannot be
			# reached, not a check of the gate.
			curl -s --max-time 30 -b "$CAL_JAR" -o "$BODY" \
				"$OCM_URL/services/cal-rss.php?user_id=1" >/dev/null
			if grep -qF 'ZZ-CAL-PRIVATE' "$BODY"; then
				bad "cal-rss.php SERVES ANOTHER USER'S FEED TO A USER WITH NO PERMISSIONS"
			else
				ok "the calendar feed serves nobody another user's appointments"
			fi

			# The refusal is scoped to other people: your own calendar still
			# draws with sharing off.
			cal_probe "own cal_day with sharing off" "cal_day.php?user_id=${CAL_UID}" allow

			# 30d. A read-all group gets the colleague calendars back with
			# sharing off, which is what calendar_admin resolves to.
			adb "UPDATE \`groups\` SET read_all = 1 WHERE group_id = '${CAL_GROUP}'" >/dev/null
			cal_login
			cal_probe "cal_day, read_all, sharing off" "cal_day.php?user_id=1" allow
			cal_probe "cal_week, read_all, sharing off" "cal_week.php?user_id=1" allow
			cal_probe "cal_adv, read_all, sharing off" "cal_adv.php?user_list%5B%5D=1" allow

			# 30e. The refusal is on the record either way.
			CAL_DENIED="$(docker compose "${COMPOSE_ARGS[@]}" logs app 2>/dev/null \
				| grep -c 'calendar refused\|calendar rss refused' || true)"
			if [ "${CAL_DENIED:-0}" -ge 1 ]; then
				ok "the calendar refusals are logged (${CAL_DENIED} lines)"
			else
				bad "no calendar refusal reached the application log"
			fi
		fi
	fi

	cleanup_cal
	trap 'rm -f "$COOKIES" "$BODY"' EXIT
else
	printf '  skip the calendar scope checks (needs the database and docker compose)\n'
fi

echo
echo "36. the Mega Report no longer prints PHP errors to the browser"

# Three lines of leftover debugging sat at the top of the report:
# ini_set on display_errors and display_startup_errors, plus
# error_reporting(E_ALL). They forced PHP's own error output into the
# response for this one page whatever the server was configured to do, so
# a fatal printed the absolute file path and a stack trace to whoever ran
# the report. Whether error detail reaches the browser is php.ini's
# decision, read through pl_is_debug_mode() in cms/app/lib/pl.php.
mr_token() {
	curl -sL --max-time 30 -b "$COOKIES" "$OCM_URL/reports/megareport/" \
		| grep -oE 'name="_csrf" value="[0-9a-f]{64}"' \
		| head -1 | sed -e 's/.*value="//' -e 's/"$//'
}

MRTOK="$(mr_token)"
if [ "${#MRTOK}" -ne 64 ]; then
	bad "no CSRF token on the Mega Report form - section 36 is untested"
else
	# 36a. No columns ticked. pl_grab_post() returns null for a field that
	# was not submitted, and this is the case the friendly message below
	# was written for -- but sizeof(null) is a fatal TypeError under PHP 8,
	# so the report died before it could print it.
	curl -s --max-time 30 -b "$COOKIES" -o "$BODY" -X POST \
		--data-urlencode "_csrf=${MRTOK}" \
		"$OCM_URL/reports/megareport/report.php" >/dev/null
	if grep -q 'you need to check off the fields' "$BODY"; then
		ok "the Mega Report explains that no columns were ticked"
	else
		bad "the Mega Report does not handle an empty column list"
	fi
	if grep -q '/var/www/\|Stack trace' "$BODY"; then
		bad "the Mega Report prints a server file path to the browser"
	else
		ok "that page carries no server path and no stack trace"
	fi

	# 36b. And a query the database refuses. The detail belongs in the log,
	# not in the response.
	MRTOK="$(mr_token)"
	mr_status="$(curl -s --max-time 30 -b "$COOKIES" -o "$BODY" -w '%{http_code}' -X POST \
		--data-urlencode "_csrf=${MRTOK}" \
		-d "fo[]=cases.case_id" -d "order_by=zznotacolumn" \
		"$OCM_URL/reports/megareport/report.php")"
	if grep -q '/var/www/\|Stack trace\|Uncaught' "$BODY"; then
		bad "a failed Mega Report query prints error detail to the browser (status ${mr_status})"
	else
		ok "a failed Mega Report query keeps its error detail in the log (status ${mr_status})"
	fi

	# 36c. A report that does run still runs.
	MRTOK="$(mr_token)"
	curl -s --max-time 30 -b "$COOKIES" -o "$BODY" -X POST \
		--data-urlencode "_csrf=${MRTOK}" \
		-d "fo[]=cases.case_id" -d "recordlimit=5" \
		"$OCM_URL/reports/megareport/report.php" >/dev/null
	if grep -q 'Mega Report' "$BODY" && ! grep -q '/var/www/' "$BODY"; then
		ok "the Mega Report still renders a result"
	else
		bad "the Mega Report no longer renders a result"
	fi
fi

echo
echo "39. re-authentication in front of the sensitive changes"

# A signed-in session is a bearer token. Someone who walks up to an
# unlocked workstation, or who holds a stolen cookie, could reset the
# account holder's password, edit accounts, or rewrite the security
# settings without ever proving they knew the password. pl_reauth_required()
# puts a fresh password check in front of those three, and holds the
# result for PL_REAUTH_WINDOW_SECONDS so a normal multi-step edit is not
# interrupted twice.
#
# password.php is the awkward one. Its challenge form deliberately does
# not carry password fields forward, so the POST that comes back out of
# the challenge has an action and no passwords. Falling through there
# would report "New password cannot be blank" forever, so that route
# redirects instead. That loop is what assertions 8 and 9 pin down.
if [ "$HAVE_DB" = 1 ] && [ "$HAVE_COMPOSE" = 1 ]; then
	RAGROUP='zz_ra_grp'
	RAUSER='zz_ra_user'
	RAPASS='zz-ra-Passw0rd'
	RANEW='zz-ra-N3wPassw0rd'
	RAJAR="$(mktemp)"
	RATARGETJAR="$(mktemp)"
	RATARGETPASS='zz-ra-Target1!'
	RATARGETNEW='zz-ra-Target2!'

	cleanup_ra() {
		adb "DELETE FROM user_sessions WHERE user_id IN (SELECT user_id FROM users WHERE username IN ('zz_ra_reset','zz_ra_create'))" >/dev/null
		adb "DELETE FROM users WHERE username IN ('zz_ra_reset','zz_ra_create')" >/dev/null
		rm -f "$RATARGETJAR"
		adb "DELETE FROM reauth_grants WHERE action_scope IN ('user_admin','password_change','settings')" >/dev/null
		adb "DELETE FROM audit_log WHERE action LIKE 'reauth.%'" >/dev/null
		adb "DELETE FROM user_sessions WHERE user_id IN (SELECT user_id FROM users WHERE username = '${RAUSER}')" >/dev/null
		adb "DELETE FROM users WHERE username = '${RAUSER}'" >/dev/null
		adb "DELETE FROM \`groups\` WHERE group_id = '${RAGROUP}'" >/dev/null
		rm -f "$RAJAR"
	}
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_ra' EXIT
	cleanup_ra

	# The users flag is the one that matters: it is what lets this account
	# reach system-users.php at all, so the re-auth gate is the only thing
	# left between it and an account edit.
	adb "INSERT INTO \`groups\` (group_id, read_office, read_all, edit_office, edit_all, users, pba, motd, intake, reports)
		VALUES ('${RAGROUP}', NULL, 0, NULL, 0, 1, 0, 0, 0, NULL)" >/dev/null

	RAHASH="$(docker compose "${COMPOSE_ARGS[@]}" exec -T app \
		php -r 'echo password_hash($argv[1], PASSWORD_DEFAULT);' "$RAPASS" </dev/null 2>/dev/null)"
	RAUID="$(adb "SELECT COALESCE(MAX(user_id), 0) + 1 FROM users")"
	adb "INSERT INTO users (user_id, username, password, enabled, group_id, password_expire)
		VALUES (${RAUID}, '${RAUSER}', '${RAHASH}', 1, '${RAGROUP}', 0)" >/dev/null

	ra_token() {
		curl -sL --max-time 30 -c "$1" -b "$1" "$OCM_URL/password.php" \
			| grep -oE 'name="_csrf" value="[0-9a-f]{64}"' \
			| head -1 | sed -e 's/.*value="//' -e 's/"$//'
	}

	: > "$RAJAR"
	curl -sL --max-time 30 -c "$RAJAR" -b "$RAJAR" -o /dev/null \
		-d "login_user=${RAUSER}&login_pass=${RAPASS}&auth_id=1" "$OCM_URL/" >/dev/null

	# 39a. An account edit raises the challenge instead of being written.
	RATOK="$(ra_token "$RAJAR")"
	curl -sL --max-time 30 -c "$RAJAR" -b "$RAJAR" -o "$BODY" -X POST \
		-d "_csrf=${RATOK}&action=update&user_id=${RAUID}&username=${RAUSER}&group_id=${RAGROUP}&enabled=1" \
		"$OCM_URL/system-users.php" >/dev/null
	if grep -q 'name="_reauth_scope" value="user_admin"' "$BODY"; then
		ok "an account edit raises the re-auth challenge"
	else
		bad "an account edit was accepted without a re-auth challenge"
	fi

	# 39b. The work in flight survives the challenge.
	if grep -q 'name="username" value="'"${RAUSER}"'"' "$BODY" \
		&& grep -q 'name="action" value="update"' "$BODY"; then
		ok "the challenge carries the in-flight form fields forward"
	else
		bad "the challenge drops the in-flight form fields - the edit is lost"
	fi

	# 39c. ...but not the fields that would put a secret in the markup.
	if grep -q 'name="password"' "$BODY" || grep -q 'name="newpass' "$BODY"; then
		bad "the challenge echoes a password field back as a hidden input"
	else
		ok "the challenge does not carry password fields forward"
	fi

	# 39d. A wrong answer buys nothing.
	RATOK="$(ra_token "$RAJAR")"
	curl -sL --max-time 30 -c "$RAJAR" -b "$RAJAR" -o "$BODY" -X POST \
		-d "_csrf=${RATOK}&_reauth_scope=user_admin&_reauth_password=not-the-password&action=update&user_id=${RAUID}" \
		"$OCM_URL/system-users.php" >/dev/null
	RAGRANTS="$(adb "SELECT COUNT(*) FROM reauth_grants WHERE action_scope = 'user_admin'")"
	if [ "${RAGRANTS:-0}" = 0 ] && grep -q 'Credentials did not match' "$BODY"; then
		ok "a wrong password is refused and writes no grant"
	else
		bad "a wrong password was not refused, or it left a grant behind (${RAGRANTS:-?})"
	fi

	# 39e. And it is on the record.
	if [ "$(adb "SELECT COUNT(*) FROM audit_log WHERE action = 'reauth.denied'")" -gt 0 ]; then
		ok "the refused challenge is recorded in the audit log"
	else
		bad "the refused challenge left no audit row"
	fi

	# 39f. The right answer issues the grant.
	RATOK="$(ra_token "$RAJAR")"
	curl -sL --max-time 30 -c "$RAJAR" -b "$RAJAR" -o "$BODY" -X POST \
		-d "_csrf=${RATOK}&_reauth_scope=user_admin&_reauth_password=${RAPASS}&action=update&user_id=${RAUID}&username=${RAUSER}&group_id=${RAGROUP}&enabled=1" \
		"$OCM_URL/system-users.php" >/dev/null
	RAGRANTS="$(adb "SELECT COUNT(*) FROM reauth_grants WHERE action_scope = 'user_admin' AND granted_until > NOW()")"
	RAAUDIT="$(adb "SELECT COUNT(*) FROM audit_log WHERE action = 'reauth.granted'")"
	if [ "${RAGRANTS:-0}" -ge 1 ] && [ "${RAAUDIT:-0}" -ge 1 ]; then
		ok "the right password issues a grant and records it"
	else
		bad "the right password issued no grant (grants ${RAGRANTS:-?}, audit ${RAAUDIT:-?})"
	fi

	# 39g. One grant is not a pass for everything. A borrowed session that
	# talked its way past one gate must still be stopped at the next.
	RATOK="$(ra_token "$RAJAR")"
	curl -sL --max-time 30 -c "$RAJAR" -b "$RAJAR" -o "$BODY" -X POST \
		-d "_csrf=${RATOK}&action=update&oldpass=${RAPASS}&newpass1=${RANEW}&newpass2=${RANEW}" \
		"$OCM_URL/password.php" >/dev/null
	if grep -q 'name="_reauth_scope" value="password_change"' "$BODY"; then
		ok "a grant for one scope does not satisfy another"
	else
		bad "a grant for one scope let a different scope through"
	fi

	# 39h. Answering the password-change challenge redirects rather than
	# running the handler with the body the challenge just emptied.
	RATOK="$(ra_token "$RAJAR")"
	RAHDRS="$(curl -s --max-time 30 -c "$RAJAR" -b "$RAJAR" -o "$BODY" -D - -X POST \
		-d "_csrf=${RATOK}&_reauth_scope=password_change&_reauth_password=${RAPASS}&action=update" \
		"$OCM_URL/password.php")"
	if printf '%s' "$RAHDRS" | grep -q '303' \
		&& printf '%s' "$RAHDRS" | grep -qi 'Location:.*password.php?reauth=1'; then
		ok "the password-change challenge redirects instead of looping on an empty body"
	else
		bad "the password-change challenge fell through to the handler - the empty-body loop is back"
	fi

	# 39i. And says so, in the colour a confirmation should be.
	curl -sL --max-time 30 -c "$RAJAR" -b "$RAJAR" -o "$BODY" "$OCM_URL/password.php?reauth=1" >/dev/null
	if sed 's/&nbsp;/ /g' "$BODY" | grep -q 'Identity verified'; then
		ok "the page confirms the identity check before asking for the new password"
	else
		bad "the page gives no sign the identity check succeeded"
	fi

	# 39j. With the grant in hand the change actually goes through.
	RAWAS="$(adb "SELECT password FROM users WHERE user_id = ${RAUID}")"
	RATOK="$(ra_token "$RAJAR")"
	curl -sL --max-time 30 -c "$RAJAR" -b "$RAJAR" -o "$BODY" -X POST \
		-d "_csrf=${RATOK}&action=update&oldpass=${RAPASS}&newpass1=${RANEW}&newpass2=${RANEW}" \
		"$OCM_URL/password.php" >/dev/null
	RANOW="$(adb "SELECT password FROM users WHERE user_id = ${RAUID}")"
	if [ -n "$RANOW" ] && [ "$RANOW" != "$RAWAS" ]; then
		ok "the grant lets the password change through"
	else
		bad "the password change did not take effect with a grant in hand"
	fi

	# 39k. The window is what makes the grant safe to hold at all. An
	# expired row must read the same as no row.
	adb "UPDATE reauth_grants SET granted_until = DATE_SUB(NOW(), INTERVAL 1 MINUTE)" >/dev/null
	RATOK="$(ra_token "$RAJAR")"
	curl -sL --max-time 30 -c "$RAJAR" -b "$RAJAR" -o "$BODY" -X POST \
		-d "_csrf=${RATOK}&action=update&user_id=${RAUID}&username=${RAUSER}&group_id=${RAGROUP}&enabled=1" \
		"$OCM_URL/system-users.php" >/dev/null
	if grep -q 'name="_reauth_scope" value="user_admin"' "$BODY"; then
		ok "an expired grant challenges again"
	else
		bad "an expired grant still let the change through"
	fi

	# Reset and create both need a second edit after confirmation. The
	# challenge must not carry the chosen password or save a partial user.
	for RAMODE in reset create; do
		RATARGET="zz_ra_${RAMODE}"
		RATARGETID=''
		if [ "$RAMODE" = reset ]; then
			RATARGETHASH="$(docker compose "${COMPOSE_ARGS[@]}" exec -T app \
				php -r 'echo password_hash($argv[1], PASSWORD_DEFAULT);' "$RATARGETPASS" </dev/null 2>/dev/null)"
			RATARGETID="$(adb "SELECT COALESCE(MAX(user_id), 0) + 1 FROM users")"
			adb "INSERT INTO users (user_id, username, password, enabled, group_id, password_expire, must_change_password, first_name)
				VALUES (${RATARGETID}, '${RATARGET}', '${RATARGETHASH}', 1, '${RAGROUP}', 0, 0, 'ZZRA Before')" >/dev/null
			: > "$RATARGETJAR"
			curl -sL --max-time 30 -c "$RATARGETJAR" -b "$RATARGETJAR" -o /dev/null \
				-d "login_user=${RATARGET}&login_pass=${RATARGETPASS}&auth_id=1" "$OCM_URL/" >/dev/null
			RALIVE="$(adb "SELECT COUNT(*) FROM user_sessions WHERE user_id = ${RATARGETID} AND (logout IS NULL OR logout = 0)")"
			if [ "${RALIVE:-0}" -gt 0 ]; then
				ok "the reset target has a live session before its password changes"
			else
				bad "the reset target has no live session to invalidate"
			fi
		fi
		RABEFOREROW="$(adb "SELECT * FROM users WHERE username = '${RATARGET}'")"
		if ! adb "DELETE FROM reauth_grants WHERE BINARY session_id IN
			(SELECT BINARY session_id FROM user_sessions WHERE user_id = ${RAUID}) AND action_scope = 'user_admin'" >/dev/null; then
			bad "could not clear the fixture's user-admin grant before ${RAMODE}"
		fi
		RATOK="$(ra_token "$RAJAR")"
		curl -sL --max-time 30 -c "$RAJAR" -b "$RAJAR" -o "$BODY" \
			-d "_csrf=${RATOK}&action=update&user_id=${RATARGETID}&username=${RATARGET}&group_id=${RAGROUP}&enabled=1" \
			--data-urlencode 'first_name=ZZRA After' \
			--data-urlencode "password=${RATARGETNEW}" "$OCM_URL/system-users.php" >/dev/null
		if grep -q 'name="_reauth_scope" value="user_admin"' "$BODY" \
			&& grep -q 'name="_reauth_edit_again" value="1"' "$BODY" \
			&& ! grep -q 'name="password"' "$BODY" \
			&& ! grep -qF "$RATARGETNEW" "$BODY" \
			&& [ "$(adb "SELECT * FROM users WHERE username = '${RATARGET}'")" = "$RABEFOREROW" ]; then
			ok "${RAMODE}: the challenge omits the password and leaves the user unchanged"
		else
			bad "${RAMODE}: the challenge leaked a password, lost its edit marker or wrote the user"
		fi

		# Send only the safe fields the challenge actually carried.
		RATOK="$(grep -oE 'name="_csrf" value="[0-9a-f]{64}"' "$BODY" \
			| head -1 | sed -e 's/.*value="//' -e 's/"$//')"
		RAHEAD="$(curl -s --max-time 30 -c "$RAJAR" -b "$RAJAR" -o "$BODY" -D - \
			-d "_csrf=${RATOK}&_reauth_scope=user_admin&_reauth_edit_again=1&action=update&user_id=${RATARGETID}" \
			-d "username=${RATARGET}&group_id=${RAGROUP}&enabled=1" \
			--data-urlencode 'first_name=ZZRA After' \
			--data-urlencode "_reauth_password=${RANEW}" "$OCM_URL/system-users.php")"
		RARETURN="$(printf '%s' "$RAHEAD" | tr -d '\r' | sed -n 's/^[Ll]ocation: *//p')"
		if printf '%s' "$RAHEAD" | grep -q '303' \
			&& printf '%s' "$RARETURN" | grep -q 'system-users.php?action=edit' \
			&& [ "$(adb "SELECT * FROM users WHERE username = '${RATARGET}'")" = "$RABEFOREROW" ] \
			&& { [ "$RAMODE" != reset ] || [ "$(adb "SELECT COUNT(*) FROM user_sessions WHERE user_id = ${RATARGETID:-0} AND (logout IS NULL OR logout = 0)")" = "$RALIVE" ]; }; then
			ok "${RAMODE}: confirmation returns to edit without a partial save"
		else
			bad "${RAMODE}: confirmation did not return to edit or changed the user"
		fi
		# Follow only this fixture's local edit route.
		curl -sL --max-time 30 -c "$RAJAR" -b "$RAJAR" -o "$BODY" \
			"$OCM_URL/system-users.php?action=edit&user_id=${RATARGETID}&reauth=1" >/dev/null
		if grep -q 'name="password"' "$BODY" && grep -q 'name="username"' "$BODY" \
			&& ! grep -q 'name="_reauth_scope"' "$BODY"; then
			ok "${RAMODE}: the edit screen lets the administrator reenter the password"
		else
			bad "${RAMODE}: the edit screen did not return after confirmation"
		fi
		RATOK="$(grep -oE 'name="_csrf" value="[0-9a-f]{64}"' "$BODY" \
			| head -1 | sed -e 's/.*value="//' -e 's/"$//')"
		curl -sL --max-time 30 -c "$RAJAR" -b "$RAJAR" -o "$BODY" \
			-d "_csrf=${RATOK}&action=update&user_id=${RATARGETID}&username=${RATARGET}&group_id=${RAGROUP}&enabled=1" \
			--data-urlencode 'first_name=ZZRA After' \
			--data-urlencode "password=${RATARGETNEW}" "$OCM_URL/system-users.php" >/dev/null
		RATARGETID="$(adb "SELECT user_id FROM users WHERE username = '${RATARGET}'")"
		RANEWHASH="$(adb "SELECT password FROM users WHERE username = '${RATARGET}'")"
		RAPWOK="$(docker compose "${COMPOSE_ARGS[@]}" exec -T app \
			php -r 'echo password_verify($argv[1], $argv[2]) ? "1" : "0";' "$RATARGETNEW" "$RANEWHASH" </dev/null 2>/dev/null)"
		if [ -n "$RATARGETID" ] && [ "$RAPWOK" = 1 ] \
			&& [ "$(adb "SELECT first_name FROM users WHERE username = '${RATARGET}'")" = 'ZZRA After' ] \
			&& [ "$(adb "SELECT must_change_password FROM users WHERE username = '${RATARGET}'")" = 1 ]; then
			ok "${RAMODE}: reentering the form saves the password and requires its replacement"
		else
			bad "${RAMODE}: the second edit did not save the password, fields and forced-change flag"
		fi
		if [ "$RAMODE" = reset ]; then
			if [ -n "$RATARGETID" ] \
				&& [ "$(adb "SELECT COUNT(*) FROM user_sessions WHERE user_id = ${RATARGETID:-0} AND (logout IS NULL OR logout = 0)")" = 0 ]; then
				ok "the confirmed administrator reset ends the target's old sessions"
			else
				bad "an old session survived the confirmed administrator reset"
			fi
		fi
	done

	cleanup_ra
	trap 'rm -f "$COOKIES" "$BODY"' EXIT
else
	printf '  skip the re-authentication checks (needs the database and compose)\n'
fi

echo
echo "42. single sign-on: ending the provider session too"
# Signing out of the application does not, on its own, end the session the
# identity provider is holding. With sso_single_logout on, sign-out sends the
# browser to the provider's end_session_endpoint as well, so the next sign-in
# asks for credentials instead of walking straight back in.
#
# Driven against the same fake provider as section 26, set up again here so
# this section does not depend on what an earlier one left behind.
if [ "$HAVE_DB" = 1 ] && [ "$HAVE_COMPOSE" = 1 ]; then
	if [ -n "$(adb "SELECT 1 FROM settings WHERE label = 'sso_single_logout'")" ]; then
		ok "the sso_single_logout setting is seeded"
	else
		bad "settings has no sso_single_logout row (add_sso_single_logout.sql did not run)"
	fi

	SLO_GROUP='zz_slo_grp'
	SLO_USER='zz_slo_user'
	SLO_PWUSER='zz_slo_pwuser'
	SLO_PWPASS='zz-slo-Passw0rd'
	SLO_SUB='zz-slo-subject-0001'
	SLO_MAIL='zz_slo_user@zz-slo.example'
	SLO_CLIENT='zz-ocm-slo-client'
	SLO_SECRET='zz-ocm-slo-secret'
	SLO_JAR="$(mktemp)"
	SLO_IDP='/var/www/html/cms/zz_test_idp.php'
	SLO_DIR='/tmp/zz_test_idp'
	SLO_PATH="$(printf '%s' "$OCM_URL" | sed -E 's#^[a-z]+://[^/]*##')"
	SLO_BROWSER="${OCM_URL}/zz_test_idp.php"
	SLO_SERVER="http://localhost${SLO_PATH}/zz_test_idp.php"
	SLO_ISSUER="http://localhost${SLO_PATH}/zz_test_idp"
	SLO_ORIGIN="$(printf '%s' "$OCM_URL" | sed -E 's#^(https?://[^/]+).*#\1#')"

	slo_dex() { docker compose "${COMPOSE_ARGS[@]}" exec -T app "$@"; }
	slo_set() { adb "UPDATE settings SET value = '$2' WHERE label = '$1'" >/dev/null; }
	slo_flags() { printf '%s' "${1:-}" | slo_dex sh -c "cat > ${SLO_DIR}/flags"; }

	# The Location header from a sign-out, without following it.
	slo_logout_target() {
		curl -s --max-time 30 -b "$SLO_JAR" -c "$SLO_JAR" \
			-o /dev/null -w '%{redirect_url}' "$OCM_URL/services/logout.php"
	}

	# A complete SSO sign-in, leaving the session in $SLO_JAR.
	slo_signin() {
		slo_flags "${1:-}"
		: > "$SLO_JAR"
		adb "DELETE FROM pika_sso_oidc_state" >/dev/null
		curl -sL --max-time 30 -c "$SLO_JAR" -b "$SLO_JAR" -o "$BODY" \
			-w '%{http_code}' "$OCM_URL/services/sso/login.php"
	}

	cleanup_slo() {
		adb "DELETE FROM users WHERE username IN ('${SLO_USER}', '${SLO_PWUSER}')" >/dev/null
		adb "DELETE FROM \`groups\` WHERE group_id = '${SLO_GROUP}'" >/dev/null
		adb "DELETE FROM pika_sso_oidc_state" >/dev/null
		adb "DELETE FROM audit_log WHERE action = 'sso.logout.redirect'" >/dev/null
		adb "UPDATE settings SET value = '' WHERE label LIKE 'sso\\_%'" >/dev/null
		adb "UPDATE settings SET value = '0' WHERE label IN
			('sso_enabled', 'sso_autobind_by_email', 'sso_allow_insecure_transport',
			 'sso_single_logout')" >/dev/null
		slo_dex rm -rf "$SLO_IDP" "$SLO_DIR" >/dev/null 2>&1 || true
		rm -f "$SLO_JAR"
	}
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_slo' EXIT

	cleanup_slo
	slo_dex mkdir -p "$SLO_DIR" >/dev/null 2>&1
	slo_dex chmod 0777 "$SLO_DIR" >/dev/null 2>&1
	slo_dex sh -c "cat > ${SLO_IDP}" < "${SMOKE_DIR}/fixtures/zz_test_idp.php"
	slo_dex sh -c "cat > ${SLO_DIR}/config.json" <<SLOCFG
{
	"issuer": "${SLO_ISSUER}",
	"browser_base": "${SLO_BROWSER}",
	"server_base": "${SLO_SERVER}",
	"client_id": "${SLO_CLIENT}",
	"client_secret": "${SLO_SECRET}",
	"sub": "${SLO_SUB}",
	"email": "${SLO_MAIL}"
}
SLOCFG
	slo_flags ''

	slo_set sso_provider generic
	slo_set sso_issuer_url "$SLO_ISSUER"
	slo_set sso_discovery_url "${SLO_SERVER}?ep=discovery"
	slo_set sso_client_id "$SLO_CLIENT"
	slo_set sso_client_secret "$SLO_SECRET"
	slo_set sso_allow_insecure_transport 1
	slo_set sso_enabled 1
	slo_set sso_single_logout 0

	adb "INSERT INTO \`groups\` (group_id, read_office, read_all, edit_office, edit_all, users, pba, motd, intake, reports)
		VALUES ('${SLO_GROUP}', NULL, 1, NULL, 0, 0, 0, 0, 0, NULL)" >/dev/null
	SLO_HASH="$(slo_dex php -r 'echo password_hash($argv[1], PASSWORD_DEFAULT);' "$SLO_PWPASS" </dev/null 2>/dev/null)"
	SLO_UID="$(adb "SELECT COALESCE(MAX(user_id), 0) + 1 FROM users")"
	adb "INSERT INTO users (user_id, username, password, enabled, group_id, password_expire,
			email, auth_method, sso_subject)
		VALUES (${SLO_UID}, '${SLO_USER}', '', 1, '${SLO_GROUP}', 0,
			'${SLO_MAIL}', 'sso', '${SLO_SUB}')" >/dev/null
	SLO_PWUID="$(adb "SELECT COALESCE(MAX(user_id), 0) + 1 FROM users")"
	adb "INSERT INTO users (user_id, username, password, enabled, group_id, password_expire, auth_method)
		VALUES (${SLO_PWUID}, '${SLO_PWUSER}', '${SLO_HASH}', 1, '${SLO_GROUP}', 0, 'password')" >/dev/null

	if [ -z "${SLO_UID:-}" ] || [ -z "${SLO_HASH:-}" ]; then
		bad "could not seed the single-logout fixtures"
	else
		# 42a. Off by default: an SSO account signs out locally, exactly as
		# it did before this setting existed.
		if [ "$(slo_signin '')" = 200 ] && ! grep -q 'login_pass' "$BODY"; then
			ok "the fixture signs in through the provider"
		else
			bad "the SSO fixture did not sign in - nothing below can be trusted"
		fi
		SLO_TARGET="$(slo_logout_target)"
		case "$SLO_TARGET" in
			*ep=endsession*) bad "sign-out went to the provider while sso_single_logout is off: ${SLO_TARGET}" ;;
			*) ok "with the setting off, sign-out stays on this installation" ;;
		esac

		# 42b. On: the same account is handed to the provider's end-session
		# endpoint, with a return address the provider can check.
		slo_set sso_single_logout 1
		slo_signin '' >/dev/null
		SLO_TARGET="$(slo_logout_target)"
		case "$SLO_TARGET" in
			*ep=endsession*) ok "with the setting on, sign-out goes to the provider's end-session endpoint" ;;
			*) bad "sign-out did not reach the end-session endpoint: ${SLO_TARGET:-none}" ;;
		esac
		case "$SLO_TARGET" in
			*post_logout_redirect_uri=*) ok "the end-session URL carries a post-logout return address" ;;
			*) bad "the end-session URL has no post_logout_redirect_uri - the provider has nowhere to send the user back to" ;;
		esac
		# The return address has to be this installation, not somewhere a
		# request header chose.
		SLO_RETURN="$(printf '%s' "$SLO_TARGET" | sed -n 's/.*post_logout_redirect_uri=\([^&]*\).*/\1/p' \
			| sed -e 's/%3A/:/g' -e 's/%2F/\//g')"
		case "$SLO_RETURN" in
			"${SLO_ORIGIN}"*) ok "the return address points back at this installation" ;;
			*) bad "the return address is not this installation: ${SLO_RETURN:-none}" ;;
		esac
		case "$SLO_TARGET" in
			*"${SLO_SECRET}"*) bad "the end-session URL leaks the client secret" ;;
			*) ok "the end-session URL carries no client secret" ;;
		esac
		if [ -n "$(adb "SELECT 1 FROM audit_log WHERE action = 'sso.logout.redirect' LIMIT 1")" ]; then
			ok "audit_log recorded sso.logout.redirect"
		else
			bad "audit_log has no sso.logout.redirect row"
		fi
		# The URL has to be one the provider actually answers.
		if [ "$(curl -s --max-time 30 -o /dev/null -w '%{http_code}' "$SLO_TARGET")" = 200 ]; then
			ok "the provider answers the end-session URL"
		else
			bad "the provider did not answer the end-session URL"
		fi

		# 42c. A password account is never sent to the provider, even with
		# the setting on.
		: > "$SLO_JAR"
		curl -sL --max-time 30 -c "$SLO_JAR" -b "$SLO_JAR" -o "$BODY" \
			-X POST -d "login_user=${SLO_PWUSER}&login_pass=${SLO_PWPASS}&auth_id=1" \
			"$OCM_URL/" >/dev/null
		if grep -q 'login_pass' "$BODY"; then
			bad "the password fixture did not sign in"
		fi
		SLO_TARGET="$(slo_logout_target)"
		case "$SLO_TARGET" in
			*ep=endsession*) bad "a password account was sent to the identity provider to sign out" ;;
			*) ok "a password account signs out locally" ;;
		esac

		# 42d. A provider that publishes no end-session endpoint, Google
		# among them, must not break sign-out.
		slo_signin 'no_end_session' >/dev/null
		SLO_TARGET="$(slo_logout_target)"
		case "$SLO_TARGET" in
			*ep=endsession*) bad "sign-out invented an end-session endpoint the provider does not publish" ;;
			'') bad "sign-out produced no redirect at all with no end-session endpoint published" ;;
			*) ok "a provider with no end-session endpoint signs out locally" ;;
		esac
	fi

	cleanup_slo
	trap 'rm -f "$COOKIES" "$BODY"' EXIT
else
	printf '  skip the single sign-out checks (needs the database and compose)\n'
fi

echo
echo "43. new passwords checked against known breaches"
# A password that satisfies every length and character rule is still no good
# if it is already in a credential-stuffing list. With the policy on, a
# password being set is checked against the Pwned Passwords index.
#
# The real service is a third party on the internet, so this section installs
# a stand-in that answers in the same shape and deletes it again. The
# application is pointed at it with password_breach_api_url, which exists for
# exactly this and has no field on any admin screen.
if [ "$HAVE_DB" = 1 ] && [ "$HAVE_COMPOSE" = 1 ]; then
	if [ "$(adb "SELECT value FROM settings WHERE label = 'password_breach_policy'")" = "off" ]; then
		ok "password_breach_policy is seeded, and is off until somebody turns it on"
	else
		bad "password_breach_policy is missing or is not off by default"
	fi

	HIBP_GROUP='zz_hibp_grp'
	HIBP_USER='zz_hibp_user'
	HIBP_PASS='zz-hibp-Passw0rd'
	HIBP_BAD='Zz-Hibp-Breach1!'
	HIBP_BAD2='Zz-Hibp-Breach2!'
	HIBP_GOOD='Zz-Hibp-Clean9f3a!'
	HIBP_JAR="$(mktemp)"
	HIBP_STUB='/var/www/html/cms/zz_test_hibp.php'
	HIBP_DIR='/tmp/zz_test_hibp'
	HIBP_PATH="$(printf '%s' "$OCM_URL" | sed -E 's#^[a-z]+://[^/]*##')"
	# The container reaches itself on port 80; the published port is the
	# test's way in, not the application's.
	HIBP_API="http://localhost${HIBP_PATH}/zz_test_hibp.php"

	hibp_dex() { docker compose "${COMPOSE_ARGS[@]}" exec -T app "$@"; }
	hibp_set() { adb "UPDATE settings SET value = '$2' WHERE label = '$1'" >/dev/null; }
	hibp_flags() { printf '%s' "${1:-}" | hibp_dex sh -c "cat > ${HIBP_DIR}/flags"; }
	hibp_hash() { adb "SELECT password FROM users WHERE username = '${HIBP_USER}'"; }

	# Sign the fixture in and post a password change. $1 old, $2 new.
	# Echoes the response body's flag text so the caller can look at it.
	hibp_change() {
		: > "$HIBP_JAR"
		curl -sL --max-time 30 -c "$HIBP_JAR" -b "$HIBP_JAR" -o /dev/null \
			-X POST -d "login_user=${HIBP_USER}&login_pass=$1&auth_id=1" "$OCM_URL/" 
		curl -sL --max-time 30 -c "$HIBP_JAR" -b "$HIBP_JAR" -o "$BODY" \
			"$OCM_URL/password.php"
		HIBP_TOK="$(grep -oE 'name="_csrf" value="[0-9a-f]{64}"' "$BODY" \
			| head -1 | sed 's/.*value="//;s/"//')"
		sm_password_post "$HIBP_JAR" "$1" \
			-X POST -d "action=update" -d "oldpass=$1" \
			-d "newpass1=$2" -d "newpass2=$2" -d "_csrf=${HIBP_TOK}" \
			"$OCM_URL/password.php"
	}

	cleanup_hibp() {
		adb "DELETE FROM users WHERE username = '${HIBP_USER}'" >/dev/null
		adb "DELETE FROM \`groups\` WHERE group_id = '${HIBP_GROUP}'" >/dev/null
		adb "DELETE FROM audit_log WHERE action LIKE 'password.breach\\_%'" >/dev/null
		adb "UPDATE settings SET value = 'off' WHERE label = 'password_breach_policy'" >/dev/null
		adb "UPDATE settings SET value = '' WHERE label = 'password_breach_api_url'" >/dev/null
		hibp_dex rm -rf "$HIBP_STUB" "$HIBP_DIR" >/dev/null 2>&1 || true
		rm -f "$HIBP_JAR"
	}
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_hibp' EXIT

	cleanup_hibp
	hibp_dex mkdir -p "$HIBP_DIR" >/dev/null 2>&1
	hibp_dex chmod 0777 "$HIBP_DIR" >/dev/null 2>&1
	hibp_dex sh -c "cat > ${HIBP_STUB}" < "${SMOKE_DIR}/fixtures/zz_test_hibp.php"
	printf '%s\n%s\n' "$HIBP_BAD" "$HIBP_BAD2" | hibp_dex sh -c "cat > ${HIBP_DIR}/passwords"
	hibp_flags ''
	hibp_set password_breach_api_url "$HIBP_API"

	adb "INSERT INTO \`groups\` (group_id, read_office, read_all, edit_office, edit_all, users, pba, motd, intake, reports)
		VALUES ('${HIBP_GROUP}', NULL, 1, NULL, 0, 0, 0, 0, 0, NULL)" >/dev/null
	HIBP_HASH="$(hibp_dex php -r 'echo password_hash($argv[1], PASSWORD_DEFAULT);' "$HIBP_PASS" </dev/null 2>/dev/null)"
	HIBP_UID="$(adb "SELECT COALESCE(MAX(user_id), 0) + 1 FROM users")"
	adb "INSERT INTO users (user_id, username, password, enabled, group_id, password_expire)
		VALUES (${HIBP_UID}, '${HIBP_USER}', '${HIBP_HASH}', 1, '${HIBP_GROUP}', 0)" >/dev/null

	# The stand-in has to be serving, or nothing below means anything.
	HIBP_PREFIX="$(hibp_dex php -r 'echo strtoupper(substr(sha1($argv[1]), 0, 5));' "$HIBP_BAD" </dev/null 2>/dev/null)"
	HIBP_SUFFIX="$(hibp_dex php -r 'echo strtoupper(substr(sha1($argv[1]), 5));' "$HIBP_BAD" </dev/null 2>/dev/null)"
	curl -s --max-time 30 -o "$BODY" "${OCM_URL}/zz_test_hibp.php/${HIBP_PREFIX}" >/dev/null
	if grep -q "$HIBP_SUFFIX" "$BODY"; then
		ok "the stand-in breach service answers for the test password's prefix"
	else
		bad "the stand-in breach service did not answer - the rest of this section cannot be trusted"
	fi

	if [ -z "${HIBP_UID:-}" ] || [ -z "${HIBP_HASH:-}" ]; then
		bad "could not seed the breach-check fixtures"
	else
		# 43a. Off means off: a password in the list is accepted.
		hibp_set password_breach_policy off
		hibp_change "$HIBP_PASS" "$HIBP_BAD" >/dev/null
		if [ "$(hibp_hash)" != "$HIBP_HASH" ]; then
			ok "with the policy off, a breached password is accepted"
		else
			bad "with the policy off, the password change was refused anyway"
		fi
		HIBP_HASH="$(hibp_hash)"

		# 43b. Warn: the user is told, and the change still goes through.
		hibp_set password_breach_policy warn
		hibp_change "$HIBP_BAD" "$HIBP_BAD2" >/dev/null
		if grep -qi 'known&nbsp;data&nbsp;breach' "$BODY"; then
			ok "on warn, the user is told the password has been breached"
		else
			bad "on warn, the page said nothing about the breach"
		fi
		if [ "$(hibp_hash)" != "$HIBP_HASH" ]; then
			ok "on warn, the change still goes through"
		else
			bad "on warn, the change was refused - warn must not block"
		fi
		HIBP_HASH="$(hibp_hash)"
		if [ -n "$(adb "SELECT 1 FROM audit_log WHERE action = 'password.breach_check_hit' LIMIT 1")" ]; then
			ok "audit_log recorded password.breach_check_hit"
		else
			bad "audit_log has no password.breach_check_hit row"
		fi

		# 43c. Block: refused, and the stored password is untouched.
		hibp_set password_breach_policy block
		hibp_change "$HIBP_BAD2" "$HIBP_BAD" >/dev/null
		if [ "$(hibp_hash)" = "$HIBP_HASH" ]; then
			ok "on block, a breached password is refused and the old one stands"
		else
			bad "on block, the breached password was stored anyway"
		fi

		# 43d. Block does not refuse a password nobody has seen.
		hibp_change "$HIBP_BAD2" "$HIBP_GOOD" >/dev/null
		if [ "$(hibp_hash)" != "$HIBP_HASH" ]; then
			ok "on block, a password that is not in the index is accepted"
		else
			bad "on block, a clean password was refused"
		fi
		HIBP_HASH="$(hibp_hash)"

		# 43e. A service that is down must not stop anyone changing their
		# password, even on block.
		hibp_flags 'fail'
		hibp_change "$HIBP_GOOD" "$HIBP_BAD" >/dev/null
		if [ "$(hibp_hash)" != "$HIBP_HASH" ]; then
			ok "an unreachable breach service does not block a password change"
		else
			bad "an unreachable breach service blocked a password change"
		fi
		if [ -n "$(adb "SELECT 1 FROM audit_log WHERE action = 'password.breach_check_unreachable' LIMIT 1")" ]; then
			ok "audit_log recorded password.breach_check_unreachable"
		else
			bad "audit_log has no password.breach_check_unreachable row"
		fi
		hibp_flags ''
	fi

	cleanup_hibp
	trap 'rm -f "$COOKIES" "$BODY"' EXIT
else
	printf '  skip the breach-check checks (needs the database and compose)\n'
fi

echo
echo "46. CSV export: formula guard and RFC 4180 quoting"

# Every report under cms/reports that offers a CSV format builds it with
# plCsvReport and plCsvReportTable. The data rows went through fputcsv(),
# which produces correct CSV -- and correct CSV is the problem: Excel,
# LibreOffice and Sheets all evaluate a cell whose text begins with = + - @
# when the file is opened. Exports are routinely mailed to funders, so the
# spreadsheet that evaluates a client's name is often outside the org.
#
# The report title, the filter-parameter lines and the per-table title were a
# separate defect. They were assembled by hand with addslashes(), which emits
# \" where CSV requires "". Excel, LibreOffice and Sheets end the field at
# that quote, so a filter value carrying a quote and a comma opens a fresh
# cell -- and that cell is free to begin '=', which is how a filter value
# becomes a live formula in spite of the literal "Office Code: " in front of
# it.
#
# The report driven here is cms/reports/daily_intake, which puts a contact
# last name and a case number straight into a data row and echoes the office
# filter into the preamble.
#
# Not covered: the Content-Length line in plCsvReport::display() counted
# UTF-8 code points with mb_strlen() instead of bytes, which truncates a
# download that carries any multi-byte character. It is fixed, but this stack
# cannot show it: Apache recomputes Content-Length from the buffered body, so
# the short value PHP sets never reaches the client here. Verified with a
# throwaway script that declared 13 for a 16-byte body and went out as 16.
if [ "$HAVE_DB" = 1 ]; then
	CSVDATE='2019-03-04'
	CSVDATEP='03/04/2019'

	cleanup_csv() {
		adb "DELETE FROM cases WHERE judge_name = 'ZZCSV'" >/dev/null
		adb "DELETE FROM contacts WHERE first_name = 'ZZCSV'" >/dev/null
	}
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_csv' EXIT
	cleanup_csv

	csv_next_id() {
		adb "SELECT GREATEST(
			COALESCE((SELECT MAX(${2}) FROM \`${1}\`), 0),
			COALESCE((SELECT count FROM counters WHERE id = '${1}'), 0)) + 1"
	}
	csv_bump_counter() {
		adb "UPDATE counters SET count = GREATEST(count, ${2}) WHERE id = '${1}'" >/dev/null
	}

	# One client whose stored last name is a formula, and one ordinary client.
	# The case numbers carry the other half of the check: a negative number
	# must NOT be quoted as text, or every financial total in every export
	# silently breaks, which is the damage this guard must not cause.
	CSVC1="$(csv_next_id contacts contact_id)"
	adb "INSERT INTO contacts (contact_id, first_name, last_name)
		VALUES (${CSVC1}, 'ZZCSV', '=HYPERLINK(\"http://x\",1)')" >/dev/null
	csv_bump_counter contacts "$CSVC1"
	CSVC2="$(csv_next_id contacts contact_id)"
	adb "INSERT INTO contacts (contact_id, first_name, last_name)
		VALUES (${CSVC2}, 'ZZCSV', 'Zzcsvplain')" >/dev/null
	csv_bump_counter contacts "$CSVC2"

	CSVK1="$(csv_next_id cases case_id)"
	adb "INSERT INTO cases (case_id, number, client_id, user_id, office, status, open_date, intake_user_id, judge_name)
		VALUES (${CSVK1}, '-1500.00', ${CSVC1}, 1, 'ZZC', '1', '${CSVDATE}', 1, 'ZZCSV')" >/dev/null
	csv_bump_counter cases "$CSVK1"
	CSVK2="$(csv_next_id cases case_id)"
	adb "INSERT INTO cases (case_id, number, client_id, user_id, office, status, open_date, intake_user_id, judge_name)
		VALUES (${CSVK2}, '-1,500.00', ${CSVC2}, 1, 'ZZC', '1', '${CSVDATE}', 1, 'ZZCSV')" >/dev/null
	csv_bump_counter cases "$CSVK2"

	csv_export() {
		curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" "$OCM_URL/case_list.php" >/dev/null
		csv_token="$(grep -oE 'name="_csrf" value="[0-9a-f]{64}"' "$BODY" \
			| head -1 | sed 's/.*value="//;s/"//')"
		curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" \
			--data-urlencode "report_format=csv" \
			--data-urlencode "date=${CSVDATEP}" \
			--data-urlencode "office=${1}" \
			--data-urlencode "_csrf=${csv_token}" \
			"$OCM_URL/reports/daily_intake/report.php" >/dev/null
	}

	csv_export 'ZZC'

	if grep -qF 'ZZC' "$BODY" && grep -qF 'HYPERLINK' "$BODY"; then
		ok "the daily intake export contains the fixture rows"

		# fputcsv doubles the inner quotes; the leading ' is the guard.
		if grep -qF "\"'=HYPERLINK(\"\"http://x\"\",1)\"" "$BODY"; then
			ok "a client name that is a formula is neutralised in the export"
		else
			bad "a client name beginning with = is exported as a live formula"
		fi

		# -1500.00 is a number, so it must pass through untouched. A blanket
		# prefix here would turn every negative figure in every financial
		# report into text.
		if grep -qF "'-1500.00" "$BODY"; then
			bad "the export quotes -1500.00 as text - financial totals will not sum"
		elif grep -qF -- '-1500.00' "$BODY"; then
			ok "a negative number is exported as a number, not as text"
		else
			bad "the negative-number fixture is not in the export"
		fi

		if grep -qF "'-1,500.00" "$BODY"; then
			bad "the export quotes -1,500.00 as text - a formatted negative is still a number"
		elif grep -qF -- '-1,500.00' "$BODY"; then
			ok "a negative number with a thousands separator is exported as a number"
		else
			bad "the formatted negative-number fixture is not in the export"
		fi
	else
		bad "the daily intake export is missing the fixture rows - section 46 proves nothing"
	fi

	# The preamble. addslashes() emitted a\"b; CSV requires a""b.
	csv_export 'a"b'
	if grep -qF 'Office Code: a\"b' "$BODY"; then
		bad "the export escapes a quote in a filter value with a backslash - the field ends early"
	elif grep -qF 'Office Code: a""b' "$BODY"; then
		ok "a quote in a filter value is doubled, as RFC 4180 requires"
	else
		bad "the export did not echo the office filter into the preamble"
	fi

	# The report title line keeps the shape it has always had, so a consumer
	# that skips the preamble by counting one-column rows still works.
	if head -1 "$BODY" | grep -qF '"Daily Intake Report",'; then
		ok "the report title line keeps its one-column shape"
	else
		bad "the report title line changed shape"
	fi

	cleanup_csv
	trap 'rm -f "$COOKIES" "$BODY"' EXIT
else
	printf '  skip the CSV export checks (needs the database)\n'
fi

echo
echo "48. iCal subscription links carry a token, not the password hash"

# cms/ical-subscribe.php built its "for clients without HTTP authentication"
# URL out of base64(serialize(array($user->username, $user->password))).
# $user->password is the stored hash, so the page printed the account's bcrypt
# hash inside a URL and told the user to paste it into Outlook -- from where it
# goes into the calendar client's config file on disk, into browser history,
# and into every proxy log on the way to the server. A bcrypt hash is exactly
# what an offline cracking run wants, and rows that predate the bcrypt
# migration are md5.
#
# The link did not even work. cms/services/calendar.php fed the two halves to
# pikaAuthDb, which compares a submitted password against the stored hash, so
# the hash never matched itself and the URL the subscription page produced
# answered 401 with an empty body. cms/services/calendar-4.php was worse: it
# set PHP_AUTH_USER/PHP_AUTH_PW and then called no authenticator at all, so its
# token block authenticated nothing.
#
# Both files now verify an opaque users.cal_token with hash_equals().
if [ "$HAVE_DB" = 1 ]; then
	IC_SERVICES="${OCM_URL}/services"

	cleanup_ic() {
		adb "DELETE FROM activities WHERE summary LIKE 'ZZIC48%'" >/dev/null
		adb "UPDATE users SET cal_token = NULL WHERE user_id = 1" >/dev/null
		rm -f "${BODY}.ic"
	}
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_ic' EXIT
	cleanup_ic

	ic_next_id() {
		adb "SELECT GREATEST(
			COALESCE((SELECT MAX(${2}) FROM \`${1}\`), 0),
			COALESCE((SELECT count FROM counters WHERE id = '${1}'), 0)) + 1"
	}
	ic_bump_counter() {
		adb "UPDATE counters SET count = GREATEST(count, ${2}) WHERE id = '${1}'" >/dev/null
	}

	# Both feeds select act_type IN ('C','K') from act_date forward, so the
	# fixtures are appointments dated today. One belongs to the admin the token
	# is issued for; the other belongs to a user_id nobody holds, which is what
	# proves the feed is scoped to the token's owner rather than returning the
	# whole calendar.
	IC_ACT="$(ic_next_id activities act_id)"
	adb "INSERT INTO activities (act_id, act_date, act_time, act_type, completed, user_id, summary, notes)
		VALUES (${IC_ACT}, CURDATE(), '09:00:00', 'C', 0, 1, 'ZZIC48MINE', 'ZZIC48MINE notes')" >/dev/null
	ic_bump_counter activities "$IC_ACT"

	IC_ACT2="$(ic_next_id activities act_id)"
	adb "INSERT INTO activities (act_id, act_date, act_time, act_type, completed, user_id, summary, notes)
		VALUES (${IC_ACT2}, CURDATE(), '10:00:00', 'C', 0, 999999, 'ZZIC48OTHER', 'ZZIC48OTHER notes')" >/dev/null
	ic_bump_counter activities "$IC_ACT2"

	IC_AUDIT_BEFORE="$(adb "SELECT COALESCE(MAX(audit_id), 0) FROM audit_log")"

	curl -s -b "$COOKIES" "${OCM_URL}/ical-subscribe.php" > "$BODY"

	if grep -qF -- '$2y$' "$BODY" || grep -qF -- '$2a$' "$BODY"
	then
		bad "the subscription page prints a bcrypt hash"
	else
		ok "the subscription page prints no password hash"
	fi

	# The old credential pair was base64 encoded on its way into the URL, so
	# grepping the page for a bcrypt prefix does not find it. Pull whatever the
	# token link carries, decode it, and look inside.
	IC_RAW="$(grep -oE 'calendar\.php\?[^\"'"'"' <>]*token=[A-Za-z0-9+/=]+' "$BODY" \
		| head -1 | sed 's/.*token=//')"
	IC_DECODED="$(printf '%s' "$IC_RAW" | base64 -d 2>/dev/null | tr -d '\0')"

	if printf '%s' "$IC_DECODED" | grep -qF -- 'a:2:{i:0;s:' \
		|| printf '%s' "$IC_DECODED" | grep -qF -- '$2y$' \
		|| printf '%s' "$IC_DECODED" | grep -qF -- '$2a$'
	then
		bad "the token in the link decodes to a serialized credential pair"
	else
		ok "the token in the link decodes to no credential of any kind"
	fi

	IC_LINK="$(grep -oE 'calendar\.php\?user_id=[0-9]+&token=[0-9a-f]{64}' "$BODY" | head -1)"
	IC_TOKEN="${IC_LINK##*token=}"
	IC_UID="${IC_LINK#*user_id=}"
	IC_UID="${IC_UID%%&*}"

	if [ -n "$IC_TOKEN" ]
	then
		ok "the subscription page offers a 64 hex character token link"
	else
		bad "the subscription page offers no token link"
	fi

	IC_STORED="$(adb "SELECT COALESCE(cal_token, '') FROM users WHERE user_id = 1")"

	if [ -n "$IC_TOKEN" ] && [ "$IC_STORED" = "$IC_TOKEN" ]
	then
		ok "the token in the link is the one stored in users.cal_token"
	else
		bad "users.cal_token does not match the token in the link"
	fi

	# No cookie jar on any of these: a calendar client has no session, which is
	# the whole reason the token exists.
	IC_CODE="$(curl -s -o "${BODY}.ic" -w '%{http_code}' \
		"${IC_SERVICES}/calendar.php?user_id=${IC_UID}&token=${IC_TOKEN}")"

	if [ "$IC_CODE" = 200 ]
	then
		ok "a valid token returns the feed without a session (was 401)"
	else
		bad "a valid token returned HTTP ${IC_CODE}"
	fi

	if grep -qF 'BEGIN:VCALENDAR' "${BODY}.ic"
	then
		ok "the token feed is a calendar document"
	else
		bad "the token feed is not a calendar document"
	fi

	if grep -qF 'ZZIC48MINE' "${BODY}.ic"
	then
		ok "the token feed carries the token owner's appointment"
	else
		bad "the token feed is missing the token owner's appointment"
	fi

	if grep -qF 'ZZIC48OTHER' "${BODY}.ic"
	then
		bad "the token feed carries another user's appointment"
	else
		ok "the token feed is scoped to the token owner"
	fi

	IC_CODE="$(curl -s -o /dev/null -w '%{http_code}' \
		"${IC_SERVICES}/calendar.php?user_id=${IC_UID}&token=$(printf 'f%.0s' $(seq 64))")"

	if [ "$IC_CODE" = 401 ]
	then
		ok "a wrong token is refused"
	else
		bad "a wrong token returned HTTP ${IC_CODE}"
	fi

	# The token is bound to the row it was issued from, so presenting it for a
	# different account has to fail even though the token itself is genuine.
	IC_CODE="$(curl -s -o /dev/null -w '%{http_code}' \
		"${IC_SERVICES}/calendar.php?user_id=999999&token=${IC_TOKEN}")"

	if [ "$IC_CODE" = 401 ]
	then
		ok "a valid token presented for another account is refused"
	else
		bad "a valid token for another account returned HTTP ${IC_CODE}"
	fi

	IC_CODE="$(curl -s -o /dev/null -w '%{http_code}' \
		"${IC_SERVICES}/calendar.php?user_id=${IC_UID}&token=abc")"

	if [ "$IC_CODE" = 401 ]
	then
		ok "a short token is refused before any comparison"
	else
		bad "a short token returned HTTP ${IC_CODE}"
	fi

	IC_CODE="$(curl -s -o /dev/null -w '%{http_code}' "${IC_SERVICES}/calendar.php")"

	if [ "$IC_CODE" = 401 ]
	then
		ok "the feed still demands HTTP authentication when no token is given"
	else
		bad "the tokenless feed returned HTTP ${IC_CODE}"
	fi

	# calendar-4.php is the v4-era copy. Its token block used to authenticate
	# nothing, so this URL used to be answered by the login page.
	IC_CODE="$(curl -s -o "${BODY}.ic" -w '%{http_code}' \
		"${IC_SERVICES}/calendar-4.php?user_id=${IC_UID}&token=${IC_TOKEN}")"

	if [ "$IC_CODE" = 200 ] && grep -qF 'ZZIC48MINE' "${BODY}.ic"
	then
		ok "the v4 feed serves a token holder its own appointments"
	else
		bad "the v4 feed returned HTTP ${IC_CODE} for a valid token"
	fi

	IC_CODE="$(curl -s -o /dev/null -w '%{http_code}' \
		"${IC_SERVICES}/calendar-4.php?user_id=${IC_UID}&token=$(printf 'f%.0s' $(seq 64))")"

	if [ "$IC_CODE" = 401 ]
	then
		ok "the v4 feed refuses a wrong token"
	else
		bad "the v4 feed returned HTTP ${IC_CODE} for a wrong token"
	fi

	# Rotating the token on every visit to the subscription page would silently
	# break a subscription already configured in a phone, so the page reissues
	# the stored value instead of minting a new one.
	curl -s -b "$COOKIES" -o /dev/null "${OCM_URL}/ical-subscribe.php"
	IC_STORED2="$(adb "SELECT COALESCE(cal_token, '') FROM users WHERE user_id = 1")"

	if [ -n "$IC_STORED2" ] && [ "$IC_STORED2" = "$IC_STORED" ]
	then
		ok "revisiting the subscription page keeps the existing token"
	else
		bad "the subscription page rotated the token and broke live subscriptions"
	fi

	IC_REJECTED="$(adb "SELECT COUNT(*) FROM audit_log
		WHERE audit_id > ${IC_AUDIT_BEFORE} AND action = 'ical.token_rejected'")"

	if [ "${IC_REJECTED:-0}" -ge 1 ]
	then
		ok "a refused token is recorded in the audit log"
	else
		bad "a refused token left no audit record"
	fi

	cleanup_ic
	trap 'rm -f "$COOKIES" "$BODY"' EXIT
else
	printf '  skip the iCal subscription token checks (needs the database)\n'
fi

echo
echo "60. the session address and user-agent pin"
# ── 60. The session address and user-agent pin ─────────────────────────────
# pikaAuth::authenticate() pins a signed-in session to the client address and
# the browser it was created from. The historical test was
#
#     $row['ip_address'] == $this->ip_address || $row['user_agent'] == $this->user_agent
#
# which is not a pin at all. A user agent is a request header the client picks,
# so an attacker replaying a captured session cookie sets it to the victim's
# value and the address half never runs; and in the other direction anyone
# sharing the victim's address -- an office NAT, a shared VPN egress, the
# Docker bridge -- got in with any user agent at all. Either half alone
# defeated the whole check (CWE-613).
#
# Both halves are required now, and the address half compares the network
# (/24 for IPv4, /64 for IPv6) rather than the exact host so that a caseworker
# whose carrier NAT moves them mid-session is not signed out. An organisation
# that cannot hold an address range still can keep only the user-agent half
# with the session_ip_pin setting.
if [ "$HAVE_DB" = 1 ]; then
	SPUA='OCM-SMOKE-SESSION-PIN-UA'
	SPJAR="$(mktemp)"
	SPPIN="$(adb "SELECT COALESCE(value, '') FROM settings WHERE label = 'session_ip_pin'")"

	cleanup_sp() {
		adb "DELETE FROM user_sessions WHERE user_agent = '${SPUA}'" >/dev/null
		if [ -n "${SPPIN:-}" ]; then
			adb "UPDATE settings SET value = '${SPPIN}' WHERE label = 'session_ip_pin'" >/dev/null
		fi
		rm -f "$SPJAR"
	}
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_sp' EXIT
	adb "DELETE FROM user_sessions WHERE user_agent = '${SPUA}'" >/dev/null

	# Replay the session cookie with a given user agent and say whether the
	# request came back signed in or at the login form.
	sp_replay() {
		curl -sL --max-time 30 -A "$1" -b "$SPJAR" -o "$BODY" "$OCM_URL/case_list.php" >/dev/null
		if grep -q 'login_pass' "$BODY"; then
			echo refused
		else
			echo accepted
		fi
	}

	: > "$SPJAR"
	curl -sL --max-time 30 -A "$SPUA" -c "$SPJAR" -b "$SPJAR" -o "$BODY" \
		-X POST -d "login_user=admin&login_pass=${OCM_PASSWORD}&auth_id=1" \
		"$OCM_URL/" >/dev/null

	SPID="$(adb "SELECT user_session_id FROM user_sessions
		WHERE user_agent = '${SPUA}' ORDER BY user_session_id DESC LIMIT 1")"
	SPIP="$(adb "SELECT COALESCE(ip_address, '') FROM user_sessions
		WHERE user_session_id = '${SPID}'")"

	if [ -z "$SPID" ] || [ -z "$SPIP" ]; then
		bad "could not mint a pinned session to test (id='${SPID}' ip='${SPIP}')"
	else
		ok "a login records the client address and user agent on the session"

		# The control. If this ever fails the rest of the section is noise.
		if [ "$(sp_replay "$SPUA")" = accepted ]; then
			ok "the session continues from the same address and browser"
		else
			bad "the session does not continue from its own address and browser"
		fi

		# A stolen cookie replayed from a different browser. Before the fix
		# this was accepted, because the address half matched.
		if [ "$(sp_replay 'SMOKE-DIFFERENT-ATTACKER-UA')" = refused ]; then
			ok "the session is refused to a different user agent"
		else
			bad "A SESSION COOKIE IS ACCEPTED FROM A DIFFERENT USER AGENT (CWE-613)"
		fi

		# The other direction: the browser matches but the address does not.
		# Before the fix this was accepted too, so neither half held.
		adb "UPDATE user_sessions SET ip_address = '203.0.113.7'
			WHERE user_session_id = '${SPID}'" >/dev/null
		if [ "$(sp_replay "$SPUA")" = refused ]; then
			ok "the session is refused from a foreign network"
		else
			bad "A SESSION COOKIE IS ACCEPTED FROM A FOREIGN NETWORK (CWE-613)"
		fi

		# ... but the pin is on the network, not the host, so a client whose
		# address moved inside its own /24 keeps working. Without this an
		# exact-match pin signs out every user on carrier NAT.
		case "$SPIP" in
			*.*.*.*)
				adb "UPDATE user_sessions SET ip_address = '${SPIP%.*}.99'
					WHERE user_session_id = '${SPID}'" >/dev/null
				if [ "$(sp_replay "$SPUA")" = accepted ]; then
					ok "the session survives a new address on the same /24"
				else
					bad "the pin is host-exact, which signs out clients on rotating NAT"
				fi
				;;
			*)
				printf '  skip the /24 check (the client address is not IPv4)\n'
				;;
		esac

		# An operator whose address will not hold still can keep only the
		# user-agent half.
		adb "UPDATE user_sessions SET ip_address = '203.0.113.7'
			WHERE user_session_id = '${SPID}'" >/dev/null
		adb "UPDATE settings SET value = '0' WHERE label = 'session_ip_pin'" >/dev/null
		if [ "$(sp_replay "$SPUA")" = accepted ]; then
			ok "session_ip_pin off keeps only the user-agent half of the pin"
		else
			bad "session_ip_pin off does not release the address half"
		fi

		# With the address half off, the user-agent half must still hold.
		if [ "$(sp_replay 'SMOKE-DIFFERENT-ATTACKER-UA')" = refused ]; then
			ok "session_ip_pin off still refuses a different user agent"
		else
			bad "session_ip_pin off drops the user-agent half as well"
		fi

		# A value this build does not recognise -- 'network', which is what a
		# Ciprocity install writes -- must enforce, not fail open.
		adb "UPDATE settings SET value = 'network' WHERE label = 'session_ip_pin'" >/dev/null
		if [ "$(sp_replay "$SPUA")" = refused ]; then
			ok "an unrecognised session_ip_pin value enforces the pin"
		else
			bad "an unrecognised session_ip_pin value fails open"
		fi

		# And so must a missing row, so that an installation which has not
		# applied add_session_ip_pin.sql is still protected.
		adb "DELETE FROM settings WHERE label = 'session_ip_pin'" >/dev/null
		if [ "$(sp_replay "$SPUA")" = refused ]; then
			ok "a missing session_ip_pin row enforces the pin"
		else
			bad "a missing session_ip_pin row fails open"
		fi
		adb "INSERT INTO settings (label, value) VALUES ('session_ip_pin', '1')" >/dev/null

		# The admin screen can carry the setting, or an operator cannot reach it.
		curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" "$OCM_URL/system-settings.php" >/dev/null
		if grep -q 'name="session_ip_pin"' "$BODY"; then
			ok "system-settings.php offers the session pin control"
		else
			bad "system-settings.php has no session pin control"
		fi
	fi

	cleanup_sp
	trap 'rm -f "$COOKIES" "$BODY"' EXIT
else
	printf '  skip the session pin checks (needs the database)\n'
fi


echo
echo "61. how a stored document is served back"

# ── 61. Stored documents: content type, disposition and the file name ───────
#
# A document's content type is whatever the uploading browser claimed in
# $_FILES['doc_upload']['type']; pikaDocument::uploadDoc() stores it verbatim.
# cms/documents.php echoed it back with Content-Disposition: inline, so a
# caseworker who may upload to one case could store an .html file and have it
# served as text/html from the application's own origin -- running script in
# the session of every user who opened it. CWE-79 by way of CWE-434.
#
# Inline is now kept only for types that render but cannot execute script in
# our origin: application/pdf, text/plain, and image/* except image/svg+xml.
# The doc_force_download setting drops even those to attachment.
#
# Separately, the delete confirmation rendered the file name through a plain
# %%[doc_name]%% tag, which is substituted raw, and no input filter touches an
# uploaded file name.
if [ "$HAVE_DB" = 1 ]; then
	DLJAR="$(mktemp)"

	cleanup_dl() {
		adb "DELETE FROM doc_storage WHERE doc_name LIKE 'ZZDL%' OR description = 'ZZDL upload'" >/dev/null
		adb "DELETE FROM cases WHERE number = 'ZZ-DL-1'" >/dev/null
		adb "UPDATE settings SET value = '${DLFORCE:-0}' WHERE label = 'doc_force_download'" >/dev/null
		rm -f "$DLJAR"
	}
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_dl' EXIT

	# Remember the operator's own setting before the checks move it about.
	DLFORCE="$(adb "SELECT value FROM settings WHERE label = 'doc_force_download'")"
	cleanup_dl

	dl_next_id() {
		adb "SELECT GREATEST(
			COALESCE((SELECT MAX(${2}) FROM \`${1}\`), 0),
			COALESCE((SELECT count FROM counters WHERE id = '${1}'), 0)) + 1"
	}
	dl_bump_counter() {
		adb "UPDATE counters SET count = GREATEST(count, ${2}) WHERE id = '${1}'" >/dev/null
	}

	DLCASE="$(dl_next_id cases case_id)"
	adb "INSERT INTO cases (case_id, number, user_id, office, status, intake_user_id)
		VALUES (${DLCASE}, 'ZZ-DL-1', 1, 'ZZDLOF', '1', 1)" >/dev/null
	dl_bump_counter cases "$DLCASE"

	# doc_data is gzcompress()ed binary, so PHP inside the container writes the
	# UPDATE and mariadb reads it back rather than passing it through a shell.
	dl_seed_body() {
		docker compose "${COMPOSE_ARGS[@]}" exec -T app php -r '
			file_put_contents("/tmp/zzdldoc.sql",
				"UPDATE doc_storage SET doc_data=\x27"
				. addslashes(gzcompress($argv[2]))
				. "\x27 WHERE doc_id=" . $argv[1] . ";");
		' "$1" "$2" </dev/null
		docker compose "${COMPOSE_ARGS[@]}" exec -T app \
			sh -c 'cat /tmp/zzdldoc.sql' </dev/null > "$BODY"
		docker compose "${COMPOSE_ARGS[@]}" exec -T \
			-e MYSQL_PWD="$DB_ROOT_PASSWORD" db \
			mariadb -uroot "$DB_NAME" < "$BODY"
	}

	# dl_seed_doc <doc_name> <mime_type> <body> -> doc_id
	dl_seed_doc() {
		_id="$(dl_next_id doc_storage doc_id)"
		adb "INSERT INTO doc_storage (doc_id, doc_name, doc_type, description, created, case_id, user_id, folder, mime_type)
			VALUES (${_id}, '${1}', 'C', 'ZZDL fixture', CURDATE(), ${DLCASE}, 1, 0, '${2}')" >/dev/null
		dl_bump_counter doc_storage "$_id"
		dl_seed_body "$_id" "$3" >/dev/null 2>&1
		printf '%s' "$_id"
	}

	# The Content-Disposition word for one document, or the empty string.
	dl_disp() {
		curl -sL --max-time 30 -b "$COOKIES" -D - -o /dev/null \
			"$OCM_URL/documents.php?doc_id=${1}&action=download" 2>/dev/null \
			| tr -d '\r' | grep -i '^content-disposition:' \
			| head -1 | sed -E 's/^[Cc]ontent-[Dd]isposition:[[:space:]]*([a-zA-Z]+).*/\1/'
	}

	dl_token() {
		curl -sL --max-time 30 -c "$COOKIES" -b "$COOKIES" "$OCM_URL/password.php" \
			| grep -oE 'name="_csrf" value="[0-9a-f]{64}"' \
			| head -1 | sed -e 's/.*value="//' -e 's/"$//'
	}

	# 61a. The premise: the client picks the content type and it is kept.
	# The name carries markup too, which check 61i reads back.
	DLUP="$(mktemp)"
	printf '<script>document.title="ZZDL-XSS"</script>\n' > "$DLUP"
	DLTOKEN="$(dl_token)"
	curl -sL --max-time 60 -c "$COOKIES" -b "$COOKIES" -o /dev/null \
		-F "doc_upload=@${DLUP};filename=ZZDL<img src=x onerror=alert(1)>.html;type=text/html" \
		-F 'doc_type=C' -F "case_id=${DLCASE}" -F 'description=ZZDL upload' \
		-F "_csrf=${DLTOKEN}" \
		"$OCM_URL/ops/upload_document.php" >/dev/null
	rm -f "$DLUP"
	DLHTML="$(adb "SELECT doc_id FROM doc_storage WHERE description = 'ZZDL upload' ORDER BY doc_id DESC LIMIT 1")"
	DLMIME="$(adb "SELECT mime_type FROM doc_storage WHERE doc_id = '${DLHTML:-0}'")"
	if [ "$DLMIME" = "text/html" ]; then
		ok "an uploader's declared content type is stored verbatim (text/html)"
	else
		bad "could not seed the uploaded document (doc_id='${DLHTML:-}', mime_type='${DLMIME:-}')"
	fi

	DLPDF="$(dl_seed_doc 'ZZDLfile.pdf'  'application/pdf'  'ZZDL-PDF-BODY')"
	DLSVG="$(dl_seed_doc 'ZZDLfile.svg'  'image/svg+xml'    '<svg xmlns="http://www.w3.org/2000/svg"><script>1</script></svg>')"
	DLPNG="$(dl_seed_doc 'ZZDLfile.png'  'image/png'        'ZZDL-PNG-BODY')"

	# 61b. The vulnerability itself.
	if [ -n "${DLHTML:-}" ] && [ "$(dl_disp "$DLHTML")" = "attachment" ]; then
		ok "an HTML document downloads instead of rendering in the origin"
	else
		bad "AN UPLOADED text/html DOCUMENT IS SERVED INLINE — stored XSS in the app origin (CWE-79/CWE-434)"
	fi

	# 61c. And the fix must not have broken the download itself.
	curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" \
		"$OCM_URL/documents.php?doc_id=${DLHTML:-0}&action=download" >/dev/null
	if grep -q 'ZZDL-XSS' "$BODY"; then
		ok "the document's bytes still come back intact"
	else
		bad "the document body did not come back — the download path is broken"
	fi

	# 61d. An <svg> may carry <script> that runs same-origin, so image/ alone
	# is not enough of a reason to render one inline.
	if [ "$(dl_disp "$DLSVG")" = "attachment" ]; then
		ok "an SVG downloads rather than rendering (it can carry script)"
	else
		bad "AN image/svg+xml DOCUMENT IS SERVED INLINE — an <svg> can run script in this origin"
	fi

	# 61e/61f. Controls: preview is what the application is for, and the two
	# types staff actually preview must still open in the browser.
	if [ "$(dl_disp "$DLPDF")" = "inline" ]; then
		ok "a PDF still previews in the browser"
	else
		bad "a PDF no longer previews — the allowlist is too narrow"
	fi

	if [ "$(dl_disp "$DLPNG")" = "inline" ]; then
		ok "a raster image still previews in the browser"
	else
		bad "a raster image no longer previews — the allowlist is too narrow"
	fi

	# 61g. The declared type is still the uploader's word, so the response says
	# not to sniff the body. documents.php sets this itself rather than relying
	# on the vhost, because this is the one response whose body is user bytes.
	if curl -sL --max-time 30 -b "$COOKIES" -D - -o /dev/null \
		"$OCM_URL/documents.php?doc_id=${DLPNG}&action=download" 2>/dev/null \
		| tr -d '\r' | grep -qi '^x-content-type-options:[[:space:]]*nosniff'; then
		ok "the download response carries X-Content-Type-Options: nosniff"
	else
		bad "the download response has no nosniff header — a lying content type may be sniffed"
	fi

	# 61h. The strict posture, for an organisation that wants no preview at all.
	adb "DELETE FROM settings WHERE label = 'doc_force_download'" >/dev/null
	adb "INSERT INTO settings (label, value) VALUES ('doc_force_download', '1')" >/dev/null
	if [ "$(dl_disp "$DLPDF")" = "attachment" ]; then
		ok "doc_force_download makes even a PDF an attachment"
	else
		bad "doc_force_download did not force the download"
	fi

	# 61i. And a missing row is the ordinary install, not the strict one: the
	# allowlist is what closes the hole, so absent must not mean "no preview".
	adb "DELETE FROM settings WHERE label = 'doc_force_download'" >/dev/null
	if [ "$(dl_disp "$DLPDF")" = "inline" ]; then
		ok "a missing doc_force_download row leaves the allowlist in charge"
	else
		bad "a missing doc_force_download row changed the disposition"
	fi
	adb "INSERT INTO settings (label, value) VALUES ('doc_force_download', '${DLFORCE:-0}')" >/dev/null

	# 61j. The delete confirmation prints the file name through a plain
	# %%[doc_name]%% tag, and nothing filters an uploaded file name.
	curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" \
		"$OCM_URL/documents.php?doc_id=${DLHTML:-0}&action=confirm_delete" >/dev/null
	if grep -q 'ZZDL' "$BODY" && ! grep -qF '<img src=x onerror=' "$BODY"; then
		ok "the delete confirmation escapes markup in a file name"
	else
		bad "THE DELETE CONFIRMATION RENDERS AN UPLOADED FILE NAME RAW — stored XSS (CWE-79)"
	fi

	# 61k. The operator can find the setting.
	curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" "$OCM_URL/system-settings.php" >/dev/null
	if grep -q 'doc_force_download' "$BODY"; then
		ok "system-settings.php offers the document download control"
	else
		bad "system-settings.php has no doc_force_download control"
	fi

	# 61l. And the container sends the header globally, not only on downloads.
	# httpd-config/ocm.conf documented these for a hand-rolled Apache; the
	# image shipped without them.
	curl -sL --max-time 30 -b "$COOKIES" -D - -o /dev/null "$OCM_URL/case_list.php" 2>/dev/null \
		| tr -d '\r' > "$BODY"
	if grep -qi '^x-content-type-options:[[:space:]]*nosniff' "$BODY" \
		&& grep -qi '^x-frame-options:' "$BODY"; then
		ok "the server sends nosniff and X-Frame-Options on ordinary pages"
	else
		bad "ordinary pages carry no nosniff / X-Frame-Options header"
	fi

	cleanup_dl
	trap 'rm -f "$COOKIES" "$BODY"' EXIT
else
	printf '  skip the stored-document download checks (needs the database)\n'
fi

echo
# ── 63. Retired legacy questionnaire actions ───────────────────────────────
echo "63. retired questionnaire actions are rejected"

# Include the old forms' fields so an accidentally restored handler cannot
# pass just because its input is missing. Negative IDs avoid real records.
for rq_action in save_questionnaire add_questionnaire toggle_questionnaires diag update_answers; do
	curl -sL --max-time 30 -c "$COOKIES" -b "$COOKIES" -o "$BODY" \
		"$OCM_URL/password.php" >/dev/null
	rq_token="$(grep -oE 'name="_csrf" value="[0-9a-f]{64}"' "$BODY" \
		| head -1 | sed -e 's/.*value="//' -e 's/"$//')"
	if [ "${#rq_token}" -ne 64 ]; then
		bad "$rq_action cannot be checked: no admin CSRF token"
		continue
	fi
	code="$(curl -s --max-time 30 -b "$COOKIES" -o "$BODY" -w '%{http_code}' \
		--data-urlencode "action=${rq_action}" -d "_csrf=${rq_token}" \
		--data-urlencode "title=ZZ retired questionnaire's title" \
		--data-urlencode "values=ZZ retired questionnaire's question" \
		-d 'code=01&sp_code=&questionnaire=-1&questionnaire_id=-1&init=1' \
		-d 'q[-1]=1&todo=deactivate&completed_id=-1' \
		--data-urlencode "answers[-1]=ZZ retired questionnaire's answer | 1" \
		--data-urlencode 'resp[probe]=ZZ-RETIRED-QUESTIONNAIRE-DEBUG' \
		"$OCM_URL/system-ops.php")"
	if [ "$code" = 200 ] && grep -q 'invalid action was specified' "$BODY" \
		&& ! grep -qiE 'Fatal error|Warning:|SQLSTATE|SQL syntax|q_questionnaires|q_questions|q_answers|ZZ-RETIRED-QUESTIONNAIRE-DEBUG|CSRF validation failed|Confirm your save' "$BODY"; then
		ok "$rq_action is an invalid action without SQL or debug output"
	else
		bad "$rq_action was not cleanly rejected as an invalid action (status $code)"
	fi

	code="$(curl -s --max-time 30 -b "$COOKIES" -o "$BODY" -w '%{http_code}' \
		--data-urlencode "action=${rq_action}" "$OCM_URL/system-ops.php")"
	if [ "$code" = 403 ] && grep -q 'CSRF validation failed' "$BODY"; then
		ok "$rq_action still requires a CSRF token"
	else
		bad "$rq_action bypassed the CSRF gate (status $code)"
	fi
done

echo
# ── 64. OCM9 lookup and report backports ───────────────────────────────────
echo "64. bound case/contact lookups and HTML reports"
if [ "$HAVE_DB" = 1 ]; then
	if docker compose "${COMPOSE_ARGS[@]}" exec -T app php \
		< "${SMOKE_DIR}/fixtures/zz_test_ocm9_backports.php" > "$BODY" 2>&1; then
		ok "OCM9 lookup and report regression fixture passes"
	else
		bad "OCM9 lookup and report regression fixture failed"
		cat "$BODY"
	fi
else
	printf '  skip the OCM9 regression fixture (needs the app container)\n'
fi

echo
# ── 65. The retired save_quest data operation ──────────────────────────────
echo "65. the retired save_quest action is rejected"

# save_quest read $_REQUEST, so it also answered a GET, which the POST-only
# CSRF gate at the top of dataops.php never covered. Both shapes are checked.
# The payload carries a quote so a surviving handler would print a SQL error.
SQ_HEADERS="$(mktemp)"
SQ_INJECT="-1 UNION SELECT 1--'"

curl -sL --max-time 30 -c "$COOKIES" -b "$COOKIES" -o "$BODY" \
	"$OCM_URL/password.php" >/dev/null
sq_token="$(grep -oE 'name="_csrf" value="[0-9a-f]{64}"' "$BODY" \
	| head -1 | sed -e 's/.*value="//' -e 's/"$//')"

if [ "${#sq_token}" -ne 64 ]; then
	bad "save_quest cannot be checked: no admin CSRF token"
else
	code="$(curl -s --max-time 30 -b "$COOKIES" -o "$BODY" -D "$SQ_HEADERS" \
		-w '%{http_code}' \
		-d "action=save_quest&_csrf=${sq_token}" \
		--data-urlencode "questionnaire_id=${SQ_INJECT}" \
		--data-urlencode "case_id=${SQ_INJECT}" \
		--data-urlencode "completed_id=${SQ_INJECT}" \
		--data-urlencode "answer_id=${SQ_INJECT}" \
		--data-urlencode 'response_text=ZZ-SAVEQUEST-DEBUG' \
		-d 'q_action=next&answer=1' \
		"$OCM_URL/dataops.php")"
	if [ "$code" = 200 ] && grep -q 'invalid action was specified' "$BODY"; then
		ok "a POSTed save_quest is an invalid action"
	else
		bad "a POSTed save_quest was not rejected as an invalid action (status $code)"
	fi
	if grep -q 'invalid action was specified' "$BODY" \
		&& ! grep -qiE 'Fatal error|Warning:|Notice:|SQLSTATE|SQL syntax|q_completed|q_responses|ZZ-SAVEQUEST-DEBUG' "$BODY"; then
		ok "the rejection prints no SQL, no warning and no echoed statement"
	else
		bad "save_quest still reached the questionnaire tables or printed a diagnostic"
	fi
	if grep -q 'invalid action was specified' "$BODY" \
		&& ! grep -qi 'quest_answer.php' "$SQ_HEADERS" "$BODY"; then
		ok "nothing redirects to the quest_answer.php page this tree does not have"
	else
		bad "save_quest still redirects to quest_answer.php"
	fi
fi

# The GET shape, which never needed a token in the first place.
code="$(curl -s --max-time 30 -b "$COOKIES" -o "$BODY" -D "$SQ_HEADERS" \
	-w '%{http_code}' -G \
	--data-urlencode 'action=save_quest' \
	--data-urlencode "questionnaire_id=${SQ_INJECT}" \
	--data-urlencode "case_id=${SQ_INJECT}" \
	"$OCM_URL/dataops.php")"
if [ "$code" = 200 ] && grep -q 'invalid action was specified' "$BODY"; then
	ok "a GET save_quest is an invalid action too"
else
	bad "a GET save_quest was not rejected as an invalid action (status $code)"
fi
if grep -q 'invalid action was specified' "$BODY" \
	&& ! grep -qiE 'SQLSTATE|SQL syntax|q_completed|q_responses|quest_answer.php' "$BODY" \
	&& ! grep -qi 'quest_answer.php' "$SQ_HEADERS"; then
	ok "the GET shape reaches no questionnaire query and no redirect"
else
	bad "the GET shape still ran the questionnaire handler"
fi

code="$(curl -s --max-time 30 -b "$COOKIES" -o "$BODY" -w '%{http_code}' \
	-d 'action=save_quest' "$OCM_URL/dataops.php")"
if [ "$code" = 403 ] && grep -q 'CSRF validation failed' "$BODY"; then
	ok "a POSTed save_quest still meets the CSRF gate first"
else
	bad "save_quest bypassed the CSRF gate (status $code)"
fi

rm -f "$SQ_HEADERS"

echo
# ── 66. A failed database query ─────────────────────────────────────────────
echo "66. a failed query answers an error page, not a blank one"

# PHP 8.1 made mysqli throw instead of returning false, so every failed query
# raises mysqli_sql_exception. Nothing in the tree catches it and there was no
# exception handler, so the user got status 500 with a zero-byte body and the
# server log got a PHP fatal rather than a Pika error record. The `or
# trigger_error()` calls after DB::query() were the old handling and no longer
# run; the ones written with no argument would have died on an
# ArgumentCountError if they had.
#
# The break is a renamed table, so the restore has to survive an interrupt.
# This is the last section for that reason: nothing after it depends on the
# table being there.
cleanup_exc() {
	adb "RENAME TABLE outcomes_zzhidden TO outcomes" >/dev/null 2>&1
}
trap 'rm -f "$COOKIES" "$BODY"; cleanup_exc' EXIT

EXC_REPORT="reports/outcomes/report.php"

if [ "$HAVE_DB" != 1 ]; then
	echo "  skip the failed-query checks: no database access"
else
	code="$(curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" -w '%{http_code}' \
		"$OCM_URL/$EXC_REPORT")"
	if [ "$code" = 200 ]; then
		ok "the outcomes report renders before the table is taken away"
	else
		bad "the outcomes report answered $code before the break; the rest of this section proves nothing"
	fi

	# Where the log read at the end of this section starts. It reads only what
	# the container logged after this point, because the recovery request that
	# follows the broken one writes log lines of its own and a fixed tail
	# window can push the record it is looking for out of sight. A run where
	# that happens is a green suite reporting a red check.
	#
	# The boundary is elapsed seconds, not a line count and not a wall-clock
	# time. A line count says nothing about which lines are still there: if the
	# log rotates, the same count can point at a record an earlier section left
	# behind, and a snapshot that failed leaves a count of zero, which reads
	# the whole log. A time read from this host would be compared against the
	# container's clock. Seconds-ago is measured by the clock that writes the
	# log.
	EXC_SECONDS0="$SECONDS"
	
	adb "RENAME TABLE outcomes TO outcomes_zzhidden" >/dev/null
	exc_code="$(curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" -w '%{http_code}' \
		"$OCM_URL/$EXC_REPORT")"
	exc_bytes="$(wc -c < "$BODY")"
	cleanup_exc

	if [ "$exc_bytes" -gt 0 ]; then
		ok "a failed query answers a body, not a blank page ($exc_bytes bytes)"
	else
		bad "a failed query answered ${exc_code} with a zero-byte body"
	fi

	if grep -qi 'could not complete your request' "$BODY"; then
		ok "the failure page carries the generic administrator message"
	else
		bad "the failure page does not carry the generic message ($exc_bytes bytes, status $exc_code)"
	fi

	if [ "$exc_code" = 500 ]; then
		ok "a failed query still answers 500, not a success code"
	else
		bad "a failed query answered ${exc_code}, not 500"
	fi

	if grep -q 'outcomes_zzhidden' "$BODY"; then
		bad "the failure page NAMES THE MISSING TABLE (schema disclosure)"
	else
		ok "the failure page does not name the missing table"
	fi

	if grep -qi 'mysqli_sql_exception\|DB\.php' "$BODY"; then
		bad "the failure page LEAKS THE EXCEPTION CLASS OR THE FAILING FILE"
	else
		ok "the failure page leaks neither the exception class nor the failing file"
	fi

	code="$(curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" -w '%{http_code}' \
		"$OCM_URL/$EXC_REPORT")"
	if [ "$code" = 200 ]; then
		ok "the outcomes report renders again once the table is back"
	else
		bad "the outcomes report answered $code after the restore; the table may still be renamed"
	fi

	if [ "$HAVE_COMPOSE" = 1 ]; then
		# Only what the log gained since the boundary above, so this cannot
		# pass on a record an earlier section left behind, and cannot fail
		# because a later request pushed the record out of a fixed window. Two
		# seconds are added because the boundary is whole seconds and the break
		# happened inside one of them.
		EXC_WINDOW="$((SECONDS - EXC_SECONDS0 + 2))"
		EXC_LOG="$(docker compose "${COMPOSE_ARGS[@]}" logs --no-color \
			--since "${EXC_WINDOW}s" app 2>&1)"
		EXC_LOG_LINES="$(printf '%s\n' "$EXC_LOG" | wc -l)"
		# grep reads the string directly rather than through a pipe. grep -q
		# stops at its first match, which kills the producer with SIGPIPE, and
		# under pipefail a killed producer fails the whole pipeline -- so
		# finding the record would have reported that there was none, once the
		# log grew past a pipe buffer.
		if grep -q 'uncaught_exception' <<<"$EXC_LOG"; then
			ok "the operator still gets the whole detail in the server log"
		else
			bad "the failed query left no uncaught_exception record in the ${EXC_LOG_LINES} log lines of the last ${EXC_WINDOW} seconds"
		fi
	fi
fi

echo
# ── 67. The Content-Security-Policy header ─────────────────────────────────
echo "67. the Content-Security-Policy header"

# The application shipped no CSP at all. pl_send_csp_header() emits one from
# PHP -- not from docker/apache.conf, which is baked into the image -- so an
# install that is not using the shipped image gets it too.
#
# csp_mode picks enforce / report_only / off. A MISSING row must read as
# enforce, so an install that never opens the settings screen is protected;
# that is the case worth a check of its own.
cleanup_csp() {
	adb "DELETE FROM settings WHERE label = 'csp_mode'" >/dev/null 2>&1
	adb "INSERT IGNORE INTO settings (label, value) VALUES ('csp_mode', 'enforce')" \
		>/dev/null 2>&1
}
trap 'rm -f "$COOKIES" "$BODY"; cleanup_csp' EXIT

CSP_HEADERS="$(mktemp)"
csp_header() {
	curl -s --max-time 30 -b "$COOKIES" -o /dev/null -D "$CSP_HEADERS" \
		"$OCM_URL/index.php"
	grep -i '^content-security-policy' "$CSP_HEADERS" | tr -d '\r'
}

if [ "$HAVE_DB" != 1 ]; then
	echo "  skip the CSP checks: no database access"
else
	adb "UPDATE settings SET value = 'enforce' WHERE label = 'csp_mode'" >/dev/null
	csp="$(csp_header)"

	if printf '%s' "$csp" | grep -qi '^content-security-policy:'; then
		ok "a policy is sent, and it is the enforcing header"
	else
		bad "no enforcing Content-Security-Policy header was sent [${csp}]"
	fi

	# The directives that do the work. Each is checked on its own so a
	# failure names the one that went missing.
	for directive in "object-src 'none'" "base-uri 'self'" \
		"frame-ancestors 'none'" "form-action 'self'" "default-src 'self'"
	do
		if printf '%s' "$csp" | grep -qF -- "$directive"; then
			ok "the policy carries ${directive}"
		else
			bad "the policy is MISSING ${directive}"
		fi
	done

	# script-src now names a per-request nonce and allows neither
	# 'unsafe-inline' nor 'unsafe-eval'. Each half is checked on its own so
	# a failure says which keyword came back.
	#
	# Only the script-src directive is read, not the whole policy, because
	# style-src still carries 'unsafe-inline' for the style="..." attributes
	# and a grep over the whole header would match that and pass.
	csp_script="$(printf '%s' "$csp" | tr ';' '\n' | grep -i 'script-src')"
	
	if printf '%s' "$csp_script" | grep -qF "'nonce-"; then
		ok "script-src names a nonce"
	else
		bad "script-src names NO nonce, so every inline script is blocked [${csp_script}]"
	fi
	
	if printf '%s' "$csp_script" | grep -qF "'unsafe-inline'"; then
		bad "script-src allows 'unsafe-inline' again [${csp_script}]"
	else
		ok "script-src does not allow 'unsafe-inline'"
	fi
	
	if printf '%s' "$csp" | grep -qF "'unsafe-eval'"; then
		bad "the policy allows 'unsafe-eval' again [${csp}]"
	else
		ok "the policy does not allow 'unsafe-eval'"
	fi
	
	# A nonce is only worth anything if it changes. A fixed one is a
	# password the attacker can read off the page they are injecting into,
	# and the header would look exactly the same as a correct one. This is
	# the failure that no amount of reading the policy string can see.
	csp_n1="$(csp_header | grep -oE "'nonce-[^']*'")"
	csp_n2="$(csp_header | grep -oE "'nonce-[^']*'")"
	
	if [ -n "$csp_n1" ] && [ "$csp_n1" != "$csp_n2" ]; then
		ok "the nonce is different on every response"
	else
		bad "the nonce did not change between two requests, so it is not a nonce"
	fi
	
	# And the page has to agree with its own header. Dropping
	# 'unsafe-inline' breaks every inline <script> that does not carry the
	# matching value, and the browser reports that only to its console: the
	# request still returns 200 and the page still renders, just without
	# whatever that script did. Fetch the header and the body in ONE request
	# -- a second request has a different nonce and would fail every time.
	csp_both="$(mktemp)"
	csp_inline=0
	csp_nononce=0
	csp_noheader=0
	
	# Two entry points, not one. timer.php, case.php, index.php and
	# password.php come in through pika-danio.php, which sends the headers
	# from pika_init(). cal_day.php, cal_week.php, assign_atty.php and
	# system-ops.php come in through pika_cms.php, which does not call
	# pika_init() at all - those four were served with no policy until
	# pika_cms.php started sending the headers itself. Both paths are on the
	# list so neither can lose its policy again unnoticed.
	for csp_page in timer.php case.php index.php password.php \
		cal_day.php cal_week.php assign_atty.php system-ops.php
	do
		curl -s --max-time 30 -b "$COOKIES" -D "$CSP_HEADERS" \
			-o "$csp_both" "$OCM_URL/$csp_page"
		
		csp_want="$(grep -i '^content-security-policy' "$CSP_HEADERS" | tr -d '\r' \
			| grep -oE "'nonce-[^']*'" | sed "s/^'nonce-//; s/'\$//")"
		
		if [ -z "$csp_want" ]
		then
			csp_noheader=$((csp_noheader + 1))
			bad "$csp_page sent no nonce in its policy, so its inline scripts are blocked"
			continue
		fi
		
		# Every <script> opening tag on the page, minus the ones with a
		# src: those are fetched from 'self' and need no nonce.
		csp_n="$(grep -oE '<script[^>]*>' "$csp_both" | grep -cv 'src=')"
		csp_b="$(grep -oE '<script[^>]*>' "$csp_both" | grep -v 'src=' \
			| grep -cvF "nonce=\"${csp_want}\"")"
		
		csp_inline=$((csp_inline + csp_n))
		csp_nononce=$((csp_nononce + csp_b))
		
		if [ "$csp_b" -ne 0 ]
		then
			bad "$csp_page has $csp_b inline script block(s) without this response's nonce"
		fi
	done
	
	# Nothing to find means the check is broken, not that the pages are
	# clean: these pages all render %%[NAME.js,javascript]%% tags, which is
	# what an inline script block is here. A zero means the fetches failed,
	# or the grep stopped matching the tag the plugin writes.
	if [ "$csp_inline" -eq 0 ]
	then
		bad "found no inline script block on any page - the nonce check is broken"
	elif [ "$csp_nononce" -eq 0 ]
	then
		ok "all $csp_inline inline script blocks carry their own response's nonce"
	fi
	
	rm -f "$csp_both"

	# The header above is only honest if the eval() calls really are gone,
	# so check the tree as well. A reintroduced eval() under this policy is
	# a silently dead handler, not a failed request, which is exactly the
	# kind of break a header check cannot see.
	csp_eval_files="$(grep -rlF 'eval(' cms/ --include='*.js' --include='*.html' \
		--include='*.php' 2>/dev/null | grep -vF '.min.js' | wc -l)"
	if [ "$csp_eval_files" -eq 0 ]; then
		ok "no eval() call is left in the js or the subtemplates"
	else
		bad "eval() is back in ${csp_eval_files} file(s), which script-src now blocks"
	fi

	if printf '%s' "$csp" | grep -qiE "(script|style|img|font|connect)-src[^;]*https?://"; then
		bad "the policy allows an off-site origin; the tree loads none"
	else
		ok "the policy allows no off-site origin"
	fi

	adb "UPDATE settings SET value = 'report_only' WHERE label = 'csp_mode'" >/dev/null
	csp="$(csp_header)"
	if printf '%s' "$csp" | grep -qi '^content-security-policy-report-only:' \
		&& ! printf '%s' "$csp" | grep -qi '^content-security-policy:'; then
		ok "report_only sends the Report-Only header and not the enforcing one"
	else
		bad "report_only sent the wrong header [${csp}]"
	fi

	adb "UPDATE settings SET value = 'off' WHERE label = 'csp_mode'" >/dev/null
	csp="$(csp_header)"
	if [ -z "$csp" ]; then
		ok "off sends no policy at all"
	else
		bad "off still sent a policy [${csp}]"
	fi

	adb "DELETE FROM settings WHERE label = 'csp_mode'" >/dev/null
	csp="$(csp_header)"
	if printf '%s' "$csp" | grep -qi '^content-security-policy:'; then
		ok "a missing csp_mode row enforces, so a fresh install is covered"
	else
		bad "a missing csp_mode row sent NO ENFORCING POLICY [${csp}]"
	fi

	cleanup_csp
	rm -f "$CSP_HEADERS"
fi

echo
# ── 67b. The rest of the OWASP header set ──────────────────────────────────
echo "67b. the rest of the OWASP response header set"

# pl_send_security_headers() sends the set the OWASP Secure Headers Project
# recommends, of which the CSP checked above is one. These are not conditional
# on csp_mode: turning the policy off is a statement about the policy, not
# permission to stop sending nosniff.
#
# Two of these checks are negative, and they are the ones worth having:
#
#   Strict-Transport-Security must NOT be sent here. This stack is plain HTTP,
#   and a browser that receives that header refuses plain HTTP to the host for
#   a year. Sending it to an HTTP install locks that install out of itself,
#   and there is no way to call it back. If this check ever fails, the release
#   it failed on must not ship.
#
#   X-Powered-By must be gone. It names the PHP version, which is a list of
#   published bugs to try.

SEC_HEADERS="$(mktemp)"
sec_headers() {
	curl -s --max-time 30 -b "$COOKIES" -o /dev/null -D "$SEC_HEADERS" \
		"$OCM_URL/index.php"
	tr -d '\r' < "$SEC_HEADERS"
}

hdr="$(sec_headers)"

sec_expect() {
	# sec_expect <header> <value fragment>
	if printf '%s' "$hdr" | grep -qi "^$1:.*$2"; then
		ok "$1 carries $2"
	else
		bad "$1 is MISSING or does not carry $2 [$(printf '%s' "$hdr" | grep -i "^$1:" || echo 'header absent')]"
	fi
}

sec_expect "X-Content-Type-Options" "nosniff"
sec_expect "X-Frame-Options" "DENY"
# strict-origin-when-cross-origin, deliberately not no-referrer:
# pl_request_origin() falls back to Origin and Referer to decide whether a POST
# started on our own page, and no-referrer removes both. A change to
# no-referrer here would look like hardening and would disable a CSRF control.
sec_expect "Referrer-Policy" "strict-origin-when-cross-origin"

if printf '%s' "$hdr" | grep -qi '^Referrer-Policy:.*no-referrer'; then
	bad "Referrer-Policy is no-referrer, which makes browsers send Origin: null on POSTs and disables the CSRF fallback in pl_request_origin()"
else
	ok "Referrer-Policy is not no-referrer, so the CSRF fallback still has a header to read"
fi
sec_expect "Cross-Origin-Opener-Policy" "same-origin"
sec_expect "Cross-Origin-Resource-Policy" "same-origin"
sec_expect "Cross-Origin-Embedder-Policy" "require-corp"
sec_expect "Cache-Control" "no-store"

# The Permissions-Policy is a deny list written out in full, so a feature left
# off it is a feature the page keeps. Spot-check the ones that matter most on
# a machine in an office: the camera, the microphone and the location.
for feature in "camera=()" "microphone=()" "geolocation=()"
do
	if printf '%s' "$hdr" | grep -qi "^Permissions-Policy:.*$(printf '%s' "$feature" | sed 's/[()]/\\&/g')"; then
		ok "Permissions-Policy gives up ${feature}"
	else
		bad "Permissions-Policy does NOT give up ${feature}"
	fi
done

if printf '%s' "$hdr" | grep -qi '^Strict-Transport-Security:'; then
	bad "HSTS WAS SENT OVER PLAIN HTTP. A browser that saw this refuses http:// to this host for a year and it cannot be undone"
else
	ok "no HSTS over plain HTTP, so an http install cannot lock itself out"
fi

if printf '%s' "$hdr" | grep -qi '^X-Powered-By:'; then
	bad "X-Powered-By is still sent, naming the PHP version [$(printf '%s' "$hdr" | grep -i '^X-Powered-By:')]"
else
	ok "X-Powered-By is not sent"
fi

# No header may arrive twice.
#
# Apache sets three of these too, for the responses PHP never sees. The first
# attempt used `Header always set`, and that is what this check exists for:
# `always` does NOT replace what PHP sent. It writes to err_headers_out, a
# different table from the one PHP writes to, so both values go on the wire.
# Referrer-Policy is the one that hurts -- two header fields are read as one
# comma-joined list, so the policy the browser applies is whichever it parses
# last, and the conf and the application can disagree for years without
# anybody seeing a broken page.
for h in X-Frame-Options X-Content-Type-Options Referrer-Policy \
	Cross-Origin-Opener-Policy Cross-Origin-Resource-Policy \
	Permissions-Policy Content-Security-Policy
do
	n="$(printf '%s\n' "$hdr" | grep -ci "^$h:" || true)"
	if [ "$n" -le 1 ]; then
		ok "$h is sent once"
	else
		bad "$h is sent ${n} times; Apache and PHP are both setting it. Use 'Header setifempty' in the conf, not 'Header always set' [$(printf '%s\n' "$hdr" | grep -i "^$h:" | tr '\n' '|')]"
	fi
done

# The conf files must use setifempty, for the reason above, and must say the
# same thing PHP says so that a static file and a PHP page are protected the
# same way.
for conf in docker/apache.conf httpd-config/ocm.conf
do
	if [ ! -f "$conf" ]; then
		continue
	fi

	if grep -q 'X-Frame-Options "DENY"' "$conf" \
		&& grep -q 'Referrer-Policy "strict-origin-when-cross-origin"' "$conf" \
		&& grep -q 'X-Content-Type-Options "nosniff"' "$conf"
	then
		ok "${conf} agrees with what PHP sends"
	else
		bad "${conf} DISAGREES with pl_send_security_headers(); a static file would then be protected differently from a PHP page"
	fi

	if grep -qE '^[^#]*Header +always +set +(X-Frame-Options|X-Content-Type-Options|Referrer-Policy)' "$conf"; then
		bad "${conf} uses 'Header always set', which duplicates the header PHP already sent instead of replacing it. Use 'Header setifempty'"
	else
		ok "${conf} does not use 'Header always set' for a header PHP sends"
	fi

	if grep -qE '^[^#]*Header .*Strict-Transport-Security' "$conf"; then
		bad "${conf} sets HSTS unconditionally; it must come from PHP, which only sends it over HTTPS with force_https on"
	else
		ok "${conf} does not set HSTS unconditionally"
	fi
done

# A static file is the response PHP never sees, so the conf is the only thing
# that can protect it. Check it actually does -- setifempty only fires when the
# header is absent, and getting that wrong is invisible on a PHP page.
STATIC_HDR="$(mktemp)"
curl -s --max-time 30 -o /dev/null -D "$STATIC_HDR" \
	"${OCM_URL%/cms}/errors/404.html"
static="$(tr -d '\r' < "$STATIC_HDR")"
rm -f "$STATIC_HDR"

if printf '%s' "$static" | grep -qi '^HTTP/[0-9.]* 200'; then
	for h in X-Frame-Options X-Content-Type-Options Referrer-Policy
	do
		if printf '%s' "$static" | grep -qi "^$h:"; then
			ok "a static file still carries $h, from the Apache conf"
		else
			bad "a static file carries no $h; PHP cannot set it and the conf did not"
		fi
	done
else
	echo "  skip the static-file header checks: /errors/404.html did not return 200"
fi

# compat mode exists for the install that loads a font from another server.
# It must drop exactly one header, Cross-Origin-Embedder-Policy, and leave the
# rest alone.
#
# Cache-Control is NOT part of the compat set, and this is the check that keeps
# it out. pika-danio.php calls session_start() after pl_send_security_headers(),
# and PHP's session cache limiter then replaces Cache-Control with its own
# "no-store, no-cache, must-revalidate". A compat mode that dropped no-store
# would be promising a browser cache it cannot deliver on any page that starts
# a session -- which is every page a user sees.
if [ "$HAVE_DB" != 1 ]; then
	echo "  skip the compat-mode checks: no database access"
else
	adb "DELETE FROM settings WHERE label = 'security_headers_mode'" >/dev/null 2>&1
	adb "INSERT INTO settings (label, value) VALUES ('security_headers_mode', 'compat')" \
		>/dev/null 2>&1
	hdr="$(sec_headers)"

	if printf '%s' "$hdr" | grep -qi '^Cross-Origin-Embedder-Policy:'; then
		bad "compat mode still sent Cross-Origin-Embedder-Policy, the one header it exists to drop"
	else
		ok "compat mode drops Cross-Origin-Embedder-Policy"
	fi

	if printf '%s' "$hdr" | grep -qi '^Cache-Control:.*no-store'; then
		ok "compat mode still keeps case data out of the browser cache"
	else
		bad "compat mode stopped sending Cache-Control: no-store, so case data may be written to disk on a shared machine"
	fi

	if printf '%s' "$hdr" | grep -qi '^X-Frame-Options:.*DENY' \
		&& printf '%s' "$hdr" | grep -qi '^X-Content-Type-Options:.*nosniff'
	then
		ok "compat mode keeps everything that cannot break a page"
	else
		bad "compat mode dropped a header it has no reason to drop"
	fi

	# A missing row must read as strict, so an install that never opens the
	# settings screen gets the whole set.
	adb "DELETE FROM settings WHERE label = 'security_headers_mode'" >/dev/null 2>&1
	hdr="$(sec_headers)"

	if printf '%s' "$hdr" | grep -qi '^Cross-Origin-Embedder-Policy:.*require-corp'; then
		ok "a missing security_headers_mode row is strict, so a fresh install is covered"
	else
		bad "a missing security_headers_mode row did NOT send the strict set"
	fi
fi

rm -f "$SEC_HEADERS"

# ---------------------------------------------------------------------------
# 68. cms/ops/vcal.php, and the generic error page on a page that bootstraps
# through pika_cms.php.
#
# Two separate defects, found together.
#
# a) vcal.php read act_id from nowhere. Its MAIN CODE block called
#    $pk->fetchActivity("$act_id") on a variable that the file never
#    assigned, so every request to the vCalendar export ended in a fatal and
#    the client got HTTP 500 with a zero-length body. The export had been
#    dead for years.
#
# b) template_plugins/pika_error.php required pikaSettings.php, pikaAuth.php
#    and pikaAuthHttp.php by bare name. Those three live in cms/app/lib.
#    pika_init() in pika-danio.php puts ./app/lib on the include_path, but
#    pika_cms.php puts only ./app/extralib on it. So on the nine pages that
#    bootstrap through pika_cms.php the error page fatalled while rendering
#    the error, and the generic error page added in the exception-handler
#    work never appeared: the client got a bare Apache 500 instead.
#
# (b) is the one that hides every other failure, so it is checked first and
# statically -- a request cannot prove it once (a) is fixed, and this suite
# does not write files into the application tree.
echo
echo "== 68. the vCalendar export and the error page's own includes =="

PIKA_ERROR_SRC="cms/template_plugins/pika_error.php"

if [ -f "$PIKA_ERROR_SRC" ]; then
	if grep -qE "require_once\('(pikaSettings|pikaAuth|pikaAuthHttp)\.php'\)" "$PIKA_ERROR_SRC"; then
		bad "THE ERROR PAGE STILL REQUIRES app/lib FILES BY BARE NAME; it will fatal on every pika_cms.php page"
	else
		ok "the error page does not require app/lib files by bare name"
	fi

	if grep -q "require_once(__DIR__ . '/../app/lib/pikaSettings.php')" "$PIKA_ERROR_SRC"; then
		ok "the error page resolves pikaSettings.php from its own directory"
	else
		bad "the error page no longer resolves pikaSettings.php from its own directory"
	fi
else
	printf '  skip the error-page include check (source tree not present)\n'
fi

if [ "$HAVE_DB" = 1 ] && [ "$HAVE_COMPOSE" = 1 ]; then
	VC_ID=""

	cleanup_vc() {
		if [ -n "${VC_ID:-}" ]; then
			adb "DELETE FROM activities WHERE act_id = ${VC_ID}" >/dev/null 2>&1
		fi
	}
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_vc' EXIT

	VC_ID="$(adb "SELECT COALESCE(MAX(act_id),0)+1 FROM activities")"

	if [ -z "$VC_ID" ]; then
		bad "could not seed an activity fixture for the vCalendar export"
	else
		adb "INSERT INTO activities
			(act_id, act_date, act_time, act_end_time, hours, completed,
			 act_type, case_id, user_id, summary, notes)
			VALUES (${VC_ID}, '2026-09-14', '09:00:00', '10:00:00', 1.00, 0,
			 'C', NULL, 1, 'ZZVCAL smoke export', 'ZZVCALNOTE')" >/dev/null 2>&1

		: > "$COOKIES"
		curl -s --max-time 30 -c "$COOKIES" -o /dev/null "$OCM_URL/index.php"
		curl -s --max-time 30 -c "$COOKIES" -b "$COOKIES" -o /dev/null \
			-X POST -d "login_user=admin&login_pass=${OCM_PASSWORD}&auth_id=1" \
			"$OCM_URL/index.php"

		# 68a. A real activity exports a vCalendar.
		vc_code="$(curl -s --max-time 30 -b "$COOKIES" -o "$BODY" \
			-w '%{http_code}' "$OCM_URL/ops/vcal.php?act_id=${VC_ID}")"

		if [ "$vc_code" != "200" ]; then
			bad "the vCalendar export answered HTTP ${vc_code} for a real activity"
		elif ! grep -q 'BEGIN:VCALENDAR' "$BODY"; then
			bad "THE VCALENDAR EXPORT RETURNED NO CALENDAR (act_id is unread again)"
		elif ! grep -q 'ZZVCAL smoke export' "$BODY"; then
			bad "the exported calendar does not carry the activity's summary"
		else
			ok "the vCalendar export returns the named activity"
		fi

		# 68b. It must not be servable without act_id, and must not fatal.
		for vc_q in "" "?act_id=abc" "?act_id=999999999"; do
			vc_code="$(curl -s --max-time 30 -b "$COOKIES" -o "$BODY" \
				-w '%{http_code}' "$OCM_URL/ops/vcal.php${vc_q}")"
			vc_size="$(wc -c < "$BODY" | tr -d ' ')"

			if [ "$vc_code" = "500" ] && [ "$vc_size" -lt 600 ]; then
				bad "vcal.php${vc_q} is a bare fatal again (HTTP 500, ${vc_size} bytes)"
			elif grep -q 'BEGIN:VCALENDAR' "$BODY"; then
				bad "vcal.php${vc_q} EXPORTED A CALENDAR for no valid activity"
			else
				ok "vcal.php${vc_q} refuses without exporting and without fatalling"
			fi
		done

		# 68c. A quoted value must not reach fetchActivity(), which
		# interpolates act_id into its WHERE clause with no escaping.
		vc_code="$(curl -s --max-time 30 -b "$COOKIES" -o "$BODY" \
			-w '%{http_code}' "$OCM_URL/ops/vcal.php?act_id=1%27%20OR%20%271%27%3D%271")"

		if grep -q 'BEGIN:VCALENDAR' "$BODY"; then
			bad "A QUOTED act_id REACHED THE QUERY AND EXPORTED AN ACTIVITY"
		elif [ "$vc_code" = "500" ]; then
			bad "a quoted act_id reached the query and threw (HTTP 500)"
		else
			ok "a quoted act_id is dropped before the query"
		fi

		# 68d. Every page that bootstraps through pika_cms.php must serve a
		# body. A zero-length 500 from any of them is the (b) failure again.
		for vc_page in system-ops.php cal_week.php cal_day.php assign_atty.php \
			legacy_report.php dataops.php helpdocs/elig_guide.php \
			reports/conflict/conflict.php ops/vcal.php
		do
			vc_code="$(curl -s --max-time 30 -b "$COOKIES" -o "$BODY" \
				-w '%{http_code}' "$OCM_URL/${vc_page}")"
			vc_size="$(wc -c < "$BODY" | tr -d ' ')"

			if [ "$vc_code" = "500" ] && [ "$vc_size" -lt 600 ]; then
				bad "${vc_page} serves a bare fatal (HTTP 500, ${vc_size} bytes)"
			else
				ok "${vc_page} serves a body (HTTP ${vc_code}, ${vc_size} bytes)"
			fi
		done

		# 68e. The export's own two headers. "Content-Disposition:
		# filename=..." names a filename with no disposition type in front
		# of it, which is not a disposition at all, and a text/* type with
		# no charset is read in the browser's default encoding -- which is
		# what decides how the bytes of an activity's summary and notes are
		# interpreted -- and PHP's default_charset appends one for a text/*
		# type today, so this check holds the explicit header rather than
		# catching a missing charset. Neither is a way in here, because text/calendar is
		# not a type a browser renders as markup and nosniff is on every
		# response, but "not rendered as markup" should not be the whole of
		# what stops the export echoing an activity's text back.
		VC_HDR="$BODY.vcal68e"
		curl -s --max-time 30 -b "$COOKIES" -D "$VC_HDR" -o "$BODY" \
			"$OCM_URL/ops/vcal.php?act_id=${VC_ID}" >/dev/null

		if ! grep -q 'BEGIN:VCALENDAR' "$BODY"
		then
			bad "the vCalendar header check did not get an export back"
		elif ! grep -qiE '^content-type:[ ]*text/calendar' "$VC_HDR"
		then
			bad "the vCalendar export does not send Content-Type: text/calendar"
		elif ! grep -qiE '^content-type:.*charset=' "$VC_HDR"
		then
			bad "the vCalendar export sends text/calendar with no charset"
		elif ! grep -qiE '^content-disposition:[ ]*attachment' "$VC_HDR"
		then
			bad "the vCalendar export sends a filename with no disposition type"
		else
			ok "the vCalendar export is an attachment with a charset"
		fi
		rm -f "$VC_HDR"
	fi

	cleanup_vc
	VC_ID=""
	trap 'rm -f "$COOKIES" "$BODY"' EXIT
else
	printf '  skip the vCalendar export checks (needs the database)\n'
fi

# ---------------------------------------------------------------------------
# 69. Two findings from the backport audit of the private tree.
#
# a) cms/system-sms.php read the Twilio authentication token and the
#    SparkPost API key back out of the settings table and rendered each into
#    the value attribute of a plain text input. The page handed the live
#    credentials to anybody who could open it, and to anything that could
#    read the response. system-settings.php already had the right shape for
#    this -- a password field, an empty value, and a line saying whether one
#    is stored -- for the OIDC client secret and the peer transfer shared
#    secret. The SMS page now uses it too, which means it must also not
#    erase a stored credential when the form is saved with the field blank.
#
# b) pl_menu_set() in app/lib/pl.php interpolated its $menu_name straight
#    into "DELETE FROM menu_$menu_name" and the matching INSERT. Its one
#    caller, cms/system-ops.php case 'save_menu', takes that name from
#    $_POST. A table name is not quoted, so DB::escapeString() does nothing
#    for it; it needs pl_safe_identifier(). Holding the system group is not
#    the same as holding a database shell.
echo
echo "== 69. the SMS provider secrets, and the menu table name =="

if [ "$HAVE_DB" = 1 ] && [ "$HAVE_COMPOSE" = 1 ]; then
	SMS_TWILIO_SAVED=""
	SMS_SPARK_SAVED=""
	SMS_SID_SAVED=""

	cleanup_sms() {
		adb "DELETE FROM settings WHERE label IN
			('twilio_auth_token','sparkpost_api_key','twilio_account_sid')" >/dev/null 2>&1
		if [ -n "${SMS_TWILIO_SAVED:-}" ]; then
			adb "INSERT INTO settings (label, value) VALUES ('twilio_auth_token', '${SMS_TWILIO_SAVED}')" >/dev/null 2>&1
		fi
		if [ -n "${SMS_SPARK_SAVED:-}" ]; then
			adb "INSERT INTO settings (label, value) VALUES ('sparkpost_api_key', '${SMS_SPARK_SAVED}')" >/dev/null 2>&1
		fi
		if [ -n "${SMS_SID_SAVED:-}" ]; then
			adb "INSERT INTO settings (label, value) VALUES ('twilio_account_sid', '${SMS_SID_SAVED}')" >/dev/null 2>&1
		fi
		adb "DROP TABLE IF EXISTS menu_zzsmoke" >/dev/null 2>&1
	}
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_sms' EXIT

	SMS_TWILIO_SAVED="$(adb "SELECT value FROM settings WHERE label = 'twilio_auth_token'")"
	SMS_SPARK_SAVED="$(adb "SELECT value FROM settings WHERE label = 'sparkpost_api_key'")"
	SMS_SID_SAVED="$(adb "SELECT value FROM settings WHERE label = 'twilio_account_sid'")"

	adb "DELETE FROM settings WHERE label IN ('twilio_auth_token','sparkpost_api_key')" >/dev/null
	adb "INSERT INTO settings (label, value) VALUES
		('twilio_auth_token', 'ZZTWILIOSECRET'),
		('sparkpost_api_key', 'ZZSPARKKEY')" >/dev/null

	: > "$COOKIES"
	curl -s --max-time 30 -c "$COOKIES" -o /dev/null "$OCM_URL/index.php"
	curl -s --max-time 30 -c "$COOKIES" -b "$COOKIES" -o /dev/null \
		-X POST -d "login_user=admin&login_pass=${OCM_PASSWORD}&auth_id=1" \
		"$OCM_URL/index.php"

	# 69a. Neither credential may appear in the page.
	curl -s --max-time 30 -b "$COOKIES" -o "$BODY" "$OCM_URL/system-sms.php"

	if grep -q 'ZZTWILIOSECRET' "$BODY"; then
		bad "THE SMS PAGE PRINTS THE STORED TWILIO AUTHENTICATION TOKEN"
	else
		ok "the SMS page does not print the stored Twilio token"
	fi

	if grep -q 'ZZSPARKKEY' "$BODY"; then
		bad "THE SMS PAGE PRINTS THE STORED SPARKPOST API KEY"
	else
		ok "the SMS page does not print the stored SparkPost key"
	fi

	if grep -q 'A token is stored' "$BODY" && grep -q 'An API key is stored' "$BODY"; then
		ok "the SMS page says a credential is stored without saying what it is"
	else
		bad "the SMS page does not report whether a credential is stored"
	fi

	sms_tok="$(grep -oE 'name="_csrf" value="[0-9a-f]{64}"' "$BODY" \
		| head -1 | sed 's/.*value="//; s/"//')"

	if [ -z "$sms_tok" ]; then
		bad "the SMS settings form carries no CSRF token"
	else
		# 69b. Saving with the fields blank must keep both credentials.
		curl -s --max-time 30 -b "$COOKIES" -o /dev/null -X POST \
			--data-urlencode "_csrf=${sms_tok}" \
			-d 'action=update' -d 'twilio_account_sid=ZZSID' \
			-d 'twilio_auth_token=' -d 'twilio_number=%2B15550000' \
			-d 'sparkpost_api_key=' -d 'sparkpost_from_address=zz%40example.org' \
			"$OCM_URL/system-sms.php"

		if [ "$(adb "SELECT value FROM settings WHERE label = 'twilio_auth_token'")" = "ZZTWILIOSECRET" ] \
			&& [ "$(adb "SELECT value FROM settings WHERE label = 'sparkpost_api_key'")" = "ZZSPARKKEY" ]; then
			ok "saving the SMS form with the secret fields blank keeps both credentials"
		else
			bad "SAVING THE SMS FORM WITH BLANK SECRET FIELDS ERASED A STORED CREDENTIAL"
		fi

		if [ "$(adb "SELECT value FROM settings WHERE label = 'twilio_account_sid'")" = "ZZSID" ]; then
			ok "the non-secret SMS fields still save"
		else
			bad "the non-secret SMS fields no longer save"
		fi

		# 69c. Retyping one must still replace it.
		curl -s --max-time 30 -b "$COOKIES" -o "$BODY" "$OCM_URL/system-sms.php"
		sms_tok="$(grep -oE 'name="_csrf" value="[0-9a-f]{64}"' "$BODY" \
			| head -1 | sed 's/.*value="//; s/"//')"
		curl -s --max-time 30 -b "$COOKIES" -o /dev/null -X POST \
			--data-urlencode "_csrf=${sms_tok}" \
			-d 'action=update' -d 'twilio_account_sid=ZZSID' \
			-d 'twilio_auth_token=ZZNEWTOKEN' -d 'twilio_number=%2B15550000' \
			-d 'sparkpost_api_key=' -d 'sparkpost_from_address=zz%40example.org' \
			"$OCM_URL/system-sms.php"

		if [ "$(adb "SELECT value FROM settings WHERE label = 'twilio_auth_token'")" = "ZZNEWTOKEN" ] \
			&& [ "$(adb "SELECT value FROM settings WHERE label = 'sparkpost_api_key'")" = "ZZSPARKKEY" ]; then
			ok "retyping one SMS credential replaces it and leaves the other alone"
		else
			bad "retyping an SMS credential did not replace it, or disturbed the other"
		fi
	fi

	# 69d. The menu table name.
	adb "DROP TABLE IF EXISTS menu_zzsmoke" >/dev/null
	adb "CREATE TABLE menu_zzsmoke (value VARCHAR(20), label VARCHAR(60), menu_order INT)" >/dev/null

	curl -s --max-time 30 -b "$COOKIES" -o "$BODY" "$OCM_URL/system-settings.php"
	menu_tok="$(grep -oE 'name="_csrf" value="[0-9a-f]{64}"' "$BODY" \
		| head -1 | sed 's/.*value="//; s/"//')"

	if [ -z "$menu_tok" ]; then
		bad "could not get a CSRF token for the menu save checks"
	else
		curl -s --max-time 30 -b "$COOKIES" -o /dev/null -X POST \
			--data-urlencode "_csrf=${menu_tok}" -d 'action=save_menu' \
			--data-urlencode 'menu=zzsmoke' \
			--data-urlencode 'values=a|Alpha
b|Beta' "$OCM_URL/system-ops.php"

		if [ "$(adb "SELECT COUNT(*) FROM menu_zzsmoke")" = "2" ]; then
			ok "a valid menu name still saves its items"
		else
			bad "a valid menu name no longer saves; the allowlist is too strict"
		fi

		# A name that is not a bare identifier must be refused outright.
		curl -s --max-time 30 -b "$COOKIES" -o /dev/null -X POST \
			--data-urlencode "_csrf=${menu_tok}" -d 'action=save_menu' \
			--data-urlencode 'menu=zzsmoke WHERE 1=1' \
			--data-urlencode 'values=c|Gamma' "$OCM_URL/system-ops.php"

		if [ "$(adb "SELECT COUNT(*) FROM menu_zzsmoke")" = "2" ]; then
			ok "a crafted menu name is refused and the rows are untouched"
		else
			bad "A CRAFTED MENU NAME REACHED THE QUERY"
		fi

		# And an apostrophe in a label must survive exactly once.
		curl -s --max-time 30 -b "$COOKIES" -o /dev/null -X POST \
			--data-urlencode "_csrf=${menu_tok}" -d 'action=save_menu' \
			--data-urlencode 'menu=zzsmoke' \
			--data-urlencode "values=x|O'Brien" "$OCM_URL/system-ops.php"

		menu_label="$(adb "SELECT label FROM menu_zzsmoke WHERE value = 'x'")"

		case "$menu_label" in
		"O'Brien")
			ok "an apostrophe in a menu label is stored once, not escaped twice" ;;
		"")
			bad "an apostrophe in a menu label broke the insert" ;;
		*)
			bad "a menu label is double-escaped [${menu_label}]" ;;
		esac
	fi

	cleanup_sms
	SMS_TWILIO_SAVED=""; SMS_SPARK_SAVED=""; SMS_SID_SAVED=""
	trap 'rm -f "$COOKIES" "$BODY"' EXIT
else
	printf '  skip the SMS credential and menu name checks (needs the database)\n'
fi

echo
echo "== 70. document assembly: the debug dump, and the settings a template may read =="

if [ "$HAVE_DB" = 1 ] && [ "$HAVE_COMPOSE" = 1 ]; then
	DG_CASE=""
	DG_DOC=""
	DG_TOTP_SAVED=""
	DG_SSO_SAVED=""

	DG_TOTP_HAD=0
	DG_SSO_HAD=0

	# Restore the row, not just the value. sso_client_secret is seeded by
	# add_sso.sql and section 26 sets it with an UPDATE, so a row deleted here
	# and re-INSERTed only when it held something would leave that section
	# updating nothing at all.
	cleanup_docgen() {
		[ -n "${DG_DOC:-}" ] && adb "DELETE FROM doc_storage WHERE doc_id = ${DG_DOC}" >/dev/null 2>&1
		[ -n "${DG_CASE:-}" ] && adb "DELETE FROM cases WHERE case_id = ${DG_CASE}" >/dev/null 2>&1
		if [ "${DG_TOTP_HAD:-0}" = 1 ]; then
			adb "INSERT INTO settings (label, value) VALUES ('totp_encryption_key', '${DG_TOTP_SAVED}')
				ON DUPLICATE KEY UPDATE value = '${DG_TOTP_SAVED}'" >/dev/null 2>&1
		else
			adb "DELETE FROM settings WHERE label = 'totp_encryption_key'" >/dev/null 2>&1
		fi
		if [ "${DG_SSO_HAD:-0}" = 1 ]; then
			adb "INSERT INTO settings (label, value) VALUES ('sso_client_secret', '${DG_SSO_SAVED}')
				ON DUPLICATE KEY UPDATE value = '${DG_SSO_SAVED}'" >/dev/null 2>&1
		else
			adb "DELETE FROM settings WHERE label = 'sso_client_secret'" >/dev/null 2>&1
		fi
	}
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_docgen' EXIT

	DG_TOTP_HAD="$(adb "SELECT COUNT(*) FROM settings WHERE label = 'totp_encryption_key'")"
	DG_SSO_HAD="$(adb "SELECT COUNT(*) FROM settings WHERE label = 'sso_client_secret'")"
	DG_TOTP_SAVED="$(adb "SELECT value FROM settings WHERE label = 'totp_encryption_key'")"
	DG_SSO_SAVED="$(adb "SELECT value FROM settings WHERE label = 'sso_client_secret'")"

	adb "INSERT INTO settings (label, value) VALUES ('totp_encryption_key', 'ZZTOTPKEY')
		ON DUPLICATE KEY UPDATE value = 'ZZTOTPKEY'" >/dev/null
	adb "INSERT INTO settings (label, value) VALUES ('sso_client_secret', 'ZZSSOSECRET')
		ON DUPLICATE KEY UPDATE value = 'ZZSSOSECRET'" >/dev/null

	# A case whose number carries a script tag. pl_clean_form_input() turns
	# < and > into entities on the way in, so a value seeded here is the
	# honest test of the output side: imports, migrations and direct SQL all
	# write this column too.
	DG_CASE="$(adb "SELECT COALESCE(MAX(case_id), 0) + 1 FROM cases")"
	adb "INSERT INTO cases (case_id, number, user_id, office, status)
		VALUES (${DG_CASE}, 'ZZDG<script>alert(1)</script>', 1, NULL, '1')" >/dev/null

	# A form template (doc_type = 'F') whose body asks for six settings by
	# name. doc_data is addslashes(gzcompress(...)), so build it with the
	# application's own PHP and insert it as hex.
	DG_BODY='TOTP=[%%[totp_encryption_key]%%] SSO=[%%[sso_client_secret]%%] DBPW=[%%[db_password]%%] DBHOST=[%%[db_host]%%] BASEDIR=[%%[base_directory]%%] BASEURL=[%%[base_url]%%]'
	DG_HEX="$(docker compose "${COMPOSE_ARGS[@]}" exec -T app \
		php -r 'echo bin2hex(addslashes(gzcompress($argv[1], 9)));' "$DG_BODY" </dev/null 2>/dev/null)"
	DG_DOC="$(adb "SELECT COALESCE(MAX(doc_id), 0) + 1 FROM doc_storage")"

	if [ -z "$DG_HEX" ] || [ -z "${DG_DOC:-}" ] || [ -z "${DG_CASE:-}" ]; then
		bad "could not seed the document assembly fixtures"
	else
		adb "INSERT INTO doc_storage
			(doc_id, doc_name, doc_data, doc_size, mime_type, doc_type, description, created, case_id, user_id)
			VALUES (${DG_DOC}, 'zzsmoke-form.txt', UNHEX('${DG_HEX}'), 64, 'text/plain', 'F',
				'zz smoke form', CURDATE(), 0, 1)" >/dev/null

		: > "$COOKIES"
		curl -s --max-time 30 -c "$COOKIES" -o /dev/null "$OCM_URL/index.php"
		curl -s --max-time 30 -c "$COOKIES" -b "$COOKIES" -o /dev/null \
			-X POST -d "login_user=admin&login_pass=${OCM_PASSWORD}&auth_id=1" \
			"$OCM_URL/index.php"

		# Tokens are per session, not per form, so any page carrying
		# %%[csrf_field]%% will do.
		curl -s --max-time 30 -b "$COOKIES" -o "$BODY" "$OCM_URL/system-settings.php"
		DG_CSRF="$(grep -oE 'name="_csrf" value="[0-9a-f]{64}"' "$BODY" | head -1 | sed 's/.*value="//; s/"//')"

		if [ -z "$DG_CSRF" ]; then
			bad "could not take a CSRF token for the document assembly checks"
		else
			# 70a. The [?] debug dump must escape the case data it lists.
			curl -s --max-time 30 -b "$COOKIES" -o "$BODY" \
				-X POST -d "_csrf=${DG_CSRF}&case_id=${DG_CASE}&form_id=${DG_DOC}&debug=1&recipient=&opposing=&opp_counsel=&autosave=" \
				"$OCM_URL/ops/docgen.php"

			if grep -q 'ZZDG<script>' "$BODY"; then
				bad "THE DOCUMENT ASSEMBLY DEBUG DUMP EMITS CASE DATA AS LIVE HTML (CWE-79)"
			elif grep -q 'ZZDG&lt;script&gt;' "$BODY"; then
				ok "the document assembly debug dump escapes the case data it lists"
			else
				bad "the debug dump showed neither the raw nor the escaped case number ($(wc -c < "$BODY") bytes)"
			fi

			if grep -q 'Field Name: number' "$BODY"; then
				ok "the debug dump still lists the field names a form may use"
			else
				bad "the debug dump no longer lists any field names"
			fi

			# 70b. A form template must not resolve a credential.
			curl -s --max-time 30 -b "$COOKIES" -o "$BODY" \
				-X POST -d "_csrf=${DG_CSRF}&case_id=${DG_CASE}&form_id=${DG_DOC}&debug=0&recipient=&opposing=&opp_counsel=&autosave=" \
				"$OCM_URL/ops/docgen.php"

			if grep -q 'ZZTOTPKEY' "$BODY"; then
				bad "A FORM TEMPLATE CAN READ THE TOTP ENCRYPTION KEY (CWE-522)"
			else
				ok "a form template cannot read the TOTP encryption key"
			fi

			if grep -q 'ZZSSOSECRET' "$BODY"; then
				bad "A FORM TEMPLATE CAN READ THE OIDC CLIENT SECRET (CWE-522)"
			else
				ok "a form template cannot read the OIDC client secret"
			fi

			if grep -q 'DBHOST=\[\]' "$BODY"; then
				ok "a form template cannot read the database host"
			else
				bad "a form template can read the database host"
			fi

			if grep -q 'BASEDIR=\[\]' "$BODY"; then
				ok "a form template cannot read the installation's base directory"
			else
				bad "a form template can read the installation's base directory"
			fi

			if grep -q 'DBPW=\[\]' "$BODY"; then
				ok "a form template cannot read the database password"
			else
				bad "a form template can read the database password"
			fi

			# base_url is deliberately NOT blocked: page chrome resolves it
			# through the same path on every page, so blocking it would blank
			# the navigation everywhere.
			if grep -qE 'BASEURL=\[[^]]+\]' "$BODY"; then
				ok "a template can still resolve base_url"
			else
				bad "base_url no longer resolves in a template - page chrome will be blank"
			fi

			# 70c. Blocking a label must not blank the admin form, which puts
			# these into its own data array.
			curl -s --max-time 30 -b "$COOKIES" -o "$BODY" "$OCM_URL/system-settings.php"

			if grep -q 'name="dont_use_host" value=""' "$BODY" \
				|| ! grep -q 'name="dont_use_host"' "$BODY"; then
				bad "the system settings page no longer shows the database host"
			else
				ok "the system settings page still shows the database host"
			fi

			if grep -q 'name="dont_use_base_directory" value=""' "$BODY" \
				|| ! grep -q 'name="dont_use_base_directory"' "$BODY"; then
				bad "the system settings page no longer shows the base directory"
			else
				ok "the system settings page still shows the base directory"
			fi

			if grep -q 'ZZTOTPKEY\|ZZSSOSECRET' "$BODY"; then
				bad "the system settings page prints a stored credential"
			else
				ok "the system settings page prints no stored credential"
			fi
		fi
	fi

	# 70d. Static: neither blocklist may name a label that no longer exists.
	if grep -q "pl_settings_template_blocked" cms/template_plugins/setting.php \
		&& ! grep -q "blocked_array = array" cms/template_plugins/setting.php; then
		ok "the setting template plugin uses the one blocklist"
	else
		bad "the setting template plugin still carries its own stale blocklist"
	fi

	if grep -q "pl_settings_template_blocked" cms/app/lib/pikaTempLib.php \
		&& ! grep -q "blocked_fields = array" cms/app/lib/pikaTempLib.php; then
		ok "pikaTempLib::loadSettings uses the one blocklist"
	else
		bad "pikaTempLib::loadSettings still carries its own stale blocklist"
	fi

	cleanup_docgen
	DG_CASE=""; DG_DOC=""; DG_TOTP_SAVED=""; DG_SSO_SAVED=""
	trap 'rm -f "$COOKIES" "$BODY"' EXIT
else
	printf '  skip the document assembly checks (needs the database)\n'
fi

echo
echo "== 71. user accounts: the security level a POST may set =="

if [ "$HAVE_DB" = 1 ] && [ "$HAVE_COMPOSE" = 1 ]; then
	UG_GROUP='zz_ug_grp'
	UG_GROUP2='zz_ug_grp2'
	UG_ADMIN='zz_ug_admin'
	UG_TARGET='zz_ug_target'
	UG_SYSUSER='zz_ug_sys'
	UG_PASS='zz-ug-Pass1!'
	UG_JAR="$(mktemp)"
	UG_SYSJAR="$(mktemp)"

	cleanup_ug() {
		adb "DELETE FROM user_sessions WHERE user_id IN
			(SELECT user_id FROM users WHERE username IN ('${UG_ADMIN}','${UG_TARGET}','${UG_SYSUSER}'))" >/dev/null 2>&1
		adb "DELETE FROM users WHERE username IN ('${UG_ADMIN}','${UG_TARGET}','${UG_SYSUSER}')" >/dev/null 2>&1
		adb "DELETE FROM \`groups\` WHERE group_id IN ('${UG_GROUP}','${UG_GROUP2}')" >/dev/null 2>&1
		adb "DELETE FROM reauth_grants WHERE action_scope = 'user_admin'" >/dev/null 2>&1
		adb "DELETE FROM audit_log WHERE action = 'user.group_change_refused'" >/dev/null 2>&1
		rm -f "$UG_JAR" "$UG_SYSJAR"
	}
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_ug' EXIT
	cleanup_ug

	# Two ordinary groups. The users flag is what lets an account reach
	# system-users.php at all; neither group is 'system', so neither account
	# below is a superuser.
	adb "INSERT INTO \`groups\` (group_id, read_office, read_all, edit_office, edit_all, users, pba, motd, intake, reports)
		VALUES ('${UG_GROUP}', NULL, 0, NULL, 0, 1, 0, 0, 0, NULL)" >/dev/null
	adb "INSERT INTO \`groups\` (group_id, read_office, read_all, edit_office, edit_all, users, pba, motd, intake, reports)
		VALUES ('${UG_GROUP2}', NULL, 0, NULL, 0, 0, 0, 0, 0, NULL)" >/dev/null

	UG_HASH="$(docker compose "${COMPOSE_ARGS[@]}" exec -T app \
		php -r 'echo password_hash($argv[1], PASSWORD_DEFAULT);' "$UG_PASS" </dev/null 2>/dev/null)"

	UG_AUID="$(adb "SELECT COALESCE(MAX(user_id), 0) + 1 FROM users")"
	adb "INSERT INTO users (user_id, username, password, enabled, group_id, password_expire)
		VALUES (${UG_AUID}, '${UG_ADMIN}', '${UG_HASH}', 1, '${UG_GROUP}', 0)" >/dev/null
	UG_TUID="$(adb "SELECT COALESCE(MAX(user_id), 0) + 1 FROM users")"
	adb "INSERT INTO users (user_id, username, password, enabled, group_id, password_expire)
		VALUES (${UG_TUID}, '${UG_TARGET}', '${UG_HASH}', 1, '${UG_GROUP}', 0)" >/dev/null
	UG_SUID="$(adb "SELECT COALESCE(MAX(user_id), 0) + 1 FROM users")"
	adb "INSERT INTO users (user_id, username, password, enabled, group_id, password_expire)
		VALUES (${UG_SUID}, '${UG_SYSUSER}', '${UG_HASH}', 1, 'system', 0)" >/dev/null

	if [ -z "$UG_HASH" ] || [ -z "${UG_AUID:-}" ] || [ -z "${UG_TUID:-}" ] || [ -z "${UG_SUID:-}" ]; then
		bad "could not seed the user security level fixtures"
	else
		ug_token() {
			curl -sL --max-time 30 -c "$1" -b "$1" "$OCM_URL/password.php" \
				| grep -oE 'name="_csrf" value="[0-9a-f]{64}"' \
				| head -1 | sed -e 's/.*value="//' -e 's/"$//'
		}

		# system-users.php's list screen renders no _csrf field, so take the
		# token from password.php: the token is per session, not per form.
		# The re-auth answer rides along on every post; the grant lasts five
		# minutes, so only the first one actually needs it.
		ug_post() {
			local jar="$1" pass="$2" tok
			shift 2
			tok="$(ug_token "$jar")"
			curl -sL --max-time 30 -c "$jar" -b "$jar" -o "$BODY" \
				--data-urlencode "_csrf=${tok}" \
				-d "_reauth_scope=user_admin" \
				--data-urlencode "_reauth_password=${pass}" \
				"$@" "$OCM_URL/system-users.php" >/dev/null
		}

		ug_group_of() {
			adb "SELECT group_id FROM users WHERE username = '$1'"
		}

		: > "$UG_JAR"
		curl -sL --max-time 30 -c "$UG_JAR" -b "$UG_JAR" -o "$BODY" \
			-X POST -d "login_user=${UG_ADMIN}&login_pass=${UG_PASS}&auth_id=1" \
			"$OCM_URL/" >/dev/null
		if grep -q 'login_pass' "$BODY"; then
			bad "the account maintainer fixture could not sign in"
		else
			ok "the account maintainer fixture signed in"
		fi

		# 71a. The escalation itself. pika_authorize() returns true for the
		# 'system' group before it looks at the operation at all, so an
		# account holding only the users flag posting group_id=system would
		# become a superuser using nothing but its own password.
		ug_post "$UG_JAR" "$UG_PASS" \
			-d "action=update&user_id=${UG_TUID}&username=${UG_TARGET}&group_id=system&enabled=1"
		if [ "$(ug_group_of "$UG_TARGET")" = "${UG_GROUP}" ]; then
			ok "an account maintainer cannot promote an account to the system security level"
		else
			bad "an account maintainer promoted an account to the system security level"
		fi
		if grep -q 'Only a member of the system security level may place an account in it' "$BODY"; then
			ok "the refusal says why the promotion was not saved"
		else
			bad "the promotion was refused without saying why"
		fi

		# 71b. A level that matches no row leaves the account able to do
		# nothing at all, which reads as a broken account rather than a
		# misconfigured one.
		ug_post "$UG_JAR" "$UG_PASS" \
			-d "action=update&user_id=${UG_TUID}&username=${UG_TARGET}&group_id=zz_no_such_group&enabled=1"
		if [ "$(ug_group_of "$UG_TARGET")" = "${UG_GROUP}" ]; then
			ok "a security level that does not exist is not written"
		else
			bad "a security level that does not exist was written to the account"
		fi
		if grep -q 'That security level does not exist' "$BODY"; then
			ok "the refusal names the missing security level as the reason"
		else
			bad "the missing security level was refused without saying why"
		fi

		# 71c. Rule 71a is one step short on its own: an account maintainer
		# who may edit a system account can reset its password and sign in as
		# it instead.
		ug_post "$UG_JAR" "$UG_PASS" \
			-d "action=update&user_id=${UG_SUID}&username=${UG_SYSUSER}&group_id=${UG_GROUP}&enabled=1"
		if [ "$(ug_group_of "$UG_SYSUSER")" = "system" ]; then
			ok "an account maintainer cannot take an account out of the system security level"
		else
			bad "an account maintainer took an account out of the system security level"
		fi
		if grep -q 'Only a member of the system security level may edit an account in it' "$BODY"; then
			ok "the refusal says the account is a system account"
		else
			bad "editing a system account was refused without saying why"
		fi

		# 71d. Every refusal is recorded, with what was attempted.
		UG_AUDIT="$(adb "SELECT COUNT(*) FROM audit_log WHERE action = 'user.group_change_refused'")"
		if [ "${UG_AUDIT:-0}" -ge 3 ]; then
			ok "each refused security level change is written to the audit log"
		else
			bad "refused security level changes are not in the audit log (found ${UG_AUDIT:-0})"
		fi

		# 71e. The positive control. An ordinary change to a level that does
		# exist still saves, or this page is simply broken.
		ug_post "$UG_JAR" "$UG_PASS" \
			-d "action=update&user_id=${UG_TUID}&username=${UG_TARGET}&group_id=${UG_GROUP2}&enabled=1"
		if [ "$(ug_group_of "$UG_TARGET")" = "${UG_GROUP2}" ]; then
			ok "an ordinary security level change is still saved"
		else
			bad "an ordinary security level change no longer saves"
		fi

		# 71f. And a member of the system group is not blocked by any of it.
		: > "$UG_SYSJAR"
		curl -sL --max-time 30 -c "$UG_SYSJAR" -b "$UG_SYSJAR" -o "$BODY" \
			-X POST -d "login_user=${OCM_USER}&login_pass=${OCM_PASSWORD}&auth_id=1" \
			"$OCM_URL/" >/dev/null
		ug_post "$UG_SYSJAR" "$OCM_PASSWORD" \
			-d "action=update&user_id=${UG_TUID}&username=${UG_TARGET}&group_id=system&enabled=1"
		if [ "$(ug_group_of "$UG_TARGET")" = "system" ]; then
			ok "a member of the system security level may still place an account in it"
		else
			bad "a member of the system security level can no longer place an account in it"
		fi
	fi

	# 71g. Static: the allowlist is the page's own group list, not a literal.
	if grep -qF 'isset($groups[$target_group])' cms/system-users.php; then
		ok "the security level is checked against the groups the page loaded"
	else
		bad "system-users.php no longer checks the posted security level against the groups table"
	fi

	cleanup_ug
	trap 'rm -f "$COOKIES" "$BODY"' EXIT
else
	printf '  skip the user security level checks (needs the database)\n'
fi

echo
echo "== 72. saving a report definition: the answer the browser gets =="

if [ "$HAVE_DB" = 1 ] && [ "$HAVE_COMPOSE" = 1 ]; then
	SR_GROUP='zz_sr_grp'
	SR_USER='zz_sr_user'
	SR_PASS='zz-sr-Pass1!'
	SR_JAR="$(mktemp)"

	cleanup_sr() {
		adb "DELETE FROM doc_storage WHERE report_name LIKE 'ZZSR%'" >/dev/null 2>&1
		adb "DELETE FROM user_sessions WHERE user_id IN
			(SELECT user_id FROM users WHERE username = '${SR_USER}')" >/dev/null 2>&1
		adb "DELETE FROM users WHERE username = '${SR_USER}'" >/dev/null 2>&1
		adb "DELETE FROM \`groups\` WHERE group_id = '${SR_GROUP}'" >/dev/null 2>&1
		rm -f "$SR_JAR"
	}
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_sr' EXIT
	cleanup_sr

	sr_token() {
		curl -sL --max-time 30 -c "$1" -b "$1" "$OCM_URL/password.php" \
			| grep -oE 'name="_csrf" value="[0-9a-f]{64}"' \
			| head -1 | sed -e 's/.*value="//' -e 's/"$//'
	}

	# Post the way js/save_report.js does: a raw text/xml body and the token
	# in a header, because there is no form encoding for it to travel in.
	sr_save() {
		local jar="$1" query="$2" xml="$3" tok
		tok="$(sr_token "$jar")"
		curl -s --max-time 30 -b "$jar" -o "$BODY" -w '%{http_code}' -X POST \
			-H 'Content-Type: text/xml' -H "X-CSRF-Token: ${tok}" \
			--data-binary "$xml" "$OCM_URL/ops/upload_report.php?${query}"
	}

	SR_XML='<?xml version="1.0"?><form name="zzsr"></form>'

	# 72a. The one path that stores a document says so, in the exact word the
	# browser waits for before it reloads the list.
	SR_CODE="$(sr_save "$COOKIES" 'report_name=ZZSR1&doc_name=ZZSR1.xml' "$SR_XML")"
	if [ "$SR_CODE" = 200 ] && [ "$(tr -d ' \r\n' < "$BODY")" = 'OK' ]; then
		ok "a stored report definition is answered with OK"
	else
		bad "a stored report definition answered $SR_CODE [$(head -c 60 "$BODY")]"
	fi
	if [ "$(adb "SELECT COUNT(*) FROM doc_storage WHERE report_name = 'ZZSR1'")" = 1 ]; then
		ok "the OK answer means the definition really was stored"
	else
		bad "the handler said OK and stored nothing"
	fi

	# 72b. A body that is not XML. This is what an interrupted or truncated
	# request looks like, and it used to be indistinguishable from a save.
	SR_CODE="$(sr_save "$COOKIES" 'report_name=ZZSR2&doc_name=ZZSR2.xml' 'this is not xml')"
	if [ "$SR_CODE" = 400 ]; then
		ok "settings that did not arrive readably are refused with a status"
	else
		bad "an unreadable request body answered $SR_CODE, not 400"
	fi
	if grep -q 'was not saved' "$BODY" && ! grep -q '<' "$BODY"; then
		ok "the refusal is one line of plain text the browser can show"
	else
		bad "the refusal is not plain text a browser can show"
	fi
	if [ "$(adb "SELECT COUNT(*) FROM doc_storage WHERE report_name = 'ZZSR2'")" = 0 ]; then
		ok "an unreadable request stores nothing"
	else
		bad "an unreadable request stored a report definition anyway"
	fi

	# 72c. No report to attach it to.
	SR_CODE="$(sr_save "$COOKIES" 'doc_name=ZZSR3.xml' "$SR_XML")"
	if [ "$SR_CODE" = 400 ] && grep -q 'which report' "$BODY"; then
		ok "a request that names no report is refused and says so"
	else
		bad "a request naming no report answered $SR_CODE [$(head -c 60 "$BODY")]"
	fi

	# 72d. The refusal a person is most likely to meet: an account without
	# system rights. Report definitions are administrator material.
	adb "INSERT INTO \`groups\` (group_id, read_office, read_all, edit_office, edit_all, users, pba, motd, intake, reports)
		VALUES ('${SR_GROUP}', NULL, 1, NULL, 0, 0, 0, 0, 0, NULL)" >/dev/null
	SR_HASH="$(docker compose "${COMPOSE_ARGS[@]}" exec -T app \
		php -r 'echo password_hash($argv[1], PASSWORD_DEFAULT);' "$SR_PASS" </dev/null 2>/dev/null)"
	SR_UID="$(adb "SELECT COALESCE(MAX(user_id), 0) + 1 FROM users")"
	adb "INSERT INTO users (user_id, username, password, enabled, group_id, password_expire)
		VALUES (${SR_UID}, '${SR_USER}', '${SR_HASH}', 1, '${SR_GROUP}', 0)" >/dev/null

	: > "$SR_JAR"
	curl -sL --max-time 30 -c "$SR_JAR" -b "$SR_JAR" -o /dev/null \
		-X POST -d "login_user=${SR_USER}&login_pass=${SR_PASS}&auth_id=1" \
		"$OCM_URL/" >/dev/null

	SR_CODE="$(sr_save "$SR_JAR" 'report_name=ZZSR4&doc_name=ZZSR4.xml' "$SR_XML")"
	if [ "$SR_CODE" = 403 ]; then
		ok "a user without system rights is refused with a status, not a blank 200"
	else
		bad "a refused report save answered $SR_CODE, not 403"
	fi
	if [ "$(adb "SELECT COUNT(*) FROM doc_storage WHERE report_name = 'ZZSR4'")" = 0 ]; then
		ok "a user without system rights stores no report definition"
	else
		bad "A USER WITHOUT SYSTEM RIGHTS INSTALLED A REPORT DEFINITION"
	fi

	# 72e. Static: the browser must wait for that answer before it reloads.
	if grep -q "onreadystatechange" cms/js/save_report.js \
		&& grep -qF "body=='OK'" cms/js/save_report.js; then
		ok "save_report.js reloads the list only when the save is confirmed"
	else
		bad "save_report.js reloads the saved report list without reading the answer"
	fi

	cleanup_sr
	trap 'rm -f "$COOKIES" "$BODY"' EXIT
else
	printf '  skip the saved report definition checks (needs the database)\n'
fi

echo
echo "== 73. what a template may name: a js file, a function, a template file =="

if [ "$HAVE_DB" = 1 ] && [ "$HAVE_COMPOSE" = 1 ]; then
	TP_CASE=""
	TP_DOC=""

	cleanup_tp() {
		[ -n "${TP_DOC:-}" ] && adb "DELETE FROM doc_storage WHERE doc_id = ${TP_DOC}" >/dev/null 2>&1
		[ -n "${TP_CASE:-}" ] && adb "DELETE FROM cases WHERE case_id = ${TP_CASE}" >/dev/null 2>&1
	}
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_tp' EXIT

	TP_CASE="$(adb "SELECT COALESCE(MAX(case_id), 0) + 1 FROM cases")"
	adb "INSERT INTO cases (case_id, number, user_id, office, status)
		VALUES (${TP_CASE}, 'ZZTPCASE', 1, NULL, '1')" >/dev/null

	# A form template body, the same reach section 70 uses: docgen.php hands
	# an uploaded doc_type = 'F' body to pikaTempLib as the template string,
	# so a person with the Documents tab -- not only whoever writes the
	# shipped templates -- decides what these tags say.
	#
	# The first tag walks out of the js directory. Before the fix it was read
	# and rendered: /etc/passwd came back inside a <script> block.
	TP_BODY='A=[%%[../../../../../etc/passwd,javascript]%%] B=[%%[popUp.js,javascript]%%]'
	TP_HEX="$(docker compose "${COMPOSE_ARGS[@]}" exec -T app \
		php -r 'echo bin2hex(addslashes(gzcompress($argv[1], 9)));' "$TP_BODY" </dev/null 2>/dev/null)"
	TP_DOC="$(adb "SELECT COALESCE(MAX(doc_id), 0) + 1 FROM doc_storage")"
	adb "INSERT INTO doc_storage
		(doc_id, doc_name, doc_data, doc_size, mime_type, doc_type, description, created, case_id, user_id)
		VALUES (${TP_DOC}, 'zztp-form.txt', UNHEX('${TP_HEX}'), 64, 'text/plain', 'F',
			'zz template path form', CURDATE(), 0, 1)" >/dev/null

	: > "$COOKIES"
	curl -s --max-time 30 -c "$COOKIES" -o /dev/null "$OCM_URL/index.php"
	curl -s --max-time 30 -c "$COOKIES" -b "$COOKIES" -o /dev/null \
		-X POST -d "login_user=admin&login_pass=${OCM_PASSWORD}&auth_id=1" \
		"$OCM_URL/index.php"
	curl -s --max-time 30 -b "$COOKIES" -o "$BODY" "$OCM_URL/system-settings.php"
	TP_CSRF="$(grep -oE 'name="_csrf" value="[0-9a-f]{64}"' "$BODY" | head -1 | sed 's/.*value="//; s/"//')"

	if [ -z "$TP_CSRF" ] || [ -z "$TP_HEX" ]; then
		bad "could not set up the template path checks"
	else
		curl -s --max-time 30 -b "$COOKIES" -o "$BODY" \
			-X POST -d "_csrf=${TP_CSRF}&case_id=${TP_CASE}&form_id=${TP_DOC}&debug=0&recipient=&opposing=&opp_counsel=&autosave=" \
			"$OCM_URL/ops/docgen.php"

		if grep -q 'root:x:0:0' "$BODY"; then
			bad "A FORM TEMPLATE READ A FILE OUTSIDE THE JS DIRECTORY (CWE-22)"
		else
			ok "a form template cannot read a file outside the js directory"
		fi

		if grep -q 'etc/passwd not found' "$BODY"; then
			ok "the refused js name is reported as not found, not resolved"
		else
			bad "the refused js name was not reported"
		fi

		# The positive control. A plain name in that one flat directory is
		# how every shipped template asks for its script.
		if grep -q 'function popUp' "$BODY"; then
			ok "a template can still include a js file by name"
		else
			bad "a template can no longer include a js file by name"
		fi
	fi

	cleanup_tp
	TP_CASE=""; TP_DOC=""
	trap 'rm -f "$COOKIES" "$BODY"' EXIT
else
	printf '  skip the template path checks (needs the database)\n'
fi

# 73b. The helpers themselves, exercised directly. These paths have no live
# caller today, which is the reason to pin them: the next caller will read
# the name and trust it.
if [ "$HAVE_COMPOSE" = 1 ]; then
	TP_OUT="$(docker compose "${COMPOSE_ARGS[@]}" exec -T app php -r '
		require_once("/var/www/html/cms/app/lib/pl.php");
		$r = array();
		$r[] = "path:" . pl_clean_file_path("....//");
		$r[] = "path2:" . pl_clean_file_path("../../etc/passwd");
		$r[] = "name:" . pl_clean_file_name("..");
		$r[] = "js1:" . (pl_safe_js_file_name("../x.js") ? "y" : "n");
		$r[] = "js2:" . (pl_safe_js_file_name("popUp.js") ? "y" : "n");
		$r[] = "fn1:" . (pl_template_section_callable("phpinfo") ? "y" : "n");
		$r[] = "fn2:" . (pl_template_section_callable("system") ? "y" : "n");
		$r[] = "fn3:" . (pl_template_section_callable("pl_html_escape") ? "y" : "n");
		$r[] = "fn4:" . (pl_template_section_callable("no_such_function_here") ? "y" : "n");
		echo implode(" ", $r);
	' </dev/null 2>/dev/null)"

	# A single pass over "....//" used to delete the inner dots and slashes
	# and hand back "../" -- the very string it was asked to remove.
	if printf '%s' "$TP_OUT" | grep -q 'path:[[:space:]]'; then
		ok "a cleaned file path does not survive as a climb"
	else
		bad "pl_clean_file_path left something in \"....//\" [$TP_OUT]"
	fi

	if printf '%s' "$TP_OUT" | grep -q 'path2:etc/passwd'; then
		ok "a cleaned file path drops its parent directory segments"
	else
		bad "pl_clean_file_path did not drop the parent segments [$TP_OUT]"
	fi

	if printf '%s' "$TP_OUT" | grep -q 'js1:n' && printf '%s' "$TP_OUT" | grep -q 'js2:y'; then
		ok "a js file name must be a plain name in one directory"
	else
		bad "pl_safe_js_file_name accepts or refuses the wrong names [$TP_OUT]"
	fi

	if printf '%s' "$TP_OUT" | grep -q 'fn1:n' \
		&& printf '%s' "$TP_OUT" | grep -q 'fn2:n' \
		&& printf '%s' "$TP_OUT" | grep -q 'fn4:n'; then
		ok "a template section cannot name a function built into PHP"
	else
		bad "a template section can name a built-in function [$TP_OUT]"
	fi

	if printf '%s' "$TP_OUT" | grep -q 'fn3:y'; then
		ok "a template section can still name a function this application defines"
	else
		bad "a template section can no longer name an application function [$TP_OUT]"
	fi
fi

# 73c. Static: a template file that cannot be opened must end the render,
# not fall through to fopen(false) and then feof(false), which is fatal on
# PHP 8.
if grep -qF 'trigger_error("Invalid template file "' cms/app/lib/pl.php \
	&& grep -qF 'Failed to open template file {$template_real}' cms/app/lib/pl.php; then
	ok "pl_template refuses a template file it cannot open instead of warning on"
else
	bad "pl_template still warns and carries on with a template file it cannot open"
fi

echo
echo "== 74. a conflict is two parties on opposite sides, not two parties =="

# The three conflict searches asked for "relation_code != this party's role",
# which reads as "anybody but somebody in my own seat". That is not what a
# conflict of interest is. It reported a judge who had sat on two cases
# against both parties, a referral agency that had sent in more than one
# person, and a client here who turned up as a household member there --
# two people on the same side of two different matters.
#
# Noise is not harmless on this screen. The conflict tab is the one page in
# this application a lawyer is ethically required to read, and a tab that
# cries wolf is the tab staff learn to click past.
#
# pl_conflict_opposing_roles() names the roles that genuinely oppose a given
# role: a client-side party (1 Client, 6 Non Adv. Household) against prior
# adverse parties (2 Opposing Party, 3 Opposing Counsel, 7 Adverse
# Household), an adverse party against prior clients. Anything else -- 5
# Judge, 50 Referral Agency, 99 Other, and any code a site added itself --
# opposes nothing, and that party is skipped rather than searched on an
# empty list.

# 74a. The rule itself. No database needed.
if [ "$HAVE_COMPOSE" = 1 ]; then
	CF_OUT="$(docker compose "${COMPOSE_ARGS[@]}" exec -T app php -r '
		require_once("/var/www/html/cms/app/lib/pl.php");
		$r = array();
		foreach (array(1,6,2,3,7,5,50,99,77) as $rc) {
			$r[] = "r{$rc}:" . implode("-", pl_conflict_opposing_roles($rc));
		}
		echo implode(" ", $r);
	' </dev/null 2>/dev/null)"

	if printf '%s' "$CF_OUT" | grep -qF 'r1:2-3-7' && printf '%s' "$CF_OUT" | grep -qF 'r6:2-3-7'; then
		ok "a client-side party is checked against adverse parties"
	else
		bad "the client side opposes the wrong roles [$CF_OUT]"
	fi

	if printf '%s' "$CF_OUT" | grep -qF 'r2:1' \
		&& printf '%s' "$CF_OUT" | grep -qF 'r3:1' \
		&& printf '%s' "$CF_OUT" | grep -qF 'r7:1'; then
		ok "an adverse party is checked against prior clients"
	else
		bad "the adverse side opposes the wrong roles [$CF_OUT]"
	fi

	# A role in neither bucket opposes nothing. Note the bracket expression:
	# the local grep is ugrep, where an unanchored "." runs across the line.
	if printf '%s' "$CF_OUT" | grep -qE 'r5:( |$)' \
		&& printf '%s' "$CF_OUT" | grep -qE 'r50:( |$)' \
		&& printf '%s' "$CF_OUT" | grep -qE 'r99:( |$)' \
		&& printf '%s' "$CF_OUT" | grep -qE 'r77:( |$)'; then
		ok "a judge, a referral agency and an unknown role oppose nothing"
	else
		bad "a role outside both buckets still opposes something [$CF_OUT]"
	fi
fi

# 74b. The real check, against seeded cases. Case A is the case being
# checked; case B holds the prior matters its parties turn up in.
if [ "$HAVE_DB" = 1 ] && [ "$HAVE_COMPOSE" = 1 ]; then
	cf_dex() { docker compose "${COMPOSE_ARGS[@]}" exec -T app "$@"; }

	cleanup_cf() {
		adb "DELETE FROM conflict WHERE contact_id IN
			(SELECT contact_id FROM contacts WHERE last_name LIKE 'ZZCF%')" >/dev/null
		adb "DELETE FROM cases WHERE number LIKE 'ZZ-CF-%'" >/dev/null
		adb "DELETE FROM contacts WHERE last_name LIKE 'ZZCF%'" >/dev/null
	}
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_cf' EXIT
	cleanup_cf

	cf_next_id() {
		adb "SELECT GREATEST(
			COALESCE((SELECT MAX(${2}) FROM \`${1}\`), 0),
			COALESCE((SELECT count FROM counters WHERE id = '${1}'), 0)) + 1"
	}
	cf_bump() { adb "UPDATE counters SET count = GREATEST(count, ${2}) WHERE id = '${1}'" >/dev/null; }

	# mp_last is what the NAME search matches on, so set it here rather than
	# leaving it to a save path this fixture never runs.
	cf_contact() {
		local id
		id="$(cf_next_id contacts contact_id)"
		adb "INSERT INTO contacts (contact_id, first_name, last_name, mp_first, mp_last)
			VALUES (${id}, 'Zz', '${1}', '${2}', '${3}')" >/dev/null
		cf_bump contacts "$id"
		printf '%s' "$id"
	}
	cf_case() {
		local id
		id="$(cf_next_id cases case_id)"
		adb "INSERT INTO cases (case_id, number, user_id, office, status, client_id, open_date)
			VALUES (${id}, '${1}', 1, 'ZZC', '1', ${2}, '2019-01-01')" >/dev/null
		cf_bump cases "$id"
		printf '%s' "$id"
	}
	cf_link() {
		local id
		id="$(cf_next_id conflict conflict_id)"
		adb "INSERT INTO conflict (conflict_id, case_id, contact_id, relation_code)
			VALUES (${id}, ${1}, ${2}, ${3})" >/dev/null
		cf_bump conflict "$id"
	}

	CF_MP="$(cf_dex php -r 'echo metaphone("Zzcfsmith");' </dev/null 2>/dev/null)"

	# Three contacts checked by contact ID: no name, so only the ID search
	# can reach them.
	CF_SAME="$(cf_contact ZZCFSAME '' '')"
	CF_JUDGED="$(cf_contact ZZCFJUDGED '' '')"
	CF_REAL="$(cf_contact ZZCFREAL '' '')"
	# Three sharing a surname, for the NAME search.
	CF_NAME_SELF="$(cf_contact ZZCFSMITH ZZ "$CF_MP")"
	CF_NAME_JUDGE="$(cf_contact ZZCFSMITH ZZ "$CF_MP")"
	CF_NAME_ADV="$(cf_contact ZZCFSMITH ZZ "$CF_MP")"

	CF_A="$(cf_case ZZ-CF-A "$CF_SAME")"
	CF_B="$(cf_case ZZ-CF-B "$CF_SAME")"

	# Case A, the one being checked.
	cf_link "$CF_A" "$CF_SAME"      1   # Client
	cf_link "$CF_A" "$CF_JUDGED"    2   # Opposing Party
	cf_link "$CF_A" "$CF_REAL"      1   # Client
	cf_link "$CF_A" "$CF_NAME_SELF" 1   # Client

	# Case B, where those people turn up again.
	cf_link "$CF_B" "$CF_SAME"       6  # Non Adv. Household: same side
	cf_link "$CF_B" "$CF_JUDGED"     5  # Judge: opposes nothing
	cf_link "$CF_B" "$CF_REAL"       2  # Opposing Party: a real conflict
	cf_link "$CF_B" "$CF_NAME_JUDGE" 5  # Judge of the same name
	cf_link "$CF_B" "$CF_NAME_ADV"   3  # Opposing Counsel: a real conflict

	if [ -z "$CF_MP" ] || [ -z "${CF_A:-}" ] || [ -z "${CF_NAME_ADV:-}" ]; then
		bad "could not seed the conflict fixtures - section 74b is untested"
	else
		# PL_DISABLE_SECURITY first, or pika_init() renders the login page
		# under CLI and exits before the echo runs.
		CF_HITS="$(cf_dex php -r '
			define("PL_DISABLE_SECURITY", true);
			chdir("/var/www/html/cms");
			require_once("pika-danio.php");
			pika_init();
			require_once("app/lib/pikaCase.php");
			$c = new pikaCase((int) $argv[1]);
			$ids = array();
			foreach ($c->fuzzyConflictCheck(50) as $h) {
				$ids[] = "," . $h["contact_id"] . ",";
			}
			echo "HITS:" . implode("", array_unique($ids));
		' "$CF_A" </dev/null 2>/dev/null | grep -o 'HITS:.*')"

		cf_hit() { printf '%s' "$CF_HITS" | grep -qF ",${1},"; }

		# The positive controls run first. Without them the four refusals
		# below would pass on a check that returned nothing at all.
		if cf_hit "$CF_REAL"; then
			ok "a client here who is the opposing party there is still reported"
		else
			bad "A REAL CONFLICT IS NO LONGER REPORTED - the rest of 74b proves nothing [$CF_HITS]"
		fi

		if cf_hit "$CF_NAME_ADV"; then
			ok "a client here whose name matches opposing counsel there is still reported"
		else
			bad "A REAL NAME CONFLICT IS NO LONGER REPORTED [$CF_HITS]"
		fi

		if cf_hit "$CF_SAME"; then
			bad "A CLIENT MATCHING A HOUSEHOLD MEMBER ON ANOTHER CASE IS REPORTED AS A CONFLICT [$CF_HITS]"
		else
			ok "two parties on the same side of two matters are not a conflict"
		fi

		if cf_hit "$CF_JUDGED"; then
			bad "A JUDGE ON ANOTHER CASE IS REPORTED AS A CONFLICT [$CF_HITS]"
		else
			ok "a judge who sat on another case is not a conflict"
		fi

		if cf_hit "$CF_NAME_JUDGE"; then
			bad "A JUDGE SHARING A PARTY'S SURNAME IS REPORTED AS A CONFLICT [$CF_HITS]"
		else
			ok "a judge who shares a party's surname is not a conflict"
		fi
	fi

	cleanup_cf
	trap 'rm -f "$COOKIES" "$BODY"' EXIT
fi

# 74c. The other two copies of the check carry the same gate. pikaCms is the
# copy the report under cms/reports/ uses, and pikaLSXML_V2 checks an intake
# that has not been saved yet; both reach pl.php through their own bootstrap.
if grep -qF 'pl_conflict_opposing_roles($relation_code)' cms/app/extralib/lib/pikaCms.php \
	&& grep -qF 'pl_conflict_opposing_roles($relation_code)' cms/app/lib/pikaLSXML_V2.php; then
	ok "the report and intake copies of the check carry the same role gate"
else
	bad "a copy of the conflict check still has no role gate"
fi

# The flag on the case, which is what colours the tab, was counted with the
# same "!= my own role" test in pikaCms. Fixing the search but not the flag
# would leave the case marked as having conflicts with none listed.
if grep -qF "pl_conflict_opposing_roles(\$row['relation_code'])" cms/app/extralib/lib/pikaCms.php; then
	ok "the potential-conflict flag is counted with the same rule"
else
	bad "the potential-conflict flag still counts any role but this one"
fi

# -F because the comments above each fix quote the old clause, and a bare
# grep would match those and report a fix as its own absence.
if grep -qF 'WHERE relation_code != ?' cms/app/lib/pikaCase.php cms/app/extralib/lib/pikaCms.php cms/app/lib/pikaLSXML_V2.php; then
	bad "a conflict query still asks for any role but this one"
else
	ok "no conflict query asks for any role but this one"
fi

# ---------------------------------------------------------------------------
# 75. Input that is not a scalar, and a User-Agent header that is not there.
#
# A request may make any form field an array simply by naming it twice.
# pl_clean_form_input() walks an array and hands one back whatever filter
# mode it was asked for, so an array reached code that expected a string:
#
#   a) pl_build_sql() called strlen() on it. That is a TypeError on PHP 8,
#      so GET dataops.php?action=add_activity&act_date[]=x returned a 500.
#   b) dataops.php also hands $_REQUEST['act_date'] straight to
#      pl_date_mogrify(), which called strpos() on it.
#
# pl_date_mogrify() had two further defects. It put no limit on the length
# of the string it would explode(), and its fallback ended
# date("Y-m-d", strtotime($date)) without testing the return, so text it
# could not read became a date near the epoch rather than being refused.
# pl_clean_form_input()'s date mode accepted that date, because the year
# passed its 1800-2099 range test.
#
# browser_is_mobile() read $_SERVER['HTTP_USER_AGENT'] three times without
# checking the header was there, and tested strpos() for truth rather than
# against false, so a User-Agent beginning "Android" -- which is what
# several Android browsers send -- was reported as not mobile. pikaAuth
# read REMOTE_ADDR and HTTP_USER_AGENT the same unguarded way.
#
# 75c also asserts that pl_template3() stays removed. It referenced Smarty,
# which is not in this tree, so it could only ever fatal on its own
# require_once, and nothing called it.
# ---------------------------------------------------------------------------

echo
echo "== 75. a form field named twice is an array, and a header may be absent =="

# 75a and 75b. The live behaviour, in one bootstrap. PL_DISABLE_SECURITY
# first, or pika_init() renders the login page and exits before the echo.
if [ "$HAVE_COMPOSE" = 1 ]; then
	DM_OUT="$(docker compose "${COMPOSE_ARGS[@]}" exec -T app php -r '
		define("PL_DISABLE_SECURITY", true);
		chdir("/var/www/html/cms");
		require_once("pika-danio.php");
		pika_init();
		// pl_build_sql lives in the other bootstrap and reads the table
		// definition out of the schema, so it needs both of these.
		require_once("app/extralib/lib/pl-legacy.php");

		$out = array();
		$out[] = "good:" . implode(",", array(
			pl_date_mogrify("9/9/1999"),
			pl_date_mogrify("1999-09-09"),
			pl_date_mogrify("Sept 9 1999")));

		try {
			$out[] = "arr:" . var_export(pl_date_mogrify(array("x")), true);
		} catch (Throwable $e) {
			$out[] = "arr:THREW";
		}

		$out[] = "junk:" . var_export(pl_date_mogrify("not a date at all"), true);
		$out[] = "long:" . var_export(pl_date_mogrify(str_repeat("9/9/1999 ", 5000)), true);

		// The defect with a missing header was the warning, not the answer,
		// so count what it raises rather than only what it returns.
		unset($_SERVER["HTTP_USER_AGENT"]);
		$noticed = 0;
		set_error_handler(function ($n, $m) use (&$noticed) { $noticed++; return true; });
		$mobile = browser_is_mobile();
		restore_error_handler();
		$out[] = "noua:" . var_export($mobile, true) . "-" . ($noticed ? "warned" : "quiet");
		$_SERVER["HTTP_USER_AGENT"] = "Android 13; Mobile";
		$out[] = "android0:" . var_export(browser_is_mobile(), true);
		$_SERVER["HTTP_USER_AGENT"] = "Mozilla/5.0 (Windows NT 10.0)";
		$out[] = "desktop:" . var_export(browser_is_mobile(), true);

		// act_type is the control: a scalar field alongside the array one
		// has to survive, and the separators around it have to be right.
		foreach (array(
			"INSERT" => array("act_date" => array("x"), "act_type" => "T", "notes" => "n"),
			"UPDATE" => array("act_id" => 1, "act_date" => array("x"), "act_type" => "T", "notes" => "n"))
			as $verb => $data) {
			$tag = ("INSERT" === $verb) ? "ins" : "upd";

			try {
				$s = pl_build_sql($verb, "activities", $data);
				$bad = (false !== strpos($s, ", ,")) || (false !== strpos($s, "SET ,"))
					|| (substr(rtrim($s), -1) === ",");
				$out[] = $tag . ":" . ((false === strpos($s, "act_date")) ? "omitted" : "present")
					. ((false !== strpos($s, "act_type")) ? "-kept" : "-lost")
					. ($bad ? "-badcommas" : "-ok");
			} catch (Throwable $e) {
				$out[] = $tag . ":THREW";
			}
		}

		echo implode(" ", $out);
	' </dev/null 2>/dev/null)"

	# The positive control comes first. Every refusal below is an assertion
	# that something returns false, and a function that had stopped reading
	# dates at all would satisfy all of them.
	if printf '%s' "$DM_OUT" | grep -qF 'good:1999-09-09,1999-09-09,1999-09-09'; then
		ok "pl_date_mogrify still reads the date formats this application accepts"
	else
		bad "pl_date_mogrify no longer reads a plain date, so the rest of 75a proves nothing [$DM_OUT]"
	fi

	if printf '%s' "$DM_OUT" | grep -qF 'arr:false'; then
		ok "pl_date_mogrify refuses an array rather than raising a TypeError"
	else
		bad "an array field still reaches strpos() in pl_date_mogrify [$DM_OUT]"
	fi

	if printf '%s' "$DM_OUT" | grep -qF 'junk:false'; then
		ok "pl_date_mogrify refuses text it cannot read instead of returning the epoch"
	else
		bad "pl_date_mogrify still turns unreadable text into a date [$DM_OUT]"
	fi

	if printf '%s' "$DM_OUT" | grep -qF 'long:false'; then
		ok "pl_date_mogrify refuses a string far longer than any date"
	else
		bad "pl_date_mogrify still explodes an unbounded string [$DM_OUT]"
	fi

	if printf '%s' "$DM_OUT" | grep -qF 'android0:true' \
		&& printf '%s' "$DM_OUT" | grep -qF 'desktop:false'; then
		ok "browser_is_mobile detects a User-Agent that begins with Android"
	else
		bad "browser_is_mobile still tests strpos() for truth [$DM_OUT]"
	fi

	if printf '%s' "$DM_OUT" | grep -qF 'noua:false-quiet'; then
		ok "browser_is_mobile answers a request that sends no User-Agent"
	else
		bad "browser_is_mobile still warns when no User-Agent was sent [$DM_OUT]"
	fi

	if printf '%s' "$DM_OUT" | grep -qF 'ins:omitted-kept-ok'; then
		ok "pl_build_sql leaves an array field out of the INSERT"
	else
		bad "pl_build_sql mishandles an array field in an INSERT [$DM_OUT]"
	fi

	if printf '%s' "$DM_OUT" | grep -qF 'upd:omitted-kept-ok'; then
		ok "pl_build_sql leaves an array field out of the UPDATE"
	else
		bad "pl_build_sql mishandles an array field in an UPDATE [$DM_OUT]"
	fi
fi

# 75c. Static. The session values pikaAuth reads cannot be exercised from
# the command line, and a removal is only provable by looking.
if grep -qF '$this->user_agent = $_SERVER[' cms/app/lib/pikaAuth.php \
	|| grep -qF '$this->ip_address = $_SERVER[' cms/app/lib/pikaAuth.php; then
	bad "pikaAuth still reads a \$_SERVER key without checking it is there"
else
	ok "pikaAuth guards both of the \$_SERVER values it reads"
fi

if grep -qF 'pl_template3' cms/app/lib/pl.php \
	|| grep -qF 'Smarty.class.php' cms/app/lib/pl.php; then
	bad "the dead Smarty template function is back in pl.php"
else
	ok "the dead Smarty template function stays out of pl.php"
fi

echo
echo "== 76. A stored md5, the extensions allowlist, TLS peer checks and XXE =="

# 76a. Static. PHP compares two strings that both look like numbers as
# numbers, and an md5 hex digest that begins "0e" and continues in digits
# looks like scientific notation. Two digests of that shape are therefore
# "equal" to ==, whatever they actually contain, so anyone knowing one
# such string could sign in as a user whose stored md5 was another. 76c
# proves it over HTTP; this catches the comparison returning anywhere the
# live test cannot reach.
sm76_loose=0
for sm76_f in cms/app/lib/pikaAuthDb.php cms/password.php; do
	if grep -qE 'md5\([^)]*\) *[!=]=' "$sm76_f" \
		|| grep -qE '[!=]= *md5\(' "$sm76_f"; then
		sm76_loose=1
	fi
done
if [ "$sm76_loose" = 1 ]; then
	bad "a stored md5 password is compared with == or != again"
else
	ok "every stored-md5 password comparison uses hash_equals"
fi

# 76b. The comparison has to still be there. Deleting it would also pass
# 76a, and would sign nobody in at all.
if grep -qF 'hash_equals((string) $row[' cms/app/lib/pikaAuthDb.php \
	&& grep -qF 'hash_equals((string) $user->password, md5((string) $oldpass))' cms/password.php; then
	ok "both files still compare the stored md5, through hash_equals"
else
	bad "a stored-md5 comparison has gone missing rather than been fixed"
fi

# 76c. Live. The fixture's stored password is md5("240610708"), which is
# 0e462097431906509019562988736854. md5("QNKCDZO") has the same shape, and
# before the fix it signed in as this user. A successful md5 login rewrites
# the row to bcrypt, so the fixture is written again before each attempt.
#
# The row is removed again at the end of the section, and before the
# section as well, so an interrupted earlier run cannot leave it behind.
if [ "$HAVE_DB" = 1 ]; then
	SM76_MD5='0e462097431906509019562988736854'
	SM76_UID=9912

	sm76_drop() {
		adb "DELETE FROM users WHERE user_id = ${SM76_UID} OR username = 'zzsmoke_md5'" >/dev/null
	}
	sm76_reset() {
		sm76_drop
		adb "INSERT INTO users (user_id, username, password, enabled, group_id, last_name, auth_method)
			VALUES (${SM76_UID}, 'zzsmoke_md5', '${SM76_MD5}', 1, 'system', 'SMOKE', 'password')" >/dev/null
	}
	# Answers 0 when the sign-in worked: the landing page then carries no
	# login form, so no password field is left to count.
	sm76_login() {
		local jar body
		jar="$(mktemp)"
		body="$(mktemp)"
		curl -sL --max-time 30 -c "$jar" -o /dev/null "$OCM_URL/index.php"
		curl -sL --max-time 30 -c "$jar" -b "$jar" -o /dev/null \
			--data-urlencode "login_user=zzsmoke_md5" \
			--data-urlencode "login_pass=$1" \
			-d "auth_id=1" "$OCM_URL/index.php"
		curl -sL --max-time 30 -b "$jar" -o "$body" "$OCM_URL/index.php"
		grep -c 'login_pass' "$body"
		rm -f "$jar" "$body"
	}

	sm76_reset
	if [ "$(sm76_login 'QNKCDZO')" = 0 ]; then
		bad "a different 0e-prefixed md5 signed in as the md5 fixture user"
	else
		ok "a different 0e-prefixed md5 does not sign in as the md5 fixture user"
	fi

	sm76_reset
	if [ "$(sm76_login '240610708')" = 0 ]; then
		ok "the md5 fixture user's own password still signs in"
	else
		bad "the md5 fixture user's own password no longer signs in"
	fi

	sm76_drop
fi

# 76d. Static. system-extensions.php names each checkbox with the path its
# folder scan produced, so every name carries a leading '/', and
# ops/update_extensions.php joins the names that come back with ':'. A
# reader has to undo both. pm.php used to split on ',' and compare against
# a name with no slash, so its in_array() was false for every request and
# no extension could be reached at all. One parser, in one place, is what
# stops the two sides drifting apart again.
if grep -qF "explode(',', (string) pl_settings_get('extensions'))" cms/pm.php; then
	bad "pm.php parses the extensions setting itself again"
else
	ok "pm.php reads the extensions setting through pl_enabled_extensions()"
fi

if grep -qF 'function pl_enabled_extensions(' cms/app/lib/pl.php; then
	ok "pl_enabled_extensions() is the one parser, in pl.php"
else
	bad "pl_enabled_extensions() has gone from pl.php"
fi

# 76e. Live. The parser itself, over a setting in the shape the extensions
# page actually writes. pl_settings_set() holds the value for this process
# only, so nothing is stored.
if [ "$HAVE_COMPOSE" = 1 ]; then
	sm76_dex() { docker compose "${COMPOSE_ARGS[@]}" exec -T app "$@"; }
	sm76_php='define("PL_DISABLE_SECURITY", true);
chdir("/var/www/html/cms");
require_once("pika-danio.php");
pika_init();
pl_settings_set("extensions", "/alpha:/beta");
print "PARSED[" . implode(",", pl_enabled_extensions()) . "]";'

	sm76_parsed="$(sm76_dex php -r "$sm76_php" 2>/dev/null \
		| grep -oE 'PARSED\[[^]]*\]' | head -1)"

	if [ "$sm76_parsed" = 'PARSED[alpha,beta]' ]; then
		ok "pl_enabled_extensions() splits on ':' and drops the leading slash"
	else
		bad "pl_enabled_extensions() read '/alpha:/beta' as ${sm76_parsed:-nothing}"
	fi
fi

# 76f. Live. The extensions form posts to ops/update_extensions.php, which
# requires the per-session token on every POST. The form carried no token
# field, so saving the extension list always landed on the token-recovery
# page instead of saving.
SM76_JAR="$(mktemp)"
curl -sL --max-time 30 -c "$SM76_JAR" -o /dev/null "$OCM_URL/index.php"
curl -sL --max-time 30 -c "$SM76_JAR" -b "$SM76_JAR" -o /dev/null \
	--data-urlencode "login_user=${OCM_USER}" \
	--data-urlencode "login_pass=${OCM_PASSWORD}" \
	-d "auth_id=1" "$OCM_URL/index.php"
curl -sL --max-time 30 -b "$SM76_JAR" -o "$BODY" "$OCM_URL/system-extensions.php"

if grep -qF 'name="_csrf"' "$BODY"; then
	ok "the extensions form carries the CSRF token"
else
	bad "the extensions form carries no CSRF token, so it cannot save"
fi

# 76g. Live. pl_csrf_check() leaves its own fields in $_POST, and the loop
# that builds the setting read every POST field name as an extension name,
# so '_csrf' was recorded as an installed extension -- a name pm.php would
# then accept for a require(). Posting the token and nothing else is enough
# to show it: the saved list must come back empty, not holding '_csrf'.
#
# The save rewrites the whole settings table from what this request holds,
# so the extensions rows are read first and written back afterwards, row
# existence included.
if [ "$HAVE_DB" = 1 ]; then
	SM76_SNAP="$(mktemp)"
	adb "SELECT label, value FROM settings WHERE label LIKE 'extensions%'" > "$SM76_SNAP"

	SM76_TOK="$(grep -oE 'name="_csrf" value="[0-9a-f]{64}"' "$BODY" \
		| head -1 | sed -e 's/.*value="//' -e 's/"$//')"
	SM76_CODE="$(curl -sL --max-time 30 -b "$SM76_JAR" -c "$SM76_JAR" \
		-o /dev/null -w '%{http_code}' \
		--data-urlencode "_csrf=${SM76_TOK}" \
		"$OCM_URL/ops/update_extensions.php")"
	SM76_SAVED="$(adb "SELECT value FROM settings WHERE label = 'extensions'")"

	if [ "$SM76_CODE" = 200 ] && [ -n "$SM76_TOK" ]; then
		ok "the extensions list saves with the token the form supplies"
	elif [ -z "$SM76_TOK" ]; then
		bad "no CSRF token to save the extensions list with"
	else
		bad "saving the extensions list answered $SM76_CODE"
	fi

	case "$SM76_SAVED" in
		*csrf*) bad "a CSRF field name was recorded as an installed extension" ;;
		*)      ok "a CSRF field name is not recorded as an installed extension" ;;
	esac

	while IFS="$(printf '\t')" read -r sm76_label sm76_value; do
		[ -n "$sm76_label" ] || continue
		adb "INSERT INTO settings (label, value) VALUES ('${sm76_label}', '${sm76_value}')
			ON DUPLICATE KEY UPDATE value = VALUES(value)" >/dev/null
	done < "$SM76_SNAP"
	rm -f "$SM76_SNAP"
fi
rm -f "$SM76_JAR"

# 76h. Static. app/scripts/cms-csv-download.php is generated by
# system-mac_download.php with the operator's own OCM username and password
# written into it, and run from cron against an https URL. Peer
# verification was off, so anything able to answer for that host name could
# present a certificate of its own and be handed the password. Checking the
# host name while not checking the certificate that carries it checks
# nothing, so both settings are asserted together.
if grep -qF 'CURLOPT_SSL_VERIFYPEER, FALSE' cms/app/scripts/cms-csv-download.php \
	|| grep -qF 'CURLOPT_SSL_VERIFYPEER, false' cms/app/scripts/cms-csv-download.php \
	|| grep -qF 'CURLOPT_SSL_VERIFYPEER, 0' cms/app/scripts/cms-csv-download.php; then
	bad "the generated csv download script turns TLS peer verification off"
else
	ok "the generated csv download script leaves TLS peer verification on"
fi

sm76_peer="$(grep -cF 'CURLOPT_SSL_VERIFYPEER, TRUE' cms/app/scripts/cms-csv-download.php)"
sm76_host="$(grep -cF 'CURLOPT_SSL_VERIFYHOST, 2' cms/app/scripts/cms-csv-download.php)"
if [ "$sm76_peer" = 2 ] && [ "$sm76_host" = 2 ]; then
	ok "both requests in the csv download script verify peer and host name"
else
	bad "csv download script: $sm76_peer peer checks, $sm76_host host checks, wanted 2 and 2"
fi

# 76i. Static. ops/upload_report.php parses a report definition posted as a
# raw request body. LIBXML_NONET stops the parser being talked into
# fetching a DTD or an entity over the network by the document it is
# reading. LIBXML_NOENT would switch entity substitution back on, which is
# the other half of the same problem, so its absence is asserted too.
if grep -qF 'loadXML($postText, LIBXML_NONET)' cms/ops/upload_report.php; then
	ok "the report parser is told not to go out to the network"
else
	bad "the report parser no longer passes LIBXML_NONET"
fi

# Read off the call rather than the file: the comment above it names
# LIBXML_NOENT to explain why it is absent, and a whole-file grep matches
# that sentence.
if grep -F 'loadXML(' cms/ops/upload_report.php | grep -qF 'LIBXML_NOENT'; then
	bad "the report parser substitutes entities again"
else
	ok "the report parser leaves entity substitution off"
fi

# 76j. Static. The same generated download script reads a list of table
# names out of the answer the far end sends, and writes one file per name
# into a folder the operator named. The path puts a separator in front of
# the name, so without a check on its shape the answering server chooses
# where the operator's cron job writes. Two things are asserted: the name
# is held to a plain identifier, and the decoded answer is checked to be a
# list at all before the loop reads it.
if grep -qF "preg_match('/^[A-Za-z0-9_]+\\z/', (string) \$v)" cms/app/scripts/cms-csv-download.php; then
	ok "the csv download only accepts plain table names"
else
	bad "the csv download takes any table name the server sends"
fi

if grep -qF 'if (!is_array($result))' cms/app/scripts/cms-csv-download.php; then
	ok "the csv download checks it got a list of tables"
else
	bad "the csv download loops over whatever json_decode returned"
fi

# 76k. Static. system-mac_download.php generates that script, and the URL it
# writes into it is the address the script posts this operator's OCM username
# and password to, from cron, for as long as it is installed. It was built out
# of $_SERVER['HTTP_HOST'] -- the Host header, unvalidated, and under Apache's
# default UseCanonicalName Off whatever was sent. pl_canonical_origin() is what
# the rest of the tree uses for this: it prefers the canonical_url setting, so a
# deployment that cannot trust the Host header has somewhere to say so, and it
# holds the host to a hostname shape instead of pasting it in.
#
# Asserted statically rather than by forging a Host header, because Apache
# answers 400 to a Host containing a quote or CRLF before PHP is reached, so a
# forged-Host request tests Apache and not this file.
#
# Read off the assignment rather than the file, for the reason 76i gives: the
# comment above this code names HTTP_HOST to explain why it is gone, and a
# whole-file grep matches that sentence.
if grep -F "'url' =>" cms/system-mac_download.php | grep -qF 'HTTP_HOST'; then
	bad "the mac download script's URL is built from the Host header again"
else
	ok "the mac download script's URL does not come from the Host header"
fi

if grep -qF "pl_canonical_origin('https')" cms/system-mac_download.php; then
	ok "the mac download script's URL comes from pl_canonical_origin()"
else
	bad "the mac download script does not use pl_canonical_origin()"
fi

# Both download branches also used to answer "Content-Type: text/txt", which is
# not a media type -- nothing registers it, so what a browser does with it is a
# matter of policy rather than of specification.
# Read off the header calls, again because the comment names the old type.
if grep -F 'header(' cms/system-mac_download.php | grep -qF 'text/txt'; then
	bad "the mac download branches still answer with the made-up type text/txt"
else
	ok "the mac download branches do not answer with text/txt"
fi

if [ "$(grep -F 'header(' cms/system-mac_download.php | grep -cF 'text/plain; charset=')" -eq 2 ]; then
	ok "both mac download branches answer with text/plain and a charset"
else
	bad "the mac download branches do not both answer with text/plain and a charset"
fi

# 76l. The same two things over HTTP, on an ordinary request: the generated
# script must arrive as a text/plain attachment, and the URL inside it must be
# the https origin of this deployment rather than anything else.
MD_TOK="$(curl -s --max-time 30 -b "$COOKIES" "$OCM_URL/system-mac_download.php" \
	| grep -oE 'name="_csrf" value="[0-9a-f]{64}"' | head -1 \
	| sed -e 's/.*value="//' -e 's/"$//')"

if [ "${#MD_TOK}" -ne 64 ]; then
	printf '  skip the mac download response check (no csrf token on the page)\n'
else
	MD_HDR="$BODY.mac76l"
	curl -s --max-time 30 -b "$COOKIES" -D "$MD_HDR" -o "$BODY" \
		-X POST \
		--data-urlencode "_csrf=${MD_TOK}" \
		--data-urlencode 'script=Download Script' \
		--data-urlencode 'home_path=/Users/zzsmoke' \
		--data-urlencode 'password=zzsmokepw' \
		"$OCM_URL/system-mac_download.php" >/dev/null

	if ! grep -qF '$url' "$BODY"
	then
		bad "the mac download did not return the generated script"
	elif ! grep -qiE '^content-type:[ ]*text/plain' "$MD_HDR"
	then
		bad "the generated mac download script is not served as text/plain"
	elif ! grep -qiE '^content-disposition:[ ]*attachment' "$MD_HDR"
	then
		bad "the generated mac download script is not served as an attachment"
	else
		ok "the generated mac download script is a text/plain attachment"
	fi

	if grep -qE "^\\\$url = 'https://" "$BODY"
	then
		ok "the generated mac download script posts to an https URL"
	else
		bad "the generated mac download script's URL is not https ($(grep -m1 -E '^\$url' "$BODY"))"
	fi
	rm -f "$MD_HDR"
fi

echo
echo "== 77. Two sql injection sinks in pikaCms =="

# pikaCms::fetchActivity() put $act_id into its WHERE clause exactly as it
# arrived, and dataops.php reaches it twice with the raw POST body: the
# 'act_id' field of the delete branch, and the array keys of the 'hours'
# field of the bulk-save branch. pl_clean_form_input() in its default mode
# takes out only < and >, so a quote in either closed the string early.
#
# pikaCms::fetchCaseList() interpolated its case_id filter unquoted, so that
# one did not even need a quote: "0 OR 1=1" returned the whole case table.
#
# Both columns are int(11), so both are cast now. The positive controls run
# first; without them a refusal proves only that the fixture is missing.
if [ "$HAVE_DB" = 1 ] && [ "$HAVE_COMPOSE" = 1 ]; then
	sm77_dex() { docker compose "${COMPOSE_ARGS[@]}" exec -T app "$@"; }

	SM77_ACT=9931
	SM77_OWN_CASE=0
	SM77_CASE=''
	# The row is deleted by its number, not by the id this run chose, so a run
	# that died between the insert and the checks does not leave a case behind
	# for the next one to borrow and never clean up.
	sm77_drop() {
		adb "DELETE FROM activities WHERE act_id = ${SM77_ACT}" >/dev/null
		adb "DELETE FROM cases WHERE number = 'ZZ-SQL-1'" >/dev/null
	}
	sm77_drop

	SM77_CASE="$(adb "SELECT case_id FROM cases ORDER BY case_id LIMIT 1")"
	SM77_CASE="$(printf '%s' "$SM77_CASE" | tr -d '[:space:]')"

	# 77c and 77d used to borrow whatever case the database happened to hold,
	# and to skip in silence when it held none. A suite that reports a
	# different number of checks depending on the data it finds cannot be read,
	# and the two checks that did not run were the ones covering the case list.
	# So make a case when there is none, and delete it again below.
	if [ -z "$SM77_CASE" ]; then
		SM77_CASE="$(adb "SELECT COALESCE(MAX(case_id), 0) + 1 FROM cases")"
		SM77_CASE="$(printf '%s' "$SM77_CASE" | tr -d '[:space:]')"
		SM77_OWN_CASE=1

		adb "INSERT INTO cases
			(case_id, number, client_id, user_id, office, open_date, status, problem)
			VALUES (${SM77_CASE:-0}, 'ZZ-SQL-1', 0, 1, 'ZZO', CURDATE(), 'O', '01')" \
			>/dev/null
	fi

	adb "INSERT INTO activities (act_id, case_id, user_id, act_type, act_date)
		VALUES (${SM77_ACT}, ${SM77_CASE:-0}, 1, 'C', '2026-01-01')" >/dev/null

	SM77_OUT="$(sm77_dex php -r '
		define("PL_DISABLE_SECURITY", true);
		chdir("/var/www/html/cms");
		require_once("pika-danio.php");
		pika_init();
		require_once("lib/pikaCms.php");
		$pk = new pikaCms();
		$r = $pk->fetchActivity($argv[1]);
		$w = $r ? DBResult::fetchRow($r) : null;
		echo "ACT_PLAIN:" . (is_array($w) ? $w["act_id"] : "NOROW") . "\n";
		$r = $pk->fetchActivity("0\x27 OR \x271\x27=\x271");
		$w = $r ? DBResult::fetchRow($r) : null;
		echo "ACT_INJECT:" . (is_array($w) ? $w["act_id"] : "NOROW") . "\n";
		$d = 0;
		$pk->fetchCaseList(array("case_id" => "0 OR 1=1"), $d);
		echo "CASE_INJECT:" . (int) $d . "\n";
		$d2 = 0;
		$pk->fetchCaseList(array("case_id" => $argv[2]), $d2);
		echo "CASE_PLAIN:" . (int) $d2 . "\n";
	' "$SM77_ACT" "${SM77_CASE:-0}" </dev/null 2>/dev/null)"

	sm77_drop

	sm77_says() { printf '%s' "$SM77_OUT" | grep -qF "$1"; }

	# 77a. Positive control: the lookup this function exists for still works.
	if sm77_says "ACT_PLAIN:${SM77_ACT}"; then
		ok "an activity is still fetched by its own id"
	else
		bad "THE ACTIVITY LOOKUP IS BROKEN - the rest of 77 proves nothing [$SM77_OUT]"
	fi

	# 77b. The injection itself.
	if sm77_says 'ACT_INJECT:NOROW'; then
		ok "a quote in an activity id no longer selects another row"
	else
		bad "an activity id can still break out of its quotes [$SM77_OUT]"
	fi

	if [ -z "$SM77_CASE" ]; then
		bad "77 HAD NO CASE TO LOOK UP, SO THE CASE LIST INJECTION CHECKS DID NOT RUN"
	else
		# 77c. Positive control for the case list.
		if sm77_says 'CASE_PLAIN:1'; then
			ok "a case is still found by its own id"
		else
			bad "THE CASE LOOKUP IS BROKEN - 77d proves nothing [$SM77_OUT]"
		fi

		# 77d. The unquoted filter returned the whole table.
		if sm77_says 'CASE_INJECT:0'; then
			ok "a case id filter of \"0 OR 1=1\" now matches nothing"
		else
			bad "the case list filter still takes its value as sql [$SM77_OUT]"
		fi
	fi
fi

# 77e. Static. The escape pass at the top of fetchCaseList() covers every
# other filter in the function, whose values were interpolated raw. It is
# the thing that makes the function safe for a caller it has not met.
if grep -qF 'DB::escapeString((string) $filter_value)' cms/app/extralib/lib/pikaCms.php; then
	ok "the case list escapes every filter it is handed"
else
	bad "the case list interpolates filter values unescaped again"
fi

# ---------------------------------------------------------------------------
# 78. Administrative pages carry their own gate, and no page answers a
#     request that has no session with content.
#
# pika_authorize($op, $row) is row-level: it answers questions about one
# case or one activity. Whether a whole PAGE is administrative is decided
# per file, by hand, at the top of that file. cms/system-extensions.php
# shipped without that decision -- it called pika_init() and then drew the
# extension manager for whoever asked. Its write handler,
# cms/ops/update_extensions.php, was already gated on the system flag, so
# nothing could be changed; but any logged-in user could read which custom
# extensions the site had installed and the folder each one lives in.
#
# A gate written out by hand in 19 files is a census that goes stale, so
# 78a and 78b assert the invariant rather than the one file: every
# cms/system-*.php has a refusal branch, and the flag it tests is the
# system flag or -- for the user manager, which is delegated separately --
# the users flag. 78c and 78d are the live pair: a user whose group holds
# no flags is refused, and the administrator is still served. 78e sweeps
# every page in cms/ and cms/m/ with no session at all, because a gate
# that only holds for a logged-in user is not a gate.
# ---------------------------------------------------------------------------

echo
echo "== 78. administrative pages carry their own gate =="

# 78a and 78b. The source census. No stack needed.
sm78_total=0
sm78_ungated=''
sm78_wrongflag=''
for sm78_f in cms/system-*.php
do
	sm78_total=$((sm78_total + 1))
	if ! grep -qF '!pika_authorize(' "$sm78_f"
	then
		sm78_ungated="${sm78_ungated} ${sm78_f}"
		continue
	fi
	# -F, and one -e per spelling: this pattern would need a backreference
	# to match the closing quote to the opening one, and ugrep rejects it.
	grep -qF \
		-e "pika_authorize('system'" -e 'pika_authorize("system"' \
		-e "pika_authorize('users'"  -e 'pika_authorize("users"' \
		"$sm78_f" || sm78_wrongflag="${sm78_wrongflag} ${sm78_f}"
done

# The positive control. An empty glob would satisfy every assertion below.
if [ "$sm78_total" -ge 19 ]
then
	ok "the administrative page census found $sm78_total system pages"
else
	bad "the administrative page census found only $sm78_total system pages, expected 19 or more"
fi

if [ -z "$sm78_ungated" ]
then
	ok "every system page has a pika_authorize() refusal branch"
else
	bad "system page(s) with no refusal branch:${sm78_ungated}"
fi

if [ -z "$sm78_wrongflag" ]
then
	ok "every system page gates on the system flag or the users flag"
else
	bad "system page(s) gating on neither flag:${sm78_wrongflag}"
fi

# 78c and 78d. The live pair. The hash comes out of the application's own
# PHP so it matches whatever password_hash() defaults to in this image.
if [ "$HAVE_DB" = 1 ] && [ "$HAVE_COMPOSE" = 1 ]
then
	SM78_GROUP=zz_sm78_grp
	SM78_USER=zz_sm78_user
	SM78_PASS='zz-Sm78-Passw0rd'
	SM78_JAR="$(mktemp)"

	sm78_cleanup() {
		adb "DELETE FROM users WHERE username = '${SM78_USER}'" >/dev/null
		adb "DELETE FROM \`groups\` WHERE group_id = '${SM78_GROUP}'" >/dev/null
		rm -f "$SM78_JAR"
	}
	sm78_cleanup

	# A group with nothing in it: no system flag, no users flag, no offices.
	adb "INSERT INTO \`groups\` (group_id, read_office, read_all, edit_office, edit_all, users, pba, motd, intake, reports)
		VALUES ('${SM78_GROUP}', NULL, 0, NULL, 0, 0, 0, 0, 0, NULL)" >/dev/null
	SM78_HASH="$(docker compose "${COMPOSE_ARGS[@]}" exec -T app \
		php -r 'echo password_hash($argv[1], PASSWORD_DEFAULT);' "$SM78_PASS" </dev/null 2>/dev/null)"
	SM78_UID="$(adb "SELECT COALESCE(MAX(user_id), 0) + 1 FROM users")"
	adb "INSERT INTO users (user_id, username, password, enabled, group_id, password_expire)
		VALUES (${SM78_UID}, '${SM78_USER}', '${SM78_HASH}', 1, '${SM78_GROUP}', 0)" >/dev/null

	if [ -z "$SM78_HASH" ] || [ -z "${SM78_UID:-}" ]
	then
		bad "could not seed the no-flag user for the administrative gate check"
	else
		curl -sL --max-time 30 -c "$SM78_JAR" -b "$SM78_JAR" -o "$BODY" \
			-X POST -d "login_user=${SM78_USER}&login_pass=${SM78_PASS}&auth_id=1" \
			"$OCM_URL/" >/dev/null

		if grep -q 'login_pass' "$BODY"
		then
			bad "the no-flag user could not log in, so the gate check proves nothing"
		else
			ok "the no-flag user has a session"

			# The refusal renders through the same template as the page, so
			# assert on the form the page draws, not only on the wording of
			# the refusal. A gate-less page serves the form; a gated one
			# must not, whatever it says instead.
			curl -s --max-time 30 -b "$SM78_JAR" -o "$BODY" \
				"$OCM_URL/system-extensions.php" >/dev/null
			if ! grep -qF 'ops/update_extensions.php' "$BODY"
			then
				ok "a user with no flags is not served the extension manager"
			else
				bad "a user with no flags was served the extension manager form"
			fi
		fi
		sm78_cleanup
	fi

	# The administrator still gets the page. Without this, a gate that
	# refused everybody would pass 78c.
	curl -s --max-time 30 -b "$COOKIES" -o "$BODY" \
		"$OCM_URL/system-extensions.php" >/dev/null
	if grep -qF 'ops/update_extensions.php' "$BODY"
	then
		ok "the administrator is still served the extension manager"
	else
		bad "the administrator can no longer reach the extension manager"
	fi
fi

# 78e. Nothing renders to a request with no session. cms/ops/ is left out
# on purpose: those files are write handlers, and a GET with no parameters
# reaches them as an error page, which says nothing about their gates.
# What counts as rendered: 200, a body big enough to be a page, no login
# form in it, and none of the application's refusal or error wording.
sm78_open=''
SM78_ANON="$(mktemp)"
for sm78_p in cms/*.php cms/m/*.php
do
	sm78_rel="${sm78_p#cms/}"
	# Libraries, not pages: index.php includes pika_cms.php, and every
	# page includes pika-danio.php.
	[ "$sm78_rel" = pika_cms.php ] && continue
	[ "$sm78_rel" = pika-danio.php ] && continue

	sm78_code="$(curl -s --max-time 30 -o "$SM78_ANON" -w '%{http_code}' \
		"$OCM_URL/${sm78_rel}")"
	[ "$sm78_code" = 200 ] || continue
	[ "$(wc -c <"$SM78_ANON" | tr -d ' ')" -gt 800 ] || continue
	grep -qF 'name="login_user"' "$SM78_ANON" && continue
	grep -q 'login_pass' "$SM78_ANON" && continue
	grep -qiE 'access denied|not authorized|permission denied' "$SM78_ANON" && continue
	grep -qiF 'This page is currently unavailable' "$SM78_ANON" && continue
	sm78_open="${sm78_open} ${sm78_rel}"
done
rm -f "$SM78_ANON"

if [ -z "$sm78_open" ]
then
	ok "no page in cms/ or cms/m/ renders to a request with no session"
else
	bad "page(s) rendering with no session:${sm78_open}"
fi

# 78f. Every page entry point must open without HTTP 500 or a missing-schema
# SQL error for a signed-in user. Other statuses are covered by the gate tests.
#
# m/logout.php ends the session it is handed, so it gets a throwaway session of
# its own and the main cookie jar is never sent to it. A second login for the
# same user does not disturb the first: only password.php and system-users.php
# call pl_user_sessions_invalidate_others(), and neither runs on a GET.
#
# Both sessions are checked before the sweep and the main one again after it,
# because a sweep that had quietly lost its session would still pass: every
# page would answer a redirect to the login form, and a redirect is not a 500.
# The page count is asserted for the same reason -- a glob that matched nothing
# would otherwise report success.
sm78_signed_in() {
	curl -sL --max-time 30 -b "$1" -o "$BODY" "$OCM_URL/" >/dev/null
	! grep -q 'login_pass' "$BODY" && grep -qi 'logout' "$BODY"
}

sm78_jar="$(mktemp)"
curl -sL --max-time 30 -c "$sm78_jar" -b "$sm78_jar" -o /dev/null \
	-X POST -d "login_user=${OCM_USER}&login_pass=${OCM_PASSWORD}&auth_id=1" \
	"$OCM_URL/"
if sm78_signed_in "$sm78_jar"; then
	ok "the sweep holds a throwaway session for the logout page"
else
	bad "the sweep cannot open a throwaway session, so its page checks would pass on login redirects alone"
fi
if sm78_signed_in "$COOKIES"; then
	ok "the sweep still holds the main session after a second login"
else
	bad "a second login ended the main session, so the page checks below would pass on login redirects alone"
fi

sm78_n=0
for sm78_p in cms/*.php cms/m/*.php; do
	[ -f "$sm78_p" ] || continue
	sm78_rel="${sm78_p#cms/}"
	[ "$sm78_rel" = pika_cms.php ] && continue
	[ "$sm78_rel" = pika-danio.php ] && continue

	case "$sm78_rel" in
		m/logout.php) sm78_use="$sm78_jar" ;;
		*)            sm78_use="$COOKIES" ;;
	esac

	sm78_n=$((sm78_n+1))
	code="$(curl -s --max-time 60 -b "$sm78_use" -o "$BODY" -w '%{http_code}' \
		"$OCM_URL/${sm78_rel}")"
	if [ "$code" = 500 ]; then
		bad "PAGE $sm78_rel RETURNED HTTP 500 ON A STOCK DATABASE"
	elif grep -qi "Unknown column\|Unknown table" "$BODY"; then
		bad "PAGE $sm78_rel LEAKED A MISSING-SCHEMA SQL ERROR TO THE PAGE"
	else
		ok "page $sm78_rel opens signed in (status $code)"
	fi
done
rm -f "$sm78_jar"

if [ "$sm78_n" -ge 60 ]; then
	ok "the signed-in sweep covered $sm78_n page entry points"
else
	bad "the signed-in sweep covered only $sm78_n page entry points"
fi
if sm78_signed_in "$COOKIES"; then
	ok "the main session survived the sweep"
else
	bad "the sweep ended the main session, so every page check above proved nothing"
fi

# 78g. The same sweep again, as a user whose group holds no permissions.
#
# 78f proves the pages do not crash for the admin, and the admin is in the
# `system` group, which short-circuits pika_authorize() to true on its first
# line -- so 78f cannot see an authorization failure at all. This section
# repeats the sweep as a throwaway user with every group flag off and adds the
# two checks that only mean something for such a user:
#
#   - No page may answer HTTP 200 with an empty body. A refusal that renders
#     nothing is a white screen, indistinguishable from a crash: system-ops.php
#     assembled its "Permission denied" page and then dropped it, because
#     pl_template() returns the page rather than printing it.
#   - The admin-console pages must show this user a refusal, and must not hand
#     back the bytes they hand the admin.
#
# Pages that gate on a case row (case.php, activity.php, transfer.php,
# documents.php) are deliberately absent from the must-refuse table below.
# Sections 9, 54 and 79 already gate those against a seeded case, which is a
# stronger check than a bare GET with no case_id.
#
# An empty body is only a fault when the admin gets a page there, so the one
# check that cannot be read off the response alone -- pl_report.php and
# sms_cron.php are not pages and are empty for everybody -- asks the admin the
# same question before it fails.
if [ "$HAVE_DB" = 1 ]; then
	SM78G_GROUP='zz_78g_grp'
	SM78G_USER='zz_78g_user'
	SM78G_PASS='zz-78g-Passw0rd'
	SM78G_JAR="$(mktemp)"
	SM78G_ADMIN="$(mktemp)"

	cleanup_78g() {
		# user_sessions holds a row per login and has no cascading foreign key on
		# user_id, so the login row outlives the user unless it goes first.
		adb "DELETE FROM user_sessions WHERE user_id IN
			(SELECT user_id FROM users WHERE username = '${SM78G_USER}')" >/dev/null
		adb "DELETE FROM users WHERE username = '${SM78G_USER}'" >/dev/null
		adb "DELETE FROM \`groups\` WHERE group_id = '${SM78G_GROUP}'" >/dev/null
		# A DELETE that failed has to be said out loud. Without this the run
		# reports a clean finish while its user and group are still there, and
		# the next run's counts are measured against a dirty database.
		sm78g_left="$(adb "SELECT COUNT(*) FROM users WHERE username = '${SM78G_USER}'")"
		sm78g_left="${sm78g_left}$(adb "SELECT COUNT(*) FROM \`groups\` WHERE group_id = '${SM78G_GROUP}'")"
		if [ "$sm78g_left" != 00 ]; then
			bad "the no-permission sweep could not remove its fixture (users and groups still present: ${sm78g_left})"
		fi
		rm -f "$SM78G_JAR" "$SM78G_ADMIN"
	}
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_78g' EXIT
	cleanup_78g

	adb "INSERT INTO \`groups\` (group_id, read_office, read_all, edit_office, edit_all, users, pba, motd, intake, reports)
		VALUES ('${SM78G_GROUP}', NULL, 0, NULL, 0, 0, 0, 0, 0, NULL)" >/dev/null
	SM78G_HASH="$(docker compose "${COMPOSE_ARGS[@]}" exec -T app \
		php -r 'echo password_hash($argv[1], PASSWORD_DEFAULT);' "$SM78G_PASS" </dev/null 2>/dev/null)"
	SM78G_UID="$(adb "SELECT COALESCE(MAX(user_id), 0) + 1 FROM users")"
	adb "INSERT INTO users (user_id, username, password, enabled, group_id, password_expire)
		VALUES (${SM78G_UID}, '${SM78G_USER}', '${SM78G_HASH}', 1, '${SM78G_GROUP}', 0)" >/dev/null

	curl -sL --max-time 30 -c "$SM78G_JAR" -b "$SM78G_JAR" -o "$BODY" \
		-X POST -d "login_user=${SM78G_USER}&login_pass=${SM78G_PASS}&auth_id=1" \
		"$OCM_URL/" >/dev/null
	if sm78_signed_in "$SM78G_JAR"; then
		ok "the no-permission sweep holds a session for ${SM78G_USER}"
	else
		bad "the no-permission sweep could not sign in, so its page checks would pass on login redirects alone"
	fi

	# The pages whose only gate is a group flag. Each must refuse this user.
	sm78g_must_refuse=" assign_atty.php assign_pba.php motd.php pb_attorneys.php
		system-audit.php system-case_numbers.php system-case_tabs.php
		system-default_prefs.php system-extensions.php system-forms.php
		system-groups.php system-interviews.php system-mac_download.php
		system-maint.php system-menus.php system-ops.php system-outcomes.php
		system-red_flags.php system-reset_counters.php system-screen.php
		system-settings.php system-sms.php system-users.php
		transfer_options.php transfers.php zipcode.php "
	# The table above is wrapped, so its entries are separated by newlines and
	# tabs. Word splitting collapses them to the single spaces the `case` glob
	# below matches on.
	# shellcheck disable=SC2086
	sm78g_must_refuse=" $(echo $sm78g_must_refuse) "

	sm78g_refused() {
		grep -qi 'Access denied\|Permission denied\|not viewable\|not authorized' "$1"
	}

	# The admin's copy of the same page is the baseline the refusal is measured
	# against, so it has to be a real response first. A request that fails
	# answers zero bytes, and a zero-byte baseline would make any refusal look
	# both different from the admin's and smaller than it.
	sm78g_admin_copy() {
		sm78g_admin_code="$(curl -s --max-time 60 -b "$COOKIES" -o "$SM78G_ADMIN" \
			-w '%{http_code}' "$OCM_URL/$1")"
		[ "$sm78g_admin_code" = 200 ] && [ -s "$SM78G_ADMIN" ]
	}

	# The only two entry points under cms/ that answer everybody with nothing:
	# pl_report.php is an include, and sms_cron.php is a cron script. The list is
	# spelled out rather than worked out from the admin's response, because a
	# real page that went blank for both users would otherwise be filed as a
	# non-page and pass.
	sm78g_not_pages=" pl_report.php sms_cron.php "

	sm78g_n=0
	sm78g_gated=0
	for sm78g_p in cms/*.php cms/m/*.php; do
		[ -f "$sm78g_p" ] || continue
		sm78g_rel="${sm78g_p#cms/}"
		[ "$sm78g_rel" = pika_cms.php ] && continue
		[ "$sm78g_rel" = pika-danio.php ] && continue
		[ "$sm78g_rel" = m/logout.php ] && continue

		sm78g_n=$((sm78g_n+1))
		code="$(curl -s --max-time 60 -b "$SM78G_JAR" -o "$BODY" -w '%{http_code}' \
			"$OCM_URL/${sm78g_rel}")"
		sm78g_bytes="$(wc -c < "$BODY")"

		if [ "$code" = 500 ]; then
			bad "PAGE $sm78g_rel RETURNED HTTP 500 FOR A USER WITH NO PERMISSIONS"
			continue
		fi
		if grep -qi "Unknown column\|Unknown table" "$BODY"; then
			bad "PAGE $sm78g_rel LEAKED A MISSING-SCHEMA SQL ERROR TO A USER WITH NO PERMISSIONS"
			continue
		fi
		if grep -qi 'Fatal error\|Uncaught ' "$BODY"; then
			bad "PAGE $sm78g_rel PRINTED A PHP FATAL ERROR FOR A USER WITH NO PERMISSIONS"
			continue
		fi
		if [ "$code" = 200 ] && [ "$sm78g_bytes" -eq 0 ]; then
			case "$sm78g_not_pages" in
				*" $sm78g_rel "*)
					ok "page $sm78g_rel is empty because it is not a page"
					;;
				*)
					bad "PAGE $sm78g_rel ANSWERED 200 WITH AN EMPTY BODY: A WHITE SCREEN INSTEAD OF A REFUSAL"
					;;
			esac
			continue
		fi

		case "$sm78g_must_refuse" in
			*" $sm78g_rel "*)
				sm78g_gated=$((sm78g_gated+1))
				# Three ways a refusal can be a lie, in order: the words are
				# missing; the response is the admin's page byte for byte; or the
				# page printed the refusal and then carried on into the content
				# anyway. Comparing lengths is not enough for the second one --
				# two different responses of the same length would read as
				# identical -- so the bodies are compared with cmp.
				#
				# The third is checked by shape, not by size. A refusal is the same
				# default.html shell as the page itself with a short message where
				# the content goes, and the shell carries one form and two inputs
				# (the nav search) and nothing else, while what these pages print
				# is data grids and pick lists. So a refusal that still contains a
				# table or a dropdown has printed content it refused to print.
				# This does not catch content made of nothing but text, and size
				# cannot be used instead: cms/system-ops.php answers the admin
				# 2109 bytes, which is smaller than its own refusal page.
				if ! sm78g_refused "$BODY"; then
					bad "PAGE $sm78g_rel GAVE A USER WITH NO PERMISSIONS ITS CONTENT INSTEAD OF A REFUSAL (status $code)"
				elif ! sm78g_admin_copy "$sm78g_rel"; then
					bad "page $sm78g_rel refused this user, but the admin answered $sm78g_admin_code, so the comparison proves nothing"
				elif cmp -s "$BODY" "$SM78G_ADMIN"; then
					bad "PAGE $sm78g_rel ANSWERED A USER WITH NO PERMISSIONS BYTE FOR BYTE AS IT ANSWERED THE ADMIN"
				elif grep -qi '<table\|<select' "$BODY"; then
					bad "PAGE $sm78g_rel PRINTED A REFUSAL AND A TABLE OR A DROPDOWN AS WELL, SO IT CARRIED ON PAST ITS OWN GATE"
				else
					ok "page $sm78g_rel refuses a user with no permissions (status $code)"
				fi
				;;
			*)
				ok "page $sm78g_rel opens for a user with no permissions without crashing (status $code)"
				;;
		esac
	done

	# The sweep walks cms/*.php and cms/m/*.php, so it never reaches the two
	# handlers under cms/ops/ that threw away the same refusal. Both are
	# CSRF-checked, so the POST needs a token cut from this session.
	sm78g_token="$(curl -sL --max-time 30 -b "$SM78G_JAR" "$OCM_URL/password.php" \
		| grep -oE 'name="_csrf" value="[0-9a-f]{64}"' \
		| head -1 | sed -e 's/.*value="//' -e 's/"$//')"
	if [ "${#sm78g_token}" -ne 64 ]; then
		bad "could not read a CSRF token for the no-permission user, so the two ops handlers are untested"
	else
		for sm78g_op in ops/save_settings.php ops/update_extensions.php; do
			code="$(curl -s --max-time 60 -b "$SM78G_JAR" -o "$BODY" -w '%{http_code}' \
				-d "_csrf=${sm78g_token}" "$OCM_URL/${sm78g_op}")"
			if grep -qi 'Fatal error\|Uncaught ' "$BODY"; then
				bad "$sm78g_op PRINTED A PHP FATAL ERROR FOR A USER WITH NO PERMISSIONS"
			elif [ ! -s "$BODY" ]; then
				bad "$sm78g_op REFUSED A USER WITH NO PERMISSIONS WITH AN EMPTY BODY (status $code)"
			elif sm78g_refused "$BODY"; then
				ok "$sm78g_op refuses a user with no permissions, and says so (status $code)"
			else
				bad "$sm78g_op ANSWERED A USER WITH NO PERMISSIONS SOMETHING OTHER THAN A REFUSAL (status $code)"
			fi
		done
	fi

	if [ "$sm78g_n" -ge 60 ]; then
		ok "the no-permission sweep covered $sm78g_n page entry points"
	else
		bad "the no-permission sweep covered only $sm78g_n page entry points"
	fi
	if [ "$sm78g_gated" -ge 26 ]; then
		ok "the no-permission sweep checked $sm78g_gated gated admin pages"
	else
		bad "the no-permission sweep checked only $sm78g_gated of the 26 gated admin pages -- did one get renamed?"
	fi
	if sm78_signed_in "$SM78G_JAR"; then
		ok "the no-permission session survived the sweep"
	else
		bad "the no-permission session ended during the sweep, so the refusals above prove nothing"
	fi
	if sm78_signed_in "$COOKIES"; then
		ok "the main session survived the no-permission sweep"
	else
		bad "the no-permission sweep ended the main session"
	fi

	cleanup_78g
	trap 'rm -f "$COOKIES" "$BODY"' EXIT
else
	printf '  skip the no-permission page sweep (needs a running docker compose stack)\n'
fi

# 79. The two case-transfer pages are gated.
#
# cms/transfer.php drew the "send this case to another organisation" form for
# whoever asked. It had no check of any kind: it took case_id from the query
# string, loaded the case, and printed the case number into the breadcrumb and
# into two value="" attributes, then listed every configured transfer
# destination. So a user whose group held no flags could read any case's number
# -- one request per id -- while cms/case.php answered the same id with 403.
# Its write handler, cms/ops/transfer_case.php, already required edit_case, so
# the page now applies the same predicate the handler does.
#
# cms/transfers.php is the other half: the holding tank for transfers sent TO
# this installation. It had no check either, so any logged-in user could list
# every pending referral -- client last name, first name, county, city and
# problem code -- open one, and press Accept or Reject. It is now the system
# group plus whichever group carries the intake flag, because accepting a
# transfer ends in a new case and a new contact and groups.intake already
# names the people who do that.
#
# 79a is the source census. 79b is the live pair, and it asserts the property
# that matters rather than the wording: the refusal transfer.php sends is
# byte-for-byte the refusal case.php sends, so the response cannot be used to
# tell a case that exists from one that does not.
# ---------------------------------------------------------------------------

echo
echo "== 79. the case-transfer pages are gated =="

# 79a. Source census. No stack needed.
sm79_files=0
for sm79_f in cms/transfer.php cms/transfers.php cms/app/lib/pl.php cms/case.php
do
	[ -f "$sm79_f" ] && sm79_files=$((sm79_files + 1))
done

if [ "$sm79_files" -eq 4 ]
then
	ok "all four case-transfer source files are present"
else
	bad "expected 4 case-transfer source files, found $sm79_files"
fi

# One -e per spelling: matching the closing quote to the opening one needs a
# backreference, and ugrep rejects those.
if grep -qF -e "pika_authorize('edit_case'" -e 'pika_authorize("edit_case"' cms/transfer.php
then
	ok "cms/transfer.php requires edit_case, the predicate its handler applies"
else
	bad "cms/transfer.php no longer requires edit_case"
fi

if grep -qF 'pl_case_not_viewable' cms/transfer.php
then
	ok "cms/transfer.php answers an unauthorized request with the shared refusal"
else
	bad "cms/transfer.php does not call pl_case_not_viewable()"
fi

# The refusal has to live in one place for the two pages to share it: a page
# cannot be included from another page, so it belongs in the library.
if grep -qF 'function pl_case_not_viewable' cms/app/lib/pl.php \
	&& ! grep -qF 'function pl_case_not_viewable' cms/case.php
then
	ok "pl_case_not_viewable() is defined once, in the library"
else
	bad "pl_case_not_viewable() is missing from the library or duplicated in cms/case.php"
fi

if grep -qF -e "pika_authorize('system'" -e 'pika_authorize("system"' cms/transfers.php \
	&& grep -qF -e "auth_row['intake']" -e 'auth_row["intake"]' cms/transfers.php
then
	ok "cms/transfers.php gates on the system group or the intake flag"
else
	bad "cms/transfers.php does not gate on the system group or the intake flag"
fi

# 79b. The live pair.
if [ "$HAVE_DB" = 1 ] && [ "$HAVE_COMPOSE" = 1 ]
then
	SM79_GROUP=zz_sm79_grp
	SM79_USER=zz_sm79_user
	SM79_PASS='zz-Sm79-Passw0rd'
	SM79_NUMBER='ZZ-SM79-CASE'
	SM79_JAR="$(mktemp)"
	SM79_A="$(mktemp)"
	SM79_B="$(mktemp)"

	sm79_cleanup() {
		adb "DELETE FROM users WHERE username = '${SM79_USER}'" >/dev/null
		adb "DELETE FROM \`groups\` WHERE group_id = '${SM79_GROUP}'" >/dev/null
		adb "DELETE FROM cases WHERE number = '${SM79_NUMBER}'" >/dev/null
	}
	sm79_cleanup

	# A group with nothing in it, so pika_authorize() has no reason to grant.
	adb "INSERT INTO \`groups\` (group_id, read_office, read_all, edit_office, edit_all, users, pba, motd, intake, reports)
		VALUES ('${SM79_GROUP}', NULL, 0, NULL, 0, 0, 0, 0, 0, NULL)" >/dev/null
	SM79_HASH="$(docker compose "${COMPOSE_ARGS[@]}" exec -T app \
		php -r 'echo password_hash($argv[1], PASSWORD_DEFAULT);' "$SM79_PASS" </dev/null 2>/dev/null)"
	SM79_UID="$(adb "SELECT COALESCE(MAX(user_id), 0) + 1 FROM users")"
	adb "INSERT INTO users (user_id, username, password, enabled, group_id, password_expire)
		VALUES (${SM79_UID}, '${SM79_USER}', '${SM79_HASH}', 1, '${SM79_GROUP}', 0)" >/dev/null

	# A case owned by somebody else, in an office this group cannot read.
	SM79_CASE="$(adb "SELECT COALESCE(MAX(case_id), 0) + 1 FROM cases")"
	adb "INSERT INTO cases (case_id, number, user_id, office)
		VALUES (${SM79_CASE}, '${SM79_NUMBER}', 1, 'HQ')" >/dev/null
	SM79_SEEDED="$(adb "SELECT number FROM cases WHERE case_id = ${SM79_CASE}")"

	if [ -z "$SM79_HASH" ] || [ -z "${SM79_UID:-}" ] || [ "$SM79_SEEDED" != "$SM79_NUMBER" ]
	then
		bad "could not seed the no-flag user and the unreadable case for the transfer gate check"
	else
		ok "seeded case ${SM79_NUMBER} and a group with no flags"

		curl -sL --max-time 30 -c "$SM79_JAR" -b "$SM79_JAR" -o "$BODY" \
			-X POST -d "login_user=${SM79_USER}&login_pass=${SM79_PASS}&auth_id=1" \
			"$OCM_URL/" >/dev/null

		if grep -q 'login_pass' "$BODY"
		then
			bad "the no-flag user could not log in, so the transfer gate check proves nothing"
		else
			ok "the no-flag user has a session"

			sm79_case_code="$(curl -s --max-time 30 -b "$SM79_JAR" -o "$SM79_A" \
				-w '%{http_code}' "$OCM_URL/case.php?case_id=${SM79_CASE}")"
			sm79_xfer_code="$(curl -s --max-time 30 -b "$SM79_JAR" -o "$SM79_B" \
				-w '%{http_code}' "$OCM_URL/transfer.php?case_id=${SM79_CASE}")"

			# The control: if case.php served the case, the group is not
			# actually unprivileged and nothing below means anything.
			if [ "$sm79_case_code" = 403 ]
			then
				ok "cms/case.php refuses the no-flag user this case"
			else
				bad "cms/case.php answered the no-flag user with HTTP $sm79_case_code, expected 403"
			fi

			if [ "$sm79_xfer_code" = 403 ]
			then
				ok "cms/transfer.php refuses the no-flag user the same case"
			else
				bad "cms/transfer.php answered the no-flag user with HTTP $sm79_xfer_code, expected 403"
			fi

			if ! grep -qF "$SM79_NUMBER" "$SM79_B"
			then
				ok "the refusal does not leak the case number"
			else
				bad "cms/transfer.php printed the case number to a user who may not read the case"
			fi

			# No oracle: the two pages must answer identically, or the
			# difference tells the caller which case ids are real.
			if cmp -s "$SM79_A" "$SM79_B"
			then
				ok "cms/transfer.php and cms/case.php send the same refusal byte for byte"
			else
				bad "cms/transfer.php and cms/case.php send different refusals, which is an oracle"
			fi

			sm79_tanks_code="$(curl -s --max-time 30 -b "$SM79_JAR" -o "$BODY" \
				-w '%{http_code}' "$OCM_URL/transfers.php")"
			if [ "$sm79_tanks_code" = 403 ]
			then
				ok "cms/transfers.php refuses a user with neither the system group nor the intake flag"
			else
				bad "cms/transfers.php answered a no-flag user with HTTP $sm79_tanks_code, expected 403"
			fi

			# The intake flag is the grant, so it has to actually grant.
			adb "UPDATE \`groups\` SET intake = 1 WHERE group_id = '${SM79_GROUP}'" >/dev/null
			sm79_intake_code="$(curl -s --max-time 30 -b "$SM79_JAR" -o "$BODY" \
				-w '%{http_code}' "$OCM_URL/transfers.php")"
			if [ "$sm79_intake_code" = 200 ]
			then
				ok "the intake flag opens cms/transfers.php"
			else
				bad "cms/transfers.php answered an intake user with HTTP $sm79_intake_code, expected 200"
			fi

			# ...and it must not open the outgoing page, which is a
			# case-level decision, not an intake one.
			sm79_intake_xfer="$(curl -s --max-time 30 -b "$SM79_JAR" -o "$BODY" \
				-w '%{http_code}' "$OCM_URL/transfer.php?case_id=${SM79_CASE}")"
			if [ "$sm79_intake_xfer" = 403 ]
			then
				ok "the intake flag does not open a case the user may not edit"
			else
				bad "cms/transfer.php answered an intake user with HTTP $sm79_intake_xfer, expected 403"
			fi
		fi
	fi

	# The administrator still gets both pages. Without this, a gate that
	# refused everybody would pass every check above.
	sm79_adm_xfer="$(curl -s --max-time 30 -b "$COOKIES" -o "$SM79_A" \
		-w '%{http_code}' "$OCM_URL/transfer.php?case_id=${SM79_CASE}")"
	if [ "$sm79_adm_xfer" = 200 ] && grep -qF "$SM79_NUMBER" "$SM79_A"
	then
		ok "the administrator still reaches cms/transfer.php for that case"
	else
		bad "the administrator got HTTP $sm79_adm_xfer from cms/transfer.php and no case number"
	fi

	sm79_adm_tanks="$(curl -s --max-time 30 -b "$COOKIES" -o "$BODY" \
		-w '%{http_code}' "$OCM_URL/transfers.php")"
	if [ "$sm79_adm_tanks" = 200 ]
	then
		ok "the administrator still reaches cms/transfers.php"
	else
		bad "the administrator got HTTP $sm79_adm_tanks from cms/transfers.php, expected 200"
	fi

	# A request with no case_id, and one naming a case that does not exist,
	# both get the same refusal -- the page must not answer either of them
	# with the form, and must not distinguish them.
	sm79_noid="$(curl -s --max-time 30 -b "$COOKIES" -o "$SM79_A" \
		-w '%{http_code}' "$OCM_URL/transfer.php")"
	sm79_absent="$(curl -s --max-time 30 -b "$COOKIES" -o "$SM79_B" \
		-w '%{http_code}' "$OCM_URL/transfer.php?case_id=2147483646")"
	if [ "$sm79_noid" = 403 ] && [ "$sm79_absent" = 403 ] && cmp -s "$SM79_A" "$SM79_B"
	then
		ok "cms/transfer.php answers a missing and an absent case_id identically"
	else
		bad "cms/transfer.php answered no case_id with HTTP $sm79_noid and an absent one with HTTP $sm79_absent"
	fi

	sm79_cleanup
	rm -f "$SM79_JAR" "$SM79_A" "$SM79_B"
fi

# ---------------------------------------------------------------------------
# 80. The custom semgrep ruleset exists, is wired into CI, and is tested.
#
# No scanner on this repository could see a SQL injection or an XSS in the PHP
# until .semgrep/ocm-sinks.yml existed. A stock PHP ruleset looks for
# mysqli_query() and echo; this application calls neither. SQL goes through
# DB::query(), which escapes nothing, and page output goes through the template
# layer. CodeQL cannot help at all -- it has no PHP analyzer -- so every scan
# reported a clean codebase no matter what was in it.
#
# A ruleset that has silently stopped matching is worse than no ruleset,
# because it reports success. So the rules carry their own annotated positive
# and negative cases in .semgrep/ocm-sinks.php, and the workflow runs those
# tests BEFORE it scans the application.
#
# This section is the source census for all of that. It cannot run semgrep --
# that is the workflow's job -- but it can assert the parts are present and in
# step with each other: every rule has a test case, every test case names a
# real rule, every sink this application actually has is named, and the
# workflow still fails the build on a finding rather than only reporting one.
# ---------------------------------------------------------------------------

echo
echo "== 80. the custom semgrep ruleset is present and tested =="

sm80_yml='.semgrep/ocm-sinks.yml'
sm80_php='.semgrep/ocm-sinks.php'
sm80_wf='.github/workflows/semgrep.yml'

# 80a. The three files.
sm80_files=0
for sm80_f in "$sm80_yml" "$sm80_php" "$sm80_wf"
do
	[ -f "$sm80_f" ] && sm80_files=$((sm80_files + 1))
done

if [ "$sm80_files" -eq 3 ]
then
	ok "ruleset, its test fixture and its workflow are all present"
else
	bad "expected 3 semgrep files, found $sm80_files"
fi

if [ -f "$sm80_yml" ] && [ -f "$sm80_php" ] && [ -f "$sm80_wf" ]
then
	# 80b. Every rule in the ruleset has a positive test case in the fixture,
	# and every rule id the fixture names is a rule that exists. The
	# annotations are semgrep's own; they are assembled here rather than
	# written out so that a scan of this tree does not read them as its own.
	sm80_rid="rule""id:"
	sm80_neg="o""k:"
	sm80_ids="$(grep -oE '^  - id: [A-Za-z0-9-]+$' "$sm80_yml" | sed 's/^  - id: //' | sort -u)"
	sm80_n_ids="$(printf '%s\n' "$sm80_ids" | grep -c .)"

	if [ "$sm80_n_ids" -ge 6 ]
	then
		ok "ruleset declares $sm80_n_ids rules"
	else
		bad "ruleset declares $sm80_n_ids rules, expected at least 6"
	fi

	sm80_untested=''
	sm80_unnegated=''

	for sm80_id in $sm80_ids
	do
		grep -qF -e "$sm80_rid $sm80_id" "$sm80_php" \
			|| sm80_untested="$sm80_untested $sm80_id"
		grep -qF -e "$sm80_neg $sm80_id" "$sm80_php" \
			|| sm80_unnegated="$sm80_unnegated $sm80_id"
	done

	if [ -z "$sm80_untested" ]
	then
		ok "every rule has a positive test case in the fixture"
	else
		bad "rules with no positive test case:$sm80_untested"
	fi

	# The negative cases are what stop a rule being widened until it flags
	# every query in the tree and gets switched off. A rule with only
	# positive cases can be made to match anything and still pass.
	if [ -z "$sm80_unnegated" ]
	then
		ok "every rule has a negative test case in the fixture"
	else
		bad "rules with no negative test case:$sm80_unnegated"
	fi

	sm80_orphans=''

	for sm80_ann in $(grep -oE "(rule|o)(id|k): [A-Za-z0-9-]+" "$sm80_php" \
		| sed 's/^[A-Za-z]*: //' | sort -u)
	do
		printf '%s\n' "$sm80_ids" | grep -qxF -e "$sm80_ann" \
			|| sm80_orphans="$sm80_orphans $sm80_ann"
	done

	if [ -z "$sm80_orphans" ]
	then
		ok "every rule id the fixture names is a rule that exists"
	else
		bad "fixture names rules that do not exist:$sm80_orphans"
	fi

	# 80c. The sinks this application actually has. Each of these names is the
	# reason the ruleset exists: a stock ruleset knows none of them, so if one
	# is dropped from the ruleset the scan goes quiet about a whole class of
	# defect while still reporting success.
	sm80_missing=''

	for sm80_sink in 'DB::query' 'pl_query' 'addHtmlRow' 'pl_template_sub' \
		'unserialize' 'header'
	do
		grep -qF -e "$sm80_sink" "$sm80_yml" \
			|| sm80_missing="$sm80_missing $sm80_sink"
	done

	if [ -z "$sm80_missing" ]
	then
		ok "all six application sinks are named in the ruleset"
	else
		bad "sinks missing from the ruleset:$sm80_missing"
	fi

	# The sanitisers are the other half. DB::escapeString() is deliberately
	# NOT enough on its own in this application -- it does nothing in an
	# unquoted slot -- which is why pl_safe_identifier(),
	# pl_safe_sort_direction(), pl_safe_comparison_operator() and
	# pl_process_comma_vals() have to be known to the rules as well, or every
	# report that uses them correctly is reported as a defect and the ruleset
	# gets turned off.
	sm80_missing_san=''

	for sm80_san in 'pl_safe_identifier' 'pl_safe_sort_direction' \
		'pl_safe_comparison_operator' 'pl_process_comma_vals' \
		'pl_clean_html_array' 'pl_html_escape'
	do
		grep -qF -e "$sm80_san" "$sm80_yml" \
			|| sm80_missing_san="$sm80_missing_san $sm80_san"
	done

	if [ -z "$sm80_missing_san" ]
	then
		ok "all six application sanitisers are named in the ruleset"
	else
		bad "sanitisers missing from the ruleset:$sm80_missing_san"
	fi

	# 80d. Those sanitisers have to exist in the application too. A rule that
	# names a helper nobody defines silently stops clearing taint the day the
	# helper is renamed, and the scan fills with findings on correct code.
	sm80_missing_fn=''

	for sm80_fn in 'pl_safe_identifier' 'pl_safe_sort_direction' \
		'pl_safe_order_by' 'pl_safe_comparison_operator' \
		'pl_process_comma_vals' 'pl_clean_html_array'
	do
		grep -qrF -e "function $sm80_fn(" cms/app/lib/pl.php \
			|| sm80_missing_fn="$sm80_missing_fn $sm80_fn"
	done

	if [ -z "$sm80_missing_fn" ]
	then
		ok "every sanitiser the ruleset names is defined in pl.php"
	else
		bad "sanitisers named by the ruleset but not defined:$sm80_missing_fn"
	fi

	# 80e. The workflow. The tests must run, the scan must cover both
	# application trees, and a finding must fail the build -- a workflow that
	# only uploads SARIF is a workflow nobody reads.
	if grep -qF -e '--test' "$sm80_wf"
	then
		ok "the workflow runs the ruleset's own tests"
	else
		bad "the workflow does not run the ruleset's own tests"
	fi

	if grep -qF -e 'cms cms-custom' "$sm80_wf"
	then
		ok "the workflow scans both cms and cms-custom"
	else
		bad "the workflow does not scan both application trees"
	fi

	if grep -qF -e 'exit 1' "$sm80_wf"
	then
		ok "the workflow fails the build on a finding"
	else
		bad "the workflow does not fail the build on a finding"
	fi

	# The scan has to be single-threaded. This is not a performance
	# setting. semgrep OSS 1.176.1 shards the target files across worker
	# processes and on this repository that loses findings: the same
	# commit, the same ruleset and the same 313 targets report two
	# findings with -j 1 and none in parallel. Nothing is reported as
	# skipped or timed out and the summary says the scan completed
	# successfully either way, so the failure mode of dropping this flag
	# is a gate that passes everything and tells nobody.
	#
	# Two real SQL injections in the report pages were invisible locally
	# for exactly this reason and only appeared on a runner with fewer
	# cores.
	if grep -qE -e 'semgrep scan[^#]*[[:space:]]-j[[:space:]]+1([[:space:]]|\\|$)' "$sm80_wf"
	then
		ok "the workflow scan is single-threaded (-j 1)"
	else
		bad "the workflow scan is not pinned to -j 1: a parallel semgrep scan silently drops findings"
	fi

	# And the image has to be pinned. On a floating tag this gate changes
	# behaviour when semgrep releases rather than when this repository
	# changes, and a security gate that goes red on its own gets ignored.
	if grep -qE -e 'image:[[:space:]]*semgrep/semgrep:[0-9]+\.[0-9]+\.[0-9]+' "$sm80_wf"
	then
		ok "the workflow pins an exact semgrep image version"
	else
		bad "the workflow does not pin an exact semgrep version"
	fi

	# 80f. CodeQL must not claim to cover the PHP. It cannot: there is no PHP
	# analyzer. A language list that named php would have made every one of
	# these rules look redundant.
	if [ -f .github/workflows/codeql.yml ]
	then
		if grep -qF -e "'php'" .github/workflows/codeql.yml
		then
			bad "codeql.yml claims a php analyzer, which does not exist"
		else
			ok "codeql.yml does not claim to analyse php"
		fi
	fi

	# 80g. The fixture is deliberately vulnerable, so Snyk Code reads it as
	# application source and reports the planted SQL injection and file
	# inclusion. The .snyk policy excludes the directory. Without that
	# exclusion the tempting fix is to make the fixture safe, which would
	# leave the ruleset with nothing to test against.
	if [ -f .snyk ]
	then
		if grep -qE -e '^[[:space:]]+- \.semgrep/' .snyk
		then
			ok ".snyk excludes the scanner fixture directory"
		else
			bad ".snyk does not exclude .semgrep/ - Snyk Code will report the planted vulnerabilities as real"
		fi
	else
		bad ".snyk is missing - Snyk Code will report the planted vulnerabilities in the semgrep fixture as real"
	fi
fi

# ---------------------------------------------------------------------------
# 81. plFlexList builds its own pager urls, and the sort column it puts in them
# comes straight from ?order_field=.
#
# pl_grab_get() turns < and > into entities but leaves the double quote alone,
# so a value holding one closed the href attribute and everything after it was
# read as further attributes of the <a> tag. An event handler needs no angle
# bracket, so the existing filter never saw it. The SQL side of the same value
# was fixed earlier -- pl_safe_order_by() guards the ORDER BY -- which is why
# this one survived: the query was safe and the link was not.
#
# The check needs a pager on the screen, and a pager only appears when the list
# holds more rows than one page. So the section does two things and undoes both
# afterwards: it drops the acting user's page size to 1, and it adds two cases
# of its own. The page size is read from users.session_data on every request,
# not from the session, so it has to be changed in the database to be seen. The
# cases are added rather than assumed because a freshly installed stack holds
# fewer cases than one page, and on one of those the section would otherwise
# skip itself and guard nothing.
#
# Both halves are asserted: no break-out, AND the value present in the url in
# percent-encoded form. Without the second assertion the section would pass on
# any page that simply never rendered a pager.
# ---------------------------------------------------------------------------

echo
echo "== 81. the flex list pager escapes the sort column it was handed =="

if [ "${HAVE_DB:-0}" != 1 ] || [ "${HAVE_COMPOSE:-0}" != 1 ]
then
	printf '  skip section 81 (needs the database and a compose stack)\n'
else
	fx_uid="$(adb "SELECT user_id FROM users WHERE username='${OCM_USER}' LIMIT 1")"
	fx_sd="$(adb "SELECT HEX(session_data) FROM users WHERE user_id=${fx_uid}")"
	case "$fx_sd" in
		''|NULL) fx_sd='' ;;
	esac

	# Rewrite one key of the serialised preference array and hand back the
	# result as hex, so nothing that came out of the database has to survive
	# a trip through the shell.
	fx_paging_hex() {
		docker compose "${COMPOSE_ARGS[@]}" exec -T app php -r '
			$raw = $argv[1] === "" ? "" : hex2bin($argv[1]);
			$a = @unserialize($raw);
			if (!is_array($a)) { $a = array(); }
			$a["paging"] = $argv[2];
			echo bin2hex(serialize($a));
		' "$1" "$2" </dev/null | tr -d '\r\n'
	}

	fx_restore() {
		# Only the two rows this section inserted, addressed by the ids it
		# chose, so nothing that was already in the table can be caught.
		if [ -n "${fx_c1:-}" ]
		then
			adb "DELETE FROM cases WHERE case_id IN (${fx_c1}, ${fx_c2})" >/dev/null
		fi
		if [ -z "$fx_sd" ]
		then
			adb "UPDATE users SET session_data=NULL WHERE user_id=${fx_uid}" >/dev/null
		else
			adb "UPDATE users SET session_data=UNHEX('${fx_sd}') WHERE user_id=${fx_uid}" >/dev/null
		fi
	}

	fx_small="$(fx_paging_hex "$fx_sd" 1)"
	if [ -z "$fx_small" ] || [ -z "$fx_uid" ]
	then
		printf '  skip section 81 (could not rewrite the page size)\n'
	else
		adb "UPDATE users SET session_data=UNHEX('${fx_small}') WHERE user_id=${fx_uid}" >/dev/null

		# Two cases of this section's own, above whatever ids are in use, so
		# the list is longer than the one row a page now holds. cases.case_id
		# is a plain int primary key and not auto-increment, so the id has to
		# be supplied here; leaving it out gives both rows id 0 and the second
		# one is silently dropped.
		fx_max="$(adb "SELECT COALESCE(MAX(case_id),0) FROM cases")"
		case "$fx_max" in
			''|*[!0-9]*) fx_max='' ;;
		esac
		if [ -n "$fx_max" ]
		then
			fx_c1=$((fx_max + 1))
			fx_c2=$((fx_max + 2))
			adb "INSERT INTO cases (case_id, number, user_id, office, status)
			VALUES (${fx_c1}, 'ZZ-FLEX-1', ${fx_uid}, NULL, '1'),
			(${fx_c2}, 'ZZ-FLEX-2', ${fx_uid}, NULL, '1')" >/dev/null
			fx_seeded="$(adb "SELECT COUNT(*) FROM cases WHERE case_id IN (${fx_c1}, ${fx_c2})")"
		else
			fx_seeded=0
		fi

		# The probe. A double quote, then an event handler, in the sort column.
		curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" \
			"$OCM_URL/case_list.php?order_field=open_date%22%20onmouseover%3D%22zzFLEXXSS()&order=DESC" >/dev/null

		if grep -qF 'offset=' "$BODY"
		then
			if grep -qF 'onmouseover="zzFLEXXSS()' "$BODY"
			then
				bad "ORDER_FIELD BREAKS OUT OF THE PAGER HREF ON case_list.php"
			else
				ok "a quote in order_field does not break out of the pager href"
			fi

			# The pass above is only worth something if the value reached the url.
			if grep -qF 'order_field=open_date%22%20onmouseover%3D%22zzFLEXXSS' "$BODY"
			then
				ok "the pager url carries the sort column percent-encoded"
			else
				bad "the sort column is not percent-encoded in the pager url - it was left raw, or it never reached one"
			fi

			# And the ordinary case still has to work: a real column name goes
			# into the pager unchanged, so no sort link moved.
			curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" \
				"$OCM_URL/case_list.php?order_field=open_date&order=DESC" >/dev/null
			if grep -qF 'order_field=open_date&order=DESC&offset=' "$BODY"
			then
				ok "a plain column name still passes through the pager unchanged"
			else
				bad "the pager no longer carries a plain column name"
			fi
		elif [ "${fx_seeded:-0}" = 2 ]
		then
			# The rows are in the table and the page holds one row, so a pager
			# is owed. Skipping here would let the section pass on a page that
			# never exercised the code it is meant to guard.
			bad "no pager on case_list.php with 2 extra cases and a page size of 1"
		else
			printf '  skip section 81 (could not add the cases a pager needs)\n'
		fi

		fx_restore
	fi
fi

# ---------------------------------------------------------------------------
# 82. pl_table_autosql_update() escapes the primary key it puts in the WHERE
# clause.
#
# The builder escapes every column it writes into the SET list, but the key
# column is deliberately left out of that list, so its value used to reach
# "WHERE <key>='<value>'" exactly as the request supplied it. pl_grab_vars()
# reads the key out of the request and filters it in 'primary_key' mode, and
# that mode turns < and > into entities and nothing else, so both quote
# characters arrive intact.
#
# The authorization gate in dataops.php does not stop this. It looks the case
# up with a prepared statement, but cases.case_id is an int column, and MariaDB
# coerces the whole injected string to the integer it starts with. So the gate
# sees only the case the caller is allowed to edit while the UPDATE underneath
# writes somewhere else.
#
# Two assertions, because they fail in opposite directions. The victim case
# must not change -- that is the vulnerability. The caller's own case must
# change -- without that a request rejected outright, for any unrelated reason,
# would look like a pass.
# ---------------------------------------------------------------------------

echo
echo "== 82. the update builder escapes the primary key in its where clause =="

# 82a. The typo that kept this path from being reachable through the group
# editor at all. pl_build_sql() takes the table name straight through to
# DESCRIBE, so a stray character means every group save silently DESCRIBEs a
# table that does not exist and writes nothing.
if [ -f cms/app/extralib/lib/pikaCms.php ]
then
	if grep -qF -e "pl_build_sql('UPDATE', '\`groups\`', \$a)" cms/app/extralib/lib/pikaCms.php
	then
		ok "updateGroup() names the groups table the same way addGroup() does"
	else
		bad "updateGroup() does not pass a clean groups table name to pl_build_sql()"
	fi
fi

if [ "${HAVE_DB:-0}" != 1 ] || [ "${HAVE_COMPOSE:-0}" != 1 ]
then
	printf '  skip section 82 (needs the database and a compose stack)\n'
else
	pk_uid="$(adb "SELECT user_id FROM users WHERE username='${OCM_USER}' LIMIT 1")"
	case "$pk_uid" in
		''|*[!0-9]*) pk_uid='' ;;
	esac

	pk_restore() {
		# Only the two rows this section inserted, addressed by the ids it
		# chose, so nothing that was already in the table can be caught.
		if [ -n "${pk_c1:-}" ]
		then
			adb "DELETE FROM cases WHERE case_id IN (${pk_c1}, ${pk_c2})" >/dev/null
		fi
	}

	if [ -z "$pk_uid" ]
	then
		printf '  skip section 82 (could not find the acting user)\n'
	else
		# Two cases of this section's own, above whatever ids are in use.
		# cases.case_id is a plain int primary key and not auto-increment, so
		# the id has to be supplied; leaving it out gives both rows id 0 and
		# the second one is silently dropped.
		pk_max="$(adb "SELECT COALESCE(MAX(case_id),0) FROM cases")"
		case "$pk_max" in
			''|*[!0-9]*) pk_max='' ;;
		esac

		if [ -z "$pk_max" ]
		then
			printf '  skip section 82 (could not read the case ids in use)\n'
		else
			pk_c1=$((pk_max + 1))
			pk_c2=$((pk_max + 2))
			adb "INSERT INTO cases (case_id, number, user_id, office, status)
			VALUES (${pk_c1}, 'ZZ-PK-MINE', ${pk_uid}, 'AA', '1'),
			(${pk_c2}, 'ZZ-PK-OTHER', ${pk_uid}, 'BB', '1')" >/dev/null
			pk_seeded="$(adb "SELECT COUNT(*) FROM cases WHERE case_id IN (${pk_c1}, ${pk_c2})")"

			# Fetch a token of this session's own rather than reusing one from
			# an earlier section, which the re-auth checks may have rotated.
			curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" \
				"$OCM_URL/system-maint.php" >/dev/null
			pk_tok="$(grep -oE 'name="_csrf" value="[0-9a-f]{64}"' "$BODY" \
				| head -1 | sed -E 's/.*value="([0-9a-f]*)".*/\1/')"

			if [ "${pk_seeded:-0}" != 2 ] || [ "${#pk_tok}" -ne 64 ]
			then
				printf '  skip section 82 (could not set up the two cases and a token)\n'
			else
				# Closes the quote, names the second case, then comments out
				# the LIMIT 1 the builder appends so both rows are in range.
				# The value still starts with the id the caller may edit, so
				# the authorization gate above it is satisfied.
				pk_payload="${pk_c1}' OR case_id='${pk_c2}' ORDER BY case_id DESC #"

				curl -s --max-time 30 -b "$COOKIES" -o "$BODY" \
					--data-urlencode "action=update_case" \
					--data-urlencode "_csrf=${pk_tok}" \
					--data-urlencode "case_id=${pk_payload}" \
					--data-urlencode "office=ZZ" \
					"$OCM_URL/dataops.php" >/dev/null

				pk_mine="$(adb "SELECT office FROM cases WHERE case_id=${pk_c1}")"
				pk_other="$(adb "SELECT office FROM cases WHERE case_id=${pk_c2}")"

				if [ "$pk_other" = 'ZZ' ]
				then
					bad "a case_id carrying a quote wrote a second case the request never named"
				else
					ok "a case_id carrying a quote does not reach a second case"
				fi

				# The request has to have done its ordinary work, otherwise
				# the check above passes on any request that failed early.
				if [ "$pk_mine" = 'ZZ' ]
				then
					ok "the same request still updated the case it was allowed to update"
				else
					bad "update_case wrote nothing at all (office is '${pk_mine}') - section 82 proved nothing"
				fi
			fi
		fi

		pk_restore
	fi
fi

# ----------------------------------------------------------------------------
echo
echo "== 83. pikaCms.php does not paste request values into its statements =="

# 83. pikaCms.php builds most of its statements as raw strings, and a long tail
# of them still pasted request values in unescaped. Two of those were also
# broken outright: fetchConflicts() looped with each(), removed in PHP 8, and
# deleteActivity() pasted its id in unquoted.
#
# The two static checks below name the broken pair. The live check that follows
# is the one that matters for the rest: the sweep added escapeString() and int
# casts to about forty statements, and the way that goes wrong is not an
# injection but an ordinary query that quietly stops matching. So seed two
# activities on two different days and ask the day calendar for one of them.

if [ -f cms/app/extralib/lib/pikaCms.php ]
then
	if grep -qF -e 'each($contact_ids)' cms/app/extralib/lib/pikaCms.php
	then
		bad "fetchConflicts() still calls each(), which is a fatal error on PHP 8"
	else
		ok "fetchConflicts() no longer calls each()"
	fi

	if grep -qF -e 'WHERE act_id=$act_id LIMIT 1' cms/app/extralib/lib/pikaCms.php
	then
		bad "deleteActivity() still pastes act_id into the statement unquoted"
	else
		ok "deleteActivity() does not paste act_id into the statement unquoted"
	fi
fi

if [ "${HAVE_DB:-0}" != 1 ] || [ "${HAVE_COMPOSE:-0}" != 1 ]
then
	printf '  skip section 83 (needs the database and a compose stack)\n'
else
	ak_uid="$(adb "SELECT user_id FROM users WHERE username='${OCM_USER}' LIMIT 1")"
	case "$ak_uid" in
		''|*[!0-9]*) ak_uid='' ;;
	esac

	# Fixed dates, not today's. The application runs on America/New_York and
	# this script does not, so a fixture dated from the shell is a different
	# day from the one the page defaults to for part of every evening.
	ak_day='2031-03-04'
	ak_next='2031-03-05'

	ak_restore() {
		# Only this section's own ids.
		adb "DELETE FROM activities WHERE act_id IN (929301, 929302)" >/dev/null
		if [ -n "${ak_case:-}" ]
		then
			adb "DELETE FROM cases WHERE case_id=${ak_case}" >/dev/null
		fi
	}

	if [ -z "$ak_uid" ]
	then
		printf '  skip section 83 (could not find the acting user)\n'
	else
		ak_max="$(adb "SELECT COALESCE(MAX(case_id),0) FROM cases")"
		case "$ak_max" in
			''|*[!0-9]*) ak_max='' ;;
		esac

		if [ -z "$ak_max" ]
		then
			printf '  skip section 83 (could not read the case ids in use)\n'
		else
			ak_case=$((ak_max + 1))
			adb "INSERT INTO cases (case_id, number, user_id, office, status)
			VALUES (${ak_case}, 'ZZ-AK-CASE', ${ak_uid}, 'AA', '1')" >/dev/null

			# act_time stays NULL: the page passes a time only when the day
			# asked for is today, and these two days are not.
			adb "DELETE FROM activities WHERE act_id IN (929301, 929302)" >/dev/null
			adb "INSERT INTO activities (act_id, user_id, case_id, act_date, completed, summary)
			VALUES (929301, ${ak_uid}, ${ak_case}, '${ak_day}', 0, 'ZZAKWANTED'),
			(929302, ${ak_uid}, ${ak_case}, '${ak_next}', 0, 'ZZAKOTHERDAY')" >/dev/null

			ak_seeded="$(adb "SELECT COUNT(*) FROM activities WHERE act_id IN (929301, 929302)")"

			if [ "${ak_seeded:-0}" != 2 ]
			then
				printf '  skip section 83 (could not seed the two activities)\n'
			else
				curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" \
					"$OCM_URL/cal_day.php?cal_date=${ak_day}" >/dev/null

				if grep -qF -e 'ZZAKWANTED' "$BODY"
				then
					ok "the day calendar still lists the activity seeded for that day"
				else
					bad "the day calendar lost the activity seeded for ${ak_day} - a pikaCms.php filter stopped matching"
				fi

				if grep -qF -e 'ZZAKOTHERDAY' "$BODY"
				then
					bad "the day calendar for ${ak_day} also listed an activity dated ${ak_next}"
				else
					ok "the day calendar for one day does not list another day's activity"
				fi
			fi
		fi

		ak_restore
	fi
fi


echo
echo "== 84. pl_menu_get() only accepts a bare identifier for a menu name =="

# 84. pl_menu_get() pastes the menu name into "FROM menu_<name>" and pastes
# the key, value and order columns into the select list. A menu name reaches
# it from a template lookup tag, and pl_template_sub() re-parses the values it
# has already substituted, so a request value can end up naming a menu.
#
# Nothing was exploitable, but only by accident: a SHOW TABLES loop ran first
# and required an exact match, so an injected name matched no table. That is a
# mitigation nobody wrote on purpose and nobody would think to keep. The
# deliberate one is an allowlist on the name plus backtick-quoted identifiers,
# and the checks below hold both in place.

if [ -f cms/app/lib/pl.php ]
then
	if grep -qF -e 'preg_match('\''/^[A-Za-z0-9_]+\z/'\'', $menu_name)' cms/app/lib/pl.php
	then
		ok "pl_menu_get() holds the menu name to a bare identifier"
	else
		bad "pl_menu_get() no longer checks the menu name - the table name is pasted into the statement"
	fi

	if grep -qF -e 'SELECT $key, $val FROM $menu_table_name' cms/app/lib/pl.php
	then
		bad "pl_menu_get() still builds its select list and FROM clause out of unquoted identifiers"
	else
		ok "pl_menu_get() quotes the identifiers it builds its statement from"
	fi
fi

if [ -f cms/dataops.php ]
then
	# The legacy md5 branch stays, because dropping it locks every account
	# whose password predates password_hash() out of its own change-password
	# form. It should at least compare in constant time, as the other three
	# legacy comparisons in the tree already do.
	if grep -qF -e 'hash_equals($stored_hash, md5($old_pass_in))' cms/dataops.php
	then
		ok "the change-password handler compares the legacy hash in constant time"
	else
		bad "the change-password handler compares the legacy md5 hash with a plain !=="
	fi
fi

if [ "${HAVE_DB:-0}" != 1 ] || [ "${HAVE_COMPOSE:-0}" != 1 ]
then
	printf '  skip section 84 database and page checks (needs the database and a compose stack)\n'
else
	# An allowlist is only safe if it covers every name the installer and the
	# menu editor actually create. If a menu table ever picks up a character
	# the pattern refuses, that menu stops loading and the page it feeds goes
	# quietly empty, so fail here rather than there.
	mg_bad="$(adb "SHOW TABLES LIKE 'menu\_%'" | grep -cvE '^menu_[A-Za-z0-9_]+$' || true)"
	mg_all="$(adb "SHOW TABLES LIKE 'menu\_%'" | grep -cE '^menu_' || true)"

	if [ "${mg_all:-0}" -lt 1 ]
	then
		printf '  skip the menu name survey (no menu_ tables on this stack)\n'
	elif [ "${mg_bad:-0}" -ne 0 ]
	then
		bad "${mg_bad} menu table(s) have names pl_menu_get() now refuses - those menus will load empty"
	else
		ok "all ${mg_all} menu tables have names the allowlist accepts"
	fi

	# Positive control. cal_adv.php draws its selects from lookup tags, so it
	# only has options at all if pl_menu_get() still returns rows.
	curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" "$OCM_URL/cal_adv.php"

	if grep -qF -e 'value="1">Yes' "$BODY" && grep -qF -e 'value="0">No' "$BODY"
	then
		ok "the advanced calendar still renders the yes_no menu through pl_menu_get()"
	else
		bad "the advanced calendar lost its yes_no options - pl_menu_get() is refusing a real menu name"
	fi
fi

echo "== 85. a saved preference outlives the session it was saved in =="

# 85. Both preference handlers -- cms/ops/update_prefs.php and the
# save_prefs branch of cms/dataops.php -- used to write the accepted values
# to $_SESSION and nowhere else. users.session_data was never touched, and
# pikaDefPrefs::initPrefs() reads that column back on the next login, so
# every saved preference was silently discarded at logout.
#
# The static checks below hold the shared writer in place. The round trip
# after them is the one that would have caught the original bug.

if [ -f cms/ops/update_prefs.php ] && [ -f cms/dataops.php ]
then
	up_bad=0
	for pf in cms/ops/update_prefs.php cms/dataops.php
	do
		if ! grep -qF -e 'pikaDefPrefs::storePrefs(' "$pf"
		then
			up_bad=$((up_bad + 1))
		fi
	done

	if [ "$up_bad" -eq 0 ]
	then
		ok "both preference handlers save through pikaDefPrefs::storePrefs()"
	else
		bad "${up_bad} preference handler(s) no longer call storePrefs() - their saves are lost at logout"
	fi

	# dataops.php runs under pika_cms.php, which rebuilds the include_path
	# without ./app/lib. A bare require_once('pikaDefPrefs.php') there does
	# not resolve and the whole branch is a fatal error, which is what the
	# save_prefs branch used to be.
	if grep -qF -e "require_once('app/lib/pikaDefPrefs.php')" cms/dataops.php
	then
		ok "dataops.php loads pikaDefPrefs by path, not off the include_path"
	else
		bad "dataops.php requires pikaDefPrefs by bare name - that does not resolve from this file"
	fi
fi

if [ "${HAVE_DB:-0}" != 1 ]
then
	printf '  skip the preference round trip (needs the database)\n'
else
	pr_before="$(adb "SELECT session_data FROM users WHERE username='${OCM_USER}'" | head -1)"

	# Read the token off the page that carries the form.
	curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" "$OCM_URL/prefs.php"
	pr_tok="$(grep -oE 'name="_csrf" value="[0-9a-f]{64}"' "$BODY" \
		| head -1 | sed -E 's/.*value="([0-9a-f]*)".*/\1/')"

	if [ "${#pr_tok}" -ne 64 ]
	then
		bad "prefs.php did not render a usable CSRF token (got ${#pr_tok} chars)"
	else
		# paging is a plain digit string, so the stored value is easy to read
		# back, and pikaDefPrefs::filterValue() accepts it without touching a
		# theme file or any other part of the tree.
		curl -sL --max-time 30 -b "$COOKIES" -c "$COOKIES" -o "$BODY" \
			--data-urlencode "_csrf=${pr_tok}" \
			--data-urlencode "paging=37" \
			"$OCM_URL/ops/update_prefs.php" >/dev/null

		pr_after="$(adb "SELECT session_data FROM users WHERE username='${OCM_USER}'" | head -1)"

		if printf '%s' "$pr_after" | grep -qF -e 's:6:"paging";s:2:"37"'
		then
			ok "a saved preference reached users.session_data"
		else
			bad "the saved preference never reached users.session_data - it is lost at logout"
		fi

		if [ "$pr_before" != "$pr_after" ]
		then
			ok "the stored preferences changed when a preference was saved"
		else
			bad "users.session_data is byte-identical after a save - nothing was written"
		fi

		# A fresh login has to read the value back. r_format and intake are
		# saveable and are not in the defaults file, so initPrefs() used to
		# skip them even once they were stored.
		curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" "$OCM_URL/prefs.php"

		if grep -qF -e 'name="paging" id="paging" value="37"' "$BODY"
		then
			ok "the preference screen renders the value that was saved"
		else
			bad "the preference screen does not show the saved value - initPrefs() is not reading it back"
		fi

		# Put it back so the next run starts where this one did.
		if [ -n "$pr_before" ]
		then
			adb "UPDATE users SET session_data='$(printf '%s' "$pr_before" | sed "s/'/''/g")' WHERE username='${OCM_USER}'" >/dev/null
		fi
	fi
fi

# 86. The case print report reads two rows and merges them, and neither read
# is guarded.
#
# cms/reports/case_print/case_print-form.php takes case_id straight out of
# the request, fetches the case, fetches that case's client, and calls
# array_merge() on the two rows. DBResult::fetchRow() returns null when the
# query matched nothing, and array_merge() has rejected null as a TypeError
# since PHP 8, so an unknown case_id and an ordinary case with no client both
# produced an error page instead of a report. client_id is 0 on an unassigned
# case, and the contact it names can have been deleted since, so the second
# one is not a rare shape.

echo
echo "checking the case print report with no client"

if grep -qF -e 'is_array($b)' cms/reports/case_print/case_print-form.php
then
	ok "case_print-form.php checks the client row before merging it"
else
	bad "case_print-form.php merges the client row without checking it is a row"
fi

if [ "${HAVE_DB:-0}" != 1 ]
then
	printf '  skip the case print renders (needs the database)\n'
else
	adb "DELETE FROM cases WHERE number = 'ZZCPNOCLIENT'" >/dev/null 2>&1

	# case_id is a primary key with no AUTO_INCREMENT, so pick the id here.
	cp_case="$(adb "SELECT COALESCE(MAX(case_id), 0) + 1 FROM cases")"
	cp_none="$(adb "SELECT COALESCE(MAX(case_id), 0) + 1000 FROM cases")"
	adb "INSERT INTO cases (case_id, number, client_id)
		VALUES (${cp_case}, 'ZZCPNOCLIENT', 0)" >/dev/null

	cp_code="$(curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" -w '%{http_code}' \
		"$OCM_URL/legacy_report.php?report=case_print&case_id=${cp_case}")"
	if [ "$cp_code" = "200" ] && [ -s "$BODY" ]
	then
		ok "a case with no client prints"
	else
		bad "a case with no client returned ${cp_code} - the report is a fatal, not a page"
	fi

	# An id that names no case at all is a bad request, not a crash. It used
	# to render a report with every field blank. Section 84's read_case gate
	# refuses it instead, because there is no row to judge the reader
	# against, so the answer is now the same 403 case.php gives. Either way
	# the point of this check is unchanged: a page, not a TypeError.
	cp_code="$(curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" -w '%{http_code}' \
		"$OCM_URL/legacy_report.php?report=case_print&case_id=${cp_none}")"
	if [ ! -s "$BODY" ] || grep -qF 'Fatal error' "$BODY"
	then
		bad "an unknown case_id returned ${cp_code} with a fatal or an empty body"
	elif [ "$cp_code" = "403" ] && grep -qF 'This case is not viewable' "$BODY"
	then
		ok "a case_id that names no case is refused, not printed blank"
	else
		bad "an unknown case_id returned ${cp_code} instead of a refusal"
	fi

	adb "DELETE FROM cases WHERE number = 'ZZCPNOCLIENT'" >/dev/null 2>&1
fi

echo
# ── 86. The case summary sidebar carries no inline JavaScript ───────────────
echo "86. the case summary sidebar carries no inline JavaScript"

# subtemplates/case_screen.html set a global in a one-line <script> block per
# party so that the form's onSubmit could read the party's name out of it,
# rather than interpolating the name into a JavaScript string literal where an
# apostrophe would close the literal early. That is inline script plus an
# inline event handler, both of which need script-src 'unsafe-inline'.
#
# The name now travels in data-party-name and the confirm() lives in
# js/case-screen.js. A data- attribute is the safer carrier anyway: it goes
# out through the template layer's normal HTML escaping and comes back as a
# string that was never parsed as code.
#
# Most of these are source checks rather than render checks. The panels drawn
# inside this page still have inline handlers of their own, so grepping the
# finished HTML would report their state, not this file's.

CS_TPL="cms/subtemplates/case_screen.html"

if [ ! -f "$CS_TPL" ]
then
	bad "$CS_TPL is missing - section 86 tested nothing"
else
	if grep -qiE '<[a-z][^>]*[[:space:]]on[a-z]+[[:space:]]*=' "$CS_TPL"
	then
		bad "$CS_TPL has an inline on* handler attribute again"
	else
		ok "the case summary sidebar has no inline on* handler attribute"
	fi

	if grep -q 'javascript:' "$CS_TPL"
	then
		bad "$CS_TPL has a javascript: URL again"
	else
		ok "the case summary sidebar has no javascript: URL"
	fi

	# An include carries src=. A tag that carries none opens a body, and a
	# body is inline script.
	#
	# Anchored at the start of the line because the comments in this file talk
	# about <script> blocks, and an unanchored match reads the prose as code.
	if grep -iE '^[[:space:]]*<script' "$CS_TPL" | grep -qiv 'src='
	then
		bad "$CS_TPL has an inline <script> block again"
	else
		ok "every <script> in the case summary sidebar is an external include"
	fi

	for js in case-screen.js ssn-mask.js
	do
		if grep -q "js/${js}" "$CS_TPL"
		then
			ok "the case summary sidebar includes js/${js}"
		else
			bad "$CS_TPL does not include js/${js} - its handlers are dead"
		fi

		if [ -f "cms/js/${js}" ]
		then
			ok "cms/js/${js} exists"
		else
			bad "cms/js/${js} is missing - the include 404s"
		fi
	done

	# The party name must reach the page through the default (HTML-escaping)
	# tag. encode=none here would put an unescaped value inside a quoted
	# attribute, which is an attribute-escape and then script.
	if grep -qE 'data-party-name="%%\[(client_name|full_name)[^]]*encode' "$CS_TPL"
	then
		bad "a data-party-name tag sets an encoding - it must use the default HTML escaping"
	else
		ok "both data-party-name tags use the default HTML escaping"
	fi

	# The old indirection must be gone, not merely supplemented.
	if grep -qE 'var (client_name|full_name)' "$CS_TPL"
	then
		bad "$CS_TPL still declares a name global for a confirm() prompt"
	else
		ok "no per-party name global is left in the case summary sidebar"
	fi

	# pika_ssn() is copy-pasted around this repo. The shared copy must hold
	# exactly one definition, or two files on one page share its counter and
	# the field gets two dashes.
	ssn_defs="$(grep -c 'function pika_ssn' cms/js/ssn-mask.js 2>/dev/null || echo 0)"
	if [ "$ssn_defs" = "1" ]
	then
		ok "cms/js/ssn-mask.js holds exactly one pika_ssn() definition"
	else
		bad "cms/js/ssn-mask.js holds ${ssn_defs} pika_ssn() definitions, expected 1"
	fi
fi

# The render check: a client whose name holds both a double quote and an
# apostrophe. The quote is what would close data-party-name and let the rest
# of the value be read as markup; the apostrophe is what broke the JavaScript
# string literal the old code was avoiding. Both must survive as text.
if [ "$HAVE_DB" = 1 ]
then
	cs_cid="$(adb "SELECT COALESCE(MAX(contact_id), 0) + 1 FROM contacts")"
	cs_case="$(adb "SELECT COALESCE(MAX(case_id), 0) + 1 FROM cases")"
	cs_conf="$(adb "SELECT COALESCE(MAX(conflict_id), 0) + 1 FROM conflict")"
	adb "INSERT INTO contacts (contact_id, first_name, last_name)
		VALUES (${cs_cid}, 'Zz', 'O\\'Brien \\\"Bo\\\"')" >/dev/null
	adb "INSERT INTO cases (case_id, number, client_id, status)
		VALUES (${cs_case}, 'ZZ-CSP-1', ${cs_cid}, '1')" >/dev/null

	# The client card is drawn from the party list, not from cases.client_id
	# alone: case.php draws it for the one party row whose contact is the
	# client and whose relation_code is 1. Without the conflict row the case
	# renders with no client card at all, and the checks below would pass or
	# fail on an empty page.
	adb "INSERT INTO conflict (conflict_id, case_id, contact_id, relation_code)
		VALUES (${cs_conf}, ${cs_case}, ${cs_cid}, '1')" >/dev/null

	cs_code="$(curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" -w '%{http_code}' \
		"$OCM_URL/case.php?case_id=${cs_case}")"

	if [ "$cs_code" = "200" ] && ! grep -q 'Pika Error' "$BODY"
	then
		ok "a case whose client name holds a quote and an apostrophe renders"
	else
		bad "case.php returned ${cs_code} for a client name with a quote"
	fi

	if grep -q 'data-party-name=' "$BODY"
	then
		ok "the rendered client card carries data-party-name"
	else
		bad "the rendered client card has no data-party-name - the confirm() has no name"
	fi

	# htmlspecialchars with ENT_QUOTES turns the double quote into &quot;. If
	# a raw one reached the attribute the value would have escaped it.
	if grep -q 'data-party-name="[^"]*&quot;' "$BODY"
	then
		ok "the double quote in the client name is escaped inside the attribute"
	elif grep -q 'data-party-name="[^"]*Bo' "$BODY"
	then
		bad "A RAW DOUBLE QUOTE REACHED data-party-name - THE ATTRIBUTE IS ESCAPABLE (CWE-79)"
	else
		bad "could not find the seeded client name in data-party-name"
	fi

	# pl_html_escape() passes ENT_HTML5, so the apostrophe comes out as the
	# named entity &apos; rather than &#039;. Either is correct here; what
	# matters is that it is escaped exactly once. Doubly escaped it would read
	# "&amp;apos;" and the confirm() prompt would show the entity to the user,
	# which is what happens on the contact card, whose name is cleaned once
	# before the template layer escapes it again.
	if grep -qE 'data-party-name="[^"]*O(&apos;|&#039;)Brien' "$BODY"
	then
		ok "the apostrophe in the client name is escaped exactly once"
	elif grep -qE 'data-party-name="[^"]*&amp;(apos|#039);' "$BODY"
	then
		bad "the client name is doubly escaped - the prompt will show the entity"
	else
		bad "the apostrophe in the client name did not render"
	fi

	adb "DELETE FROM conflict WHERE case_id = ${cs_case}" >/dev/null 2>&1
	adb "DELETE FROM cases WHERE number = 'ZZ-CSP-1'" >/dev/null 2>&1
	adb "DELETE FROM contacts WHERE contact_id = ${cs_cid}" >/dev/null 2>&1
fi

# ── 87. The case and contact PHP pages carry no inline JavaScript ───────────
echo "87. the case and contact PHP pages carry no inline JavaScript"

# Five pages assembled markup in PHP with an event handler attribute written
# into the string, and two of them pulled a whole <script> block in with
# file_get_contents() and echoed it. Both forms need script-src
# 'unsafe-inline'.
#
# The handlers now live in cms/js/ and the pages reference them with a
# <script src>. The party name that case.php used to interpolate into an
# onClick travels in data-party-name, the same carrier the case summary
# sidebar uses; see section 86 for why a data- attribute is the safe one.
#
# One trap is specific to the two file_get_contents() sites. js/form_save.js
# is not JavaScript: it is markup, a <script> element with a jQuery include
# above it, written to be pasted into a page. Referenced with a <script src>
# instead, the browser would parse "<script" as JavaScript and throw. The
# replacements must therefore be script-only files, which is what the last
# check here asserts.

for csp_php in cms/case.php cms/contact.php cms/index.php
do
	if [ ! -f "$csp_php" ]
	then
		bad "$csp_php is missing - section 87 tested nothing"
	elif grep -qiE '<[a-z][^>]*[[:space:]]on[a-z]+[[:space:]]*=' "$csp_php"
	then
		bad "$csp_php has an inline on* handler attribute again"
	else
		ok "$csp_php has no inline on* handler attribute"
	fi
done

for csp_js in cms/js/case.js cms/js/case-inline.js cms/js/contact-inline.js cms/js/index.js
do
	if [ -f "$csp_js" ]
	then
		ok "$csp_js exists"
	else
		bad "$csp_js is missing - the page that includes it will 404"
	fi
	
	# A file served through <script src> is parsed as JavaScript from its
	# first byte, so a <script> tag inside it is a syntax error, not markup.
	if [ -f "$csp_js" ] && grep -qi '<script' "$csp_js"
	then
		bad "$csp_js holds a <script> tag - it is markup, not a script file"
	elif [ -f "$csp_js" ]
	then
		ok "$csp_js is script-only"
	fi
done

if grep -q 'js/case-inline.js' cms/case.php && grep -q 'js/case.js' cms/case.php
then
	ok "cms/case.php includes both of its script files"
else
	bad "cms/case.php lost one of its script includes"
fi

if grep -q 'js/contact-inline.js' cms/contact.php
then
	ok "cms/contact.php includes js/contact-inline.js"
else
	bad "cms/contact.php lost its script include"
fi

if grep -q 'js/index.js' cms/index.php
then
	ok "cms/index.php includes js/index.js"
else
	bad "cms/index.php lost its script include"
fi

# The remove-client link. case.php builds this into $clients_html, which
# nothing prints today - the block that used to is the commented-out "OLD
# WAY" - so this is a source check, not a render check.
if grep -q 'data-party-name=' cms/case.php && grep -q 'js-case-remove-client' cms/case.php
then
	ok "the remove-client link carries the party name in a data attribute"
else
	bad "the remove-client link no longer carries data-party-name"
fi

if grep -q 'pl_html_escape(pl_text_name(' cms/case.php
then
	ok "the party name is escaped before it goes into the attribute"
else
	bad "the party name reaches the attribute unescaped"
fi

# ── 88. Every script include resolves to a real script file ────────────────
echo "88. every script include resolves to a real script file"

# This is a sweep, not a list of filenames, because the last three batches of
# this work produced three different ways to get it wrong and a list would
# only have caught the ones already known.
#
# There are two ways to load JavaScript in this tree and they are not
# interchangeable:
#
#   <script src="%%[base_url]%%/js/NAME.js">   the browser fetches the file
#   %%[NAME.js,javascript,parse]%%             the template layer renders the
#                                              file and inlines the result
#
# The second form exists because some of these files contain template tags -
# js/case-pb.js needs %%[current_date]%%, for instance. Converting one of
# those to a <script src> leaves a file whose tags are never substituted: it
# parses, it runs, and it is wrong. So a file loaded with <script src> must
# hold no template tag.
#
# A file loaded with <script src> must also be JavaScript rather than markup.
# js/form_save.js is a <script> element with a jQuery include above it,
# written to be pasted into a page; served through a src attribute the browser
# parses "<script" as JavaScript and throws on the first line.
#
# And the file has to exist. Two independent conversions each created a
# cms/js/index.js, one for cms/index.php and one for cms/m/index.php, which
# would have left whichever landed second silently overwriting the other.

csp_missing=0
csp_markup=0
csp_tagged=0

# Every js/NAME.js named in a <script src>, anywhere in the tree.
grep -rhoE '<script[^>]+src="[^"]*/js/[A-Za-z0-9_.-]+\.js"' cms cms-custom 2>/dev/null \
	| grep -oE '/js/[A-Za-z0-9_.-]+\.js' \
	| sed 's|^/js/||' \
	| sort -u > "$BODY.csp88"

while read -r csp_js
do
	[ -z "$csp_js" ] && continue
	
	if [ ! -f "cms/js/$csp_js" ]
	then
		bad "a page includes js/$csp_js and no such file exists"
		csp_missing=$((csp_missing + 1))
		continue
	fi
	
	# The test is the FIRST line of real code, not any mention of the string.
	# Several of these files describe in a comment what they replaced, and the
	# word <script> appears in that prose; the browser does not care about
	# that. What breaks a file is opening with markup, because the parse
	# starts at the first byte.
	csp_first="$(awk '
		BEGIN { inblock = 0 }
		{
			line = $0
			
			while (1)
			{
				if (inblock)
				{
					i = index(line, "*/")
					if (i == 0) { line = ""; break }
					line = substr(line, i + 2)
					inblock = 0
				}
				else
				{
					i = index(line, "/*")
					if (i == 0) { break }
					line = substr(line, 1, i - 1)
					inblock = 1
				}
			}
			
			sub(/^[ \t]*\/\/.*$/, "", line)
			gsub(/^[ \t]+/, "", line)
			gsub(/[ \t]+$/, "", line)
			
			if (line != "") { print line; exit }
		}
	' "cms/js/$csp_js")"
	
	case "$csp_first" in
		"<"*)
			bad "js/$csp_js is loaded with <script src> but opens with markup: $csp_first"
			csp_markup=$((csp_markup + 1))
			;;
	esac
	
	if grep -q '%%\[' "cms/js/$csp_js"
	then
		bad "js/$csp_js is loaded with <script src> but holds a template tag"
		csp_tagged=$((csp_tagged + 1))
	fi
done < "$BODY.csp88"

csp_total="$(grep -c . "$BODY.csp88" 2>/dev/null || echo 0)"

if [ "$csp_total" -lt 5 ]
then
	bad "section 88 found only $csp_total script includes - the sweep is broken"
else
	ok "$csp_total script includes swept"
fi

[ "$csp_missing" -eq 0 ] && ok "every script include resolves to a file that exists"
[ "$csp_markup"  -eq 0 ] && ok "no file served through <script src> is markup"
[ "$csp_tagged"  -eq 0 ] && ok "no file served through <script src> needs the template layer"

# The other direction: a file that does hold a template tag must still be
# loaded through the parsing form somewhere, or its tags never resolve.
# The other way to load a script, and the other way to get it wrong. The
# javascript plugin defaults to parse => false, so a file holding a tag and
# included without the flag renders the literal text %%[base_url]%% into the
# page: it parses, it runs, and the URL it builds is wrong.
#
# Every include SITE is checked, not every file. js/problem-server-ajax.js is
# included from two templates, and one of them losing the flag breaks that one
# page while the other keeps working - which is exactly the kind of difference
# a per-file check reports as fine.
csp_sites=0
csp_unparsed=0
csp_missing=0

grep -rnoE '%%\[[A-Za-z0-9_.-]+\.js,javascript[^]]*\]%%' cms cms-custom 2>/dev/null \
	| sort -u > "$BODY.csp88b"

while IFS= read -r csp_site
do
	[ -z "$csp_site" ] && continue
	
	csp_where="${csp_site%%:*}"
	csp_tag="${csp_site##*:}"
	csp_base="${csp_tag#%%[}"
	csp_base="${csp_base%%,*}"
	
	# A name behind this plugin that resolves to nothing is not a no-op.
	# The plugin returns the string "NAME not found", wraps it in script
	# tags and echoes it, so the page gets a script block whose first
	# statement is "pvppa.js not found" - a syntax error thrown on every
	# render of that page. cms/subtemplates/case-pension.html carried
	# exactly that, for a file that has never existed in this repository.
	# The plugin looks in the custom directory first and the cms one
	# second, so either one counts as resolving.
	if [ ! -f "cms/js/$csp_base" ] && [ ! -f "cms-custom/js/$csp_base" ]
	then
		bad "$csp_where includes js/$csp_base, which does not exist, so the page gets a script block reading '$csp_base not found'"
		csp_missing=$((csp_missing + 1))
		continue
	fi
	
	# Only a file that actually holds a tag needs the flag.
	if [ ! -f "cms/js/$csp_base" ] || ! grep -q '%%\[' "cms/js/$csp_base"
	then
		continue
	fi
	
	csp_sites=$((csp_sites + 1))
	
	case "$csp_tag" in
		*,parse]%%)
			;;
		*)
			bad "$csp_where includes js/$csp_base without parse, so its tags stay literal"
			csp_unparsed=$((csp_unparsed + 1))
			;;
	esac
done < "$BODY.csp88b"

if [ "$csp_sites" -lt 5 ]
then
	bad "section 88 found only $csp_sites template-tag includes - the sweep is broken"
else
	ok "$csp_sites template-tag includes swept"
fi

[ "$csp_unparsed" -eq 0 ] && ok "every include of a tag-bearing script carries parse"
[ "$csp_missing" -eq 0 ] && ok "every template-tag include resolves to a file that exists"

rm -f "$BODY.csp88b"

rm -f "$BODY.csp88"


# ── 89. Every marker class is both emitted and bound ───────────────────────
echo "89. every marker class is both emitted and bound"

# Taking a handler out of the markup splits one thing into two: a class on the
# tag, and an addEventListener in a file under cms/js. Nothing joins them but
# the spelling, and a mismatch is silent. A class emitted but never bound is a
# control that does nothing when clicked - no console error, no failed
# request, nothing on the page to notice. A class bound but never emitted is a
# listener that never fires. Neither is visible in a page fetch, so no other
# section here can see it. This is the only check that can.
#
# The sweep reads both sides as sets and requires them to match exactly.
#
# The class names on the JavaScript side are NOT read as ".js-name", because
# only some of these are CSS selectors. field-list-inline.js binds with
# classList.contains('js-field-list-toggle'), which has no dot, and requiring
# one silently drops it from the set.

grep -rhoE 'js-[A-Za-z0-9_-]+' cms/js 2>/dev/null | sort -u > "$BODY.csp89bound"

# Where a marker class may legitimately be written: the templates, the PHP
# that renders them, and the plugins that build the tags.
grep -rhoE 'js-[A-Za-z0-9_-]+' \
	cms/subtemplates cms-custom/subtemplates cms/reports cms/templates \
	cms/modules cms/template_plugins cms/m cms/*.php cms-custom/*.php \
	2>/dev/null | sort -u > "$BODY.csp89emit"

mark_bound="$(grep -c . "$BODY.csp89bound" 2>/dev/null || echo 0)"
mark_emit="$(grep -c . "$BODY.csp89emit" 2>/dev/null || echo 0)"

if [ "$mark_bound" -lt 20 ] || [ "$mark_emit" -lt 20 ]
then
	bad "section 89 found only $mark_bound bound and $mark_emit emitted marker classes - the sweep is broken"
else
	ok "$mark_bound marker classes swept"
fi

mark_dead=0
while read -r mark_class
do
	[ -z "$mark_class" ] && continue
	if ! grep -qxF "$mark_class" "$BODY.csp89emit"
	then
		bad "cms/js binds $mark_class but no template or plugin emits it, so the listener never fires"
		mark_dead=$((mark_dead + 1))
	fi
done < "$BODY.csp89bound"

while read -r mark_class
do
	[ -z "$mark_class" ] && continue
	if ! grep -qxF "$mark_class" "$BODY.csp89bound"
	then
		bad "a page emits $mark_class but nothing in cms/js binds it, so the control is dead"
		mark_dead=$((mark_dead + 1))
	fi
done < "$BODY.csp89emit"

[ "$mark_dead" -eq 0 ] && ok "every marker class is both emitted and bound"

rm -f "$BODY.csp89bound"
rm -f "$BODY.csp89emit"

# And the handlers must not come back. Case matters here: onChange="..." was
# missed by an earlier case-sensitive sweep and three live handlers survived
# on case-elig.html, so this reads case-insensitively.
#
# Markup inside an HTML comment is never parsed and is not a handler, so the
# comments are stripped before the count rather than filtered after it: both
# remaining examples sit inside a comment on a line that also holds live
# markup, and dropping the whole line would hide anything else on it.
mark_attr="$(find cms/subtemplates cms-custom/subtemplates cms/reports cms/templates -name '*.html' -print0 2>/dev/null \
	| xargs -0 sed -E 's/<!--.*-->//g' 2>/dev/null \
	| grep -ciE '<[^<>]*[[:space:]]on(click|change|submit|load|unload|blur|focus|keyup|keydown|keypress|mouseover|mouseout|mousedown|mouseup|dblclick|select|reset|abort|error|input|paste)[[:space:]]*=' )"

if [ "$mark_attr" -eq 0 ]
then
	ok "no template renders an inline on* handler attribute"
else
	bad "$mark_attr inline on* handler attributes are back in the templates"
fi

# ---------------------------------------------------------------------------
# 82. pikaTempLib reads the file it is handed, whatever file that is.
#
# The constructor calls file_exists() and then file_get_contents(), with no
# check that the path is a template. Handed /etc/hostname it returns the
# container hostname as the template string, which the caller then renders into
# a page. Confirmed against the unpatched class.
#
# No request reaches that today. The only caller whose path is influenced by a
# request is activity.php, which builds "subtemplates/activity{$act_type}.html"
# out of ?act_type=, and the fixed prefix and the .html suffix are what stop a
# traversal from landing anywhere interesting -- not any check. So this is the
# class being made to refuse rather than a live leak being closed, and the
# checks below are written to hold whichever caller arrives next.
#
# Section 82a runs inside the container rather than over HTTP, because that is
# where a caller handing the class an outside path can be arranged. It writes a
# file with a marker in it somewhere the template roots do not cover, and
# asserts the marker does not come back. Note that trigger_error() only stops
# the request where pl_error_handler() is installed, which a php -r is not, so
# the assertion is on the template string and not on the exit status.
# ---------------------------------------------------------------------------

echo
echo "== 82. the template engine refuses a file outside the template roots =="

if [ "${HAVE_COMPOSE:-0}" != 1 ]
then
	printf '  skip section 82 (needs a compose stack)\n'
else
	# 82a. A file outside the roots must not be read.
	TL_OUT="$(docker compose "${COMPOSE_ARGS[@]}" exec -T -w /var/www/html/cms app php -r '
		file_put_contents("/tmp/zz-templib-outside.html", "ZZTEMPLIBLEAK");
		$_SERVER["custom_directory"] = "/var/www/html/cms-custom";
		require_once("app/lib/pl.php");
		require_once("app/lib/pikaTempLib.php");
		$t = new pikaTempLib("/tmp/zz-templib-outside.html", array());
		$r = new ReflectionClass($t);
		$p = $r->getProperty("_template_string");
		$p->setAccessible(true);
		echo "STRING:" . trim((string) $p->getValue($t));
	' </dev/null 2>/dev/null | tr -d '\r')"

	case "$TL_OUT" in
		*ZZTEMPLIBLEAK*)
			bad "pikaTempLib read a file outside the template roots (${TL_OUT})" ;;
		*STRING:*)
			ok "pikaTempLib refuses a file outside the template roots" ;;
		*)
			bad "pikaTempLib containment check did not run (${TL_OUT})" ;;
	esac

	# 82b. Positive control. A refusal that refuses everything would pass 82a
	# and break every screen, so a real template must still be read.
	TL_IN="$(docker compose "${COMPOSE_ARGS[@]}" exec -T -w /var/www/html/cms app php -r '
		$_SERVER["custom_directory"] = "/var/www/html/cms-custom";
		require_once("app/lib/pl.php");
		require_once("app/lib/pikaTempLib.php");
		$t = new pikaTempLib("subtemplates/activity.html", array());
		$r = new ReflectionClass($t);
		$p = $r->getProperty("_template_string");
		$p->setAccessible(true);
		echo "LEN:" . strlen((string) $p->getValue($t));
	' </dev/null 2>/dev/null | tr -d '\r')"

	TL_LEN="$(printf '%s' "$TL_IN" | sed -e 's/.*LEN://')"
	case "$TL_LEN" in
		''|*[!0-9]*)
			bad "pikaTempLib positive control did not run (${TL_IN})" ;;
		0)
			bad "pikaTempLib no longer reads subtemplates/activity.html - the containment check is refusing real templates" ;;
		*)
			ok "pikaTempLib still reads a real template (${TL_LEN} bytes)" ;;
	esac
fi

# 82c. The caller. A traversing act_type must leave the screen working and
# nothing of the filesystem on it. Asserting the screen still renders as well
# as the absence of the file, because a blank page would also hold no passwd.
TL_BODY="$BODY.templib82c"
TL_CODE="$(curl -s --max-time 30 -b "$COOKIES" -o "$TL_BODY" -w '%{http_code}' \
	"$OCM_URL/activity.php?act_type=../../../../etc/passwd")"

if grep -q 'root:x:' "$TL_BODY"
then
	bad "activity.php served /etc/passwd for a traversing act_type"
elif [ "$TL_CODE" != 200 ]
then
	bad "activity.php returned ${TL_CODE} for a traversing act_type"
elif grep -qi 'act_date' "$TL_BODY"
then
	ok "activity.php falls back to the default activity screen for a traversing act_type"
else
	bad "activity.php rendered no activity screen for a traversing act_type"
fi

rm -f "$TL_BODY"

# ---------------------------------------------------------------------------
# 83. Request values inside quoted HTML attributes.
#
# pl_grab_var() and pl_grab_get()'s default filter turn < and > into entities
# and leave everything else alone, so a value that went through them cannot
# open a tag. Both pages below put such a value inside a quoted attribute,
# where the quote is what matters and the quote is not on that list.
#
# The current CSP -- script-src 'self' with a nonce, no 'unsafe-inline' --
# stops an on* attribute written this way from running, so what these checks
# describe is attribute injection rather than script execution. They assert on
# the markup rather than on any consequence of it, because the CSP is a second
# line and this is the first one.
# ---------------------------------------------------------------------------

echo
echo "== 83. request values stay inside their quoted attributes =="

XA_BODY="$BODY.attr83"

# 83a. assign_atty.php, single-quoted hidden input. case_id and field are
# request values and the template writes them as value='...'.
curl -s --max-time 30 -b "$COOKIES" -o "$XA_BODY" -w '' --get \
	--data-urlencode "case_id=1' zzatty=1 x='" \
	--data-urlencode "field=atty_id" \
	"$OCM_URL/assign_atty.php" >/dev/null

if grep -qF "value='1' zzatty=1" "$XA_BODY"
then
	bad "assign_atty.php lets case_id break out of a single-quoted attribute"
elif grep -qE "value='1&[A-Za-z0-9#]+; zzatty=1" "$XA_BODY"
then
	# Any character reference will do. htmlspecialchars() writes &apos; under
	# ENT_HTML5 and &#039; under ENT_HTML401, and which one is not the point.
	ok "assign_atty.php escapes the quote in case_id"
else
	bad "assign_atty.php did not render the case_id input at all"
fi

# 83b. The same page, double-quoted, and a different value: county comes from
# the search form and $z is the filter array itself.
curl -s --max-time 30 -b "$COOKIES" -o "$XA_BODY" -w '' --get \
	--data-urlencode 'case_id=1' \
	--data-urlencode 'field=atty_id' \
	--data-urlencode 'county=ZZ" zzcounty=1 x="' \
	"$OCM_URL/assign_atty.php" >/dev/null

if grep -qF 'value="ZZ" zzcounty=1' "$XA_BODY"
then
	bad "assign_atty.php lets county break out of a double-quoted attribute"
elif grep -qE 'value="ZZ&[A-Za-z0-9#]+; zzcounty=1' "$XA_BODY"
then
	ok "assign_atty.php escapes the quote in a search field"
else
	bad "assign_atty.php did not render the county input at all"
fi

# 83c. Positive control for both: an ordinary search term still comes back in
# the box, unchanged, so the escape has not eaten the form.
curl -s --max-time 30 -b "$COOKIES" -o "$XA_BODY" -w '' --get \
	--data-urlencode 'case_id=1' \
	--data-urlencode 'field=atty_id' \
	--data-urlencode 'county=Wayne' \
	"$OCM_URL/assign_atty.php" >/dev/null

if grep -qF 'name="county" value="Wayne"' "$XA_BODY"
then
	ok "assign_atty.php still hands an ordinary search term back to the form"
else
	bad "assign_atty.php lost the search term it was given"
fi

# 83d. system-outcomes.php builds a form action out of ?outcome=. The value
# reaches it through DB::escapeString(), which backslash-escapes the quote for
# SQL and leaves it in the string -- and in HTML a backslashed quote is still
# the end of the attribute.
curl -s --max-time 30 -b "$COOKIES" -o "$XA_BODY" -w '' --get \
	--data-urlencode 'action=edit' \
	--data-urlencode 'outcome=housing" zzoutcome=1 x="' \
	"$OCM_URL/system-outcomes.php" >/dev/null

if grep -qF 'zzoutcome=1' "$XA_BODY"
then
	bad "system-outcomes.php lets outcome break out of the form action"
elif grep -qF 'zzoutcome%3D1' "$XA_BODY"
then
	ok "system-outcomes.php encodes the outcome in the form action"
else
	bad "system-outcomes.php did not render the form action at all"
fi

# 83e. Positive control. The form still points at the outcome it is editing,
# so the encoding has not broken the save.
curl -s --max-time 30 -b "$COOKIES" -o "$XA_BODY" -w '' --get \
	--data-urlencode 'action=edit' \
	--data-urlencode 'outcome=housing' \
	"$OCM_URL/system-outcomes.php" >/dev/null

if grep -qF 'outcome=housing" method="POST"' "$XA_BODY"
then
	ok "system-outcomes.php still aims the edit form at the outcome it opened"
else
	bad "system-outcomes.php no longer aims the edit form at its outcome"
fi

rm -f "$XA_BODY"

# 84. The two per-case report forms gate on read access to the case.
#
# cms/legacy_report.php has no authorization call of its own, and neither
# cms/reports/case_print/case_print-form.php nor
# cms/reports/compen_bill/compen_bill-form.php read a permission before
# printing the case. Both take case_id off the query string, so before the gate
# any signed-in user could print any case, including one case.php refuses them.
#
# The gate is read access to the case, not the `reports` group flag: the case
# Docs tab posts report=case_print for ordinary users, so a report-level flag
# would take case printing away from everyone outside the system group. Both
# halves are checked here - the refusal for a user who cannot read the case,
# and the print for a user who can.
if [ "$HAVE_DB" = 1 ]; then
	RGROUP='zz_rpt_grp'
	RREADER='zz_rpt_reader'
	ROWNER='zz_rpt_owner'
	RPWD='zz-rpt-Passw0rd'
	RSECRET='ZZRPTSECRETCLIENT'
	RJAR="$(mktemp)"
	ROJAR="$(mktemp)"

	cleanup_rpt() {
		# Two tables outlive the users unless they go first. user_sessions has no
		# cascading foreign key on user_id, and csrf_tokens holds the row
		# pl_csrf_rotate() wrote at login, keyed by session id.
		#
		# The session ids are read into the shell rather than compared between the
		# two tables in SQL. csrf_tokens.session_id is declared
		# utf8mb4_unicode_ci; user_sessions.session_id takes the database default,
		# utf8mb4_general_ci on a stock install. Comparing the two columns answers
		# "Illegal mix of collations", and adb sends stderr to /dev/null, so that
		# DELETE would remove nothing and say nothing.
		rpt_sids="$(adb "SELECT CONCAT(CHAR(39), session_id, CHAR(39)) FROM user_sessions
			WHERE user_id IN (SELECT user_id FROM users
				WHERE username IN ('${RREADER}', '${ROWNER}'))" | paste -sd, -)"
		if [ -n "$rpt_sids" ]; then
			adb "DELETE FROM csrf_tokens WHERE session_id IN (${rpt_sids})" >/dev/null
		fi
		adb "DELETE FROM user_sessions WHERE user_id IN
			(SELECT user_id FROM users WHERE username IN ('${RREADER}', '${ROWNER}'))" >/dev/null
		adb "DELETE FROM cases WHERE number = 'ZZ-RPT-1'" >/dev/null
		adb "DELETE FROM contacts WHERE last_name = '${RSECRET}'" >/dev/null
		adb "DELETE FROM users WHERE username IN ('${RREADER}', '${ROWNER}')" >/dev/null
		adb "DELETE FROM \`groups\` WHERE group_id = '${RGROUP}'" >/dev/null
		# A DELETE that failed has to be said out loud, or the run reports a clean
		# finish while the next run measures a dirty database. The login rows in
		# audit_log are kept on purpose and are not counted here.
		rpt_left="$(adb "SELECT COUNT(*) FROM users WHERE username IN ('${RREADER}', '${ROWNER}')")"
		rpt_left="${rpt_left}$(adb "SELECT COUNT(*) FROM cases WHERE number = 'ZZ-RPT-1'")"
		rpt_left="${rpt_left}$(adb "SELECT COUNT(*) FROM contacts WHERE last_name = '${RSECRET}'")"
		rpt_left="${rpt_left}$(adb "SELECT COUNT(*) FROM \`groups\` WHERE group_id = '${RGROUP}'")"
		if [ -n "$rpt_sids" ]; then
			rpt_left="${rpt_left}$(adb "SELECT COUNT(*) FROM csrf_tokens WHERE session_id IN (${rpt_sids})")"
		else
			rpt_left="${rpt_left}0"
		fi
		if [ "$rpt_left" != 00000 ]; then
			bad "the report gate fixture could not be removed (users, case, contact, group, csrf rows still present: ${rpt_left})"
		fi
		rm -f "$RJAR" "$ROJAR"
	}

	# Every request below goes through one of these two. Neither the status nor
	# the body proves anything on its own: curl's own exit status is checked,
	# because a request that timed out after the expected words had arrived would
	# otherwise read as a refusal, and $BODY is emptied first, because a stale
	# body left by the previous request would read as one too.
	rpt_fetch() {
		: > "$BODY"
		rpt_code="$(curl -s --max-time 60 -b "$1" -o "$BODY" -w '%{http_code}' "$2")"
		rpt_curl=$?
		[ "$rpt_curl" = 0 ]
	}

	rpt_login() {
		: > "$1"
		: > "$BODY"
		rpt_code="$(curl -sL --max-time 30 -c "$1" -b "$1" -o "$BODY" -w '%{http_code}' \
			-X POST -d "login_user=${2}&login_pass=${RPWD}&auth_id=1" "$OCM_URL/")"
		rpt_curl=$?
		[ "$rpt_curl" = 0 ] && [ "$rpt_code" = 200 ] && [ -s "$BODY" ] \
			&& ! grep -q 'login_pass' "$BODY"
	}
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_rpt' EXIT
	cleanup_rpt

	# One group with every flag off, and two users in it. The difference
	# between them is the case's user_id, which is the only thing
	# pika_authorize('read_case', ...) has left to grant on.
	adb "INSERT INTO \`groups\` (group_id, read_office, read_all, edit_office, edit_all, users, pba, motd, intake, reports)
		VALUES ('${RGROUP}', NULL, 0, NULL, 0, 0, 0, 0, 0, NULL)" >/dev/null

	RHASH="$(docker compose "${COMPOSE_ARGS[@]}" exec -T app \
		php -r 'echo password_hash($argv[1], PASSWORD_DEFAULT);' "$RPWD" </dev/null 2>/dev/null)"
	RUID="$(adb "SELECT COALESCE(MAX(user_id), 0) + 1 FROM users")"
	adb "INSERT INTO users (user_id, username, password, enabled, group_id, password_expire)
		VALUES (${RUID}, '${RREADER}', '${RHASH}', 1, '${RGROUP}', 0)" >/dev/null
	ROUID="$(adb "SELECT COALESCE(MAX(user_id), 0) + 1 FROM users")"
	adb "INSERT INTO users (user_id, username, password, enabled, group_id, password_expire)
		VALUES (${ROUID}, '${ROWNER}', '${RHASH}', 1, '${RGROUP}', 0)" >/dev/null

	# The client's surname is the marker. Both forms print the client name, so
	# it appearing in a response is the leak itself, not a proxy for it.
	RCID="$(adb "SELECT COALESCE(MAX(contact_id), 0) + 1 FROM contacts")"
	adb "INSERT INTO contacts (contact_id, first_name, last_name)
		VALUES (${RCID}, 'Zz', '${RSECRET}')" >/dev/null
	RCASE="$(adb "SELECT COALESCE(MAX(case_id), 0) + 1 FROM cases")"
	# cases.office is char(3). A longer value is silently truncated on the
	# shipped non-strict database and rejected under strict SQL mode, where the
	# failed insert would take the positive controls down with it.
	adb "INSERT INTO cases (case_id, number, client_id, user_id, office, status)
		VALUES (${RCASE}, 'ZZ-RPT-1', ${RCID}, ${ROUID}, 'ZZO', '1')" >/dev/null

	rpt_print="$OCM_URL/legacy_report.php?report=case_print&case_id=${RCASE}"
	rpt_bill="$OCM_URL/reports/compen_bill/compen_bill-form.php?case_id=${RCASE}"

	if [ -z "$RHASH" ] || [ -z "${RCASE:-}" ] || [ -z "${RCID:-}" ]; then
		bad "could not seed the report authorization fixtures"
	else
		# Positive control on the fixture. If the admin cannot see the marker
		# then the two refusal checks below would pass on a blank page.
		for rpt_url in "$rpt_print" "$rpt_bill"; do
			if ! rpt_fetch "$COOKIES" "$rpt_url"; then
				bad "the admin's request for ${rpt_url##*/} failed (curl exit $rpt_curl) - section 84 proves nothing"
			elif [ "$rpt_code" != 200 ]; then
				bad "the admin got $rpt_code from ${rpt_url##*/} - section 84 proves nothing"
			elif grep -qF "$RSECRET" "$BODY"; then
				ok "the admin sees the client name in ${rpt_url##*/} (status 200)"
			else
				bad "the admin does NOT see the client name in ${rpt_url##*/} - section 84 proves nothing"
			fi
		done

		# Each login is checked on its own. Both used to be POSTed into the same
		# body file and only the second one read, so a reader who could not log in
		# was reported as logged in, and an anonymous request refused for want of a
		# session would have been filed as the gate working.
		if ! rpt_login "$RJAR" "$RREADER"; then
			bad "the report reader could not log in (curl exit $rpt_curl, status $rpt_code) - section 84 is untested"
		elif ! rpt_login "$ROJAR" "$ROWNER"; then
			bad "the case's own handler could not log in (curl exit $rpt_curl, status $rpt_code) - section 84 is untested"
		else
			ok "both throwaway report users can log in"

			# Control on the fixture: the case page itself refuses the reader.
			# Everything below is about the report forms reaching the same
			# answer, so if case.php lets this user in there is nothing to say.
			if ! rpt_fetch "$RJAR" "$OCM_URL/case.php?case_id=${RCASE}"; then
				bad "the reader's request for case.php failed (curl exit $rpt_curl) - section 84 proves nothing"
			elif [ "$rpt_code" = 403 ] && grep -q 'This case is not viewable' "$BODY"; then
				ok "the fixture case is refused to the reader on case.php (status 403)"
			else
				bad "case.php answered the reader $rpt_code, not the refusal - section 84 proves nothing"
			fi

			for rpt_url in "$rpt_print" "$rpt_bill"; do
				if ! rpt_fetch "$RJAR" "$rpt_url"; then
					bad "the reader's request for ${rpt_url##*/} failed (curl exit $rpt_curl), so the refusal is unproven"
				elif grep -qF "$RSECRET" "$BODY"; then
					bad "A USER WHO CANNOT READ THE CASE CAN PRINT IT THROUGH ${rpt_url##*/}"
				elif [ "$rpt_code" != 403 ]; then
					bad "${rpt_url##*/} hid the case from the reader but answered $rpt_code, not 403"
				elif grep -q 'This case is not viewable' "$BODY"; then
					ok "${rpt_url##*/} refuses a user who cannot read the case"
				else
					bad "${rpt_url##*/} answered 403 without saying why"
				fi
			done

			# The refusal has to come before the dispatch, not from the form that
			# gets included. legacy_report.php prefers a deployment's own copy of
			# case_print-form.php for any report name at all, and that copy is not in
			# this repository, so a gate that only lives in the stock forms does not
			# cover this file. A report name that reaches a different form, and one
			# that reaches no form, both have to answer the refusal.
			for rpt_name in compen_bill zz_no_such_report; do
				if ! rpt_fetch "$RJAR" "$OCM_URL/legacy_report.php?report=${rpt_name}&case_id=${RCASE}"; then
					bad "the reader's request for legacy_report.php?report=${rpt_name} failed (curl exit $rpt_curl)"
				elif [ "$rpt_code" = 403 ] && grep -q 'This case is not viewable' "$BODY"; then
					ok "legacy_report.php refuses the case before it dispatches report=${rpt_name}"
				elif grep -qF "$RSECRET" "$BODY"; then
					bad "legacy_report.php?report=${rpt_name} PRINTED THE CLIENT NAME TO A USER WHO CANNOT READ THE CASE"
				else
					bad "legacy_report.php?report=${rpt_name} answered the reader $rpt_code instead of refusing the case before dispatch"
				fi
			done

			# An id that names no case, and an id that is not a case id at all, have
			# to be answered the same way as a case the reader may not read.
			#
			# The billing form used to construct pikaCase before the gate. A SELECT
			# that matched no row ends in trigger_error(), which the pl error
			# handler turns into the generic "currently unavailable" screen and
			# exits, so an unknown id answered 200 and that screen while an existing
			# case the reader may not read answered 403 - enough to tell real case
			# numbers from invented ones. An absent or non-integer id was worse:
			# plBase treats it as a new record and allocates the next free case id.
			rpt_none="$(adb "SELECT COALESCE(MAX(case_id), 0) + 5000 FROM cases")"
			for rpt_id in "$rpt_none" '0' '1e3' ''; do
				for rpt_form in case_print compen_bill; do
					case "$rpt_form" in
						case_print)
							rpt_url="$OCM_URL/legacy_report.php?report=case_print&case_id=${rpt_id}"
							;;
						*)
							rpt_url="$OCM_URL/reports/compen_bill/compen_bill-form.php?case_id=${rpt_id}"
							;;
					esac
					if ! rpt_fetch "$RJAR" "$rpt_url"; then
						bad "the reader's request for $rpt_form with case_id='${rpt_id}' failed (curl exit $rpt_curl)"
					elif [ "$rpt_code" = 403 ] && grep -q 'This case is not viewable' "$BODY"; then
						ok "$rpt_form answers case_id='${rpt_id}' the same refusal an existing case gets"
					else
						bad "$rpt_form ANSWERED case_id='${rpt_id}' WITH $rpt_code INSTEAD OF THE REFUSAL AN EXISTING CASE GETS, SO A SIGNED-IN USER CAN TELL REAL CASE IDS FROM INVENTED ONES"
					fi
				done
			done

			# The other half. The gate must not cost an ordinary user the case
			# printing they already had: this user holds no group flag at all
			# and reads the case only by owning it.
			for rpt_url in "$rpt_print" "$rpt_bill"; do
				if ! rpt_fetch "$ROJAR" "$rpt_url"; then
					bad "the handler's request for ${rpt_url##*/} failed (curl exit $rpt_curl), so the print is unproven"
				elif [ "$rpt_code" = 200 ] && grep -qF "$RSECRET" "$BODY"; then
					ok "${rpt_url##*/} still prints for the case's own handler"
				else
					bad "${rpt_url##*/} no longer prints for the case's own handler (status $rpt_code)"
				fi
			done

			# Each form has two routes and the checks above take one each: the
			# billing form directly, the print form through the dispatcher. The
			# other two routes both answered HTTP 500 with an empty body, and no
			# check said so, which is why they stayed broken.
			#
			# compen_bill-form.php did chdir('../../'). That is right for a direct
			# request, where the working directory is the form's own directory, and
			# one level too far when legacy_report.php includes the form with the
			# working directory already cms/. The include_path pika_init() writes is
			# relative to cms/, so from one level up the form's own require of
			# pika-danio.php found nothing.
			rpt_url="$OCM_URL/legacy_report.php?report=compen_bill&case_id=${RCASE}"
			if ! rpt_fetch "$ROJAR" "$rpt_url"; then
				bad "the handler's request for legacy_report.php?report=compen_bill failed (curl exit $rpt_curl)"
			elif [ "$rpt_code" = 200 ] && grep -qF "$RSECRET" "$BODY"; then
				ok "legacy_report.php prints the billing form for the case's own handler"
			else
				bad "legacy_report.php?report=compen_bill ANSWERED THE CASE'S OWN HANDLER $rpt_code, NOT THE BILLING FORM"
			fi

			# The same route still has to refuse a reader who may not read the
			# case. That 403 comes from the dispatcher's own gate, not the form's:
			# reverting the form to prove the check above showed the reader still
			# refused 403 while the handler got the 500. So this holds the
			# dispatcher's gate in place on the route the chdir fix touched.
			if ! rpt_fetch "$RJAR" "$rpt_url"; then
				bad "the reader's request for legacy_report.php?report=compen_bill failed (curl exit $rpt_curl)"
			elif grep -qF "$RSECRET" "$BODY"; then
				bad "legacy_report.php?report=compen_bill GAVE THE READER THE CLIENT NAME ON A CASE THEY MAY NOT READ"
			elif [ "$rpt_code" = 403 ]; then
				ok "legacy_report.php?report=compen_bill refuses the reader 403"
			else
				bad "legacy_report.php?report=compen_bill answered the reader $rpt_code, not 403"
			fi

			# case_print-form.php is included, never requested: it calls
			# pl_table_array(), which pika_cms.php loads and pika_init() alone does
			# not. Requested directly it reached its own relative include, missed
			# pl_report.php, then called pl_grab_var() before anything had defined
			# it, and answered 500 with an empty body from a URL that is served
			# because the file sits under the document root. It answers 404 now.
			#
			# Both users are asked, because a refusal that depends on who asks
			# would be a gate, and this is not one: the file is not a page. The
			# client name must not appear whatever the status is.
			for rpt_who in "handler:$ROJAR" "reader:$RJAR"; do
				rpt_url="$OCM_URL/reports/case_print/case_print-form.php?case_id=${RCASE}"
				if ! rpt_fetch "${rpt_who#*:}" "$rpt_url"; then
					bad "the ${rpt_who%%:*}'s direct request for case_print-form.php failed (curl exit $rpt_curl)"
				elif grep -qF "$RSECRET" "$BODY"; then
					bad "A DIRECT REQUEST FOR case_print-form.php PRINTED THE CLIENT NAME TO THE ${rpt_who%%:*}"
				elif [ "$rpt_code" = 404 ]; then
					ok "a direct request for case_print-form.php answers the ${rpt_who%%:*} 404"
				else
					bad "a direct request for case_print-form.php answered the ${rpt_who%%:*} $rpt_code, not the 404 a file that is not a page should give"
				fi
			done
		fi
	fi

	cleanup_rpt
	trap 'rm -f "$COOKIES" "$BODY"' EXIT
fi

# 85. The pop-up timer gates on read access to the case, and on edit access
# before it writes a time slip onto it.
#
# cms/timer.php had no authorization call at all. It takes case_id off the query
# string, hands it to the case_menu plugin and to pikaCase, and prints the case
# number and the client's name, so any signed-in user read a case that case.php
# refuses them. Ending the timer is a write and was ungated too: that branch
# builds an Activity out of the same query string and saves it against the case,
# so the same user could file a time slip on any case id. Measured before the
# gate: a user whose group grants no case access got HTTP 200 with the number
# and the client's surname, and an activity row landed on the case.
#
# Three users, because the two halves need different answers from the same
# fixture. The reader is refused outright. The viewer may read every case and
# edit none, so the timer opens for them and only the end branch is refused --
# read access is not a licence to write. The case's own handler keeps both.
#
# The "(No Case #)" timer is checked as well: a gate that refused a timer naming
# no case would be a regression, not a fix.
if [ "$HAVE_DB" = 1 ] && [ "$HAVE_COMPOSE" = 1 ]; then
	TMG='zz_tmr_none'
	TMRG='zz_tmr_read'
	TMRD='zz_tmr_reader'
	TMVW='zz_tmr_viewer'
	TMOW='zz_tmr_owner'
	TMPWD='zz-tmr-Passw0rd'
	TMSECRET='ZZTMRSECRETCLIENT'
	TMNUM='ZZ-TMR-1'
	TMJAR="$(mktemp)"
	TMVJAR="$(mktemp)"
	TMOJAR="$(mktemp)"

	cleanup_tmr() {
		# The activities go first: they are what the end branch writes, and a
		# leftover row would be counted by the next run as a leak.
		if [ -n "${TMCASE:-}" ]; then
			adb "DELETE FROM activities WHERE case_id = ${TMCASE}" >/dev/null
		fi
		# Session ids are read into the shell, not compared between the two
		# tables in SQL: csrf_tokens.session_id is utf8mb4_unicode_ci and
		# user_sessions.session_id takes the database default, so joining them
		# answers "Illegal mix of collations" -- which adb sends to /dev/null,
		# leaving a DELETE that removes nothing and says nothing.
		tmr_uids="$(adb "SELECT user_id FROM users
			WHERE username IN ('${TMRD}', '${TMVW}', '${TMOW}')" | paste -sd, -)"
		tmr_sids=''
		if [ -n "$tmr_uids" ]; then
			tmr_sids="$(adb "SELECT CONCAT(CHAR(39), session_id, CHAR(39)) FROM user_sessions
				WHERE user_id IN (${tmr_uids})" | paste -sd, -)"
		fi
		if [ -n "$tmr_sids" ]; then
			adb "DELETE FROM csrf_tokens WHERE session_id IN (${tmr_sids})" >/dev/null
		fi
		if [ -n "$tmr_uids" ]; then
			adb "DELETE FROM user_sessions WHERE user_id IN (${tmr_uids})" >/dev/null
		fi
		adb "DELETE FROM cases WHERE number = '${TMNUM}'" >/dev/null
		adb "DELETE FROM contacts WHERE last_name = '${TMSECRET}'" >/dev/null
		adb "DELETE FROM users WHERE username IN ('${TMRD}', '${TMVW}', '${TMOW}')" >/dev/null
		adb "DELETE FROM \`groups\` WHERE group_id IN ('${TMG}', '${TMRG}')" >/dev/null

		# A DELETE that failed has to be said out loud, or this run reports a
		# clean finish and the next one measures a dirty database. The login
		# rows in audit_log are kept on purpose and are not counted.
		tmr_left="$(adb "SELECT COUNT(*) FROM users WHERE username IN ('${TMRD}', '${TMVW}', '${TMOW}')")"
		tmr_left="${tmr_left}$(adb "SELECT COUNT(*) FROM cases WHERE number = '${TMNUM}'")"
		tmr_left="${tmr_left}$(adb "SELECT COUNT(*) FROM contacts WHERE last_name = '${TMSECRET}'")"
		tmr_left="${tmr_left}$(adb "SELECT COUNT(*) FROM \`groups\` WHERE group_id IN ('${TMG}', '${TMRG}')")"
		if [ -n "$tmr_uids" ]; then
			tmr_left="${tmr_left}$(adb "SELECT COUNT(*) FROM user_sessions
				WHERE user_id IN (${tmr_uids})")"
		else
			tmr_left="${tmr_left}0"
		fi
		if [ -n "$tmr_sids" ]; then
			tmr_left="${tmr_left}$(adb "SELECT COUNT(*) FROM csrf_tokens
				WHERE session_id IN (${tmr_sids})")"
		else
			tmr_left="${tmr_left}0"
		fi
		if [ "$tmr_left" != 000000 ]; then
			bad "the timer fixture could not be removed (users, case, contact, groups, sessions, csrf rows still present: ${tmr_left})"
		fi
		rm -f "$TMJAR" "$TMVJAR" "$TMOJAR"
	}

	# curl's own exit status is checked on every request: a request that timed
	# out after the expected words had arrived would otherwise read as a
	# refusal. $BODY is emptied first, because a stale body left by the
	# previous request would read as one too.
	tmr_fetch() {
		: > "$BODY"
		tmr_code="$(curl -s --max-time 60 -b "$1" -o "$BODY" -w '%{http_code}' "$2")"
		tmr_curl=$?
		[ "$tmr_curl" = 0 ]
	}

	tmr_login() {
		: > "$1"
		: > "$BODY"
		tmr_code="$(curl -sL --max-time 30 -c "$1" -b "$1" -o "$BODY" -w '%{http_code}' \
			-X POST -d "login_user=${2}&login_pass=${TMPWD}&auth_id=1" "$OCM_URL/")"
		tmr_curl=$?
		[ "$tmr_curl" = 0 ] && [ "$tmr_code" = 200 ] && [ -s "$BODY" ] \
			&& ! grep -q 'login_pass' "$BODY"
	}

	# How many activities sit on the fixture case. The end branch writing one is
	# the leak itself on the write side, not a proxy for it.
	tmr_acts() {
		adb "SELECT COUNT(*) FROM activities WHERE case_id = ${TMCASE}"
	}

	TMCASE=''
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_tmr' EXIT
	cleanup_tmr

	# One group with every flag off, and one that may read every case and edit
	# none. read_all without edit_all is the shape that separates the two gates.
	adb "INSERT INTO \`groups\` (group_id, read_office, read_all, edit_office, edit_all, users, pba, motd, intake, reports)
		VALUES ('${TMG}', NULL, 0, NULL, 0, 0, 0, 0, 0, NULL)" >/dev/null
	adb "INSERT INTO \`groups\` (group_id, read_office, read_all, edit_office, edit_all, users, pba, motd, intake, reports)
		VALUES ('${TMRG}', NULL, 1, NULL, 0, 0, 0, 0, 0, NULL)" >/dev/null

	TMHASH="$(docker compose "${COMPOSE_ARGS[@]}" exec -T app \
		php -r 'echo password_hash($argv[1], PASSWORD_DEFAULT);' "$TMPWD" </dev/null 2>/dev/null)"
	TMRUID="$(adb "SELECT COALESCE(MAX(user_id), 0) + 1 FROM users")"
	adb "INSERT INTO users (user_id, username, password, enabled, group_id, password_expire)
		VALUES (${TMRUID}, '${TMRD}', '${TMHASH}', 1, '${TMG}', 0)" >/dev/null
	TMVUID="$(adb "SELECT COALESCE(MAX(user_id), 0) + 1 FROM users")"
	adb "INSERT INTO users (user_id, username, password, enabled, group_id, password_expire)
		VALUES (${TMVUID}, '${TMVW}', '${TMHASH}', 1, '${TMRG}', 0)" >/dev/null
	TMOUID="$(adb "SELECT COALESCE(MAX(user_id), 0) + 1 FROM users")"
	adb "INSERT INTO users (user_id, username, password, enabled, group_id, password_expire)
		VALUES (${TMOUID}, '${TMOW}', '${TMHASH}', 1, '${TMG}', 0)" >/dev/null

	# The client's surname is a marker: the case menu prints it, so finding it in
	# a response is the read leak itself. cases.office is char(3) -- a longer
	# value is silently truncated on the shipped non-strict database and rejected
	# under strict SQL mode, where the failed insert would take the positive
	# controls down with it.
	TMCID="$(adb "SELECT COALESCE(MAX(contact_id), 0) + 1 FROM contacts")"
	adb "INSERT INTO contacts (contact_id, first_name, last_name)
		VALUES (${TMCID}, 'Zz', '${TMSECRET}')" >/dev/null
	TMCASE="$(adb "SELECT COALESCE(MAX(case_id), 0) + 1 FROM cases")"
	adb "INSERT INTO cases (case_id, number, client_id, user_id, office, open_date, status, problem)
		VALUES (${TMCASE}, '${TMNUM}', ${TMCID}, ${TMOUID}, 'ZZO', CURDATE(), 'O', '01')" >/dev/null

	tmr_case="$OCM_URL/timer.php?case_id=${TMCASE}"
	tmr_end="${tmr_case}&end=1&elapsed_mins=60&act_type=C"

	if [ -z "$TMHASH" ] || [ -z "${TMCASE:-}" ] || [ -z "${TMCID:-}" ] \
		|| [ "$(adb "SELECT COUNT(*) FROM cases WHERE case_id = ${TMCASE} AND number = '${TMNUM}'")" != 1 ]; then
		bad "could not seed the timer authorization fixture"
	else
		# Positive control. adb hides stderr, so a fixture insert that failed is
		# silent; if the admin cannot see the marker then every refusal below
		# would pass on a page that never had anything to leak.
		if ! tmr_fetch "$COOKIES" "$tmr_case"; then
			bad "the admin's request for timer.php failed (curl exit $tmr_curl) - section 85 proves nothing"
		elif [ "$tmr_code" = 200 ] && grep -qF "$TMSECRET" "$BODY" && grep -qF "$TMNUM" "$BODY"; then
			ok "the admin sees the case number and the client name in timer.php (status 200)"
		else
			bad "the admin got $tmr_code from timer.php without the case fixture in it - section 85 proves nothing"
		fi

		# Each login is checked on its own. A user who could not log in would
		# otherwise be refused for want of a session and filed as the gate working.
		if ! tmr_login "$TMJAR" "$TMRD"; then
			bad "the timer reader could not log in (curl exit $tmr_curl, status $tmr_code) - section 85 is untested"
		elif ! tmr_login "$TMVJAR" "$TMVW"; then
			bad "the read-only timer user could not log in (curl exit $tmr_curl, status $tmr_code) - section 85 is untested"
		elif ! tmr_login "$TMOJAR" "$TMOW"; then
			bad "the case's own handler could not log in (curl exit $tmr_curl, status $tmr_code) - section 85 is untested"
		else
			ok "all three throwaway timer users can log in"

			# Control on the fixture: the case page itself refuses the reader.
			# Everything below is the timer reaching the same answer, so if
			# case.php lets this user in there is nothing to say.
			if ! tmr_fetch "$TMJAR" "$OCM_URL/case.php?case_id=${TMCASE}"; then
				bad "the reader's request for case.php failed (curl exit $tmr_curl) - section 85 proves nothing"
			elif [ "$tmr_code" = 403 ] && grep -q 'This case is not viewable' "$BODY"; then
				ok "the fixture case is refused to the reader on case.php (status 403)"
			else
				bad "case.php answered the reader $tmr_code, not the refusal - section 85 proves nothing"
			fi

			if ! tmr_fetch "$TMJAR" "$tmr_case"; then
				bad "the reader's request for timer.php failed (curl exit $tmr_curl), so the refusal is unproven"
			elif grep -qF "$TMSECRET" "$BODY" || grep -qF "$TMNUM" "$BODY"; then
				bad "timer.php PRINTED CASE ${TMNUM} AND ITS CLIENT TO A USER WHO CANNOT READ THE CASE"
			elif [ "$tmr_code" != 403 ]; then
				bad "timer.php hid the case from the reader but answered $tmr_code, not 403"
			elif grep -q 'This case is not viewable' "$BODY"; then
				ok "timer.php refuses a user who cannot read the case"
			else
				bad "timer.php answered 403 without saying why"
			fi

			# An id that names no case, and an id that is not a case id at all,
			# have to answer the same way as a case the reader may not read.
			# Before the gate both printed the generic error page at HTTP 200,
			# which both lost the refusal and told the caller the id was unused.
			for tmr_id in 99999999 abc; do
				if ! tmr_fetch "$TMJAR" "$OCM_URL/timer.php?case_id=${tmr_id}"; then
					bad "the reader's request for timer.php?case_id=${tmr_id} failed (curl exit $tmr_curl)"
				elif [ "$tmr_code" = 403 ] && grep -q 'This case is not viewable' "$BODY"; then
					ok "timer.php answers case_id='${tmr_id}' the same refusal an existing case gets"
				else
					bad "timer.php ANSWERED case_id='${tmr_id}' WITH $tmr_code INSTEAD OF THE REFUSAL AN EXISTING CASE GETS, SO A SIGNED-IN USER CAN TELL REAL CASE IDS FROM INVENTED ONES"
				fi
			done

			# A timer naming no case at all is a supported path and has nothing
			# to authorize.
			if ! tmr_fetch "$TMJAR" "$OCM_URL/timer.php"; then
				bad "the reader's request for a timer with no case failed (curl exit $tmr_curl)"
			elif [ "$tmr_code" = 200 ] && grep -qF '(No Case #)' "$BODY"; then
				ok "a timer naming no case still opens for a user with no case access"
			else
				bad "timer.php answered a request naming no case $tmr_code, so the gate took the (No Case #) timer away"
			fi

			# The write half. The viewer may read every case, so the timer opens
			# and prints the number; ending it writes an Activity onto a case
			# they may not edit, and that is what has to be refused.
			if ! tmr_fetch "$TMVJAR" "$tmr_case"; then
				bad "the read-only user's request for timer.php failed (curl exit $tmr_curl)"
			elif [ "$tmr_code" = 200 ] && grep -qF "$TMNUM" "$BODY"; then
				ok "timer.php still opens for a user who may read the case but not edit it"
			else
				bad "timer.php answered a user who may read the case $tmr_code, so the gate refused a reader it should allow"
			fi

			tmr_before="$(tmr_acts)"

			for tmr_pair in "$TMVJAR:a user who may read the case but not edit it" \
				"$TMJAR:a user who cannot read the case"; do
				tmr_jar="${tmr_pair%%:*}"
				tmr_who="${tmr_pair#*:}"

				if ! tmr_fetch "$tmr_jar" "$tmr_end"; then
					bad "the end-timer request by ${tmr_who} failed (curl exit $tmr_curl)"
				elif [ "$tmr_code" = 403 ] && grep -q 'This case is not viewable' "$BODY"; then
					ok "ending a timer on the case is refused to ${tmr_who}"
				else
					bad "timer.php answered the end-timer request by ${tmr_who} ${tmr_code} instead of the refusal"
				fi

				if [ "$(tmr_acts)" != "$tmr_before" ]; then
					bad "ENDING A TIMER WROTE AN ACTIVITY ONTO CASE ${TMNUM} FOR ${tmr_who}"
				else
					ok "no activity was written onto the case for ${tmr_who}"
				fi
			done

			# The other half of the write gate: the case's own handler keeps the
			# time slip. Without this the two refusals above would also pass on
			# a timer that had stopped saving for everyone.
			#
			# Counted from the row count immediately before this request, not
			# from the one taken before the loop: if a refusal above had let a
			# write through, this check would then be measuring that write and
			# would report the handler's own slip as missing.
			tmr_before_own="$(tmr_acts)"

			if ! tmr_fetch "$TMOJAR" "$tmr_end"; then
				bad "the handler's end-timer request failed (curl exit $tmr_curl), so the write is unproven"
			elif [ "$tmr_code" != 200 ]; then
				bad "the case's own handler got $tmr_code ending a timer on their own case"
			elif [ "$(tmr_acts)" = "$((tmr_before_own + 1))" ]; then
				ok "the case's own handler still files a time slip on the case"
			else
				bad "the case's own handler ended a timer and no activity was written (was ${tmr_before_own}, now $(tmr_acts))"
			fi
		fi
	fi

	cleanup_tmr
	trap 'rm -f "$COOKIES" "$BODY"' EXIT
else
	printf '  skip the timer authorization checks (needs the database and the container)\n'
fi

# 86. A report the caller may not run answers the refusal page, not a fatal.
#
# cms/reports/lsc_gap/report.php built its refusal page with pikaTempLib and
# never required the file that declares the class, so the refusal branch died
# with "Class pikaTempLib not found" and the user got HTTP 500 with no page.
# Measured on the unpatched file with the user below: 500 and no refusal text,
# while reports/lsc_gap/index.php and reports/red_flag/report.php, which have
# the require, both answered the refusal.
#
# Every reports/*/report.php is swept, not just the one that was broken. The
# fault is a missing require in a file that is a copy of its siblings, and
# nothing stops the next copy leaving it out again.
#
# pika_report_authorize() returns true for the system group, so the user here
# cannot be an administrator. It also denies by default: a group whose reports
# column is NULL may run none of them.
if [ "$HAVE_DB" = 1 ]; then
	QGROUP='zz_rq_grp'
	QREADER='zz_rq_reader'
	QPWD='zz-rq-Passw0rd'
	QJAR="$(mktemp)"

	cleanup_rq() {
		# user_sessions has no cascading key on user_id and csrf_tokens holds the
		# row login wrote, keyed by session id. The ids are read into the shell
		# because the two session_id columns take different collations and
		# comparing them in SQL answers "Illegal mix of collations", which adb
		# would swallow.
		rq_sids="$(adb "SELECT CONCAT(CHAR(39), session_id, CHAR(39)) FROM user_sessions
			WHERE user_id IN (SELECT user_id FROM users WHERE username = '${QREADER}')" \
			| paste -sd, -)"
		if [ -n "$rq_sids" ]; then
			adb "DELETE FROM csrf_tokens WHERE session_id IN (${rq_sids})" >/dev/null
		fi
		adb "DELETE FROM user_sessions WHERE user_id IN
			(SELECT user_id FROM users WHERE username = '${QREADER}')" >/dev/null
		adb "DELETE FROM users WHERE username = '${QREADER}'" >/dev/null
		adb "DELETE FROM \`groups\` WHERE group_id = '${QGROUP}'" >/dev/null
		rq_left="$(adb "SELECT COUNT(*) FROM users WHERE username = '${QREADER}'")"
		rq_left="${rq_left}$(adb "SELECT COUNT(*) FROM \`groups\` WHERE group_id = '${QGROUP}'")"
		if [ -n "$rq_sids" ]; then
			rq_left="${rq_left}$(adb "SELECT COUNT(*) FROM csrf_tokens
				WHERE session_id IN (${rq_sids})")"
		else
			rq_left="${rq_left}0"
		fi
		if [ "$rq_left" != 000 ]; then
			bad "the report refusal fixture could not be removed (user, group, csrf rows still present: ${rq_left})"
		fi
		rm -f "$QJAR"
	}
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_rq' EXIT
	cleanup_rq

	adb "INSERT INTO \`groups\` (group_id, read_office, read_all, edit_office, edit_all, users, pba, motd, intake, reports)
		VALUES ('${QGROUP}', NULL, 0, NULL, 0, 0, 0, 0, 0, NULL)" >/dev/null
	QHASH="$(docker compose "${COMPOSE_ARGS[@]}" exec -T app \
		php -r 'echo password_hash($argv[1], PASSWORD_DEFAULT);' "$QPWD" </dev/null 2>/dev/null)"
	QUID="$(adb "SELECT COALESCE(MAX(user_id), 0) + 1 FROM users")"
	adb "INSERT INTO users (user_id, username, password, enabled, group_id, password_expire)
		VALUES (${QUID}, '${QREADER}', '${QHASH}', 1, '${QGROUP}', 0)" >/dev/null

	rq_fetch() {
		: > "$BODY"
		rq_code="$(curl -s --max-time 60 -b "$QJAR" -o "$BODY" -w '%{http_code}' "$OCM_URL/$1")"
		rq_curl=$?
		[ "$rq_curl" = 0 ]
	}

	: > "$QJAR"
	: > "$BODY"
	rq_code="$(curl -sL --max-time 30 -c "$QJAR" -b "$QJAR" -o "$BODY" -w '%{http_code}' \
		-X POST -d "login_user=${QREADER}&login_pass=${QPWD}&auth_id=1" "$OCM_URL/")"
	rq_curl=$?

	QREPORTS="$(find cms/reports -mindepth 2 -maxdepth 2 -name 'report.php' 2>/dev/null | sort)"

	if [ -z "$QHASH" ] || [ -z "$QUID" ]; then
		bad "could not seed the report refusal fixture"
	elif [ "$rq_curl" != 0 ] || [ "$rq_code" != 200 ] || grep -q 'login_pass' "$BODY"; then
		bad "the throwaway report reader could not log in (status ${rq_code}, curl ${rq_curl})"
	elif [ -z "$QREPORTS" ]; then
		bad "NO reports/*/report.php WAS FOUND, SO SECTION 85 DID NOT RUN"
	else
		ok "the throwaway report reader can log in and may run no report"

		# The refusal has to be recognisable before the sweep can rely on it.
		if ! rq_fetch 'reports/red_flag/report.php'; then
			bad "the reader's request for the control report failed (curl exit $rq_curl)"
		elif grep -qF 'not authorized to run this report' "$BODY"; then
			ok "a report entry point that has the require prints the refusal"
		else
			bad "THE CONTROL REPORT DID NOT PRINT THE REFUSAL (status ${rq_code}), SO THE SWEEP BELOW PROVES NOTHING"
		fi

		rq_bad=''
		rq_seen=0
		for rq_file in $QREPORTS; do
			rq_seen=$((rq_seen + 1))
			rq_path="${rq_file#cms/}"
			if ! rq_fetch "$rq_path"; then
				rq_bad="${rq_bad} ${rq_path}(curl ${rq_curl})"
			elif ! grep -qF 'not authorized to run this report' "$BODY"; then
				rq_bad="${rq_bad} ${rq_path}(${rq_code})"
			fi
		done

		if [ -z "$rq_bad" ]; then
			ok "all ${rq_seen} report entry points print the refusal to a user who may run none"
		else
			bad "A REPORT ANSWERED SOMETHING OTHER THAN THE REFUSAL TO A USER WHO MAY RUN NONE OF THEM:${rq_bad}"
		fi
	fi

	cleanup_rq
	trap 'rm -f "$COOKIES" "$BODY"' EXIT
fi

# 87. The LSC justice gap report sends a spreadsheet when the form asks for one.
#
# The report read pl_grab_post('output_format') into a variable it never used
# again, then chose its output class on $report_format, which nothing assigned.
# The comparison was therefore against a variable that was never set, the CSV
# branch could not be reached, and ticking "Send to a spreadsheet" returned the
# HTML report with no sign that anything had been ignored. Every other report in
# the tree reads report_format, and so does this one's own form.
echo
echo "87. the LSC justice gap report honours the spreadsheet checkbox"

# The report refuses a range with only one end, so both dates are sent. Without
# them the request ends on the error page and every check below would pass or
# fail on that page rather than on the output format.
lg_url="$OCM_URL/reports/lsc_gap/report.php"
lg_dates='open_date_begin=2019-01-01&open_date_end=2026-12-31'

lg_post() {
	: > "$BODY"
	: > "${BODY}.lg"
	lg_code="$(curl -s --max-time 60 -b "$COOKIES" -D "$BODY" -o "${BODY}.lg" \
		-w '%{http_code}' -X POST -d "$1" "$lg_url")"
	lg_curl=$?
	[ "$lg_curl" = 0 ]
}

# Positive control first. If the admin cannot run the report at all then the
# format checks below would be comparing two error pages.
if ! lg_post "$lg_dates"; then
	bad "the admin's request for the LSC gap report failed (curl exit $lg_curl) - section 87 proves nothing"
elif [ "$lg_code" != 200 ]; then
	bad "the admin got $lg_code from the LSC gap report - section 87 proves nothing"
elif ! grep -qF 'Category' "${BODY}.lg"; then
	bad "the LSC gap report did not print its header row - section 87 proves nothing"
else
	ok "the admin can run the LSC gap report (status 200)"

	# The default is unchanged: no checkbox means the HTML report.
	if grep -qiE '^content-type:[[:space:]]*text/html' "$BODY"; then
		ok "the LSC gap report still answers HTML when the checkbox is not ticked"
	else
		bad "the LSC gap report no longer answers HTML by default: $(grep -i '^content-type:' "$BODY" | tr -d '\r')"
	fi

	# The fix. report_format=csv is what the form's checkbox posts.
	if ! lg_post "report_format=csv&${lg_dates}"; then
		bad "the admin's CSV request for the LSC gap report failed (curl exit $lg_curl)"
	elif ! grep -qiE '^content-type:[[:space:]]*text/x-comma-separated-values' "$BODY"; then
		bad "THE LSC GAP REPORT IGNORED report_format=csv AND ANSWERED $(grep -i '^content-type:' "$BODY" | tr -d '\r')"
	elif ! grep -qiE '^content-disposition:[[:space:]]*(attachment|inline);' "$BODY"; then
		bad "the LSC gap report sent CSV with no Content-Disposition, so it has no filename"
	elif grep -qi '<html' "${BODY}.lg"; then
		bad "the LSC gap report sent a CSV content type with an HTML body"
	elif grep -qF 'Category' "${BODY}.lg"; then
		ok "the LSC gap report sends a CSV spreadsheet when report_format=csv is posted"
	else
		bad "the LSC gap report sent CSV headers with no header row in the body"
	fi

	# The name the report used to read. It is not a field this form has, so it
	# must not be a second way to ask for the spreadsheet.
	if ! lg_post "output_format=csv&${lg_dates}"; then
		bad "the admin's output_format request for the LSC gap report failed (curl exit $lg_curl)"
	elif grep -qiE '^content-type:[[:space:]]*text/html' "$BODY"; then
		ok "output_format=csv is not a second name for the checkbox"
	else
		bad "the LSC gap report answered output_format=csv with $(grep -i '^content-type:' "$BODY" | tr -d '\r')"
	fi
fi

rm -f "${BODY}.lg"
# 90. A filter box the report never reads.
#
# The time report's Case Number box posts number, and lsac_outcome's Closing
# Code(s) box posts close_code. Both handlers build a SQL clause from that
# field, and neither read it, so the variable was never set, the clause was
# never added, and the report came back unfiltered with nothing to say the box
# had been ignored. Same shape as the lsc_gap report reading the wrong name.
echo
echo "90. report filter boxes reach the SQL"

tf_url="$OCM_URL/reports/time/report.php"
tf_dates='date_start=01/01/2000&date_end=12/31/2030&show_sql=1'

tf_post() {
	: > "$BODY"
	tf_code="$(curl -s --max-time 60 -b "$COOKIES" -o "$BODY" -w '%{http_code}' \
		-X POST -d "$1" "$tf_url")"
	tf_curl=$?
	[ "$tf_curl" = 0 ]
}

# show_sql renders the statement the report ran, so the clause is either in it
# or it is not. Check that the statement is on the page before reading it, or
# every check below would pass on a page with no SQL to look at.
if ! tf_post "$tf_dates"; then
	bad "the admin's request for the time report failed (curl exit $tf_curl) - section 90 proves nothing"
elif [ "$tf_code" != 200 ]; then
	bad "the admin got $tf_code from the time report - section 90 proves nothing"
elif ! grep -qF 'SELECT act_date' "$BODY"; then
	bad "the time report did not print the SQL it ran - section 90 proves nothing"
else
	ok "the time report prints the SQL it ran (status 200)"

	# An empty box must add nothing. The form posts number on every submission,
	# so this is the ordinary case and it has to stay unfiltered.
	if grep -qF 'AND number=' "$BODY"; then
		bad "the time report filtered on a case number that was never posted"
	else
		ok "the time report adds no case-number clause when the box is empty"
	fi

	# Second positive control: the funding box already worked, so its clause
	# proves this probe can see a filter reach the SQL at all.
	if ! tf_post "${tf_dates}&funding=ZZ-SMOKE-FUND"; then
		bad "the admin's funding request for the time report failed (curl exit $tf_curl)"
	elif grep -qF 'activities.funding=' "$BODY" && grep -qF 'ZZ-SMOKE-FUND' "$BODY"; then
		ok "the time report's funding box reaches the SQL, so a filter is visible here"
	else
		bad "the time report's funding box did not reach the SQL - section 90 proves nothing"
	fi

	# The fix. The clause has to be in the statement and the report has to name
	# the parameter it applied; the value alone would also appear in the
	# parameter line, so it is not proof on its own.
	if ! tf_post "${tf_dates}&number=ZZ-SMOKE-CASE"; then
		bad "the admin's case-number request for the time report failed (curl exit $tf_curl)"
	elif ! grep -qF 'AND number=' "$BODY"; then
		bad "THE TIME REPORT IGNORED ITS CASE NUMBER BOX: no clause for it in the SQL it ran"
	elif ! grep -qF 'ZZ-SMOKE-CASE' "$BODY"; then
		bad "the time report added a case-number clause without the number that was posted"
	elif grep -qF 'Case Number' "$BODY"; then
		ok "the time report's Case Number box reaches the SQL and is named as a parameter"
	else
		bad "the time report filtered on the case number without listing it as a parameter"
	fi
fi

# lsac_outcome has the same defect and cannot be shown the same way. Every
# figure in it comes from an lsac_* `cases` column that no install or upgrade
# script creates, so on the database this project installs the report stops at
# its schema guard - section 8e2 - before it reaches any filter, and its
# working boxes cannot be demonstrated either. So the read itself is asserted.
if grep -qF "pl_grab_post('close_code')" \
	"${REPO_DIR}/cms/reports/lsac_outcome/report.php"; then
	ok "lsac_outcome reads the close_code its form posts"
else
	bad "LSAC_OUTCOME BUILDS 'AND close_code IN' FROM A FIELD IT NEVER READS"
fi

# 91. The include fragments answer nothing when they are asked for directly.
#
# cms/modules/ and cms/template_plugins/ are include fragments. They carry no
# bootstrap require and no authorization of their own, because the page that
# includes them has already done both. Every one of them is nonetheless a file
# under the docroot, so any request can ask for it by name, and it then runs
# with none of the variables its including page was going to set - $case_id
# among them.
#
# Measured on a stock install, all of them answer an empty body: the plugins
# only define functions, and the case modules die on the first call to a
# framework function that was never loaded. Nothing is exposed. This section
# holds that still. What it is watching for is a fragment that grows top-level
# code which draws something before it dies, because such a fragment would
# print it to whoever asked - signed in or not, and with no case check in
# front of it. That is the shape of the extension-include hole in cms/pm.php.
echo
echo "91. the include fragments give nothing away when asked for directly"

fr_list="$(cd "${REPO_DIR}/cms" 2>/dev/null && ls modules/*.php template_plugins/*.php 2>/dev/null)"
fr_count="$(printf '%s\n' "$fr_list" | grep -c '\.php$')"

# Count the files first. A path typo or a moved directory would leave the loop
# with nothing to do, and every check below would pass on an empty list.
if [ "${fr_count:-0}" -lt 40 ]; then
	bad "section 91 found only ${fr_count} include fragments - the sweep is broken"
else
	ok "section 91 found ${fr_count} include fragments to ask for"

	fr_body=""
	fr_leak=""
	for fr in $fr_list; do
		# Anonymous, then signed in as the admin. A fragment that draws
		# anything would draw it for at least one of the two.
		for fr_cookie in "" "$COOKIES"; do
			if [ -n "$fr_cookie" ]; then
				curl -s --max-time 20 -b "$fr_cookie" -o "$BODY" \
					"$OCM_URL/$fr" >/dev/null 2>&1
			else
				curl -s --max-time 20 -o "$BODY" \
					"$OCM_URL/$fr" >/dev/null 2>&1
			fi
			if [ -s "$BODY" ]; then
				fr_body="${fr_body} ${fr}"
			fi
			# display_errors is off on a correct install, so a path in the
			# body means the server is describing its own filesystem.
			if grep -qE '/var/www/html|Fatal error|Uncaught' "$BODY"; then
				fr_leak="${fr_leak} ${fr}"
			fi
		done
	done

	if [ -z "$fr_body" ]; then
		ok "every include fragment answers an empty body, signed in or not"
	else
		bad "AN INCLUDE FRAGMENT DREW SOMETHING WHEN ASKED FOR DIRECTLY, WITH NO PAGE AND NO CASE CHECK IN FRONT OF IT:${fr_body}"
	fi

	if [ -z "$fr_leak" ]; then
		ok "no include fragment prints a filesystem path or a PHP error"
	else
		bad "AN INCLUDE FRAGMENT PRINTED A PHP ERROR OR A FILESYSTEM PATH:${fr_leak}"
	fi
fi

# 92. Every filter box on a report form reaches the report that runs it.
#
# Three bugs in a row were the same shape: a report form offers a box, the
# handler builds a clause from a variable of that name, and nothing ever reads
# the posted field, so the variable stays unset and the box silently does
# nothing. The lsc_gap report read the wrong name, the time report never read
# number, and lsac_outcome never read close_code. A request cannot show this
# for the reports whose figures need columns no install script creates, so the
# check is static: for every report, take the controls inside the form that
# posts to report.php and require that report.php reads each one by name.
#
# Only the form aimed at report.php counts. megareport and megapartyreport also
# carry a second form that posts to ops/upload_document.php, and its fields are
# read there, not by the report.
echo
echo "92. report forms post nothing the report ignores"

if ! command -v python3 >/dev/null 2>&1; then
	printf '  skip the report control check (needs python3)\n'
else
	RC_PY="$(mktemp)"
	cat > "$RC_PY" <<'RCPY'
import io, os, re, sys

root = os.path.join(sys.argv[1], 'cms', 'reports')
htmlc = re.compile(r'<!--.*?-->', re.S)
blockc = re.compile(r'/\*.*?\*/', re.S)
# the form that submits to the report, up to its close tag
form = re.compile(r'<\s*form\b[^>]*\baction\s*=\s*["\'][^"\']*report\.php[^"\']*["\']'
                  r'(.*?)(?:</\s*form\s*>|\Z)', re.I | re.S)
control = re.compile(r'<\s*(?:input|select|textarea|button)\b([^>]*)>', re.I | re.S)
nameattr = re.compile(r'\bname\s*=\s*["\']([A-Za-z_][\w\-]*)(?:\[\])?["\']', re.I)
tag = re.compile(r'%%\[([A-Za-z_][\w\-]*),([A-Za-z_][\w\-\.]*)')
read = re.compile(r'pl_grab_\w+\s*\(\s*["\']([\w\-]+)["\']'
                  r'|\$_(?:POST|GET|REQUEST)\s*\[\s*["\']([\w\-]+)["\']')
# A submit button posts nothing a report reads. Nor does a widget that renders
# a link, a table or a set of controls it names itself: file_list draws a table
# of document links, and field_list uses its tag name only to pick which table
# to describe, then emits a checkbox per column called cases.<column>. In both
# the tag name never reaches the request.
skip = set('gen submit reset button action csrf_token pl_csrf_token'.split())
display = set('javascript css parse file_list field_list'.split())

seen = 0
for d in sorted(os.listdir(root)):
    f = os.path.join(root, d, 'form.html')
    r = os.path.join(root, d, 'report.php')
    if not (os.path.isfile(f) and os.path.isfile(r)):
        continue
    body = htmlc.sub(' ', io.open(f, encoding='utf-8', errors='replace').read())
    php = blockc.sub(' ', io.open(r, encoding='utf-8', errors='replace').read())
    names = set()
    for blk in form.findall(body):
        for m in control.finditer(blk):
            n = nameattr.search(m.group(1))
            # a disabled control posts nothing
            if n and not re.search(r'\bdisabled\b', m.group(1), re.I):
                names.add(n.group(1))
        for m in tag.finditer(blk):
            if m.group(2) not in display:
                names.add(m.group(1))
    names -= skip
    seen += len(names)
    reads = set(a or b for a, b in read.findall(php))
    missing = sorted(names - reads)
    if missing:
        print('%s\t%s' % (d, ','.join(missing)))
print('TOTAL\t%d' % seen)
RCPY

	rc_dirs="$(ls -d "${REPO_DIR}"/cms/reports/*/ 2>/dev/null | wc -l)"
	rc_out="$(python3 "$RC_PY" "$REPO_DIR" 2>/dev/null)"
	rc_seen="$(printf '%s\n' "$rc_out" | sed -n 's/^TOTAL\t//p')"
	rc_bad="$(printf '%s\n' "$rc_out" | grep -v '^TOTAL' | tr '\n' ' ')"

	# Both counts guard the sweep. A wrong path or a broken pattern would find
	# no reports and no controls, and then the check below would pass without
	# having looked at anything.
	if [ "${rc_dirs:-0}" -lt 30 ]; then
		bad "section 92 found only ${rc_dirs} report directories - the sweep is broken"
	elif [ "${rc_seen:-0}" -lt 100 ]; then
		bad "section 92 read only ${rc_seen} controls off ${rc_dirs} report forms - the sweep is broken"
	else
		ok "section 92 read ${rc_seen} filter controls off ${rc_dirs} report forms"

		if [ -n "$(printf '%s' "$rc_bad" | tr -d ' ')" ]; then
			bad "A REPORT FORM OFFERS A FILTER BOX ITS OWN report.php NEVER READS: ${rc_bad}"
		else
			ok "every report reads every filter box its form posts to it"
		fi
	fi

	rm -f "$RC_PY"
fi

# 93. No service endpoint answers a signed-in request with a server error.
#
# cms/services/pension_issue-server-ajax.php queried menu_pension_sub_issue,
# which no install or upgrade script creates. Every signed-in request to it
# therefore ended on the error page: HTTP 500, ten kilobytes of text/html, to
# a caller that had asked for text/xml. Nothing in the suite had ever asked a
# service endpoint for anything, so a whole layer of the application could not
# answer at all and the suite stayed green. Sections 8e2 and 91 do this for
# pages and for include fragments; this one does it for the service layer.
#
# The check is a bare GET with no parameters. A service that needs parameters
# answers 400, 403 or an empty document, and all of those are fine - the only
# failure is a 5xx, which means the code could not run to the point of
# deciding what to refuse.
#
# services/logout.php is left out on purpose: it marks the session row, and
# every endpoint asked after it would be answering an anonymous caller. That
# is not hypothetical - it happened while this bug was being found, and it
# hid the 500 for a whole sweep. So the session is checked after each
# request, and the body is what says whether it is still alive: this
# application renders the login form with HTTP 200, so the status code cannot
# tell a signed-in page from a signed-out one.
echo
echo "93. every service endpoint answers a signed-in request without a server error"

# The absence of the login form is not on its own proof of a session: an
# empty body and an error page both lack it too. So this asks for the status
# as well, and for the same positive marker section 3 uses after logging in.
sv_alive() {
	sv_live="$(curl -s --max-time 30 -b "$COOKIES" -o "${BODY}.sv" \
		-w '%{http_code}' "$OCM_URL/system-settings.php")"
	[ "$sv_live" = 200 ] \
		&& ! grep -qF 'login_pass' "${BODY}.sv" \
		&& grep -qi 'logout' "${BODY}.sv"
}

sv_list="$(cd "${REPO_DIR}/cms/services" 2>/dev/null && ls *.php 2>/dev/null \
	| grep -v '^logout\.php$')"
sv_count="$(printf '%s\n' "$sv_list" | grep -c .)"

if [ "${sv_count:-0}" -lt 10 ]; then
	bad "section 93 found only ${sv_count} service endpoints - the sweep is broken"
elif ! sv_alive; then
	bad "the admin session was already gone before section 93 started - it proves nothing"
else
	sv_bad=''
	sv_dead=''
	sv_lost=''
	sv_served=0

	for sv in $sv_list; do
		sv_code="$(curl -s --max-time 30 -b "$COOKIES" -o "$BODY" \
			-w '%{http_code}' "$OCM_URL/services/${sv}")"

		# 000 is curl saying it never got a reply at all, which is not a
		# status the application chose. An empty 200 is not a document
		# either, so it must not be counted as one.
		case "$sv_code" in
			000) sv_dead="${sv_dead} ${sv}" ;;
			5*) sv_bad="${sv_bad} ${sv}=${sv_code}" ;;
			200)
				if [ -s "$BODY" ]; then
					sv_served=$((sv_served + 1))
				fi ;;
		esac

		if ! sv_alive; then
			sv_lost="${sv}"
			break
		fi
	done

	# Without this the sweep could have asked every endpoint as a signed-out
	# caller, been handed the login page by all of them, and reported no
	# server errors.
	if [ -n "$sv_lost" ]; then
		bad "the admin session did not survive services/${sv_lost} - section 93 stopped there and proves nothing beyond it"
	elif [ "${sv_served:-0}" -lt 3 ]; then
		bad "only ${sv_served} of ${sv_count} service endpoints served anything - section 93 is not signed in"
	else
		ok "section 93 asked all ${sv_count} service endpoints, ${sv_served} served a document"

		if [ -n "$sv_dead" ]; then
			bad "A SERVICE ENDPOINT NEVER ANSWERED AT ALL:${sv_dead}"
		fi

		if [ -n "$sv_bad" ]; then
			bad "A SERVICE ENDPOINT ANSWERED A SIGNED-IN REQUEST WITH A SERVER ERROR:${sv_bad}"
		else
			ok "no service endpoint answers a signed-in request with a server error"
		fi
	fi
fi

rm -f "${BODY}.sv"

# 94. The pension sub-issue service still sends XML when its menu is absent.
#
# Section 93 above would catch the 500 coming back, but not the shape of the
# reply. The caller parses this as XML, so an empty list has to be a valid
# document with the right content type rather than an empty body or an HTML
# page carrying a 200. Looking for the opening tag is not enough for that: a
# truncated document, a document with the wrong root, and a document that
# still carries rows all contain it. So the body is parsed and its root and
# child count are read.
#
# The table is then created and a row put through the service, because nothing
# else in the suite ever exercises the two escape calls on the way out.
#
# The absence of the menu table is established by an exact name match against
# information_schema, not by SHOW TABLES LIKE: every underscore in the name is
# a LIKE wildcard, so that pattern also matches a table with any character in
# those places and the check would skip itself.
echo
echo "94. the pension sub-issue service answers with XML when its menu table is absent"

ps_url="$OCM_URL/services/pension_issue-server-ajax.php"
ps_exists="SELECT COUNT(*) FROM information_schema.tables
	WHERE table_schema = DATABASE() AND table_name = 'menu_pension_sub_issue'"

if ! command -v adb >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
	printf '  skip the pension sub-issue check (needs the database and python3)\n'
elif ! adb "SELECT 1" >/dev/null 2>&1; then
	bad "section 94 cannot reach the database, so it cannot tell whether the menu table is there"
elif [ "$(adb "$ps_exists")" != 0 ]; then
	printf '  skip the pension sub-issue check (this install has the menu table)\n'
else
	ps_type="$(curl -s --max-time 30 -b "$COOKIES" -o "$BODY" \
		-w '%{http_code} %{content_type}' "$ps_url")"
	ps_code="${ps_type%% *}"
	ps_ctype="${ps_type#* }"

	ps_media="$(printf '%s' "${ps_ctype%%;*}" | tr -d ' ')"

	if [ "$ps_code" != 200 ]; then
		bad "the pension sub-issue service answered ${ps_code} with its menu table absent"
	else
		if [ "$ps_media" = 'text/xml' ]; then
			ok "the pension sub-issue service answers text/xml with its menu table absent"
		else
			bad "the pension sub-issue service answered ${ps_media}, not text/xml, with its menu table absent"
		fi

		# An empty body, a truncated document and a document with the wrong
		# root all carry a 200 the caller cannot use.
		ps_shape="$(python3 - "$BODY" <<'PY'
import sys
import xml.etree.ElementTree as ET

try:
	root = ET.parse(sys.argv[1]).getroot()
except Exception as exc:
	print('does not parse as XML: %s' % exc)
else:
	print('%s with %d children' % (root.tag, len(list(root))))
PY
)"
		if [ "$ps_shape" = 'pension_issues with 0 children' ]; then
			ok "the empty reply parses as XML and is an empty pension_issues document"
		else
			bad "the empty reply is not an empty pension_issues document: ${ps_shape}"
		fi
	fi

	# Put a row through the service. An ampersand and an angle bracket in the
	# label are the case that matters: createElement() does not escape its
	# value argument, so an unescaped label of this shape writes a document
	# the caller cannot parse.
	adb "CREATE TABLE menu_pension_sub_issue (
		value varchar(8) NOT NULL DEFAULT '',
		label varchar(64) NOT NULL DEFAULT '',
		menu_order int NOT NULL DEFAULT 0)" >/dev/null
	adb "INSERT INTO menu_pension_sub_issue (value, label, menu_order)
		VALUES ('AB1', 'Benefits & Accrual <check>', 1)" >/dev/null

	ps_code="$(curl -s --max-time 30 -b "$COOKIES" -o "$BODY" \
		-w '%{http_code}' "$ps_url")"
	ps_label="$(python3 - "$BODY" <<'PY'
import sys
import xml.etree.ElementTree as ET

try:
	root = ET.parse(sys.argv[1]).getroot()
except Exception as exc:
	print('does not parse as XML: %s' % exc)
else:
	labels = [el.text or '' for el in root.iter('label')]
	print(labels[0] if labels else 'no label element')
PY
)"

	adb "DROP TABLE menu_pension_sub_issue" >/dev/null

	if [ "$ps_code" != 200 ]; then
		bad "the pension sub-issue service answered ${ps_code} with its menu table present"
	elif [ "$ps_label" = 'Benefits & Accrual <check>' ]; then
		ok "a menu label holding & and < parses back out of the reply unchanged"
	else
		bad "a menu label holding & and < came back as: ${ps_label}"
	fi
fi

# Some of the tables this code queries are add-on schema: nothing an install
# runs creates them, and an install that was never given them has to work
# anyway. A query against a table that is not there fails, and a failed query
# here ends the request on the error page, so the caller gets HTTP 500 instead
# of an answer. That is what the pension sub-issue service did, and three
# pension reports before it.
#
# "Nothing an install runs" is the exact claim. The historical pika<version>.sql
# scripts in cms/app/sql/upgrades DO create some of these tables -- pika300.sql
# creates documents and pika700.sql creates menu_sms_messages -- but those
# scripts are version-stepped, are not idempotent, and are deliberately absent
# from APPLY_IN_ORDER, so neither the container entrypoint nor the manual
# instructions ever run them. The database this section asks is the oracle
# precisely because it has had new_install.sql and APPLY_IN_ORDER applied to it.
#
# A request cannot find the rest of them, because the code that names them is
# only reached on an install that has the table. So the check is static: ask the
# database which tables this install actually has, take every table named in a
# SQL string under cms/, and for each one the install lacks, require the file
# that names it either to guard it or to be a listed exception with a reason.
#
# A guard means one of four things: pl_mysql_table_exists(), an exact
# information_schema lookup, the table list a report hands to
# pika_report_require_schema(), or a CREATE TABLE for it in the same file.
#
# Only a string that begins with a SQL keyword is read as SQL. The queries are
# built up in pieces, so a fragment may begin at any clause, but no sentence of
# English begins with SELECT or FROM, and prose is what the earlier version of
# this sweep kept tripping over. A name written as menu_$menu is skipped too:
# the real table is whatever the caller passed, so there is nothing to look up.
#
# What this deliberately does NOT catch, so that a pass is not read as more than
# it is. It does not track variables or constants, so a table name that arrives
# through one is invisible. It does not join string fragments, so a query split
# as "SELECT * FROM " . "missing WHERE x=1" is missed. It reads guards per file,
# not per branch, so a guard anywhere in a file exempts every use of that name
# in it. It strips /* */ before reading strings, so a SQL literal that itself
# contains /* is cut short. Each of those can hide a real unguarded query; the
# floors below at least stop the sweep passing when it reads nothing.
echo
echo "95. every table a stock install lacks is guarded where it is named"

if ! command -v python3 >/dev/null 2>&1 || ! command -v adb >/dev/null 2>&1; then
	printf '  skip the absent-table check (needs the database and python3)\n'
elif ! adb "SELECT 1" >/dev/null 2>&1; then
	bad "section 95 cannot reach the database, so it cannot tell which tables this install has"
else
	AT_LIST="$(mktemp)"
	AT_PY="$(mktemp)"
	# The suite's own trap only knows about the two files it made at the top.
	# Re-set it so an interrupt part way through this section does not leave
	# these two behind.
	trap 'rm -f "$COOKIES" "$BODY" "$AT_LIST" "$AT_PY"' EXIT

	# SELECT 1 above proves the client works, not that this query answered.
	# Without the second test a failed table list reads as an install with no
	# tables at all, which would flag every name in the tree.
	adb "SELECT table_name FROM information_schema.tables
		WHERE table_schema = DATABASE()" > "$AT_LIST"

	if [ ! -s "$AT_LIST" ]; then
		bad "SECTION 95 COULD NOT READ THE TABLE LIST, SO IT CANNOT SAY WHICH TABLES ARE MISSING"
	else

	cat > "$AT_PY" <<'ATPY'
import io, os, re, sys

root = os.path.join(sys.argv[1], 'cms')
present = set(l.strip() for l in io.open(sys.argv[2]) if l.strip())

OPENER = re.compile(r'''^\s*\(?\s*(SELECT|INSERT|REPLACE|UPDATE|DELETE|TRUNCATE
	|FROM|JOIN|LEFT|RIGHT|INNER|OUTER|CROSS|STRAIGHT_JOIN
	|WHERE|AND|OR|ORDER|GROUP|HAVING|LIMIT|SET|ON|UNION|,)\b''',
	re.I | re.X)

# INTO is optional after INSERT, because INSERT missing SET x=1 is valid SQL.
#
# The two lookaheads are there to stop two real misreadings. A name after FROM
# or JOIN that is followed by "(" is a function, not a table. The \b is what
# stops the name backtracking to dodge that test, which is how SCOPE( first
# got through as SCOP: cms/pika_cms.php
# searches an Exchange calendar with FROM SCOPE('...'), which is not MySQL at
# all. And UPDATE has to be followed by SET or by a comma list, because
# "ON DUPLICATE KEY UPDATE granted_until = VALUES(granted_until)" ends with the
# word UPDATE followed by a column name, which otherwise reads as a table.
TABLE = [
	re.compile(r'\bFROM\s+`?([A-Za-z_][A-Za-z0-9_]*)`?(\$?)\b(?!\s*\()', re.I),
	re.compile(r'\bJOIN\s+`?([A-Za-z_][A-Za-z0-9_]*)`?(\$?)\b(?!\s*\()', re.I),
	re.compile(r'\b(?:INSERT|REPLACE)\s+(?:IGNORE\s+)?(?:INTO\s+)?`?([A-Za-z_][A-Za-z0-9_]*)`?(\$?)', re.I),
	re.compile(r'''\bUPDATE\s+(?:LOW_PRIORITY\s+)?(?:IGNORE\s+)?`?([A-Za-z_][A-Za-z0-9_]*)`?(\$?)\b
		(?=\s*,|\s+SET\b|\s+(?:AS\s+)?[A-Za-z_][A-Za-z0-9_]*\s*(?:,|\s+SET\b))''', re.I | re.X),
	re.compile(r'\bTRUNCATE\s+(?:TABLE\s+)?`?([A-Za-z_][A-Za-z0-9_]*)`?(\$?)', re.I),
]

# FROM a, b and UPDATE a, b each name two tables. Step over an alias if there
# is one, then take every further name in the comma list. The keyword test is
# what stops UPDATE t SET a=1, b=2 reading b as a table.
ALIAS = re.compile(r'\s+(?:AS\s+)?([A-Za-z_][A-Za-z0-9_]*)', re.I)
LIST_ITEM = re.compile(r'\s*,\s*`?([A-Za-z_][A-Za-z0-9_]*)`?(\$?)')
NOT_ALIAS = set('''where set on join left right inner outer cross using and or
	group order having limit union values straight_join natural for'''.split())

HEREDOC = re.compile(
	r"<<<[ \t]*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1\r?\n(.*?)\r?\n[ \t]*\2\b", re.S)
BLOCK = re.compile(r'/\*.*?\*/', re.S)
LINE = re.compile(r'(?<!:)//[^\n]*|^[ \t]*#[^\n]*', re.M)
LITERAL = re.compile(r"'((?:\\.|[^'\\])*)'|\"((?:\\.|[^\"\\])*)\"", re.S)
SCHEMA_CALL = re.compile(r'pika_report_require_schema\s*\((.*?)\)\s*;', re.S)
CREATED = re.compile(r'CREATE\s+(?:TEMPORARY\s+)?TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?'
	r'`?([A-Za-z_][A-Za-z0-9_]*)`?', re.I)

NOISE = set(['select', 'dual', 'information_schema'])

# Each names a table nothing an install runs creates, and has a reason that is
# not a guard. Anything not listed here has to guard itself.
ALLOWED = {
	('documents', 'cms/app/scripts/fs2db.php'):
		'the source table of the one-time move of documents off the file system;'
		' pika300.sql created it, but that script is not in APPLY_IN_ORDER, so'
		' the table exists on the install being migrated from and never on a new'
		' one, which is the whole point of the script',
	('intakes', 'cms/app/lib/pikaContact.php'):
		'its only caller, cms/contact.php, asks information_schema for the table'
		' by exact name first',
	('intakes', 'cms/app/lib/pikaMisc.php'):
		'pikaMisc::getIntakes() has no caller',
	('megareports', 'cms/app/lib/pikaMisc.php'):
		'pikaMisc::getMegaReports() has no caller',
	('menu_sms_messages', 'cms/sms_cron.php'):
		'the script stops at its require() of the Twilio autoloader, which is'
		' neither vendored nor declared as a dependency, well before this query;'
		' pika700.sql creates the table and the activities sms_* columns, but'
		' that script is not in APPLY_IN_ORDER so no install runs it',
	('show_me_the_penguin', 'cms/error.php'):
		'not a query: the string is the sample message the error page prints to'
		' show what a failed query looks like',
}


def php_files(top):
	found = []
	def failed(err):
		found.append(None)
	for dirpath, dirnames, filenames in os.walk(top, onerror=failed):
		rel = os.path.relpath(dirpath, top)
		if rel.startswith('vendor') or rel.startswith(os.path.join('app', 'sql')):
			continue
		for name in sorted(filenames):
			if name.endswith('.php'):
				found.append(os.path.join(dirpath, name))
	return found


problems = []
checked = 0
read_ok = 0
read_failed = 0

paths = php_files(root)
if None in paths:
	read_failed += paths.count(None)
	paths = [p for p in paths if p is not None]

for path in paths:
	try:
		raw = io.open(path, encoding='utf-8', errors='replace').read()
	except Exception:
		# A file this sweep could not read is a hole in it, not a pass. The
		# count below is what makes that visible.
		read_failed += 1
		continue
	read_ok += 1

	rel = os.path.relpath(path, os.path.dirname(root))
	code = LINE.sub(' ', BLOCK.sub(' ', raw))

	# Heredocs come from the raw text: their bodies are SQL, not PHP, so the
	# comment strippers above would eat parts of them.
	candidates = [m.group(3) for m in HEREDOC.finditer(raw)]
	for m in LITERAL.finditer(code):
		candidates.append(m.group(1) if m.group(1) is not None else m.group(2))

	named = set()
	for sql in candidates:
		if not sql or len(sql) < 10 or not OPENER.match(sql):
			continue
		for pat in TABLE:
			for hit in pat.finditer(sql):
				name, dollar = hit.group(1), hit.group(2)
				if not dollar and name.lower() not in NOISE:
					named.add(name)
				pos = hit.end()
				a = ALIAS.match(sql, pos)
				if a and a.group(1).lower() not in NOT_ALIAS:
					pos = a.end()
				while True:
					item = LIST_ITEM.match(sql, pos)
					if not item:
						break
					if not item.group(2) and item.group(1).lower() not in NOISE:
						named.add(item.group(1))
					pos = item.end()
					a = ALIAS.match(sql, pos)
					if a and a.group(1).lower() not in NOT_ALIAS:
						pos = a.end()

	if not named:
		continue

	guarded = set(re.findall(
		r"""pl_mysql_table_exists\s*\(\s*['"]([A-Za-z0-9_]+)['"]""", code))
	# An exact information_schema lookup only counts as one where the file
	# actually reads information_schema: table_name = 'x' on its own is an
	# ordinary comparison and proves nothing.
	if 'information_schema' in code.lower():
		guarded |= set(re.findall(
			r"""table_name\s*=\s*['"]([A-Za-z0-9_]+)['"]""", code, re.I))
	guarded |= set(re.findall(r"""TABLES\s+LIKE\s+['"]([A-Za-z0-9_\\]+)['"]""",
		code, re.I))
	for call in SCHEMA_CALL.finditer(code):
		guarded |= set(re.findall(r"""['"]([A-Za-z0-9_]+)['"]""", call.group(1)))
	# A table the file creates itself is there by the time it is read.
	for sql in candidates:
		guarded |= set(CREATED.findall(sql))
	guarded = set(t.replace('\\', '') for t in guarded)

	for t in sorted(named):
		if t in present:
			continue
		checked += 1
		if t in guarded or (t, rel) in ALLOWED:
			continue
		problems.append('%s names %s and neither guards it nor is a listed'
			' exception' % (rel, t))

print('read %d' % read_ok)
print('unread %d' % read_failed)
print('checked %d' % checked)
for p in problems:
	print('BAD %s' % p)
ATPY

	at_out="$(python3 "$AT_PY" "$REPO_DIR" "$AT_LIST" 2>&1)"
	at_read="$(printf '%s\n' "$at_out" | grep '^read ' | cut -d' ' -f2)"
	at_unread="$(printf '%s\n' "$at_out" | grep '^unread ' | cut -d' ' -f2)"
	at_checked="$(printf '%s\n' "$at_out" | grep '^checked ' | cut -d' ' -f2)"
	at_lines="$(printf '%s\n' "$at_out" | grep '^BAD ' | sed 's/^BAD //')"
	rm -f "$AT_PY" "$AT_LIST"
	trap 'rm -f "$COOKIES" "$BODY"' EXIT

	# A sweep that finds nothing to look at has failed, not passed. Two
	# separate floors, because they fail differently: at_checked counts the
	# references examined, and at_read counts the files opened. Only the
	# second one moves when the sweep stops reading the tree, and a run that
	# read twelve files can still report the same 27 references as a run that
	# read all of them.
	if [ -z "$at_read" ] || [ -z "$at_checked" ]; then
		bad "SECTION 95 DID NOT RUN: ${at_out}"
	elif [ "${at_unread:-1}" -ne 0 ]; then
		bad "SECTION 95 COULD NOT READ ${at_unread} FILES, SO ITS RESULT IS NOT COVERAGE"
	elif [ "$at_read" -lt 250 ]; then
		bad "SECTION 95 READ ONLY ${at_read} PHP FILES, SO IT IS NOT READING THE TREE"
	elif [ "$at_checked" -lt 20 ]; then
		bad "SECTION 95 EXAMINED ONLY ${at_checked} REFERENCES, SO IT IS NOT READING WHAT IT SHOULD"
	elif [ -z "$at_lines" ]; then
		ok "all ${at_checked} references to a table this install lacks, across ${at_read} files, are guarded or listed"
	else
		bad "A TABLE THIS INSTALL LACKS IS QUERIED UNGUARDED: $(printf '%s' "$at_lines" | tr '\n' ';')"
	fi
	fi
fi

# 96. The holding-pen handler in dataops.php was unreachable and unsafe at the
# same time, and each fault hid the other.
#
# pl_table_autosql_update() built "UPDATE cases SET WHERE case_id='1'" whenever
# nothing the caller supplied was a column of this install's schema. The handler
# sets transfer_to, which is not a column of cases here, so a POST that reached
# its body ended in a MariaDB syntax error and an HTTP 500.
#
# Behind that 500 sat a query that interpolated the case id instead of escaping
# it. The id arrives from pl_grab_vars('cases'), which filters a primary key in
# 'primary_key' mode, and that mode trims the value and encodes < and >, so a
# quote arrives intact. Fixing the builder made the unsafe line reachable, which
# is why both fixes belong to one change.
#
# These checks are behavioural, not textual. They post to the handler and then
# ask the database what it did. Everything the section reads is its own: it seeds
# its own source case, one conflict row on that case to prove the handler copies
# what it should, and one conflict row on a case id no request names to catch it
# copying what it should not.
#
# Nothing here deletes a row until the section has proved it owns one. The
# vacancy query must find the fixture ids free and both marker offices unused,
# and the seeding must then report every row it asked for. Only then is TH_OWNED
# set, and only then may cleanup run a DELETE. A collision, a query that cannot
# answer, or an exit part way through leaves the database alone.
echo
echo "96. the holding-pen handler answers a quoted case id without breaking out of its query"

if ! command -v adb >/dev/null 2>&1; then
	printf '  skip the holding-pen checks (needs the database)\n'
elif ! adb "SELECT 1" >/dev/null 2>&1; then
	bad "section 96 cannot reach the database, so it cannot tell what the handler wrote"
else
	# Two office codes nothing else uses. office is char(3), and the handler
	# copies the posted trans_office into the office column of every case it
	# creates, so this marks the handler's output as this section's property.
	TH_SRC_OFFICE='Z95'
	TH_NEW_OFFICE='Z96'
	# The source case the requests name, a case id they never name, and two
	# contacts: one that must be copied, one that must not.
	TH_CASE='9299999'
	TH_OTHER='9299998'
	TH_CONTACT_MINE='9242423'
	TH_CONTACT_OTHER='9242424'
	TH_ROW_MINE='9777776'
	TH_ROW_OTHER='9777777'
	TH_HEAD="$(mktemp)"
	TH_OWNED=0
	TH_OWNED_IDS='0'
	TH_CLEAN_ERR=''
	TH_SEEN=''

	# The suite's own trap only knows the two files it made at the top.
	cleanup_th() {
		rm -f "$TH_HEAD"

		# The gate. Until the vacancy query has passed and the fixture is in
		# place, this section owns nothing, and a DELETE here would take
		# somebody else's rows. An exit part way through arrives here too.
		if [ "$TH_OWNED" != 1 ]; then
			return 0
		fi

		# Read the ids before the case rows go, so the checks below can still
		# name the children. Deleting those by a subquery on cases would lose
		# them the moment the parent delete ran first, and this schema has no
		# foreign key to stop that order.
		#
		# By the marker office rather than the ids the handler reported: a
		# request that dies after its insert sends no Location header, and
		# the case it made would otherwise outlive the section.
		TH_OWNED_IDS="$(adb "SELECT GROUP_CONCAT(case_id) FROM cases
			WHERE office IN ('${TH_SRC_OFFICE}', '${TH_NEW_OFFICE}')")"
		case "$TH_OWNED_IDS" in
			'' | NULL) TH_OWNED_IDS='0' ;;
		esac

		adb "DELETE FROM conflict
			WHERE conflict_id IN (${TH_ROW_MINE}, ${TH_ROW_OTHER})" \
			>/dev/null 2>&1 || TH_CLEAN_ERR="${TH_CLEAN_ERR} seeded-conflict"
		adb "DELETE FROM conflict WHERE case_id IN (${TH_OWNED_IDS})" \
			>/dev/null 2>&1 || TH_CLEAN_ERR="${TH_CLEAN_ERR} conflict"
		adb "DELETE FROM activities WHERE case_id IN (${TH_OWNED_IDS})" \
			>/dev/null 2>&1 || TH_CLEAN_ERR="${TH_CLEAN_ERR} activities"
		adb "DELETE FROM cases
			WHERE office IN ('${TH_SRC_OFFICE}', '${TH_NEW_OFFICE}')" \
			>/dev/null 2>&1 || TH_CLEAN_ERR="${TH_CLEAN_ERR} cases"
	}
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_th' EXIT

	# A token of its own rather than the one section 7 captured, so this section
	# does not depend on how far away that is or on what ran in between.
	curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" "$OCM_URL/prefs.php" >/dev/null
	TH_TOKEN="$(grep -oE 'name="_csrf" value="[0-9a-f]*"' "$BODY" \
		| head -1 | sed -E 's/.*value="([0-9a-f]*)".*/\1/')"

	th_post() {
		: > "$TH_HEAD"
		th_code="$(curl -s --max-time 60 -b "$COOKIES" -D "$TH_HEAD" \
			-o "$BODY" -w '%{http_code}' \
			--data-urlencode "action=toledo_holding" \
			--data-urlencode "case_id=$1" \
			--data-urlencode "trans_office=${TH_NEW_OFFICE}" \
			--data-urlencode "_csrf=${TH_TOKEN}" \
			"$OCM_URL/dataops.php")"
		th_curl=$?
		# Only the handler's own redirect carries new_case_id, so requiring it
		# is what tells a completed request apart from a login redirect, a
		# refusal, or a request that died halfway.
		th_new="$(grep -i '^location:' "$TH_HEAD" \
			| grep -oE 'new_case_id=[0-9]+' | head -1 | cut -d= -f2)"
		[ "$th_curl" = 0 ]
	}

	# What each request must have produced: a case this section did not seed
	# and no earlier request reported, carrying the marker office, with the
	# source case's own conflict row copied onto it.
	#
	# The copy is the positive control. Without it a zero in the injection
	# check below could mean the handler copies nothing at all, and a redirect
	# naming the source case would let the check count the row the section
	# seeded itself. The relation code comes from the seeded row rather than a
	# literal, because what matters is that the field is carried across.
	#
	# $1 names the request for the messages, $2 is what to say for a 500.
	th_made_new_case() {
		if [ "$th_code" = 500 ]; then
			bad "$2"
			return 1
		fi
		if [ -z "$th_new" ]; then
			bad "$1 answered ${th_code} and named no new case, so the handler did not finish"
			return 1
		fi
		if [ "$th_new" = "$TH_CASE" ]; then
			bad "$1 named the source case ${TH_CASE} as its output, so no case was created"
			return 1
		fi
		case " ${TH_SEEN} " in
			*" ${th_new} "*)
				bad "$1 named case ${th_new}, which an earlier request in this section already made"
				return 1
				;;
		esac
		TH_SEEN="${TH_SEEN} ${th_new}"
		th_office="$(adb "SELECT office FROM cases WHERE case_id = ${th_new}")"
		if [ "$th_office" != "$TH_NEW_OFFICE" ]; then
			bad "$1 named case ${th_new}, which is not a case this run created (office '${th_office}')"
			return 1
		fi
		th_mine="$(adb "SELECT COUNT(*) FROM conflict
			WHERE case_id = ${th_new}
			  AND contact_id = ${TH_CONTACT_MINE}
			  AND relation_code = (SELECT relation_code FROM conflict
			                       WHERE conflict_id = ${TH_ROW_MINE})")"
		if [ -z "$th_mine" ] || [ "$th_mine" -lt 1 ]; then
			bad "$1 did not copy the source case's conflict row onto new case ${th_new} (count '${th_mine}'), so the injection check below would prove nothing"
			return 1
		fi
		return 0
	}

	# Refuse to seed over anything that is already there: these ids are chosen
	# to be free, and if they are not, this section does not own them and must
	# neither write them nor delete them.
	TH_TAKEN="$(adb "SELECT
		(SELECT COUNT(*) FROM cases WHERE case_id IN (${TH_CASE}, ${TH_OTHER}))
		+ (SELECT COUNT(*) FROM conflict
		   WHERE conflict_id IN (${TH_ROW_MINE}, ${TH_ROW_OTHER}))
		+ (SELECT COUNT(*) FROM cases
		   WHERE office IN ('${TH_SRC_OFFICE}', '${TH_NEW_OFFICE}'))")"

	if [ "$TH_TAKEN" = 0 ]; then
		adb "INSERT INTO cases (case_id, office, status, user_id, client_id)
			VALUES (${TH_CASE}, '${TH_SRC_OFFICE}', '1', 1, 0)" >/dev/null 2>&1
		adb "INSERT INTO conflict (conflict_id, contact_id, case_id, relation_code)
			VALUES (${TH_ROW_MINE}, ${TH_CONTACT_MINE}, ${TH_CASE}, 'A')" >/dev/null 2>&1
		adb "INSERT INTO conflict (conflict_id, contact_id, case_id, relation_code)
			VALUES (${TH_ROW_OTHER}, ${TH_CONTACT_OTHER}, ${TH_OTHER}, 'A')" >/dev/null 2>&1
		TH_SEEDED="$(adb "SELECT
			(SELECT COUNT(*) FROM cases WHERE case_id = ${TH_CASE})
			+ (SELECT COUNT(*) FROM conflict
			   WHERE conflict_id IN (${TH_ROW_MINE}, ${TH_ROW_OTHER}))")"
		if [ "$TH_SEEDED" = 3 ]; then
			# Three rows this section wrote, on ids nothing else was using.
			# From here its cleanup has something of its own to remove.
			TH_OWNED=1
		fi
	else
		TH_SEEDED='not attempted'
	fi

	if [ "${#TH_TOKEN}" -ne 64 ]; then
		bad "no CSRF token for the holding-pen POST - section 96 is untested"
	elif [ -z "$TH_TAKEN" ]; then
		bad "section 96 could not ask whether its fixture ids are free, so it wrote nothing and will delete nothing"
	elif [ "$TH_TAKEN" != 0 ]; then
		bad "section 96's fixture ids are already in use (${TH_TAKEN} rows), so it will not seed over them or delete them"
	elif [ "$TH_SEEDED" != 3 ]; then
		bad "section 96 could not seed its case and two conflict rows (count '${TH_SEEDED}'), so it proves nothing"
	else
		if ! th_post "$TH_CASE"; then
			bad "the holding-pen request failed outright (curl exit ${th_curl}) - section 96 is untested"
		elif th_made_new_case "the holding-pen request for an ordinary case id" \
			"THE HOLDING-PEN HANDLER 500s ON AN ORDINARY CASE ID: its UPDATE is not a valid statement"
		then
			ok "the holding-pen handler answers an ordinary case id with ${th_code} and copies that case's own conflict row to the case it creates"
		fi

		# A trailing quote on an id the section owns. Unescaped it ended the
		# string mid-query and the request died on the error page.
		if ! th_post "${TH_CASE}'"; then
			bad "the quoted holding-pen request failed outright (curl exit ${th_curl})"
		elif th_made_new_case "the quoted holding-pen request" \
			"A QUOTE IN THE CASE ID 500s THE HOLDING-PEN HANDLER: the id reaches its query unescaped"
		then
			ok "a quote in the case id does not break the handler's query, and the case it makes still carries the source case's own conflict row (status ${th_code})"
		fi

		# The payload that mattered. The handler copies the conflict rows of
		# the case it was given onto the case it creates, so an always-true
		# clause made that every row in the table.
		if ! th_post "${TH_CASE}' OR '1'='1"; then
			bad "the always-true holding-pen request failed outright (curl exit ${th_curl})"
		elif th_made_new_case "the always-true holding-pen request" \
			"the always-true holding-pen request answered 500 - section 96's injection check is untested"
		then
			TH_LEAKED="$(adb "SELECT COUNT(*) FROM conflict
				WHERE case_id = ${th_new} AND contact_id = ${TH_CONTACT_OTHER}")"
			if [ -z "$TH_LEAKED" ]; then
				bad "section 96 could not count the copied conflict rows, so its result is not proof"
			elif [ "$TH_LEAKED" != 0 ]; then
				bad "SQL INJECTION IN THE HOLDING-PEN HANDLER: an always-true case id copied case ${TH_OTHER}'s conflict row onto new case ${th_new}"
			else
				ok "an always-true case id copies no other case's conflict rows (status ${th_code})"
			fi
		fi
	fi

	cleanup_th

	# The handler writes on every call, so a section that leaves its cases
	# behind changes what a later one counts. Only its own rows are counted
	# here: the marker offices, the two conflict ids it seeded, and the
	# children of the cases it owned.
	if [ "$TH_OWNED" != 1 ]; then
		printf '  section 96 wrote nothing, so it removed nothing\n'
	elif [ -n "$TH_CLEAN_ERR" ]; then
		bad "section 96 could not remove its own rows (failed:${TH_CLEAN_ERR}), so a later count would read them"
	else
		TH_LEFT="$(adb "SELECT
			(SELECT COUNT(*) FROM cases
			 WHERE office IN ('${TH_SRC_OFFICE}', '${TH_NEW_OFFICE}'))
			+ (SELECT COUNT(*) FROM conflict
			   WHERE conflict_id IN (${TH_ROW_MINE}, ${TH_ROW_OTHER}))
			+ (SELECT COUNT(*) FROM conflict WHERE case_id IN (${TH_OWNED_IDS}))
			+ (SELECT COUNT(*) FROM activities
			   WHERE case_id IN (${TH_OWNED_IDS}))")"

		if [ "$TH_LEFT" = 0 ]; then
			ok "section 96 leaves none of its own cases, conflicts or activities behind"
		else
			bad "section 96 left ${TH_LEFT} of its own rows in the database, so a later count would read them"
		fi
	fi

	trap 'rm -f "$COOKIES" "$BODY"' EXIT
fi


# 97. pl_table_autosql_insert() had the same empty-SET-list fault as its UPDATE
# sibling, and system-ops.php's add_group reaches it from a request: a POST with
# a valid token and no group fields supplied gave MariaDB "INSERT `groups` SET"
# and answered HTTP 500. The builder now refuses an insert with nothing in it, on
# the error page it already uses for a $data that is not an array. Writing must
# not be the answer either: a row of column defaults is not what was asked for.
#
# The refusal's own words are what this checks. A 200 on its own would also be
# an authorization refusal, a CSRF rejection or a gate redirect, and each of
# those answers before the builder runs.
echo
echo "97. an empty add_group POST is refused rather than answered with a 500"

if ! command -v adb >/dev/null 2>&1; then
	printf '  skip the empty-insert check (needs the database)\n'
elif ! adb "SELECT 1" >/dev/null 2>&1; then
	bad "section 97 cannot reach the database, so it cannot tell whether a group was written"
else
	curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" "$OCM_URL/prefs.php" >/dev/null
	EI_TOKEN="$(grep -oE 'name="_csrf" value="[0-9a-f]*"' "$BODY" \
		| head -1 | sed -E 's/.*value="([0-9a-f]*)".*/\1/')"
	EI_BEFORE="$(adb "SELECT COUNT(*) FROM \`groups\`")"
	: > "$BODY"
	EI_CODE="$(curl -s --max-time 60 -b "$COOKIES" -o "$BODY" -w '%{http_code}' \
		--data-urlencode "action=add_group" \
		--data-urlencode "_csrf=${EI_TOKEN}" \
		"$OCM_URL/system-ops.php")"
	EI_CURL=$?
	EI_AFTER="$(adb "SELECT COUNT(*) FROM \`groups\`")"

	if [ "${#EI_TOKEN}" -ne 64 ]; then
		bad "no CSRF token for the add_group POST - section 97 is untested"
	elif [ "$EI_CURL" != 0 ]; then
		bad "the add_group POST failed outright (curl exit ${EI_CURL}) - section 97 is untested"
	elif [ -z "$EI_BEFORE" ] || [ -z "$EI_AFTER" ]; then
		bad "section 97 could not count the groups table, so its result is not proof"
	elif [ "$EI_CODE" = 500 ]; then
		bad "AN EMPTY add_group POST 500s: the INSERT builder emits a statement with no SET list"
	elif [ "$EI_CODE" != 200 ]; then
		bad "the empty add_group POST answered ${EI_CODE}, so it never reached the INSERT builder"
	elif ! grep -q 'No values were supplied for the new record' "$BODY"; then
		bad "the empty add_group POST answered 200 without the builder's refusal, so section 97 does not know which answer it got"
	elif [ "$EI_AFTER" != "$EI_BEFORE" ]; then
		bad "an empty add_group POST wrote a groups row (${EI_BEFORE} -> ${EI_AFTER})"
	else
		ok "an empty add_group POST is refused by the INSERT builder and writes no group (status ${EI_CODE})"
	fi
fi


# 98. pikaMisc::getContactsAlphabetically() escaped its LIMIT values instead of
# casting them. The offset arrives from the request through htmlContactList(),
# which tests it with is_numeric(), and that test passes -1, 1.5 and 1e2. None of
# the three is a value MariaDB accepts in a LIMIT clause, so each answered the
# address book with a 500. Both values are cast now and held at the lowest one
# SQL takes.
#
# The checks are behavioural, and they count rows rather than trusting a status:
# this application answers a PHP error with 200, an account gate redirects to a
# form, and an empty address book renders happily whatever the offset was. So
# the section seeds three contacts under a surname letter this install does not
# use, and every check asks for that letter. Each value the is_numeric() test
# lets through must return what the integer it casts to returns: -1 the rows of
# 0, 1.5 the rows of 1, and 1e2 the rows of 100.
#
# Ownership works as in section 96: nothing is deleted until the vacancy query
# has passed and the seeding has reported every row.
echo
echo "98. the address book casts an offset MariaDB cannot use in a LIMIT"

if ! command -v adb >/dev/null 2>&1; then
	printf '  skip the address book offset checks (needs the database)\n'
elif ! adb "SELECT 1" >/dev/null 2>&1; then
	bad "section 98 cannot reach the database, so it cannot seed the rows it counts"
else
	AB_ID1='9242431'
	AB_ID2='9242432'
	AB_ID3='9242433'
	AB_OWNED=0
	AB_CLEAN_ERR=''
	AB_JAR="$(mktemp)"

	# A surname letter with no aliases on it, so every row the address book
	# returns for that letter is one of the three seeded below. Counting
	# against whatever contacts the install already holds would not tell one
	# offset from another.
	AB_LETTER=''
	for AB_CAND in Q X Y K J U V Z
	do
		if [ "$(adb "SELECT COUNT(*) FROM aliases
			WHERE last_name LIKE '${AB_CAND}%'")" = 0 ]
		then
			AB_LETTER="$AB_CAND"
			break
		fi
	done

	cleanup_ab() {
		rm -f "$AB_JAR"
		if [ "$AB_OWNED" != 1 ]; then
			return 0
		fi
		adb "DELETE FROM aliases
			WHERE alias_id IN (${AB_ID1}, ${AB_ID2}, ${AB_ID3})" \
			>/dev/null 2>&1 || AB_CLEAN_ERR="${AB_CLEAN_ERR} aliases"
		adb "DELETE FROM contacts
			WHERE contact_id IN (${AB_ID1}, ${AB_ID2}, ${AB_ID3})" \
			>/dev/null 2>&1 || AB_CLEAN_ERR="${AB_CLEAN_ERR} contacts"
	}
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_ab' EXIT

	AB_TAKEN="$(adb "SELECT
		(SELECT COUNT(*) FROM contacts
		 WHERE contact_id IN (${AB_ID1}, ${AB_ID2}, ${AB_ID3}))
		+ (SELECT COUNT(*) FROM aliases
		   WHERE alias_id IN (${AB_ID1}, ${AB_ID2}, ${AB_ID3}))")"

	if [ -n "$AB_LETTER" ] && [ "$AB_TAKEN" = 0 ]; then
		AB_N=0
		for AB_ID in "$AB_ID1" "$AB_ID2" "$AB_ID3"
		do
			AB_N=$((AB_N + 1))
			adb "INSERT INTO contacts (contact_id, first_name, last_name)
				VALUES (${AB_ID}, 'Smoke', '${AB_LETTER}zsmoke${AB_N}')" \
				>/dev/null 2>&1
			adb "INSERT INTO aliases
				(alias_id, contact_id, primary_name, first_name, last_name)
				VALUES (${AB_ID}, ${AB_ID}, 1, 'Smoke',
					'${AB_LETTER}zsmoke${AB_N}')" >/dev/null 2>&1
		done
		AB_SEEDED="$(adb "SELECT COUNT(*) FROM aliases
			WHERE alias_id IN (${AB_ID1}, ${AB_ID2}, ${AB_ID3})")"
		if [ "$AB_SEEDED" = 3 ]; then
			AB_OWNED=1
		fi
	else
		AB_SEEDED='not attempted'
	fi

	# $1 the offset, $2 the cookie jar. The header row of the matches table is
	# a plain <tr>; only result rows carry the striping class, so counting it
	# counts what the query returned.
	ab_rows() {
		: > "$BODY"
		ab_code="$(curl -sL --max-time 60 -b "$2" -o "$BODY" -w '%{http_code}' \
			"$OCM_URL/addressbook.php?dmodeb=1&last_name=${AB_LETTER}&offset=$1")"
		ab_curl=$?
		ab_count="$(grep -c '<tr class="row' "$BODY")"
		[ "$ab_curl" = 0 ]
	}

	# $1 the offset, $2 how many of the three seeded rows it must return.
	ab_check() {
		if ! ab_rows "$1" "$COOKIES"; then
			bad "the address book request for offset=$1 failed outright (curl exit ${ab_curl})"
		elif [ "$ab_code" = 500 ]; then
			bad "THE ADDRESS BOOK 500s ON offset=$1: the value reaches LIMIT as written"
		elif [ "$ab_code" != 200 ]; then
			bad "the address book answered ${ab_code} on offset=$1, so it rendered nothing to count"
		elif grep -q 'login_pass' "$BODY"; then
			bad "the address book bounced to the login form on offset=$1, so this proves nothing"
		elif grep -q 'Pika Error' "$BODY"; then
			bad "THE ADDRESS BOOK ERRORS ON offset=$1: the value reached the database"
		elif ! grep -q 'Address Book Matches' "$BODY"; then
			bad "the address book answered 200 on offset=$1 without its results heading, so the contact query did not run"
		elif [ "$ab_count" != "$2" ]; then
			bad "the address book returned ${ab_count} of its three seeded rows on offset=$1, not ${2}"
		else
			ok "the address book answers offset=$1 with the ${2} rows that offset selects (status ${ab_code})"
		fi
	}

	if [ -z "$AB_LETTER" ]; then
		printf '  skip the address book offset checks (every candidate surname letter is in use)\n'
	elif [ -z "$AB_TAKEN" ]; then
		bad "section 98 could not ask whether its fixture ids are free, so it wrote nothing and will delete nothing"
	elif [ "$AB_TAKEN" != 0 ]; then
		bad "section 98's fixture ids are already in use (${AB_TAKEN} rows), so it will not seed over them or delete them"
	elif [ "$AB_SEEDED" != 3 ]; then
		bad "section 98 could not seed its three contacts (count '${AB_SEEDED}'), so it has nothing to count"
	else
		# The reference values first, from offsets MariaDB has always taken.
		ab_check 0 3
		ab_check 1 2
		ab_check 100 0
		# Then the three the is_numeric() test lets through.
		ab_check -1 3
		ab_check 1.5 2
		ab_check 1e2 0

		# The count comes from the paging preference, which accepts a digit
		# string. "00" is truthy in PHP, so it survives the fallback that
		# replaces an empty preference with a default, and arrives here as a
		# zero. LIMIT 0 is valid SQL and an empty page is what that setting
		# asks for, so the cast has to keep it: a floor of one would answer
		# with a row nobody asked for.
		#
		# The preference is stored per user, so this reads the row, writes a
		# preference set of its own, and puts the original back. Hex in and
		# hex out, so the serialized value needs no quoting and the copy can
		# be compared byte for byte. A second cookie jar and its own login
		# keep the suite's session, and its page size, as they were.
		AB_WHO="$(adb "SELECT user_id FROM users WHERE username = '${OCM_USER}'")"
		AB_PREFS="$(adb "SELECT HEX(session_data) FROM users
			WHERE user_id = ${AB_WHO:-0}")"

		if [ -z "$AB_WHO" ] || [ -z "$AB_PREFS" ]; then
			bad "section 98 could not read ${OCM_USER}'s stored preferences, so it left them alone and did not test a zero page size"
		else
			adb "UPDATE users
				SET session_data = 'a:1:{s:6:\"paging\";s:2:\"00\";}'
				WHERE user_id = ${AB_WHO}" >/dev/null 2>&1
			curl -sL --max-time 30 -c "$AB_JAR" -b "$AB_JAR" -o /dev/null \
				-X POST \
				-d "login_user=${OCM_USER}&login_pass=${OCM_PASSWORD}&auth_id=1" \
				"$OCM_URL/"

			if ! ab_rows 0 "$AB_JAR"; then
				bad "the address book request for a zero page size failed outright (curl exit ${ab_curl})"
			elif [ "$ab_code" != 200 ]; then
				bad "the address book answered ${ab_code} with the paging preference set to 00"
			elif ! grep -q 'Address Book Matches' "$BODY"; then
				bad "the address book did not render with the paging preference set to 00, so the zero page size is untested"
			elif [ "$ab_count" != 0 ]; then
				bad "A ZERO PAGE SIZE SHOWS ${ab_count} ROWS: the LIMIT count is floored above the value the preference asked for"
			else
				ok "a paging preference of 00 gives an empty page rather than a row nobody asked for"
			fi

			adb "UPDATE users SET session_data = UNHEX('${AB_PREFS}')
				WHERE user_id = ${AB_WHO}" >/dev/null 2>&1
			AB_NOW="$(adb "SELECT HEX(session_data) FROM users
				WHERE user_id = ${AB_WHO}")"
			if [ "$AB_NOW" = "$AB_PREFS" ]; then
				ok "section 98 puts ${OCM_USER}'s stored preferences back as they were"
			else
				bad "SECTION 98 DID NOT RESTORE ${OCM_USER}'s PREFERENCES: the stored page size is still the test's own"
			fi
		fi
	fi

	cleanup_ab

	if [ "$AB_OWNED" != 1 ]; then
		printf '  section 98 wrote nothing, so it removed nothing\n'
	elif [ -n "$AB_CLEAN_ERR" ]; then
		bad "section 98 could not remove its own rows (failed:${AB_CLEAN_ERR}), so the address book keeps them"
	else
		AB_LEFT="$(adb "SELECT
			(SELECT COUNT(*) FROM contacts
			 WHERE contact_id IN (${AB_ID1}, ${AB_ID2}, ${AB_ID3}))
			+ (SELECT COUNT(*) FROM aliases
			   WHERE alias_id IN (${AB_ID1}, ${AB_ID2}, ${AB_ID3}))")"

		if [ "$AB_LEFT" = 0 ]; then
			ok "section 98 leaves none of its own contacts behind"
		else
			bad "section 98 left ${AB_LEFT} of its own rows in the address book"
		fi
	fi

	trap 'rm -f "$COOKIES" "$BODY"' EXIT
fi

# 99. system-ops.php wrote a request value straight into the query string of
# the URL it redirects to: "system-tables.php?screen=edit&table={$_POST['table']}".
# An "&" in the table name added a parameter to that next request and a "#"
# truncated the rest of it, so the request chose what the page it landed on was
# asked to do. The page itself is a fixed local file, so this is about the query
# string and not about where the redirect goes.
#
# The add_field case is the one posted here: a field_type outside the four the
# handler accepts fails its in_array() check, so nothing is written to the
# settings and the redirect is still emitted. The assertion is that the table
# name comes back as one encoded parameter value rather than as two parameters.
echo
echo "99. system-ops.php encodes a table name before putting it in a redirect"

if ! command -v adb >/dev/null 2>&1; then
	printf '  skip the system-ops redirect check (needs the database)\n'
elif ! adb "SELECT 1" >/dev/null 2>&1; then
	bad "section 99 cannot reach the database, so it cannot tell whether the POST wrote anything"
else
	curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" "$OCM_URL/prefs.php" >/dev/null
	SO_TOKEN="$(grep -oE 'name="_csrf" value="[0-9a-f]*"' "$BODY" \
		| head -1 | sed -E 's/.*value="([0-9a-f]*)".*/\1/')"
	SO_LOC="$(curl -s --max-time 30 -b "$COOKIES" -o /dev/null -D - \
		--data-urlencode "action=add_field" \
		--data-urlencode "_csrf=${SO_TOKEN}" \
		--data-urlencode "field_type=zz_not_a_type" \
		--data-urlencode "field=zz_so_field" \
		--data-urlencode "table=zz_so&screen=delete&x=y" \
		"$OCM_URL/system-ops.php" \
		| grep -i '^location:' | tr -d '\r' | head -1 \
		| sed -e 's/^[Ll][Oo][Cc][Aa][Tt][Ii][Oo][Nn]: *//')"

	if [ "${#SO_TOKEN}" -ne 64 ]; then
		bad "no CSRF token for the system-ops POST - section 99 is untested"
	elif [ -z "$SO_LOC" ]; then
		bad "system-ops.php sent no Location header, so section 99 tested nothing"
	elif [ "${SO_LOC#system-tables.php}" = "$SO_LOC" ]; then
		bad "the system-ops redirect no longer names system-tables.php (${SO_LOC})"
	elif printf '%s' "$SO_LOC" | grep -q 'screen=delete'; then
		bad "a table name carrying an & STILL adds a parameter to the system-ops redirect (${SO_LOC})"
	elif ! printf '%s' "$SO_LOC" | grep -q 'table=zz_so%26screen%3Ddelete%26x%3Dy'; then
		bad "the system-ops redirect does not carry the table name it was given (${SO_LOC})"
	elif [ "$SO_LOC" != "system-tables.php?screen=edit&table=zz_so%26screen%3Ddelete%26x%3Dy" ]; then
		# The three checks above each answer one way of getting this wrong.
		# This one names the whole value, so a fourth way is a failure too.
		bad "the system-ops redirect is not the target it should be (${SO_LOC})"
	else
		ok "system-ops.php encodes the table name into one parameter (${SO_LOC})"
	fi

	# Nothing may have been written: the field type was not one the handler
	# accepts, and the settings are shared by the whole install.
	if [ "$(adb "SELECT COUNT(*) FROM settings WHERE value LIKE '%zz_so_field%'")" != 0 ]; then
		bad "the refused add_field POST wrote zz_so_field into the settings"
	else
		ok "the refused add_field POST wrote nothing to the settings"
	fi
fi

# 100. pikaCase::removeContact() put the conflict id from the request inside a
# quoted literal, right beside the case_id clause that is the whole ownership
# check on that DELETE. ops/delete_conflict.php reads the id with
# pl_grab_post(), which rewrites angle brackets and nothing else, so a single
# quote reached the query: a value carrying one could close the literal and
# write its own condition in place of the ownership clause. A user who may edit
# one case could then delete conflict rows belonging to a case they may not see.
# The handler does check the CSRF token and does check that the caller may edit
# the case it names, so this needed a signed-in user, not a stranger.
#
# Two cases are seeded with one conflict row each. The request names case A and
# carries a value aimed at case B's row. Case B's row has to survive.
echo
echo "100. a conflict id carrying a quote cannot delete another case's conflict row"

# The conflict rows carry no marker of their own, so they are found through
# either of the two rows that do: the contact and the cases. Both markers are
# read, because a row is orphaned the moment only one of them is gone.
DC_MARKED="conflict_id IN (SELECT conflict_id FROM conflict WHERE contact_id IN (SELECT contact_id FROM contacts WHERE last_name='ZZDCONF') OR case_id IN (SELECT case_id FROM cases WHERE number LIKE 'ZZ-DC-%'))"

cleanup_dc() {
	if command -v adb >/dev/null 2>&1; then
		adb "DELETE FROM conflict WHERE ${DC_MARKED}" >/dev/null 2>&1
		# The markers go only once nothing points at them. There is no foreign
		# key here, so a conflict DELETE that failed would leave rows whose
		# only markers are this contact and these cases -- and removing those
		# would strand the rows where no later run could find them.
		DC_ORPHANS="$(adb "SELECT COUNT(*) FROM conflict WHERE ${DC_MARKED}" 2>/dev/null)"
		if [ "$DC_ORPHANS" = 0 ]; then
			adb "DELETE FROM cases WHERE number LIKE 'ZZ-DC-%'" >/dev/null 2>&1
			adb "DELETE FROM contacts WHERE last_name='ZZDCONF'" >/dev/null 2>&1
		else
			printf '  note section 100 left %s conflict row(s) it could not delete, and kept its ZZDCONF contact and ZZ-DC-%% cases so a later run can find them\n' "$DC_ORPHANS"
		fi
	fi
}

if ! command -v adb >/dev/null 2>&1; then
	printf '  skip the conflict-delete check (needs the database)\n'
elif ! adb "SELECT 1" >/dev/null 2>&1; then
	bad "section 100 cannot reach the database, so it cannot tell what the DELETE removed"
else
	cleanup_dc
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_dc' EXIT

	DC_CONTACT="$(adb "SELECT COALESCE(MAX(contact_id),0)+1 FROM contacts")"
	adb "INSERT INTO contacts (contact_id, first_name, last_name) VALUES (${DC_CONTACT},'Zz','ZZDCONF')" >/dev/null
	DC_CASE_A="$(adb "SELECT COALESCE(MAX(case_id),0)+1 FROM cases")"
	adb "INSERT INTO cases (case_id, number, user_id, office, status, client_id) VALUES (${DC_CASE_A},'ZZ-DC-A',1,'ZZOFF','1',${DC_CONTACT})" >/dev/null
	DC_CASE_B="$(adb "SELECT COALESCE(MAX(case_id),0)+1 FROM cases")"
	adb "INSERT INTO cases (case_id, number, user_id, office, status, client_id) VALUES (${DC_CASE_B},'ZZ-DC-B',1,'ZZOFF','1',${DC_CONTACT})" >/dev/null

	# conflict_id is a plain integer key with a default of 0, not an
	# auto-increment column, so each row has to be given its own id.
	DC_ROW_A="$(adb "SELECT COALESCE(MAX(conflict_id),0)+1 FROM conflict")"
	adb "INSERT INTO conflict (conflict_id, case_id, contact_id, relation_code) VALUES (${DC_ROW_A},${DC_CASE_A},${DC_CONTACT},1)" >/dev/null
	DC_ROW_B="$(adb "SELECT COALESCE(MAX(conflict_id),0)+1 FROM conflict")"
	adb "INSERT INTO conflict (conflict_id, case_id, contact_id, relation_code) VALUES (${DC_ROW_B},${DC_CASE_B},${DC_CONTACT},1)" >/dev/null

	# The path base_url gives this deployment, taken from OCM_URL so the check
	# does not have to know it: "http://host:port/cms" -> "/cms". Section 34i
	# works this out too, but it may have been skipped.
	DC_BASE="$(printf '%s' "$OCM_URL" \
		| sed -e 's#^[A-Za-z][A-Za-z0-9+.-]*://[^/]*##' -e 's#/*$##')"

	DC_SEEDED="$(adb "SELECT COUNT(*) FROM conflict WHERE conflict_id IN (${DC_ROW_A},${DC_ROW_B}) AND contact_id=${DC_CONTACT}")"

	curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" "$OCM_URL/prefs.php" >/dev/null
	DC_TOKEN="$(grep -oE 'name="_csrf" value="[0-9a-f]*"' "$BODY" \
		| head -1 | sed -E 's/.*value="([0-9a-f]*)".*/\1/')"

	if [ "$DC_SEEDED" != 2 ]; then
		bad "section 100 seeded ${DC_SEEDED} of its 2 conflict rows, so nothing below it was tested"
	elif [ "${#DC_TOKEN}" -ne 64 ]; then
		bad "no CSRF token for the delete_conflict POST - section 100 is untested"
	else
		# The value does not begin with the id it names. conflict_id is an
		# integer column, so a value beginning with that id would be read back
		# as that id and delete the same row whether the rest of it reached the
		# query or not. It begins with 0, which names no row.
		DC_TRY="0' OR conflict_id='${DC_ROW_B}'#"
		DC_LOC="$(curl -s --max-time 30 -b "$COOKIES" -o /dev/null -D - \
			--data-urlencode "_csrf=${DC_TOKEN}" \
			--data-urlencode "case_id=${DC_CASE_A}" \
			--data-urlencode "conflict_id=${DC_TRY}" \
			"$OCM_URL/ops/delete_conflict.php" \
			| grep -i '^location:' | tr -d '\r' | head -1 \
			| sed -e 's/^[Ll][Oo][Cc][Aa][Tt][Ii][Oo][Nn]: *//')"

		# Each count is read into a variable and reported as read. An adb that
		# failed answers nothing, and a check that treats "not 1" as proof of a
		# deletion would report a deletion it never saw.
		DC_LEFT_B="$(adb "SELECT COUNT(*) FROM conflict WHERE conflict_id=${DC_ROW_B}")"
		DC_LEFT_A="$(adb "SELECT COUNT(*) FROM conflict WHERE conflict_id=${DC_ROW_A}")"

		if [ -z "$DC_LOC" ]; then
			bad "ops/delete_conflict.php sent no Location header for the quoted conflict_id (status unknown, ${DC_LEFT_B} row(s) left of case ${DC_CASE_B}'s)"
		elif [ "$DC_LOC" != "${DC_BASE}/case.php?case_id=${DC_CASE_A}&screen=info" ]; then
			bad "ops/delete_conflict.php did not redirect back to the case it was given (${DC_LOC})"
		elif [ "$DC_LEFT_B" != 1 ]; then
			bad "case ${DC_CASE_B}'s conflict row reads as [${DC_LEFT_B}] rows, not 1, after a request naming case ${DC_CASE_A} with a quoted conflict_id (an empty count means the read itself failed)"
		elif [ "$DC_LEFT_A" != 1 ]; then
			bad "the named case's own conflict row reads as [${DC_LEFT_A}] rows, not 1, after a conflict_id that names no row"
		else
			ok "a conflict_id carrying a quote deletes nothing (case ${DC_CASE_B}'s row survived a request naming case ${DC_CASE_A})"
		fi

		# The ownership clause itself, which the check above does not reach:
		# that value begins with 0, so the cast now returns before any SQL
		# runs, and dropping "AND case_id=..." from the query would leave it
		# green. This one is a plain number, so it reaches the DELETE and only
		# the case_id clause stands between it and another case's row.
		#
		# This request does not answer the way the one above does. When the
		# clause stops the delete, DB::affectedRows() is 0, and
		# pikaCase::removeContact() raises an error for that, which renders the
		# Pika error page and exits before ops/delete_conflict.php reaches its
		# redirect. So accept either shape -- the error page, or the ordinary
		# redirect back to the case -- and let the row count decide which of
		# them happened. What must not pass is a refusal that never reached
		# the delete at all: pl_csrf_check() answers 403 text/plain or renders
		# its recovery form, and neither is one of these two shapes.
		#
		# curl's redirect_url is read instead of the raw header so the status
		# and the destination come back from the same request as the body.
		DC_OUT2="$(curl -s --max-time 30 -b "$COOKIES" -o "$BODY" \
			-w '%{http_code} %{redirect_url}' \
			--data-urlencode "_csrf=${DC_TOKEN}" \
			--data-urlencode "case_id=${DC_CASE_A}" \
			--data-urlencode "conflict_id=${DC_ROW_B}" \
			"$OCM_URL/ops/delete_conflict.php")"
		DC_CODE2="${DC_OUT2%% *}"
		DC_REDIR2="${DC_OUT2#* }"

		DC_LEFT_B="$(adb "SELECT COUNT(*) FROM conflict WHERE conflict_id=${DC_ROW_B}")"

		DC_REACHED=0
		if [ "$DC_CODE2" = 302 ] \
			&& [ "$DC_REDIR2" = "$OCM_URL/case.php?case_id=${DC_CASE_A}&screen=info" ]; then
			DC_REACHED=1
		elif [ "$DC_CODE2" = 200 ] && grep -q 'Pika Error' "$BODY"; then
			DC_REACHED=1
		fi

		if [ "$DC_REACHED" != 1 ]; then
			bad "the cross-case delete request answered HTTP ${DC_CODE2} with neither the case redirect nor the refused-delete page, so it did not reach the delete (${DC_LEFT_B} row(s) left of case ${DC_CASE_B}'s)"
		elif [ "$DC_LEFT_B" != 1 ]; then
			bad "case ${DC_CASE_B}'s conflict row reads as [${DC_LEFT_B}] rows, not 1, after its plain numeric id was posted through case ${DC_CASE_A} - the DELETE is not checking which case owns the row"
		else
			ok "a conflict row is not deleted through a case that does not own it"
		fi

		# The positive control. Without it every check above would pass on a
		# handler that had stopped deleting anything at all.
		curl -s --max-time 30 -b "$COOKIES" -o /dev/null \
			--data-urlencode "_csrf=${DC_TOKEN}" \
			--data-urlencode "case_id=${DC_CASE_A}" \
			--data-urlencode "conflict_id=${DC_ROW_A}" \
			"$OCM_URL/ops/delete_conflict.php" >/dev/null

		DC_LEFT_A="$(adb "SELECT COUNT(*) FROM conflict WHERE conflict_id=${DC_ROW_A}")"
		DC_LEFT_B="$(adb "SELECT COUNT(*) FROM conflict WHERE conflict_id=${DC_ROW_B}")"

		if [ "$DC_LEFT_A" != 0 ]; then
			bad "the conflict row case ${DC_CASE_A} owns reads as [${DC_LEFT_A}] rows after that case asked for it to be deleted, so section 100's checks establish nothing"
		elif [ "$DC_LEFT_B" != 1 ]; then
			bad "case ${DC_CASE_B}'s conflict row reads as [${DC_LEFT_B}] rows, not 1, after case ${DC_CASE_A} deleted its own"
		else
			ok "ops/delete_conflict.php still deletes the conflict row the named case owns"
		fi
	fi

	cleanup_dc
	trap 'rm -f "$COOKIES" "$BODY"' EXIT
fi

# 101. reports/inactive_user/report.php put its row-count field into the LIMIT
# clause after passing it through DB::escapeString(). A row count is not quoted,
# so escaping it rewrote nothing that was there: whatever was typed after the
# number reached the query as written, and a value that was not a number ended
# the request with a 500. reports/inactive_case/report.php casts the same field
# to int; this file was missed when that one was corrected.
#
# The report needs a date or it stops before building the query at all, so every
# request here carries one. It reports one row per staff member, and a stock
# install has only one, so two cases owned by staff ids nobody is using are
# seeded to take it to three: with one row no limit can be told from any other,
# and with two a limit of two cannot be told from that limit with an offset.
echo
echo "101. the inactive staff report casts its row-count field instead of escaping it"

cleanup_iu() {
	if command -v adb >/dev/null 2>&1; then
		adb "DELETE FROM cases WHERE number LIKE 'ZZ-IU-%'" >/dev/null 2>&1
		# The contact goes only once no case points at it, for the same reason
		# as section 100: the cases are findable by their own number, but a
		# case left behind without its contact is a case whose client row is
		# gone, which is not a state this fixture should leave in the database.
		IU_ORPHANS="$(adb "SELECT COUNT(*) FROM cases WHERE number LIKE 'ZZ-IU-%'" 2>/dev/null)"
		if [ "$IU_ORPHANS" = 0 ]; then
			adb "DELETE FROM contacts WHERE last_name='ZZIUSER'" >/dev/null 2>&1
		else
			printf '  note section 101 left %s case(s) it could not delete, and kept its ZZIUSER contact with them\n' "$IU_ORPHANS"
		fi
	fi
}

iu_post() {
	curl -s --max-time 60 -b "$COOKIES" -o "$BODY" -w '%{http_code}' \
		--data-urlencode "report_format=html" \
		--data-urlencode "inactive_date_begin=2030-01-01" \
		--data-urlencode "limit=$1" \
		"$OCM_URL/reports/inactive_user/report.php"
}

# "<strong>Limit Results:</strong> 3 Row(s)<br/>" -> "3 Row(s)", empty when the
# report did not report a limit at all.
iu_param() {
	grep -oE 'Limit Results:</strong>[^<]*' "$BODY" | head -1 \
		| sed -e 's#^Limit Results:</strong> *##'
}

# "<p>Number of rows: <em>2</em>" -> "2".
iu_rows() {
	grep -oE 'Number of rows: <em>[0-9]+</em>' "$BODY" | head -1 \
		| sed -E 's/.*<em>([0-9]+)<.*/\1/'
}

if ! command -v adb >/dev/null 2>&1; then
	printf '  skip the inactive staff report row-count check (needs the database)\n'
elif ! adb "SELECT 1" >/dev/null 2>&1; then
	bad "section 101 cannot reach the database, so it cannot seed a second report row"
else
	cleanup_iu
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_iu' EXIT

	IU_CONTACT="$(adb "SELECT COALESCE(MAX(contact_id),0)+1 FROM contacts")"
	adb "INSERT INTO contacts (contact_id, first_name, last_name) VALUES (${IU_CONTACT},'Zz','ZZIUSER')" >/dev/null
	# Staff ids no user row has. The report groups by that id, so each becomes a
	# row of its own; the name column renders empty for them, which is all they
	# are for. Two, not one, so that the row count below is at least three: a
	# limit of 2 against a total of 2 returns the same two rows whether or not
	# an OFFSET reached the query, which would hide the whole finding.
	IU_STAFF="$(adb "SELECT COALESCE(MAX(user_id),0)+1 FROM users")"
	IU_STAFF2="$((IU_STAFF + 1))"
	IU_CASE="$(adb "SELECT COALESCE(MAX(case_id),0)+1 FROM cases")"
	IU_CASE2="$((IU_CASE + 1))"
	# last_changed has to be set here. The column takes no default, so an INSERT
	# that leaves it out stores 0000-00-00, and the report's own
	# "HAVING MAX(cases.last_changed)" reads that as false and drops the row --
	# the seeded case would never appear and this section would test nothing. A
	# date in the past also satisfies the report's "activity prior to" filter.
	adb "INSERT INTO cases (case_id, number, user_id, office, status, client_id, last_changed) VALUES (${IU_CASE},'ZZ-IU-A',${IU_STAFF},'ZZOFF','1',${IU_CONTACT},'2020-01-01 00:00:00')" >/dev/null
	adb "INSERT INTO cases (case_id, number, user_id, office, status, client_id, last_changed) VALUES (${IU_CASE2},'ZZ-IU-B',${IU_STAFF2},'ZZOFF','1',${IU_CONTACT},'2020-01-01 00:00:00')" >/dev/null

	# Both seeded rows have to be there. Without this the checks below could all
	# pass on an install that already held enough rows while neither INSERT ran,
	# which would report a working test that tested nothing it set up.
	IU_SEEDED="$(adb "SELECT COUNT(*) FROM cases WHERE number IN ('ZZ-IU-A','ZZ-IU-B') AND last_changed='2020-01-01 00:00:00'")"

	# What the report holds with no limit at all, read from the report itself
	# rather than assumed, so the checks below do not depend on the install. The
	# field is sent empty rather than large: a number would cap this count too,
	# and an install holding more rows than the cap would read its own limit
	# back as the total.
	IU_CODE="$(iu_post '')"
	IU_TOTAL="$(iu_rows)"

	if [ "$IU_SEEDED" != 2 ]; then
		bad "section 101 seeded [${IU_SEEDED}] of its 2 inactive-staff cases, so nothing below it was tested"
	elif [ "$IU_CODE" != 200 ]; then
		bad "the inactive staff report answered HTTP ${IU_CODE} with no row count, so section 101 is untested"
	elif ! grep -q 'Staff Name' "$BODY"; then
		bad "the inactive staff report did not draw its table, so section 101 is untested"
	elif [ -n "$(iu_param)" ]; then
		bad "the inactive staff report reported a limit of [$(iu_param)] for an empty row count, so its unlimited total cannot be read"
	elif [ -z "$IU_TOTAL" ] || [ "$IU_TOTAL" -lt 3 ]; then
		bad "section 101 could not get three rows into the inactive staff report (it holds [${IU_TOTAL}]), so an offset cannot be told from none"
	else
		ok "the inactive staff report holds ${IU_TOTAL} rows to limit"

		# The row count has to reach the query, or a report that ignored the field
		# would satisfy every check below it.
		IU_CODE="$(iu_post 1)"
		IU_PARAM="$(iu_param)"
		IU_ROWS="$(iu_rows)"

		if [ "$IU_CODE" != 200 ]; then
			bad "the inactive staff report answered HTTP ${IU_CODE} for a row count of 1"
		elif [ "$IU_PARAM" != "1 Row(s)" ]; then
			bad "the inactive staff report reports its row count as [${IU_PARAM}] rather than [1 Row(s)]"
		elif [ "$IU_ROWS" != 1 ]; then
			bad "a row count of 1 returned ${IU_ROWS} rows, so the inactive staff report's LIMIT reaches nothing and section 101 establishes nothing"
		else
			ok "the row count the inactive staff report is given reaches its query"
		fi

		# A value that is not a number drops the clause instead of ending the
		# request. Before the cast this answered 500.
		IU_CODE="$(iu_post 'zznotanumber')"
		IU_PARAM="$(iu_param)"
		IU_ROWS="$(iu_rows)"

		if [ "$IU_CODE" != 200 ]; then
			bad "a row count that is not a number ends the inactive staff report with HTTP ${IU_CODE}"
		elif [ -n "$IU_PARAM" ]; then
			bad "a row count that is not a number is still reported as a limit of [${IU_PARAM}]"
		elif [ "$IU_ROWS" != "$IU_TOTAL" ]; then
			bad "a row count that is not a number returned ${IU_ROWS} of the report's ${IU_TOTAL} rows, so something of it still reached the query"
		else
			ok "a row count that is not a number drops the limit rather than reaching the query"
		fi

		# Anything written after the number is gone rather than escaped. The
		# number asked for is the report's whole total, so the OFFSET has to
		# change the answer if it reaches the query: "LIMIT ${IU_TOTAL}" returns
		# every row, "LIMIT ${IU_TOTAL} OFFSET 1" returns one fewer. A smaller
		# number would return the same rows either way on an install holding
		# more than that, and the check would pass with the text still in the
		# query.
		IU_CODE="$(iu_post "${IU_TOTAL} OFFSET 1")"
		IU_PARAM="$(iu_param)"
		IU_ROWS="$(iu_rows)"

		if [ "$IU_CODE" != 200 ]; then
			bad "a row count with text after it ends the inactive staff report with HTTP ${IU_CODE}"
		elif [ "$IU_PARAM" != "${IU_TOTAL} Row(s)" ]; then
			bad "text after the row count survived into the inactive staff report's limit ([${IU_PARAM}])"
		elif [ "$IU_ROWS" != "$IU_TOTAL" ]; then
			bad "a row count of \"${IU_TOTAL} OFFSET 1\" returned ${IU_ROWS} of the report's ${IU_TOTAL} rows, so the text after the number reached the query"
		else
			ok "only the number is read out of the inactive staff report's row count"
		fi
	fi

	cleanup_iu
	trap 'rm -f "$COOKIES" "$BODY"' EXIT
fi

# 102. cms/services/zip-server-ajax.php, problem-server-ajax.php and
# date_selector-server.php each defined PL_DISABLE_SECURITY, which tells
# pika_init() to skip authenticate() entirely. Anyone who could reach the server
# could reach them: no account and no cookie. Two of the three answer from the
# database -- problem-server-ajax.php returns the deployment's own configured
# problem-code menu, labels and all -- and the third renders a template.
#
# They now define PL_DISABLE_DISPLAY_LOGIN instead, so pika_init()
# authenticates as it does everywhere else and a request with no session ends
# with an empty body rather than a login page rendered where XML was asked for.
#
# Each endpoint is asked twice: once with no cookie at all, where its own marker
# must not appear, and once with this run's session, where it must. Without the
# second request a broken endpoint would read as a secure one.
echo
echo "102. the ajax service endpoints require a session"

# path|marker in the reply|what it serves
SV_CASES="services/zip-server-ajax.php?zip=55401|<zipcode|the zip code lookup
services/problem-server-ajax.php?problem=01|<problem_codes|the problem code menu
services/date_selector-server.php?field_name=act_date&container=date_selector-1&month=1&year=2026|js-date-selector|the date selector"

SV_OPEN=0
SV_CLOSED=0
SV_BROKEN=""

while IFS='|' read -r SV_PATH SV_MARK SV_WHAT; do
	[ -n "$SV_PATH" ] || continue

	# No -b and no -c: this request carries no session of any kind.
	#
	# What a stranger gets is exact, so assert it rather than only the absence
	# of the reply: pika_init() authenticates, PL_DISABLE_DISPLAY_LOGIN makes
	# authenticate() exit instead of rendering the login page, and that path sets
	# no status of its own, so the answer is HTTP 200 with a zero-byte body. "the
	# marker is missing" alone would also be satisfied by a 500 error page, by a
	# login page, and by a request that never completed at all.
	#
	# The empty 200 is what a request that gets as far as authentication gets. An
	# install with force_https set answers plain HTTP with a redirect earlier than
	# that, inside pika_init(), so this describes the endpoint only when $OCM_URL
	# is the scheme the install serves -- which it has to be for the login at the
	# top of this suite to have worked.
	SV_CODE="$(curl -s --max-time 30 -o "$BODY" -w '%{http_code}' "$OCM_URL/$SV_PATH")"
	SV_CURL=$?
	SV_BYTES="$(wc -c 2>/dev/null < "$BODY" | tr -d ' ')"
	if [ "$SV_CURL" != 0 ]; then
		SV_OPEN=$((SV_OPEN + 1))
		bad "${SV_WHAT} could not be reached without a session at all (curl exit ${SV_CURL}), so this run says nothing about it"
	elif grep -q "$SV_MARK" "$BODY"; then
		SV_OPEN=$((SV_OPEN + 1))
		bad "${SV_WHAT} served its reply to a request with no session (HTTP ${SV_CODE}, ${SV_BYTES} bytes)"
	elif [ "$SV_CODE" != 200 ] || [ "$SV_BYTES" != 0 ]; then
		SV_OPEN=$((SV_OPEN + 1))
		bad "${SV_WHAT} answered a request with no session with HTTP ${SV_CODE} and ${SV_BYTES} bytes, not the empty 200 that this endpoint gives a request which reaches authentication"
	else
		SV_CLOSED=$((SV_CLOSED + 1))
	fi

	# The same request with this run's session has to work, or the check above
	# proves nothing about authentication.
	SV_CODE2="$(curl -s --max-time 30 -b "$COOKIES" -o "$BODY" -w '%{http_code}' "$OCM_URL/$SV_PATH")"
	SV_CURL2=$?
	if [ "$SV_CURL2" != 0 ] || [ "$SV_CODE2" != 200 ] || ! grep -q "$SV_MARK" "$BODY"; then
		SV_BROKEN="${SV_BROKEN} ${SV_PATH%%\?*}"
	fi
done <<SVEOF
$SV_CASES
SVEOF

if [ "$SV_OPEN" = 0 ] && [ "$SV_CLOSED" = 3 ]; then
	ok "all 3 ajax service endpoints end a request with no session as an empty 200"
else
	bad "${SV_OPEN} of the 3 ajax service endpoints did not refuse a request with no session as an empty 200, ${SV_CLOSED} did"
fi

if [ -z "$SV_BROKEN" ]; then
	ok "all 3 still answer a signed-in request, so the check above is about the session"
else
	bad "these ajax service endpoints no longer answer a signed-in request:${SV_BROKEN}"
fi

# The session check has to come before the input validation, not after it. The
# order is set by the file itself: pika_init() runs before the pl_grab_get()
# calls that read the request. What this check adds is the observable half of
# that -- the text "Invalid field_name." is what this endpoint's validation
# sends and nothing else here sends, so a stranger receiving it is a stranger
# being answered by that validation's own reply, and an empty reply is what a
# request that reaches authentication looks like from outside. Receiving the
# text is not the same as watching the code run: it cannot show on its own that
# nothing was read first, or where execution stopped, only what came back.
# Section 8d is the regression guard on the validation itself, for a caller that
# does hold a session.
SV_MAL_CODE="$(curl -s --max-time 30 -o "$BODY" -w '%{http_code}' -G \
	--data-urlencode "field_name=a b\"c" \
	--data-urlencode "container=date_selector-1" \
	"$OCM_URL/services/date_selector-server.php")"
SV_MAL_CURL=$?
SV_MAL_BYTES="$(wc -c 2>/dev/null < "$BODY" | tr -d ' ')"
if [ "$SV_MAL_CURL" != 0 ]; then
	bad "the date selector could not be reached without a session at all (curl exit ${SV_MAL_CURL}), so this run says nothing about what a stranger's malformed request gets"
elif grep -q 'Invalid field_name' "$BODY"; then
	bad "the date selector sent a stranger the text its own field_name validation sends, so a request with no session was answered by that validation"
elif [ "$SV_MAL_CODE" != 200 ] || [ "$SV_MAL_BYTES" != 0 ]; then
	bad "the date selector answered a stranger's malformed request with HTTP ${SV_MAL_CODE} and ${SV_MAL_BYTES} bytes, and an empty 200 is what a request that reaches authentication here gets"
else
	ok "the date selector says nothing to a stranger who sends a malformed field_name (empty 200)"
fi

# pl_grab_get() returns a value in whatever shape the query string gave it, so
# field_name[]=bad arrives as an array and a string cast of it is the literal
# "Array", which the field-name pattern accepts. Output escaping kept that
# harmless -- the attribute read Array, it did not break out of the tag -- but
# the endpoint answered a request it should have refused and PHP logged an
# array-to-string warning for every use.
#
# Each PARAMETER gets its own request, with every other parameter valid. Sending
# two arrays at once proves only the first check: field_name is checked first and
# ends the request, so the container could go back to casting and this would
# still pass. The same holds inside the date guard, which covers field_value,
# month and year in one condition -- a single request with month[] still gets 400
# with either of the other two terms deleted, so all three are sent separately.
# These requests carry the session on purpose -- what is being checked here is
# the validation, not the session.
sv_arr_try()
{
	sv_arr_what="$1"
	sv_arr_mark="$2"
	shift 2
	sv_arr_code="$(curl -s --max-time 30 -b "$COOKIES" -o "$BODY" -w '%{http_code}' -G "$@" \
		"$OCM_URL/services/date_selector-server.php")"
	sv_arr_curl=$?
	if [ "$sv_arr_curl" != 0 ]; then
		bad "the date selector could not be reached with ${sv_arr_what} (curl exit ${sv_arr_curl}), so this run says nothing about it"
	elif [ "$sv_arr_code" = 400 ] && grep -q "$sv_arr_mark" "$BODY"; then
		ok "the date selector refuses ${sv_arr_what} (400, ${sv_arr_mark})"
	else
		bad "the date selector did not refuse ${sv_arr_what} with HTTP 400 and ${sv_arr_mark} (status ${sv_arr_code})"
	fi
}

sv_arr_try "an array where the field name belongs" 'Invalid field_name' \
	--data-urlencode "field_name[]=bad" \
	--data-urlencode "container=date_selector-00001"
sv_arr_try "an array where the container id belongs" 'Invalid container' \
	--data-urlencode "field_name=open_date" \
	--data-urlencode "container[]=bad"
sv_arr_try "an array where the month belongs" 'Invalid date parameter' \
	--data-urlencode "field_name=open_date" \
	--data-urlencode "container=date_selector-00001" \
	--data-urlencode "month[]=bad"
sv_arr_try "an array where the field value belongs" 'Invalid date parameter' \
	--data-urlencode "field_name=open_date" \
	--data-urlencode "container=date_selector-00001" \
	--data-urlencode "field_value[]=bad" \
	--data-urlencode "month=1" \
	--data-urlencode "year=2020"
sv_arr_try "an array where the year belongs" 'Invalid date parameter' \
	--data-urlencode "field_name=open_date" \
	--data-urlencode "container=date_selector-00001" \
	--data-urlencode "month=1" \
	--data-urlencode "year[]=bad"

# 105. pl_totp_mark_used() records the window a code was accepted in, closing
# that window and every earlier one to a replay. What it writes is therefore a
# floor, and a floor may only rise: writing a lower window back over a higher
# one reopens every code between the two to a replay that the higher value had
# already refused.
#
# Two ordinary requests are enough to try it, with no attacker involved. The
# verifier skips any window at or below the stored one, so a lower window is
# only ever accepted while the stored value is still the older one. Two
# overlapping requests do that: each reads the row before the other records,
# so both verify, one of them a window later than the other, and before this
# fix the later write was the one that stuck.
#
# The check calls the function rather than racing two requests, because a race
# cannot be made to happen on demand. Three calls decide it: one below the
# stored window, one above it, and one against a row holding NULL, which is
# what an account that has never verified a code holds.
if [ "$HAVE_COMPOSE" = 1 ] && [ "$HAVE_DB" = 1 ]; then
	# The fixture case numbered ZZPRPREFS carries the process id, and its
	# cleanup matches on its case id and its number together. That pairing is
	# the pattern followed here. The name carries a random number as well,
	# because a process id repeats - after a reboot, and across two hosts
	# sharing one database - and two runs that pick the same name can each
	# read, change and delete the other's row while believing it is their
	# own.
	#
	# Every statement below that reads or changes the fixture row matches on
	# the name as well as the id. Three do not, and cannot: the id comes from
	# a MAX over the whole table, the INSERT that creates the row has nothing
	# to match on yet, and the function under test takes a user id, so the id
	# is all its own UPDATE has to pick a row with, and the three calls
	# cannot narrow it. That UPDATE does carry one further predicate, on the
	# bound it is about to write, but that is the guard under test rather
	# than a check on whose row this is. "Cannot" describes how this fixture
	# is built, not a limit of SQL.
	sm105_user="zzfloor_${$}_${RANDOM}"
	sm105_uid="$(adb "SELECT COALESCE(MAX(user_id), 0) + 1 FROM users")"
	case "$sm105_uid" in
		''|*[!0-9]*) sm105_uid='' ;;
	esac
	if [ -z "$sm105_uid" ]; then
		bad "could not read a free user id, so the replay floor was not checked"
	else
		# group_id is NOT NULL with a default of NOGROUP, so the fixture needs
		# no group row. The account is never signed in: every call below runs
		# the function directly, so the password and the secret stay empty.
		#
		# The count matches on the name as well as the id, because the id came
		# from MAX(user_id) + 1 and another insert can take it first. It is
		# the only check that the INSERT worked, since the INSERT's own status
		# is discarded.
		#
		# What it establishes is that a row carrying this run's name holds
		# this id. That is evidence of ownership rather than proof of it, and
		# it is only as strong as the name is unrepeated. A run that loses the
		# id to another insert counts zero as long as the row that won carries
		# a different name, and it then reports the fixture as missing instead
		# of working on a row it did not create. A random number can repeat,
		# so a colliding pair is a smaller chance rather than none.
		adb "INSERT INTO users (user_id, username, password, enabled, group_id)
			VALUES (${sm105_uid}, '${sm105_user}', '', 0, 'NOGROUP')" \
			>/dev/null 2>&1
		sm105_seeded="$(adb "SELECT COUNT(*) FROM users
			WHERE user_id = ${sm105_uid} AND username = '${sm105_user}'")"

		# The window this account already spent, and the value the function
		# must refuse to go below.
		sm105_floor() {
			adb "SELECT IFNULL(totp_last_used, 'null') FROM users
				WHERE user_id = ${sm105_uid}
				AND username = '${sm105_user}'"
		}

		# PL_DISABLE_SECURITY, because this runs php with no session at all;
		# the same CLI probe idiom as section 76. The marker says the call
		# ran, so a php failure cannot be read as a value that did not move.
		sm105_mark() {
			docker compose "${COMPOSE_ARGS[@]}" exec -T app php -r '
define("PL_DISABLE_SECURITY", true);
chdir("/var/www/html/cms");
require_once("pika-danio.php");
pika_init();
pl_totp_mark_used((int) $argv[1], (int) $argv[2]);
print "MARKED";' "$sm105_uid" "$1" 2>/dev/null
		}

		if [ "$sm105_seeded" != 1 ]; then
			bad "the totp floor fixture user was not created, so none of the three calls were checked"
		else
			# A lower window must not win. Master writes it unconditionally,
			# so this is the assertion that separates the two.
			adb "UPDATE users SET totp_last_used = 101
				WHERE user_id = ${sm105_uid}
				AND username = '${sm105_user}'" >/dev/null 2>&1
			sm105_out="$(sm105_mark 100)"
			sm105_got="$(sm105_floor)"
			case "$sm105_out" in
			*MARKED*)
				if [ "$sm105_got" = 101 ]; then
					ok "a window below the stored one leaves the replay floor at 101"
				else
					bad "a window below the stored one moved the replay floor from 101 to '$sm105_got'"
				fi
				;;
			*)
				bad "the mark-used call did not run, so a lower window was not checked"
				;;
			esac

			# A real login still has to be able to raise it, or the floor
			# would freeze at the first code an account ever used.
			sm105_out="$(sm105_mark 102)"
			sm105_got="$(sm105_floor)"
			case "$sm105_out" in
			*MARKED*)
				if [ "$sm105_got" = 102 ]; then
					ok "a window above the stored one raises the replay floor to 102"
				else
					bad "a window above the stored one left the replay floor at '$sm105_got'"
				fi
				;;
			*)
				bad "the mark-used call did not run, so a higher window was not checked"
				;;
			esac

			# An account that has never verified a code holds NULL, which is
			# not a lower window and must not be treated as one.
			adb "UPDATE users SET totp_last_used = NULL
				WHERE user_id = ${sm105_uid}
				AND username = '${sm105_user}'" >/dev/null 2>&1
			sm105_out="$(sm105_mark 100)"
			sm105_got="$(sm105_floor)"
			case "$sm105_out" in
			*MARKED*)
				if [ "$sm105_got" = 100 ]; then
					ok "the first window an account uses sets the replay floor from NULL"
				else
					bad "the first window an account uses left the replay floor at '$sm105_got'"
				fi
				;;
			*)
				bad "the mark-used call did not run, so the NULL row was not checked"
				;;
			esac
		fi

		adb "DELETE FROM users WHERE user_id = ${sm105_uid}
			AND username = '${sm105_user}'" >/dev/null 2>&1
	fi
fi
echo
echo "smoke: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
