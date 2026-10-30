#!/usr/bin/env bash
# 从 dtalk/run_compose/.env 同步关键变量到 im/run_compose/.env
# - MYSQL_ROOT_PASSWORD（鉴权库）
# - CLUSTER_ID / PRESENCE_URL（联邦 Presence 上报）
#
# 用法:
#   bash sync-mysql-from-dtalk.sh <im_run_compose_dir>
# 可选环境变量:
#   DTALK_ENV   直接指定 dtalk 的 .env 文件路径
#   DTALK_ROOT  指定 dtalk 项目根目录（将读取 $DTALK_ROOT/run_compose/.env）
set -euo pipefail

IM_RUN_COMPOSE="${1:-}"
if [[ -z "${IM_RUN_COMPOSE}" ]]; then
  echo "usage: $0 <im_run_compose_dir>" >&2
  exit 1
fi

IM_ENV="${IM_RUN_COMPOSE}/.env"
if [[ ! -f "${IM_ENV}" ]]; then
  echo "ERROR: 未找到 im .env: ${IM_ENV}" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IM_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PARENT_DIR="$(cd "${IM_ROOT}/.." && pwd)"

candidates=()
if [[ -n "${DTALK_ENV:-}" ]]; then
  candidates+=("${DTALK_ENV}")
fi
if [[ -n "${DTALK_ROOT:-}" ]]; then
  candidates+=("${DTALK_ROOT}/run_compose/.env")
fi
# 常见同级目录布局：.../txchat/im 与 .../txchat/dtalk
candidates+=(
  "${PARENT_DIR}/dtalk/run_compose/.env"
  "${IM_ROOT}/../dtalk/run_compose/.env"
  "${PARENT_DIR}/dtalk/script/compose/.env"
)

DTALK_ENV_FILE=""
for c in "${candidates[@]}"; do
  if [[ -f "${c}" ]]; then
    DTALK_ENV_FILE="$(cd "$(dirname "${c}")" && pwd)/$(basename "${c}")"
    break
  fi
done

if [[ -z "${DTALK_ENV_FILE}" ]]; then
  echo "ERROR: 未找到 dtalk 的 .env（需要 MYSQL_ROOT_PASSWORD）" >&2
  echo "已尝试：" >&2
  for c in "${candidates[@]}"; do
    echo "  - ${c}" >&2
  done
  echo "请先完成 dtalk: make init-compose，或手动指定：" >&2
  echo "  make init-compose DTALK_ENV=/path/to/dtalk/run_compose/.env" >&2
  exit 1
fi

env_get() {
  local key="$1" file="$2"
  grep -E "^${key}=" "${file}" | head -1 | cut -d= -f2- | tr -d '\r\n' || true
}

upsert_env() {
  local key="$1" val="$2" file="$3"
  val="$(printf '%s' "${val}" | tr -d '\r\n')"
  if [[ -z "${val}" ]]; then
    return 0
  fi
  # 避免 sed 遇到 URL 中的 / 或特殊字符；整文件重写该 key
  awk -v k="${key}" -v v="${val}" '
    BEGIN { done=0 }
    $0 ~ ("^" k "=") { print k "=" v; done=1; next }
    { print }
    END { if (!done) print k "=" v }
  ' "${file}" >"${file}.tmp" && mv "${file}.tmp" "${file}"
}

PWD_VAL="$(env_get MYSQL_ROOT_PASSWORD "${DTALK_ENV_FILE}")"
if [[ -z "${PWD_VAL}" ]]; then
  echo "ERROR: ${DTALK_ENV_FILE} 中 MYSQL_ROOT_PASSWORD 为空" >&2
  echo "请检查 dtalk 是否已正确 init-compose 并生成密码" >&2
  exit 1
fi

# 联邦变量：环境/key 优先，否则从 dtalk .env 同步（对齐 MYSQL 密码同步）
# 未明确 FEDERATION_ENABLED=true 时 Presence 地址写空，logic 不会上报
CLUSTER_ID_VAL="$(printf '%s' "${CLUSTER_ID:-$(env_get CLUSTER_ID "${DTALK_ENV_FILE}")}" | tr -d '\r\n')"
FED_EN="$(printf '%s' "${FEDERATION_ENABLED:-$(env_get FEDERATION_ENABLED "${DTALK_ENV_FILE}")}" | tr -d '\r\n')"
if [[ "${FED_EN}" == "true" ]]; then
  PRESENCE_URL_VAL="$(printf '%s' "${PRESENCE_URL:-$(env_get PRESENCE_URL "${DTALK_ENV_FILE}")}" | tr -d '\r\n')"
  PRESENCE_URL_VAL="${PRESENCE_URL_VAL:-http://txchat-presence:18050}"
else
  PRESENCE_URL_VAL=""
fi

upsert_env "MYSQL_ROOT_PASSWORD" "${PWD_VAL}" "${IM_ENV}"
upsert_env "CLUSTER_ID" "${CLUSTER_ID_VAL:-cluster-a}" "${IM_ENV}"
# PRESENCE_URL 允许为空：upsert_env 会跳过空值，这里始终覆盖
awk -v k="PRESENCE_URL" -v v="${PRESENCE_URL_VAL}" '
  BEGIN { done=0 }
  $0 ~ ("^" k "=") { print k "=" v; done=1; next }
  { print }
  END { if (!done) print k "=" v }
' "${IM_ENV}" >"${IM_ENV}.tmp" && mv "${IM_ENV}.tmp" "${IM_ENV}"

echo "info: 已同步部署变量到 im .env"
echo "info:   mysql_source = ${DTALK_ENV_FILE}"
echo "info:   target = ${IM_ENV}"
echo "info:   MYSQL_ROOT_PASSWORD=*** (len=${#PWD_VAL})"
echo "info:   CLUSTER_ID=${CLUSTER_ID_VAL:-cluster-a}"
echo "info:   FEDERATION_ENABLED=${FED_EN:-false}"
echo "info:   PRESENCE_URL=${PRESENCE_URL_VAL:-<empty>}"
