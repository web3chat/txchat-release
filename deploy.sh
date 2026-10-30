#!/usr/bin/env bash
# 单集群一键部署。步骤与手动部署.md 相同：加载镜像、初始化 dtalk、im 与 square、
# 首次把 toml 拷进空配置卷、先启动 MySQL，再启动 im，再启动 square，最后启动 dtalk。
# dtalk 的 Nginx 要解析 txchat-square，广场必须先于 dtalk 启动。
# 再次执行不会重新生成密码，也不会覆盖已有 toml 或已改过的镜像标签。
set -euo pipefail

ROOT=$(
  cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
  pwd
)
REPO="${TXCHAT_RELEASE_REPO:-web3chat/txchat-release}"

DTALK_SERVICES="answer backend backup call device discovery gateway generator group offline-push oss pusher store chatclean chatadmin"
IM_SERVICES="comet logic"

DOWNLOAD=0
IMAGES_DIR=""
RELEASE=""
SKIP_SEED=0
FORCE_SEED=0
REINIT=0
DOWN=0
PURGE=0
RESET_SQUARE_PG=0
UPGRADE=0

MYSQL_WAIT_SECONDS=600
PING_WAIT_SECONDS=180
COMPOSE_DOWNLOAD_URL="https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64"

info() {
  printf 'info: %s\n' "$*"
}

error() {
  printf 'ERROR: %s\n' "$*" >&2
}

usage() {
  cat <<'EOF'
用法: bash ./deploy.sh [选项]

按 README 部署单集群。已有 dtalk/.env、square/.env 时不会重写已有密码。
卷和 toml 已存在时不会重跑 initwork.sh，也不会覆盖配置。
没有 docker compose 时会自动安装 Compose v2。

选项:
  --download            用 gh 下载 bundle-<dtalk/IMAGE_TAG> 并 docker load
                        这一份里每个业务模块一个 tar；中间件部署时在线拉取
  --images-dir DIR      加载该目录下的 .tar（docker save 的产物）
  --release NAME        配合 --download，替换要下载的 Release 名
                        默认 bundle-<dtalk/IMAGE_TAG>
  --skip-seed           不把镜像里的 toml 拷进配置卷
  --force-seed          用镜像里的 toml 覆盖已有配置卷
  --reinit              卷缺失且镜像标签已手改时，仍执行 initwork.sh
                        这会把 .env 里的业务镜像标签写回 IMAGE_TAG
  --down                停止并删除 dtalk、im、square 的全部容器
                        保留数据卷、配置卷、.env 和镜像
  --purge               删除这些容器，以及本机由下载加载的全部镜像
                        含 /tmp/txchat-images 里的 tar。不留 txchat 镜像
                        保留数据卷、配置卷和 .env
  --reset-square-pg     删除广场 PostgreSQL 数据卷，并停掉广场容器
                        只动 square-pg-data。MySQL、.env 和镜像保留
                        下次 bash ./deploy.sh 会按当前 .env 重建库和运营台账号
  --upgrade             对照 GitHub Release，升级有新标签的业务模块
                        只改对应 .env 镜像标签并重建该容器
                        不重跑 initwork，不更换 MySQL、Kafka、Redis 等中间件
  -h, --help            显示本说明

镜像已经 docker load 过时，直接 bash ./deploy.sh。
单模块升级用 --upgrade。要手工只重建一个容器，看手动部署.md。
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --download)
        DOWNLOAD=1
        ;;
      --images-dir)
        shift
        IMAGES_DIR="${1:-}"
        if [[ -z "$IMAGES_DIR" ]]; then
          error "--images-dir 需要目录路径"
          exit 1
        fi
        ;;
      --release)
        shift
        RELEASE="${1:-}"
        if [[ -z "$RELEASE" ]]; then
          error "--release 需要 Release 名称"
          exit 1
        fi
        ;;
      --skip-seed)
        SKIP_SEED=1
        ;;
      --force-seed)
        FORCE_SEED=1
        ;;
      --reinit)
        REINIT=1
        ;;
      --down)
        DOWN=1
        ;;
      --purge)
        PURGE=1
        ;;
      --reset-square-pg)
        RESET_SQUARE_PG=1
        ;;
      --upgrade)
        UPGRADE=1
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        error "未知参数: $1"
        usage >&2
        exit 1
        ;;
    esac
    shift
  done

  if [[ "$SKIP_SEED" -eq 1 && "$FORCE_SEED" -eq 1 ]]; then
    error "--skip-seed 与 --force-seed 不能同时使用"
    exit 1
  fi
  local solo=0
  [[ "$DOWN" -eq 1 ]] && solo=$((solo + 1))
  [[ "$PURGE" -eq 1 ]] && solo=$((solo + 1))
  [[ "$RESET_SQUARE_PG" -eq 1 ]] && solo=$((solo + 1))
  [[ "$UPGRADE" -eq 1 ]] && solo=$((solo + 1))
  if [[ "$solo" -gt 1 ]]; then
    error "--down、--purge、--reset-square-pg、--upgrade 只能单独使用"
    exit 1
  fi
  if [[ "$solo" -eq 1 && ( "$DOWNLOAD" -eq 1 || -n "$IMAGES_DIR" || "$SKIP_SEED" -eq 1 || "$FORCE_SEED" -eq 1 || "$REINIT" -eq 1 || -n "$RELEASE" ) ]]; then
    error "--down、--purge、--reset-square-pg、--upgrade 不能和部署选项一起用"
    exit 1
  fi
}

read_tag() {
  local file="$1" tag
  if [[ ! -f "$file" ]]; then
    error "缺少标签文件: ${file}"
    exit 1
  fi
  tag=$(tr -d '[:space:]' <"$file")
  if [[ -z "$tag" ]]; then
    error "标签文件为空: ${file}"
    exit 1
  fi
  printf '%s' "$tag"
}

env_get() {
  local key="$1" file="$2" line
  if [[ ! -f "$file" ]]; then
    error "找不到环境文件: ${file}"
    return 1
  fi
  line=$(grep -E "^${key}=" "$file" | head -n 1 || true)
  line=${line#*=}
  printf '%s' "$line" | tr -d '\r\n'
}

write_env_key() {
  local file="$1" key="$2" val="$3"
  awk -v k="${key}" -v v="${val}" '
    BEGIN { done=0 }
    $0 ~ ("^" k "=") { print k "=" v; done=1; next }
    { print }
    END { if (!done) print k "=" v }
  ' "$file" >"${file}.tmp" && mv "${file}.tmp" "$file"
}

ensure_image_tag() {
  local file="$1" key="$2" tag="$3" current
  current=$(env_get "$key" "$file" || true)
  if [[ -n "$current" && "$current" != "v0.0.0" ]]; then
    return 0
  fi
  info "写入 ${key}=${tag}，文件 ${file}，原值 ${current:-<empty>}"
  write_env_key "$file" "$key" "$tag"
}

ensure_service_images() {
  local file="$1" tag="$2" name key
  shift 2
  for name in "$@"; do
    key=$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]' | tr '-' '_')
    ensure_image_tag "$file" "${key}_IMAGE" "$tag"
  done
}

# 已有 .env 时不整文件覆盖。模板里有值、目标为空或缺少该行时才补上。
fill_missing_env() {
  local dest="$1" example="$2" line key val current
  if [[ ! -f "$dest" || ! -f "$example" ]]; then
    error "无法补齐环境文件: dest=${dest} example=${example}"
    return 1
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line%$'\r'}
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "$line" != *=* ]] && continue
    key=${line%%=*}
    val=${line#*=}
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    [[ -z "$val" ]] && continue
    current=$(env_get "$key" "$dest" || true)
    [[ -n "$current" ]] && continue
    info "补齐空配置 ${key}，来源 ${example}"
    write_env_key "$dest" "$key" "$val"
  done <"$example"
}

check_platform() {
  local os arch
  os=$(uname -s)
  arch=$(uname -m)
  if [[ "$os" != "Linux" || "$arch" != "x86_64" ]]; then
    error "镜像是 linux/amd64。当前系统是 ${os} ${arch}，请在 x86_64 Linux 上执行"
    exit 1
  fi
}

check_layout() {
  local path
  for path in \
    "$ROOT/dtalk/envfill.sh" \
    "$ROOT/dtalk/initwork.sh" \
    "$ROOT/dtalk/env_tmpl" \
    "$ROOT/dtalk/IMAGE_TAG" \
    "$ROOT/im/initwork.sh" \
    "$ROOT/im/sync-mysql-from-dtalk.sh" \
    "$ROOT/im/env.example" \
    "$ROOT/im/IMAGE_TAG" \
    "$ROOT/square/docker-compose.yml" \
    "$ROOT/square/env.example" \
    "$ROOT/square/IMAGE_TAG" \
    "$ROOT/square/sql/schema.sql"; do
    if [[ ! -f "$path" ]]; then
      error "仓库不完整，缺少 ${path}"
      exit 1
    fi
  done
}

as_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
    return
  fi
  if ! command -v sudo >/dev/null 2>&1; then
    return 1
  fi
  if ! sudo -n true >/dev/null 2>&1; then
    return 1
  fi
  sudo -n "$@"
}

compose_ready() {
  docker compose version >/dev/null 2>&1
}

try_install_compose_package() {
  if ! as_root true; then
    info "当前用户不是 root，也没有免密 sudo，跳过系统包安装"
    return 1
  fi
  if command -v apt-get >/dev/null 2>&1; then
    info "尝试 apt 安装 docker-compose-plugin"
    if ! as_root env DEBIAN_FRONTEND=noninteractive apt-get update -y; then
      error "apt-get update 失败，改为下载官方二进制"
      return 1
    fi
    if as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-plugin; then
      return 0
    fi
    info "docker-compose-plugin 未装上，改试 docker-compose-v2"
    if as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-v2; then
      return 0
    fi
    error "apt 安装 Compose 插件失败"
    return 1
  fi
  if command -v dnf >/dev/null 2>&1; then
    info "尝试 dnf 安装 docker-compose-plugin"
    if as_root dnf install -y docker-compose-plugin; then
      return 0
    fi
    error "dnf 安装 docker-compose-plugin 失败"
    return 1
  fi
  if command -v yum >/dev/null 2>&1; then
    info "尝试 yum 安装 docker-compose-plugin"
    if as_root yum install -y docker-compose-plugin; then
      return 0
    fi
    error "yum 安装 docker-compose-plugin 失败"
    return 1
  fi
  info "没有 apt/dnf/yum，跳过系统包安装"
  return 1
}

