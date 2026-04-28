# rtlreviewbot

A maintainer-invoked, Claude-powered code review bot for GitHub pull
requests. Currently a sandbox build under `Ride-The-Lightning` for testing
the design before any production deployment.

## Status

**v0.1.0 — scaffold.** GitHub App is registered (`rtlreview`, App ID 3524153)
and installation token minting is implemented and tested. The review pipeline
itself is placeholder-only at this stage.

## What it does (planned)

A maintainer comments `/rtlreviewbot review` on a PR. The bot:

1. Posts a holding comment within ~10s
2. Runs the `code-review` skill against the PR diff
3. Posts a formal GitHub PR review (body + inline comments + verdict)
4. Marks the PR with the `rtlreviewbot-active` label
5. Records audit metadata in a hidden marker comment

After the initial invocation, developers control re-review cadence using
GitHub's native **Re-request review** button.

The bot is **not** an auto-approver, **not** a merge gate, and **not**
auto-triggered on every PR.

## Layout

| Path | Purpose |
|---|---|
| `.github/workflows/review.yml` | Reusable workflow — entry point invoked by consumer repos |
| `.github/workflows/ci.yml` | Lint + unit tests for this repo |
| `skills/code-review/` | Skill definition, prompts, and domain rules |
| `scripts/` | Bash orchestration scripts (one per pipeline step) |
| `scripts/handlers/` | One script per supported `/rtlreviewbot` command |
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
