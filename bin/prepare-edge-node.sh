#!/bin/bash

set -exo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/util.sh"

export DEBIAN_FRONTEND="noninteractive" # suppress apt-get's ncurses

LogInfo "Updating curl and wget"
apt-get -y install curl wget

LogInfo "Setting up Trifacta dependency repository"
curl -s "https://packagecloud.io/install/repositories/trifacta/dependencies/script.deb.sh" | bash

LogInfo "Setting up PostgreSQL repository"
echo "deb http://apt.postgresql.org/pub/repos/apt/ xenial-pgdg main" > /etc/apt/sources.list.d/pgdg.list
wget -q -O - "https://www.postgresql.org/media/keys/ACCC4CF8.asc" | apt-key add -

LogInfo "Start PostgreSQL upon VM boot"
systemctl enable postgresql

LogInfo "Installing deployment dependencies"
apt-get install -y bc libxml2-utils jq moreutils

# Installs a world-readable pkg_resources to /usr/lib/python2.7/dist-packages/.
# Something else, likely a manual pip install, installs a root:staff readable
# pkg_resources to /usr/local/lib/python2.7/dist-packages/.
LogInfo "Re-installing python-pkg-resources"
apt-get install --reinstall python-pkg-resources

LogInfo "Installing Python dependencies"
apt-get install -y python-kerberos python-requests

set +e
LogInfo "Removing conflicting nginx package"
apt-get purge -y hdinsight-nginx nginx nginx-common nginx-core || true
