# Import schema for Remove-AnyoneLink

**Updated:** 2026-11-05  
**Rule:** never copy private tenant rows into public/repo artifacts. Use synthetic mocks only (`mocks/`).

## Compatible source

Primary: `anyone_links.csv` from [`Get-AnyoneLinkInventory.ps1`](../../anyone-link-inventory/) (v0.4.x).

### Required columns

| Column | Meaning |
|---|---|
| `LinkId` | Graph permission id (`permission.id`) |
| `DriveId` | Drive id |
| `ItemId` | Drive item id |

### Strongly recommended columns (filters and logging)

| Column | Meaning |
|---|---|
| `Scope` | `anonymous` / `organization` / `users` |
| `LinkType` | `view` / `edit` |
| `Roles` | e.g. `write` or `read` (inventory may join with `;`) |
| `LinkUrl` | Sharing URL (**sensitive**) |
| `ItemName`, `ItemUrl`, `SiteUrl`, `DriveName`, `DriveType` | Operator context |
| `ExpirationDateTime`, `HasPassword` | Context only; not delete criteria by default |

Exact header from the inventory tool:

```text
LinkId,Scope,Roles,LinkType,ExpirationDateTime,HasPassword,LinkUrl,ItemName,ItemUrl,ItemId,DriveName,DriveType,DriveId,SiteUrl
```

## Filtering before import

Recommended pre-filter for a security cleanup campaign:

1. `Scope = anonymous`
2. `Roles` contains `write` **or** `LinkType = edit`
3. Unused / not recently used first (from a **separate** audit join). Recently used links wait for a review window.
4. Pilot: take 3–5 rows into a dedicated CSV; do **not** point `-Execute` at the full tenant list on the first run.

## Public artifact rule

Mocks under `mocks/` use only `contoso` placeholders. Do not paste real `LinkUrl`, site paths, owner UPNs, or tenant hostnames into README, GitHub, or docs.
