# 计划与进度

> M0–M6 是 0.1.0 的历史开发记录，包含后来被替换的硬链接回退、主线程内联搜索和 jitless 方案。
> 0.2.0 的当前实现、验证范围与发布流程以 [CHANGELOG](../CHANGELOG.md)、[RELEASE-VALIDATION](RELEASE-VALIDATION.md)、[RELEASING](RELEASING.md) 为准。历史勾选不代表新版已经重新验收。

目标：一个可侧载到鸿蒙PC 的 HAP，启动后自动拉起内置的 `kimi web`，用 ArkWeb 展示官方 Web UI；
登录等外链跳转到系统默认浏览器。

状态图例：✅ 完成　🔄 进行中　⏳ 待办　🔒 需要用户操作（登录 / 连接设备）

## 关键决策

| 决策 | 选择 | 理由 |
|---|---|---|
| 壳技术 | ArkTS + ArkWeb | 只做鸿蒙PC，不需要 Electron；包更小 |
| kimi 来源 | npm `@moonshot-ai/kimi-code`（纯 JS，Node ≥22.19） | 官方二进制是 Node SEA，只有 darwin/linux(glibc)/win32，无鸿蒙版 |
| Node 运行时 | [hqzing/ohos-node](https://github.com/hqzing/ohos-node) v24.x（官方源码 `--dest-os=openharmony` 交叉编译） | Harmonybrew 生态通用的鸿蒙版 Node；可按其 build.sh 自行复现 |
| 运行方式 | 子进程（fork+execve），不在进程内嵌 libnode | 2in1 允许执行包内 bin；崩溃隔离、可重启 |
| node 分发 | `libs/arm64-v8a/node.bin` + `executableBinaryPaths` + ELF `.permission`（INHERIT_PARENT_PERMISSION） | `.bin` 后缀兼容旧版重签器；随包 node 继承应用的 JIT/联网权限 |
| kimi JS 分发 | `resources/resfile/kimicode`（安装时解压为真实文件） | 早期用私有 HNP；改 resfile 是为兼容小白调试助手等重签工具 |
| 对外分发 | 未签名 HAP + 接收方用 HoKit/小白调试助手以自己账号重签侧载，仅 API 26 | 不上架；个人开发者拿不到随包 ELF 的“二进制证书” |
| 签名 | `devecocli auth login` + `devecocli signature generate`（调试证书+调试 Profile） | 官方命令行自动签名；侧载不需要上架用的“二进制证书” |
| 外链 | 注入脚本接管 `window.open` 与外链点击 + `onLoadIntercept` 兜底 → `openLink` | kimi Web 用 `window.open(url,'_blank')` 和“先开空窗再改 location”两种写法 |

## 里程碑

### M0 环境与调研 ✅
- [x] 本机：CLT 26.0.0.621（API 26 Beta2）、devecocli 1.3.0、JDK 17、kimi CLI 0.42.0
- [x] kimi web 机制：`#token=` 片段、`server.token`、`/api/v1/healthz`、设备码登录
- [x] 鸿蒙PC：HNP、fork/exec、seccomp、硬链接、HOME、代码签名（见 HARMONYOS-NOTES.md）

### M1 工程骨架与构建链路 ✅
- [x] ArkTS 工程（2in1、API 26 编译 / 兼容 5.0.5(17)）、NAPI `libkimihost.so`、`libkimicompat.so`
- [x] `ohos-preload.cjs`：`fs.link*` 回退（本机模拟 EACCES 验证）
- [x] `fetch-deps.sh`（GitHub 下载 + ohos-node.com SHASUMS 交叉校验）、`stage-runtime.sh`、`InjectRuntime` 任务
- [x] 本机（macOS Node）冒烟：同样的目录布局与启动参数下 `kimi web` 就绪、token 鉴权正常

### M2 签名 ✅
- [x] 鸿蒙PC（MOR-M1，HarmonyOS 7.0.0 / API 26）经 USB 连接（无线调试因网络二层不通失败）
- [x] `devecocli auth login`（浏览器登录）→ `signature generate`（自动注册设备、带 ACL 的调试 Profile）
- [x] 签名配置提取到 `signing/default.local.json`，构建时由根 `hvigorfile.ts` 注入

### M3 真机验证 ✅
- [x] 安装成功（HNP 解包、libs 解压、executableBinaryPaths 生效）
- [x] node 以 JIT 模式运行（`.permission` 继承 `ALLOW_WRITABLE_CODE_MEMORY`），kimi web 就绪
- [x] ArkWeb 加载 Web UI，token 鉴权通过
- [x] 登录：授权页在系统浏览器打开，授权后 Web UI 变为已登录
- [x] 对话 + Shell 工具（Agent 执行命令、读文件）在真机可用
- [x] 登录后重启的 SIGSYS 崩溃：定位到会话搜索 worker 的线程创建阶段，M4 已改为主线程内联执行

### M4 体验完善 ✅
- [x] 会话全文搜索：真机确认 worker 在线程创建阶段触发 SIGSYS（具体 syscall 未定位），预加载层改为主线程内联执行同一协议，并兼容创建后立即 `unref()`；重启后 worker 可启动，索引直连命中，UI 搜索通过
- [x] 文件上传（`onShowFileSelector`）、下载（导出会话 ZIP、文件预览的 blob 窗口）：真机验证单/多附件、ZIP 导出与防重名、blob PDF 预览和保存
- [x] 工作目录选择：系统目录选择器 + 授权/路径持久化，可恢复默认，冷启动保持
- [x] 窗口内快捷操作：重启服务、查看日志（同端口重启自动重载；日志中的 token 脱敏）
- [x] 调试工具链（jitprobe 等）移除后的回归：冷启动、切后台（PID 与健康检查不变）、关闭窗口后 Node 回收、再次冷启动恢复

### M5 Agent 工具链补全 ✅
- [x] ripgrep：随包 musl ARM64 预编译 bin（`.permission` 继承权限）；真机验证 `rg 13.0.0`、Shell 搜索和 Kimi Grep 工具正向命中
- [x] git 2.55.0：随包主程序与 remote-https 等必要 helper；真机验证 status、diff、log 和 HTTPS `ls-remote`
- [x] Python 3.14.6：解释器与原生库走 libs 签名，纯标准库放 resfile；真机验证 ssl、sqlite3、zlib、bz2、lzma、ctypes、readline 和 HTTPS 200
- [x] node-pty 评估：原生模块可加载，但真机 `/dev/ptmx`、`/dev/pts` 均为 EACCES，`forkpty` 失败；当前沙箱无法提供 PTY，不集成无效模块

### M6 升级与分发 ✅
- [x] `compatibleSdkVersion` 定为 26.0.0（只支持 API 26 的 2in1）
- [x] 去掉 HNP，kimi 包改走 resfile（resfile 条目 deflate 重写）；`build.sh` 总是产出未签名包 + sha256（加入 M5 工具后 HAP 约 105MB）
- [x] 2in1 模拟器（HarmonyOS 6.1.1(24)）验证 resfile 版本：安装解压、服务启动、联网（登录设备码请求）、外链、关窗口回收、release 模式
- [x] `emulator` 产品 + `scripts/emulator.sh`：真机不在手边时自测（模拟器不限制 JIT，JIT/ACL 仍需真机）
- [x] API 26 真机复测 resfile 版本（MOR-M1 / HarmonyOS 7.0.0.111：安装解压、JIT、Web UI、真实对话、关窗回收与重启均通过）
- [x] HoKit 最终验收：对包含 Python 与搜索 worker `unref()` 修复的约 105MB 未签名包重签，`verify-app`/`verify-profile` 通过（Profile 含 JIT 与文件持久化 ACL 及真机 UDID），安装后健康检查、Python/HTTPS、UI 搜索均正常
- [x] 升级检查：npm 上 `@moonshot-ai/kimi-code` 最新版已是当前内置的 2.2.0，无新版可升级
- [x] （可选，不阻塞分发）jitless 兜底评估：用 `node:https` 实现 fetch 的方案暂不实现——HoKit 链路已实测带上 JIT ACL 且 JIT 正常；仅当其他重签工具丢失 ACL 时才需要（见风险表）

### M7 官方运行时自更新 🔄
- [x] 原生更新界面，CLI 与 WebUI 从官方 npm 按同一版本整体更新
- [x] 隔离 npm 配置与暂存目录、禁用安装脚本和 bin 软链接、完整性/结构/CLI 冒烟、原子激活和首次启动回滚
- [x] npm 单归档与随包 tar 解压，发布校验覆盖归档内容；自动化与主机真实官方安装通过
- [x] 模拟器完成官方 2.3.2 更新、WebUI/工作目录/历史附件保留与恢复随包 2.2.0
- [x] API 26 真机同证书覆盖安装 0.3.0（未卸载）
- [ ] 真机解锁后进行官方更新、登录/已有会话与真实对话回归（当前锁屏无法操作）

## 风险与预案

| 风险 | 预案 |
|---|---|
| 系统更新收紧 bin 权限继承 | 明确报告启动失败并检查 JIT ACL；不再用不可联网的 jitless 模式掩盖问题 |
| 其他 kimi 功能在沙箱里触发 SIGSYS | 打开调试日志（失败页按钮），看兼容层记录的 syscall 与预加载脚本的调用追踪 |
| 调试 Profile 一年过期（当前到 2027-10-18） | 重新运行 `scripts/setup-signing.sh default --force` |
| 换证书后覆盖安装失败 | `hdc uninstall com.kimicodehmos.app` 后再装（会清空登录状态） |
| 模拟器结果过于乐观（不限制 JIT） | JIT/ACL/`.permission`/重签相关改动一律以真机为准 |
