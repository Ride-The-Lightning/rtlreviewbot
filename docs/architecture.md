# Architecture

Placeholder. Implementation pending.

This document will cover:

- The three-layer architecture (GitHub App, this repo, consumer repos)
- The reusable workflow execution model
- State model: PR labels (`rtl-active`, `rtl-paused`) and
  the hidden `rtlreviewbot-meta` marker comment
- Finding ID lifecycle and statuses
- Security constraints (fork safety, token scope, audit trail)

The original architecture primer that motivated this work lives in the
project root (gitignored) and will be folded into this file once the
implementation is far enough along to justify a stable architecture document.
