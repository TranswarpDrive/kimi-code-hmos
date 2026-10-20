# CLAUDE.md — Kimi Code 鸿蒙PC 外壳（kimi-code-hmos）

非官方的个人侧载项目：把官方 Kimi Code Web（由 Kimi Code CLI 的 `kimi web` 提供）包成一个鸿蒙PC（2in1）HAP。
不用 Electron，用 ArkTS + ArkWeb 做壳；Node 运行时作为随包 bin、kimi-code npm 包作为 resfile 资源内置进 HAP。
分发方式：只支持 API 26 的 2in1，接收方用小白调试助手、HoKit 等工具以自己的华为开发者账号重签侧载（`dist/*-unsigned.hap`）。
已在 MOR-M1（HarmonyOS 7.0.0，API 26）真机跑通：JIT、登录（系统浏览器授权）、对话、Shell 工具。

计划与进度见 [docs/PLAN.md](docs/PLAN.md)，平台踩坑与资料来源见 [docs/HARMONYOS-NOTES.md](docs/HARMONYOS-NOTES.md)。

## 架构

```
EntryAbility (ArkTS)
 ├─ KimiServer.ets ── libkimihost.so (NAPI: fork+execve / kill / waitpid 线程 / nativeLibDir)
 │      └─ 子进程: <libs>/node  --require <kimi>/runtime/ohos-preload.cjs
 │                  <kimi>/package/dist/main.mjs web --no-open --port <p> --web-title "Kimi Code"
 │         <libs> = /data/storage/el1/bundle/libs/arm64（node、python3、rg、git/helper 与 Python 原生库）
 │         <kimi> = <context.resourceDir>/kimicode（resfile 安装时解压出的只读文件）
 │         随包 bin 的 ELF .permission 节声明 INHERIT_PARENT_PERMISSION → 继承应用的 JIT、联网权限
 │         env: HOME=<filesDir>/home  PATH=<libs>:...  GIT_EXEC_PATH=<libs>
 │              GIT_TEMPLATE_DIR=<kimi>/git/share/git-core/templates
 │              PYTHONHOME=<kimi>/python  PYTHONPATH=<libs>:<kimi>/python/lib/python3.14:...
 │              PYTHONPYCACHEPREFIX=<cacheDir>/python-pycache  TERMINFO=<kimi>/python/share/terminfo
 │              LD_LIBRARY_PATH=<libs>  LD_PRELOAD=<libs>/libkimicompat.so
 │              UV_USE_IO_URING=0  KIMI_HMOS_SEARCH_WORKER_MODE=inline  KIMI_HMOS_DEBUG=0|1 ...
 └─ pages/Index.ets ── ArkWeb 加载 http://127.0.0.1:<p>/#token=<server.token>
        ├─ document-start 注入脚本接管外链、blob 下载与 blob 文件预览
        ├─ onShowFileSelector + DocumentViewPicker 处理上传；WebDownloadDelegate/Base64 处理下载
        ├─ 原生工具栏：工作目录选择、重启服务、查看日志（token 脱敏）
        ├─ onLoadIntercept 兜底主框架外链
        └─ 外链(含 OAuth 设备码授权页) → UIAbilityContext.openLink → 系统默认浏览器
```

- 不用 HNP：重签工具对带 HNP 的 HAP 支持不稳定；resfile 是标准资源目录，任何工具都不会动它。
- kimi 登录是 OAuth 设备码流程：服务端轮询 token，浏览器授权后无需回跳应用。
- `server.token` 由 kimi 首次启动生成在 `$HOME/.kimi-code/server.token`（0600），壳读取它拼 URL。
- 就绪探测：`GET /api/v1/healthz`（免鉴权）。node 启动即崩（SIGTRAP 等）时自动 `--jitless` 重试并在页面顶部提示。

## 目录

| 路径 | 说明 |
|---|---|
| `AppScope/` | 应用级配置（bundleName `com.kimicodehmos.app`） |
| `entry/src/main/ets/kimi/` | 服务管理、外链、Web 桥、文件上传下载与目录选择、权限、长时任务、崩溃日志诊断 |
| `entry/src/main/cpp/` | NAPI `libkimihost.so`、LD_PRELOAD 兼容层 `compat/ohos_compat.c` → `libkimicompat.so` |
| `entry/hvigorfile.ts` | `InjectRuntime` 任务：PackageHap 后注入可执行 bin 与清单中的 Python 原生文件，并把 resfile 条目改为 deflate |
| `hvigorfile.ts` | 构建时注入本机签名配置 `signing/*.local.json` |
| `build-profile.json5` | 产品 `default`（分发，只支持 API 26）与 `emulator`（模拟器自测，兼容 API 24） |
| `runtime/ohos-preload.cjs` | node 预加载补丁（link 回退、worker 继承预加载、搜索 worker 主线程内联、调试追踪） |
| `runtime/bin-permission.json` | 写进可执行 bin `.permission` 节的权限声明 |
| `runtime/kimi-deps/` | kimi 运行时依赖（ws、qrcode）的锁定清单 |
| `scripts/` | `fetch-deps.sh` / `stage-runtime.sh` / `setup-signing.sh` / `build.sh` / `install.sh` / `emulator.sh` |
| `scripts/versions.env` | 锁定的 Node、kimi-code、git、Python、ripgrep 版本与校验值 |
| `vendor/`、`entry/libs/`、`entry/src/main/resources/resfile/kimicode/`、`dist/` | 生成物，均不入库 |

## 常用命令

