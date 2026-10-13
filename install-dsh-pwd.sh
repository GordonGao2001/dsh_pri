#!/usr/bin/env bash
#
# 拉取 deepseek-harness 源码，打上「-pwd 密码登录 + 首次来源 IP 绑定」补丁，然后构建。
#
# 用法:
#   ./install-dsh-pwd.sh                  # 默认装到 ~/deepseek-harness-pwd
#   ./install-dsh-pwd.sh --dir /opt/dsh   # 指定目录
#   ./install-dsh-pwd.sh --no-build       # 只拉取并打补丁，不安装依赖/不构建
#   ./install-dsh-pwd.sh --force-patch    # 目录里已有源码时，先丢弃本地改动再打补丁
#
# 环境变量:
#   DSH_SRC            源码目录 (同 --dir)
#   DSH_REPO_URL       仓库地址，默认官方 GitHub
#   DSH_PINNED_COMMIT  补丁对应的上游提交，默认见下
#   DSH_PATCH          补丁文件路径，默认与本脚本同目录
#
set -euo pipefail

REPO_URL="${DSH_REPO_URL:-https://github.com/deepseek-ai/deepseek-harness.git}"
# 补丁是对着这个提交生成的；上游一旦改动，补丁可能需要 3-way 合并。
PINNED_COMMIT="${DSH_PINNED_COMMIT:-d743267388641bc76f17c45ce8b4c231aed1d32c}"
SRC_DIR="${DSH_SRC:-$HOME/deepseek-harness-pwd}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_FILE="${DSH_PATCH:-$HERE/dsh-password-auth.patch}"
PNPM_VERSION="11.28.5"
DO_BUILD=1
FORCE_PATCH=0
FORCE_REBUILD=0

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!!  %s\033[0m\n' "$*" >&2; }
die()  { printf '\n\033[1;31m!!  %s\033[0m\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
拉取 deepseek-harness 源码，打上「-pwd 密码登录 + 首次来源 IP 绑定」补丁，然后构建。

用法:
  ./install-dsh-pwd.sh                  # 默认装到 ~/deepseek-harness-pwd
  ./install-dsh-pwd.sh --dir /opt/dsh   # 指定目录
  ./install-dsh-pwd.sh --no-build       # 只拉取并打补丁，不安装依赖/不构建
  ./install-dsh-pwd.sh --force-patch    # 已有源码时先丢弃本地改动再打补丁
  ./install-dsh-pwd.sh --rebuild        # 忽略「已构建过」的记录，强制重装依赖并重新构建

环境变量:
  DSH_SRC            源码目录 (同 --dir)
  DSH_REPO_URL       仓库地址，默认官方 GitHub
  DSH_PINNED_COMMIT  补丁对应的上游提交，默认见脚本内
  DSH_PATCH          补丁文件路径，默认与本脚本同目录
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) SRC_DIR="$2"; shift 2 ;;
    --patch) PATCH_FILE="$2"; shift 2 ;;
    --no-build) DO_BUILD=0; shift ;;
    --force-patch) FORCE_PATCH=1; shift ;;
    --force-rebuild|--rebuild) FORCE_REBUILD=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数: $1" ;;
  esac
done

# ---------------------------------------------------------------- 前置检查
command -v git  >/dev/null 2>&1 || die "缺少 git"
command -v node >/dev/null 2>&1 || die "缺少 Node.js (需要 >= 22.19，推荐 24)"
node -e 'const [a,b]=process.versions.node.split(".").map(Number); process.exit(a>22||(a===22&&b>=19)?0:1)' \
  || die "Node.js 版本过低: $(node -v) — 需要 >= 22.19 (推荐 24)"
[ -f "$PATCH_FILE" ] || die "找不到补丁文件: $PATCH_FILE"
echo "Node  $(node -v)"
echo "源码  $SRC_DIR"
echo "补丁  $PATCH_FILE"

# ---------------------------------------------------------------- 拉源码
if [ -d "$SRC_DIR/.git" ]; then
  log "复用已有仓库 ${SRC_DIR}（不重新克隆）"
elif [ -e "$SRC_DIR" ]; then
  die "$SRC_DIR 已存在但不是 git 仓库，请换个 --dir 或先清理它"
