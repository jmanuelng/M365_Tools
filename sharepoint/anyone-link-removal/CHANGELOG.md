# Changelog

## 1.1.0-preview.1 — 2026-11-07

Unreleased preview; offline validation only, not a live-tested stable release.

- Terminating structured nested HTTP errors and Retry-After seconds/date parsing;
  bounded transient GET retries, no automatic DELETE transport retry.
- Verify uncertain mutations before any replay; fresh strict permission allowlist
  before each possible mutation. Pause on auth/errors; never infer absence from empty200.
- Input tuple uniqueness and SHA256 output binding; durable mutation journal,
  verified-only execution checkpoints and safe unresolved-attempt restart handling.
- Timestamped every-row progress, incremental CSV, atomic summary and precise
  processed/deleted/absent/skipped/error/remaining/completion feedback.
- Cooperative request/run limits and explicit external hard-watchdog caveat.
- Default read-only, ShouldProcess/WhatIf and token role restrictions retained.
- Existing21 plus new18 offline assertions; no live-tenant operation in validation.

## 1.0.0 — 2026-11-05

Initial public tool with opt-in execution, certificate authentication and mock tests.
