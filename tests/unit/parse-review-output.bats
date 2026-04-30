#!/usr/bin/env bats
#
# Unit tests for scripts/parse-review-output.sh.
#
# The parser has no I/O dependencies — feed markdown in, assert JSON shape on
# stdout. Per-test fixtures live in tests/fixtures/claude-output-*.md.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export REPO_ROOT
}

# ---------------------------------------------------------------------------
# Initial-review happy paths
# ---------------------------------------------------------------------------

@test "initial-review: summary, two findings, REQUEST_CHANGES" {
  run --separate-stderr bash "$REPO_ROOT/scripts/parse-review-output.sh" \
    < "$REPO_ROOT/tests/fixtures/claude-output-initial.md"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.verdict == "REQUEST_CHANGES"' >/dev/null
  echo "$output" | jq -e '.findings | length == 2' >/dev/null
  echo "$output" | jq -e '.findings[0].id == "F1"' >/dev/null
  echo "$output" | jq -e '.findings[0].severity == "major"' >/dev/null
  echo "$output" | jq -e '.findings[0].path == "src/htlc.go"' >/dev/null
  echo "$output" | jq -e '.findings[0].line == 18' >/dev/null
  echo "$output" | jq -e '.findings[0].line | type == "number"' >/dev/null
  echo "$output" | jq -e '.findings[1].id == "F2" and .findings[1].severity == "minor"' >/dev/null
  echo "$output" | jq -e '.summary | contains("nil HTLCs")' >/dev/null
}

@test "initial-review: zero findings → empty array, COMMENT verdict" {
  run --separate-stderr bash "$REPO_ROOT/scripts/parse-review-output.sh" \
    < "$REPO_ROOT/tests/fixtures/claude-output-clean.md"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.verdict == "COMMENT"' >/dev/null
  echo "$output" | jq -e '.findings == []' >/dev/null
  echo "$output" | jq -e '.summary | length > 0' >/dev/null
}

# ---------------------------------------------------------------------------
# Re-review format
# ---------------------------------------------------------------------------

@test "re-review: prior + new findings split into the right buckets" {
  run --separate-stderr bash "$REPO_ROOT/scripts/parse-review-output.sh" \
    < "$REPO_ROOT/tests/fixtures/claude-output-rereview.md"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.verdict == "REQUEST_CHANGES"' >/dev/null
  echo "$output" | jq -e '.findings == []' >/dev/null
  echo "$output" | jq -e '.prior_findings | length == 3' >/dev/null
  echo "$output" | jq -e '.new_findings   | length == 1' >/dev/null

  # Status fields propagate.
  echo "$output" | jq -e '.prior_findings[0].id == "F1" and .prior_findings[0].status == "addressed"' >/dev/null
  echo "$output" | jq -e '.prior_findings[1].id == "F2" and .prior_findings[1].status == "unresolved"' >/dev/null
  echo "$output" | jq -e '.prior_findings[1].severity == "minor"' >/dev/null
  echo "$output" | jq -e '.prior_findings[2].id == "F3" and .prior_findings[2].status == "withdrawn"' >/dev/null

  # New findings continue the ID sequence.
  echo "$output" | jq -e '.new_findings[0].id == "F4" and .new_findings[0].severity == "major"' >/dev/null
}

# ---------------------------------------------------------------------------
# Verdict validation
# ---------------------------------------------------------------------------

@test "missing ## Verdict section exits 2" {
  run bash "$REPO_ROOT/scripts/parse-review-output.sh" \
    < "$REPO_ROOT/tests/fixtures/claude-output-no-verdict.md"
  [ "$status" -eq 2 ]
}

@test "invalid verdict (e.g. APPROVE) exits 2" {
  run bash -c '
    printf "## Summary\nx\n\n## Verdict\nAPPROVE\n" \
      | bash "$1"
  ' _ "$REPO_ROOT/scripts/parse-review-output.sh"
  [ "$status" -eq 2 ]
}

@test "empty input exits 2" {
  run bash -c 'printf "" | bash "$1"' _ "$REPO_ROOT/scripts/parse-review-output.sh"
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# Lenient parsing (warnings, not failures)
# ---------------------------------------------------------------------------

@test "finding without an id is skipped (other findings still parse)" {
  run --separate-stderr bash -c '
    cat <<EOF | bash "$1"
## Summary
x
## Findings
<finding severity="minor" path="x" line="1">
no id
</finding>
<finding id="F1" severity="major" path="y" line="2">
has id
</finding>
## Verdict
COMMENT
EOF
  ' _ "$REPO_ROOT/scripts/parse-review-output.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.findings | length == 1' >/dev/null
  echo "$output" | jq -e '.findings[0].id == "F1"' >/dev/null
}

@test "finding with non-numeric line falls back to null" {
  run --separate-stderr bash -c '
    cat <<EOF | bash "$1"
## Summary
x
## Findings
<finding id="F1" severity="minor" path="x" line="abc">
non-numeric line
</finding>
## Verdict
COMMENT
EOF
  ' _ "$REPO_ROOT/scripts/parse-review-output.sh"
  [ "$status" -eq 0 ]
  # line key is dropped (with_entries strips nulls).
  echo "$output" | jq -e '.findings[0] | has("line") | not' >/dev/null
}

@test "finding tag attribute order does not matter" {
  run --separate-stderr bash -c '
    cat <<EOF | bash "$1"
## Summary
x
## Findings
<finding severity="major" line="42" id="F1" path="src/x.go">
shuffled attrs
</finding>
## Verdict
REQUEST_CHANGES
EOF
  ' _ "$REPO_ROOT/scripts/parse-review-output.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.findings[0].id == "F1" and .findings[0].path == "src/x.go" and .findings[0].line == 42' >/dev/null
}

@test "multi-line finding body is preserved (newlines in JSON string)" {
  run --separate-stderr bash -c '
    cat <<EOF | bash "$1"
## Summary
x
## Findings
<finding id="F1" severity="major" path="x" line="1">
first line
second line
third line
</finding>
## Verdict
COMMENT
EOF
  ' _ "$REPO_ROOT/scripts/parse-review-output.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.findings[0].body | contains("first line") and contains("second line") and contains("third line")' >/dev/null
}

# ---------------------------------------------------------------------------
# Output shape
# ---------------------------------------------------------------------------

@test "output is single-line valid JSON with all five top-level keys" {
  run --separate-stderr bash "$REPO_ROOT/scripts/parse-review-output.sh" \
    < "$REPO_ROOT/tests/fixtures/claude-output-initial.md"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | wc -l | tr -d ' ')" = "0" ]
  echo "$output" | jq -e '.summary and (.findings | type == "array") and (.prior_findings | type == "array") and (.new_findings | type == "array") and .verdict' >/dev/null
}

# ---------------------------------------------------------------------------
# Logging hygiene
# ---------------------------------------------------------------------------

@test "stderr lines are valid JSON log objects" {
  run --separate-stderr bash "$REPO_ROOT/scripts/parse-review-output.sh" \
    < "$REPO_ROOT/tests/fixtures/claude-output-initial.md"
  [ "$status" -eq 0 ]
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    echo "$line" | jq -e '.level and .script and .event and .outcome' >/dev/null
  done <<< "$stderr"
}
