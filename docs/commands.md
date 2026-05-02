# Commands reference

How maintainers and PR authors interact with rtlreviewbot.

> **Status (v0.1.0).** Command recognition (`scripts/parse-command.sh`) and
> permission gating (`scripts/check-permission.sh`) are implemented. Handler
> dispatch and review-pipeline behavior land in subsequent milestones. The
> command surface and roles described here are stable.

## Invocation

rtlreviewbot is **maintainer-invoked**. The first time a PR is reviewed, a
maintainer comments `/rtl review`. After that, anyone with `write` access
(or the PR author, or any user for `explain`) drives further behavior via
the comment commands listed below — most importantly, `/rtl re-review` to
re-review against current HEAD after pushing changes.

> **Note:** Re-reviews are **comment-driven**, not button-driven. GitHub's
> native "Re-request review" UI button does not work for GitHub App
> reviewers — the underlying API silently rejects App accounts in the
> requested-reviewers list. The bot's success comment includes a `/rtl
> re-review` CTA so users have a single, obvious path.

Comments on PRs that don't yet carry the `rtl-active` label are ignored,
with the single exception of the initial `/rtl review`.

## Quick reference

| Command | Who | Effect |
|---|---|---|
| `/rtl review` | maintainer | Initial review; activates the bot on this PR |
| `/rtl stop` | maintainer or author | Deactivate the bot on this PR |
| `/rtl pause` / `/rtl resume` | maintainer or author | Temporarily deactivate / reactivate |
| `/rtl dismiss <id>` | maintainer | Stop flagging a specific finding |
| `/rtl explain <id>` | anyone | Elaborate on a finding (no new review) |
| `/rtl re-review` | maintainer | Re-review against current HEAD (the canonical re-review path — see invocation note above) |
| `/rtl approve` | maintainer | Submit a formal `APPROVE` review when all prior findings are addressed/withdrawn |

## Recognition rules

A line in a PR comment is treated as a command if **all** of these hold:

1. It starts at column 0 with `/rtl` followed by at least one space or tab.
2. The next token is a known subcommand (the commands listed above).

Trailing whitespace and `\r` (CRLF input) are stripped before matching. If
several lines in one comment look like commands, the **first recognized
line wins**. Lines that don't start at column 0 — markdown blockquotes
(`> /rtl review`), indented text, mid-sentence references — are ignored.
Subcommand typos are not auto-corrected; an unknown subcommand resolves to
"no command".

The authoritative list of recognized subcommands lives in `KNOWN_COMMANDS`
in `scripts/parse-command.sh`.

## Roles

| Role | Definition |
|---|---|
| **maintainer** | Has GitHub permission `write` or `admin` on the repository (verified via the collaborators API). |
| **author** | Opened the PR (verified by comparing the commenter's login to `pull_request.user.login`). |
| **anyone** | Any user, including non-collaborators. |

A maintainer who opens a PR satisfies both `maintainer` and `author`.

## Per-command details

### `/rtl review`

The first-time review for a PR. Adds the `rtl-active` label and runs the
`code-review` skill against the current diff, then posts a formal GitHub
review (body + inline comments + verdict).

Subsequent reviews on the same PR should use `/rtl re-review` rather
than re-issuing `/rtl review`.

### `/rtl stop`

Removes the `rtl-active` label (and `rtl-paused`, if set). The bot will
post no further reviews on this PR unless a maintainer issues `/rtl review`
again. The metadata marker comment is left intact as the historical
audit record.

Implemented in v0.6.0. The success path is acknowledged with a 👍
reaction on the triggering `/rtl stop` comment; errors get a visible PR
comment.

### `/rtl pause` / `/rtl resume`

Temporary off-switch. `/rtl pause` adds the `rtl-paused` label while leaving
`rtl-active` in place; while paused, `/rtl re-review` invocations are
acknowledged but no-op until `/rtl resume`. `/rtl resume` removes
`rtl-paused`.

Use when a PR is undergoing rapid churn and the author doesn't want
intermediate reviews. Implemented in v0.6.0. Both commands acknowledge
success with a 👍 reaction on the triggering comment.

### `/rtl dismiss <id> [reason]`

Tells the bot to stop flagging the given finding on subsequent reviews.
The dismissal is recorded in the PR's metadata marker comment
(`dismissed_findings`) so it survives across re-reviews; if the original
finding was posted as an inline comment, the bot also edits that comment
in place to prepend a dismissal banner (`> 🚫 Dismissed by @maintainer
— reason`) so anyone reading the PR thread later sees the dismissal next
to the original concern.

Finding IDs (`F1`, `F2`, …) appear in the bot's review comments. Authors
**cannot** dismiss findings on their own PRs — that would let an author
silence the bot on their own code. An author who disagrees with a finding
can reply with a normal comment or use `/rtl explain <id>` to ask for
more reasoning.

Example: `/rtl dismiss F3 false positive — see issue #234`

