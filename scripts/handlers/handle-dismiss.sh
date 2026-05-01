#!/usr/bin/env bash
#
# handle-dismiss.sh — handler for /rtl dismiss <id> [reason].
#
# Reads the metadata marker, validates that <id> is a known non-dismissed
# finding, appends {id, by, reason, at} to dismissed_findings, writes the
# marker back. If the finding has an inline_comment_id (set by handle-
# review.sh from v0.6.0 onwards), also edits that comment in place to
# prepend a dismissal banner so anyone reading the PR thread later sees
# the dismissal next to the original concern.
#
# Permission: enforced upstream by run-review.sh (maintainer only).
#
# Success UX: 👍 reaction on the triggering comment.
# Error UX:   visible comment on the PR (unknown id, already dismissed,
#             marker missing, malformed args).

set -euo pipefail

readonly SCRIPT_NAME="${BASH_SOURCE[0]##*/}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; readonly SCRIPT_DIR
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)";              readonly REPO_ROOT

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

REPO=""; PR=""; ACTOR=""; ARGS=""; COMMENT_ID=""; BOT_LOGIN="${RTL_BOT_LOGIN:-rtlreview[bot]}"
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

if [[ -z "$REPO" || -z "$PR" || -z "$ACTOR" ]]; then
  log error parse_args failure '{"message":"missing --repo, --pr, or --actor"}'
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
# Parse <id> [reason] from --args. The dispatcher joins the parsed args
# array with spaces; first whitespace-delimited token is the finding id,
# the rest is the free-text reason.
# ---------------------------------------------------------------------------

if [[ -z "$ARGS" ]]; then
  post_error "❌ \`/rtl dismiss\` requires a finding id, e.g. \`/rtl dismiss F3 explanation here\`."
  log info handle_dismiss missing_id "{}"
  exit 0
fi

read -r FINDING_ID REASON <<<"$ARGS"

if ! [[ "$FINDING_ID" =~ ^F[0-9]+$ ]]; then
  post_error "❌ \`/rtl dismiss\` first argument must be a finding id like \`F3\` (got: \`${FINDING_ID}\`)."
  log info handle_dismiss bad_id "$(jq -cn --arg id "$FINDING_ID" '{id:$id}')"
  exit 0
fi

# ---------------------------------------------------------------------------
# Read the marker.
# ---------------------------------------------------------------------------

WORK="$(mktemp -d -t rtl-dismiss.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

MARKER_FILE="$WORK/marker.json"
NEW_MARKER_FILE="$WORK/new_marker.json"

log info handle_dismiss read_marker "$(jq -cn --arg id "$FINDING_ID" '{finding_id:$id}')"

if ! "$REPO_ROOT/scripts/update-metadata.sh" \
       --repo "$REPO" --pr "$PR" --mode read --bot-login "$BOT_LOGIN" \
       >"$MARKER_FILE" 2>/dev/null; then
  post_error "❌ \`/rtl dismiss ${FINDING_ID}\` could not read the metadata marker. See workflow logs."
  log error read_marker failure '{}'
  exit 2
fi

if [[ "$(cat "$MARKER_FILE")" == "null" ]]; then
  post_error "❌ Cannot dismiss \`${FINDING_ID}\`: rtlreviewbot has not reviewed this PR yet. Run \`/rtl review\` first."
  log info handle_dismiss no_marker "{}"
  exit 0
fi

# ---------------------------------------------------------------------------
# Validate the finding id is known and not already dismissed.
# ---------------------------------------------------------------------------

FINDING_JSON="$(jq --arg id "$FINDING_ID" '.findings[]? | select(.id == $id)' "$MARKER_FILE")"
ALREADY_DISMISSED="$(jq --arg id "$FINDING_ID" '[.dismissed_findings[]? | select(.id == $id)] | length > 0' "$MARKER_FILE")"

if [[ -z "$FINDING_JSON" ]]; then
  post_error "❌ Cannot dismiss \`${FINDING_ID}\`: no such finding on this PR. Check the most recent review for the actual finding ids."
  log info handle_dismiss unknown_id "$(jq -cn --arg id "$FINDING_ID" '{id:$id}')"
  exit 0
fi

if [[ "$ALREADY_DISMISSED" == "true" ]]; then
  post_error "ℹ️ \`${FINDING_ID}\` is already dismissed on this PR; nothing to do."
  log info handle_dismiss already_dismissed "$(jq -cn --arg id "$FINDING_ID" '{id:$id}')"
  ack_success
  exit 0
fi

INLINE_COMMENT_ID="$(echo "$FINDING_JSON" | jq -r '.inline_comment_id // empty')"
ORIG_BODY="$(echo "$FINDING_JSON" | jq -r '.body // ""')"
SEVERITY="$(echo "$FINDING_JSON" | jq -r '.severity // "minor"')"

# ---------------------------------------------------------------------------
# Compose updated marker JSON and write it.
# ---------------------------------------------------------------------------

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

jq \
  --arg id     "$FINDING_ID" \
  --arg by     "$ACTOR" \
  --arg reason "$REASON" \
  --arg at     "$NOW" \
  '
  .dismissed_findings = ((.dismissed_findings // []) + [{
    id:     $id,
    by:     $by,
    reason: $reason,
    at:     $at
  }])
  ' "$MARKER_FILE" > "$NEW_MARKER_FILE"

if ! "$REPO_ROOT/scripts/update-metadata.sh" \
       --repo "$REPO" --pr "$PR" --mode write --bot-login "$BOT_LOGIN" \
       <"$NEW_MARKER_FILE" >/dev/null 2>/dev/null; then
  post_error "❌ \`/rtl dismiss ${FINDING_ID}\` could not write the metadata marker. See workflow logs."
  log error write_marker failure '{}'
  exit 2
fi

# ---------------------------------------------------------------------------
# Edit the original inline comment in place, if we have its id.
# ---------------------------------------------------------------------------

if [[ -n "$INLINE_COMMENT_ID" && "$INLINE_COMMENT_ID" != "null" ]]; then
  REASON_RENDERED="${REASON:-no reason given}"
  NEW_INLINE_BODY="> 🚫 **Dismissed** by @${ACTOR} — _${REASON_RENDERED}_

**${FINDING_ID} (${SEVERITY}):** ${ORIG_BODY}"

  if ! edit_comment "$REPO" "$INLINE_COMMENT_ID" "$NEW_INLINE_BODY"; then
    log warn edit_inline failure "$(jq -cn --arg id "$INLINE_COMMENT_ID" '{comment_id:$id}')"
    # Non-fatal — the marker mutation already took effect; future re-
    # reviews will skip this finding regardless.
  fi
fi

ack_success
log info handle_dismiss success "$(jq -cn \
  --arg id "$FINDING_ID" --arg by "$ACTOR" --arg reason "$REASON" \
  '{id:$id, by:$by, reason:$reason}')"
