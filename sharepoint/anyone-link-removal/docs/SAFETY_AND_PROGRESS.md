# Bounded execution, recovery and truthful progress

**Version 1.1.0-preview.2 · reviewed 2026-11-08 · OFFLINE TESTS ONLY.**
This public tool uses raw REST, not a private Graph SDK executor. Neither another
executor's outcomes nor its running jobs establish live validation of this code.
No stable-release or production-readiness claim is made. Validate in a test tenant,
then obtain explicit approval for an exact small production pilot.

## Before execution: exact scope and existing authorization

1. Keep a dedicated write app separate from inventory/read-only apps. Supply
   existing certificate auth and already-approved permissions; the script does not
   register apps, grant consent, change site grants or escalate after401/403.
2. Export an independently reviewed CSV. All DriveId/ItemId/LinkId values must be
   nonblank and unique. Exclusions belong upstream: do not pass excluded rows.
   Fresh state checks are **not** a refreshed audit or proof a link was never used.
3. Record its exact SHA256 in the approval and supply `-ExpectedInputSha256`.
   The optional parameter adds an independently supplied approval-byte check;
   `input_sha256.txt` always binds the folder to the first CSV. Reordering changes
   the hash. A hash by itself is not approval.
4. Run the default live dry-run, inspect plans/skips and recipient impact, then
   explicitly approve that exact cohort. `-Execute` still requires ShouldProcess;
   `-WhatIf` always prevents mutation. `-Confirm:$false` suppresses a prompt, not
   the need for actual approval. A prior successful batch grants no new scope.
5. Use a separate output folder per input/identity/mode. A file lock prevents
   concurrent writers to the same folder; it is not a distributed tenant lock.
   An external coordinator must prevent different folders targeting the same key.

## Sequential state machine

`validate/lock -> journal resume -> auth -> candidate GET -> approval -> immediate
exact-shape GET -> durable ATTEMPT -> DELETE -> durable RESPONSE -> bounded
permission verification -> matching item verification -> durable VERIFIED -> progress`

- ID must match exactly; scope must be anonymous, link.type edit, inheritedFrom
  null. A write role is insufficient. Disabling `RequireAnonymousEdit` affects only
  the CSV convenience filter, never the mutation guard.
- URI path components are escaped, not interpolated as arbitrary Graph routes.
- Only explicit permission404 means absent. Empty/malformed200 is an error.
- DELETE204 acknowledges the request; it does not establish final verification.
  A terminal checkpoint requires **permission404 AND item200 with identical ID**.
  Missing items or mismatched IDs pause; removal of the permission is not inferred
  to have retained the item merely because the DELETE succeeded.
- Permission200 after an acknowledged deletion gets at most
  `MaxVerificationPolls` extra reads (default3). Shape drift pauses. Even persistent
 200 never causes an acknowledged DELETE to be replayed.
- Changed/inherited links are SKIP, not completed deletions or replacements.

## Retry policy and error classification

| Condition | Behavior |
|---|---|
| GET transport timeout/status0,408,429,500,502,503,504 | Up to MaxReadRetries additional attempts (default3, four total) in each read phase |
| GET401/403 or another permanent status | Stop immediately; no retry, sign-in or privilege widening |
| Empty/malformed200 | Stop; never reinterpret as404 or a transient timeout |
| Retry-After integer or HTTP-date | Wait before the next request, including reconciliation reads |
| Missing Retry-After | Exponential fallback2,4,8... capped30 seconds |
| Negative/invalid/too-long/over-budget delay | Pause; never shorten the server's delay |
| DELETE200/202/204/404 | Record response; verify with reads; NEVER resend |
| DELETE timeout/status0/408/500/502 | Read reconciliation; if still present/unknown, pause without automatic resend |
| DELETE429/503/504 | Wait, reconcile exact permission plus item, then optional fresh-guarded retry up to MaxDeleteRetries (default1) |
| DELETE401/403/other permanent status | Immediate stop; no subsequent reconciliation request in that invocation |
| Receipt/checkpoint persistence failure | Stop; no blind replay; preserve evidence |

The transport has **no internal DELETE retry**. A failed verification read has its
own bounded GET retry budget; it does not authorize another mutation. Historical
transient errors stay in receipts even after later success. Current-run errors
and unresolved current outcomes must not be confused with past recovered faults.

## Durable receipts and resume

- `mutation_journal.jsonl` is authoritative. ATTEMPT is fsynced before DELETE,
  RESPONSE afterward, VERIFIED only after permission404/item200 proof. WriteThrough
  and Flush(true) improve durability; hardware/filesystem guarantees still apply.
- `request_receipts.jsonl` records key, phase, method, intent/response/exception,
  status and exception type, never raw errors, response/auth bodies, token or URI.
- `done.txt`, CSV results and atomic `summary.json` are projections, **not** a
  multi-file transaction. A crash after VERIFIED but before done.txt is recoverable
  from the journal. Do not delete the journal because a projection is stale.
- `-Resume` is required for any existing mutation journal. Same CSV bytes,
  TenantId, ClientId and mock/live context only. A mock folder cannot become live.
  Legacy done entries or VERIFIED entries lacking item proof/context are not
  trusted: exact read reconciliation is required before they can become complete.
