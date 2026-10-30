#!/usr/bin/env bash
# 幂等补跑联邦 MySQL 表（已有 txchat-mysql-data 时 initdb 不会再执行）。
# 用法:
#   make migrate-federation-mysql
#   bash script/compose/migrate-federation-mysql.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

die() { echo "ERROR: $*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "未找到命令 '$1'"; }
info() { echo "==> $*"; }
ok() { echo "✔ $*"; }

env_get() {
  local key="$1" file="$2" val
  val="$(grep -E "^${key}=" "${file}" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '\r' || true)"
  val="$(printf '%s' "${val}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  printf '%s' "${val}"
}

need_cmd bash
need_cmd docker

ENV_FILE="${ROOT_DIR}/run_compose/.env"
# 始终用仓库 script/mysql 为权威来源；run_compose 里常是旧版 init-compose 拷贝，勿优先
SQL_FULL="${ROOT_DIR}/script/mysql/dtalk_record_federation.sql"
SQL_MIRROR="${ROOT_DIR}/script/mysql/dtalk_record_federation_mirror.sql"

[[ -f "${SQL_FULL}" ]] || die "缺少 ${SQL_FULL}"

# 顺带刷新 run_compose 中的过期副本，避免下次手工执行踩旧文件
if [[ -d "${ROOT_DIR}/run_compose" ]]; then
  cp -f "${SQL_FULL}" "${ROOT_DIR}/run_compose/dtalk_record_federation.sql"
  if [[ -f "${SQL_MIRROR}" ]]; then
    cp -f "${SQL_MIRROR}" "${ROOT_DIR}/run_compose/dtalk_record_federation_mirror.sql"
  fi
fi

MYSQL_CONTAINER_NAME="txchat-mysql"
MYSQL_ROOT_PASSWORD=""
if [[ -f "${ENV_FILE}" ]]; then
  MYSQL_CONTAINER_NAME="$(env_get MYSQL_CONTAINER_NAME "${ENV_FILE}")"
  MYSQL_CONTAINER_NAME="${MYSQL_CONTAINER_NAME:-txchat-mysql}"
  MYSQL_ROOT_PASSWORD="$(env_get MYSQL_ROOT_PASSWORD "${ENV_FILE}")"
fi

# 容器环境变量与首次建库密码一致时更可靠
if PW_FROM_CTR="$(docker exec "${MYSQL_CONTAINER_NAME}" printenv MYSQL_ROOT_PASSWORD 2>/dev/null || true)"; then
  if [[ -n "${PW_FROM_CTR}" ]]; then
    MYSQL_ROOT_PASSWORD="${PW_FROM_CTR}"
  fi
fi
[[ -n "${MYSQL_ROOT_PASSWORD}" ]] || die "无法获取 MYSQL_ROOT_PASSWORD（检查 run_compose/.env 或容器环境）"

echo "┌ migrate-federation-mysql"
echo "│ container: ${MYSQL_CONTAINER_NAME}"
echo "│ sql: ${SQL_FULL}"
[[ -f "${SQL_MIRROR}" ]] && echo "│ mirror: ${SQL_MIRROR}"
echo "└"

docker ps --format '{{.Names}}' | grep -qx "${MYSQL_CONTAINER_NAME}" \
  || die "MySQL 容器未运行: ${MYSQL_CONTAINER_NAME}"

info "apply ${SQL_FULL}"
docker exec -i "${MYSQL_CONTAINER_NAME}" \
  mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" --default-character-set=utf8mb4 \
  <"${SQL_FULL}"
ok "full schema applied"

if [[ -f "${SQL_MIRROR}" ]]; then
  info "apply ${SQL_MIRROR}"
  docker exec -i "${MYSQL_CONTAINER_NAME}" \
    mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" --default-character-set=utf8mb4 \
    <"${SQL_MIRROR}"
  ok "mirror alter applied"
fi

info "verify tables"
docker exec -i "${MYSQL_CONTAINER_NAME}" \
  mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" --default-character-set=utf8mb4 -N -e \
  "SHOW TABLES FROM dtalk_record LIKE 'dtalk_federation%';"

ok "done（各联邦集群均需执行一次）"
