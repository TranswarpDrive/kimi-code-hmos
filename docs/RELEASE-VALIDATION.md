# 0.4.1 验证记录

验证日期：2026-11-13。本版只增加剪贴板读取权限 `READ_PASTEBOARD`，让 Ctrl+V 能粘贴其他应用复制的图片和文字；其余代码与 0.4.0 相同，随包 Kimi Code 仍为 2.2.0。

## 本次通过

| 项目 | 方法与结果 |
| --- | --- |
| 自动化回归 | `npm run check` 通过；45 项 Node/ArkTS 测试与 7 项 Python 包校验测试全部通过，真实上游搜索测试无跳过 |
| 构建与 HAP 结构 | macOS Apple Silicon + DevEco CLT 26，`scripts/build.sh release` 编译及 signed/unsigned HAP 校验通过；版本 0.4.1 / 1003001、API 26 / 2in1；校验确认包内声明 `READ_PASTEBOARD` |
| 重签与覆盖安装 | 重新生成的调试 Profile 含 `READ_PASTEBOARD` ACL，appIdentifier 不变；MOR-M1（HarmonyOS 7 / API 26）用新签名覆盖安装成功，登录、会话与工作目录保留 |
| 权限授予 | 首次启动随目录权限一起弹出授权；`atm dump` 确认已授予 |
| 跨应用粘贴图片 | 在系统图片查看器复制 PNG（剪贴板为 `text/uri`，来源为其他应用），在 Kimi 输入框粘贴：页面 paste 事件收到一个 `image/png` 文件，上游 Web 将其加为图片附件 |
| 权限对照 | 撤销 `READ_PASTEBOARD` 后重复同一粘贴，clipboardData 为空、剪贴板服务记录 permission denied；恢复授权后再次正常 |

粘贴通过 DevTools 向页面发送浏览器自身的粘贴命令（与实体键盘 Ctrl+V 走同一条剪贴板读取路径）完成；uitest 与 HoKit 投屏的组合键无法送达 ArkWeb，未用实体键盘逐键复测。验证用的 Web 调试开关不在发布包中。

## 未覆盖与限制

- 截图工具、浏览器“复制图片”等其他图片来源未逐一测试；只验证了图片查看器复制和本应用写入的位图。
- 拒绝剪贴板权限后应用仍可用，但跨应用粘贴为空；需要到系统设置里重新开启。
- 重签时 Profile 必须包含 `READ_PASTEBOARD` ACL，否则安装失败；HoKit 一般自动带上，小白调试助手需在 ACL 设置页勾选。本次只验证了 devecocli 生成的调试 Profile。
- 只使用一台 MOR-M1；其他设备、全新安装与长时间运行未覆盖。其余功能沿用 [0.4.0 验证记录](RELEASE-VALIDATION-0.4.0.md)。

继续以 **Pre-release** 发布。

[0.4.0](RELEASE-VALIDATION-0.4.0.md)、[0.3.0](RELEASE-VALIDATION-0.3.0.md) 与 [0.2.0](RELEASE-VALIDATION-0.2.0.md) 验证记录仅作为历史依据。
