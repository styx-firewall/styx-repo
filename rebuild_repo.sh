#!/bin/bash

# Configuration
GPG_KEY_ID="diegargon@"
KEY_FILENAME="styx-firewall-keyring.gpg"
REPO_BASE="."
DIST_NAME="trixie"
POOL_DIR="$REPO_BASE/pool/main"
DIST_DIR="$REPO_BASE/dists/$DIST_NAME/main/binary-amd64"

# --- Common variables for metapackages ---
META_VERSION="1.6"
META_ARCH="amd64"
# --- Create linux-headers-styx metapackage ---
META_HEADERS_DIR="linux-headers-styx"
META_HEADERS_DEBIAN_DIR="$META_HEADERS_DIR/DEBIAN"
META_HEADERS_CONTROL_FILE="$META_HEADERS_DEBIAN_DIR/control"
META_HEADERS_DEPENDS="linux-headers-6.12.48-14-styx"
# --- Create linux-image-styx metapackage ---
META_DIR="linux-image-styx"
META_DEBIAN_DIR="$META_DIR/DEBIAN"
META_CONTROL_FILE="$META_DEBIAN_DIR/control"
## Use common variables META_VERSION and META_ARCH
META_DEPENDS="linux-image-6.12.48-14-styx"

# --- GPG key verification ---
echo "[+] Verifying GPG key..."
if ! gpg --list-secret-keys "$GPG_KEY_ID" >/dev/null 2>&1; then
    echo "[!] ERROR: GPG key '$GPG_KEY_ID' not found"
    echo "    Available keys:"
    gpg --list-secret-keys --keyid-format LONG
    exit 1
fi

# --- Directory structure ---
mkdir -p "$POOL_DIR"
mkdir -p "$DIST_DIR"

# --- Create linux-image-styx metapackage ---
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
# Show generated package
if [ -f "$META_DIR.deb" ]; then
    echo "[+] Package generated: $META_DIR.deb"
    ls -lh "$META_DIR.deb"
    # Only move if the file is not already at the destination
    if [ ! "$META_DIR.deb" -ef "$REPO_BASE/$META_DIR.deb" ]; then
        mv -v "$META_DIR.deb" "$REPO_BASE/"
    fi
fi

# --- Create linux-headers-styx metapackage ---
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
# Show generated package
if [ -f "$META_HEADERS_DIR.deb" ]; then
    echo "[+] Package generated: $META_HEADERS_DIR.deb"
    ls -lh "$META_HEADERS_DIR.deb"
    # Only move if the file is not already at the destination
    if [ ! "$META_HEADERS_DIR.deb" -ef "$REPO_BASE/$META_HEADERS_DIR.deb" ]; then
        mv -v "$META_HEADERS_DIR.deb" "$REPO_BASE/"
    fi
fi

# Move .deb to pool/main
if ls *.deb 1> /dev/null 2>&1; then
    mv -v *.deb "$POOL_DIR/"
fi

# --- Metadata generation ---
echo "[+] Generating Packages..."
dpkg-scanpackages --multiversion "$POOL_DIR" > "$DIST_DIR/Packages"
gzip -k -f "$DIST_DIR/Packages"

# --- Release file ---
echo "[+] Generating Release..."
cat > "$REPO_BASE/dists/$DIST_NAME/Release" <<EOF
Origin: STYX Firewall
Label: STYX Repository
Suite: $DIST_NAME
Codename: $DIST_NAME
Architectures: amd64
Components: main
Description: STYX Firewall packages
Date: $(date -Ru)
EOF

apt-ftparchive release "$REPO_BASE/dists/$DIST_NAME" >> "$REPO_BASE/dists/$DIST_NAME/Release"

# --- Signing ---
echo "[+] Signing Release..."
rm -f "$REPO_BASE/dists/$DIST_NAME/Release.gpg" "$REPO_BASE/dists/$DIST_NAME/InRelease"
gpg --yes --batch --default-key "$GPG_KEY_ID" -abs -o "$REPO_BASE/dists/$DIST_NAME/Release.gpg" "$REPO_BASE/dists/$DIST_NAME/Release"
gpg --yes --batch --default-key "$GPG_KEY_ID" --clearsign -o "$REPO_BASE/dists/$DIST_NAME/InRelease" "$REPO_BASE/dists/$DIST_NAME/Release"

