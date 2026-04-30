#!/usr/bin/env bats
#
# Unit tests for scripts/update-metadata.sh.
#
# Strategy: stub `gh` via PATH injection. The stub dispatches based on the
# request method (GET=list, PATCH=update, POST=create) and reads canned
# responses from per-test files. It also captures the body file path that
# was passed via `-F body=@<file>`, so tests can inspect what would be
# written to GitHub.

bats_require_minimum_version 1.5.0

setup() {
  TEST_TMP="$(mktemp -d)"
  export TEST_TMP

  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export REPO_ROOT

  mkdir -p "$TEST_TMP/bin"
  : > "$TEST_TMP/call_log"
  : > "$TEST_TMP/last_method"
  : > "$TEST_TMP/last_body_file_copy"

  # Default fixtures.
  printf '[]' > "$TEST_TMP/list_response.json"
  printf '%s' '{"id":7777,"html_url":"u"}' > "$TEST_TMP/post_response.json"
  printf '%s' '{"id":1002,"html_url":"u"}' > "$TEST_TMP/patch_response.json"
  printf '0' > "$TEST_TMP/list_exit"
  printf '0' > "$TEST_TMP/post_exit"
  printf '0' > "$TEST_TMP/patch_exit"
  : > "$TEST_TMP/list_stderr"
  : > "$TEST_TMP/post_stderr"
  : > "$TEST_TMP/patch_stderr"

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
  cat > "$TEST_TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_TMP/call_log"

method="GET"
body_arg=""
prev=""
for a in "$@"; do
  case "$a" in
    PATCH) method=PATCH ;;
    POST)  method=POST  ;;
  esac
  if [[ "$prev" == "-F" && "$a" == body=@* ]]; then
    body_arg="${a#body=@}"
  fi
  prev="$a"
done

printf '%s' "$method" > "$TEST_TMP/last_method"
# Copy the body file (it lives in a temp dir that the script will rm -rf
# on exit) so tests can still inspect it after the run completes.
if [[ -n "$body_arg" && -f "$body_arg" ]]; then
  cp "$body_arg" "$TEST_TMP/last_body_file_copy"
fi

case "$method" in
  PATCH)
    [[ -s "$TEST_TMP/patch_stderr" ]] && cat "$TEST_TMP/patch_stderr" >&2
    cat "$TEST_TMP/patch_response.json"
    exit "$(cat "$TEST_TMP/patch_exit")"
    ;;
  POST)
    [[ -s "$TEST_TMP/post_stderr" ]] && cat "$TEST_TMP/post_stderr" >&2
    cat "$TEST_TMP/post_response.json"
    exit "$(cat "$TEST_TMP/post_exit")"
    ;;
  GET)
    [[ -s "$TEST_TMP/list_stderr" ]] && cat "$TEST_TMP/list_stderr" >&2
    cat "$TEST_TMP/list_response.json"
    exit "$(cat "$TEST_TMP/list_exit")"
    ;;
esac
STUB
  chmod +x "$TEST_TMP/bin/gh"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Compose a list-comments fixture containing exactly one rtlreviewbot
# marker comment with the given state JSON.
make_marker_fixture() {
  local id="$1" state_json="$2"
  jq -n --arg s "$state_json" --argjson id "$id" '
    [{
      id: $id,
      user: {login: "rtlreview[bot]"},
      body: ("<!-- rtlreviewbot-meta\n" + $s + "\n-->")
    }]
  ' > "$TEST_TMP/list_response.json"
}

# ---------------------------------------------------------------------------
# READ — happy paths
# ---------------------------------------------------------------------------

@test "read returns parsed state JSON when marker is present" {
  make_marker_fixture 1002 '{"version":"1.0","last_reviewed_sha":"abc","findings":[{"id":"F1","severity":"major"}]}'
  run --separate-stderr bash "$REPO_ROOT/scripts/update-metadata.sh" \
    --repo o/r --pr 1 --mode read
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.version == "1.0"' >/dev/null
  echo "$output" | jq -e '.last_reviewed_sha == "abc"' >/dev/null
  echo "$output" | jq -e '.findings[0].id == "F1"' >/dev/null
}

@test "read returns the literal 'null' when no marker comments exist" {
  printf '[]' > "$TEST_TMP/list_response.json"
  run --separate-stderr bash "$REPO_ROOT/scripts/update-metadata.sh" \
    --repo o/r --pr 1 --mode read
  [ "$status" -eq 0 ]
  [ "$output" = "null" ]
}

