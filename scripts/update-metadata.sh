#!/usr/bin/env bash
#
# update-metadata.sh — read or write the rtlreviewbot metadata marker
# comment on a PR.
#
# Usage:
#   read mode:
#     update-metadata.sh --repo <owner/repo> --pr <n> --mode read
#                        [--bot-login <login>]
#
#   write mode:
#     update-metadata.sh --repo <owner/repo> --pr <n> --mode write
#                        [--bot-login <login>] < state.json
#
# Defaults:
#   --bot-login   rtlreview[bot]
#
# Marker format:
#   The marker is one issue comment on the PR, authored by the rtlreviewbot
#   App, whose body is exactly:
#
#     <!-- rtlreviewbot-meta
#     {...state JSON...}
#     -->
#
# Output:
#   read mode (stdout):
#     - If a marker exists, the parsed state JSON (whatever the body
#       contained between the sentinels — caller validates schema).
#     - If no marker exists, the literal string `null`.
#   write mode (stdout):
#     {"comment_id": <int>, "created": <bool>}
#       created=true  — a new marker comment was POSTed
#       created=false — the existing marker was PATCHed in place
#
#   stderr: structured JSON log lines.
#
# Exit codes:
#   0  success
#   2  system error (bad inputs, gh API failure, malformed marker, invalid
#      stdin JSON in write mode)
#
# Invariants:
#   - There is at most one marker comment per PR. Write mode never POSTs
#     a second marker; if one exists, it is updated in place via PATCH.
#   - We identify our marker by BOTH the sentinel string in the body AND
#     the comment author. The author check is defense-in-depth: only the
#     App's installation token can post comments authored by the App, so
#     a marker we find with author == bot_login is provably ours.

set -euo pipefail

readonly SCRIPT_NAME="${BASH_SOURCE[0]##*/}"
readonly SENTINEL_OPEN="<!-- rtlreviewbot-meta"
readonly SENTINEL_CLOSE="-->"

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
MODE=""
BOT_LOGIN="${RTL_BOT_LOGIN:-rtlreview[bot]}"

