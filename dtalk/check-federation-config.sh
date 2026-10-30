#!/usr/bin/env bash
# 校验联邦相关配置：clusterId / presenceUrl / generator Node 是否与全局一致
# 用法:
#   bash check-federation-config.sh
#   bash check-federation-config.sh /path/to/dtalk
#
# 期望值来源（优先级从高到低）:
#   1) 环境变量 CLUSTER_ID / PRESENCE_URL / GENERATOR_NODE
#   2) run_compose/.env
#   3) 默认值 cluster-a / http://txchat-presence:18050 / 1
#
# 检查文件（优先 target/，否则源码树）:
#   federation.toml / pusher.toml / gateway.toml / generator.toml
#   以及同级 im/logic/conf/logic.toml 或 im/target/logic.toml
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${1:-${SCRIPT_DIR}/../..}" && pwd)"
ENV_FILE="${ROOT_DIR}/run_compose/.env"

errors=0
warns=0

if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'; C_GREEN=$'\033[32m'; C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
else
  C_RED=""; C_YELLOW=""; C_GREEN=""; C_DIM=""; C_RESET=""
fi

env_get() {
  local key="$1" file="$2"
  [[ -f "${file}" ]] || return 0
  grep -E "^${key}=" "${file}" | head -n1 | cut -d= -f2- | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true
}

toml_get() {
  # toml_get <file> <key>  → 取第一个 key = "value" 或 key=value
  local file="$1" key="$2"
  [[ -f "${file}" ]] || return 0
  local line
  line="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "${file}" | head -n1 | tr -d '\r' || true)"
  [[ -n "${line}" ]] || return 0
  # 去掉 key=
  line="${line#*=}"
  line="$(printf '%s' "${line}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^"//;s/"$//')"
  printf '%s' "${line}"
}

pick_file() {
  # pick_file <name.toml> <src_path>
  local name="$1" src="$2"
  if [[ -f "${ROOT_DIR}/target/${name}" ]]; then
    echo "${ROOT_DIR}/target/${name}"
  elif [[ -f "${src}" ]]; then
    echo "${src}"
  else
    echo ""
  fi
}

expect() {
  local label="$1" got="$2" want="$3"
  if [[ "${got}" == "${want}" ]]; then
    echo "  ${C_GREEN}✔${C_RESET} ${label}: ${C_DIM}${got}${C_RESET}"
  else
    echo "  ${C_RED}✘${C_RESET} ${label}: got='${got}' want='${want}'"
    errors=$((errors + 1))
  fi
}

warn() {
  echo "  ${C_YELLOW}!${C_RESET} $*"
  warns=$((warns + 1))
}

info() { echo "${C_DIM}$*${C_RESET}"; }

# ---- resolve expected ----
CLUSTER_ID="${CLUSTER_ID:-$(env_get CLUSTER_ID "${ENV_FILE}")}"
PRESENCE_URL="${PRESENCE_URL:-$(env_get PRESENCE_URL "${ENV_FILE}")}"
GENERATOR_NODE="${GENERATOR_NODE:-$(env_get GENERATOR_NODE "${ENV_FILE}")}"
CLUSTER_ID="${CLUSTER_ID:-cluster-a}"
PRESENCE_URL="${PRESENCE_URL:-http://txchat-presence:18050}"
GENERATOR_NODE="${GENERATOR_NODE:-1}"

echo "┌ check-federation-config"
echo "│ root: ${ROOT_DIR}"
if [[ -f "${ENV_FILE}" ]]; then
  echo "│ env : ${ENV_FILE}"
else
  warn "未找到 run_compose/.env，使用默认/环境变量期望值（建议先 make init-compose）"
fi
echo "│ expect CLUSTER_ID=${CLUSTER_ID}"
echo "│ expect PRESENCE_URL=${PRESENCE_URL}"
echo "│ expect GENERATOR_NODE=${GENERATOR_NODE}"
echo "└"

# ---- federation ----
fed="$(pick_file federation.toml "${ROOT_DIR}/service/federation/config/federation.toml")"
if [[ -n "${fed}" ]]; then
  echo "▸ federation (${fed})"
  expect "clusterId" "$(toml_get "${fed}" clusterId)" "${CLUSTER_ID}"
  expect "presence.url" "$(toml_get "${fed}" url)" "${PRESENCE_URL}"
  enabled="$(toml_get "${fed}" enabled)"
  if [[ "${enabled}" != "true" ]]; then
    warn "federation.enabled=${enabled:-?}（跨集群入站/outbox 需为 true）"
  fi
else
  warn "未找到 federation.toml"
fi

# ---- pusher ----
pusher="$(pick_file pusher.toml "${ROOT_DIR}/service/record/pusher/config/pusher.toml")"
if [[ -n "${pusher}" ]]; then
  echo "▸ pusher (${pusher})"
  expect "federation.clusterId" "$(toml_get "${pusher}" clusterId)" "${CLUSTER_ID}"
  expect "federation.presenceUrl" "$(toml_get "${pusher}" presenceUrl)" "${PRESENCE_URL}"
  enabled="$(toml_get "${pusher}" enabled)"
  # pusher 文件里第一个 enabled 可能不是 federation（OffPush.IsEnabled 等）
  # 更精确：取 [federation] 段后的 enabled
  fed_enabled="$(awk '
    /^[[:space:]]*\[federation\]/ {in_fed=1; next}
    /^[[:space:]]*\[/ {in_fed=0}
    in_fed && /^[[:space:]]*enabled[[:space:]]*=/ {
      gsub(/[[:space:]]/,""); sub(/enabled=/,""); gsub(/"/,""); print; exit
    }
  ' "${pusher}" || true)"
  if [[ "${fed_enabled}" == "true" ]]; then
    info "  federation.enabled=true（出站已开）"
  else
    warn "pusher [federation].enabled=${fed_enabled:-false}（跨集群出站需为 true）"
  fi
else
  warn "未找到 pusher.toml"
fi

# ---- gateway ----
gw="$(pick_file gateway.toml "${ROOT_DIR}/gateway/api/v1/etc/gateway.toml")"
if [[ -n "${gw}" ]]; then
  echo "▸ gateway (${gw})"
  if grep -qE '^[[:space:]]*\[federation\]' "${gw}"; then
    expect "federation.clusterId" "$(toml_get "${gw}" clusterId)" "${CLUSTER_ID}"
    expect "federation.presenceUrl" "$(toml_get "${gw}" presenceUrl)" "${PRESENCE_URL}"
  else
    warn "gateway.toml 缺少 [federation] 段（撤回跨集群同步不可用；可 make apply-federation 补齐）"
  fi
else
  warn "未找到 gateway.toml"
fi

# ---- generator ----
gen="$(pick_file generator.toml "${ROOT_DIR}/service/generator/config/generator.toml")"
if [[ -n "${gen}" ]]; then
  echo "▸ generator (${gen})"
  expect "Node" "$(toml_get "${gen}" Node)" "${GENERATOR_NODE}"
else
  warn "未找到 generator.toml"
fi

# ---- im logic ----
im_root="$(cd "${ROOT_DIR}/.." && pwd)/im"
logic=""
logic_target="${im_root}/target/logic.toml"
logic_src="${im_root}/logic/conf/logic.toml"
if [[ -f "${logic_target}" ]] && grep -qE '^[[:space:]]*clusterId[[:space:]]*=' "${logic_target}"; then
  logic="${logic_target}"
elif [[ -f "${logic_src}" ]]; then
  logic="${logic_src}"
elif [[ -f "${logic_target}" ]]; then
  logic="${logic_target}"
fi
if [[ -n "${logic}" ]]; then
  echo "▸ im/logic (${logic})"
  expect "presence.clusterId" "$(toml_get "${logic}" clusterId)" "${CLUSTER_ID}"
  logic_url="$(toml_get "${logic}" url)"
  if [[ -z "${logic_url}" ]]; then
    warn "logic [presence].url 为空 → Presence 上报已禁用"
  else
    expect "presence.url" "${logic_url}" "${PRESENCE_URL}"
  fi
else
  warn "未找到 im/logic.toml（若 im 与 dtalk 同级部署，请先在 im 侧 init-compose）"
fi

# ---- cross consistency: all clusterIds equal among found files ----
echo "▸ cross-check"
ids=()
for f in "${fed}" "${pusher}" "${gw}" "${logic}"; do
  [[ -n "${f}" && -f "${f}" ]] || continue
  id="$(toml_get "${f}" clusterId)"
  [[ -n "${id}" ]] && ids+=("${id}")
done
uniq_ids="$(printf '%s\n' "${ids[@]:-}" | awk 'NF' | sort -u)"
uniq_count="$(printf '%s\n' "${uniq_ids}" | awk 'NF' | wc -l | tr -d ' ')"
if [[ "${uniq_count}" -gt 1 ]]; then
  echo "  ${C_RED}✘${C_RESET} 多处 clusterId 不一致:"
  printf '%s\n' "${uniq_ids}" | while read -r line; do echo "      - ${line}"; done
  errors=$((errors + 1))
else
  echo "  ${C_GREEN}✔${C_RESET} 各模块 clusterId 一致: ${C_DIM}${uniq_ids:-none}${C_RESET}"
fi

echo
if [[ "${errors}" -gt 0 ]]; then
  echo "${C_RED}FAIL${C_RESET}: ${errors} error(s), ${warns} warning(s)"
  echo "修复: make apply-federation CLUSTER_ID=${CLUSTER_ID} PRESENCE_URL=${PRESENCE_URL} GENERATOR_NODE=${GENERATOR_NODE}"
  exit 1
fi
echo "${C_GREEN}OK${C_RESET}: federation config consistent (${warns} warning(s))"
exit 0
