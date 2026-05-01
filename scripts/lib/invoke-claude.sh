# shellcheck shell=bash
#
# scripts/lib/invoke-claude.sh — auth-fallback wrapper around the Claude
# Code CLI. Source-only.
#
# Sourced from a handler:
#   . "$REPO_ROOT/scripts/lib/invoke-claude.sh"
#
# Public functions:
#   invoke_claude_for_review <prompt-file> <output-file> <parsed-output-file> <error-file>
#       For handlers that produce a structured review (handle-review,
#       handle-re-review). Success requires both:
#         - claude exits 0
#         - parse-review-output.sh accepts the output
#       Returns 0 on first successful (mode, attempt); non-zero if every
#       (mode, attempt) combination fails.
#
#   invoke_claude_raw <prompt-file> <output-file> <error-file>
#       For handlers that produce plain markdown text (handle-explain).
#       Success requires:
#         - claude exits 0
#         - output is non-empty
#         - output does not match a known soft-failure pattern
#           ("Credit balance is too low", "rate limit", invalid-key
#           messages) — these come back via stdout with exit 0 from the
#           CLI but are not actual responses
#       Returns 0/non-zero like invoke_claude_for_review.
#
# Auth modes:
#   The library inspects ANTHROPIC_API_KEY and CLAUDE_CODE_OAUTH_TOKEN at
#   call time and tries them in fixed order: api first, oauth second.
#   Each invocation runs with `env -u` to remove the unwanted variable so
#   the CLI uses exactly one credential per attempt (without env -u the
#   CLI's precedence between the two is implementation-defined).
#
# Logging:
#   The library emits structured JSON to stderr at every decision point
#   (attempt, hard_failure, soft_failure, success, mode_exhausted,
#   no_credentials). The script field in those log lines is
#   "invoke-claude.sh" so the operator can tell library logs apart from
#   handler logs.

_INVOKE_CLAUDE_SCRIPT="invoke-claude.sh"

_invoke_claude_log() {
  local level="$1" event="$2" outcome="$3"
  # Default `extra` to '{}' if no 4th arg. We use an if-block instead of
  # ${4:-{}} because the latter parses as ${4:-{} + literal }, leaving
  # `extra` set to `{` (invalid JSON, breaks --argjson).
  local extra='{}'
  if [[ $# -ge 4 && -n "$4" ]]; then extra="$4"; fi
  jq -cn \
    --arg level   "$level" \
    --arg script  "$_INVOKE_CLAUDE_SCRIPT" \
    --arg event   "$event" \
    --arg outcome "$outcome" \
    --argjson extra "$extra" \
    '{level:$level, script:$script, event:$event, outcome:$outcome} + $extra' >&2
}

# _invoke_claude_attempt <mode> <prompt-file> <output-file> <error-file>
_invoke_claude_attempt() {
  local mode="$1" prompt="$2" out="$3" err="$4"
  local model="${RTL_CLAUDE_MODEL:-claude-opus-4-7}"
  case "$mode" in
    api)
      env -u CLAUDE_CODE_OAUTH_TOKEN \
        claude --model "$model" -p \
        <"$prompt" >"$out" 2>"$err"
      ;;
    oauth)
      env -u ANTHROPIC_API_KEY \
        claude --model "$model" -p \
        <"$prompt" >"$out" 2>"$err"
      ;;
    *)
      return 99 ;;
  esac
}

