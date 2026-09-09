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

echo
echo "smoke: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
