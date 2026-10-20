# 鸿蒙PC 平台笔记

开发本项目时查证过的事实与出处。“真机实测”一节来自 MOR-M1（HarmonyOS 7.0.0.111，API 26，HongMeng Kernel 1.13.0）。

## Kimi Code CLI / Web

- 本机 `~/.kimi-code/bin/kimi` 是 Node v24.15.0 SEA（`__NODE_SEA_BLOB`），内嵌 `main.cjs` + Web UI + 少量 `.node`。
- 官方发布清单 `https://code.kimi.com/kimi-code/binaries/<ver>/manifest.json` 只有
  darwin-arm64/x64、linux-arm64/x64（glibc）、win32-arm64/x64，没有 musl / 鸿蒙版。
- npm 包 `@moonshot-ai/kimi-code`：`bin.kimi = dist/main.mjs`，`engines.node >= 22.19.0`，
  依赖 `ws`、`qrcode`；`node-pty`、`@mariozechner/clipboard` 为可选。`dist-web/` 是 Web UI。
- `kimi web [--port 58627] [--no-open] [--web-title]`：前台运行，同源提供 REST/WS 和 Web UI。
  - URL：`http://127.0.0.1:<port>/#token=<token>`（token 走 fragment，不会发给服务端日志）。
  - token：`<KIMI_CODE_HOME 或 ~/.kimi-code>/server.token`，32 字节 base64url，要求权限 0600。
  - `GET /api/v1/healthz` 免鉴权；其余 `/api/*` 需 `Authorization: Bearer`。
  - 登录：Web UI `POST /oauth/login` → 服务端走 OAuth 设备码流程，返回 `verification_uri_complete`，
    Web UI 用 `window.open(url,'_blank','noopener,noreferrer')` 打开；服务端自行轮询，无回跳。
  - 另有“先 `window.open('', '_blank')` 再设置 `location.href`”的写法（防弹窗拦截）。
- 代码里两处用 `fs.link` 做“原子独占创建”且只吞 EEXIST（锁文件 `tryCreate`、minidb `Topology.open`）。
- 平台判断：`process.platform` 为 `openharmony` 时 ripgrep 自动下载会报 “Unsupported platform/arch”。

## 文件与目录（API 26 真机实测）

- `onShowFileSelector` + `DocumentViewPicker` 可处理 Kimi Web 的单/多文件上传；取消时回传空列表。
- Kimi 的文件预览会“先开空窗再把 location 改成 blob URL”，壳在当前文档内显示带下载/关闭按钮的预览层；ArkWeb 能渲染其中的 PDF。
- 会话 ZIP 导出也是 blob 下载，并在点击后立即 `revokeObjectURL`；需在点击捕获阶段同步开始读取，再经 Base64 桥写入本地。
- 保存下载文件要用 `Environment.getUserDownloadDir()`，本机返回 `/storage/Users/currentUser/Download`（单数）；
  硬编码成 `Downloads` 会报 `Operation not permitted`。hdc 不能直接读这个共享目录，可用系统文件管理器核对文件和 ZIP 内容。

## HNP（HarmonyOS Native Package）

