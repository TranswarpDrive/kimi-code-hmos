# 第三方组件

本仓库自有外壳代码采用根目录的 MIT 许可证。HAP 中的第三方程序、运行时和依赖采用各自许可证；本文件不替代其原始许可文本。

| 组件 | 锁定版本/来源 | 随包许可位置（resources/resfile/kimicode/ 下） |
|---|---|---|
| Kimi Code | @moonshot-ai/kimi-code 2.2.0，npm registry | package/LICENSE（MIT） |
| Node.js | 24.21.0，[hqzing/ohos-node](https://github.com/hqzing/ohos-node) | licenses/node.LICENSE |
| npm | 11.19.0，来自上述 Node 发行包 | npm.tar.gz 内的 npm/LICENSE（Artistic-2.0） |
| tar 及解压依赖 | tar 7.5.19、@isaacs/fs-minipass、chownr、minipass、minizlib、yallist，来自上述 Node 发行包 | npm-extract/node_modules/ 下各包许可文件 |
| Git 及依赖 | 2.55.0，[Harmonybrew/ohos-git](https://github.com/Harmonybrew/ohos-git) | licenses/git.licenses.txt（含 GPL v2 等） |
| Python 及依赖 | 3.14.6，[Harmonybrew/ohos-python](https://github.com/Harmonybrew/ohos-python) | licenses/python.licenses.txt |
| ripgrep | dsh-harmonyos 0.15.0 固定提交的 rg 13.0.0 | licenses/ripgrep/LICENSE-MIT、UNLICENSE |
| ws、qrcode 及传递依赖 | runtime/kimi-deps/package-lock.json | package/node_modules/ 下各包许可文件 |
| libc++ 与鸿蒙原生运行库 | DevEco CLT 26 随 SDK 构建 | 依照相应 SDK/LLVM 的许可 |

二进制下载 URL、SHA-256 和 Kimi npm 完整性值见源码中的 `scripts/versions.env`。鸿蒙适配源码、补丁和构建方法由上述项目提供；ripgrep 对应来源为 [dsh-harmonyos 固定提交](https://github.com/ystyle/dsh-harmonyos/tree/8fefed1f474242cae6aaaa6f7fca1a46269659d5)。Kimi Code 的 npm 归档包含随包使用的 JavaScript 源文件。

本项目没有把 Node 伪装成 Linux，没有替换上游 Kimi 主程序。鸿蒙兼容改动位于本仓库的 `runtime/` 和 `entry/src/main/cpp/compat/`；构建脚本还会为可执行文件写入权限节。分发修改版时，应一并提供这些修改及对应组件的源码获取途径。

Kimi Code、Moonshot AI、HarmonyOS、Huawei 等名称及商标归各权利人所有。本项目未经其官方维护或背书。
