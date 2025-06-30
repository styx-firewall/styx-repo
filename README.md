# styx-repo

# Usage
curl -s --compressed  "https://styx-firewall.github.io/styx-repo/KEY.gpg" |  gpg --dearmor | sudo tee /etc/apt/trusted.gpg.d/styx.gpg >/dev/null
curl -s --compressed -o /etc/apt/sources.list.d/styx.list "https://styx-firewall.github.io/styx-repo/styx.list"


# Rebuild

Drop packages and

dpkg-scanpackages --multiversion . > Packages
gzip -k -f Packages
apt-ftparchive release . > Release
gpg --default-key "diegargon@" -abs -o - Release > Release.gpg
gpg --default-key "diegargon@" --clearsign -o - Release > InRelease
git add -A
git commit -m update
git push


# Repo create instructions

https://assafmo.github.io/2019/05/02/ppa-repo-hosted-on-github.html