download_to() {
  local url="$1" dest="$2"
  if command -v curl >/dev/null 2>&1; then
    info "curl -fL --retry 3 ${url}"
    curl -fL --retry 3 --retry-delay 2 -o "$dest" "$url"
    return
  fi
  if command -v wget >/dev/null 2>&1; then
    info "wget ${url}"
    wget -O "$dest" "$url"
    return
  fi
  error "安装 Compose 需要 curl 或 wget。url=${url}"
  return 1
}

assert_elf() {
  local file="$1" magic
  magic=$(od -An -t x1 -N 4 "$file" | tr -d ' \n')
  if [[ "$magic" != "7f454c46" ]]; then
    error "下载内容不是 Linux ELF，magic=${magic}，文件 ${file}"
    return 1
  fi
}

install_compose_user() {
  local src="$1" user_dir
  if [[ -z "${HOME:-}" && -z "${DOCKER_CONFIG:-}" ]]; then
    info "HOME 与 DOCKER_CONFIG 都为空，跳过用户插件目录"
    return 0
  fi
  user_dir="${DOCKER_CONFIG:-${HOME}/.docker}/cli-plugins"
  if ! mkdir -p "$user_dir"; then
    error "无法创建插件目录 ${user_dir}"
    return 1
  fi
  cp "$src" "${user_dir}/docker-compose"
  chmod +x "${user_dir}/docker-compose"
  info "已安装到 ${user_dir}/docker-compose"
}

install_compose_system() {
  local src="$1" dir="/usr/local/lib/docker/cli-plugins"
  if ! as_root true; then
    info "没有 root 权限，未写入 ${dir}"
    return 0
  fi
  if as_root mkdir -p "$dir" \
    && as_root cp "$src" "${dir}/docker-compose" \
    && as_root chmod +x "${dir}/docker-compose"; then
    info "已安装到 ${dir}/docker-compose"
    return 0
  fi
  error "写入系统插件目录失败: ${dir}/docker-compose"
  return 1
}

install_compose_binary() {
  local tmp
  tmp=$(mktemp)
  info "下载 Compose v2 插件: ${COMPOSE_DOWNLOAD_URL}"
  if ! download_to "$COMPOSE_DOWNLOAD_URL" "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! assert_elf "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  chmod +x "$tmp"
  install_compose_user "$tmp" || true
  install_compose_system "$tmp" || true
  rm -f "$tmp"
}

ensure_compose_v2() {
  local version_line
  if compose_ready; then
    version_line=$(docker compose version 2>/dev/null || true)
    info "Docker Compose 已就绪: ${version_line}"
    return 0
  fi
  info "未检测到 docker compose，开始安装 Compose v2"
  if ! try_install_compose_package; then
    info "系统包未安装成功"
  fi
  if ! compose_ready; then
    info "改为下载官方二进制"
    if ! install_compose_binary; then
      error "Compose v2 二进制安装失败，url=${COMPOSE_DOWNLOAD_URL}"
      exit 1
    fi
  fi
  if ! compose_ready; then
    error "安装后仍无法执行 docker compose version，url=${COMPOSE_DOWNLOAD_URL}"
    docker compose version >&2 || true
    exit 1
  fi
  version_line=$(docker compose version 2>/dev/null || true)
  info "Docker Compose 已安装: ${version_line}"
}

check_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    error "未找到 docker。请先安装 Docker Engine"
    exit 1
  fi
  ensure_compose_v2
  if ! docker info >/dev/null 2>&1; then
    error "docker info 失败。确认 Docker 已启动，且当前用户有权限"
    exit 1
  fi
  if [[ -n "${COMPOSE_PROFILES:-}" ]]; then
    info "忽略环境变量 COMPOSE_PROFILES=${COMPOSE_PROFILES}，单集群不启动 federation"
    unset COMPOSE_PROFILES
  fi
}

# docker load 之前检查 tar 里被引用的配置块都在包里。
# containerd 镜像库下 docker save 多平台清单，可能清单进了包、某个平台的配置块没进。
# 这种包 load 时标签能挂上，创建容器才报 failed to read config content。
verify_tar_configs() {
  local file="$1" listing manifest cfg hex missing=0 small_blobs refs
  # 成员名统一去掉 ./ 前缀再比对
  listing=$(tar -tf "$file" 2>/dev/null | sed 's|^\./||') || {
    error "无法读取镜像包 ${file}"
    return 1
  }
  if ! printf '%s\n' "$listing" | grep -qx 'manifest.json' \
    && ! printf '%s\n' "$listing" | grep -qx 'index.json'; then
    error "${file} 不是 docker save 产物（没有 manifest.json / index.json）"
    return 1
  fi
  # 经典 docker save 格式：manifest.json 里每个 Config 文件必须在包里。
  # 有 index.json 时 containerd 的 docker load 以 OCI 图为准，manifest.json 里 flatten 后
  # 残留的幽灵条目（指向已替换掉的旧配置）不影响加载，只警告；纯经典格式 tar 才算残缺。
  local has_oci=0
  printf '%s\n' "$listing" | grep -qx 'index.json' && has_oci=1
  if printf '%s\n' "$listing" | grep -qx 'manifest.json'; then
    manifest=$(tar -xOf "$file" manifest.json 2>/dev/null || true)
    while IFS= read -r cfg; do
      [[ -z "$cfg" ]] && continue
      if ! printf '%s\n' "$listing" | grep -qx "$cfg"; then
        if [[ "$has_oci" -eq 1 ]]; then
          info "manifest.json 引用的配置块不在包里（OCI 图为准，不影响加载）: ${cfg}"
        else
          error "镜像包缺少配置块 ${cfg}（${file}）"
          missing=1
        fi
      fi
    done < <(printf '%s' "$manifest" | grep -oE '"Config"[[:space:]]*:[[:space:]]*"[^"]+"' | sed -E 's/.*"([^"]+)"$/\1/' | sort -u)
  fi
  # OCI 布局（containerd 的 docker save）：index.json 与清单里引用的每个 blob 都要在 blobs/ 里。
  # 只按 "digest":"sha256:..." 收集；配置里的 diff_ids 是裸字符串，不会被误当成包内块。
  if printf '%s\n' "$listing" | grep -qx 'index.json'; then
    # 只提取小包（清单、配置；层都大于 1MB）。GNU tar 第二列是 属主/属组，bsdtar 拆成两列，尺寸列不同
    small_blobs=$(tar -tvf "$file" 2>/dev/null \
      | awk '{ sz = ($2 ~ /\//) ? $3 : $4; if ((sz+0) < 1048576) print $NF }' \
      | sed 's|^\./||' \
      | grep -E '^(index\.json|blobs/sha256/[0-9a-f]{64})$' || true)
    if [[ -z "$small_blobs" ]]; then
      error "读不到 ${file} 里的 OCI 清单"
      return 1
    fi
    # shellcheck disable=SC2086
    # grep 必须加 -a：小包（清单/配置）都是 JSON 文本，但二进制内容会让 grep 默认只报
    # "binary file matches" 不输出匹配行，digest 收集不全会误报通过。
    refs=$(tar -xOf "$file" $small_blobs 2>/dev/null \
      | grep -aoE '"digest"[[:space:]]*:[[:space:]]*"sha256:[0-9a-f]{64}"' \
      | grep -aoE '[0-9a-f]{64}' | sort -u || true)
    while IFS= read -r hex; do
      [[ -z "$hex" ]] && continue
      if ! printf '%s\n' "$listing" | grep -qx "blobs/sha256/${hex}"; then
        error "镜像包缺少内容块 sha256:${hex}（${file}）。多平台清单残缺，某个平台的镜像配置或层不在包里"
        missing=1
      fi
    done <<< "$refs"
  fi
  if [[ "$missing" -ne 0 ]]; then
    error "这份 tar 是残缺包，装上后创建容器才报 failed to read config content。请按打包文档把镜像收成单平台后重打，或换完整的包"
    return 1
  fi
  return 0
}

load_one_tar() {
  local file="$1"
  if ! verify_tar_configs "$file"; then
    return 1
  fi
  info "docker load -i ${file}"
  docker load -i "$file"
}

