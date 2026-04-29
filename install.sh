#!/usr/bin/env bash
# install.sh — Unix installer for the Braid CLI.
#
# Source repo abad-ai/braid is private, so this script uses `gh` to download
# release assets. The user must have `gh` installed and authenticated against
# the abad-ai org. SHA256SUMS verification is mandatory — the binary is never
# executed before its checksum matches.
#
# Mirrored to the public abad-ai/braid-install repo so the one-liner is:
#   curl -fsSL https://raw.githubusercontent.com/abad-ai/braid-install/main/install.sh | bash
#
# Env vars:
#   BRAID_VERSION  release tag to install (default: latest)
#   BRAID_REPO     source repo (default: abad-ai/braid)

set -euo pipefail

REPO="${BRAID_REPO:-abad-ai/braid}"
INSTALL_DIR="${HOME}/.braid/bin"
BIN_NAME="braid"

err() { printf 'install.sh: %s\n' "$*" >&2; }

# --- Preflight: gh must exist and be authenticated --------------------------
if ! command -v gh >/dev/null 2>&1; then
	err "GitHub CLI 'gh' is required (source repo is private)."
	err "Install via https://cli.github.com and re-run."
	exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
	err "gh is installed but not authenticated."
	err "Run: gh auth login"
	exit 1
fi

# --- Detect platform --------------------------------------------------------
UNAME_S="$(uname -s)"
case "$UNAME_S" in
	Linux)  OS="linux" ;;
	Darwin) OS="darwin" ;;
	*)
		err "Unsupported OS: $UNAME_S (only Linux and Darwin are supported)."
		exit 1
		;;
esac

UNAME_M="$(uname -m)"
case "$UNAME_M" in
	x86_64|amd64) ARCH="x64" ;;
	aarch64|arm64) ARCH="arm64" ;;
	*)
		err "Unsupported architecture: $UNAME_M"
		exit 1
		;;
esac

# Bun's `bun-linux-*` cross-compile targets are glibc-linked. On musl-based
# distros (Alpine and friends) the binary downloads and SHA-verifies cleanly
# but fails at runtime with a confusing dynamic-loader error. Detect musl up
# front so the failure mode is "we don't ship a binary for your distro" rather
# than "your install seemed to work but braid won't start."
if [ "$OS" = "linux" ]; then
	# `ldd --version` writes "musl libc" on musl, "GNU libc"/"GLIBC" on glibc.
	# It exits non-zero on musl (intentional), so check both stdout+stderr and
	# don't fail the script on the non-zero exit.
	LDD_OUT="$( (ldd --version 2>&1) || true )"
	IS_MUSL=0
	if printf '%s' "$LDD_OUT" | grep -qi 'musl'; then
		IS_MUSL=1
	fi
	# Defense-in-depth: minimal containers (busybox, distroless) may lack
	# `ldd` entirely, in which case the grep above can silently miss musl.
	# The presence of the musl dynamic loader at /lib/ld-musl-* is the
	# canonical signal regardless of whether ldd exists.
	for ld in /lib/ld-musl-*; do
		if [ -e "$ld" ]; then
			IS_MUSL=1
			break
		fi
	done
	if [ "$IS_MUSL" = "1" ]; then
		err "Detected musl libc (Alpine, etc.). Braid binaries are glibc-only."
		err "Workarounds:"
		err "  - install on a glibc distro (Ubuntu, Debian, Fedora, etc.)"
		err "  - or build from source: https://github.com/abad-ai/braid"
		exit 1
	fi
fi

# --- Resolve & validate version ---------------------------------------------
VERSION="${BRAID_VERSION:-latest}"

# Validate BRAID_VERSION before passing to gh. Allowed: vX.Y.Z, X.Y.Z, with
# optional pre-release suffix; or the literal "latest".
if ! printf '%s' "$VERSION" | grep -Eq '^(latest|v?[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?)$'; then
	err "Invalid BRAID_VERSION: '$VERSION'"
	err "Expected 'latest' or a semver like v0.5.0 / 0.5.0 / 0.5.0-rc1"
	exit 1
fi

if [ "$VERSION" = "latest" ]; then
	VERSION="$(gh release view --repo "$REPO" --json tagName -q .tagName)"
	if [ -z "$VERSION" ]; then
		err "Could not resolve latest release tag for $REPO."
		exit 1
	fi
fi

