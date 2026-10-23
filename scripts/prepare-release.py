#!/usr/bin/env python3
"""验证并整理 GitHub Release 附件，不连接 GitHub、不读取本机签名材料。"""
import argparse
import hashlib
import json
import pathlib
import runpy
import shutil
import sys
import tempfile
import zipfile
import struct

ROOT = pathlib.Path(__file__).resolve().parent.parent


def prepare(hap):
    verifier = runpy.run_path(str(ROOT / "scripts/verify-hap.py"))
    info = verifier["verify"](hap, release=True)
    expected = json.loads((ROOT / "AppScope/app.json5").read_text())["app"]
    if info["version"] != expected["versionName"] or info["versionCode"] != expected["versionCode"]:
        raise ValueError("HAP version does not match the source tree")
    versions = dict(line.split("=", 1) for line in (ROOT / "scripts/versions.env").read_text().splitlines()
                    if line and not line.startswith("#") and "=" in line)
    if any(versions.get(key) != value for key, value in info["runtime"].items()):
        raise ValueError("HAP runtime versions do not match scripts/versions.env")
    if not hap.name.endswith("-release-unsigned.hap"):
        raise ValueError("Only a release-unsigned.hap may enter the public release directory")
    destination = ROOT / "dist" / ("release-" + info["version"])
    if destination.exists():
        raise ValueError(f"Release directory already exists: {destination}; keep it or move it aside first")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="release-stage-", dir=destination.parent) as temporary:
        stage = pathlib.Path(temporary)
        shutil.copyfile(hap, stage / hap.name)
        for source, target in [
            ("docs/INSTALL.md", "INSTALL.md"), ("docs/RELEASE-VALIDATION.md", "VALIDATION.md"),
            ("THIRD-PARTY-NOTICES.md", "THIRD-PARTY-NOTICES.md"), ("LICENSE", "LICENSE"),
            ("CHANGELOG.md", "CHANGELOG.md")
        ]:
            shutil.copyfile(ROOT / source, stage / target)
        info["distribution"] = "unsigned; recipient must sign with their own device profile"
        (stage / "release-info.json").write_text(json.dumps(info, ensure_ascii=False, indent=2) + "\n")
        files = sorted(stage.iterdir())
        sums = [hashlib.sha256(file.read_bytes()).hexdigest() + "  " + file.name for file in files]
        (stage / "SHA256SUMS").write_text("\n".join(sums) + "\n")
        # 仅在全部校验和复制完成后公开目录，失败不会留下看似完整的发布物。
        stage.rename(destination)
    print(destination)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("hap", type=pathlib.Path)
    args = parser.parse_args()
    try:
        prepare(args.hap.resolve())
    except (ValueError, OSError, KeyError, zipfile.BadZipFile, struct.error) as error:
        print(f"Release preparation failed: {error}", file=sys.stderr)
        sys.exit(1)
