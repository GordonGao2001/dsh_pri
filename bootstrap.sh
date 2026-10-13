#!/usr/bin/env bash
#
# 全新空机器上的一条命令：准备 Node → 拉 deepseek-harness 并打补丁 → 构建（已构建过就跳过）→ 启动。
# 每一步都可重复执行：已经完成的步骤会跳过，不会重新克隆、重新编译。
#
# 用法:
#   # 方式 1（private 仓库推荐）：先拉工具仓库，再一条命令跑起来
#   git clone https://github.com/GordonGao2001/dsh_pri.git ~/dsh_pri
#   ~/dsh_pri/bootstrap.sh -pwd '你的密码' --tunnel
#
#   # 方式 2（仓库设为 public 之后）：
#   bash <(curl -fsSL https://raw.githubusercontent.com/GordonGao2001/dsh_pri/main/bootstrap.sh) -pwd '你的密码' --tunnel
#
# 参数:
#   -pwd <密码>        必填。网页上要输入的密码，也是首次来源 IP 绑定的依据
#   --tunnel           同时开 Cloudflare 临时隧道（trycloudflare）
#   --port <端口>      监听端口，默认 3080
#   --dir <目录>       harness 源码目录，默认 ~/deepseek-harness-pwd
#   --tool-dir <目录>  工具仓库目录，默认 ~/dsh_pri（脚本不在仓库里时自动克隆到这里）
#   --rebuild          强制重新安装依赖并重新构建
#   --prepare-only     只准备环境（Node/源码/构建），不启动服务
#   --node <版本>      需要时安装的 Node 版本，默认 v24.15.0
#
set -euo pipefail

TOOL_REPO="${DSH_PRI_REPO:-https://github.com/GordonGao2001/dsh_pri.git}"
NODE_VERSION="${DSH_NODE_VERSION:-v24.15.0}"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!!  %s\033[0m\n' "$*" >&2; }
die()  { printf '\n\033[1;31m!!  %s\033[0m\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------- 0. 找到工具仓库
# 用 curl | bash 跑的时候脚本不在仓库里，这里先把自己需要的文件拉下来，再交给仓库里的脚本。
if [ ! -f "$SELF_DIR/dsh-password-auth.patch" ]; then
  TOOL_DIR="${DSH_PRI_DIR:-$HOME/dsh_pri}"
  if [ ! -f "$TOOL_DIR/dsh-password-auth.patch" ]; then
    have git || die "缺少 git；请先安装 git（apt-get install -y git / yum install -y git）"
    log "拉取工具仓库到 $TOOL_DIR"
    rm -rf "$TOOL_DIR.clone.$$"
    git clone --depth 1 "$TOOL_REPO" "$TOOL_DIR.clone.$$" || die "克隆 $TOOL_REPO 失败（private 仓库需要 https://<token>@github.com/... 或配好 SSH key）"
    mkdir -p "$(dirname "$TOOL_DIR")"
    [ -e "$TOOL_DIR" ] && rm -rf "$TOOL_DIR"
    mv "$TOOL_DIR.clone.$$" "$TOOL_DIR"
  fi
  log "转到 $TOOL_DIR/bootstrap.sh 继续"
  exec "$TOOL_DIR/bootstrap.sh" "$@"
fi
TOOL_DIR="$SELF_DIR"

# ---------------------------------------------------------------- 1. 解析参数
PASSWORD=""
PORT=3080
SRC_DIR="${DSH_SRC:-$HOME/deepseek-harness-pwd}"
USE_TUNNEL=0
REBUILD=0
PREPARE_ONLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    -pwd|--pwd) [ $# -ge 2 ] || die "-pwd 后面要跟密码"; PASSWORD="$2"; shift 2 ;;
    -pwd=*) PASSWORD="${1#-pwd=}"; shift ;;
    --pwd=*) PASSWORD="${1#--pwd=}"; shift ;;
    --tunnel) USE_TUNNEL=1; shift ;;
    --port) [ $# -ge 2 ] || die "--port 后面要跟端口号"; PORT="$2"; shift 2 ;;
    --dir) SRC_DIR="$2"; shift 2 ;;
    --tool-dir) shift 2 ;;
    --rebuild) REBUILD=1; shift ;;
    --prepare-only) PREPARE_ONLY=1; shift ;;
    --node) NODE_VERSION="$2"; shift 2 ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) die "未知参数: $1" ;;
  esac
