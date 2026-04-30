#!/usr/bin/env bats
#
# Unit tests for scripts/authenticate.sh.
#
# Strategy: stub `curl` via PATH injection so the script doesn't actually
# hit GitHub. The stub captures the command-line args (so we can assert what
# the script tried to send) and writes a canned response. A fresh RSA key is
# generated per test in setup() — we never store a private key in the repo,
# even a fake one.

bats_require_minimum_version 1.5.0

setup() {
  TEST_TMP="$(mktemp -d)"
  export TEST_TMP

  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export REPO_ROOT

  # Real 2048-bit RSA key — openssl actually signs with it, so the JWT we
  # capture in the curl stub is a cryptographically valid token (we don't
  # verify the signature in tests, but generating real keys exercises the
  # signing path end-to-end).
  openssl genrsa -out "$TEST_TMP/test.pem" 2048 2>/dev/null

  export GATEWAY_APP_ID="123456"
  export GATEWAY_INSTALLATION_ID="789012"
  GATEWAY_PRIVATE_KEY="$(cat "$TEST_TMP/test.pem")"
  export GATEWAY_PRIVATE_KEY

  # Default stub: 200 OK with a canned token response.
  install_curl_stub_default

  export PATH="$TEST_TMP/bin:$PATH"
}

teardown() {
  rm -rf "$TEST_TMP"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

install_curl_stub_default() {
  mkdir -p "$TEST_TMP/bin"
  cat > "$TEST_TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
# Capture each arg on its own line so tests can grep them.
: > "$TEST_TMP/curl_args.txt"
for a in "$@"; do
  printf '%s\n' "$a" >> "$TEST_TMP/curl_args.txt"
done
# Find the response-output path (-o <file>) and write the canned body.
RESP=""
prev=""
for a in "$@"; do
  if [[ "$prev" == "-o" ]]; then RESP="$a"; fi
  prev="$a"
done
if [[ -n "$RESP" ]]; then
  cat > "$RESP" <<'BODY'
{"token":"ghs_fake_token_value","expires_at":"2026-04-27T13:00:00Z","permissions":{"contents":"read"},"repository_selection":"selected"}
BODY
fi
# Honor -w '%{http_code}': emit the status code on stdout.
printf '200'
STUB
  chmod +x "$TEST_TMP/bin/curl"
}

# Decode base64url from stdin.
b64url_decode() {
  local s
  s="$(cat)"
  s="${s//-/+}"
  s="${s//_/\/}"
  while (( ${#s} % 4 != 0 )); do s+="="; done
  printf '%s' "$s" | openssl base64 -d -A
}

# Pull the JWT out of the captured Authorization header line.
extract_jwt() {
  local auth_line
  auth_line="$(grep -E '^Authorization: Bearer ' "$TEST_TMP/curl_args.txt")"
  printf '%s' "${auth_line#Authorization: Bearer }"
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@test "happy path: emits {token, expires_at} JSON on stdout, exit 0" {
  run --separate-stderr bash "$REPO_ROOT/scripts/authenticate.sh"
  [ "$status" -eq 0 ]
  [ -n "$output" ]

  echo "$output" | jq -e '.token == "ghs_fake_token_value"' >/dev/null
  echo "$output" | jq -e '.expires_at == "2026-04-27T13:00:00Z"' >/dev/null
}

@test "JWT header decodes to {alg:RS256, typ:JWT}" {
  run bash "$REPO_ROOT/scripts/authenticate.sh"
  [ "$status" -eq 0 ]

  jwt="$(extract_jwt)"
  header="$(printf '%s' "$jwt" | cut -d. -f1 | b64url_decode)"
  echo "$header" | jq -e '.alg == "RS256" and .typ == "JWT"' >/dev/null
}

@test "JWT iss is the integer App ID" {
  run bash "$REPO_ROOT/scripts/authenticate.sh"
  [ "$status" -eq 0 ]

  jwt="$(extract_jwt)"
  payload="$(printf '%s' "$jwt" | cut -d. -f2 | b64url_decode)"

  # iss must be a JSON number, not a string
  echo "$payload" | jq -e '.iss == 123456' >/dev/null
  echo "$payload" | jq -e '(.iss | type) == "number"' >/dev/null
}

@test "JWT exp - iat is positive and <= 600 seconds" {
  run bash "$REPO_ROOT/scripts/authenticate.sh"
  [ "$status" -eq 0 ]

  jwt="$(extract_jwt)"
  payload="$(printf '%s' "$jwt" | cut -d. -f2 | b64url_decode)"
  iat="$(echo "$payload" | jq -r '.iat')"
  exp="$(echo "$payload" | jq -r '.exp')"
  delta=$((exp - iat))
  [ "$delta" -gt 0 ]
  [ "$delta" -le 600 ]
}

@test "JWT iat is backdated (<= now) to absorb clock skew" {
  run bash "$REPO_ROOT/scripts/authenticate.sh"
  [ "$status" -eq 0 ]
  now=$(date +%s)

  jwt="$(extract_jwt)"
  payload="$(printf '%s' "$jwt" | cut -d. -f2 | b64url_decode)"
  iat="$(echo "$payload" | jq -r '.iat')"
  [ "$iat" -le "$now" ]
}

@test "request URL targets the correct installation endpoint" {
  run bash "$REPO_ROOT/scripts/authenticate.sh"
  [ "$status" -eq 0 ]
  grep -F "https://api.github.com/app/installations/789012/access_tokens" \
    "$TEST_TMP/curl_args.txt"
}

@test "request includes Accept and X-GitHub-Api-Version headers" {
  run bash "$REPO_ROOT/scripts/authenticate.sh"
  [ "$status" -eq 0 ]
  grep -F "Accept: application/vnd.github+json" "$TEST_TMP/curl_args.txt"
  grep -F "X-GitHub-Api-Version: 2022-11-28" "$TEST_TMP/curl_args.txt"
}

@test "request method is POST" {
  run bash "$REPO_ROOT/scripts/authenticate.sh"
  [ "$status" -eq 0 ]
  # -X POST should be present in the captured args
  grep -Fx -- "-X" "$TEST_TMP/curl_args.txt"
  grep -Fx -- "POST" "$TEST_TMP/curl_args.txt"
}

@test "missing GATEWAY_APP_ID exits 2" {
  unset GATEWAY_APP_ID
  run bash "$REPO_ROOT/scripts/authenticate.sh"
  [ "$status" -eq 2 ]
}

@test "missing GATEWAY_PRIVATE_KEY exits 2" {
  unset GATEWAY_PRIVATE_KEY
  run bash "$REPO_ROOT/scripts/authenticate.sh"
  [ "$status" -eq 2 ]
}

@test "missing GATEWAY_INSTALLATION_ID exits 2" {
  unset GATEWAY_INSTALLATION_ID
  run bash "$REPO_ROOT/scripts/authenticate.sh"
  [ "$status" -eq 2 ]
}

@test "non-numeric GATEWAY_APP_ID exits 2" {
  export GATEWAY_APP_ID="notanumber"
  run bash "$REPO_ROOT/scripts/authenticate.sh"
  [ "$status" -eq 2 ]
}

@test "non-numeric GATEWAY_INSTALLATION_ID exits 2" {
  export GATEWAY_INSTALLATION_ID="abc"
  run bash "$REPO_ROOT/scripts/authenticate.sh"
  [ "$status" -eq 2 ]
}

@test "5xx response triggers exactly one retry, then succeeds" {
  cat > "$TEST_TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
COUNT_FILE="$TEST_TMP/curl_count"
n=0
[[ -f "$COUNT_FILE" ]] && n=$(cat "$COUNT_FILE")
n=$((n + 1))
printf '%d' "$n" > "$COUNT_FILE"

RESP=""
prev=""
for a in "$@"; do
  if [[ "$prev" == "-o" ]]; then RESP="$a"; fi
  prev="$a"
done

if (( n == 1 )); then
  [[ -n "$RESP" ]] && printf '%s' '{"message":"server overloaded"}' > "$RESP"
  printf '503'
else
  if [[ -n "$RESP" ]]; then
    printf '%s' '{"token":"ghs_retry_token","expires_at":"2026-04-27T14:00:00Z"}' > "$RESP"
  fi
  printf '200'
fi
STUB
  chmod +x "$TEST_TMP/bin/curl"

  run --separate-stderr bash "$REPO_ROOT/scripts/authenticate.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.token == "ghs_retry_token"' >/dev/null

  count="$(cat "$TEST_TMP/curl_count")"
  [ "$count" -eq 2 ]
}

@test "401 (auth failure) does not retry, exits 2" {
  cat > "$TEST_TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
COUNT_FILE="$TEST_TMP/curl_count"
n=0
[[ -f "$COUNT_FILE" ]] && n=$(cat "$COUNT_FILE")
n=$((n + 1))
printf '%d' "$n" > "$COUNT_FILE"

RESP=""
prev=""
for a in "$@"; do
  if [[ "$prev" == "-o" ]]; then RESP="$a"; fi
  prev="$a"
done
[[ -n "$RESP" ]] && printf '%s' '{"message":"Bad credentials"}' > "$RESP"
printf '401'
STUB
  chmod +x "$TEST_TMP/bin/curl"

  run bash "$REPO_ROOT/scripts/authenticate.sh"
  [ "$status" -eq 2 ]
  count="$(cat "$TEST_TMP/curl_count")"
  [ "$count" -eq 1 ]
}

@test "two consecutive 5xx responses exit 2 (retry budget exhausted)" {
  cat > "$TEST_TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
COUNT_FILE="$TEST_TMP/curl_count"
n=0
[[ -f "$COUNT_FILE" ]] && n=$(cat "$COUNT_FILE")
n=$((n + 1))
printf '%d' "$n" > "$COUNT_FILE"

RESP=""
prev=""
for a in "$@"; do
  if [[ "$prev" == "-o" ]]; then RESP="$a"; fi
  prev="$a"
done
[[ -n "$RESP" ]] && printf '%s' '{"message":"still down"}' > "$RESP"
printf '500'
STUB
  chmod +x "$TEST_TMP/bin/curl"

  run bash "$REPO_ROOT/scripts/authenticate.sh"
  [ "$status" -eq 2 ]
  count="$(cat "$TEST_TMP/curl_count")"
  [ "$count" -eq 2 ]
}

@test "200 response missing .token exits 2" {
  cat > "$TEST_TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
RESP=""
prev=""
for a in "$@"; do
  if [[ "$prev" == "-o" ]]; then RESP="$a"; fi
  prev="$a"
done
[[ -n "$RESP" ]] && printf '%s' '{"unexpected":"shape"}' > "$RESP"
printf '200'
STUB
  chmod +x "$TEST_TMP/bin/curl"

  run bash "$REPO_ROOT/scripts/authenticate.sh"
  [ "$status" -eq 2 ]
}

@test "the minted token never appears in stderr logs" {
  run --separate-stderr bash "$REPO_ROOT/scripts/authenticate.sh"
  [ "$status" -eq 0 ]
  if echo "$stderr" | grep -q "ghs_fake_token_value"; then
    printf 'token leaked in stderr:\n%s\n' "$stderr" >&2
    return 1
  fi
}

@test "the JWT signature never appears in stderr logs" {
  run --separate-stderr bash "$REPO_ROOT/scripts/authenticate.sh"
  [ "$status" -eq 0 ]

  jwt="$(extract_jwt)"
  sig="$(printf '%s' "$jwt" | cut -d. -f3)"
  if echo "$stderr" | grep -qF "$sig"; then
    printf 'JWT signature leaked in stderr:\n%s\n' "$stderr" >&2
    return 1
  fi
}

@test "private key file is removed after successful run" {
  # The script creates and cleans up its own tempfile via EXIT trap. We can't
  # observe the cleanup directly without instrumenting the script, but we can
  # at least confirm no rtlreviewbot-key.* tempfiles linger after the run.
  before=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'rtlreviewbot-key.*' 2>/dev/null | wc -l)
  run bash "$REPO_ROOT/scripts/authenticate.sh"
  [ "$status" -eq 0 ]
  after=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'rtlreviewbot-key.*' 2>/dev/null | wc -l)
  [ "$after" -eq "$before" ]
}
