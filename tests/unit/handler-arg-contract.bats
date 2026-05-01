#!/usr/bin/env bats
#
# Regression test: every handler under scripts/handlers/ tolerates the
# full set of arguments the dispatcher (run-review.sh) might forward.
# Catches the v0.7.0 -> v0.7.1 failure where the dispatcher started
# passing --comment-id but handle-review.sh's strict arg parser
# rejected it as "unknown argument".
#
# What we test, per handler:
#   - The handler does NOT log a parse_args failure
#   - The handler does NOT print "unknown argument" anywhere on stderr
#
# We do NOT verify each handler completes its full job — we only care
# that the arg-parsing step succeeds. Sub-scripts and gh are stubbed
# permissively so handlers don't bail before reaching their core
# logic; if they bail later for unrelated reasons that's fine for this
# test.

bats_require_minimum_version 1.5.0

setup() {
  TEST_TMP="$(mktemp -d)"
  export TEST_TMP

  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export REPO_ROOT

  # Copy scripts/ to a tmpdir so we can overlay sub-scripts.
  cp -r "$REPO_ROOT/scripts" "$TEST_TMP/scripts"

  # Permissive sub-script stubs. The arg-parsing step runs first in
  # every handler; these stubs let any handler that gets that far
  # continue running without exploding on missing tools.
  for sub in fetch-pr-context post-holding-comment update-metadata post-review; do
    cat > "$TEST_TMP/scripts/$sub.sh" <<'STUB'
#!/usr/bin/env bash
echo '{}'
STUB
    chmod +x "$TEST_TMP/scripts/$sub.sh"
  done

  # PATH-stub gh — most handlers call it for label checks, comment
  # posts, reactions, etc. The stub returns enough to satisfy the
  # common shapes (empty labels, empty objects).
  mkdir -p "$TEST_TMP/bin"
  cat > "$TEST_TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"--jq [.labels[].name]"*) echo '[]' ;;
  *)                          echo '{}' ;;
esac
STUB
  chmod +x "$TEST_TMP/bin/gh"
  export PATH="$TEST_TMP/bin:$PATH"
}

teardown() { rm -rf "$TEST_TMP"; }

@test "every handler tolerates the full dispatcher arg set" {
  # The full set of args the dispatcher forwards. issue_comment events
  # forward all of these; pull_request events omit --comment-id and
  # --args, but every handler must still tolerate them when present
  # — the dispatcher's arg-list could grow in the future, and stubs/
  # tests should not need a coordinated update for a handler to keep
  # working under unrecognized flags.
  args=(
    --repo o/r
    --pr 42
    --actor alice
    --bot-login 'rtlreview[bot]'
    --comment-id 555
    --args "F1 a reason"
  )

  fail_count=0
  failures=""
  for handler in "$TEST_TMP/scripts/handlers/"handle-*.sh; do
    name="$(basename "$handler" .sh)"

    # We don't care about the handler's exit status — it may legitimately
    # exit non-zero on missing context, no marker, etc. We only check
    # stderr for arg-parsing failures.
    set +e
    stderr_capture="$(bash "$handler" "${args[@]}" 2>&1 >/dev/null)"
    set -e

    if printf '%s' "$stderr_capture" | grep -qF '"event":"parse_args","outcome":"failure"'; then
      failures+="${name}: parse_args failure logged"$'\n'
      fail_count=$((fail_count + 1))
      continue
    fi
    if printf '%s' "$stderr_capture" | grep -qiF "unknown argument"; then
      failures+="${name}: 'unknown argument' on stderr"$'\n'
      fail_count=$((fail_count + 1))
      continue
    fi
  done

  if (( fail_count > 0 )); then
    printf 'Handler arg-contract regressions:\n%s\n' "$failures" >&2
    return 1
  fi
}
