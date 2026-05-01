#!/usr/bin/env bats
#
# Unit tests for scripts/handlers/handle-re-review.sh.
#
# Many sub-scripts to stub. We copy scripts/ + skills/ into a tmpdir
# and overlay update-metadata.sh, fetch-pr-context.sh, post-holding-
# comment.sh, and post-review.sh. The claude CLI is stubbed via PATH.

bats_require_minimum_version 1.5.0

setup() {
  TEST_TMP="$(mktemp -d)"
  export TEST_TMP

  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export REPO_ROOT

  cp -r "$REPO_ROOT/scripts" "$TEST_TMP/scripts"
  cp -r "$REPO_ROOT/skills"  "$TEST_TMP/skills"

  # update-metadata stub.
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

  # fetch-pr-context stub.
  cat > "$TEST_TMP/scripts/fetch-pr-context.sh" <<'STUB'
#!/usr/bin/env bash
cat "$TEST_TMP/context.json"
STUB
  chmod +x "$TEST_TMP/scripts/fetch-pr-context.sh"

  # post-holding-comment stub.
  cat > "$TEST_TMP/scripts/post-holding-comment.sh" <<'STUB'
#!/usr/bin/env bash
echo '{"comment_id":7777,"html_url":"u","created":true}'
STUB
  chmod +x "$TEST_TMP/scripts/post-holding-comment.sh"

  # post-review stub.
  cat > "$TEST_TMP/scripts/post-review.sh" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
{
  "review_id": 9999,
  "review_url": "https://github.com/o/r/pull/42#review-9999",
  "inline_count": 2,
  "demoted_count": 1,
  "fallback": false,
  "finding_comment_ids": {"F2": 2002, "F4": 2003}
}
JSON
STUB
  chmod +x "$TEST_TMP/scripts/post-review.sh"

  : > "$TEST_TMP/call_log"

  # Default context: not truncated.
  echo '{"pr":{"head_sha":"def"},"diff":{"truncated":false,"char_count":1000,"max_chars":200000}}' \
    > "$TEST_TMP/context.json"

  # Default marker: F1 (originally unresolved), F2 (originally unresolved),
  # F3 dismissed. last_reviewed_sha differs from current head_sha so the
  # short-circuit does NOT fire by default.
  cat > "$TEST_TMP/marker.json" <<'JSON'
{
  "version": "1.1",
  "last_reviewed_sha": "abc",
  "last_reviewed_at": "2026-04-30T00:00:00Z",
  "skill_version": "0.1.0",
  "model": "claude-opus-4-7",
  "findings": [
    {"id":"F1","severity":"major","status":"unresolved","path":"src/x.go","line":10,"body":"B1","inline_comment_id":1001,"first_raised_sha":"abc"},
    {"id":"F2","severity":"minor","status":"unresolved","path":"src/y.go","line":5,"body":"B2","inline_comment_id":1002,"first_raised_sha":"abc"}
  ],
  "dismissed_findings": [
    {"id":"F3","by":"alice","reason":"x","at":"2026-04-30T00:00:00Z"}
  ]
}
JSON

  # Claude stub: emits a re-review where F1 is addressed, F2 still
  # unresolved, plus a new F3 (continuing the ID sequence past the
  # dismissed F3 — the prompt says continue from max(prior)+1).
  mkdir -p "$TEST_TMP/bin"
  cat > "$TEST_TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
[[ "$*" == *"--version"* ]] && { echo "claude 1.0.0"; exit 0; }
cat <<'OUT'
## Summary

Most prior findings are addressed. One new race condition.

## Prior findings

<finding id="F1" status="addressed">
Fixed in 89abcde.
</finding>

<finding id="F2" status="unresolved" severity="minor" path="src/y.go" line="5">
Still no test exercising the closed-channel case.
</finding>

## New findings

<finding id="F4" severity="major" path="src/htlc.go" line="55">
cancelPending reads h.state outside the mutex.
</finding>

## Verdict

REQUEST_CHANGES
OUT
STUB
  chmod +x "$TEST_TMP/bin/claude"

  # gh stub: handles pr fetch, label checks, label adds/removes, comment
  # edits, reactions.
  echo '{"state":"open","head":{"sha":"def"},"labels":[{"name":"rtl-active"}]}' > "$TEST_TMP/pr.json"
  echo '["rtl-active"]' > "$TEST_TMP/labels.json"

  cat > "$TEST_TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "GH: $*" >> "$TEST_TMP/call_log"
case "$*" in
  *"--jq [.labels[].name]"*)         cat "$TEST_TMP/labels.json" ;;
  *"api repos/"*"/pulls/"[0-9]*)     cat "$TEST_TMP/pr.json" ;;
  *"-X PATCH"*"/comments/"*)         exit 0 ;;
  *"-X POST"*"/comments"*)           echo '{"id":99}' ;;
  *"/reactions"*)                    echo '{"id":1}' ;;
  *)                                  echo '{}' ;;
