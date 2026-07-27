#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

# rebuild_repo.sh
# Build and publish an APT repository for ALL environments (dev, test, prod).
#
# Purpose:
# - Standard structure: suite=trixie, components=styx-{dev,test,prod}
# - Processes ALL three environments in a single run.
# - Pulls packages from stage/<component>/ if they exist.
# - Downloads kernel assets, builds small metapackages, moves .deb files
#   into each component's `pool/<component>/`, regenerates
#   `dists/<suite>/<component>/binary-amd64/Packages` and a combined
#   `Release`, then signs the Release with a GPG key.
#
# Key mechanics:
# 1) Place per-environment .deb files in:
#      stage/styx-dev/
#      stage/styx-test/
#      stage/styx-prod/
#    The script moves them to the corresponding pool/<component>/.
# 2) Kernel assets are downloaded once and shared across all components.
# 3) Metapackages (linux-image-styx, linux-headers-styx) are built once
#    and copied to all components.
#
# Usage:
#   ./rebuild_repo.sh
#
# Environment variables (optional):
#   REPO_BASE       - repository root (default: .)
#   REPO_DISTRO     - distribution name (default: trixie)
#   GPG_KEY_ID      - key id/email for signing (default: diegargon@)
#   KEY_FILENAME    - exported public key filename
#
# Per-component kernel overrides (optional).
# Revision is derived automatically from the version string (e.g. 6.12.87-15-styx → revision 15).
#   DEV_KERNEL_VERSION   - kernel version for styx-dev  (default: 6.12.87-15-styx)
#   TEST_KERNEL_VERSION  - kernel version for styx-test (default: 6.12.87-15-styx)
#   PROD_KERNEL_VERSION  - kernel version for styx-prod (default: 6.12.87-15-styx)
#
# Per-component GitHub release tag.
# Override via environment: DEV_KERNEL_TAG=v6.12.95-16-styx ./rebuild_repo.sh
#   DEV_KERNEL_TAG       - release tag for styx-dev  (default: v16)
#   TEST_KERNEL_TAG      - release tag for styx-test (default: v0.15)
#   PROD_KERNEL_TAG      - release tag for styx-prod (default: v0.15)
#
# End of header

# Per-component kernel version.
# Override via environment: DEV_KERNEL_VERSION=6.12.87-16-styx ./rebuild_repo.sh
DEV_KERNEL_VERSION="${DEV_KERNEL_VERSION:-6.12.95-17-styx}"
TEST_KERNEL_VERSION="${TEST_KERNEL_VERSION:-6.12.95-17-styx}"
PROD_KERNEL_VERSION="${PROD_KERNEL_VERSION:-6.12.95-17-styx}"

# Per-component GitHub release tag.
# Override via environment: DEV_KERNEL_TAG=v6.12.95-16-styx ./rebuild_repo.sh
DEV_KERNEL_TAG="${DEV_KERNEL_TAG:-6.12.95-17-styx}"
TEST_KERNEL_TAG="${TEST_KERNEL_TAG:-v0.15}"
PROD_KERNEL_TAG="${PROD_KERNEL_TAG:-v0.15}"

REPO_BASE="${REPO_BASE:-.}"

# Ensure all operations happen inside the repo root
cd "$REPO_BASE" || { echo "[!] Cannot cd to REPO_BASE: $REPO_BASE" >&2; exit 1; }

REPO_DISTRO="${REPO_DISTRO:-trixie}"
REPO_DIST="$REPO_DISTRO"

# All three environments — always processed
COMPONENTS=("styx-dev" "styx-test" "styx-prod")

# Git remote — saved early so filter-repo cannot wipe it
ORIGIN_URL="${ORIGIN_URL:-https://github.com/styx-firewall/styx-repo.git}"

GPG_KEY_ID="${GPG_KEY_ID:-diegargon@}"
KEY_FILENAME="${KEY_FILENAME:-styx-firewall-keyring.gpg}"

META_VERSION_BASE="1.6"
META_ARCH="amd64"
META_HEADERS_DIR="linux-headers-styx"
META_HEADERS_DEBIAN_DIR="$META_HEADERS_DIR/DEBIAN"
META_HEADERS_CONTROL_FILE="$META_HEADERS_DEBIAN_DIR/control"
META_DIR="linux-image-styx"
META_DEBIAN_DIR="$META_DIR/DEBIAN"
META_CONTROL_FILE="$META_DEBIAN_DIR/control"

