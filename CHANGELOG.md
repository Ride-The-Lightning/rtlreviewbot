# Changelog

All notable changes to rtlreviewbot are recorded here. The format is loosely
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.9.0] — 2026-05-01

### Added
- `/rtl approve` — maintainer-driven command that submits a formal
  `APPROVE` review on the PR. The handler is **deterministic** (no
  Claude call) and gates approval on three marker-derived checks:
  - The marker must exist (i.e. `/rtl review` has run at least once).
  - `marker.last_reviewed_sha` must equal the PR's current `head.sha` —
    if commits have landed since the last review, the bot replies
    "run `/rtl re-review` first" instead of approving stale code.
  - Every entry in `marker.findings` must have status `addressed` or
    `withdrawn`, or appear in `marker.dismissed_findings`. Findings
    with status `unresolved` or `partially_addressed` (and not
    dismissed) block approval; the handler posts the open list.
  On success the marker gains `approved_by` and `approved_at` audit
  fields, the trigger comment receives a 👍, and the formal APPROVE
  shows up in the PR's review timeline. New files:
  - `scripts/handlers/handle-approve.sh`
  - `tests/unit/handle-approve.bats` (happy + each rejection path)
- `approve` added to `scripts/parse-command.sh` `KNOWN_COMMANDS` and
  to the maintainer-required dispatch group in `scripts/run-review.sh`.
- `docs/commands.md` — full per-command writeup including the
  branch-protection caveat (the bot's APPROVE counts toward
  required-approvers gates; configure protection accordingly).

### Changed
- `skills/code-review/SKILL.md` — clarified the skill-vs-orchestrator
  split: the skill itself still produces only `REQUEST_CHANGES` /
  `COMMENT`; the orchestrator now emits `APPROVE` separately via the
  new handler. The "no LGTM-only output" anti-pattern still applies
  to skill output.

### Removed
- `.github/workflows/review.yml` — the deprecated reusable workflow
  shipped in v0.5.x and soft-deprecated in v0.8.0. Consumers on v0.7.x
  pins continue to work (their pin references the v0.7.x copy of the
  file). New consumers must use the composite action at
  `.github/actions/review` per `docs/consumer-setup.md` Part 2 Step 3.
- `README.md` and `docs/consumer-setup.md` updated to reflect that
  the composite action is now the only supported entry point.

## [0.8.1] — 2026-05-01

### Changed
- Inline review comments now begin with a severity-coded emoji
  (🔴 blocker, 🟠 major, 🟡 minor, 🔵 nit). The textual severity word is
  retained right after — the emoji is purely visual triage. Body summary
  / `prior status` listings and the `/rtl explain` reply are intentionally
  unchanged in this release.
- `scripts/post-review.sh` comment-ID lookup regex relaxed (drops the
  `^` anchor) so it tolerates the new optional emoji prefix without a
  hard-coded codepoint allowlist.

## [0.8.0] — 2026-05-01

Composite-action refactor — packaging change so the rtlreviewbot repo
can be re-privated. No functional change to `/rtl <command>` behavior.

### Added
- `.github/actions/review/action.yml` — composite action that becomes
  the v0.8.0+ consumer entry point. Same script body
  (`scripts/run-review.sh`) is invoked, but consumers reach it via
  `uses: Ride-The-Lightning/rtlreviewbot/.github/actions/review@v0.8.0`
  inside their own job's `steps:`, with credentials passed as `with:`
  inputs instead of a `secrets:` block. GitHub's runner orchestration
  fetches the action repo automatically — consumer workflows no longer
  need an `actions/checkout` of rtlreviewbot, which means the bot can
  finally be made private (the missing piece since v0.5.x).

### Changed
- `docs/consumer-setup.md` Part 2 Step 3 rewritten around the composite
  action. Shape is breaking for consumers upgrading from v0.7.x: there
  is no longer a top-level `secrets:` block; every value moves into
  `with:`. A migration table is included in Step 3. Pinned refs in the
  example bumped to `v0.8.0`.
- `scripts/fetch-pr-context.sh` — `MAX_DIFF_CHARS` default bumped from
  200000 to 300000. Per-run override via `RTL_MAX_DIFF_CHARS` or the
  `--max-diff-chars` flag is unaffected. `config/defaults.yml` is still
  unwired; reading it as authoritative is deferred to v0.9.0.

### Deprecated
- `.github/workflows/review.yml` (the reusable workflow). It still
  works while rtlreviewbot is public and now emits a `::warning::` on
  every run pointing at the composite-action migration. Removal
  planned for v0.9.0. The workflow's internal `actions/checkout` of
  this repo uses the consumer's `GITHUB_TOKEN`, which cannot read the
  repo once it is private — that is the underlying reason for the
  move.

