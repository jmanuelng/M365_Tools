# Find every "Anyone" sharing link in SharePoint Online and OneDrive

**Applies to:** SharePoint Online, OneDrive for Business, Microsoft Graph v1.0 · **Script:** `Get-AnyoneLinkInventory.ps1` v0.4.1 · **Updated:** 2026-11-04 · **Access:** read-only

"Anyone" links (anonymous links) let anybody who has the URL open a file or folder, with no sign-in. They are convenient, they get forwarded, and they are rarely cleaned up. Before you tighten your sharing defaults or delete old links, you need to know what exists: which sites, which files, view or edit, expiring or not.

The SharePoint admin center does not give you a tenant-wide list. This script does. It walks every site and every OneDrive through Microsoft Graph and writes one CSV row per link. It never changes anything.

In this article you will:

1. [Check the prerequisites](#1-prerequisites)
2. [Install PowerShell 7](#2-install-powershell-7)
3. [Create a self-signed certificate](#3-create-a-certificate)
4. [Register an Entra ID app with read-only access](#4-register-the-app-in-microsoft-entra-id)
5. [Run the script](#5-run-the-script) (test first, then full)
6. [Read the results](#6-understand-the-output)
7. [Clean up](#7-clean-up-security)

Plus [how it works](#how-it-works), [troubleshooting](#troubleshooting) and an [FAQ](#faq).

---

## 1. Prerequisites

| You need | Why |
|---|---|
| A Microsoft 365 tenant with SharePoint Online | The thing being scanned |
| **Global Administrator** or **Privileged Role Administrator** (for one click: admin consent) and **Application Administrator** or **Cloud Application Administrator** (to register the app) | One-time setup |
| A computer with **PowerShell 7.4 or later** (Windows, macOS or Linux) | The script uses PowerShell 7.4 features |
| Outbound HTTPS to `login.microsoftonline.com` and `graph.microsoft.com` | Authentication and data |

No PowerShell modules are required. The script calls the Graph REST API directly.

> **Why an app and not my admin account?** Delegated (user) access only sees what that user can see, and an admin is not automatically a member of every site or OneDrive. An app with the **application** permission `Sites.Read.All` can read every site, which is what a complete inventory needs. `Sites.Read.All` is read-only.

## 2. Install PowerShell 7

Check your version:

```powershell
$PSVersionTable.PSVersion
```

If it is lower than 7.4 (Windows PowerShell 5.1 shows `5.1`), install PowerShell 7 side by side. It does not replace Windows PowerShell.

- **Windows:** `winget install --id Microsoft.PowerShell --source winget`
- **macOS:** `brew install --cask powershell`
- **Linux:** see [Install PowerShell on Linux](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-linux)

Then start it with `pwsh`. Everything below runs in `pwsh`.

## 3. Create a certificate

The app proves its identity with a certificate (recommended by Microsoft over client secrets). You keep the private key; Entra ID gets only the public part.

### Option A: Windows (certificate store)

```powershell
$cert = New-SelfSignedCertificate -Subject 'CN=AnyoneLinkInventory' `
    -CertStoreLocation 'Cert:\CurrentUser\My' -KeyExportPolicy NonExportable `
    -KeySpec Signature -KeyLength 2048 -HashAlgorithm SHA256 -NotAfter (Get-Date).AddMonths(3)
Export-Certificate -Cert $cert -FilePath .\AnyoneLinkInventory.cer   # public part, to upload
$cert.Thumbprint                                                    # note this for -CertificateThumbprint
```

### Option B: macOS / Linux (or any OS with OpenSSL)

```bash
openssl req -x509 -newkey rsa:2048 -sha256 -days 90 -nodes \
  -keyout key.pem -out AnyoneLinkInventory.cer -subj "/CN=AnyoneLinkInventory"
openssl pkcs12 -export -out AnyoneLinkInventory.pfx -inkey key.pem -in AnyoneLinkInventory.cer
rm key.pem    # the .pfx now holds the private key; protect it with a password when prompted
```

Use the `.pfx` with `-CertificatePath`. Upload only the `.cer`.

> Keep the `.pfx` out of source control and shared folders. A short validity (90 days) limits the damage if it leaks.

## 4. Register the app in Microsoft Entra ID

1. Go to the [Microsoft Entra admin center](https://entra.microsoft.com) > **Identity** > **Applications** > **App registrations** > **New registration**.
2. **Name:** `AnyoneLinkInventory-ReadOnly` (any name). **Supported account types:** *Accounts in this organizational directory only (Single tenant)*. Leave Redirect URI empty. Select **Register**.
3. On the **Overview** page copy:
   - **Application (client) ID** → `-ClientId`
   - **Directory (tenant) ID** → `-TenantId` (or use your `<name>.onmicrosoft.com` domain)
4. **Certificates & secrets** > **Certificates** > **Upload certificate** > select the `.cer` from step 3 > **Add**. Check that the thumbprint shown matches yours.
5. **API permissions** > **Add a permission** > **Microsoft Graph** > **Application permissions** > search `Sites.Read.All` > check it > **Add permissions**.
6. Select **Grant admin consent for <your organization>** and confirm. The status column must show a green check.
7. Optional but recommended: remove the default delegated `User.Read` permission; the app does not need it.

Reference: [Register an application](https://learn.microsoft.com/entra/identity-platform/quickstart-register-app) · [Certificate credentials](https://learn.microsoft.com/entra/identity-platform/certificate-credentials).

> Permission changes can take a few minutes to apply. If the first run gets `403` on every site, wait 5–10 minutes and retry.

## 5. Run the script

Download `Get-AnyoneLinkInventory.ps1` and, on Windows, unblock it:

```powershell
Unblock-File .\Get-AnyoneLinkInventory.ps1
```

### Quick start (prompts for everything)

```powershell
.\Get-AnyoneLinkInventory.ps1
```

With no parameters the script shows a short banner and asks for each value, validates its format and tells you where to find it. Full help any time:

```powershell
Get-Help .\Get-AnyoneLinkInventory.ps1 -Full
.\Get-AnyoneLinkInventory.ps1 -Help
```

### Step 1: dry run (lists drives only)

```powershell
.\Get-AnyoneLinkInventory.ps1 -TenantId contoso.onmicrosoft.com `
    -ClientId 00000000-0000-0000-0000-000000000000 `
    -CertificateThumbprint 0000000000000000000000000000000000000000 -WhatIf
```

This proves authentication and permissions work and writes `drives.csv` (every library and OneDrive, with size) without reading any permissions.

### Step 2: small test on one site

```powershell
.\Get-AnyoneLinkInventory.ps1 -TenantId contoso.onmicrosoft.com `
    -ClientId 00000000-0000-0000-0000-000000000000 `
    -CertificatePath ./AnyoneLinkInventory.pfx `
    -SiteUrlFilter '/sites/<one-site-name>' -MaxDrives 3 -OutputFolder ./test1
```

### Step 3: full tenant

```powershell
.\Get-AnyoneLinkInventory.ps1 -TenantId contoso.onmicrosoft.com `
    -ClientId 00000000-0000-0000-0000-000000000000 `
    -CertificateThumbprint 0000000000000000000000000000000000000000 `
    -OutputFolder ./full_scan
```

If it stops for any reason (network, laptop sleep, watchdog), **run the exact same command again**. Finished drives are skipped and an interrupted drive continues from its last checkpoint.

### Unattended (scheduled task, CI)

```powershell
.\Get-AnyoneLinkInventory.ps1 -TenantId ... -ClientId ... -CertificateThumbprint ... `
    -OutputFolder D:\Reports\AnyoneLinks -NonInteractive
```

`-NonInteractive` never prompts: a missing or invalid value stops the script with exit code `2` and a clear message.

### Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `-TenantId` | yes* | | Tenant GUID or `<name>.onmicrosoft.com` |
| `-ClientId` | yes* | | App (client) ID GUID |
| `-CertificateThumbprint` | one of* | | 40-hex thumbprint, Windows cert store (CurrentUser then LocalMachine) |
| `-CertificatePath` | one of* | | `.pfx` path, any OS |
| `-CertificatePassword` | no | prompt | SecureString for the `.pfx` |
| `-OutputFolder` | no | `./AnyoneLinkInventory_<date>` | Reuse to resume |
| `-IncludeAllScopes` | no | off | Also report Organization and Specific-people links |
| `-SiteUrlFilter` | no | | Regex on the drive URL |
| `-MaxDrives` | no | 0 (all) | Limit for tests |
| `-ThrottleLimit` | no | 4 | Parallel drives (1–8) |
| `-NoActivityTimeoutMinutes` | no | 120 | Watchdog: stop if no Graph call completes in this time |
| `-NonInteractive` | no | off | Fail instead of prompting |
| `-WhatIf` | no | | Enumerate drives only |
| `-Help` | no | | Show full help |

\* Prompted for when missing, unless `-NonInteractive`.

## 6. Understand the output

Everything goes into `-OutputFolder`:

| File | Content |
|---|---|
| `anyone_links.csv` | **The result.** One row per link. |
| `drives.csv` | Every drive found: site, name, type, size. |
| `skipped.csv` | Anything that could not be read, with HTTP status (403 = locked/no access, 404 = gone, 423 = locked site). |
| `progress.txt` | Heartbeat: a line every 20 batches and one per finished drive. |
| `run_<time>.log` | Full log with every warning and error. |
| `parts/`, `state/`, `done.txt` | Per-drive results and checkpoints, used for resume. Safe to delete after the final CSV is produced. |

Columns of `anyone_links.csv`:

| Column | Meaning |
|---|---|
| `Scope` | `anonymous` = Anyone link (`organization` / `users` only with `-IncludeAllScopes`) |
| `LinkType` / `Roles` | `view` (read) or `edit` (write). **Edit + anonymous is the highest risk.** |
| `ExpirationDateTime` | Empty = never expires |
| `HasPassword` | Whether the link requires a password |
| `LinkUrl` | The sharing URL itself. **Treat the CSV as sensitive:** anyone with this file can open those items. |
| `ItemName`, `ItemUrl`, `ItemId` | The shared file or folder (a shared folder exposes everything inside it) |
| `SiteUrl`, `DriveName`, `DriveType`, `DriveId` | Where it lives (`personal` = OneDrive, `documentLibrary` = SharePoint) |

Suggested triage, in this order:

1. `anonymous` + `edit` + no expiration (anyone can change or delete content).
2. Links on folders and on OneDrive (`personal`) drives.
3. `anonymous` + `view` + no expiration.

Then consider tenant settings: SharePoint admin center > **Policies** > **Sharing**: default link type, expiration for Anyone links, and allowed permissions. See [Manage sharing settings](https://learn.microsoft.com/sharepoint/turn-external-sharing-on-or-off).

> The script does not report *when a link was last used*. For that, search the unified audit log for `AnonymousLinkUsed` events (Microsoft Purview > Audit).

## 7. Clean up (security)

When you are done:

1. Delete the app registration (Entra admin center > App registrations > your app > **Delete**), or at least remove its certificate.
2. Delete the certificate: Windows `Remove-Item Cert:\CurrentUser\My\<thumbprint>`; other OS: delete the `.pfx`.
3. Store `anyone_links.csv` somewhere access-controlled, or delete it after remediation.

## How it works

- **Read-only by design.** The only calls are a POST to the token endpoint and GETs to Graph (some grouped in `$batch`, whose sub-requests are GETs). There is no code that writes to the tenant.
- **Enumeration:** `GET /sites/getAllSites` → `GET /sites/{id}/drives` → `GET /drives/{id}/root/delta`.
- **Only unique permissions:** delta is called with the header `Prefer: hierarchicalsharing`, so only items at the root of a unique-permission hierarchy carry the `shared` facet. Items that just inherit the site's permissions are not queried one by one. On large libraries this is the difference between hours and minutes.
- **Batching:** permissions are read with JSON `$batch`, 20 requests per call.
- **Parallelism:** `ForEach-Object -Parallel` across drives, smallest first, so most drives finish early and big libraries do not block progress.
- **Throttling:** exponential backoff with jitter on 429/5xx/timeouts, and `Retry-After` honored (also per sub-request inside `$batch`), per [Microsoft Graph throttling guidance](https://learn.microsoft.com/graph/throttling).
- **Timeouts:** each call has hard connect (60 s) and read (120 s) limits; the token call 30 s / 60 s. Tokens are refreshed every 45 minutes.
- **Checkpoints:** after each batch, rows are appended to `parts/<drive>.partial.csv` and finished item IDs to `state/`; finished drives are written to `done.txt`.
- **Resume / skip list:** a drive is skipped if its drive ID *or* its web URL appears (tab-separated) in `done.txt`, so you can seed `done.txt` with one drive URL per line to skip drives finished by an earlier run or tool.
- **Watchdog:** if no Graph call completes for `-NoActivityTimeoutMinutes`, the run stops cleanly with exit code 3 and can be resumed.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `AADSTS700016` / `AADSTS700038` | Wrong `-ClientId`, or app in another tenant. |
| `AADSTS90002` | Wrong `-TenantId`. |
| `AADSTS700027` / `AADSTS7000274` | Certificate not uploaded to the app, or a different one. Compare thumbprints. |
| `Certificate ... has no private key` | You pointed at the `.cer`. Use the `.pfx`, or the store certificate created on this machine. |
| `Cannot open the certificate` | Wrong `.pfx` password or corrupt file. |
| `403` on all sites / `No drives found` | `Sites.Read.All` is *Delegated* instead of *Application*, or admin consent missing. Wait a few minutes after consent. |
| Some sites `403`/`423` in `skipped.csv` | Locked or archived sites, or sites with restricted access control. Expected; review manually. |
| Many `Retry ... HTTP 429` warnings | Throttling. It is handled; lower `-ThrottleLimit` to 2 and run outside business hours. |
| `No Graph activity for N min` (exit 3) | Network loss or sleep. Rerun the same command. |
| `Some drives failed` (exit 1) | See `run_*.log`; rerun to retry only those drives. |
| Script won't start on Windows | Run `Unblock-File`, or `Set-ExecutionPolicy -Scope Process RemoteSigned`. |
| `#Requires` version error | You are in Windows PowerShell 5.1. Start `pwsh`. |

## FAQ

**Does it change or delete links?** No. It only reads.

**Can I use a client secret instead of a certificate?** Not with this script, on purpose. Certificates are the Microsoft-recommended credential for app-only access.

**Can I limit the app to some sites only?** Yes: grant `Sites.Selected` instead of `Sites.Read.All` and give the app read access per site ([Sites.Selected](https://learn.microsoft.com/graph/permissions-selected-overview)). `getAllSites` will then return only those sites.

**How long does it take?** It depends on the number of drives and unique-permission items. Small tenants: minutes. Thousands of drives: a few hours. Progress is saved continuously.

**Does it cover Teams and Microsoft 365 Groups files?** Yes. Their files live in SharePoint sites, which are included.

**Why are some links missing compared to the UI?** Links inherited from a parent folder are reported once, on the folder where they were created.

**Is the CSV sensitive?** Yes. It contains working anonymous URLs. Protect it like a password list.

## Sources and credits

- Microsoft Learn: [Throttling](https://learn.microsoft.com/graph/throttling), [JSON batching](https://learn.microsoft.com/graph/json-batching), [driveItem delta](https://learn.microsoft.com/graph/api/driveitem-delta), [Scan guidance](https://learn.microsoft.com/onedrive/developer/rest-api/concepts/scan-guidance), [Avoid throttling in SharePoint Online](https://learn.microsoft.com/sharepoint/dev/general-development/how-to-avoid-getting-throttled-or-blocked-in-sharepoint-online), [Certificate credentials](https://learn.microsoft.com/entra/identity-platform/certificate-credentials)
- Tony Redmond, Office 365 IT Pros: [Report-SharingOneDriveFiles.PS1](https://github.com/12Knocksinna/Office365itpros/blob/master/Report-SharingOneDriveFiles.PS1)
- PnP Script Samples: [Audit sharing links](https://pnp.github.io/script-samples/spo-audit-sharing-links/README.html)

## Changelog

See the `.NOTES` section of the script (`Get-Help .\Get-AnyoneLinkInventory.ps1 -Full`).

License: [MIT](../../LICENSE). Provided as-is; test in a non-production tenant first.