@test "read returns 'null' when no rtlreviewbot-authored comments exist" {
  cat > "$TEST_TMP/list_response.json" <<'JSON'
[{"id":1,"user":{"login":"bob"},"body":"random comment"},
 {"id":2,"user":{"login":"alice"},"body":"another"}]
JSON
  run --separate-stderr bash "$REPO_ROOT/scripts/update-metadata.sh" \
    --repo o/r --pr 1 --mode read
  [ "$status" -eq 0 ]
  [ "$output" = "null" ]
}

@test "read ignores spoofed markers (sentinel present, but author is not the bot)" {
  cat > "$TEST_TMP/list_response.json" <<'JSON'
[{"id":99,"user":{"login":"impersonator"},"body":"<!-- rtlreviewbot-meta\n{\"x\":1}\n-->"}]
JSON
  run --separate-stderr bash "$REPO_ROOT/scripts/update-metadata.sh" \
    --repo o/r --pr 1 --mode read
  [ "$status" -eq 0 ]
  [ "$output" = "null" ]
}

@test "read tolerates a rich marker with nested arrays" {
  make_marker_fixture 1002 '{"findings":[{"id":"F1"},{"id":"F2"}],"dismissed_findings":[{"id":"F3","by":"alice"}]}'
  run --separate-stderr bash "$REPO_ROOT/scripts/update-metadata.sh" \
    --repo o/r --pr 1 --mode read
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.findings | length == 2' >/dev/null
  echo "$output" | jq -e '.dismissed_findings[0].by == "alice"' >/dev/null
}

# ---------------------------------------------------------------------------
# READ — error paths
# ---------------------------------------------------------------------------

@test "read exits 2 when marker JSON is corrupt" {
  cat > "$TEST_TMP/list_response.json" <<'JSON'
[{"id":1002,"user":{"login":"rtlreview[bot]"},"body":"<!-- rtlreviewbot-meta\nthis is not json\n-->"}]
JSON
  run bash "$REPO_ROOT/scripts/update-metadata.sh" \
    --repo o/r --pr 1 --mode read
  [ "$status" -eq 2 ]
}

@test "read exits 2 when marker body is empty between sentinels" {
  cat > "$TEST_TMP/list_response.json" <<'JSON'
[{"id":1002,"user":{"login":"rtlreview[bot]"},"body":"<!-- rtlreviewbot-meta\n-->"}]
JSON
  run bash "$REPO_ROOT/scripts/update-metadata.sh" \
    --repo o/r --pr 1 --mode read
  [ "$status" -eq 2 ]
}

