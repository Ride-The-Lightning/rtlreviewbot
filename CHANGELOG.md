# Changelog

All notable changes to rtlreviewbot are recorded here. The format is loosely
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

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