- 官方文档：[startup_appspawn/service/hnp](https://gitee.com/openharmony/startup_appspawn/blob/master/service/hnp/README_zh.md)、
  [hnp/pack](https://gitee.com/openharmony/startup_appspawn/blob/master/service/hnp/pack/README_zh.md)。
- `hnpcli pack -i <dir> -o <out>`，目录内 `hnp.json`：`{"type":"hnp-config","name","version","install":{"links":[...]}}`；
  不写 links 时默认把 `bin/` 下可执行文件都软链。文件权限按打包机上的 UGO 保留（macOS 打包即可）。
- HAP 内布局 `hnp/<abi>/<x>.hnp`；`module.json5` 写 `"hnpPackages":[{"package":"x.hnp","type":"private"}]`。
- 私有 HNP 安装后沙箱路径 `/data/app/<name>.org/<name>_<version>/`，环境变量 `HNP_PRIVATE_HOME=/data/app`；
  公有 HNP 在 `/data/service/hnp/`（同名公有包两个应用不能同时装）。物理路径 `/data/app/el1/bundle/<userid>/hnp`。
- hvigor（6.26，CLT 内）不处理 hnp；`app_packing_tool.jar` 支持 `--hnp-path` 但 hvigor 不传。
  做法（参考 [Termony](https://github.com/TermonyHQ/Termony)）：构建后把 `hnp/` 加进未签名 HAP，再签名。
- `hap-sign-tool.jar sign-app`（`signCode` 默认 1）会解开 HAP 中的 `.hnp`，对其中每个 ELF 做 fs-verity 代码签名（`signNativeHnps`）。
- `module.json` schema 里的 `executableBinaryPaths`（API 24+）见下文“随包 bin 的权限”。

## 进程与沙箱（2in1）

- 官方 HNP 文档给出用 `fork` + `execv` 执行私有 HNP 二进制的示例；Termony 在 MateBook 上用 `forkpty` 跑 bash。
- 手机上第三方应用不能 fork/exec 自带二进制（Termony 手机版 PR 的结论），所以 `deviceTypes` 只写 `2in1`。
- [Termony README](https://github.com/TermonyHQ/Termony)：调试签名的应用已可 `mprotect(anon_page, R_X)`（JIT 可用）。
- 进程执行不归权限体系管（不存在“执行命令”权限），而由 SELinux 域 + seccomp + 强制代码签名管。
- [harmonyos-node-notes](https://github.com/lzzhij/harmonyos-node-notes)（API 26 真机，进程内嵌 Node 24）：
  - libuv 会探测 `io_uring_setup(425)`，被应用 seccomp trap → 需 SIGSYS 处理 + `UV_USE_IO_URING=0`。
  - `link(2)` → EACCES；`flock` 不支持；`os.homedir()` → EPERM（需设置 HOME）。
  - `spawnSync('/bin/sh')` → EACCES（该设备可能不是 2in1，未在 PC 上实测）。
  - 沙箱日志 hdc 读不到；可用 `hdc shell snapshot_display`、`hdc rport`/`fport` 观测。
- Claude Code 的 musl 二进制在 HiShell 中会因 `close_range` 被 seccomp 拦截（hqzing 的 close-range-shim）。

## 签名与权限

- `devecocli`（npm `@deveco/deveco-cli` 1.3.0）：`auth login`（浏览器 OAuth）、`signature generate`
  （本地 p12/csr + 云端调试证书 + 调试 Profile，写入 `build-profile.json5`，口令 AES-128-GCM 加密），
  需要已连接的真机用于注册设备。环境变量 `DEVECO_CLI_CLT_PATH` 指向 CLT。
- 上架分发自带 ELF 需要 AGC “二进制证书”（certType 4），个人开发者拿不到；本项目只做调试签名侧载。
- 受限权限判定：`provisionEnable == true` 且 `availableLevel ∈ {system_basic, system_core}` 才需 ACL。
  本项目唯一的受限权限是 `kernel.ALLOW_WRITABLE_CODE_MEMORY`（JIT）；其余为 normal：`INHERIT_PARENT_PERMISSION`、
  `INTERNET`、`GET_NETWORK_INFO`、`KEEP_BACKGROUND_RUNNING`、`READ_WRITE_DOCUMENTS_DIRECTORY`、
  `READ_WRITE_DOWNLOAD_DIRECTORY`、`FILE_ACCESS_PERSIST`（devecocli 会把后三个也列进 Profile 的 ACL）。
- `signature generate` 按 module.json5 里申请的受限权限生成调试 Profile 的 `allowed-acls`；新增受限权限后要 `--force`
  重新生成（证书也会换新，已安装的旧签名应用需先卸载）。调试 Profile 有效期一年。
- 本机 `~/.ohos/config/` 里还有其他项目的自动签名材料；本项目的材料名为 `default_kimi-code-hmos_*`。

## 随包 bin 的权限（官方文档 + 真机实测）

官方文档：[应用程序包集成bin文件（PC/2in1）](https://developer.huawei.com/consumer/cn/doc/doccenter-getting-started/hap-bin)

- bin 放在模块 `libs/<abi>/`，在 `module.json5` 的 `executableBinaryPaths` 里声明（相对路径，必须以 `libs/<abi>/` 开头），
  应用需是解压模式（`compressNativeLibs: true`）。hvigor 默认只打包 libs 下的 `.so`，官方做法是
  `buildOptionSet[].nativeLib.collectAllLibs: true` 且 debug 包 `debugSymbol.strip: false`；本项目改为构建后直接注入。
- **bin 的权限写在 ELF 的 `.permission` 节**：`{"requestPermissions":[{"name":"..."}]}`，用
  `llvm-objcopy --add-section .permission=<json> in out` 添加（strip 会删掉该节）。声明的权限不能超出应用声明的权限，
  否则安装失败。声明 `ohos.permission.INHERIT_PARENT_PERMISSION`（2in1、normal、无需 ACL）即可继承父进程全部
  system_grant 权限；该权限本身不会再传给孙进程。
- 实测：
  - 应用有 `kernel.ALLOW_WRITABLE_CODE_MEMORY` 时，应用进程 `mmap(RWX)`、`mprotect(RW→RX)` 成功；
  - HNP 里的 node、或只在 `executableBinaryPaths` 声明的 bin，exec 后两者都返回 **EINVAL** → V8 `Check failed: 12 == errno` → SIGTRAP；
  - 给 bin 加上声明 `INHERIT_PARENT_PERMISSION` 的 `.permission` 节后，bin 中 RWX 成功，node 以 JIT 模式运行；
  - 只申请 `kernel.EXEMPT_ANONYMOUS_EXECUTABLE_MEMORY`（normal）时连应用进程都是 EINVAL，不能替代 `ALLOW_WRITABLE_CODE_MEMORY`。
- `--jitless` 下 V8 没有 WebAssembly，Node 内置 `fetch`（undici 的 llhttp 是 WASM）报 `WebAssembly is not defined`。
- 其他应用（如 WorkBuddy 的 Electron 里跑的 `node .../codebuddy`）也以同样方式运行 node。

## 随包 Agent 工具（API 26 真机实测）

- `rg` 使用 dsh-harmonyos 的 musl ARM64 预编译文件（本机为 13.0.0），加 `.permission` 并放进 `executableBinaryPaths` 后，
  Kimi 的 Shell 与 Grep 工具都能按名称找到并返回正确结果，无需伪装 `process.platform` 或走自动下载。
- git 使用 Harmonybrew/ohos-git 2.55.0。常用命令只需主程序及少量 helper，不必打包完整 `libexec`：
  当前为 `git-upload-pack`、`git-receive-pack`、`git-upload-archive`、`git-shell`、`git-remote-https`。
  它们都放在 `libs/arm64-v8a/`，并设 `GIT_EXEC_PATH` 为该目录；git `share/` 放 resfile，`GIT_TEMPLATE_DIR` 指向其中的 `git-core/templates`。
- `status`、`diff`、`log` 和 HTTPS `ls-remote` 已在真机通过；加入 rg/git 后 HAP 约 76MB。
- Python 使用 Harmonybrew/ohos-python 3.14.6。`python3` 加 `.permission`，15 个依赖库与全部 `lib-dynload` 平铺进 libs 签名；
  纯标准库放 resfile 并裁掉 test、开发 config、`__pycache__` 和 GUI 组件，以 `PYTHONHOME`/`PYTHONPATH` 重定位，pycache 指向 cacheDir。
  真机验证 ssl、sqlite3、zlib、bz2、lzma、ctypes、readline 及真实 HTTPS 200，加入后 HAP 约 105MB。
- node-pty 1.2.0-beta.15 的 OHOS/musl N-API 模块可以加载，但 `stat`/`open` `/dev/ptmx` 与 `/dev/pts` 都返回 EACCES，
  `forkpty(3)` 因此失败；当前应用沙箱无法提供 PTY，未把无效模块留在 HAP 中。kimi-code 2.2.0 的 Web UI 也只有终端 API 与翻译文案，没有终端面板实现。

## seccomp 与 SIGSYS（真机实测）

- OpenHarmony 公开的应用策略 [app.seccomp.policy](https://gitee.com/openharmony/startup_init/blob/master/services/modules/seccomp/seccomp_policy/app.seccomp.policy)：
  白名单外一律 `TRAP`；`clone` 带命名空间标志时 TRAP；`linkat`、`statfs`、`copy_file_range`、`inotify_*`、`memfd_create` 等在白名单内。
- libuv（Node 24）即使设置 `UV_USE_IO_URING=0`，每个事件循环初始化仍会调用 3 次 `io_uring_setup`(425)，被 TRAP；
  `libkimicompat.so` 把它改成 `-ENOSYS` 后正常降级到 epoll。每个 worker 线程也会触发同样的 3 次。
- 若 TRAP 发生时该线程屏蔽了 SIGSYS，内核强制按默认动作杀进程；兼容层因此接管 `pthread_sigmask`/`sigprocmask`，不允许屏蔽 SIGSYS
  （musl 内部用原始系统调用的屏蔽窗口仍无法覆盖）。
- 被 SIGSYS 杀掉的进程**不会**留下 FaultLogger 崩溃记录（SIGTRAP、SIGABRT 会）。
- kimi 登录后启动时，在主进程里创建会话搜索 worker（`dist/search-worker.mjs`，带 `execArgv: []`、`resourceLimits`、`name`）
  约 70ms 后 node 被 SIGSYS 结束，兼容层没有记录到对应的 TRAP；同样的 worker 在独立 node 进程里能正常启动并回 `ready`，
  任意参数组合的空 worker 也正常。进一步复现确认进程在真实线程创建阶段就被 SIGSYS 结束，尚未进入兼容层处理函数，具体 syscall 仍未定位。
  当前用 `KIMI_HMOS_SEARCH_WORKER_MODE=inline` 让预加载层在主线程内联执行同一 worker 代码与消息协议；实现需容忍宿主在 `new Worker(...)` 后立即调用 `unref()`，因此 `MessageChannel` 创建前先记录该请求。真机重启后 worker 可启动，索引直连搜索可命中，UI 搜索通过。
- 沙箱里硬链接 `link()` 正常（与 harmonyos-node-notes 在其设备上的 EACCES 结论不同），`statfs`/`fsync` 目录/`copyFile`/`truncate`/`writev` 正常。

## 排障手段（真机实测）

- `hdc shell -b <bundle>`：以 shell 身份进入 `/mnt/debug/100/debug_hap/<bundle>`，读不到 `/data/storage/el2/...` 沙箱文件。
- 无线调试要求两端二层互通（同网段但 ARP 不通的网络会失败）；USB-C 连接 + “USB 调试”最稳。
- hilog 会被 ArkWeb 的 debug 日志冲掉，持续抓取用 `hdc shell "hilog -T KimiShell" > file`。
- `hdc shell snapshot_display -f /data/local/tmp/x.jpeg` + `hdc file recv` 截屏；`hdc shell "bm dump -n <bundle>"` 看权限授予状态与 executableBinaryPaths。
- 应用内 `FaultLogger.query(CPP_CRASH)` 能查到本 uid 下（含 node 子进程）的崩溃栈。
- `os.cpus()` 在沙箱里返回空数组（/proc/cpuinfo 不可读）；`nproc` 可用。

## 对外侧载分发（2026-10 调研）

- 鸿蒙电脑仍未开放“任意来源安装”（华为 2025-06 表示会逐步开放，2026 年下半年的评测仍称未开放）。
- 应用市场之外的途径：调试 Profile（绑定 UDID，账号最多 100 台设备）、“指定设备发布（原内部测试）”（仅企业开发者，浏览器
  `store://enterprise/manifest?url=` 安装）、AGC 邀请/公开测试（仍经应用市场）。个人分发的现实做法是接收方用
  [HoKit](https://github.com/yabi-zzh/HoKit)、小白调试助手（auto-installer，已闭源）以自己的华为账号自动申请调试证书 + Profile 后重签安装。
- 小白调试助手 GitHub issue #63“带 HNP 的 HAP 无法正常安装”仍为 Open（本机的新版程序里已有 HnpPackage/hnpcli 与 AclPage 相关代码）；
  HoKit README 提到多包签名顺序会影响 ACL，说明它按包内声明自动申请受限权限。为降低风险，本项目不再使用 HNP。
- `resources/resfile` 安装时解压到 `context.resourceDir`（API 11+，实测为 `/data/storage/el1/bundle/entry/resources/resfile`）；
  打包工具对 resources 一律 Stored，重写为 deflate 后在模拟器和 API 26 真机（MOR-M1）均确认能正常解压；
  真机同时复测了 JIT、Web UI、真实对话、关窗回收与重启。
- 最终分发验收（2026-10-19，MOR-M1 / HarmonyOS 7.0.0.111）：HoKit 对包含 Python 与搜索 worker `unref()` 修复的
  约 105MB 未签名包重签，`verify-app`/`verify-profile` 通过（Profile 含 `ALLOW_WRITABLE_CODE_MEMORY` 与
  `FILE_ACCESS_PERSIST`），安装后健康检查、Python/HTTPS、UI 搜索均正常。

## 2in1 模拟器（2026-10 实测）

- 模拟器镜像最高只有 HarmonyOS 6.1.1(24)（`devecocli emulator image list`），没有 API 26。为此 `build-profile.json5`
  另有一个只用于自测的 `emulator` 产品（`compatibleSdkVersion` 6.1.1(24)；`executableBinaryPaths` 需要 API 24+），
  `scripts/emulator.sh` 构建它并装到模拟器。对外分发的仍是 `default` 产品。
- 创建/启动：`devecocli emulator create --device-type 2in1 --os-version="HarmonyOS 6.1.1(24)" KimiPC_API24`、
  `devecocli emulator start KimiPC_API24`（都需要 `DEVECO_CLI_CLT_PATH`）。在 hdc 里显示为 `127.0.0.1:5555`，
  `param get bootevent.boot.completed` 为 true 即开机完成。
- 模拟器不校验调试 Profile 的设备列表：用真机生成的调试签名可以直接安装（模拟器 UDID 没注册也行）。
  不要为了模拟器再跑 `devecocli signature generate`，它会重新生成证书，真机上已装的应用就得卸载重装（丢登录状态）。
- 能验证的：安装（resfile 解压、`executableBinaryPaths`）、壳的 ArkTS 逻辑、服务启动、node 联网（登录的设备码请求）、
  外链唤起系统浏览器、关窗口后 node 退出、release 构建模式。
- **不能验证 JIT 相关的限制**：把 node 的 `.permission` 节删掉后，在模拟器上照样能 JIT 运行（真机上同样配置会 SIGTRAP）。
  JIT、ACL、`.permission` 继承、重签工具是否带上 ACL，都只能在真机上确认。
- 输入与截图：`hdc -t 127.0.0.1:5555 shell "uitest uiInput click <x> <y>"`（物理像素，屏幕 3120×2080），
  `snapshot_display -f /data/local/tmp/x.jpeg` + `hdc file recv`。node 的进程名是 `kimi-code`（`ps -A` 可见），
  `/proc/<pid>/maps` 无权读取。
