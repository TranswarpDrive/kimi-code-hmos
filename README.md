# Kimi Code for HarmonyOS PC（非官方外壳）

把官方 [Kimi Code](https://www.kimi.com/code) 的 Web UI（`kimi web`）打包成鸿蒙PC（2in1）可侧载的 HAP：

- 启动应用 → 自动在后台拉起内置的 `kimi web` 服务（Node 24 + `@moonshot-ai/kimi-code` npm 包，V8 JIT 正常开启）
- 应用窗口用 ArkWeb 展示官方 Web UI，自动带上本地服务 token
- 登录（OAuth 设备码授权页）以及其他外部链接 → 用系统默认浏览器打开
- 窗口最小化时用 2in1 长时任务保持服务运行；关闭应用时停止服务

> 这是个人侧载项目，与 Moonshot AI / 华为无关。Kimi Code 本体及其商标归 Moonshot AI 所有。
>
> 已在 MOR-M1（HarmonyOS 7.0.0，API 26）真机验证：登录、对话、Shell 工具可用。

## 环境要求

| 组件 | 说明 |
|---|---|
| macOS（Apple Silicon） | 已在本机验证；Linux 理论可用 |
| DevEco Command Line Tools | 默认路径 `~/DevTools/command-line-tools-26/command-line-tools`，可用 `DEVECO_CLI_CLT_PATH` 覆盖 |
| `devecocli` | `npm i -g @deveco/deveco-cli`，用于命令行登录和自动签名 |
| JDK 17+、Node 22+、`zip` | 签名工具、构建脚本 |
| 鸿蒙PC | 开启开发者模式，USB 调试或无线调试 |

## 连接鸿蒙PC

在鸿蒙PC 上：设置 → 关于本机 → 连续点“软件版本”开启开发者模式；再到 设置 → 系统 → 开发者选项，
打开“USB 调试”并用 USB-C 数据线连到 Mac（最稳），或打开“无线调试”：

```bash
hdc tconn <鸿蒙PC 无线调试页显示的 IP:端口>   # 无线调试，要求两台机器在同一个二层网络
hdc list targets                              # 能看到设备即可
```

首次连接时鸿蒙PC 上会弹出“允许调试”确认，选择允许。

## 快速开始

```bash
# 1. 首次：生成调试证书和调试 Profile（需要登录华为开发者账号、并连接鸿蒙PC）
scripts/setup-signing.sh

# 2. 构建（下载并校验依赖 → 打 HNP → 构建并签名），产物在 dist/
scripts/build.sh

# 3. 安装并启动
scripts/install.sh
```

未连接设备时 `scripts/build.sh` 也能运行，只是只产出未签名 HAP（用于检查包结构）。

## 工作原理

```
HAP
├── ets / libs/arm64-v8a/libkimihost.so   ArkTS 壳 + NAPI 进程管理（fork/execve/kill）
├── libs/arm64-v8a/node                   鸿蒙版 Node，executableBinaryPaths 声明，ELF .permission 节继承应用权限
├── libs/arm64-v8a/libkimicompat.so       LD_PRELOAD 兼容层（seccomp TRAP → -ENOSYS）
└── hnp/arm64-v8a/kimicode.hnp            → /data/app/kimicode.org/kimicode_<ver>/{package/, runtime/ohos-preload.cjs}
```

- 随包 bin 的权限写在 ELF 的 `.permission` 节：node 声明 `INHERIT_PARENT_PERMISSION`，被壳拉起时继承应用的
  JIT（`kernel.ALLOW_WRITABLE_CODE_MEMORY`）与联网权限，见官方“应用程序包集成bin文件（PC/2in1）”。
- HAP 签名时 hap-sign-tool 会对 `libs/` 下所有文件和 HNP 内的 ELF 做代码签名。
- 应用沙箱的限制由两层兼容处理：`libkimicompat.so`（seccomp TRAP → -ENOSYS，并禁止线程屏蔽 SIGSYS）和
  `ohos-preload.cjs`（硬链接回退、worker 继承补丁、禁用会话搜索 worker）。
- 细节见 [CLAUDE.md](CLAUDE.md)、[docs/HARMONYOS-NOTES.md](docs/HARMONYOS-NOTES.md)，进度见 [docs/PLAN.md](docs/PLAN.md)。

## 升级 Kimi Code

1. 改 `scripts/versions.env` 里的 `KIMI_CODE_VERSION` 和 `KIMI_CODE_INTEGRITY`（`npm view @moonshot-ai/kimi-code@<ver> dist.integrity`）
2. 若依赖有变化，同步 `runtime/kimi-deps/package.json` 并更新锁文件
3. `scripts/build.sh && scripts/install.sh`，在设备上回归登录、对话、工具调用

## 已知限制

- 会话全文搜索暂不可用：kimi 登录后创建会话搜索 worker 会让服务进程被 SIGSYS 结束，壳里暂时禁用了它（见 docs/HARMONYOS-NOTES.md）。
- 文件上传/下载、文件预览新窗口尚未适配；Web 终端面板（node-pty）、ripgrep、git 等工具尚未内置。
- 只能调试签名侧载：上架需要 AGC 审批 `ALLOW_WRITABLE_CODE_MEMORY` 并申请“二进制证书”。调试 Profile 一年后过期，
  重新运行 `scripts/setup-signing.sh default --force` 即可。

## 排障

- 启动页/失败页可展开日志；失败页的“开启调试日志并重启”会打开 kimi debug 日志与系统调用/API 追踪（排障完记得关）。
- 系统日志：`hdc shell "hilog -T KimiShell"`（node 的输出以 `[node]` 前缀转发，token 已打码）。
- 设备拒绝 V8 JIT 时，壳会自动改用 `node --jitless` 重试并在顶部提示（此时联网功能不可用，检查签名 Profile 的 ACL）。
- 安装报签名不一致：`hdc uninstall com.kimicodehmos.app` 后再 `scripts/install.sh`（会清空应用内的登录状态）。