# Normalize to v-prefix. Release tags and asset names always carry the `v`
# (e.g. `v0.5.0`, `braid-v0.5.0-linux-x64`), but BRAID_VERSION accepts both
# `v0.5.0` and `0.5.0` for ergonomics. Without normalization, a bare semver
# would ask gh for release "0.5.0" (404) and look for asset "braid-0.5.0-..."
# (also missing).
case "$VERSION" in
	v*) ;;
	*) VERSION="v$VERSION" ;;
esac

# Re-validate the resolved tag (defense-in-depth — gh output is trusted, but
# this also catches accidental empty/garbage responses).
if ! printf '%s' "$VERSION" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$'; then
	err "Resolved tag '$VERSION' is not a valid semver."
	exit 1
fi

ASSET="braid-${VERSION}-${OS}-${ARCH}"

# --- Download with checksum verification ------------------------------------
TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# Two separate `gh release download` calls so the user gets useful
# progress: the SHA256SUMS download is instant, but the binary is ~100MB
# and takes a noticeable amount of time. A combined call would only print
# one status line and look like a hang during the long binary fetch.
printf 'Fetching checksums from %s@%s...\n' "$REPO" "$VERSION"
gh release download "$VERSION" \
	--repo "$REPO" \
	-p "SHA256SUMS" \
	-D "$TMP_DIR" \
	--clobber \
	|| { err "Failed to download SHA256SUMS from $REPO@$VERSION (check network and gh authentication)."; exit 1; }

if [ ! -f "$TMP_DIR/SHA256SUMS" ]; then
	err "SHA256SUMS not found on release $VERSION (cannot verify integrity)."
	exit 1
fi

# For the binary itself we bypass `gh release download` (which has no
# progress UI) and use curl with --progress-bar. Auth via `gh auth token`
# preserves the same private-repo flow. Asset URL comes from the same
# release lookup `gh release download` would do internally.
ASSET_API_URL="$(gh api "repos/$REPO/releases/tags/$VERSION" \
	--jq ".assets[] | select(.name == \"$ASSET\") | .url")" \
	|| { err "Failed to query release assets for $REPO@$VERSION (check network and gh authentication)."; exit 1; }
if [ -z "$ASSET_API_URL" ]; then
	err "Asset $ASSET not found on release $VERSION."
	exit 1
fi

GH_TOKEN_FOR_DOWNLOAD="$(gh auth token 2>/dev/null)"
if [ -z "$GH_TOKEN_FOR_DOWNLOAD" ]; then
	err "Could not read gh token (gh auth token returned empty)."
	exit 1
fi

printf 'Downloading %s...\n' "$ASSET"
curl --fail --location --progress-bar \
	-H "Authorization: Bearer $GH_TOKEN_FOR_DOWNLOAD" \
	-H "Accept: application/octet-stream" \
	-o "$TMP_DIR/$ASSET" \
	"$ASSET_API_URL"
unset GH_TOKEN_FOR_DOWNLOAD

if [ ! -f "$TMP_DIR/$ASSET" ]; then
	err "Download succeeded but $ASSET is missing in $TMP_DIR (unexpected)."
	exit 1
fi

# Pick the right shasum tool per platform. Both produce the same checksum
# format ("<sha>  <filename>"), so `-c` works against the same SHA256SUMS.
printf 'Verifying SHA256...\n'
(
	cd "$TMP_DIR"
	# Reduce SHA256SUMS to only the line for our asset; otherwise -c will try
	# to verify every other platform's binary too and fail on missing files.
	grep -E "[[:space:]]+\\*?${ASSET}\$" SHA256SUMS > "${ASSET}.sha256" || {
		err "No SHA256SUMS entry for $ASSET"
		exit 1
	}
	if [ "$OS" = "darwin" ]; then
		shasum -a 256 -c "${ASSET}.sha256"
	else
		sha256sum -c "${ASSET}.sha256"
	fi
)

# --- Install ----------------------------------------------------------------
mkdir -p "$INSTALL_DIR"
install -m 0755 "$TMP_DIR/$ASSET" "$INSTALL_DIR/$BIN_NAME"

printf '\nInstalled %s -> %s\n' "$VERSION" "$INSTALL_DIR/$BIN_NAME"

case ":$PATH:" in
	*":$INSTALL_DIR:"*) ;;
	*)
		printf '\nAdd %s to your PATH:\n' "$INSTALL_DIR"
		# We want $PATH to remain literal in the printed command (the user
		# copies it into their shell rc), so single quotes are intentional.
		# shellcheck disable=SC2016
		printf '  export PATH="%s:$PATH"\n' "$INSTALL_DIR"
		printf '  # Append the line above to ~/.bashrc or ~/.zshrc to make it permanent.\n'
		;;
esac

printf '\nRun: braid --version\n'
