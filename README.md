# deepseek-harness 密码登录 + Cloudflare 临时隧道

把 [deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)（`dsh web` 那个本地 GUI）的
**启动 token 登录**换成一套自己的规则：

| 项目 | 上游原来的行为 | 打补丁之后 |
| --- | --- | --- |
| 登录凭据 | 每次启动随机生成 token，拼在 URL 上：`dsh web: http://127.0.0.1:3080/?token=xxxx` | 启动时必须自己给：`dsh web -pwd 你的密码` |
| 打开网页看到什么 | 带着 `?token=` 直接进界面；不带就是一行 401 文本 | 一个密码输入页；输对了才进界面 |
| 谁能用 | 拿到那条带 token 的 URL 的人 | **第一个输对密码的来源 IP**；之后其它 IP 即使有 cookie、即使密码正确也一律拒绝 |
| 会话 cookie | 绑定 authority | 绑定 authority **+ 来源 IP**，且该 IP 必须是当前绑定的那个 |

补丁针对上游提交 `d743267388641bc76f17c45ce8b4c231aed1d32c`（v0.2.1-alpha.2）生成，
`dsh-password-auth.patch` 是完整 diff，可以直接看、可以直接 `git apply`。

---

## 目录内容

| 文件 | 作用 |
| --- | --- |
| `dsh-password-auth.patch` | 补丁本体（17 个文件改动） |
| `install-dsh-pwd.sh` | 拉源码 → 打补丁 → `pnpm install` → `pnpm run build` |
| `run-dsh-web.sh` | 启动 `dsh web -pwd ...`，可加 `--tunnel` 挂 Cloudflare 临时域名 |
| `dsh_cloudflare_colab.py` | 仿 ComfyUI 那个 Colab 脚本写的版本：装 Node/cloudflared、拉源码打补丁构建、起隧道（补丁本体以 base64 内嵌在文件里，单文件即可用） |
| `verify/run-probes.sh` | 不用构建整个仓库就能跑的逻辑验证（45 + 26 项断言） |
| `verify/check-http-gate.sh` | 对跑起来的服务做端到端验证（curl，9 组检查） |

---

## 快速开始

### 本地（macOS / Linux）

```bash
cd dsh-pwd-cloudflare

# 1) 拉源码 + 打补丁 + 构建（第一次十几分钟，会编译整个 monorepo）
./install-dsh-pwd.sh                       # 默认装到 ~/deepseek-harness-pwd

# 2) 本机跑
./run-dsh-web.sh -pwd 'my-secret-123'

# 3) 或者同时挂 Cloudflare 临时隧道（会打印 https://xxx.trycloudflare.com）
./run-dsh-web.sh -pwd 'my-secret-123' --tunnel
```

`--tunnel` 会先起 cloudflared 拿到公网域名，再带着
`--trusted-host <域名> --public-url https://<域名>/` 启动 harness（原因见下面「Host 头」一节），
所以打印出来的公网地址就是可以直接发给别人（其实只有你自己能用，见下）的地址。

### Colab

把 `dsh_cloudflare_colab.py` 的三个 `# @title` 段分别粘成三个单元格，先跑第一段（装环境+构建），
在第二段里改密码，再跑第三段。也可以直接 `python dsh_cloudflare_colab.py`。

第二段里的 `launch_now` 设成 `False` 时只做「装环境 / 构建 / 打补丁」，不起服务也不开隧道 ——
想先把构建跑完、之后再手动启动时用这个。密码、端口、隧道开关也都在第二段的 `# @param` 里。

> 构建很吃内存和时间，Colab 上建议选「高内存」运行时。

---

## 补丁改了什么

### 1. 删掉启动 token，换成 `-pwd`

* `packages/client/connection/src/browser-auth.ts` —— 整个重写。
  删掉 `?token=` 查询参数、进程级随机 `launchToken`、`PROCESS_LAUNCH_TOKENS`、`authenticatedUrl()`；
  换成密码校验、密码页、来源 IP 绑定。
* `packages/bundle/web-app/src/index.ts` —— 打印/打开的 URL 不再带 token，就是干净地址。
* `packages/client/connection/src/rpc.ts`、`src/rpc-host.ts` ——
  删掉 `authenticatedUrl`，新增 `handleLogin()`；请求事实里补上 TCP 对端（`socket.remoteAddress`）。

### 2. 命令行必须带 `-pwd`

* `packages/bundle/web-app/src/startup.ts` —— 新增 `-pwd <password>`（**必填**，少于 4 个字符也拒绝），
  值通过 `webStartup` 服务交给 Connection。
