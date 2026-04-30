#!/usr/bin/env bats
#
# Unit tests for scripts/check-permission.sh.
#
# Strategy: stub `gh` via PATH injection. The stub:
#   - records each invocation's argv (so tests can assert call counts)
#   - emits a canned response based on a per-test mode file
#   - exits 0 on 2xx-canned responses, non-zero on 4xx/5xx-canned responses
#     while writing the GitHub-style "HTTP <status>" message to stderr (which
#     is what real `gh` does and what the script greps for).

setup() {
  TEST_TMP="$(mktemp -d)"
  export TEST_TMP

  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export REPO_ROOT

  # Each test sets MODE to drive the stub. Default: 200 with admin.
  printf '200_admin' > "$TEST_TMP/mode"

  # Each call appends a line to call_log so we can count.
  : > "$TEST_TMP/call_log"

  install_gh_stub

  # Scope cache to this test's tmpdir so caches don't leak between tests.
  export RTL_PERMISSION_CACHE_DIR="$TEST_TMP/cache"

  export PATH="$TEST_TMP/bin:$PATH"
}

teardown() {
  rm -rf "$TEST_TMP"
}

# ---------------------------------------------------------------------------
# gh stub
# ---------------------------------------------------------------------------

install_gh_stub() {
  mkdir -p "$TEST_TMP/bin"
  cat > "$TEST_TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Log the invocation.
printf '%s\n' "$*" >> "$TEST_TMP/call_log"

mode="$(cat "$TEST_TMP/mode" 2>/dev/null || echo 200_admin)"

case "$mode" in
  200_admin)
    printf '%s' '{"permission":"admin","user":{"login":"alice"}}'
    ;;
  200_write)
    printf '%s' '{"permission":"write","user":{"login":"alice"}}'
    ;;
  200_read)
    printf '%s' '{"permission":"read","user":{"login":"alice"}}'
    ;;
  200_none)
    printf '%s' '{"permission":"none","user":{"login":"alice"}}'
    ;;
  200_unknown)
    printf '%s' '{"permission":"surprise","user":{"login":"alice"}}'
    ;;
  200_no_field)
    printf '%s' '{"user":{"login":"alice"}}'
    ;;
  404)
    printf 'gh: Not Found (HTTP 404)\n' >&2
    exit 1
    ;;
  403)
    printf 'gh: Forbidden (HTTP 403)\n' >&2
    exit 1
    ;;
  500)
    printf 'gh: Internal Server Error (HTTP 500)\n' >&2
    exit 1
    ;;
  network)
    printf 'gh: connection refused\n' >&2
    exit 1
    ;;
esac
STUB
  chmod +x "$TEST_TMP/bin/gh"
}

set_mode() { printf '%s' "$1" > "$TEST_TMP/mode"; }
call_count() { wc -l < "$TEST_TMP/call_log" | tr -d ' '; }

# ---------------------------------------------------------------------------
# Happy paths
# ---------------------------------------------------------------------------

@test "admin user passes write check" {
  set_mode 200_admin
  run bash "$REPO_ROOT/scripts/check-permission.sh" \
    --user alice --repo Ride-The-Lightning/RTL-Web --level write
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.passed == true' >/dev/null
  echo "$output" | jq -e '.permission == "admin"' >/dev/null
  echo "$output" | jq -e '.required == "write"' >/dev/null
  echo "$output" | jq -e '.cached == false' >/dev/null
}

@test "write user passes write check" {
  set_mode 200_write
  run bash "$REPO_ROOT/scripts/check-permission.sh" \
    --user alice --repo Ride-The-Lightning/RTL-Web --level write
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.passed == true' >/dev/null
}

@test "admin user passes admin check" {
  set_mode 200_admin
  run bash "$REPO_ROOT/scripts/check-permission.sh" \
    --user alice --repo Ride-The-Lightning/RTL-Web --level admin
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.passed == true' >/dev/null
}

