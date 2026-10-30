#!/usr/bin/env bash
# 联邦模式：向 Presence 原子占用 Snowflake Node。
# 日志走 stderr。stdout 只有 CLUSTER_ID= 与 GENERATOR_NODE= 两行。
#
# 未指定 CLUSTER_ID 时生成 cluster-<节点号>-<8位十六进制>，并记住，重跑不换。
# 未指定节点时从 128～1023 用 /dev/urandom 抽取。
# PUT 返回 40901 就换一个再占，最多 20 次。自动集群号会连 ID 一起换。
# 占坑成功后用同一接口再查一次，generatorNode 一致才算可用。
# 该 clusterId 在 Presence 已有节点时复用，不再重新随机。
# stdout 两行：CLUSTER_ID=... 与 GENERATOR_NODE=...
set -euo pipefail

NODE_MIN=128
NODE_MAX=1023
NODE_SPAN=$((NODE_MAX - NODE_MIN + 1))
MAX_TRY=20

CLUSTER_ID="${CLUSTER_ID:-}"
CLUSTER_ID_SOURCE="${CLUSTER_ID_SOURCE:-default}"
PRESENCE_URL="${PRESENCE_URL:-}"
PRESENCE_URL="${PRESENCE_URL%/}"
GENERATOR_NODE_SOURCE="${GENERATOR_NODE_SOURCE:-default}"
PINNED="${GENERATOR_NODE:-}"
ROOT_DIR="${ROOT_DIR:-}"
AUTO_CLUSTER=0
if [[ "${CLUSTER_ID_SOURCE}" == "default" ]]; then
  AUTO_CLUSTER=1
fi

die() {
  echo "ERROR: $*" >&2
  exit 1
}

info() { echo "info: $*" >&2; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "未找到命令 '$1'"
}

random_node() {
  local raw
  raw="$(od -An -N4 -tu4 /dev/urandom | tr -d '[:space:]')"
  [[ "${raw}" =~ ^[0-9]+$ ]] || die "无法从 /dev/urandom 生成随机节点"
  echo $((NODE_MIN + raw % NODE_SPAN))
}

random_suffix() {
  local raw
  raw="$(od -An -N4 -tx1 /dev/urandom | tr -d '[:space:]' | tr 'A-F' 'a-f')"
  [[ "${raw}" =~ ^[0-9a-f]{8}$ ]] || die "无法从 /dev/urandom 生成集群随机串"
  printf '%s\n' "${raw}"
}

cluster_id_file() {
  echo "${ROOT_DIR}/.cluster-state/cluster-id"
}

read_auto_cluster() {
  local f
  f="$(cluster_id_file)"
  [[ -f "${f}" ]] || return 0
  tr -d '[:space:]' <"${f}"
}

write_auto_cluster() {
  local f dir
  f="$(cluster_id_file)"
  dir="$(dirname "${f}")"
  mkdir -p "${dir}"
  printf '%s\n' "${CLUSTER_ID}" >"${f}.tmp"
  mv "${f}.tmp" "${f}"
}

