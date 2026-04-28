#!/usr/bin/env bash
#
# authenticate.sh — mint a GitHub App installation access token.
#
# Required env:
#   GATEWAY_APP_ID            numeric GitHub App ID
#   GATEWAY_PRIVATE_KEY       full PEM contents of the App's private key
#   GATEWAY_INSTALLATION_ID   numeric installation ID for the target org/repo
#
# Output:
#   stdout (one line): {"token":"...","expires_at":"..."}
#   stderr           : structured JSON log lines (one object per line)
#
# Exit codes:
#   0  success
#   2  system error (missing/invalid input, signing failure, network failure,
#                    or non-2xx GitHub API response)
#
# Notes:
#   - The minted token is short-lived (1h) and is the only secret-bearing
#     output; it is emitted on stdout exactly once and is never logged.
#   - The private key is materialized to a 0600 tempfile and removed via
#     EXIT trap, even on error.
#   - One retry on 5xx / network failure with a 2-second backoff. Other
#     non-2xx responses (e.g. 401, 404) are treated as fatal — retrying a
#     401 just wastes time.

set -euo pipefail

readonly SCRIPT_NAME="${BASH_SOURCE[0]##*/}"
readonly GITHUB_API="${GITHUB_API_URL:-https://api.github.com}"

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------

# log <level> <event> <outcome> [<extra-json-object>]
log() {
  local level="$1" event="$2" outcome="$3"
  local extra="${4:-}"
  if [[ -z "$extra" ]]; then
    extra='{}'
  fi
  jq -cn \
    --arg level   "$level" \
    --arg script  "$SCRIPT_NAME" \
    --arg event   "$event" \
    --arg outcome "$outcome" \
    --argjson extra "$extra" \
    '{level:$level, script:$script, event:$event, outcome:$outcome} + $extra' >&2
}

die() {
  local msg="$1" event="$2"
  log error "$event" failure "$(jq -cn --arg m "$msg" '{message:$m}')"
  exit 2
}

require_env() {
  local var="$1"
  if [[ -z "${!var:-}" ]]; then
    die "required env var $var is unset or empty" validate_env
  fi
}

# base64url encode stdin (RFC 4648 §5): standard base64, then strip '=' padding
# and newlines, then translate '+/' to '-_'.
b64url() {
  base64 | tr -d '=\n' | tr '/+' '_-'
}

# ---------------------------------------------------------------------------
# 1. Validate inputs
# ---------------------------------------------------------------------------

require_env GATEWAY_APP_ID
require_env GATEWAY_PRIVATE_KEY
require_env GATEWAY_INSTALLATION_ID

if ! [[ "$GATEWAY_APP_ID" =~ ^[0-9]+$ ]]; then
  die "GATEWAY_APP_ID must be numeric" validate_env
fi
if ! [[ "$GATEWAY_INSTALLATION_ID" =~ ^[0-9]+$ ]]; then
  die "GATEWAY_INSTALLATION_ID must be numeric" validate_env
fi

# ---------------------------------------------------------------------------
# 2. Materialize the private key safely
# ---------------------------------------------------------------------------

KEY_FILE="$(mktemp -t rtlreviewbot-key.XXXXXX)"
RESP_FILE="$(mktemp -t rtlreviewbot-resp.XXXXXX)"
ERR_FILE="$(mktemp -t rtlreviewbot-err.XXXXXX)"
chmod 600 "$KEY_FILE"
trap 'rm -f "$KEY_FILE" "$RESP_FILE" "$ERR_FILE"' EXIT

# printf '%s' preserves the PEM as-is (echo would mangle backslashes on some
# shells, and we must keep the trailing newline that valid PEM blocks have).
printf '%s' "$GATEWAY_PRIVATE_KEY" > "$KEY_FILE"

# ---------------------------------------------------------------------------
# 3. Build the JWT (RS256)
# ---------------------------------------------------------------------------

