# Best practices: Microsoft Graph at scale for M365 admin scripts

Lessons learned building tenant-wide scanners (for example [anyone-link-inventory](sharepoint/anyone-link-inventory/)). These apply to any PowerShell or REST script that walks thousands of sites, drives, users or mailboxes through Microsoft Graph.

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

## Further reading

- Tony Redmond, Office 365 IT Pros: [Report-SharingOneDriveFiles.PS1](https://github.com/12Knocksinna/Office365itpros/blob/master/Report-SharingOneDriveFiles.PS1)
- PnP Script Samples: [Audit sharing links](https://pnp.github.io/script-samples/spo-audit-sharing-links/README.html)
