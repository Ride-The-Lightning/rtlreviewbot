#!/usr/bin/env bats
#
# Unit tests for scripts/post-review.sh.
#
# Strategy: stub `gh` via PATH injection. The stub captures each invocation's
# argv (and the `-F body=@file` body file) so tests can inspect what would
# have been sent to GitHub. Per-test exit code lets us simulate API
# failures and exercise the body-only fallback path.

bats_require_minimum_version 1.5.0

setup() {
  TEST_TMP="$(mktemp -d)"
  export TEST_TMP

  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export REPO_ROOT

  mkdir -p "$TEST_TMP/bin"
  : > "$TEST_TMP/call_log"
  : > "$TEST_TMP/gh_count"

  # Default response: success, returns review id 456.
  printf '%s' '{"id":456,"html_url":"https://github.com/o/r/pull/42#pullrequestreview-456"}' \
    > "$TEST_TMP/gh_response.json"
  printf '0' > "$TEST_TMP/gh_exit"
  : > "$TEST_TMP/gh_stderr"
  printf '0' > "$TEST_TMP/gh_fail_first"

  # Default context: two files, one of which is "removed".
  cat > "$TEST_TMP/ctx.json" <<'JSON'
{
  "pr": {"number": 42, "head_sha": "deadbeef"},
  "files": [
    {"path": "src/htlc.go", "status": "modified"},
    {"path": "src/old.go",  "status": "removed"}
  ]
}
JSON

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
n=0; [[ -f "$TEST_TMP/gh_count" ]] && n=$(cat "$TEST_TMP/gh_count")
n=$((n+1)); printf '%d' "$n" > "$TEST_TMP/gh_count"

# Capture the full argv for this invocation.
{ printf 'INVOCATION %d\n' "$n"; printf '%s\n' "$@"; printf 'END\n'; } >> "$TEST_TMP/call_log"

# If --input <file> is present, copy the body file for inspection.
prev=""
for a in "$@"; do
  [[ "$prev" == "--input" ]] && cp "$a" "$TEST_TMP/payload_${n}.json"
  prev="$a"
done

# Two-shot mode: fail the first call, succeed the second.
fail_first="$(cat "$TEST_TMP/gh_fail_first" 2>/dev/null || echo 0)"
if (( fail_first == 1 )) && (( n == 1 )); then
  cat "$TEST_TMP/gh_stderr" >&2
  exit 1
fi

[[ -s "$TEST_TMP/gh_stderr" ]] && cat "$TEST_TMP/gh_stderr" >&2
cat "$TEST_TMP/gh_response.json"
exit "$(cat "$TEST_TMP/gh_exit")"
STUB
  chmod +x "$TEST_TMP/bin/gh"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Tests pipe a small review JSON literal through to post-review.sh.
post() {
  local review_json="$1"
  shift
  bash -c '
    printf "%s" "$1" | bash "$2" "${@:3}"
  ' _ "$review_json" "$REPO_ROOT/scripts/post-review.sh" \
    --repo o/r --pr 42 --context-file "$TEST_TMP/ctx.json" "$@"
}

# Dump the first payload's comments array for assertions.
payload_comments() {
  jq -c '.comments' "$TEST_TMP/payload_1.json"
}

# ---------------------------------------------------------------------------
# Happy path — initial review
# ---------------------------------------------------------------------------

@test "all findings anchor inline when paths are in the diff" {
  run --separate-stderr post '{
    "summary":"OK",
    "findings":[
      {"id":"F1","severity":"major","path":"src/htlc.go","line":18,"body":"a"},
      {"id":"F2","severity":"minor","path":"src/htlc.go","line":42,"body":"b"}
    ],
    "prior_findings":[], "new_findings":[],
    "verdict":"COMMENT"
  }'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.review_id == 456' >/dev/null
  echo "$output" | jq -e '.inline_count == 2' >/dev/null
  echo "$output" | jq -e '.demoted_count == 0' >/dev/null
  echo "$output" | jq -e '.fallback == false' >/dev/null
  payload_comments | jq -e 'length == 2' >/dev/null
}

@test "verdict REQUEST_CHANGES maps to event REQUEST_CHANGES" {
  run --separate-stderr post '{
    "summary":"x",
    "findings":[{"id":"F1","severity":"blocker","path":"src/htlc.go","line":1,"body":"a"}],
    "prior_findings":[], "new_findings":[],
    "verdict":"REQUEST_CHANGES"
  }'
  [ "$status" -eq 0 ]
  jq -e '.event == "REQUEST_CHANGES"' "$TEST_TMP/payload_1.json" >/dev/null
}

