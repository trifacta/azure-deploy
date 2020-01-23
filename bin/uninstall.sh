#/bin/bash

LogInfo()    { echo -e "$(date +'%Y-%m-%d %H:%M:%S') [INFO] $1" ; }
LogWarning() { echo -e "$(date +'%Y-%m-%d %H:%M:%S') [WARNING] $1" ; }
LogError()   { echo -e "$(date +'%Y-%m-%d %H:%M:%S') [ERROR] $1" >&2 && exit 1; }

function PackageIsInstalled() {
  local package_name="$1"
  installed=$(apt -qq list "$1" 2>&1 | grep installed)
  [[ ! -z "$installed" ]]
}

trifacta_basedir="/opt/trifacta"
trifacta_pkg_name="trifacta"

LogInfo "Stopping trifacta"
service trifacta stop

if $(PackageIsInstalled "$trifacta_pkg_name"); then
  LogInfo "Package \"$trifacta_pkg_name\" installed. Uninstalling."
  apt-get remove --purge -y "$trifacta_pkg_name"
fi

LogInfo "Deleting \"$trifacta_basedir\""
rm -rf "$trifacta_basedir"
