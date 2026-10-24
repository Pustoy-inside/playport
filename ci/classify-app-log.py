#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Emit fixed error categories only; never copy private log text to stdout."""
import pathlib
import re
import sys
import tarfile

CATEGORIES = {
    "package-manifest": r"invalid manifest|failed to load manifest|manifest parse|package\.swift.*error",
    "package-resolution": r"failed to resolve|failed to clone|couldn.t fetch|could not resolve|failed downloading|failed to check out|failed to fetch",
    "swift-sdk-selection": r"no.*swift sdk|swift sdk.*not found|no darwin sdk|could not locate.*sdk|sdk.*not installed|invalid darwin sdk",
    "swift-version": r"compiled with.*swift|requires.*swift.*version|tools version.*newer|unsupported.*swift version",
    "missing-shared-library": r"error while loading shared libraries|cannot open shared object file",
    "missing-build-tool": r"command not found|toolnotfound|could not find.*executable|unable to find.*tool|failed to find.*tool",
    "missing-package-file": r"could not find package.swift|no such file or directory|file doesn.t exist|file not found",
    "duplicate-resource": r"multiple resources|duplicate.*resource|multiple commands produce",
    "binary-target": r"binary target|xcframework.*(invalid|missing|not found)|does not contain.*binary artifact",
    "swift-import": r"no such module|could not build.*module|failed to build.*module|module map.*not found",
    "link-symbol": r"undefined symbol|duplicate symbol|symbol.s. not found|linker command failed",
    "disk-space": r"no space left on device|disk quota exceeded",
    "signing-required": r"requires logging in|no.*signing identity|provisioning profile",
    "terminal": r"terminal.*(not|error)|not a tty|inappropriate ioctl",
    "process-crash": r"segmentation fault|illegal instruction|signal [46]|fatal error|stack dump|program crashed",
    "network": r"connection (refused|reset|timed out)|could not resolve host|ssl.*error|tls.*error|certificate.*failed",
}


def classify(text):
    return [name for name, pattern in CATEGORIES.items() if re.search(pattern, text, re.I)]


def main():
    path = pathlib.Path(sys.argv[1])
    if path.name.endswith('.tar.gz'):
        # Read exactly one regular file into memory, without extracting any paths.
        with tarfile.open(path, 'r:gz') as archive:
            member = archive.getmember('.work/run/logs/app.log')
            if not member.isfile() or member.size > 32 * 1024 * 1024:
                raise ValueError('Unsupported diagnostic log')
            text = archive.extractfile(member).read().decode('utf-8', errors='replace')
    else:
        text = path.read_text(errors='replace')
    for category in classify(text) or ['unclassified']:
        print('App build error category: ' + category)


if __name__ == '__main__':
    main()
