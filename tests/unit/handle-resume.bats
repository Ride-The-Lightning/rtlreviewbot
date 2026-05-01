#!/usr/bin/env bats
#
# Unit tests for scripts/handlers/handle-resume.sh.

bats_require_minimum_version 1.5.0

setup() {
  TEST_TMP="$(mktemp -d)"
  export TEST_TMP

  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export REPO_ROOT

  mkdir -p "$TEST_TMP/bin"
  echo '[]' > "$TEST_TMP/labels.json"
  : > "$TEST_TMP/call_log"

  cat > "$TEST_TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "GH: $*" >> "$TEST_TMP/call_log"
case "$*" in
  *"--jq [.labels[].name]"*) cat "$TEST_TMP/labels.json" ;;
  *"-X DELETE"*"/labels/"*) exit 0 ;;
  *"/reactions"*)            echo '{"id":1}' ;;
  *)                         echo '{}' ;;
esac
STUB
  chmod +x "$TEST_TMP/bin/gh"
  export PATH="$TEST_TMP/bin:$PATH"
}

teardown() { rm -rf "$TEST_TMP"; }

run_handler() {
  bash "$REPO_ROOT/scripts/handlers/handle-resume.sh" "$@"
}

count() { grep -c -- "$1" "$TEST_TMP/call_log" || true; }

# ---------------------------------------------------------------------------

@test "removes rtl-paused when present" {
  echo '["rtl-active","rtl-paused"]' > "$TEST_TMP/labels.json"
  run --separate-stderr run_handler --repo o/r --pr 42 --comment-id 555
  [ "$status" -eq 0 ]
  [ "$(count '/labels/rtl-paused')" = "1" ]
  [ "$(count '/reactions')" = "1" ]
}

@test "no-op when rtl-paused is absent (still reacts)" {
  echo '["rtl-active"]' > "$TEST_TMP/labels.json"
  run --separate-stderr run_handler --repo o/r --pr 42 --comment-id 555
  [ "$status" -eq 0 ]
  [ "$(count '/labels/rtl-paused')" = "0" ]
  [ "$(count '/reactions')" = "1" ]
}

@test "missing --repo exits 2" {
  run run_handler --pr 42
  [ "$status" -eq 2 ]
}
