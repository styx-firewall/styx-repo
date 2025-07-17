#!/bin/bash

# Configuración
GPG_KEY_ID="diegargon@"                       # ID o correo de la clave GPG
KEY_FILENAME="styx-firewall-keyring.gpg"       # Nombre del archivo .gpg exportado
REPO_BASE="."                                  # Carpeta base del repo APT
DIST_DIR="$REPO_BASE/dists/stable/main/binary-amd64"  # Ruta donde se generan los paquetes

# Crear carpeta destino si no existe
mkdir -p "$DIST_DIR"

# Paso 1: Generar índice de paquetes en la carpeta correcta
echo "[+] Generando Packages..."
dpkg-scanpackages --multiversion "$REPO_BASE" > "$DIST_DIR/Packages"
gzip -k -f "$DIST_DIR/Packages"

# Paso 2: Crear archivo Release en dists/stable
echo "[+] Generando Release..."
apt-ftparchive release "$REPO_BASE/dists/stable" > "$REPO_BASE/dists/stable/Release"

# Paso 3: Firmar Release (binaria y clear)
echo "[+] Firmando Release..."
gpg --default-key "$GPG_KEY_ID" -abs -o "$REPO_BASE/dists/stable/Release.gpg" "$REPO_BASE/dists/stable/Release"
gpg --default-key "$GPG_KEY_ID" --clearsign -o "$REPO_BASE/dists/stable/InRelease" "$REPO_BASE/dists/stable/Release"

# Paso 4: Exportar clave pública en binario (en raíz para distribución)
echo "[+] Exportando clave GPG en formato binario..."
gpg --export --output "$REPO_BASE/$KEY_FILENAME" "$GPG_KEY_ID"
if [ ! -s "$REPO_BASE/$KEY_FILENAME" ]; then
    echo "[!] Error: no se pudo exportar la clave '$GPG_KEY_ID'"
    exit 1
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
echo "  curl -fsSL https://styx-firewall.github.io/styx-repo/$KEY_FILENAME -o /usr/share/keyrings/$KEY_FILENAME"
echo "  echo \"deb [signed-by=/usr/share/keyrings/$KEY_FILENAME] https://styx-firewall.github.io/styx-repo stable main\" | sudo tee /etc/apt/sources.list.d/styx.list"
echo "  sudo apt update"
