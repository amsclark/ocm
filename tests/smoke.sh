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

echo "smoke: $OCM_URL as $OCM_USER"

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
		curl -sL --max-time 30 -b "$COOKIES" -o "$BODY" \
			-d "action=update&user_id=${MFA_UID}&_csrf=${mfa_tok}" \
			-d "username=${MFA_USER}&enabled=1&group_id=${MFA_GROUP}" \
			-d "totp_enabled=$1" \
			"$OCM_URL/system-users.php" >/dev/null
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
		curl -sL --max-time 30 -b "$COOKIES" -o /dev/null \
			-d "action=update&_csrf=${sso_tok}" \
			-d "sso_client_secret=" \
			"$OCM_URL/system-settings.php" >/dev/null
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
echo "smoke: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
