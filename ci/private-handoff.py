#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Prepare local downloads in an owner-only draft body; never print its data."""
import io
import json
import os
import tarfile
import urllib.error
import urllib.parse
import urllib.request

REPO = 'Pustoy-inside/playport'
PREFIX = 'LOCAL_HANDOFF_JSON\n'


def api(path, method='GET', data=None):
    request = urllib.request.Request(
        'https://api.github.com/repos/' + REPO + path,
        data=None if data is None else json.dumps(data).encode(),
        headers={'Authorization': 'Bearer ' + os.environ['GH_TOKEN'],
                 'Accept': 'application/vnd.github+json',
                 'Content-Type': 'application/json'}, method=method)
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, newurl):
        return None


def asset_url(asset):
    # The capability URL is stored only in the private draft, never public logs.
    request = urllib.request.Request(asset['url'], headers={
        'Authorization': 'Bearer ' + os.environ['GH_TOKEN'],
        'Accept': 'application/octet-stream'})
    opener = urllib.request.build_opener(NoRedirect)
    try:
        opener.open(request, timeout=60)
    except urllib.error.HTTPError as error:
        if error.code != 302:
            raise
        url = error.headers['Location']
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme != 'https' or not parsed.hostname.endswith('.githubusercontent.com'):
            raise ValueError('Unexpected asset download host')
        return url
    raise ValueError('Expected a scoped download redirect')


def prepare():
    releases = api('/releases?per_page=100')
    failure = next(r for r in releases if r['draft'] and
                   r['tag_name'] == 'personal-failure-40055549346-1')
    cache = next(r for r in sorted(releases, key=lambda r: r['created_at'], reverse=True)
                 if r['draft'] and r['tag_name'].startswith('ci-build-cache-v1-') and
                 any(a['name'] == 'cache.ready' for a in r['assets']))
    assets = [{'name': a['name'], 'size': a['size'], 'url': asset_url(a)}
              for a in cache['assets'] if a['name'].startswith('cache.part.') or a['name'] == 'cache.ready']
    archive_asset = next(a for a in failure['assets'] if a['name'] == 'ci-failure-logs.tar.gz')
    with urllib.request.urlopen(asset_url(archive_asset), timeout=60) as response:
        archive_bytes = response.read(2 * 1024 * 1024)
    with tarfile.open(fileobj=io.BytesIO(archive_bytes), mode='r:gz') as archive:
        member = archive.getmember('.work/run/logs/app.log')
        if not member.isfile() or member.size > 1024 * 1024:
            raise ValueError('Unsupported private diagnostic')
        app_log = archive.extractfile(member).read().decode('utf-8', errors='replace')[-32000:]
    metadata = {'version': 1, 'cache_tag': cache['tag_name'], 'assets': assets, 'app_log': app_log}
    # Updating this already-private draft does not publish the release or its log.
    api('/releases/' + str(failure['id']), method='PATCH', data={
        'draft': True, 'body': PREFIX + json.dumps(metadata)})
    print('Private local handoff prepared; no download URL or log content was printed.')


if __name__ == '__main__':
    if os.environ.get('GITHUB_ACTIONS') != 'true' or os.environ.get('GITHUB_REPOSITORY') != REPO:
        raise SystemExit('Restricted to the personal fork runner')
    try:
        prepare()
    except Exception:
        # Exception messages can contain capability URLs; keep them out of CI.
        raise SystemExit('Private handoff failed without exposing diagnostic content')
