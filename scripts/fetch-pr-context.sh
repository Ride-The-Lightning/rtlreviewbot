#!/usr/bin/env bash
#
# fetch-pr-context.sh — gather everything the /code-review skill needs about
# a PR, in one structured JSON blob on stdout.
#
# Usage:
#   fetch-pr-context.sh --repo <owner/repo> --pr <number>
#                       [--bot-login <login>]
#                       [--max-diff-chars <n>]
#
# Defaults:
#   --bot-login        rtlreview[bot]   (the rtlreviewbot App's bot user)
#   --max-diff-chars   300000           (overridable via $RTL_MAX_DIFF_CHARS)
#
# Output (stdout, single JSON object):
#   {
#     "pr": {
#       "number", "title", "body", "state", "author",
#       "base_sha", "head_sha", "base_ref", "head_ref", "draft"
#     },
#     "diff": {
#       "text":        <raw unified diff, possibly truncated>,
#       "char_count":  <length of original diff in bytes>,
#       "truncated":   <bool — true iff char_count > max_chars>,
#       "max_chars":   <threshold used>
#     },
#     "files":           [{"path","additions","deletions","status"}, ...],
#     "comments":        [{"id","user","body","created_at"}, ...],
#                          # issue comments on the PR (general discussion),
#                          # bot's own comments excluded
#     "review_comments": [{"id","user","body","path","line",
#                          "in_reply_to_id","created_at"}, ...],
#                          # inline (file/line-anchored) review comments,
#                          # bot's own comments excluded
#     "reviews":         [{"id","user","body","state","submitted_at"}, ...]
#                          # formal reviews, bot's own excluded
#   }
#
# Exit codes:
#   0  success
#   2  system error (bad inputs, gh API failure)
#
# Notes:
#   - Diff is fetched with `Accept: application/vnd.github.diff` and is the
#     raw unified diff (not JSON). Truncation is by byte count, applied
#     after fetch — the caller sees the original char_count even when the
#     text is truncated, so it can decide to chunk or skip.
#   - "Filtering out the bot" is client-side; GitHub does not filter
#     comments by author server-side. We compare user.login to --bot-login.
#   - All list endpoints are paginated. We collect all pages before
#     emitting output.

set -euo pipefail

readonly SCRIPT_NAME="${BASH_SOURCE[0]##*/}"

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
BOT_LOGIN="${RTL_BOT_LOGIN:-rtlreview[bot]}"
MAX_DIFF_CHARS="${RTL_MAX_DIFF_CHARS:-300000}"

