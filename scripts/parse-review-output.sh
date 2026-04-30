#!/usr/bin/env bash
#
# parse-review-output.sh — convert Claude's markdown review output into a
# structured JSON object that downstream scripts (post-review.sh,
# update-metadata.sh) can consume.
#
# Usage:
#   parse-review-output.sh < claude-output.md
#
# Input (stdin): markdown matching SKILL.md "Output contract":
#   ## Summary
#   <free text>
#   ## Findings              (initial-review mode)
#   <finding ...>...</finding>
#   ...
#   ## Prior findings        (re-review mode)
#   <finding ...>...</finding>
#   ## New findings          (re-review mode)
#   <finding ...>...</finding>
#   ## Verdict
#   REQUEST_CHANGES | COMMENT
#
# Output (stdout, single-line JSON):
#   {
#     "summary":        <string>,
#     "findings":       [ {id, severity, path, line, body}, ... ],
#     "prior_findings": [ {id, status, severity?, path?, line?, body}, ... ],
#     "new_findings":   [ {id, severity, path, line, body}, ... ],
#     "verdict":        "REQUEST_CHANGES" | "COMMENT"
#   }
#
# Lenient parser: missing or malformed findings are dropped with a stderr
# warning, but the script still produces well-formed output. The only
# fatal error is a missing/invalid verdict — the verdict is the load-
# bearing field for post-review.sh's decision.
#
# Exit codes:
#   0  success (output JSON on stdout)
#   2  fatal parse error (verdict missing/invalid, or empty input)

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

# extract_attr <attr-name> <attr-string> — pulls value="..." from an
# attribute string; prints empty if not present.
extract_attr() {
  local name="$1" str="$2"
  if [[ "$str" =~ ${name}=\"([^\"]*)\" ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

# rstrip — remove trailing whitespace from a string. Portable to bash
# 3.2 (macOS), which lacks the ${s:0:-1} negative-length form.
rstrip() {
  local s="$1"
  while [[ -n "$s" && "${s: -1}" =~ [[:space:]] ]]; do
    s="${s%?}"
  done
  printf '%s' "$s"
}

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

INPUT="$(cat)"
[[ -z "$INPUT" ]] && die "empty input" empty_input

section=""             # current "## " section (lowercased, normalized)
in_finding=false
fattrs=""
fbody=""
summary_text=""
verdict=""

findings_json='[]'
prior_findings_json='[]'
new_findings_json='[]'

# emit_finding <section> <attrs-line> <body> — assemble a finding object
# from the captured attrs + body and append it to the right list.
emit_finding() {
  local section_name="$1" attrs="$2" body="$3"

  local id sev path line status
  id="$(extract_attr id "$attrs")"
  sev="$(extract_attr severity "$attrs")"
  path="$(extract_attr path "$attrs")"
  line="$(extract_attr line "$attrs")"
  status="$(extract_attr status "$attrs")"

  if [[ -z "$id" ]]; then
    log warn parse_finding skipped "$(jq -cn --arg a "$attrs" '{reason:"missing id", attrs:$a}')"
    return 0
  fi

  body="$(rstrip "$body")"

  # Build finding JSON with conditional fields. Empty strings collapse to
  # null (so post-review.sh can distinguish "not anchored" from "").
  local obj
  obj="$(jq -cn \
    --arg id     "$id" \
    --arg sev    "$sev" \
    --arg path   "$path" \
    --arg line   "$line" \
    --arg status "$status" \
    --arg body   "$body" \
    '{
      id:       $id,
      severity: ($sev    | if . == "" then null else . end),
      status:   ($status | if . == "" then null else . end),
      path:     ($path   | if . == "" then null else . end),
      line:     ($line   | if . == "" then null else (tonumber? // null) end),
      body:     $body
    }
    | with_entries(select(.value != null))
    ')"

  case "$section_name" in
    findings)
      findings_json="$(jq --argjson o "$obj" '. + [$o]' <<<"$findings_json")" ;;
    prior_findings)
      prior_findings_json="$(jq --argjson o "$obj" '. + [$o]' <<<"$prior_findings_json")" ;;
    new_findings)
      new_findings_json="$(jq --argjson o "$obj" '. + [$o]' <<<"$new_findings_json")" ;;
    *)
      log warn parse_finding orphan "$(jq -cn --arg id "$id" --arg s "$section_name" '{id:$id, in_section:$s}')" ;;
  esac
}

