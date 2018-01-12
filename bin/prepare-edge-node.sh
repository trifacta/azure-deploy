#!/bin/bash

set -exo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/util.sh"

export DEBIAN_FRONTEND="noninteractive" # suppress apt-get's ncurses

LogInfo "Updating curl and wget"
apt-get -y install curl wget

LogInfo "Setting up Trifacta dependency repository"
curl -s "https://packagecloud.io/install/repositories/trifacta/dependencies/script.deb.sh" | bash

LogInfo "Setting up Postgres repository"
echo "deb http://apt.postgresql.org/pub/repos/apt/ xenial-pgdg main" > /etc/apt/sources.list.d/pgdg.list
wget -q -O - "https://www.postgresql.org/media/keys/ACCC4CF8.asc" | apt-key add -

LogInfo "Installing deployment dependencies"
apt-get install -y bc libxml2-utils jq moreutils

LogInfo "Fixing Python package permissions"
python_dir="/usr/local/lib/python2.7"
directories=$(find "$python_dir/dist-packages/" -maxdepth 2 -type d)
for d in $directories; do
  chmod 775 "${d}"
  chmod ugo+r "${d}"/*
done
chmod -R 755 $python_dir/dist-packages/pkg_resources*
chmod -R 755 $python_dir/dist-packages/watchdog*
chmod -R 755 $python_dir/dist-packages/tzlocal*
chmod -R 755 $python_dir/dist-packages/six*
chmod -R 755 $python_dir/dist-packages/setuptools*
chmod -R 755 $python_dir/dist-packages/retrying*
chmod -R 755 $python_dir/dist-packages/requests*
chmod -R 755 $python_dir/dist-packages/PyYAML*

set +e
LogInfo "Removing conflicting nginx package"
apt-get purge -y hdinsight-nginx nginx nginx-common nginx-core
