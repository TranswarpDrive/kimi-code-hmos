<div align="center">
  <img src="entry/src/main/resources/base/media/startIcon.png" width="88" alt="Kimi Code 图标" />
  <h1>Kimi Code for HarmonyOS PC</h1>
  <p>在鸿蒙电脑上使用 Kimi Code。</p>
  <p>
    <a href="https://github.com/TranswarpDrive/kimi-code-hmos/releases/tag/v0.2.1">下载 v0.2.1</a> ·
    <a href="docs/INSTALL.md">安装教程</a> ·
    <a href="README.en.md">English</a>
  </p>
  <p>公开测试版 · HarmonyOS PC / API 26 · MIT</p>
</div>

这是 [Kimi Code](https://www.kimi.com/code) 的非官方鸿蒙 PC 移植版。它把 Kimi Code 的网页界面和运行环境打包成一个独立应用，让你在自己的项目目录中使用 Kimi Code，无需额外安装 Node、Python 或 Git。

## 下载与安装

1. **[下载 HAP 安装包](https://github.com/TranswarpDrive/kimi-code-hmos/releases/download/v0.2.1/KimiCode-hmos-0.2.1-kimi2.2.0-release-unsigned.hap)**，只需要这一个文件。
2. 用支持鸿蒙 PC 的签名工具，为自己的设备签名、安装。具体步骤见[安装教程](docs/INSTALL.md)。
3. 打开应用，登录 Kimi 账号，选择项目文件夹后即可开始使用。

> 安装包需要自行签名才能安装。目前仅支持 **API 26 的鸿蒙 PC（2in1）**，暂不支持手机和平板。使用模型需要自己的 Kimi 账号及可用服务。

发布页里的 `SHA256SUMS` 是**可选的文件校验清单**，不参与签名或安装。想确认下载是否完整，可以按[校验方法](docs/INSTALL.md)核对。

## 可以做什么

- 在独立窗口中与 Kimi Code 对话，处理代码和项目文件。
- 选择本地项目目录，上传文件、搜索会话、导出会话记录。
- 使用内置的 Python、Git 和 ripgrep，供 Kimi 的 Shell 工具调用。
- 在顶部工具栏切换目录、重启服务或查看日志。

## 使用前了解

| 项目 | 当前情况 |
| --- | --- |
| 网页终端 | 暂不可用，可以通过 Kimi 的 Shell 工具运行命令 |
| 文件导出 | 会话 ZIP 和网页生成的文件，单次保存上限为 32 MiB |
| 升级安装 | 沿用原签名证书并覆盖安装；卸载会清除应用内的登录和会话 |

这是公开测试版。GitHub 当前下载为 0.2.1；源码中的 0.2.2 是针对旧签名器漏签问题的修复候选，尚待原设备重签安装复测。0.2.0 已在 MOR-M1 / API 26 上做过真机测试，其他设备、首次安装和长时间运行仍需进一步验证，详见[验证记录](docs/RELEASE-VALIDATION.md)。

遇到问题可以[提交反馈](https://github.com/TranswarpDrive/kimi-code-hmos/issues/new?template=bug_report.yml)，说明系统版本、签名工具和复现步骤。附日志前，请先遮住账号凭据和个人对话。

## 从源码构建

完整构建目前在 macOS Apple Silicon + DevEco Command Line Tools 26 上验证。准备好环境后，在项目目录运行：

```bash
KIMI_UNSIGNED_ONLY=1 scripts/build.sh release
```

环境配置、自用签名和测试方法见[构建与发布](docs/RELEASING.md)。想了解实现，可以从[项目结构](CLAUDE.md)和[鸿蒙适配笔记](docs/HARMONYOS-NOTES.md)看起。

## 贡献者与 AI 协作

维护者：[@TranswarpDrive](https://github.com/TranswarpDrive)。参与开发的 AI 工具包括：

- **Claude（Anthropic）**：早期移植与工程搭建。
- **kimi-k3**：后续功能完善。
- **[Codex（OpenAI）](https://github.com/codex)**：0.2.1 的稳定性修复、测试和发布流程完善。

## 许可

本项目代码采用 [MIT](LICENSE) 许可，内置组件遵循各自的[第三方许可](THIRD-PARTY-NOTICES.md)。这是社区移植项目，与 Moonshot AI、华为无隶属或官方维护关系。
