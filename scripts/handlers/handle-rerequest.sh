#!/usr/bin/env bash
#
# handle-rerequest.sh — invoked when GitHub fires a `pull_request`
# `review_requested` event with the bot as the requested reviewer.
#
# In practice this event does not fire for our bot today: GitHub's
# `requested_reviewers` API silently rejects App accounts, so the bot
# is never in the reviewers sidebar where the Re-request review button
# lives. The reusable workflow listens for this event anyway as
# forward-compat (in case GitHub ever opens up App reviewers); this
# handler is the no-op landing spot if it does fire.
#
# Stub for M5: silent no-op. The canonical re-review trigger is the
# `/rtl re-review` comment command, handled by handle-re-review.sh
# (also a stub at present — wiring it up is the next natural milestone).

set -euo pipefail

readonly SCRIPT_NAME="${BASH_SOURCE[0]##*/}"

while (( $# > 0 )); do
  case "$1" in
    --repo|--pr|--actor|--bot-login|--args) shift 2 ;;
    *) shift ;;
  esac
done

printf '{"level":"info","script":"%s","event":"handle_rerequest","outcome":"no_op_event_unsupported_for_apps"}\n' \
  "$SCRIPT_NAME" >&2

exit 0
