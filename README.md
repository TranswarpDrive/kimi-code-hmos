# Kimi Code for HarmonyOS PC（非官方外壳）

[English](README.en.md) · [安装与升级](docs/INSTALL.md) · [构建与发布](docs/RELEASING.md) · [版本验证记录](docs/RELEASE-VALIDATION.md)

将官方 [Kimi Code](https://www.kimi.com/code) 的 Web UI 打包为鸿蒙 PC 应用：内置 Node、Kimi Code、Python、Git 和 ripgrep，启动后即可在应用窗口中登录和使用。

**当前版本 0.2.0，面向 HarmonyOS PC（2in1）、API 26 的公开测试。** 不支持手机和平板。发布附件为未签名 HAP，接收方需要用自己的华为开发者账号签名后侧载；不是 AppGallery 应用，也不能免签直接安装。具体已验证和未覆盖范围见[验证记录](docs/RELEASE-VALIDATION.md)。

## 下载与安装

在本仓库 GitHub Releases 下载 `*-release-unsigned.hap`、`SHA256SUMS` 和安装说明。校验文件后，用支持鸿蒙 PC 随包二进制签名的工具给自己的设备签名安装。Profile 需要包含 JIT 与目录持久访问 ACL，详见[安装说明](docs/INSTALL.md)。

升级时沿用原证书并覆盖安装，以保留登录和会话。签名不一致时先找回原证书；卸载会清除应用沙箱数据。

## 功能与边界

- 内置 `kimi web`，ArkWeb 展示上游 Web UI；登录授权及外部链接交给系统浏览器。
- 支持会话搜索、文件上传、会话 ZIP 导出、blob 文件预览与保存。
- 内置 Python 3.14.6、Git 2.55.0、ripgrep 13.0.0，供 Shell 等工具使用。
- 工具栏提供工作目录选择、服务重启、日志查看和关闭调试。
- 搜索在独立 Node 子进程中运行，服务操作串行处理；关闭应用清理服务进程组。
- 日志限制大小并轮转，界面和系统日志统一脱敏。

已知限制：网页终端需要的 PTY 被设备沙箱禁止；可使用 Shell 工具执行命令。会话 ZIP/blob 下载上限为 **32 MiB**。后台运行、目录访问和模型联网分别依赖系统权限、签名 Profile 与用户账号。调试日志仍可能包含个人路径或对话内容，反馈前请检查。

## 从源码构建

已验证构建环境为 macOS Apple Silicon、DevEco Command Line Tools 26、JDK 17、Node ≥22.19、Python 3。完整工具清单和模拟器边界见[构建说明](docs/RELEASING.md)。

```bash
# 无签名材料也能构建分发包
KIMI_UNSIGNED_ONLY=1 scripts/build.sh release

# 生成可用于 GitHub Release 的附件目录
python3 scripts/prepare-release.py dist/KimiCode-hmos-0.2.0-kimi2.2.0-release-unsigned.hap
```

需要自用安装时，首次运行 `scripts/setup-signing.sh`，以后直接 `scripts/build.sh release` 和 `scripts/install.sh`。脚本使用已有本地签名，签名材料不会进入公开附件。

## 测试

```bash
npm ci --ignore-scripts
npm run check
bash scripts/fetch-test-upstream.sh
KIMI_REQUIRE_UPSTREAM=1 npm test
```

测试涵盖真实上游搜索索引的连续打开/关闭、并发 worker、进程终止、重启竞争、后台任务、文件失败清理、下载限制、原生桥来源和日志脱敏。GitHub CI 在 Node 22.19 / 24 上运行；完整构建另检查 ArkTS/C++ 编译、运行时清单、ELF 权限、包完整性和意外签名文件。实际结果见[版本验证记录](docs/RELEASE-VALIDATION.md)。

## 实现

- ArkTS + ArkWeb 外壳，NAPI 负责启动和回收随包进程。
- Node、Python、Git 等 ELF 放在 `libs/` 中签名，通过 `.permission` 节继承应用权限。
- Kimi 包与 Python 标准库放在 `resfile/`，安装时解压成真实文件。
- `libkimicompat.so` 处理沙箱 syscall 限制；`runtime/` 提供搜索子进程和兼容补丁。
- 依赖版本和哈希由 `scripts/versions.env` 锁定。升级时须重新跑上游协议测试和真机验收。

平台历史、架构和开发约定见 [CLAUDE.md](CLAUDE.md)、[HARMONYOS-NOTES.md](docs/HARMONYOS-NOTES.md)。原项目由 Claude（Anthropic）协助开发，后由 kimi-k3 接续；原有署名保留。

## 许可与反馈

外壳代码采用 [MIT](LICENSE)，内置组件采用各自许可证，见[第三方说明](THIRD-PARTY-NOTICES.md)。本项目与 Moonshot AI、华为无隶属或官方维护关系。

请通过仓库的 Bug report 模板提供版本、环境、步骤和脱敏日志。不要上传签名材料、token 或完整个人会话。
