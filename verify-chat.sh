#!/bin/sh
# 用 sh 调用时先交给 bash。dash 不支持 pipefail。
if [ -z "${BASH_VERSION-}" ]; then
  if command -v bash >/dev/null 2>&1; then
    exec bash "$0" "$@"
  fi
  printf 'ERROR: 需要 bash\n' >&2
  exit 1
fi

# 下载 im-util，用 pressure 的 pre 发私聊，再用 ana 统计发送、接收和回执。
# 入口是 Nginx 的 host:port。pressure 原本连接 /sub，这里改成 /sub/，由 Nginx 转到 comet 的 /sub。
set -euo pipefail

ROOT=$(
  cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
  pwd
)

SERVER="${SERVER:-127.0.0.1:8888}"
USERS="${USERS:-${ROOT}/users.txt}"
TIMEOUT="${TIMEOUT:-20}"
IM_UTIL_REPO="${IM_UTIL_REPO:-https://github.com/txchat/im-util.git}"
IM_UTIL_REF="${IM_UTIL_REF:-v0.1.0}"

info() {
  printf 'info: %s\n' "$*"
}

error() {
  printf 'ERROR: %s\n' "$*" >&2
}

for cmd in git go awk; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    error "未找到 ${cmd}"
    exit 1
  fi
done

case "$TIMEOUT" in
  *s|*m|*h) duration="$TIMEOUT" ;;
  *) duration="${TIMEOUT}s" ;;
esac

server="${SERVER#ws://}"
server="${server#http://}"
server="${server%/sub/}"
server="${server%/sub}"
server="${server%/}"

work=$(mktemp -d "${TMPDIR:-/tmp}/txchat-verify.XXXXXX")
ok=0
cleanup() {
  if [ "$ok" = 1 ]; then
    rm -rf "$work"
  else
    error "日志留在 ${work}"
  fi
}
trap cleanup EXIT

info "临时目录 ${work}"
info "下载 ${IM_UTIL_REPO} ${IM_UTIL_REF}"
if ! git clone --depth 1 --branch "$IM_UTIL_REF" "$IM_UTIL_REPO" "$work/im-util"; then
  error "下载 im-util 失败。可设置 IM_UTIL_REPO 和 IM_UTIL_REF"
  exit 1
fi

client="$work/im-util/pkg/net/ws/client.go"
if [ ! -f "$client" ]; then
  error "下载的代码里没有 ${client}"
  exit 1
fi
awk '
  BEGIN {
    key = "server + \"/sub\""
    repl = "server + \"/sub/\""
  }
  {
    n = index($0, key)
    if (n > 0 && index($0, repl) == 0) {
      $0 = substr($0, 1, n - 1) repl substr($0, n + length(key))
    }
    print
  }
' "$client" > "$client.tmp"
mv "$client.tmp" "$client"
if ! grep -q 'server + "/sub/"' "$client"; then
  error "没有把 WebSocket 路径改成 /sub/"
  exit 1
fi

info "编译 pressure"
(
  cd "$work/im-util"
  go build -o "$work/pressure" ./pressure
)

if [ ! -f "$USERS" ]; then
  info "没有用户文件，生成两个账号: ${USERS}"
  (
    cd "$work/im-util"
    go run ./protocol wallet gen -n 2 -w "$USERS" --ws ','
  )
  info "users.txt 含私钥，不要提交"
fi

info "pressure 连接 ${server}，持续 ${duration}。结束后工具还会再等 30 秒收消息"
(
  cd "$work/im-util"
  "$work/pressure" pre \
    -u 2 \
    -s "$server" \
    -a dtalk \
    -i "$USERS" \
    -t "$duration" \
    -r 1/s \
    -o "$work/pressure_output.txt"
) >"$work/pre.log" 2>&1 || {
  error "pressure pre 失败，见 ${work}/pre.log"
  exit 1
}

info "分析发送、接收和回执"
(
  cd "$work/im-util"
  "$work/pressure" ana \
    -i "$work/pressure_output.txt" \
    -o "$work/analyze_output.txt"
) >"$work/ana.log" 2>&1 || {
  error "pressure ana 失败，见 ${work}/ana.log"
  exit 1
}

line=$(grep 'message tranport success count:' "$work/ana.log" | tail -n 1 || true)
success=$(printf '%s\n' "$line" | sed -n 's/.*message tranport success count: \([0-9][0-9]*\).*/\1/p')
failed=$(printf '%s\n' "$line" | sed -n 's/.*failed count: \([0-9][0-9]*\).*/\1/p')
if [ -z "$success" ]; then
  error "没有读到 pressure 的统计结果，见 ${work}/ana.log"
  exit 1
fi
info "收发完成 success=${success} failed=${failed}"
if [ "$success" -lt 1 ]; then
  error "没有一条消息同时完成发送、接收和回执"
  exit 1
fi
ok=1
