#!/usr/bin/env bash
#
# handle-explain.sh — handler for /rtl explain <id>.
#
# Reads the metadata marker, validates that <id> is a known non-dismissed
# finding, fetches PR context, builds the explain prompt with a
# target_finding block injected into the context, invokes Claude (auth
# fallback via lib/invoke-claude.sh, raw markdown output), and posts the
# response. If the finding has an inline_comment_id (set by handle-
# review.sh from v0.6.0+), the response is posted as a reply on the
# original inline-comment thread; otherwise it goes as a top-level PR
# comment with a "(re: F<id>)" preamble.
#
# Permission: enforced upstream by run-review.sh — open to anyone.
#
# Success UX: 👍 reaction on the triggering comment.
# Error UX:   visible explanatory comment on the PR (unknown id,
#             dismissed id, marker missing, Claude failure).

set -euo pipefail

readonly SCRIPT_NAME="${BASH_SOURCE[0]##*/}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; readonly SCRIPT_DIR
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)";              readonly REPO_ROOT

readonly SKILL_DIR_DEFAULT="$REPO_ROOT/skills/code-review"

# shellcheck source=../lib/comment-ops.sh
. "$REPO_ROOT/scripts/lib/comment-ops.sh"

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

REPO=""; PR=""; ACTOR=""; ARGS=""; COMMENT_ID=""
BOT_LOGIN="${RTL_BOT_LOGIN:-rtlreview[bot]}"
SKILL_DIR="${RTL_SKILL_DIR:-$SKILL_DIR_DEFAULT}"

while (( $# > 0 )); do
  case "$1" in
    --repo)         REPO="$2"; shift 2 ;;
    --pr)           PR="$2"; shift 2 ;;
    --actor)        ACTOR="$2"; shift 2 ;;
    --args)         ARGS="$2"; shift 2 ;;
    --comment-id)   COMMENT_ID="$2"; shift 2 ;;
    --bot-login)    BOT_LOGIN="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [[ -z "$REPO" || -z "$PR" ]]; then
  log error parse_args failure '{"message":"missing --repo or --pr"}'
  exit 2
fi

ack_success() {
  if [[ -n "$COMMENT_ID" ]]; then
    react_to_comment "$REPO" "$COMMENT_ID" "+1" || true
  fi
}

post_error() {
  post_comment "$REPO" "$PR" "$1" >/dev/null || true
}

# ---------------------------------------------------------------------------
# Parse the finding id from --args.
# ---------------------------------------------------------------------------

if [[ -z "$ARGS" ]]; then
  post_error "❌ \`/rtl explain\` requires a finding id, e.g. \`/rtl explain F3\`."
  log info handle_explain missing_id "{}"
  exit 0
fi

read -r FINDING_ID _REST <<<"$ARGS"

if ! [[ "$FINDING_ID" =~ ^F[0-9]+$ ]]; then
  post_error "❌ \`/rtl explain\` first argument must be a finding id like \`F3\` (got: \`${FINDING_ID}\`)."
  log info handle_explain bad_id "$(jq -cn --arg id "$FINDING_ID" '{id:$id}')"
  exit 0
fi

# ---------------------------------------------------------------------------
# Read marker, validate finding.
# ---------------------------------------------------------------------------

WORK="$(mktemp -d -t rtl-explain.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

MARKER_FILE="$WORK/marker.json"
CTX_FILE="$WORK/context.json"
MERGED_CTX_FILE="$WORK/merged_context.json"
PROMPT_FILE="$WORK/prompt.md"
RESPONSE_FILE="$WORK/response.md"
ERR_FILE="$WORK/err"

log info handle_explain attempt "$(jq -cn --arg id "$FINDING_ID" --arg a "$ACTOR" '{finding_id:$id, actor:$a}')"

if ! "$REPO_ROOT/scripts/update-metadata.sh" \
       --repo "$REPO" --pr "$PR" --mode read --bot-login "$BOT_LOGIN" \
       >"$MARKER_FILE" 2>/dev/null; then
  post_error "❌ \`/rtl explain ${FINDING_ID}\` could not read the metadata marker. See workflow logs."
  log error read_marker failure '{}'
  exit 2
fi

if [[ "$(cat "$MARKER_FILE")" == "null" ]]; then
  post_error "❌ Cannot explain \`${FINDING_ID}\`: rtlreviewbot has not reviewed this PR yet. Run \`/rtl review\` first."
  log info handle_explain no_marker "{}"
  exit 0
fi

FINDING_JSON="$(jq --arg id "$FINDING_ID" '.findings[]? | select(.id == $id)' "$MARKER_FILE")"
DISMISSED="$(jq --arg id "$FINDING_ID" '[.dismissed_findings[]? | select(.id == $id)] | length > 0' "$MARKER_FILE")"

if [[ -z "$FINDING_JSON" ]]; then
  post_error "❌ Cannot explain \`${FINDING_ID}\`: no such finding on this PR."
  log info handle_explain unknown_id "$(jq -cn --arg id "$FINDING_ID" '{id:$id}')"
  exit 0
