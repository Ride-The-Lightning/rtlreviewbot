#!/usr/bin/env bash
#
# handle-re-review.sh — handler for /rtl re-review.
#
# Drives FR-2's full re-review flow against the metadata marker:
#
#   1. Preconditions:
#      - PR is open
#      - rtl-active label present (else: "no prior review, run /rtl review")
#      - rtl-paused label absent (else: "bot is paused, /rtl resume first")
#      - marker exists (else: same as no rtl-active — bot has not reviewed)
#   2. HEAD-SHA short-circuit: if marker.last_reviewed_sha == pr.head_sha,
#      post "no new commits since last review — findings still stand" and
#      exit. Saves a Claude call on accidental re-invocations.
#   3. Holding comment ("🔁 re-review starting…").
#   4. Fetch PR context.
#   5. Truncation gate (same as initial review).
#   6. Compose `prior` block from the marker (findings + dismissed_findings)
#      and merge it into the context as `prior`.
#   7. Build the re-review prompt (SKILL.md + prompts/re-review.md +
#      merged context) and invoke Claude (auth fallback, parser-as-oracle).
#   8. Post the formal review (post-review.sh handles status-aware body
#      composition for addressed/withdrawn priors and inline anchoring
#      for unresolved/new).
#   9. Merge the marker:
#      - For each prior finding, update status from parser output (keep
#        original severity/path/line/body/first_raised_sha).
#      - Append new findings with status=unresolved and inline_comment_id
#        from the post-review id mapping.
#      - Carry over dismissed_findings unchanged.
#      - Update last_reviewed_sha, last_reviewed_at, model.
#  10. rtl-active stays put (idempotent re-add).
#  11. Finalize holding with the same 🔁 CTA pattern as initial review.
#
# Permission: enforced upstream by run-review.sh (maintainer only).
#
# Exit codes:
#   0  on success, or on benign no-ops (no new commits, paused, etc.)
#   2  on system error at any step

set -euo pipefail

readonly SCRIPT_NAME="${BASH_SOURCE[0]##*/}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; readonly SCRIPT_DIR
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)";              readonly REPO_ROOT

readonly RTL_ACTIVE="rtl-active"
readonly RTL_PAUSED="rtl-paused"
readonly SKILL_DIR_DEFAULT="$REPO_ROOT/skills/code-review"

# shellcheck source=../lib/comment-ops.sh
. "$REPO_ROOT/scripts/lib/comment-ops.sh"
# shellcheck source=../lib/labels.sh
. "$REPO_ROOT/scripts/lib/labels.sh"

log() {
  local level="$1" event="$2" outcome="$3"
  local extra="${4:-}"
  if [[ -z "$extra" ]]; then extra='{}'; fi
  jq -cn \
    --arg level "$level" --arg script "$SCRIPT_NAME" \
    --arg event "$event" --arg outcome "$outcome" \
    --argjson extra "$extra" \
    '{level:$level, script:$script, event:$event, outcome:$outcome} + $extra' >&2
}

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------

REPO=""; PR=""; ACTOR=""; COMMENT_ID=""
BOT_LOGIN="${RTL_BOT_LOGIN:-rtlreview[bot]}"
SKILL_DIR="${RTL_SKILL_DIR:-$SKILL_DIR_DEFAULT}"
MODEL="${RTL_CLAUDE_MODEL:-claude-opus-4-7}"
SKILL_VERSION="${RTL_SKILL_VERSION:-0.1.0}"

while (( $# > 0 )); do
  case "$1" in
    --repo)         REPO="$2"; shift 2 ;;
    --pr)           PR="$2"; shift 2 ;;
    --actor)        ACTOR="$2"; shift 2 ;;
    --comment-id)   COMMENT_ID="$2"; shift 2 ;;
    --bot-login)    BOT_LOGIN="$2"; shift 2 ;;
    --args)         shift 2 ;;
    *) shift ;;
  esac
done

if [[ -z "$REPO" || -z "$PR" || -z "$ACTOR" ]]; then
  log error parse_args failure '{"message":"missing --repo/--pr/--actor"}'
  exit 2
fi

# ---------------------------------------------------------------------------
# Workspace
# ---------------------------------------------------------------------------

WORK="$(mktemp -d -t rtl-rerev.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

