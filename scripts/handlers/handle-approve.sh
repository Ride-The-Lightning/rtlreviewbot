#!/usr/bin/env bash
#
# handle-approve.sh — handler for /rtl approve.
#
# Submits a formal APPROVE review on the PR if and only if the marker
# state passes three gates:
#   1. The marker exists (i.e. /rtl review has run at least once).
#   2. The PR head SHA equals marker.last_reviewed_sha (i.e. nothing
#      has landed since the bot last looked).
#   3. Every finding in marker.findings has status in {addressed,
#      withdrawn} OR is also in marker.dismissed_findings. Findings
#      with status unresolved or partially_addressed (and not dismissed)
#      block approval.
#
# Permission: enforced upstream by run-review.sh (maintainer only).
#
# Success UX:
#   - POST /pulls/{n}/reviews with event=APPROVE and a templated body
#     summarizing the disposition of every prior finding.
#   - 👍 reaction on the triggering comment.
#   - Marker patched with approved_by / approved_at audit fields.
# Error UX: visible comment on the PR explaining what is missing
# (no marker, SHA drift, open findings).

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

REPO=""; PR=""; ACTOR=""; COMMENT_ID=""; BOT_LOGIN="${RTL_BOT_LOGIN:-rtlreview[bot]}"
while (( $# > 0 )); do
  case "$1" in
    --repo)         REPO="$2"; shift 2 ;;
    --pr)           PR="$2"; shift 2 ;;
    --actor)        ACTOR="$2"; shift 2 ;;
    --comment-id)   COMMENT_ID="$2"; shift 2 ;;
    --bot-login)    BOT_LOGIN="$2"; shift 2 ;;
    --args)         shift 2 ;;  # /rtl approve takes no positional args
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
# Read the marker.
# ---------------------------------------------------------------------------

WORK="$(mktemp -d -t rtl-approve.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

MARKER_FILE="$WORK/marker.json"
NEW_MARKER_FILE="$WORK/new_marker.json"
PAYLOAD_FILE="$WORK/payload.json"
RESPONSE_FILE="$WORK/response.json"
ERR_FILE="$WORK/err"

log info handle_approve read_marker '{}'

if ! "$REPO_ROOT/scripts/update-metadata.sh" \
       --repo "$REPO" --pr "$PR" --mode read --bot-login "$BOT_LOGIN" \
       >"$MARKER_FILE" 2>/dev/null; then
  post_error "❌ \`/rtl approve\` could not read the metadata marker. See workflow logs."
  log error read_marker failure '{}'
  exit 2
fi

if [[ "$(cat "$MARKER_FILE")" == "null" ]]; then
  post_error "❌ Cannot approve: rtlreviewbot has not reviewed this PR yet. Run \`/rtl review\` first."
  log info handle_approve no_marker '{}'
  exit 0
fi

# ---------------------------------------------------------------------------
# Gate: head SHA must match marker.last_reviewed_sha.
# ---------------------------------------------------------------------------

LAST_REVIEWED_SHA="$(jq -r '.last_reviewed_sha // empty' "$MARKER_FILE")"

if [[ -z "$LAST_REVIEWED_SHA" ]]; then
  post_error "❌ Cannot approve: the metadata marker has no \`last_reviewed_sha\`. Run \`/rtl review\` to refresh it."
  log error head_sha_check missing_last_reviewed_sha '{}'
  exit 0
fi

HEAD_SHA="$(gh api "repos/${REPO}/pulls/${PR}" --jq '.head.sha' 2>"$ERR_FILE" || true)"
if [[ -z "$HEAD_SHA" ]]; then
  err="$(tr '\n' ' ' <"$ERR_FILE" 2>/dev/null || true)"
  post_error "❌ \`/rtl approve\` could not read the PR head SHA. See workflow logs."
  log error head_sha_check failure_fetching "$(jq -cn --arg e "$err" '{message:$e}')"
  exit 2
fi

if [[ "$LAST_REVIEWED_SHA" != "$HEAD_SHA" ]]; then
  post_error "❌ Cannot approve: the PR has new commits since the last review (last reviewed \`${LAST_REVIEWED_SHA:0:7}\`, current head \`${HEAD_SHA:0:7}\`).

