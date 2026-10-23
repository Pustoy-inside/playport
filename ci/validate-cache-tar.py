# SPDX-License-Identifier: GPL-3.0-or-later
"""Validate the private cache's allowlisted paths before extracting anything."""
import posixpath
import sys
import tarfile

workspace = sys.argv[1].rstrip("/")
allowed = (".work/run", ".work/cache", ".work/inputs/apple-linker/prefix",
           ".work/inputs/rust", "app/Staged", "build/generated")


def safe_name(name):
    return (name.rstrip("/") != "app/Staged/.stamps" and not name.startswith("app/Staged/.stamps/")
            and not name.startswith("/") and ".." not in name.split("/")
            and any(name.rstrip("/") == p or name.startswith(p + "/") for p in allowed))


with tarfile.open(fileobj=sys.stdin.buffer, mode="r|") as archive:
    for member in archive:
        if not safe_name(member.name):
            raise SystemExit(f"Unexpected cache path: {member.name!r}")
        if member.islnk() and not safe_name(member.linkname):
            raise SystemExit(f"Unexpected cache hardlink: {member.linkname!r}")
        if member.issym():
            target = posixpath.normpath(posixpath.join(workspace, posixpath.dirname(member.name), member.linkname))
            if not target.startswith(workspace + "/"):
                raise SystemExit(f"Cache symlink leaves the workspace: {member.name!r}")