CTX_FILE="$WORK/context.json"
MARKER_FILE="$WORK/marker.json"
MERGED_CTX_FILE="$WORK/merged_context.json"
PROMPT_FILE="$WORK/prompt.md"
REVIEW_OUT="$WORK/review.md"
PARSED_FILE="$WORK/parsed.json"
NEW_MARKER_FILE="$WORK/new_marker.json"
POST_FILE="$WORK/post.json"
HOLDING_FILE="$WORK/holding.json"
ERR_FILE="$WORK/err"
HOLDING_ID=""

ack_success_react() {
  if [[ -n "$COMMENT_ID" ]]; then
    react_to_comment "$REPO" "$COMMENT_ID" "+1" || true
  fi
}

post_user_comment() {
  post_comment "$REPO" "$PR" "$1" >/dev/null 2>&1 || true
}

update_holding() {
  [[ -z "$HOLDING_ID" ]] && return 0
  edit_comment "$REPO" "$HOLDING_ID" "$1" 2>/dev/null || true
}

fail_with_holding() {
  local msg="$1" event="$2"
  log error "$event" failure "$(jq -cn --arg m "$msg" '{message:$m}')"
  update_holding "❌ rtlreviewbot re-review failed: $msg

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
  log error preconditions failure "$(jq -cn --arg m "fetch PR failed" '{message:$m}')"
  exit 2
fi

PR_STATE="$(jq -r '.state' "$PR_FILE")"

if [[ "$PR_STATE" != "open" ]]; then
  post_user_comment "Cannot \`/rtl re-review\` on a PR that is not open (state: \`$PR_STATE\`)."
  log info preconditions skipped_not_open "$(jq -cn --arg s "$PR_STATE" '{state:$s}')"
  exit 0
fi

if ! has_label "$REPO" "$PR" "$RTL_ACTIVE"; then
  post_user_comment "rtlreviewbot is not active on this PR. Run \`/rtl review\` first to engage it."
  log info preconditions skipped_not_active "{}"
  exit 0
fi

if has_label "$REPO" "$PR" "$RTL_PAUSED"; then
  post_user_comment "rtlreviewbot is paused on this PR. Use \`/rtl resume\` to re-enable, then re-run \`/rtl re-review\`."
  log info preconditions skipped_paused "{}"
  exit 0
fi

# Read the prior marker. Required for re-review.
log info read_marker attempt "{}"
if ! "$REPO_ROOT/scripts/update-metadata.sh" \
       --repo "$REPO" --pr "$PR" --mode read --bot-login "$BOT_LOGIN" \
       >"$MARKER_FILE" 2>/dev/null; then
  log error read_marker failure '{}'
  post_user_comment "❌ \`/rtl re-review\` could not read the metadata marker. See workflow logs."
  exit 2
fi

if [[ "$(cat "$MARKER_FILE")" == "null" ]]; then
  post_user_comment "rtlreviewbot has no prior review on this PR. Run \`/rtl review\` first."
  log info preconditions skipped_no_marker "{}"
  exit 0
fi

# ---------------------------------------------------------------------------
# Step 2 — HEAD-SHA short-circuit
# ---------------------------------------------------------------------------

CURRENT_HEAD_SHA="$(jq -r '.head.sha' "$PR_FILE")"
LAST_REVIEWED_SHA="$(jq -r '.last_reviewed_sha // ""' "$MARKER_FILE")"

if [[ -n "$LAST_REVIEWED_SHA" && "$CURRENT_HEAD_SHA" == "$LAST_REVIEWED_SHA" ]]; then
  post_user_comment "No new commits since the last rtlreviewbot review (HEAD is still \`${CURRENT_HEAD_SHA:0:7}\`). Findings still stand."
  log info head_sha_short_circuit applied "$(jq -cn --arg s "$CURRENT_HEAD_SHA" '{head_sha:$s}')"
  ack_success_react
  exit 0
fi

# ---------------------------------------------------------------------------
# Step 3 — holding comment
# ---------------------------------------------------------------------------

log info holding_comment attempt "{}"
if ! "$REPO_ROOT/scripts/post-holding-comment.sh" \
       --repo "$REPO" --pr "$PR" \
       --body "🔁 rtlreviewbot re-review starting…" \
       >"$HOLDING_FILE" 2>"$ERR_FILE"; then
  err="$(tr '\n' ' ' <"$ERR_FILE" 2>/dev/null || true)"
  log error holding_comment failure "$(jq -cn --arg m "$err" '{message:$m}')"
  exit 2
fi
HOLDING_ID="$(jq -r '.comment_id' "$HOLDING_FILE")"

# ---------------------------------------------------------------------------
# Step 4 — fetch PR context
# ---------------------------------------------------------------------------

log info fetch_context attempt "{}"
if ! "$REPO_ROOT/scripts/fetch-pr-context.sh" \
       --repo "$REPO" --pr "$PR" --bot-login "$BOT_LOGIN" \
       >"$CTX_FILE" 2>"$ERR_FILE"; then
  err="$(tr '\n' ' ' <"$ERR_FILE" 2>/dev/null || true)"
  fail_with_holding "could not fetch PR context: ${err:-unknown}" fetch_context
fi

# ---------------------------------------------------------------------------
# Step 5 — truncation gate
# ---------------------------------------------------------------------------

TRUNCATED="$(jq -r '.diff.truncated' "$CTX_FILE")"
if [[ "$TRUNCATED" == "true" ]]; then
  CC="$(jq -r '.diff.char_count' "$CTX_FILE")"
  MX="$(jq -r '.diff.max_chars'  "$CTX_FILE")"
  update_holding "⚠️ Skipping re-review — diff is ${CC} characters and the per-PR ceiling is ${MX}.

Consider splitting this PR into smaller pieces, then re-invoke \`/rtl re-review\`."
  log info diff_truncated skipped "$(jq -cn --argjson c "$CC" --argjson m "$MX" '{char_count:$c, max_chars:$m}')"
  exit 0
fi

# ---------------------------------------------------------------------------
# Step 6 — compose merged context with `prior` block
# ---------------------------------------------------------------------------

# The `prior` field shape per SKILL.md: the marker contents directly. We
# pass them through with light projection — Claude does not need
# inline_comment_id / first_raised_sha.
jq --slurpfile m "$MARKER_FILE" '
  . + {
    prior: {
      last_reviewed_sha: $m[0].last_reviewed_sha,
      skill_version:     $m[0].skill_version,
      model:             $m[0].model,
      findings: ($m[0].findings // []
        | map({
            id, severity, status,
            path:  (.path // null),
            line:  (.line // null),
            body:  (.body // "")
          })),
      dismissed_findings: ($m[0].dismissed_findings // [])
    }
  }
' "$CTX_FILE" > "$MERGED_CTX_FILE"

# ---------------------------------------------------------------------------
# Step 7 — invoke the /code-review skill in re-review mode
# ---------------------------------------------------------------------------

{
  cat "$SKILL_DIR/SKILL.md"
  printf '\n\n---\n\n'
  cat "$SKILL_DIR/prompts/re-review.md"
  printf '\n\n---\n\n## PR context\n\n```json\n'
  cat "$MERGED_CTX_FILE"
  printf '\n```\n'
} > "$PROMPT_FILE"

