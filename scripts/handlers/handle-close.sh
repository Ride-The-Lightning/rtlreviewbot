#!/usr/bin/env bash
#
# handle-close.sh — invoked when a PR is closed or merged.
#
# Stub for M5: silent no-op. Future work (FR-cleanup) will remove the
# rtl-active / rtl-paused labels and finalize the metadata marker so
# the audit record reflects the PR's terminal state.

set -euo pipefail

readonly SCRIPT_NAME="${BASH_SOURCE[0]##*/}"

log() {
  printf '{"level":"info","script":"%s","event":"%s","outcome":"%s"}\n' \
    "$SCRIPT_NAME" "$1" "$2" >&2
}

# Accept the standard handler args; ignore them — this is a no-op.
while (( $# > 0 )); do
  case "$1" in
    --repo|--pr|--actor|--bot-login|--args) shift 2 ;;
    *) shift ;;
  esac
done

log handle_close not_implemented_no_op
exit 0