@test "read user passes read check" {
  set_mode 200_read
  run bash "$REPO_ROOT/scripts/check-permission.sh" \
    --user alice --repo Ride-The-Lightning/RTL-Web --level read
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.passed == true' >/dev/null
}

# ---------------------------------------------------------------------------
# Denials (exit 1)
# ---------------------------------------------------------------------------

@test "read user is denied write" {
  set_mode 200_read
  run bash "$REPO_ROOT/scripts/check-permission.sh" \
    --user alice --repo Ride-The-Lightning/RTL-Web --level write
  [ "$status" -eq 1 ]
  echo "$output" | jq -e '.passed == false' >/dev/null
  echo "$output" | jq -e '.permission == "read"' >/dev/null
}

@test "write user is denied admin" {
  set_mode 200_write
  run bash "$REPO_ROOT/scripts/check-permission.sh" \
    --user alice --repo Ride-The-Lightning/RTL-Web --level admin
  [ "$status" -eq 1 ]
  echo "$output" | jq -e '.passed == false' >/dev/null
}

@test "404 (non-collaborator on private repo) treated as none, denies read" {
  set_mode 404
  run bash "$REPO_ROOT/scripts/check-permission.sh" \
    --user randomuser --repo Ride-The-Lightning/RTL-Web --level read
  [ "$status" -eq 1 ]
  echo "$output" | jq -e '.permission == "none"' >/dev/null
  echo "$output" | jq -e '.passed == false' >/dev/null
}

@test "403 treated as none, denies read" {
  set_mode 403
  run bash "$REPO_ROOT/scripts/check-permission.sh" \
    --user randomuser --repo Ride-The-Lightning/RTL-Web --level read
  [ "$status" -eq 1 ]
  echo "$output" | jq -e '.permission == "none"' >/dev/null
}

# ---------------------------------------------------------------------------
# System errors (exit 2)
# ---------------------------------------------------------------------------

@test "5xx from API exits 2 (fail closed, never fail open)" {
  set_mode 500
  run bash "$REPO_ROOT/scripts/check-permission.sh" \
    --user alice --repo Ride-The-Lightning/RTL-Web --level read
  [ "$status" -eq 2 ]
}

@test "network failure from gh exits 2" {
  set_mode network
  run bash "$REPO_ROOT/scripts/check-permission.sh" \
    --user alice --repo Ride-The-Lightning/RTL-Web --level read
  [ "$status" -eq 2 ]
}

@test "200 with unrecognized .permission value exits 2" {
  set_mode 200_unknown
  run bash "$REPO_ROOT/scripts/check-permission.sh" \
    --user alice --repo Ride-The-Lightning/RTL-Web --level read
  [ "$status" -eq 2 ]
}

