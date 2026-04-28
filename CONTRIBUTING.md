# Contributing to rtlreviewbot

## Local development

You'll need:
- Bash 4+ (the macOS default `bash` 3.2 also works for the production
  scripts, but tests assume `bats-core` is installed)
- `openssl`, `jq`, `curl` — present on standard Linux and macOS
- `shellcheck` and `actionlint` for local linting (optional but matches CI)
- `bats-core` for running unit tests:
  ```bash
  git clone --depth 1 --branch v1.10.0 https://github.com/bats-core/bats-core.git /tmp/bats-core
  sudo /tmp/bats-core/install.sh /usr/local
  ```

Run unit tests:
```bash
bats tests/unit/
```

Lint:
```bash
find scripts -name '*.sh' -print0 | xargs -0 shellcheck
actionlint
```

## Code style

- All shell scripts start with `#!/usr/bin/env bash` and `set -euo pipefail`.
- All scripts must be idempotent and safe to retry.
- Exit codes: `0` success, `1` user-facing error (post comment), `2` system
  error (fail workflow).
- stdout is for structured output consumed by other scripts (JSON only);
  stderr is for logs (one JSON object per line).
- Never log token values, private keys, or full secret env vars.
- Prefer `gh` CLI over raw `curl` for GitHub API calls — except where the
  caller is providing its own JWT (e.g. `authenticate.sh`).

## Commits

- Group related changes into a single commit; do not interleave unrelated
  work.
- Reference the relevant milestone (e.g. `M1.3`) in the commit body when
  applicable.
- Do not commit secrets. The `.gitignore` defensively excludes `*.pem` —
  if you find yourself wanting to add a key file to the repo, stop and
  rethink.

## Releases

Releases are cut from `main` via `git tag vX.Y.Z`. Consumer repos pin to
specific tags in their workflow shims, so breaking changes must bump the
major version.
