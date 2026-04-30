#!/usr/bin/env bash
#
# handle-review.sh — orchestrate the FR-1 initial-review flow.
#
# Invoked by run-review.sh once the command has been parsed and the
# commenter's permission verified. Assumes:
#   - $GH_TOKEN is set to a valid App installation token (caller authenticated)
#   - $ANTHROPIC_API_KEY is exported (consumed by `claude` CLI)
#   - The Claude Code CLI (`claude`) is on PATH
#
# Usage:
#   handle-review.sh --repo <owner/repo> --pr <n> --actor <login>
#                    [--bot-login <login>]
#                    [--skill-dir <path>]
#                    [--model <claude-model-id>]
#                    [--skill-version <semver>]
#
# Behavior (FR-1):
#   1. Verify PR is open and not already rtl-active (precondition checks).
#   2. Post the holding comment.
#   3. Fetch PR context (fetch-pr-context.sh).
#   4. If diff was truncated, post a polite skip-comment and stop.
#   5. Compose the prompt (SKILL.md + initial-review.md + context JSON)
#      and invoke the Claude Code skill, with one retry on failure.
#   6. Parse Claude's output into structured JSON.
#   7. Post the formal review (post-review.sh).
#   8. Apply the rtl-active label.
#   9. Best-effort: add the bot as a requested reviewer (enables the
#      Re-request review button → FR-2 trigger).
#   10. Write the metadata marker (update-metadata.sh).
#   11. Edit the holding comment to "✅ Review posted: <url>".
#
# Exit codes:
#   0  review posted, or precondition prevented it (already-active, draft,
#      not-open, truncated-diff) — these are user-visible no-ops.
#   2  system failure at any step (the holding comment is updated to a
#      visible failure message before exit so the maintainer sees it).

set -euo pipefail

readonly SCRIPT_NAME="${BASH_SOURCE[0]##*/}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; readonly SCRIPT_DIR
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)";              readonly REPO_ROOT
readonly RTL_LABEL="rtl-active"

log() {
  local level="$1" event="$2" outcome="$3"
  local extra="${4:-}"
  if [[ -z "$extra" ]]; then
    extra='{}'
  fi
  jq -cn \
    --arg level   "$level" \
    --arg script  "$SCRIPT_NAME" \
    --arg event   "$event" \
    --arg outcome "$outcome" \
    --argjson extra "$extra" \
    '{level:$level, script:$script, event:$event, outcome:$outcome} + $extra' >&2
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

REPO=""
PR=""
ACTOR=""
BOT_LOGIN="${RTL_BOT_LOGIN:-rtlreview[bot]}"
SKILL_DIR="${RTL_SKILL_DIR:-$REPO_ROOT/skills/code-review}"
MODEL="${RTL_CLAUDE_MODEL:-claude-opus-4-7}"
SKILL_VERSION="${RTL_SKILL_VERSION:-0.1.0}"

die_args() {
  log error parse_args failure "$(jq -cn --arg m "$1" '{message:$m}')"
  exit 2
}

while (( $# > 0 )); do
  case "$1" in
    --repo)          REPO="$2"; shift 2 ;;
    --pr)            PR="$2"; shift 2 ;;
    --actor)         ACTOR="$2"; shift 2 ;;
    --bot-login)     BOT_LOGIN="$2"; shift 2 ;;
    --skill-dir)     SKILL_DIR="$2"; shift 2 ;;
    --model)         MODEL="$2"; shift 2 ;;
    --skill-version) SKILL_VERSION="$2"; shift 2 ;;
    *) die_args "unknown argument: $1" ;;
  esac
done

[[ -z "$REPO"  ]] && die_args "missing required --repo"
[[ -z "$PR"    ]] && die_args "missing required --pr"
[[ -z "$ACTOR" ]] && die_args "missing required --actor"