esac
STUB
  chmod +x "$TEST_TMP/bin/gh"

  export ANTHROPIC_API_KEY="fake"
  export PATH="$TEST_TMP/bin:$PATH"
}

teardown() { rm -rf "$TEST_TMP"; }

run_handler() {
  bash "$TEST_TMP/scripts/handlers/handle-re-review.sh" "$@"
}

count() { grep -c -- "$1" "$TEST_TMP/call_log" || true; }

# ---------------------------------------------------------------------------

@test "happy path: posts review and merges marker correctly" {
  run --separate-stderr run_handler --repo o/r --pr 42 --actor alice --comment-id 555
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMP/marker_written.json" ]

  # F1 status flipped to addressed; severity/path/line/body preserved.
  jq -e '.findings[] | select(.id=="F1") | .status == "addressed"' "$TEST_TMP/marker_written.json" >/dev/null
  jq -e '.findings[] | select(.id=="F1") | .severity == "major"' "$TEST_TMP/marker_written.json" >/dev/null
  jq -e '.findings[] | select(.id=="F1") | .body == "B1"' "$TEST_TMP/marker_written.json" >/dev/null
  jq -e '.findings[] | select(.id=="F1") | .inline_comment_id == 1001' "$TEST_TMP/marker_written.json" >/dev/null

  # F2 stays unresolved; inline_comment_id refreshed to the new id from post-review.
  jq -e '.findings[] | select(.id=="F2") | .status == "unresolved"' "$TEST_TMP/marker_written.json" >/dev/null
  jq -e '.findings[] | select(.id=="F2") | .inline_comment_id == 2002' "$TEST_TMP/marker_written.json" >/dev/null

  # F4 added with status=unresolved, inline_comment_id from cids, first_raised_sha=current head.
  jq -e '.findings[] | select(.id=="F4") | .status == "unresolved"' "$TEST_TMP/marker_written.json" >/dev/null
  jq -e '.findings[] | select(.id=="F4") | .inline_comment_id == 2003' "$TEST_TMP/marker_written.json" >/dev/null
  jq -e '.findings[] | select(.id=="F4") | .first_raised_sha == "def"' "$TEST_TMP/marker_written.json" >/dev/null

  # dismissed_findings carry over.
  jq -e '.dismissed_findings | length == 1' "$TEST_TMP/marker_written.json" >/dev/null
  jq -e '.dismissed_findings[0].id == "F3"' "$TEST_TMP/marker_written.json" >/dev/null

  # last_reviewed_sha advanced to current head.
  jq -e '.last_reviewed_sha == "def"' "$TEST_TMP/marker_written.json" >/dev/null

  # Reaction on triggering comment.
  [ "$(count '/reactions')" = "1" ]
}

@test "HEAD-SHA short-circuit: same sha → no review, but reaction" {
  echo '{"state":"open","head":{"sha":"abc"},"labels":[{"name":"rtl-active"}]}' > "$TEST_TMP/pr.json"
  run --separate-stderr run_handler --repo o/r --pr 42 --actor alice --comment-id 555
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_TMP/marker_written.json" ]
  grep -F 'No new commits' "$TEST_TMP/call_log"
  [ "$(count '/reactions')" = "1" ]
}

@test "rejects when PR is not rtl-active" {
  echo '[]' > "$TEST_TMP/labels.json"
  run --separate-stderr run_handler --repo o/r --pr 42 --actor alice
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_TMP/marker_written.json" ]
  grep -F 'not active' "$TEST_TMP/call_log"
}

@test "rejects when PR is rtl-paused" {
  echo '["rtl-active","rtl-paused"]' > "$TEST_TMP/labels.json"
  run --separate-stderr run_handler --repo o/r --pr 42 --actor alice
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_TMP/marker_written.json" ]
  grep -F 'paused' "$TEST_TMP/call_log"
}

@test "rejects when PR is closed" {
  echo '{"state":"closed","head":{"sha":"def"},"labels":[{"name":"rtl-active"}]}' > "$TEST_TMP/pr.json"
  run --separate-stderr run_handler --repo o/r --pr 42 --actor alice
  [ "$status" -eq 0 ]
  grep -F 'not open' "$TEST_TMP/call_log"
}

@test "rejects when no marker exists" {
  echo 'null' > "$TEST_TMP/marker.json"
  run --separate-stderr run_handler --repo o/r --pr 42 --actor alice
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_TMP/marker_written.json" ]
  grep -F 'no prior review' "$TEST_TMP/call_log"
}

@test "diff-truncated → posts skip notice via holding edit, exits 0" {
  echo '{"pr":{"head_sha":"def"},"diff":{"truncated":true,"char_count":300000,"max_chars":200000}}' \
    > "$TEST_TMP/context.json"
  run --separate-stderr run_handler --repo o/r --pr 42 --actor alice
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_TMP/marker_written.json" ]
  # Holding comment should have been edited.
  [ "$(count 'PATCH.*/comments/7777')" -ge "1" ]
}

@test "missing --repo exits 2" {
  run run_handler --pr 42 --actor alice
  [ "$status" -eq 2 ]
}
