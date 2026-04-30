#!/usr/bin/env bats
#
# Unit tests for scripts/post-holding-comment.sh.
#
# Strategy: stub `gh` via PATH injection. The stub branches on the request
# shape — list (GET /issues/N/comments) vs post (-X POST). Both responses
# come from per-test fixture files so each test can set up the world it needs.

bats_require_minimum_version 1.5.0

setup() {
  TEST_TMP="$(mktemp -d)"
  export TEST_TMP

  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export REPO_ROOT

  : > "$TEST_TMP/call_log"
  : > "$TEST_TMP/post_args.txt"

  # Default fixtures: empty comment list, post returns id 999.
  printf '[]' > "$TEST_TMP/list_response.json"
  printf '%s' '{"id":999,"html_url":"https://github.com/o/r/issues/1#issuecomment-999"}' \
    > "$TEST_TMP/post_response.json"

  # Default exit codes for the stub.
  printf '0' > "$TEST_TMP/list_exit"
  printf '0' > "$TEST_TMP/post_exit"
  : > "$TEST_TMP/list_stderr"
  : > "$TEST_TMP/post_stderr"

  install_gh_stub

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
# Log every invocation's argv on a single line.
printf '%s\n' "$*" >> "$TEST_TMP/call_log"

is_post=0
for a in "$@"; do
  if [[ "$a" == "POST" ]]; then is_post=1; fi
done

if (( is_post )); then
  # Capture each arg of the POST so tests can assert what we sent.
  : > "$TEST_TMP/post_args.txt"
  for a in "$@"; do
    printf '%s\n' "$a" >> "$TEST_TMP/post_args.txt"
  done
  cat "$TEST_TMP/post_response.json"
  if [[ -s "$TEST_TMP/post_stderr" ]]; then cat "$TEST_TMP/post_stderr" >&2; fi
  exit "$(cat "$TEST_TMP/post_exit")"
else
  cat "$TEST_TMP/list_response.json"
  if [[ -s "$TEST_TMP/list_stderr" ]]; then cat "$TEST_TMP/list_stderr" >&2; fi
  exit "$(cat "$TEST_TMP/list_exit")"
fi
STUB
  chmod +x "$TEST_TMP/bin/gh"
}

list_call_count() {
  grep -cv -- '-X POST' "$TEST_TMP/call_log" || true
}
post_call_count() {
  grep -c -- '-X POST' "$TEST_TMP/call_log" || true
}

# ---------------------------------------------------------------------------
# Happy path — fresh post
# ---------------------------------------------------------------------------

@test "posts a new holding comment when none exists, returns id+url" {
  run --separate-stderr bash "$REPO_ROOT/scripts/post-holding-comment.sh" \
    --repo Ride-The-Lightning/RTL-Web --pr 42
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.comment_id == 999' >/dev/null
  echo "$output" | jq -e '.html_url == "https://github.com/o/r/issues/1#issuecomment-999"' >/dev/null
  echo "$output" | jq -e '.created == true' >/dev/null
}

@test "POST goes to the correct endpoint" {
  run --separate-stderr bash "$REPO_ROOT/scripts/post-holding-comment.sh" \
    --repo Ride-The-Lightning/RTL-Web --pr 42
  [ "$status" -eq 0 ]
  grep -Fx 'repos/Ride-The-Lightning/RTL-Web/issues/42/comments' "$TEST_TMP/post_args.txt"
}

@test "posted body contains the rtl-holding marker" {
  run --separate-stderr bash "$REPO_ROOT/scripts/post-holding-comment.sh" \
    --repo Ride-The-Lightning/RTL-Web --pr 42
  [ "$status" -eq 0 ]
  # The marker should appear in the body= field passed to gh.
  grep -F '<!-- rtl-holding -->' "$TEST_TMP/post_args.txt"
}

@test "default body includes the 'review starting' phrase" {
  run --separate-stderr bash "$REPO_ROOT/scripts/post-holding-comment.sh" \
    --repo Ride-The-Lightning/RTL-Web --pr 42
  [ "$status" -eq 0 ]
  grep -F 'review starting' "$TEST_TMP/post_args.txt"
}

@test "custom --body is sent verbatim alongside the marker" {
  run --separate-stderr bash "$REPO_ROOT/scripts/post-holding-comment.sh" \
    --repo Ride-The-Lightning/RTL-Web --pr 42 \
    --body 'queued — back in a minute'
  [ "$status" -eq 0 ]
  grep -F 'queued — back in a minute' "$TEST_TMP/post_args.txt"
  grep -F '<!-- rtl-holding -->' "$TEST_TMP/post_args.txt"
}

