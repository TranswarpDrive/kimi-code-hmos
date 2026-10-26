#!/usr/bin/env python3
"""离线检查发布包；仅使用标准库，不运行包内代码、不读取签名材料。"""
import argparse
import collections
import hashlib
import io
import json
import pathlib
import struct
import sys
import tarfile
import zipfile

RESOURCE = "resources/resfile/kimicode/"
COMMANDS = ["node", "python3", "rg", "git", "git-upload-pack", "git-receive-pack",
            "git-upload-archive", "git-shell", "git-remote-https"]
REQUIRED = [
    "module.json", "libs/arm64-v8a/node.bin", "libs/arm64-v8a/python3.bin",
    "libs/arm64-v8a/rg.bin", "libs/arm64-v8a/git.bin", "libs/arm64-v8a/git-remote-https.bin",
    "libs/arm64-v8a/libkimihost.so", "libs/arm64-v8a/libkimicompat.so",
    "libs/arm64-v8a/libc++_shared.so",
] + [RESOURCE + name for name in [
    "runtime-manifest.json", "package/dist/main.mjs", "package/dist/search-worker.mjs",
    "runtime/ohos-preload.cjs", "runtime/process-worker.cjs", "runtime/worker-child.cjs", "runtime/runtime-updater.cjs",
    "npm.tar.gz", "npm-extract/node_modules/tar/package.json",
    "npm-extract/node_modules/tar/dist/commonjs/index.min.js",
    "python/lib/python3.14/os.py", "python/lib/python3.14/ssl.py",
    "licenses/node.LICENSE", "licenses/git.licenses.txt", "licenses/python.licenses.txt",
    "licenses/ripgrep/LICENSE-MIT", "package/LICENSE",
]] + [RESOURCE + "bin/" + name for name in COMMANDS]


def require(condition, message):
    if not condition:
        raise ValueError(message)


def verify_npm_archive(data):
    try:
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
            members = archive.getmembers()
    except (tarfile.TarError, EOFError) as error:
        raise ValueError("Invalid npm archive") from error
    require(0 < len(members) <= 10000, "Unexpected npm archive entry count")
    names = []
    total_size = 0
    for member in members:
        name = member.name.rstrip("/")
        parts = pathlib.PurePosixPath(name).parts
        require((name == "npm" or name.startswith("npm/")) and not name.startswith("/") and
                ".." not in parts and "\\" not in name and
                not any(part.startswith("._") for part in parts), f"Unsafe npm archive path: {member.name}")
        require(member.isdir() or member.isreg(), f"Unsupported npm archive entry: {member.name}")
        names.append(name)
        total_size += member.size
    require(all(count == 1 for count in collections.Counter(names).values()), "Duplicate npm archive entries")
    require(total_size <= 128 * 1024 * 1024, "npm archive expands beyond the size limit")
    required = {"npm/bin/npm-cli.js", "npm/lib/cli.js", "npm/LICENSE", "npm/package.json",
                "npm/node_modules/semver/package.json"}
    require(required <= set(names), "Missing npm archive files: " + ", ".join(sorted(required - set(names))))


def elf_sections(data):
    require(data[:6] == b"\x7fELF\x02\x01", "Expected a little-endian ELF64 executable")
    require(struct.unpack_from("<H", data, 18)[0] == 183, "Expected ARM64 ELF")
    offset = struct.unpack_from("<Q", data, 40)[0]
    entry_size, count, names_index = struct.unpack_from("<HHH", data, 58)
    require(entry_size >= 64 and 0 < names_index < count, "Invalid ELF section table")
    require(offset + entry_size * count <= len(data), "Truncated ELF section table")
    headers = [struct.unpack_from("<IIQQQQIIQQ", data, offset + i * entry_size) for i in range(count)]
    name_header = headers[names_index]
    names = data[name_header[4]:name_header[4] + name_header[5]]
    sections = {}
    for header in headers:
        start = header[0]
        end = names.find(b"\0", start)
        require(0 <= start < len(names) and end >= 0, "Invalid ELF section name")
        name = names[start:end].decode("ascii")
        if header[1] != 8:  # SHT_NOBITS has no file payload.
            require(header[4] + header[5] <= len(data), "Truncated ELF section")
            sections[name] = data[header[4]:header[4] + header[5]]
    return sections