else
  log "克隆 $REPO_URL"
  # 克隆到临时目录再改名：中途失败也不会留下半个目录、更不会删掉已有内容。
  tmp="$SRC_DIR.clone.$$"
  rm -rf "$tmp"
  # 部分克隆：历史完整（能切到指定提交），文件按需拉取，比全量克隆小很多。
  if ! git clone --filter=blob:none "$REPO_URL" "$tmp"; then
    warn "部分克隆失败（服务器或代理不支持 filter），改用普通克隆重试"
    rm -rf "$tmp"
    git clone "$REPO_URL" "$tmp" || { rm -rf "$tmp"; die "克隆 $REPO_URL 失败"; }
  fi
  mkdir -p "$(dirname "$SRC_DIR")"
  mv "$tmp" "$SRC_DIR"
fi

cd "$SRC_DIR"
git fetch --tags origin >/dev/null 2>&1 || warn "git fetch 失败，使用本地已有提交"

if [ "$FORCE_PATCH" = 1 ]; then
  log "丢弃本地改动 (--force-patch)"
  git checkout -- . 2>/dev/null || true
  git clean -fd packages apps 2>/dev/null || true
fi

if git cat-file -e "${PINNED_COMMIT}^{commit}" 2>/dev/null; then
  log "切换到补丁对应的提交 ${PINNED_COMMIT:0:10}"
  git checkout --detach "$PINNED_COMMIT"
else
  warn "本地没有提交 ${PINNED_COMMIT}，停在当前分支；补丁会用 3-way 尝试应用"
fi

# ---------------------------------------------------------------- 打补丁
log "应用密码登录补丁"
if git apply --reverse --check "$PATCH_FILE" >/dev/null 2>&1; then
  log "补丁已经在这个目录里，跳过"
elif git apply --check "$PATCH_FILE" >/dev/null 2>&1; then
  git apply "$PATCH_FILE"
  log "补丁应用成功"
else
  warn "直接应用失败（上游可能已改动），尝试 3-way 合并"
  git apply --3way "$PATCH_FILE" || die "补丁无法应用。请用 DSH_PINNED_COMMIT=<合适提交> 重试，或手动处理冲突。"
fi
git --no-pager diff --stat | tail -3

if [ "$DO_BUILD" = 0 ]; then
  log "已按要求跳过依赖安装与构建 (--no-build)"
  exit 0
fi

# ---------------------------------------------------------------- 是不是已经构建过
# 记录「用哪个补丁构建成功过」：同一台机器上重复执行时，直接跳过 install + build。
PATCH_SHA="$( (shasum -a 256 "$PATCH_FILE" 2>/dev/null || sha256sum "$PATCH_FILE") | awk '{print $1}')"
BUILD_MARKER="$SRC_DIR/.dsh-pwd-build.ok"
if [ "$FORCE_REBUILD" = 0 ] && [ -f "$BUILD_MARKER" ] && [ "$(cat "$BUILD_MARKER")" = "$PATCH_SHA" ] \
  && [ -d "$SRC_DIR/node_modules" ] && [ -f "$SRC_DIR/apps/web/dist/index.html" ]; then
  log "已经用同一个补丁 (${PATCH_SHA:0:12}) 构建过，跳过依赖安装与构建"
  log "（要强制重来请加 --rebuild）"
  exit 0
fi

# ---------------------------------------------------------------- pnpm
if ! command -v pnpm >/dev/null 2>&1; then
  log "未找到 pnpm，尝试安装 pnpm@$PNPM_VERSION"
  corepack enable >/dev/null 2>&1 || true
  if ! command -v pnpm >/dev/null 2>&1; then
    npm install -g "pnpm@$PNPM_VERSION" >/dev/null 2>&1 || warn "全局安装 pnpm 失败，改用 npx"
  fi
fi
if command -v pnpm >/dev/null 2>&1; then
  PNPM=(pnpm)
else
  PNPM=(npx --yes "pnpm@$PNPM_VERSION")
fi
echo "pnpm  ${PNPM[*]}"

# ---------------------------------------------------------------- 安装 + 构建
if [ -d "$SRC_DIR/node_modules" ]; then
  log "已有 node_modules，跳过 pnpm install"
else
  log "安装依赖 (pnpm install) —— 首次会下载大量包，请耐心等待"
  "${PNPM[@]}" install
fi

log "构建 (pnpm run build) —— 需要编译整个 monorepo 与前端，通常 10 分钟以上"
"${PNPM[@]}" run build

[ -f "$SRC_DIR/apps/web/dist/index.html" ] || die "构建结束但没有找到 apps/web/dist/index.html，构建可能失败"
printf '%s\n' "$PATCH_SHA" > "$BUILD_MARKER"
log "完成。启动方式："
cat <<EOF

  ./run-dsh-web.sh -pwd 你的密码

  或直接：

  cd "$SRC_DIR"
  node --import tsx/esm apps/cli/src/bin.ts web -pwd 你的密码 --no-open

EOF
