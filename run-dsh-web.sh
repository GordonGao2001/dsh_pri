#!/usr/bin/env bash
#
# 启动打过补丁的 DeepSeek Harness Web，可选挂在 Cloudflare 临时隧道 (trycloudflare) 上。
#
# 用法:
#   ./run-dsh-web.sh -pwd 你的密码                       # 只监听 127.0.0.1:3080
#   ./run-dsh-web.sh -pwd 你的密码 --tunnel              # 同时开 Cloudflare 临时隧道
#   ./run-dsh-web.sh -pwd 你的密码 --port 8080 --tunnel  # 换端口
#   ./run-dsh-web.sh -pwd 你的密码 -- --no-open          # 后面的参数原样传给 dsh web
#
# 环境变量:
#   DSH_SRC   源码目录，默认 ~/deepseek-harness-pwd
#
set -euo pipefail

SRC_DIR="${DSH_SRC:-$HOME/deepseek-harness-pwd}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASSWORD=""
PORT=3080
USE_TUNNEL=0
TUNNEL_LOG="${DSH_TUNNEL_LOG:-$HOME/.dsh-cloudflared.log}"
TUNNEL_URL_FILE="${DSH_TUNNEL_URL_FILE:-$HOME/.dsh-tunnel-url}"
TUNNEL_PID=""
EXTRA=()

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!!  %s\033[0m\n' "$*" >&2; }
die()  { printf '\n\033[1;31m!!  %s\033[0m\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
启动打过补丁的 DeepSeek Harness Web，可选挂在 Cloudflare 临时隧道 (trycloudflare) 上。

用法:
  ./run-dsh-web.sh -pwd 你的密码                       # 只监听 127.0.0.1:3080
  ./run-dsh-web.sh -pwd 你的密码 --tunnel              # 同时开 Cloudflare 临时隧道
  ./run-dsh-web.sh -pwd 你的密码 --port 8080 --tunnel  # 换端口
  ./run-dsh-web.sh -pwd 你的密码 -- --no-open          # -- 后面的参数原样传给 dsh web

环境变量:
  DSH_SRC   源码目录，默认 ~/deepseek-harness-pwd

说明:
  网页第一次打开会让你输入 -pwd 指定的密码，第一个输对的来源 IP 会被记住，
  之后只有这个 IP 能用（换网络或重启服务后需要重新输入）。
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -pwd|--pwd) [ $# -ge 2 ] || die "-pwd 后面要跟密码"; PASSWORD="$2"; shift 2 ;;
    -pwd=*) PASSWORD="${1#-pwd=}"; shift ;;
    --pwd=*) PASSWORD="${1#--pwd=}"; shift ;;
    --port) [ $# -ge 2 ] || die "--port 后面要跟端口号"; PORT="$2"; shift 2 ;;
    --dir) SRC_DIR="$2"; shift 2 ;;
    --tunnel) USE_TUNNEL=1; shift ;;
    --) shift; EXTRA=("$@"); break ;;
    -h|--help) usage; exit 0 ;;
    *) EXTRA+=("$1"); shift ;;
  esac
done

[ -n "$PASSWORD" ] || die "必须用 -pwd <密码> 指定访问密码，例如: $0 -pwd 'my-secret-123'"
[ "${#PASSWORD}" -ge 4 ] || die "密码至少要 4 个字符（harness 自身也会拒绝更短的）"
[[ "$PORT" =~ ^[0-9]+$ ]] || die "--port 必须是数字，收到: $PORT"
if [ "$USE_TUNNEL" = 1 ] && [ "$PORT" = 0 ]; then
  die "隧道模式不能用 --port 0：cloudflared 需要一个固定端口"
fi

# ---------------------------------------------------------------- 源码检查
[ -d "$SRC_DIR/.git" ] || die "找不到源码目录 ${SRC_DIR}，请先运行 ./install-dsh-pwd.sh"
cd "$SRC_DIR"
[ -f apps/cli/src/bin.ts ] || die "$SRC_DIR 看起来不是 deepseek-harness 源码目录"
[ -f apps/web/dist/index.html ] || die "还没有构建产物 (apps/web/dist/index.html)。请先运行 ./install-dsh-pwd.sh"
[ -d node_modules ] || die "还没有安装依赖 (node_modules)。请先运行 ./install-dsh-pwd.sh"
grep -q 'PASSWORD_LOGIN_PATH' packages/client/connection/src/browser-auth.ts 2>/dev/null \
  || warn "源码里没有找到密码登录补丁的标记，可能补丁没打上；启动后请确认访问 / 时是否出现密码页"

