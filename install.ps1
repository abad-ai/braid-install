# install.ps1 -- Windows installer for the Braid CLI.
#
# Source repo abad-ai/braid is private, so this script uses `gh` to download
# release assets. The user must have `gh` installed and authenticated against
# the abad-ai org. SHA256 verification is mandatory.
#
# Mirrored to the public abad-ai/braid-install repo. One-liner:
#   iwr https://raw.githubusercontent.com/abad-ai/braid-install/main/install.ps1 -useb | iex
#
# Env vars:
#   BRAID_VERSION  release tag to install (default: latest)
#   BRAID_REPO     source repo (default: abad-ai/braid)

# Write-Host is intentional for user-facing output in this interactive
# installer -- output should go directly to the host, not the pipeline.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingWriteHost', '',
    Justification = 'Interactive installer: Write-Host is the right choice for user-facing messages that should not enter the pipeline.'
)]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Repo = if ($env:BRAID_REPO) { $env:BRAID_REPO } else { 'abad-ai/braid' }
$InstallDir = Join-Path $env:USERPROFILE '.braid\bin'
$BinName = 'braid.exe'

function Fail($msg) {
    Write-Error "install.ps1: $msg"
    exit 1
}

# --- Preflight: gh must exist and be authenticated --------------------------
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Fail "GitHub CLI 'gh' is required (source repo is private). Install via https://cli.github.com and re-run."
}
& gh auth status *> $null
if ($LASTEXITCODE -ne 0) {
    Fail "gh is installed but not authenticated. Run: gh auth login"
}

# --- Resolve & validate version --------------------------------------------
$Version = if ($env:BRAID_VERSION) { $env:BRAID_VERSION } else { 'latest' }
$VersionPattern = '^(latest|v?[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?)$'
if ($Version -notmatch $VersionPattern) {
    Fail "Invalid BRAID_VERSION: '$Version'. Expected 'latest' or a semver like v0.5.0."
}

if ($Version -eq 'latest') {
    $Version = (& gh release view --repo $Repo --json tagName -q .tagName).Trim()
    if (-not $Version) {
        Fail "Could not resolve latest release tag for $Repo."
    }
}

# Normalize to v-prefix. Release tags and asset names always carry the `v`
# (e.g. `v0.5.0`, `braid-v0.5.0-windows-x64.exe`), but BRAID_VERSION accepts
# both `v0.5.0` and `0.5.0` for ergonomics. Without this normalization, a bare
# semver would ask gh for release "0.5.0" (404) and look for asset
# "braid-0.5.0-..." (also missing).
if ($Version -notmatch '^v') { $Version = "v$Version" }

if ($Version -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$') {
    Fail "Resolved tag '$Version' is not a valid semver."
}

# Windows binaries are always x64 for v1.
$Asset = "braid-$Version-windows-x64.exe"