# shellcheck source=../lib/invoke-claude.sh
. "$REPO_ROOT/scripts/lib/invoke-claude.sh"

if ! invoke_claude_for_review "$PROMPT_FILE" "$REVIEW_OUT" "$PARSED_FILE" "$ERR_FILE"; then
  err_excerpt="$(head -c 1500 "$ERR_FILE"   2>/dev/null | tr '\n' ' ' || true)"
  out_excerpt="$(head -c 1500 "$REVIEW_OUT" 2>/dev/null | tr '\n' ' ' || true)"
  fail_with_holding "code-review skill failed across all auth modes: ${err_excerpt:-${out_excerpt:-no output}}" invoke_claude
fi

# ---------------------------------------------------------------------------
# Step 8 — post the formal review
# ---------------------------------------------------------------------------

if ! "$REPO_ROOT/scripts/post-review.sh" \
       --repo "$REPO" --pr "$PR" --context-file "$CTX_FILE" \
       <"$PARSED_FILE" >"$POST_FILE" 2>"$ERR_FILE"; then
  err="$(tr '\n' ' ' <"$ERR_FILE" 2>/dev/null || true)"
  fail_with_holding "could not post review: ${err:-unknown}" post_review
fi
REVIEW_URL="$(jq -r '.review_url' "$POST_FILE")"

# ---------------------------------------------------------------------------
# Step 9 — merge the marker
#
# Strategy: keep prior fields (severity, path, line, body, first_raised_sha,
# inline_comment_id) for prior findings, update status from parser output.
# inline_comment_id may also be refreshed if post-review.sh assigned a new
# inline anchor (re-posted unresolved/partially_addressed findings get new
# comment ids on each re-review).
#
# New findings get a fresh marker entry with status=unresolved and the
# new inline_comment_id from post-review's mapping.
#
# dismissed_findings carry over unchanged.
# ---------------------------------------------------------------------------

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
COMMENT_IDS="$(jq -c '.finding_comment_ids // {}' "$POST_FILE")"

