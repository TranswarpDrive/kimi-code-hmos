# 安装与升级

适用于 **HarmonyOS PC（2in1）、API 26**。不支持手机、平板及旧版 HarmonyOS。应用内置 Kimi Code 2.2.0；使用模型还需要自己的 Kimi 账号和可用服务。

## 下载

从 [GitHub Releases](https://github.com/TranswarpDrive/kimi-code-hmos/releases) 下载 `*-release-unsigned.hap`，**只需要这一个文件**。这是未签名安装包，需要用自己的华为开发者账号签名后安装。

0.3.0 当前为本地候选，尚未替换公开的 0.2.1。收到候选包时，直接导入该 HAP 重签；实际测试范围见[验证记录](RELEASE-VALIDATION.md)。

`SHA256SUMS` 仅用于可选的完整性校验，不参与签名或安装。

<details>
<summary>可选：检查下载文件是否完整</summary>

在发布页查看 `SHA256SUMS`，或下载这份校验清单，再与本地计算的结果对比。

macOS 在下载目录中运行：

```bash
shasum -a 256 KimiCode-hmos-0.2.1-kimi2.2.0-release-unsigned.hap
```

Linux 可用 `sha256sum`；Windows PowerShell 可用 `Get-FileHash <文件路径> -Algorithm SHA256`。将结果与 `SHA256SUMS` 中对应文件的一行核对。下载完整的全部附件后，也可运行 `shasum -a 256 -c SHA256SUMS`。

</details>

## 首次安装

1. 在鸿蒙电脑开启开发者模式和 USB/无线调试，允许连接设备的电脑进行调试。
2. 使用支持鸿蒙 PC 随包二进制签名的工具，例如 [HoKit 桌面版](https://github.com/yabi-zzh/HoKit)，登录**自己的**华为开发者账号。手机端与桌面端的签名实现不同，不能把其中一个版本的测试结果当作另一个版本的保证。
3. 导入未签名 HAP，使用工具生成的证书和本设备 Profile 签名、安装。Profile 必须包含包内声明的 ACL，尤其是 `ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY`（JIT）与 `ohos.permission.FILE_ACCESS_PERSIST`（目录持久授权）。不要用删除权限声明的方法绕过签名失败。
4. 启动 Kimi Code，允许所需的“文档”“下载”和后台运行权限。首次加载需要解压运行时并启动服务。
5. 登录时在系统浏览器完成 Kimi 设备码授权，回到应用。授权由 Kimi 服务轮询确认。
6. 用顶部“选择目录”指定项目文件夹，再开始使用。新会话使用新的默认目录；已有会话仍可能保留其原工作目录。

发布包不含签名证书、个人账号、会话或开发者设备信息。第三方签名工具各版本的操作界面可能不同，以工具实际提示为准。

## 升级与证书续期

使用**同一账号、同一证书**给新版 HAP 签名并覆盖安装。开发脚本 `scripts/install.sh` 使用覆盖安装，保留登录和会话。

遇到签名不一致时，先找回原证书或原签名工具配置。**卸载会删除应用沙箱中的登录、会话和默认沙箱工作文件**；确实需要更换证书时，先导出需要保留的会话并复制工作文件，再自行决定是否卸载。

调试 Profile 的期限以签名工具显示为准。续期尽量沿用原证书。不要为了日常升级反复生成新证书。

## 更新内置 CLI 与 WebUI

1. 点击顶部“更新”→“检查更新”。应用只连接官方 `https://registry.npmjs.org`，CLI 与 WebUI 使用同一个 `@moonshot-ai/kimi-code` 版本。
2. 发现新版后，先完成或保存正在执行的任务，再点击“下载并更新”并二次确认。下载和校验期间旧服务继续运行，完成后才会重启切换。
3. 更新安装在应用私有目录，不会修改项目中的 `package.json`、锁文件或 `node_modules`，也不会清除登录、已有会话、工作目录和目录授权。
4. 新版首次启动失败会自动恢复上一可用版本。更新界面也可手动“恢复随包版本”；恢复同样需要重启，但不删除项目数据。

此功能不更新 HAP 外壳、Node、Python、Git 或 ripgrep。壳和原生运行时的升级仍需按上一节同证书覆盖安装。取消或中断下载不会激活不完整版本；不要删除应用数据来排除更新故障。

## 常见问题

| 现象 | 处理 |
|---|---|
| 设备类型/API 不支持 | 确认是鸿蒙 PC 2in1、API 26；模拟器专用包不用于分发 |
| 签名完成，但安装提示 `signCode` / 9568393 | 0.2.1 及更早的包可能被旧版 C++ 签名器漏签部分程序。0.2.2 及以后已调整文件命名以规避；导入新版原始未签名包重新签名。仍失败时保留错误日志，换桌面版作对照，勿反复清理证书或卸载。详见[签名兼容性说明](SIGNING-COMPATIBILITY.md) |
| 安装提示 ACL、Profile 或代码签名错误 | 检查 Profile 绑定的设备、上述 ACL，以及工具是否给所有随包 ELF 签名 |
| 启动失败、信号退出 | 打开“查看日志”；检查 JIT ACL。当前版本不再把无法联网的 jitless 模式显示为可用 |
| 更新检查、下载或新版启动失败 | 查看“更新日志”；检查能否访问官方 npm。失败不会激活半成品；新版首次启动失败会回滚，也可手动恢复随包版本，勿清除应用数据 |
| 工作目录无法访问 | 重新选择目录并授权；冷启动恢复授权失败时会提示并使用默认目录 |
| 保存下载失败 | 检查“下载”目录权限和剩余空间。会话 ZIP、blob 下载上限 32 MiB，超限请缩小导出范围 |
| 搜索暂时没有结果 | 首次建立索引可能需要时间；仍失败时查看日志并重启服务 |
| 网页终端不可用 | 当前设备沙箱不允许 PTY；请使用 Kimi Shell 工具执行命令 |
| 调试日志太多 | 点击“关闭调试”并重启。日志会轮转，不会无限累积 |

反馈问题请使用仓库的 Bug report 模板，附应用版本、系统版本、签名工具、复现步骤和脱敏日志。不要上传证书、Profile、token 或个人会话内容。

## English

Requires a HarmonyOS **PC / 2in1, API 26**. You only need to download the `release-unsigned.hap`. Checking its SHA-256 against `SHA256SUMS` is optional. Sign the HAP with your own Huawei developer certificate and a profile for your device, using a tool that signs bundled ELF executables. The profile must include the requested JIT and persistent-file-access ACL permissions.

Keep the same certificate when upgrading and install in place. Uninstalling deletes sandboxed login state, sessions and workspace files. The Web terminal is unavailable; use the Shell tool. Blob/session ZIP downloads are limited to 32 MiB.

The toolbar's **Update** entry downloads matching CLI and Web UI versions from the official npm registry. Downloads are verified and staged before a confirmed restart; a failed first launch rolls back. Projects, sign-in state, sessions and folder grants are preserved. This does not update the HAP shell or native Node runtime. See the [validation record](https://github.com/TranswarpDrive/kimi-code-hmos/blob/v0.2.1/docs/RELEASE-VALIDATION.md) for the exact tested scope.
