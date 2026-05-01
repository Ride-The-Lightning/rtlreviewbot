# shellcheck shell=bash
#
# scripts/lib/labels.sh — PR label helpers, source-only.
#
# Sourced from a handler script:
#   . "$REPO_ROOT/scripts/lib/labels.sh"
#
# All functions take the (repo, pr) plus the label name. None of them log;
# the caller is responsible for structured logging at decision points.

# add_label <repo> <pr> <label>
#   POST /issues/{n}/labels. Idempotent — if the label is already applied,
#   GitHub returns the current set without error.
#   Returns 0 on success, non-zero on API failure.
add_label() {
  local repo="$1" pr="$2" label="$3"
  gh api -X POST "repos/${repo}/issues/${pr}/labels" \
    -f "labels[]=${label}" >/dev/null
}

# remove_label <repo> <pr> <label>
#   DELETE /issues/{n}/labels/{name}. Tolerates 404 (label not present)
#   and returns 0; that is the idempotent semantic we want for /rtl stop
#   and friends.
remove_label() {
  local repo="$1" pr="$2" label="$3"
  if ! gh api -X DELETE "repos/${repo}/issues/${pr}/labels/${label}" \
         >/dev/null 2>&1; then
    # Distinguish "label not present" (fine) from real failure. Re-query
    # the PR's current labels — if the label is absent, return 0.
    if ! has_label "$repo" "$pr" "$label"; then
      return 0
    fi
    return 1
  fi
}

# has_label <repo> <pr> <label>
#   Returns 0 if the PR carries <label>, non-zero otherwise.
#   We extract the label list with `gh --jq` (which does not accept --arg)
#   and pipe through a second jq invocation that does.
has_label() {
  local repo="$1" pr="$2" label="$3"
  gh api "repos/${repo}/pulls/${pr}" --jq '[.labels[].name]' 2>/dev/null \
    | jq -e --arg l "$label" 'index($l) != null' >/dev/null
}
