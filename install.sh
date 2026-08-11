#!/bin/sh
# Lovie CLI installer.
#   curl -fsSL https://raw.githubusercontent.com/lovieco/homebrew-tap/main/install.sh | sh
#
# Env overrides:
#   LOVIE_VERSION   pin a version tag (e.g. v0.1.0); default = latest release
#   LOVIE_BIN_DIR   install dir (default: /usr/local/bin, or ~/.local/bin if not writable)
#
# Verification: the SHA-256 checksum is always enforced. When cosign is on
# PATH the archive's Sigstore bundle is also verified against the exact
# lovieco/lovie release-workflow identity; a bad or missing signature then
# fails the install. Without cosign a warning is printed and only the
# checksum protects you.
set -eu

REPO="lovieco/homebrew-tap"

os=$(uname -s | tr '[:upper:]' '[:lower:]')
arch=$(uname -m)
case "$arch" in
  x86_64 | amd64) arch=amd64 ;;
  arm64 | aarch64) arch=arm64 ;;
  *) echo "unsupported architecture: $arch" >&2; exit 1 ;;
esac
case "$os" in
  linux | darwin) ;;
  *) echo "unsupported OS: $os (use the Windows zip from the releases page)" >&2; exit 1 ;;
esac

tag="${LOVIE_VERSION:-}"
if [ -z "$tag" ]; then
  tag=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
    | grep '"tag_name"' \
    | head -1 \
    | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
fi
if [ -z "$tag" ]; then
  echo "could not determine the latest lovie release; set LOVIE_VERSION" >&2
  exit 1
fi

version="${tag#v}"
asset="lovie_${version}_${os}_${arch}.tar.gz"
url="https://github.com/${REPO}/releases/download/${tag}/${asset}"

echo "Downloading ${asset} (${tag})..."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL "$url" -o "$tmp/$asset"

sums_url="https://github.com/${REPO}/releases/download/${tag}/checksums.txt"
if ! curl -fsSL "$sums_url" -o "$tmp/checksums.txt"; then
  echo "could not download checksums.txt; refusing to install an unverified binary" >&2
  exit 1
fi
expected=$(grep " ${asset}$" "$tmp/checksums.txt" | awk '{print $1}' | head -1)
if [ -z "$expected" ]; then
  echo "checksum for ${asset} not found in checksums.txt" >&2
  exit 1
fi
if command -v sha256sum >/dev/null 2>&1; then
  actual=$(sha256sum "$tmp/$asset" | awk '{print $1}')
else
  actual=$(shasum -a 256 "$tmp/$asset" | awk '{print $1}')
fi
if [ "$expected" != "$actual" ]; then
  echo "checksum mismatch for ${asset}:" >&2
  echo "  expected $expected" >&2
  echo "  actual   $actual" >&2
  exit 1
fi
echo "Checksum verified."

if command -v cosign >/dev/null 2>&1; then
  bundle_url="https://github.com/${REPO}/releases/download/${tag}/${asset}.sigstore.json"
  if ! curl -fsSL "$bundle_url" -o "$tmp/$asset.sigstore.json"; then
    echo "could not download the signature bundle for ${asset}; refusing to install" >&2
    exit 1
  fi
  identity="https://github.com/lovieco/lovie/.github/workflows/cli-release.yml@refs/tags/lovie-cli/${tag}"
  if ! cosign verify-blob \
    --bundle "$tmp/$asset.sigstore.json" \
    --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
    --certificate-identity "$identity" \
    "$tmp/$asset" >/dev/null 2>&1; then
    echo "signature verification failed for ${asset} (expected identity: $identity)" >&2
    exit 1
  fi
  echo "Signature verified."
else
  echo "warning: cosign not found — skipping signature verification (checksum only)" >&2
fi

tar -xzf "$tmp/$asset" -C "$tmp"

bindir="${LOVIE_BIN_DIR:-/usr/local/bin}"
if [ ! -d "$bindir" ] || [ ! -w "$bindir" ]; then
  bindir="$HOME/.local/bin"
  mkdir -p "$bindir"
fi
install -m 0755 "$tmp/lovie" "$bindir/lovie"

echo "Installed lovie to $bindir/lovie"
case ":$PATH:" in
  *":$bindir:"*) ;;
  *) echo "Note: $bindir is not on your PATH — add it, e.g. export PATH=\"$bindir:\$PATH\"" ;;
esac
"$bindir/lovie" version
