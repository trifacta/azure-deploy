#!/bin/bash

bin_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$bin_dir/util.sh"

export DEBIAN_FRONTEND="noninteractive"

# LogInfo "Removing stale packages"
# apt -y autoremove

# LogInfo "Updating curl, wget"
# apt-get -y install curl wget

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
cat > /etc/postgresql/9.3/main/pg_hba.conf << EOF
# PostgreSQL Client Authentication Configuration File
# ===================================================
#
# Refer to the "Client Authentication" section in the PostgreSQL
# documentation for a complete description of this file.  A short
# synopsis follows.
#
# This file controls: which hosts are allowed to connect, how clients
# are authenticated, which PostgreSQL user names they can use, which
# databases they can access.  Records take one of these forms:
#
# local      DATABASE  USER  METHOD  [OPTIONS]
# host       DATABASE  USER  ADDRESS  METHOD  [OPTIONS]
# hostssl    DATABASE  USER  ADDRESS  METHOD  [OPTIONS]
# hostnossl  DATABASE  USER  ADDRESS  METHOD  [OPTIONS]
#
# (The uppercase items must be replaced by actual values.)
#
# The first field is the connection type: "local" is a Unix-domain
# socket, "host" is either a plain or SSL-encrypted TCP/IP socket,
# "hostssl" is an SSL-encrypted TCP/IP socket, and "hostnossl" is a
# plain TCP/IP socket.
#
# DATABASE can be "all", "sameuser", "samerole", "replication", a
# database name, or a comma-separated list thereof. The "all"
# keyword does not match "replication". Access to replication
# must be enabled in a separate record (see example below).
#
# USER can be "all", a user name, a group name prefixed with "+", or a
# comma-separated list thereof.  In both the DATABASE and USER fields
# you can also write a file name prefixed with "@" to include names
# from a separate file.
#
# ADDRESS specifies the set of hosts the record matches.  It can be a
# host name, or it is made up of an IP address and a CIDR mask that is
# an integer (between 0 and 32 (IPv4) or 128 (IPv6) inclusive) that
# specifies the number of significant bits in the mask.  A host name
# that starts with a dot (.) matches a suffix of the actual host name.
# Alternatively, you can write an IP address and netmask in separate
# columns to specify the set of hosts.  Instead of a CIDR-address, you
# can write "samehost" to match any of the server's own IP addresses,
# or "samenet" to match any address in any subnet that the server is
# directly connected to.
#
# METHOD can be "trust", "reject", "md5", "password", "gss", "sspi",
# "krb5", "ident", "peer", "pam", "ldap", "radius" or "cert".  Note that
# "password" sends passwords in clear text; "md5" is preferred since
# it sends encrypted passwords.
#
# OPTIONS are a set of options for the authentication in the format
# NAME=VALUE.  The available options depend on the different
# authentication methods -- refer to the "Client Authentication"
# section in the documentation for a list of which options are
# available for which authentication methods.
#
# Database and user names containing spaces, commas, quotes and other
# special characters must be quoted.  Quoting one of the keywords
# "all", "sameuser", "samerole" or "replication" makes the name lose
# its special character, and just match a database or username with
# that name.
#
# This file is read on server startup and when the postmaster receives
# a SIGHUP signal.  If you edit the file on a running system, you have
# to SIGHUP the postmaster for the changes to take effect.  You can
# use "pg_ctl reload" to do that.

# Put your actual configuration here
# ----------------------------------
#
# If you want to allow non-local connections, you need to add more
# "host" records.  In that case you will also need to make PostgreSQL
# listen on a non-local interface via the listen_addresses
# configuration parameter, or via the -i or -h command line switches.




# DO NOT DISABLE!
# If you change this first entry you will need to make sure that the
# database superuser can access the database using some other method.
# Noninteractive access to all databases is required during automatic
# maintenance (custom daily cronjobs, replication, and similar tasks).
#
# Database administrative login by Unix domain socket
local   all             postgres                                peer

# TYPE  DATABASE        USER            ADDRESS                 METHOD
# Entries for trifacta user
local trifacta trifacta md5
host trifacta trifacta 127.0.0.1/32 md5
host trifacta trifacta ::1/128 md5
# Entries for trifactaactiviti user
local trifacta-activiti trifactaactiviti md5
host trifacta-activiti trifactaactiviti 127.0.0.1/32 md5
host trifacta-activiti trifactaactiviti ::1/128 md5
# Entries for scheduling-service & time-based-trigger-service user
local trifactatimebasedtriggerservice trifactatimebasedtriggerservice md5
host trifactatimebasedtriggerservice trifactatimebasedtriggerservice 127.0.0.1/32 md5
host trifactatimebasedtriggerservice trifactatimebasedtriggerservice ::1/128 md5
local trifactaschedulingservice trifactaschedulingservice md5
host trifactaschedulingservice trifactaschedulingservice 127.0.0.1/32 md5
host trifactaschedulingservice trifactaschedulingservice ::1/128 md5

# "local" is for Unix domain socket connections only
local   all             all                                     peer
# IPv4 local connections:
host    all             all             127.0.0.1/32            md5
# IPv6 local connections:
host    all             all             ::1/128                 md5
# Allow replication connections from localhost, by a user with the
# replication privilege.
#local   replication     postgres                                peer
#host    replication     postgres        127.0.0.1/32            md5
#host    replication     postgres        ::1/128                 md5
EOF
service postgresql restart

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
