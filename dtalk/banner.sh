#!/bin/bash
# init-compose 完成后的炫酷收尾输出
set -euo pipefail

VERSION="${1:-unknown}"
COMMIT="${2:-unknown}"
SERVERS="${3:-}"

if [[ -t 1 ]]; then
  C_CYAN=$'\033[38;5;51m'
  C_GREEN=$'\033[38;5;46m'
  C_YELLOW=$'\033[38;5;226m'
  C_DIM=$'\033[2m'
  C_BOLD=$'\033[1m'
  C_RESET=$'\033[0m'
else
  C_CYAN="" C_GREEN="" C_YELLOW="" C_DIM="" C_BOLD="" C_RESET=""
fi

count_servers() {
  # shellcheck disable=SC2086
  set -- ${SERVERS}
  echo "$#"
}

SERVER_COUNT="$(count_servers)"
NOW="$(date '+%Y-%m-%d %H:%M:%S %z')"

cat <<EOF
${C_CYAN}
    ██████╗ ████████╗ █████╗ ██╗     ██╗  ██╗
    ██╔══██╗╚══██╔══╝██╔══██╗██║     ██║ ██╔╝
    ██║  ██║   ██║   ███████║██║     █████╔╝
    ██║  ██║   ██║   ██╔══██║██║     ██╔═██╗
    ██████╔╝   ██║   ██║  ██║███████╗██║  ██╗
    ╚═════╝    ╚═╝   ╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝
${C_DIM}                         power by bigsea${C_RESET}
${C_GREEN}
        ▄︻デ══━一  INIT-COMPOSE COMPLETE  一━══デ︻▄
${C_RESET}
${C_BOLD}┌─ Mission Report ─────────────────────────────────────────${C_RESET}
${C_GREEN}✔${C_RESET} 交叉编译 linux/amd64 服务二进制 → ${C_DIM}target/${C_RESET}
${C_GREEN}✔${C_RESET} 构建 Docker 镜像（版本 ${C_YELLOW}${VERSION}${C_RESET}）
${C_GREEN}✔${C_RESET} 生成 compose 工作目录 → ${C_DIM}run_compose/${C_RESET}
${C_GREEN}✔${C_RESET} 写入环境变量 → ${C_DIM}run_compose/.env${C_RESET}
${C_GREEN}✔${C_RESET} 初始化 Docker volume / network / MySQL SQL / Nginx
${C_BOLD}├─ Build Info ─────────────────────────────────────────────${C_RESET}
   version : ${C_YELLOW}${VERSION}${C_RESET}
   commit  : ${C_DIM}${COMMIT}${C_RESET}
   servers : ${C_CYAN}${SERVER_COUNT}${C_RESET}  (${C_DIM}${SERVERS}${C_RESET})
   time    : ${C_DIM}${NOW}${C_RESET}
${C_BOLD}├─ Federation Globals ─────────────────────────────────────${C_RESET}
   CLUSTER_ID      : ${C_YELLOW}${CLUSTER_ID:-cluster-a}${C_RESET}
   PRESENCE_URL    : ${C_DIM}${PRESENCE_URL:-http://txchat-presence:18050}${C_RESET}
   GENERATOR_NODE  : ${C_YELLOW}${GENERATOR_NODE:-1}${C_RESET}
${C_BOLD}├─ Next Commands ──────────────────────────────────────────${C_RESET}
   ${C_CYAN}make docker-compose-up${C_RESET}     # 启动全部组件与服务
   ${C_CYAN}make docker-compose-ps${C_RESET}     # 查看运行状态
   ${C_CYAN}make check-federation${C_RESET}      # 校验 clusterId / presenceUrl 一致性
   ${C_CYAN}make migrate-federation-mysql${C_RESET} # 已有库补建联邦表（幂等）
   ${C_DIM}# 请妥善备份 run_compose/.env（含 MYSQL_ROOT_PASSWORD / CLUSTER_ID）${C_RESET}
${C_BOLD}└──────────────────────────────────────────────────────────${C_RESET}

${C_GREEN}${C_BOLD}★ dtalk 已就绪，发射倒计时结束。Good luck, commander.${C_RESET}

EOF
