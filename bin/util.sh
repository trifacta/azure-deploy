#!/bin/bash

NONE='\033[00m'
RED='\033[01;31m'
GREEN='\033[01;32m'
YELLOW='\033[01;33m'
WHITE='\033[01;37m'
BOLD='\033[1m'

function LogInfo()    { echo -e "${BOLD}${WHITE}[INFO] $1${NONE}" ; }
function LogWarning() { echo -e "${BOLD}${YELLOW}[WARNING] $1${NONE}" ; }
function LogError()   { echo -e "${BOLD}${RED}[ERROR] $1${NONE}" && exit 1; }

function ScriptDirectory() {
  echo $(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
}

function BackupFile() {
  /bin/cp -p "$1" "$1.bak.$(date +'%Y%m%d%H%M%S')"
}

function RandomString() {
  local half_length="$1"
  local random=$(openssl rand -hex $half_length)
  echo -n $random
}

function FullBuildNumber() {
  cat "$(ScriptDirectory)/../build_number.txt"
}

function BuildNumber() {
  cat "$(ScriptDirectory)/../build_number.txt" | cut -d. -f1-3
}

function HDPVersion() {
  echo $(basename `ls -d /usr/hdp/* | grep -P '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+-[0-9]+'`)
}
