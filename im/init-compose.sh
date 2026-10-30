#!/bin/bash
# make init-compose 的实际执行脚本（含进度条 + 自动同步 dtalk MySQL 密码）
# 用法：bash init-compose.sh <version> <commit> "<server list>"
# 可选环境变量：DTALK_ENV / DTALK_ROOT
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/progress.sh"
TARGETDIR="${TARGETDIR:-target}"

VERSION="${1:-unknown}"
COMMIT="${2:-unknown}"
SERVERS="${3:-}"

# 可被 make / 环境覆盖；若未设，先读 key，再尝试从 dtalk .env 读取
CLUSTER_ID="${CLUSTER_ID:-}"
PRESENCE_URL="${PRESENCE_URL:-}"
FEDERATION_ENABLED="${FEDERATION_ENABLED:-}"

# 预置文件：script/compose/key（优先级低于已有环境变量）
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
      CLUSTER_ID|PRESENCE_URL|FEDERATION_ENABLED)
        if [[ -z "${!k:-}" ]]; then
          export "${k}=${v}"
        fi
        ;;
    esac
  done <"${keyf}"
  echo "info: 已合并预置 ${keyf}" >&2
}
load_key_if_unset

die() {
  finish_sticky_progress || true
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "未找到命令 '$1'，请先安装并确保在 PATH 中"
}

step() {
  draw_progress "$1" "$2" "$3" "$4"
}

if [[ -z "${SERVERS}" ]]; then
  die "server list is empty"
fi

need_cmd bash
need_cmd go
need_cmd docker
need_cmd git

# shellcheck disable=SC2086
set -- ${SERVERS}
N=$#
# compile N + apply-federation 1 + image N + copy/sync/initwork 3
TOTAL=$((N * 2 + 4))

export PROGRESS_TOTAL="${TOTAL}"

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
if [[ -n "${DTALK_ENV:-}" ]]; then
  echo "└ DTALK_ENV=${DTALK_ENV}"
elif [[ -n "${DTALK_ROOT:-}" ]]; then
  echo "└ DTALK_ROOT=${DTALK_ROOT}"
else
  echo "└ dtalk .env: 自动探测同级目录 ../dtalk/run_compose/.env"
fi
echo

cd "${ROOT_DIR}" || die "无法进入项目目录: ${ROOT_DIR}"

# 预先解析 dtalk 联邦全局变量（打镜像前写入 logic.toml）
resolve_federation_globals() {
  local candidates=()
  if [[ -n "${DTALK_ENV:-}" ]]; then
    candidates+=("${DTALK_ENV}")
  fi
  if [[ -n "${DTALK_ROOT:-}" ]]; then
    candidates+=("${DTALK_ROOT}/run_compose/.env")
  fi
  candidates+=(
    "${ROOT_DIR}/../dtalk/run_compose/.env"
    "${ROOT_DIR}/../dtalk/script/compose/.env"
  )
  local f val
  for f in "${candidates[@]}"; do
    [[ -f "${f}" ]] || continue
    if [[ -z "${CLUSTER_ID}" ]]; then
      val="$(grep -E '^CLUSTER_ID=' "${f}" | head -1 | cut -d= -f2- || true)"
      [[ -n "${val}" ]] && CLUSTER_ID="${val}"
    fi
    if [[ -z "${PRESENCE_URL}" ]]; then
      val="$(grep -E '^PRESENCE_URL=' "${f}" | head -1 | cut -d= -f2- || true)"
      [[ -n "${val}" ]] && PRESENCE_URL="${val}"
    fi
    if [[ -z "${FEDERATION_ENABLED}" ]]; then
      val="$(grep -E '^FEDERATION_ENABLED=' "${f}" | head -1 | cut -d= -f2- || true)"
      [[ -n "${val}" ]] && FEDERATION_ENABLED="${val}"
    fi
    if [[ -n "${CLUSTER_ID}" && -n "${FEDERATION_ENABLED}" ]]; then
      break
    fi
  done
  CLUSTER_ID="${CLUSTER_ID:-cluster-a}"
  FEDERATION_ENABLED="${FEDERATION_ENABLED:-false}"
  # 与 dtalk 一致：未明确开启联邦时不注入 Presence 地址，logic 上报保持关闭
  if [[ "${FEDERATION_ENABLED}" == "true" ]]; then
    PRESENCE_URL="${PRESENCE_URL:-http://txchat-presence:18050}"
  else
    PRESENCE_URL=""
  fi
  export CLUSTER_ID PRESENCE_URL FEDERATION_ENABLED
}

resolve_federation_globals
echo "└ federation: FEDERATION_ENABLED=${FEDERATION_ENABLED} CLUSTER_ID=${CLUSTER_ID} PRESENCE_URL=${PRESENCE_URL:-<empty>}"

# 1) 编译
export PROGRESS_OFFSET=0
rm -rf "${TARGETDIR}"
bash ./script/build/builder.sh "${TARGETDIR}" "linux_amd64" "${SERVERS}"

# 2) Presence：写入环境变量占位（运行时由 compose 从 .env 注入，对齐 MYSQL_PASSWORD）
step "$((N + 1))" "${TOTAL}" "setup" "apply-federation"
if [[ -f "${TARGETDIR}/logic.toml" ]]; then
  awk '
    /^[[:space:]]*clusterId[[:space:]]*=/ {
      sub(/=.*/, ""); sub(/[[:space:]]+$/, ""); print $0 " = \"${CLUSTER_ID}\""; next
    }
    /^[[:space:]]*url[[:space:]]*=/ {
      sub(/=.*/, ""); sub(/[[:space:]]+$/, ""); print $0 " = \"${PRESENCE_URL}\""; next
    }
    { print }
  ' "${TARGETDIR}/logic.toml" >"${TARGETDIR}/logic.toml.tmp" \
    && mv "${TARGETDIR}/logic.toml.tmp" "${TARGETDIR}/logic.toml"
  echo "info: patched ${TARGETDIR}/logic.toml → \${PRESENCE_URL}/\${CLUSTER_ID}（运行时从 .env 注入）"
  echo "info:   expect CLUSTER_ID=${CLUSTER_ID} PRESENCE_URL=${PRESENCE_URL}"
fi

# 3) 镜像
export PROGRESS_OFFSET="$((N + 1))"
cp script/docker/*Dockerfile "${TARGETDIR}/"
bash ./script/compose/build-images.sh "${TARGETDIR}" "${VERSION}" "${SERVERS}"

# 4) compose 工作区
step "$((N * 2 + 2))" "${TOTAL}" "setup" "copy-compose-files"
rm -rf run_compose
mkdir -p run_compose
cp -R script/compose/. run_compose/
cp -R script/redis/. run_compose/

step "$((N * 2 + 3))" "${TOTAL}" "setup" "sync-mysql-from-dtalk"
bash ./script/compose/sync-mysql-from-dtalk.sh "${ROOT_DIR}/run_compose"

step "$((N * 2 + 4))" "${TOTAL}" "setup" "initwork"
(
  cd run_compose
  bash ./initwork.sh "${SERVERS}" "${VERSION}"
)

step "${TOTAL}" "${TOTAL}" "setup" "done"
finish_sticky_progress
trap - EXIT

bash ./script/compose/banner.sh "${VERSION}" "${COMMIT}" "${SERVERS}"