* `packages/boot/cmdline/src/index.ts` —— `parseCmdline` 多了一个可选的参数改写钩子。
  为什么需要这个：commander 不接受多字符短参数，`-pwd secret` 会被拆成 `-p -w -d`，
  结果是密码变成 `wd`、`secret` 变成多余参数（静默出错！）。所以 `-pwd` 会在解析前被改写成 `--pwd`。
  `-pwd xxx` / `-pwd=xxx` / `-pwdxxx` / `--pwd xxx` 都认。
* `packages/bundle/web-app/cordis.patch.yml` —— connection 行把密码传下去。

### 3. 网页变成密码页

* 未登录访问 `/` 不再返回 401 文本，而是返回一张自带的密码页
  （自带样式、无外部资源、`<form method="post">`，禁 JS 也能用，表单 action 是相对路径所以路径前缀反代也正常）。
* 提交地址是新增的具名路由 `/__dsh_login`（因为 dist 兜底路由只处理 GET/HEAD，POST 会被 405 挡掉）。
* 密码对了：下发 `HttpOnly; SameSite=Lax` 的签名 cookie（HTTP 下不加 `Secure`，TLS 下自动加上），然后 303 跳回 `./`。
* 密码错了：401 + 密码页；`GET /__dsh_login` 也能直接看表单；其他方法 405。

### 4. 来源 IP 绑定

* 第一次输对密码的 IP 被记在本进程里；此后：
  * 其它 IP 的 `GET /` -> 403（连密码页都不给）；
  * 其它 IP 即使 **输对密码** 也是 403；
  * 别人偷走 cookie 也没用，cookie 里签了它自己的 IP，且必须要等于当前绑定的 IP。
* 重启服务后绑定清空，需要重新输一次密码（这是有意的：重启后旧 cookie 一并失效）。
* **隧道场景**下 TCP 对端永远是 `127.0.0.1`（cloudflared 在本机连过来），
  所以当且仅当对端是 loopback 时会去读 `CF-Connecting-IP` / `X-Forwarded-For` / `X-Real-IP`，
  取到真实客户端 IP 再绑定；远端直连（对端不是 loopback）则忽略这些头，防止伪造。

### 5. `authenticatedUrl()` 保留为「兼容垫片」

这个方法原来是「把进程 token 拼到 URL 上」，现在**原样返回传入的 URL、不再加任何凭据**，
方法名和签名都保留。原因是 `tsconfig.host.json` / `tsconfig.client.json` 会把测试和 benchmark
一起做类型检查（`packages/*/*/tests/**`、`apps/*/tests/**`、`benchmarks/**`），
里面有十来处（`packages/api/*/tests`、`frontend-static.spec.ts`、`node-half.host.spec.ts`、
`apps/web/tests/scaffold.ts`、benchmark…）是在这个入口上取「可登录的 URL」。
删掉它会连带一片编译错误，所以留成垫片：**类型还在，凭据没有了**。
这些测试的运行时行为本来就需要按新逻辑重写（要 POST 密码换 cookie），属于已知遗留项。

### 6. 桌面版最小适配

`apps/desktop-host` 会为每次启动生成一个随机密码并通过 IPC 交给 Electron，
`apps/desktop/src/web-document.ts` 改成用 POST `/__dsh_login` 换 cookie。
桌面版整体流程没有完整回归测试，**本补丁主要面向 `dsh web` + 隧道**。

---

## Host 头 / 隧道为什么需要 `--trusted-host`

`/api` 有一道 Host 栅栏（防 DNS rebinding）：只接受 loopback、监听地址，以及 `--trusted-host` 里列出的 authority。
cloudflared 会把公网域名放在 `Host` 头里转发进来，所以不加 `--trusted-host xxx.trycloudflare.com` 时
页面能打开但所有 API 都会 403（界面一直转圈/连不上）。

`run-dsh-web.sh --tunnel` 和 Colab 脚本都替你做了这件事：先起隧道拿域名，再带着参数启动。

---

## 构建与自查（重要）

整个 monorepo 的类型检查会把**测试文件也一起查**，所以改这个补丁时，
不要直接跑十几分钟的完整构建，先只跑类型检查（`tsc -b`，增量、可重复跑）：

```bash
cd ~/deepseek-harness-pwd
node --max-old-space-size=4096 ./node_modules/typescript/bin/tsc -b tsconfig.host.json
node ./node_modules/typescript/bin/tsc -b tsconfig.client.json
```

两条都过了，再跑 `pnpm run build`（它在此基础上做 tsdown 打包和前端 vite 构建）。
`pnpm run build` 里没有测试，所以测试红了不影响构建产物。

两个已知的、**不影响构建**的历史遗留：

* `pnpm test` 里那些需要启动 web profile 的用例会失败 —— 它们没带 `-pwd`
  （`apps/cli/tests/web-agent-presets.e2e.ts`、`apps/web/tests/*.e2e.ts` 等）。
