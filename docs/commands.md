# Commands reference

Placeholder. Implementation pending.

The full command surface is enumerated in the architecture primer. This file
will document each command, who can invoke it, what it does, and example
usage.

| Command | Who | Effect |
|---|---|---|
| `/rtlreviewbot review` | Maintainer | Initial review; activates the bot on this PR |
| Re-request review (UI button) | Author or anyone with push | Re-review against current HEAD |
| `/rtlreviewbot stop` | Maintainer or author | Deactivate the bot on this PR |
| `/rtlreviewbot pause` / `resume` | Maintainer or author | Temporarily deactivate / reactivate |
| `/rtlreviewbot dismiss <id>` | Maintainer | Stop flagging a specific finding |
| `/rtlreviewbot explain <id>` | Anyone | Elaborate on a finding (no new review) |
| `/rtlreviewbot re-review` | Maintainer | Force fresh review without rate-limit |