```bash
export DEVECO_CLI_CLT_PATH=$HOME/DevTools/command-line-tools-26/command-line-tools   # devecocli 需要
scripts/setup-signing.sh [default --force]   # devecocli 登录 + 生成调试证书/Profile（需连设备）；改了 ACL 权限要 --force
scripts/build.sh [release]                   # 下载校验依赖 → stage-runtime → hvigor 构建；dist/ 下有未签名（分发）与已签名（自用）HAP
scripts/install.sh                           # hdc install -r 并启动（换证书后需先 hdc uninstall com.kimicodehmos.app）；跳过模拟器
scripts/emulator.sh [release]                # 真机不在时：构建 emulator 产品 → 装到 2in1 模拟器（127.0.0.1:5555）→ 启动
hdc shell "hilog -T KimiShell"               # 壳日志 + 转发的 node 输出（[node] 前缀，token 已打码）
```

- 设备：USB-C 连接并开“USB 调试”最稳；无线调试要求两端二层互通。
- 模拟器（`KimiPC_API24`，HarmonyOS 6.1.1(24)）：直接用真机的调试签名安装，别为它重新生成证书。它**不限制 JIT**
  （node 去掉 `.permission` 也能 JIT），所以 JIT/ACL/重签相关的改动必须真机验证；其余（安装、服务、联网、外链、生命周期）可在模拟器上测。
- 调试：服务失败页可“开启调试日志并重启”（写 `files/debug.flag`）：kimi `--log-level debug`、兼容层打印被拦截的 syscall、预加载脚本追踪 fs/os/crypto/net/child_process 调用。很吵，排障完关掉。
- `hdc shell -b <bundle>` 在这台机器上进不了应用沙箱；沙箱日志靠 hilog 转发，崩溃栈靠 `Diagnostics.ets` 查询 FaultLogger。

## 平台约束（改代码前必读）

- 只面向 `2in1`、API 26（`default` 产品的 `compatibleSdkVersion` 26.0.0；`emulator` 产品为 6.1.1(24)，只用于自测）。手机/平板不允许应用 fork/exec 自带二进制；
  `executableBinaryPaths`（API 24+）、`INHERIT_PARENT_PERMISSION`（API 23+）在低版本系统不可用。
- **随包 bin 的权限写在它自己的 ELF `.permission` 节**（官方“应用程序包集成bin文件（PC/2in1）”）。
  可执行文件声明 `INHERIT_PARENT_PERMISSION`，应用也必须声明它；node 没有它时 exec 后拿不到应用的 JIT 与联网权限
  （放在 HNP 里、或只在 executableBinaryPaths 声明都不行，实测 mmap(RWX) 返回 EINVAL）。
- JIT 需要受限权限 `kernel.ALLOW_WRITABLE_CODE_MEMORY`（调试 Profile 由 devecocli 自动带 ACL）；`kernel.EXEMPT_ANONYMOUS_EXECUTABLE_MEMORY` 实测不能替代。
- 带 `.permission` 的 bin 不能被 strip；hvigor 只收 libs 下 `.so`，所以 node、python3 与清单中的 Python 原生文件由 `InjectRuntime` 原样注入。
- 打包工具把 resources 下文件一律不压缩存储，`InjectRuntime` 用 deflate 重写 resfile 条目；当前 HAP 约 105MB。
- Python 的所有 ELF 必须留在 libs 签名链；纯标准库放 `<kimi>/python/lib/python3.14`，以 `PYTHONHOME`/`PYTHONPATH` 重定位，pycache 指向可写 cacheDir。
- 重签工具必须把受限权限 `kernel.ALLOW_WRITABLE_CODE_MEMORY` 写进接收方的调试 Profile（HoKit 自动；小白调试助手有 ACL 设置页），否则安装失败。
- 应用 seccomp 对白名单外 syscall 用 TRAP；libuv 无视 `UV_USE_IO_URING=0` 仍会探测 `io_uring_setup`(425)，靠 `libkimicompat.so` 的 SIGSYS→-ENOSYS 兜住。兼容层同时禁止任何线程屏蔽 SIGSYS（屏蔽时被 TRAP 会被强制杀进程）。
- kimi 登录后在主进程创建会话搜索 worker 时，node 会在线程创建阶段被 SIGSYS 杀掉（具体 syscall 未定位）；`KIMI_HMOS_SEARCH_WORKER_MODE=inline` 让预加载脚本在主线程内联执行同一 worker 代码与消息协议，保留全文搜索。
- kimi 创建 worker 时显式传 `execArgv: []`，预加载脚本会把自己补进去，否则 worker 里没有补丁。
- `os.homedir()` 默认指向不可读的 `/storage/Users/currentUser`，子进程必须设置 `HOME`；`os.cpus()` 在沙箱里返回空数组。
- `process.platform === 'openharmony'`，不要伪装成 linux（kimi 会去下载 glibc 版 ripgrep 等不可执行文件）。
- 真机沙箱禁止访问 `/dev/ptmx` 与 `/dev/pts`，node-pty 的 `forkpty` 无法工作，不要靠仅打包原生模块来宣称 Web 终端可用。
- 受限（ACL）权限只能申请调试 Profile 里有的；改了受限权限要 `setup-signing.sh default --force` 重新生成 Profile。
- fork 后到 execve 前只能调用 async-signal-safe 函数；argv/envp 在 fork 前准备好。

## 约定

- 文档、注释用中文；标识符用英文。ArkTS 遵循严格模式（无 any、无解构、对象字面量需有类型）。
- 版本：`AppScope/app.json5` 的 `versionName` 是壳版本；内置 kimi-code / node 版本记在 `scripts/versions.env`。
- Git：`main` 分支，小步提交，提交信息用中文说明“做了什么/为什么”；生成物和本机签名不入库。
- 升级 kimi-code：改 `scripts/versions.env` 的版本与 integrity → `scripts/build.sh` → 真机回归（登录、对话、Shell 工具、重启后稳定性）。
