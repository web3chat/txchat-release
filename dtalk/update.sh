#!/usr/bin/env bash
# 热更新指定 dtalk 业务模块：编译 + 打镜像 + docker run 重建
# 不改 .env、不走 init-compose、不调用 docker-compose（规避 v1 ContainerConfig）
#
# 用法:
#   bash script/compose/update.sh pusher gateway
#   make update MODULES="pusher gateway"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TARGETDIR="${TARGETDIR:-target}"
# 可选：REFRESH_CONFIG=1 时把仓库内 toml 覆盖进配置卷（默认不覆盖，避免冲掉线上改动）
REFRESH_CONFIG="${REFRESH_CONFIG:-0}"

ALL_SERVERS="answer backend backup call device discovery gateway generator group offline-push oss pusher store chatclean chatadmin federation"
MYSQL_SERVICES="backend backup device group store chatclean chatadmin federation gateway pusher"

die() { echo "ERROR: $*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "未找到命令 '$1'"; }

env_get() {
  local key="$1"
  local file="$2"
  local val
  val="$(grep -E "^${key}=" "${file}" | head -n1 | cut -d= -f2- | tr -d '\r' || true)"
  printf '%s' "${val}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# offline-push -> OFFLINE_PUSH
svc_env_prefix() {
  echo "$1" | tr '[:lower:]-' '[:upper:]_'
}

is_in_list() {
  local needle="$1"
  local hay="$2"
  for x in ${hay}; do
    [[ "${x}" == "${needle}" ]] && return 0
  done
  return 1
}

need_cmd bash
need_cmd go
need_cmd docker

cd "${ROOT_DIR}" || die "无法进入项目目录: ${ROOT_DIR}"

ENV_FILE="${ROOT_DIR}/run_compose/.env"
[[ -f "${ENV_FILE}" ]] || die "run_compose/.env 不存在，请先执行一次 make init-compose"

MODULES=("$@")
if [[ ${#MODULES[@]} -eq 0 ]]; then
  die "请指定模块，例如: make update MODULES=\"pusher gateway\"
支持: ${ALL_SERVERS}"
fi

# 校验模块名
for m in "${MODULES[@]}"; do
  is_in_list "${m}" "${ALL_SERVERS}" || die "未知模块 '${m}'
支持: ${ALL_SERVERS}"
done

COMPOSE_PROJECT_NAME="$(env_get COMPOSE_PROJECT_NAME "${ENV_FILE}")"
MYSQL_ROOT_PASSWORD="$(env_get MYSQL_ROOT_PASSWORD "${ENV_FILE}")"
[[ -n "${COMPOSE_PROJECT_NAME}" ]] || COMPOSE_PROJECT_NAME="txchat_biz"

echo "┌ dtalk update（不改 .env，不调用 docker-compose）"
echo "│ modules: ${MODULES[*]}"
echo "│ project: ${COMPOSE_PROJECT_NAME}"
echo "│ refresh_config: ${REFRESH_CONFIG}"
echo "└"

# 确保网络存在
docker network inspect txchat-components >/dev/null 2>&1 || docker network create txchat-components
docker network inspect txchat-service >/dev/null 2>&1 || docker network create txchat-service

# 1) 只编译指定模块
echo "==> build (${MODULES[*]})"
mkdir -p "${TARGETDIR}"
# shellcheck disable=SC2068
bash ./script/builder/builder.sh "${TARGETDIR}" "linux_amd64" "${MODULES[*]}"
cp script/docker/*Dockerfile "${TARGETDIR}/"

# 1.5) 用 .env 全局联邦变量回写 target toml，避免 update 把源码默认值打进镜像
# Makefile / 命令行已导出的 FEDERATION_ENABLED 优先；否则读 run_compose/.env
if [[ -z "${FEDERATION_ENABLED:-}" ]]; then
  FEDERATION_ENABLED="$(env_get FEDERATION_ENABLED "${ENV_FILE}")"
fi
CLUSTER_ID="$(env_get CLUSTER_ID "${ENV_FILE}")"
PRESENCE_URL="$(env_get PRESENCE_URL "${ENV_FILE}")"
GENERATOR_NODE="$(env_get GENERATOR_NODE "${ENV_FILE}")"
export FEDERATION_ENABLED="${FEDERATION_ENABLED:-false}"
export CLUSTER_ID="${CLUSTER_ID:-cluster-a}"
export PRESENCE_URL="${PRESENCE_URL:-http://txchat-presence:18050}"
export GENERATOR_NODE="${GENERATOR_NODE:-1}"
echo "==> apply-federation (FEDERATION_ENABLED=${FEDERATION_ENABLED} CLUSTER_ID=${CLUSTER_ID} PRESENCE_URL=${PRESENCE_URL} GENERATOR_NODE=${GENERATOR_NODE})"
if [[ "${FEDERATION_ENABLED}" != "true" ]]; then
  echo "warn: FEDERATION_ENABLED=${FEDERATION_ENABLED}，将把 federation/pusher/gateway 的 enabled 写成 false" >&2
  echo "warn: 若要启用联邦，请先在 run_compose/.env 设置 FEDERATION_ENABLED=true，或：" >&2
  echo "warn:   make update MODULES=\"federation\" FEDERATION_ENABLED=true" >&2
fi
bash "${SCRIPT_DIR}/apply-federation-config.sh" "${TARGETDIR}"

# 2) 逐个打镜像 + 重建容器
for sName in "${MODULES[@]}"; do
  prefix="$(svc_env_prefix "${sName}")"
  image_tag="$(env_get "${prefix}_IMAGE" "${ENV_FILE}")"
  container_name="$(env_get "${prefix}_CONTAINER_NAME" "${ENV_FILE}")"
  config_volume="$(env_get "${prefix}_CONFIG_VOLUME" "${ENV_FILE}")"

  [[ -n "${image_tag}" ]] || die ".env 缺少 ${prefix}_IMAGE"
  [[ -n "${container_name}" ]] || die ".env 缺少 ${prefix}_CONTAINER_NAME"
  [[ -n "${config_volume}" ]] || die ".env 缺少 ${prefix}_CONFIG_VOLUME"

  image_name="txchat-${sName}:${image_tag}"
  echo
  echo "==> [${sName}] image ${image_name}"
  (
    cd "${TARGETDIR}"
    docker build --build-arg "server_name=${sName}" -f server.Dockerfile -t "${image_name}" .
  )

  if [[ "${REFRESH_CONFIG}" == "1" ]]; then
    echo "==> [${sName}] refresh config volume: ${config_volume}"
    docker volume inspect "${config_volume}" >/dev/null 2>&1 \
      || die "配置卷 ${config_volume} 不存在，请先 make init-compose"
    src_toml="${ROOT_DIR}/${TARGETDIR}/${sName}.toml"
    [[ -f "${src_toml}" ]] || die "缺少 ${src_toml}"
    docker run --rm \
      -v "${config_volume}:/etc/txchat-${sName}/config" \
      -v "${src_toml}:/tmp/${sName}.toml:ro" \
      alpine:latest \
      cp "/tmp/${sName}.toml" "/etc/txchat-${sName}/config/${sName}.toml"
  fi

  echo "==> [${sName}] recreate via docker run (${container_name})"
  if docker ps -a --format '{{.Names}}' | grep -qx "${container_name}"; then
    docker stop "${container_name}" >/dev/null 2>&1 || true
    docker rm -f "${container_name}" >/dev/null
  fi
  # 清理同名 / 同服务残留（含旧版错误打上的 compose 标签容器）
  while IFS= read -r c; do
    [[ -z "${c}" ]] && continue
    echo "    rm leftover: ${c}"
    docker rm -f "${c}" >/dev/null 2>&1 || true
  done < <(
    {
      docker ps -a --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME}" \
        --filter "label=com.docker.compose.service=${sName}" --format '{{.Names}}' 2>/dev/null || true
      docker ps -a --filter "label=txchat.service=${sName}" --format '{{.Names}}' 2>/dev/null || true
    } | awk 'NF && !seen[$0]++'
  )

  run_args=(
    -d
    --name "${container_name}"
    --network txchat-components
    --restart unless-stopped
    -v "${config_volume}:/etc/txchat-${sName}/config"
    # 不要打 com.docker.compose.* 标签：残缺标签会导致 docker-compose v1
    # 在后续 make docker-compose-up 时 ValueError / ComposeVersion 崩溃。
    --label "txchat.managed-by=update"
    --label "txchat.service=${sName}"
  )

  if is_in_list "${sName}" "${MYSQL_SERVICES}"; then
    [[ -n "${MYSQL_ROOT_PASSWORD}" ]] || die ".env 缺少 MYSQL_ROOT_PASSWORD（${sName} 需要）"
    run_args+=(-e "MYSQL_PASSWORD=${MYSQL_ROOT_PASSWORD}")
  fi

  # federation Bridge gRPC / admin 必须映射到宿主，否则跨机 Presence 注册地址不可达
  if [[ "${sName}" == "federation" ]]; then
    grpc_port="$(env_get FEDERATION_GRPC_PUB_PORT "${ENV_FILE}")"
    admin_port="$(env_get FEDERATION_ADMIN_PUB_PORT "${ENV_FILE}")"
    grpc_port="${grpc_port:-18060}"
    admin_port="${admin_port:-18061}"
    run_args+=(-p "${grpc_port}:18060" -p "${admin_port}:18061")
  fi

  docker run "${run_args[@]}" "${image_name}"
  docker network connect txchat-service "${container_name}" 2>/dev/null || true

  echo "✔ [${sName}] ok  image=${image_name}  container=${container_name}"
done

echo
echo "✔ update 完成（docker run，未改 .env）"
echo "  modules: ${MODULES[*]}"
echo "  日志示例: docker logs -f <CONTAINER_NAME>"
echo
