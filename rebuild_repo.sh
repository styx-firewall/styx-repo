#!/bin/bash

# Configuración
GPG_KEY_ID="diegargon@"                       # ID o correo de la clave GPG
KEY_FILENAME="styx-firewall-keyring.gpg"       # Nombre del archivo .gpg exportado
REPO_DIR="."                                  # Carpeta base del repo APT (podés ajustarla)

# Paso 1: Generar índice de paquetes
echo "[+] Generando Packages..."
dpkg-scanpackages --multiversion "$REPO_DIR" > "$REPO_DIR/Packages"
gzip -k -f "$REPO_DIR/Packages"

# Paso 2: Crear archivo Release
echo "[+] Generando Release..."
apt-ftparchive release "$REPO_DIR" > "$REPO_DIR/Release"

# Paso 3: Firmar Release (binaria y clear)
echo "[+] Firmando Release..."
gpg --default-key "$GPG_KEY_ID" -abs -o - "$REPO_DIR/Release" > "$REPO_DIR/Release.gpg"
gpg --default-key "$GPG_KEY_ID" --clearsign -o - "$REPO_DIR/Release" > "$REPO_DIR/InRelease"

# Paso 4: Exportar clave pública en binario
echo "[+] Exportando clave GPG en formato binario..."
gpg --export --output "$REPO_DIR/$KEY_FILENAME" "$GPG_KEY_ID"
if [ ! -s "$REPO_DIR/$KEY_FILENAME" ]; then
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
echo "  curl -fsSL https://TU_REPO_URL/$KEY_FILENAME -o /usr/share/keyrings/$KEY_FILENAME"
echo "  echo \"deb [signed-by=/usr/share/keyrings/$KEY_FILENAME] https://TU_REPO_URL/debian stable main\" | sudo tee /etc/apt/sources.list.d/styx.list"
echo "  sudo apt update"