node_in_cluster_id() {
  local id="$1"
  if [[ "${id}" =~ ^cluster-([0-9]+)-[0-9a-f]{8}$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  fi
}

# 不能在 $(...) 里改 CLUSTER_ID：命令替换是子 shell。stdout 为「节点号 集群ID」。
mint_auto_cluster() {
  local node suffix
  node="$(random_node)"
  suffix="$(random_suffix)"
  printf '%s cluster-%s-%s\n' "${node}" "${node}" "${suffix}"
}

parse_alloc() {
  # stdin: JSON。stdout 三行：result、generatorNode、message
  python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception as e:
    sys.stderr.write("parse json: %s\n" % e)
    sys.exit(2)
data = d.get("data") or {}
node = data.get("generatorNode")
if node is None:
    node = ""
sys.stdout.write("%s\n%s\n%s\n" % (d.get("result", ""), node, d.get("message", "")))
'
}

state_file() {
  echo "${ROOT_DIR}/.cluster-state/${CLUSTER_ID}/generator-node"
}

read_state() {
  local f
  f="$(state_file)"
  [[ -f "${f}" ]] || return 0
  tr -d '[:space:]' <"${f}"
}

write_state() {
  local node="$1" f dir
  f="$(state_file)"
  dir="$(dirname "${f}")"
  mkdir -p "${dir}"
  printf '%s\n' "${node}" >"${f}.tmp"
  mv "${f}.tmp" "${f}"
}

put_node() {
  # put_node <candidate> <bodyfile>
  local candidate="$1" body="$2"
  curl -sS -o "${body}" -w '%{http_code}' \
    -X PUT "${PRESENCE_URL}/internal/clusters/${CLUSTER_ID}/generator-node" \
    -H 'Content-Type: application/json' \
    --max-time 15 \
    -d "{\"candidateNode\":${candidate}}"
}

verify_curl() {
  local node="$1"
  echo "curl -sS -X PUT '${PRESENCE_URL}/internal/clusters/${CLUSTER_ID}/generator-node' -H 'Content-Type: application/json' -d '{\"candidateNode\":${node}}'"
}

[[ -n "${PRESENCE_URL}" ]] || die "联邦模式必须提供 PRESENCE_URL，且当前机器要能访问该地址"
[[ -n "${ROOT_DIR}" ]] || die "ROOT_DIR 为空"
need_cmd curl
need_cmd python3
need_cmd od

if [[ "${GENERATOR_NODE_SOURCE}" != "default" ]]; then
  [[ "${PINNED}" =~ ^[0-9]+$ ]] || die "指定的 GENERATOR_NODE 不是整数: '${PINNED}'"
  if (( PINNED < 0 || PINNED > 1023 )); then
    die "指定的 GENERATOR_NODE=${PINNED} 超出 0～1023"
  fi
fi

if (( AUTO_CLUSTER == 1 )); then
  saved_id="$(read_auto_cluster || true)"
  if [[ "${saved_id}" =~ ^cluster-([0-9]+)-[0-9a-f]{8}$ ]]; then
    CLUSTER_ID="${saved_id}"
    info "沿用本机记录的 CLUSTER_ID=${CLUSTER_ID}"
  else
    CLUSTER_ID=""
  fi
else
  [[ "${CLUSTER_ID}" =~ ^[A-Za-z0-9._-]+$ ]] || die "CLUSTER_ID 无效: '${CLUSTER_ID}'"
fi

saved="$(read_state || true)"
body="$(mktemp)"
trap 'rm -f "${body}"' EXIT

try=1
while (( try <= MAX_TRY )); do
  candidate=""
  if (( AUTO_CLUSTER == 1 )) && [[ -z "${CLUSTER_ID}" ]]; then
    if [[ "${GENERATOR_NODE_SOURCE}" != "default" ]]; then
      CLUSTER_ID="cluster-${PINNED}-$(random_suffix)"
      candidate="${PINNED}"
    else
      pair="$(mint_auto_cluster)"
      candidate="${pair%% *}"
      CLUSTER_ID="${pair#* }"
    fi
    if (( try > 1 )); then
      info "节点被占用，改用 CLUSTER_ID=${CLUSTER_ID}（${try}/${MAX_TRY}）"
    else
      info "生成 CLUSTER_ID=${CLUSTER_ID}"
    fi
  elif (( try == 1 )) && [[ "${GENERATOR_NODE_SOURCE}" != "default" ]]; then
    candidate="${PINNED}"
  elif (( AUTO_CLUSTER == 1 )); then
    embedded="$(node_in_cluster_id "${CLUSTER_ID}")"
    if [[ "${embedded}" =~ ^[0-9]+$ ]]; then
      candidate="${embedded}"
      info "CLUSTER_ID 中的节点号为 ${candidate}，向 Presence 确认"
    else
      pair="$(mint_auto_cluster)"
      candidate="${pair%% *}"
      CLUSTER_ID="${pair#* }"
      info "生成 CLUSTER_ID=${CLUSTER_ID}"
    fi
  elif (( try == 1 )) && [[ "${saved}" =~ ^[0-9]+$ ]]; then
    candidate="${saved}"
    info "沿用本机记录的节点 ${candidate}，向 Presence 确认"
  else
    candidate="$(random_node)"
    if (( try > 1 )); then
      info "节点被占用，重新抽取 ${candidate}（${try}/${MAX_TRY}）"
    else
      info "抽取候选节点 ${candidate}（范围 ${NODE_MIN}～${NODE_MAX}）"
    fi
  fi

  set +e
  http="$(put_node "${candidate}" "${body}")"
  curl_rc=$?
  set -e
  if (( curl_rc != 0 )); then
    die "无法访问 Presence ${PRESENCE_URL}（curl 退出码 ${curl_rc}）。联邦初始化已停止，未继续编译"
  fi

  set +e
  parsed="$(parse_alloc <"${body}")"
  parse_rc=$?
  set -e
  if (( parse_rc != 0 )); then
    die "Presence 响应无法解析 HTTP ${http}: $(tr -d '\n' <"${body}" | head -c 400)"
  fi
  result="$(printf '%s\n' "${parsed}" | sed -n '1p')"
  got="$(printf '%s\n' "${parsed}" | sed -n '2p')"
  message="$(printf '%s\n' "${parsed}" | sed -n '3p')"

  if [[ "${http}" == "409" || "${result}" == "40901" ]]; then
    if [[ "${GENERATOR_NODE_SOURCE}" != "default" ]]; then
      die "指定节点 ${candidate} 已被其它集群占用。去掉 GENERATOR_NODE 后重跑 make init-compose，将在 ${NODE_MIN}～${NODE_MAX} 自动换一个空闲节点"
    fi
    info "候选 ${candidate} 不可用: HTTP ${http} result=${result} ${message}"
    if (( AUTO_CLUSTER == 1 )); then
      CLUSTER_ID=""
    fi
    try=$((try + 1))
    continue
  fi

  if [[ "${http}" == "404" || "${result}" == "40401" ]]; then
    if (( AUTO_CLUSTER == 1 )); then
      write_auto_cluster
      die "Presence 中还没有集群 ${CLUSTER_ID}。该 ID 已写入 $(cluster_id_file)，重跑不会重新随机。请先登记后再执行同一条 make init-compose：make migrate CLUSTER_ID=${CLUSTER_ID} BRIDGE_GRPC_ADDR=<本集群federation主机>:18060"
    fi
    die "Presence 中没有集群 ${CLUSTER_ID}。请先在 presence 登记集群（不必带 GENERATOR_NODE）：make migrate CLUSTER_ID=${CLUSTER_ID} BRIDGE_GRPC_ADDR=<本集群federation主机>:18060"
  fi

  if [[ "${http}" != "200" || "${result}" != "0" || ! "${got}" =~ ^[0-9]+$ ]]; then
    die "占坑失败 HTTP ${http} result=${result} message=${message} body=$(tr -d '\n' <"${body}" | head -c 400)"
  fi

  if [[ "${GENERATOR_NODE_SOURCE}" != "default" && "${got}" != "${PINNED}" ]]; then
    die "集群 ${CLUSTER_ID} 在 Presence 已占用节点 ${got}，与指定的 ${PINNED} 不一致。去掉 GENERATOR_NODE 后重跑将复用 ${got}"
  fi
  embedded_ok="$(node_in_cluster_id "${CLUSTER_ID}")"
  if (( AUTO_CLUSTER == 1 )) && [[ -n "${embedded_ok}" && "${got}" != "${embedded_ok}" ]]; then
    die "集群 ${CLUSTER_ID} 在 Presence 已占用节点 ${got}，与 ID 里的 ${embedded_ok} 不一致。删除 $(cluster_id_file) 后重跑会生成新的 CLUSTER_ID"
  fi

  info "占坑返回 generatorNode=${got}（${message}）。开始校验是否可用"
  info "$(verify_curl "${got}")"

  set +e
  vhttp="$(put_node "${got}" "${body}")"
  vrc=$?
  set -e
  if (( vrc != 0 )); then
    die "节点 ${got} 校验请求失败（curl 退出码 ${vrc}）。初始化已停止。重跑 make init-compose 会向 Presence 再确认该节点"
  fi
  set +e
  vparsed="$(parse_alloc <"${body}")"
  vparse=$?
  set -e
  if (( vparse != 0 )); then
    die "节点 ${got} 校验响应无法解析"
  fi
  vresult="$(printf '%s\n' "${vparsed}" | sed -n '1p')"
  vgot="$(printf '%s\n' "${vparsed}" | sed -n '2p')"
  if [[ "${vhttp}" != "200" || "${vresult}" != "0" || "${vgot}" != "${got}" ]]; then
    die "节点 ${got} 校验未通过 HTTP ${vhttp} result=${vresult} generatorNode=${vgot}。初始化已停止，未继续编译。重跑 make init-compose 会重新占坑"
  fi

  write_state "${got}"
  if (( AUTO_CLUSTER == 1 )); then
    write_auto_cluster
  fi
  info "节点 ${got} 可用，CLUSTER_ID=${CLUSTER_ID}，已写入 $(state_file)"
  printf 'CLUSTER_ID=%s\nGENERATOR_NODE=%s\n' "${CLUSTER_ID}" "${got}"
  exit 0
done

die "连续 ${MAX_TRY} 次占坑都被占用。重跑 make init-compose 会继续在 ${NODE_MIN}～${NODE_MAX} 抽取"