# ---------------------------------------------------------------------------
# Idempotency — reuse existing holding comment
# ---------------------------------------------------------------------------

@test "reuses an existing holding comment, does not POST" {
  cat > "$TEST_TMP/list_response.json" <<'JSON'
[
  {"id":111,"html_url":"https://github.com/o/r/issues/1#issuecomment-111","body":"some unrelated comment"},
  {"id":222,"html_url":"https://github.com/o/r/issues/1#issuecomment-222","body":"<!-- rtl-holding -->\n👀 rtlreviewbot review starting…"}
]
JSON

  run --separate-stderr bash "$REPO_ROOT/scripts/post-holding-comment.sh" \
    --repo Ride-The-Lightning/RTL-Web --pr 42
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.comment_id == 222' >/dev/null
  echo "$output" | jq -e '.created == false' >/dev/null
  [ "$(post_call_count)" = "0" ]
}

@test "ignores comments that don't carry the marker" {
  cat > "$TEST_TMP/list_response.json" <<'JSON'
[
  {"id":1,"html_url":"u","body":"LGTM"},
  {"id":2,"html_url":"u","body":"thanks!"}
]
JSON

  run --separate-stderr bash "$REPO_ROOT/scripts/post-holding-comment.sh" \
    --repo Ride-The-Lightning/RTL-Web --pr 42
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.created == true' >/dev/null
  [ "$(post_call_count)" = "1" ]
}

@test "tolerates a comment with null body in the list" {
  cat > "$TEST_TMP/list_response.json" <<'JSON'
[
  {"id":1,"html_url":"u","body":null},
  {"id":2,"html_url":"u","body":"LGTM"}
]
JSON

  run --separate-stderr bash "$REPO_ROOT/scripts/post-holding-comment.sh" \
    --repo Ride-The-Lightning/RTL-Web --pr 42
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.created == true' >/dev/null
}

# ---------------------------------------------------------------------------
# API failures (exit 2)
# ---------------------------------------------------------------------------

@test "list-comments API failure exits 2" {
  printf '1' > "$TEST_TMP/list_exit"
  printf 'gh: Internal Server Error (HTTP 500)\n' > "$TEST_TMP/list_stderr"
  run --separate-stderr bash "$REPO_ROOT/scripts/post-holding-comment.sh" \
    --repo Ride-The-Lightning/RTL-Web --pr 42
  [ "$status" -eq 2 ]
}

@test "POST failure exits 2" {
  printf '1' > "$TEST_TMP/post_exit"
  printf 'gh: Forbidden (HTTP 403)\n' > "$TEST_TMP/post_stderr"
  run --separate-stderr bash "$REPO_ROOT/scripts/post-holding-comment.sh" \
    --repo Ride-The-Lightning/RTL-Web --pr 42
  [ "$status" -eq 2 ]
}

@test "POST returns malformed JSON exits 2" {
  printf '%s' 'not json at all' > "$TEST_TMP/post_response.json"
  run --separate-stderr bash "$REPO_ROOT/scripts/post-holding-comment.sh" \
    --repo Ride-The-Lightning/RTL-Web --pr 42
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# Argument validation
# ---------------------------------------------------------------------------

@test "missing --repo exits 2" {
  run --separate-stderr bash "$REPO_ROOT/scripts/post-holding-comment.sh" --pr 42
  [ "$status" -eq 2 ]
}

@test "missing --pr exits 2" {
  run --separate-stderr bash "$REPO_ROOT/scripts/post-holding-comment.sh" --repo Ride-The-Lightning/RTL-Web
  [ "$status" -eq 2 ]
}

@test "non-numeric --pr exits 2" {
  run --separate-stderr bash "$REPO_ROOT/scripts/post-holding-comment.sh" \
    --repo Ride-The-Lightning/RTL-Web --pr forty-two
  [ "$status" -eq 2 ]
}

@test "invalid --repo format exits 2" {
  run --separate-stderr bash "$REPO_ROOT/scripts/post-holding-comment.sh" \
    --repo not-a-repo --pr 1
  [ "$status" -eq 2 ]
}

@test "unknown argument exits 2" {
  run --separate-stderr bash "$REPO_ROOT/scripts/post-holding-comment.sh" \
    --repo Ride-The-Lightning/RTL-Web --pr 1 --unexpected foo
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# Logging hygiene
# ---------------------------------------------------------------------------

@test "stderr lines are valid JSON log objects" {
  run --separate-stderr bash "$REPO_ROOT/scripts/post-holding-comment.sh" \
    --repo Ride-The-Lightning/RTL-Web --pr 42
  [ "$status" -eq 0 ]
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    echo "$line" | jq -e '.level and .script and .event and .outcome' >/dev/null
  done <<< "$stderr"
}