# --- Download ---------------------------------------------------------------
$TmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("braid-install-" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $TmpDir | Out-Null

try {
    # Two separate `gh release download` calls so the user gets useful
    # progress: SHA256SUMS is instant, but the binary is ~120MB and takes
    # a minute. A combined call only prints one status line and looks
    # like a hang during the long binary fetch.
    Write-Host "Fetching checksums from $Repo@$Version..."
    & gh release download $Version --repo $Repo -p 'SHA256SUMS' -D $TmpDir --clobber
    if ($LASTEXITCODE -ne 0) { Fail "gh release download (SHA256SUMS) failed." }

    $SumsPath = Join-Path $TmpDir 'SHA256SUMS'
    if (-not (Test-Path $SumsPath)) { Fail "SHA256SUMS not found on release $Version (cannot verify integrity)." }

    # For the binary itself we bypass `gh release download` (no progress UI)
    # and use Invoke-WebRequest, which renders a native progress bar.
    # Auth via `gh auth token` preserves the same private-repo flow.
    # Parse the release JSON in PowerShell rather than threading jq through
    # PS quote-escaping (which was a source of bugs).
    $ReleaseJson = (& gh api "repos/$Repo/releases/tags/$Version") -join "`n"
    if ($LASTEXITCODE -ne 0 -or -not $ReleaseJson) {
        Fail "Failed to query release $Version on $Repo (check network and gh authentication)."
    }
    $ReleaseObj   = $ReleaseJson | ConvertFrom-Json
    $AssetObj     = $ReleaseObj.assets | Where-Object { $_.name -eq $Asset } | Select-Object -First 1
    if (-not $AssetObj) { Fail "Asset $Asset not found on release $Version." }
    $AssetApiUrl  = $AssetObj.url

    $GhToken = (& gh auth token).Trim()
    if (-not $GhToken) { Fail "Could not read gh token (gh auth token returned empty)." }

    $AssetPath = Join-Path $TmpDir $Asset
    Write-Host "Downloading $Asset..."
    # Force the cmdlet's progress UI on even if the user shell suppresses it.
    $prevProgress = $ProgressPreference
    $ProgressPreference = 'Continue'
    try {
        Invoke-WebRequest -Uri $AssetApiUrl -OutFile $AssetPath -UseBasicParsing `
            -Headers @{
                Authorization = "Bearer $GhToken"
                Accept        = 'application/octet-stream'
            }
    } finally {
        $ProgressPreference = $prevProgress
        Remove-Variable GhToken
    }

    if (-not (Test-Path $AssetPath)) { Fail "Download succeeded but $Asset is missing (unexpected)." }

    # --- Verify SHA256 ------------------------------------------------------
    Write-Host 'Verifying SHA256...'
    $expectedLine = Get-Content $SumsPath | Where-Object { $_ -match ("\s\*?" + [regex]::Escape($Asset) + "$") }
    if (-not $expectedLine) { Fail "No SHA256SUMS entry for $Asset" }
    $expected = ($expectedLine -split '\s+', 2)[0].ToLower()
    $actual   = (Get-FileHash -Algorithm SHA256 -Path $AssetPath).Hash.ToLower()
    if ($expected -ne $actual) {
        Fail "SHA256 mismatch for $Asset`n  expected: $expected`n  actual:   $actual"
    }

    # --- Install ------------------------------------------------------------
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    $DestPath = Join-Path $InstallDir $BinName

    # Windows holds an exclusive lock on running PE images, so a plain
    # Copy-Item over an in-use braid.exe (which is exactly what happens
    # during `braid upgrade`) fails with "file in use". Standard self-update
    # pattern: rename the old binary out of the way first (Windows allows
    # renaming a locked file -- the rename only takes effect for new opens),
    # then copy the new binary into place. The renamed file lingers until
    # the running process exits, and we leave it for the next run to clean.
    if (Test-Path $DestPath) {
        $StaleSuffix = '.old-' + [System.Guid]::NewGuid().ToString('N')
        try {
            Rename-Item -Path $DestPath -NewName ($BinName + $StaleSuffix) -ErrorAction Stop
        } catch {
            Fail "Could not move existing $DestPath out of the way (is another braid process holding it?). $_"
        }
    }

    # Best-effort cleanup of stale .old-* leftovers from prior upgrades.
    Get-ChildItem -Path $InstallDir -Filter ($BinName + '.old-*') -ErrorAction SilentlyContinue |
        ForEach-Object {
            Remove-Item -Force -Path $_.FullName -ErrorAction SilentlyContinue
        }

    Copy-Item -Force -Path $AssetPath -Destination $DestPath

    Write-Host ''
    Write-Host "Installed $Version -> $(Join-Path $InstallDir $BinName)"

    if (-not (($env:PATH -split ';') -contains $InstallDir)) {
        Write-Host ''
        Write-Host "Add $InstallDir to your User PATH. Run this in a fresh PowerShell window:"
        Write-Host ''
        Write-Host "  `$old = [Environment]::GetEnvironmentVariable('Path', 'User')"
        Write-Host "  if (-not (`$old -split ';' | Where-Object { `$_ -eq '$InstallDir' })) {"
        Write-Host "    [Environment]::SetEnvironmentVariable('Path', `"`$old;$InstallDir`", 'User')"
        Write-Host '  }'
        Write-Host ''
        Write-Host "Then open a new terminal. (Avoid 'setx PATH' -- it has a 1024-char limit and silently truncates long PATH values.)"
    }
    Write-Host ''
    Write-Host 'Run: braid --version'
}
finally {
    if (Test-Path $TmpDir) { Remove-Item -Recurse -Force $TmpDir }
}
