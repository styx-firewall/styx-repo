#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

# rebuild_repo-v3.sh
# Improved version of rebuild_repo.sh using standard APT repo layout.
#
# Purpose:
# - Build and publish an APT repository for a given environment (dev/test/prod).
# - Standard structure: suite=trixie, component=styx-{dev,test,prod}
# - Downloads kernel assets, builds small metapackages, moves selected .deb files
#   into `pool/main/<component>`, regenerates `dists/<suite>/<component>/binary-amd64/Packages`
#   and `Release`, and optionally signs the Release with a GPG key.
#
# Key mechanics (remember):
# 1) Place the .deb files you want to publish into the repository root (REPO_BASE).
#    The script glob `*.deb` picks them up, moves them to `pool/main` and then
#    deletes those originals from the repo root.
# 2) Run the script with the target environment name (default `dev`):
#      ./rebuild_repo-v3.sh dev
#    This generates `dists/trixie/styx-dev/...`.
#    Use `./rebuild_repo-v3.sh test` for `dists/trixie/styx-test/...`.
# 3) To override kernel selection or revision, set environment variables:
#      REVISION=15 KERNEL_VERSION=6.13.2-15-styx ./rebuild_repo-v3.sh dev
# 4) Signing: signs `Release` only if the GPG key exists.
#
# Usage examples:
#   ./rebuild_repo-v3.sh           # dev
#   ./rebuild_repo-v3.sh test      # test
#   ./rebuild_repo-v3.sh prod      # prod
#
# Environment variables used (can be exported or prefixed at runtime):
#  - ENVIRONMENT or first positional arg: environment name (dev/test/prod)
#  - REPO_BASE: repository root (default `.`)
#  - REPO_DISTRO: distribution name (default `trixie`)
#  - REVISION, KERNEL_VERSION: control kernel assets download
#  - GPG_KEY_ID: key id/email for signing
#  - KEY_FILENAME: name to export the public key file
#
# Safety notes:
# - The script requires external commands: wget, dpkg-deb, dpkg-scanpackages,
#   apt-ftparchive, ar, tar, gzip. It exits if they are missing.
# - Files moved from repo root to `pool/main/<component>` are removed from the root
#   (to keep the repo clean). If you want to stage packages without deleting originals,
#   use a temporary directory and run the script from there.
# - The script supports dev/test/prod environments. For production, ensure the correct
#   GPG signing key is available and consider additional access controls.
#
# End of header

ENVIRONMENT="${1:-dev}"
REVISION="${REVISION:-15}"
KERNEL_VERSION="${KERNEL_VERSION:-6.12.87-${REVISION}-styx}"

REPO_BASE="${REPO_BASE:-.}"

# Ensure all operations happen inside the repo root
cd "$REPO_BASE" || { echo "[!] Cannot cd to REPO_BASE: $REPO_BASE" >&2; exit 1; }

REPO_DISTRO="${REPO_DISTRO:-trixie}"
REPO_COMPONENT="styx-$ENVIRONMENT"
REPO_DIST="$REPO_DISTRO"
POOL_DIR="$REPO_BASE/pool/main/$REPO_COMPONENT"
DIST_DIR="$REPO_BASE/dists/$REPO_DIST/$REPO_COMPONENT/binary-amd64"
STAGE_DIR="$REPO_BASE/stage/$REPO_COMPONENT"

# Git remote — saved early so filter-repo cannot wipe it
ORIGIN_URL="${ORIGIN_URL:-https://github.com/styx-firewall/styx-repo.git}"

# Override kernel version per component via optional config file.
# Create stage/<component>/kernel.conf with:
#   REVISION=15
#   KERNEL_VERSION=6.12.87-15-styx
# If the file does not exist, the defaults above are used.
if [ -f "$STAGE_DIR/kernel.conf" ]; then
  echo "[+] Loading kernel overrides from $STAGE_DIR/kernel.conf"
  source "$STAGE_DIR/kernel.conf"
fi

