# 计划与进度

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
| node 分发 | `libs/arm64-v8a/node` + `executableBinaryPaths` + ELF `.permission`（INHERIT_PARENT_PERMISSION） | 只有这样 node 才能继承应用的 JIT/联网权限；HNP 里的二进制拿不到 |
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
- [x] 登录后重启的 SIGSYS 崩溃：定位到会话搜索 worker，暂时禁用该 worker

### M4 体验完善 ⏳
- [ ] 查清搜索 worker 触发 SIGSYS 的具体 syscall，恢复会话全文搜索
- [ ] 文件上传（`onShowFileSelector`）、下载（导出会话 ZIP、文件预览的 blob 窗口）
- [ ] 工作目录选择（目前默认 `文档/kimi-code-projects`，由 kimi 自己创建）
- [ ] 窗口内快捷操作：重启服务、查看日志（目前只在启动/失败页提供）
- [ ] 调试工具链（jitprobe 等）移除后的回归：冷启动、切后台、关闭窗口后进程回收

### M5 Agent 工具链补全 ⏳
- [ ] ripgrep（Rust `aarch64-unknown-linux-ohos` 交叉编译，加 `.permission` 作为随包 bin）
- [ ] git、python 等常用工具（同样以随包 bin + INHERIT_PARENT_PERMISSION 方式）
- [ ] node-pty（Web 终端面板）

### M6 升级与分发 🔄
- [x] `compatibleSdkVersion` 定为 26.0.0（只支持 API 26 的 2in1）
- [x] 去掉 HNP，kimi 包改走 resfile（resfile 条目 deflate 重写，HAP 保持 56MB）；`build.sh` 总是产出未签名包 + sha256
- [x] 2in1 模拟器（HarmonyOS 6.1.1(24)）验证 resfile 版本：安装解压、服务启动、联网（登录设备码请求）、外链、关窗口回收、release 模式
- [x] `emulator` 产品 + `scripts/emulator.sh`：真机不在手边时自测（模拟器不限制 JIT，JIT/ACL 仍需真机）
- [ ] API 26 真机复测 resfile 版本（🔒 需重新连接设备）
- [ ] 用 HoKit / 小白调试助手实测“未签名包 → 重签 → 安装 → JIT 正常”（确认 ACL 被带上）
- [ ] 升级 kimi-code：改 `scripts/versions.env` → 重新打包 → 回归
- [ ] （可选）jitless 兜底：用 `node:https` 实现 fetch，万一重签工具没带上 JIT 的 ACL，应用仍能联网（性能较差）

## 风险与预案

| 风险 | 预案 |
|---|---|
| 系统更新收紧 bin 权限继承 | 壳自动 `--jitless` 重试并提示；补 M6 的 fetch 兜底 |
| 其他 kimi 功能在沙箱里触发 SIGSYS | 打开调试日志（失败页按钮），看兼容层记录的 syscall 与预加载脚本的调用追踪 |
| 调试 Profile 一年过期（当前到 2027-10-18） | 重新运行 `scripts/setup-signing.sh default --force` |
| 换证书后覆盖安装失败 | `hdc uninstall com.kimicodehmos.app` 后再装（会清空登录状态） |
| 模拟器结果过于乐观（不限制 JIT） | JIT/ACL/`.permission`/重签相关改动一律以真机为准 |
