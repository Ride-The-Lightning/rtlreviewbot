#!/usr/bin/env bats
#
# Unit tests for scripts/fetch-pr-context.sh.
#
# Strategy: stub `gh` via PATH injection. The stub dispatches based on the
# API path that appears in argv (e.g. `repos/.../pulls/N/files`) and on
# whether `Accept: application/vnd.github.diff` was passed. It serves
# canned fixtures from $TEST_TMP/fx, which setup() seeds from
# tests/fixtures/. Individual tests override fixtures by overwriting files
# in $TEST_TMP/fx before invoking the script.

bats_require_minimum_version 1.5.0

setup() {
  TEST_TMP="$(mktemp -d)"
  export TEST_TMP

  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export REPO_ROOT

  mkdir -p "$TEST_TMP/fx" "$TEST_TMP/bin"

  # Seed default fixtures.
  cp "$REPO_ROOT/tests/fixtures/pr.json"              "$TEST_TMP/fx/pr.json"
  cp "$REPO_ROOT/tests/fixtures/diff.txt"             "$TEST_TMP/fx/diff.txt"
  cp "$REPO_ROOT/tests/fixtures/files.json"           "$TEST_TMP/fx/files.json"
  cp "$REPO_ROOT/tests/fixtures/comments.json"        "$TEST_TMP/fx/comments.json"
  cp "$REPO_ROOT/tests/fixtures/review_comments.json" "$TEST_TMP/fx/review_comments.json"
  cp "$REPO_ROOT/tests/fixtures/reviews.json"         "$TEST_TMP/fx/reviews.json"

  : > "$TEST_TMP/call_log"
  printf '0' > "$TEST_TMP/gh_exit"
  : > "$TEST_TMP/gh_stderr"

  install_gh_stub
  export PATH="$TEST_TMP/bin:$PATH"
}

teardown() {
  rm -rf "$TEST_TMP"
}

# ---------------------------------------------------------------------------
# gh stub — dispatches on URL pattern and the diff Accept header.
# ---------------------------------------------------------------------------