# ---------------------------------------------------------------------------
# Line-by-line walk
# ---------------------------------------------------------------------------

while IFS= read -r line || [[ -n "$line" ]]; do
  # ## Section header — closes any open finding (treated as a parse warning),
  # switches the active section.
  if [[ "$line" =~ ^"## "(.+)$ ]]; then
    if "$in_finding"; then
      log warn parse_finding unclosed "$(jq -cn --arg a "$fattrs" '{attrs:$a}')"
      in_finding=false
      fattrs=""; fbody=""
    fi

    raw="${BASH_REMATCH[1]}"
    raw="${raw%"${raw##*[![:space:]]}"}"   # rstrip
    case "$raw" in
      Summary)             section=summary ;;
      Findings)            section=findings ;;
      "Prior findings")    section=prior_findings ;;
      "New findings")      section=new_findings ;;
      Verdict)             section=verdict ;;
      *)                   section="" ;;
    esac
    continue
  fi

  # Finding-open tag (must start the line). Same line may also close.
  if [[ "$line" =~ ^"<finding"[[:space:]] ]]; then
    if "$in_finding"; then
      log warn parse_finding nested "$(jq -cn --arg a "$fattrs" '{prev_attrs:$a}')"
    fi
    fattrs="$line"
    fbody=""
    in_finding=true
    if [[ "$line" =~ "</finding>" ]]; then
      in_finding=false
      emit_finding "$section" "$fattrs" "$fbody"
      fattrs=""; fbody=""
    fi
    continue
  fi

  # Finding-close tag.
  if [[ "$line" == "</finding>" ]] && "$in_finding"; then
    in_finding=false
    emit_finding "$section" "$fattrs" "$fbody"
    fattrs=""; fbody=""
    continue
  fi

  # Inside a finding — accumulate the body.
  if "$in_finding"; then
    fbody+="$line"$'\n'
    continue
  fi

  # Section content.
  case "$section" in
    summary)
      summary_text+="$line"$'\n' ;;
    verdict)
      # First non-blank line is the verdict; ignore anything after.
      if [[ -z "$verdict" ]] && [[ -n "${line//[[:space:]]/}" ]]; then
        # Strip surrounding whitespace.
        local_v="${line#"${line%%[![:space:]]*}"}"
        local_v="${local_v%"${local_v##*[![:space:]]}"}"
        verdict="$local_v"
      fi ;;
  esac
done <<<"$INPUT"

if "$in_finding"; then
  log warn parse_finding unclosed_eof "$(jq -cn --arg a "$fattrs" '{attrs:$a}')"
fi

# ---------------------------------------------------------------------------
# Validate verdict
# ---------------------------------------------------------------------------

case "$verdict" in
  REQUEST_CHANGES|COMMENT) ;;
  "") die "missing ## Verdict section or empty verdict" missing_verdict ;;
  *)  die "invalid verdict: $verdict (expected REQUEST_CHANGES or COMMENT)" invalid_verdict ;;
esac

# ---------------------------------------------------------------------------
# Trim summary's leading/trailing blank lines, then emit final JSON.
# ---------------------------------------------------------------------------

# Drop leading blank lines.
while [[ -n "$summary_text" && "${summary_text:0:1}" == $'\n' ]]; do
  summary_text="${summary_text:1}"
done
summary_text="$(rstrip "$summary_text")"

jq -cn \
  --arg summary           "$summary_text" \
  --argjson findings      "$findings_json" \
  --argjson prior_finds   "$prior_findings_json" \
  --argjson new_finds     "$new_findings_json" \
  --arg verdict           "$verdict" \
  '{
    summary:        $summary,
    findings:       $findings,
    prior_findings: $prior_finds,
    new_findings:   $new_finds,
    verdict:        $verdict
  }'
