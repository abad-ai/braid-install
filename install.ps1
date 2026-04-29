# install.ps1 — Windows installer for the Braid CLI.
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

if ($Version -notmatch '^v?[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$') {
    Fail "Resolved tag '$Version' is not a valid semver."
}

# Windows binaries are always x64 for v1.
$Asset = "braid-$Version-windows-x64.exe"

# --- Download ---------------------------------------------------------------
$TmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("braid-install-" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $TmpDir | Out-Null

try {
    Write-Host "Downloading $Asset from $Repo@$Version..."
    & gh release download $Version --repo $Repo -p $Asset -p 'SHA256SUMS' -D $TmpDir --clobber
    if ($LASTEXITCODE -ne 0) { Fail "gh release download failed." }

    $AssetPath = Join-Path $TmpDir $Asset
    $SumsPath  = Join-Path $TmpDir 'SHA256SUMS'
    if (-not (Test-Path $AssetPath)) { Fail "Asset $Asset not found on release $Version." }
    if (-not (Test-Path $SumsPath))  { Fail "SHA256SUMS not found on release $Version (cannot verify integrity)." }

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
    Copy-Item -Force -Path $AssetPath -Destination (Join-Path $InstallDir $BinName)

    Write-Host ''
    Write-Host "Installed $Version -> $(Join-Path $InstallDir $BinName)"

    if (-not (($env:PATH -split ';') -contains $InstallDir)) {
        Write-Host ''
        Write-Host "Add $InstallDir to your PATH:"
        Write-Host "  setx PATH `"`$env:PATH;$InstallDir`""
        Write-Host '  (then open a new terminal)'
    }
    Write-Host ''
    Write-Host 'Run: braid --version'
}
finally {
    if (Test-Path $TmpDir) { Remove-Item -Recurse -Force $TmpDir }
}
