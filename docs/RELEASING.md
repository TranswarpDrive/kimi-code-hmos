# 构建与发布

## 构建环境

目前完整 HAP 构建在 macOS Apple Silicon + DevEco Command Line Tools 26 验证。其他构建主机尚未验证。需要 Node ≥22.19、npm、Python 3、JDK 17，以及 CLT 的 ohpm、hvigorw、hdc 和 LLVM 工具；还需要 curl、tar、openssl、zip、unzip、shasum。

```bash
export DEVECO_CLI_CLT_PATH="$HOME/DevTools/command-line-tools-26/command-line-tools"
export PATH="$DEVECO_CLI_CLT_PATH/bin:$DEVECO_CLI_CLT_PATH/sdk/default/openharmony/toolchains:$PATH"
```

脚本下载地址、版本和校验值固定在 `scripts/versions.env`。每次构建重新从校验通过的归档提取依赖，并用 npm 锁文件安装运行时依赖，避免解压缓存被改动后误打包。

## 日常开发

```bash
npm ci --ignore-scripts
npm run check
bash scripts/fetch-test-upstream.sh
KIMI_REQUIRE_UPSTREAM=1 npm test
scripts/build.sh release
scripts/install.sh dist/KimiCode-hmos-0.2.0-kimi2.2.0-release-signed.hap
```

首次自用签名可运行 `scripts/setup-signing.sh`（需要 devecocli 和自己的华为账号）。已有签名配置时日常升级直接构建、安装，不必重新生成。构建是否签名取决于本地配置，和设备是否连接无关。

`npm test` 会测试真实 ArkTS 服务逻辑的转译结果和 Node 兼容层；它不等于鸿蒙 SDK 的类型检查。完整 `build.sh` 必须通过上游搜索集成测试、ArkTS/C++ 编译和 HAP 检查。GitHub CI 不需要签名材料，会下载锁定的 Kimi 包，在 Node 22.19 / 24 上执行回归测试；CI 不生成 HAP。

## 生成可分发附件

```bash
KIMI_UNSIGNED_ONLY=1 scripts/build.sh release
python3 scripts/prepare-release.py dist/KimiCode-hmos-0.2.0-kimi2.2.0-release-unsigned.hap
```

输出为 `dist/release-0.2.0/`，只含未签名 HAP、安装说明、变更记录、验证范围、许可证说明、机器可读版本信息与 `SHA256SUMS`。整理脚本拒绝 debug 包、版本不匹配的旧包和已存在的发布目录。

`verify-hap.py` 校验 ZIP 完整性、重复/危险路径、意外签名材料、API/设备类型、ELF 架构与权限节、关键运行时哈希和 Python 模块。它验证包结构，不能替代实际设备运行。

## 发布前验收

先更新 `docs/RELEASE-VALIDATION.md`，填写本次实际通过和未覆盖的项目：

- 同证书覆盖升级后登录和会话保留；干净设备首次安装、授权和登录。
- 冷启动、连续重启、搜索命中、退后台、关闭窗口后的进程回收。
- 文件上传、ZIP/blob 下载、防重名、工作目录切换及冷启动恢复。
- Python、git、rg、Shell 工具及 HTTPS；另一名使用者以自己的设备和 Profile 重签安装。

将已验证的未签名包整理为附件后再创建 GitHub Release。尚未覆盖多设备和全新账号安装时使用 **Pre-release**，并在发布说明列出限制。不要把整个 `dist/`、`vendor/`、测试截图或本地签名目录拖进 Release。Git 源码不包含这些生成物。

内置第三方组件采用各自许可证，发布时保留 `THIRD-PARTY-NOTICES.md` 和 HAP 内许可证，并提供与二进制对应的上游源码、补丁及构建脚本获取途径。

## 升级内置 Kimi

更新 `scripts/versions.env` 中版本和完整性校验值，按上游 package.json 更新 `runtime/kimi-deps` 的清单与锁文件，再重新执行完整构建与真机验收。尤其检查搜索 worker 的消息协议；不能因版本号相近而跳过集成测试。
