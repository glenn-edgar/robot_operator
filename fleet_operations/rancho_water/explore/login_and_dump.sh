#!/usr/bin/env bash
# rancho_water/explore/login_and_dump.sh — PoC scraper for the Rancho Water
# customer portal. Logs in with the credentials from
# farm_soil/secrets/ttn.env (gitignored), then GETs the waterflow page and
# dumps the rendered HTML to var/rancho_explore/.
#
# This is an EXPLORATION script, not the eventual production skill. Its
# whole job is to land readable HTML on disk so we can decide what to
# extract; the real skill in rancho_water/lib/ will be designed based on
# what we see in those dumps.
#
# Run from anywhere:
#   fleet_design/rancho_water/explore/login_and_dump.sh
#
# Outputs go under fleet_design/var/rancho_explore/ (gitignored):
#   01_login_form.html   — what the unauthenticated GET returned
#   02_login_post.html   — what the POST returned (post-redirects)
#   03_waterflow.html    — the target page, post-login
#   cookies.txt          — Netscape-format cookie jar (session lives here)
#
# **Failure modes to expect on first run:**
#  * If the login form uses field names we didn't guess (very likely on
#    a real ASP.NET site), the POST step still runs but produces a page
#    that's still the unauthenticated login form. That's a sign to look
#    at 01_login_form.html for the actual field names and update the
#    POST_FIELDS section below.
#  * If ASP.NET requires __VIEWSTATE / __EVENTVALIDATION round-tripping
#    (it usually does), we extract those from 01_login_form.html and
#    include them in the POST body. The extractor below handles missing
#    values gracefully (just sends an empty string), which usually
#    presents differently in the response — easier to debug.

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
SECRETS=$REPO_ROOT/farm_soil/secrets/ttn.env

# ─── Secrets ──────────────────────────────────────────────────────────
if [ ! -f "$SECRETS" ]; then
    echo "ERROR: missing $SECRETS" >&2
    exit 2
fi
set -a
. "$SECRETS"
set +a

: "${RANCHO_WATER_ACCOUNT:?must be set in $SECRETS}"
: "${RANCHO_WATER_PASSWORD:?must be set in $SECRETS}"

# ─── Layout ───────────────────────────────────────────────────────────
OUT_DIR=$REPO_ROOT/var/rancho_explore
mkdir -p "$OUT_DIR"
COOKIE_JAR=$OUT_DIR/cookies.txt
rm -f "$COOKIE_JAR"   # always start with a fresh session
LOGIN_FORM=$OUT_DIR/01_login_form.html
LOGIN_POST=$OUT_DIR/02_login_post.html
WATERFLOW=$OUT_DIR/03_waterflow.html

BASE=https://myaccount.ranchowater.com
# /secure/ is the protected area we WANT; it 302s to /default.aspx?ReturnUrl=…
# which is the actual login page. Hitting /secure/ with curl -L means we land
# on the login page AND have curl resolve the right URL for our POST below.
LOGIN_ENTRY_URL=$BASE/secure/
LOGIN_POST_URL=$BASE/default.aspx?ReturnUrl=%2fsecure%2f
WATERFLOW_URL=$BASE/secure/waterflow.aspx
UA="fleet_design-rancho-explore/1.0 (+contact: glenn-edgar@onyxengr.com)"

# ─── Stage 1: GET the login form ──────────────────────────────────────
echo "[1/3] GET $LOGIN_ENTRY_URL"
curl -sS -L \
     -A "$UA" \
     -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
     -o "$LOGIN_FORM" \
     -w "      http=%{http_code} size=%{size_download} final_url=%{url_effective}\n" \
     "$LOGIN_ENTRY_URL"

# Extract one <input name="X" value="Y"> pair. ASP.NET sprinkles these
# all over the place; we only need the well-known three hidden fields.
extract_input() {
    local name=$1
    # The value may come before name= OR after — match either order.
    grep -oE "<input[^>]*name=\"$name\"[^>]*>" "$LOGIN_FORM" 2>/dev/null \
        | head -1 \
        | grep -oE 'value="[^"]*"' \
        | head -1 \
        | sed -E 's/^value="(.*)"$/\1/'
}

