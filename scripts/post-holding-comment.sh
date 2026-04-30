#!/usr/bin/env bash
#
# post-holding-comment.sh — post (or find) the "review starting" holding
# comment on a PR.
#
# This is the fast acknowledgement that runs within ~10s of a /rtl review
# invocation. The handler typically deletes or edits this comment once the
# formal review has been posted.
#
# Usage:
#   post-holding-comment.sh --repo <owner/repo> --pr <number> [--body <text>]
#
# Output:
#   stdout (one line of JSON):
#     {"comment_id":<int>,"html_url":"...","created":<bool>}
#       created=true   — we just posted it
#       created=false  — an existing rtl-holding comment was found and reused
#   stderr: structured JSON log lines.
#
# Exit codes:
#   0  success (comment posted or existing one reused)
#   2  system error (bad inputs, gh API failure)
#
# Idempotency:
#   Holding comments carry an HTML-comment marker (HOLDING_MARKER below). On
#   each invocation we list the PR's issue comments, look for a comment whose
#   body contains the marker, and reuse it if found. This keeps re-runs of a
#   workflow (or a hook re-firing) from stacking up "review starting" comments.
#
# Auth:
#   Inherits gh's auth context. Callers are expected to have set GH_TOKEN to
#   the App installation token (from authenticate.sh) before invoking.

set -euo pipefail

readonly SCRIPT_NAME="${BASH_SOURCE[0]##*/}"
readonly HOLDING_MARKER="<!-- rtl-holding -->"
readonly DEFAULT_BODY=$'\xf0\x9f\x91\x80 rtlreviewbot review starting…'

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

die() {
  local msg="$1" event="$2"
  log error "$event" failure "$(jq -cn --arg m "$msg" '{message:$m}')"
  exit 2
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

REPO=""
PR=""
BODY_TEXT="$DEFAULT_BODY"

while (( $# > 0 )); do
  case "$1" in
    --repo)
      [[ $# -ge 2 ]] || die "--repo requires a value" parse_args
      REPO="$2"; shift 2 ;;
    --pr)
      [[ $# -ge 2 ]] || die "--pr requires a value" parse_args
      PR="$2"; shift 2 ;;
    --body)
      [[ $# -ge 2 ]] || die "--body requires a value" parse_args
      BODY_TEXT="$2"; shift 2 ;;
    *)
      die "unknown argument: $1" parse_args ;;
  esac
done

[[ -z "$REPO" ]] && die "missing required --repo" parse_args
[[ -z "$PR"   ]] && die "missing required --pr"   parse_args

if ! [[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  die "invalid --repo format: $REPO (expected owner/repo)" parse_args
fi
if ! [[ "$PR" =~ ^[0-9]+$ ]]; then
  die "invalid --pr: $PR (must be numeric)" parse_args
fi

# Compose the body. The marker goes on its own leading line so it is invisible
# in the rendered comment but trivial to grep.
COMMENT_BODY="${HOLDING_MARKER}"$'\n'"${BODY_TEXT}"

# ---------------------------------------------------------------------------
# Look for an existing holding comment (idempotency)
# ---------------------------------------------------------------------------

LIST_FILE="$(mktemp -t rtl-holding-list.XXXXXX)"
ERR_FILE="$(mktemp -t rtl-holding-err.XXXXXX)"
POST_FILE="$(mktemp -t rtl-holding-post.XXXXXX)"
trap 'rm -f "$LIST_FILE" "$ERR_FILE" "$POST_FILE"' EXIT

log info list_comments attempt "$(jq -cn \
  --arg r "$REPO" --arg p "$PR" '{repo:$r, pr:$p}')"

if ! gh api --paginate "repos/${REPO}/issues/${PR}/comments" \
     >"$LIST_FILE" 2>"$ERR_FILE"; then
  err_excerpt="$(tr '\n' ' ' <"$ERR_FILE" 2>/dev/null || true)"
  die "gh api list comments failed: ${err_excerpt:-unknown error}" list_comments
fi

# `gh api --paginate` concatenates JSON arrays from multiple pages by emitting
# them back-to-back. Use `jq -s` to slurp and flatten.
EXISTING="$(jq -s --arg marker "$HOLDING_MARKER" '
  map(.[]?) | map(select(.body | type == "string" and contains($marker))) | .[0] // empty
' "$LIST_FILE")"

if [[ -n "$EXISTING" ]]; then
  ID="$(echo "$EXISTING" | jq -r '.id')"
  URL="$(echo "$EXISTING" | jq -r '.html_url')"
  log info post_holding reused "$(jq -cn \
    --arg r "$REPO" --arg p "$PR" --argjson id "$ID" \
    '{repo:$r, pr:$p, comment_id:$id}')"
  jq -cn --argjson id "$ID" --arg url "$URL" \
    '{comment_id:$id, html_url:$url, created:false}'
  exit 0
fi

# ---------------------------------------------------------------------------
# Post a new holding comment
# ---------------------------------------------------------------------------

log info post_holding attempt "$(jq -cn \
  --arg r "$REPO" --arg p "$PR" '{repo:$r, pr:$p}')"

if ! gh api -X POST "repos/${REPO}/issues/${PR}/comments" \
       -f body="$COMMENT_BODY" \
       >"$POST_FILE" 2>"$ERR_FILE"; then
  err_excerpt="$(tr '\n' ' ' <"$ERR_FILE" 2>/dev/null || true)"
  die "gh api post comment failed: ${err_excerpt:-unknown error}" post_holding
fi

ID="$(jq -er '.id' "$POST_FILE" 2>/dev/null)" \
  || die "response missing .id" parse_response
URL="$(jq -er '.html_url' "$POST_FILE" 2>/dev/null)" \
  || die "response missing .html_url" parse_response

jq -cn --argjson id "$ID" --arg url "$URL" \
  '{comment_id:$id, html_url:$url, created:true}'

log info post_holding success "$(jq -cn \
  --arg r "$REPO" --arg p "$PR" --argjson id "$ID" \
  '{repo:$r, pr:$p, comment_id:$id}')"
