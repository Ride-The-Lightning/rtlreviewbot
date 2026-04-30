# Changelog

All notable changes to rtlreviewbot are recorded here. The format is loosely
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.5.0] — 2026-04-30

First end-to-end-capable release. The `/rtl review` flow is wired top to
bottom; the other commands route correctly and post a "not yet
implemented" acknowledgement.

### Added
- M2 — command surface and permission gating:
  - `scripts/parse-command.sh` — extract `/rtl <command> [args]` from a
    PR comment body (strict start-of-line match; first recognized line
    wins).
  - `scripts/check-permission.sh` — verify a user meets a required GitHub
    permission level (per-workflow-run cache, fail-closed on API errors).
  - `scripts/post-holding-comment.sh` — post (or reuse) the "review
    starting" holding comment, identified by a hidden marker.
- M3 — PR context aggregation and metadata marker:
  - `scripts/fetch-pr-context.sh` — single JSON object aggregating PR
    metadata, raw diff, file list, issue/review comments, and reviews;
    filters the bot's own contributions; truncates the diff at a
    configurable threshold without failing open.
  - `scripts/update-metadata.sh` — read or write the `rtlreviewbot-meta`
    marker comment; identifies the marker by both sentinel and bot
    author so spoofed markers are ignored.
- M4 — `/code-review` skill:
  - `skills/code-review/SKILL.md` — canonical input/output contract,
    severity rubric, verdict mapping, domain-rule fallback policy.
  - `skills/code-review/prompts/initial-review.md`,
    `re-review.md`, `explain.md` — mode-specific prompts.
- M5 — review orchestration:
  - `scripts/parse-review-output.sh` — Claude markdown + `<finding>`
    output to JSON.
  - `scripts/post-review.sh` — submit the formal review via the GitHub
    API; demote unanchored findings to the body; fall back to body-only
    on API rejection.
  - `scripts/run-review.sh` — top-level dispatcher with loop-prevention,
    automation-account filter, per-command permission gating.
  - `scripts/handlers/handle-review.sh` — full FR-1 flow.
  - Scaffolded handler stubs for `stop`/`pause`/`resume`/`dismiss`/
    `explain`/`re-review`/`rerequest`/`close`.
  - `.github/workflows/review.yml` — real reusable workflow body that
    consumer repos call via `uses:`.
- Tests: `parse-command.bats`, `check-permission.bats`,
  `post-holding-comment.bats`, `fetch-pr-context.bats`,
  `update-metadata.bats`, `parse-review-output.bats`, `post-review.bats`,
  `run-review.bats`, plus shared fixtures in `tests/fixtures/`.

### Changed
- `docs/commands.md` rewritten from placeholder to a working reference
  (recognition rules, role definitions, per-command details).
- `docs/consumer-setup.md` Step 3 replaced with a concrete ~30-line shim
  example. Step 9 adds `ANTHROPIC_API_KEY` to the org-secrets table.
- All command and label references aligned to the `/rtl` prefix and
  `rtl-active` / `rtl-paused` labels.

### Fixed
- bats tests now use `run --separate-stderr` where they assert on
  stdout, fixing pre-existing failures in `authenticate.bats` that were
  shadowed by trailing log lines on combined stdout+stderr.
- Several BSD/GNU portability issues surfaced by the macOS / Linux split
  (awk `close` reserved word, GNU grep parsing `-->` as an option, bash
  3.2 lacking `${s:0:-1}`).

### Notes
- The reusable workflow expects `installation_id` as a workflow input
  rather than auto-resolving it; the consumer shim hard-codes the value
  from `docs/consumer-setup.md` Part 2 Step 1.
- Re-review (FR-2), explain (FR-5), and the state-mutation commands are
  scaffolded but not implemented. Their handlers post a "not yet
  implemented" comment so users see acknowledgement.
- First end-to-end smoke test against a real PR is the natural next
  step. Expect to find at least one Claude-CLI-invocation issue —
  isolated to `handle-review.sh`'s `invoke_claude()` function.

## [0.1.0] — 2026-04-27

### Added
- Initial repo scaffold: directory layout, placeholder scripts, skill stubs,
  config defaults, docs scaffolding.
- `scripts/authenticate.sh` — mints GitHub App installation tokens via JWT
  (RS256) and the GitHub App API.
- bats unit tests for `authenticate.sh`.
- CI workflow running `shellcheck`, `actionlint`, and bats unit tests.
- Consumer setup documentation covering one-time GitHub App registration
  and per-repo onboarding.

### Notes
- Bot identity registered as the `rtlreview` GitHub App under the
  `Ride-The-Lightning` org for sandbox testing. The eventual production
  home is `lightninglabs/gateway`.
- Org secrets are named `GATEWAY_APP_ID` and `GATEWAY_PRIVATE_KEY` (kept
  for continuity with the original design); the visible bot identity is
  rtlreviewbot.