# --- Public Key ---
FORCE_REGENERATE_KEY=false
if [ "$FORCE_REGENERATE_KEY" = true ] || [ ! -f "$REPO_BASE/$KEY_FILENAME" ]; then
    echo "[+] Exporting GPG key..."
    # Export in ASCII format (for manual verification)
    gpg --export --armor "$GPG_KEY_ID" > "$REPO_BASE/$KEY_FILENAME.asc"
    # Export in binary format (dearmored, recommended for APT)
    gpg --export "$GPG_KEY_ID" | gpg --dearmor > "$REPO_BASE/$KEY_FILENAME"
    # Show fingerprint for verification
    echo -e "\n🔑 Key fingerprint (verify it):"
    gpg --fingerprint "$GPG_KEY_ID" | grep -E "([0-9A-F]{4} ?){10}"
fi

# --- Cleaning temporary files and directories ---
echo "[+] Cleaning temporary files and directories..."
# Remove temporary metapackage directories if they exist
rm -rf "$META_DIR" "$META_HEADERS_DIR"
# Remove .deb files left outside pool/main
find "$REPO_BASE" -maxdepth 1 -type f -name '*.deb' -exec rm -v {} \;
echo "[+] Cleaning completed."

# --- Git ---
# Save the origin URL before possible destructive operations
ORIGIN_URL=$(git remote get-url origin 2>/dev/null)

echo "[+] Updating Git repository..."
read -p "Do you want to push the changes to git? (y/n): " confirm
if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
    # We commit changes before filter-repo to avoid rewrite without new changes
    git add -A
    git commit -m "Update repo $(date +%Y-%m-%d)"
    # --- Backup y limpieza de historial pool/main/ ---
    if [ -d "$POOL_DIR" ]; then
        echo "[+] Backing up $POOL_DIR to $REPO_BASE/pool2..."
        rm -rf "$REPO_BASE/pool2"
        cp -a "$POOL_DIR" "$REPO_BASE/pool2"

        echo "[+] Running git filter-repo to clean pool/main history..."
        git filter-repo --path pool/main/ --invert-paths --force
        echo "[+] Restoring pool2 to pool/main..."
        rm -rf "$POOL_DIR"
        cp -a "$REPO_BASE/pool2" "$POOL_DIR"
        ls -al
        rm -rf "$REPO_BASE/pool2"
        # Restaurar el remoto origin si se perdió
        if [ -n "$ORIGIN_URL" ] && ! git remote | grep -q '^origin$'; then
            git remote add origin "$ORIGIN_URL"
            echo "[+] Origin remote restored: $ORIGIN_URL"
        fi
    fi
    # Add again after filter-repo
    git add -A
    git commit -m "Update repo $(date +%Y-%m-%d)"
    git push --force origin main
    echo "[+] Changes pushed to git."
else
    echo "[!] Git push cancelled by user."
fi

# --- Instructions ---
echo -e "\n✔ Repository updated successfully.\n"
echo "📦 Instructions for users:"
echo
echo "1. Recommended option (binary, for APT):"
echo "   curl -fsSL https://styx-firewall.github.io/styx-repo/$KEY_FILENAME | sudo tee /usr/share/keyrings/$KEY_FILENAME >/dev/null"
echo "   echo \"deb [arch=amd64 signed-by=/usr/share/keyrings/$KEY_FILENAME] https://styx-firewall.github.io/styx-repo $DIST_NAME main\" | sudo tee /etc/apt/sources.list.d/styx.list"
echo "   sudo apt update"
echo
echo "2. Alternative option (manual verification):"
echo "   curl -fsSL https://styx-firewall.github.io/styx-repo/$KEY_FILENAME.asc | sudo gpg --dearmor -o /usr/share/keyrings/$KEY_FILENAME"
