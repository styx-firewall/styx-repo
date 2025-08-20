#!/bin/bash

# Configuración
GPG_KEY_ID="diegargon@"
KEY_FILENAME="styx-firewall-keyring.gpg"
REPO_BASE="."
DIST_NAME="trixie"
POOL_DIR="$REPO_BASE/pool/main"
DIST_DIR="$REPO_BASE/dists/$DIST_NAME/main/binary-amd64"


# --- Variables comunes para metapaquetes ---
META_VERSION="1.6"
META_ARCH="amd64"
# --- Creación de metapaquete linux-headers-styx ---
META_HEADERS_DIR="linux-headers-styx"
META_HEADERS_DEBIAN_DIR="$META_HEADERS_DIR/DEBIAN"
META_HEADERS_CONTROL_FILE="$META_HEADERS_DEBIAN_DIR/control"

META_HEADERS_DEPENDS="linux-headers-6.12.42-12-styx"

# --- Creación de metapaquete linux-image-styx ---
META_DIR="linux-image-styx"
META_DEBIAN_DIR="$META_DIR/DEBIAN"
META_CONTROL_FILE="$META_DEBIAN_DIR/control"
## Usar las variables comunes META_VERSION y META_ARCH
META_DEPENDS="linux-image-6.12.42-12-styx"

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

# --- Creación de metapaquete linux-image-styx ---
rm -rf "$META_DIR"
mkdir -p "$META_DEBIAN_DIR"
cat > "$META_CONTROL_FILE" <<EOF
Package: linux-image-styx
Version: $META_VERSION
Architecture: $META_ARCH
Maintainer: Styx Firewall <repo@styx-firewall>
Depends: $META_DEPENDS
Description: Metapaquete para instalar el kernel Linux Styx
EOF
dpkg-deb --build "$META_DIR"
# Mostrar el paquete generado
if [ -f "$META_DIR.deb" ]; then
    echo "[+] Paquete generado: $META_DIR.deb"
    ls -lh "$META_DIR.deb"
    # Solo mover si el archivo no está ya en el destino
    if [ ! "$META_DIR.deb" -ef "$REPO_BASE/$META_DIR.deb" ]; then
        mv -v "$META_DIR.deb" "$REPO_BASE/"
    fi
fi

# --- Creación de metapaquete linux-headers-styx ---
rm -rf "$META_HEADERS_DIR"
mkdir -p "$META_HEADERS_DEBIAN_DIR"
cat > "$META_HEADERS_CONTROL_FILE" <<EOF
Package: linux-headers-styx
Version: $META_VERSION
Architecture: $META_ARCH
Maintainer: Styx Firewall <repo@styx-firewall>
Depends: $META_HEADERS_DEPENDS
Description: Metapaquete para instalar los headers del kernel Linux Styx
EOF
dpkg-deb --build "$META_HEADERS_DIR"
# Mostrar el paquete generado
if [ -f "$META_HEADERS_DIR.deb" ]; then
    echo "[+] Paquete generado: $META_HEADERS_DIR.deb"
    ls -lh "$META_HEADERS_DIR.deb"
    # Solo mover si el archivo no está ya en el destino
    if [ ! "$META_HEADERS_DIR.deb" -ef "$REPO_BASE/$META_HEADERS_DIR.deb" ]; then
        mv -v "$META_HEADERS_DIR.deb" "$REPO_BASE/"
    fi
fi

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
FORCE_REGENERATE_KEY=false
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

# --- Limpieza de temporales ---
echo "[+] Limpiando archivos y directorios temporales..."
# Elimina directorios temporales de metapaquetes si existen
rm -rf "$META_DIR" "$META_HEADERS_DIR"
# Elimina archivos .deb que hayan quedado fuera del pool/main
find "$REPO_BASE" -maxdepth 1 -type f -name '*.deb' -exec rm -v {} \;
echo "[+] Limpieza completada."

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
