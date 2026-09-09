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


echo
echo "smoke: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
