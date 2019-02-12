#!/bin/bash

set -exo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/util.sh"

directory_id=""
application_id=""
secret=""
wasb_sas_token=""
key_vault_url=""

# TODO: Figure out what's going on with spark-job-service.classpath

function Usage() {
  cat << EOF
Usage: "$0 [options]"

Options:
  -d <dir ID>    Azure Active Directory directory ID for the registered application. Required when storage is ADLS. [default: $directory_id]
  -a <app ID>    Registered application\'s ID. Required when storage is ADLS. [default: $application_id]
  -S <secret>    Registered application\'s key for access to ADLS. Required when storage is ADLS. [default: $secret]
  -t <sas token> Shared Access Signature token. Required when storage is WASB.
  -K <key vault URL> Azure Key Vault URL. Required when storage is ADLS.
  -h             This message.
EOF
}

while getopts "u:d:a:S:t:K:h" opt; do
  case $opt in
    d  ) directory_id=$OPTARG ;;
    a  ) application_id=$OPTARG ;;
    S  ) secret=$OPTARG ;;
    t  ) wasb_sas_token=$OPTARG ;;
    K  ) key_vault_url=$OPTARG ;;
    h  ) Usage && exit 0 ;;
    \? ) LogError "Invalid option: -$OPTARG" ;;
    :  ) LogError "Option -$OPTARG requires an argument." ;;
  esac
done

trifacta_basedir="/opt/trifacta"
triconf="$trifacta_basedir/conf/trifacta-conf.json"
create_db_roles_script="$trifacta_basedir/bin/setup-utils/db/trifacta-create-postgres-roles-dbs.sh"

trifacta_user="trifacta"

hadoop_conf_dir="/usr/hdp/current/hadoop-client/conf"
core_site="$hadoop_conf_dir/core-site.xml"
hdfs_site="$hadoop_conf_dir/hdfs-site.xml"
yarn_site="$hadoop_conf_dir/yarn-site.xml"

function FullHDPVersion() {
  echo $(basename `ls -d /usr/hdp/* | grep -P '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+-[0-9]+'`)
}

function ShortHDPVersion() {
  local full_version=$(FullHDPVersion)
  echo "$full_version" | cut -d. -f-2
}

function CreateCustomerKey() {
  local keyfile="$trifacta_basedir/conf/.key/customerKey"
  if [[ -f "$keyfile" ]]; then
    LogWarning "Found existing key file (\"$keyfile\"). Leaving as is."
  else
    LogInfo "Creating customer key file \"$keyfile\""
    echo "$(RandomString 16)" > "$keyfile"
    chmod 600 "$keyfile"
  fi
}

function CreateHdfsDirectories() {
  # Note, these do not need to be prefixed by the ADLS mount point if ADLS is in use
  local directories="
    /user/trifacta
    /trifacta
    /trifacta/dictionaries
    /trifacta/libraries
    /trifacta/queryResults
    /trifacta/tempfiles
    /trifacta/uploads"
  for directory in $directories; do
    hdfs dfs -mkdir -p "$directory"
  done
}

function CopyHadoopConfigFiles() {
  LogInfo "Copying Hadoop configuration files"
  cp -rp --remove-destination "/usr/hdp/current/hadoop-client/conf/"* "/opt/trifacta/conf/hadoop-site/"
  cp -rp --remove-destination "/etc/hive/conf/"* "/opt/trifacta/conf/hadoop-site/"
  ln -sf "/etc/hive/conf/hive-site.xml" "/etc/hadoop/conf/hive-site.xml"
}

function CheckValueSetOrExit() {
  local name="$1"
  local value="$2"
  if [[ -z "$value" ]]; then
    LogError "Error: \"$name\" is empty. Exiting."
  else
    LogInfo "$name : $value"
  fi
}

function ConfigurePostgres() {
  local pg_version="9.6"
  local pg_dir="/etc/postgresql/$pg_version/main/"
  local pg_conf="$pg_dir/postgresql.conf"

  local pg_port=$(grep -Po "^port[ \t]*=[ \t]*\K[0-9]+" "$pg_conf")

  LogInfo "Configuring PostgreSQL"
  CheckValueSetOrExit "PostgreSQL version" "pg_version"
  CheckValueSetOrExit "PostgreSQL conf" "$pg_conf"
  CheckValueSetOrExit "PostgreSQL port" "$pg_port"

  sed -i "s@5432@$pg_port@g" "$triconf"
}

