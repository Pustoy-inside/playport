# SPDX-License-Identifier: GPL-3.0-or-later
"""The private-log classifier must emit constants, never log content."""
import io
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]


class PersonalDiagnostics(unittest.TestCase):
    def test_private_archive_outputs_only_category(self):
        scratch = REPO / '.work/diagnostics-tests'
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as directory:
            path = Path(directory) / 'private.tar.gz'
            data = b'PRIVATE-CANARY /private/user/path: error: no such module SecretModule\n'
            with tarfile.open(path, 'w:gz') as archive:
                member = tarfile.TarInfo('.work/run/logs/app.log')
                member.size = len(data)
                archive.addfile(member, io.BytesIO(data))
            result = subprocess.run([sys.executable, 'ci/classify-app-log.py', str(path)],
                                    cwd=REPO, text=True, capture_output=True, check=True)
            self.assertEqual(result.stdout, 'App build error category: swift-import\n')
            self.assertEqual(result.stderr, '')

    def test_unknown_private_text_is_not_printed(self):
        scratch = REPO / '.work/diagnostics-tests'
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as directory:
            path = Path(directory) / 'app.log'
            path.write_text('PRIVATE-CANARY unknown diagnostic')
            result = subprocess.run([sys.executable, 'ci/classify-app-log.py', str(path)],
                                    cwd=REPO, text=True, capture_output=True, check=True)
            self.assertEqual(result.stdout, 'App build error category: unclassified\n')
            self.assertEqual(result.stderr, '')