jq -n \
  --slurpfile parsed "$PARSED_FILE" \
  --slurpfile prior  "$MARKER_FILE" \
  --argjson   cids   "$COMMENT_IDS" \
  --arg       sha   "$CURRENT_HEAD_SHA" \
  --arg       now   "$NOW" \
  --arg       skill_version "$SKILL_VERSION" \
  --arg       model "$MODEL" \
  '
  ($prior[0].findings // [])           as $prior_findings
  | ($prior[0].dismissed_findings // []) as $prior_dismissed
  | ($parsed[0].prior_findings // [])    as $status_updates
  | ($parsed[0].new_findings // [])      as $new_findings_parser

  | ($prior_findings | map(. as $f
      | ($status_updates | map(select(.id == $f.id))[0]) as $upd
      | $f + (if $upd then {
          status: ($upd.status // $f.status),
          inline_comment_id: ($cids[$f.id] // $f.inline_comment_id // null)
        } else {} end)
    )) as $merged_priors

  | ($new_findings_parser | map(. as $f | {
      id:                $f.id,
      severity:          $f.severity,
      status:            "unresolved",
      path:              ($f.path // null),
      line:              ($f.line // null),
      body:              ($f.body // ""),
      inline_comment_id: ($cids[$f.id] // null),
      first_raised_sha:  $sha
    })) as $new_findings_marker

  | {
      version:            "1.1",
      last_reviewed_sha:  $sha,
      last_reviewed_at:   $now,
      skill_version:      $skill_version,
      model:              $model,
      findings:           ($merged_priors + $new_findings_marker),
      dismissed_findings: $prior_dismissed
    }
  ' > "$NEW_MARKER_FILE"

if ! "$REPO_ROOT/scripts/update-metadata.sh" \
       --repo "$REPO" --pr "$PR" --mode write --bot-login "$BOT_LOGIN" \
       <"$NEW_MARKER_FILE" >/dev/null 2>"$ERR_FILE"; then
  err="$(tr '\n' ' ' <"$ERR_FILE" 2>/dev/null || true)"
  fail_with_holding "could not write metadata marker: ${err:-unknown}" update_metadata
fi

# ---------------------------------------------------------------------------
# Step 10 — finalize holding comment
# ---------------------------------------------------------------------------

INLINE_COUNT="$(jq -r '.inline_count'  "$POST_FILE")"
DEMOTED_COUNT="$(jq -r '.demoted_count' "$POST_FILE")"
TOTAL=$((INLINE_COUNT + DEMOTED_COUNT))

PRIOR_ADDRESSED="$(jq '[.prior_findings[]? | select(.status=="addressed")] | length' "$PARSED_FILE")"
PRIOR_UNRESOLVED="$(jq '[.prior_findings[]? | select(.status=="unresolved" or .status=="partially_addressed")] | length' "$PARSED_FILE")"
PRIOR_WITHDRAWN="$(jq '[.prior_findings[]? | select(.status=="withdrawn")] | length' "$PARSED_FILE")"
NEW_COUNT="$(jq '.new_findings | length' "$PARSED_FILE")"

update_holding "✅ Re-review posted: ${REVIEW_URL}

Prior findings: ${PRIOR_ADDRESSED} addressed, ${PRIOR_UNRESOLVED} still unresolved, ${PRIOR_WITHDRAWN} withdrawn.
New findings: ${NEW_COUNT}.
Total inline: ${INLINE_COUNT}; in body: ${DEMOTED_COUNT}.

🔁 **Need another re-review after pushing changes?** Reply with \`/rtl re-review\`.
Maintainers can also \`/rtl dismiss <id>\` to silence specific findings, or anyone can \`/rtl explain <id>\` for elaboration."

ack_success_react

log info handle_re_review success "$(jq -cn \
  --arg url "$REVIEW_URL" \
  --argjson total "$TOTAL" \
  --argjson addressed "$PRIOR_ADDRESSED" \
  --argjson unresolved "$PRIOR_UNRESOLVED" \
  --argjson withdrawn "$PRIOR_WITHDRAWN" \
  --argjson new_count "$NEW_COUNT" \
  '{review_url:$url, total:$total, addressed:$addressed, unresolved:$unresolved, withdrawn:$withdrawn, new:$new_count}')"
