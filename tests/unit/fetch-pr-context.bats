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

  mkdir -p "$TEST_TMP/fx" "$TEST_TMP/fx/contents" "$TEST_TMP/bin"

  # Seed default fixtures.
  cp "$REPO_ROOT/tests/fixtures/pr.json"              "$TEST_TMP/fx/pr.json"
  cp "$REPO_ROOT/tests/fixtures/diff.txt"             "$TEST_TMP/fx/diff.txt"
  cp "$REPO_ROOT/tests/fixtures/files.json"           "$TEST_TMP/fx/files.json"
  cp "$REPO_ROOT/tests/fixtures/comments.json"        "$TEST_TMP/fx/comments.json"
  cp "$REPO_ROOT/tests/fixtures/review_comments.json" "$TEST_TMP/fx/review_comments.json"
  cp "$REPO_ROOT/tests/fixtures/reviews.json"         "$TEST_TMP/fx/reviews.json"

  # Seed content envelopes for the two default-fixture files. Each
  # envelope is the contents-API shape: {content: <base64>, encoding: "base64"}.
  # The stub serves these for repos/.../contents/<path>?ref=... requests.
  seed_contents_envelope "src/htlc.go"      'package htlc

func Settle(h *HTLC) error {
  if h == nil {
    return ErrNil
  }
  return commit(h)
}

func commit(h *HTLC) error {
  return h.state.persist()
}
'
  seed_contents_envelope "src/htlc_test.go" 'package htlc

import "testing"

func TestSettleNil(t *testing.T) {
  if err := Settle(nil); err != ErrNil {
    t.Fatal("expected ErrNil")
  }
}
'

  # README, CLAUDE.md, CONTRIBUTING.md default to absent. Individual
  # tests opt-in by calling seed_doc_envelope / seed_readme_envelope.

  : > "$TEST_TMP/call_log"
  printf '0' > "$TEST_TMP/gh_exit"
  : > "$TEST_TMP/gh_stderr"

  install_gh_stub
  export PATH="$TEST_TMP/bin:$PATH"
}

# seed_contents_envelope <repo-path> <plaintext>
#   Writes a base64-encoded contents-API envelope under fx/contents/
#   keyed by the repo path. The stub looks here for any
#   repos/.../contents/<path>?ref=... request.
seed_contents_envelope() {
  local rpath="$1" text="$2"
  local b64
  b64="$(printf '%s' "$text" | base64 | tr -d '\n')"
  local fxpath="$TEST_TMP/fx/contents/$rpath"
  mkdir -p "$(dirname "$fxpath")"
  jq -n --arg c "$b64" --arg p "$rpath" --argjson s "${#text}" \
    '{name: ($p | split("/") | last), path: $p, size: $s,
      type: "file", encoding: "base64", content: $c}' > "$fxpath.json"
}

# seed_binary_envelope <repo-path>
#   Writes a contents envelope whose decoded body contains NUL bytes
#   (simulating a binary file).
seed_binary_envelope() {
  local rpath="$1"
  local b64
  # 16 bytes: ELF magic + nulls + some garbage.
  b64="$(printf '\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00' \
         | base64 | tr -d '\n')"
  local fxpath="$TEST_TMP/fx/contents/$rpath"
  mkdir -p "$(dirname "$fxpath")"
  jq -n --arg c "$b64" --arg p "$rpath" \
    '{name: ($p | split("/") | last), path: $p, size: 16,
      type: "file", encoding: "base64", content: $c}' > "$fxpath.json"
}

# seed_readme_envelope <plaintext>
seed_readme_envelope() {
  local text="$1"
  local b64
  b64="$(printf '%s' "$text" | base64 | tr -d '\n')"
  jq -n --arg c "$b64" --argjson s "${#text}" \
    '{name: "README.md", path: "README.md", size: $s,
      type: "file", encoding: "base64", content: $c}' > "$TEST_TMP/fx/readme.json"
}

# seed_doc_envelope <repo-path> <plaintext>
#   For top-level docs like CLAUDE.md, CONTRIBUTING.md.
seed_doc_envelope() {
  local rpath="$1" text="$2"
  local b64
  b64="$(printf '%s' "$text" | base64 | tr -d '\n')"
  local fxpath="$TEST_TMP/fx/contents/$rpath"
  mkdir -p "$(dirname "$fxpath")"
  jq -n --arg c "$b64" --arg p "$rpath" --argjson s "${#text}" \
    '{name: $p, path: $p, size: $s,
      type: "file", encoding: "base64", content: $c}' > "$fxpath.json"
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

# Strip any ?ref=... query string for fixture lookup.
url_path="${url%%\?*}"

