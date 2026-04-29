# Braid Installer

One-line installer for the [Braid](https://github.com/abad-ai/braid) CLI — a framework for launching AI agents in isolated cloud sandboxes.

## Install

**macOS / Linux:**

```bash
curl -fsSL https://raw.githubusercontent.com/abad-ai/braid-install/main/install.sh | bash
```

**Windows (PowerShell 5.1+):**

```powershell
iwr https://raw.githubusercontent.com/abad-ai/braid-install/main/install.ps1 -useb | iex
```

The installer drops the `braid` binary at `~/.braid/bin/braid` (or `%USERPROFILE%\.braid\bin\braid.exe` on Windows). Add that directory to your `PATH` — the script prints the exact line to run.

## Prerequisites

- **[GitHub CLI (`gh`)](https://cli.github.com)** — installed and authenticated (`gh auth login`).

  The Braid source repo is private. The installer uses `gh release download` to fetch binaries via your existing GitHub session — no separate token needed.

## Pinning a version

```bash
BRAID_VERSION=v0.5.0 curl -fsSL https://raw.githubusercontent.com/abad-ai/braid-install/main/install.sh | bash
```

`BRAID_VERSION` defaults to `latest`. Tags must match `v?MAJOR.MINOR.PATCH[-prerelease]`.

## Upgrading

```bash
braid upgrade
```

This re-runs the installer for the currently-installed binary. Pass `BRAID_VERSION` to install a specific version.

## Security guarantees

1. **Mandatory SHA256 verification.** Both scripts download `SHA256SUMS` alongside the binary and abort if the binary's hash does not match. The binary is **never** executed before the checksum matches.
2. **`BRAID_VERSION` is validated** against `^(latest|v?\d+\.\d+\.\d+(-[A-Za-z0-9.-]+)?)$` before being passed to `gh`. The env var crosses a trust boundary (user shell → script → `gh` argv); regex validation prevents argv injection.
3. **No `curl | bash` of arbitrary URLs.** The only network downloads are via `gh release download` against the fixed `abad-ai/braid` repo + tag. The shell one-liner only fetches the install script itself from `raw.githubusercontent.com` over HTTPS.
4. **Install location is `$HOME/.braid/bin`** (`%USERPROFILE%\.braid\bin` on Windows). The script never uses `sudo` and never writes outside `$HOME`.
5. **Strict mode.** `set -euo pipefail` (sh) and `$ErrorActionPreference = 'Stop'` (ps1) so any download/verification failure aborts the install before the binary touches `$INSTALL_DIR`.

## Reading the script before running

This is a curl-pipe-bash installer. If you'd rather inspect before running:

```bash
curl -fsSL https://raw.githubusercontent.com/abad-ai/braid-install/main/install.sh -o install.sh
less install.sh
bash install.sh
```

## Reporting vulnerabilities

See [SECURITY.md](./SECURITY.md).

## Source of truth

These scripts are mirrored from the [`install/`](https://github.com/abad-ai/braid/tree/main/install) directory in the (private) [`abad-ai/braid`](https://github.com/abad-ai/braid) source repo. File changes here should be PRs that copy from the source repo, not direct edits.
