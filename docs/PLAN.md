# 计划与进度

目标：一个可侧载到鸿蒙PC 的 HAP，启动后自动拉起内置的 `kimi web`，用 ArkWeb 展示官方 Web UI；
登录等外链跳转到系统默认浏览器。

状态图例：✅ 完成　🔄 进行中　⏳ 待办　🔒 需要用户操作（登录 / 连接设备）

## 关键决策

| 决策 | 选择 | 理由 |
|---|---|---|
| 壳技术 | ArkTS + ArkWeb | 只做鸿蒙PC，不需要 Electron；包更小、无 JIT 权限依赖 |
| kimi 来源 | npm `@moonshot-ai/kimi-code`（纯 JS，Node ≥22.19） | 官方二进制是 Node SEA，只有 darwin/linux(glibc)/win32，无鸿蒙版 |
| Node 运行时 | [hqzing/ohos-node](https://github.com/hqzing/ohos-node) v24.x（官方源码 `--dest-os=openharmony` 交叉编译） | Harmonybrew 生态通用的鸿蒙版 Node；可按其 build.sh 自行复现 |
| 运行方式 | 子进程（fork+execve），不在进程内嵌 libnode | 2in1 允许执行包内 HNP 二进制；崩溃隔离、可重启 |
| 二进制分发 | 私有 HNP（`hnpPackages` type=private） | 官方 Native 包机制；hap-sign-tool 会对 HNP 内 ELF 做代码签名 |
| 签名 | `devecocli auth login` + `devecocli signature generate`（调试证书+调试 Profile） | 官方命令行自动签名；侧载不需要上架用的“二进制证书” |
| 外链 | 注入脚本接管 `window.open` + `onWindowNew` 兜底 → `openLink` | kimi Web 用 `window.open(url,'_blank')` 和“先开空窗再改 location”两种写法 |

## 里程碑

### M0 环境与调研 ✅
- [x] 本机：CLT 26.0.0.621（API 26 Beta2）、devecocli 1.3.0、JDK 17、kimi CLI 0.42.0
- [x] kimi web 机制：`#token=` 片段、`server.token`、`/api/v1/healthz`、设备码登录
- [x] 鸿蒙PC：HNP 路径、fork/exec、seccomp、硬链接、HOME、代码签名（见 HARMONYOS-NOTES.md）

### M1 工程骨架与构建链路 ✅
- [x] ArkTS 工程（2in1、API 26 编译 / 兼容 5.0.5(17)）
- [x] NAPI `libkimihost.so`：spawn / kill / 退出回调
- [x] `libkimicompat.so`：SIGSYS → -ENOSYS 兼容层
- [x] `ohos-preload.cjs`：`fs.link*` 回退（本机模拟 EACCES 验证：首次独占创建成功、二次抛 EEXIST）
- [x] `scripts/fetch-deps.sh`（GitHub 下载 + ohos-node.com SHASUMS 交叉校验）、`scripts/build-hnp.sh`
- [x] `entry/hvigorfile.ts`：`InjectHnp` 任务位于 PackageHap 之后、PackingCheck/SignHap 之前
- [x] 本机产出未签名 HAP（57MB），含 `hnp/arm64-v8a/*.hnp`，`module.json` 含 `hnpPackages`
- [x] 本机（macOS Node）冒烟：同样的目录布局与启动参数下 `kimi web` 就绪、`healthz` 200、token 鉴权正常
- [x] 启动失败时自动 `--jitless` 重试（V8 JIT 被拒的兜底）

### M2 签名 🔒
- [ ] 鸿蒙PC 开启开发者模式 + USB/无线调试，`hdc list targets` 可见 🔒
- [ ] `devecocli auth login`（浏览器登录华为开发者账号）🔒
- [ ] `devecocli signature generate` → 本机签名配置移入 `signing/default.local.json`
- [ ] `scripts/build.sh` 产出已签名 HAP

### M3 真机验证 ⏳
- [ ] 安装成功（HNP 解包到 `/data/app/...`）
- [ ] node 可执行（`node -v` 写入日志），kimi web 正常监听
- [ ] ArkWeb 加载 Web UI，token 鉴权通过
- [ ] 登录：授权页在系统浏览器打开，授权后 Web UI 变为已登录
- [ ] 对话 + 文件读写 + Shell 工具调用回归

### M4 体验完善 ⏳
- [ ] 启动页（进度 + 日志尾部）、失败重试、查看完整日志
- [ ] 工作目录：申请文档/下载目录权限，默认打开 `~/Documents`
- [ ] 后台保活（2in1 `TASK_KEEPING` 长时任务），窗口关闭时优雅停止服务
- [ ] 端口占用检测（默认 58637，避免与终端里的 `kimi web` 58627 冲突）
- [ ] 文件上传（`onShowFileSelector`）、下载（导出会话 ZIP）

### M5 Agent 工具链补全 ⏳
- [ ] 内置 shell（busybox/bash HNP）——若系统 `/bin/sh` 对应用不可执行
- [ ] ripgrep（Rust `aarch64-unknown-linux-ohos` 交叉编译）
- [ ] git、node-pty（Web 终端面板）按需

### M6 升级流程 ⏳
- [ ] 升级 kimi-code：改 `scripts/versions.env` → 重新打包 → 回归
- [ ] （可选）应用内下载新版 npm 包覆盖运行

## 风险与预案

| 风险 | 预案 |
|---|---|
| 调试 Profile 不含 kernel.* ACL，V8 JIT 被 W^X 拒绝 | 调试签名的应用已可 mprotect R_X（Termony 实测）；不行则给 node 加 `--jitless` |
| `io_uring_setup` / `close_range` 被 seccomp trap | `UV_USE_IO_URING=0` + `libkimicompat.so` 预加载 |
| HNP 内 ELF 已带 ohos-node 的自签名段 | 先按原样交给 hap-sign-tool；若安装/执行报签名错误，用 `llvm-objcopy` 去掉 `.codesign` 再打包 |
| 系统 `/bin/sh` 对应用不可执行 → kimi Shell 工具不可用 | M5 内置 busybox/bash |
| 设备 OS 低于 compatibleSdkVersion | 调整 `compatibleSdkVersion`；所用 ArkWeb/Ability API 均 ≤ API 12 |
