# Onboarding a consumer repo

This document covers two things:

1. **One-time setup** — registering the rtlreviewbot GitHub App and storing its
   credentials at the org level. Done once per organization.
2. **Per-repo onboarding** — installing the App on a repo and adding the
   workflow shim that calls the rtlreviewbot reusable workflow.

> **Status:** v0.1.0 documents the App registration and credential storage.
> The reusable workflow body and consumer shim example are placeholders that
> will be completed in subsequent milestones.

---

## Part 1 — One-time setup (per organization)

### Architecture context

rtlreviewbot uses a **reusable workflow** (Pattern 1). The bot's logic lives
in this repo (`Ride-The-Lightning/rtlreviewbot`) and is invoked from each
consumer repo's own GitHub Actions runners. The GitHub App is purely an
**identity / auth surface** — it mints short-lived installation tokens. There
is no hosted service and the App does not need webhook subscriptions.

### Step 1 — Decide the App owner

Recommended: an organization, not a personal account. Org-owned Apps can be
managed by org admins and installed on any repo in the org. Secrets live at
the org level.

### Step 2 — Open the App creation form

- Org-owned: `https://github.com/organizations/<ORG>/settings/apps/new`
- User-owned: `https://github.com/settings/apps/new`

### Step 3 — Identity fields

| Field | Value |
|---|---|
| GitHub App name | `rtlreviewbot` (must be globally unique on GitHub; suffix if taken) |
| Description | `Maintainer-invoked Claude-powered code review bot for pull requests.` |
| Homepage URL | the URL of this repo |
| Identifying and authorizing users → Callback URL | leave blank |
| Post installation → Setup URL | leave blank |
| Request user authorization (OAuth) during installation | unchecked |

### Step 4 — Webhook section

| Field | Value |
|---|---|
| Active | **uncheck this box** |
| Webhook URL | leave blank |
| Webhook secret | leave blank |

The bot is triggered by GitHub Actions events in each consumer repo, not by
webhooks delivered to a server. Disabling webhooks here keeps the App's
attack surface minimal.

### Step 5 — Permissions

Default everything to **No access**. Only change:

**Repository permissions**

