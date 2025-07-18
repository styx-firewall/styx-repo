#!/bin/bash

# Configuración
GPG_KEY_ID="diegargon@"
KEY_FILENAME="styx-firewall-keyring.gpg"
REPO_BASE="."
DIST_NAME="bookworm"
POOL_DIR="$REPO_BASE/pool/main"
DIST_DIR="$REPO_BASE/dists/$DIST_NAME/main/binary-amd64"

# --- Verificación de clave GPG ---
echo "[+] Verificando clave GPG..."
if ! gpg --list-secret-keys "$GPG_KEY_ID" >/dev/null 2>&1; then
    echo "[!] ERROR: No se encontró la clave GPG '$GPG_KEY_ID'"
    echo "    Claves disponibles:"
    gpg --list-secret-keys --keyid-format LONG
    exit 1
fi

# --- Estructura de directorios ---
mkdir -p "$POOL_DIR"
mkdir -p "$DIST_DIR"

# Mover .deb a pool/main
if ls *.deb 1> /dev/null 2>&1; then
    mv -v *.deb "$POOL_DIR/"
fi

# --- Generación de metadatos ---
echo "[+] Generando Packages..."
dpkg-scanpackages --multiversion "$POOL_DIR" > "$DIST_DIR/Packages"
gzip -k -f "$DIST_DIR/Packages"

# --- Archivo Release ---
echo "[+] Generando Release..."
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

# --- Firma ---
echo "[+] Firmando Release..."
rm -f "$REPO_BASE/dists/$DIST_NAME/Release.gpg" "$REPO_BASE/dists/$DIST_NAME/InRelease"
gpg --yes --batch --default-key "$GPG_KEY_ID" -abs -o "$REPO_BASE/dists/$DIST_NAME/Release.gpg" "$REPO_BASE/dists/$DIST_NAME/Release"
gpg --yes --batch --default-key "$GPG_KEY_ID" --clearsign -o "$REPO_BASE/dists/$DIST_NAME/InRelease" "$REPO_BASE/dists/$DIST_NAME/Release"

# --- Clave Pública ---
FORCE_REGENERATE_KEY=true
if [ "$FORCE_REGENERATE_KEY" = true ] || [ ! -f "$REPO_BASE/$KEY_FILENAME" ]; then
    echo "[+] Exportando clave GPG..."
    # Exporta en formato ASCII (para verificación manual)
    gpg --export --armor "$GPG_KEY_ID" > "$REPO_BASE/$KEY_FILENAME.asc"
    # Exporta en formato binario (dearmored, recomendado para APT)
    gpg --export "$GPG_KEY_ID" | gpg --dearmor > "$REPO_BASE/$KEY_FILENAME"
    # Mostrar fingerprint para verificación
    echo -e "\n🔑 Fingerprint de la clave (verifícalo):"
    gpg --fingerprint "$GPG_KEY_ID" | grep -E "([0-9A-F]{4} ?){10}"
fi

# --- Git ---
echo "[+] Actualizando repositorio Git..."
git add -A
git commit -m "Update repo $(date +%Y-%m-%d)"
git push

# --- Instrucciones ---
echo -e "\n✔ Repositorio actualizado correctamente.\n"
echo "📦 Instrucciones para usuarios:"
echo
echo "1. Opción recomendada (binario, para APT):"
echo "   curl -fsSL https://styx-firewall.github.io/styx-repo/$KEY_FILENAME | sudo tee /usr/share/keyrings/$KEY_FILENAME >/dev/null"
echo "   echo \"deb [arch=amd64 signed-by=/usr/share/keyrings/$KEY_FILENAME] https://styx-firewall.github.io/styx-repo $DIST_NAME main\" | sudo tee /etc/apt/sources.list.d/styx.list"
echo "   sudo apt update"
echo
echo "2. Opción alternativa (verificación manual):"
echo "   curl -fsSL https://styx-firewall.github.io/styx-repo/$KEY_FILENAME.asc | sudo gpg --dearmor -o /usr/share/keyrings/$KEY_FILENAME"
echo "   # Verifica el fingerprint con: gpg --show-keys /usr/share/keyrings/$KEY_FILENAME"