if ! [[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  die_args "invalid --repo format: $REPO"
fi
if ! [[ "$PR" =~ ^[0-9]+$ ]]; then
  die_args "invalid --pr: $PR"
fi
[[ -d "$SKILL_DIR" ]] || die_args "skill dir not found: $SKILL_DIR"

# ---------------------------------------------------------------------------
# Workspace
# ---------------------------------------------------------------------------

WORK="$(mktemp -d -t rtl-handle-review.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

CTX_FILE="$WORK/context.json"
PROMPT_FILE="$WORK/prompt.md"
REVIEW_OUT="$WORK/review.md"
PARSED_FILE="$WORK/parsed.json"
STATE_FILE="$WORK/state.json"
ERR_FILE="$WORK/err"
HOLDING_FILE="$WORK/holding.json"

# Lazy state: holding-comment id; set after step 2 succeeds.
HOLDING_ID=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# post_user_comment <body> — drop a normal issue comment on the PR. Used for
# precondition messages where there is no holding comment to edit.
post_user_comment() {
  local body="$1"
  gh api -X POST "repos/${REPO}/issues/${PR}/comments" \
    -f "body=$body" >/dev/null 2>&1 || true
}

# update_holding <body> — replace the holding comment body (markers preserved).
# No-op if the holding comment was never posted.
update_holding() {
  local body="$1"
  [[ -z "$HOLDING_ID" ]] && return 0
  gh api -X PATCH "repos/${REPO}/issues/comments/${HOLDING_ID}" \
    -f "body=$body" >/dev/null 2>&1 || true
}

# fail_with_holding <message> <event> — surface a system error to the
# maintainer via the holding comment, then exit 2.
fail_with_holding() {
  local msg="$1" event="$2"
  log error "$event" failure "$(jq -cn --arg m "$msg" '{message:$m}')"
  update_holding "❌ rtlreviewbot review failed: $msg

See workflow logs for details."
  exit 2
}

# ---------------------------------------------------------------------------
# Step 1 — preconditions
# ---------------------------------------------------------------------------

log info preconditions attempt "$(jq -cn --arg r "$REPO" --arg p "$PR" --arg a "$ACTOR" \
  '{repo:$r, pr:$p, actor:$a}')"

PR_FILE="$WORK/pr.json"
if ! gh api "repos/${REPO}/pulls/${PR}" >"$PR_FILE" 2>"$ERR_FILE"; then
  err="$(tr '\n' ' ' <"$ERR_FILE" 2>/dev/null || true)"
  log error preconditions failure "$(jq -cn --arg m "fetch PR failed: $err" '{message:$m}')"
  exit 2
fi

PR_STATE="$(jq -r '.state' "$PR_FILE")"
PR_DRAFT="$(jq -r '.draft // false' "$PR_FILE")"
PR_LABELS="$(jq -r '[.labels[].name]' "$PR_FILE")"

if [[ "$PR_STATE" != "open" ]]; then
  post_user_comment "Cannot run \`/rtl review\` on a PR that is not open (state: \`$PR_STATE\`)."
  log info preconditions skipped_not_open "$(jq -cn --arg s "$PR_STATE" '{state:$s}')"
  exit 0
fi

if [[ "$PR_DRAFT" == "true" ]]; then
  post_user_comment "Cannot run \`/rtl review\` on a draft PR. Mark it ready for review first."
  log info preconditions skipped_draft "{}"
  exit 0
fi

if echo "$PR_LABELS" | jq -e --arg l "$RTL_LABEL" 'index($l) != null' >/dev/null; then
  post_user_comment "rtlreviewbot is already active on this PR. Use the **Re-request review** button or \`/rtl re-review\` to refresh."
  log info preconditions skipped_already_active "{}"
  exit 0
fi

# ---------------------------------------------------------------------------
# Step 2 — holding comment
# ---------------------------------------------------------------------------

log info holding_comment attempt "{}"

if ! "$REPO_ROOT/scripts/post-holding-comment.sh" \
       --repo "$REPO" --pr "$PR" >"$HOLDING_FILE" 2>"$ERR_FILE"; then
  err="$(tr '\n' ' ' <"$ERR_FILE" 2>/dev/null || true)"
  log error holding_comment failure "$(jq -cn --arg m "$err" '{message:$m}')"
  exit 2
fi
HOLDING_ID="$(jq -r '.comment_id' "$HOLDING_FILE")"

# ---------------------------------------------------------------------------
# Step 3 — fetch PR context
# ---------------------------------------------------------------------------

log info fetch_context attempt "{}"

if ! "$REPO_ROOT/scripts/fetch-pr-context.sh" \
       --repo "$REPO" --pr "$PR" --bot-login "$BOT_LOGIN" \
       >"$CTX_FILE" 2>"$ERR_FILE"; then
  err="$(tr '\n' ' ' <"$ERR_FILE" 2>/dev/null || true)"
  fail_with_holding "could not fetch PR context: ${err:-unknown}" fetch_context
fi

# ---------------------------------------------------------------------------
# Step 4 — truncation gate
# ---------------------------------------------------------------------------

TRUNCATED="$(jq -r '.diff.truncated' "$CTX_FILE")"
if [[ "$TRUNCATED" == "true" ]]; then
  CC="$(jq -r '.diff.char_count' "$CTX_FILE")"
  MX="$(jq -r '.diff.max_chars'  "$CTX_FILE")"
  update_holding "⚠️ Skipping review — diff is ${CC} characters and rtlreviewbot's per-PR ceiling is ${MX}.

Consider splitting this PR into smaller pieces, then re-invoke \`/rtl review\`. The bot does not approve unreviewed code."
  log info diff_truncated skipped "$(jq -cn --argjson c "$CC" --argjson m "$MX" '{char_count:$c, max_chars:$m}')"
  exit 0
fi

# ---------------------------------------------------------------------------
# Step 5 — invoke the /code-review skill via Claude Code
#
# Prompt structure: SKILL.md (canonical contract + rubric) -> initial-review
# prompt (mode-specific) -> the PR context JSON.
# ---------------------------------------------------------------------------

{
  cat "$SKILL_DIR/SKILL.md"
  printf '\n\n---\n\n'
  cat "$SKILL_DIR/prompts/initial-review.md"
  printf '\n\n---\n\n## PR context\n\n```json\n'
  cat "$CTX_FILE"
  printf '\n```\n'
} > "$PROMPT_FILE"

# One-time diagnostic: log the CLI's version and resolved path. Helps
# debug "is claude even installed" / "which version is on PATH" without
# needing to repro inside the runner.
CLAUDE_BIN="$(command -v claude 2>/dev/null || echo '<not-found>')"
CLAUDE_VERSION="$(claude --version 2>&1 | head -n1 || echo '<unavailable>')"
log info invoke_claude environment "$(jq -cn \
  --arg bin "$CLAUDE_BIN" --arg ver "$CLAUDE_VERSION" --arg m "$MODEL" \
  '{bin:$bin, version:$ver, model:$m}')"

# Non-interactive Claude Code: `claude -p` reads the prompt from stdin and
# prints the assistant response to stdout. Piping rather than passing the
# prompt as an argument avoids two problems: (1) the CLI's argparser
# rejects values that start with `--` (our SKILL.md leads with YAML
# frontmatter that starts with `---`), and (2) argv length limits on
# 200k-character diffs.
invoke_claude() {
  claude --model "$MODEL" -p \
    <"$PROMPT_FILE" >"$REVIEW_OUT" 2>"$ERR_FILE"
}

attempt=1
max_attempts=2
claude_ok=false
claude_exit=0
while (( attempt <= max_attempts )); do
  # Capture exit code via the else branch. After `fi`, bash sets $? to 0
  # when no branch ran (per the man page rule "or zero if no condition
  # tested true"), which would mask the actual failure code.
  if invoke_claude; then
    claude_ok=true
    break
  else
    claude_exit=$?
  fi
  if (( attempt < max_attempts )); then
    log warn invoke_claude retry "$(jq -cn \
      --argjson n "$attempt" --argjson code "$claude_exit" \
      '{attempt:$n, exit_code:$code}')"
    sleep 5
  fi
  attempt=$((attempt + 1))
done

if ! "$claude_ok"; then
  # Some CLIs surface errors on stdout instead of stderr (or write to
  # both). Capture both, truncated, so the failure log gives the operator
  # something concrete to act on.
  err_excerpt="$(head -c 1500 "$ERR_FILE"   2>/dev/null | tr '\n' ' ' || true)"
  out_excerpt="$(head -c 1500 "$REVIEW_OUT" 2>/dev/null | tr '\n' ' ' || true)"
  log error invoke_claude full_failure "$(jq -cn \
    --argjson code "$claude_exit" \
    --arg     stderr "$err_excerpt" \
    --arg     stdout "$out_excerpt" \
    '{exit_code:$code, stderr:$stderr, stdout:$stdout}')"
  fail_with_holding "code-review skill failed after retry (exit ${claude_exit}): ${err_excerpt:-${out_excerpt:-no output}}" invoke_claude
fi

# ---------------------------------------------------------------------------
# Step 6 — parse Claude's output
# ---------------------------------------------------------------------------

if ! "$REPO_ROOT/scripts/parse-review-output.sh" \
       <"$REVIEW_OUT" >"$PARSED_FILE" 2>"$ERR_FILE"; then
  err="$(tr '\n' ' ' <"$ERR_FILE" 2>/dev/null || true)"
  fail_with_holding "could not parse skill output: ${err:-unknown}" parse_review
fi

# ---------------------------------------------------------------------------
# Step 7 — post the formal review
# ---------------------------------------------------------------------------

POST_FILE="$WORK/post.json"
if ! "$REPO_ROOT/scripts/post-review.sh" \
       --repo "$REPO" --pr "$PR" --context-file "$CTX_FILE" \
       <"$PARSED_FILE" >"$POST_FILE" 2>"$ERR_FILE"; then
  err="$(tr '\n' ' ' <"$ERR_FILE" 2>/dev/null || true)"
  fail_with_holding "could not post review: ${err:-unknown}" post_review
fi
REVIEW_URL="$(jq -r '.review_url' "$POST_FILE")"

# ---------------------------------------------------------------------------
# Step 8 — apply the rtl-active label
# ---------------------------------------------------------------------------

log info apply_label attempt "$(jq -cn --arg l "$RTL_LABEL" '{label:$l}')"
if ! gh api -X POST "repos/${REPO}/issues/${PR}/labels" \
       -f "labels[]=$RTL_LABEL" >/dev/null 2>"$ERR_FILE"; then
  err="$(tr '\n' ' ' <"$ERR_FILE" 2>/dev/null || true)"
  log warn apply_label failure "$(jq -cn --arg m "$err" '{message:$m}')"
  # Non-fatal — the review is already posted. Maintainer can label manually.
fi

# ---------------------------------------------------------------------------
# Step 9 — best-effort reviewer add (enables Re-request review for FR-2)
# ---------------------------------------------------------------------------

# Use the bot's slug (without [bot] suffix) for the requested-reviewers API.
# If $BOT_LOGIN is the [bot]-suffixed user login, strip the suffix.
BOT_SLUG="${BOT_LOGIN%\[bot\]}"
log info request_reviewer attempt "$(jq -cn --arg s "$BOT_SLUG" '{slug:$s}')"
if ! gh api -X POST "repos/${REPO}/pulls/${PR}/requested_reviewers" \
       -f "reviewers[]=$BOT_SLUG" >/dev/null 2>"$ERR_FILE"; then
  err="$(tr '\n' ' ' <"$ERR_FILE" 2>/dev/null || true)"
  log warn request_reviewer not_added "$(jq -cn --arg m "$err" '{message:$m}')"
  # Non-fatal. Some Apps cannot be requested reviewers; the bot still works
  # for direct /rtl re-review even if Re-request review does not target it.
fi

# ---------------------------------------------------------------------------
# Step 10 — write metadata marker
# ---------------------------------------------------------------------------

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
HEAD_SHA="$(jq -r '.pr.head_sha' "$CTX_FILE")"

jq -n \
  --arg sha           "$HEAD_SHA" \
  --arg now           "$NOW" \
  --arg skill_version "$SKILL_VERSION" \
  --arg model         "$MODEL" \
  --slurpfile parsed  "$PARSED_FILE" \
  '{
    version:           "1.0",
    last_reviewed_sha: $sha,
    last_reviewed_at:  $now,
    skill_version:     $skill_version,
    model:             $model,
    findings:          ($parsed[0].findings
                          | map({
                              id, severity,
                              status: "unresolved",
                              path:   (.path // null),
                              line:   (.line // null),
                              first_raised_sha: $sha
                            })),
    dismissed_findings: []
  }' > "$STATE_FILE"

if ! "$REPO_ROOT/scripts/update-metadata.sh" \
       --repo "$REPO" --pr "$PR" --mode write --bot-login "$BOT_LOGIN" \
       <"$STATE_FILE" >/dev/null 2>"$ERR_FILE"; then
  err="$(tr '\n' ' ' <"$ERR_FILE" 2>/dev/null || true)"
  fail_with_holding "could not write metadata marker: ${err:-unknown}" update_metadata
fi

# ---------------------------------------------------------------------------
# Step 11 — finalize the holding comment
# ---------------------------------------------------------------------------

INLINE_COUNT="$(jq -r '.inline_count'  "$POST_FILE")"
DEMOTED_COUNT="$(jq -r '.demoted_count' "$POST_FILE")"
TOTAL=$((INLINE_COUNT + DEMOTED_COUNT))
update_holding "✅ Review posted: ${REVIEW_URL}

${TOTAL} finding(s); ${INLINE_COUNT} inline, ${DEMOTED_COUNT} in body."

log info handle_review success "$(jq -cn \
  --arg url "$REVIEW_URL" \
  --argjson total "$TOTAL" \
  --argjson inline "$INLINE_COUNT" \
  --argjson demoted "$DEMOTED_COUNT" \
  '{review_url:$url, total:$total, inline:$inline, demoted:$demoted}')"
