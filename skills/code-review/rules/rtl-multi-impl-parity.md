# RTL multi-implementation parity check

> **Applies to:** any consumer repo with the RTL (Ride-The-Lightning)
> codebase layout — primarily `Ride-The-Lightning/RTL` (the production
> repo), and any staging/fork copies that share its directory structure.
> Gate on the trigger paths below, not on the repo name; if none of the
> touched files match, skip this file entirely.
>
> **Trigger paths:** PRs that modify files under
> `backend/controllers/{lnd,cln,eclair}/`,
> `backend/utils/{lnd,cln,eclair}/`,
> `backend/models/{lnd,cln,eclair}/`,
> `backend/routes/{lnd,cln,eclair}/`,
> or the frontend trees under `src/app/{lnd,cln,eclair}/`. Trigger even
> when the diff looks small. RTL supports three Lightning backends (LND,
> Core Lightning, Eclair) with parallel directory structures, and the
> single most common bug class in this repo is "fixed it for LND, forgot
> CLN and Eclair" — a silent parity drift that only surfaces for users
> on the un-updated implementation.

## Why this matters

RTL is one codebase serving three Lightning Network implementations:
- **LND** (`lnd`) — Lightning Labs' implementation, the original RTL target.
- **CLN** (`cln`) — Core Lightning by Blockstream/ACINQ-adjacent.
- **ECL** (`eclair`) — Eclair by ACINQ, JVM-based.

The backend and frontend are organized in parallel per-implementation
directories. Most features (channels, payments, invoices, peers) exist in
all three and need to behave consistently. When a contributor fixes a bug
or adds a feature for the implementation they happen to run, the other two
trees silently fall out of sync. The user running CLN doesn't learn about
the LND-only fix until they hit the same bug — which they will, because the
underlying logic was the same.

A generic reviewer doesn't know that `backend/controllers/lnd/channels.js`
has siblings under `cln/` and `eclair/`. Your job is to know this and to
ask, for every per-impl change: should this also land in the other two?

## Directory layout reference

Per-implementation code lives in parallel trees. Approximate layout (verify
against the actual repo state on first run):

```
backend/
├── controllers/
│   ├── lnd/      ← LND-specific request handlers
│   ├── cln/      ← Core Lightning request handlers
│   ├── eclair/   ← Eclair request handlers
│   └── shared/   ← Implementation-agnostic handlers
├── utils/
│   ├── (common files like connect.js, logger.js)
│   └── (some impl-specific helpers)
├── models/
│   └── (sometimes per-impl, sometimes shared)
└── routes/
    └── (typically per-impl)

src/app/
├── lnd/          ← LND Angular feature module
├── cln/          ← CLN Angular feature module
├── eclair/       ← Eclair Angular feature module
└── shared/       ← Shared services, pipes, store slices
```

The frontend modules under `src/app/{lnd,cln,eclair}/` each have their own
`store/` (NgRx actions, reducers, effects, selectors) and `transactions/`,
`peers-channels/`, `network/` subtrees. Parity concerns apply to these
slices too, not just to backend controllers.

## Categorizing a change: shared vs implementation-specific

Before flagging anything, decide which bucket the change falls in.

### Shared-semantics concepts (parity is almost always expected)

These exist in all three implementations and a logic change in one should
land in the others:

- **Channels**: open, close, force-close, list, get, balance, policy update,
  routing-fee configuration.
- **Payments**: send (single-path and multi-path/AMP-style), invoice
  decoding, payment status, payment history, route querying.
- **Invoices**: create, list, lookup, cancel, settle (where applicable).
- **Peers**: connect, disconnect, list, node info lookup.
- **Network / graph**: node info, channel graph, network metrics.
- **On-chain**: wallet balance, send on-chain, list transactions, address
  generation (where applicable).
- **Fee handling**: routing fee config, fee report, fee suggestions.
- **Forwarding history / earnings**.
- **Dashboard / summary endpoints**.

If a PR touches any of the above for one implementation only, flag it
unless the author has explicitly explained why the others are exempt.

### Implementation-specific concepts (parity is NOT expected)

These exist in one impl only and a change in one has no counterpart:

- **LND-only**: Loop (submarine swaps via Lightning Labs), Boltz (alternate
  swap provider), wallet unlocker, watchtowers, channel backup file
  (`channel.backup`) format, macaroon-specific auth, AMP keysend.
- **CLN-only**: BOLT12 offers, runes (the CLN auth primitive), plugins,
  CLNRest plugin specifics, `commando` legacy fallbacks.
- **ECL-only**: API password auth, Eclair WebSocket push subscriptions,
  Eclair's circular-rebalance flow, JVM-specific config concerns.