# Expected kernel asset filenames (used for download and verification)
HEADER_NAME="linux-headers-${KERNEL_VERSION}_${REVISION}_amd64.deb"
IMAGE_NAME="linux-image-${KERNEL_VERSION}_${REVISION}_amd64.deb"
LIBC_NAME="linux-libc-dev_${REVISION}_amd64.deb"

GPG_KEY_ID="${GPG_KEY_ID:-diegargon@}"
KEY_FILENAME="${KEY_FILENAME:-styx-firewall-keyring.gpg}"

META_VERSION="1.6"
META_ARCH="amd64"
META_HEADERS_DIR="linux-headers-styx"
META_HEADERS_DEBIAN_DIR="$META_HEADERS_DIR/DEBIAN"
META_HEADERS_CONTROL_FILE="$META_HEADERS_DEBIAN_DIR/control"
META_HEADERS_DEPENDS="linux-headers-${KERNEL_VERSION}"
META_DIR="linux-image-styx"
META_DEBIAN_DIR="$META_DIR/DEBIAN"
META_CONTROL_FILE="$META_DEBIAN_DIR/control"
META_DEPENDS="linux-image-${KERNEL_VERSION}"

ASSET_BASE="https://github.com/styx-firewall/styx-kernel/releases/download/v0.${REVISION}"

required_cmds=(wget dpkg-deb dpkg-scanpackages apt-ftparchive ar tar gzip)
for cmd in "${required_cmds[@]}"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "[!] Required command not found: $cmd" >&2
    exit 1
  fi
done

echo "[+] Repo: $REPO_BASE  dist: $REPO_DIST  component: $REPO_COMPONENT  kernel: $KERNEL_VERSION"

# NOTE: always call with || to handle failures (set -e is active)
download_or_fail() {
  local url="$1"
  echo "[*] Downloading $url"
  if ! wget -c "$url"; then
    echo "[!] Failed to download: $url" >&2
    return 1
  fi
  return 0
}

download_kernel_assets() {
  if [ ! -f "$HEADER_NAME" ]; then
    download_or_fail "$ASSET_BASE/$HEADER_NAME" || echo "[!] Warning: header not downloaded: $HEADER_NAME"
  else
    echo "[+] Found local $HEADER_NAME"
  fi

  if [ ! -f "$IMAGE_NAME" ]; then
    download_or_fail "$ASSET_BASE/$IMAGE_NAME" || echo "[!] Warning: image not downloaded: $IMAGE_NAME"
  else
    echo "[+] Found local $IMAGE_NAME"
  fi

  if [ ! -f "$LIBC_NAME" ]; then
    download_or_fail "$ASSET_BASE/$LIBC_NAME" || echo "[!] Warning: linux-libc-dev not downloaded: $LIBC_NAME"
  else
    echo "[+] Found local $LIBC_NAME"
  fi
}

echo "[+] Creating directories"
mkdir -p "$POOL_DIR"
mkdir -p "$DIST_DIR"
mkdir -p "$STAGE_DIR"

echo "[+] Downloading kernel assets"
download_kernel_assets

# Verify required kernel assets exist; fail if any are missing
missing=()
for f in "$HEADER_NAME" "$IMAGE_NAME" "$LIBC_NAME"; do
  if [ ! -f "$f" ]; then
    missing+=("$f")
  fi
