#!/usr/bin/env bats
#
# Unit tests for scripts/handlers/handle-approve.sh.
#
# Strategy mirrors handle-dismiss.bats: copy scripts/ to a per-test
# tmpdir, stub update-metadata.sh in-place to read/write a per-test
# marker.json file, and PATH-stub gh so we can capture and replay
# API responses.

bats_require_minimum_version 1.5.0

setup() {
  TEST_TMP="$(mktemp -d)"
  export TEST_TMP

  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export REPO_ROOT

  cp -r "$REPO_ROOT/scripts" "$TEST_TMP/scripts"

  # update-metadata.sh stub: read echoes marker.json; write captures stdin.
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

  # Default head SHA matches the marker's last_reviewed_sha.
  printf 'abc' > "$TEST_TMP/head_sha"

  : > "$TEST_TMP/call_log"
  mkdir -p "$TEST_TMP/bin"
  cat > "$TEST_TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "GH: $*" >> "$TEST_TMP/call_log"

# Capture --input <file> payload for inspection.
prev=""
for a in "$@"; do
  [[ "$prev" == "--input" ]] && cp "$a" "$TEST_TMP/last_payload.json"
  prev="$a"
done

case "$*" in
  *"--jq"*"head.sha"*)
    cat "$TEST_TMP/head_sha" ;;
  *"-X POST"*"/pulls/"*"/reviews"*)
    echo '{"id":456,"html_url":"https://github.com/o/r/pull/42#pullrequestreview-456"}' ;;
  *"/reactions"*)
    echo '{"id":1}' ;;
  *"-X POST"*"/issues/"*"/comments"*)
    echo '{"id":99}' ;;
  *)
    echo '{}' ;;
esac
STUB
  chmod +x "$TEST_TMP/bin/gh"
  export PATH="$TEST_TMP/bin:$PATH"

  # Default marker: F1 addressed, F2 withdrawn. SHA matches head_sha.
  cat > "$TEST_TMP/marker.json" <<'JSON'
{
  "version": "1.1",
  "last_reviewed_sha": "abc",
  "skill_version": "0.1.0",
  "model": "claude-opus-4-7",
  "findings": [
    {"id":"F1","severity":"major","status":"addressed","path":"src/x.go","line":10,"body":"original F1 body"},
    {"id":"F2","severity":"minor","status":"withdrawn","path":"src/y.go","line":5,"body":"original F2 body"}
  ],
  "dismissed_findings": []
}
JSON
}

teardown() { rm -rf "$TEST_TMP"; }

run_handler() {
  bash "$TEST_TMP/scripts/handlers/handle-approve.sh" "$@"
}

count() { grep -c -- "$1" "$TEST_TMP/call_log" || true; }

# ---------------------------------------------------------------------------

@test "happy path: all addressed, SHA matches → APPROVE submitted" {
  run --separate-stderr run_handler --repo o/r --pr 42 --actor alice --comment-id 555
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMP/last_payload.json" ]
  jq -e '.event == "APPROVE"' "$TEST_TMP/last_payload.json" >/dev/null
  jq -e '.commit_id == "abc"' "$TEST_TMP/last_payload.json" >/dev/null
  jq -e '.comments == []' "$TEST_TMP/last_payload.json" >/dev/null
  jq -e '.body | contains("Approved")' "$TEST_TMP/last_payload.json" >/dev/null
  jq -e '.body | contains("F1")' "$TEST_TMP/last_payload.json" >/dev/null
  jq -e '.body | contains("@alice")' "$TEST_TMP/last_payload.json" >/dev/null
  # Marker patched with audit fields.
  [ -f "$TEST_TMP/marker_written.json" ]
  jq -e '.approved_by == "alice"' "$TEST_TMP/marker_written.json" >/dev/null
  jq -e '.approved_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")' "$TEST_TMP/marker_written.json" >/dev/null
  # 👍 reaction posted.
  [ "$(count '/reactions')" -ge "1" ]
}

@test "SHA mismatch: PR has new commits → no APPROVE, error comment" {
  printf 'def0000' > "$TEST_TMP/head_sha"
  run --separate-stderr run_handler --repo o/r --pr 42 --actor alice --comment-id 555
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_TMP/last_payload.json" ]
  [ ! -f "$TEST_TMP/marker_written.json" ]
  grep -F 'new commits since the last review' "$TEST_TMP/call_log"
  [ "$(count '/reviews')" = "0" ]
}

