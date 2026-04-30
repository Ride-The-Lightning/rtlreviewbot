## Summary

The new commit adds the nil guard to `commit()` (F1 addressed). The
test gap from F2 is unchanged. The new code in `cancelPending()`
introduces a race condition that is more concerning than the prior
findings.

## Prior findings

<finding id="F1" status="addressed">
Nil guard now at `src/htlc.go:18`, covering the indirect path. Resolved.
</finding>

<finding id="F2" status="unresolved" severity="minor" path="src/htlc_test.go" line="5">
Still no test exercising `commit(nil)` directly.
</finding>

<finding id="F3" status="withdrawn">
On second look, this was incorrect — the deadlock path is impossible
because of the mutex acquired earlier.
</finding>

## New findings

<finding id="F4" severity="major" path="src/htlc.go" line="55">
`cancelPending()` reads `h.state` outside the mutex acquired at line
53. Acquire the mutex before reading.
</finding>

## Verdict

REQUEST_CHANGES
