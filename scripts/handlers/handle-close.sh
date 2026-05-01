#!/usr/bin/env bash
#
# handle-close.sh — invoked when a PR is closed or merged.
#
# Two effects:
#   1. Strip rtl-active and rtl-paused labels (cleanup; the metadata marker
#      remains as the audit trail).
#   2. Append a terminal record to the marker — closed_at, merged — so the
#      marker reflects the PR's final state.
#
# Silent — no comment posted. The PR is already closed; nobody is watching
# the thread for new commentary, and adding a comment on close would just
# clutter the post-mortem.
#
# Idempotent: if the PR is not currently rtl-active/-paused, the label
# strips are no-ops; if the marker already has terminal fields, this run
# overwrites them with current values (the most recent close wins, which
# matters for reopened-then-closed PRs).

set -euo pipefail

readonly SCRIPT_NAME="${BASH_SOURCE[0]##*/}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; readonly SCRIPT_DIR
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)";              readonly REPO_ROOT

readonly RTL_ACTIVE="rtl-active"
readonly RTL_PAUSED="rtl-paused"

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

REPO=""; PR=""; BOT_LOGIN="${RTL_BOT_LOGIN:-rtlreview[bot]}"
while (( $# > 0 )); do
  case "$1" in
    --repo)         REPO="$2"; shift 2 ;;
    --pr)           PR="$2"; shift 2 ;;
    --bot-login)    BOT_LOGIN="$2"; shift 2 ;;
    --actor|--comment-id|--args) shift 2 ;;
    *) shift ;;
  esac
done

if [[ -z "$REPO" || -z "$PR" ]]; then
  log error parse_args failure '{"message":"missing --repo or --pr"}'
  exit 2
fi

# Loop prevention: if the PR was never rtl-active and has no marker, this
# is a close event for a PR the bot was never engaged with. Exit silently.
HAD_LABEL=false
HAD_PAUSED=false
if has_label "$REPO" "$PR" "$RTL_ACTIVE"; then HAD_LABEL=true; fi
if has_label "$REPO" "$PR" "$RTL_PAUSED"; then HAD_PAUSED=true; fi

if [[ "$HAD_LABEL" == "false" && "$HAD_PAUSED" == "false" ]]; then
  log info handle_close not_engaged "{}"
  exit 0
fi

log info handle_close attempt "$(jq -cn --arg r "$REPO" --arg p "$PR" '{repo:$r, pr:$p}')"

# 1. Strip labels.
[[ "$HAD_LABEL"  == "true" ]] && remove_label "$REPO" "$PR" "$RTL_ACTIVE" || true
[[ "$HAD_PAUSED" == "true" ]] && remove_label "$REPO" "$PR" "$RTL_PAUSED" || true

# 2. Append the terminal record to the marker, if a marker exists.
WORK="$(mktemp -d -t rtl-close.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

MARKER_FILE="$WORK/marker.json"
NEW_MARKER_FILE="$WORK/new_marker.json"

if "$REPO_ROOT/scripts/update-metadata.sh" \
     --repo "$REPO" --pr "$PR" --mode read --bot-login "$BOT_LOGIN" \
     >"$MARKER_FILE" 2>/dev/null && [[ "$(cat "$MARKER_FILE")" != "null" ]]; then

  # Re-fetch the PR object to get the merged flag accurately. We don't
  # want to trust whatever the workflow's event payload said.
  PR_FILE="$WORK/pr.json"
  MERGED="false"
  if gh api "repos/${REPO}/pulls/${PR}" >"$PR_FILE" 2>/dev/null; then
    MERGED="$(jq -r '.merged // false' "$PR_FILE")"
  fi

  NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  jq \
    --arg now "$NOW" \
    --argjson merged "$MERGED" \
    '
    .terminal = {
      closed_at: $now,
      merged:    $merged
    }
    ' "$MARKER_FILE" > "$NEW_MARKER_FILE"

  if "$REPO_ROOT/scripts/update-metadata.sh" \
       --repo "$REPO" --pr "$PR" --mode write --bot-login "$BOT_LOGIN" \
       <"$NEW_MARKER_FILE" >/dev/null 2>/dev/null; then
    log info handle_close marker_finalized "$(jq -cn --argjson m "$MERGED" --arg t "$NOW" '{merged:$m, closed_at:$t}')"
  else
    log warn handle_close marker_write_failed '{}'
    # Non-fatal: labels were already stripped, marker just lacks the
    # terminal record. Worst case the audit trail is incomplete.
  fi
else
  log info handle_close no_marker '{}'
fi

log info handle_close success "$(jq -cn --argjson l "$HAD_LABEL" --argjson p "$HAD_PAUSED" \
  '{stripped_active:$l, stripped_paused:$p}')"
