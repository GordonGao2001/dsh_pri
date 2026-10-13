#!/usr/bin/env bash
#
# 对**已经在运行**的、打过补丁的 dsh web 做端到端检查（需要先构建好）。
#
# 用法:
#   ./verify/check-http-gate.sh -pwd <密码> [--port 3080] [--host 127.0.0.1]
#
# 它会验证：
#   1. 未登录访问 / 得到密码页（不是 harness 界面）
#   2. ?token=... 这种旧的启动 token 已经失效
#   3. 密码错误 -> 401，密码正确 -> 303 + 会话 cookie
#   4. 带 cookie 才能拿到真正的界面
#   5. 换一个来源 IP（模拟隧道转发）即使带 cookie 也会被拒
#   6. 另一个 IP 即使输对密码也会被拒（绑定在第一个 IP 上）
#   7. /api 没有会话时是 401
#
set -euo pipefail

PASSWORD=""
HOST="127.0.0.1"
PORT=3080

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31m!!  %s\033[0m\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
对已经在运行的、打过补丁的 dsh web 做端到端检查（需要先构建好）。

用法:
  ./verify/check-http-gate.sh -pwd <密码> [--port 3080] [--host 127.0.0.1]

它会验证:
  1. 未登录访问 / 得到密码页（不是 harness 界面）
  2. ?token=... 这种旧的启动 token 已经失效
  3. 密码错误 -> 401，密码正确 -> 303 + 会话 cookie
  4. 带 cookie 才能拿到真正的界面
  5. 换一个来源 IP（模拟隧道转发头）即使带 cookie 也会被拒
  6. 另一个 IP 即使输对密码也会被拒（绑定在第一个 IP 上）
  7. /api 没有会话时是 401
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -pwd|--pwd) PASSWORD="$2"; shift 2 ;;
    -pwd=*) PASSWORD="${1#-pwd=}"; shift ;;
    --pwd=*) PASSWORD="${1#--pwd=}"; shift ;;
    --host) HOST="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数: $1" ;;
  esac
done

[ -n "$PASSWORD" ] || die "需要 -pwd <密码>（就是启动服务时用的那个）"
command -v curl >/dev/null 2>&1 || die "需要 curl"

BASE="http://$HOST:$PORT"
WORK="$(mktemp -d -t dsh-gate-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
check() { # check <说明> <实际> <期望>
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1)); printf '  ok   %s (%s)\n' "$1" "$2"
  else
    fail=$((fail + 1)); printf '  FAIL %s 期望 %s 实际 %s\n' "$1" "$3" "$2"
  fi
}
code() { # code <输出文件> [curl 参数...]
  local out="$1"; shift
  curl -sS -o "$out" -w '%{http_code}' "$@" 2>/dev/null || echo 000
}

log "目标 $BASE"
curl -sS -o /dev/null --max-time 5 "$BASE/" 2>/dev/null || die "连不上 ${BASE}，服务没在跑？"

log "1) 未登录访问 /"
status="$(code "$WORK/anon.html" "$BASE/")"
check "返回 200" "$status" "200"
grep -q '<form' "$WORK/anon.html" && grep -q '__dsh_login' "$WORK/anon.html" \
  && { pass=$((pass+1)); echo "  ok   拿到的是密码页"; } \
  || { fail=$((fail+1)); echo "  FAIL 页面里没有密码表单"; }
grep -q 'id="root"' "$WORK/anon.html" \
  && { fail=$((fail+1)); echo "  FAIL 未登录就拿到了界面"; } \
  || { pass=$((pass+1)); echo "  ok   没有泄漏界面"; }

log "2) 旧的 ?token= 启动令牌"
status="$(code "$WORK/token.html" "$BASE/?token=deadbeefdeadbeef")"
check "返回 200（密码页，而不是直接登录）" "$status" "200"
grep -q '<form' "$WORK/token.html" \
  && { pass=$((pass+1)); echo "  ok   ?token= 不再能直接登录"; } \
  || { fail=$((fail+1)); echo "  FAIL ?token= 竟然还是被接受了"; }

log "3) 密码错误的提交"
status="$(code "$WORK/wrong.html" -X POST "$BASE/__dsh_login" --data-urlencode 'password=definitely-wrong')"
check "返回 401" "$status" "401"

log "4) 密码正确的提交"
status="$(code "$WORK/right.html" -X POST "$BASE/__dsh_login" --data-urlencode "password=$PASSWORD" -c "$WORK/cookies.txt" -D "$WORK/right.headers")"
check "返回 303" "$status" "303"
grep -qi '^set-cookie: dsh-auth-' "$WORK/right.headers" \
  && { pass=$((pass+1)); echo "  ok   下发了会话 cookie"; } \
  || { fail=$((fail+1)); echo "  FAIL 没有下发 cookie"; }

log "5) 带 cookie 访问 /"
status="$(code "$WORK/app.html" "$BASE/" -b "$WORK/cookies.txt")"
check "返回 200" "$status" "200"
grep -q 'id="root"' "$WORK/app.html" \
  && { pass=$((pass+1)); echo "  ok   拿到真正的界面"; } \
  || { fail=$((fail+1)); echo "  FAIL 没有拿到界面"; }
grep -q '<form' "$WORK/app.html" \
  && { fail=$((fail+1)); echo "  FAIL 带着 cookie 还是密码页"; } \
  || { pass=$((pass+1)); echo "  ok   不再是密码页"; }

log "6) 别人的 IP 盗用 cookie（模拟隧道转发头）"
status="$(code "$WORK/stolen.html" "$BASE/" -b "$WORK/cookies.txt" -H 'CF-Connecting-IP: 203.0.113.9')"
check "返回 403" "$status" "403"

log "7) 别人的 IP 输对密码"
status="$(code "$WORK/other-ip.html" -X POST "$BASE/__dsh_login" --data-urlencode "password=$PASSWORD" -H 'CF-Connecting-IP: 198.51.100.7')"
check "返回 403" "$status" "403"

log "8) 没有会话访问 /api"
status="$(code "$WORK/api.txt" -X POST "$BASE/api/probe" -H 'content-type: application/json' --data '{}')"
check "返回 401" "$status" "401"

log "9) 带 cookie 的 /api 不再是 401（应是 403/404/405 之类的业务响应）"
api_status="$(code "$WORK/api2.txt" -X POST "$BASE/api/probe" -H 'content-type: application/json' --data '{}' -b "$WORK/cookies.txt")"
if [ "$api_status" = "401" ]; then
  fail=$((fail + 1)); echo "  FAIL 带 cookie 的 /api 仍然 401"
else
  pass=$((pass + 1)); echo "  ok   /api 通过了会话校验（${api_status}）"
fi

echo ""
echo "$pass 项通过, $fail 项失败"
[ "$fail" = 0 ] || exit 1
