#!/usr/bin/env bash
# make docker-compose-up：兼容 docker compose v2 与 docker-compose v1.29
#
# 背景：make update 曾用 docker run 打残缺 compose 标签（缺 version/number），
# compose v1 会在 convergence 时崩溃（ValueError / ComposeVersion AttributeError）。
#
# 策略：
# 1) 优先 docker compose v2
# 2) up 前清理「毒容器」：带本项目 compose 标签但缺 version/number，或无 compose.version 的同名容器
# 3) v1 额外：对仍带残缺标签的本项目容器一律删掉，再 up（避免收敛逻辑踩坑）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RUN_DIR="${ROOT_DIR}/run_compose"
ENV_FILE="${RUN_DIR}/.env"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { printf '%s\n' "$*"; }

[[ -d "${RUN_DIR}" ]] || die "run_compose/ 不存在，请先执行 make init-compose"
[[ -f "${ENV_FILE}" ]] || die "缺少 ${ENV_FILE}"

env_get() {
  grep -E "^${1}=" "${ENV_FILE}" | head -1 | cut -d= -f2- | tr -d '\r' \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true
}

PROJECT="$(env_get COMPOSE_PROJECT_NAME)"
PROJECT="${PROJECT:-txchat_biz}"
PROFILES="$(env_get COMPOSE_PROFILES)"

COMPOSE_BIN=""
COMPOSE_IS_V1=0
if docker compose version >/dev/null 2>&1; then
  COMPOSE_BIN="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_BIN="docker-compose"
  COMPOSE_IS_V1=1
else
  die "未找到 docker compose / docker-compose"
fi

log "info: compose → ${COMPOSE_BIN}"
log "info: project → ${PROJECT}"
if [[ "${COMPOSE_IS_V1}" -eq 1 ]]; then
  log "warn: 检测到 docker-compose v1（如 1.29），兼容性差；建议安装 Compose V2:"
  log "warn:   sudo apt-get install -y docker-compose-plugin   # 或官方文档安装 docker compose"
fi

label_of() {
  docker inspect -f "{{index .Config.Labels \"$1\"}}" "$2" 2>/dev/null || true
}

# 毒容器：挂了本项目 compose 标签，但缺少 version 或 container-number（update 残留）
is_poison_compose_container() {
  local cid="$1"
  local proj num ver
  proj="$(label_of "com.docker.compose.project" "${cid}")"
  [[ "${proj}" == "${PROJECT}" ]] || return 1
  num="$(label_of "com.docker.compose.container-number" "${cid}")"
  ver="$(label_of "com.docker.compose.version" "${cid}")"
  if [[ -z "${num}" || -z "${ver}" ]]; then
    return 0
  fi
  return 1
}

rm_container() {
  local cid="$1" name="$2" reason="$3"
  log "    rm (${reason}): ${name} (${cid})"
  docker rm -f "${cid}" >/dev/null 2>&1 || true
}

echo "==> sanitize containers incompatible with compose"
# 1) 按项目标签扫毒
while IFS= read -r line; do
  [[ -z "${line}" ]] && continue
  cid="$(printf '%s' "${line}" | awk '{print $1}')"
  name="$(printf '%s' "${line}" | awk '{print $2}')"
  if is_poison_compose_container "${cid}"; then
    rm_container "${cid}" "${name}" "incomplete compose labels"
  fi
done < <(docker ps -a \
  --filter "label=com.docker.compose.project=${PROJECT}" \
  --format '{{.ID}} {{.Names}}' 2>/dev/null || true)

# 2) .env 中声明的固定容器名：若存在且没有合法 compose.version，先删掉再交给 compose 重建
#    （覆盖 make update 的无标签 / 残标签 docker run 容器）
while IFS= read -r cname; do
  [[ -z "${cname}" ]] && continue
  cid="$(docker ps -aq --filter "name=^/${cname}$" 2>/dev/null | head -1 || true)"
  [[ -n "${cid}" ]] || continue
  ver="$(label_of "com.docker.compose.version" "${cid}")"
  proj="$(label_of "com.docker.compose.project" "${cid}")"
  if [[ -z "${ver}" ]]; then
    rm_container "${cid}" "${cname}" "no compose.version (update orphan)"
  elif [[ -n "${proj}" && "${proj}" != "${PROJECT}" ]]; then
    log "    skip ${cname}: belongs to other project ${proj}"
  fi
done < <(grep -E '^[A-Z0-9_]+_CONTAINER_NAME=' "${ENV_FILE}" | cut -d= -f2- | tr -d '\r' | awk 'NF && !seen[$0]++')

