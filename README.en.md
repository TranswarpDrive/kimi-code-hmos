# Kimi Code for HarmonyOS PC (Unofficial Wrapper)

> [中文版本](README.md)

Package the official [Kimi Code](https://www.kimi.com/code) Web UI (`kimi web`) into a sideloadable HAP for HarmonyOS PC (2in1):

- Launch the app → automatically start the built-in `kimi web` service in the background (Node 24 + `@moonshot-ai/kimi-code` npm package, V8 JIT enabled)
- The app window displays the official Web UI via ArkWeb, automatically carrying the local service token
- Login (OAuth device-code authorization page) and other external links open in the system default browser
- File upload, session ZIP export, blob file preview and download (saved to system "Downloads")
- Bundled ripgrep, git, and Python 3.14.6: Agent can search content, run Git status/diff/log and HTTPS remote operations, and run Python with ssl, sqlite3, and other common modules
- Top toolbar for selecting working directory, restarting service, and viewing logs (token redacted)
- Long-running task keeps the service alive when minimized; closing the app stops the service

## Project Background

This project was originally developed with assistance from **Claude** (Anthropic). After Claude's account was suspended, **`kimi-k3`** took over to complete the final fixes, real-device validation, documentation wrap-up, and open-source release.

Authorship is credited to **Claude (Anthropic) and kimi-k3**. This project is not affiliated with Moonshot AI, Huawei, or the author's personal devices, and contains no personal identifying information.

> This is a personal sideload project, unrelated to Moonshot AI / Huawei. The Kimi Code software and trademarks belong to Moonshot AI.
>
> Verified on a real MOR-M1 device (HarmonyOS 7.0.0, API 26): login, chat, and Shell tools work.

## Requirements

| Component | Notes |
|---|---|
| macOS (Apple Silicon) | Verified locally; Linux should work in theory |
| DevEco Command Line Tools | Default path `~/DevTools/command-line-tools-26/command-line-tools`, override with `DEVECO_CLI_CLT_PATH` |
| `devecocli` | `npm i -g @deveco/deveco-cli`, used for CLI login and automatic signing |
| JDK 17+, Node 22+, `zip` | For signing tools and build scripts |
| HarmonyOS PC | HarmonyOS 7.0 (API 26), developer mode enabled, USB or wireless debugging |

## Sideloading to Others (Not on AppGallery)

Only supports **HarmonyOS 7.0 (API 26) HarmonyOS PCs**. Send the **`*-unsigned.hap`** file in `dist/` (along with the `.sha256`) to the recipient, who then uses [HoKit](https://github.com/yabi-zzh/HoKit) or the "Xiaobai Debugger Assistant" with **their own Huawei developer account** to "one-click sign and install":

1. The recipient enables developer mode and USB/wireless debugging on the HarmonyOS PC, connects the device with the tool, and logs into their Huawei account;
2. Import the unsigned HAP and execute "one-click sign & install". This app requests the restricted permission `ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY` (required for the built-in Node JIT): HoKit will automatically apply for it based on the package declaration; if the Xiaobai tool prompts for ACL, check/add this permission in the ACL settings;
3. If an old version signed by someone else is installed, uninstall it first before installing (different certificates cannot overwrite; uninstalling clears the in-app Kimi login and sessions);
4. Debug packages signed with a personal account have an expiration date; when expired, simply re-sign/re-install with the same tool.

> The app runs with a debug certificate: logs and Profile are bound to the recipient's own account and device. Do not share your signing materials (`~/.ohos/config`, `signing/`) with others.

## Connecting the HarmonyOS PC

On the HarmonyOS PC: Settings → About this PC → tap "Software version" repeatedly to enable developer mode; then go to Settings → System → Developer options, turn on "USB debugging" and connect to Mac with a USB-C cable (most stable), or turn on "Wireless debugging":

```bash
hdc tconn <IP:port shown on the wireless debugging page>   # wireless debugging requires both devices on the same L2 network
hdc list targets                                           # device visible is enough
```

The first connection will pop up an "Allow debugging" confirmation on the HarmonyOS PC; choose Allow.

## Quick Start

```bash
# 1. First time: generate debug certificate and debug Profile (requires Huawei developer login and connected HarmonyOS PC)
scripts/setup-signing.sh

# 2. Build (download & verify deps → place node & kimi package → build & sign), output in dist/
scripts/build.sh

# 3. Install and launch
scripts/install.sh
```

`scripts/build.sh` can also run without a connected device, producing only the unsigned HAP (for inspecting package structure).

When a real device is not available, you can self-test using the local 2in1 emulator (emulator image tops at API 24, so a separate `emulator` product is built; the emulator does not restrict JIT, so JIT and permission-related issues still need real-device verification):

```bash
export DEVECO_CLI_CLT_PATH=$HOME/DevTools/command-line-tools-26/command-line-tools          # devecocli needs this
devecocli emulator create --device-type 2in1 --os-version="HarmonyOS 6.1.1(24)" KimiPC_API24   # first time only
scripts/emulator.sh   # build → start emulator (if not running) → install → launch app
```

## How It Works

```
HAP
├── ets / libs/arm64-v8a/libkimihost.so   ArkTS shell + NAPI process management (fork/execve/kill)
├── libs/arm64-v8a/                       node, python3, rg, git, and Python native libs; executable bins carry .permission section
├── libs/arm64-v8a/libkimicompat.so       LD_PRELOAD compatibility layer (seccomp TRAP → -ENOSYS)
└── resources/resfile/kimicode/           kimi-code, preload patches, and Python stdlib, extracted to <resourceDir>/kimicode at install time
```

- Permissions for bundled binaries are written in the ELF `.permission` section: executables declare `INHERIT_PARENT_PERMISSION`, so when launched by the shell they inherit the app's JIT (`kernel.ALLOW_WRITABLE_CODE_MEMORY`) and networking permissions. See the official "Application Package Integrating bin Files (PC/2in1)" guide.
- HAP signing (including re-signing by recipient tools) uses hap-sign-tool to code-sign all files under `libs/`.
- App sandbox restrictions are handled by two compatibility layers: `libkimicompat.so` (seccomp TRAP → -ENOSYS, and forbids the main thread from masking SIGSYS) and `ohos-preload.cjs` (hard link fallback, worker inheritance patch, session search worker inlined into main thread).
- Details see [CLAUDE.md](CLAUDE.md), [docs/HARMONYOS-NOTES.md](docs/HARMONYOS-NOTES.md), progress see [docs/PLAN.md](docs/PLAN.md).

## Upgrading Kimi Code

1. Update `KIMI_CODE_VERSION` and `KIMI_CODE_INTEGRITY` in `scripts/versions.env` (`npm view @moonshot-ai/kimi-code@<ver> dist.integrity`)
2. If dependencies change, sync `runtime/kimi-deps/package.json` and update the lockfile
3. `scripts/build.sh && scripts/install.sh`, then regress login, chat, and tool calls on the device

## Known Limitations

- Web terminal unavailable: the real-device sandbox denies access to `/dev/ptmx` and `/dev/pts` (EACCES), so `node-pty`'s `forkpty` cannot work.
- Debug-signed sideloading only: AppGallery release requires AGC approval for `ALLOW_WRITABLE_CODE_MEMORY` and applying for a "binary certificate". The debug Profile expires after one year; simply re-run `scripts/setup-signing.sh default --force`.

## Troubleshooting

- The startup page/failure page and the top toolbar of the READY screen can both view logs (token redacted); the failure page's "Enable debug logs and restart" turns on kimi debug logs and syscall/API tracing (remember to turn off after troubleshooting).
- System logs: `hdc shell "hilog -T KimiShell"` (node output is forwarded with `[node]` prefix, token masked).
- When the device denies V8 JIT, the shell automatically retries with `node --jitless` and shows a top prompt (networking will not work in this mode; check the ACL of the signing Profile).
- Signature mismatch during install: `hdc uninstall com.kimicodehmos.app` then `scripts/install.sh` (this clears the in-app login state).