function CreateDBRoles() {
  # Must be run after ConfigurePostgres
  LogInfo "Creating DB roles"
  bash "$create_db_roles_script"
}

function GetHostFromString() {
  echo "$1" | cut -d: -f1
}

function GetPortFromString() {
  echo "$1" | cut -d: -f2
}

function GetHadoopProperty() {
  local property="$1"
  local config_file="$2"
  echo $(xmllint --xpath "/configuration/property[name=\"$property\"]/value/text()" "$config_file")
}

function GetDefaultFS() {
  echo $(GetHadoopProperty "fs.defaultFS" "$core_site")
}

function GetDefaultFSType() {
  GetDefaultFS | cut -d: -f1
}

function ConfigureSecureTokenService() {
  # Secure Token Service: Refresh Token Encryption Key
  local refresh_token_encryption_key=$(RandomString 16 | base64)

  jq ".[\"secure-token-service\"].systemProperties[\"server.port\"] = \"8090\" |
    .[\"secure-token-service\"].systemProperties[\"com.trifacta.services.secure_token_service.refresh_token_encryption_key\"] = \"$refresh_token_encryption_key\"" \
    "$triconf" | sponge "$triconf"
}

function ConfigureUdfService() {
  LogInfo "Configuring UDF service"

  # The edge node on HDI clusters doesn't handle websocket compression correctly
  # Turning it off sustains websocket connections and udfs work with this change
  local jvm_options="-Dorg.apache.tomcat.websocket.DISABLE_BUILTIN_EXTENSIONS=true"
  jq ".[\"udf-service\"].jvmOptions = [\"$jvm_options\"]" "$triconf" | sponge "$triconf"
}

function ConfigureAzureCommon() {
  CheckValueSetOrExit "Directory ID" "$directory_id"
  CheckValueSetOrExit "Application ID" "$application_id"
  CheckValueSetOrExit "Secret" "$secret"

  jq ".azure.directoryid = \"$directory_id\" |
    .azure.applicationid = \"$application_id\" |
    .azure.secret = \"$secret\" |
    .azure.keyVaultUrl = \"$key_vault_url\"" \
    "$triconf" | sponge "$triconf"
}

function ConfigureADLS() {
  local adls_host=$(GetHadoopProperty "dfs.adls.home.hostname" "$core_site")
  local adls_uri="adl://${adls_host}"
  local adls_prefix=$(GetHadoopProperty "dfs.adls.home.mountpoint" "$core_site")

  LogInfo "Configuring ADLS"
  CheckValueSetOrExit "ADLS URI" "$adls_uri"
  CheckValueSetOrExit "ADLS Prefix" "$adls_prefix"

  jq ".webapp.storageProtocol = \"hdfs\" |
    .hdfs.username = \"$trifacta_user\" |
    .hdfs.enabled = true |
    .hdfs.protocolOverride = \"adl\" |
    .hdfs.namenode.host = \"$adls_host\" |
    .hdfs.namenode.port = 443 |
    .hdfs.webhdfs.httpfs = false |
    .hdfs.webhdfs.ssl.enabled = true |
    .hdfs.webhdfs.host = \"$adls_host\" |
    .hdfs.webhdfs.version = \"/webhdfs/v1\" |
    .hdfs.webhdfs.credentials.username = \"$trifacta_user\" |
    .hdfs.webhdfs.port = 443 |
    .hdfs.pathsConfig.fileUpload = \"${adls_prefix}/trifacta/uploads\" |
    .hdfs.pathsConfig.dictionaries = \"${adls_prefix}/trifacta/dictionaries\" |
    .hdfs.pathsConfig.libraries = \"${adls_prefix}/trifacta/libraries\" |
    .hdfs.pathsConfig.tempFiles = \"${adls_prefix}/trifacta/tempfiles\" |
    .hdfs.pathsConfig.sparkEventLogs = \"${adls_prefix}/trifacta/sparkeventlogs\" |
    .hdfs.pathsConfig.batchResults = \"${adls_prefix}/trifacta/queryResults\" |
    .azure.adl.mode = \"system\" |
    .azure.adl.enabled = true |
    .azure.adl.store = \"$adls_uri\"" \
    "$triconf" | sponge "$triconf"
}

function ConfigureWASB() {
  local wasb_service_name=$(GetDefaultFS)
  local wasb_container=$(echo "$wasb_service_name" | cut -d@ -f1 | cut -d/ -f3)
  local wasb_host=$(echo "$wasb_service_name" | cut -d@ -f2)

  LogInfo "Configuring WASB"
  CheckValueSetOrExit "WASB service name" "$wasb_service_name"
  CheckValueSetOrExit "WASB Host" "$wasb_host"
  CheckValueSetOrExit "WASB Shared Access Signature token" "$wasb_sas_token"

  jq ".webapp.storageProtocol = \"wasbs\" |
    .hdfs.enabled = false |
    .azure.wasb.enabled = true |
    .azure.wasb.fetchSasTokensFromKeyVault = false |
    .azure.wasb.defaultStore.blobHost = \"$wasb_host\" |
    .azure.wasb.defaultStore.container = \"$wasb_container\" |
    .azure.wasb.defaultStore.sasToken = \"$wasb_sas_token\"" \
    "$triconf" | sponge "$triconf"

  # Not really sure this is required but it's probably safest to ensure wasbs
  sed -i 's@wasb://@wasbs://@g' "/opt/trifacta/conf/hadoop-site/core-site.xml"
}

function ConfigureHDP() {
  local hdp_full_version=$(FullHDPVersion)
  local hdp_short_version=$(ShortHDPVersion)

  LogInfo "Configuring HDP"
  CheckValueSetOrExit "HDP full version" "$hdp_full_version"
  CheckValueSetOrExit "HDP short version" "$hdp_short_version"

  jq ".hadoopBundleJar = \"hadoop-deps/hdp-${hdp_short_version}/build/libs/hdp-${hdp_short_version}-bundle.jar\" |
    .[\"batch-job-runner\"].classpath = \"%(topOfTree)s/services/batch-job-runner/build/install/batch-job-runner/batch-job-runner.jar:%(topOfTree)s/services/batch-job-runner/build/install/batch-job-runner/lib/*:/etc/hadoop/conf:%(topOfTree)s/conf/hadoop-site:/usr/lib/hdinsight-datalake/*:/usr/hdp/current/hadoop-client/client/*:/usr/hdp/current/hadoop-client/*:/usr/hdp/current/hadoop-client/lib/*:%(topOfTree)s/%(hadoopBundleJar)s\" |
    .[\"batch-job-runner\"].env.LD_LIBRARY_PATH = \"%(topOfTree)s/libs/java/joblaunch/fileconverter/tableausdk-linux64/lib64/tableausdk/:/usr/hdp/current/hadoop-client/lib/native:/usr/hdp/current/hadoop-client/lib/native/Linux-amd64-64\" |
    .[\"batch-job-runner\"].systemProperties[\"java.library.path\"] = \"/usr/hdp/current/hadoop-client/lib/native:/usr/hdp/current/hadoop-client/lib/native/Linux-amd64-64\" |
    .[\"spark-job-service\"].jvmOptions = [\"-Xmx512m\", \"-Dhdp.version=${hdp_full_version}\"] |
    .[\"spark-job-service\"].classpath = \"%(topOfTree)s/services/spark-job-server/server/build/libs/spark-job-server-bundle.jar:%(topOfTree)s/%(sparkBundleJar)s:/etc/hadoop/conf:%(topOfTree)s/conf/hadoop-site:/usr/lib/hdinsight-datalake/*:%(topOfTree)s/services/spark-job-server/build/bundle/*:/usr/hdp/current/hadoop-client/client/*:/usr/hdp/current/hadoop-client/*:%(topOfTree)s/%(hadoopBundleJar)s\" |
    .spark.hadoopUser = \"$trifacta_user\" |
    .spark.props[\"spark.driver.extraJavaOptions\"] = \"-XX:MaxPermSize=1024m -XX:PermSize=256m -Dhdp.version=${hdp_full_version}\" |
    .spark.props[\"spark.driver.extraLibraryPath\"] = \"/usr/hdp/current/hadoop-client/lib/native:/usr/hdp/current/hadoop-client/lib/native/Linux-amd64-64\" |
    .spark.props[\"spark.executor.extraLibraryPath\"] = \"/usr/hdp/current/hadoop-client/lib/native:/usr/hdp/current/hadoop-client/lib/native/Linux-amd64-64\" |
    .spark.props[\"spark.yarn.am.extraJavaOptions\"] = \"-Dhdp.version=${hdp_full_version}\" |
    .[\"batch-job-runner\"].autoRestart = true |
    .[\"data-service\"].autoRestart = true |
    .[\"ml-service\"].autoRestart = true |
    .[\"proxy\"].autoRestart = true |
    .[\"scheduling-service\"].autoRestart = true |
    .[\"spark-job-service\"].autoRestart = true |
    .[\"time-based-trigger-service\"].autoRestart = true |
    .[\"udf-service\"].autoRestart = true |
    .[\"vfs-service\"].autoRestart = true  |
    .webapp.autoRestart = true |
    .env.PATH = \"\${HOME}/bin:$PATH:/usr/local/bin:/usr/lib/zookeeper/bin\" |
    .env.TRIFACTA_CONF = \"/opt/trifacta/conf\" |
    .env.JAVA_HOME = \"/usr/lib/jvm/java-1.8.0-openjdk-amd64\"" \
    "$triconf" | sponge "$triconf"
}

function ConfigureHAResourceManager() {
  local enabled=$(GetHadoopProperty "yarn.resourcemanager.ha.enabled" "$yarn_site")
  if [[ "$enabled" != "true" ]]; then
    return
  fi

  # Get the namenode names (assumes single nameservice)
  local ha_rm_ids=$(GetHadoopProperty "yarn.resourcemanager.ha.rm-ids" "$yarn_site")
  local rm1_name=$(echo "$ha_rm_ids" | cut -d, -f1)
  local rm2_name=$(echo "$ha_rm_ids" | cut -d, -f2)

  local ha_rm_ids=$(GetHadoopProperty "yarn.resourcemanager.ha.rm-ids" "$yarn_site")

  rm_active=$(GetHadoopProperty "yarn.resourcemanager.hostname" "$yarn_site")
  rm_active_host=$(GetHostFromString $rm_active)
  rm1=$(GetHadoopProperty "yarn.resourcemanager.address.$rm1_name" "$yarn_site")
  rm2=$(GetHadoopProperty "yarn.resourcemanager.address.$rm2_name" "$yarn_site")
  rm1_host=$(GetHostFromString $rm1)
  rm2_host=$(GetHostFromString $rm2)
  rm1_port=$(GetPortFromString $rm1)
  rm2_port=$(GetPortFromString $rm2)

  rm1_admin=$(GetHadoopProperty "yarn.resourcemanager.admin.address.$rm1_name" "$yarn_site")
  rm2_admin=$(GetHadoopProperty "yarn.resourcemanager.admin.address.$rm2_name" "$yarn_site")
  rm1_admin_port=$(GetPortFromString $rm1_admin)
  rm2_admin_port=$(GetPortFromString $rm2_admin)

  rm1_webapp=$(GetHadoopProperty "yarn.resourcemanager.webapp.address.$rm1_name" "$yarn_site")
  rm2_webapp=$(GetHadoopProperty "yarn.resourcemanager.webapp.address.$rm2_name" "$yarn_site")
  rm1_webapp_port=$(GetPortFromString $rm1_webapp)
  rm2_webapp_port=$(GetPortFromString $rm2_webapp)

  rm1_scheduler=$(GetHadoopProperty "yarn.resourcemanager.scheduler.address.$rm1_name" "$yarn_site")
  rm2_scheduler=$(GetHadoopProperty "yarn.resourcemanager.scheduler.address.$rm2_name" "$yarn_site")
  rm1_scheduler_port=$(GetPortFromString $rm1_scheduler)
  rm2_scheduler_port=$(GetPortFromString $rm2_scheduler)

  LogInfo "Configuring HA ResourceManager"
  CheckValueSetOrExit "RM Active" "$rm_active"
  CheckValueSetOrExit "RM1" "$rm1"
  CheckValueSetOrExit "RM1 admin port" "$rm1_admin_port"
  CheckValueSetOrExit "RM1 webapp port" "$rm1_webapp_port"
  CheckValueSetOrExit "RM1 scheduler port" "$rm1_scheduler_port"
  CheckValueSetOrExit "RM2" "$rm2"
  CheckValueSetOrExit "RM2 admin port" "$rm2_admin_port"
  CheckValueSetOrExit "RM2 webapp port" "$rm2_webapp_port"
  CheckValueSetOrExit "RM2 scheduler port" "$rm2_scheduler_port"

  jq ".feature.highAvailability.resourceManager = true |
    .yarn.resourcemanager.host = \"$rm_active_host\" |
    .yarn.resourcemanager.port = $rm1_port |
    .yarn.resourcemanager.adminPort = $rm1_admin_port |
    .yarn.resourcemanager.schedulerPort = $rm1_scheduler_port |
    .yarn.resourcemanager.webappPort = $rm1_webapp_port |
    .yarn.highAvailability.resourceManagers.$rm1_name.host = \"$rm1_host\" |
    .yarn.highAvailability.resourceManagers.$rm1_name.port = $rm1_port |
    .yarn.highAvailability.resourceManagers.$rm1_name.adminPort = $rm1_admin_port |
    .yarn.highAvailability.resourceManagers.$rm1_name.schedulerPort = $rm1_scheduler_port |
    .yarn.highAvailability.resourceManagers.$rm1_name.webappPort = $rm1_webapp_port |
    .yarn.highAvailability.resourceManagers.$rm2_name.host = \"$rm2_host\" |
    .yarn.highAvailability.resourceManagers.$rm2_name.port = $rm2_port |
    .yarn.highAvailability.resourceManagers.$rm2_name.adminPort = $rm2_admin_port |
    .yarn.highAvailability.resourceManagers.$rm2_name.schedulerPort = $rm2_scheduler_port |
    .yarn.highAvailability.resourceManagers.$rm2_name.webappPort = $rm2_webapp_port" \
    "$triconf" | sponge "$triconf"
}

function ConfigureHANameNode() {
  local enabled=$(GetHadoopProperty "dfs.ha.automatic-failover.enabled" "$hdfs_site")
  if [[ "$enabled" != "true" ]]; then
    return
  fi

  local fs_type="$1"
  local service_name=""
  if [[ "$fs_type" == "adl" ]]; then
    service_name=$(GetHadoopProperty "dfs.adls.home.hostname" "$core_site")
  elif [[ "$fs_type" == "wasb" ]]; then
    service_name=$(GetDefaultFS)
    service_name=$(echo "$service_name" | grep -Po "[a-z]*://\K.*")
  fi

  # Get the namenode names (assumes single nameservice)
  local nameservice=$(GetHadoopProperty "dfs.internal.nameservices" "$hdfs_site")
  local namenodes=$(GetHadoopProperty "dfs.ha.namenodes.$nameservice" "$hdfs_site")
  local nn1_name=$(echo "$namenodes" | cut -d, -f1)
  local nn2_name=$(echo "$namenodes" | cut -d, -f2)

  # Get the namenode addresses and ports
  local nn1_address=$(GetHadoopProperty "dfs.namenode.rpc-address.$nameservice.$nn1_name" "$hdfs_site")
  local nn1_host=$(GetHostFromString "$nn1_address")
  local nn1_port=$(GetPortFromString "$nn1_address")
  local nn2_address=$(GetHadoopProperty "dfs.namenode.rpc-address.$nameservice.$nn2_name" "$hdfs_site")
  local nn2_host=$(GetHostFromString "$nn2_address")
  local nn2_port=$(GetPortFromString "$nn2_address")

  LogInfo "Configuring HA NameNode"
  CheckValueSetOrExit "Service name" "$service_name"
  CheckValueSetOrExit "NameService" "$nameservice"
  CheckValueSetOrExit "NameNodes" "$namenodes"
  CheckValueSetOrExit "NameNode 1 host" "$nn1_host"
  CheckValueSetOrExit "NameNode 1 port" "$nn1_port"
  CheckValueSetOrExit "NameNode 2 host" "$nn2_host"
  CheckValueSetOrExit "NameNode 2 port" "$nn2_port"

  jq ".feature.highAvailability.namenode = true |
    .hdfs.highAvailability.serviceName = \"$service_name\" |
    .hdfs.highAvailability.namenodes.nn1.host = \"$nn1_host\" |
    .hdfs.highAvailability.namenodes.nn1.port = $nn1_port |
    .hdfs.highAvailability.namenodes.nn2.host = \"$nn2_host\" |
    .hdfs.highAvailability.namenodes.nn2.port = $nn2_port" \
    "$triconf" | sponge "$triconf"
}

function ConfigureHive() {
  local hive_enabled=true

  if $hive_enabled; then
    local hdp_short_version=$(ShortHDPVersion)
    LogInfo "Configuring Hive"
    CheckValueSetOrExit "HDP short version" "$hdp_short_version"

    jq ".[\"data-service\"].hiveJdbcJar = \"hadoop-deps/hdp-${hdp_short_version}/build/libs/hdp-${hdp_short_version}-hive-jdbc.jar\" |
      .[\"spark-job-service\"].enableHiveSupport = true |
      .[\"spark-job-service\"].hiveDependenciesLocation = \"%(topOfTree)s/hadoop-deps/hdp-${hdp_short_version}/build/libs\"" \
      "$triconf" | sponge "$triconf"
  fi
}

function ConfigureHDI() {
  LogInfo "Configuring HDI"

  fs_type=$(GetDefaultFSType)
  CheckValueSetOrExit "Default FS Type" "$fs_type"

  ConfigureHDP
  if [[ "$fs_type" == "adl" ]]; then
    ConfigureADLS
  elif [[ "$fs_type" == "wasb" ]]; then
    ConfigureWASB
  else
    LogError "Unsupported filesystem (\"$fs_type\"). Exiting."
  fi
  ConfigureHANameNode "$fs_type"
  ConfigureHAResourceManager
  ConfigureHive
}

function ConfigureEdgeNode() {
  LogInfo "Configuring edge node"

  local total_cores=$(GetCoreCount)

  # Num. webapp processes = round(cores/3) + 1
  local webapp_num_procs=$(echo "$(Round $(echo $total_cores/3 | bc -l)) + 1" | bc)
  # Num. webapp DB connections = cores * 2
  local webapp_db_max_connections=$(echo "$total_cores*2" | bc)

  # Num. VFS processes = (# of webapp processes) / 2
  local vfs_num_procs=$(echo "$webapp_num_procs/2" | bc)

  # Num. photon processes = round(cores/6) + 1
  local photon_num_procs=$(echo "$(Round $(echo $total_cores/6 | bc -l)) + 1" | bc)
  if [[ "$total_cores" > 16 ]]; then
    photon_num_threads="4"
  else
    photon_num_threads="2"
  fi
  photon_mem_thresh="50"

  LogInfo "Webapp processes           : $webapp_num_procs"
  LogInfo "Webapp max connections     : $webapp_db_max_connections"
  LogInfo "VFS service processes      : $vfs_num_procs"
  LogInfo "Photon processes           : $photon_num_procs"
  LogInfo "Photon threads per process : $photon_num_threads"
  LogInfo "Photon memory threshold    : $photon_mem_thresh"

  jq ".webapp.numProcesses = $webapp_num_procs |
    .webapp.db.pool.maxConnections = $webapp_db_max_connections |
    .[\"vfs-service\"].numProcesses = $vfs_num_procs |
    .batchserver.workers.photon.max  = $photon_num_procs |
    .batchserver.workers.photon.memoryPercentageThreshold = $photon_mem_thresh |
    .photon.numThreads = $photon_num_threads" \
    "$triconf" | sponge "$triconf"
}

function StartTrifacta() {
  LogInfo "Starting Trifacta"
  chmod 666 "$triconf"
  service trifacta restart || true
}

function CreateHiveConnection() {
  local connection_file="$script_dir/hive-connection.json"
  local zk_host_str=$(GetHadoopProperty "hive.zookeeper.quorum" "/etc/hive/conf/hive-site.xml")
cat > "$connection_file" << EOF
{
    "jdbc": "hive2",
    "defaultDatabase": "default",
    "connectStrOpts": ";serviceDiscoveryMode=zooKeeper;zooKeeperNamespace=hiveserver2"
}
EOF

  LogInfo "Creating Hive connection"
  $trifacta_basedir/bin/trifacta_cli.py \
    create_connection \
    --user_name admin@trifacta.local \
    --password admin \
    --conn_name hive \
    --conn_host "$zk_host_str" \
    --conn_port 2181 \
    --conn_credential_type trifacta_service \
    --conn_type hadoop_hive \
    --conn_params_location "$connection_file" \
    --conn_skip_test \
    --conn_is_global
}

BackupFile "$triconf"

CreateCustomerKey
CreateHdfsDirectories
CopyHadoopConfigFiles

ConfigurePostgres
CreateDBRoles

ConfigureEdgeNode
ConfigureSecureTokenService
ConfigureUdfService
ConfigureAzureCommon
ConfigureHDI

StartTrifacta
CreateHiveConnection
