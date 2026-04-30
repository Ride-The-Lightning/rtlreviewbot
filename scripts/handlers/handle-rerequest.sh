#!/usr/bin/env bash
#
# handle-rerequest.sh — invoked when the GitHub Re-request review button
# is clicked with rtlreviewbot as the requested reviewer (FR-2 trigger).
#
# Stub for M5: posts a comment letting the requester know the re-review
# pipeline is not wired up yet, and that they should re-run /rtl review
# in the meantime. Full implementation (rate-limit gate, prior-finding
# diff, status assignment) lands in a later milestone.

set -euo pipefail

readonly SCRIPT_NAME="${BASH_SOURCE[0]##*/}"

REPO=""; PR=""
while (( $# > 0 )); do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --pr)   PR="$2";   shift 2 ;;
    --actor|--bot-login|--args) shift 2 ;;
    *) shift ;;
  esac
done

printf '{"level":"info","script":"%s","event":"handle_rerequest","outcome":"not_implemented"}\n' \
  "$SCRIPT_NAME" >&2

if [[ -n "$REPO" && -n "$PR" ]]; then
  gh api -X POST "repos/${REPO}/issues/${PR}/comments" \
    -f "body=Re-request review noted, but the re-review flow is not yet implemented in this version of rtlreviewbot. As a workaround, a maintainer can run \`/rtl review\` again." \
    >/dev/null 2>&1 || true
fi

exit 0
