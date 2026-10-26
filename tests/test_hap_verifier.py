"""发布包校验的反例：危险路径、重复条目、签名材料和损坏内容必须被拒绝。"""
import pathlib
import runpy
import tempfile
import unittest
import warnings
import zipfile

VERIFY = runpy.run_path(str(pathlib.Path(__file__).resolve().parents[1] / "scripts/verify-hap.py"))["verify"]


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
