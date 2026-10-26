# 0.3.0 本地候选验证记录

验证日期：2026-10-26。本版增加官方 npm 的 Kimi Code CLI / WebUI 自更新，并包含 0.2.2 的旧签名器兼容性修复。当前只整理本地候选附件，尚未替换 GitHub 的公开下载。

## 本次通过

| 项目 | 方法与结果 |
| --- | --- |
| 自动化回归 | 完整 `scripts/build.sh release` 中 37 项 Node/ArkTS 测试和 7 项 Python 包校验测试通过，无跳过；覆盖更新事务、项目文件不变、首次启动回滚、更新进程取消、bin-links 禁用和上游搜索 |
| 构建与 HAP 结构 | macOS Apple Silicon + DevEco CLT 26，release 编译及 signed/unsigned HAP 校验通过。版本 0.3.0 / 1002000、API 26 / 2in1、9 个可执行文件、219 个运行时文件；npm 归档路径、类型、重复项、展开大小和必需文件均通过检查 |
| 官方安装与 Web 冒烟 | 在隔离目录使用随包 npm 归档安装官方 `@moonshot-ai/kimi-code@2.3.2` 及 33 个运行时包，锁文件官方 tarball/SHA-512、CLI `--version` 和 WebUI 资产通过；实际 `kimi web` 的 healthz 返回 200，首页 HTML 与标题正确 |
| 更新状态完整性 | 主机真实完成 install → activate → commit → rollback；确认不生成 `node_modules/.bin` 软链接，损坏状态可独立恢复随包，已有示例项目的 package/锁文件/node_modules 逐字节不变 |
| 新版搜索兼容 | 使用真实 2.3.2 `search-worker.mjs` 连续三次建立索引、命中唯一测试文本、关闭并重新打开数据库，均通过 |
| 模拟器官方更新 | HarmonyOS 6.1.1 / API 24 2in1 模拟器，原生界面发现官方 2.3.2，下载、校验、激活、重启和首次启动提交成功；日志明确显示 `Kimi server ready 2.3.2`，更新后的 WebUI 正常加载 |
| 模拟器数据保留与恢复 | 默认工作目录 `/storage/Users/currentUser/Documents` 和输入框中的 4 个历史附件标记在 2.2.0 → 2.3.2 → 恢复 2.2.0 后均保留；恢复后服务与 WebUI 正常 |
| API 26 真机覆盖安装 | MOR-M1（HarmonyOS 7 / API 26）使用既有签名配置 `hdc install -r`，从 0.2.2 覆盖安装最终 0.3.0 成功，系统确认 `versionName=0.3.0`、`versionCode=1002000`；未卸载应用 |

模拟器只用于功能自测，其专用 HAP 不作为公开附件。公开分发包仍只支持 API 26 的 2in1。

## 实际发现并修复的问题

- 首次模拟器安装时，npm 创建 `node_modules/.bin/kimi` 软链接被沙箱拒绝，退出码 243。旧 2.2.0 服务未被替换。随后为 npm 参数、环境与隔离配置统一禁用 bin-links，主机和模拟器复测通过。
- 首次复用候选包激活时，发现恢复专用版本检查缺少 `satisfies`。已调整为仅“恢复随包”不依赖 npm，激活、提交和回滚继续使用完整 npm semver，随后真实完成激活与首次启动提交。

## 未覆盖与限制

- MOR-M1 当前锁屏且暂时无法解锁，系统拒绝启动应用。因此真机只确认同证书覆盖安装和版本，**没有**把模拟器的官方更新、WebUI、JIT 或数据保留结果当作真机结果。
- 模拟器处于未登录状态，本次没有覆盖真实账号登录、已有会话、真实对话或 Shell 工具。数据保留仅指上述工作目录和 4 个历史附件标记，以及自动化中的项目文件不变测试。
- 自动首次启动回滚由 Node/ArkTS 测试覆盖，未在设备上故意损坏新版触发；取消下载由更新进程生命周期测试覆盖。
- 未重复新账号授权、多设备、全新安装、HoKit/小白重签、休眠唤醒、长时间后台运行和原签名问题设备的复测。网页终端仍受 PTY 限制，ZIP/blob 单次导出上限仍为 32 MiB。

公开下载前仍需真机解锁后的官方更新、登录/已有会话与真实对话回归；未完成这些项目时应继续使用 **Pre-release** 并保留本限制说明。

[0.2.1 验证记录](https://github.com/TranswarpDrive/kimi-code-hmos/blob/v0.2.1/docs/RELEASE-VALIDATION.md)与 [0.2.0 真机验证记录](https://github.com/TranswarpDrive/kimi-code-hmos/blob/v0.2.1/docs/RELEASE-VALIDATION-0.2.0.md)仅作为历史依据，不代表本版新增设备覆盖。
