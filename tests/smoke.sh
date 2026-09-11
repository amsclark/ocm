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
# The reply body is left in $BODY, exactly as a plain curl would leave it.
sm_reauth_post() {
	sm_ra_scope="$1"
	sm_ra_url="$2"
	shift 2
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

# 8d. services/date_selector-server.php runs with PL_DISABLE_SECURITY, so it is
# reachable with no session at all. Both checks matter: a malformed field name
# is refused, and a real one still renders the calendar. Deliberately no cookie
# jar -- that is how the endpoint is actually reached.
CAL="$OCM_URL/services/date_selector-server.php"
code="$(curl -s --max-time 30 -o "$BODY" -w '%{http_code}' \
	--get --data-urlencode 'field_name="><script>x</script>' \
	--data-urlencode 'container=date_selector-00001' "$CAL")"
if [ "$code" = 400 ] && grep -q 'Invalid field_name' "$BODY"; then
	ok "date_selector-server.php refuses a malformed field_name (400)"
else
	bad "date_selector-server.php ACCEPTED a malformed field_name (status $code)"
fi

code="$(curl -s --max-time 30 -o "$BODY" -w '%{http_code}' \
	"$CAL?field_name=open_date&container=date_selector-00001&month=1&year=2020")"
size="$(wc -c < "$BODY")"
if [ "$code" = 200 ] && [ "$size" -gt 200 ]; then
	ok "date_selector-server.php still renders a legitimate field ($size bytes)"
else
	bad "date_selector-server.php refused a LEGITIMATE field (status $code, $size bytes)"
fi

# 8e. reports/index.php filters the list by the per-report permission. The admin
# must still see reports; an empty list here is the over-enforcement failure.
code="$(curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" -w '%{http_code}' \
	"$OCM_URL/reports/")"
if [ "$code" = 200 ] && ! grep -q 'not authorized to run any reports' "$BODY"; then
	ok "reports/index.php still lists reports for a permitted user"
else
	bad "reports/index.php listed NOTHING for the admin (status $code)"
