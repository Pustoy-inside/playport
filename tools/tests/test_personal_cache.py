# SPDX-License-Identifier: GPL-3.0-or-later
"""Exercise cache safety with real archives, without network or GitHub access."""
import io
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]


@unittest.skipUnless(shutil.which("zstd") and shutil.which("tar"), "zstd and tar required")
class PersonalCacheTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "workspace"
        self.root.mkdir()
        (self.root / "ci").mkdir()
        shutil.copy(REPO / "ci/validate-cache-tar.py", self.root / "ci")
        self.env = dict(os.environ, GITHUB_ACTIONS="true", RUNNER_OS="Linux",
                        GITHUB_REPOSITORY="nVoxel/playport", GITHUB_WORKSPACE=str(self.root))

    def write(self, name, text):
        p = self.root / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)

    def run_cache(self, mode, archive, check=True):
        result = subprocess.run(["bash", str(REPO / "ci/build-cache.sh"), mode, str(archive)],
                                env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if check:
            self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def test_round_trip_preserves_outputs_but_excludes_sdk_keys_and_app_stamps(self):
        kept = {".work/run/stamps/pe": "valid engine stamp",
                ".work/run/pe/staged/example.dll": "compiled dll",
                ".work/cache/llvm-ios/lib.a": "llvm",
                ".work/inputs/apple-linker/prefix/bin/ld": "linker",
                ".work/inputs/rust/cargo/bin/rustc": "rust",
                "app/Staged/KosmicKrisp.xcframework/binary": "framework",
                "build/generated/wine-pe-arm64ec-windows.tsv": "manifest"}
        excluded = {".work/config/swiftpm/swift-sdks/SDK/secret": "SDK canary",
                    ".work/ci-sdk/identity.age": "private key canary",
                    "app/Staged/.stamps/stage": "stale resource stamp",
                    "app/Staged/.stamps/notices": "stale notice stamp"}
        for name, data in (kept | excluded).items():
            self.write(name, data)
        archive = self.root / "cache.tar.zst"
        self.run_cache("pack", archive)
        raw = subprocess.check_output(["zstd", "-dc", str(archive)])
        with tarfile.open(fileobj=io.BytesIO(raw)) as tar:
            names = {m.name.rstrip("/") for m in tar}
        self.assertTrue(set(kept).issubset(names))
        self.assertFalse(set(excluded) & names)
        for directory in (".work/run", ".work/cache", ".work/inputs", "app/Staged", "build/generated"):
            shutil.rmtree(self.root / directory)
        self.run_cache("unpack", archive)
        for name, data in kept.items():
            self.assertEqual((self.root / name).read_text(), data)
        self.assertFalse((self.root / "app/Staged/.stamps").exists())
        self.assertEqual((self.root / ".work/config/swiftpm/swift-sdks/SDK/secret").read_text(), "SDK canary")

    def test_invalid_path_is_rejected_before_any_output_is_installed(self):
        self.write(".work/run/stamps/pe", "existing stamp")
        raw = io.BytesIO()
        with tarfile.open(fileobj=raw, mode="w") as tar:
            for name in (".work/run/stamps/pe", "../escaped"):
                info = tarfile.TarInfo(name)
                info.size = 4
                tar.addfile(info, io.BytesIO(b"evil"))
        archive = self.root / "bad.tar.zst"
        compressed = subprocess.check_output(["zstd", "-c"], input=raw.getvalue())
        archive.write_bytes(compressed)
        result = self.run_cache("unpack", archive, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.root / ".work/run/stamps/pe").read_text(), "existing stamp")
        self.assertFalse((self.root.parent / "escaped").exists())
