# Lightning-specific review rules

> **STATUS: STUB — to be filled in by senior Lightning engineers, not by Claude.**
>
> This file is the domain-knowledge surface of rtlreviewbot. The rules here
> govern what the bot flags as concerns specific to Lightning Network code:
> consensus, cryptography, HTLC handling, channel state machines, watchtower
> behavior, gossip, fee policy, on-chain interaction, etc.
>
> The bot's value depends on the quality of these rules. They must come from
> people who have written and operated production Lightning code, not from
> Claude's best guesses or generic LLM knowledge of the protocol.

## Format (proposed — open to revision by domain experts)

Each rule should be self-contained and include:

```
## <rule-id> — <short title>

**Severity:** blocker | major | minor | nit
**Applies to:** <file globs or subsystems>
**Pattern:** <what to look for>
**Why it matters:** <consequence if violated>
**Example violation:** <code snippet or anti-pattern>
**Acceptable alternatives:** <what to do instead>
```

## Rules

(none yet — to be authored by domain experts)