fi

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
if [ -f "$templib" ] && grep -qF "preg_match('/^[A-Za-z_][A-Za-z0-9_]*\$/'" "$templib"; then
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
			DTOKEN="$(dops_token)"
			DLOC="$(curl -s --max-time 30 -c "$DJAR" -b "$DJAR" -o /dev/null -D - -X POST \
				-d "action=add_activity&cancel=1&act_url=https://zz-evil.example/steal&_csrf=${DTOKEN}" \
				"$OCM_URL/dataops.php" | grep -i '^location:' | tr -d '\r')"
			case "$DLOC" in
				*zz-evil.example*) bad "dataops.php still redirects to an off-site URL (${DLOC})" ;;
				*)                 ok "dataops.php refuses to redirect off-site" ;;
			esac

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
	mfa_window() { python3 -c 'import time; print(int(time.time()) // 30)'; }
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
sys.stdout.write('%06d' % (value % 1000000))
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
		curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" \
			"$OCM_URL/system-users.php?action=edit&user_id=${MFA_UID}" >/dev/null
	}
	# Post the account form with one MFA value. The form is the only way an
	# administrator can reach these columns, so drive it rather than the table.
	mfa_admin_set() {
		mfa_admin_edit
		mfa_tok="$(grep -oE 'name="_csrf" value="[0-9a-f]*"' "$BODY" \
			| head -1 | sed -E 's/.*value="([0-9a-f]*)".*/\1/')"
		sm_reauth_post user_admin "$OCM_URL/system-users.php" \
			-d "action=update&user_id=${MFA_UID}&_csrf=${mfa_tok}" \
			-d "username=${MFA_USER}&enabled=1&group_id=${MFA_GROUP}" \
			-d "totp_enabled=$1"
	}
	mfa_login() {
		: > "$MFA_JAR"
		curl -sL --max-time 30 -c "$MFA_JAR" -b "$MFA_JAR" -o "$BODY" \
			-d "login_user=${MFA_USER}&login_pass=${MFA_PASS}&auth_id=1&totp=${1:-}" \
			"$OCM_URL/" >/dev/null
	}

	if [ -z "$MFA_HASH" ] || [ -z "${MFA_UID:-}" ]; then
		bad "could not seed the MFA fixtures (hash/user)"
	else
		# 25a. The control renders, and the account's own secret does not.
		mfa_admin_edit
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
		if grep -q 'Set up Multi-Factor Authentication' "$BODY"; then
			ok "a user with MFA on and no device lands on the enrollment page"
		else
			bad "the enrollment gate did not fire - a user with MFA on reached the application"
		fi
		curl -sL --max-time 30 -b "$MFA_JAR" -o "$BODY" "$OCM_URL/case_list.php" >/dev/null
		if grep -q 'Set up Multi-Factor Authentication' "$BODY"; then
			ok "the gate also holds an ordinary page request"
		else
			bad "case_list.php was served to an un-enrolled account"
		fi

		# 25d. Enrolment: the page hands out a key, a wrong code is refused
		# and stores nothing, the right code stores the secret encrypted.
		curl -sL --max-time 30 -b "$MFA_JAR" -o "$BODY" "$OCM_URL/enroll_mfa.php" >/dev/null
		MFA_SECRET="$(sed -n 's/.*class="enroll-key">\([A-Z2-7]*\)<.*/\1/p' "$BODY" | head -1)"
		MFA_TOKEN="$(grep -oE 'name="enroll_token" value="[^"]*"' "$BODY" \
			| head -1 | sed -E 's/.*value="([^"]*)".*/\1/')"
		MFA_CSRF="$(grep -oE 'name="_csrf" value="[0-9a-f]*"' "$BODY" \
			| head -1 | sed -E 's/.*value="([0-9a-f]*)".*/\1/')"
		if [ "${#MFA_SECRET}" -ge 16 ] && [ -n "$MFA_TOKEN" ] && [ "${#MFA_CSRF}" -eq 64 ]; then
			ok "the enrollment page renders a key, a pending token and a CSRF token"
		else
			bad "the enrollment page is incomplete (key ${#MFA_SECRET} chars, token ${#MFA_TOKEN} chars, csrf ${#MFA_CSRF} chars)"
		fi

		# The way out. An account that is held on the enrollment page has
		# exactly one other link, and the enrollment gate lets exactly one
		# other page through. A link that 404s leaves a user who cannot
		# enrol -- lost phone, no authenticator app yet -- with no way to
		# end the session at all. Follow the link the page actually renders
		# rather than reading the source, so a future edit that points it
		# somewhere else is caught too.
		MFA_OUT="$(sed -n 's/.*<a href="\([^"]*logout[^"]*\)".*/\1/p' "$BODY" | head -1)"
		# base_url is a path, not an absolute URL, on a stock install.
		case "$MFA_OUT" in
			http*) ;;
			/*) MFA_OUT="$(printf '%s' "$OCM_URL" | sed -E 's#^(https?://[^/]+).*#\1#')${MFA_OUT}" ;;
		esac
		# Without the fixture's cookies: following it with them would end the
		# session the rest of this section still needs. Whether the URL
		# exists is the whole question.
		if [ -n "$MFA_OUT" ] \
			&& [ "$(curl -s --max-time 30 -o /dev/null -w '%{http_code}' "$MFA_OUT")" != 404 ]; then
			ok "the enrollment page's sign-out link resolves"
		else
			bad "the enrollment page's sign-out link is broken (${MFA_OUT:-none found})"
		fi

		mfa_enroll_post() {
			curl -sL --max-time 30 -b "$MFA_JAR" -o "$BODY" \
				--data-urlencode "enroll_token=${MFA_TOKEN}" \
				--data-urlencode "_csrf=${MFA_CSRF}" \
				--data-urlencode "mfa_code=$1" \
				"$OCM_URL/enroll_mfa.php" >/dev/null
		}

		if [ "${#MFA_SECRET}" -lt 16 ]; then
			bad "no enrollment key - the rest of section 25 is untested"
		else
			mfa_enroll_post 000000
			if grep -q 'That code did not match' "$BODY" \
				&& [ -z "$(adb "SELECT totp_secret FROM users WHERE user_id = ${MFA_UID} AND LENGTH(totp_secret) > 0")" ]; then
				ok "a wrong enrollment code is refused and stores nothing"
			else
				bad "a wrong enrollment code was accepted, or stored a secret anyway"
			fi

			MFA_ENROL_WINDOW="$(mfa_window)"
			MFA_ENROL_CODE="$(mfa_code "$MFA_SECRET")"
			mfa_enroll_post "$MFA_ENROL_CODE"
			if grep -qi 'logout' "$BODY" && ! grep -q 'Set up Multi-Factor Authentication' "$BODY"; then
				ok "the right enrollment code finishes enrollment and opens the application"
			else
				bad "the right enrollment code did not finish enrollment"
			fi
			if [ "$(adb "SELECT LEFT(totp_secret, 4) FROM users WHERE user_id = ${MFA_UID}")" = 'enc:' ]; then
				ok "the stored secret is encrypted at rest"
			else
				bad "the stored secret is not in the enc: format - it may be cleartext"
			fi
			if [ -n "$(adb "SELECT 1 FROM audit_log WHERE action = 'user.totp_self_enrolled' LIMIT 1")" ]; then
				ok "audit_log recorded user.totp_self_enrolled"
			else
				bad "audit_log has no user.totp_self_enrolled row"
			fi
			curl -sL --max-time 30 -b "$MFA_JAR" -o "$BODY" "$OCM_URL/enroll_mfa.php" >/dev/null
			if grep -q 'class="enroll-key"' "$BODY"; then
				bad "enroll_mfa.php hands out a second key to an already-enrolled account"
			else
				ok "enroll_mfa.php refuses to re-issue a key to an enrolled account"
			fi

			# 25e. The login form now needs the code.
			mfa_rl_clear
			mfa_login
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

			# Wait for the next 30-second window so that the code used during
			# enrollment is in the past. Capped: a stopped clock must not hang
			# the suite.
			mfa_waited=0
			while [ "$(mfa_window)" = "$MFA_ENROL_WINDOW" ] && [ "$mfa_waited" -lt 35 ]; do
				sleep 1
				mfa_waited=$((mfa_waited+1))
			done

			mfa_rl_clear
			mfa_login "$MFA_ENROL_CODE"
			if grep -q 'login_pass' "$BODY"; then
				ok "a code that was already used is refused"
			else
				bad "a used code was accepted a second time - the replay guard is not working"
			fi

			mfa_rl_clear
			mfa_login "$(mfa_code "$MFA_SECRET")"
			if ! grep -q 'login_pass' "$BODY" && grep -qi 'logout' "$BODY"; then
				ok "the password and a current code sign the account in"
			else
				bad "a valid password and a valid code were refused"
			fi

			# 25f. The admin sees the enrolled state, and Reset sends the
			# account back to enrollment without turning the requirement off.
			mfa_admin_edit
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

			mfa_admin_set 2
			if [ -z "$(adb "SELECT totp_secret FROM users WHERE user_id = ${MFA_UID} AND LENGTH(totp_secret) > 0")" ] \
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
			if grep -q 'Set up Multi-Factor Authentication' "$BODY"; then
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
			if ! grep -q 'login_pass' "$BODY" && grep -qi 'logout' "$BODY"; then
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
		curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" \
			"$OCM_URL/search.php?s=%25%25%5Btotp_encryption_key%5D%25%25" >/dev/null
		if grep -q 'name="s" size="48" value=""' "$BODY" \
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
			# The legacy gate does not echo its permission template. Its only
			# output is the benchmark table when benchmarking is enabled.
			rq_bench_pattern='^<br><table align=center width=500><tr><td><pre>Execution Speed:  [0-9]+([.][0-9]+)? seconds<br>File Size:  [0-9]+([.][0-9]+)?K<br></pre></td></tr></table>$'
			for rq_action in save_questionnaire add_questionnaire toggle_questionnaires diag update_answers; do
				AZTOK="$(az_token "$AZJAR")"
				code="$(curl -s --max-time 30 -b "$AZJAR" -o "$BODY" -w '%{http_code}' \
					--data-urlencode "action=${rq_action}" -d "_csrf=${AZTOK}" \
					"$OCM_URL/system-ops.php")"
				rq_denial_body="$(tr -d '\r\n' < "$BODY")"
				if [ "${#AZTOK}" -eq 64 ] && [ "$code" = 200 ] \
					&& { [ -z "$rq_denial_body" ] || [[ "$rq_denial_body" =~ $rq_bench_pattern ]]; }; then
					ok "$rq_action remains denied to a non-admin user"
				else
					bad "$rq_action did not reach the system permission gate (status $code)"
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
	LK_TODAY="$(date +%Y-%m-%d)"
	LK_OLD="$(date -d '-30 days' +%Y-%m-%d 2>/dev/null || date -v-30d +%Y-%m-%d)"
	LK_FUTURE="$(date -d '+3 days' +%Y-%m-%d 2>/dev/null || date -v+3d +%Y-%m-%d)"

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
		# page the default tab draws. The date-picker markup carries a random
		# element id on every render, so compare with that id normalised.
		cs_normalise() {
			sed -E 's/date_selector-[0-9]+/date_selector-ID/g' "$1"
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
# appear ANYWHERE in the setting. With 'extensions' set to 'billing', a request
# for the directory 'bill' passed; with two entries, the whole string
# 'billing,intake' passed as one name. Any directory under cms-custom/extensions
# whose name is a substring of the setting could be loaded. The check now
# compares against the parsed list, exactly.
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

	cleanup_pm() {
		adb "DELETE FROM settings WHERE label = 'extensions'" >/dev/null
		if [ -n "${PMPREV:-}" ]; then
			adb "INSERT INTO settings (label, value) VALUES ('extensions', '${PMPREV}')" >/dev/null
		fi
		# Only the three fixture directories, never the whole extensions tree.
		docker compose "${COMPOSE_ARGS[@]}" exec -T app rm -rf \
			/var/www/html/cms-custom/extensions/zzextra \
			/var/www/html/cms-custom/extensions/zzext \
			"/var/www/html/cms-custom/extensions/zzextra,zzother" </dev/null >/dev/null 2>&1
	}
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_pm' EXIT
	cleanup_pm

	# Two entries, so the comma fixture below can carry the whole setting
	# string as one directory name.
	adb "DELETE FROM settings WHERE label = 'extensions'" >/dev/null
	adb "INSERT INTO settings (label, value) VALUES ('extensions', 'zzextra,zzother')" >/dev/null

	# zzextra is enabled. zzext is a prefix of it and is NOT enabled.
	# 'zzextra,zzother' is the entire setting string as one directory name.
	docker compose "${COMPOSE_ARGS[@]}" exec -T app sh -s >/dev/null 2>&1 <<'PMSEED'
D=/var/www/html/cms-custom/extensions
mkdir -p "$D/zzextra" "$D/zzext" "$D/zzextra,zzother"
printf '<?php echo "ZZPM-ENABLED-OK";\n' > "$D/zzextra/zzhello.php"
printf '<?php echo "ZZPM-SUBSTRING-OK";\n' > "$D/zzext/zzhello.php"
printf '<?php echo "ZZPM-COMMA-OK";\n' > "$D/zzextra,zzother/zzhello.php"
printf 'ZZPM-SECRET-TXT\n' > "$D/zzextra/zzsecret.txt"
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

		# Nor is the whole comma-separated setting string one directory name.
		code="$(pm_get 'zzextra,zzother/zzhello.php')"
		if ! grep -q 'ZZPM-COMMA-OK' "$BODY"; then
			ok "the whole extensions setting is not one directory name"
		else
			bad "a directory named after the whole setting string was loaded"
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

		code="$(tr_get '')"
		if [ "$code" = 200 ] && grep -qF 'No Case #' "$BODY"; then
			ok "transfer.php with no case says 'No Case #'"
		else
			bad "transfer.php with no case answers ${code} without 'No Case #'"
		fi

		code="$(tr_get 'case_id=zznotanumber')"
		if [ "$code" = 200 ] && grep -qF 'No Case #' "$BODY"; then
			ok "transfer.php with a non-numeric case_id says 'No Case #'"
		else
			bad "transfer.php with a non-numeric case_id answers ${code} without 'No Case #'"
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
		if [ "$code" = 200 ] && ! grep -qF 'onfocus' "$BODY"; then
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
echo "57. a syndicated feed cannot write the home page"

# cms/index.php draws every enabled row in rss_feeds on the home page. The
# channel title went into an <h2> as it arrived, the entry link went into an
# unquoted href= attribute, and the body was filtered with
# strip_tags($content,'<a><ul><ol><li><p>') - which keeps every attribute on
# the tags it keeps, so a feed could ship onmouseover= on an allowed <a> and
# point its href at javascript:. A feed with a title and no items reached
# count(null) in pikaRssFeed::parseRSS() and answered the whole home page
# with an empty HTTP 500. And updateFeeds() handed feed_url straight to
# file_get_contents(), so file:// read a local file and drew it on the page.
if [ "$HAVE_DB" = 1 ]; then

	RSSID=9057
	RSSFILE=/tmp/zzrss_local.xml

	cleanup_rss() {
		adb "DELETE FROM rss_feeds WHERE feed_id = ${RSSID}" >/dev/null
		if [ "$HAVE_COMPOSE" = 1 ]; then
			docker compose "${COMPOSE_ARGS[@]}" exec -T app rm -f "$RSSFILE" >/dev/null 2>&1
		fi
	}
	trap 'rm -f "$COOKIES" "$BODY"; cleanup_rss' EXIT
	cleanup_rss

	rss_set() {
		# $1 = feed_url, $2 = feed_cache, $3 = last_modified expression
		adb "DELETE FROM rss_feeds WHERE feed_id = ${RSSID}" >/dev/null
		adb "INSERT INTO rss_feeds (feed_id, name, feed_url, feed_cache, feed_type,
			enabled, list_limit, last_modified, created)
			VALUES (${RSSID}, 'ZZRSSFEED', '${1}', '${2}', 1, 1, 5, ${3}, NOW())" >/dev/null
	}

	rss_home() {
		curl -s --max-time 60 -b "$COOKIES" -o "$BODY" -w '%{http_code}' \
			"$OCM_URL/index.php"
	}

	# An unreachable port on the loopback interface, so nothing in this
	# section can reach the network. NOW() keeps updateFeeds() from trying.
	RSSDEAD='http://127.0.0.1:1/none.xml'

	# 1. Every scriptable piece of a feed at once: markup in the channel
	#    title, an attribute breakout in the link, and a body carrying an
	#    event handler, a javascript: href and a <script> element.
	rss_set "$RSSDEAD" \
		'<?xml version="1.0"?><rss version="2.0"><channel><title>ZZRSSTITLE&lt;img src=x onerror=zzrsspwn&gt;</title><item><title>ZZRSSITEM</title><link>x onmouseover=zzrsspwn</link><description>&lt;a href="javascript:zzrsspwn"&gt;ZZRSSBODY&lt;/a&gt;&lt;script&gt;zzrsspwn&lt;/script&gt;&lt;p onclick="zzrsspwn"&gt;ZZRSSPARA&lt;/p&gt;</description></item></channel></rss>' \
		'NOW()'

	RSSCODE="$(rss_home)"
	if [ "$RSSCODE" = 200 ]; then
		ok "the home page still draws with a feed enabled"
	else
		bad "the home page answered $RSSCODE with a feed enabled"
	fi

	if grep -q 'ZZRSSTITLE' "$BODY"; then
		ok "the feed title reaches the home page"
	else
		bad "the feed title is missing - this section is testing nothing"
	fi

	if grep -qF '<img src=x onerror=' "$BODY"; then
		bad "a feed channel title puts a live <img> tag on the home page"
	else
		ok "a feed channel title cannot put a tag on the home page"
	fi

	# The link is drawn inside href="...". An unquoted attribute let the
	# value end it and add one of its own.
	if grep -qE '<a href=[^"]' "$BODY"; then
		bad "the feed link is drawn into an unquoted href attribute"
	else
		ok "the feed link is drawn into a quoted href attribute"
	fi

	if grep -qF 'onmouseover=' "$BODY"; then
		bad "a feed link breaks out of the href attribute and adds a handler"
	else
		ok "a feed link cannot break out of the href attribute"
	fi

	if grep -qF 'javascript:' "$BODY"; then
		bad "a feed body keeps a javascript: link"
	else
		ok "a feed body cannot keep a javascript: link"
	fi

	if grep -qF 'onclick="zzrsspwn"' "$BODY"; then
		bad "a feed body keeps an event handler on an allowed tag"
	else
		ok "a feed body cannot keep an event handler on an allowed tag"
	fi

	# The words survive even though the markup does not - the allowed tags
	# are a feature, and dropping the text would be a regression.
	if grep -q 'ZZRSSBODY' "$BODY" && grep -q 'ZZRSSPARA' "$BODY"; then
		ok "the feed body text still reaches the home page"
	else
		bad "the feed body text was dropped - the sanitizer is too tight"
	fi

	# 2. A feed with a channel title and no items.
	rss_set "$RSSDEAD" \
		'<?xml version="1.0"?><rss version="2.0"><channel><title>ZZRSSEMPTY</title></channel></rss>' \
		'NOW()'

	RSSCODE="$(rss_home)"
	if [ "$RSSCODE" = 200 ]; then
		ok "a feed with no items does not break the home page"
	else
		bad "a feed with no items answered $RSSCODE - count() on a missing key"
	fi

	# 3. A feed carrying a DOCTYPE. The parser has to refuse the document:
	#    a DOCTYPE can declare an entity that reads a file or that expands
	#    until the request runs out of memory.
	rss_set "$RSSDEAD" \
		'<?xml version="1.0"?><!DOCTYPE rss><rss version="2.0"><channel><title>ZZRSSDOCTYPE</title><item><title>t</title><link>http://example.com/</link><description>d</description></item></channel></rss>' \
		'NOW()'

	RSSCODE="$(rss_home)"
	if [ "$RSSCODE" = 200 ] && ! grep -q 'ZZRSSDOCTYPE' "$BODY"; then
		ok "a feed declaring a DOCTYPE is refused"
	else
		bad "a feed declaring a DOCTYPE is parsed anyway (http $RSSCODE)"
	fi

	# 4. A feed URL naming a local file. The stale last_modified makes
	#    updateFeeds() fetch it.
	if [ "$HAVE_COMPOSE" = 1 ]; then
		docker compose "${COMPOSE_ARGS[@]}" exec -T app sh -c \
			"printf '%s' '<?xml version=\"1.0\"?><rss version=\"2.0\"><channel><title>ZZRSSLOCALFILE</title><item><title>t</title><link>http://example.com/</link><description>d</description></item></channel></rss>' > $RSSFILE" >/dev/null 2>&1

		rss_set "file://${RSSFILE}" '' "'2000-01-01 00:00:00'"

		RSSCODE="$(rss_home)"
		if [ "$RSSCODE" = 200 ] && ! grep -q 'ZZRSSLOCALFILE' "$BODY"; then
			ok "a feed URL cannot name a local file"
		else
			bad "a feed URL read a local file onto the home page (http $RSSCODE)"
		fi

		if [ "$(adb "SELECT LENGTH(feed_cache) FROM rss_feeds WHERE feed_id = ${RSSID}")" = 0 ]; then
			ok "a rejected feed URL is never fetched"
		else
			bad "a rejected feed URL was fetched into the feed cache"
		fi
	else
		printf '  skip the local file feed checks (needs docker compose)\n'
	fi

	# 5. A well formed feed over http still draws its markup, so the
	#    hardening did not turn the feature off.
	rss_set "$RSSDEAD" \
		'<?xml version="1.0"?><rss version="2.0"><channel><title>ZZRSSGOOD</title><item><title>ZZRSSGOODITEM</title><link>http://example.com/story</link><description>&lt;p&gt;ZZRSSGOODTEXT &lt;a href="http://example.com/more"&gt;ZZRSSGOODLINK&lt;/a&gt;&lt;/p&gt;</description></item></channel></rss>' \
		'NOW()'

	RSSCODE="$(rss_home)"
	if [ "$RSSCODE" = 200 ] && grep -qF '<a href="http://example.com/story">ZZRSSGOODITEM</a>' "$BODY"; then
		ok "a good feed entry still links to its story"
	else
		bad "a good feed entry lost its link (http $RSSCODE)"
	fi

	if grep -qF '<p>ZZRSSGOODTEXT <a href="http://example.com/more">ZZRSSGOODLINK</a></p>' "$BODY"; then
		ok "a good feed body keeps its allowed markup"
	else
		bad "a good feed body lost the markup the feature allows"
	fi

	cleanup_rss
	trap 'rm -f "$COOKIES" "$BODY"' EXIT
else
	printf '  skip the syndicated feed checks (needs the database)\n'
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
# 'extensions' set to 'project', cms-custom/extensions/pro was reachable, and a
# directory named after two enabled extensions joined by the comma that
# separates them was reachable too.
if [ "$HAVE_DB" = 1 ] && [ "$HAVE_COMPOSE" = 1 ]; then
	# 'zzpmext' and 'zzpmb' are enabled. 'zzpm' is a substring of the setting
	# and is NOT enabled; neither is the literal name 'zzpmext,zzpmb', which
	# is the whole setting value and so sits inside it.
	PMEXT='zzpmext'
	PMSUB='zzpm'
	PMSECOND='zzpmb'
	PMSPAN='zzpmext, zzpmb'
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
	adb "INSERT INTO settings (label, value) VALUES ('extensions', '${PMSPAN}')" >/dev/null

	# Four plants: both enabled extensions, a directory whose name is a
	# substring of the setting, and a directory whose name is the whole
	# setting value, comma and space included.
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

	# 62d. The other reachable shape of the same bug: a directory named after
	# the whole setting value. It is inside the setting string, so strpos()
	# accepted it, but it is not one of the names the setting lists.
	if [ -z "$(pm_get "/zzpmext,%20zzpmb/ok.php")" ]; then
		ok "a directory named after the whole setting value is refused"
	else
		bad "AN EXTENSION THAT IS NOT ENABLED RAN — its name spans the comma in the setting (CWE-98)"
	fi

	# 62e. Control: the setting is a comma list, and the space an operator
	# naturally types after the comma must not stop the second name matching.
	if [ "$(pm_get "/${PMSECOND}/ok.php")" = "ZZPM-SECOND-RAN" ]; then
		ok "the second name in the comma list still runs"
	else
		bad "a comma-list entry with a leading space no longer runs"
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
# cal_day.php, cal_week.php, cal_adv.php and services/cal-rss.php took a user
# id off the query string and drew that user's activities, with the summary and
# the notes, for anyone who asked. cal-rss.php did not even require a login: it
# set PL_DISABLE_SECURITY, so an unauthenticated GET returned a week of a named
# user's appointments and case notes as XML.
#
# All four pages now ask pl_can_view_user_calendar() (cms/pika-danio.php):
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
	# fix, this exact request returned the row seeded above to anybody on the
	# network.
	curl -s --max-time 30 -o "$BODY" "$OCM_URL/services/cal-rss.php?user_id=1" >/dev/null
	if grep -qF 'ZZ-CAL-PRIVATE' "$BODY"; then
		bad "cal-rss.php SERVES A USER'S APPOINTMENTS AND NOTES WITH NO LOGIN (CWE-306)"
	elif grep -q 'login_pass' "$BODY"; then
		ok "cal-rss.php asks an anonymous caller to log in ($(wc -c < "$BODY") bytes)"
	else
		bad "cal-rss.php gave neither the feed nor a login form ($(wc -c < "$BODY") bytes)"
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

			curl -s --max-time 30 -b "$CAL_JAR" -o "$BODY" \
				"$OCM_URL/services/cal-rss.php?user_id=1" >/dev/null
			if grep -qF 'ZZ-CAL-PRIVATE' "$BODY"; then
				bad "cal-rss.php SERVES ANOTHER USER'S FEED TO A USER WITH NO PERMISSIONS"
			else
				ok "cal-rss.php refuses another user's feed with sharing off"
			fi

			# The refusal is scoped to other people. Own calendar, and the feed
			# with no user_id at all, still work with sharing off.
			cal_probe "own cal_day with sharing off" "cal_day.php?user_id=${CAL_UID}" allow
			curl -s --max-time 30 -b "$CAL_JAR" -o "$BODY" \
				"$OCM_URL/services/cal-rss.php" >/dev/null
			if grep -q '<rss' "$BODY"; then
				ok "cal-rss.php still serves the caller their own feed"
			else
				bad "cal-rss.php does not serve the caller's own feed ($(wc -c < "$BODY") bytes)"
			fi

			# The feed is XML now, not the text/html it used to claim.
			CAL_CT="$(curl -s --max-time 30 -b "$CAL_JAR" -o /dev/null -D - \
				"$OCM_URL/services/cal-rss.php" | tr -d '\r' \
				| awk 'tolower($1) == "content-type:" { print tolower($2) }' | tail -n 1)"
			case "$CAL_CT" in
				application/rss+xml*) ok "cal-rss.php sends Content-Type: $CAL_CT" ;;
				*) bad "cal-rss.php sends Content-Type: ${CAL_CT:-none}" ;;
			esac

			# 30d. A read-all group gets the colleague calendars back with
			# sharing off, which is what calendar_admin resolves to.
			adb "UPDATE \`groups\` SET read_all = 1 WHERE group_id = '${CAL_GROUP}'" >/dev/null
			cal_login
			cal_probe "cal_day, read_all, sharing off" "cal_day.php?user_id=1" allow
			cal_probe "cal_week, read_all, sharing off" "cal_week.php?user_id=1" allow
			cal_probe "cal_adv, read_all, sharing off" "cal_adv.php?user_list%5B%5D=1" allow

			curl -s --max-time 30 -b "$CAL_JAR" -o "$BODY" \
				"$OCM_URL/services/cal-rss.php?user_id=1" >/dev/null
			if grep -qF 'ZZ-CAL-PRIVATE' "$BODY"; then
				ok "cal-rss.php serves another user's feed to a read-all group"
			else
				bad "a read-all group did NOT get another user's feed ($(wc -c < "$BODY") bytes)"
			fi

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
echo "smoke: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