done
if [ ${#missing[@]} -gt 0 ]; then
  echo "[!] ERROR: missing required kernel assets:" >&2
  for m in "${missing[@]}"; do
    echo "    - $m" >&2
  done
  echo "    Ensure the kernel builder publishes these assets or set REVISION/KERNEL_VERSION appropriately." >&2
  exit 1
fi

echo "[+] Creating linux-image-styx metapackage"
rm -rf "$META_DIR"
mkdir -p "$META_DEBIAN_DIR"
cat > "$META_CONTROL_FILE" <<EOF
Package: linux-image-styx
Version: $META_VERSION
Architecture: $META_ARCH
Maintainer: Styx Firewall <repo@styx-firewall>
Depends: $META_DEPENDS
Description: Metapackage to install the Styx Linux kernel
EOF
dpkg-deb --build "$META_DIR"
if [ -f "$META_DIR.deb" ]; then
  echo "[+] Package generated: $META_DIR.deb"
  ls -lh "$META_DIR.deb"
  mv -v -- "$META_DIR.deb" "$REPO_BASE/"
else
  echo "[!] ERROR: metapackage $META_DIR.deb was not built" >&2
  exit 1
fi

echo "[+] Creating linux-headers-styx metapackage"
rm -rf "$META_HEADERS_DIR"
mkdir -p "$META_HEADERS_DEBIAN_DIR"
cat > "$META_HEADERS_CONTROL_FILE" <<EOF
Package: linux-headers-styx
Version: $META_VERSION
Architecture: $META_ARCH
Maintainer: Styx Firewall <repo@styx-firewall>
Depends: $META_HEADERS_DEPENDS
Description: Metapackage to install the Styx Linux kernel headers
EOF
dpkg-deb --build "$META_HEADERS_DIR"
if [ -f "$META_HEADERS_DIR.deb" ]; then
  echo "[+] Package generated: $META_HEADERS_DIR.deb"
  ls -lh "$META_HEADERS_DIR.deb"
  mv -v -- "$META_HEADERS_DIR.deb" "$REPO_BASE/"
else
  echo "[!] ERROR: metapackage $META_HEADERS_DIR.deb was not built" >&2
  exit 1
fi

# Move .deb files to pool/main (from repo root + staging)
echo "[+] Moving .deb files to $POOL_DIR"
shopt -s nullglob
debs=( *.deb "$STAGE_DIR"/*.deb )
if [ ${#debs[@]} -gt 0 ]; then
  mv -v -- "${debs[@]}" "$POOL_DIR/"
else
  echo "[!] No .deb files found to move"
fi
shopt -u nullglob

echo "[+] Generating Packages list"
dpkg-scanpackages --multiversion "pool/main/$REPO_COMPONENT" > "$DIST_DIR/Packages"
gzip -k -f "$DIST_DIR/Packages"

echo "[+] Generating Release"

# Use apt-ftparchive config to generate the complete Release in one pass
# (avoids duplicate fields from manual cat + append)
APT_CONF=$(mktemp /tmp/styx-apt-conf.XXXXXX)
cat > "$APT_CONF" <<EOFCONF
APT::FTPArchive::Release::Origin "STYX Firewall";
APT::FTPArchive::Release::Label "STYX Repository";
APT::FTPArchive::Release::Suite "$REPO_DIST";
APT::FTPArchive::Release::Codename "$REPO_DIST";
APT::FTPArchive::Release::Architectures "amd64";
APT::FTPArchive::Release::Components "$REPO_COMPONENT";
APT::FTPArchive::Release::Description "STYX Firewall packages";
EOFCONF

apt-ftparchive -c "$APT_CONF" release "$REPO_BASE/dists/$REPO_DIST" > "$REPO_BASE/dists/$REPO_DIST/Release"
rm -f "$APT_CONF"

# Signing (optional)
if gpg --list-secret-keys "$GPG_KEY_ID" >/dev/null 2>&1; then
  echo "[+] Signing Release with key $GPG_KEY_ID"
  rm -f "$REPO_BASE/dists/$REPO_DIST/Release.gpg" "$REPO_BASE/dists/$REPO_DIST/InRelease" || true
  gpg --yes --batch --default-key "$GPG_KEY_ID" -abs -o "$REPO_BASE/dists/$REPO_DIST/Release.gpg" "$REPO_BASE/dists/$REPO_DIST/Release"
  gpg --yes --batch --default-key "$GPG_KEY_ID" --clearsign -o "$REPO_BASE/dists/$REPO_DIST/InRelease" "$REPO_BASE/dists/$REPO_DIST/Release"
else
  echo "[!] ERROR: GPG key '$GPG_KEY_ID' not found" >&2
  echo "    Available keys:"
  gpg --list-secret-keys --keyid-format LONG
  exit 1
fi

# Export public key if available
if gpg --list-keys "$GPG_KEY_ID" >/dev/null 2>&1; then
  echo "[+] Exporting public key to $REPO_BASE/$KEY_FILENAME and .asc"
  gpg --export --armor "$GPG_KEY_ID" > "$REPO_BASE/$KEY_FILENAME.asc"
  gpg --export "$GPG_KEY_ID" | gpg --dearmor > "$REPO_BASE/$KEY_FILENAME"
  echo -e "\n🔑 Key fingerprint (verify it):"
  gpg --fingerprint "$GPG_KEY_ID" | grep -E "([0-9A-F]{4} ?){10}" || true
fi

echo "[+] Cleaning temporary metapackage directories"
rm -rf "$META_DIR" "$META_HEADERS_DIR"

echo "[+] Cleaning .deb files left in repo root and staging..."
find "$REPO_BASE" -maxdepth 1 -type f -name '*.deb' -exec rm -v {} \;
find "$STAGE_DIR" -maxdepth 1 -type f -name '*.deb' -exec rm -v {} \;
echo "[+] Cleaning completed."

# --- Git operations (interactive) ---
echo "[+] Updating Git repository (interactive)"
read -p "Do you want to push the changes to git? (y/n): " confirm
if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
  git add -A
  git commit -m "Update repo $REPO_DIST/$REPO_COMPONENT $(date +%Y-%m-%d)" || true
  if [ -d "$POOL_DIR" ]; then
    echo "[+] Backing up $POOL_DIR to $REPO_BASE/pool2..."
    rm -rf "$REPO_BASE/pool2"
    cp -a "$POOL_DIR" "$REPO_BASE/pool2"

    echo "[+] Running git filter-repo to clean pool/main history (optional)"
    if command -v git-filter-repo >/dev/null 2>&1 || command -v git filter-repo >/dev/null 2>&1; then
      git filter-repo --path pool/main/ --invert-paths --force || echo "[!] git filter-repo failed or not available"
    else
      echo "[!] git-filter-repo not available; skipping history rewrite"
    fi

    echo "[+] Restoring pool2 to pool/main..."
    rm -rf "$POOL_DIR"
    mkdir -p "$(dirname "$POOL_DIR")"
    cp -a "$REPO_BASE/pool2" "$POOL_DIR"
    rm -rf "$REPO_BASE/pool2"
    if [ -n "$ORIGIN_URL" ] && ! git remote | grep -q '^origin$'; then
      git remote add origin "$ORIGIN_URL"
      echo "[+] Origin remote restored: $ORIGIN_URL"
    fi
  fi
  git add -A
  git commit -m "Update repo $REPO_DIST/$REPO_COMPONENT $(date +%Y-%m-%d)" || true
  if git push --force origin main; then
    echo "[+] Changes pushed to git."
  else
    echo "[!] git push failed"
  fi
else
  echo "[!] Git push cancelled by user."
fi

echo -e "\n✔ Repository $REPO_DIST/$REPO_COMPONENT updated successfully.\n"
echo "📦 Instructions for users:"
echo
echo "1. Recommended option (binary, for APT):"
echo "   curl -fsSL https://styx-firewall.github.io/styx-repo/$KEY_FILENAME | sudo tee /usr/share/keyrings/$KEY_FILENAME >/dev/null"
echo "   echo \"deb [arch=amd64 signed-by=/usr/share/keyrings/$KEY_FILENAME] https://styx-firewall.github.io/styx-repo $REPO_DIST $REPO_COMPONENT\" | sudo tee /etc/apt/sources.list.d/styx.list"
echo "   sudo apt update"
echo
echo "2. Alternative option (manual verification):"
echo "   curl -fsSL https://styx-firewall.github.io/styx-repo/$KEY_FILENAME.asc | sudo gpg --dearmor -o /usr/share/keyrings/$KEY_FILENAME"

exit 0