required_cmds=(wget dpkg-deb dpkg-scanpackages apt-ftparchive ar tar gzip)
for cmd in "${required_cmds[@]}"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "[!] Required command not found: $cmd" >&2
    exit 1
  fi
done

echo "[+] Repo: $REPO_BASE  dist: $REPO_DIST"
echo "[+] Kernel versions: dev=$DEV_KERNEL_VERSION  test=$TEST_KERNEL_VERSION  prod=$PROD_KERNEL_VERSION"
echo "[+] Will process components: ${COMPONENTS[*]}"

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

# Process each component

ACTIVE_COMPONENTS=()

for COMP in "${COMPONENTS[@]}"; do
  echo ""
  echo "---- Processing component: $COMP ----"

  POOL_DIR="$REPO_BASE/pool/$COMP"
  DIST_DIR="$REPO_BASE/dists/$REPO_DIST/$COMP/binary-amd64"
  STAGE_DIR="$REPO_BASE/stage/$COMP"

  # Resolve per-component kernel configuration
  case "$COMP" in
    styx-dev)
      COMP_KERNEL_VERSION="$DEV_KERNEL_VERSION"
      COMP_KERNEL_TAG="$DEV_KERNEL_TAG"
      ;;
    styx-test)
      COMP_KERNEL_VERSION="$TEST_KERNEL_VERSION"
      COMP_KERNEL_TAG="$TEST_KERNEL_TAG"
      ;;
    styx-prod)
      COMP_KERNEL_VERSION="$PROD_KERNEL_VERSION"
      COMP_KERNEL_TAG="$PROD_KERNEL_TAG"
      ;;
  esac

  # Derive revision from kernel version (6.12.87-15-styx → 15)
  COMP_KERNEL_REVISION=$(echo "$COMP_KERNEL_VERSION" | sed 's/.*-\([0-9]\+\)-styx$/\1/')

  # Derive asset filenames and URLs for this component
  COMP_HEADER_NAME="linux-headers-${COMP_KERNEL_VERSION}_${COMP_KERNEL_REVISION}_amd64.deb"
  COMP_IMAGE_NAME="linux-image-${COMP_KERNEL_VERSION}_${COMP_KERNEL_REVISION}_amd64.deb"
  COMP_LIBC_NAME="linux-libc-dev_${COMP_KERNEL_REVISION}_amd64.deb"
  COMP_ASSET_BASE="https://github.com/styx-firewall/styx-kernel/releases/download/${COMP_KERNEL_TAG}"
  COMP_META_VERSION="${META_VERSION_BASE}-${COMP_KERNEL_REVISION}"

  echo "[+] Kernel for $COMP: $COMP_KERNEL_VERSION (revision $COMP_KERNEL_REVISION)"

  mkdir -p "$POOL_DIR" "$DIST_DIR" "$STAGE_DIR"

  # Download kernel assets for this component
  echo "[+] Downloading kernel assets for $COMP"
  for f in "$COMP_HEADER_NAME" "$COMP_IMAGE_NAME" "$COMP_LIBC_NAME"; do
    if [ ! -f "$f" ]; then
      download_or_fail "$COMP_ASSET_BASE/$f" || echo "[!] Warning: download failed: $f"
    else
      echo "[+] Found local $f"
    fi
  done

  # Verify required kernel assets exist; fail if any are missing
  missing=()
  for f in "$COMP_HEADER_NAME" "$COMP_IMAGE_NAME" "$COMP_LIBC_NAME"; do
    if [ ! -f "$f" ]; then
      missing+=("$f")
    fi
  done
  if [ ${#missing[@]} -gt 0 ]; then
    echo "[!] ERROR: missing required kernel assets for $COMP:" >&2
    for m in "${missing[@]}"; do
      echo "    - $m" >&2
    done
    echo "    Ensure the kernel builder publishes these assets or set ${COMP^^}_KERNEL_VERSION/${COMP^^}_KERNEL_REVISION appropriately." >&2
    exit 1
  fi

  # Build metapackages for this component
  echo "[+] Creating linux-image-styx metapackage for $COMP (version $COMP_META_VERSION)"
  rm -rf "$META_DIR"
  mkdir -p "$META_DEBIAN_DIR"
  cat > "$META_CONTROL_FILE" <<EOF
Package: linux-image-styx
Version: $COMP_META_VERSION
Architecture: $META_ARCH
Maintainer: Styx Firewall <repo@styx-firewall>
Depends: linux-image-${COMP_KERNEL_VERSION}
Description: Metapackage to install the Styx Linux kernel
EOF
  META_IMAGE_DEB="linux-image-styx_${COMP_META_VERSION}_amd64.deb"
  dpkg-deb --build "$META_DIR" "$REPO_BASE/$META_IMAGE_DEB"
  if [ -f "$REPO_BASE/$META_IMAGE_DEB" ]; then
    echo "[+] Package generated: $META_IMAGE_DEB"
    ls -lh "$REPO_BASE/$META_IMAGE_DEB"
  else
    echo "[!] ERROR: metapackage $META_IMAGE_DEB was not built" >&2
    exit 1
  fi

  echo "[+] Creating linux-headers-styx metapackage for $COMP (version $COMP_META_VERSION)"
  rm -rf "$META_HEADERS_DIR"
  mkdir -p "$META_HEADERS_DEBIAN_DIR"
  cat > "$META_HEADERS_CONTROL_FILE" <<EOF
Package: linux-headers-styx
Version: $COMP_META_VERSION
Architecture: $META_ARCH
Maintainer: Styx Firewall <repo@styx-firewall>
Depends: linux-headers-${COMP_KERNEL_VERSION}
Description: Metapackage to install the Styx Linux kernel headers
EOF
  META_HEADERS_DEB="linux-headers-styx_${COMP_META_VERSION}_amd64.deb"
  dpkg-deb --build "$META_HEADERS_DIR" "$REPO_BASE/$META_HEADERS_DEB"
  if [ -f "$REPO_BASE/$META_HEADERS_DEB" ]; then
    echo "[+] Package generated: $META_HEADERS_DEB"
    ls -lh "$REPO_BASE/$META_HEADERS_DEB"
  else
    echo "[!] ERROR: metapackage $META_HEADERS_DEB was not built" >&2
    exit 1
  fi

  # Copy kernel assets into this component's pool
  echo "[+] Copying kernel assets to pool/$COMP/"
  cp -v "$REPO_BASE/$COMP_HEADER_NAME" "$POOL_DIR/"
  cp -v "$REPO_BASE/$COMP_IMAGE_NAME" "$POOL_DIR/"
  cp -v "$REPO_BASE/$COMP_LIBC_NAME" "$POOL_DIR/"

  # Copy metapackages into this component's pool
  echo "[+] Copying metapackages to pool/$COMP/"
  cp -v "$REPO_BASE/$META_IMAGE_DEB" "$POOL_DIR/"
  cp -v "$REPO_BASE/$META_HEADERS_DEB" "$POOL_DIR/"

  # Clean up metapackage build directories for this component
  rm -rf "$META_DIR" "$META_HEADERS_DIR"

  # Move stage packages if they exist
  if [ -d "$STAGE_DIR" ]; then
    shopt -s nullglob
    stage_debs=( "$STAGE_DIR"/*.deb )
    shopt -u nullglob
    if [ ${#stage_debs[@]} -gt 0 ]; then
      echo "[+] Moving ${#stage_debs[@]} package(s) from stage/$COMP/ to pool/$COMP/"
      mv -v -- "${stage_debs[@]}" "$POOL_DIR/"
    else
      echo "[*] No .deb files in stage/$COMP/ (kernel + metapackages only)"
    fi
  else
    echo "[*] stage/$COMP/ does not exist (kernel + metapackages only)"
  fi

  # Generate Packages
  echo "[+] Generating Packages for $COMP"
  dpkg-scanpackages --multiversion "pool/$COMP" > "$DIST_DIR/Packages"
  gzip -k -f "$DIST_DIR/Packages"

  ACTIVE_COMPONENTS+=("$COMP")
done


# Generate combined Release for all active components

echo ""
echo "---- Generating combined Release for: ${ACTIVE_COMPONENTS[*]} ----"

COMPONENT_LIST=$(IFS=,; echo "${ACTIVE_COMPONENTS[*]}")

APT_CONF=$(mktemp /tmp/styx-apt-conf.XXXXXX)
cat > "$APT_CONF" <<EOFCONF
APT::FTPArchive::Release::Origin "STYX Firewall";
APT::FTPArchive::Release::Label "STYX Repository";
APT::FTPArchive::Release::Suite "$REPO_DIST";
APT::FTPArchive::Release::Codename "$REPO_DIST";
APT::FTPArchive::Release::Architectures "amd64";
APT::FTPArchive::Release::Components "$COMPONENT_LIST";
APT::FTPArchive::Release::Description "STYX Firewall packages";
EOFCONF

apt-ftparchive -c "$APT_CONF" release "$REPO_BASE/dists/$REPO_DIST" > "$REPO_BASE/dists/$REPO_DIST/Release"
rm -f "$APT_CONF"

# Sign Release
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

# Cleanup

echo "[+] Cleaning .deb files left in repo root and staging..."
find "$REPO_BASE" -maxdepth 1 -type f -name '*.deb' -exec rm -v {} \;
for COMP in "${COMPONENTS[@]}"; do
  find "$REPO_BASE/stage/$COMP" -maxdepth 1 -type f -name '*.deb' -exec rm -v {} \;
done
echo "[+] Cleaning completed."

# Git operations (interactive)
echo "[+] Updating Git repository (interactive)"
read -p "Do you want to push the changes to git? (y/n): " confirm
if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
  git add -A
  git commit -m "Update repo $REPO_DIST [${COMPONENT_LIST}] $(date +%Y-%m-%d)" || true
  if [ -d "$REPO_BASE/pool" ]; then
    echo "[+] Backing up pool/ to pool2/..."
    rm -rf "$REPO_BASE/pool2"
    cp -a "$REPO_BASE/pool" "$REPO_BASE/pool2"

    echo "[+] Running git filter-repo to clean pool history (optional)"
    if command -v git-filter-repo >/dev/null 2>&1 || command -v git filter-repo >/dev/null 2>&1; then
      git filter-repo --path pool/ --invert-paths --force || echo "[!] git filter-repo failed or not available"
    else
      echo "[!] git-filter-repo not available; skipping history rewrite"
    fi

    echo "[+] Restoring pool2/ to pool/"
    rm -rf "$REPO_BASE/pool"
    mkdir -p "$REPO_BASE/pool"
    cp -a "$REPO_BASE/pool2"/* "$REPO_BASE/pool/"
    rm -rf "$REPO_BASE/pool2"
    if [ -n "$ORIGIN_URL" ] && ! git remote | grep -q '^origin$'; then
      git remote add origin "$ORIGIN_URL"
      echo "[+] Origin remote restored: $ORIGIN_URL"
    fi
  fi
  git add -A
  git commit -m "Update repo $REPO_DIST [${COMPONENT_LIST}] $(date +%Y-%m-%d)" || true
  if git push --force origin main; then
    echo "[+] Changes pushed to git."
  else
    echo "[!] git push failed"
  fi
else
  echo "[!] Git push cancelled by user."
fi

echo -e "\n✔ Repository updated successfully.\n"
echo "   Distribution: $REPO_DIST"
echo "   Components:   ${ACTIVE_COMPONENTS[*]}"
echo "   Kernel dev:   $DEV_KERNEL_VERSION"
echo "   Kernel test:  $TEST_KERNEL_VERSION"
echo "   Kernel prod:  $PROD_KERNEL_VERSION"
echo ""
echo "📦 Instructions for users:"
echo
echo "1. Recommended option (binary, for APT):"
echo "   curl -fsSL https://styx-firewall.github.io/styx-repo/$KEY_FILENAME | sudo tee /usr/share/keyrings/$KEY_FILENAME >/dev/null"
echo "   echo \"deb [arch=amd64 signed-by=/usr/share/keyrings/$KEY_FILENAME] https://styx-firewall.github.io/styx-repo $REPO_DIST styx-dev styx-test styx-prod\" | sudo tee /etc/apt/sources.list.d/styx.list"
echo "   sudo apt update"
echo
echo "2. Alternative option (manual verification):"
echo "   curl -fsSL https://styx-firewall.github.io/styx-repo/$KEY_FILENAME.asc | sudo gpg --dearmor -o /usr/share/keyrings/$KEY_FILENAME"

exit 0
