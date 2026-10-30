#!/usr/bin/env bash
# 将全局 CLUSTER_ID / PRESENCE_URL / GENERATOR_NODE 写入各模块 toml
# 用法:
#   CLUSTER_ID=cluster-a PRESENCE_URL=http://txchat-presence:18050 GENERATOR_NODE=1 \
#     bash apply-federation-config.sh [target_dir]
#
# target_dir 默认: <dtalk>/target
# 若存在 ../im/target/logic.toml，一并写入（Presence 上报）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TARGET_DIR="${1:-${ROOT_DIR}/target}"

CLUSTER_ID="${CLUSTER_ID:-cluster-a}"
GENERATOR_NODE="${GENERATOR_NODE:-1}"
FEDERATION_ENABLED="${FEDERATION_ENABLED:-false}"
# 未明确开启联邦时不写入 Presence 地址，避免各模块配置里留下可连通的联邦入口
if [[ "${FEDERATION_ENABLED}" == "true" ]]; then
  PRESENCE_URL="${PRESENCE_URL:-http://txchat-presence:18050}"
else
  PRESENCE_URL=""
fi

# 去掉 Windows CRLF / 意外换行，避免写入 toml 后服务 panic
strip_ws() { printf '%s' "$1" | tr -d '\r\n'; }
CLUSTER_ID="$(strip_ws "${CLUSTER_ID}")"
PRESENCE_URL="$(strip_ws "${PRESENCE_URL}")"
GENERATOR_NODE="$(strip_ws "${GENERATOR_NODE}")"
FEDERATION_ENABLED="$(strip_ws "${FEDERATION_ENABLED}")"

die() { echo "ERROR: $*" >&2; exit 1; }

# 用 awk 原地改 toml，避免 sed 分隔符被 http:// 等 URL 弄坏
replace_file() {
  local file="$1"
  local tmp="${file}.tmp.$$"
  cat >"${tmp}" && mv "${tmp}" "${file}"
}

set_kv_quoted() {
  # set_kv_quoted <file> <key> <value>
  # 匹配: key = "..."（值可含 / : 等任意字符）
  local file="$1" key="$2" val="$3"
  [[ -f "${file}" ]] || return 0
  grep -qE "^[[:space:]]*${key}[[:space:]]*=" "${file}" || return 0
  awk -v key="${key}" -v val="${val}" '
    BEGIN { re = "^[[:space:]]*" key "[[:space:]]*=" }
    $0 ~ re {
      sub(/=.*/, "")
      sub(/[[:space:]]+$/, "")
      print $0 " = \"" val "\""
      next
    }
    { print }
  ' "${file}" | replace_file "${file}"
}

set_node() {
  local file="$1" node="$2"
  [[ -f "${file}" ]] || return 0
  grep -qE '^[[:space:]]*Node[[:space:]]*=' "${file}" || return 0
  awk -v node="${node}" '
    /^[[:space:]]*Node[[:space:]]*=/ {
      sub(/=.*/, "")
      sub(/[[:space:]]+$/, "")
      print $0 " = " node
      next
    }
    { print }
  ' "${file}" | replace_file "${file}"
}

set_bool_kv() {
  local file="$1" key="$2" val="$3"
  [[ -f "${file}" ]] || return 0
  grep -qE "^[[:space:]]*${key}[[:space:]]*=" "${file}" || return 0
  awk -v key="${key}" -v val="${val}" '
    BEGIN { re = "^[[:space:]]*" key "[[:space:]]*=" }
    $0 ~ re {
      sub(/=.*/, "")
      sub(/[[:space:]]+$/, "")
      print $0 " = " val
      next
    }
    { print }
  ' "${file}" | replace_file "${file}"
}

fed_enabled_toml() {
  if [[ "${FEDERATION_ENABLED}" == "true" ]]; then
    echo "true"
  else
    echo "false"
  fi
}