# 3) compose v1：再清一遍本项目标签容器中仍缺 version 的（双保险）
if [[ "${COMPOSE_IS_V1}" -eq 1 ]]; then
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    cid="$(printf '%s' "${line}" | awk '{print $1}')"
    name="$(printf '%s' "${line}" | awk '{print $2}')"
    ver="$(label_of "com.docker.compose.version" "${cid}")"
    if [[ -z "${ver}" ]]; then
      rm_container "${cid}" "${name}" "v1 force: missing compose.version"
    fi
  done < <(docker ps -a \
    --filter "label=com.docker.compose.project=${PROJECT}" \
    --format '{{.ID}} {{.Names}}' 2>/dev/null || true)
fi

docker network inspect txchat-components >/dev/null 2>&1 || docker network create txchat-components
docker network inspect txchat-service >/dev/null 2>&1 || docker network create txchat-service

# 用仓库内最新 compose 覆盖 run_compose 副本（保留 .env / key）
for f in components.compose.yaml service.compose.yaml; do
  if [[ -f "${SCRIPT_DIR}/${f}" ]]; then
    cp -f "${SCRIPT_DIR}/${f}" "${RUN_DIR}/${f}"
  fi
done

# 强制从 .env 导出关键变量，覆盖 shell 里空的同名 export（compose 优先用环境变量）
export_from_env() {
  local key="$1" default="${2:-}"
  local v
  v="$(env_get "${key}")"
  if [[ -z "${v}" ]]; then
    v="${default}"
  fi
  if [[ -z "${v}" ]]; then
    die ".env 缺少 ${key}（且无默认值）"
  fi
  export "${key}=${v}"
}

export_from_env MYSQL_ROOT_PASSWORD
export_from_env MYSQL_ROOT_HOST '%'
export_from_env MYSQL_VERSION '8-oracle'
export_from_env MYSQL_CONTAINER_NAME 'txchat-mysql'
export_from_env MINIO_VERSION 'RELEASE.2021-07-22T05-23-32Z'
export_from_env MINIO_CONTAINER_NAME 'txchat-minio'
export_from_env MINIO_ROOT_USER 'minio'
export_from_env MINIO_ROOT_PASSWORD
export_from_env MINIO_DATA_VOLUME 'txchat-minio-data'
export_from_env MYSQL_DATA_VOLUME 'txchat-mysql-data'
export_from_env MYSQL_LOG_VOLUME 'txchat-mysql-log'
export_from_env MYSQL_INIT_VOLUME 'txchat-mysql-init'
export_from_env NGINX_VERSION '1.19.2-alpine'
export_from_env NGINX_CONTAINER_NAME 'txchat-nginx'
export_from_env NGINX_CONFIG_VOLUME 'txchat-nginx-config'
export_from_env NGINX_LOG_VOLUME 'txchat-nginx-log'
export_from_env COMPOSE_PROJECT_NAME 'txchat_biz'

# 确保 external 卷存在（initwork 未跑或被 destroy 后常见）
for vol in txchat-mysql-data txchat-mysql-log txchat-mysql-init txchat-minio-data \
  txchat-nginx-config txchat-nginx-log; do
  if ! docker volume inspect "${vol}" >/dev/null 2>&1; then
    log "info: create volume ${vol}"
    docker volume create "${vol}" >/dev/null
  fi
done

cd "${RUN_DIR}"

COMPOSE_ARGS=(-f components.compose.yaml -f service.compose.yaml)
# 联邦 profile（compose v1 可能忽略；v2 生效）
if [[ "${PROFILES}" == *"federation"* ]] || [[ "$(env_get FEDERATION_ENABLED)" == "true" ]]; then
  export COMPOSE_PROFILES="${PROFILES:-federation}"
  log "info: COMPOSE_PROFILES=${COMPOSE_PROFILES}"
fi

UP_ARGS=(up -d)
# compose v1 会忽略 profiles，federation 服务仍会被拉起。未开启时把副本数压成 0。
if [[ "${COMPOSE_IS_V1}" -eq 1 ]] && [[ "$(env_get FEDERATION_ENABLED)" != "true" ]]; then
  UP_ARGS+=(--scale federation=0)
  log "info: 未开启联邦，不启动 federation"
fi

echo "==> ${COMPOSE_BIN} ${UP_ARGS[*]}"
set +e
# shellcheck disable=SC2086
${COMPOSE_BIN} "${COMPOSE_ARGS[@]}" "${UP_ARGS[@]}"
rc=$?
set -e

if [[ "${rc}" -ne 0 ]]; then
  log "ERROR: compose up 失败 (exit=${rc})"
  if [[ "${COMPOSE_IS_V1}" -eq 1 ]]; then
    log "提示: docker-compose 1.29 与当前 Docker 经常不兼容。"
    log "请安装 Compose V2 后重试："
    log "  sudo apt-get update && sudo apt-get install -y docker-compose-plugin"
    log "  docker compose version"
    log "或临时用: make update MODULES=\"...\" 只热更新业务容器（不经 compose up）"
  fi
  exit "${rc}"
fi

echo "✔ docker-compose-up done"