@test "verdict COMMENT maps to event COMMENT" {
  run --separate-stderr post '{
    "summary":"x","findings":[],"prior_findings":[],"new_findings":[],"verdict":"COMMENT"
  }'
  [ "$status" -eq 0 ]
  jq -e '.event == "COMMENT"' "$TEST_TMP/payload_1.json" >/dev/null
}

# ---------------------------------------------------------------------------
# Anchor validation / demotion
# ---------------------------------------------------------------------------

@test "finding whose path is not in the diff is demoted to body" {
  run --separate-stderr post '{
    "summary":"x",
    "findings":[
      {"id":"F1","severity":"major","path":"src/htlc.go","line":1,"body":"in diff"},
      {"id":"F9","severity":"minor","path":"src/missing.go","line":1,"body":"not in diff"}
    ],
    "prior_findings":[], "new_findings":[],
    "verdict":"COMMENT"
  }'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.inline_count == 1 and .demoted_count == 1' >/dev/null
  jq -r '.body' "$TEST_TMP/payload_1.json" | grep -F 'F9'
  jq -r '.body' "$TEST_TMP/payload_1.json" | grep -F 'src/missing.go'
}

@test "finding on a removed file is demoted to body" {
  run --separate-stderr post '{
    "summary":"x",
    "findings":[
      {"id":"F1","severity":"major","path":"src/old.go","line":5,"body":"file gone"}
    ],
    "prior_findings":[], "new_findings":[],
    "verdict":"COMMENT"
  }'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.inline_count == 0 and .demoted_count == 1' >/dev/null
  jq -r '.body' "$TEST_TMP/payload_1.json" | grep -F 'src/old.go'
}

@test "finding without path/line is demoted (cannot anchor)" {
  run --separate-stderr post '{
    "summary":"x",
    "findings":[{"id":"F1","severity":"minor","body":"floating"}],
    "prior_findings":[], "new_findings":[],
    "verdict":"COMMENT"
  }'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.demoted_count == 1' >/dev/null
}

# ---------------------------------------------------------------------------
# Re-review handling
# ---------------------------------------------------------------------------

@test "re-review: addressed/withdrawn priors go to body, unresolved/new go inline" {
  run --separate-stderr post '{
    "summary":"x",
    "findings":[],
    "prior_findings":[
      {"id":"F1","status":"addressed","body":"fixed"},
      {"id":"F2","status":"unresolved","severity":"minor","path":"src/htlc.go","line":42,"body":"still bad"},
      {"id":"F3","status":"withdrawn","body":"was wrong"}
    ],
    "new_findings":[
      {"id":"F4","severity":"major","path":"src/htlc.go","line":55,"body":"new race"}
    ],
    "verdict":"REQUEST_CHANGES"
  }'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.inline_count == 2' >/dev/null
  body="$(jq -r '.body' "$TEST_TMP/payload_1.json")"
  echo "$body" | grep -F 'Status of prior findings'
  echo "$body" | grep -F 'F1'
  echo "$body" | grep -F 'F3'
  # F2 and F4 are inline, not in body's prior-status section.
  payload_comments | jq -e 'map(.body) | (any(test("F2"))) and (any(test("F4")))' >/dev/null
}

# ---------------------------------------------------------------------------
# Inline comment shape
# ---------------------------------------------------------------------------

@test "inline comment uses side: RIGHT and integer line" {
  run --separate-stderr post '{
    "summary":"x",
    "findings":[{"id":"F1","severity":"major","path":"src/htlc.go","line":18,"body":"a"}],
    "prior_findings":[], "new_findings":[],
    "verdict":"COMMENT"
  }'
  [ "$status" -eq 0 ]
  payload_comments | jq -e '.[0].side == "RIGHT"' >/dev/null
  payload_comments | jq -e '.[0].line == 18 and (.[0].line | type == "number")' >/dev/null
  payload_comments | jq -e '.[0].body | startswith("🟠 **F1 (major):**")' >/dev/null
}

