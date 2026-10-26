"""发布包校验的反例：危险路径、重复条目、签名材料和损坏内容必须被拒绝。"""
import io
import pathlib
import runpy
import tarfile
import tempfile
import unittest
import warnings
import zipfile

VERIFIER = runpy.run_path(str(pathlib.Path(__file__).resolve().parents[1] / "scripts/verify-hap.py"))
VERIFY = VERIFIER["verify"]
VERIFY_NPM_ARCHIVE = VERIFIER["verify_npm_archive"]


class ArchiveRejectionTests(unittest.TestCase):
    def reject(self, entries, expected, content="test content"):
        with tempfile.TemporaryDirectory() as directory:
            archive = pathlib.Path(directory) / "test.hap"
            with warnings.catch_warnings():
                warnings.simplefilter("ignore", UserWarning)
                with zipfile.ZipFile(archive, "w") as output:
                    for name in entries:
                        output.writestr(name, content)
            with self.assertRaisesRegex(ValueError, expected):
                VERIFY(archive)

    def test_paths_cannot_escape_archive_root(self):
        for path in ["../private", "/absolute", "libs/../../escape", "libs\\escape"]:
            with self.subTest(path=path):
                self.reject([path], "Unsafe archive path")

    def test_duplicate_entries_are_rejected(self):
        self.reject(["module.json", "module.json"], "Duplicate ZIP entries")

    def test_private_files_are_rejected(self):
        for path in ["signing/default.local.json", "profile.p7b", "certificate.p12", "private.key", "home/.kimi-code/server.token"]:
            with self.subTest(path=path):
                self.reject([path], "Private/generated content|Sensitive file")
        self.reject(["private.pem"], "Sensitive file", "-----BEGIN " + "PRIVATE KEY-----\ntest-only")
        # 公开 CA 证书不能误判为签名私钥，检查应继续到必需文件校验。
        self.reject(["cacert.pem"], "Missing required files", "-----BEGIN CERTIFICATE-----\ntest-only")

    def test_missing_runtime_is_rejected(self):
        self.reject(["module.json"], "Missing required files")

    def test_extensionless_native_files_cannot_reintroduce_signer_incompatibility(self):
        for name in ["node", "python3", "rg", "git", "git-remote-https"]:
            self.reject(["libs/arm64-v8a/" + name], "may be skipped by older code signers")
        self.reject(["libs/arm64-v8a/old.version/node"], "may be skipped by older code signers")
        for name in ["node.bin", "python3.bin", "libssl.so.3"]:
            self.reject(["libs/arm64-v8a/" + name], "Missing required files")

    def make_npm_archive(self, entries):
        output = io.BytesIO()
        with tarfile.open(fileobj=output, mode="w:gz") as archive:
            for name, data, kind in entries:
                info = tarfile.TarInfo(name)
                info.type = kind
                info.size = len(data) if kind == tarfile.REGTYPE else 0
                if kind == tarfile.SYMTYPE:
                    info.linkname = "target"
                archive.addfile(info, io.BytesIO(data) if info.size else None)
        return output.getvalue()

    def test_npm_archive_paths_types_duplicates_and_required_files(self):
        required = ["npm/bin/npm-cli.js", "npm/lib/cli.js", "npm/LICENSE", "npm/package.json",
                    "npm/node_modules/semver/package.json"]
        entries = [("npm", b"", tarfile.DIRTYPE)] + [(name, b"test", tarfile.REGTYPE) for name in required]
        VERIFY_NPM_ARCHIVE(self.make_npm_archive(entries))
        for name in ["npm/../escape", "/absolute", "._npm", "npm/._cli.js"]:
            with self.subTest(path=name):
                unsafe = entries + [(name, b"bad", tarfile.REGTYPE)]
                with self.assertRaisesRegex(ValueError, "Unsafe npm archive path"):
                    VERIFY_NPM_ARCHIVE(self.make_npm_archive(unsafe))
        with self.assertRaisesRegex(ValueError, "Duplicate npm archive entries"):
            VERIFY_NPM_ARCHIVE(self.make_npm_archive(entries + [entries[-1]]))
        with self.assertRaisesRegex(ValueError, "Unsupported npm archive entry"):
            VERIFY_NPM_ARCHIVE(self.make_npm_archive(entries + [("npm/link", b"", tarfile.SYMTYPE)]))
        with self.assertRaisesRegex(ValueError, "Missing npm archive files"):
            VERIFY_NPM_ARCHIVE(self.make_npm_archive(entries[:-1]))

    def test_corrupt_zip_data_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = pathlib.Path(directory) / "corrupt.hap"
            with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_STORED) as output:
                output.writestr("module.json", "unique-test-payload")
            archive.write_bytes(archive.read_bytes().replace(b"unique-test-payload", b"broken-test-payload", 1))
            with self.assertRaisesRegex(ValueError, "ZIP CRC check failed"):
                VERIFY(archive)


if __name__ == "__main__":
    unittest.main()