@test "read exits 2 when listing comments fails" {
  printf '1' > "$TEST_TMP/list_exit"
  printf 'gh: Not Found (HTTP 404)\n' > "$TEST_TMP/list_stderr"
  run bash "$REPO_ROOT/scripts/update-metadata.sh" \
    --repo o/r --pr 1 --mode read
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# WRITE — create new
# ---------------------------------------------------------------------------

@test "write creates a new marker via POST when none exists" {
  printf '[]' > "$TEST_TMP/list_response.json"
  run --separate-stderr bash -c '
    echo "{\"version\":\"1.0\",\"last_reviewed_sha\":\"abc\",\"findings\":[]}" \
      | bash "$1" --repo o/r --pr 1 --mode write
  ' _ "$REPO_ROOT/scripts/update-metadata.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.created == true' >/dev/null
  echo "$output" | jq -e '.comment_id == 7777' >/dev/null
  [ "$(cat "$TEST_TMP/last_method")" = "POST" ]

  # The body sent to GitHub must contain the open and close sentinels and
  # be valid JSON between them.
  grep -F '<!-- rtlreviewbot-meta' "$TEST_TMP/last_body_file_copy"
  grep -Fx '-->' "$TEST_TMP/last_body_file_copy"
  awk '/<!-- rtlreviewbot-meta/{f=1;next}/-->/{f=0;next}f' \
    "$TEST_TMP/last_body_file_copy" | jq -e '.last_reviewed_sha == "abc"' >/dev/null
}

# ---------------------------------------------------------------------------
# WRITE — update existing
# ---------------------------------------------------------------------------

@test "write updates an existing marker via PATCH on its comment id" {
  make_marker_fixture 1002 '{"version":"1.0","findings":[]}'
  run --separate-stderr bash -c '
    echo "{\"version\":\"1.0\",\"last_reviewed_sha\":\"new\",\"findings\":[{\"id\":\"F1\"}]}" \
      | bash "$1" --repo o/r --pr 1 --mode write
  ' _ "$REPO_ROOT/scripts/update-metadata.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.created == false' >/dev/null
  echo "$output" | jq -e '.comment_id == 1002' >/dev/null
  [ "$(cat "$TEST_TMP/last_method")" = "PATCH" ]
  grep -F 'repos/o/r/issues/comments/1002' "$TEST_TMP/call_log"

  awk '/<!-- rtlreviewbot-meta/{f=1;next}/-->/{f=0;next}f' \
    "$TEST_TMP/last_body_file_copy" | jq -e '.last_reviewed_sha == "new"' >/dev/null
}

@test "write does not POST a duplicate marker when one already exists" {
  make_marker_fixture 1002 '{"x":1}'
  run --separate-stderr bash -c '
    echo "{\"x\":2}" | bash "$1" --repo o/r --pr 1 --mode write
  ' _ "$REPO_ROOT/scripts/update-metadata.sh"
  [ "$status" -eq 0 ]
  # Only PATCH should have been called, not POST.
  ! grep -- '-X POST' "$TEST_TMP/call_log"
  grep -- '-X PATCH' "$TEST_TMP/call_log"
}

# ---------------------------------------------------------------------------
# WRITE — input validation and error paths
# ---------------------------------------------------------------------------

@test "write exits 2 on empty stdin" {
  printf '[]' > "$TEST_TMP/list_response.json"
  run bash -c '
    printf "" | bash "$1" --repo o/r --pr 1 --mode write
  ' _ "$REPO_ROOT/scripts/update-metadata.sh"
  [ "$status" -eq 2 ]
}

@test "write exits 2 when stdin is not valid JSON" {
  printf '[]' > "$TEST_TMP/list_response.json"
  run bash -c '
    echo "not-json" | bash "$1" --repo o/r --pr 1 --mode write
  ' _ "$REPO_ROOT/scripts/update-metadata.sh"
  [ "$status" -eq 2 ]
}

@test "write exits 2 when POST fails" {
  printf '[]' > "$TEST_TMP/list_response.json"
  printf '1' > "$TEST_TMP/post_exit"
  printf 'gh: Forbidden (HTTP 403)\n' > "$TEST_TMP/post_stderr"
  run bash -c '
    echo "{\"x\":1}" | bash "$1" --repo o/r --pr 1 --mode write
  ' _ "$REPO_ROOT/scripts/update-metadata.sh"
  [ "$status" -eq 2 ]
}

@test "write exits 2 when PATCH fails" {
  make_marker_fixture 1002 '{"x":1}'
  printf '1' > "$TEST_TMP/patch_exit"
  printf 'gh: Forbidden (HTTP 403)\n' > "$TEST_TMP/patch_stderr"
  run bash -c '
    echo "{\"x\":2}" | bash "$1" --repo o/r --pr 1 --mode write
  ' _ "$REPO_ROOT/scripts/update-metadata.sh"
  [ "$status" -eq 2 ]
}

@test "write exits 2 when POST returns a malformed response" {
  printf '[]' > "$TEST_TMP/list_response.json"
  printf 'not json' > "$TEST_TMP/post_response.json"
  run bash -c '
    echo "{\"x\":1}" | bash "$1" --repo o/r --pr 1 --mode write
  ' _ "$REPO_ROOT/scripts/update-metadata.sh"
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# Argument validation
# ---------------------------------------------------------------------------

@test "missing --repo exits 2" {
  run bash "$REPO_ROOT/scripts/update-metadata.sh" --pr 1 --mode read
  [ "$status" -eq 2 ]
}

@test "missing --pr exits 2" {
  run bash "$REPO_ROOT/scripts/update-metadata.sh" --repo o/r --mode read
  [ "$status" -eq 2 ]
}

@test "missing --mode exits 2" {
  run bash "$REPO_ROOT/scripts/update-metadata.sh" --repo o/r --pr 1
  [ "$status" -eq 2 ]
}

@test "invalid --mode exits 2" {
  run bash "$REPO_ROOT/scripts/update-metadata.sh" --repo o/r --pr 1 --mode bogus
  [ "$status" -eq 2 ]
}

@test "invalid --repo format exits 2" {
  run bash "$REPO_ROOT/scripts/update-metadata.sh" --repo notarepo --pr 1 --mode read
  [ "$status" -eq 2 ]
}

@test "non-numeric --pr exits 2" {
  run bash "$REPO_ROOT/scripts/update-metadata.sh" --repo o/r --pr foo --mode read
  [ "$status" -eq 2 ]
}

@test "unknown argument exits 2" {
  run bash "$REPO_ROOT/scripts/update-metadata.sh" --repo o/r --pr 1 --mode read --extra foo
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# Logging hygiene
# ---------------------------------------------------------------------------

@test "stderr lines are valid JSON log objects (read)" {
  make_marker_fixture 1002 '{"x":1}'
  run --separate-stderr bash "$REPO_ROOT/scripts/update-metadata.sh" \
    --repo o/r --pr 1 --mode read
  [ "$status" -eq 0 ]
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    echo "$line" | jq -e '.level and .script and .event and .outcome' >/dev/null
  done <<< "$stderr"
}
