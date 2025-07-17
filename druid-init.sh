#!/usr/bin/env bash

# Author: Krzysztof Jankiewicz
# GitHub: https://github.com/BigDataKJCourses/druid-on-dataproc
# License: See LICENSE file in this repository
# Usage allowed with attribution. Redistribution or resale prohibited.

set -euxo pipefail

# ============================
# === PARAMETRY SKRYPTU  ====
# ============================
DRUID_VERSION="32.0.1"
INSTALL_DIR="/opt/druid"
DRUID_USER="druid"

MYSQL_CONNECTOR_VERSION="9.3.0"
MYSQL_JAR="mysql-connector-j-${MYSQL_CONNECTOR_VERSION}.jar"
MYSQL_URL="https://repo1.maven.org/maven2/com/mysql/mysql-connector-j/${MYSQL_CONNECTOR_VERSION}/${MYSQL_JAR}"

ZOOKEEPER_PORT=2181

HDFS_DEEP_DIR="/druid/deepstorage"
HADOOP_CONF_DIR="/etc/hadoop/conf"

MYSQL_DB="druid"
MYSQL_USER="druid"
MYSQL_PASS="druidpass"

# ============================
# === 1. STAGING_BUCKET i HOSTNAME ===
# ============================
STAGING_BUCKET=$(curl -s -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/attributes/dataproc-bucket)
CLUSTER_NAME=$(curl -s -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/attributes/dataproc-cluster-name)
HOST_FULL=$(hostname -f)

ZK_HOST="${CLUSTER_NAME}-m"
ZK_CONNECT="${ZK_HOST}:${ZOOKEEPER_PORT}"

# ============================
# === 2. ROLA WĘZŁA ===========
# ============================
if [[ "${HOST_FULL}" =~ -m(\.|$) ]]; then
  ROLE="master"
else
  ROLE="worker"
fi


# ============================
# === 3. UŻYTKOWNIK DRUID =====
# ============================
if ! id "${DRUID_USER}" &>/dev/null; then
  useradd --system --create-home --shell /bin/bash "${DRUID_USER}"
fi

# ============================
# === 4. DEPENDENCIES ========
# ============================
apt-get update
apt-get install -y curl unzip default-jre-headless mysql-client

# ============================
# === 5. POBRANIE DRUID =======
# ============================
mkdir -p "${INSTALL_DIR}"
gsutil cp "gs://${STAGING_BUCKET}/apache-druid-${DRUID_VERSION}-bin.tar.gz" /tmp/druid.tgz
tar -xzf /tmp/druid.tgz -C "${INSTALL_DIR}" --strip-components=1
chown -R "${DRUID_USER}":"${DRUID_USER}" "${INSTALL_DIR}"


# ============================
# === 6. KATALOGI LOG i PID ===
# ============================
for d in /var/log/druid /var/druid/metadata /var/druid/indexing-tasks /var/druid/pids /var/druid/tmp; do
  mkdir -p "${d}"
  chown -R "${DRUID_USER}":"${DRUID_USER}" "${d}"
done

# ============================
# === 7. ZMIENNE ŚRODOWISKOWE =
# ============================
cat <<EOF > /etc/profile.d/druid.sh
export DRUID_HOME=${INSTALL_DIR}
export PATH=\$DRUID_HOME/bin:\$PATH
export HADOOP_CONF_DIR=${HADOOP_CONF_DIR}
EOF

# ============================
# === 8. KONFIGURACJA MySQL ===
# ============================
if [[ "${ROLE}" == "master" ]]; then
  sudo mysql -u root <<EOF
CREATE DATABASE IF NOT EXISTS ${MYSQL_DB} DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'%' IDENTIFIED BY '${MYSQL_PASS}';
GRANT ALL PRIVILEGES ON ${MYSQL_DB}.* TO '${MYSQL_USER}'@'%';
FLUSH PRIVILEGES;
EOF
fi

# ============================
# === 9. STEROWNIK MySQL ======
# ============================
EXT_DIR="${INSTALL_DIR}/extensions/mysql-metadata-storage"
mkdir -p "${EXT_DIR}"
curl -fsSL "${MYSQL_URL}" -o "${EXT_DIR}/${MYSQL_JAR}"
chown -R "${DRUID_USER}":"${DRUID_USER}" "${EXT_DIR}"

