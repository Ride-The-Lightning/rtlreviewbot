#!/usr/bin/env bash
#
# handle-resume.sh — handler for /rtl resume.
#
# Stub for M5: posts a "not yet implemented" comment so the user gets
# feedback. Full implementation (remove rtl-active/rtl-paused labels,
# finalize the marker) lands in a later milestone.

set -euo pipefail

readonly SCRIPT_NAME="${BASH_SOURCE[0]##*/}"
readonly CMD="resume"

REPO=""; PR=""
while (( $# > 0 )); do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --pr)   PR="$2";   shift 2 ;;
    --actor|--bot-login|--args) shift 2 ;;
    *) shift ;;
  esac
done

printf '{"level":"info","script":"%s","event":"handle_%s","outcome":"not_implemented"}\n' \
  "$SCRIPT_NAME" "$CMD" >&2

if [[ -n "$REPO" && -n "$PR" ]]; then
  gh api -X POST "repos/${REPO}/issues/${PR}/comments" \
    -f "body=\`/rtl ${CMD}\` is recognized but not yet implemented in this version of rtlreviewbot. The command surface is documented in [docs/commands.md](https://github.com/Ride-The-Lightning/rtlreviewbot/blob/main/docs/commands.md)." \
    >/dev/null 2>&1 || true
fi

exit 0