# repos/<owner>/<repo>/contents/<path...>
# repos/<owner>/<repo>/readme
case "$url_path" in
  repos/*/pulls/[0-9]*/files)     cat "$TEST_TMP/fx/files.json" ;;
  repos/*/issues/[0-9]*/comments) cat "$TEST_TMP/fx/comments.json" ;;
  repos/*/pulls/[0-9]*/comments)  cat "$TEST_TMP/fx/review_comments.json" ;;
  repos/*/pulls/[0-9]*/reviews)   cat "$TEST_TMP/fx/reviews.json" ;;
  repos/*/pulls/[0-9]*)
    if (( is_diff )); then cat "$TEST_TMP/fx/diff.txt"
    else                    cat "$TEST_TMP/fx/pr.json"
    fi
    ;;
  repos/*/readme)
    if [[ -s "$TEST_TMP/fx/readme.json" ]]; then
      cat "$TEST_TMP/fx/readme.json"
    else
      printf '{"message":"Not Found"}\n' >&2
      exit 1
    fi
    ;;
  repos/*/contents/*)
    # Extract everything after "repos/<owner>/<repo>/contents/" — this
    # is the repo-relative path, possibly url-encoded.
    rel="${url_path#repos/*/contents/}"
    # Minimal decode: %2F → /, %20 → space. Sufficient for tests; we
    # don't claim to be a full URI decoder.
    rel="${rel//%2F/\/}"
    rel="${rel//%20/ }"
    fx_path="$TEST_TMP/fx/contents/${rel}.json"
    if [[ -s "$fx_path" ]]; then
      cat "$fx_path"
    else
      printf '{"message":"Not Found"}\n' >&2
      exit 1
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
  echo "$output" | jq -e '.file_contents == []' >/dev/null
}

# ---------------------------------------------------------------------------
# File contents
# ---------------------------------------------------------------------------

@test "file_contents includes post-change text for each changed file" {
  run --separate-stderr bash "$REPO_ROOT/scripts/fetch-pr-context.sh" \
    --repo o/r --pr 42
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.file_contents | length == 2' >/dev/null
  echo "$output" | jq -e '.file_contents[0].path == "src/htlc.go"' >/dev/null
  echo "$output" | jq -e '.file_contents[0].text | contains("func Settle")' >/dev/null
  echo "$output" | jq -e '.file_contents[0].truncated == false' >/dev/null
  echo "$output" | jq -e '.file_contents[0].binary == false' >/dev/null
  echo "$output" | jq -e '.file_contents[0].skipped == null' >/dev/null
  echo "$output" | jq -e '.file_contents[1].path == "src/htlc_test.go"' >/dev/null
}

@test "content fetch carries the HEAD SHA in the ref query" {
  run --separate-stderr bash "$REPO_ROOT/scripts/fetch-pr-context.sh" \
    --repo o/r --pr 42
  [ "$status" -eq 0 ]
  head_sha="$(jq -r '.head.sha' "$TEST_TMP/fx/pr.json")"
  grep -F "contents/src/htlc.go?ref=${head_sha}" "$TEST_TMP/call_log"
}

@test "removed files are omitted from file_contents" {
  cat > "$TEST_TMP/fx/files.json" <<'EOF'
[
  {"filename": "src/htlc.go",      "additions": 0, "deletions": 5, "status": "removed"},
  {"filename": "src/htlc_test.go", "additions": 1, "deletions": 0, "status": "modified"}
]
EOF
  run --separate-stderr bash "$REPO_ROOT/scripts/fetch-pr-context.sh" \
    --repo o/r --pr 42
  [ "$status" -eq 0 ]
  # files list keeps the removed entry...
  echo "$output" | jq -e '.files | length == 2' >/dev/null
  # ...but file_contents has only the modified one.
  echo "$output" | jq -e '.file_contents | length == 1' >/dev/null
  echo "$output" | jq -e '.file_contents[0].path == "src/htlc_test.go"' >/dev/null
}

@test "renamed file is fetched at the new path" {
  cat > "$TEST_TMP/fx/files.json" <<'EOF'
[
  {"filename": "src/htlc_v2.go", "additions": 2, "deletions": 2,
   "status": "renamed", "previous_filename": "src/htlc.go"}
]
EOF
  seed_contents_envelope "src/htlc_v2.go" "package htlc

// renamed
"
  run --separate-stderr bash "$REPO_ROOT/scripts/fetch-pr-context.sh" \
    --repo o/r --pr 42
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.file_contents | length == 1' >/dev/null
  echo "$output" | jq -e '.file_contents[0].path == "src/htlc_v2.go"' >/dev/null
  echo "$output" | jq -e '.file_contents[0].text | contains("renamed")' >/dev/null
  # Did we hit the new path, not the old one?
  head_sha="$(jq -r '.head.sha' "$TEST_TMP/fx/pr.json")"
  grep -F "contents/src/htlc_v2.go?ref=${head_sha}" "$TEST_TMP/call_log"
  ! grep -F 'contents/src/htlc.go?ref=' "$TEST_TMP/call_log"
}

@test "binary file produces a marker entry with text:null and binary:true" {
  cat > "$TEST_TMP/fx/files.json" <<'EOF'
[
  {"filename": "img/logo.png", "additions": 0, "deletions": 0, "status": "added"}
]
EOF
  seed_binary_envelope "img/logo.png"
  run --separate-stderr bash "$REPO_ROOT/scripts/fetch-pr-context.sh" \
    --repo o/r --pr 42
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.file_contents | length == 1' >/dev/null
  echo "$output" | jq -e '.file_contents[0].path == "img/logo.png"' >/dev/null
  echo "$output" | jq -e '.file_contents[0].binary == true' >/dev/null
  echo "$output" | jq -e '.file_contents[0].text == null' >/dev/null
  echo "$output" | jq -e '.file_contents[0].skipped == null' >/dev/null
}

