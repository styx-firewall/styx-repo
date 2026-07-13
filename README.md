# styx-repo


# Usage

```
1. Recommended option (binary, for APT):
   curl -fsSL https://styx-firewall.github.io/styx-repo/styx-firewall-keyring.gpg | sudo tee /usr/share/keyrings/styx-firewall-keyring.gpg >/dev/null

   echo "deb [arch=amd64 signed-by=/usr/share/keyrings/styx-firewall-keyring.gpg] https://styx-firewall.github.io/styx-repo trixie styx-test" | sudo tee /etc/apt/sources.list.d/styx.list
   sudo apt update

2. Alternative option (manual verification):
   curl -fsSL https://styx-firewall.github.io/styx-repo/styx-firewall-keyring.gpg.asc | sudo gpg --dearmor -o /usr/share/keyrings/styx-firewall-keyring.gpg
   # Verify the fingerprint with:
   gpg --show-keys /usr/share/keyrings/styx-firewall-keyring.gpg
```

# Rebuild

rebuild_repo.sh