* 这些 e2e 用的是 `scaffold.authenticatedUrl`，在新逻辑下拿到的是干净 URL，
  浏览器会停在密码页，需要改成「先 POST 密码拿 cookie」。

---

## 验证

```bash
# 1) 逻辑层（不需要构建整个仓库，几秒钟）
./verify/run-probes.sh ~/deepseek-harness-pwd
#   -> BrowserAuth 密码门 45/45，-pwd 命令行 26/26

# 2) 端到端（需要先 install + build，并让服务跑着）
./run-dsh-web.sh -pwd 'my-secret-123' &
./verify/check-http-gate.sh -pwd 'my-secret-123'
#   -> 验证密码页、?token= 失效、错误/正确密码、cookie、换 IP 被拒、/api 401
```

`run-probes.sh` 直接拿打过补丁的 `browser-auth.ts` 和 `startup.ts` 跑：
前者用假的请求/响应对象验证密码门与 IP 绑定，后者用真实的 `dsh-cmdline` 源码验证 `-pwd` 参数解析。
我这边已经跑过：**45/45 与 26/26 全部通过**。

---

## 注意事项 / 已知限制

* **密码会出现在进程参数里**（`ps aux` 能看到 `-pwd xxx`），这是 `-pwd` 这种写法的固有代价。
  多用户机器上请注意；只想给自己用的话无所谓。
* **测试套件没有全部跟着改**。上游那些针对启动 token 写的测试（`apps/web/tests/*.e2e.ts`、
  `apps/cli/tests/*web*.e2e.ts`、`packages/api/gateway/tests/*` 等）都假设 URL 里带 `?token=`，
  没有 `-pwd` 也起不来，所以 `pnpm test` 里这些用例会红。**不影响 build 和运行**。
  已经完全改掉的：`packages/bundle/web-app/tests/web-app.spec.ts`、`browser-open.spec.ts`；
  直接删掉的：`packages/client/connection/tests/browser-auth.host.spec.ts`、`apps/cli/tests/web-auth.e2e.ts`
  （它们整篇就是在测 token 交换）。
* **上游代码会变**。`install-dsh-pwd.sh` 会切到补丁对应的提交；如果上游已经跑远，补丁会用
  `git apply --3way` 尝试合并，失败就报错退出，不会默默改坏。
* **换网络 / 换 IP 就进不去**了（这正是需求），需要重启服务重新输密码；
  想临时放开就重跑 `run-dsh-web.sh`。
* **`--tunnel` 的域名每次重启都会变**（trycloudflare 临时隧道就是这样），
  每次都要用新地址；要固定域名得用 Cloudflare 账号的命名隧道。
* 隧道把服务暴露到公网，安全边界就是这一个密码 + 一个 IP。
  密码别用弱口令；不确定的时候宁可用 `cloudflared access` 之类的额外一层。
* 想回到干净的上游代码：`cd <源码目录> && git checkout -- .`（或者 `git apply -R dsh-password-auth.patch`）。

---

## 补丁涉及的文件

```
apps/cli/tests/web-auth.e2e.ts                         | 210 -----   删除（整篇测 token）
apps/desktop-host/src/index.ts                         |  15 +-      每次启动生成随机密码
apps/desktop/src/host-process.ts                       |   7 +-      把密码随 ready 事件转给 Electron
apps/desktop/src/main.ts                               |   2 +-
apps/desktop/src/web-document.ts                       |  15 +-      改为 POST 密码换 cookie
packages/boot/cmdline/src/index.ts                     |   8 +-      parseCmdline 支持参数改写
packages/bundle/web-app/cordis.patch.yml               |   7 +-      密码传给 connection
packages/bundle/web-app/src/index.ts                   |   9 +-      打印的 URL 不再带 token
packages/bundle/web-app/src/startup.ts                 |  62 ++-      新增必填 -pwd
packages/bundle/web-app/tests/browser-open.spec.ts     |  10 +-
packages/bundle/web-app/tests/web-app.spec.ts          |  44 +-
packages/client/connection/src/browser-auth.ts         | 476 +++++    核心：密码页 + IP 绑定
packages/client/connection/src/index.ts                |  32 +-      配置 + 登录路由
packages/client/connection/src/rpc-host.ts             |   9 +-
packages/client/connection/src/rpc.ts                  |  41 +-      加 handleLogin/socket，authenticatedUrl 变垫片
packages/client/connection/tests/browser-auth.host.spec.ts | 302 --- 删除（整篇测 token）
packages/extensions/tool-cordis/src/api-catalog.ts     |  14 +-      文档目录条目
```