VIEWSTATE=$(extract_input "__VIEWSTATE" || true)
VS_GEN=$(extract_input "__VIEWSTATEGENERATOR" || true)
EV=$(extract_input "__EVENTVALIDATION" || true)

echo "      __VIEWSTATE:          ${#VIEWSTATE} bytes (prefix: ${VIEWSTATE:0:32}…)"
echo "      __VIEWSTATEGENERATOR: $VS_GEN"
echo "      __EVENTVALIDATION:    ${#EV} bytes (prefix: ${EV:0:32}…)"

# Discover candidate form fields so we know what to POST.
echo
echo "      candidate USERNAME-ish fields:"
grep -oE '<input[^>]*name="[^"]*[Uu]ser[^"]*"' "$LOGIN_FORM" | head -5 | sed 's/^/        /'
echo "      candidate PASSWORD-ish fields:"
grep -oE '<input[^>]*name="[^"]*[Pp]ass[^"]*"' "$LOGIN_FORM" | head -5 | sed 's/^/        /'
echo "      candidate SUBMIT-ish fields:"
grep -oE '<input[^>]*name="[^"]*(Login|Submit|Sign)[^"]*"' "$LOGIN_FORM" | head -5 | sed 's/^/        /'
echo "      <form ... action=...>:"
grep -oE '<form[^>]*action="[^"]*"' "$LOGIN_FORM" | head -3 | sed 's/^/        /'

# ─── Stage 2: POST the login form ─────────────────────────────────────
# Field names discovered from stage-1 output. DevExpress + ASP.NET WebForms
# uses ctl00$ContentPlaceHolder1$* names for everything inside the
# ContentPlaceHolder1 master-page region.
POST_USER_FIELD="ctl00\$ContentPlaceHolder1\$txtUsername"
POST_PASS_FIELD="ctl00\$ContentPlaceHolder1\$txtPassword"
POST_SUBMIT_FIELD="ctl00\$ContentPlaceHolder1\$btnSignIn"
POST_SUBMIT_VALUE="Sign In"

echo
echo "[2/3] POST $LOGIN_POST_URL"
echo "      user field=$POST_USER_FIELD"

# --data-urlencode encodes special chars (incl. the $ in field names).
curl -sS -L \
     -A "$UA" \
     -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
     -e "$LOGIN_ENTRY_URL" \
     --data-urlencode "__VIEWSTATE=$VIEWSTATE" \
     --data-urlencode "__VIEWSTATEGENERATOR=$VS_GEN" \
     --data-urlencode "__EVENTVALIDATION=$EV" \
     --data-urlencode "$POST_USER_FIELD=$RANCHO_WATER_ACCOUNT" \
     --data-urlencode "$POST_PASS_FIELD=$RANCHO_WATER_PASSWORD" \
     --data-urlencode "$POST_SUBMIT_FIELD=$POST_SUBMIT_VALUE" \
     -o "$LOGIN_POST" \
     -w "      http=%{http_code} size=%{size_download} final_url=%{url_effective}\n" \
     "$LOGIN_POST_URL"

# Heuristic: a successful login usually drops the password field from the
# response (we landed on a different page). Surface this so the operator
# knows whether to look at the dumps.
if grep -q 'txtPassword' "$LOGIN_POST"; then
    echo
    echo "  >>> login post returned a page that still contains the password"
    echo "      field. Login likely FAILED. Look at $LOGIN_POST for"
    echo "      an error message; also check the cookies.txt jar for any"
    echo "      .ASPXAUTH session token (its presence usually means OK)."
else
    echo "      no password field in response — login probably OK"
fi

# ─── Stage 3: GET the waterflow page with the session cookie ──────────
echo
echo "[3/3] GET $WATERFLOW_URL"
curl -sS -L \
     -A "$UA" \
     -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
     -o "$WATERFLOW" \
     -w "      http=%{http_code} size=%{size_download} final_url=%{url_effective}\n" \
     "$WATERFLOW_URL"

# ─── Report ───────────────────────────────────────────────────────────
echo
echo "──── dump complete ────"
ls -la "$OUT_DIR"
echo
echo "Next: look at $WATERFLOW (the target) — does it have water-flow"
echo "data? Is it a server-rendered table, a chart with embedded data,"
echo "or an empty shell that fetches its data via XHR? That decides the"
echo "shape of the scraper."
