# Read-only default, bounded mutation and truthful feedback

Preview review: 2026-11-07. This generic version has offline validation only; no live-tenant execution is claimed.

- Input requires nonblank unique DriveId/ItemId/LinkId tuples. Output is bound to
  the input SHA256: use a new folder for a changed file. Keep exclusions upstream.
- Dry-run is default. Execute still uses ShouldProcess; neither WhatIf nor a
  successful previous batch is approval to execute another batch.
- Immediately re-read the exact permission before deletion: require the expected
  ID, anonymous scope, edit type and no inheritedFrom. A write role is insufficient.
- Only explicit permission GET404 is absence; malformed/empty GET200 is an error.
  DELETE204 means request succeeded, not final verified absence. DELETE404 is
  separately represented. Every confirmed deletion is followed by exact GET404.
- The generic tool verifies permission absence, not item survival; the separate
  purpose-specific executor can additionally check each corresponding item remains. That is separate from this generic preview and is not evidence of its live validation.
- Nested status/Retry-After are extracted without logging raw service responses.
  GET retries only transient 429/503/504, twice at most. Retry-After can be seconds
  or HTTP date. A server delay beyond the configured cap pauses, never shortens it.
- DELETE transport NEVER retries automatically. An ambiguous response is checked
  with GET first. Verified absence is recovered without replay; unresolved timeout
  or auth failure stops. Only a still-present transient 429/503/504 can retry after
  another complete allowlist check, up to MaxDeleteRetries (default one).
- Append journal ATTEMPT before mutation, RESPONSE afterward, VERIFIED on absence.
  A prior unresolved attempt with a present link requires operator review. Never
  remove that journal entry merely to force a retry. Confirmed terminal outcomes
  alone enter done.txt. Dry-run or changed/inherited/error rows do not enter it.
- Per-row CSV checkpoints, timestamped logs, progress.txt and atomic summary.json
  expose real Processed/Remaining/ResumedCompleted/EligibleChecked/WouldDelete/
  DeletedVerified/AlreadyAbsent/Skipped/Errors/Paused counts. Auth/errors pause
  with nonzero exit. Completed only means enumeration finished; skips still count.
- RequestTimeoutSeconds controls transport deadlines, MaxRunSeconds cooperative
  elapsed budget; neither guarantees a hard wall-clock bound across DNS/runtime
  failures. Use an external supervisor/watchdog for hard deadlines. ThrottleLimit
  remains a compatibility parameter: actual requests are sequential, not parallel.
- Restart into the same input-bound folder preserves verified checkpoints. Keep
  results/journal together. This is not a concurrent multi-writer transaction log;
  run one process per output folder and preserve storage failures for review.
- Removing a permission removes that URL's grant, not the file or other grants.
  Recipients depending solely on that public URL lose access. Recreating a link
  does not guarantee the identical old URL. Activity evidence is external: this
  tool never asserts unused beyond the supplied audit coverage.

## Offline validation

`tests/Test-RemoveAnyoneLink.ps1` checks existing behavior and the public-package scrub.
`tests/Test-RemovalSafety.ps1` replaces all HTTP transport/auth with local queues
and uses MockGraph child runs. No credentials/network/tenant are involved.
Together the suites have 39 assertions. Reserved __mockGetStatus fixture fields
are interpreted only in MockGraph mode. Do not confuse mock DELETE calls with
real service operations. Validate this preview in a non-production tenant before
considering production use.

## Documentation references

Public documentation consulted 2026-11-07 (not a tenant test):
https://learn.microsoft.com/en-us/graph/api/permission-delete?view=graph-rest-1.0
https://learn.microsoft.com/en-us/graph/throttling
These document permission deletion/204 and Retry-After guidance. Offline tests
validate implementation behavior, not real-world service or network performance.