Implemented in v0.6.0. Acknowledged with a 👍 reaction; failures (unknown
id, already dismissed, marker missing) post a visible explanatory comment.

### `/rtl explain <id>`

Asks the bot to elaborate on a specific finding — its reasoning, severity,
and any rule references. Posts a reply on the original inline comment if
one exists; otherwise as a top-level PR comment with a "(re: F<id>)"
preamble. Does not trigger a new review.

Example: `/rtl explain F3`

Implemented in v0.7.0. Acknowledged with a 👍 reaction on the triggering
comment. Errors (unknown id, dismissed id, marker missing, Claude
failure) post a visible explanatory comment instead.

### `/rtl re-review`

The canonical way to re-review a PR against current HEAD after the
author has pushed changes. The bot acknowledges what was addressed
since the prior review, restates anything still unresolved, marks any
findings it now thinks were wrong as `withdrawn`, and adds new findings
introduced by the new commits. The metadata marker is merged so finding
IDs are stable across re-reviews and dismissed findings stay dismissed.

GitHub's native "Re-request review" UI button does not target GitHub
App reviewers (the API silently rejects App accounts on the requested-
reviewers endpoint), so this comment command is the supported re-review
path. Every successful `/rtl review` ends with a CTA pointing at it.

If `marker.last_reviewed_sha == pr.head_sha` (no new commits since the
prior review), the bot short-circuits with "No new commits since last
review — findings still stand." rather than burning a Claude call.

Implemented in v0.7.0. Maintainer-only. No rate limit (the 5-minute
limit in earlier specs was attached to the now-defunct UI-button
trigger).

### `/rtl approve`

Submits a formal `APPROVE` review on the PR with an LGTM-style summary
body, *iff* the metadata marker passes three gates:

1. The marker exists (i.e. `/rtl review` has run at least once).
2. `marker.last_reviewed_sha` equals the PR's current `head.sha` —
   nothing has landed since the bot last looked. If commits have been
   pushed since the last review, the bot replies with a "run
   `/rtl re-review` first" message instead of approving stale code.
3. Every entry in `marker.findings` either has status `addressed` or
   `withdrawn`, **or** appears in `marker.dismissed_findings`. Findings
   with status `unresolved` or `partially_addressed` (and not dismissed)
   block approval; the bot posts a list of what is still open.

The approval handler is **deterministic** — it does not invoke the
review skill. The body it posts is templated from the marker
(`Findings recap` section listing each prior finding with its severity
and current status, plus a `Dismissed` section if any). Because the
verdict is decided by hard rules on the marker rather than by the LLM,
there is no risk of a hallucinated approval.

On success the marker is patched with `approved_by` and `approved_at`
audit fields, the trigger comment receives a 👍 reaction, and the
formal review is visible in the PR's review timeline like any human
approval.

Implemented in v0.9.0. Maintainer-only. **The bot's APPROVE counts as
an approving review for branch-protection purposes** — if your repo
requires N approving reviews, the bot's APPROVE counts toward N.
Configure branch protection accordingly (e.g. require approvals from
specific code-owners or human accounts) if that is not the intent.

## Other triggers (not comment commands)

| Trigger | Source | Behavior |
|---|---|---|
| PR closed / merged | system event | Auto-deactivates: removes `rtl-active` and `rtl-paused`, appends a terminal record (`closed_at`, `merged`) to the metadata marker. Silent — no comment posted. Implemented in v0.6.0. |

> The reusable workflow also listens for `pull_request` `review_requested`
> events for forward-compatibility, but they currently do not fire for the
> bot — see the invocation note above for why. The listener is harmless;
> if GitHub ever supports App accounts in the requested-reviewers API, the
> trigger will start working without code changes.

## What is not recognized

- Comments authored by the rtlreviewbot App itself (loop prevention).
- Comments from known automation accounts (e.g. `dependabot[bot]`,
  `renovate[bot]`).
- Command-shaped text that isn't at column 0 — indented, blockquoted, or
  mid-sentence.
- Subcommands not listed in the table above, including typos. The parser
  returns "no command" rather than guessing.
- Any comment on a PR that doesn't carry `rtl-active`, except for the
  initial `/rtl review`.
