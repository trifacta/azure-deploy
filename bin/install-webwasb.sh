#!/bin/bash

# Adapted from https://github.com/hdinsight/Iaas-Applications/blob/master/Hue/scripts/Hue-install_v0.sh

set -eo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/util.sh"

branch="master"

function Usage() {
  cat << EOF
Usage: "$0 [options]"

Options:
  -B <branch>  Branch from which to pull artifact [default: $branch]
EOF
}

while getopts "v:B:h" opt; do
  case $opt in
    B  ) branch=$OPTARG ;;
    h  ) Usage && exit 0 ;;
    \? ) LogError "Invalid option: -$OPTARG" ;;
    :  ) LogError "Option -$OPTARG requires an argument." ;;
  esac
done

tarfile="webwasb-tomcat.tar.gz"
tarfile_uri="https://raw.githubusercontent.com/Trifacta/azure-deploy/$branch/misc/$tarfile"
tmpdir="/tmp/trifacta-deploy/webwasb"
installdir="/usr/share/webwasb-tomcat"
webwasb_user="webwasb"
webwasb_conf="$installdir/upstart/webwasb.conf"

LogInfo "============================================================"
LogInfo "Trifacta branch  : $branch"
LogInfo "Tarfile URI      : $tarfile_uri"
LogInfo "Install dir      : $installdir"
LogInfo "============================================================"

export JAVA_HOME="/usr/lib/jvm/java-8-openjdk-amd64"

DeleteExistingDirectory "$installdir"
DeleteExistingDirectory "$tmpdir"
LogInfo "Removing WebWasb installation and temporary folder"

LogInfo "Downloading and untarring webwasb tarball"
mkdir -p "$tmpdir"
pushd "$tmpdir" &> /dev/null
wget -q "$tarfile_uri"
tar -xzf "$tarfile" -C "/usr/share/"
popd &> /dev/null
DeleteExistingDirectory "$tmpdir"

set +e
LogInfo "Adding webwasb user"
if [[ ! $(getent passwd webwasb) ]]; then
  useradd -r "$webwasb_user"
fi
set -eo pipefail

LogInfo "Creating WebWasb service"
sed -i "s|JAVAHOMEPLACEHOLDER|$JAVA_HOME|g" "$webwasb_conf"
chown -R "$webwasb_user":"$webwasb_user" $installdir
cp -f "$webwasb_conf" /etc/init/

cat > "/etc/systemd/system/multi-user.target.wants/webwasb.service" <<EOL
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
