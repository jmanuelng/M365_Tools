# SharePoint Online / OneDrive tools

| Tool | What it does | Access |
|---|---|---|
| [anyone-link-inventory](anyone-link-inventory/) | Read-only inventory of every "Anyone" (anonymous) sharing link across all SharePoint sites and OneDrive accounts, using Microsoft Graph app-only auth. | Read-only |
| [anyone-link-removal](anyone-link-removal/) | Deletes **Anyone edit** sharing-link permissions from a filtered inventory CSV. Dry-run by default; requires `-Execute`. Companion to the inventory tool. | **Mutates** |

Publish standards: [BEST_PRACTICES.md](../BEST_PRACTICES.md) (§11 write tools, §12 publishing).