install_gh_stub() {
  cat > "$TEST_TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_TMP/call_log"

# Force-fail mode for system-error tests.
if [[ -s "$TEST_TMP/gh_stderr" ]]; then
  cat "$TEST_TMP/gh_stderr" >&2
fi
exit_code="$(cat "$TEST_TMP/gh_exit" 2>/dev/null || echo 0)"
if (( exit_code != 0 )); then
  exit "$exit_code"
fi

url=""; is_diff=0
for a in "$@"; do
  case "$a" in
    repos/*) url="$a" ;;
    "Accept: application/vnd.github.diff") is_diff=1 ;;
  esac
done

case "$url" in
  repos/*/pulls/[0-9]*/files)     cat "$TEST_TMP/fx/files.json" ;;
  repos/*/issues/[0-9]*/comments) cat "$TEST_TMP/fx/comments.json" ;;
  repos/*/pulls/[0-9]*/comments)  cat "$TEST_TMP/fx/review_comments.json" ;;
  repos/*/pulls/[0-9]*/reviews)   cat "$TEST_TMP/fx/reviews.json" ;;
  repos/*/pulls/[0-9]*)
    if (( is_diff )); then cat "$TEST_TMP/fx/diff.txt"
    else                    cat "$TEST_TMP/fx/pr.json"
    fi
    ;;
  *) printf 'gh stub: unhandled url %s\n' "$url" >&2; exit 1 ;;
esac
STUB
  chmod +x "$TEST_TMP/bin/gh"
}

# ---------------------------------------------------------------------------
# PR metadata
# ---------------------------------------------------------------------------

@test "pr metadata is extracted from the PR object" {
  run --separate-stderr bash "$REPO_ROOT/scripts/fetch-pr-context.sh" \
    --repo Ride-The-Lightning/RTL-Web --pr 42
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.pr.number == 42' >/dev/null
  echo "$output" | jq -e '.pr.title == "Fix HTLC settlement edge case"' >/dev/null
  echo "$output" | jq -e '.pr.author == "alice"' >/dev/null
  echo "$output" | jq -e '.pr.base_sha | startswith("aaaa")' >/dev/null
  echo "$output" | jq -e '.pr.head_sha | startswith("bbbb")' >/dev/null
  echo "$output" | jq -e '.pr.base_ref == "main"' >/dev/null
  echo "$output" | jq -e '.pr.head_ref == "feature/htlc-fix"' >/dev/null
  echo "$output" | jq -e '.pr.draft == false' >/dev/null
}

@test "draft defaults to false when missing from PR object" {
  jq 'del(.draft)' "$TEST_TMP/fx/pr.json" > "$TEST_TMP/fx/pr.json.new"
  mv "$TEST_TMP/fx/pr.json.new" "$TEST_TMP/fx/pr.json"

  run --separate-stderr bash "$REPO_ROOT/scripts/fetch-pr-context.sh" \
    --repo Ride-The-Lightning/RTL-Web --pr 42
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.pr.draft == false' >/dev/null
}

# ---------------------------------------------------------------------------
# Diff handling
# ---------------------------------------------------------------------------

@test "diff text is included verbatim and char_count matches the original" {
  run --separate-stderr bash "$REPO_ROOT/scripts/fetch-pr-context.sh" \
    --repo o/r --pr 42
  [ "$status" -eq 0 ]
  expected_size="$(wc -c < "$TEST_TMP/fx/diff.txt" | tr -d ' ')"
  echo "$output" | jq -e --argjson n "$expected_size" '.diff.char_count == $n' >/dev/null
  echo "$output" | jq -e '.diff.truncated == false' >/dev/null
  echo "$output" | jq -e '.diff.text | contains("if h == nil")' >/dev/null
}

@test "diff is truncated when char_count exceeds --max-diff-chars" {
  run --separate-stderr bash "$REPO_ROOT/scripts/fetch-pr-context.sh" \
    --repo o/r --pr 42 --max-diff-chars 50
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.diff.truncated == true' >/dev/null
  echo "$output" | jq -e '.diff.max_chars == 50' >/dev/null
  # The original size is still reported (not the truncated size).
  expected_size="$(wc -c < "$TEST_TMP/fx/diff.txt" | tr -d ' ')"
  echo "$output" | jq -e --argjson n "$expected_size" '.diff.char_count == $n' >/dev/null
  # The text length is at most max_chars.
  echo "$output" | jq -e '.diff.text | length <= 50' >/dev/null
}

@test "max-diff-chars can be supplied via env" {
  RTL_MAX_DIFF_CHARS=50 \
    run --separate-stderr bash "$REPO_ROOT/scripts/fetch-pr-context.sh" \
      --repo o/r --pr 42
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.diff.truncated == true' >/dev/null
  echo "$output" | jq -e '.diff.max_chars == 50' >/dev/null
}

@test "diff request carries the Accept: application/vnd.github.diff header" {
  run --separate-stderr bash "$REPO_ROOT/scripts/fetch-pr-context.sh" \
    --repo o/r --pr 42
  [ "$status" -eq 0 ]
  grep -F 'Accept: application/vnd.github.diff' "$TEST_TMP/call_log"
}

# ---------------------------------------------------------------------------
# Files
# ---------------------------------------------------------------------------

@test "files list is flattened to {path, additions, deletions, status}" {
  run --separate-stderr bash "$REPO_ROOT/scripts/fetch-pr-context.sh" \
    --repo o/r --pr 42
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.files | length == 2' >/dev/null
  echo "$output" | jq -e '.files[0] | .path == "src/htlc.go" and .additions == 3' >/dev/null
  echo "$output" | jq -e '.files[1].path == "src/htlc_test.go"' >/dev/null
}

@test "empty files list is preserved as []" {
  echo '[]' > "$TEST_TMP/fx/files.json"
  run --separate-stderr bash "$REPO_ROOT/scripts/fetch-pr-context.sh" \
    --repo o/r --pr 42
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.files == []' >/dev/null
}

# ---------------------------------------------------------------------------
# Bot filtering
# ---------------------------------------------------------------------------

@test "bot's own issue comments are filtered out (default --bot-login)" {
  run --separate-stderr bash "$REPO_ROOT/scripts/fetch-pr-context.sh" \
    --repo o/r --pr 42
  [ "$status" -eq 0 ]
  # Two human comments (bob, alice); bot's holding comment dropped.
  echo "$output" | jq -e '.comments | length == 2' >/dev/null
  echo "$output" | jq -e '.comments | map(.user) | contains(["bob","alice"])' >/dev/null
  echo "$output" | jq -e '.comments | map(.user) | contains(["rtlreview[bot]"]) | not' >/dev/null
}

@test "bot's own review comments are filtered out" {
  run --separate-stderr bash "$REPO_ROOT/scripts/fetch-pr-context.sh" \
    --repo o/r --pr 42
  [ "$status" -eq 0 ]
  # Three total in fixture; only alice's reply remains.
  echo "$output" | jq -e '.review_comments | length == 1' >/dev/null
  echo "$output" | jq -e '.review_comments[0].user == "alice"' >/dev/null
  echo "$output" | jq -e '.review_comments[0].in_reply_to_id == 2001' >/dev/null
}

@test "bot's own reviews are filtered out" {
  run --separate-stderr bash "$REPO_ROOT/scripts/fetch-pr-context.sh" \
    --repo o/r --pr 42
  [ "$status" -eq 0 ]
  # Two reviews: bot's COMMENTED and carol's APPROVED. Bot dropped.
  echo "$output" | jq -e '.reviews | length == 1' >/dev/null
  echo "$output" | jq -e '.reviews[0].user == "carol"' >/dev/null
  echo "$output" | jq -e '.reviews[0].state == "APPROVED"' >/dev/null
}

@test "--bot-login overrides the filter target" {
  # If we pretend the bot is "alice", her comments should be filtered instead.
  run --separate-stderr bash "$REPO_ROOT/scripts/fetch-pr-context.sh" \
    --repo o/r --pr 42 --bot-login alice
  [ "$status" -eq 0 ]
  # comments fixture: bob, rtlreview[bot] (passthrough now), alice — alice dropped.
  echo "$output" | jq -e '.comments | map(.user) | contains(["bob"])' >/dev/null
  echo "$output" | jq -e '.comments | map(.user) | contains(["alice"]) | not' >/dev/null
}

# ---------------------------------------------------------------------------
# Argument validation
# ---------------------------------------------------------------------------

@test "missing --repo exits 2" {
  run bash "$REPO_ROOT/scripts/fetch-pr-context.sh" --pr 42
  [ "$status" -eq 2 ]
}

@test "missing --pr exits 2" {
  run bash "$REPO_ROOT/scripts/fetch-pr-context.sh" --repo o/r
  [ "$status" -eq 2 ]
}

@test "non-numeric --pr exits 2" {
  run bash "$REPO_ROOT/scripts/fetch-pr-context.sh" --repo o/r --pr forty-two
  [ "$status" -eq 2 ]
}

@test "invalid --repo format exits 2" {
  run bash "$REPO_ROOT/scripts/fetch-pr-context.sh" --repo not-a-repo --pr 1
  [ "$status" -eq 2 ]
}

@test "non-numeric --max-diff-chars exits 2" {
  run bash "$REPO_ROOT/scripts/fetch-pr-context.sh" \
    --repo o/r --pr 1 --max-diff-chars not-a-number
  [ "$status" -eq 2 ]
}

@test "unknown argument exits 2" {
  run bash "$REPO_ROOT/scripts/fetch-pr-context.sh" \
    --repo o/r --pr 1 --extra foo
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# API failure
# ---------------------------------------------------------------------------

@test "gh API failure exits 2" {
  printf '1' > "$TEST_TMP/gh_exit"
  printf 'gh: Not Found (HTTP 404)\n' > "$TEST_TMP/gh_stderr"
  run bash "$REPO_ROOT/scripts/fetch-pr-context.sh" --repo o/r --pr 1
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# Logging hygiene
# ---------------------------------------------------------------------------

@test "stderr lines are valid JSON log objects" {
  run --separate-stderr bash "$REPO_ROOT/scripts/fetch-pr-context.sh" \
    --repo o/r --pr 42
  [ "$status" -eq 0 ]
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    echo "$line" | jq -e '.level and .script and .event and .outcome' >/dev/null
  done <<< "$stderr"
}