# ============================
# === 10. KONFIGURACJA CLUSTERA ==
# ============================
BASE_CONF="${INSTALL_DIR}/conf/druid"
rm -rf "${BASE_CONF}/_common" "${BASE_CONF}/master" "${BASE_CONF}/data" "${BASE_CONF}/query"
cp -r "${INSTALL_DIR}/conf/druid/cluster/_common" "${BASE_CONF}/"
if [[ "${ROLE}" == "master" ]]; then
  cp -r "${INSTALL_DIR}/conf/druid/cluster/master" "${BASE_CONF}/"
  rm -rf "${BASE_CONF}/coordinator-overlord"
  cp -r "${BASE_CONF}/master/coordinator-overlord" "${BASE_CONF}/coordinator-overlord"
  cp -r "${INSTALL_DIR}/conf/druid/cluster/query/"* "${BASE_CONF}/"
else
  cp -r "${INSTALL_DIR}/conf/druid/cluster/data/"* "${BASE_CONF}/"
fi

# ============================
# === 10a. KONFIGURACJA CLUSTERA WYJATKI ==
# ============================
if [[ "${ROLE}" == "master" ]]; then
  # Overlord
  # sudo sed -i '/^druid.plaintextPort=/d' "${BASE_CONF}/overlord/runtime.properties"
  # echo "druid.plaintextPort=8091" | sudo tee -a "${BASE_CONF}/overlord/runtime.properties"

  # Coordinator
  # sudo sed -i '/^druid.plaintextPort=/d' "${BASE_CONF}/coordinator/runtime.properties"
  # echo "druid.plaintextPort=8092" | sudo tee -a "${BASE_CONF}/coordinator/runtime.properties"
  
  # Coordinator i Overlord
  sudo sed -i '/^druid.plaintextPort=/d' "${BASE_CONF}/coordinator-overlord/runtime.properties"
  echo "druid.plaintextPort=8091" | sudo tee -a "${BASE_CONF}/coordinator-overlord/runtime.properties"

  # Router
  sudo sed -i '/^druid.plaintextPort=/d' "${BASE_CONF}/router/runtime.properties"
  echo "druid.plaintextPort=8095" | sudo tee -a "${BASE_CONF}/router/runtime.properties"
fi


chown -R "${DRUID_USER}:${DRUID_USER}" "${BASE_CONF}"


cat <<EOF > "${BASE_CONF}/_common/common.runtime.properties"
# Zookeeper
druid.zk.service.host=${ZK_CONNECT}

# Metadata (MySQL)
druid.metadata.storage.type=mysql
druid.metadata.storage.connector.connectURI=jdbc:mysql://${ZK_HOST}:3306/${MYSQL_DB}?useSSL=false&allowPublicKeyRetrieval=true
druid.metadata.storage.connector.user=${MYSQL_USER}
druid.metadata.storage.connector.password=${MYSQL_PASS}

# Deep Storage (HDFS)
druid.storage.type=hdfs
druid.storage.hadoop.conf.dir=${HADOOP_CONF_DIR}
druid.storage.storageDirectory=hdfs://${ZK_HOST}/${HDFS_DEEP_DIR}

# Indeksery
druid.indexer.logs.directory=/var/log/druid
druid.indexer.task.baseDir=/var/druid/indexing-tasks
druid.indexer.task.tempDir=/var/druid/tmp

# Rozszerzenia
druid.extensions.directory=${INSTALL_DIR}/extensions
druid.extensions.loadList=["druid-avro-extensions","druid-basic-security","druid-stats","druid-bloom-filter","druid-datasketches","druid-histogram","druid-kafka-extraction-namespace","druid-kafka-indexing-service","druid-lookups-cached-global","druid-lookups-cached-single","druid-protobuf-extensions","mysql-metadata-storage","druid-orc-extensions","druid-parquet-extensions","druid-hdfs-storage"]

# PID
druid.pid.dir=/var/druid/pids
EOF
chown -R "${DRUID_USER}":"${DRUID_USER}" "${BASE_CONF}/_common"