def verify(hap, release=False, product="default"):
    with zipfile.ZipFile(hap) as archive:
        names = archive.namelist()
        counts = collections.Counter(names)
        require(all(count == 1 for count in counts.values()), "Duplicate ZIP entries")
        for name in names:
            parts = pathlib.PurePosixPath(name).parts
            require(not name.startswith("/") and ".." not in parts and "\\" not in name, f"Unsafe archive path: {name}")
            require(not any(part in {".kimi-code", ".ohos", "signing", ".git", ".DS_Store"} for part in parts), f"Private/generated content: {name}")
            require(not name.endswith((".p12", ".p7b", ".jks", ".keystore", ".key", ".local.json", "server.token", "debug.flag")), f"Sensitive file: {name}")
            if name.endswith(".pem"):
                # Python/certifi 的公开 CA 证书是 HTTPS 所必需的；应拦截私钥而非所有 PEM。
                require(b"PRIVATE KEY-----" not in archive.read(name), f"Sensitive file: {name}")
        require(archive.testzip() is None, "ZIP CRC check failed")
        # 旧版 C++ IsNativeFile 会静默跳过路径中不含点号的文件。
        # 要求文件名本身有后缀，不能靠父目录带点号偶然通过。
        for name in names:
            if name.startswith("libs/") and not name.endswith("/"):
                require(bool(pathlib.PurePosixPath(name).suffix), f"Native file may be skipped by older code signers: {name}")
        require(all(name in counts for name in REQUIRED), "Missing required files: " + ", ".join(name for name in REQUIRED if name not in counts))
        module = json.loads(archive.read("module.json"))
        app = module["app"]
        config = module["module"]
        require(app["bundleName"] == "com.kimicodehmos.app", "Unexpected bundle name")
        expected_api = 24 if product == "emulator" else 26
        require(int(app["minAPIVersion"]) % 1000 == expected_api, f"Expected API {expected_api} product")
        require(config["deviceTypes"] == ["2in1"], "Unexpected device types")
        require(config.get("compressNativeLibs") is True, "Native libraries must be extracted at install time")
        if release:
            require(not app.get("debug", False), "A debug build cannot be published as a release")
        permissions = {item["name"] for item in config["requestPermissions"]}
        require("ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY" in permissions, "Missing JIT permission")
        binaries = [item["path"] for item in config["executableBinaryPaths"]]
        require(len(set(binaries)) == len(binaries), "Duplicate executable declarations")
        expected_binaries = {"libs/arm64-v8a/" + name + ".bin" for name in COMMANDS}
        require(set(binaries) == expected_binaries, "Missing or unexpected executable declarations")
        for name in COMMANDS:
            launcher = RESOURCE + "bin/" + name
            require(archive.getinfo(launcher).external_attr >> 16 & 0o111, f"Command launcher is not executable: {name}")
            require(archive.read(launcher).startswith(b"#!/system/bin/sh\n"), f"Invalid command launcher: {name}")
        for name in binaries:
            require(name in counts, f"Missing executable: {name}")
            sections = elf_sections(archive.read(name))
            require(".permission" in sections, f"Missing ELF permission section: {name}")
            declared = json.loads(sections[".permission"].rstrip(b"\0"))["requestPermissions"]
            requested = {item["name"] for item in declared}
            require("ohos.permission.INHERIT_PARENT_PERMISSION" in requested, f"Missing permission inheritance: {name}")
            require(requested <= permissions, f"Executable requests undeclared permissions: {name}")
        manifest = json.loads(archive.read(RESOURCE + "runtime-manifest.json"))
        require(manifest["schema"] == 1, "Unknown runtime manifest schema")
        listed = set()
        for item in manifest["files"]:
            name = item["path"]
            require(name not in listed and name in counts, f"Missing/duplicate manifest entry: {name}")
            listed.add(name)
            require(hashlib.sha256(archive.read(name)).hexdigest() == item["sha256"], f"Runtime checksum mismatch: {name}")
        require(set(binaries) <= listed, "Some executables are missing from the runtime manifest")
        require({RESOURCE + "bin/" + name for name in COMMANDS} <= listed, "Command launchers missing from runtime manifest")
        require(any("/_ssl." in name for name in listed), "Python SSL extension missing")
        require(any("/_sqlite3." in name for name in listed), "Python SQLite extension missing")
        require(any("/libssl.so" in name for name in listed), "Python SSL native library missing")
        package = json.loads(archive.read(RESOURCE + "package/package.json"))
        require(package["version"] == manifest["versions"]["KIMI_CODE_VERSION"], "Kimi version mismatch")
        verify_npm_archive(archive.read(RESOURCE + "npm.tar.gz"))
        return {"file": pathlib.Path(hap).name, "version": app["versionName"], "versionCode": app["versionCode"],
                "product": product, "debug": app.get("debug", False), "sizeBytes": pathlib.Path(hap).stat().st_size,
                "sha256": hashlib.sha256(pathlib.Path(hap).read_bytes()).hexdigest(),
                "runtime": manifest["versions"], "verifiedRuntimeFiles": len(listed), "executableCount": len(binaries)}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("hap")
    parser.add_argument("--release", action="store_true")
    parser.add_argument("--product", choices=["default", "emulator"], default="default")
    args = parser.parse_args()
    try:
        print(json.dumps(verify(args.hap, args.release, args.product), ensure_ascii=False, indent=2))
    except (ValueError, KeyError, OSError, zipfile.BadZipFile, struct.error) as error:
        print(f"HAP verification failed: {error}", file=sys.stderr)
        sys.exit(1)
