# Security Policy

## Reporting a vulnerability

This repo hosts the public installer scripts for the Braid CLI. The scripts execute on user machines, so we take security reports seriously.

**Please do not file public issues for security vulnerabilities.**

Instead, report privately via one of:

- GitHub Security Advisories: <https://github.com/abad-ai/braid-install/security/advisories/new>
- Email: `security@abad.ai`

We aim to acknowledge reports within 2 business days.

## Scope

In scope:

- The contents of `install.sh` and `install.ps1` in this repo
- The verification logic (SHA256, version regex, argv handling)
- Any path or argv injection in the install flow

Out of scope (report to the source repo instead):

- Bugs in the `braid` CLI itself — see `abad-ai/braid` (private; contact maintainers for access)
- Issues in third-party tools the installer depends on (`gh`, `curl`, PowerShell)

## Verifying the installer yourself

Both scripts are short and auditable. Before running:

```bash
curl -fsSL https://raw.githubusercontent.com/abad-ai/braid-install/main/install.sh -o install.sh
shellcheck install.sh
less install.sh
bash install.sh
```

The CI in this repo runs `shellcheck` and `PSScriptAnalyzer` on every PR.