while (( $# > 0 )); do
  case "$1" in
    --repo)
      [[ $# -ge 2 ]] || die "--repo requires a value" parse_args
      REPO="$2"; shift 2 ;;
    --pr)
      [[ $# -ge 2 ]] || die "--pr requires a value" parse_args
      PR="$2"; shift 2 ;;
    --bot-login)
      [[ $# -ge 2 ]] || die "--bot-login requires a value" parse_args
      BOT_LOGIN="$2"; shift 2 ;;
    --max-diff-chars)
      [[ $# -ge 2 ]] || die "--max-diff-chars requires a value" parse_args
      MAX_DIFF_CHARS="$2"; shift 2 ;;
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
if ! [[ "$MAX_DIFF_CHARS" =~ ^[0-9]+$ ]]; then
  die "invalid --max-diff-chars: $MAX_DIFF_CHARS (must be numeric)" parse_args
fi

# ---------------------------------------------------------------------------
# Workspace
# ---------------------------------------------------------------------------

WORK="$(mktemp -d -t rtl-fetch.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

PR_FILE="$WORK/pr.json"
DIFF_FILE="$WORK/diff.txt"
FILES_FILE="$WORK/files.json"
COMMENTS_FILE="$WORK/comments.json"
REVIEW_COMMENTS_FILE="$WORK/review_comments.json"
REVIEWS_FILE="$WORK/reviews.json"
ERR_FILE="$WORK/err"

# fetch <label> <out-file> <api-path> [extra gh-api args...]
fetch() {
  local label="$1" out="$2" path="$3"
  shift 3
  log info fetch attempt "$(jq -cn --arg l "$label" --arg p "$path" '{step:$l, path:$p}')"
  if ! gh api "$@" "$path" > "$out" 2>"$ERR_FILE"; then
    local err
    err="$(tr '\n' ' ' <"$ERR_FILE" 2>/dev/null || true)"
    die "fetch ${label} failed: ${err:-unknown error}" "fetch_${label}"
  fi
}

# ---------------------------------------------------------------------------
# Fetches
# ---------------------------------------------------------------------------

fetch pr               "$PR_FILE"               "repos/${REPO}/pulls/${PR}"
fetch diff             "$DIFF_FILE"             "repos/${REPO}/pulls/${PR}" \
                                                -H "Accept: application/vnd.github.diff"
fetch files            "$FILES_FILE"            "repos/${REPO}/pulls/${PR}/files"            --paginate
fetch comments         "$COMMENTS_FILE"         "repos/${REPO}/issues/${PR}/comments"        --paginate
fetch review_comments  "$REVIEW_COMMENTS_FILE"  "repos/${REPO}/pulls/${PR}/comments"         --paginate
fetch reviews          "$REVIEWS_FILE"          "repos/${REPO}/pulls/${PR}/reviews"          --paginate

# ---------------------------------------------------------------------------
# Truncation
# ---------------------------------------------------------------------------

DIFF_CHARS="$(wc -c <"$DIFF_FILE" | tr -d ' ')"
TRUNCATED="false"
if (( DIFF_CHARS > MAX_DIFF_CHARS )); then
  head -c "$MAX_DIFF_CHARS" "$DIFF_FILE" > "$WORK/diff.trunc.txt"
  mv "$WORK/diff.trunc.txt" "$DIFF_FILE"
  TRUNCATED="true"
  log warn diff_truncated applied "$(jq -cn \
    --argjson c "$DIFF_CHARS" --argjson m "$MAX_DIFF_CHARS" \
    '{char_count:$c, max_chars:$m}')"
fi

# ---------------------------------------------------------------------------
# Assemble final JSON
#
# --slurpfile reads paginated arrays as an array-of-arrays; we flatten
# them with `add // []` (more lenient than `flatten`, handles empty file).
# --rawfile reads the diff verbatim into a JSON string.
# ---------------------------------------------------------------------------

log info assemble attempt "{}"

jq -n \
  --slurpfile pr_arr               "$PR_FILE" \
  --rawfile   diff_text            "$DIFF_FILE" \
  --argjson   char_count           "$DIFF_CHARS" \
  --argjson   truncated            "$TRUNCATED" \
  --argjson   max_chars            "$MAX_DIFF_CHARS" \
  --slurpfile files_pages          "$FILES_FILE" \
  --slurpfile comments_pages       "$COMMENTS_FILE" \
  --slurpfile review_comments_pages "$REVIEW_COMMENTS_FILE" \
  --slurpfile reviews_pages        "$REVIEWS_FILE" \
  --arg       bot                  "$BOT_LOGIN" \
  '
  ($pr_arr[0])                                            as $p |
  ($files_pages           | add // [])                    as $files |
  ($comments_pages        | add // [])                    as $comments |
  ($review_comments_pages | add // [])                    as $rcomments |
  ($reviews_pages         | add // [])                    as $reviews |
  {
    pr: {
      number:   $p.number,
      title:    $p.title,
      body:     $p.body,
      state:    $p.state,
      author:   $p.user.login,
      base_sha: $p.base.sha,
      head_sha: $p.head.sha,
      base_ref: $p.base.ref,
      head_ref: $p.head.ref,
      draft:    ($p.draft // false)
    },
    diff: {
      text:       $diff_text,
      char_count: $char_count,
      truncated:  $truncated,
      max_chars:  $max_chars
    },
    files: ($files | map({
      path:      .filename,
      additions: .additions,
      deletions: .deletions,
      status:    .status
    })),
    comments: ($comments
      | map(select(.user.login != $bot))
      | map({id, user: .user.login, body, created_at})),
    review_comments: ($rcomments
      | map(select(.user.login != $bot))
      | map({id, user: .user.login, body, path, line, in_reply_to_id, created_at})),
    reviews: ($reviews
      | map(select(.user.login != $bot))
      | map({id, user: .user.login, body, state, submitted_at}))
  }
  '
