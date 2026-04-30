# Commands reference

How maintainers and PR authors interact with rtlreviewbot.

> **Status (v0.1.0).** Command recognition (`scripts/parse-command.sh`) and
> permission gating (`scripts/check-permission.sh`) are implemented. Handler
> dispatch and review-pipeline behavior land in subsequent milestones. The
> command surface and roles described here are stable.

## Invocation

rtlreviewbot is **maintainer-invoked**. The first time a PR is reviewed, a
maintainer comments `/rtl review`. After that, the author (or anyone with
push access) re-runs the review by clicking GitHub's **Re-request review**
button — comment commands are not needed for routine re-reviews.

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
| `/rtl re-review` | maintainer | Force fresh review without rate-limit |
| Re-request review (UI button) | author or anyone with push | Re-review against current HEAD |

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

Subsequent reviews on the same PR should use Re-request review or
`/rtl re-review` rather than re-issuing `/rtl review`.

### `/rtl stop`

Removes the `rtl-active` label (and `rtl-paused`, if set). The bot will
post no further reviews on this PR unless a maintainer issues `/rtl review`
again.

### `/rtl pause` / `/rtl resume`

Temporary off-switch. `/rtl pause` adds the `rtl-paused` label while leaving
`rtl-active` in place; while paused, Re-request review events are no-ops.
`/rtl resume` removes `rtl-paused`.

Use when a PR is undergoing rapid churn and the author doesn't want
intermediate reviews.

### `/rtl dismiss <id>`

Tells the bot to stop flagging the given finding on subsequent reviews.
The dismissal is recorded in the PR's metadata marker comment
(`dismissed_findings`) so it survives across re-reviews.

Finding IDs (`F1`, `F2`, …) appear in the bot's review comments. Authors
**cannot** dismiss findings on their own PRs — that would let an author
silence the bot on their own code. An author who disagrees with a finding
can reply with a normal comment or use `/rtl explain <id>` to ask for
more reasoning.

Example: `/rtl dismiss F3`

### `/rtl explain <id>`

Asks the bot to elaborate on a specific finding — its reasoning, severity,
and any rule references. Posts a reply on the relevant inline comment;
does not trigger a new review.

Example: `/rtl explain F3`

### `/rtl re-review`

Forces a fresh review of the current HEAD, bypassing the standard rate
limit. Use when a maintainer needs an immediate re-review (e.g. after a
late fix that should clear blockers before merge).

The standard re-review path (Re-request review button) is rate-limited to
one re-review per 5 minutes per PR; this command is the escape hatch.

## Other triggers (not comment commands)

| Trigger | Source | Behavior |
|---|---|---|
| Re-request review button | GitHub UI | Re-runs review against current HEAD on a PR with `rtl-active`. Rate-limited to one re-review per 5 minutes per PR. |
| PR closed / merged | system event | Auto-deactivates: removes `rtl-active` and `rtl-paused`, records final status in the metadata marker. |

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
