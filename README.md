# styx-repo

# Usage

```
1. Opción recomendada (binario, para APT):
   curl -fsSL https://styx-firewall.github.io/styx-repo/styx-firewall-keyring.gpg | sudo tee /usr/share/keyrings/styx-firewall-keyring.gpg >/dev/null

   echo "deb [arch=amd64 signed-by=/usr/share/keyrings/styx-firewall-keyring.gpg] https://styx-firewall.github.io/styx-repo bookworm main" | sudo tee /etc/apt/sources.list.d/styx.list
   sudo apt update

2. Opción alternativa (verificación manual):
   curl -fsSL https://styx-firewall.github.io/styx-repo/styx-firewall-keyring.gpg.asc | sudo gpg --dearmor -o /usr/share/keyrings/styx-firewall-keyring.gpg
   # Verifica el fingerprint con:
   gpg --show-keys /usr/share/keyrings/styx-firewall-keyring.gpg
```

# Rebuild

rebuild_repo.sh

# Repo create instructions

https://assafmo.github.io/2019/05/02/ppa-repo-hosted-on-github.html
