#!/usr/bin/env bash
#
# fetch-pr-context.sh — gather everything the /code-review skill needs about
# a PR, in one structured JSON blob on stdout.
#
# Usage:
#   fetch-pr-context.sh --repo <owner/repo> --pr <number>
#                       [--bot-login <login>]
#                       [--max-diff-chars <n>]
#                       [--max-file-chars <n>]
#                       [--max-file-contents-chars <n>]
#                       [--max-readme-chars <n>]
#                       [--max-claude-md-chars <n>]
#                       [--max-contributing-chars <n>]
#
# Defaults:
#   --bot-login                 rtlreview[bot]   (the rtlreviewbot App's bot user)
#   --max-diff-chars            300000   ($RTL_MAX_DIFF_CHARS)
#   --max-file-chars             50000   ($RTL_MAX_FILE_CHARS)
#   --max-file-contents-chars   600000   ($RTL_MAX_FILE_CONTENTS_CHARS)
#   --max-readme-chars           20000   ($RTL_MAX_README_CHARS)
#   --max-claude-md-chars        20000   ($RTL_MAX_CLAUDE_MD_CHARS)
#   --max-contributing-chars     20000   ($RTL_MAX_CONTRIBUTING_CHARS)
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
#     "file_contents":   [{"path","text","char_count","truncated","binary",
#                          "skipped"}, ...],
#                          # post-change (HEAD SHA) contents of each non-removed
#                          # changed file. Order matches `files`. Possible states:
#                          #   text != null               -> content included
#                          #     (truncated:true means only first max_file_chars
#                          #      bytes are in text; char_count is the full size)
#                          #   text == null, binary:true  -> binary file, skipped
#                          #   text == null, skipped:"budget_exhausted"
#                          #                              -> total cap hit
#                          #   text == null, skipped:"fetch_failed"
#                          #                              -> API error (>1MB, etc.)
#     "readme":          {"text","char_count","truncated"} | null,
#                          # consumer repo's README at HEAD SHA, null if absent.
#     "claude_md":       {"text","char_count","truncated"} | null,
#                          # consumer repo's CLAUDE.md at HEAD SHA, null if absent.
#     "contributing_md": {"text","char_count","truncated"} | null,
#                          # consumer repo's CONTRIBUTING.md at HEAD SHA, null if absent.
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
MAX_FILE_CHARS="${RTL_MAX_FILE_CHARS:-50000}"
MAX_FILE_CONTENTS_CHARS="${RTL_MAX_FILE_CONTENTS_CHARS:-600000}"
MAX_README_CHARS="${RTL_MAX_README_CHARS:-20000}"
MAX_CLAUDE_MD_CHARS="${RTL_MAX_CLAUDE_MD_CHARS:-20000}"
MAX_CONTRIBUTING_CHARS="${RTL_MAX_CONTRIBUTING_CHARS:-20000}"

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
    --max-file-chars)
      [[ $# -ge 2 ]] || die "--max-file-chars requires a value" parse_args
      MAX_FILE_CHARS="$2"; shift 2 ;;
    --max-file-contents-chars)
      [[ $# -ge 2 ]] || die "--max-file-contents-chars requires a value" parse_args
      MAX_FILE_CONTENTS_CHARS="$2"; shift 2 ;;
    --max-readme-chars)
      [[ $# -ge 2 ]] || die "--max-readme-chars requires a value" parse_args
      MAX_README_CHARS="$2"; shift 2 ;;
    --max-claude-md-chars)
      [[ $# -ge 2 ]] || die "--max-claude-md-chars requires a value" parse_args
      MAX_CLAUDE_MD_CHARS="$2"; shift 2 ;;
    --max-contributing-chars)
      [[ $# -ge 2 ]] || die "--max-contributing-chars requires a value" parse_args
      MAX_CONTRIBUTING_CHARS="$2"; shift 2 ;;
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
for v in MAX_DIFF_CHARS MAX_FILE_CHARS MAX_FILE_CONTENTS_CHARS \
         MAX_README_CHARS MAX_CLAUDE_MD_CHARS MAX_CONTRIBUTING_CHARS; do
  if ! [[ "${!v}" =~ ^[0-9]+$ ]]; then
    die "invalid ${v}: ${!v} (must be numeric)" parse_args
  fi
done

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
FILE_CONTENTS_FILE="$WORK/file_contents.json"
README_FILE="$WORK/readme.json"
CLAUDE_MD_FILE="$WORK/claude_md.json"
CONTRIBUTING_FILE="$WORK/contributing.json"
ERR_FILE="$WORK/err"

# fetch <label> <out-file> <api-path> [extra gh-api args...]
# Dies on failure (used for required fetches).
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

# try_fetch <label> <out-file> <api-path> [extra gh-api args...]
# Returns 0 on success, 1 on any gh error (404, 403, etc.). Used for
# best-effort fetches where absence is normal (CLAUDE.md, README).
# On failure, the out file is truncated to empty so callers can use
# `[[ ! -s "$out" ]]` to detect absence uniformly.
try_fetch() {
  local label="$1" out="$2" path="$3"
  shift 3
  log info try_fetch attempt "$(jq -cn --arg l "$label" --arg p "$path" '{step:$l, path:$p}')"
  if gh api "$@" "$path" > "$out" 2>"$ERR_FILE"; then
    return 0
  fi
  : > "$out"
  log info try_fetch absent "$(jq -cn --arg l "$label" '{step:$l}')"
  return 1
}

# url_encode_path <path>
# URL-encodes each segment of a slash-delimited path, preserving slashes.
# GitHub's contents API requires this for paths with spaces or other
# special characters.
url_encode_path() {
  local p="$1"
  local IFS='/'
  local -a segs
  read -r -a segs <<< "$p"
  local out=""
  local seg first=1
  for seg in "${segs[@]}"; do
    if (( first )); then
      first=0
    else
      out="${out}/"
    fi
    out="${out}$(jq -rn --arg s "$seg" '$s | @uri')"
  done
  printf '%s' "$out"
}

# Portable base64 decode. macOS BSD and Linux coreutils both accept
# --decode, but tolerate -d as a fallback.
b64_decode() {
  base64 --decode 2>/dev/null || base64 -d
}

# is_binary <file>
# Returns 0 (true) if grep treats the file as binary. Grep's -I flag
# uses the standard "NUL byte in first chunk" heuristic that git also
# uses, so this is a portable substitute for `file --mime-encoding`.
is_binary() {
  ! LC_ALL=C grep -Iq . "$1" 2>/dev/null
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
# Pre-fetched file contents and project docs
#
# Fetched separately from the diff so the skill can reason about the
# surrounding code in each changed file, not just the hunks. See SKILL.md
# "Input contract" for the consumer-facing JSON shape.
# ---------------------------------------------------------------------------

HEAD_SHA="$(jq -r '.head.sha' "$PR_FILE")"
if [[ -z "$HEAD_SHA" || "$HEAD_SHA" == "null" ]]; then
  die "PR object missing head.sha" extract_head_sha
fi

echo '[]' > "$FILE_CONTENTS_FILE"
TOTAL_USED=0

append_file_entry() {
  jq --argjson e "$1" '. + [$e]' "$FILE_CONTENTS_FILE" > "$WORK/fc.tmp"
  mv "$WORK/fc.tmp" "$FILE_CONTENTS_FILE"
}

while IFS= read -r fileinfo; do
  fpath="$(jq -r '.filename' <<<"$fileinfo")"
  fstatus="$(jq -r '.status' <<<"$fileinfo")"

  # Deleted files have no content at HEAD — nothing to fetch.
  [[ "$fstatus" == "removed" ]] && continue

  # Budget exhausted: emit marker and continue (don't break — keep the
  # remaining files visible to the skill so it knows what was elided).
  if (( TOTAL_USED >= MAX_FILE_CONTENTS_CHARS )); then
    append_file_entry "$(jq -cn --arg p "$fpath" \
      '{path:$p, text:null, char_count:0, truncated:false, binary:false,
        skipped:"budget_exhausted"}')"
    continue
  fi

  encoded="$(url_encode_path "$fpath")"
  envelope="$WORK/_content_envelope.json"

  if ! try_fetch "content" "$envelope" \
       "repos/${REPO}/contents/${encoded}?ref=${HEAD_SHA}"; then
    append_file_entry "$(jq -cn --arg p "$fpath" \
      '{path:$p, text:null, char_count:0, truncated:false, binary:false,
        skipped:"fetch_failed"}')"
    continue
  fi

  decoded="$WORK/_content_decoded"
  : > "$decoded"
  jq -r '.content // ""' "$envelope" | tr -d '\n' | b64_decode > "$decoded" \
    2>/dev/null || true
  full_size="$(wc -c <"$decoded" | tr -d ' ')"

  if is_binary "$decoded"; then
    append_file_entry "$(jq -cn --arg p "$fpath" --argjson n "$full_size" \
      '{path:$p, text:null, char_count:$n, truncated:false, binary:true,
        skipped:null}')"
    continue
  fi

  remaining=$(( MAX_FILE_CONTENTS_CHARS - TOTAL_USED ))
  cap="$MAX_FILE_CHARS"
  (( remaining < cap )) && cap="$remaining"

  truncated_flag="false"
  take="$full_size"
  if (( full_size > cap )); then
    truncated_flag="true"
    take="$cap"
  fi

  text="$(head -c "$take" "$decoded")"
  TOTAL_USED=$(( TOTAL_USED + take ))

  append_file_entry "$(jq -cn \
    --arg p "$fpath" \
    --arg t "$text" \
    --argjson n "$full_size" \
    --argjson tr "$truncated_flag" \
    '{path:$p, text:$t, char_count:$n, truncated:$tr, binary:false,
      skipped:null}')"
done < <(jq -c '.[] | {filename, status}' "$FILES_FILE")

# README (resolves to whichever extension the repo uses), CLAUDE.md,
# CONTRIBUTING.md — each is a best-effort fetch. 404 → null in output.

build_doc_json() {
  local envelope="$1" max_chars="$2" out="$3"
  if [[ ! -s "$envelope" ]]; then
    printf 'null\n' > "$out"
    return
  fi
  local decoded="$WORK/_doc_decoded"
  : > "$decoded"
  jq -r '.content // ""' "$envelope" | tr -d '\n' | b64_decode > "$decoded" \
    2>/dev/null || true
  local size truncated_flag text
  size="$(wc -c <"$decoded" | tr -d ' ')"
  if (( size == 0 )); then
    printf 'null\n' > "$out"
    return
  fi
  truncated_flag="false"
  if (( size > max_chars )); then
    truncated_flag="true"
    text="$(head -c "$max_chars" "$decoded")"
  else
    text="$(cat "$decoded")"
  fi
  jq -n --arg t "$text" --argjson n "$size" --argjson tr "$truncated_flag" \
    '{text:$t, char_count:$n, truncated:$tr}' > "$out"
}

: > "$README_FILE"
: > "$CLAUDE_MD_FILE"
: > "$CONTRIBUTING_FILE"

try_fetch readme          "$README_FILE"       "repos/${REPO}/readme?ref=${HEAD_SHA}"             || true
try_fetch claude_md       "$CLAUDE_MD_FILE"    "repos/${REPO}/contents/CLAUDE.md?ref=${HEAD_SHA}" || true
try_fetch contributing_md "$CONTRIBUTING_FILE" "repos/${REPO}/contents/CONTRIBUTING.md?ref=${HEAD_SHA}" || true

README_DOC="$WORK/readme_doc.json"
CLAUDE_MD_DOC="$WORK/claude_md_doc.json"
CONTRIBUTING_DOC="$WORK/contributing_doc.json"

build_doc_json "$README_FILE"       "$MAX_README_CHARS"       "$README_DOC"
build_doc_json "$CLAUDE_MD_FILE"    "$MAX_CLAUDE_MD_CHARS"    "$CLAUDE_MD_DOC"
build_doc_json "$CONTRIBUTING_FILE" "$MAX_CONTRIBUTING_CHARS" "$CONTRIBUTING_DOC"

# ---------------------------------------------------------------------------
# Assemble final JSON
#
# --slurpfile reads paginated arrays as an array-of-arrays; we flatten
# them with `add // []` (more lenient than `flatten`, handles empty file).
# --rawfile reads the diff verbatim into a JSON string.
# ---------------------------------------------------------------------------

log info assemble attempt "{}"

jq -n \
  --slurpfile pr_arr                "$PR_FILE" \
  --rawfile   diff_text             "$DIFF_FILE" \
  --argjson   char_count            "$DIFF_CHARS" \
  --argjson   truncated             "$TRUNCATED" \
  --argjson   max_chars             "$MAX_DIFF_CHARS" \
  --slurpfile files_pages           "$FILES_FILE" \
  --slurpfile file_contents_arr     "$FILE_CONTENTS_FILE" \
  --slurpfile readme_doc            "$README_DOC" \
  --slurpfile claude_md_doc         "$CLAUDE_MD_DOC" \
  --slurpfile contributing_doc      "$CONTRIBUTING_DOC" \
  --slurpfile comments_pages        "$COMMENTS_FILE" \
  --slurpfile review_comments_pages "$REVIEW_COMMENTS_FILE" \
  --slurpfile reviews_pages         "$REVIEWS_FILE" \
  --arg       bot                   "$BOT_LOGIN" \
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
    file_contents:   $file_contents_arr[0],
    readme:          $readme_doc[0],
    claude_md:       $claude_md_doc[0],
    contributing_md: $contributing_doc[0],
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