fi

if [[ "$DISMISSED" == "true" ]]; then
  post_error "ℹ️ \`${FINDING_ID}\` has been dismissed on this PR. Use \`/rtl re-review\` to refresh against current HEAD if you want it re-evaluated."
  log info handle_explain dismissed "$(jq -cn --arg id "$FINDING_ID" '{id:$id}')"
  exit 0
fi

# ---------------------------------------------------------------------------
# Fetch PR context.
# ---------------------------------------------------------------------------

if ! "$REPO_ROOT/scripts/fetch-pr-context.sh" \
       --repo "$REPO" --pr "$PR" --bot-login "$BOT_LOGIN" \
       >"$CTX_FILE" 2>"$ERR_FILE"; then
  err="$(tr '\n' ' ' <"$ERR_FILE" 2>/dev/null || true)"
  post_error "❌ \`/rtl explain ${FINDING_ID}\` could not fetch PR context. See workflow logs."
  log error fetch_context failure "$(jq -cn --arg m "$err" '{message:$m}')"
  exit 2
fi

# Inject target_finding into the context. SKILL.md specifies the field name
# `text` for the finding body (vs `body` in the marker), so we rename here.
jq --argjson f "$FINDING_JSON" '
  . + {
    target_finding: {
      id:       $f.id,
      severity: $f.severity,
      path:     ($f.path // null),
      line:     ($f.line // null),
      text:     ($f.body // "")
    }
  }
' "$CTX_FILE" > "$MERGED_CTX_FILE"

# ---------------------------------------------------------------------------
# Compose the prompt and invoke Claude.
# ---------------------------------------------------------------------------

{
  cat "$SKILL_DIR/SKILL.md"
  printf '\n\n---\n\n'
  cat "$SKILL_DIR/prompts/explain.md"
  printf '\n\n---\n\n## PR context\n\n```json\n'
  cat "$MERGED_CTX_FILE"
  printf '\n```\n'
} > "$PROMPT_FILE"

# shellcheck source=../lib/invoke-claude.sh
. "$REPO_ROOT/scripts/lib/invoke-claude.sh"

if ! invoke_claude_raw "$PROMPT_FILE" "$RESPONSE_FILE" "$ERR_FILE"; then
  err_excerpt="$(head -c 1500 "$ERR_FILE"      2>/dev/null | tr '\n' ' ' || true)"
  out_excerpt="$(head -c 500 "$RESPONSE_FILE"  2>/dev/null | tr '\n' ' ' || true)"
  post_error "❌ \`/rtl explain ${FINDING_ID}\` failed: ${err_excerpt:-${out_excerpt:-no output from skill}}"
  log error invoke_claude failure "$(jq -cn --arg e "$err_excerpt" --arg o "$out_excerpt" '{stderr:$e, stdout_excerpt:$o}')"
  exit 2
fi

# ---------------------------------------------------------------------------
# Post the response.
#
# Routing:
#   - If the finding has an inline_comment_id, post as a REPLY on the
#     original inline thread. Best UX — the elaboration sits next to the
#     concern.
#   - Otherwise, post a top-level PR comment with a "(re: F<id>)"
#     preamble so readers can find their way back to the finding.
# ---------------------------------------------------------------------------

INLINE_COMMENT_ID="$(echo "$FINDING_JSON" | jq -r '.inline_comment_id // empty')"
RESPONSE_BODY="$(cat "$RESPONSE_FILE")"

if [[ -n "$INLINE_COMMENT_ID" && "$INLINE_COMMENT_ID" != "null" ]]; then
  if reply_id="$(reply_to_review_comment "$REPO" "$PR" "$INLINE_COMMENT_ID" "$RESPONSE_BODY")"; then
    log info post_reply success "$(jq -cn --arg id "$reply_id" --arg parent "$INLINE_COMMENT_ID" '{reply_id:$id, in_reply_to:$parent}')"
  else
    # Reply failed (e.g. parent comment was deleted). Fall back to
    # top-level so the user still gets the elaboration.
    log warn post_reply failure_falling_back '{}'
    post_comment "$REPO" "$PR" \
      "(re: \`${FINDING_ID}\`)

${RESPONSE_BODY}" >/dev/null \
      || { post_error "❌ \`/rtl explain ${FINDING_ID}\` produced output but the comment-post failed. See workflow logs."; exit 2; }
  fi
else
  if ! post_comment "$REPO" "$PR" \
        "(re: \`${FINDING_ID}\`)

${RESPONSE_BODY}" >/dev/null; then
    post_error "❌ \`/rtl explain ${FINDING_ID}\` produced output but the comment-post failed. See workflow logs."
    log error post_comment failure '{}'
    exit 2
  fi
  log info post_top_level success '{}'
fi

ack_success
log info handle_explain success "$(jq -cn --arg id "$FINDING_ID" '{id:$id}')"
