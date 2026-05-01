#!/usr/bin/env bats
#
# Unit tests for scripts/handlers/handle-explain.sh.
#
# Strategy: copy scripts/ to a per-test tmpdir, stub update-metadata.sh,
# fetch-pr-context.sh, and the claude CLI. PATH-stub gh for reactions,
# comment posts, and reply-to-review-comment.

bats_require_minimum_version 1.5.0

setup() {
  TEST_TMP="$(mktemp -d)"
  export TEST_TMP

  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export REPO_ROOT

  cp -r "$REPO_ROOT/scripts" "$TEST_TMP/scripts"
  cp -r "$REPO_ROOT/skills"  "$TEST_TMP/skills"

  # update-metadata stub: read returns marker.json contents, write captures stdin.
  cat > "$TEST_TMP/scripts/update-metadata.sh" <<'STUB'
#!/usr/bin/env bash
mode=""
for ((i=1; i<=$#; i++)); do
  if [[ "${!i}" == "--mode" ]]; then j=$((i+1)); mode="${!j}"; fi
done
case "$mode" in
  read)  cat "$TEST_TMP/marker.json" 2>/dev/null || echo 'null' ;;
  write) cat > "$TEST_TMP/marker_written.json" ;;
esac
STUB
  chmod +x "$TEST_TMP/scripts/update-metadata.sh"

  # fetch-pr-context stub.
  cat > "$TEST_TMP/scripts/fetch-pr-context.sh" <<'STUB'
#!/usr/bin/env bash
cat "$TEST_TMP/context.json"
STUB
  chmod +x "$TEST_TMP/scripts/fetch-pr-context.sh"

  : > "$TEST_TMP/call_log"
  echo '{"pr":{"head_sha":"abc"},"diff":{"text":"d","truncated":false}}' > "$TEST_TMP/context.json"

  cat > "$TEST_TMP/marker.json" <<'JSON'
{
  "version": "1.1",
  "last_reviewed_sha": "abc",
  "findings": [
    {"id":"F1","severity":"major","status":"unresolved","path":"src/x.go","line":10,"body":"original F1 body","inline_comment_id":1001},
    {"id":"F2","severity":"minor","status":"unresolved","path":"src/y.go","line":5,"body":"original F2 body","inline_comment_id":null}
  ],
  "dismissed_findings": [
    {"id":"F3","by":"alice","reason":"already gone","at":"2026-04-30T00:00:00Z"}
  ]
}
JSON

  mkdir -p "$TEST_TMP/bin"

  # claude stub: outputs a passable explanation by default.
  cat > "$TEST_TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
[[ "$*" == *"--version"* ]] && { echo "claude 1.0.0"; exit 0; }
case "${CLAUDE_MODE:-good}" in
  good)        echo "F1 flags this because the helper at line 12 returns nil but commit dereferences it. Add a nil check or document the precondition."; exit 0 ;;
  empty)       exit 0 ;;
  hard_fail)   echo "auth error" >&2; exit 1 ;;
esac
STUB
  chmod +x "$TEST_TMP/bin/claude"

  # gh stub.
  cat > "$TEST_TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "GH: $*" >> "$TEST_TMP/call_log"
case "$*" in
  *"/reactions"*)                  echo '{"id":1}' ;;
  *"-X POST"*"/pulls/"*"/comments"*) echo '{"id":2222}' ;;
  *"-X POST"*"/issues/"*"/comments"*) echo '{"id":3333}' ;;
  *)                                echo '{}' ;;
esac
STUB
  chmod +x "$TEST_TMP/bin/gh"

  # Provide a fake auth so invoke_claude_raw doesn't bail on no-creds.
  export ANTHROPIC_API_KEY="fake"
  export PATH="$TEST_TMP/bin:$PATH"
}

teardown() { rm -rf "$TEST_TMP"; }

run_handler() {
  bash "$TEST_TMP/scripts/handlers/handle-explain.sh" "$@"
}

count() { grep -c -- "$1" "$TEST_TMP/call_log" || true; }

# ---------------------------------------------------------------------------

@test "F1 (with inline_comment_id) posts as a reply on the inline thread" {
  run --separate-stderr run_handler --repo o/r --pr 42 --actor anyone \
    --comment-id 555 --args "F1"
  [ "$status" -eq 0 ]
  # Reply endpoint is /pulls/N/comments — distinct from /issues/N/comments.
  [ "$(count 'POST.*pulls/42/comments')" = "1" ]
  [ "$(count 'POST.*issues/42/comments')" = "0" ]
  [ "$(count '/reactions')" = "1" ]
}

@test "F2 (no inline_comment_id) posts as a top-level PR comment" {
  run --separate-stderr run_handler --repo o/r --pr 42 --actor anyone \
    --args "F2"
  [ "$status" -eq 0 ]
  [ "$(count 'POST.*pulls/42/comments')" = "0" ]
  [ "$(count 'POST.*issues/42/comments')" = "1" ]
}

@test "rejects unknown finding id (no Claude call, no comment posted to PR thread)" {
  CLAUDE_MODE=good run --separate-stderr run_handler --repo o/r --pr 42 \
    --actor anyone --args "F99"
  [ "$status" -eq 0 ]
  # No reply or top-level review-comment posted.
  [ "$(count 'POST.*pulls/42/comments')" = "0" ]
  # An error notice IS posted via post_comment.
  grep -F 'no such finding' "$TEST_TMP/call_log"
}

@test "rejects dismissed finding with explanatory comment" {
  run --separate-stderr run_handler --repo o/r --pr 42 --actor anyone --args "F3"
  [ "$status" -eq 0 ]
  grep -F 'has been dismissed' "$TEST_TMP/call_log"
}

@test "rejects malformed first arg" {
  run --separate-stderr run_handler --repo o/r --pr 42 --actor anyone --args "junk"
  [ "$status" -eq 0 ]
  grep -F 'must be a finding id' "$TEST_TMP/call_log"
}

@test "missing --args prints usage hint" {
  run --separate-stderr run_handler --repo o/r --pr 42 --actor anyone
  [ "$status" -eq 0 ]
  grep -F 'requires a finding id' "$TEST_TMP/call_log"
}

@test "absent marker yields a clear 'run /rtl review first' error" {
  echo 'null' > "$TEST_TMP/marker.json"
  run --separate-stderr run_handler --repo o/r --pr 42 --actor anyone --args "F1"
  [ "$status" -eq 0 ]
  grep -F 'has not reviewed this PR yet' "$TEST_TMP/call_log"
}

@test "Claude hard failure surfaces a visible error and exits 2" {
  CLAUDE_MODE=hard_fail run run_handler --repo o/r --pr 42 --actor anyone \
    --comment-id 555 --args "F1"
  [ "$status" -eq 2 ]
}

@test "missing --repo exits 2" {
  run run_handler --pr 42 --actor anyone --args "F1"
  [ "$status" -eq 2 ]
}
