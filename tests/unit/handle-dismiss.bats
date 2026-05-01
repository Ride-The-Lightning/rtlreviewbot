#!/usr/bin/env bats
#
# Unit tests for scripts/handlers/handle-dismiss.sh.
#
# Strategy: copy scripts/ to a per-test tmpdir so the handler's $REPO_ROOT
# points at our copy. Replace update-metadata.sh with a stub that reads/
# writes a per-test marker JSON file. PATH-stub gh for label, comment,
# reaction, and edit calls.

bats_require_minimum_version 1.5.0

setup() {
  TEST_TMP="$(mktemp -d)"
  export TEST_TMP

  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export REPO_ROOT

  cp -r "$REPO_ROOT/scripts" "$TEST_TMP/scripts"

  # update-metadata.sh stub: --mode read echoes the current marker.json
  # file contents (or "null"); --mode write reads stdin and saves it.
  cat > "$TEST_TMP/scripts/update-metadata.sh" <<'STUB'
#!/usr/bin/env bash
mode=""
for ((i=1; i<=$#; i++)); do
  if [[ "${!i}" == "--mode" ]]; then j=$((i+1)); mode="${!j}"; fi
done
case "$mode" in
  read)  cat "$TEST_TMP/marker.json" ;;
  write) cat > "$TEST_TMP/marker_written.json" ;;
esac
STUB
  chmod +x "$TEST_TMP/scripts/update-metadata.sh"

  : > "$TEST_TMP/call_log"
  mkdir -p "$TEST_TMP/bin"
  cat > "$TEST_TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "GH: $*" >> "$TEST_TMP/call_log"
case "$*" in
  *"/reactions"*)               echo '{"id":1}' ;;
  *"-X PATCH"*"/comments/"*)    exit 0 ;;
  *"-X POST"*"/comments"*)      echo '{"id":99}' ;;
  *)                             echo '{}' ;;
esac
STUB
  chmod +x "$TEST_TMP/bin/gh"
  export PATH="$TEST_TMP/bin:$PATH"

  # Default marker: F1 (active) and F3 (already dismissed).
  cat > "$TEST_TMP/marker.json" <<'JSON'
{
  "version": "1.1",
  "last_reviewed_sha": "abc",
  "findings": [
    {"id":"F1","severity":"major","status":"unresolved","path":"src/x.go","line":10,"body":"original F1 body","inline_comment_id":1001},
    {"id":"F2","severity":"minor","status":"unresolved","path":"src/y.go","line":5,"body":"original F2 body","inline_comment_id":null},
    {"id":"F3","severity":"minor","status":"unresolved","path":"src/z.go","line":1,"body":"original F3 body","inline_comment_id":1003}
  ],
  "dismissed_findings": [
    {"id":"F3","by":"alice","reason":"already gone","at":"2026-04-30T00:00:00Z"}
  ]
}
JSON
}

teardown() { rm -rf "$TEST_TMP"; }

run_handler() {
  bash "$TEST_TMP/scripts/handlers/handle-dismiss.sh" "$@"
}

count() { grep -c -- "$1" "$TEST_TMP/call_log" || true; }

# ---------------------------------------------------------------------------

@test "dismissing F1 appends to dismissed_findings and edits the inline comment" {
  run --separate-stderr run_handler --repo o/r --pr 42 --actor alice \
    --comment-id 555 --args "F1 false positive on this codepath"
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMP/marker_written.json" ]
  jq -e '.dismissed_findings | length == 2' "$TEST_TMP/marker_written.json" >/dev/null
  jq -e '.dismissed_findings[1] | .id == "F1" and .by == "alice" and (.reason | startswith("false positive"))' \
    "$TEST_TMP/marker_written.json" >/dev/null
  # Inline comment edited at id 1001 (F1's inline_comment_id from the marker).
  [ "$(count 'PATCH.*/comments/1001')" = "1" ]
  [ "$(count '/reactions')" = "1" ]
}

@test "dismissing F2 (no inline_comment_id) updates marker but skips inline edit" {
  run --separate-stderr run_handler --repo o/r --pr 42 --actor alice \
    --args "F2 demoted finding still ok"
  [ "$status" -eq 0 ]
  jq -e '.dismissed_findings | length == 2' "$TEST_TMP/marker_written.json" >/dev/null
  [ "$(count 'PATCH.*/comments/')" = "0" ]
}

@test "rejects an already-dismissed finding (F3) without writing the marker" {
  run --separate-stderr run_handler --repo o/r --pr 42 --actor alice \
    --comment-id 555 --args "F3"
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_TMP/marker_written.json" ]
  # Posts an "already dismissed" message, still reacts.
  grep -F 'POST repos/o/r/issues/42/comments' "$TEST_TMP/call_log"
  [ "$(count '/reactions')" = "1" ]
}

@test "rejects an unknown finding id" {
  run --separate-stderr run_handler --repo o/r --pr 42 --actor alice --args "F99 nope"
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_TMP/marker_written.json" ]
  grep -F 'no such finding' "$TEST_TMP/call_log"
}

@test "rejects malformed first arg (not Fn)" {
  run --separate-stderr run_handler --repo o/r --pr 42 --actor alice --args "junk reason"
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_TMP/marker_written.json" ]
  grep -F 'must be a finding id' "$TEST_TMP/call_log"
}

@test "missing --args explains the syntax" {
  run --separate-stderr run_handler --repo o/r --pr 42 --actor alice
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_TMP/marker_written.json" ]
  grep -F 'requires a finding id' "$TEST_TMP/call_log"
}

@test "absent marker yields a clear 'run /rtl review first' error" {
  echo 'null' > "$TEST_TMP/marker.json"
  run --separate-stderr run_handler --repo o/r --pr 42 --actor alice --args "F1 anything"
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_TMP/marker_written.json" ]
  grep -F 'has not reviewed this PR yet' "$TEST_TMP/call_log"
}
