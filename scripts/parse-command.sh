#!/usr/bin/env bash
#
# parse-command.sh — extract a /rtl command from a PR comment body.
#
# Input:
#   stdin: raw comment body (may contain markdown, multiple lines, CRLF, etc.)
#
# Output:
#   stdout (one line of JSON): one of
#     {"command":"<name>","args":[...]}            — recognized command
#     {"command":null}                              — no command found
#   stderr: structured JSON log lines (one object per line)
#
# Exit codes:
#   0  always (parsing errors or "no command" are not failures — the caller
#      decides what to do based on stdout). Reserved exit 2 is unused here
#      because there is no I/O that can plausibly fail at this layer.
#
# Recognition rules:
#   - A command line starts at column 0 with the literal "/rtl" followed by
#     at least one whitespace character.
#   - Lines that do not start at column 0 (leading whitespace, blockquote
#     `> `, list markers) are ignored. This matches typical bot conventions
#     (e.g. Prow) and avoids triggering on quoted text.
#   - Trailing whitespace (including CR from CRLF) is stripped before match.
#   - Subcommand must be one of the known set; unknown subcommands resolve
#     to {"command":null} so we never act on a typo.
#   - If multiple recognized command lines appear, the first wins.

set -euo pipefail

readonly SCRIPT_NAME="${BASH_SOURCE[0]##*/}"

# Known subcommands. Keep aligned with docs/commands.md.
readonly KNOWN_COMMANDS=(
  review
  stop
  pause
  resume
  dismiss
  explain
  re-review
  approve
)

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

is_known_command() {
  local cmd="$1"
  local k
  for k in "${KNOWN_COMMANDS[@]}"; do
    [[ "$cmd" == "$k" ]] && return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
# Read the whole body. We intentionally read all of stdin before processing
# rather than streaming, because (a) PR comment bodies are bounded by GitHub
# (~65k chars) and (b) we want consistent behavior whether stdin is a pipe,
# file, or here-string.
# ---------------------------------------------------------------------------

BODY="$(cat)"

COMMAND=""
ARGS_JSON="[]"
LINE_NO=0
MATCH_LINE=0

while IFS= read -r line || [[ -n "$line" ]]; do
  LINE_NO=$((LINE_NO + 1))

  # Strip trailing whitespace (catches CRLF and stray spaces).
  while [[ "$line" =~ [[:space:]]$ ]]; do
    line="${line%[[:space:]]}"
  done

  # Must start at column 0 with "/rtl" + whitespace + non-empty subcommand.
  # The optional 3rd group captures the rest as a single string of args.
  if [[ "$line" =~ ^/rtl[[:space:]]+([^[:space:]]+)([[:space:]]+(.*))?$ ]]; then
    cmd="${BASH_REMATCH[1]}"
    args_rest="${BASH_REMATCH[3]:-}"

    if is_known_command "$cmd"; then
      COMMAND="$cmd"
      MATCH_LINE=$LINE_NO
      if [[ -n "$args_rest" ]]; then
        # Split args on whitespace into a JSON array of strings. `read -ra`
        # uses IFS (whitespace by default) and tolerates multiple spaces.
        read -ra args_arr <<< "$args_rest"
        if (( ${#args_arr[@]} > 0 )); then
          ARGS_JSON="$(printf '%s\n' "${args_arr[@]}" | jq -R . | jq -cs .)"
        fi
      fi
      break
    fi
  fi
done <<< "$BODY"

if [[ -z "$COMMAND" ]]; then
  log info parse_command no_command "$(jq -cn --argjson n "$LINE_NO" '{lines_scanned:$n}')"
  jq -cn '{command: null}'
else
  log info parse_command recognized "$(
    jq -cn \
      --arg c "$COMMAND" \
      --argjson n "$MATCH_LINE" \
      --argjson args "$ARGS_JSON" \
      '{command:$c, line:$n, arg_count:($args|length)}'
  )"
  jq -cn --arg cmd "$COMMAND" --argjson args "$ARGS_JSON" '{command:$cmd, args:$args}'
fi