done

# 先把密码检查掉：否则会在十几分钟的构建之后才报错。
if [ "$PREPARE_ONLY" = 0 ]; then
  [ -n "$PASSWORD" ] || die "必须用 -pwd <密码> 指定网页访问密码，例如: $0 -pwd 'my-secret-123' --tunnel"
  [ "${#PASSWORD}" -ge 4 ] || die "密码至少要 4 个字符"
fi

# ---------------------------------------------------------------- 2. 准备 Node
node_ok() {
  have node && node -e 'const [a,b]=process.versions.node.split(".").map(Number);process.exit(a>22||(a===22&&b>=19)?0:1)' 2>/dev/null
}

ensure_node() {
  if node_ok; then
    echo "Node  $(node -v)（已满足 >= 22.19）"
    return 0
  fi
  if have node; then warn "现有 Node $(node -v) 太旧，需要 >= 22.19，改为安装 $NODE_VERSION"; fi
  have curl || die "缺少 curl，无法自动安装 Node"
  local os arch plat dir tarball
  os="$(uname -s)"; arch="$(uname -m)"
  case "$os-$arch" in
    Linux-x86_64)              plat="linux-x64" ;;
    Linux-aarch64|Linux-arm64) plat="linux-arm64" ;;
    Darwin-x86_64)             plat="darwin-x64" ;;
    Darwin-arm64)              plat="darwin-arm64" ;;
    *) die "不认识的平台 $os-${arch}，请自己装 Node >= 22.19" ;;
  esac
  dir="$HOME/.local/node-$NODE_VERSION-$plat"
  if [ ! -x "$dir/bin/node" ]; then
    tarball="/tmp/node-$NODE_VERSION-$plat.tar.gz"
    log "安装 Node $NODE_VERSION ($plat) 到 $dir"
    curl -fsSL "https://nodejs.org/dist/$NODE_VERSION/node-$NODE_VERSION-$plat.tar.gz" -o "$tarball" \
      || die "下载 Node 失败（网络受限？也可以自己装好 Node 再跑）"
    mkdir -p "$dir"
    tar -xzf "$tarball" -C "$dir" --strip-components=1
    rm -f "$tarball"
  fi
  export PATH="$dir/bin:$PATH"
  node_ok || die "Node 安装后仍不可用：$dir/bin/node"
  echo "Node  $(node -v)（${dir}；本次会话有效）"
}

log "1/3 检查运行环境"
have git || die "缺少 git；请先安装 git（apt-get install -y git / yum install -y git）"
ensure_node

# ---------------------------------------------------------------- 3. 源码 + 补丁 + 构建
log "2/3 准备 deepseek-harness 源码并打补丁"
INSTALL_ARGS=(--dir "$SRC_DIR")
[ "$REBUILD" = 1 ] && INSTALL_ARGS+=(--force-rebuild)
"$TOOL_DIR/install-dsh-pwd.sh" "${INSTALL_ARGS[@]}"

if [ "$PREPARE_ONLY" = 1 ]; then
  log "已按要求只准备环境（--prepare-only），不启动"
  echo "启动命令： $TOOL_DIR/run-dsh-web.sh -pwd '你的密码'$([ "$USE_TUNNEL" = 1 ] && echo ' --tunnel') --port $PORT --dir $SRC_DIR"
  exit 0
fi

# ---------------------------------------------------------------- 4. 启动
log "3/3 启动 dsh web"
RUN_ARGS=(-pwd "$PASSWORD" --port "$PORT" --dir "$SRC_DIR")
[ "$USE_TUNNEL" = 1 ] && RUN_ARGS+=(--tunnel)
exec "$TOOL_DIR/run-dsh-web.sh" "${RUN_ARGS[@]}"