# _invoke_claude_loop <validator-fn-name> <prompt-file> <output-file> <parsed-or-empty> <error-file>
# Tries each available auth mode in order, with two attempts per mode.
# Validator gets called with (output-file, parsed-or-empty) — if it
# returns 0, the attempt is considered successful and the loop stops.
_invoke_claude_loop() {
  local validator="$1" prompt="$2" out="$3" parsed="$4" err="$5"

  local -a auth_modes=()
  [[ -n "${ANTHROPIC_API_KEY:-}"       ]] && auth_modes+=(api)
  [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]] && auth_modes+=(oauth)

  if (( ${#auth_modes[@]} == 0 )); then
    _invoke_claude_log error invoke_claude no_credentials \
      '{"message":"need ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN"}'
    return 99
  fi

  # One-time environment diagnostic.
  local claude_bin claude_version
  claude_bin="$(command -v claude 2>/dev/null || echo '<not-found>')"
  claude_version="$(claude --version 2>&1 | head -n1 || echo '<unavailable>')"
  _invoke_claude_log info invoke_claude environment "$(jq -cn \
    --arg bin "$claude_bin" --arg ver "$claude_version" \
    --arg model "${RTL_CLAUDE_MODEL:-claude-opus-4-7}" \
    --argjson modes "$(printf '%s\n' "${auth_modes[@]}" | jq -R . | jq -cs .)" \
    '{bin:$bin, version:$ver, model:$model, auth_modes:$modes}')"

  local mode attempt code
  for mode in "${auth_modes[@]}"; do
    attempt=1
    while (( attempt <= 2 )); do
      _invoke_claude_log info invoke_claude attempt \
        "$(jq -cn --arg m "$mode" --argjson n "$attempt" '{mode:$m, attempt:$n}')"

      if _invoke_claude_attempt "$mode" "$prompt" "$out" "$err"; then
        if "$validator" "$out" "$parsed"; then
          _invoke_claude_log info invoke_claude success \
            "$(jq -cn --arg m "$mode" --argjson n "$attempt" '{mode:$m, attempt:$n}')"
          return 0
        else
          local soft_excerpt
          soft_excerpt="$(head -c 500 "$out" 2>/dev/null | tr '\n' ' ' || true)"
          _invoke_claude_log warn invoke_claude soft_failure \
            "$(jq -cn --arg m "$mode" --argjson n "$attempt" --arg ex "$soft_excerpt" \
               '{mode:$m, attempt:$n, output_excerpt:$ex}')"
        fi
      else
        code=$?
        local err_excerpt
        err_excerpt="$(head -c 500 "$err" 2>/dev/null | tr '\n' ' ' || true)"
        _invoke_claude_log warn invoke_claude hard_failure \
          "$(jq -cn --arg m "$mode" --argjson n "$attempt" --argjson c "$code" --arg e "$err_excerpt" \
             '{mode:$m, attempt:$n, exit_code:$c, stderr:$e}')"
      fi

      if (( attempt < 2 )); then sleep 5; fi
      attempt=$((attempt + 1))
    done
    _invoke_claude_log info invoke_claude mode_exhausted "$(jq -cn --arg m "$mode" '{mode:$m}')"
  done

  return 1
}

# Validators

# _validate_review_parseable <output-file> <parsed-output-file>
#   Treats output as success iff parse-review-output.sh accepts it.
_validate_review_parseable() {
  local out="$1" parsed="$2"
  # The lib lives at scripts/lib/invoke-claude.sh; the parser at
  # scripts/parse-review-output.sh. Resolve relative to this file.
  local lib_dir parser
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  parser="$lib_dir/../parse-review-output.sh"
  "$parser" <"$out" >"$parsed" 2>/dev/null
}

# _validate_raw_explain <output-file> <unused>
#   Treats output as success iff:
#     - non-empty (at least 50 bytes — short paragraphs are at least that),
#     - not a known soft-failure surrogate from the CLI on stdout.
_validate_raw_explain() {
  local out="$1"
  [[ -s "$out" ]] || return 1
  local size
  size="$(wc -c <"$out" | tr -d ' ')"
  (( size >= 50 )) || return 1
  # Soft-failure patterns (anchor to start-of-output to avoid matching
  # legitimate explanations that mention these phrases in passing).
  local first_line
  first_line="$(head -n1 "$out")"
  if [[ "$first_line" =~ ^(Credit\ balance|Rate\ limit|Invalid\ API\ key) ]]; then
    return 1
  fi
}

# Public entry points

# invoke_claude_for_review <prompt-file> <output-file> <parsed-output-file> <error-file>
invoke_claude_for_review() {
  local prompt="$1" output="$2" parsed="$3" err="$4"
  _invoke_claude_loop _validate_review_parseable "$prompt" "$output" "$parsed" "$err"
}

# invoke_claude_raw <prompt-file> <output-file> <error-file>
invoke_claude_raw() {
  local prompt="$1" output="$2" err="$3"
  _invoke_claude_loop _validate_raw_explain "$prompt" "$output" "" "$err"
}
