# SPDX-License-Identifier: GPL-3.0-or-later
"""Private handoff data must remain in the existing private draft body."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('private_handoff', REPO / 'ci/private-handoff.py')
handoff = importlib.util.module_from_spec(spec)
spec.loader.exec_module(handoff)


class PersonalHandoff(unittest.TestCase):
    def test_log_and_download_links_are_written_only_to_private_draft(self):
        private_log = b'PRIVATE-LOG-CANARY'
        raw = io.BytesIO()
        with tarfile.open(fileobj=raw, mode='w:gz') as archive:
            member = tarfile.TarInfo('.work/run/logs/app.log')
            member.size = len(private_log)
            archive.addfile(member, io.BytesIO(private_log))
        releases = [
            {'id': 7, 'draft': True, 'tag_name': 'personal-failure-40055549346-1',
             'created_at': '2026-10-24', 'assets': [{'name': 'ci-failure-logs.tar.gz'}]},
            {'id': 8, 'draft': True, 'tag_name': 'ci-build-cache-v1-test',
             'created_at': '2026-10-24', 'assets': [{'name': 'cache.ready', 'size': 65}]},
        ]
        output = io.StringIO()
        with patch.object(handoff, 'api', side_effect=[releases, {}]) as api, \
             patch.object(handoff, 'asset_url', return_value='https://private/CAPABILITY-CANARY'), \
             patch.object(handoff.urllib.request, 'urlopen', return_value=io.BytesIO(raw.getvalue())), \
             contextlib.redirect_stdout(output):
            handoff.prepare()
        self.assertNotIn('CANARY', output.getvalue())
        call = api.call_args
        self.assertEqual(call.args, ('/releases/7',))
        self.assertEqual(call.kwargs['method'], 'PATCH')
        self.assertIs(call.kwargs['data']['draft'], True)
        metadata = json.loads(call.kwargs['data']['body'].removeprefix(handoff.PREFIX))
        self.assertEqual(metadata['app_log'], private_log.decode())
        self.assertEqual(metadata['assets'][0]['url'], 'https://private/CAPABILITY-CANARY')
