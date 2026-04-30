#!/usr/bin/env bats
#
# Unit tests for scripts/run-review.sh — the top-level event dispatcher.
#
# Strategy: copy the scripts/ tree to a per-test tmpdir, then replace
# authenticate.sh, check-permission.sh, and every handlers/handle-*.sh with
# stubs that just log "HANDLER <name> <args>" to a shared log file. This
# keeps the test focused on routing decisions (which handler did the
# dispatcher pick, did it gate on permission correctly) without exercising
# any real network or business logic.

bats_require_minimum_version 1.5.0

setup() {
  TEST_TMP="$(mktemp -d)"
  export TEST_TMP

  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export REPO_ROOT

  # Per-test trace of every "interesting" call.
  export RTL_TEST_LOG="$TEST_TMP/trace.log"
  : > "$RTL_TEST_LOG"

  cp -r "$REPO_ROOT/scripts" "$TEST_TMP/scripts"

  # authenticate.sh stub — return a fake installation token.
  cat > "$TEST_TMP/scripts/authenticate.sh" <<'STUB'
#!/usr/bin/env bash
echo "AUTH" >> "$RTL_TEST_LOG"
echo '{"token":"fake-installation-token","expires_at":"2026-12-31T00:00:00Z"}'
STUB
  chmod +x "$TEST_TMP/scripts/authenticate.sh"

  # check-permission.sh stub — exit 0 (allow) by default; tests can override
  # via $RTL_TEST_PERM_EXIT.
  cat > "$TEST_TMP/scripts/check-permission.sh" <<'STUB'
#!/usr/bin/env bash
echo "CHECK_PERM $*" >> "$RTL_TEST_LOG"
exit "${RTL_TEST_PERM_EXIT:-0}"
STUB
  chmod +x "$TEST_TMP/scripts/check-permission.sh"

  # Replace every handler with a logger stub.
  for h in "$TEST_TMP/scripts/handlers"/*.sh; do
    name="$(basename "$h")"
    cat > "$h" <<STUB
#!/usr/bin/env bash
echo "HANDLER $name \$*" >> "\$RTL_TEST_LOG"
exit 0
STUB
    chmod +x "$h"
  done

  # gh stub — log every call and return canned author info for is_author.
  mkdir -p "$TEST_TMP/bin"
  cat > "$TEST_TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "GH $*" >> "$RTL_TEST_LOG"

# is_author() runs `gh api repos/.../pulls/N --jq .user.login`. Return the
# author login set by the test, or "default-author" if unset.
for a in "$@"; do
  case "$a" in
    repos/*/pulls/[0-9]*) is_pr=1 ;;
    .user.login)          want_author=1 ;;
  esac
done
if [[ -n "${is_pr:-}" && -n "${want_author:-}" ]]; then
  printf '%s' "${RTL_TEST_PR_AUTHOR:-default-author}"
  exit 0
fi
echo '{}'
STUB
  chmod +x "$TEST_TMP/bin/gh"
  export PATH="$TEST_TMP/bin:$PATH"
}

teardown() {
  rm -rf "$TEST_TMP"
}

run_dispatcher() {
  bash "$TEST_TMP/scripts/run-review.sh" "$@"
}

last_handler() {
  grep '^HANDLER ' "$RTL_TEST_LOG" | tail -n1 | awk '{print $2}'
}

handler_calls() {
  grep -c '^HANDLER ' "$RTL_TEST_LOG" || true
}

# ---------------------------------------------------------------------------
# issue_comment routing
# ---------------------------------------------------------------------------

@test "issue_comment with /rtl review routes to handle-review.sh" {
  run run_dispatcher \
    --event-name issue_comment --event-action created \
    --repo o/r --pr 42 --actor alice --comment-body '/rtl review'
  [ "$status" -eq 0 ]
  [ "$(last_handler)" = "handle-review.sh" ]
}

@test "issue_comment with /rtl stop routes to handle-stop.sh" {
  run run_dispatcher \
    --event-name issue_comment --repo o/r --pr 42 --actor alice \
    --comment-body '/rtl stop'
  [ "$status" -eq 0 ]
  [ "$(last_handler)" = "handle-stop.sh" ]
}

@test "issue_comment with /rtl explain F3 routes to handle-explain with --args F3" {
  run run_dispatcher \
    --event-name issue_comment --repo o/r --pr 42 --actor anyone \
    --comment-body '/rtl explain F3'
  [ "$status" -eq 0 ]
  [ "$(last_handler)" = "handle-explain.sh" ]
  grep -F -- '--args F3' "$RTL_TEST_LOG"
}

@test "issue_comment with /rtl re-review routes to handle-re-review.sh" {
  run run_dispatcher \
    --event-name issue_comment --repo o/r --pr 42 --actor alice \
    --comment-body '/rtl re-review'
  [ "$status" -eq 0 ]
  [ "$(last_handler)" = "handle-re-review.sh" ]
}

@test "issue_comment that is not a /rtl command exits 0 silently (no handler)" {
  run run_dispatcher \
    --event-name issue_comment --repo o/r --pr 42 --actor alice \
    --comment-body 'looks good!'
  [ "$status" -eq 0 ]
  [ "$(handler_calls)" = "0" ]
}

@test "empty comment body exits 0 silently" {
  run run_dispatcher \
    --event-name issue_comment --repo o/r --pr 42 --actor alice \
    --comment-body ''
  [ "$status" -eq 0 ]
  [ "$(handler_calls)" = "0" ]
}

