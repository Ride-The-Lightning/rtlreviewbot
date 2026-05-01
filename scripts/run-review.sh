#!/usr/bin/env bash
#
# run-review.sh — top-level entry point invoked by the reusable workflow.
#
# Responsibilities:
#   1. Mint a GitHub App installation token and export it as $GH_TOKEN so
#      every downstream `gh` call inherits the bot's identity.
#   2. Skip silently on loop-prevention triggers (the bot's own activity).
#   3. Determine which flow to run based on the event:
#        issue_comment             → parse /rtl command, permission-check,
#                                    dispatch to handlers/handle-<cmd>.sh
#        pull_request review_requested → handlers/handle-rerequest.sh
#        pull_request closed           → handlers/handle-close.sh
#   4. Pass --repo / --pr / --actor / --args through to the handler.
#
# Required env (set via the workflow):
#   GATEWAY_APP_ID, GATEWAY_PRIVATE_KEY, GATEWAY_INSTALLATION_ID
#   ANTHROPIC_API_KEY (consumed by handle-review.sh's Claude invocation)
#
# Usage (from the workflow):
#   run-review.sh \
#     --event-name <issue_comment|pull_request> \
#     --event-action <created|review_requested|closed|...> \
#     --repo <owner/repo> \
#     --pr <number> \
#     --actor <login> \
#     [--comment-body <body>]              (issue_comment only)
#     [--bot-login <login>]
#
# Exit codes:
#   0  handled (or no-op for unrecognized event / non-command comment / loop)
#   2  system error (auth failed, handler bailed)

set -euo pipefail

readonly SCRIPT_NAME="${BASH_SOURCE[0]##*/}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; readonly SCRIPT_DIR

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

EVENT_NAME=""
EVENT_ACTION=""
REPO=""
PR=""
ACTOR=""
COMMENT_BODY=""
COMMENT_ID=""
BOT_LOGIN="${RTL_BOT_LOGIN:-rtlreview[bot]}"

while (( $# > 0 )); do
  case "$1" in
    --event-name)   EVENT_NAME="$2"; shift 2 ;;
    --event-action) EVENT_ACTION="$2"; shift 2 ;;
    --repo)         REPO="$2"; shift 2 ;;
    --pr)           PR="$2"; shift 2 ;;
    --actor)        ACTOR="$2"; shift 2 ;;
    --comment-body) COMMENT_BODY="$2"; shift 2 ;;
    --comment-id)   COMMENT_ID="$2"; shift 2 ;;
    --bot-login)    BOT_LOGIN="$2"; shift 2 ;;
    *) die "unknown argument: $1" parse_args ;;
  esac
done

[[ -z "$EVENT_NAME" ]] && die "missing required --event-name" parse_args
[[ -z "$REPO"       ]] && die "missing required --repo"       parse_args
[[ -z "$PR"         ]] && die "missing required --pr"         parse_args
[[ -z "$ACTOR"      ]] && die "missing required --actor"      parse_args

# ---------------------------------------------------------------------------
# Loop prevention (before any expensive work or auth)
# ---------------------------------------------------------------------------

if [[ "$ACTOR" == "$BOT_LOGIN" ]]; then
  log info loop_prevention skipped "$(jq -cn --arg a "$ACTOR" '{actor:$a}')"
  exit 0
fi

# Filter known automation that sometimes posts in PR threads. These accounts
# do not invoke /rtl commands; ignore them defensively.
case "$ACTOR" in
  dependabot\[bot\]|renovate\[bot\]|github-actions\[bot\])
    log info bot_filter skipped "$(jq -cn --arg a "$ACTOR" '{actor:$a}')"
    exit 0
    ;;
esac

# ---------------------------------------------------------------------------
# Authenticate — mint the installation token, export GH_TOKEN
# ---------------------------------------------------------------------------

log info authenticate attempt "{}"

AUTH_OUT="$("$SCRIPT_DIR/authenticate.sh")" \
  || die "authentication failed (see authenticate.sh stderr)" authenticate

