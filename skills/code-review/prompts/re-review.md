# Re-review prompt

You are reviewing a pull request that you have reviewed before. Your
task is to (1) report the status of each prior finding against the
current diff, and (2) raise any new findings the new commits introduce.

You have been given a PR context object as JSON, plus a `prior` field
containing your previous review's metadata. Both shapes are documented
in `SKILL.md` under "Input contract".

The rubric, tone, and anti-patterns in `SKILL.md` apply unchanged.

## Your task

Produce a re-review in the format below. There are four sections:

1. **Summary** — one to three short paragraphs. Acknowledge what was
   addressed in one line; focus on what's still unresolved and what's
   new.
2. **Prior findings** — one `<finding>` block per ID in
   `prior.findings`, with a `status` attribute and an explanation of
   what changed.
3. **New findings** — `<finding>` blocks for concerns the new commits
   introduce. Continue the ID sequence (see "Finding ID continuity"
   below).
4. **Verdict** — `REQUEST_CHANGES` or `COMMENT`, per the rubric.

## Status values for prior findings

| Status | When to use |
|---|---|
| `addressed`           | The fix is in the diff and the concern is fully resolved. |
| `partially_addressed` | The fix is in the diff but does not fully resolve the concern. State what remains. |
| `unresolved`          | The concern is still present in the current diff. |
| `withdrawn`           | The original finding was wrong (you misread the code, the concern doesn't apply). State explicitly that the bot is retracting it and why. |

`withdrawn` is reserved for "we were wrong". Do not use it because the
author dismissed the finding (that's a separate `dismissed_findings`
list maintained outside the skill); do not use it because the author
disagreed.

Findings already in `prior.dismissed_findings` should not appear in
your output at all — the maintainer has told the bot to drop them.

## Finding ID continuity

New IDs continue from the highest existing ID. Existing IDs include
both `prior.findings` and `prior.dismissed_findings`. Examples:

- Prior had `F1`, `F2`, `F3` (none dismissed) → new findings start at `F4`.
- Prior had `F1`, `F2`; `F2` was dismissed → new findings start at `F3`
  (still continue from the max).
- Prior had `F1`–`F4`; `F2` and `F3` were `withdrawn` in an earlier
  re-review → new findings start at `F5` (withdrawn IDs are not reused).

IDs are append-only. Never reuse an ID.

## Output format reminder

```
## Summary

<text>

## Prior findings

<finding id="F1" status="addressed">
Fixed in <sha or file:line> — <one line>.
</finding>

<finding id="F2" status="unresolved" severity="minor" path="src/x.go" line="42">
Still present: <one paragraph>.
</finding>

<finding id="F3" status="withdrawn">
On second look, this was incorrect — <reason>.
</finding>

## New findings

<finding id="F4" severity="major" path="src/y.go" line="10">
<one paragraph>
</finding>

## Verdict

COMMENT
```

For `unresolved` and `partially_addressed` prior findings, include
`severity`, `path`, and `line` so the orchestrator can re-anchor the
inline comment. For `addressed` and `withdrawn`, those attributes are
optional.

## Worked example

**Input** (abbreviated): your prior review had F1 (major, missing nil
check in `commit()`) and F2 (minor, missing test). The new commit adds
the nil check in `commit()` but adds no new tests; it also introduces
a new race condition in `cancelPending()`.

**Output:**

```
## Summary

The new commit adds the nil guard to `commit()` (F1 addressed). The
test gap from F2 is unchanged. The new code in `cancelPending()`
introduces a race that is more concerning than the original findings.

## Prior findings

<finding id="F1" status="addressed">
Nil guard now at `src/htlc.go:18`, covering the indirect path. Resolved.
</finding>

<finding id="F2" status="unresolved" severity="minor" path="src/htlc_test.go" line="5">
Still no test exercising `commit(nil)` directly.
</finding>

## New findings

<finding id="F3" severity="major" path="src/htlc.go" line="55">
`cancelPending()` reads `h.state` outside the mutex acquired at line
53. If a concurrent `Settle()` mutates state between lines 55 and 58,
the cancel can act on stale data and double-spend the HTLC. Acquire
the mutex before reading.
</finding>

## Verdict

REQUEST_CHANGES
```

## Constraints

- Do not re-list `addressed` findings as if they were new.
- Do not raise a "new" finding that is actually the same concern as a
  prior one — restate the prior finding as `unresolved` instead.
- For findings in `prior.dismissed_findings`, do not raise them again
  even if they're still present in the diff.
- All other anti-patterns and tone guidance from `SKILL.md` apply.
