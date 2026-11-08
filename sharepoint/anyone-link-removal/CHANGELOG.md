# Changelog

## 1.1.0-preview.2 — 2026-11-08

Public raw-REST preview, offline tested only; no stable or live-tenant validation claim.

- Bounded transient GET retries now cover timeouts/status0,408,429,500,502,503,504
  in every phase, with configurable read retries and bounded permission200 polls.
- Exact permission404 PLUS matching underlying item200 required for VERIFIED.
  Acknowledged mutations never replay; timeout ambiguity pauses if reads remain present/unknown.
- Retry-After applies before reconciliation reads as well as explicit transient
  mutation retries. Permanent/auth errors stop immediately; invalid delays fail closed.
- Fsynced per-phase request receipts and mutation intents/responses/proofs; persistence
  failures do not become blind mutation retries. Journal, not done.txt, owns resume.
- Explicit Resume, input approval-hash option, identity/mode binding and output lock.
  Legacy/missing-context proofs are re-read; corrupt/out-of-scope journals fail closed.
- Distinct invocation/execution completion, historical/current failures and unresolved
  counts; offset timestamps, phase backoff and safe-pause reasons. UTC/Stopwatch clock
  guard remains cooperative; independent suspend-aware supervision is still required.
- Complete parameter help, approval/dry-run/resume/reconciliation examples, recovery
  state machine, progress table, security/restore limits and inline WHY comments.
- Existing21 + safety18 + new reliability101 assertions pass (140 total).
  Added public transport fault injection and crash/restart/documentation tests;
  no credentials or live requests in any validation suite.

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
