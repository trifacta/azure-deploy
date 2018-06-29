#!/bin/bash

set -exo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/util.sh"

export DEBIAN_FRONTEND="noninteractive" # suppress apt-get's ncurses

function Usage() {
  cat << EOF
Usage: "$0 [options]"

Options:
  -v <version>   Trifacta version [default: $version]
  -b <build>     Trifacta build number [default: $build]
  -s <sas>       Shared access signature for artifact download
EOF
}

while getopts "v:b:s:h" opt; do
  case $opt in
    v  ) version=$OPTARG ;;
    b  ) build=$OPTARG ;;
    s  ) shared_access_signature=$OPTARG ;;
    h  ) Usage && exit 0 ;;
    \? ) LogError "Invalid option: -$OPTARG" ;;
    :  ) LogError "Option -$OPTARG requires an argument." ;;
  esac
done

if [[ -z ${version+x} ]]; then
  LogError "Version number must be specified (via -v option)"
fi
if [[ -z ${build+x} ]]; then
  LogError "Build number must be specified (via -b option)"
fi
if [[ -z ${shared_access_signature+x} ]]; then
  LogError "Shared access signature must be specified (via -s option)"
fi

trifacta_deb_filename="trifacta-server-${version}-${build}~xenial_amd64.deb"
trifacta_license_filename="license.json"

trifacta_uri_base="https://trifactamarketplace.blob.core.windows.net/artifacts"
trifacta_deb_uri="${trifacta_uri_base}/${trifacta_deb_filename}?${shared_access_signature}"
trifacta_deb_path="${script_dir}/${trifacta_deb_filename}"
trifacta_license_uri="${trifacta_uri_base}/${trifacta_license_filename}?${shared_access_signature}"
trifacta_license_path="/opt/trifacta/license/${trifacta_license_filename}"

function PackageIsInstalled() {
  local package_name="$1"
  installed=$(apt -qq list "$1" 2>&1 | grep installed)
  [[ ! -z "$installed" ]]
}

LogInfo "============================================================"
LogInfo "Trifacta version      : $version"
LogInfo "Trifacta build        : $build"
LogInfo "Trifacta DEB file     : $trifacta_deb_filename"
LogInfo "Trifacta DEB URI      : $trifacta_deb_uri"
LogInfo "Trifacta DEB path     : $trifacta_deb_path"
LogInfo "Trifacta license file : $trifacta_license_filename"
LogInfo "Trifacta license URI  : $trifacta_license_uri"
LogInfo "Trifacta license path : $trifacta_license_path"
LogInfo "============================================================"

# Remove the package if it's already installed
trifacta_pkg_name="trifacta"
if $(PackageIsInstalled "$trifacta_pkg_name"); then
  LogWarning "Package \"$trifacta_pkg_name\" already installed. Uninstalling."
  apt-get remove --purge -y "$trifacta_pkg_name"
  rm -rf "/opt/trifacta"
fi

LogInfo "Downloading \"$trifacta_deb_filename\""
wget -q "$trifacta_deb_uri" -O "$trifacta_deb_path"

# Verify existence of the .deb file
if [[ ! -f "$trifacta_deb_path" ]]; then
  LogError "Missing file \"$trifacta_deb_path\". Exiting."
fi

LogInfo "Installing some known dependencies"
apt-get update
apt-get install -y openjdk-8-jre-headless postgresql-9.3 python-psycopg2

# Install dependencies wth strict version requirements
strict_dependencies=$(dpkg -I "$trifacta_deb_path" | grep -oP ' Depends: \K.*' | tr -d " ()" | tr , '\n' | grep -v ">" | grep = | tr '\n' ' ')
LogInfo "Installing strict dependencies ($strict_dependencies)"
apt-get install -y $strict_dependencies
apt-mark hold $strict_dependencies

LogInfo "Installing \"$trifacta_deb_path\""
apt-get install -y "$trifacta_deb_path"

LogInfo "Downloading \"$trifacta_license_filename\""
wget -q "$trifacta_license_uri" -O "$trifacta_license_path"
