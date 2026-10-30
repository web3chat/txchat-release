#!/bin/bash
# 按服务列表构建 docker 镜像，并输出底部固定进度条
# 用法：bash build-images.sh <targetDir> <version> "<server list>"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/progress.sh"

targetDir="${1:-}"
version="${2:-}"
serviceList="${3:-}"

if [[ -z "${targetDir}" || -z "${version}" || -z "${serviceList}" ]]; then
  echo "usage: $0 <targetDir> <version> \"<server list>\"" >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: 未找到 docker 命令，请先安装并启动 Docker" >&2
  exit 127
fi

# shellcheck disable=SC2086
set -- ${serviceList}
total_local=$#
idx=0

offset="${DTALK_PROGRESS_OFFSET:-0}"
total_global="${DTALK_PROGRESS_TOTAL:-${total_local}}"

cd "${ROOT_DIR}/${targetDir}"
for name in ${serviceList}; do
  idx=$((idx + 1))
  cur=$((offset + idx))
  echo "==> docker build txchat-${name}:${version}"
  run_with_progress "${cur}" "${total_global}" "image" "${name}" -- \
    docker build --build-arg "server_name=${name}" . -f server.Dockerfile -t "txchat-${name}:${version}"
done
