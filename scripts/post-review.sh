#!/usr/bin/env bash
#
# post-review.sh — submit a formal PR review to GitHub.
#
# Usage:
#   post-review.sh --repo <owner/repo> --pr <n> --context-file <path>
#                  [--commit-sha <sha>] [--bot-login <login>]
#                  < review.json
#
#   stdin       parsed review JSON (output of parse-review-output.sh)
#   --context-file  path to fetch-pr-context.sh output (used for inline-anchor
#                   validation against the actual diff files)
#   --commit-sha    optional; defaults to context.pr.head_sha
#
# Behavior:
#   - Maps verdict ("REQUEST_CHANGES" | "COMMENT") to GitHub's review event.
#   - For each finding, attempts to post as an inline review comment anchored
#     to (path, line). Findings whose path is not in the diff (or whose file
#     was deleted) are *demoted* to a "Could not anchor" appendix in the
#     review body — preserves information without breaking the API call.
#   - Falls back once: if the POST fails (e.g. a line number Claude
#     hallucinated isn't in the diff), retries with all findings in the body
#     and no inline comments. If that also fails, exits 2.
#
# Output (stdout, single-line JSON):
#   {"review_id": <int>, "review_url": "...", "inline_count": <int>,
#    "demoted_count": <int>, "fallback": <bool>}
#
# Exit codes:
#   0  review posted
#   2  system error (bad input, both POSTs failed, malformed response)

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
# Args
# ---------------------------------------------------------------------------

REPO=""
PR=""
CTX_FILE=""
COMMIT_SHA=""

while (( $# > 0 )); do
  case "$1" in
    --repo)         REPO="$2"; shift 2 ;;
    --pr)           PR="$2"; shift 2 ;;
    --context-file) CTX_FILE="$2"; shift 2 ;;
    --commit-sha)   COMMIT_SHA="$2"; shift 2 ;;
    *) die "unknown argument: $1" parse_args ;;
  esac
done

[[ -z "$REPO"     ]] && die "missing required --repo" parse_args
[[ -z "$PR"       ]] && die "missing required --pr" parse_args
[[ -z "$CTX_FILE" ]] && die "missing required --context-file" parse_args
[[ -f "$CTX_FILE" ]] || die "context file not found: $CTX_FILE" parse_args

if ! [[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  die "invalid --repo format: $REPO" parse_args
fi
if ! [[ "$PR" =~ ^[0-9]+$ ]]; then
  die "invalid --pr: $PR" parse_args
fi

REVIEW="$(cat)"
if ! echo "$REVIEW" | jq empty 2>/dev/null; then
  die "stdin is not valid JSON" parse_review
fi

VERDICT="$(echo "$REVIEW" | jq -r '.verdict')"
case "$VERDICT" in
  REQUEST_CHANGES|COMMENT) ;;
  *) die "review verdict invalid or missing: $VERDICT" parse_review ;;
esac

if [[ -z "$COMMIT_SHA" ]]; then
  COMMIT_SHA="$(jq -r '.pr.head_sha' "$CTX_FILE")"
  [[ -z "$COMMIT_SHA" || "$COMMIT_SHA" == "null" ]] \
    && die "context file missing .pr.head_sha and --commit-sha not provided" parse_args
fi

WORK="$(mktemp -d -t rtl-post.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# Build the set of findings to post.
#
# Effective findings = top-level .findings (initial-review)
#                    + .new_findings           (re-review, new ones)
#                    + .prior_findings filtered to {unresolved, partially_addressed}
#
# .prior_findings with status in {addressed, withdrawn} are reported in the
# review body's "Status of prior findings" appendix instead.
# ---------------------------------------------------------------------------