@test "200 missing .permission field exits 2" {
  set_mode 200_no_field
  run bash "$REPO_ROOT/scripts/check-permission.sh" \
    --user alice --repo Ride-The-Lightning/RTL-Web --level read
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# Argument validation
# ---------------------------------------------------------------------------

@test "missing --user exits 2" {
  run bash "$REPO_ROOT/scripts/check-permission.sh" \
    --repo Ride-The-Lightning/RTL-Web --level read
  [ "$status" -eq 2 ]
}

@test "missing --repo exits 2" {
  run bash "$REPO_ROOT/scripts/check-permission.sh" \
    --user alice --level read
  [ "$status" -eq 2 ]
}

@test "missing --level exits 2" {
  run bash "$REPO_ROOT/scripts/check-permission.sh" \
    --user alice --repo Ride-The-Lightning/RTL-Web
  [ "$status" -eq 2 ]
}

@test "invalid --level exits 2" {
  run bash "$REPO_ROOT/scripts/check-permission.sh" \
    --user alice --repo Ride-The-Lightning/RTL-Web --level superuser
  [ "$status" -eq 2 ]
}

@test "invalid --repo format exits 2" {
  run bash "$REPO_ROOT/scripts/check-permission.sh" \
    --user alice --repo not-a-repo --level read
  [ "$status" -eq 2 ]
}

@test "invalid --user format exits 2" {
  run bash "$REPO_ROOT/scripts/check-permission.sh" \
    --user 'bad name with spaces' --repo Ride-The-Lightning/RTL-Web --level read
  [ "$status" -eq 2 ]
}

@test "App-style [bot] suffix in --user is accepted" {
  set_mode 200_write
  run bash "$REPO_ROOT/scripts/check-permission.sh" \
    --user 'rtlreview[bot]' --repo Ride-The-Lightning/RTL-Web --level write
  [ "$status" -eq 0 ]
}

@test "unknown argument exits 2" {
  run bash "$REPO_ROOT/scripts/check-permission.sh" \
    --user alice --repo Ride-The-Lightning/RTL-Web --level read --extra foo
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# Caching
# ---------------------------------------------------------------------------

@test "second call for same user/repo is served from cache (no second API call)" {
  set_mode 200_write

  run bash "$REPO_ROOT/scripts/check-permission.sh" \
    --user alice --repo Ride-The-Lightning/RTL-Web --level write
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.cached == false' >/dev/null
  [ "$(call_count)" = "1" ]

  run bash "$REPO_ROOT/scripts/check-permission.sh" \
    --user alice --repo Ride-The-Lightning/RTL-Web --level write
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.cached == true' >/dev/null
  [ "$(call_count)" = "1" ]
}

@test "different --level for same user shares the cached permission" {
  set_mode 200_admin

  run bash "$REPO_ROOT/scripts/check-permission.sh" \
    --user alice --repo Ride-The-Lightning/RTL-Web --level read
  [ "$status" -eq 0 ]
  [ "$(call_count)" = "1" ]

  run bash "$REPO_ROOT/scripts/check-permission.sh" \
    --user alice --repo Ride-The-Lightning/RTL-Web --level admin
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.cached == true' >/dev/null
  [ "$(call_count)" = "1" ]
}

@test "different user does NOT share cache" {
  set_mode 200_write

  run bash "$REPO_ROOT/scripts/check-permission.sh" \
    --user alice --repo Ride-The-Lightning/RTL-Web --level write
  [ "$status" -eq 0 ]

  run bash "$REPO_ROOT/scripts/check-permission.sh" \
    --user bob --repo Ride-The-Lightning/RTL-Web --level write
  [ "$status" -eq 0 ]
  [ "$(call_count)" = "2" ]
}

@test "different repo does NOT share cache (no path collision)" {
  set_mode 200_write

  run bash "$REPO_ROOT/scripts/check-permission.sh" \
    --user alice --repo Ride-The-Lightning/RTL-Web --level write
  [ "$status" -eq 0 ]

  run bash "$REPO_ROOT/scripts/check-permission.sh" \
    --user alice --repo Ride-The-Lightning/lnd --level write
  [ "$status" -eq 0 ]
  [ "$(call_count)" = "2" ]
}

# ---------------------------------------------------------------------------
# API request shape
# ---------------------------------------------------------------------------

@test "request targets the correct API path" {
  set_mode 200_admin
  run bash "$REPO_ROOT/scripts/check-permission.sh" \
    --user alice --repo Ride-The-Lightning/RTL-Web --level read
  [ "$status" -eq 0 ]
  grep -F 'api repos/Ride-The-Lightning/RTL-Web/collaborators/alice/permission' \
    "$TEST_TMP/call_log"
}

# ---------------------------------------------------------------------------
# Logging hygiene
# ---------------------------------------------------------------------------

@test "stderr lines are valid JSON log objects" {
  set_mode 200_admin
  run --separate-stderr bash "$REPO_ROOT/scripts/check-permission.sh" \
    --user alice --repo Ride-The-Lightning/RTL-Web --level read
  [ "$status" -eq 0 ]
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    echo "$line" | jq -e '.level and .script and .event and .outcome' >/dev/null
  done <<< "$stderr"
}
