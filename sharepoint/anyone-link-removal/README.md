> **1.1.0-preview.1 — offline validation only.** This generic update passed 39 offline assertions; it has not been live-tested. Production operations performed with a separate purpose-specific executor are not validation of this preview. Test in a non-production tenant first. See [safety/progress semantics](docs/SAFETY_AND_PROGRESS.md).

# Remove "Anyone" edit sharing links in SharePoint Online and OneDrive

**Applies to:** SharePoint Online, OneDrive for Business, Microsoft Graph v1.0 · **Scripts:** `Remove-AnyoneLink.ps1` v1.1.0-preview.1 · `Grant-SitesSelectedWrite.ps1` v1.0.0 · **Updated:** 2026-11-07 · **Access:** **CHANGES TENANT STATE** (deletes sharing permissions)

> **This tool mutates the tenant.** It deletes Microsoft Graph `permission` objects that represent **Anyone (anonymous) edit** sharing links. It does **not** delete files, folders, or sites. Deleting a sharing link **cannot restore the same URL** — owners must create a new link if access is still required.
>
> Dry-run is the default. No DELETE is sent unless you pass **`-Execute`** (and `ShouldProcess` confirms, unless you use `-Confirm:$false` deliberately).

Companion to the read-only inventory tool
[`Get-AnyoneLinkInventory.ps1`](../anyone-link-inventory/). Use inventory first, triage the CSV, then point this tool at a **small filtered candidate list**.

In this article you will:

1. [Read the safety model](#1-safety-model)
2. [Check the prerequisites](#2-prerequisites)
3. [Install PowerShell 7](#3-install-powershell-7)
4. [Create a certificate](#4-create-a-certificate)
5. [Register a dedicated Entra ID write app](#5-register-a-dedicated-write-app)
6. [Prepare a candidate CSV](#6-prepare-a-candidate-csv)
7. [Run dry-run, then execute](#7-run-the-script)
8. [Read the results](#8-understand-the-output)
9. [Clean up](#9-clean-up-security)

Plus [Sites.Selected (tighter alternative)](#sitesselected-tighter-alternative), [how it works](#how-it-works), [troubleshooting](#troubleshooting) and an [FAQ](#faq).

---

## 1. Safety model

| Guard | Behavior |
|---|---|
| Dry-run default | Without `-Execute`, the script only GETs and writes `would_delete.csv` |
| `-WhatIf` | Honored via `SupportsShouldProcess`; no DELETE even with `-Execute` |
| Fresh check | Every candidate is re-fetched with `GET .../permissions/{id}` before any delete |
| Allowlist shape | Must be `link.scope=anonymous`, edit/write, `inheritedFrom` null, id matches CSV |
| Inherited | Skipped (Graph cannot delete inherited permissions) |
| Mutation retries | DELETE retried only on 429/503/504 after a fresh allowlist re-check; never blind |
| Resume | `done.txt` keys `DriveId\|ItemId\|LinkId` |
| Mock | `-MockGraph` never contacts Entra or Graph |
| App separation | Do **not** reuse the read-only inventory app or expand its permissions |
| Publish-safe | No tenant IDs, hostnames, or UPNs hardcoded — parameters / prompts only |

## 2. Prerequisites

| You need | Why |
|---|---|
| A Microsoft 365 tenant with SharePoint Online | Target of the cleanup |
| **Global Administrator** or **Privileged Role Administrator** (admin consent) and **Application Administrator** or **Cloud Application Administrator** (app registration) | One-time setup |
| PowerShell **7.4+** (Windows, macOS, or Linux) | Script uses 7.4 features |
| Outbound HTTPS to `login.microsoftonline.com` and `graph.microsoft.com` | Auth + Graph |
| A candidate CSV from the inventory tool (or compatible) | See [docs/IMPORT_SCHEMA.md](docs/IMPORT_SCHEMA.md) |

No PowerShell modules are required for `Remove-AnyoneLink.ps1` (raw Graph REST). The optional `Grant-SitesSelectedWrite.ps1` helper can use `Microsoft.Graph.Authentication` or a pasted Graph Explorer token.

> **Why a separate app?** The inventory tool should stay read-only (`Sites.Read.All`). Expanding it to write increases blast radius. Register a **dedicated** single-tenant write app for removal.

## 3. Install PowerShell 7

```powershell
$PSVersionTable.PSVersion
```

If lower than 7.4, install PowerShell 7 side by side (`winget install --id Microsoft.PowerShell`, `brew install --cask powershell`, or [Install on Linux](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-linux)). Run everything below in `pwsh`.

## 4. Create a certificate

Same pattern as the inventory tool — certificate auth, not client secrets.

### Option A: Windows (certificate store)

```powershell
$cert = New-SelfSignedCertificate -Subject 'CN=AnyoneLinkRemoval' `
    -CertStoreLocation 'Cert:\CurrentUser\My' -KeyExportPolicy NonExportable `
    -KeySpec Signature -KeyLength 2048 -HashAlgorithm SHA256 -NotAfter (Get-Date).AddMonths(3)
Export-Certificate -Cert $cert -FilePath .\AnyoneLinkRemoval.cer
$cert.Thumbprint
```

### Option B: macOS / Linux (OpenSSL)

```bash
openssl req -x509 -newkey rsa:2048 -sha256 -days 90 -nodes \
  -keyout key.pem -out AnyoneLinkRemoval.cer -subj "/CN=AnyoneLinkRemoval"
openssl pkcs12 -export -out AnyoneLinkRemoval.pfx -inkey key.pem -in AnyoneLinkRemoval.cer
rm key.pem
```

Keep the `.pfx` out of source control. Short validity (90 days) limits damage if it leaks.

## 5. Register a dedicated write app

1. [Microsoft Entra admin center](https://entra.microsoft.com) > **Identity** > **Applications** > **App registrations** > **New registration**.
2. **Name:** `AnyoneLinkRemoval-Write` (any name). **Supported account types:** *Accounts in this organizational directory only (Single tenant)*. Leave Redirect URI empty. **Register**.
3. Copy **Application (client) ID** → `-ClientId` and **Directory (tenant) ID** → `-TenantId` (or use `<name>.onmicrosoft.com`).
4. **Certificates & secrets** > **Certificates** > **Upload certificate** > the `.cer` from step 4.
5. **API permissions** > **Add a permission** > **Microsoft Graph** > **Application permissions**:
   - **Recommended for tenant-wide permission delete (least privileged per Graph permission-delete docs):** `Files.ReadWrite.All`  
     Manifest / published ID: `75359482-378d-4052-8f01-80520e7db3cd`  
     Reference: [permission-delete](https://learn.microsoft.com/graph/api/permission-delete?view=graph-rest-1.0) · [Files.ReadWrite.All](https://graphpermissions.merill.net/permission/Files.ReadWrite.All)
   - **Tighter for a site-scoped pilot:** `Sites.Selected` instead, then grant **write** per site (see [Sites.Selected](#sitesselected-tighter-alternative)).
6. **Grant admin consent** for your organization. Wait a few minutes if the first calls return 403.
7. Optional: remove default delegated `User.Read`.

> Do **not** grant `Sites.FullControl.All` or `Sites.Manage.All` on the removal app. The script refuses tokens that carry those roles by default (`-DeniedPermissionIds`).

## 6. Prepare a candidate CSV

1. Run [`Get-AnyoneLinkInventory.ps1`](../anyone-link-inventory/) and open `anyone_links.csv`.
2. Filter to `Scope=anonymous` and edit/write (`LinkType=edit` or `Roles` contains `write`).
3. Triage with audit / business review. Absence from a short audit window is **not** proof a link was never used.
4. Export **3–5 pilot rows** to a dedicated CSV. Keep the full list for later waves.

Required columns: `LinkId`, `DriveId`, `ItemId`. See [docs/IMPORT_SCHEMA.md](docs/IMPORT_SCHEMA.md). Treat any CSV that contains `LinkUrl` as **sensitive**.

## 7. Run the script

Unblock on Windows: `Unblock-File .\Remove-AnyoneLink.ps1`.

### Quick start (prompts)

```powershell
.\Remove-AnyoneLink.ps1
```

With no parameters the script shows a banner and prompts for each required value (format-checked, with where-to-find hints). Full help:

```powershell
Get-Help .\Remove-AnyoneLink.ps1 -Full
.\Remove-AnyoneLink.ps1 -Help
```

### Local logic test (no network)

```powershell
.\Remove-AnyoneLink.ps1 -MockGraph -InputCsv .\mocks\sample_input.csv `
    -OutputFolder ./output/mock_dryrun

.\Remove-AnyoneLink.ps1 -MockGraph -InputCsv .\mocks\sample_input.csv `
    -OutputFolder ./output/mock_execute -Execute -Confirm:$false
```

Or: `pwsh ./tests/Test-RemoveAnyoneLink.ps1`.

### Step 1: live dry-run (GET only)

```powershell
.\Remove-AnyoneLink.ps1 -TenantId contoso.onmicrosoft.com `
    -ClientId 00000000-0000-0000-0000-000000000000 `
    -CertificatePath ./AnyoneLinkRemoval.pfx `
    -InputCsv ./candidates_pilot.csv `
    -MaxItems 5 `
    -OutputFolder ./removal_dryrun
```

Review `would_delete.csv` and `skipped.csv`. Nothing is deleted.

### Step 2: live DELETE on the same short list

```powershell
.\Remove-AnyoneLink.ps1 -TenantId contoso.onmicrosoft.com `
    -ClientId 00000000-0000-0000-0000-000000000000 `
    -CertificatePath ./AnyoneLinkRemoval.pfx `
    -InputCsv ./candidates_pilot.csv `
    -MaxItems 5 `
    -OutputFolder ./removal_pilot `
    -Execute -Confirm
```

### Unattended (only after a successful interactive pilot)

```powershell
.\Remove-AnyoneLink.ps1 -TenantId ... -ClientId ... -CertificateThumbprint ... `
    -InputCsv D:\Reports\candidates.csv -OutputFolder D:\Reports\removal1 `
    -NonInteractive -Execute -Confirm:$false
```

`-NonInteractive` never prompts: missing or invalid values stop with exit code `2`.

### Parameters (summary)

| Parameter | Required | Default | Description |
|---|---|---|---|
| `-TenantId` | yes* | | Tenant GUID or `<name>.onmicrosoft.com` |
| `-ClientId` | yes* | | Dedicated **write** app (client) ID |
| `-CertificateThumbprint` / `-CertificatePath` | one of* | | Cert with private key |
| `-InputCsv` | yes* | | Inventory-compatible candidate CSV |
| `-OutputFolder` | no | `./AnyoneLinkRemoval_<date>` | Logs + results; reuse to resume |
| `-MaxItems` | no | 0 (all) | Cap for pilots |
| `-Execute` | no | off | Opt-in DELETE after fresh validation |
| `-MockGraph` | no | off | Local simulation (no network) |
| `-AllowedPermissionIds` | no | Files.ReadWrite.All GUID | Token role allowlist |
| `-DeniedPermissionIds` | no | FullControl + Manage.All | Token role denylist |
| `-NonInteractive` | no | off | Fail instead of prompting |
| `-RequestTimeoutSeconds` | no | 30 | Per-call connection/operation limits; not a hard watchdog |
| `-MaxRetryDelaySeconds` | no | 60 | Pause if server backoff exceeds budget |
| `-MaxRunSeconds` | no | 3600 | Cooperative overall budget |
| `-MaxDeleteRetries` | no | 1 | Transient-only, verified and freshly guarded replay |
| `-ThrottleLimit` | no | 2 | Reserved compatibility parameter; requests are sequential |
| `-Help` | no | | Full comment-based help |

\* Prompted when missing, unless `-NonInteractive` (or `-MockGraph` for auth values).

## 8. Understand the output

| File | Content |
|---|---|
| `would_delete.csv` | Rows that passed live allowlist checks |
| `skipped.csv` | Inherited / wrong scope / missing / GET errors |
| `removal_results.csv` | Dry-run plans and (if `-Execute`) delete outcomes |
| `done.txt` | Verified terminal execution checkpoints only; no dry-run/skip entries |
| `input_sha256.txt` | Binds output folder to exact input bytes |
| `mutation_journal.jsonl` | Durable attempt/response/verified journal |
| `summary.json` | Atomic per-row counts and completion/pause state |
| `run_*.log` | Full log |
| `progress.txt` | Heartbeat counters |

`Action` values: `WOULD_DELETE`, `DELETED`, `ALREADY_ABSENT`, `ERROR`, `SKIP`.
`Completed` means all selected rows were examined, not that all were deleted.
Errors/auth failures pause with nonzero exit. An unresolved prior mutation requires
operator review; do not remove its journal merely to force a replay. Default dry-run
and `-WhatIf` never create mutation checkpoints. Reusing an output folder with changed
input bytes fails; use a new folder. Run one writer per folder. Local checkpoint
files are not a multi-file transaction; retain them together and inspect storage errors.

## 9. Clean up (security)

When finished:

1. Delete the write app registration (or at least remove its certificate and revoke admin consent).
2. Delete the certificate (store thumbprint or `.pfx`).
3. If you temporarily used a bootstrap `Sites.FullControl.All` identity or permission for Sites.Selected grants, **remove it**.
4. Store result CSVs somewhere access-controlled (they may still contain `LinkUrl` values for skipped/planned rows).

## Sites.Selected (tighter alternative)

For a pilot limited to known sites / OneDrives:

1. Grant the removal app application **`Sites.Selected`** only (admin consent).
2. Use an identity that already has **`Sites.FullControl.All`** (temporary bootstrap — often a separate bootstrap app or delegated admin) to `POST /sites/{site-id}/permissions` with role **`write`** for the removal app on each target site.
3. Helper (dry-run by default): `Grant-SitesSelectedWrite.ps1` — pass `-TenantId`, `-ClientId` (removal app), and `-SiteListPath` / `-SiteUrl`. Use `-Execute` with `-AccessToken` (Graph Explorer) or `-UseConnectMgGraph`.
4. Field lesson: **Graph Explorer with delegated `Sites.FullControl.All` can still get 403** on other users' OneDrive personal sites. Prefer an app-only FullControl bootstrap (then remove it) or application **`Files.ReadWrite.All`** when the scope needs many personal OneDrives. Details: [BEST_PRACTICES.md §11](../../BEST_PRACTICES.md).

## How it works

- **Parameter-only:** TenantId, ClientId, certificate, InputCsv, OutputFolder — nothing tenant-specific is baked into the script.
- **Dry-run / Execute / WhatIf / ShouldProcess** gates every DELETE.
- **Fresh GET** of `GET /drives/{driveId}/items/{itemId}/permissions/{linkId}` before delete; allowlist re-check before every retry.
- **StrictMode-safe Graph I/O:** `Invoke-WebRequest -SkipHttpErrorCheck`; GET **404** = already gone; DELETE **204** = success; status codes unwrapped without assuming `ErrorRecord.StatusCode` exists.
- **Token role allow/deny** checked after client-credentials auth.
- **Resume** via `done.txt`.

See also [BEST_PRACTICES.md](../../BEST_PRACTICES.md) (§11 write tools, §12 publishing).

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `INPUT ERROR` / exit 2 | Missing/invalid parameter under `-NonInteractive`, or bad CSV columns |
| Token / AADSTS errors | Wrong TenantId/ClientId/cert; see inventory README troubleshooting |
| Token contains DENIED role | Removal app has FullControl/Manage — remove it |
| Token roles do not include AllowedPermissionIds | Consent `Files.ReadWrite.All` or pass Sites.Selected GUID in `-AllowedPermissionIds` |
| Many SKIP inherited | Expected for child items under a shared folder — delete the folder link instead |
| `ERROR` / paused | Inspect sanitized log, mutation journal and exact state before any retry; never blindly replay an uncertain DELETE |
| 403 on personal OneDrive with Sites.Selected | Grant write on that site with an app-only FullControl bootstrap, or use Files.ReadWrite.All |

## FAQ

**Does dry-run delete anything?** No.

**Can the same Anyone URL come back after DELETE?** Do not promise restoration of the identical URL. Replacement access/new links are not a guaranteed undo.

**Can I reuse the inventory app?** No. Keep read and write apps separate.

**Does this delete files?** No. Only the sharing permission (the link).

**Does it remove Anyone *view* links?** No. Fresh live checks always require anonymous scope, edit type and no inheritedFrom; a write role alone is insufficient.

## Sources and credits

- Microsoft Learn: [permission-delete](https://learn.microsoft.com/graph/api/permission-delete?view=graph-rest-1.0), [permission resource](https://learn.microsoft.com/graph/api/resources/permission?view=graph-rest-1.0), [sharingLink](https://learn.microsoft.com/graph/api/resources/sharinglink?view=graph-rest-1.0), [Sites.Selected overview](https://learn.microsoft.com/graph/permissions-selected-overview), [site-post-permissions](https://learn.microsoft.com/graph/api/site-post-permissions?view=graph-rest-1.0), [Certificate credentials](https://learn.microsoft.com/entra/identity-platform/certificate-credentials)
- Merill graphpermissions: [Files.ReadWrite.All](https://graphpermissions.merill.net/permission/Files.ReadWrite.All)
- Sibling tool: [anyone-link-inventory](../anyone-link-inventory/) · [BEST_PRACTICES.md](../../BEST_PRACTICES.md)

## Changelog

See [CHANGELOG.md](CHANGELOG.md) and `.NOTES` (`Get-Help .\Remove-AnyoneLink.ps1 -Full`).

License: [MIT](../../LICENSE). Provided as-is; test in a non-production tenant first.
