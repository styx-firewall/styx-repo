# styx-repo

# Usage

```
curl -fsSL https://styx-firewall.github.io/styx-repo/styx-firewall-keyring.gpg | sudo gpg --dearmor -o /usr/share/keyrings/styx-firewall-keyring.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/styx-firewall-keyring.gpg] https://styx-firewall.github.io/styx-repo bookworm main" | sudo tee /etc/apt/sources.list.d/styx.list```

# Rebuild

rebuild_repo.sh

# Repo create instructions

https://assafmo.github.io/2019/05/02/ppa-repo-hosted-on-github.html