while (( $# > 0 )); do
  case "$1" in
    --repo)
      [[ $# -ge 2 ]] || die "--repo requires a value" parse_args
      REPO="$2"; shift 2 ;;
    --pr)
      [[ $# -ge 2 ]] || die "--pr requires a value" parse_args
      PR="$2"; shift 2 ;;
    --mode)
      [[ $# -ge 2 ]] || die "--mode requires a value" parse_args
      MODE="$2"; shift 2 ;;
    --bot-login)
      [[ $# -ge 2 ]] || die "--bot-login requires a value" parse_args
      BOT_LOGIN="$2"; shift 2 ;;
    *)
      die "unknown argument: $1" parse_args ;;
  esac
done

[[ -z "$REPO" ]] && die "missing required --repo" parse_args
[[ -z "$PR"   ]] && die "missing required --pr"   parse_args
[[ -z "$MODE" ]] && die "missing required --mode" parse_args

if ! [[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  die "invalid --repo format: $REPO (expected owner/repo)" parse_args
fi
if ! [[ "$PR" =~ ^[0-9]+$ ]]; then
  die "invalid --pr: $PR (must be numeric)" parse_args
fi
case "$MODE" in
  read|write) ;;
  *) die "invalid --mode: $MODE (must be read|write)" parse_args ;;
esac

# ---------------------------------------------------------------------------
# Find the existing marker (if any)
# ---------------------------------------------------------------------------

WORK="$(mktemp -d -t rtl-meta.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

LIST_FILE="$WORK/comments.json"
ERR_FILE="$WORK/err"

log info list_comments attempt "$(jq -cn --arg r "$REPO" --arg p "$PR" '{repo:$r, pr:$p}')"

if ! gh api --paginate "repos/${REPO}/issues/${PR}/comments" \
      >"$LIST_FILE" 2>"$ERR_FILE"; then
  err="$(tr '\n' ' ' <"$ERR_FILE" 2>/dev/null || true)"
  die "gh api list comments failed: ${err:-unknown error}" list_comments
fi

# Find the first comment that is (a) authored by the bot and (b) carries
# the marker open sentinel in its body. `add // []` flattens slurped pages
# (each page is one JSON array) and tolerates the empty-list case.
EXISTING="$(jq -s \
  --arg sentinel "$SENTINEL_OPEN" \
  --arg author   "$BOT_LOGIN" \
  '
  (add // [])
  | map(select(
      (.body       | type == "string") and
      (.body       | contains($sentinel)) and
      (.user.login == $author)
    ))
  | .[0] // empty
  ' "$LIST_FILE")"

# extract_state — read a comment body on stdin, print the lines that lie
# strictly between the open and close sentinels (each must be at column 0).
# `s_open` / `s_close` rather than `open` / `close` to dodge BSD awk, which
# treats `close` as a reserved function name.
extract_state() {
  awk -v s_open="$SENTINEL_OPEN" -v s_close="$SENTINEL_CLOSE" '
    index($0, s_open) == 1            { in_m=1; next }
    in_m && index($0, s_close) == 1   { in_m=0; next }
    in_m                              { print }
  '
}

# ---------------------------------------------------------------------------
# Read mode
# ---------------------------------------------------------------------------

if [[ "$MODE" == "read" ]]; then
  if [[ -z "$EXISTING" ]]; then
    log info read_marker absent "{}"
    printf 'null\n'
    exit 0
  fi

  body="$(echo "$EXISTING" | jq -r '.body')"
  state_json="$(printf '%s\n' "$body" | extract_state)"

  if [[ -z "$state_json" ]]; then
    die "marker comment found but body is empty between sentinels" parse_marker
  fi
  if ! echo "$state_json" | jq empty 2>/dev/null; then
    die "marker comment body is not valid JSON" parse_marker
  fi

  comment_id="$(echo "$EXISTING" | jq -r '.id')"
  log info read_marker present "$(jq -cn --argjson id "$comment_id" '{comment_id:$id}')"

  # Compact to a single line for downstream consumers.
  echo "$state_json" | jq -c .
  exit 0
fi

# ---------------------------------------------------------------------------
# Write mode
# ---------------------------------------------------------------------------

NEW_STATE="$(cat)"

if [[ -z "$NEW_STATE" ]]; then
  die "write mode requires state JSON on stdin (got empty input)" read_stdin
fi
if ! echo "$NEW_STATE" | jq empty 2>/dev/null; then
  die "stdin is not valid JSON" read_stdin
fi

# Compose the new comment body. The state JSON is pretty-printed inside the
# marker so the raw comment is at least skimmable in the GitHub UI / API.
NEW_BODY_FILE="$WORK/new_body.txt"
{
  printf '%s\n' "$SENTINEL_OPEN"
  echo "$NEW_STATE" | jq .
  printf '%s\n' "$SENTINEL_CLOSE"
} > "$NEW_BODY_FILE"

POST_FILE="$WORK/post.json"

if [[ -n "$EXISTING" ]]; then
  COMMENT_ID="$(echo "$EXISTING" | jq -r '.id')"
  log info write_marker patch "$(jq -cn --argjson id "$COMMENT_ID" '{comment_id:$id}')"

  if ! gh api -X PATCH "repos/${REPO}/issues/comments/${COMMENT_ID}" \
        -F "body=@${NEW_BODY_FILE}" \
        >"$POST_FILE" 2>"$ERR_FILE"; then
    err="$(tr '\n' ' ' <"$ERR_FILE" 2>/dev/null || true)"
    die "gh api PATCH failed: ${err:-unknown error}" patch_marker
  fi

  jq -cn --argjson id "$COMMENT_ID" '{comment_id:$id, created:false}'
  exit 0
fi

log info write_marker post "{}"

if ! gh api -X POST "repos/${REPO}/issues/${PR}/comments" \
      -F "body=@${NEW_BODY_FILE}" \
      >"$POST_FILE" 2>"$ERR_FILE"; then
  err="$(tr '\n' ' ' <"$ERR_FILE" 2>/dev/null || true)"
  die "gh api POST failed: ${err:-unknown error}" post_marker
fi

NEW_ID="$(jq -er '.id' "$POST_FILE" 2>/dev/null)" \
  || die "POST response missing .id" parse_response

jq -cn --argjson id "$NEW_ID" '{comment_id:$id, created:true}'
