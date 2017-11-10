#!/bin/bash

# suppress apt-get's ncurses
export DEBIAN_FRONTEND="noninteractive"
export JAVA_HOME="/usr/lib/jvm/java-8-openjdk-amd64"

function LogInfo()    { echo -e "$(date +'%Y-%m-%d %H:%M:%S') [INFO] $1" ; }
function LogWarning() { echo -e "$(date +'%Y-%m-%d %H:%M:%S') [WARNING] $1" ; }
function LogError()   { echo -e "$(date +'%Y-%m-%d %H:%M:%S') [ERROR] $1" && exit 1; }

function InstallWebWasb() {
  # Adapted from https://raw.githubusercontent.com/hdinsight/Iaas-Applications/master/Hue/scripts/Hue-install_v0.sh
  local tarfile="webwasb-tomcat.tar.gz"
  local tarfile_uri="https://hdiconfigactions.blob.core.windows.net/linuxhueconfigactionv01/$tarfile"
  local tmpdir="/tmp/webwasb"
  local installdir="/usr/share/webwasb-tomcat"

  LogInfo "Removing WebWasb installation and temporary folder"
  rm -rf $installdir $tmpdir

  LogInfo "Downloading and untarring webwasb tarball"
  mkdir $tmpdir
  wget $tarfile_uri -P $tmpdir
  pushd $tmpdir &> /dev/null
  tar -xzf $tarfile -C /usr/share/
  popd &> /dev/null
  rm -rf $tmpdir

  LogInfo "Adding webwasb user"
  useradd -r webwasb

  LogInfo "Creating WebWasb service"
  sed -i "s|JAVAHOMEPLACEHOLDER|$JAVA_HOME|g" $installdir/upstart/webwasb.conf
  chown -R webwasb:webwasb $installdir
  cp -f $installdir/upstart/webwasb.conf /etc/init/
  cat >/etc/systemd/system/multi-user.target.wants/webwasb.service <<EOL
[[Unit]
Description=webwasb service

[Service]
Type=simple
User=webwasb
Group=webwasb
Restart=always
RestartSec=5
Environment="JAVA_HOME=$JAVA_HOME"
Environment="CATALINA_HOME=/usr/share/webwasb-tomcat"
ExecStart=/usr/share/webwasb-tomcat/bin/catalina.sh run
ExecStopPost=rm -rf $CATALINA_HOME/temp/*

[Install]
WantedBy=multi-user.target
EOL

  LogInfo "Starting WebWasb service"
  systemctl daemon-reload
  systemctl stop webwasb.service
  systemctl start webwasb.service
}

LogInfo "Updating curl and wget"
apt-get -y install curl wget

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

InstallWebWasb
