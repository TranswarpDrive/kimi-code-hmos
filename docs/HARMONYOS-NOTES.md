# 鸿蒙PC 平台笔记

开发本项目时查证过的事实与出处。标注“未实测”的条目需在真机上确认后更新。

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
- `module.json` schema 里还有 `executableBinaryPaths`（API 24+，“binary paths with kernel permission”），暂不使用。

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
  本项目只申请 normal 级权限：`INTERNET`、`GET_NETWORK_INFO`、`KEEP_BACKGROUND_RUNNING`、
  `READ_WRITE_DOCUMENTS_DIRECTORY`、`READ_WRITE_DOWNLOAD_DIRECTORY`、`FILE_ACCESS_PERSIST`。
- 本机 `~/.ohos/config/` 里已有其他项目的自动签名材料（同一账号下注册了 3 台设备）。
