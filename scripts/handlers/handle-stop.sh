#!/usr/bin/env bash
#
# handle-stop.sh — handler for /rtl stop.
#
# Removes the rtl-active and rtl-paused labels from the PR. The metadata
# marker comment is left intact as a historical record (the bot does not
# delete prior reviews, only deactivates itself).
#
# Permission: enforced upstream by run-review.sh (maintainer or PR author).
#
# Success UX (per Q2 Option C of the M6 plan):
#   - 👍 reaction on the triggering comment if --comment-id was provided
#   - On error, post a comment so the user gets visible feedback
#
# Exit codes:
#   0  on success, or on benign no-ops (already stopped)
#   2  on system error (gh API failure on a real call, bad inputs)

set -euo pipefail

readonly SCRIPT_NAME="${BASH_SOURCE[0]##*/}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; readonly SCRIPT_DIR
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)";              readonly REPO_ROOT

readonly RTL_ACTIVE="rtl-active"
readonly RTL_PAUSED="rtl-paused"

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
while (( $# > 0 )); do
  case "$1" in
    --repo)         REPO="$2"; shift 2 ;;
    --pr)           PR="$2"; shift 2 ;;
    --actor)        ACTOR="$2"; shift 2 ;;
    --comment-id)   COMMENT_ID="$2"; shift 2 ;;
    --bot-login|--args) shift 2 ;;
    *) shift ;;
  esac
done

if [[ -z "$REPO" || -z "$PR" ]]; then
  log error parse_args failure '{"message":"missing --repo or --pr"}'
  exit 2
fi

# ---------------------------------------------------------------------------
# Helpers for post-success / post-error feedback.
# ---------------------------------------------------------------------------

ack_success() {
  if [[ -n "$COMMENT_ID" ]]; then
    react_to_comment "$REPO" "$COMMENT_ID" "+1" || \
      log warn react failure '{"message":"reaction failed"}'
  fi
}

post_error() {
  local body="$1"
  post_comment "$REPO" "$PR" "$body" >/dev/null || true
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

log info handle_stop attempt "$(jq -cn --arg r "$REPO" --arg p "$PR" --arg a "$ACTOR" \
  '{repo:$r, pr:$p, actor:$a}')"

# Idempotent: if the PR is not currently rtl-active, this is a no-op.
if ! has_label "$REPO" "$PR" "$RTL_ACTIVE" \
   && ! has_label "$REPO" "$PR" "$RTL_PAUSED"; then
  log info handle_stop already_stopped "{}"
  ack_success
  exit 0
fi

removed_active=false
removed_paused=false

if has_label "$REPO" "$PR" "$RTL_ACTIVE"; then
  if remove_label "$REPO" "$PR" "$RTL_ACTIVE"; then
    removed_active=true
  else
    post_error "❌ \`/rtl stop\` could not remove the \`${RTL_ACTIVE}\` label. See workflow logs."
    log error remove_label failure "$(jq -cn --arg l "$RTL_ACTIVE" '{label:$l}')"
    exit 2
  fi
fi

if has_label "$REPO" "$PR" "$RTL_PAUSED"; then
  if remove_label "$REPO" "$PR" "$RTL_PAUSED"; then
    removed_paused=true
  else
    post_error "❌ \`/rtl stop\` could not remove the \`${RTL_PAUSED}\` label. See workflow logs."
    log error remove_label failure "$(jq -cn --arg l "$RTL_PAUSED" '{label:$l}')"
    exit 2
  fi
fi

ack_success

log info handle_stop success "$(jq -cn \
  --argjson removed_active "$removed_active" \
  --argjson removed_paused "$removed_paused" \
  '{removed_active:$removed_active, removed_paused:$removed_paused}')"