@test "per-file cap truncates a single file and marks truncated:true" {
  run --separate-stderr bash "$REPO_ROOT/scripts/fetch-pr-context.sh" \
    --repo o/r --pr 42 --max-file-chars 20
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.file_contents[0].truncated == true' >/dev/null
  echo "$output" | jq -e '.file_contents[0].text | length <= 20' >/dev/null
  # char_count still reports the full pre-truncation size.
  echo "$output" | jq -e '.file_contents[0].char_count > 20' >/dev/null
}

@test "total cap skips remaining files with budget_exhausted marker" {
  # Cap small enough that the first file fits but the second cannot.
  # First fixture content is "package htlc\n\nfunc Settle..." (>50 bytes).
  run --separate-stderr bash "$REPO_ROOT/scripts/fetch-pr-context.sh" \
    --repo o/r --pr 42 --max-file-contents-chars 50 --max-file-chars 50
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.file_contents | length == 2' >/dev/null
  # First entry got partial inclusion (truncated to 50 bytes total).
  echo "$output" | jq -e '.file_contents[0].text != null' >/dev/null
  # Second got the budget_exhausted marker.
  echo "$output" | jq -e '.file_contents[1].text == null' >/dev/null
  echo "$output" | jq -e '.file_contents[1].skipped == "budget_exhausted"' >/dev/null
}

@test "missing content fixture yields fetch_failed (simulates >1MB / API error)" {
  cat > "$TEST_TMP/fx/files.json" <<'EOF'
[
  {"filename": "src/huge.go", "additions": 1, "deletions": 0, "status": "modified"}
]
EOF
  # Deliberately no fixture for src/huge.go → stub returns 404.
  run --separate-stderr bash "$REPO_ROOT/scripts/fetch-pr-context.sh" \
    --repo o/r --pr 42
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.file_contents | length == 1' >/dev/null
  echo "$output" | jq -e '.file_contents[0].path == "src/huge.go"' >/dev/null
  echo "$output" | jq -e '.file_contents[0].text == null' >/dev/null
  echo "$output" | jq -e '.file_contents[0].skipped == "fetch_failed"' >/dev/null
}

# ---------------------------------------------------------------------------
# Project docs (README / CLAUDE.md / CONTRIBUTING.md)
# ---------------------------------------------------------------------------

@test "absent README, CLAUDE.md, CONTRIBUTING.md all serialize as null" {
  # Default setup seeds none of the three.
  run --separate-stderr bash "$REPO_ROOT/scripts/fetch-pr-context.sh" \
    --repo o/r --pr 42
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.readme == null' >/dev/null
  echo "$output" | jq -e '.claude_md == null' >/dev/null
  echo "$output" | jq -e '.contributing_md == null' >/dev/null
}

@test "present README is decoded and included" {
  seed_readme_envelope "# rtlreviewbot-test

This is the consumer repo readme.
"
  run --separate-stderr bash "$REPO_ROOT/scripts/fetch-pr-context.sh" \
    --repo o/r --pr 42
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.readme.text | contains("consumer repo readme")' >/dev/null
  echo "$output" | jq -e '.readme.truncated == false' >/dev/null
  echo "$output" | jq -e '.readme.char_count > 0' >/dev/null
}

@test "present CLAUDE.md and CONTRIBUTING.md are decoded and included" {
  seed_doc_envelope "CLAUDE.md"       "# Project conventions

Use t.Context() in tests.
"
  seed_doc_envelope "CONTRIBUTING.md" "# Contributing

Open an issue first.
"
  run --separate-stderr bash "$REPO_ROOT/scripts/fetch-pr-context.sh" \
    --repo o/r --pr 42
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.claude_md.text | contains("t.Context()")' >/dev/null
  echo "$output" | jq -e '.contributing_md.text | contains("Open an issue")' >/dev/null
}

@test "per-doc cap truncates README and marks truncated:true" {
  seed_readme_envelope "$(printf 'x%.0s' {1..5000})"
  run --separate-stderr bash "$REPO_ROOT/scripts/fetch-pr-context.sh" \
    --repo o/r --pr 42 --max-readme-chars 100
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.readme.truncated == true' >/dev/null
  echo "$output" | jq -e '.readme.text | length <= 100' >/dev/null
  echo "$output" | jq -e '.readme.char_count == 5000' >/dev/null
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

@test "non-numeric --max-file-chars exits 2" {
  run bash "$REPO_ROOT/scripts/fetch-pr-context.sh" \
    --repo o/r --pr 1 --max-file-chars not-a-number
  [ "$status" -eq 2 ]
}

@test "non-numeric --max-readme-chars exits 2" {
  run bash "$REPO_ROOT/scripts/fetch-pr-context.sh" \
    --repo o/r --pr 1 --max-readme-chars 1.5
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