Run \`/rtl re-review\` first to evaluate the new commits, then \`/rtl approve\`."
  log info handle_approve sha_mismatch "$(jq -cn \
    --arg last "$LAST_REVIEWED_SHA" --arg head "$HEAD_SHA" \
    '{last_reviewed_sha:$last, head_sha:$head}')"
  exit 0
fi

# ---------------------------------------------------------------------------
# Gate: every finding in .findings must be addressed/withdrawn or dismissed.
# Empty findings array is a valid state (initial review found nothing).
# ---------------------------------------------------------------------------

OPEN_FINDINGS_JSON="$(jq -c '
  . as $marker
  | ([$marker.dismissed_findings[]?.id]) as $dismissed_ids
  | [$marker.findings[]?
      | . as $f
      | (.status // "unresolved") as $s
      | select($s != "addressed" and $s != "withdrawn")
      | select($dismissed_ids | index($f.id) | not)
    ]
' "$MARKER_FILE")"

OPEN_COUNT="$(echo "$OPEN_FINDINGS_JSON" | jq 'length')"

if (( OPEN_COUNT > 0 )); then
  OPEN_LIST="$(echo "$OPEN_FINDINGS_JSON" | jq -r '
    map("- `\(.id)` (\(.severity // "unknown")) — \(.status // "unresolved")") | join("\n")
  ')"
  post_error "❌ Cannot approve: ${OPEN_COUNT} finding(s) still open.

${OPEN_LIST}

Address them and run \`/rtl re-review\` to refresh status, then \`/rtl approve\`."
  log info handle_approve findings_open "$(jq -cn --argjson n "$OPEN_COUNT" '{open_count:$n}')"
  exit 0
fi

# ---------------------------------------------------------------------------
# Compose the APPROVE body.
# ---------------------------------------------------------------------------

F_SECTION="$(jq -r '
  if (.findings // []) | length == 0 then ""
  else "**Findings:**\n" + ([.findings[]
    | "- `\(.id)` (\(.severity // "unknown")) — \(.status // "unresolved"): \(.body // "" | .[0:140])\(if (.body // "" | length) > 140 then "…" else "" end)"
  ] | join("\n")) end
' "$MARKER_FILE")"

D_SECTION="$(jq -r '
  if (.dismissed_findings // []) | length == 0 then ""
  else "**Dismissed:**\n" + ([.dismissed_findings[]
    | "- `\(.id)` by @\(.by) — \(.reason // "_no reason given_")"
  ] | join("\n")) end
' "$MARKER_FILE")"

if [[ -z "$F_SECTION" && -z "$D_SECTION" ]]; then
  RECAP="_No findings were raised on this PR._"
elif [[ -z "$D_SECTION" ]]; then
  RECAP="$F_SECTION"
elif [[ -z "$F_SECTION" ]]; then
  RECAP="$D_SECTION"
else
  RECAP="${F_SECTION}

${D_SECTION}"
fi

SKILL_VERSION="$(jq -r '.skill_version // "unknown"' "$MARKER_FILE")"
MODEL="$(jq -r '.model // "unknown"' "$MARKER_FILE")"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

BODY="✅ Approved — all prior findings addressed.

### Findings recap

${RECAP}

---
*Approved by @${ACTOR} via \`/rtl approve\`. Last reviewed at \`${LAST_REVIEWED_SHA:0:7}\`. Skill v${SKILL_VERSION}, model \`${MODEL}\`.*"

jq -n \
  --arg commit_id "$HEAD_SHA" \
  --arg body      "$BODY" \
  '{commit_id: $commit_id, body: $body, event: "APPROVE", comments: []}' \
  > "$PAYLOAD_FILE"

# ---------------------------------------------------------------------------
# Submit the APPROVE review.
# ---------------------------------------------------------------------------

log info handle_approve submit_review_attempt '{}'

if ! gh api -X POST \
        -H "Accept: application/vnd.github+json" \
        --input "$PAYLOAD_FILE" \
        "repos/${REPO}/pulls/${PR}/reviews" \
        >"$RESPONSE_FILE" 2>"$ERR_FILE"; then
  err="$(tr '\n' ' ' <"$ERR_FILE" 2>/dev/null || true)"
  post_error "❌ \`/rtl approve\` failed to submit the review. See workflow logs."
  log error submit_review failure "$(jq -cn --arg e "$err" '{message:$e}')"
  exit 2
fi

REVIEW_ID="$(jq -r '.id // empty' "$RESPONSE_FILE")"
REVIEW_URL="$(jq -r '.html_url // empty' "$RESPONSE_FILE")"

# ---------------------------------------------------------------------------
# Patch the marker with audit fields. Non-fatal if it fails — the APPROVE
# is already on GitHub; the marker is purely audit metadata.
# ---------------------------------------------------------------------------

jq \
  --arg by "$ACTOR" \
  --arg at "$NOW" \
  '. + {approved_by: $by, approved_at: $at}' \
  "$MARKER_FILE" > "$NEW_MARKER_FILE"

if ! "$REPO_ROOT/scripts/update-metadata.sh" \
       --repo "$REPO" --pr "$PR" --mode write --bot-login "$BOT_LOGIN" \
       <"$NEW_MARKER_FILE" >/dev/null 2>/dev/null; then
  log warn update_marker failure '{}'
fi

ack_success
log info handle_approve success "$(jq -cn \
  --arg actor "$ACTOR" --arg id "$REVIEW_ID" --arg url "$REVIEW_URL" \
  '{actor:$actor, review_id:$id, review_url:$url}')"
