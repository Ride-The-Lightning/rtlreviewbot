#!/usr/bin/env bash
#
# handle-pause.sh — handler for /rtl pause.
#
# Adds the rtl-paused label to the PR while leaving rtl-active in place.
# While rtl-paused is present, /rtl re-review and the (no-op) re-request
# review event handler exit silently — the bot is engaged but suppressed.
#
# Permission: enforced upstream by run-review.sh (maintainer or PR author).
#
# Success UX: 👍 reaction on the triggering comment.
# Error UX:   visible comment on the PR.

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

REPO=""; PR=""; COMMENT_ID=""
while (( $# > 0 )); do
  case "$1" in
    --repo)         REPO="$2"; shift 2 ;;
    --pr)           PR="$2"; shift 2 ;;
    --comment-id)   COMMENT_ID="$2"; shift 2 ;;
    --actor|--bot-login|--args) shift 2 ;;
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

log info handle_pause attempt "$(jq -cn --arg r "$REPO" --arg p "$PR" '{repo:$r, pr:$p}')"

# Precondition: only meaningful on an rtl-active PR.
if ! has_label "$REPO" "$PR" "$RTL_ACTIVE"; then
  post_error "rtlreviewbot is not active on this PR. Run \`/rtl review\` to engage it first."
  log info handle_pause skipped_not_active "{}"
  exit 0
fi

# Idempotent: already paused = no-op.
if has_label "$REPO" "$PR" "$RTL_PAUSED"; then
  log info handle_pause already_paused "{}"
  ack_success
  exit 0
fi

if ! add_label "$REPO" "$PR" "$RTL_PAUSED"; then
  post_error "❌ \`/rtl pause\` could not apply the \`${RTL_PAUSED}\` label. See workflow logs."
  log error add_label failure '{}'
  exit 2
fi

ack_success
log info handle_pause success '{}'
