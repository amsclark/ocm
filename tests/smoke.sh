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

OCM_URL="${OCM_URL:-http://127.0.0.1:8080/cms}"
OCM_USER="${OCM_USER:-admin}"
COOKIES="$(mktemp)"
BODY="$(mktemp)"
trap 'rm -f "$COOKIES" "$BODY"' EXIT

pass=0
fail=0
HAVE_DB=0
ok()   { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

# ── Password ───────────────────────────────────────────────────────────────
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
# Needs a compose project to reach the db container; skipped when the suite is
# pointed at a host it cannot query.
if [ -n "${COMPOSE_PROJECT:-}" ] && command -v docker >/dev/null 2>&1; then
	# The password goes in MYSQL_PWD, never in a -p argument. `mariadb -p`
	# with an empty value does not mean "no password" -- it means "prompt for
	# one", and under `exec -T` there is no terminal to answer, so the client
	# blocks forever and the whole suite hangs with no output. Setting the
	# variable to an empty string is an actual empty password.
	#
	# `< /dev/null` for the same reason: nothing here should ever be able to
	# wait on stdin.
	adb() {
		docker compose -p "$COMPOSE_PROJECT" exec -T \
			-e MYSQL_PWD="${DB_PASSWORD:-}" db \
			mariadb -u"${DB_USER:-cms}" -N -B \
			-e "$1" "${DB_NAME:-cms}" </dev/null 2>/dev/null
	}
	if [ -z "$(adb 'SELECT 1')" ]; then
		# Fall back to root, which the compose file always sets.
		adb() {
			docker compose -p "$COMPOSE_PROJECT" exec -T \
				-e MYSQL_PWD="${DB_ROOT_PASSWORD:-}" db \
				mariadb -uroot -N -B \
				-e "$1" "${DB_NAME:-cms}" </dev/null 2>/dev/null
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
	printf '  skip audit log checks (set COMPOSE_PROJECT to enable)\n'
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
	printf '  skip CSRF database checks (set COMPOSE_PROJECT to enable)\n'
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
	printf '  skip upload-gate database checks (set COMPOSE_PROJECT to enable)\n'
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
	SMOKE_HASH="$(docker compose -p "$COMPOSE_PROJECT" exec -T app \
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
	printf '  skip intake permission checks (set COMPOSE_PROJECT to enable)\n'
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
if [ -n "${COMPOSE_PROJECT:-}" ]; then
	if docker compose -p "$COMPOSE_PROJECT" logs app 2>/dev/null \
		| grep -q 'invalid SQL identifier rejected by allowlist'; then
		ok "the identifier allowlist logged the rejected sort columns"
	else
		bad "no allowlist rejection in the app log - pl_safe_order_by() did not run"
	fi
else
	printf '  skip allowlist log check (set COMPOSE_PROJECT to enable)\n'
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

	SHASH="$(docker compose -p "$COMPOSE_PROJECT" exec -T app \
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
	printf '  skip search scoping checks (set COMPOSE_PROJECT to enable)\n'
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
else
	bad "section 14 skipped: no database access or no CSRF token"
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
	bad "section 15 credential checks skipped: no database access"
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
	bad "section 15 admin-page control skipped: no database access"
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
echo "smoke: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