| Permission | Access | Why |
|---|---|---|
| Contents | Read-only | Read diffs / file contents |
| Issues | Read & write | Post and edit PR comments (PR comments are issue comments under the hood) |
| Pull requests | Read & write | Fetch PR data, submit formal reviews |
| Metadata | Read-only | (mandatory — auto-set, can't change) |

**Organization permissions**

| Permission | Access | Why |
|---|---|---|
| Members | Read-only | Permission checks for `/rtl` commands |

> Note: GitHub bundles "PR reviews write" into "Pull requests: Read & write" —
> there is no separate toggle. The set above covers everything the bot needs.

### Step 6 — Installation scope

Choose **Only on this account** initially. You can widen to "Any account"
later. It is much easier to widen than to narrow.

### Step 7 — Create the App

Click **Create GitHub App**. Record:

- App ID (shown near the top of the App settings page)
- Public link (`https://github.com/apps/<slug>`)

### Step 8 — Generate a private key

App settings page → **Private keys** → **Generate a private key**. A `.pem`
file downloads. **Treat it like a password.**

- Move it outside the working tree (e.g. `~/.secrets/rtlreviewbot.pem`)
- `chmod 600 ~/.secrets/rtlreviewbot.pem`
- Never commit it. (This repo's `.gitignore` defensively excludes `*.pem`.)

### Step 9 — Store credentials as org secrets

Org Settings → Secrets and variables → Actions → New organization secret.

| Secret name | Value | Visibility |
|---|---|---|
| `GATEWAY_APP_ID` | the numeric App ID from Step 7 | Selected repositories — start narrow |
| `GATEWAY_PRIVATE_KEY` | full PEM contents (include `-----BEGIN…-----` and `-----END…-----` lines) | Selected repositories — start narrow |
| `ANTHROPIC_API_KEY` (optional) | Anthropic API key with access to the configured Claude model. Per-token billing on the Anthropic API. | Selected repositories — start narrow |
| `CLAUDE_CODE_OAUTH_TOKEN` (optional) | Long-lived OAuth token tied to a Claude.ai account. Generated locally by running `claude /login` then `claude setup-token`. Bills against the signed-in account's Pro/Max/Team subscription quota. | Selected repositories — start narrow |

> The `GATEWAY_` prefix on the App-credential secrets is retained from the
> original architecture primer. The visible bot identity is rtlreviewbot;
> the secret names are an internal implementation detail.
>
> **Claude auth: at least one of the two Claude-related secrets must be
> set.** Either alone works. If you set both, the bot tries
> `ANTHROPIC_API_KEY` first per `/rtl review` invocation and falls back
> to `CLAUDE_CODE_OAUTH_TOKEN` if the API path fails (auth error, credit
> exhausted, soft "Credit balance is too low" output, or any case where
> the response is not a parseable review). This gives you continuity
> through transient API-side outages without losing per-call billing
> visibility when the API path is healthy.
>
> Both forms cost real money under different billing models. Treat each
> as a real secret.

Installation IDs are **not** secrets — they are not sensitive and can be
discovered at runtime via `GET /app/installations`.

### Step 10 — Sanity-check the App

From a workstation with the PEM available:

```bash
APP_ID=<your app id>
PEM=~/.secrets/rtlreviewbot.pem

NOW=$(date +%s)
HEADER=$(printf '{"alg":"RS256","typ":"JWT"}' | base64 | tr -d '=' | tr '/+' '_-')
PAYLOAD=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' $((NOW-60)) $((NOW+540)) "$APP_ID" \
  | base64 | tr -d '=' | tr '/+' '_-')
SIG=$(printf '%s.%s' "$HEADER" "$PAYLOAD" \
  | openssl dgst -sha256 -sign "$PEM" \
  | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
JWT="$HEADER.$PAYLOAD.$SIG"

curl -sS -H "Authorization: Bearer $JWT" \
  -H "Accept: application/vnd.github+json" \
  https://api.github.com/app | jq '.name, .permissions, .events'
```

Expected output: the App's name, the permissions set in Step 5, and an empty
`events` array (since webhooks are disabled).

This confirms the App, key, and permissions are wired correctly before any
consumer onboarding.

---

## Part 2 — Per-repo onboarding

### Step 1 — Install the App

On the App settings page → **Install App** → choose the org → select the
target repo (or "All repositories").

The Installation ID appears in the install URL:
`https://github.com/organizations/<ORG>/settings/installations/<INSTALLATION_ID>`

Record the Installation ID for the consumer repo (only needed if the consumer
shim hard-codes it; the App can otherwise look it up at runtime).

### Step 2 — Grant the consumer repo access to the org secrets

In Org Settings → Secrets, edit `GATEWAY_APP_ID` and `GATEWAY_PRIVATE_KEY` and
add the consumer repo to the selected-repositories list.

### Step 3 — Add the workflow shim to the consumer repo

The canonical shim lives in this repo at
[`templates/rtlreviewbot.yml`](../templates/rtlreviewbot.yml). Copy it
to your repo at `.github/workflows/rtlreviewbot.yml` and customize the
two placeholders (release tag pin and `installation_id`):

```yaml
name: rtlreviewbot

# rtlreviewbot fires on:
#   - issue_comment.created      — a /rtl <command> comment on a PR
#   - pull_request.review_requested — the GitHub Re-request review button
#   - pull_request.closed        — cleanup on close/merge
on:
  issue_comment:
    types: [created]
  pull_request:
    types: [review_requested, closed]

permissions:
  # The composite action mints an App installation token internally; the
  # GITHUB_TOKEN handed to this shim is unused, so we minimise it.
  contents: read

jobs:
  review:
    # issue_comment fires for any issue. Filter to PR comments only.
    if: ${{ github.event_name != 'issue_comment' || github.event.issue.pull_request != null }}
    runs-on: ubuntu-latest
    timeout-minutes: 15
    steps:
      - uses: Ride-The-Lightning/rtlreviewbot/.github/actions/review@v0.9.0
        with:
          event_name:      ${{ github.event_name }}
          event_action:    ${{ github.event.action }}
          repo:            ${{ github.repository }}
          pr_number:       ${{ github.event.issue.number || github.event.pull_request.number }}
          actor:           ${{ github.event.sender.login }}
          comment_body:    ${{ github.event.comment.body }}
          comment_id:      ${{ github.event.comment.id }}
          installation_id: 127679607          # see Part 2 Step 1
          # Credentials — passed as `with:` inputs since composite
          # actions cannot declare a `secrets:` block. At least one of
          # anthropic_api_key or claude_code_oauth_token must be set;
          # if both are set, API is tried first and OAuth is the
          # fallback. Setting neither makes /rtl review fail with a
          # clear "no auth credential" error.
          app_id:                  ${{ secrets.GATEWAY_APP_ID }}
          private_key:             ${{ secrets.GATEWAY_PRIVATE_KEY }}
          anthropic_api_key:       ${{ secrets.ANTHROPIC_API_KEY }}
          claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

Notes:

- **Pin the `uses:` ref to a release tag** (e.g. `v0.8.0`). Floating refs
  like `@main` are not supported in production. Unlike v0.7.x, there is
  only one place to pin — the separate `ref:` input is gone.
- **`comment_id` is required for reaction-based UX.** The state-management
  commands (`/rtl pause`/`resume`/`stop`/`dismiss`) acknowledge success
  with a 👍 reaction on the triggering comment. If `comment_id` is empty
  the reaction is silently skipped — the command still works, but you
  lose the visual feedback.
- **`installation_id`** is the consumer-repo-specific App installation
  ID from Part 2 Step 1. It is not a secret — the architecture primer
  explains why; treat it as a hard-coded literal in the shim.
- **At least one of `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN`**
  must be added to the consumer repo's secret scope alongside the App
  credentials. Either alone works; setting both enables fallback (API
  attempted first, OAuth on failure). See Part 1 Step 9 for the full
  table.

#### Migrating from v0.7.x

The shim shape changed in v0.8.0. The functional behavior of every
`/rtl <command>` is unchanged — this is purely a packaging change so
the rtlreviewbot repo can be re-privated.

| v0.7.x (deprecated) | v0.8.0+ |
|---|---|
| `uses: …/rtlreviewbot/.github/workflows/review.yml@<TAG>` at the **job** level | `uses: …/rtlreviewbot/.github/actions/review@<TAG>` as a **step** inside the job |
| Top-level `secrets:` block alongside `with:` | All values (including credentials) under a single `with:` block |
| Separate `ref:` input duplicating the `uses:` pin | Single pin, on `uses:` |
| Job declared via `jobs.<id>.uses:` (no `runs-on:`) | Job declares its own `runs-on:` and contains a normal `steps:` list |

The `pull_request.review_requested` and `pull_request.closed` events,
the `issue_comment.created` filter, the `permissions: contents: read`,
and every input field name are unchanged. Replace the body of the
shim's `jobs.review:` with the example above.

The v0.7.x reusable workflow was removed in v0.9.0. Existing v0.7.x
consumer pins continue to work because they reference the v0.7.x copy
of the reusable workflow at the v0.7.x tag — but new consumers must
use the composite-action shape above. v0.8.0 retained the reusable
workflow with a deprecation warning as a soft-landing window.

### Step 4 — Optional per-repo configuration

A consumer repo may add `.github/rtlreviewbot-config.yml` to override defaults
from `config/defaults.yml`. Schema is documented in that file.

### Step 5 — Verify the integration

Once Steps 1-3 are in place and the workflow file is committed:

1. Open (or pick) a PR with a small diff (under 300k characters).
2. Comment `/rtl review` on the PR.
3. Within ~30-60 seconds the bot should:
   - Acknowledge the request (the workflow run appears under the
     repo's Actions tab — look for the `rtlreviewbot` workflow).
   - Post a formal review on the PR with verdict `COMMENT` or
     `REQUEST_CHANGES` and (usually) one or more inline findings
     anchored to specific lines. Severity is rendered as a leading
     emoji per `🔴 blocker / 🟠 major / 🟡 minor / 🔵 nit`.
   - Append a metadata marker comment (a hidden HTML-comment block
     that drives `/rtl re-review`, `/rtl explain`, and `/rtl approve`).

If nothing happens, check the workflow run logs in the Actions tab.
The most common first-time failures are:

- **Authentication errors** — the App credentials (`GATEWAY_APP_ID`,
  `GATEWAY_PRIVATE_KEY`) are missing from the repo's secret scope or
  the App is not installed on this repo. Re-do Steps 1-2.
- **`installation_id` mismatch** — the value in the workflow shim
  must match the App's installation id on *this* repo, not on the
  org. Re-fetch from the URL in Step 1.
- **Diff size ceiling** — the bot skips PRs whose diff exceeds 300k
  characters with a polite skip-comment. Test on a smaller PR.

Once `/rtl review` works, the rest of the `/rtl <command>` surface is
documented in [`docs/commands.md`](commands.md).

---

## Reference values for this test environment

| Field | Value |
|---|---|
| Owner org | `Ride-The-Lightning` |
| App name | `rtlreview` |
| App ID | `3524153` |
| Test consumer repo | `Ride-The-Lightning/RTL-Web` |
| Test installation ID | `127679607` |
