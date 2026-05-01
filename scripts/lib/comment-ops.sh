# shellcheck shell=bash
#
# scripts/lib/comment-ops.sh — comment manipulation helpers, source-only.
#
# Designed to be sourced from a handler script:
#   . "$REPO_ROOT/scripts/lib/comment-ops.sh"
#
# Conventions:
#   - All functions log nothing themselves; the caller is responsible for
#     structured logging at decision points.
#   - GitHub API failures are signalled via non-zero exit code. Functions
#     that produce a value echo it on stdout on success.
#   - All gh calls inherit the caller's GH_TOKEN.

# post_comment <repo> <pr> <body>
#   POST a new issue comment on the PR. Echoes the new comment id on stdout.
#   Returns 0 on success, non-zero on API failure.
post_comment() {
  local repo="$1" pr="$2" body="$3"
  gh api -X POST "repos/${repo}/issues/${pr}/comments" \
    -f "body=${body}" --jq '.id'
}

# edit_comment <repo> <comment_id> <body>
#   PATCH an existing issue comment by id. Returns 0 on success.
edit_comment() {
  local repo="$1" comment_id="$2" body="$3"
  gh api -X PATCH "repos/${repo}/issues/comments/${comment_id}" \
    -f "body=${body}" >/dev/null
}

# react_to_comment <repo> <comment_id> <content>
#   Add a reaction to an issue comment. <content> is one of GitHub's reaction
#   types: "+1", "-1", "laugh", "confused", "heart", "hooray", "rocket", "eyes".
#   Returns 0 on success.
react_to_comment() {
  local repo="$1" comment_id="$2" content="$3"
  gh api -X POST \
    -H "Accept: application/vnd.github+json" \
    "repos/${repo}/issues/comments/${comment_id}/reactions" \
    -f "content=${content}" >/dev/null
}

# reply_to_review_comment <repo> <pr> <in_reply_to_id> <body>
#   POST a reply on an inline (review-comment) thread. Different endpoint
#   from issue comments. Echoes the new comment id on stdout.
reply_to_review_comment() {
  local repo="$1" pr="$2" in_reply_to_id="$3" body="$4"
  gh api -X POST \
    -H "Accept: application/vnd.github+json" \
    "repos/${repo}/pulls/${pr}/comments" \
    -f "body=${body}" \
    -F "in_reply_to=${in_reply_to_id}" \
    --jq '.id'
}

# find_comment_by_marker <repo> <pr> <sentinel> <author>
#   List issue comments on a PR, return the id of the first one whose body
#   contains <sentinel> AND whose author matches <author>. Echoes the id, or
#   nothing if no match. Returns 0 either way.
find_comment_by_marker() {
  local repo="$1" pr="$2" sentinel="$3" author="$4"
  gh api --paginate "repos/${repo}/issues/${pr}/comments" \
    | jq -s --arg sentinel "$sentinel" --arg author "$author" '
        (add // [])
        | map(select(
            (.body       | type == "string") and
            (.body       | contains($sentinel)) and
            (.user.login == $author)
          ))
        | .[0].id // empty
      '
}
