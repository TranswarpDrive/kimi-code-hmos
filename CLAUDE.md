# CLAUDE.md — Kimi Code 鸿蒙PC 外壳（kimi-code-hmos）

非官方的个人侧载项目：把官方 Kimi Code Web（由 Kimi Code CLI 的 `kimi web` 提供）包成一个鸿蒙PC（2in1）HAP。
不用 Electron，用 ArkTS + ArkWeb 做壳；Node 运行时和 kimi-code npm 包以私有 HNP 内置进 HAP。

计划与进度见 [docs/PLAN.md](docs/PLAN.md)，平台踩坑与资料来源见 [docs/HARMONYOS-NOTES.md](docs/HARMONYOS-NOTES.md)。

## 架构

```
EntryAbility (ArkTS)
 ├─ KimiServer.ets ── libkimihost.so (NAPI: fork+execve / kill / waitpid 线程)
 │      └─ 子进程: /data/app/node.org/node_<ver>/bin/node
 │                  --require <kimi HNP>/runtime/ohos-preload.cjs
 │                  <kimi HNP>/package/dist/main.mjs web --no-open --port <p>
 │         env: HOME=<filesDir>/home  UV_USE_IO_URING=0  LD_PRELOAD=libkimicompat.so ...
 └─ pages/Index.ets ── ArkWeb 加载 http://127.0.0.1:<p>/#token=<server.token>
        ├─ document-start 注入脚本接管 window.open → JS 代理 kimiHost.openExternal
        ├─ onWindowNew / onLoadIntercept 兜底外链
        └─ 外链(含 OAuth 设备码授权页) → UIAbilityContext.openLink → 系统默认浏览器
```

- HNP 安装后在应用沙箱内的路径：`/data/app/<name>.org/<name>_<version>/`（`HNP_PRIVATE_HOME=/data/app`）。
- kimi 登录是 OAuth 设备码流程：服务端轮询 token，浏览器授权后无需回跳应用。
- `server.token` 由 kimi 首次启动生成在 `$HOME/.kimi-code/server.token`（必须 0600），壳读取它拼 URL。
- 就绪探测：`GET /api/v1/healthz`（免鉴权）。

## 目录

| 路径 | 说明 |
|---|---|
| `AppScope/` | 应用级配置（bundleName `com.kimicodehmos.app`） |
| `entry/src/main/ets/` | ArkTS：`entryability/`、`pages/`、`kimi/`（服务管理、外链、日志） |
| `entry/src/main/cpp/` | NAPI 模块 `libkimihost.so` + LD_PRELOAD 兼容层 `libkimicompat.so` |
| `entry/hvigorfile.ts` | 自定义任务：在 `SignHap` 前把 `entry/hnp/` 注入未签名 HAP |
| `runtime/` | 打进 kimi HNP 的 JS 补丁（`ohos-preload.cjs`） |
| `scripts/` | `fetch-deps.sh` / `build-hnp.sh` / `setup-signing.sh` / `build.sh` / `install.sh` |
| `scripts/versions.env` | 锁定的 Node、kimi-code 版本与 sha256 |
| `vendor/`、`entry/hnp/`、`out/`、`dist/` | 生成物，均不入库 |
| `signing/*.local.json` | 本机签名配置，不入库；由根 `hvigorfile.ts` 在构建时注入 |

## 常用命令

```bash
export DEVECO_CLI_CLT_PATH=$HOME/DevTools/command-line-tools-26/command-line-tools   # devecocli 需要
scripts/fetch-deps.sh          # 下载并校验 node(ohos) 与 kimi-code npm 包到 vendor/
scripts/build-hnp.sh           # 生成 entry/hnp/arm64-v8a/{node,kimi}.hnp
scripts/setup-signing.sh       # 首次：devecocli auth login + signature generate（需登录、需连设备）
scripts/build.sh               # 全流程，产物在 dist/
scripts/install.sh             # hdc 安装并启动
hdc shell hilog -x | grep -i KimiShell   # 看壳日志（domain 0x4B49 / tag KimiShell）
```

工具位置：CLT 在 `~/DevTools/command-line-tools-26/command-line-tools`（hvigorw/ohpm/hdc 已在 PATH），
签名工具 `sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar`，`hnpcli` 在 `.../toolchains/`。

## 平台约束（改代码前必读）

- 只面向 `2in1`（鸿蒙PC）。手机/平板不允许应用 fork/exec 自带二进制。
- 包内 ELF 必须有代码签名：HNP 里的 ELF 由 hap-sign-tool 在 `sign-app` 时统一签（`signNativeHnps`），不要另行改动已签名 HAP。
- 应用沙箱 seccomp 会拦截部分 syscall（如 `io_uring_setup`、`close_range`）：子进程必须带 `UV_USE_IO_URING=0`，并预加载 `libkimicompat.so`（SIGSYS → `-ENOSYS`）。
- 沙箱内硬链接 `link(2)` 可能 EACCES；`ohos-preload.cjs` 把 `fs.link*` 退化为 `open(dst,'wx')` 独占拷贝（保留 EEXIST 语义）。
- `os.homedir()` 默认指向不可读的 `/storage/Users/currentUser`，所以子进程必须显式设置 `HOME`。
- `process.platform === 'openharmony'`，不要伪装成 linux（会导致 kimi 去下载 glibc 版 ripgrep 等不可执行的二进制）。
- 受限（ACL）权限只能申请调试 Profile 里允许的；申请了 Profile 里没有的 system_grant 受限权限会导致安装失败。
- fork 后到 execve 前只能调用 async-signal-safe 函数；argv/envp 在 fork 前准备好。

## 约定

- 文档、注释用中文；标识符用英文。ArkTS 遵循 ArkTS 严格模式（无 any、无解构、对象字面量需有类型）。
- 版本号：`AppScope/app.json5` 的 `versionName` = `<壳版本>`，内置 kimi-code 版本记在 `scripts/versions.env`。
- Git：`main` 分支，小步提交，提交信息用中文说明“做了什么/为什么”；生成物和本机签名不入库。
- 升级 kimi-code：改 `scripts/versions.env` 的版本与 sha256 → `scripts/build.sh` → 真机回归（登录、对话、工具调用）。