load_tars() {
  local dir="$1" found=0 f
  if [[ ! -d "$dir" ]]; then
    error "镜像目录不存在: ${dir}"
    exit 1
  fi
  shopt -s nullglob
  for f in "$dir"/*.tar.gz; do
    error "不加载压缩包 ${f}。请使用 docker save 生成的 .tar"
    exit 1
  done
  for f in "$dir"/*.tar; do
    found=1
    load_one_tar "$f"
  done
  shopt -u nullglob
  if [[ "$found" -eq 0 ]]; then
    error "目录里没有 .tar: ${dir}"
    exit 1
  fi
}

file_size() {
  stat -c%s "$1" 2>/dev/null || echo 0
}

list_release_assets() {
  local release="$1" attempt
  for attempt in 1 2 3 4 5; do
    if gh api "repos/${REPO}/releases/tags/${release}" \
      --jq '.assets[] | [.name, .size, .id, (.digest // "")] | @tsv'; then
      return 0
    fi
    error "列出 Release 附件失败: ${release}，第 ${attempt}/5 次。访问 GitHub 时连接被重置"
    sleep $((attempt * 5))
  done
  return 1
}

asset_location() {
  local token="$1" id="$2"
  curl -fsS -o /dev/null -D - \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/octet-stream" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/${REPO}/releases/assets/${id}" \
    | awk 'tolower($1)=="location:" {print $2}' | tr -d '\r' | tail -n 1
}

# GitHub 附件带 sha256 摘要时校验本地文件。大小一致但内容不同的旧缓存会被删掉重下。
asset_digest_ok() {
  local file="$1" digest="$2" actual
  [[ "$digest" == sha256:* ]] || return 0
  command -v sha256sum >/dev/null 2>&1 || return 0
  actual=$(sha256sum "$file" 2>/dev/null | awk '{print $1}')
  [[ -n "$actual" && "$actual" == "${digest#sha256:}" ]]
}

download_release_asset() {
  local token="$1" dest="$2" name="$3" size="$4" id="$5" digest="${6:-}"
  local file attempt actual loc curl_args=(-fL --retry 5 --retry-delay 5 -C -)
  file="${dest}/${name}"
  actual=$(file_size "$file")
  if [[ -f "$file" && "$actual" -eq "$size" ]]; then
    if asset_digest_ok "$file" "$digest"; then
      info "已存在且大小一致，跳过 ${name}（${size} bytes）"
      return 0
    fi
    error "本地文件摘要与 Release 附件不一致，删除后重下: ${name}"
    rm -f "$file"
  fi
  if curl --help all 2>/dev/null | grep -q -- '--retry-all-errors'; then
    curl_args+=(--retry-all-errors)
  fi
  for attempt in 1 2 3 4 5 6 7 8; do
    actual=$(file_size "$file")
    if [[ -f "$file" && "$actual" -eq "$size" ]]; then
      if asset_digest_ok "$file" "$digest"; then
        info "下载完成 ${name}（${size} bytes）"
        return 0
      fi
      error "摘要校验失败，删除后重下: ${name}（期望 ${digest}）"
      rm -f "$file"
    fi
    if [[ -f "$file" && "$actual" -gt "$size" ]]; then
      error "本地文件大于 Release 附件，删除后重下: ${name} 实际 ${actual} 期望 ${size}"
      rm -f "$file"
    fi
    info "下载 ${name}，期望 ${size} bytes，已有 ${actual}，第 ${attempt}/8 次"
    loc=$(asset_location "$token" "$id" || true)
    if [[ -z "$loc" ]]; then
      error "未拿到 ${name} 的下载地址，asset_id=${id}，第 ${attempt}/8 次"
      sleep $((attempt * 5))
      continue
    fi
    if ! curl "${curl_args[@]}" -o "$file" "$loc"; then
      actual=$(file_size "$file")
      error "下载中断: ${name}，已有 ${actual}/${size} bytes，第 ${attempt}/8 次。GitHub 连接被重置时会续传"
    fi
    actual=$(file_size "$file")
    if [[ "$actual" -eq "$size" ]]; then
      if asset_digest_ok "$file" "$digest"; then
        info "下载完成 ${name}（${size} bytes）"
        return 0
      fi
      error "摘要校验失败，删除后重下: ${name}（期望 ${digest}）"
      rm -f "$file"
    fi
    sleep $((attempt * 3))
  done
  actual=$(file_size "$file")
  error "多次重试后仍未下完: ${name}，已有 ${actual}，期望 ${size}，release 目录 ${dest}"
  error "若连续出现 connection reset by peer，这台机器到 GitHub 的链路不稳定。可设置 HTTPS_PROXY 后再执行，或把 tar 拷到本机后用 --images-dir"
  return 1
}

download_release() {
  local release="$1" dest="${2:-}" token row name size id digest count=0
  if ! command -v gh >/dev/null 2>&1; then
    error "未找到 gh。请先 gh auth login，或改用 --images-dir"
    exit 1
  fi
  if ! command -v curl >/dev/null 2>&1; then
    error "下载 Release 需要 curl"
    exit 1
  fi
  token=$(gh auth token) || {
    error "gh auth token 失败。请先 gh auth login"
    exit 1
  }
  if [[ -z "$dest" ]]; then
    dest="${IMAGES_DIR:-/tmp/txchat-images/${release}}"
  fi
  mkdir -p "$dest"
  info "下载 Release ${release}，仓库 ${REPO}，目录 ${dest}"
  while IFS=$'\t' read -r name size id digest; do
    [[ -z "${name}" ]] && continue
    count=$((count + 1))
    if ! download_release_asset "$token" "$dest" "$name" "$size" "$id" "$digest"; then
      exit 1
    fi
  done < <(list_release_assets "$release")
  if [[ "$count" -eq 0 ]]; then
    error "Release ${release} 没有附件，或没能从 GitHub 拿到文件列表"
    exit 1
  fi
  info "Release 附件已齐，共 ${count} 个文件"
}

image_ref() {
  local env_file="$1" key="$2" fallback="$3" current=""
  if [[ -f "$env_file" ]]; then
    current=$(env_get "$key" "$env_file")
  fi
  if [[ -n "$current" && "$current" != "v0.0.0" ]]; then
    printf '%s' "$current"
    return 0
  fi
  printf '%s' "$fallback"
}

require_image() {
  local image="$1"
  if docker image inspect "$image" >/dev/null 2>&1; then
    info "镜像已就绪: ${image}"
    return 0
  fi
  # containerd 镜像库下，残缺 tar 加载后标签还在、配置块缺失，inspect 会失败
  if docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -Fxq -- "$image"; then
    error "镜像记录损坏: ${image}。标签在但配置块缺失，是残缺 tar 加载留下的"
    error "执行 docker rmi -f ${image} 后，换完整的包重新加载"
    return 1
  fi
  error "缺少镜像: ${image}"
  return 1
}

pull_image() {
  local image="$1"
  if docker image inspect "$image" >/dev/null 2>&1; then
    info "镜像已就绪: ${image}"
    return 0
  fi
  info "拉取镜像 ${image}"
  docker pull --platform linux/amd64 "$image"
}

# custom-nginx 拉不到，用仓库里的 dtalk/nginx.Dockerfile 在本机构建。构建上下文只用到 nginx.conf。
ensure_custom_nginx() {
  local version="$1"
  if docker image inspect "custom-nginx:${version}" >/dev/null 2>&1; then
    info "镜像已就绪: custom-nginx:${version}"
    return 0
  fi
  info "本机构建 custom-nginx:${version}（基镜像 nginx:${version} 构建时自动拉取）"
  docker build -f "$ROOT/dtalk/nginx.Dockerfile" \
    --build-arg "version=${version}" \
    -t "custom-nginx:${version}" \
    "$ROOT/dtalk"
}

# Docker Hub 已下架 minio/minio 的老标签，拉不到。按 GitHub 发布的二进制在本机构建，
# 镜像名保持 minio/minio:<MINIO_VERSION>，与 compose 里的引用一致。
ensure_minio() {
  local version="$1"
  local image="minio/minio:${version}"
  local src rc
  if docker image inspect "$image" >/dev/null 2>&1; then
    info "镜像已就绪: ${image}"
    return 0
  fi
  src=$(mktemp -d)
  info "本机构建 ${image}（下载 MinIO ${version} 官方二进制）"
  if ! curl -fL -o "$src/minio" \
    "https://github.com/minio/minio/releases/download/${version}/minio.linux-amd64.${version}"; then
    error "下载 MinIO 二进制失败: ${version}"
    rm -rf "$src"
    return 1
  fi
  if ! curl -fL -o "$src/docker-entrypoint.sh" \
    "https://raw.githubusercontent.com/minio/minio/${version}/dockerscripts/docker-entrypoint.sh"; then
    error "下载 MinIO entrypoint 失败: ${version}"
    rm -rf "$src"
    return 1
  fi
  # 健康检查用 curl，必须装进镜像
  cat > "$src/Dockerfile" <<'EOF'
FROM alpine:latest
RUN apk add --no-cache curl ca-certificates
COPY minio /usr/bin/minio
COPY docker-entrypoint.sh /usr/bin/docker-entrypoint.sh
RUN chmod +x /usr/bin/minio /usr/bin/docker-entrypoint.sh
EXPOSE 9000
VOLUME ["/data"]
ENTRYPOINT ["/usr/bin/docker-entrypoint.sh"]
CMD ["minio"]
EOF
  docker build --platform linux/amd64 -t "$image" "$src"
  rc=$?
  rm -rf "$src"
  return "$rc"
}

# 中间件不进 Release，部署时缺什么从镜像仓库拉什么。业务镜像仍走 tar。
ensure_infra_images() {
  local mysql_version="$1" redis_version="$2" nginx_version="$3" etcd_ver minio_ver
  etcd_ver=$(image_version ETCD_VERSION "$ROOT/im/.env" "$ROOT/im/env.example")
  minio_ver=$(image_version MINIO_VERSION "$ROOT/dtalk/.env" "$ROOT/dtalk/env_tmpl")
  pull_image "mysql:${mysql_version}" || exit 1
  ensure_custom_nginx "$nginx_version" || exit 1
  ensure_minio "$minio_ver" || exit 1
  pull_image "redis:${redis_version}" || exit 1
  pull_image "quay.io/coreos/etcd:${etcd_ver}" || exit 1
  pull_image "ubuntu/zookeeper:3.1-22.04_beta" || exit 1
  pull_image "ubuntu/kafka:3.1-22.04_beta" || exit 1
  pull_image "sheepkiller/kafka-manager:latest" || exit 1
  pull_image "postgres:16-alpine" || exit 1
  pull_image "hello-world:latest" || exit 1
  pull_image "alpine:latest" || exit 1
}

require_images() {
  local dtalk_tag="$1" im_tag="$2" square_tag="$3" nginx_version="$4" mysql_version="$5" redis_version="$6"
  local missing=0 gateway logic comet square etcd_ver minio_ver
  gateway=$(image_ref "$ROOT/dtalk/.env" GATEWAY_IMAGE "$dtalk_tag")
  logic=$(image_ref "$ROOT/im/.env" LOGIC_IMAGE "$im_tag")
  comet=$(image_ref "$ROOT/im/.env" COMET_IMAGE "$im_tag")
  square=$(image_ref "$ROOT/square/.env" SQUARE_IMAGE "$square_tag")
  etcd_ver=$(image_version ETCD_VERSION "$ROOT/im/.env" "$ROOT/im/env.example")
  minio_ver=$(image_version MINIO_VERSION "$ROOT/dtalk/.env" "$ROOT/dtalk/env_tmpl")
  require_image "txchat-gateway:${gateway}" || missing=1
  require_image "txchat-logic:${logic}" || missing=1
  require_image "txchat-comet:${comet}" || missing=1
  require_image "txchat-square:${square}" || missing=1
  require_image "postgres:16-alpine" || missing=1
  require_image "custom-nginx:${nginx_version}" || missing=1
  require_image "mysql:${mysql_version}" || missing=1
  require_image "minio/minio:${minio_ver}" || missing=1
  require_image "redis:${redis_version}" || missing=1
  require_image "quay.io/coreos/etcd:${etcd_ver}" || missing=1
  require_image "ubuntu/zookeeper:3.1-22.04_beta" || missing=1
  require_image "ubuntu/kafka:3.1-22.04_beta" || missing=1
  require_image "sheepkiller/kafka-manager:latest" || missing=1
  if [[ "$missing" -ne 0 ]]; then
    error "请加上 --download，或用 --images-dir 指向已下载的 tar 目录"
    exit 1
  fi
}

require_init_images() {
  require_image "hello-world:latest" || exit 1
  require_image "alpine:latest" || exit 1
}

volume_exists() {
  docker volume inspect "$1" >/dev/null 2>&1
}

tag_was_customized() {
  local current="$1" bundled="$2"
  [[ -n "$current" && "$current" != "v0.0.0" && "$current" != "$bundled" ]]
}

need_initwork() {
  local env_file="$1" image_key="$2" bundled="$3"
  shift 3
  local current volume
  current=$(env_get "$image_key" "$env_file")
  if [[ -z "$current" || "$current" == "v0.0.0" ]]; then
    return 0
  fi
  for volume in "$@"; do
    if ! volume_exists "$volume"; then
      if tag_was_customized "$current" "$bundled" && [[ "$REINIT" -eq 0 ]]; then
        error "卷 ${volume} 不存在，且 ${image_key}=${current} 已不是 ${bundled}"
        error "继续会把业务镜像标签写回 IMAGE_TAG。确认后加 --reinit"
        exit 1
      fi
      return 0
    fi
  done
  return 1
}

clear_dummy_container() {
  docker rm -f dummy >/dev/null 2>&1 || true
}

init_dtalk() {
  local tag="$1" env_file="$ROOT/dtalk/.env" fed profiles
  if [[ ! -f "$env_file" ]]; then
    if ! command -v openssl >/dev/null 2>&1; then
      error "未找到 openssl，envfill.sh 需要它来生成密码"
      exit 1
    fi
    info "生成 dtalk/.env，目录 ${ROOT}/dtalk"
    (cd "$ROOT/dtalk" && bash ./envfill.sh)
  else
    info "已有 dtalk/.env，跳过 envfill.sh"
  fi

  fed=$(env_get FEDERATION_ENABLED "$env_file")
  profiles=$(env_get COMPOSE_PROFILES "$env_file")
  info "dtalk FEDERATION_ENABLED=${fed:-<empty>} COMPOSE_PROFILES=${profiles:-<empty>}"
  if [[ "$fed" == "true" || -n "$profiles" ]]; then
    error "deploy.sh 只部署单集群。请保持 FEDERATION_ENABLED=false，且 COMPOSE_PROFILES 为空"
    exit 1
  fi

  if need_initwork "$env_file" GATEWAY_IMAGE "$tag" txchat-mysql-init txchat-gateway-config txchat-nginx-config; then
    info "初始化 dtalk 卷，镜像标签 ${tag}，服务 ${DTALK_SERVICES}"
    require_init_images
    clear_dummy_container
    (cd "$ROOT/dtalk" && bash ./initwork.sh "$DTALK_SERVICES" "$tag")
  else
    info "dtalk 卷已存在，跳过 initwork.sh"
  fi
  # initwork 的 sed 要求等号后已有内容，空值或缺少该行时补上标签
  # shellcheck disable=SC2086
  ensure_service_images "$env_file" "$tag" $DTALK_SERVICES
}

init_im() {
  local tag="$1" env_file="$ROOT/im/.env" dtalk_env="$ROOT/dtalk/.env" pw
  if [[ ! -f "$env_file" ]]; then
    info "复制 im/env.example -> im/.env"
    cp "$ROOT/im/env.example" "$env_file"
  else
    info "已有 im/.env，不覆盖已有值"
  fi
  fill_missing_env "$env_file" "$ROOT/im/env.example"

  info "同步 MySQL 密码，来源 ${dtalk_env}"
  DTALK_ENV="$dtalk_env" bash "$ROOT/im/sync-mysql-from-dtalk.sh" "$ROOT/im"
  pw=$(env_get MYSQL_ROOT_PASSWORD "$env_file")
  if [[ -z "$pw" ]]; then
    error "同步后 im/.env 的 MYSQL_ROOT_PASSWORD 仍为空，来源 ${dtalk_env}"
    exit 1
  fi
  info "MySQL 密码已同步到 im/.env，长度 ${#pw}"

  if need_initwork "$env_file" COMET_IMAGE "$tag" txchat-redis-config txchat-comet-config txchat-logic-config; then
    info "初始化 im 卷，镜像标签 ${tag}，服务 ${IM_SERVICES}"
    require_init_images
    clear_dummy_container
    (cd "$ROOT/im" && bash ./initwork.sh "$IM_SERVICES" "$tag")
  else
    info "im 卷已存在，跳过 initwork.sh"
  fi
  # shellcheck disable=SC2086
  ensure_service_images "$env_file" "$tag" $IM_SERVICES
}

gen_hex() {
  local bytes="$1" out
  out=$(openssl rand -hex "$bytes" | tr -d '\r\n')
  if [[ -z "$out" ]]; then
    error "openssl rand -hex ${bytes} 没有输出"
    return 1
  fi
  printf '%s' "$out"
}

# 运营台代传图片的签名私钥。32 字节 secp256k1 标量，写成 64 位十六进制。
gen_oss_privkey() {
  local attempt text hex
  for attempt in 1 2 3 4 5; do
    text=$(openssl ecparam -name secp256k1 -genkey -noout 2>/dev/null | openssl ec -text -noout 2>/dev/null) || true
    hex=$(printf '%s\n' "$text" | awk '
      $1 == "priv:" { grab=1; next }
      $1 == "pub:" { grab=0 }
      grab { gsub(/:/, ""); gsub(/[[:space:]]/, ""); printf "%s", tolower($0) }
    ')
    if [[ ${#hex} -eq 66 && "$hex" == 00* ]]; then
      hex=${hex:2}
    fi
    if [[ ${#hex} -eq 64 && "$hex" =~ ^[0-9a-f]+$ && "$hex" != 0000000000000000000000000000000000000000000000000000000000000000 ]]; then
      printf '%s' "$hex"
      return 0
    fi
    error "生成 OSS 私钥失败，第 ${attempt}/5 次，长度 ${#hex}"
  done
  return 1
}

# 运营台密码至少 12 位。base64 不含逗号、冒号和 $，避免写进 .env 后被 compose 展开。
gen_admin_password() {
  local pw i
  for i in 1 2 3 4 5; do
    pw=$(openssl rand -base64 18 | tr -d '\r\n')
    if [[ ${#pw} -ge 12 && "$pw" != *","* && "$pw" != *":"* && "$pw" != *'$'* && "$pw" != *" "* ]]; then
      printf '%s' "$pw"
      return 0
    fi
    error "生成的运营台密码不符合长度或字符限制，第 ${i}/5 次"
  done
  return 1
}

ensure_secret() {
  local file="$1" key="$2" min="$3"
  shift 3
  local current value
  current=$(env_get "$key" "$file" || true)
  if [[ -n "$current" ]]; then
    if [[ ${#current} -lt "$min" ]]; then
      error "${key} 长度 ${#current}，小于 ${min}。已有值不会改写，文件 ${file}"
      if [[ "$key" == "SQUARE_JWT_SECRET" ]]; then
        exit 1
      fi
    else
      info "${key} 已存在，长度 ${#current}，跳过生成"
    fi
    return 0
  fi
  value=$("$@") || {
    error "生成 ${key} 失败，文件 ${file}"
    exit 1
  }
  if [[ ${#value} -lt "$min" || "$value" == *","* || "$value" == *":"* || "$value" == *'$'* || "$value" == *" "* ]]; then
    error "生成的 ${key} 不符合要求，长度 ${#value}，文件 ${file}"
    exit 1
  fi
  info "写入 ${key}，长度 ${#value}，文件 ${file}"
  write_env_key "$file" "$key" "$value"
}

valid_cors_host() {
  local h="$1"
  [[ "$h" != "0.0.0.0" ]] || return 1
  [[ "$h" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ || "$h" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]
}

add_cors_host() {
  local h="$1" x
  valid_cors_host "$h" || return 0
  for x in $cors_hosts; do
    [[ "$x" == "$h" ]] && return 0
  done
  cors_hosts="${cors_hosts:+$cors_hosts }$h"
}

# 浏览器打开运营台的来源。只允许 127.0.0.1 时，从公网 :8888 登录会被广场回空 403。
square_cors_origins() {
  local cors_hosts="" ip line
  add_cors_host "127.0.0.1"
  add_cors_host "localhost"
  if [[ -n "${SQUARE_PUBLIC_HOST:-}" ]]; then
    add_cors_host "$SQUARE_PUBLIC_HOST"
  else
    ip=$(curl -4 -fsS --max-time 2 http://100.100.100.200/latest/meta-data/eipv4 2>/dev/null || true)
    add_cors_host "$ip"
    if ! valid_cors_host "$ip"; then
      ip=$(curl -4 -fsS --max-time 3 https://api.ipify.org 2>/dev/null || true)
      add_cors_host "$ip"
    fi
  fi
  if command -v ip >/dev/null 2>&1; then
    while read -r line; do
      ip=${line%%/*}
      add_cors_host "$ip"
    done < <(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}')
  fi
  local host port origins="" origin seen=" "
  for host in $cors_hosts; do
    for port in 8888 18100; do
      origin="http://${host}:${port}"
      [[ "$seen" == *" ${origin} "* ]] && continue
      seen="${seen}${origin} "
      origins="${origins:+$origins,}${origin}"
    done
  done
  printf '%s' "$origins"
}

merge_csv() {
  local current="$1" extra="$2" item out=""
  while IFS= read -r item; do
    item=${item#"${item%%[![:space:]]*}"}
    item=${item%"${item##*[![:space:]]}"}
    [[ -z "$item" ]] && continue
    if printf '%s\n' "$out" | tr ',' '\n' | grep -Fxq -- "$item"; then
      continue
    fi
    out="${out:+$out,}${item}"
  done < <(printf '%s,%s\n' "$current" "$extra" | tr ',' '\n')
  printf '%s' "$out"
}

ensure_square_cors() {
  local file="$1" current generated merged
  current=$(env_get SQUARE_CORS "$file" || true)
  generated=$(square_cors_origins)
  merged=$(merge_csv "$current" "$generated")
  if [[ "$merged" == "$current" ]]; then
    info "SQUARE_CORS 已包含本机来源: ${current}"
    return 0
  fi
  info "写入 SQUARE_CORS=${merged}，文件 ${file}"
  write_env_key "$file" SQUARE_CORS "$merged"
}

# $host 会去掉端口。浏览器 Origin 仍带 :8888，广场会直接 403。
ensure_square_nginx_host() {
  local volume="txchat-nginx-config" ver image tmp out nginx_name
  if ! volume_exists "$volume"; then
    info "Nginx 配置卷不存在，跳过广场 Host 修正"
    return 0
  fi
  ver=$(env_get NGINX_VERSION "$ROOT/dtalk/.env" || true)
  if [[ -z "$ver" ]]; then
    error "dtalk/.env 中 NGINX_VERSION 为空，无法修正广场 Host"
    exit 1
  fi
  image="custom-nginx:${ver}"
  tmp=$(mktemp)
  out=$(mktemp)
  docker run --rm --entrypoint cat -v "${volume}:/cfg:ro" "$image" /cfg/dtalk.conf >"$tmp"
  awk '
    FNR == NR {
      if ($0 ~ /location[[:space:]]+\/square\//) scan = 1
      else if (scan && $0 ~ /location[[:space:]]+/) scan = 0
      if (scan && $0 ~ /X-Square-Cors/) has = 1
      next
    }
    {
      if ($0 ~ /location[[:space:]]+\/square\//) in_sq = 1
      else if (in_sq && $0 ~ /location[[:space:]]+/) in_sq = 0
      if (in_sq && $0 ~ /proxy_set_header[[:space:]]+Host[[:space:]]+\$host;/) {
        sub(/\$host;/, "$http_host;")
      }
      print
      if (!has && in_sq && $0 ~ /proxy_set_header[[:space:]]+Host[[:space:]]+\$http_host;/) {
        print "            add_header X-Square-Cors passthrough always;"
        has = 1
      }
    }
  ' "$tmp" "$tmp" >"$out"
  if cmp -s "$tmp" "$out"; then
    info "广场 Nginx 已保留端口并去掉多余的跨域 *"
    rm -f "$tmp" "$out"
    return 0
  fi
  docker run --rm --entrypoint sh \
    -v "${volume}:/cfg" \
    -v "${out}:/in/dtalk.conf:ro" \
    "$image" \
    -c 'cp /in/dtalk.conf /cfg/dtalk.conf'
  rm -f "$tmp" "$out"
  info "已更新广场 Nginx：Host 带端口，且不再附加跨域 *"
  nginx_name=$(env_get NGINX_CONTAINER_NAME "$ROOT/dtalk/.env" || true)
  nginx_name=${nginx_name:-txchat-nginx}
  if docker ps --format '{{.Names}}' | grep -qx "$nginx_name"; then
    docker exec "$nginx_name" nginx -t
    docker exec "$nginx_name" nginx -s reload
    info "已重载 ${nginx_name}"
  fi
}

init_square() {
  local tag="$1" env_file="$ROOT/square/.env" example="$ROOT/square/env.example"
  local need_openssl=0 key current user created=0
  if [[ ! -f "$env_file" ]]; then
    info "复制 square/env.example -> square/.env"
    cp "$example" "$env_file"
    created=1
  else
    info "已有 square/.env，不覆盖已有值"
  fi
  fill_missing_env "$env_file" "$example"

  for key in SQUARE_PG_PASSWORD SQUARE_JWT_SECRET SQUARE_BOOTSTRAP_ADMIN_PASSWORD SQUARE_OSS_PRIVKEY; do
    current=$(env_get "$key" "$env_file" || true)
    if [[ -z "$current" ]]; then
      need_openssl=1
    fi
  done
  if [[ "$need_openssl" -eq 1 ]] && ! command -v openssl >/dev/null 2>&1; then
    error "未找到 openssl，生成广场密码和 OSS 私钥需要它"
    exit 1
  fi
  ensure_secret "$env_file" SQUARE_PG_PASSWORD 16 gen_hex 24
  ensure_secret "$env_file" SQUARE_JWT_SECRET 32 gen_hex 32
  ensure_secret "$env_file" SQUARE_BOOTSTRAP_ADMIN_PASSWORD 12 gen_admin_password
  ensure_secret "$env_file" SQUARE_OSS_PRIVKEY 64 gen_oss_privkey
  ensure_square_cors "$env_file"
  if [[ "$created" -eq 1 ]]; then
    info "写入 SQUARE_IMAGE=${tag}，文件 ${env_file}"
    write_env_key "$env_file" SQUARE_IMAGE "$tag"
  else
    ensure_image_tag "$env_file" SQUARE_IMAGE "$tag"
  fi

  user=$(env_get SQUARE_BOOTSTRAP_ADMIN_USER "$env_file" || true)
  if [[ -z "$user" ]]; then
    error "square/.env 中 SQUARE_BOOTSTRAP_ADMIN_USER 为空"
    exit 1
  fi
  info "广场运营台账号 ${user}，镜像标签 $(env_get SQUARE_IMAGE "$env_file")"
}

ensure_network() {
  local name="$1"
  if docker network inspect "$name" >/dev/null 2>&1; then
    info "网络已存在: ${name}"
    return 0
  fi
  info "创建网络 ${name}"
  docker network create "$name"
}

volume_has_file() {
  local volume="$1" filename="$2"
  if ! volume_exists "$volume"; then
    return 1
  fi
  docker run --rm --entrypoint sh -v "${volume}:/cfg:ro" alpine \
    -c "test -s /cfg/${filename}"
}

seed_one() {
  local image="$1" src="$2" volume="$3" filename="$4"
  if [[ "$SKIP_SEED" -eq 1 ]]; then
    info "跳过配置拷贝: ${volume}/${filename}"
    return 0
  fi
  if [[ "$FORCE_SEED" -eq 0 ]] && volume_has_file "$volume" "$filename"; then
    info "配置卷已有 ${filename}，跳过 ${volume}"
    return 0
  fi
  if ! volume_exists "$volume"; then
    error "配置卷不存在: ${volume}。请先完成 initwork"
    exit 1
  fi
  info "拷贝配置 ${image} ${src} -> ${volume}"
  docker run --rm --entrypoint sh \
    -v "${volume}:/out" \
    "$image" \
    -c "cp -a ${src}/. /out/"
}

seed_configs() {
  local name key image
  for name in $DTALK_SERVICES; do
    key=$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]' | tr '-' '_')
    image=$(env_get "${key}_IMAGE" "$ROOT/dtalk/.env")
    if [[ -z "$image" || "$image" == "v0.0.0" ]]; then
      error "dtalk/.env 中 ${key}_IMAGE 无效: ${image:-<empty>}"
      exit 1
    fi
    seed_one "txchat-${name}:${image}" \
      "/etc/txchat-${name}/config" \
      "txchat-${name}-config" \
      "${name}.toml"
  done
  image=$(env_get COMET_IMAGE "$ROOT/im/.env")
  if [[ -z "$image" || "$image" == "v0.0.0" ]]; then
    error "im/.env 中 COMET_IMAGE 无效: ${image:-<empty>}"
    exit 1
  fi
  seed_one "txchat-comet:${image}" /etc/comet/config txchat-comet-config comet.toml
  image=$(env_get LOGIC_IMAGE "$ROOT/im/.env")
  if [[ -z "$image" || "$image" == "v0.0.0" ]]; then
    error "im/.env 中 LOGIC_IMAGE 无效: ${image:-<empty>}"
    exit 1
  fi
  seed_one "txchat-logic:${image}" /etc/logic/config txchat-logic-config logic.toml
}

compose_up() {
  local dir="$1"
  info "启动 ${dir}"
  (
    cd "$dir"
    docker compose -f components.compose.yaml -f service.compose.yaml up -d --no-build
  )
}

compose_up_service() {
  local dir="$1" service="$2"
  info "启动 ${dir} 的 ${service}"
  (
    cd "$dir"
    docker compose -f components.compose.yaml -f service.compose.yaml up -d --no-build --no-deps "$service"
  )
}

container_status() {
  docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null || true
}

mysql_health() {
  local name="$1"
  docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$name" 2>/dev/null || true
}

wait_healthy() {
  local name="$1" label="$2" start=$SECONDS status
  info "等待 ${label} 健康检查通过: ${name}，超时 ${MYSQL_WAIT_SECONDS}s"
  while true; do
    status=$(mysql_health "$name")
    if [[ "$status" == "healthy" ]]; then
      info "${label} 已就绪: ${name}"
      return 0
    fi
    if ((SECONDS - start >= MYSQL_WAIT_SECONDS)); then
      error "等待 ${label} 超时: ${name} status=${status:-missing}"
      return 1
    fi
    sleep 5
  done
}

wait_mysql() {
  wait_healthy "$1" "MySQL"
}

wait_running() {
  local name="$1" timeout="$2" start=$SECONDS status
  while true; do
    status=$(container_status "$name")
    if [[ "$status" == "running" ]]; then
      info "容器已运行: ${name}"
      return 0
    fi
    if ((SECONDS - start >= timeout)); then
      error "等待容器超时: ${name} status=${status:-missing}"
      return 1
    fi
    sleep 5
  done
}

wait_ping() {
  local start=$SECONDS code
  if ! command -v curl >/dev/null 2>&1; then
    info "未安装 curl，跳过 http://127.0.0.1:8888/ping"
    return 0
  fi
  info "等待 http://127.0.0.1:8888/ping 返回 200，超时 ${PING_WAIT_SECONDS}s"
  while true; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:8888/ping || true)
    if [[ "$code" == "200" ]]; then
      info "http://127.0.0.1:8888/ping -> 200"
      return 0
    fi
    if ((SECONDS - start >= PING_WAIT_SECONDS)); then
      error "入口未就绪: http://127.0.0.1:8888/ping http_code=${code:-none}"
      return 1
    fi
    sleep 5
  done
}

wait_json_ok() {
  local url="$1" start=$SECONDS code body compact
  if ! command -v curl >/dev/null 2>&1; then
    info "未安装 curl，跳过 ${url}"
    return 0
  fi
  info "等待 ${url} 返回 200 且正文包含 ok=true，超时 ${PING_WAIT_SECONDS}s"
  while true; do
    body=$(curl -sS --max-time 3 -w $'\n%{http_code}' "$url" || true)
    code=$(printf '%s\n' "$body" | tail -n 1)
    body=$(printf '%s\n' "$body" | sed '$d')
    compact=$(printf '%s' "$body" | tr -d '[:space:]')
    if [[ "$code" == "200" && "$compact" == *'"ok":true'* ]]; then
      info "${url} -> 200 ${compact}"
      return 0
    fi
    if ((SECONDS - start >= PING_WAIT_SECONDS)); then
      error "广场未就绪: ${url} http_code=${code:-none} body=${compact:-empty}"
      return 1
    fi
    sleep 5
  done
}

# 官方镜像只在数据卷为空时使用 POSTGRES_PASSWORD。卷里已有数据时，.env 里的新密码不会写进库，广场会报 28P01。
# 容器内本地套接字是 trust，不走 TCP 密码。用它把库用户改成当前 .env，不删除数据卷。
sync_square_pg_password() {
  local pw
  pw=$(env_get SQUARE_PG_PASSWORD "$ROOT/square/.env" || true)
  if [[ -z "$pw" ]]; then
    error "square/.env 中 SQUARE_PG_PASSWORD 为空，无法对齐数据库密码"
    return 1
  fi
  info "对齐 PostgreSQL 用户 square 的密码到 square/.env，长度 ${#pw}"
  # psql -c 原样把 SQL 交给服务器，不会展开 :'pass'。从标准输入读才会替换变量。
  if ! docker exec -i txchat-square-pg \
    psql -U square -d square -v ON_ERROR_STOP=1 -v pass="$pw" <<'SQL'
ALTER USER square PASSWORD :'pass';
SQL
  then
    error "对齐 PostgreSQL 密码失败，容器 txchat-square-pg，用户 square，库 square"
    return 1
  fi
  info "PostgreSQL 用户 square 的密码已与 square/.env 一致"
}

start_square() {
  ensure_network txchat-components
  info "启动 square，目录 ${ROOT}/square"
  if ! (
    cd "$ROOT/square"
    docker compose up -d --no-build
  ); then
    error "square 启动失败，目录 ${ROOT}/square"
    dump_failure txchat-square-pg txchat-square
    return 1
  fi
  if ! wait_healthy txchat-square-pg "PostgreSQL"; then
    dump_failure txchat-square-pg txchat-square
    return 1
  fi
  if ! sync_square_pg_password; then
    dump_failure txchat-square-pg txchat-square
    return 1
  fi
  info "重启 txchat-square，使用对齐后的数据库密码"
  if ! docker restart txchat-square >/dev/null; then
    error "重启 txchat-square 失败"
    dump_failure txchat-square-pg txchat-square
    return 1
  fi
  if ! wait_running txchat-square 180; then
    dump_failure txchat-square-pg txchat-square
    return 1
  fi
  if ! wait_json_ok "http://127.0.0.1:18100/square/healthz"; then
    dump_failure txchat-square-pg txchat-square
    return 1
  fi
}

wait_im_containers() {
  local name
  local names=(
    txchat-zookeeper
    txchat-kafka
    "$(env_get REDIS_CONTAINER_NAME "$ROOT/im/.env")"
    "$(env_get ETCD_CONTAINER_NAME "$ROOT/im/.env")"
    "$(env_get LOGIC_CONTAINER_NAME "$ROOT/im/.env")"
    "$(env_get COMET_CONTAINER_NAME "$ROOT/im/.env")"
  )
  for name in "${names[@]}"; do
    if [[ -z "$name" ]]; then
      error "im/.env 中有容器名为空"
      exit 1
    fi
    if ! wait_running "$name" 300; then
      dump_failure "${names[@]}"
      exit 1
    fi
  done
}

dump_failure() {
  local name
  error "当前 txchat 容器:"
  docker ps -a --filter name=txchat- >&2 || true
  for name in "$@"; do
    error "---- logs ${name} ----"
    docker logs --tail 80 "$name" >&2 || true
  done
}

compose_down() {
  local dir="$1"
  shift
  info "停止并删除容器，目录 ${dir}"
  (
    cd "$dir"
    docker compose "$@" down --remove-orphans
  )
}

remove_remaining_containers() {
  local id name
  local -a ids=()
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    ids+=("$id")
  done < <(docker ps -aq --filter name=txchat- || true)
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    ids+=("$id")
  done < <(docker ps -aq --filter name='^dummy$' || true)
  if [[ ${#ids[@]} -eq 0 ]]; then
    info "没有剩余的 txchat 容器"
    return 0
  fi
  for id in "${ids[@]}"; do
    name=$(docker inspect -f '{{.Name}}' "$id" 2>/dev/null || true)
    info "删除容器 ${name:-$id}"
  done
  docker rm -f "${ids[@]}"
}

stop_containers() {
  local failed=0 left
  compose_down "$ROOT/dtalk" -f components.compose.yaml -f service.compose.yaml || failed=1
  compose_down "$ROOT/im" -f components.compose.yaml -f service.compose.yaml || failed=1
  compose_down "$ROOT/square" || failed=1
  remove_remaining_containers
  left=$(docker ps -aq --filter name=txchat- || true)
  if [[ -n "$left" ]]; then
    error "仍有 txchat 容器未删除"
    docker ps -a --filter name=txchat- >&2 || true
    exit 1
  fi
  if [[ "$failed" -ne 0 ]]; then
    info "compose down 有报错，容器已按名称删掉"
  fi
}

stop_all() {
  info "关闭 dtalk、im、square 的容器。数据卷、配置卷、.env 和镜像都保留"
  stop_containers
  info "容器已删除。需要再启动时执行 bash ./deploy.sh"
}

env_value() {
  local key="$1" file="$2" line
  [[ -f "$file" ]] || return 0
  line=$(grep -E "^${key}=" "$file" | head -n 1 || true)
  line=${line#*=}
  printf '%s' "$line" | tr -d '\r\n'
}

image_version() {
  local key="$1" env_file="$2" tmpl="$3" value
  value=$(env_value "$key" "$env_file")
  if [[ -z "$value" ]]; then
    value=$(env_value "$key" "$tmpl")
  fi
  printf '%s' "$value"
}

remove_one_image() {
  local image="$1"
  [[ -z "$image" || "$image" == *":v0.0.0" ]] && return 0
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    # 内容块缺失时 inspect 会失败，标签却还在。这里仍要删掉记录。
    if docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -Fxq -- "$image"; then
      info "删除损坏镜像 ${image}"
      docker rmi -f "$image" >/dev/null 2>&1 || true
    fi
    return 0
  fi
  info "删除镜像 ${image}"
  if ! docker rmi -f "$image"; then
    error "删除镜像失败: ${image}。可能仍被其它容器使用"
    return 1
  fi
}

images_in_tar() {
  local tarfile="$1" manifest
  manifest=$(tar -xOf "$tarfile" manifest.json 2>/dev/null || true)
  [[ -z "$manifest" ]] && return 0
  printf '%s\n' "$manifest" \
    | tr '{' '\n' \
    | sed -n 's/.*"RepoTags"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p' \
    | tr ',' '\n' \
    | tr -d '"[] \r' \
    | sed '/^$/d'
}

remove_project_images() {
  local failed=0 image mysql_ver nginx_ver minio_ver redis_ver etcd_ver tarfile left
  info "删除本机由下载加载的镜像，包含升级后单独加载的 txchat 标签"
  while IFS= read -r tarfile; do
    [[ -z "$tarfile" ]] && continue
    info "读取镜像包标签 ${tarfile}"
    while IFS= read -r image; do
      [[ -z "$image" || "$image" == "<none>:<none>" ]] && continue
      remove_one_image "$image" || failed=1
    done < <(images_in_tar "$tarfile")
  done < <(find /tmp/txchat-images -type f -name '*.tar' 2>/dev/null || true)

  while IFS= read -r image; do
    [[ -z "$image" || "$image" == *":<none>" ]] && continue
    remove_one_image "$image" || failed=1
  done < <(docker images --format '{{.Repository}}:{{.Tag}}' 'txchat-*' 2>/dev/null || true)

  mysql_ver=$(image_version MYSQL_VERSION "$ROOT/dtalk/.env" "$ROOT/dtalk/env_tmpl")
  nginx_ver=$(image_version NGINX_VERSION "$ROOT/dtalk/.env" "$ROOT/dtalk/env_tmpl")
  minio_ver=$(image_version MINIO_VERSION "$ROOT/dtalk/.env" "$ROOT/dtalk/env_tmpl")
  redis_ver=$(image_version REDIS_VERSION "$ROOT/im/.env" "$ROOT/im/env.example")
  etcd_ver=$(image_version ETCD_VERSION "$ROOT/im/.env" "$ROOT/im/env.example")
  remove_one_image "mysql:${mysql_ver}" || failed=1
  remove_one_image "custom-nginx:${nginx_ver}" || failed=1
  remove_one_image "minio/minio:${minio_ver}" || failed=1
  remove_one_image "redis:${redis_ver}" || failed=1
  remove_one_image "quay.io/coreos/etcd:${etcd_ver}" || failed=1
  remove_one_image "ubuntu/zookeeper:3.1-22.04_beta" || failed=1
  remove_one_image "ubuntu/kafka:3.1-22.04_beta" || failed=1
  remove_one_image "sheepkiller/kafka-manager:latest" || failed=1
  remove_one_image "postgres:16-alpine" || failed=1
  remove_one_image "hello-world:latest" || failed=1
  remove_one_image "alpine:latest" || failed=1
  if [[ "$failed" -ne 0 ]]; then
    error "有镜像没能删除。容器已删除，可处理占用后再执行 bash ./deploy.sh --purge"
    exit 1
  fi
  left=$(docker images --format '{{.Repository}}:{{.Tag}}' 'txchat-*' 2>/dev/null || true)
  if [[ -n "$left" ]]; then
    error "本机仍有 txchat 镜像"
    printf '%s\n' "$left" >&2
    exit 1
  fi
  # 去掉没有标签的旧镜像。否则下次 docker load 会沿用已丢失内容块的记录。
  docker image prune -f >/dev/null || true
}

remove_downloaded_tars() {
  local dir="/tmp/txchat-images"
  if [[ ! -d "$dir" ]]; then
    info "没有下载目录 ${dir}"
    return 0
  fi
  info "删除下载的镜像包 ${dir}"
  rm -rf "$dir"
}

purge_all() {
  info "删除容器，以及本机由下载加载的全部镜像和 /tmp/txchat-images。数据卷、配置卷和 .env 保留"
  stop_containers
  remove_project_images
  remove_downloaded_tars
  info "容器和下载的镜像已删除。本机不再保留这些镜像包。重新部署执行 bash ./deploy.sh --download"
}

reset_square_pg() {
  local name found=0
  info "清理广场 PostgreSQL。删除容器 txchat-square、txchat-square-pg 和数据卷 square-pg-data"
  info "MySQL、配置卷、.env 和镜像保留"
  (
    cd "$ROOT/square"
    docker compose down --remove-orphans -v
  ) || info "square compose down 失败，改为按名称删除容器和数据卷"
  docker rm -f txchat-square txchat-square-pg >/dev/null 2>&1 || true
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    found=1
    info "删除数据卷 ${name}"
    docker volume rm "$name"
  done < <(docker volume ls --format '{{.Name}}' | grep -E '(^|_)square-pg-data$' || true)
  if docker ps -aq --filter name='^txchat-square$' | grep -q . || docker ps -aq --filter name='^txchat-square-pg$' | grep -q .; then
    error "广场容器仍在，PostgreSQL 数据卷无法删除"
    docker ps -a --filter name=txchat-square >&2 || true
    exit 1
  fi
  if [[ "$found" -eq 0 ]]; then
    info "没有残留的 square-pg-data 数据卷"
  fi
  if docker volume ls --format '{{.Name}}' | grep -E '(^|_)square-pg-data$' | grep -q .; then
    error "square-pg-data 仍在。确认没有容器占用这个卷"
    docker volume ls --format '{{.Name}}' | grep -E '(^|_)square-pg-data$' >&2 || true
    exit 1
  fi
  info "广场数据库已清空。执行 bash ./deploy.sh 会按 square/.env 重建库，并用其中的运营台账号重新建管理员"
}

image_env_key() {
  printf '%s_IMAGE' "$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | tr '-' '_')"
}

container_env_key() {
  printf '%s_CONTAINER_NAME' "$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | tr '-' '_')"
}

compose_declares() {
  local file="$1" svc="$2"
  [[ -f "$file" ]] || return 1
  awk -v svc="$svc" '
    { sub(/\r$/, "") }
    /^services:/ { ins=1; next }
    /^[^[:space:]]/ { ins=0 }
    ins && $1 == svc ":" { found=1 }
    END { exit found ? 0 : 1 }
  ' "$file"
}

module_env_file() {
  local svc="$1"
  if compose_declares "$ROOT/im/service.compose.yaml" "$svc" || compose_declares "$ROOT/im/components.compose.yaml" "$svc"; then
    printf '%s' "$ROOT/im/.env"
    return 0
  fi
  if compose_declares "$ROOT/square/docker-compose.yml" "$svc"; then
    printf '%s' "$ROOT/square/.env"
    return 0
  fi
  printf '%s' "$ROOT/dtalk/.env"
}

compose_service_names() {
  local file
  for file in \
    "$ROOT/dtalk/service.compose.yaml" \
    "$ROOT/dtalk/components.compose.yaml" \
    "$ROOT/im/service.compose.yaml" \
    "$ROOT/im/components.compose.yaml" \
    "$ROOT/square/docker-compose.yml"; do
    [[ -f "$file" ]] || continue
    awk '
      { sub(/\r$/, "") }
      /^services:/ { ins=1; next }
      /^[^[:space:]]/ { ins=0 }
      ins && /^  [a-z0-9][a-z0-9-]*:/ {
        name=$1
        sub(/:.*/, "", name)
        print name
      }
    ' "$file"
  done
}

