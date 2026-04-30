## Summary

The PR adds a guard against nil HTLCs in `Settle()`, addressing the
panic reported in #123. The accompanying test covers the new guard but
leaves the indirect path through `commit()` untested.

## Findings

<finding id="F1" severity="major" path="src/htlc.go" line="18">
`commit()` is called from `Settle()` after the new nil check at line
12, but `commit()` itself dereferences `h.state` without checking for
nil. Move the guard into `commit()` or document the precondition.
</finding>

<finding id="F2" severity="minor" path="src/htlc_test.go" line="5">
`TestSettleNil` verifies the nil-from-Settle path but not the path
through `commit()` directly.
</finding>

## Verdict

REQUEST_CHANGES
