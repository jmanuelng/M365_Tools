# M365_Tools

A collection of practical, generic PowerShell tools for Microsoft 365 administrators. Every tool is written to run in **any** tenant: nothing is hardcoded, every tenant-specific value is a parameter (or is prompted for), and each tool has its own step-by-step README.

## Tools

| Area | Tool | Description | Access |
|---|---|---|---|
| SharePoint / OneDrive | [anyone-link-inventory](sharepoint/anyone-link-inventory/) | Inventory every "Anyone" (anonymous) sharing link in the tenant to CSV. Resumable, throttling-aware, parallel. | Read-only (Graph `Sites.Read.All`) |
| SharePoint / OneDrive | [anyone-link-removal](sharepoint/anyone-link-removal/) | Remove **Anyone edit** sharing-link permissions from a filtered inventory CSV. Preview 1.1.0-preview.1: guarded checkpoints/progress, offline-tested only. Dry-run by default; `-Execute` opt-in. | **Mutates** (Graph `Files.ReadWrite.All`; or `Sites.Selected` + per-site write) |
| Entra ID | [entra/](entra/) | Coming soon | |
| Exchange Online | [exchange/](exchange/) | Coming soon | |
| Intune | [intune/](intune/) | Coming soon | |

## Best practices

See [BEST_PRACTICES.md](BEST_PRACTICES.md): lessons learned running Microsoft Graph scripts at tenant scale (unique-permission scans, batching, throttling, timeouts, parallelism, resume, security), Sites.Selected / write-tool lessons (§11), and the **publish checklist** (§12) for adding tools to this repo.

## Principles

- **Read-only unless stated otherwise.** A tool that changes anything says so at the top of its README.
- **Parameter-only / publish-safe.** No tenant IDs, app IDs, hostnames, or certificates hardcoded. Prompts validate format and say where to find each value; `-NonInteractive` fails with exit code 2 when something required is missing.
- **Least privilege.** Each README lists the exact permissions needed and how to remove them afterwards.
- **No secrets in the repo.** Certificates, keys and output files are ignored by `.gitignore`. Never commit them.
- **Documented.** Each script has full comment-based help (`Get-Help .\Script.ps1 -Full`) plus meaningful inline comments on safety paths.

## Disclaimer

Provided as-is under the [MIT License](LICENSE). Test in a non-production tenant first and review the code before running it in yours.
