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

# Re-validate the resolved tag (defense-in-depth — gh output is trusted, but
# this also catches accidental empty/garbage responses).
if ! printf '%s' "$VERSION" | grep -Eq '^v?[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$'; then
	err "Resolved tag '$VERSION' is not a valid semver."
	exit 1
fi

ASSET="braid-${VERSION}-${OS}-${ARCH}"

# --- Download with checksum verification ------------------------------------
TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

printf 'Downloading %s from %s@%s...\n' "$ASSET" "$REPO" "$VERSION"
gh release download "$VERSION" \
	--repo "$REPO" \
	-p "$ASSET" \
	-p "SHA256SUMS" \
	-D "$TMP_DIR" \
	--clobber

if [ ! -f "$TMP_DIR/$ASSET" ]; then
	err "Asset $ASSET not found on release $VERSION."
	exit 1
fi
if [ ! -f "$TMP_DIR/SHA256SUMS" ]; then
	err "SHA256SUMS not found on release $VERSION (cannot verify integrity)."
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
