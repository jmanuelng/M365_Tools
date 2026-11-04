# M365_Tools

A collection of practical, generic PowerShell tools for Microsoft 365 administrators. Every tool is written to run in **any** tenant: nothing is hardcoded, every tenant-specific value is a parameter (or is prompted for), and each tool has its own step-by-step README.

## Tools

| Area | Tool | Description | Access |
|---|---|---|---|
| SharePoint / OneDrive | [anyone-link-inventory](sharepoint/anyone-link-inventory/) | Inventory every "Anyone" (anonymous) sharing link in the tenant to CSV. Resumable, throttling-aware, parallel. | Read-only (Graph `Sites.Read.All`) |
| Entra ID | [entra/](entra/) | Coming soon | |
| Exchange Online | [exchange/](exchange/) | Coming soon | |
| Intune | [intune/](intune/) | Coming soon | |

## Best practices

See [BEST_PRACTICES.md](BEST_PRACTICES.md): lessons learned running Microsoft Graph scripts at tenant scale (unique-permission scans, batching, throttling, timeouts, parallelism, resume, security).

## Principles

- **Read-only unless stated otherwise.** A tool that changes anything says so at the top of its README.
- **Least privilege.** Each README lists the exact permissions needed and how to remove them afterwards.
- **No secrets in the repo.** Certificates, keys and output files are ignored by `.gitignore`. Never commit them.
- **Documented.** Each script has full comment-based help (`Get-Help .\Script.ps1 -Full`).

## Disclaimer

Provided as-is under the [MIT License](LICENSE). Test in a non-production tenant first and review the code before running it in yours.
