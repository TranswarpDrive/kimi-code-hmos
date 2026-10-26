# 无扩展名可执行文件的重签兼容性

0.2.1 收到 HoKit 手机端重签后安装失败的反馈，提示“代码签名验证失败，请确保签名时 signCode 为 true”（错误码 9568393）。签名工具完成操作并不代表设备接受了所有代码签名。

## 已确认的原因与边界

旧版 OpenHarmony C++ 签名器的 `IsNativeFile` 先查找文件路径中的点号，找不到就返回 false，之后才检查 `libs/` 前缀。因此 `libs/arm64-v8a/node` 等文件会被漏签，`libs/arm64-v8a/node.bin` 则不会。Java 版没有这个前置判断。

上游已在 [2026-09-29 的修复](https://github.com/openharmony/developtools_hapsigner/commit/b83d1167d287e1232c0122fb43ca0715bc512306)中移除这个限制；可与[旧版实现](https://github.com/openharmony/developtools_hapsigner/blob/806ee87ab315/hapsigntool_cpp/codesigning/sign/src/code_signing.cpp)对照。

本地核对的 HoKit 桌面版 1.8.7 自带手机端 1.8.0：手机端传入了 `signCode=true`，其原生签名库仍有“未找到点号就返回 false”的逻辑。该检查针对这个具体版本，不能推断所有手机端版本的实现。原反馈设备上的确切 HoKit 版本、重签产物及安装日志尚未取得，仍需在原环境复测确认。

## 0.2.2 的兼容处理

- 随包 9 个可执行文件统一采用 `.bin` 后缀，同步更新 `executableBinaryPaths`、构建注入及运行时清单。
- 启动时直接执行已签名的 `node.bin`。构建时为 Node、Python、Git、ripgrep 及 Git helper 生成标准命令名的 shell 启动脚本，安装到只读 `resfile/kimicode/bin`；`PATH` 和 `GIT_EXEC_PATH` 指向该目录。
- 启动脚本通过系统 shell 的 `exec -a` 保留命令名与参数，执行安装目录中的原文件，不复制或修改 ELF，也不关闭代码签名。原生文件路径由应用启动时提供，覆盖升级无需维护沙箱中的旧路径。
- 本次 PC 模拟器的应用沙箱拒绝创建软链接，也拒绝执行可写数据目录中的脚本；因此采用随包安装到只读目录的启动脚本，并在 ZIP 中保留可执行位。
- 发布包校验拒绝 `libs/` 中没有扩展名的文件，并校验全部启动脚本的权限位和清单摘要；回归测试覆盖命令执行、Git helper 名称、参数转义及缺失运行时。

实际通过的构建、签名与设备测试见[本版验证记录](RELEASE-VALIDATION.md)。模拟器不能替代鸿蒙 PC 对签名、权限和 JIT 的真机验证。
