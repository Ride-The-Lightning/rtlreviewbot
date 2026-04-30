#!/usr/bin/env bats
#
# Unit tests for scripts/parse-command.sh.
#
# parse-command.sh has no I/O dependencies — it reads stdin and writes stdout
# — so tests are pure: feed a body in, assert the JSON shape on stdout.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export REPO_ROOT
}

# Helper: pipe a body into the script and capture stdout.
parse() {
  local body="$1"
  printf '%s' "$body" | bash "$REPO_ROOT/scripts/parse-command.sh"
}

# Helper: pipe and capture, ignoring exit (caller checks $output / $status).
run_parse() {
  local body="$1"
  run bash -c "printf '%s' \"\$1\" | bash '$REPO_ROOT/scripts/parse-command.sh'" _ "$body"
}

# ---------------------------------------------------------------------------
# Happy paths — each known command
# ---------------------------------------------------------------------------

@test "review (no args) is recognized" {
  out="$(parse '/rtl review')"
  echo "$out" | jq -e '.command == "review"' >/dev/null
  echo "$out" | jq -e '.args == []' >/dev/null
}

@test "stop is recognized" {
  out="$(parse '/rtl stop')"
  echo "$out" | jq -e '.command == "stop"' >/dev/null
}

@test "pause is recognized" {
  out="$(parse '/rtl pause')"
  echo "$out" | jq -e '.command == "pause"' >/dev/null
}

@test "resume is recognized" {
  out="$(parse '/rtl resume')"
  echo "$out" | jq -e '.command == "resume"' >/dev/null
}

@test "re-review (with hyphen) is recognized" {
  out="$(parse '/rtl re-review')"
  echo "$out" | jq -e '.command == "re-review"' >/dev/null
  echo "$out" | jq -e '.args == []' >/dev/null
}

@test "dismiss with finding ID arg" {
  out="$(parse '/rtl dismiss F3')"
  echo "$out" | jq -e '.command == "dismiss"' >/dev/null
  echo "$out" | jq -e '.args == ["F3"]' >/dev/null
}

@test "explain with finding ID arg" {
  out="$(parse '/rtl explain F12')"
  echo "$out" | jq -e '.command == "explain"' >/dev/null
  echo "$out" | jq -e '.args == ["F12"]' >/dev/null
}

@test "extra args are passed through verbatim" {
  out="$(parse '/rtl explain F3 because reasons')"
  echo "$out" | jq -e '.command == "explain"' >/dev/null
  echo "$out" | jq -e '.args == ["F3","because","reasons"]' >/dev/null
}

# ---------------------------------------------------------------------------
# Unknown / non-commands
# ---------------------------------------------------------------------------

@test "empty body returns null command" {
  out="$(parse '')"
  echo "$out" | jq -e '.command == null' >/dev/null
}

@test "whitespace-only body returns null command" {
  out="$(parse '   '$'\n''   ')"
  echo "$out" | jq -e '.command == null' >/dev/null
}

@test "non-rtl text returns null command" {
  out="$(parse 'looks good to me!')"
  echo "$out" | jq -e '.command == null' >/dev/null
}

@test "unknown subcommand returns null command" {
  out="$(parse '/rtl frobnicate')"
  echo "$out" | jq -e '.command == null' >/dev/null
}

@test "/rtl with no subcommand returns null" {
  out="$(parse '/rtl')"
  echo "$out" | jq -e '.command == null' >/dev/null
}

@test "/rtl with only trailing whitespace returns null" {
  out="$(parse '/rtl   ')"
  echo "$out" | jq -e '.command == null' >/dev/null
}

@test "/rtlreview without space is NOT a command (no false-prefix match)" {
  out="$(parse '/rtlreview now')"
  echo "$out" | jq -e '.command == null' >/dev/null
}

@test "/rtlreviewbot review (legacy prefix) is NOT recognized as /rtl" {
  out="$(parse '/rtlreviewbot review')"
  echo "$out" | jq -e '.command == null' >/dev/null
}

# ---------------------------------------------------------------------------
# Position rules — strict start-of-line, no leading whitespace
# ---------------------------------------------------------------------------

@test "command mid-sentence is ignored" {
  out="$(parse 'please run /rtl review on this')"
  echo "$out" | jq -e '.command == null' >/dev/null
}

@test "command with leading whitespace is ignored (defends against quoted text)" {
  out="$(parse '  /rtl review')"
  echo "$out" | jq -e '.command == null' >/dev/null
}

@test "command in markdown blockquote is ignored" {
  out="$(parse '> /rtl review')"
  echo "$out" | jq -e '.command == null' >/dev/null
}

@test "command on a non-first line is recognized when it starts at column 0" {
  body=$'thanks for the review\n/rtl resume'
  out="$(parse "$body")"
  echo "$out" | jq -e '.command == "resume"' >/dev/null
}

# ---------------------------------------------------------------------------
# Whitespace handling
# ---------------------------------------------------------------------------

@test "trailing whitespace is stripped" {
  out="$(parse '/rtl review   ')"
  echo "$out" | jq -e '.command == "review"' >/dev/null
  echo "$out" | jq -e '.args == []' >/dev/null
}

@test "trailing CR (CRLF input) is stripped" {
  out="$(printf '/rtl review\r\n' | bash "$REPO_ROOT/scripts/parse-command.sh")"
  echo "$out" | jq -e '.command == "review"' >/dev/null
}

@test "multiple spaces between command and args collapse" {
  out="$(parse '/rtl   dismiss    F7')"
  echo "$out" | jq -e '.command == "dismiss"' >/dev/null
  echo "$out" | jq -e '.args == ["F7"]' >/dev/null
}

@test "tab as separator is accepted" {
  out="$(printf '/rtl\tdismiss\tF9' | bash "$REPO_ROOT/scripts/parse-command.sh")"
  echo "$out" | jq -e '.command == "dismiss"' >/dev/null
  echo "$out" | jq -e '.args == ["F9"]' >/dev/null
}

# ---------------------------------------------------------------------------
# First-wins semantics
# ---------------------------------------------------------------------------

@test "first command wins when multiple are present" {
  body=$'/rtl review\n/rtl stop'
  out="$(parse "$body")"
  echo "$out" | jq -e '.command == "review"' >/dev/null
}

@test "first KNOWN command wins, skipping prior unknown ones" {
  body=$'/rtl frobnicate\n/rtl pause'
  out="$(parse "$body")"
  echo "$out" | jq -e '.command == "pause"' >/dev/null
}

# ---------------------------------------------------------------------------
# Output shape
# ---------------------------------------------------------------------------

@test "output is single line of JSON (no command case)" {
  out="$(parse 'hello')"
  # exactly one line
  [ "$(printf '%s' "$out" | wc -l | tr -d ' ')" = "0" ]
  echo "$out" | jq -e '.' >/dev/null
}

@test "output is single line of JSON (recognized case)" {
  out="$(parse '/rtl review')"
  [ "$(printf '%s' "$out" | wc -l | tr -d ' ')" = "0" ]
  echo "$out" | jq -e '.' >/dev/null
}

@test "exit code is 0 even when no command is found" {
  run_parse 'no command here'
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Logging hygiene
# ---------------------------------------------------------------------------

@test "stderr lines are valid JSON" {
  run --separate-stderr bash -c "printf '/rtl review' | bash '$REPO_ROOT/scripts/parse-command.sh'"
  [ "$status" -eq 0 ]
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    echo "$line" | jq -e '.level and .script and .event and .outcome' >/dev/null
  done <<< "$stderr"
}
