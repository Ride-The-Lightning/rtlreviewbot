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
| `ANTHROPIC_API_KEY` | Anthropic API key with access to the configured Claude model | Selected repositories — start narrow |

> The `GATEWAY_` prefix on the App-credential secrets is retained from the
> original architecture primer. The visible bot identity is rtlreviewbot;
> the secret names are an internal implementation detail.
>
> `ANTHROPIC_API_KEY` is the API key the `/code-review` skill uses to call
> Claude. Treat it as a real secret — it's billed against your Anthropic
> account whenever the bot runs.

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

Drop the following file at `.github/workflows/rtlreviewbot.yml` in the
consumer repo. It catches the relevant GitHub events and forwards
normalized inputs to the reusable workflow.

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
  # The reusable workflow uses an App installation token internally; the
  # GITHUB_TOKEN handed to this shim is unused, so we minimise it.
  contents: read

jobs:
  review:
    # issue_comment fires for any issue. Filter to PR comments only.
    if: ${{ github.event_name != 'issue_comment' || github.event.issue.pull_request != null }}
    uses: Ride-The-Lightning/rtlreviewbot/.github/workflows/review.yml@v0.5.0
    with:
      event_name:      ${{ github.event_name }}
      event_action:    ${{ github.event.action }}
      repo:            ${{ github.repository }}
      pr_number:       >-
        ${{ github.event.issue.number || github.event.pull_request.number }}
      actor:           ${{ github.event.sender.login }}
      comment_body:    ${{ github.event.comment.body }}
      installation_id: 127679607          # see Part 2 Step 1
      ref:             v0.5.0             # pin to a release tag in production
    secrets:
      app_id:            ${{ secrets.GATEWAY_APP_ID }}
      private_key:       ${{ secrets.GATEWAY_PRIVATE_KEY }}
      anthropic_api_key: ${{ secrets.ANTHROPIC_API_KEY }}
```

Notes:

- **Pin the `uses:` ref and `ref:` input to the same release tag.** They
  both control which version of rtlreviewbot runs; mismatched values
  cause subtle drift. The example uses `v0.5.0` as a placeholder — pin
  to whatever tag matches the rtlreviewbot release you're consuming.
- **`installation_id`** is the consumer-repo-specific App installation
  ID from Part 2 Step 1. It's not a secret — the architecture primer
  explains why; treat it as a hard-coded literal in the shim.
- **`ANTHROPIC_API_KEY`** must be added to the consumer repo's secret
  scope alongside `GATEWAY_APP_ID` and `GATEWAY_PRIVATE_KEY`.

### Step 4 — Optional per-repo configuration

A consumer repo may add `.github/rtlreviewbot-config.yml` to override defaults
from `config/defaults.yml`. Schema is documented in that file.

---

## Reference values for this test environment

| Field | Value |
|---|---|
| Owner org | `Ride-The-Lightning` |
| App name | `rtlreview` |
| App ID | `3524153` |
| Test consumer repo | `Ride-The-Lightning/RTL-Web` |
| Test installation ID | `127679607` |