@test "open unresolved finding blocks approval" {
  jq '.findings[0].status = "unresolved"' "$TEST_TMP/marker.json" \
    > "$TEST_TMP/marker.json.new" && mv "$TEST_TMP/marker.json.new" "$TEST_TMP/marker.json"
  run --separate-stderr run_handler --repo o/r --pr 42 --actor alice --comment-id 555
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_TMP/last_payload.json" ]
  grep -F 'finding(s) still open' "$TEST_TMP/call_log"
  grep -F 'F1' "$TEST_TMP/call_log"
}

@test "partially_addressed finding blocks approval" {
  jq '.findings[0].status = "partially_addressed"' "$TEST_TMP/marker.json" \
    > "$TEST_TMP/marker.json.new" && mv "$TEST_TMP/marker.json.new" "$TEST_TMP/marker.json"
  run --separate-stderr run_handler --repo o/r --pr 42 --actor alice --comment-id 555
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_TMP/last_payload.json" ]
  grep -F 'finding(s) still open' "$TEST_TMP/call_log"
}

@test "missing marker yields 'run /rtl review first'" {
  echo 'null' > "$TEST_TMP/marker.json"
  run --separate-stderr run_handler --repo o/r --pr 42 --actor alice --comment-id 555
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_TMP/last_payload.json" ]
  grep -F 'has not reviewed this PR yet' "$TEST_TMP/call_log"
}

@test "empty findings array still approves vacuously" {
  jq '.findings = []' "$TEST_TMP/marker.json" \
    > "$TEST_TMP/marker.json.new" && mv "$TEST_TMP/marker.json.new" "$TEST_TMP/marker.json"
  run --separate-stderr run_handler --repo o/r --pr 42 --actor alice --comment-id 555
  [ "$status" -eq 0 ]
  jq -e '.event == "APPROVE"' "$TEST_TMP/last_payload.json" >/dev/null
  jq -e '.body | contains("No findings were raised")' "$TEST_TMP/last_payload.json" >/dev/null
}

@test "dismissed finding with unresolved status does not block" {
  jq '.findings[0].status = "unresolved"
      | .dismissed_findings = [{"id":"F1","by":"alice","reason":"dup of F2","at":"2026-04-30T00:00:00Z"}]' \
    "$TEST_TMP/marker.json" > "$TEST_TMP/marker.json.new" \
    && mv "$TEST_TMP/marker.json.new" "$TEST_TMP/marker.json"
  run --separate-stderr run_handler --repo o/r --pr 42 --actor alice --comment-id 555
  [ "$status" -eq 0 ]
  jq -e '.event == "APPROVE"' "$TEST_TMP/last_payload.json" >/dev/null
  jq -e '.body | contains("Dismissed")' "$TEST_TMP/last_payload.json" >/dev/null
}

@test "missing last_reviewed_sha → error comment, no APPROVE" {
  jq 'del(.last_reviewed_sha)' "$TEST_TMP/marker.json" \
    > "$TEST_TMP/marker.json.new" && mv "$TEST_TMP/marker.json.new" "$TEST_TMP/marker.json"
  run --separate-stderr run_handler --repo o/r --pr 42 --actor alice --comment-id 555
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_TMP/last_payload.json" ]
  grep -F 'last_reviewed_sha' "$TEST_TMP/call_log"
}

@test "approval body includes finding recap with severity and status" {
  run --separate-stderr run_handler --repo o/r --pr 42 --actor alice --comment-id 555
  [ "$status" -eq 0 ]
  jq -e '.body | contains("F1")' "$TEST_TMP/last_payload.json" >/dev/null
  jq -e '.body | contains("major")' "$TEST_TMP/last_payload.json" >/dev/null
  jq -e '.body | contains("addressed")' "$TEST_TMP/last_payload.json" >/dev/null
  jq -e '.body | contains("F2")' "$TEST_TMP/last_payload.json" >/dev/null
  jq -e '.body | contains("withdrawn")' "$TEST_TMP/last_payload.json" >/dev/null
}