ensure_gateway_federation() {
  local file="$1"
  local en
  en="$(fed_enabled_toml)"
  [[ -f "${file}" ]] || return 0
  if grep -qE '^[[:space:]]*\[federation\]' "${file}"; then
    set_kv_quoted "${file}" "clusterId" "${CLUSTER_ID}"
    set_kv_quoted "${file}" "presenceUrl" "${PRESENCE_URL}"
    set_kv_quoted "${file}" "mysqlPwd" '${MYSQL_PASSWORD}'
    # gateway [federation] 段内第一个 enabled
    awk -v en="${en}" '
      BEGIN{in_fed=0}
      /^[[:space:]]*\[federation\]/{in_fed=1; print; next}
      /^[[:space:]]*\[/{in_fed=0}
      in_fed && /^[[:space:]]*enabled[[:space:]]*=/{sub(/=.*/, "= " en); print; next}
      {print}
    ' "${file}" >"${file}.tmp" && mv "${file}.tmp" "${file}"
    return 0
  fi
  cat >>"${file}" <<EOF

# 跨集群联邦（由 apply-federation-config 自动补齐）
[federation]
    enabled = ${en}
    clusterId = "${CLUSTER_ID}"
    presenceUrl = "${PRESENCE_URL}"
    presenceTimeout = "2s"
    mysqlHost = "txchat-mysql"
    mysqlPort = "3306"
    mysqlUser = "root"
    mysqlPwd = "\${MYSQL_PASSWORD}"
    mysqlDb = "dtalk_record"
    rpcTimeout = "2s"
EOF
}

[[ -d "${TARGET_DIR}" ]] || die "target 目录不存在: ${TARGET_DIR}（请先编译）"

echo "info: apply federation globals → ${TARGET_DIR}"
echo "info:   FEDERATION_ENABLED=${FEDERATION_ENABLED}"
echo "info:   CLUSTER_ID=${CLUSTER_ID}"
echo "info:   PRESENCE_URL=${PRESENCE_URL}"
echo "info:   GENERATOR_NODE=${GENERATOR_NODE}"

FED_EN="$(fed_enabled_toml)"

# federation.toml：顶层 clusterId/enabled + [presence].url
if [[ -f "${TARGET_DIR}/federation.toml" ]]; then
  set_kv_quoted "${TARGET_DIR}/federation.toml" "clusterId" "${CLUSTER_ID}"
  set_kv_quoted "${TARGET_DIR}/federation.toml" "url" "${PRESENCE_URL}"
  set_bool_kv "${TARGET_DIR}/federation.toml" "enabled" "${FED_EN}"
fi

# pusher.toml：[federation]
if [[ -f "${TARGET_DIR}/pusher.toml" ]]; then
  set_kv_quoted "${TARGET_DIR}/pusher.toml" "clusterId" "${CLUSTER_ID}"
  set_kv_quoted "${TARGET_DIR}/pusher.toml" "presenceUrl" "${PRESENCE_URL}"
  set_kv_quoted "${TARGET_DIR}/pusher.toml" "mysqlPwd" '${MYSQL_PASSWORD}'
  awk -v en="${FED_EN}" '
    BEGIN{in_fed=0}
    /^[[:space:]]*\[federation\]/{in_fed=1; print; next}
    /^[[:space:]]*\[/{in_fed=0}
    in_fed && /^[[:space:]]*enabled[[:space:]]*=/{sub(/=.*/, "= " en); print; next}
    {print}
  ' "${TARGET_DIR}/pusher.toml" >"${TARGET_DIR}/pusher.toml.tmp" && mv "${TARGET_DIR}/pusher.toml.tmp" "${TARGET_DIR}/pusher.toml"
fi

# gateway.toml
ensure_gateway_federation "${TARGET_DIR}/gateway.toml"

# generator.toml
set_node "${TARGET_DIR}/generator.toml" "${GENERATOR_NODE}"

# im/logic.toml：写入环境变量占位（运行时由 im compose 从 .env 注入）
IM_LOGIC_TOML="$(cd "${ROOT_DIR}/.." && pwd)/im/target/logic.toml"
if [[ -f "${IM_LOGIC_TOML}" ]] && grep -qE '^[[:space:]]*clusterId[[:space:]]*=' "${IM_LOGIC_TOML}"; then
  set_kv_quoted "${IM_LOGIC_TOML}" "clusterId" '${CLUSTER_ID}'
  set_kv_quoted "${IM_LOGIC_TOML}" "url" '${PRESENCE_URL}'
  echo "info:   also patched ${IM_LOGIC_TOML} → \${PRESENCE_URL}/\${CLUSTER_ID}"
fi

echo "info: apply-federation-config done"