NOW=$(date +%s)
IAT=$((NOW - 60))    # backdate 60s to absorb clock skew vs GitHub
EXP=$((NOW + 540))   # 9 minutes; GitHub's max is 10

HEADER_B64=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)

# Build payload via jq so iss is a proper JSON integer (no quoting).
# -j suppresses jq's trailing newline; otherwise that newline would be
# encoded into the base64url payload and the resulting JWT would have a
# stray '\n' inside its JSON body. Most verifiers tolerate it, but it's
# nonstandard.
PAYLOAD_B64=$(
  jq -cnj \
    --argjson iat "$IAT" \
    --argjson exp "$EXP" \
    --argjson iss "$GATEWAY_APP_ID" \
    '{iat:$iat, exp:$exp, iss:$iss}' | b64url
)

SIGNING_INPUT="${HEADER_B64}.${PAYLOAD_B64}"

SIG_B64=$(
  printf '%s' "$SIGNING_INPUT" \
    | openssl dgst -sha256 -sign "$KEY_FILE" -binary 2>"$ERR_FILE" \
    | b64url
) || {
  err_msg="$(tr '\n' ' ' <"$ERR_FILE" 2>/dev/null || true)"
  die "openssl signing failed: ${err_msg:-unknown error}" sign_jwt
}

if [[ -z "$SIG_B64" ]]; then
  die "openssl produced empty signature (malformed private key?)" sign_jwt
fi

JWT="${SIGNING_INPUT}.${SIG_B64}"

log info sign_jwt success "$(
  jq -cn \
    --arg app "$GATEWAY_APP_ID" \
    --argjson iat "$IAT" \
    --argjson exp "$EXP" \
    '{app_id:$app, iat:$iat, exp:$exp}'
)"

# ---------------------------------------------------------------------------
# 4. Mint the installation token (POST with one retry on 5xx/network)
# ---------------------------------------------------------------------------

URL="${GITHUB_API}/app/installations/${GATEWAY_INSTALLATION_ID}/access_tokens"

attempt=1
max_attempts=2
http_code=""
while (( attempt <= max_attempts )); do
  log info mint_token attempt "$(
    jq -cn \
      --argjson n "$attempt" \
      --arg inst "$GATEWAY_INSTALLATION_ID" \
      '{attempt:$n, installation_id:$inst}'
  )"

  http_code=$(
    curl -sS \
      -o "$RESP_FILE" \
      -w '%{http_code}' \
      -X POST \
      -H "Authorization: Bearer ${JWT}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "$URL" 2>"$ERR_FILE"
  ) || true
  [[ -z "$http_code" ]] && http_code="000"

  if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
    break
  fi

  if (( attempt < max_attempts )) && \
     { [[ "$http_code" =~ ^5[0-9][0-9]$ ]] || [[ "$http_code" == "000" ]]; }; then
    log warn mint_token retry "$(
      jq -cn --arg s "$http_code" --argjson sleep 2 \
        '{http_status:$s, sleep_seconds:$sleep}'
    )"
    sleep 2
    attempt=$((attempt + 1))
    continue
  fi

  break
done

if ! [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
  body_excerpt="$(head -c 500 "$RESP_FILE" 2>/dev/null | tr '\n' ' ' || true)"
  die "GitHub API HTTP ${http_code}: ${body_excerpt}" mint_token
fi

# ---------------------------------------------------------------------------
# 5. Parse and emit the token
# ---------------------------------------------------------------------------

TOKEN=$(jq -er '.token' "$RESP_FILE" 2>"$ERR_FILE") \
  || die "response missing .token" parse_response
EXPIRES_AT=$(jq -er '.expires_at' "$RESP_FILE" 2>"$ERR_FILE") \
  || die "response missing .expires_at" parse_response

# Single-line JSON on stdout. The token is intentionally NOT logged anywhere.
jq -cn --arg t "$TOKEN" --arg e "$EXPIRES_AT" '{token:$t, expires_at:$e}'

log info mint_token success "$(
  jq -cn --arg e "$EXPIRES_AT" '{expires_at:$e}'
)"
