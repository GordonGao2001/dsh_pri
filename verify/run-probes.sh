#!/usr/bin/env bash
#
# 不构建整个 monorepo 也能验证补丁的核心逻辑：
# 直接把打过补丁的 browser-auth.ts / startup.ts 拿出来，配假的请求对象跑一遍。
#
# 用法:
#   ./verify/run-probes.sh [源码目录]
#   源码目录默认 $DSH_SRC 或 ~/deepseek-harness-pwd
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${1:-${DSH_SRC:-$HOME/deepseek-harness-pwd}}"
WORK="$(mktemp -d -t dsh-probes-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

command -v node >/dev/null 2>&1 || { echo "需要 node" >&2; exit 1; }
[ -f "$SRC/packages/client/connection/src/browser-auth.ts" ] || { echo "找不到 $SRC 里的源码" >&2; exit 1; }

NODE_FLAGS=(--experimental-transform-types --no-warnings)
status=0

# ---------------------------------------------------------------- 探针 1: 密码门 + IP 绑定
echo ""
echo "################ 1/2  BrowserAuth 密码门 ################"
mkdir -p "$WORK/auth/node_modules/@deepseek-ai/dsh-credentials"
cat > "$WORK/auth/node_modules/@deepseek-ai/dsh-credentials/package.json" <<'EOF'
{ "name": "@deepseek-ai/dsh-credentials", "version": "0.0.0", "type": "module", "main": "index.js", "exports": { ".": "./index.js" } }
EOF
cat > "$WORK/auth/node_modules/@deepseek-ai/dsh-credentials/index.js" <<'EOF'
export function credentialKey(...parts) { return parts.join('/') }
EOF
cp "$SRC/packages/client/connection/src/browser-auth.ts" "$WORK/auth/browser-auth.ts"
cp "$HERE/browser-auth.probe.ts" "$WORK/auth/probe.ts"
( cd "$WORK/auth" && node "${NODE_FLAGS[@]}" probe.ts ) || status=1

# ---------------------------------------------------------------- 探针 2: -pwd 参数解析
echo ""
echo "################ 2/2  -pwd 命令行 ################"
mkdir -p "$WORK/startup/node_modules/@deepseek-ai/dsh-cmdline" \
         "$WORK/startup/node_modules/@deepseek-ai/dsh-host-webserver"
cat > "$WORK/startup/node_modules/@deepseek-ai/dsh-cmdline/package.json" <<'EOF'
{ "name": "@deepseek-ai/dsh-cmdline", "version": "0.0.0", "type": "module", "main": "index.js", "exports": { ".": "./index.js" } }
EOF
cat > "$WORK/startup/node_modules/@deepseek-ai/dsh-cmdline/index.js" <<EOF
export * from '$SRC/packages/boot/cmdline/src/index.ts'
EOF
cat > "$WORK/startup/node_modules/@deepseek-ai/dsh-host-webserver/package.json" <<'EOF'
{ "name": "@deepseek-ai/dsh-host-webserver", "version": "0.0.0", "type": "module", "main": "index.js", "exports": { ".": "./index.js" } }
EOF
cat > "$WORK/startup/node_modules/@deepseek-ai/dsh-host-webserver/index.js" <<'EOF'
export function isWildcardHost(host) { return host === '0.0.0.0' || host === '::' }
EOF
COMMANDER_SRC=""
GLOBAL_ROOT="$(npm root -g 2>/dev/null || true)"
for candidate in \
  "$SRC/node_modules/commander" \
  "$GLOBAL_ROOT/@deepseek-ai/dsh/node_modules/commander" \
  "$GLOBAL_ROOT/commander"; do
  if [ -n "$candidate" ] && [ -d "$candidate" ]; then
    COMMANDER_SRC="$candidate"
    break
  fi
done
if [ -n "$COMMANDER_SRC" ]; then
  echo "(commander 取自 $COMMANDER_SRC)"
  cp -R "$COMMANDER_SRC" "$WORK/startup/node_modules/commander"
else
  echo "!! 找不到 commander：先在源码目录执行 pnpm install，或者 npm i -g commander" >&2
  status=1
fi
cp "$SRC/packages/bundle/web-app/src/startup.ts" "$WORK/startup/startup.ts"
cp "$SRC/packages/bundle/web-app/src/public-url.ts" "$WORK/startup/public-url.ts"
cp "$HERE/startup.probe.ts" "$WORK/startup/probe.ts"
( cd "$WORK/startup" && node "${NODE_FLAGS[@]}" probe.ts ) || status=1

echo ""
if [ "$status" = 0 ]; then
  echo "两个探针全部通过 ✅"
else
  echo "有探针失败 ❌" >&2
fi
exit "$status"
