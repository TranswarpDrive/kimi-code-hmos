# Kimi Code for HarmonyOS PC — unofficial wrapper

[中文](README.md) · [Installation](docs/INSTALL.md) · [Build and release](docs/RELEASING.md) · [Validation record](docs/RELEASE-VALIDATION.md)

A native ArkTS/ArkWeb wrapper for the official Kimi Code Web UI, bundled with Node, Python, Git and ripgrep.

**Version 0.2.0 is intended for public testing on HarmonyOS PC / 2in1, API 26.** Phones and tablets are unsupported. Release HAPs are unsigned: recipients must sign them with their own Huawei developer certificate and device profile. This is not an AppGallery release or a signature-free installer.

## Install and upgrade

Download the `*-release-unsigned.hap`, `SHA256SUMS` and installation instructions from this repository's GitHub Releases. Verify the checksum, then sign and install with a tool supporting HarmonyOS PC bundled executables. The profile must contain the requested JIT and persistent-file-access ACL permissions. See [INSTALL.md](docs/INSTALL.md).

Keep the same certificate for upgrades and install in place. If a signature mismatch occurs, recover the original certificate first. Uninstalling removes sandboxed login state, sessions and workspace files.

## Features and limitations

- Starts the bundled Kimi Web service and opens it in ArkWeb; login authorization and external links use the system browser.
- Session search, uploads, session ZIP export, blob previews and downloads.
- Python 3.14.6, Git 2.55.0 and ripgrep 13.0.0 for agent tools.
- Workspace picker, service restart, log viewer and debug switch.
- Search workers run in isolated Node processes; startup, restart and shutdown are serialized.
- Bounded, rotating logs with shared credential redaction.

The Web terminal is unavailable because the device sandbox denies PTY access; use the Shell tool. Session ZIP/blob downloads are limited to **32 MiB**. Background operation, file access and model connectivity depend on system permissions, signing profiles and the user's own account. Diagnostic logs may still contain personal paths or conversation content.

## Build and test

The full HAP build has been validated on macOS Apple Silicon with DevEco CLT 26, JDK 17, Node ≥22.19 and Python 3. See the [build guide](docs/RELEASING.md) for all prerequisites.

```bash
npm ci --ignore-scripts
npm run check
bash scripts/fetch-test-upstream.sh
KIMI_REQUIRE_UPSTREAM=1 npm test

KIMI_UNSIGNED_ONLY=1 scripts/build.sh release
python3 scripts/prepare-release.py dist/KimiCode-hmos-0.2.0-kimi2.2.0-release-unsigned.hap
```

For your own signed installation, run `scripts/setup-signing.sh` once, then `scripts/build.sh release` and `scripts/install.sh`. Existing signing material is reused; public release attachments exclude it.

Regression tests cover the real upstream search worker, repeated database opening/closing, concurrent workers, process termination, lifecycle races, file cleanup and limits, bridge origins and redaction across log chunks. GitHub CI runs on Node 22.19 / 24. HAP builds additionally validate ArkTS/C++ compilation, archive integrity, runtime hashes, ELF permissions and accidental private files. See the [validation record](docs/RELEASE-VALIDATION.md) for the actual tested scope.

## Implementation and licensing

ArkTS manages a local service through a native process host. Bundled executables inherit app permissions via their ELF permission sections. Kimi assets and Python standard libraries are installed from resfile resources. Compatibility code lives in `runtime/` and `entry/src/main/cpp/compat/`; versions and checksums are pinned in `scripts/versions.env`.

The project was initially developed with assistance from Claude (Anthropic), then continued by kimi-k3; the original credits are retained. The wrapper uses the [MIT license](LICENSE); bundled components keep their own [licenses](THIRD-PARTY-NOTICES.md). This project is not affiliated with or maintained by Moonshot AI or Huawei.

Report reproducible issues using the repository's Bug report template. Never upload certificates, profiles, tokens or personal session archives.
