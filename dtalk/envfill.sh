#!/bin/bash
# 根据 env_tmpl 生成 .env
# 可选 ./key（由 script/compose/key 复制而来）：MYSQL/MINIO 密码、FEDERATION_* / CLUSTER_ID / PRESENCE_URL / GENERATOR_NODE
# 无 key 时自动生成随机密码；联邦变量沿用环境变量或 env_tmpl 默认值
set -euo pipefail

work_dir=$(
  cd "$(dirname "$0")" || exit 1
  pwd
)

cd "${work_dir}" || exit 1

rand_password() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 16 | tr -d '\n'
    return 0
  fi
  if [[ -r /dev/urandom ]] && command -v base64 >/dev/null 2>&1; then
    head -c 18 /dev/urandom | base64 | tr -d '\n' | head -c 24
    return 0
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    # 最后兜底（熵较弱，仅用于无 openssl/urandom 环境）
    printf '%s:%s:%s' "$(date +%s%N 2>/dev/null || date +%s)" "$$" "$RANDOM" | sha256sum | awk '{print $1}' | head -c 24
    return 0
  fi
  echo "ERROR: 无法生成随机密码：请安装 openssl，或确保 /dev/urandom 可用" >&2
  exit 127
}

randomPassword() {
  MYSQL_ROOT_PASSWORD="$(rand_password)"
  MINIO_ROOT_PASSWORD="$(rand_password)"
  echo "info: 未找到 key 文件，已自动生成 MYSQL/MINIO 密码（写入 .env）" >&2
}

if [[ ! -f env_tmpl ]]; then
  echo "ERROR: 缺少 env_tmpl（当前目录: ${work_dir}）" >&2
  exit 1
fi

# 仅加载当前目录 ./key（避免 bash 在 PATH 中误找到同名文件）
# 兼容 Windows CRLF：直接 source 会报 $'\r': command not found
if [[ -f ./key ]]; then
  _key_tmp="$(mktemp)"
  tr -d '\r' <./key >"${_key_tmp}"
  # shellcheck disable=SC1090
  source "${_key_tmp}"
  rm -f "${_key_tmp}"
  echo "info: 已加载 ./key" >&2
else
  randomPassword
fi

# key 里密码可留空：表示仍自动生成
if [[ -z "${MYSQL_ROOT_PASSWORD:-}" ]]; then
  MYSQL_ROOT_PASSWORD="$(rand_password)"
  echo "info: MYSQL_ROOT_PASSWORD 为空，已自动生成" >&2
fi
if [[ -z "${MINIO_ROOT_PASSWORD:-}" ]]; then
  MINIO_ROOT_PASSWORD="$(rand_password)"
  echo "info: MINIO_ROOT_PASSWORD 为空，已自动生成" >&2
fi

if [[ -z "${MYSQL_ROOT_PASSWORD:-}" || -z "${MINIO_ROOT_PASSWORD:-}" ]]; then
  echo "ERROR: MYSQL_ROOT_PASSWORD / MINIO_ROOT_PASSWORD 为空" >&2
  exit 1
fi

eval "cat <<EOF
$(cat env_tmpl)
EOF
" >.env

echo "info: 已生成 ${work_dir}/.env"