EFFECTIVE="$(echo "$REVIEW" | jq -c '
  ( .findings // [] )
  + ( .new_findings // [] )
  + ( (.prior_findings // [])
      | map(select(.status == "unresolved" or .status == "partially_addressed")) )
')"

PRIOR_STATUS="$(echo "$REVIEW" | jq -c '
  ( .prior_findings // [] )
  | map(select(.status == "addressed" or .status == "withdrawn"))
')"

# ---------------------------------------------------------------------------
# Anchor validation. A finding can be inline iff its .path matches a file in
# the diff whose status is not "removed". Line-level validity is left to the
# GitHub API; if it rejects, we fall back to body-only.
# ---------------------------------------------------------------------------

ANCHORED="$(jq -nc \
  --argjson eff "$EFFECTIVE" \
  --slurpfile ctx "$CTX_FILE" \
  '
  ( $ctx[0].files
    | map(select(.status != "removed"))
    | map(.path)
  ) as $valid_paths
  |
  $eff
  | map(. as $f
        | $f + {
            _anchored: ( $f.path != null
                         and $f.line != null
                         and ($valid_paths | index($f.path) != null) )
          })
  ')"

INLINE="$(echo "$ANCHORED" | jq -c 'map(select(._anchored)) | map(del(._anchored))')"
DEMOTED="$(echo "$ANCHORED" | jq -c 'map(select(._anchored | not)) | map(del(._anchored))')"

INLINE_COUNT="$(echo "$INLINE"  | jq 'length')"
DEMOTED_COUNT="$(echo "$DEMOTED" | jq 'length')"

# ---------------------------------------------------------------------------
# Compose the review body. The summary always leads. Demoted findings and
# the prior-status appendix follow when present.
# ---------------------------------------------------------------------------

SUMMARY="$(echo "$REVIEW" | jq -r '.summary')"

format_finding_line() {
  echo "$1" | jq -r '
    "- **\(.id)** "
    + (if .severity then "(\(.severity)) " else "" end)
    + (if .path     then "`\(.path)" + (if .line then ":\(.line)" else "" end) + "` — " else "" end)
    + ( .body
        | gsub("\\s+"; " ")
        | if length > 280 then .[0:277] + "..." else . end )
  '
}

BODY_FILE="$WORK/body.md"
{
  printf '%s\n' "$SUMMARY"

  if (( DEMOTED_COUNT > 0 )); then
    printf '\n---\n\n### Findings (could not anchor inline)\n\n'
    echo "$DEMOTED" | jq -c '.[]' | while IFS= read -r f; do
      format_finding_line "$f"
    done
  fi

  prior_count="$(echo "$PRIOR_STATUS" | jq 'length')"
  if (( prior_count > 0 )); then
    printf '\n---\n\n### Status of prior findings\n\n'
    echo "$PRIOR_STATUS" | jq -c '.[]' | while IFS= read -r f; do
      echo "$f" | jq -r '"- **\(.id)** \(.status): \(.body)"'
    done
  fi
} > "$BODY_FILE"

BODY_TEXT="$(cat "$BODY_FILE")"

# ---------------------------------------------------------------------------
# Compose the review API payload.
#
# Inline comment body format: "<emoji> **Fn (severity):** <body>" so the
# finding id and severity are visible at a glance in the GitHub UI.
# Severity emoji: 🔴 blocker, 🟠 major, 🟡 minor, 🔵 nit. The emoji is
# pure visual decoration; the textual severity word is still authoritative
# for any programmatic consumer (and the comment-ID lookup below tolerates
# the optional prefix).
# ---------------------------------------------------------------------------

inline_comments_json() {
  echo "$INLINE" | jq -c '
    map({
      path: .path,
      line: (.line | tonumber),
      side: "RIGHT",
      body: (
        ( if   .severity == "blocker" then "🔴 "
          elif .severity == "major"   then "🟠 "
          elif .severity == "minor"   then "🟡 "
          elif .severity == "nit"     then "🔵 "
          else "" end )
        + "**\(.id)"
        + (if .severity then " (\(.severity))" else "" end)
        + (if .status   then " — \(.status)" else "" end)
        + ":** \(.body)"
      )
    })
  '
}

build_payload() {
  local include_inline="$1"
  local comments
  if [[ "$include_inline" == "true" ]]; then
    comments="$(inline_comments_json)"
  else
    comments='[]'
  fi
  jq -n \
    --arg     commit_id "$COMMIT_SHA" \
    --arg     body      "$BODY_TEXT" \
    --arg     event     "$VERDICT" \
    --argjson comments  "$comments" \
    '{commit_id: $commit_id, body: $body, event: $event, comments: $comments}'
}

# ---------------------------------------------------------------------------
# POST the review. Retry once with body-only on failure (catches the case
# where Claude cited a line that does not exist in the diff and the API
# refuses the whole payload).
# ---------------------------------------------------------------------------

POST_FILE="$WORK/post.json"
ERR_FILE="$WORK/err"

post_attempt() {
  local include_inline="$1"
  build_payload "$include_inline" > "$WORK/payload.json"
  log info post_review attempt "$(jq -cn \
    --arg ev "$VERDICT" --argjson inline "$INLINE_COUNT" --arg mode "$include_inline" \
    '{verdict:$ev, inline_count:$inline, mode:$mode}')"
  gh api -X POST \
    -H "Accept: application/vnd.github+json" \
    --input "$WORK/payload.json" \
    "repos/${REPO}/pulls/${PR}/reviews" \
    >"$POST_FILE" 2>"$ERR_FILE"
}

FALLBACK="false"
if ! post_attempt true; then
  err="$(tr '\n' ' ' <"$ERR_FILE" 2>/dev/null || true)"
  log warn post_review fallback_to_body "$(jq -cn --arg e "$err" '{first_error:$e}')"
  FALLBACK="true"

  # Re-render the body with EVERY finding demoted, since none will be inline.
  ALL_FOR_BODY="$(echo "$ANCHORED" | jq -c 'map(del(._anchored))')"
  {
    printf '%s\n' "$SUMMARY"

    if (( $(echo "$ALL_FOR_BODY" | jq 'length') > 0 )); then
      printf '\n---\n\n### Findings\n\n'
      echo "$ALL_FOR_BODY" | jq -c '.[]' | while IFS= read -r f; do
        format_finding_line "$f"
      done
    fi

    prior_count="$(echo "$PRIOR_STATUS" | jq 'length')"
    if (( prior_count > 0 )); then
      printf '\n---\n\n### Status of prior findings\n\n'
      echo "$PRIOR_STATUS" | jq -c '.[]' | while IFS= read -r f; do
        echo "$f" | jq -r '"- **\(.id)** \(.status): \(.body)"'
      done
    fi
  } > "$BODY_FILE"
  BODY_TEXT="$(cat "$BODY_FILE")"
  INLINE_COUNT=0
  DEMOTED_COUNT="$(echo "$ALL_FOR_BODY" | jq 'length')"

  if ! post_attempt false; then
    err="$(tr '\n' ' ' <"$ERR_FILE" 2>/dev/null || true)"
    die "review POST failed even after fallback: ${err:-unknown}" post_review
  fi
fi

REVIEW_ID="$(jq -er '.id'       "$POST_FILE" 2>/dev/null)" \
  || die "review response missing .id"       parse_response
REVIEW_URL="$(jq -er '.html_url' "$POST_FILE" 2>/dev/null)" \
  || die "review response missing .html_url" parse_response

# ---------------------------------------------------------------------------
# Look up the inline comment IDs the API assigned. The POST /reviews
# response does not include the comments array; we have to GET them in a
# follow-up call. We then build a map { "F1": <comment_id>, ... } by
# parsing each comment's body — our format `**F<n> (severity)...` (with
# an optional emoji prefix added in v0.8.1) makes this unambiguous.
# Findings that were demoted to the body get no entry.
#
# If this lookup fails, downstream consumers (handle-review.sh writing
# the marker) just see an empty map and store inline_comment_id=null per
# finding. The review itself is already posted; we never roll that back
# on a follow-up failure.
# ---------------------------------------------------------------------------

FINDING_COMMENT_IDS='{}'
COMMENTS_FILE="$WORK/review_comments.json"

if (( INLINE_COUNT > 0 )); then
  if gh api --paginate \
       "repos/${REPO}/pulls/${PR}/reviews/${REVIEW_ID}/comments" \
       >"$COMMENTS_FILE" 2>"$ERR_FILE"; then
    # Guard against the response being something other than an array of
    # comments — e.g. a stub returning the review object, or a paginated
    # empty result. The `if type == "array"` keeps `map()` from blowing up.
    parsed_map="$(jq -s '
      (add // [])
      | (if type == "array" then . else [] end)
      | map(select((.body? // "") | test("\\*\\*F[0-9]+")))
      | map({
          key:   (.body | capture("\\*\\*(?<id>F[0-9]+)") | .id),
          value: .id
        })
      | from_entries
    ' "$COMMENTS_FILE" 2>/dev/null)" || parsed_map=""
    if [[ -n "$parsed_map" ]]; then
      FINDING_COMMENT_IDS="$parsed_map"
    fi
  else
    err="$(tr '\n' ' ' <"$ERR_FILE" 2>/dev/null || true)"
    log warn post_review comment_id_lookup_failed "$(jq -cn --arg e "$err" '{message:$e}')"
  fi
fi

jq -cn \
  --argjson id                   "$REVIEW_ID" \
  --arg     url                  "$REVIEW_URL" \
  --argjson inline               "$INLINE_COUNT" \
  --argjson demoted              "$DEMOTED_COUNT" \
  --argjson fallback             "$FALLBACK" \
  --argjson finding_comment_ids  "$FINDING_COMMENT_IDS" \
  '{
    review_id:           $id,
    review_url:          $url,
    inline_count:        $inline,
    demoted_count:       $demoted,
    fallback:            $fallback,
    finding_comment_ids: $finding_comment_ids
  }'

log info post_review success "$(jq -cn \
  --argjson id "$REVIEW_ID" \
  --argjson inline "$INLINE_COUNT" \
  --argjson demoted "$DEMOTED_COUNT" \
  --argjson cmap "$FINDING_COMMENT_IDS" \
  '{review_id:$id, inline_count:$inline, demoted_count:$demoted, comment_ids:($cmap|length)}')"
