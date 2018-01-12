#!/bin/bash

set -exo pipefail

LogInfo()    { echo -e "$(date +'%Y-%m-%d %H:%M:%S') [INFO] $1" ; }
LogWarning() { echo -e "$(date +'%Y-%m-%d %H:%M:%S') [WARNING] $1" ; }
LogError()   { echo -e "$(date +'%Y-%m-%d %H:%M:%S') [ERROR] $1" >&2 && exit 1; }

function BackupFile() {
  local filename="$1"
  local filename_bak="$1.bak.$(date +'%Y%m%d%H%M%S')"
  LogInfo "Backing up \"$filename\" to \"$filename_bak\""
  cp -p "$filename" "$filename_bak"
}

function DeleteExistingDirectory() {
  if [[ -d "$1" ]]; then
    LogWarning "Deleting the existing directory \"$1\""
    rm -rf "$1"
  fi
}

function RandomString() {
  local half_length="$1"
  local random=$(openssl rand -hex $half_length)
  echo -n $random
}

function Round() {
  echo "($1 + 0.5) / 1" | bc
}

function GetCoreCount() {
  cat /proc/cpuinfo | grep 'core id' | sort | uniq | wc -l
}

function GetTotalMemoryKB() {
  awk '/MemTotal/{print $2}' /proc/meminfo
}

function GetTotalMemoryMB() {
  echo "$(GetTotalMemoryKB)/1024" | bc
}

function GetTotalMemoryGB() {
  echo "$(GetTotalMemoryKB)/1024/1024" | bc
}