# ---------------------------------------------------------------- cloudflared
ensure_cloudflared() {
  command -v cloudflared >/dev/null 2>&1 && return 0
  local os arch asset base
  os="$(uname -s)"; arch="$(uname -m)"
  base="https://github.com/cloudflare/cloudflared/releases/latest/download"
  case "$os-$arch" in
    Linux-x86_64)             asset="cloudflared-linux-amd64" ;;
    Linux-aarch64|Linux-arm64) asset="cloudflared-linux-arm64" ;;
    Darwin-x86_64)            asset="cloudflared-darwin-amd64.tgz" ;;
    Darwin-arm64)             asset="cloudflared-darwin-arm64.tgz" ;;
    *) die "不认识的平台 $os-${arch}，请先自行安装 cloudflared" ;;
  esac
  log "下载 cloudflared ($asset)"
  local dir="$HOME/.local/bin"
  mkdir -p "$dir"
  if [ "${asset##*.}" = tgz ]; then
    curl -fsSL "$base/$asset" -o "$dir/cloudflared.tgz" && tar -xzf "$dir/cloudflared.tgz" -C "$dir" && rm -f "$dir/cloudflared.tgz"
  else
    curl -fsSL "$base/$asset" -o "$dir/cloudflared" && chmod +x "$dir/cloudflared"
  fi
  [ -x "$dir/cloudflared" ] || die "cloudflared 下载失败"
  PATH="$dir:$PATH"
  export PATH
}

cleanup() {
  if [ -n "$TUNNEL_PID" ] && kill -0 "$TUNNEL_PID" 2>/dev/null; then
    kill "$TUNNEL_PID" 2>/dev/null || true
  fi
  # 日志和地址文件故意保留：断开之后还能回查上次的地址和 cloudflared 的错误。
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------- 先开隧道
TUNNEL_URL=""
if [ "$USE_TUNNEL" = 1 ]; then
  ensure_cloudflared
  # 上一次没退干净时会抢同一个端口/两条隧道，这里先提醒一下。
  if command -v pgrep >/dev/null 2>&1 && pgrep -f "cloudflared tunnel" >/dev/null 2>&1; then
    warn "已经有 cloudflared 在跑；如果那是上一次留下的，先 kill 掉再继续"
  fi
  : > "$TUNNEL_LOG"
  log "启动 Cloudflare 临时隧道 -> http://127.0.0.1:${PORT}（日志: ${TUNNEL_LOG}）"
  cloudflared tunnel --url "http://127.0.0.1:$PORT" --no-autoupdate >"$TUNNEL_LOG" 2>&1 &
  TUNNEL_PID=$!
  for _ in $(seq 1 90); do
    TUNNEL_URL="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$TUNNEL_LOG" 2>/dev/null | head -1 || true)"
    [ -n "$TUNNEL_URL" ] && break
    if ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
      cat "$TUNNEL_LOG" >&2
      die "cloudflared 提前退出"
    fi
    sleep 1
  done
  [ -n "$TUNNEL_URL" ] || die "90 秒内没拿到 trycloudflare 地址，日志在 $TUNNEL_LOG"
  printf '%s/\n' "$TUNNEL_URL" > "$TUNNEL_URL_FILE" 2>/dev/null || true
fi

# ---------------------------------------------------------------- 组装参数
TUNNEL_HOST=""
if [ -n "$TUNNEL_URL" ]; then
  TUNNEL_HOST="${TUNNEL_URL#https://}"
  TUNNEL_HOST="${TUNNEL_HOST%%/*}"
fi

DSH_ARGS=(web -pwd "$PASSWORD" --host 127.0.0.1 --port "$PORT")
if [ -n "$TUNNEL_URL" ]; then
  # cloudflared 会把公网域名放进 Host 头，harness 的 /api 主机栅栏只接受
  # loopback、监听地址和 --trusted-host 里列出的 authority，所以要显式放行。
  DSH_ARGS+=(--trusted-host "$TUNNEL_HOST" --public-url "$TUNNEL_URL/")
  DSH_ARGS+=(--no-open)
fi

cat <<EOF

============================================================
  DeepSeek Harness (密码登录 + 首次来源 IP 绑定)
------------------------------------------------------------
  本地地址 : http://127.0.0.1:$PORT
EOF
if [ -n "$TUNNEL_URL" ]; then
cat <<EOF
  公网地址 : $TUNNEL_URL/
             ↑ 用浏览器打开这个地址。临时隧道：每次重启换新地址，
               旧地址会变成 Cloudflare Error 1033，丢掉重跑即可。
               上次的地址也写在这里：$TUNNEL_URL_FILE
EOF
else
cat <<EOF
  公网地址 : (未开启隧道；加 --tunnel 可挂 Cloudflare 临时域名)
EOF
fi
cat <<EOF
  登录密码 : 启动时 -pwd 指定的密码
  IP 绑定  : 第一个输对密码的来源 IP 会被记住，之后只有它能访问；
             换网络或重启服务后需要重新输入密码
============================================================

EOF

log "启动 dsh web"
printf '  node --import tsx/esm apps/cli/src/bin.ts %s\n\n' "${DSH_ARGS[*]}"
node --import tsx/esm apps/cli/src/bin.ts "${DSH_ARGS[@]}" ${EXTRA[@]+"${EXTRA[@]}"}
