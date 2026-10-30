#!/bin/bash
work_dir=$(
  cd "$(dirname "$0")" || exit
  pwd
)/../..

created_volume=()
created_network=()

serviceList=$1
projectVersion=$2

# platform adaptation
HOST_OS=$(uname -s | tr '[:upper:]' '[:lower:]')
case ${HOST_OS} in
"darwin")
  function dosed() {
    sed -r -i '' "$@"
  }
  ;;
*)
  function dosed() {
    sed -r -i "$@"
  }
  ;;
esac

function network_create() {
  networkName=$1
  filterName=$(docker network ls | awk 'NR>1{ print $2 }' | grep -w "${networkName}")
  if [ "$filterName" == "" ]; then
      #不存在就创建
      created_network+=("$networkName")
      docker network create "$networkName"
  fi
}

function volume_create() {
  volumeName=$1
  filterName=$(docker volume ls | awk 'NR>1{ print $2 }' | grep -w "${volumeName}")
  if [ "$filterName" == "" ]; then
      #不存在就创建
      created_volume+=("$volumeName")
      docker volume create "$volumeName"
  fi
}

function sync_mysql_init_sql() {
  # 将 SQL 同步进 txchat-mysql-init（挂到 /docker-entrypoint-initdb.d）。
  # 注意：官方 MySQL 镜像仅在数据目录为空时执行该目录；已有库须另跑
  # make migrate-federation-mysql。
  local dummy="txchat-mysql-init-sync-$$"
  docker container create --name "${dummy}" -v "txchat-mysql-init":/root hello-world >/dev/null
  docker cp dtalk_biz.sql "${dummy}:/root/dtalk_biz.sql"
  docker cp dtalk_record.sql "${dummy}:/root/dtalk_record.sql"
  docker cp dtalk_chatclean.sql "${dummy}:/root/dtalk_chatclean.sql"
  # 仅联邦模式拷贝 federation SQL（方案 E 单集群兼容）
  if [ "${FEDERATION_ENABLED:-false}" = "true" ]; then
    if [ -f dtalk_record_federation.sql ]; then
      docker cp dtalk_record_federation.sql "${dummy}:/root/dtalk_record_federation.sql"
      echo "info: synced dtalk_record_federation.sql → txchat-mysql-init"
    else
      echo "warn: FEDERATION_ENABLED=true 但缺少 dtalk_record_federation.sql" >&2
    fi
    if [ -f dtalk_record_federation_mirror.sql ]; then
      docker cp dtalk_record_federation_mirror.sql "${dummy}:/root/dtalk_record_federation_mirror.sql"
      echo "info: synced dtalk_record_federation_mirror.sql → txchat-mysql-init"
    fi
  fi
  docker rm "${dummy}" >/dev/null
}

function initMySQL() {
  # 新建 init 卷：完整写入基础 SQL +（可选）federation SQL
  for vname in ${created_volume[*]} ; do
    if [ "${vname}" = "txchat-mysql-init" ]; then
      sync_mysql_init_sql
      return 0
    fi
  done
  # init 卷已存在：联邦开启时仍同步 federation SQL（供文档/排查；不会对已有 data 卷自动建表）
  if [ "${FEDERATION_ENABLED:-false}" = "true" ]; then
    if docker volume ls -q | grep -qx "txchat-mysql-init"; then
      sync_mysql_init_sql
      echo "warn: MySQL 数据卷若已初始化，initdb 不会再跑 SQL；请执行: make migrate-federation-mysql" >&2
    fi
  fi
}

function initNginx() {
    for vname in ${created_volume[*]} ; do \
      if [ "${vname}" = "txchat-nginx-config" ]; then
        docker container create --name dummy -v "txchat-nginx-config":/root hello-world
        docker cp conf.d/* dummy:/root/
        docker rm dummy
      fi
    done
}

volumes=("txchat-mysql-data" "txchat-mysql-config" "txchat-mysql-log" "txchat-mysql-init" "txchat-minio-data"  "txchat-nginx-config" "txchat-nginx-log")
# compose 中声明为 external，需在 up 前存在（与 im/initwork.sh 一致）
networks=("txchat-components" "txchat-service")

for sName in ${serviceList} ; do \
  volumes+=("txchat-${sName}-config")
  # 将「-」转为「_」并将小写转大写
  upperSName=$(echo "${sName//[-]/_}" | tr '[:lower:]' '[:upper:]')
  # 修改.env文件服务镜像版本号
  dosed "s/(${upperSName}_IMAGE=)\s*(.+)/\1${projectVersion}/" .env
done

for vname in ${volumes[*]} ; do \
  volume_create "${vname}"
done

for netname in ${networks[*]} ; do \
  network_create "${netname}"
done

initMySQL
initNginx