# ---------------------------------------------------------------------------
# Permission gating
# ---------------------------------------------------------------------------

@test "/rtl review denied for non-maintainer (perm script exits 1)" {
  RTL_TEST_PERM_EXIT=1 run_dispatcher \
    --event-name issue_comment --repo o/r --pr 42 --actor outsider \
    --comment-body '/rtl review'
  # Expectation: handler NOT called; gh comment posted with denial.
  ! grep -q '^HANDLER ' "$RTL_TEST_LOG"
  grep -F 'requires maintainer permission' "$RTL_TEST_LOG"
}

@test "/rtl stop allowed for PR author when not maintainer" {
  RTL_TEST_PERM_EXIT=1 RTL_TEST_PR_AUTHOR=alice run_dispatcher \
    --event-name issue_comment --repo o/r --pr 42 --actor alice \
    --comment-body '/rtl stop'
  [ "$(last_handler)" = "handle-stop.sh" ]
}

@test "/rtl stop denied for non-maintainer non-author" {
  RTL_TEST_PERM_EXIT=1 RTL_TEST_PR_AUTHOR=alice run_dispatcher \
    --event-name issue_comment --repo o/r --pr 42 --actor outsider \
    --comment-body '/rtl stop'
  ! grep -q '^HANDLER ' "$RTL_TEST_LOG"
  grep -F 'maintainer or PR author' "$RTL_TEST_LOG"
}

@test "/rtl explain runs for anyone (no permission check)" {
  RTL_TEST_PERM_EXIT=1 run_dispatcher \
    --event-name issue_comment --repo o/r --pr 42 --actor random_drive_by \
    --comment-body '/rtl explain F1'
  [ "$(last_handler)" = "handle-explain.sh" ]
}

# ---------------------------------------------------------------------------
# Loop prevention and bot filtering
# ---------------------------------------------------------------------------

@test "comment from rtlreview[bot] is silently dropped (loop prevention)" {
  run run_dispatcher \
    --event-name issue_comment --repo o/r --pr 42 \
    --actor 'rtlreview[bot]' --comment-body '/rtl review'
  [ "$status" -eq 0 ]
  [ "$(handler_calls)" = "0" ]
  # Should NOT even authenticate.
  ! grep -q '^AUTH' "$RTL_TEST_LOG"
}

@test "dependabot[bot] is silently dropped" {
  run run_dispatcher \
    --event-name issue_comment --repo o/r --pr 42 \
    --actor 'dependabot[bot]' --comment-body '/rtl review'
  [ "$status" -eq 0 ]
  [ "$(handler_calls)" = "0" ]
}

@test "renovate[bot] is silently dropped" {
  run run_dispatcher \
    --event-name issue_comment --repo o/r --pr 42 \
    --actor 'renovate[bot]' --comment-body '/rtl review'
  [ "$status" -eq 0 ]
  [ "$(handler_calls)" = "0" ]
}

@test "--bot-login override changes the loop-prevention target" {
  run run_dispatcher \
    --event-name issue_comment --repo o/r --pr 42 --actor 'someotherbot[bot]' \
    --bot-login 'someotherbot[bot]' --comment-body '/rtl review'
  [ "$status" -eq 0 ]
  [ "$(handler_calls)" = "0" ]
}

# ---------------------------------------------------------------------------
# pull_request routing
# ---------------------------------------------------------------------------

@test "pull_request review_requested routes to handle-rerequest.sh" {
  run run_dispatcher \
    --event-name pull_request --event-action review_requested \
    --repo o/r --pr 42 --actor alice
  [ "$status" -eq 0 ]
  [ "$(last_handler)" = "handle-rerequest.sh" ]
}

@test "pull_request closed routes to handle-close.sh" {
  run run_dispatcher \
    --event-name pull_request --event-action closed \
    --repo o/r --pr 42 --actor alice
  [ "$status" -eq 0 ]
  [ "$(last_handler)" = "handle-close.sh" ]
}

@test "pull_request with unrelated action exits 0 silently" {
  run run_dispatcher \
    --event-name pull_request --event-action synchronize \
    --repo o/r --pr 42 --actor alice
  [ "$status" -eq 0 ]
  [ "$(handler_calls)" = "0" ]
}

# ---------------------------------------------------------------------------
# Other events
# ---------------------------------------------------------------------------

@test "unsupported event_name exits 0 silently" {
  run run_dispatcher \
    --event-name discussion --repo o/r --pr 42 --actor alice
  [ "$status" -eq 0 ]
  [ "$(handler_calls)" = "0" ]
}

# ---------------------------------------------------------------------------
# Argument validation
# ---------------------------------------------------------------------------

@test "missing --event-name exits 2" {
  run run_dispatcher --repo o/r --pr 42 --actor alice
  [ "$status" -eq 2 ]
}

@test "missing --repo exits 2" {
  run run_dispatcher --event-name issue_comment --pr 42 --actor alice
  [ "$status" -eq 2 ]
}

@test "missing --pr exits 2" {
  run run_dispatcher --event-name issue_comment --repo o/r --actor alice
  [ "$status" -eq 2 ]
}

@test "missing --actor exits 2" {
  run run_dispatcher --event-name issue_comment --repo o/r --pr 42
  [ "$status" -eq 2 ]
}

@test "unknown flag exits 2" {
  run run_dispatcher --event-name issue_comment --repo o/r --pr 42 \
    --actor alice --bogus 1
  [ "$status" -eq 2 ]
}
