#!/bin/bash
# make init-compose 的实际执行脚本（含底部固定进度条）
# 用法：bash init-compose.sh <version> <commit> "<server list>"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/progress.sh"
TARGETDIR="${TARGETDIR:-target}"

VERSION="${1:-unknown}"
COMMIT="${2:-unknown}"
SERVERS="${3:-}"

# 预置文件（与 MYSQL 密码同源）：script/compose/key
# 优先级：已有环境变量（make 命令行）> key > 默认值
load_key_if_unset() {
  local keyf="${SCRIPT_DIR}/key"
  [[ -f "${keyf}" ]] || return 0
  local line k v
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    [[ "${line}" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line//[[:space:]]/}" ]] && continue
    k="${line%%=*}"
    v="${line#*=}"
    k="${k%"${k##*[![:space:]]}"}"
    k="${k#"${k%%[![:space:]]*}"}"
    case "${k}" in
      FEDERATION_ENABLED|CLUSTER_ID|PRESENCE_URL|GENERATOR_NODE)
        if [[ -z "${!k:-}" ]]; then
          export "${k}=${v}"
        fi
        ;;
    esac
  done <"${keyf}"
  echo "info: 已合并预置 ${keyf}" >&2
}
load_key_if_unset

# 联邦全局变量（可由 make init-compose CLUSTER_ID=... 或 key 传入）
CLUSTER_ID="${CLUSTER_ID:-cluster-a}"
CLUSTER_ID_SOURCE="${CLUSTER_ID_SOURCE:-default}"
GENERATOR_NODE="${GENERATOR_NODE:-1}"
GENERATOR_NODE_SOURCE="${GENERATOR_NODE_SOURCE:-default}"
FEDERATION_ENABLED="${FEDERATION_ENABLED:-false}"
COMPOSE_PROFILES=""
# 未明确 FEDERATION_ENABLED=true 时，不编译、不启动 federation，也不把 Presence 地址写进运行配置。
# key 里残留的 PRESENCE_URL 同样忽略，避免 logic 在单集群模式下上报。
if [[ "${FEDERATION_ENABLED}" == "true" ]]; then
  COMPOSE_PROFILES="federation"
  PRESENCE_URL="${PRESENCE_URL:-http://txchat-presence:18050}"
else
  PRESENCE_URL=""
fi
export CLUSTER_ID CLUSTER_ID_SOURCE PRESENCE_URL GENERATOR_NODE GENERATOR_NODE_SOURCE FEDERATION_ENABLED COMPOSE_PROFILES

die() {
  finish_sticky_progress || true
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "未找到命令 '$1'，请先安装并确保在 PATH 中"
}

step() {
  local cur="$1"
  local total="$2"
  local phase="$3"
  local module="$4"
  draw_progress "${cur}" "${total}" "${phase}" "${module}"
}

if [[ -z "${SERVERS}" ]]; then
  die "server list is empty"
fi

need_cmd bash
need_cmd go
need_cmd docker
need_cmd git

if [[ "${FEDERATION_ENABLED}" == "true" ]]; then
  echo "info: 联邦模式，先确定 CLUSTER_ID 并向 Presence 占用 GENERATOR_NODE，可用后才继续编译"
  alloc_out="$(
    ROOT_DIR="${ROOT_DIR}" \
    CLUSTER_ID="${CLUSTER_ID}" \
    CLUSTER_ID_SOURCE="${CLUSTER_ID_SOURCE}" \
    PRESENCE_URL="${PRESENCE_URL}" \
    GENERATOR_NODE="${GENERATOR_NODE}" \
    GENERATOR_NODE_SOURCE="${GENERATOR_NODE_SOURCE}" \
      bash "${SCRIPT_DIR}/allocate-generator-node.sh"
  )"
  CLUSTER_ID="$(printf '%s\n' "${alloc_out}" | sed -n 's/^CLUSTER_ID=//p' | head -n1)"
  GENERATOR_NODE="$(printf '%s\n' "${alloc_out}" | sed -n 's/^GENERATOR_NODE=//p' | head -n1)"
  [[ "${CLUSTER_ID}" =~ ^[A-Za-z0-9._-]+$ ]] || die "未得到可用的 CLUSTER_ID"
  [[ "${GENERATOR_NODE}" =~ ^[0-9]+$ ]] || die "未得到可用的 GENERATOR_NODE"
  export CLUSTER_ID GENERATOR_NODE
fi

# shellcheck disable=SC2086
set -- ${SERVERS}
N=$#
# compile N + apply-federation 1 + image N + setup 3
TOTAL=$((N * 2 + 4))

export DTALK_PROGRESS_TOTAL="${TOTAL}"

init_sticky_progress
trap 'finish_sticky_progress || true' EXIT

echo "┌ init-compose server list (version=${VERSION}):"
i=1
for s in ${SERVERS}; do
  echo "  ${i}. ${s}"
  i=$((i + 1))
done
echo "└ total: ${N} servers"
echo "└ progress steps: ${TOTAL} (compile ${N} + federation 1 + image ${N} + setup 3)"
echo "└ federation: FEDERATION_ENABLED=${FEDERATION_ENABLED} CLUSTER_ID=${CLUSTER_ID} PRESENCE_URL=${PRESENCE_URL} GENERATOR_NODE=${GENERATOR_NODE}"
echo

cd "${ROOT_DIR}" || die "无法进入项目目录: ${ROOT_DIR}"

# 1) 编译
export DTALK_PROGRESS_OFFSET=0
rm -rf "${TARGETDIR}"
bash ./script/builder/builder.sh "${TARGETDIR}" "linux_amd64" "${SERVERS}"

# 2) 注入联邦全局配置到 target/*.toml（再打镜像）
step "$((N + 1))" "${TOTAL}" "setup" "apply-federation"
bash ./script/compose/apply-federation-config.sh "${TARGETDIR}"

# 3) 镜像
export DTALK_PROGRESS_OFFSET="$((N + 1))"
cp script/docker/*Dockerfile "${TARGETDIR}/"
bash ./script/compose/build-images.sh "${TARGETDIR}" "${VERSION}" "${SERVERS}"

# 4) compose 工作区
step "$((N * 2 + 2))" "${TOTAL}" "setup" "copy-compose-files"
rm -rf run_compose
mkdir -p run_compose
cp -R script/compose/. run_compose/
cp -R script/mysql/. run_compose/
cp -R script/nginx/. run_compose/

step "$((N * 2 + 3))" "${TOTAL}" "setup" "envfill"
(
  cd run_compose
  # env_tmpl 使用 ${CLUSTER_ID:-...}，需导出后由 envfill eval
  export CLUSTER_ID PRESENCE_URL GENERATOR_NODE FEDERATION_ENABLED COMPOSE_PROFILES
  bash ./envfill.sh
)

step "$((N * 2 + 4))" "${TOTAL}" "setup" "initwork"
(
  cd run_compose
  FEDERATION_ENABLED="${FEDERATION_ENABLED}" bash ./initwork.sh "${SERVERS}" "${VERSION}"
)

step "${TOTAL}" "${TOTAL}" "setup" "done"
finish_sticky_progress

bash ./script/compose/banner.sh "${VERSION}" "${COMMIT}" "${SERVERS}"