upgrade_service_names() {
  {
    printf '%s\n' $DTALK_SERVICES $IM_SERVICES square
    compose_service_names
  } | awk '
    BEGIN { skip["mysql"]=1; skip["minio"]=1; skip["nginx"]=1; skip["redis"]=1; skip["etcd"]=1
            skip["zookeeper"]=1; skip["kafka"]=1; skip["kafka-manager"]=1; skip["postgres"]=1; skip["federation"]=1 }
    NF && !skip[$0] && !seen[$0]++ { print length($0), $0 }
  ' | sort -nr | awk '{ print $2 }'
}

# 附件名 txchat-<服务>-<标签>.tar。服务名按长度从长到短匹配，避免 offline-push 被拆开。
module_from_tar() {
  local name="$1" rest svc
  [[ "$name" == txchat-*.tar ]] || return 1
  [[ "$name" == *.tar.gz ]] && return 1
  rest=${name#txchat-}
  rest=${rest%.tar}
  while IFS= read -r svc; do
    [[ -z "$svc" ]] && continue
    if [[ "$rest" == "$svc-"* && "$rest" != "$svc-" ]]; then
      printf '%s\t%s' "$svc" "${rest#"${svc}-"}"
      return 0
    fi
  done < <(upgrade_service_names)
  return 1
}

pull_release_repo() {
  local branch
  if ! git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    info "当前目录不是 git 仓库，不拉取运行目录"
    return 0
  fi
  if [[ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ]]; then
    info "运行目录有未提交改动，不执行 git pull。继续按 Release 升级镜像"
    return 0
  fi
  branch=$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)
  info "拉取运行目录 ${ROOT}，分支 ${branch}"
  if ! git -C "$ROOT" pull --ff-only; then
    error "git pull --ff-only 失败。镜像升级继续，compose 可能还是旧的"
  fi
}