# ============================
# === 11. START KOMPONENTÓW ==
# ============================
start_component() {
  local name=$1
  local log_file=$2

  local conf_dir="${BASE_CONF}"
  
  local jvm_file="${conf_dir}/${name}/jvm.config"
  local runtime_file="${conf_dir}/${name}/runtime.properties"
  
  local TMPDIR="/var/druid/tmp"
  
  case "$name" in
    broker)
      XMX="3g"
      DIRECT_MEM="3g"
      BUFFER_SIZE="128000000"    # 128MB
      NUM_MERGE_BUFFERS="2"
      NUM_THREADS="4"
      ;;
    historical)
      XMX="2g"
      DIRECT_MEM="2g"
      BUFFER_SIZE="100000000"    # 100MB
      NUM_MERGE_BUFFERS="1"
      NUM_THREADS="2"
      ;;
    middleManager|coordinator-overlord)
      XMX="1g"
      DIRECT_MEM="512m"
      ;;
    coordinator|overlord|router)
      XMX="512m"
      DIRECT_MEM="256m"
      ;;
    *)
      XMX="1g"
      DIRECT_MEM="512m"
      ;;
  esac
  
  # Modyfikacja jvm.config
  if [[ -f "$jvm_file" ]]; then
    sudo sed -i 's/^-Xms.*/-Xms'"${XMX}"'/' "$jvm_file"
    sudo sed -i 's/^-Xmx.*/-Xmx'"${XMX}"'/' "$jvm_file"
    sudo sed -i 's/^-XX:MaxDirectMemorySize=.*/-XX:MaxDirectMemorySize='"${DIRECT_MEM}"'/' "$jvm_file"
	
	# Popraw ścieżkę java.io.tmpdir
    if grep -q '^-Djava.io.tmpdir=' "$jvm_file"; then
      sudo sed -i 's|^-Djava.io.tmpdir=.*|-Djava.io.tmpdir='"${TMPDIR}"'|' "$jvm_file"
    else
      echo "-Djava.io.tmpdir=${TMPDIR}" | sudo tee -a "$jvm_file" > /dev/null
    fi
	
  fi

  # Modyfikacja parametrów przetwarzania, tylko jeśli plik istnieje
  if [[ -f "$runtime_file" ]]; then
    if [[ "$name" == "broker" || "$name" == "historical" ]]; then
      echo "Konfiguruję parametry przetwarzania w ${runtime_file}"

      # Usuń stare wartości
      sudo sed -i '/^druid.processing.buffer.sizeBytes=/d' "$runtime_file"
      sudo sed -i '/^druid.processing.numMergeBuffers=/d' "$runtime_file"
      sudo sed -i '/^druid.processing.numThreads=/d' "$runtime_file"

      # Dodaj nowe
      echo "druid.processing.buffer.sizeBytes=${BUFFER_SIZE}" | sudo tee -a "$runtime_file" > /dev/null
      echo "druid.processing.numMergeBuffers=${NUM_MERGE_BUFFERS}" | sudo tee -a "$runtime_file" > /dev/null
      echo "druid.processing.numThreads=${NUM_THREADS}" | sudo tee -a "$runtime_file" > /dev/null
    fi
  fi

  sudo -u "${DRUID_USER}" env \
    DRUID_HOME="${INSTALL_DIR}" \
    HADOOP_CONF_DIR="${HADOOP_CONF_DIR}" \
    PATH="${INSTALL_DIR}/bin:$PATH" \
    bash -c "cd ${INSTALL_DIR} && nohup ./bin/run-druid ${name} ${conf_dir} > ${log_file} 2>&1 &"
}

if [[ "${ROLE}" == "master" ]]; then
  echo "Starting Druid master components..."
  # start_component coordinator /var/log/druid/coordinator.log 
  # start_component overlord /var/log/druid/overlord.log
  start_component coordinator-overlord /var/log/druid/coordinator-overlord.log
  start_component broker /var/log/druid/broker.log
  start_component router /var/log/druid/router.log
else
  echo "Starting Druid worker components..."
  start_component historical /var/log/druid/historical.log
  start_component middleManager /var/log/druid/middleManager.log
fi

echo "======= Druid (${DRUID_VERSION}) uruchomiony jako ${ROLE} ======="
