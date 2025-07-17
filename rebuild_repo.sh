#!/bin/bash

# Configuración
GPG_KEY_ID="diegargon@"                  # ID o correo de la clave GPG
KEY_FILENAME="styx-firewall-keyring.gpg" # Nombre del archivo .gpg exportado
REPO_BASE="."                            # Carpeta base del repo APT
DIST_NAME="bookworm"                     # Nombre de distribución (usar bookworm en lugar de stable)
POOL_DIR="$REPO_BASE/pool/main"          # Directorio para paquetes .deb
DIST_DIR="$REPO_BASE/dists/$DIST_NAME/main/binary-amd64" # Ruta para metadatos

# Crear estructura de directorios necesaria
mkdir -p "$POOL_DIR"
mkdir -p "$DIST_DIR"

# Mover todos los .deb a pool/main (si existen)
if ls *.deb 1> /dev/null 2>&1; then
    mv *.deb "$POOL_DIR/"
fi

# Paso 1: Generar índice de paquetes
echo "[+] Generando Packages..."
dpkg-scanpackages --multiversion "$POOL_DIR" > "$DIST_DIR/Packages"
gzip -k -f "$DIST_DIR/Packages"

# Eliminar archivos de Release anteriores
rm -f "$REPO_BASE/dists/stable/Release.gpg" "$REPO_BASE/dists/stable/InRelease" "$REPO_BASE/dists/stable/Release"

# Paso 2: Crear archivo Release
echo "[+] Generando Release..."
cat > "$REPO_BASE/dists/$DIST_NAME/Release" <<EOF
Origin: STYX Firewall
Label: STYX Repository
Suite: stable
Codename: stable
Architectures: amd64
Components: main
Description: STYX Firewall packages
Date: $(date -Ru)
EOF

apt-ftparchive release "$REPO_BASE/dists/$DIST_NAME" >> "$REPO_BASE/dists/$DIST_NAME/Release"

# Paso 3: Firmar Release
echo "[+] Firmando Release..."
gpg --yes --default-key "$GPG_KEY_ID" -abs -o "$REPO_BASE/dists/$DIST_NAME/Release.gpg" "$REPO_BASE/dists/$DIST_NAME/Release"
gpg --yes --default-key "$GPG_KEY_ID" --clearsign -o "$REPO_BASE/dists/$DIST_NAME/InRelease" "$REPO_BASE/dists/$DIST_NAME/Release"

# Paso 4: Exportar clave pública SOLO si no existe o se fuerza su regeneración
FORCE_REGENERATE_KEY=false  # Cambiar a 'true' si quieres forzar la regeneración

if [ "$FORCE_REGENERATE_KEY" = true ] || [ ! -f "$REPO_BASE/$KEY_FILENAME" ]; then
    echo "[+] Exportando clave GPG en formato binario..."
    gpg --export --output "$REPO_BASE/$KEY_FILENAME" "$GPG_KEY_ID"
    
    if [ ! -s "$REPO_BASE/$KEY_FILENAME" ]; then
        echo "[!] Error: no se pudo exportar la clave '$GPG_KEY_ID'"
        exit 1
    fi
else
    echo "[+] La clave GPG ya existe. No se regenerará (usar FORCE_REGENERATE_KEY=true para forzar)."
fi

# Paso 5: Subir cambios al repo Git
echo "[+] Actualizando repositorio Git..."
git add -A
git commit -m "Update repo and GPG key"
git push

# Paso 6: Mensaje final
echo
echo "✔ Repositorio actualizado correctamente."
echo
echo "📦 Instrucciones para usuarios:"
echo
echo "  curl -fsSL https://styx-firewall.github.io/styx-repo/$KEY_FILENAME | sudo gpg --dearmor -o /usr/share/keyrings/$KEY_FILENAME"
echo "  echo \"deb [arch=amd64 signed-by=/usr/share/keyrings/$KEY_FILENAME] https://styx-firewall.github.io/styx-repo $DIST_NAME main\" | sudo tee /etc/apt/sources.list.d/styx.list"
echo "  sudo apt update"