# Kimi Code for HarmonyOS PC（非官方外壳）

把官方 [Kimi Code](https://www.kimi.com/code) 的 Web UI（`kimi web`）打包成鸿蒙PC（2in1）可侧载的 HAP：

- 启动应用 → 自动在后台拉起内置的 `kimi web` 服务（Node 24 + `@moonshot-ai/kimi-code` npm 包）
- 应用窗口用 ArkWeb 展示官方 Web UI，自动带上本地服务 token
- 登录（OAuth 设备码授权页）以及其他外部链接 → 用系统默认浏览器打开
- 窗口最小化时用 2in1 长时任务保持服务运行；关闭应用时停止服务

> 这是个人侧载项目，与 Moonshot AI / 华为无关。Kimi Code 本体及其商标归 Moonshot AI 所有。

## 环境要求

| 组件 | 说明 |
|---|---|
| macOS（Apple Silicon） | 已在本机验证；Linux 理论可用 |
| DevEco Command Line Tools | 默认路径 `~/DevTools/command-line-tools-26/command-line-tools`，可用 `DEVECO_CLI_CLT_PATH` 覆盖 |
| `devecocli` | `npm i -g @deveco/deveco-cli`，用于命令行登录和自动签名 |
| JDK 17+、Node 22+、`zip` | 签名工具、构建脚本 |
| 鸿蒙PC | 开启开发者模式，USB 调试或无线调试 |

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
└── hnp/arm64-v8a/
    ├── node.hnp       → /data/app/node.org/node_24.21.0/{bin/node, lib/libc++_shared.so, lib/libkimicompat.so}
    └── kimicode.hnp   → /data/app/kimicode.org/kimicode_2.2.0/{package/, runtime/ohos-preload.cjs}
```

- HNP（HarmonyOS Native Package）是鸿蒙PC 分发命令行程序的官方机制；HAP 签名时 hap-sign-tool 会对其中的 ELF 做代码签名。
- 应用沙箱的限制由两层兼容处理：`libkimicompat.so`（SIGSYS → -ENOSYS）和 `ohos-preload.cjs`（硬链接回退等）。
- 细节见 [CLAUDE.md](CLAUDE.md)、[docs/HARMONYOS-NOTES.md](docs/HARMONYOS-NOTES.md)，进度见 [docs/PLAN.md](docs/PLAN.md)。

## 升级 Kimi Code

1. 改 `scripts/versions.env` 里的 `KIMI_CODE_VERSION` 和 `KIMI_CODE_INTEGRITY`（`npm view @moonshot-ai/kimi-code@<ver> dist.integrity`）
2. 若依赖有变化，同步 `runtime/kimi-deps/package.json` 并更新锁文件
3. `scripts/build.sh && scripts/install.sh`，在设备上回归登录、对话、工具调用

## 排障

- 应用内启动页可展开日志；日志文件在应用沙箱 `files/logs/kimi-server.log`
- 系统日志：`hdc shell hilog -x | grep KimiShell`
- 设备拒绝 V8 JIT 时，壳会自动改用 `node --jitless` 重试并记住（WebP 图片解码不可用）
- 安装报签名/设备不匹配：重新运行 `scripts/setup-signing.sh`（会注册当前连接的设备）
