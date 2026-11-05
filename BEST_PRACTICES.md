# Best practices: Microsoft Graph at scale for M365 admin scripts

Lessons learned building tenant-wide scanners and write tools (for example [anyone-link-inventory](sharepoint/anyone-link-inventory/) and [anyone-link-removal](sharepoint/anyone-link-removal/)). These apply to any PowerShell or REST script that walks thousands of sites, drives, users or mailboxes through Microsoft Graph. §12 is the publish checklist for this repo.

## 1. Do less work: ask only for what can matter

- **Scan only items with unique permissions.** Calling `/permissions` on every item is the most common reason sharing scans take hours. Call `driveItem delta` with the header `Prefer: hierarchicalsharing`; only items at the root of a unique-permission hierarchy carry the `shared` facet, so you query permissions only for those. In one real library, 5,000+ items dropped to ~150 permission calls and the scan went from ~40 minutes to seconds.
  - Sources: [driveItem delta](https://learn.microsoft.com/graph/api/driveitem-delta), [Scan guidance](https://learn.microsoft.com/onedrive/developer/rest-api/concepts/scan-guidance)
- **Use `$select`** to return only the fields you need, and `delta` instead of recursive folder walks.

## 2. Batch requests

- Group GETs with [JSON batching](https://learn.microsoft.com/graph/json-batching): up to **20 requests per `$batch`**.
- Each sub-request has its own status. Check every one; a 200 on the batch does not mean every sub-request succeeded. Retry throttled sub-requests individually.

## 3. Handle throttling properly

- On **429 / 503 / 504**, honor the `Retry-After` header (also inside `$batch` sub-responses). Otherwise use **exponential backoff with jitter** (for example `2^attempt` seconds plus a random 0-1 s, capped).
- Cap the number of retries and log each one, so a persistent failure surfaces instead of looping forever.
- Decorate traffic with a descriptive `User-Agent` as Microsoft recommends for SharePoint.
- Sources: [Microsoft Graph throttling](https://learn.microsoft.com/graph/throttling), [Avoid getting throttled or blocked in SharePoint Online](https://learn.microsoft.com/sharepoint/dev/general-development/how-to-avoid-getting-throttled-or-blocked-in-sharepoint-online)

## 4. Set hard timeouts

- Give every call a **connect timeout and a read timeout** (for example 60 s connect, 120 s read; 30 s / 60 s for the token call).
- **PowerShell 7.4 gotcha:** in our tests `HttpClient.Timeout` did not reliably bound a stalled response body read, so a single hung socket could freeze a worker indefinitely. Use `Invoke-RestMethod -ConnectionTimeoutSeconds` and `-OperationTimeoutSeconds` (PowerShell 7.4+) or an explicit `CancellationToken` per request.
- Treat a timeout like a throttle: back off and retry.
- Source: [Invoke-RestMethod](https://learn.microsoft.com/powershell/module/microsoft.powershell.utility/invoke-restmethod)

## 5. Refresh tokens before they expire

- App-only access tokens last about an hour. Refresh proactively (for example every 45 minutes) rather than waiting for a 401 mid-run, and make sure every parallel worker sees the new token.
- Source: [Access tokens](https://learn.microsoft.com/entra/identity-platform/access-tokens)

## 6. Parallelism that actually runs in parallel

- `ForEach-Object -Parallel` with the **Microsoft Graph PowerShell SDK** inside each runspace often gives little or no speed-up: the SDK shares one authenticated client/connection in the process, so workers effectively queue behind each other.
- For real parallelism, acquire your own token (certificate, see below) and call Graph with **raw REST** (`Invoke-RestMethod`) in each runspace. Keep the degree of parallelism modest (3-4) so you parallelize without triggering throttling.
- Source: [ForEach-Object -Parallel](https://learn.microsoft.com/powershell/module/microsoft.powershell.core/foreach-object)

## 7. Make long runs resumable and observable

- **Checkpoint inside long units of work,** not just between them. Write results per drive (or per site/user) and record finished item IDs after each batch, so a restart in a 30,000-item library continues where it stopped instead of from zero.
- Keep a **done list** (`done.txt`) so completed units are skipped on rerun.
- Write a **heartbeat file** (timestamp + counters) after every successful call.
- Run an **external watchdog** that judges progress on that fine-grained heartbeat (items/calls), not on "units finished". A watchdog keyed on finished drives will kill a healthy run that is busy in one big library, and with no inner checkpoint it restarts that library forever.
- Add an in-script **no-activity timeout** (for example 2 hours) that exits cleanly with a distinct exit code, and a cap on watchdog relaunches.

## 8. Order work smallest first

- Process small units first and the biggest libraries last. Most of the tenant finishes early, partial results are useful sooner, and one giant library cannot block everything else.

## 9. Expect locked and inaccessible content

- OneDrives and sites can return **423 Locked** (locked, archived, or being deleted) or 403 (restricted access). Don't retry them endlessly: log them to a `skipped.csv` with the reason and move on, then review manually.

## 10. Security

- Use **certificate authentication** for app-only access, not client secrets. Consider an app management policy that blocks secrets.
- **Least privilege:** grant only what the script needs (for example `Sites.Read.All` Application for a read-only scan), and make the app single-tenant.
- **Delete the app registration and certificate when the job is done,** or at least remove the credential.
- **Never commit secrets:** keep `.pfx`, keys, tenant/app IDs and output files out of source control with `.gitignore`, pass them as parameters, and treat output (for example working anonymous URLs) as sensitive.
- Sources: [Certificate credentials](https://learn.microsoft.com/entra/identity-platform/certificate-credentials), [App management policies](https://learn.microsoft.com/graph/api/resources/applicationauthenticationmethodpolicy)

## 11. Sites.Selected for write tools (and OneDrive personal sites)

- Prefer a **dedicated write app** separate from any read-only inventory app.
- For a tight pilot, use application **`Sites.Selected`** and grant **write** only on the sites you will touch. Assigning those grants requires a caller with **`Sites.FullControl.All`** (temporary bootstrap), then remove FullControl and leave Sites.Selected.
- Field lesson: **Graph Explorer with delegated `Sites.FullControl.All` can still get 403** on other users' OneDrive personal sites, even when site IDs resolve fine with an app-only `Sites.Read.All` client. Do not rely on Graph Explorer alone for Sites.Selected grants to personal OneDrives; use an app-only FullControl bootstrap (then remove it) or application **`Files.ReadWrite.All`** when the pilot scope needs tenant-wide permission deletes.
- Always default scripts to dry-run; require an explicit execute switch; re-GET each permission and skip inherited/changed rows before DELETE.
- Under `Set-StrictMode -Version Latest`, use `Invoke-WebRequest -SkipHttpErrorCheck` for Graph GET/DELETE. Treat GET **404** as already removed and DELETE **204** as success. Do not throw a pscustomobject status bag and then read `.StatusCode` on the caught `ErrorRecord` — StrictMode will throw and can mark a successful delete as failed. Prefer verifying with a GET after DELETE.
- Sources: [permission-delete](https://learn.microsoft.com/graph/api/permission-delete?view=graph-rest-1.0), [Sites.Selected overview](https://learn.microsoft.com/graph/permissions-selected-overview), [Files.ReadWrite.All](https://graphpermissions.merill.net/permission/Files.ReadWrite.All)

## Further reading

- Tony Redmond, Office 365 IT Pros: [Report-SharingOneDriveFiles.PS1](https://github.com/12Knocksinna/Office365itpros/blob/master/Report-SharingOneDriveFiles.PS1)
- PnP Script Samples: [Audit sharing links](https://pnp.github.io/script-samples/spo-audit-sharing-links/README.html)

## 12. Publishing a tool to this repo

Durable copy also lives at the Forge runbook `runbooks/publish-m365-tools.md` (outside git) so the checklist is findable even if this file is forgotten. Every public tool must meet the quality bar of [anyone-link-inventory](sharepoint/anyone-link-inventory/).

### Hard requirements (do not skip)

1. **Folder layout** under the area (`sharepoint/`, `entra/`, …): script + README + optional `mocks/` + `tests/` + small `docs/`. Never commit secrets, real output, pilot CSVs, or tenant-specific command sheets.
2. **Parameter-only / publish-safe by default:** no hardcoded TenantId, ClientId, certificate thumbprint/path, hostname, UPN, site URL, or output folder. Every tenant-specific value is a **parameter** (with interactive prompts + format checks + where-to-find hints when omitted). Examples use placeholders only (`contoso.onmicrosoft.com`, `00000000-…`). Microsoft’s **published** Graph permission GUIDs (e.g. Files.ReadWrite.All `75359482-…`) are OK as defaults; real tenant/app IDs are not.
3. **Comment-based help + inline comments:** full `Get-Help` header (SYNOPSIS, DESCRIPTION, PARAMETER, EXAMPLE, NOTES with dated CHANGELOG + SOURCES). Add a `-Help` switch and a quick-start banner when run with no params. For write tools, DESCRIPTION must state mutation/irreversibility and safety gates. Put **meaningful inline comments** on safety paths (dry-run vs `-Execute`, `ShouldProcess`/`-WhatIf`, allowlist checks, StrictMode-safe Graph status unwrap, `SkipHttpErrorCheck` / 204 / 404 handling).
4. **Script contract:** `Set-StrictMode -Version Latest`; version in `$ScriptVersion` and NOTES; `-NonInteractive` fails with exit code **2** when required values are missing/invalid; dry-run default for any mutating tool; mutation only behind an explicit switch (`-Execute`) + `SupportsShouldProcess`.
5. **README contract (Learn / blog style):** Applies-to line; **mutation warning** at the top if the tool writes; prerequisites; PWSH 7.4+; certificate; Entra app + consent; run examples (dry then execute); output schema; cleanup / least privilege; how it works; troubleshooting; FAQ; placeholders only.
6. **Privacy scrub before commit:** `rg` (or the tool’s test scrub) for tenant names, real GUIDs, UPNs, hostnames, internal paths (tenant short names, real app/tenant GUIDs, UPNs, hostnames, secrets paths, …). Scrub must **PASS** on the public folder.
7. **Local mock tests must PASS** (`pwsh ./tests/Test-….ps1`) with no network. Logic tests + scrub test.
8. **Update root [README.md](README.md) Tools table** (and the area README). Link this file (§11 for write tools, §12 for publish).
9. **Do not weaken [.gitignore](.gitignore)** (certs, csv, log, output stay ignored). Force-add only intentional mock fixtures under `mocks/` when needed (`git add -f mocks/sample_input.csv`).
10. **Commit + push:** clear message; prefer direct commit to `main` matching prior history unless the change is risky — then PR. Never force-push. Repo publish is documentation/code only (still log in Forge manuel-log / changelog / kb).
11. **Mirror durable lessons** into Forge kb (`sharepoint-online.md`, etc.) + `kb/CHANGES.md`, and append `manuel-log.md` / `changelog.md` with America/Cancún timestamps.

### Pre-push checklist (copy/paste)

```text
[ ] Public folder has script + README (+ mocks/tests/docs as needed); no secrets/output/pilot CSVs
[ ] No hardcoded tenant/app/cert/hostname/UPN; parameters + prompts + -NonInteractive exit 2
[ ] Get-Help header complete; -Help; banner; CHANGELOG; SOURCES; inline safety comments
[ ] README: Applies-to, mutation warning if write, setup for ANY tenant, placeholders only
[ ] Scrub PASS on public folder
[ ] Mock tests PASS
[ ] Root README Tools table updated; BEST_PRACTICES linked
[ ] .gitignore unchanged in spirit; mock CSV force-added if required
[ ] Commit message clear; push origin main (or PR); GitHub URL confirmed
[ ] Forge kb + manuel-log + changelog updated (Cancún time)
```