- Crash after ATTEMPT but before RESPONSE may mean the server applied the delete.
  Resume reads first. If permission404 and matching item200, reconcile without
  any new DELETE. If permission remains, **pause for operator review**, even if
  a prior RESPONSE said204. Do not clear or edit evidence to force a resend.
- Missing original input hash, a truncated/malformed journal or a key outside the immutable CSV fails closed.
  Preserve original bytes and investigate independently; there is no repair/reset
  flag that silently discards a possible mutation intent.

### Read-only reconciliation example

Use your previously configured `$auth` splat and independently reviewed hash:

```powershell
./Remove-AnyoneLink.ps1 @auth -InputCsv ./reviewed.csv -OutputFolder ./approved-run `
    -ExpectedInputSha256 $approvedHash -Resume
```

Omitting Execute means no DELETE. An absent permission plus matching item can be
observed, but dry-run does not create VERIFIED checkpoints. After an unchanged
approval has been confirmed, `-Execute -Resume -Confirm` can checkpoint that exact
absent target without sending another DELETE. A present unresolved permission
requires operator investigation, not a new folder to evade the safeguard.

## Progress and exit semantics

Logs use ISO8601 local timestamps **with offsets**. Per-phase receipts appear
before/after requests; backoff feedback includes phase and planned delay. Every
processed row updates incremental CSV, progress.txt and atomic summary.json.

| Field/outcome | Meaning |
|---|---|
| Processed / Remaining | Rows examined / not yet examined in this invocation, not verified deletion count |
| ResumedCompleted | Journal-proven keys skipped before this invocation |
| EligibleChecked / WouldDelete | Shape-passing checks / read-only plans; not deletion counts |
| DELETED / DeletedVerified | Mutation followed by permission404 + matching item200 |
| ALREADY_ABSENT / AlreadyAbsent | No new mutation required; permission404 + item200 proof |
| SKIP / Skipped | Changed/inherited/disallowed target; not done |
| ERROR / Errors / CurrentRunErrors | Current invocation failure; pause and inspect receipts |
| HistoricalFailureResponses | Earlier unsuccessful mutation responses retained in journal; may be recovered |
| AggregateVerified | Prior journal-proven exclusions plus current verified absent outcomes; not every CSV row |
| UnresolvedProcessed | Examined ERROR rows; separate from untouched Remaining |
| Completed | Enumeration finished without a pause; can still contain dry-run/skips |
| ExecutionComplete | Execute mode, no pause, all selected rows verified, no plans/skips/errors |
| WallElapsedSeconds / StopwatchElapsedSeconds | Different clock observations, not proof of a root cause |

Exit0 means the invocation finished, not necessarily that every link was deleted.
Exit1 means paused/request/persistence failure; exit2 means invalid input/context/
resume. A killed process may have **no final summary**. Always reconcile durable
journal evidence rather than treating an old RUNNING projection as a live process.
No output authorizes another cohort. Summaries are per invocation plus explicit
resume counts; CSV/journal history remains append-only across invocations.

## Time bounds and supervision

Graph data requests use30-second connection/operation controls by default; token
acquisition has separate30/60-second controls. `MaxRunSeconds` is a cooperative
whole-invocation budget including prompts, auth and waits. Wall/Stopwatch divergence
above60 seconds pauses rather than extending a run or asserting why a gap occurred.

These controls do **not** guarantee hard cancellation across OS/DNS/runtime stalls
or host suspension. Use an independent finite process watchdog and receipt-inactivity
checks. On Linux, a suspend-aware clock such as CLOCK_BOOTTIME is preferable to
monotonic alone. Size inactivity beyond maximum request/backoff windows. This
script launches no supervisor and does not claim continuous execution across gaps.
`ThrottleLimit` is reserved compatibility input: all operations remain sequential.

## Impact, security and undo limits

Only the exact permission is removed. Files and independent grants are not intended
to change; matching item verification is mandatory. Recipients relying solely on
the Anyone URL lose access. The original URL is not guaranteed restorable; an owner
may create replacement access outside this tool. Confirm that impact before writes.

Plans may contain sharing URLs and result/journal files contain operational IDs.
Keep runtime evidence access-controlled and OUT of source control. Certificate and
password values remain parameters/in-memory; raw exceptions and auth bodies are
suppressed. Retain evidence before removing app/certificate access under a separately
approved security cleanup; a failure is not consent to grant broader privileges.

## Offline validation and evidence limits

Run all three suites with PowerShell7.4+; no Pester/install/credentials required:

```powershell
pwsh ./tests/Test-RemoveAnyoneLink.ps1
pwsh ./tests/Test-RemovalSafety.ps1
pwsh ./tests/Test-Reliability.ps1
```

All140 assertions pass (existing21 + safety18 + reliability101).
Existing behavior/scrub tests, transport queue substitution and MockGraph child
runs cover timeout recovery/exhaustion, ambiguous applied/present/unknown deletes,
no acknowledged replay, both verification phases, integer/date Retry-After,
permanent errors, persistence failure, clock budgets, crash/restart boundaries,
synthetic multi-key exclusions, duplicate/hash guards, output locking and complete
help sections. This is implementation evidence, not real network/service validation.

References read2026-11-08 (documentation, NOT tenant tests):
- https://learn.microsoft.com/en-us/graph/api/permission-delete?view=graph-rest-1.0
- https://learn.microsoft.com/en-us/graph/throttling
