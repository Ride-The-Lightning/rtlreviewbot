#!/usr/bin/env bash
#
# check-permission.sh — verify a GitHub user has at least a given repository
# permission level.
#
# Usage:
#   check-permission.sh --user <login> --repo <owner/repo> --level <read|write|admin>
#
# Output:
#   stdout (one line of JSON):
#     {"user":"...","repo":"...","permission":"<actual>","required":"<level>","passed":<bool>,"cached":<bool>}
#   stderr: structured JSON log lines.
#
# Exit codes:
#   0  user meets the required level (passed)
#   1  user does NOT meet the required level (denied) — caller posts comment
#   2  system error (bad inputs, gh API failure other than 403/404, etc.)
#
# Notes:
#   - GitHub's `permission` field is one of: admin > write > read > none.
#     Granular roles (triage, maintain, custom) collapse into this set
#     server-side, so we treat .permission as the source of truth.
#   - 403 / 404 from the API are treated as "no permission" (the user is not
#     a collaborator and has no team-granted role). Any other API failure
#     is fatal — we never fail-open.
#   - Results are cached per workflow run in $RUNNER_TEMP (or /tmp). The
#     cache holds the user's actual permission level, not the pass/fail
#     decision, so different `--level` checks for the same user share one
#     API call. The cache directory is wiped naturally between runs.

set -euo pipefail

readonly SCRIPT_NAME="${BASH_SOURCE[0]##*/}"

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

USER_LOGIN=""
REPO=""
REQUIRED=""

while (( $# > 0 )); do
  case "$1" in
    --user)
      [[ $# -ge 2 ]] || die "--user requires a value" parse_args
      USER_LOGIN="$2"; shift 2 ;;
    --repo)
      [[ $# -ge 2 ]] || die "--repo requires a value" parse_args
      REPO="$2"; shift 2 ;;
    --level)
      [[ $# -ge 2 ]] || die "--level requires a value" parse_args
      REQUIRED="$2"; shift 2 ;;
    *)
      die "unknown argument: $1" parse_args ;;
  esac
done

[[ -z "$USER_LOGIN" ]] && die "missing required --user"  parse_args
[[ -z "$REPO"       ]] && die "missing required --repo"  parse_args
[[ -z "$REQUIRED"   ]] && die "missing required --level" parse_args

# Validate formats. Repo is owner/name; user is GitHub-login-shaped (alnum +
# hyphen, optionally with a [bot] suffix for App users).
if ! [[ "$USER_LOGIN" =~ ^[A-Za-z0-9][A-Za-z0-9-]*(\[bot\])?$ ]]; then
  die "invalid --user format: $USER_LOGIN" parse_args
fi
if ! [[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  die "invalid --repo format: $REPO (expected owner/repo)" parse_args
fi
case "$REQUIRED" in
  read|write|admin) ;;
  *) die "invalid --level: $REQUIRED (must be read|write|admin)" parse_args ;;
esac

# ---------------------------------------------------------------------------
# Permission ordering
# ---------------------------------------------------------------------------

perm_ord() {
  case "$1" in
    none)  echo 0 ;;
    read)  echo 1 ;;
    write) echo 2 ;;
    admin) echo 3 ;;
    *)     echo -1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Cache lookup
# ---------------------------------------------------------------------------

CACHE_DIR="${RTL_PERMISSION_CACHE_DIR:-${RUNNER_TEMP:-/tmp}/rtl-permissions}"
CACHE_FILE="${CACHE_DIR}/${REPO}/${USER_LOGIN}"

PERM=""
CACHED="false"

if [[ -f "$CACHE_FILE" ]]; then
  PERM="$(cat "$CACHE_FILE")"
  CACHED="true"
  log info perm_lookup cache_hit "$(jq -cn \
    --arg u "$USER_LOGIN" --arg r "$REPO" --arg p "$PERM" \
    '{user:$u, repo:$r, permission:$p}')"
fi

# ---------------------------------------------------------------------------
# API call (cache miss)
# ---------------------------------------------------------------------------

if [[ -z "$PERM" ]]; then
  RESP_FILE="$(mktemp -t rtl-perm-resp.XXXXXX)"
  ERR_FILE="$(mktemp -t rtl-perm-err.XXXXXX)"
  trap 'rm -f "$RESP_FILE" "$ERR_FILE"' EXIT

  log info perm_lookup api_call "$(jq -cn \
    --arg u "$USER_LOGIN" --arg r "$REPO" \
    '{user:$u, repo:$r}')"

  if gh api "repos/${REPO}/collaborators/${USER_LOGIN}/permission" \
       >"$RESP_FILE" 2>"$ERR_FILE"; then
    PERM="$(jq -er '.permission' "$RESP_FILE" 2>/dev/null)" \
      || die "response missing .permission" parse_response
  else
    # gh prints the HTTP status to stderr on failure (e.g. "HTTP 404"). We
    # treat 403 and 404 as "user has no permission on this repo" — both
    # represent the same logical state for our purposes (no role, or repo
    # is private and user is invisible).
    err_excerpt="$(tr '\n' ' ' <"$ERR_FILE" 2>/dev/null || true)"
    if grep -qE 'HTTP (403|404)' "$ERR_FILE"; then
      PERM="none"
      log info perm_lookup api_no_access "$(jq -cn \
        --arg u "$USER_LOGIN" --arg r "$REPO" \
        '{user:$u, repo:$r, treated_as:"none"}')"
    else
      die "gh api failed: ${err_excerpt:-unknown error}" api_call
    fi
  fi

  # Validate the level we got back is one we understand. An unknown value
  # (e.g. some future custom-role string surfaced into .permission) should
  # fail closed rather than silently denying or granting.
  case "$PERM" in
    none|read|write|admin) ;;
    *) die "unrecognized permission value from API: $PERM" parse_response ;;
  esac

  mkdir -p "$(dirname "$CACHE_FILE")"
  printf '%s' "$PERM" > "$CACHE_FILE"
fi

# ---------------------------------------------------------------------------
# Decide
# ---------------------------------------------------------------------------

ord_have="$(perm_ord "$PERM")"
ord_need="$(perm_ord "$REQUIRED")"

if (( ord_have >= ord_need )); then
  PASSED=true
  STATUS=0
else
  PASSED=false
  STATUS=1
fi

jq -cn \
  --arg u "$USER_LOGIN" \
  --arg r "$REPO" \
  --arg p "$PERM" \
  --arg req "$REQUIRED" \
  --argjson passed "$PASSED" \
  --argjson cached "$CACHED" \
  '{user:$u, repo:$r, permission:$p, required:$req, passed:$passed, cached:$cached}'

log info perm_decision "$([[ "$PASSED" == "true" ]] && echo passed || echo denied)" \
  "$(jq -cn --arg u "$USER_LOGIN" --arg r "$REPO" --arg p "$PERM" --arg req "$REQUIRED" \
     '{user:$u, repo:$r, permission:$p, required:$req}')"

exit "$STATUS"