list_release_tars() {
  local attempt
  for attempt in 1 2 3 4 5; do
    if gh api --paginate "repos/${REPO}/releases?per_page=100" \
      --jq '.[] | .assets[] | select(.name | test("\\.tar$")) | [.created_at, .name, (.size|tostring), (.id|tostring), (.digest // "")] | @tsv'; then
      return 0
    fi
    error "列出 Release 失败，仓库 ${REPO}，第 ${attempt}/5 次"
    sleep $((attempt * 5))
  done
  return 1
}

# 每个业务模块保留 created_at 最新的一张 tar。输出：created service tag size id name digest
pick_latest_modules() {
  local raw created name size id digest parsed svc tag
  raw=$(mktemp)
  list_release_tars >"$raw" || {
    rm -f "$raw"
    return 1
  }
  if [[ ! -s "$raw" ]]; then
    rm -f "$raw"
    error "没有从 GitHub 拿到 Release 附件，仓库 ${REPO}"
    return 1
  fi
  while IFS=$'\t' read -r created name size id digest; do
    [[ -z "$name" || -z "$created" ]] && continue
    if [[ "$name" == txchat-federation-*.tar || "$name" == infra-*.tar || "$name" == postgres-*.tar ]]; then
      printf 'info: 跳过中间件或联邦附件 %s\n' "$name" >&2
      continue
    fi
    if ! parsed=$(module_from_tar "$name"); then
      if [[ "$name" == txchat-*.tar ]]; then
        printf 'info: 运行目录没有 %s 对应的 compose，跳过\n' "$name" >&2
      fi
      continue
    fi
    svc=${parsed%%$'\t'*}
    tag=${parsed#*$'\t'}
    [[ -z "$svc" || -z "$tag" ]] && continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$created" "$svc" "$tag" "$size" "$id" "$name" "$digest"
  done <"$raw" | sort -t $'\t' -k2,2 -k1,1 | awk -F '\t' '{ last[$2]=$0 } END { for (s in last) print last[s] }'
  rm -f "$raw"
}

module_is_running() {
  local svc="$1" env_file key name
  if [[ "$svc" == "square" ]]; then
    [[ "$(container_status txchat-square)" == "running" ]]
    return
  fi
  env_file=$(module_env_file "$svc")
  key=$(container_env_key "$svc")
  name=$(env_get "$key" "$env_file" || true)
  [[ -n "$name" && "$(container_status "$name")" == "running" ]]
}

wait_service_container() {
  local svc="$1" env_file key name
  env_file=$(module_env_file "$svc")
  key=$(container_env_key "$svc")
  name=$(env_get "$key" "$env_file" || true)
  if [[ -z "$name" ]]; then
    error "${env_file} 中 ${key} 为空，无法确认 ${svc} 是否起来"
    return 1
  fi
  wait_running "$name" 180
}

recreate_module() {
  local svc="$1" tag="$2" key dir
  key=$(image_env_key "$svc")
  if [[ "$svc" == "square" ]]; then
    SQUARE_IMAGE="$tag" start_square
    return
  fi
  dir=$(dirname "$(module_env_file "$svc")")
  if [[ "$dir" == "$ROOT/square" ]]; then
    (
      cd "$dir"
      export "${key}=${tag}"
      docker compose up -d --no-build --no-deps "$svc"
    ) || return 1
    wait_service_container "$svc"
    return
  fi
  (
    cd "$dir"
    export "${key}=${tag}"
    docker compose -f components.compose.yaml -f service.compose.yaml up -d --no-build --no-deps "$svc"
  ) || return 1
  wait_service_container "$svc"
}

restart_nginx_for_new_square() {
  local nginx
  nginx=$(env_get NGINX_CONTAINER_NAME "$ROOT/dtalk/.env" || true)
  if [[ -z "$nginx" || "$(container_status "$nginx")" != "running" ]]; then
    info "Nginx 未在运行，广场起来后再执行 bash ./deploy.sh 会把它拉起来"
    return 0
  fi
  info "广场原先没在跑，重启 ${nginx}，让 8888 解析 txchat-square"
  docker restart "$nginx" >/dev/null || return 1
  wait_running "$nginx" 180 || return 1
  wait_ping || return 1
  wait_json_ok "http://127.0.0.1:8888/square/healthz"
}

require_gh() {
  if ! command -v gh >/dev/null 2>&1; then
    error "未找到 gh。请先 gh auth login"
    exit 1
  fi
  if ! command -v curl >/dev/null 2>&1; then
    error "下载 Release 需要 curl"
    exit 1
  fi
  gh auth token >/dev/null || {
    error "gh auth token 失败。请先 gh auth login"
    exit 1
  }
}

upgrade_from_releases() {
  local token dest latest created svc tag size id name digest
  local env_file key current changed=0 square_was image_ready
  pull_release_repo
  check_layout
  if [[ ! -f "$ROOT/dtalk/.env" || ! -f "$ROOT/im/.env" ]]; then
    error "还没有 dtalk/.env 或 im/.env。请先 bash ./deploy.sh 完成首次部署"
    exit 1
  fi
  require_gh
  token=$(gh auth token)
  dest="/tmp/txchat-images/upgrade"
  mkdir -p "$dest"
  square_was=$(container_status txchat-square)
  latest=$(mktemp)
  if ! pick_latest_modules >"$latest"; then
    rm -f "$latest"
    exit 1
  fi
  if [[ ! -s "$latest" ]]; then
    rm -f "$latest"
    error "Release 里没有可升级的业务模块 tar，仓库 ${REPO}"
    exit 1
  fi
  while IFS=$'\t' read -r created svc tag size id name digest; do
    [[ -z "$svc" ]] && continue
    env_file=$(module_env_file "$svc")
    key=$(image_env_key "$svc")
    if [[ -f "$env_file" ]]; then
      current=$(env_get "$key" "$env_file" || true)
    else
      current=""
    fi
    if [[ "$current" == "$tag" ]] && module_is_running "$svc"; then
      info "${svc} 已是 ${tag}，跳过"
      continue
    fi
    if [[ "$current" == "$tag" ]]; then
      info "${svc} 标签已是 ${tag}，容器未在运行，重新启动"
    else
      info "${svc} 从 ${current:-<empty>} 升级到 ${tag}，附件 ${name}，发布于 ${created}"
    fi
    if docker image inspect "txchat-${svc}:${tag}" >/dev/null 2>&1; then
      image_ready=1
    else
      image_ready=0
    fi
    if [[ "$current" != "$tag" || "$image_ready" -eq 0 ]]; then
      if ! download_release_asset "$token" "$dest" "$name" "$size" "$id" "$digest"; then
        rm -f "$latest"
        exit 1
      fi
      if ! load_one_tar "${dest}/${name}"; then
        rm -f "$latest"
        exit 1
      fi
    fi
    if [[ "$svc" == "square" && ! -f "$env_file" ]]; then
      info "广场还没有 .env，按 Release 标签 ${tag} 生成配置后再启动"
      init_square "$tag"
    fi
    if ! recreate_module "$svc" "$tag"; then
      error "${svc} 重建失败，目标标签 ${tag}"
      rm -f "$latest"
      exit 1
    fi
    write_env_key "$env_file" "$key" "$tag"
    info "${svc} 已换成 ${tag}"
    changed=1
    if [[ "$svc" == "square" && "$square_was" != "running" ]]; then
      if ! restart_nginx_for_new_square; then
        error "广场已启动，但 Nginx 重启失败"
        rm -f "$latest"
        exit 1
      fi
    fi
  done <"$latest"
  rm -f "$latest"
  if [[ "$changed" -eq 0 ]]; then
    info "业务模块已是 Release 中的最新标签。中间件、数据卷和密码未改"
    return 0
  fi
  info "升级完成。数据卷和 .env 里的密码未改。需要整集群再拉起时执行 bash ./deploy.sh"
}

main() {
  local dtalk_tag im_tag square_tag nginx_version mysql_version redis_version
  local release dest
  local mysql_name nginx_name gateway_name

  parse_args "$@"
  if [[ "$DOWN" -eq 1 ]]; then
    check_docker
    stop_all
    exit 0
  fi
  if [[ "$PURGE" -eq 1 ]]; then
    check_docker
    purge_all
    exit 0
  fi
  if [[ "$RESET_SQUARE_PG" -eq 1 ]]; then
    check_docker
    reset_square_pg
    exit 0
  fi
  if [[ "$UPGRADE" -eq 1 ]]; then
    check_platform
    check_docker
    upgrade_from_releases
    exit 0
  fi
  check_platform
  check_layout
  check_docker

  dtalk_tag=$(read_tag "$ROOT/dtalk/IMAGE_TAG")
  im_tag=$(read_tag "$ROOT/im/IMAGE_TAG")
  square_tag=$(read_tag "$ROOT/square/IMAGE_TAG")
  nginx_version=$(env_get NGINX_VERSION "$ROOT/dtalk/env_tmpl")
  mysql_version=$(env_get MYSQL_VERSION "$ROOT/dtalk/env_tmpl")
  redis_version=$(env_get REDIS_VERSION "$ROOT/im/env.example")
  info "仓库目录 ${ROOT}"
  info "dtalk 标签 ${dtalk_tag}，im 标签 ${im_tag}，square 标签 ${square_tag}"

  if [[ "$DOWNLOAD" -eq 1 ]]; then
    release="${RELEASE:-bundle-${dtalk_tag}}"
    dest="${IMAGES_DIR:-/tmp/txchat-images/${release}}"
    mkdir -p "$dest"
    download_release "$release" "$dest"
    load_tars "$dest"
  elif [[ -n "$IMAGES_DIR" ]]; then
    load_tars "$IMAGES_DIR"
  else
    info "未指定 --download 或 --images-dir，使用本机已有镜像"
  fi

  ensure_infra_images "$mysql_version" "$redis_version" "$nginx_version"
  require_images "$dtalk_tag" "$im_tag" "$square_tag" "$nginx_version" "$mysql_version" "$redis_version"
  init_dtalk "$dtalk_tag"
  ensure_square_nginx_host
  init_im "$im_tag"
  init_square "$square_tag"
  seed_configs

  mysql_name=$(env_get MYSQL_CONTAINER_NAME "$ROOT/dtalk/.env")
  nginx_name=$(env_get NGINX_CONTAINER_NAME "$ROOT/dtalk/.env")
  gateway_name=$(env_get GATEWAY_CONTAINER_NAME "$ROOT/dtalk/.env")
  if [[ -z "$mysql_name" ]]; then
    error "dtalk/.env 中 MYSQL_CONTAINER_NAME 为空"
    exit 1
  fi
  # logic 启动时会连接 txchat-mysql。MySQL 不在网络里时 DNS 失败，logic 会直接退出。
  compose_up_service "$ROOT/dtalk" mysql
  if ! wait_mysql "$mysql_name"; then
    dump_failure "$mysql_name"
    exit 1
  fi

  compose_up "$ROOT/im"
  wait_im_containers

  # Nginx 启动时解析 upstream square。广场不在 txchat-components 里时，8888 一起起不来。
  if ! start_square; then
    exit 1
  fi

  compose_up "$ROOT/dtalk"
  if ! wait_mysql "$mysql_name"; then
    dump_failure "$mysql_name" "$gateway_name" "$nginx_name" txchat-square txchat-square-pg
    exit 1
  fi
  if ! wait_running "$gateway_name" 180; then
    dump_failure "$mysql_name" "$gateway_name" "$nginx_name" txchat-square txchat-square-pg
    exit 1
  fi
  if ! wait_running "$nginx_name" 180; then
    dump_failure "$mysql_name" "$gateway_name" "$nginx_name" txchat-square txchat-square-pg
    exit 1
  fi
  if ! wait_ping; then
    dump_failure "$mysql_name" "$gateway_name" "$nginx_name" txchat-square txchat-square-pg
    exit 1
  fi
  if ! wait_json_ok "http://127.0.0.1:8888/square/healthz"; then
    dump_failure "$mysql_name" "$gateway_name" "$nginx_name" txchat-square txchat-square-pg
    exit 1
  fi

  info "单集群已启动。客户端连接 http://<本机>:8888 ，WebSocket 为 ws://<本机>:8888/sub ，广场为 http://<本机>:8888/square/healthz"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