A PR adding or modifying any of the above does NOT require parity. Note
the categorization in your comment so the author sees you considered it.

### Gray areas

Some concepts exist in two of three implementations. Examples:

- Static channel backup files: LND has them; CLN has emergency-backup but
  different format; Eclair doesn't expose user-facing backups the same way.
- Keysend / spontaneous payments: LND and CLN support it natively; Eclair's
  support has varied across versions.
- HTLC interception / channel acceptor: LND-specific historically; CLN has
  hook-based equivalents.

When the change falls in a gray area, name the gray area explicitly and
ask the author which subset of impls applies. Don't silently treat it as
"LND-only" or "all three".

## Review procedure

For each PR, do this in order:

1. **List touched per-impl paths.** Walk the diff and collect every file
   whose path matches `backend/{controllers,utils,models,routes}/(lnd|cln|eclair)/...`
   or `src/app/(lnd|cln|eclair)/...`.

2. **Compute sibling paths.** For each touched file, replace the impl
   segment with each of the other two and check whether a sibling file
   exists in the repo. Use the actual file tree, not assumptions — the
   parallel structure is mostly symmetric but not perfectly so.

3. **Categorize the change** using the buckets above.

4. **Decide expected action:**
   - *Shared semantics + sibling exists + sibling unchanged* → flag.
   - *Shared semantics + sibling does not exist* → flag as a possible
     missing feature in the sibling impl, but soft (the impl may not
     support it).
   - *Implementation-specific* → do not flag; optionally note the
     categorization for transparency.
   - *Gray area* → ask the author which impls apply.

5. **Check the frontend mirror.** A backend controller change in
   `backend/controllers/lnd/channels.*` often has a matching frontend
   feature module slice. If the backend changes the response shape, the
   frontend NgRx effect/reducer for that impl needs to know — and so do
   the CLN and Eclair effects if their backends were also updated.

6. **Check the shared layer.** If the change is in a shared util used by
   all three impls (e.g., `backend/utils/connect.js`, common pipes,
   shared store slices), do the inverse check: does the change assume
   semantics that only hold for one impl? A shared helper that special-
   cases LND fee-rate units is at risk of breaking the others.

## Output format

If parity is missing, post a single comment per affected concept (not per
file — group them):

```
**[Multi-impl parity]** <concept name, e.g. "channel close handling">

This PR modifies `<file>` (impl: <LND|CLN|ECL>) but the equivalent path(s)
appear unchanged:
- `<sibling-1>` (impl: <other>)
- `<sibling-2>` (impl: <other>)

Categorization: **shared semantics** — <concept> exists in all three
implementations and typically needs parallel updates.

Was the omission intentional? Common reasons it might be:
- The underlying bug only affects <impl> (call this out in the PR if so).
- The sibling code path already handles this correctly (link the
  function/lines if so).
- A follow-up PR will land the other impls (link the issue).
```

If the change is implementation-specific, optionally post:

```
**[Multi-impl parity]** Categorized as <LND|CLN|ECL>-specific
(<concept>, e.g. "Loop swap integration"). Parity check skipped.
```

This second comment is optional but useful on larger PRs where it's not
obvious from the diff that the reviewer considered parity.

## Examples

**Example 1 — flag.**

Diff modifies `backend/controllers/lnd/payments.ts` to add retry logic on a
network error. `cln/payments.ts` and `eclair/payments.ts` exist and are
unchanged. Payment retry is shared semantics.
→ Flag. The same network error class probably affects the other backends.

**Example 2 — do not flag.**

Diff modifies `backend/controllers/lnd/loop.ts` to support a new Loop API
parameter. No siblings exist under `cln/` or `eclair/`.
→ Do not flag. Loop is LND-only. Optionally note the categorization.

**Example 3 — gray area, ask.**

Diff modifies `backend/controllers/cln/offers.ts` to fix BOLT12 invoice
decoding. BOLT12 is primarily CLN; Eclair has partial support; LND does
not.
→ Ask the author whether the Eclair offer path needs the same fix, and
note that LND can be excluded.

**Example 4 — shared utility, inverse check.**

Diff modifies `backend/utils/logger.js` to redact `Grpc-Metadata-Macaroon`
headers. The helper is used by all three impls.
→ Confirm that CLN and Eclair also have their auth headers redacted (rune
header for CLN, basic auth header for Eclair). The change is in a shared
file but the *implementation* might silently special-case one impl.

## When NOT to use this skill

- PRs touching only `frontend/` shared components, theme files, or `src/assets/`.
- PRs touching only documentation, samples, or CI config.
- PRs touching only one impl's feature that has no analog in the others
  (Loop, Boltz, BOLT12 offers — see the impl-specific list).
- Dependency bumps and lock-file changes.
