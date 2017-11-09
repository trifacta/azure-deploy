#!/bin/bash

bin_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$bin_dir/util.sh"

export DEBIAN_FRONTEND="noninteractive"

LogInfo "Setting up Trifacta dependency repository"
curl -s "https://packagecloud.io/install/repositories/trifacta/dependencies/script.deb.sh" | bash

LogInfo "Setting up Postgres repository"
echo "deb http://apt.postgresql.org/pub/repos/apt/ xenial-pgdg main" > /etc/apt/sources.list.d/pgdg.list
wget --quiet -O - "https://www.postgresql.org/media/keys/ACCC4CF8.asc" | apt-key add -

LogInfo "Updating packages"
apt-get update

LogInfo "Installing OpenJDK"
apt-get install -y openjdk-8-jre-headless

LogInfo "Installing Supervisor"
apt-get install -y supervisor=3.2.0-2

LogInfo "Installing Postgres"
apt-get install -y postgresql-9.3 python-psycopg2

LogInfo "Removing nginx"
apt-get -y purge hdinsight-nginx nginx nginx-common nginx-core

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