### Fixed
- Workflow inputs are routed through the `env:` block instead of
  substituted directly into the `run:` script body. Direct substitution
  let any shell metacharacter in an input value (notably backticks and
  parentheses inside `comment_body`) trigger command-substitution and
  subshell parsing, crashing the run before `run-review.sh` could even
  start its loop-prevention check. It also exposed a shell-injection
  surface to anyone able to post a `/rtl` comment. Latent since v0.5.x;
  surfaced when the v0.8.0 smoke run re-fired on a marker comment that
  contained backtick-wrapped CSS selectors and `(...)` fragments.
  Fixed in both `.github/actions/review/action.yml` and the deprecated
  `.github/workflows/review.yml`.

### Notes
- Migrating an existing consumer from v0.7.x to v0.8.0 is a workflow-
  shim shape change, not just a tag bump. Walk through the new
  `docs/consumer-setup.md` Part 2 Step 3 example end-to-end.
- After v0.8.0 ships and the smoke test on `Ride-The-Lightning/RTL-Web`
  is green, the rtlreviewbot repo can be re-privated. Required
  follow-up settings on this repo:
  Settings → Actions → General → Access → "Accessible from
  repositories in the 'Ride-The-Lightning' organization." Same-org
  consumers can then continue to fetch the composite action.

## [0.7.0] — 2026-05-01

Claude-invoking command handlers — the second half of M6. `/rtl
re-review` and `/rtl explain` are now real instead of stubs. Combined
with the v0.6.0 state-management handlers, every documented `/rtl <cmd>`
in `docs/commands.md` is now implemented.

### Added
- `scripts/lib/invoke-claude.sh` — source-only library with the auth-
  fallback (api → oauth) Claude invocation loop. Two public functions:
  - `invoke_claude_for_review` — for handlers that produce a structured
    review (parser-as-oracle: success requires both exit 0 and parser
    acceptance). Used by `handle-review.sh` and `handle-re-review.sh`.
  - `invoke_claude_raw` — for handlers that produce plain markdown
    text. Success requires exit 0, non-empty output (≥50 bytes), and
    that the output does not match a known soft-failure pattern
    ("Credit balance is too low", rate-limit messages, invalid-key
    messages). Used by `handle-explain.sh`.
- `scripts/handlers/handle-explain.sh` — full FR-5 flow. Reads the
  marker, validates the finding id, fetches PR context, injects a
  `target_finding` block, invokes Claude, posts the response. If the
  finding has an `inline_comment_id`, the response goes as a reply on
  the original inline thread; otherwise as a top-level PR comment with
  a "(re: F<id>)" preamble.
- `scripts/handlers/handle-re-review.sh` — full FR-2 flow. Preconditions
  (open / rtl-active / not paused / marker exists). HEAD-SHA short-
  circuit when nothing has changed since the last review. Fetches PR
  context, injects the `prior` block from the marker, invokes Claude,
  posts the formal review (post-review handles status-aware body
  composition), merges the marker (prior-finding fields preserved with
  status updates from the parser; new findings appended with current
  HEAD as `first_raised_sha`; dismissed_findings carry over).
- bats coverage for both new handlers under
  `tests/unit/handle-explain.bats` and `tests/unit/handle-re-review.bats`.

### Changed
- `scripts/handlers/handle-review.sh` refactored to use
  `invoke_claude_for_review` from the new lib. The script is ~100 lines
  shorter; behavior is unchanged.
- `docs/consumer-setup.md` Step 3 shim example: documents the
  `comment_id` input that v0.6.0 added (carryover — older shims that
  omit it lose the 👍-reaction UX but otherwise still work). Pinned
  refs bumped to `v0.7.0`.
- `docs/commands.md` per-command details for `re-review` and `explain`
  updated from stub framing to actual behavior.

### Notes
- The reusable workflow accepts the same auth secrets and inputs as
  v0.6.0; no consumer-shim changes are required to consume v0.7.0
  beyond bumping the pinned ref.
- `handle-rerequest.sh` (the listener for the never-firing
  `pull_request review_requested` event) remains a silent no-op; the
  `/rtl re-review` comment command is the supported re-review path.

## [0.6.0] — 2026-05-01

State-management command handlers — the first half of M6. The four
non-Claude-invoking commands (`stop`, `pause`, `resume`, `dismiss`) and
the PR-close cleanup handler are now real instead of "not yet
implemented" stubs. Smoke testing on a sandbox PR is the natural next
step before tagging v0.7.0 with the Claude-invoking handlers
(`re-review`, `explain`).

