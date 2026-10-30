#!/usr/bin/env bash
# 重置 im 部署环境：仅删除本项目容器 / 卷 / 自建镜像与 run_compose。
# 不触碰 dtalk / presence 及其他无关资源；不删除共享网络。
#
# 用法：
#   ./reset.sh              # 交互确认后执行
#   ./reset.sh -y           # 跳过确认
#   ./reset.sh --dry-run    # 只打印将要删除的资源
#   ./reset.sh -y --keep-images
#   ./reset.sh -y --keep-run-compose
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RUN_COMPOSE_DIR="${PROJECT_ROOT}/run_compose"

YES=0
DRY_RUN=0
KEEP_IMAGES=0
PURGE_RUN_COMPOSE=1

# 本项目自建镜像（不含 redis/etcd/kafka 等公共基础镜像）
IM_IMAGE_REPOS=(
  txchat-comet
  txchat-logic
)

# .env 缺失时的默认容器名（与 script/compose/.env / components 一致）
DEFAULT_CONTAINERS=(
  txchat-comet-node1
  txchat-logic-node1
  txchat-zookeeper
  txchat-kafka
  txchat-kafka-manager
  txchat-redis
  txchat-etcd
)

DEFAULT_VOLUMES=(
  txchat-comet-config
  txchat-logic-config
  txchat-redis-data
  txchat-redis-config
  txchat-redis-log
  txchat-etcd-data
)

log() { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }

usage() {
  cat <<'EOF'
重置 im 部署环境（仅本项目资源）。
用法：
  ./reset.sh              # 交互确认后执行
  ./reset.sh -y           # 跳过确认
  ./reset.sh --dry-run    # 只打印将要删除的资源
  ./reset.sh -y --keep-images
  ./reset.sh -y --keep-run-compose
说明：
  - 只删 im 容器 / 卷 / 自建镜像与 run_compose
  - 不删 dtalk、presence 及其他无关容器镜像
  - 不删共享网络 txchat-components / txchat-service
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) YES=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --keep-images) KEEP_IMAGES=1 ;;
    --keep-run-compose) PURGE_RUN_COMPOSE=0 ;;
    --purge-run-compose) PURGE_RUN_COMPOSE=1 ;;
    -h|--help) usage ;;
    *)
      warn "unknown arg: $1"
      usage
      ;;
  esac
  shift
done

run() {
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "DRY-RUN: $*"
    return 0
  fi
  log "+ $*"
  "$@"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    warn "command not found: $1"
    exit 1
  }
}

need_cmd docker

if ! docker info >/dev/null 2>&1; then
  warn "docker daemon 不可用，请先启动 Docker"
  exit 1
fi

COMPOSE_BIN=""
if docker compose version >/dev/null 2>&1; then
  COMPOSE_BIN="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_BIN="docker-compose"
fi

collect_from_env() {
  local file="$1" suffix_re="$2"
  [[ -f "${file}" ]] || return 0
  grep -E "^[A-Z0-9_]+${suffix_re}=" "${file}" 2>/dev/null \
    | cut -d= -f2- | tr -d '\r' | awk 'NF && !seen[$0]++'
}

resolve_env_file() {
  if [[ -f "${RUN_COMPOSE_DIR}/.env" ]]; then
    echo "${RUN_COMPOSE_DIR}/.env"
  elif [[ -f "${SCRIPT_DIR}/.env" ]]; then
    echo "${SCRIPT_DIR}/.env"
  else
    echo ""
  fi
}

uniq_lines() {
  awk 'NF && !seen[$0]++'
}

list_existing_containers() {
  local names=("$@")
  local n
  for n in "${names[@]}"; do
    [[ -n "${n}" ]] || continue
    if docker ps -a --format '{{.Names}}' | grep -Fxq "${n}"; then
      printf '%s\n' "${n}"
    fi
  done
}

list_existing_volumes() {
  local names=("$@")
  local n
  for n in "${names[@]}"; do
    [[ -n "${n}" ]] || continue
    if docker volume ls --format '{{.Name}}' | grep -Fxq "${n}"; then
      printf '%s\n' "${n}"
    fi
  done
}

list_project_images() {
  local repo id
  for repo in "${IM_IMAGE_REPOS[@]}"; do
    while IFS= read -r id; do
      [[ -n "${id}" ]] || continue
      printf '%s\n' "${id}"
    done < <(docker images --format '{{.Repository}} {{.ID}}' \
      | awk -v r="${repo}" '$1 == r {print $2}' | awk 'NF && !seen[$0]++')
  done | uniq_lines
}

