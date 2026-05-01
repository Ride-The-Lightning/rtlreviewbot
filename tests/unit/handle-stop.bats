#!/usr/bin/env bats
#
# Unit tests for scripts/handlers/handle-stop.sh.

bats_require_minimum_version 1.5.0

setup() {
  TEST_TMP="$(mktemp -d)"
  export TEST_TMP

  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export REPO_ROOT

  mkdir -p "$TEST_TMP/bin"

  # Test-controllable label set; the gh stub returns this when asked for
  # `[.labels[].name]`.
  echo '[]' > "$TEST_TMP/labels.json"
  : > "$TEST_TMP/call_log"

  cat > "$TEST_TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "GH: $*" >> "$TEST_TMP/call_log"

case "$*" in
  *"-X DELETE"*"/labels/"*) exit 0 ;;
  *"--jq [.labels[].name]"*) cat "$TEST_TMP/labels.json" ;;
  *"/reactions"*)            echo '{"id":1}' ;;
  *"-X POST"*"/comments"*)   echo '{"id":99}' ;;
  *)                         echo '{}' ;;
esac
STUB
  chmod +x "$TEST_TMP/bin/gh"
  export PATH="$TEST_TMP/bin:$PATH"
}

teardown() { rm -rf "$TEST_TMP"; }

run_handler() {
  bash "$REPO_ROOT/scripts/handlers/handle-stop.sh" "$@"
}

count() { grep -c -- "$1" "$TEST_TMP/call_log" || true; }

# ---------------------------------------------------------------------------

@test "removes both rtl-active and rtl-paused when present" {
  echo '["rtl-active","rtl-paused","other"]' > "$TEST_TMP/labels.json"
  run --separate-stderr run_handler --repo o/r --pr 42 --actor alice --comment-id 555
  [ "$status" -eq 0 ]
  [ "$(count '/labels/rtl-active')" = "1" ]
  [ "$(count '/labels/rtl-paused')" = "1" ]
  [ "$(count '/reactions')" = "1" ]
}

@test "removes only rtl-active when rtl-paused is absent" {
  echo '["rtl-active"]' > "$TEST_TMP/labels.json"
  run --separate-stderr run_handler --repo o/r --pr 42 --actor alice
  [ "$status" -eq 0 ]
  [ "$(count '/labels/rtl-active')" = "1" ]
  [ "$(count '/labels/rtl-paused')" = "0" ]
}

@test "no-op when neither label is present (still reacts)" {
  echo '["other"]' > "$TEST_TMP/labels.json"
  run --separate-stderr run_handler --repo o/r --pr 42 --actor alice --comment-id 555
  [ "$status" -eq 0 ]
  [ "$(count '/labels/rtl')" = "0" ]
  [ "$(count '/reactions')" = "1" ]
}

@test "no reaction call when --comment-id is absent" {
  echo '["rtl-active"]' > "$TEST_TMP/labels.json"
  run --separate-stderr run_handler --repo o/r --pr 42 --actor alice
  [ "$status" -eq 0 ]
  [ "$(count '/reactions')" = "0" ]
}

@test "missing --repo exits 2" {
  run run_handler --pr 42 --actor alice
  [ "$status" -eq 2 ]
}

@test "stderr is structured JSON" {
  echo '["rtl-active"]' > "$TEST_TMP/labels.json"
  run --separate-stderr run_handler --repo o/r --pr 42 --actor alice
  [ "$status" -eq 0 ]
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    echo "$line" | jq -e '.level and .script and .event and .outcome' >/dev/null
  done <<< "$stderr"
}
