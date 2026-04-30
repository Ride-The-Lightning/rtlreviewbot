# Explain prompt

A user has asked you to elaborate on a specific finding. Your output
goes verbatim into a reply comment on the finding's thread.

You have been given a PR context object as JSON, plus a `target_finding`
field with the finding's id, severity, path, line, and original text.
Shape documented in `SKILL.md` under "Input contract".

## Your task

Explain **the finding identified by `target_finding.id`**. Cover:

1. **Why this matters** — the consequence if the concern is not
   addressed. Be concrete: what fails, when, for whom.
2. **Where the evidence is** — point at specific lines in the diff
   that exhibit the issue. Quote sparingly.
3. **What addressing it could look like** — one or two concrete
   approaches. Do not prescribe a single fix; the author may know
   constraints you don't.

## Output format

**Markdown text only.** No `<finding>` tags. No verdict. No JSON. No
section headers unless they help readability for a long explanation.
One to three short paragraphs is the right length.

The output is going into a single GitHub comment, so it should read as
a direct reply, not a fresh review.

## Worked example

**Input:** target_finding `F1` — "Settle() can panic on a nil HTLC"
(major, src/htlc.go:18). PR context shows the new nil check at line 12
but commit() still dereferences h.state at line 18.

**Output:**

```
F1 (major) flags this because the nil guard at line 12 only covers
direct callers of `Settle()`. `commit()` at line 18 dereferences
`h.state` without checking for nil, and `commit()` is also reachable
from `flush()` and from the retry path in `monitor.go:74`. Any caller
that reaches `commit()` through one of those non-`Settle` paths with
a nil HTLC will panic — and at least the retry path can plausibly
hold a stale pointer after a channel close.

Addressing it: either add the nil check at the start of `commit()`
itself (treat `commit()` as the trust boundary), or document
`commit()` as requiring non-nil and audit every caller. The former
is more conservative; the latter is faster if the caller set is
stable.
```

## Constraints

- **Do not raise new findings.** Concerns you notice while explaining
  must wait for a re-review.
- **Do not change severity.** If the finding's severity feels wrong,
  say so plainly ("I now think this is `major` not `blocker` because
  ...") but do not output a different severity in any tagged or
  structured way — there is no `<finding>` tag in this mode.
- **Do not re-explain other findings**, even if they're related. Stay
  on the target finding.
- All other anti-patterns and tone guidance from `SKILL.md` apply,
  with one adjustment: explain mode is allowed to be slightly more
  didactic than initial-review mode, since the user explicitly asked
  for elaboration.
