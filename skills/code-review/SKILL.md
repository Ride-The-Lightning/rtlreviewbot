---
name: code-review
description: Review a pull request using domain rules and produce findings with severities, file/line anchors, and an overall verdict.
version: 0.1.0
---

# Code Review Skill

Placeholder. Implementation pending in a later milestone.

## Inputs (planned)
- PR diff
- PR description and title
- Existing review comments (for re-review context)
- Set of relevant rules from `rules/`

## Outputs (planned)
- Review body (summary + overall assessment)
- Inline comments anchored to file + line, each tagged with severity and finding ID
- Overall verdict: `REQUEST_CHANGES` (any blocker/major) or `COMMENT` (otherwise)

## Prompts
- `prompts/initial-review.md` — first-time review of a PR
- `prompts/re-review.md` — review against current HEAD given prior findings
- `prompts/explain.md` — elaborate on a specific finding

## Rules
- `rules/lightning.md` — Lightning-specific review rules (domain expert input required)
- `rules/security.md` — security review rules