### Added
- Shared shell libraries:
  - `scripts/lib/comment-ops.sh` — source-only helpers for posting,
    editing, reacting to, and replying to GitHub PR comments. Replaces
    inlined `gh api` blocks across handlers.
  - `scripts/lib/labels.sh` — `add_label`, `remove_label`, `has_label`.
- `scripts/handlers/handle-stop.sh` — full FR `/rtl stop` flow. Removes
  `rtl-active` and `rtl-paused`. The metadata marker is left intact.
- `scripts/handlers/handle-pause.sh` — full `/rtl pause` flow. Adds
  `rtl-paused` while leaving `rtl-active` in place. Re-reviews are
  suppressed while paused.
- `scripts/handlers/handle-resume.sh` — full `/rtl resume` flow.
- `scripts/handlers/handle-dismiss.sh` — full `/rtl dismiss <id>
  [reason]` flow. Reads marker, validates id, appends to
  `dismissed_findings`, writes marker. If the finding has an
  `inline_comment_id`, also edits the original inline comment to prepend
  a dismissal banner so readers see the dismissal alongside the
  original concern.
- `scripts/handlers/handle-close.sh` — full PR-close cleanup. Strips
  labels and appends a terminal record (`closed_at`, `merged`) to the
  marker.
- `--comment-id` plumbing: `.github/workflows/review.yml` accepts a new
  `comment_id` input; `run-review.sh` forwards it to handlers via
  `--comment-id`. Used so state-management handlers can react (👍) on
  the triggering comment.
- bats coverage for each new handler under `tests/unit/handle-*.bats`.

### Changed
- Marker schema bumped to `version: "1.1"`. Each finding now includes
  `body` (verbatim Claude finding text) and `inline_comment_id` (the
  GitHub comment ID assigned when the review was posted, or `null` if
  the finding was demoted to the body). v0.7.0's re-review and explain
  handlers will rely on both; v0.6.0's dismiss already uses
  `inline_comment_id` for the inline-edit UX.
- `scripts/post-review.sh` now follows the review POST with a GET on
  `/pulls/N/reviews/<id>/comments` to retrieve the assigned comment
  ids. Returns a `finding_comment_ids` map (`{F1: 12345, ...}`) in its
  output JSON. Failure of this follow-up call is non-fatal — the
  review is still posted, the marker just records `null` ids.
- `scripts/handlers/handle-review.sh` now writes `body` and
  `inline_comment_id` per finding into the marker.
- Per-handler success UX: 👍 reaction on the triggering comment via the
  new `--comment-id` plumbing. Errors continue to post visible
  explanatory comments. Net effect: routine state-management commands
  no longer add comment-thread noise.
- `docs/commands.md`: per-command details for `stop`/`pause`/`resume`/
  `dismiss`/`close` updated from "(stub)" framing to actual behavior.

### Notes
- Markers written by v0.5.x lack `body` and `inline_comment_id`. v0.6.0
  handlers tolerate the missing fields gracefully — `dismiss` still
  works against an old marker, the inline-edit step just no-ops.
- Re-review and explain handlers remain stubs in v0.6.0; they ship in
  v0.7.0.

## [0.5.5] — 2026-05-01

Pivot re-review trigger from the GitHub "Re-request review" UI button to
the `/rtl re-review` comment command. The button cannot work for our
bot: GitHub's `requested_reviewers` API silently rejects App accounts
(it returns 200 but does not actually attach the App), so the bot is
never in the reviewers sidebar where the button lives.

This was discovered on the first end-to-end smoke test against
`Ride-The-Lightning/RTL-Web` PR #2 — the bot's review posted cleanly
but no Re-request review affordance appeared.

### Changed
- `scripts/handlers/handle-review.sh`: removed the no-op "best-effort
  reviewer add" step. The API call always silently failed for App
  accounts; removing it cuts ~1 second of latency and a misleading log
  line per review.
- `scripts/handlers/handle-review.sh`: the holding comment's success
  message now ends with a 🔁 CTA pointing users at `/rtl re-review`,
  `/rtl dismiss <id>`, and `/rtl explain <id>`. Mimics the affordance
  of the native button without depending on the App-as-reviewer path.
- `docs/commands.md`: invocation section explicitly notes the GitHub
  API limitation and pins `/rtl re-review` as the canonical re-review
  trigger. The "Re-request review button" row in the other-triggers
  table is removed; a forward-compat note about the workflow listener
  remains.

### Notes
- The reusable workflow still listens for `pull_request review_requested`
  events. The listener is a free no-op today and would auto-enable if
  GitHub ever opens up App accounts on the requested-reviewers API.
- `handle-re-review.sh` is still a stub. Wiring it up is the next
  natural milestone — full FR-2 flow against the metadata marker.

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
