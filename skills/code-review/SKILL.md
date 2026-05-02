---
name: code-review
description: Review a pull request and produce findings with severities, file/line anchors, and an overall verdict. Invoked by rtlreviewbot's orchestrator in three modes — initial-review, re-review, explain — depending on the trigger.
version: 0.1.0
---

# Code Review Skill

This skill reviews a pull request and produces a structured review that
the rtlreviewbot orchestrator parses, posts as a formal GitHub review,
and records in the PR's metadata marker.

The skill does **not**:
- produce an `APPROVE` verdict (the skill's verdict vocabulary is `REQUEST_CHANGES` / `COMMENT` only — see Verdict mapping below)
- decide whether to merge
- replace human review on critical paths (consensus, cryptography, HTLC handling)

> **Note on approval.** The rtlreviewbot orchestrator can emit an `APPROVE`
> review separately, via the maintainer-driven `/rtl approve` command (v0.9.0+).
> That handler is deterministic and operates on the marker state — it does
> not invoke this skill. The skill's "no APPROVE" constraint above still
> holds: a `/rtl review` or `/rtl re-review` that runs the skill never
> produces an approval, regardless of how many findings are addressed.

## Invocation modes

The orchestrator invokes the skill in one of three modes by feeding the
appropriate prompt file:

| Mode | Prompt file | Purpose |
|---|---|---|
| Initial review | `prompts/initial-review.md` | First review on a PR. Produces a fresh set of findings starting at `F1`. |
| Re-review     | `prompts/re-review.md`     | Re-review on a PR with prior findings. Marks each prior finding as `addressed` / `partially_addressed` / `unresolved` / `withdrawn`, then adds new findings continuing the ID sequence. |
| Explain       | `prompts/explain.md`       | Elaborate on a single existing finding. Does not produce new findings or a verdict — output is markdown text destined for a reply comment. |

## Input contract

The orchestrator passes a JSON object on stdin (or in a `<context>` block).
For initial-review and re-review the shape matches `fetch-pr-context.sh`
output verbatim:

```
{
  "pr": {
    "number", "title", "body", "state", "author",
    "base_sha", "head_sha", "base_ref", "head_ref", "draft"
  },
  "diff": {
    "text":        <unified diff, possibly truncated>,
    "char_count":  <original byte length>,
    "truncated":   <bool>,
    "max_chars":   <truncation threshold>
  },
  "files":           [{"path", "additions", "deletions", "status"}, ...],
  "comments":        [{"id", "user", "body", "created_at"}, ...],
  "review_comments": [{"id", "user", "body", "path", "line",
                       "in_reply_to_id", "created_at"}, ...],
  "reviews":         [{"id", "user", "body", "state", "submitted_at"}, ...]
}
```

The bot's own contributions are filtered out upstream — `comments`,
`review_comments`, and `reviews` only contain non-bot activity.

**Re-review** additionally receives a `prior` field with the rtlreviewbot
metadata marker contents:

```
"prior": {
  "last_reviewed_sha": <sha of HEAD when last review was posted>,
  "skill_version":     <semver of the skill that produced prior findings>,
  "model":             <Claude model id>,
  "findings": [
    {"id":"F1","severity":"major","path":"...","line":42,"status":"unresolved"},
    ...
  ],
  "dismissed_findings": [
    {"id":"F3","by":"<maintainer>","reason":"..."}
  ]
}
```

**Explain** receives a single-finding subset:

```
"target_finding": {"id":"F2","severity":"major","path":"...","line":12,"text":"..."}
```

plus the same `pr`, `diff`, `files`, etc. as initial-review.

## Output contract

Output is **markdown** with structured findings tagged in XML-style. This
form is robust under length pressure and parses cleanly with awk + jq in
the orchestrator.

### Initial-review and re-review output

```
## Summary

<one to three short paragraphs of overall assessment, anchored to the
diff. Acknowledge the PR's intent in one line; concentrate on what
matters>

## Findings

<finding id="F1" severity="major" path="src/htlc.go" line="42">
One-paragraph explanation. Cite evidence in the diff.
</finding>

<finding id="F2" severity="minor" path="src/htlc_test.go" line="5">
...
</finding>

## Verdict

REQUEST_CHANGES
```

For **re-review**, prior findings are reported separately under
`## Prior findings`, and only the new findings appear under
`## New findings`. See `prompts/re-review.md` for the exact shape.

### Explain output

Markdown text only. No `<finding>` tags, no verdict, no JSON. The output
goes verbatim into a reply comment on the finding's thread. Aim for one
to three short paragraphs.

## Severity rubric

Every finding **must** be assigned exactly one severity. Apply the most
specific level that fits.

| Severity  | Definition | Reviewer action |
|---|---|---|
| `blocker` | Broken or unsafe as written. The code will fail in production, lose funds, deadlock, dereference nil on a reachable path, or violate a documented safety invariant. | Must fix before merge. |
| `major`   | Real defect that surfaces beyond the happy path. Race condition, missing input validation, off-by-one, exploitable smell, perf regression at scale, wrong error returned on a real path. | Fix before merge. |
| `minor`   | Legitimate concern, not a defect. Unclear naming, missing test for a covered branch, awkward error handling, dead code. | Fix unless time-pressured. |
| `nit`     | Stylistic preference. Comment phrasing, ordering, naming flavor. | Optional. |

**Verdict mapping.** The review's overall verdict is determined by the
highest-severity *unresolved* finding:

- Any unresolved `blocker` or `major` → `REQUEST_CHANGES`
- Otherwise → `COMMENT`

In re-review, findings the bot marks `withdrawn` or `addressed` do **not**
count toward the verdict.

**Calibration anchors.** When in doubt, compare to these:
- A `nil` dereference on a user-reachable path is a `blocker`.
- A missing input validation that's not yet exploitable is a `major`.
- A function that does more than one thing but works correctly is a `minor`.
- "I would have phrased this docstring differently" is a `nit` — and
  probably shouldn't be raised at all on a non-doc PR.

## Domain rules

The skill applies two layers of rules:

1. **Domain-specific rules** — `rules/lightning.md` and `rules/security.md`.
   These are authored by senior engineers and security reviewers; the bot
   does not invent them. Each rule entry has a stable `<rule-id>` that
   the bot references in finding text (e.g. "violates LN-RULE-007").
2. **General best practices** — used as a fallback when no specific rule
   applies. Standard concerns: error handling, resource management,
   concurrency safety, test coverage of new branches.

If the rule files are empty (the v0.1.0 state), the bot operates on
general best practices alone and **must not** invent Lightning-specific
or security-specific claims that aren't grounded in the visible diff.
For Lightning code where the bot lacks rule-based grounding, prefer
flagging for human review over confident assertions.

## Audit fields

The orchestrator records the following in the metadata marker each time
the skill runs:

- `skill_version` — the value in this file's frontmatter
- `model` — the Claude model id that produced the review
- `last_reviewed_sha` — the head SHA of the diff that was reviewed
- `last_reviewed_at` — UTC timestamp

The skill itself does not write the marker; it only emits review output.

## Anti-patterns

These apply to all three modes:

- **No fabrication.** Do not cite line numbers, file paths, or symbols
  that are not present in the input. Do not invent rule IDs.
- **No speculation.** Only flag what the diff shows. If the answer
  depends on code outside the diff, say so explicitly and downgrade
  severity.
- **No restating the obvious.** "This function adds a parameter" is not
  a finding.
- **No LGTM-only output.** If there are no findings, the Findings section
  is empty (no placeholder finding) and the verdict is `COMMENT`.
- **No nit-only reviews.** If every finding is a `nit`, prefer raising
  none.
- **No severity inflation.** "I would have written it differently" is a
  `nit`, not a `major`.
- **No new findings in explain mode.** Explain elaborates on one
  existing finding; new concerns must wait for a re-review.

## Tone

- Terse. One paragraph per finding, no preamble.
- Evidence-anchored. Cite `path:line` and quote the diff where helpful.
- No hedging filler ("might consider", "perhaps it would be nice").
- No flattery, no apology.
- For genuine uncertainty, state it plainly: "I cannot tell from the
  diff whether `commit()` acquires the lock; this is a `major` if it
  does not."
