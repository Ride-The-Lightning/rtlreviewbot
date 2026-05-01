#!/usr/bin/env bats
#
# Unit tests for scripts/handlers/handle-close.sh.
#
# Same scripts/-copy + update-metadata.sh-stub pattern as handle-dismiss.

bats_require_minimum_version 1.5.0

setup() {
  TEST_TMP="$(mktemp -d)"
  export TEST_TMP

  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export REPO_ROOT

  cp -r "$REPO_ROOT/scripts" "$TEST_TMP/scripts"

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

  : > "$TEST_TMP/call_log"
  echo '[]' > "$TEST_TMP/labels.json"
  echo '{"merged":false}' > "$TEST_TMP/pr.json"

  mkdir -p "$TEST_TMP/bin"
  cat > "$TEST_TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "GH: $*" >> "$TEST_TMP/call_log"
case "$*" in
  *"--jq [.labels[].name]"*)         cat "$TEST_TMP/labels.json" ;;
  *"-X DELETE"*"/labels/"*)          exit 0 ;;
  *"api repos/"*"/pulls/"[0-9]*)     cat "$TEST_TMP/pr.json" ;;
  *)                                 echo '{}' ;;
esac
STUB
  chmod +x "$TEST_TMP/bin/gh"
  export PATH="$TEST_TMP/bin:$PATH"

  cat > "$TEST_TMP/marker.json" <<'JSON'
{"version":"1.1","last_reviewed_sha":"abc","findings":[],"dismissed_findings":[]}
JSON
}

teardown() { rm -rf "$TEST_TMP"; }

run_handler() {
  bash "$TEST_TMP/scripts/handlers/handle-close.sh" "$@"
}

count() { grep -c -- "$1" "$TEST_TMP/call_log" || true; }

# ---------------------------------------------------------------------------

@test "strips both labels and writes terminal marker on a merged PR" {
  echo '["rtl-active","rtl-paused"]' > "$TEST_TMP/labels.json"
  echo '{"merged":true}' > "$TEST_TMP/pr.json"
  run --separate-stderr run_handler --repo o/r --pr 42
  [ "$status" -eq 0 ]
  [ "$(count '/labels/rtl-active')" = "1" ]
  [ "$(count '/labels/rtl-paused')" = "1" ]
  [ -f "$TEST_TMP/marker_written.json" ]
  jq -e '.terminal.merged == true' "$TEST_TMP/marker_written.json" >/dev/null
  jq -e '.terminal.closed_at | length > 0' "$TEST_TMP/marker_written.json" >/dev/null
}

@test "strips only rtl-active when only it is set" {
  echo '["rtl-active"]' > "$TEST_TMP/labels.json"
  run --separate-stderr run_handler --repo o/r --pr 42
  [ "$status" -eq 0 ]
  [ "$(count '/labels/rtl-active')" = "1" ]
  [ "$(count '/labels/rtl-paused')" = "0" ]
}

@test "silent no-op when PR was never engaged (no labels, no marker)" {
  echo '[]' > "$TEST_TMP/labels.json"
  rm -f "$TEST_TMP/marker.json"
  run --separate-stderr run_handler --repo o/r --pr 42
  [ "$status" -eq 0 ]
  [ "$(count '/labels/rtl')" = "0" ]
  [ ! -f "$TEST_TMP/marker_written.json" ]
}

@test "marker terminal record uses .merged from the PR object, not the event" {
  echo '["rtl-active"]' > "$TEST_TMP/labels.json"
  echo '{"merged":false}' > "$TEST_TMP/pr.json"
  run --separate-stderr run_handler --repo o/r --pr 42
  [ "$status" -eq 0 ]
  jq -e '.terminal.merged == false' "$TEST_TMP/marker_written.json" >/dev/null
}

@test "missing --repo exits 2" {
  run run_handler --pr 42
  [ "$status" -eq 2 ]
}
