# Changelog

All notable changes to rtlreviewbot are recorded here. The format is loosely
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.5.4] — 2026-04-30

Claude auth: API-key path is no longer the only option, and is no longer
required. The reusable workflow now accepts either `anthropic_api_key`
or `claude_code_oauth_token`, or both. With both set, `handle-review.sh`
tries API first and falls back to OAuth on failure — including the
"soft failure" case where the CLI exits 0 but produces non-review
output (e.g. `"Credit balance is too low"`).

The fallback success criterion is the parser itself: a Claude attempt
counts as success only when `parse-review-output.sh` accepts the output.
Single source of truth — no separate heuristic to drift.

### Added
- `CLAUDE_CODE_OAUTH_TOKEN` accepted as an alternative or fallback to
  `ANTHROPIC_API_KEY`. Generated locally via `claude setup-token` after
  `claude /login`; bills against the signed-in Claude.ai subscription
  quota rather than per-token API.
- `handle-review.sh`: structured try-then-fall-back loop over auth modes
  (`api`, `oauth`). Each mode gets up to two attempts. Each attempt is
  scored by the parser, not by exit code alone — soft failures fall
  through to the next attempt instead of being mistaken for success.
- Diagnostic logs include the list of auth modes available and which
  mode/attempt produced the eventual success or final failure.

### Changed
- `.github/workflows/review.yml`: both Claude auth secrets are now
  `required: false` at the workflow-call layer; runtime enforcement
  ("at least one must be set") moved into `handle-review.sh`.
- `docs/consumer-setup.md` Step 9 secrets table: `CLAUDE_CODE_OAUTH_TOKEN`
  added; both Claude secrets marked optional with an explanatory note.
- `docs/consumer-setup.md` Step 3 shim example: passes both auth
  secrets through.

### Notes
- Existing shims that only set `anthropic_api_key` continue to work
  unchanged. To get fallback, set the second secret too.
- The OAuth token is tied to a specific Claude.ai account. Production
  deployments should plan for a different auth surface (org-scoped API
  key, Bedrock, or Vertex) rather than relying on a personal session.

## [0.5.3] — 2026-04-30

### Fixed
- `handle-review.sh`: capture the Claude exit code from the `else`
  branch of the auth-retry loop. Previously `claude_exit=$?` after
  `fi` always logged 0, masking the real failure code.

## [0.5.1, 0.5.2] — 2026-04-30

### Fixed
- `handle-review.sh`: pipe the prompt to `claude -p` via stdin rather
  than passing it as a positional argument. The CLI parsed our SKILL.md
  YAML frontmatter (which starts with `---`) as an unknown option.
- `handle-review.sh`: surface both stdout and stderr (truncated) from
  the failed Claude invocation so the operator has something concrete
  to act on, instead of an "unknown" placeholder.

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
