# rtlreviewbot

A maintainer-invoked, Claude-powered code review bot for GitHub pull
requests. Currently a sandbox build under `Ride-The-Lightning` for testing
the design before any production deployment.

## Status

**v0.5.5 — first end-to-end-capable release, smoke-tested.** The `/rtl
review` flow is wired top to bottom: the dispatcher authenticates as the
App, parses the command, gates on maintainer permission, fetches PR
context, invokes the `code-review` skill (with API-key → OAuth-token
auth fallback), parses the structured output, posts a formal review,
applies the `rtl-active` label, and writes the metadata marker. Smoke-
tested against a real sandbox PR. Other commands (`stop`, `pause`,
`resume`, `dismiss`, `explain`, `re-review`, plus PR-close cleanup)
route correctly but reply with a "not yet implemented" comment — full
implementations land in subsequent milestones.

GitHub App is registered (`rtlreview`, App ID 3524153). Re-reviews are
driven by the `/rtl re-review` comment command (GitHub's native
Re-request review button does not work for App reviewers — see
[`docs/commands.md`](docs/commands.md)). See
[`docs/consumer-setup.md`](docs/consumer-setup.md) for the consumer-repo
shim and [`CHANGELOG.md`](CHANGELOG.md) for the per-milestone breakdown.

## What it does (planned)

A maintainer comments `/rtl review` on a PR. The bot:

1. Posts a holding comment within ~10s
2. Runs the `code-review` skill against the PR diff
3. Posts a formal GitHub PR review (body + inline comments + verdict)
4. Marks the PR with the `rtl-active` label
5. Records audit metadata in a hidden marker comment

After the initial invocation, developers control re-review cadence by
posting `/rtl re-review` on the PR. (GitHub's native **Re-request review**
button does not work for GitHub App reviewers — the API silently rejects
App accounts in the requested-reviewers list — so the bot's success
comment ends with a CTA pointing at the comment command.)

The bot is **not** an auto-approver, **not** a merge gate, and **not**
auto-triggered on every PR.

## Layout

| Path | Purpose |
|---|---|
| `.github/workflows/review.yml` | Reusable workflow — entry point invoked by consumer repos |
| `.github/workflows/ci.yml` | Lint + unit tests for this repo |
| `skills/code-review/` | Skill definition, prompts, and domain rules |
| `scripts/` | Bash orchestration scripts (one per pipeline step) |
| `scripts/handlers/` | One script per supported `/rtl` command |
| `config/defaults.yml` | Default configuration (overridable per consumer repo) |
| `tests/{unit,integration,fixtures}/` | bats unit tests, integration suite, sample data |
| `docs/` | Setup guide, command reference, architecture, troubleshooting |

## Onboarding a repo

See [`docs/consumer-setup.md`](docs/consumer-setup.md).

## Security stance

- The App holds the minimum permissions needed (read content, write PR
  comments and reviews, read org members). No write access to code, branches,
  branch protection, settings, or secrets.
- Webhooks are disabled — the App is identity-only.
- Tokens are short-lived (1 hour) and never logged.
- The bot reads diffs; it never checks out or executes fork-authored code
  under privileged token context.