GH_TOKEN="$(echo "$AUTH_OUT" | jq -r '.token')"
export GH_TOKEN
export GITHUB_TOKEN="$GH_TOKEN"   # gh CLI honors either; export both for safety.

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

case "$EVENT_NAME" in

  issue_comment)
    if [[ -z "$COMMENT_BODY" ]]; then
      log info issue_comment empty_body "{}"
      exit 0
    fi

    PARSED="$(printf '%s' "$COMMENT_BODY" | "$SCRIPT_DIR/parse-command.sh")"
    CMD="$(echo "$PARSED" | jq -r '.command')"

    if [[ "$CMD" == "null" || -z "$CMD" ]]; then
      log info parse_command no_command "{}"
      exit 0
    fi

    log info dispatch issue_comment "$(jq -cn --arg c "$CMD" '{command:$c}')"

    # Permission gate per command.
    permission_denied() {
      local cmd="$1" need="$2"
      gh api -X POST "repos/${REPO}/issues/${PR}/comments" \
        -f "body=Sorry, \`/rtl $cmd\` requires $need permission." \
        >/dev/null 2>&1 || true
      log info permission_denied "$cmd" "$(jq -cn --arg n "$need" '{need:$n}')"
      exit 0
    }

    is_maintainer() {
      "$SCRIPT_DIR/check-permission.sh" \
        --user "$ACTOR" --repo "$REPO" --level write >/dev/null 2>&1
    }

    is_author() {
      local pr_author
      pr_author="$(gh api "repos/${REPO}/pulls/${PR}" --jq '.user.login' 2>/dev/null || true)"
      [[ -n "$pr_author" && "$pr_author" == "$ACTOR" ]]
    }

    case "$CMD" in
      review|dismiss|re-review)
        is_maintainer || permission_denied "$CMD" "maintainer"
        ;;
      stop|pause|resume)
        if ! is_maintainer && ! is_author; then
          permission_denied "$CMD" "maintainer or PR author"
        fi
        ;;
      explain)
        : # anyone may invoke
        ;;
      *)
        log warn dispatch unknown_command "$(jq -cn --arg c "$CMD" '{command:$c}')"
        exit 0
        ;;
    esac

    # Route to the matching handler script.
    HANDLER="$SCRIPT_DIR/handlers/handle-${CMD}.sh"
    if [[ ! -x "$HANDLER" ]]; then
      die "handler not found or not executable: $HANDLER" dispatch
    fi

    # Args (e.g. finding ID for dismiss/explain) are passed through joined
    # into a single string. Handlers re-parse if needed.
    CMD_ARGS="$(echo "$PARSED" | jq -r '.args | join(" ")')"

    exec "$HANDLER" --repo "$REPO" --pr "$PR" --actor "$ACTOR" \
                    --bot-login "$BOT_LOGIN" \
                    ${COMMENT_ID:+--comment-id "$COMMENT_ID"} \
                    ${CMD_ARGS:+--args "$CMD_ARGS"}
    ;;

  pull_request)
    case "$EVENT_ACTION" in
      review_requested)
        log info dispatch review_requested "{}"
        HANDLER="$SCRIPT_DIR/handlers/handle-rerequest.sh"
        ;;
      closed)
        log info dispatch closed "{}"
        HANDLER="$SCRIPT_DIR/handlers/handle-close.sh"
        ;;
      *)
        log info dispatch unsupported_pr_action "$(jq -cn --arg a "$EVENT_ACTION" '{action:$a}')"
        exit 0
        ;;
    esac

    [[ -x "$HANDLER" ]] || die "handler not found or not executable: $HANDLER" dispatch
    exec "$HANDLER" --repo "$REPO" --pr "$PR" --actor "$ACTOR" --bot-login "$BOT_LOGIN"
    ;;

  *)
    log info dispatch unsupported_event "$(jq -cn --arg e "$EVENT_NAME" '{event:$e}')"
    exit 0
    ;;

esac