@test "commit_id defaults to context.pr.head_sha" {
  run --separate-stderr post '{
    "summary":"x","findings":[],"prior_findings":[],"new_findings":[],"verdict":"COMMENT"
  }'
  [ "$status" -eq 0 ]
  jq -e '.commit_id == "deadbeef"' "$TEST_TMP/payload_1.json" >/dev/null
}

@test "--commit-sha overrides context.pr.head_sha" {
  run --separate-stderr post '{
    "summary":"x","findings":[],"prior_findings":[],"new_findings":[],"verdict":"COMMENT"
  }' --commit-sha cafebabe
  [ "$status" -eq 0 ]
  jq -e '.commit_id == "cafebabe"' "$TEST_TMP/payload_1.json" >/dev/null
}

# ---------------------------------------------------------------------------
# Fallback path
# ---------------------------------------------------------------------------

@test "first POST 422 → second POST with everything in body succeeds" {
  printf '1' > "$TEST_TMP/gh_fail_first"
  printf 'gh: Validation Failed (HTTP 422)\n' > "$TEST_TMP/gh_stderr"
  run --separate-stderr post '{
    "summary":"x",
    "findings":[{"id":"F1","severity":"major","path":"src/htlc.go","line":18,"body":"a"}],
    "prior_findings":[], "new_findings":[],
    "verdict":"COMMENT"
  }'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.fallback == true' >/dev/null
  echo "$output" | jq -e '.inline_count == 0' >/dev/null

  # First payload had inline comment; second had none.
  jq -e '.comments | length == 1' "$TEST_TMP/payload_1.json" >/dev/null
  jq -e '.comments | length == 0' "$TEST_TMP/payload_2.json" >/dev/null
  # Second body contains the demoted finding.
  jq -r '.body' "$TEST_TMP/payload_2.json" | grep -F 'F1'
}

@test "both POSTs fail → exit 2" {
  printf '1' > "$TEST_TMP/gh_exit"
  printf 'gh: Validation Failed\n' > "$TEST_TMP/gh_stderr"
  run post '{"summary":"x","findings":[],"prior_findings":[],"new_findings":[],"verdict":"COMMENT"}'
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# Argument and input validation
# ---------------------------------------------------------------------------

@test "missing --repo exits 2" {
  run bash -c '
    echo "{}" | bash "$1" --pr 1 --context-file "$2"
  ' _ "$REPO_ROOT/scripts/post-review.sh" "$TEST_TMP/ctx.json"
  [ "$status" -eq 2 ]
}

@test "missing --pr exits 2" {
  run bash -c '
    echo "{}" | bash "$1" --repo o/r --context-file "$2"
  ' _ "$REPO_ROOT/scripts/post-review.sh" "$TEST_TMP/ctx.json"
  [ "$status" -eq 2 ]
}

@test "missing --context-file exits 2" {
  run bash -c '
    echo "{}" | bash "$1" --repo o/r --pr 1
  ' _ "$REPO_ROOT/scripts/post-review.sh"
  [ "$status" -eq 2 ]
}

@test "--context-file pointing to missing file exits 2" {
  run bash -c '
    echo "{}" | bash "$1" --repo o/r --pr 1 --context-file /nope
  ' _ "$REPO_ROOT/scripts/post-review.sh"
  [ "$status" -eq 2 ]
}

@test "invalid JSON on stdin exits 2" {
  run bash -c '
    echo "not json" | bash "$1" --repo o/r --pr 1 --context-file "$2"
  ' _ "$REPO_ROOT/scripts/post-review.sh" "$TEST_TMP/ctx.json"
  [ "$status" -eq 2 ]
}

@test "invalid verdict exits 2" {
  run post '{"summary":"x","findings":[],"prior_findings":[],"new_findings":[],"verdict":"APPROVE"}'
  [ "$status" -eq 2 ]
}

@test "missing head_sha and no --commit-sha exits 2" {
  echo '{"pr":{},"files":[]}' > "$TEST_TMP/ctx.json"
  run post '{"summary":"x","findings":[],"prior_findings":[],"new_findings":[],"verdict":"COMMENT"}'
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# Logging hygiene
# ---------------------------------------------------------------------------

@test "stderr lines are valid JSON log objects" {
  run --separate-stderr post '{
    "summary":"x","findings":[],"prior_findings":[],"new_findings":[],"verdict":"COMMENT"
  }'
  [ "$status" -eq 0 ]
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    echo "$line" | jq -e '.level and .script and .event and .outcome' >/dev/null
  done <<< "$stderr"
}