compose_down() {
  local dir="$1"
  [[ -d "${dir}" ]] || return 0
  local files=()
  [[ -f "${dir}/components.compose.yaml" ]] && files+=(-f components.compose.yaml)
  [[ -f "${dir}/service.compose.yaml" ]] && files+=(-f service.compose.yaml)
  [[ ${#files[@]} -gt 0 ]] || return 0
  [[ -n "${COMPOSE_BIN}" ]] || return 0
  log "==> compose down in ${dir} (仅本 compose 项目)"
  (
    cd "${dir}"
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      log "DRY-RUN: ${COMPOSE_BIN} ${files[*]} down --remove-orphans --volumes"
    else
      # shellcheck disable=SC2086
      ${COMPOSE_BIN} "${files[@]}" down --remove-orphans --volumes || true
    fi
  )
}

ENV_FILE="$(resolve_env_file)"
CANDIDATE_CONTAINERS=()
CANDIDATE_VOLUMES=()

if [[ -n "${ENV_FILE}" ]]; then
  log "info: 资源名单来自 ${ENV_FILE}"
  while IFS= read -r line; do
    [[ -n "${line}" ]] && CANDIDATE_CONTAINERS+=("${line}")
  done < <(collect_from_env "${ENV_FILE}" "_CONTAINER_NAME")
  while IFS= read -r line; do
    [[ -n "${line}" ]] && CANDIDATE_VOLUMES+=("${line}")
  done < <(collect_from_env "${ENV_FILE}" "_(DATA|CONFIG|LOG|INIT)_VOLUME")
fi

# components 里部分容器名为硬编码，不在 .env 的 *_CONTAINER_NAME 中
CANDIDATE_CONTAINERS+=("${DEFAULT_CONTAINERS[@]}")
CANDIDATE_VOLUMES+=("${DEFAULT_VOLUMES[@]}")

# bash 3.2 兼容（避免 mapfile）
_CONTAINERS_MERGED="$(printf '%s\n' "${CANDIDATE_CONTAINERS[@]}" | uniq_lines)"
_VOLUMES_MERGED="$(printf '%s\n' "${CANDIDATE_VOLUMES[@]}" | uniq_lines)"
CANDIDATE_CONTAINERS=()
CANDIDATE_VOLUMES=()
while IFS= read -r line; do
  [[ -n "${line}" ]] && CANDIDATE_CONTAINERS+=("${line}")
done <<<"${_CONTAINERS_MERGED}"
while IFS= read -r line; do
  [[ -n "${line}" ]] && CANDIDATE_VOLUMES+=("${line}")
done <<<"${_VOLUMES_MERGED}"

CONTAINERS="$(list_existing_containers "${CANDIDATE_CONTAINERS[@]}" || true)"
VOLUMES="$(list_existing_volumes "${CANDIDATE_VOLUMES[@]}" || true)"
IMAGES=""
if [[ "${KEEP_IMAGES}" -eq 0 ]]; then
  IMAGES="$(list_project_images || true)"
fi

log "==== im reset preview (project-scoped) ===="
log "project root : ${PROJECT_ROOT}"
log "run_compose  : ${RUN_COMPOSE_DIR}"
log "env file     : ${ENV_FILE:-"(defaults)"}"
log "containers   :"
if [[ -n "${CONTAINERS}" ]]; then printf '  %s\n' ${CONTAINERS}; else log "  (none)"; fi
log "volumes      :"
if [[ -n "${VOLUMES}" ]]; then printf '  %s\n' ${VOLUMES}; else log "  (none)"; fi
if [[ "${KEEP_IMAGES}" -eq 0 ]]; then
  log "images       :"
  if [[ -n "${IMAGES}" ]]; then
    while IFS= read -r id; do
      [[ -n "${id}" ]] || continue
      docker images --format '{{.Repository}}:{{.Tag}} {{.ID}}' | awk -v id="${id}" '$2 == id {print "  " $1 " (" id ")"; found=1} END{if(!found) print "  " id}'
    done <<<"${IMAGES}"
  else
    log "  (none)"
  fi
else
  log "images       : (keep)"
fi
log "networks     : (skip shared txchat-components / txchat-service)"
log "purge run_compose: ${PURGE_RUN_COMPOSE}"
log "=========================================="

if [[ "${YES}" -ne 1 && "${DRY_RUN}" -ne 1 ]]; then
  printf '确认删除以上 im 资源？输入 yes 继续: '
  read -r ans
  if [[ "${ans}" != "yes" ]]; then
    log "已取消"
    exit 0
  fi
fi

compose_down "${RUN_COMPOSE_DIR}"

if [[ -n "${CONTAINERS}" ]]; then
  log "==> remove containers"
  # shellcheck disable=SC2086
  run docker rm -f ${CONTAINERS}
fi

if [[ -n "${VOLUMES}" ]]; then
  log "==> remove volumes"
  # shellcheck disable=SC2086
  run docker volume rm ${VOLUMES} || true
fi

if [[ "${KEEP_IMAGES}" -eq 0 && -n "${IMAGES}" ]]; then
  log "==> remove project images"
  # shellcheck disable=SC2086
  run docker rmi -f ${IMAGES} || true
fi

if [[ "${PURGE_RUN_COMPOSE}" -eq 1 && -e "${RUN_COMPOSE_DIR}" ]]; then
  log "==> remove run_compose directory"
  run rm -rf "${RUN_COMPOSE_DIR}"
fi

log "==> done (dtalk / presence / 共享网络未改动)"
log "重新部署建议："
log "  cd ${PROJECT_ROOT}"
log "  make init-compose"
log "  make docker-compose-up"
