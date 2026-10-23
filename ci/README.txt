Personal Playport build for nVoxel/playport

The upstream project runs source-only CI. This fork adds an explicitly reviewed,
owner-requested build workflow, restricted to this public fork and standard
ubuntu-24.04/macos-26 runners. It never signs into an Apple account.

Run Personal unsigned IPA from Actions, or change ci/build-request.json on main.
Forked Actions may first require the owner to enable workflows on the Actions page.

The macOS runner uses its preinstalled Xcode 26.6 to make xtool's x86-64 Linux SDK.
The Linux runner generates an age key. Only its public recipient is transferred;
the encrypted SDK is placed in a temporary draft release and removed after the run.
The private key exists only on the Linux runner. No plaintext Apple SDK is uploaded.

Linux builds the pinned compiler/runtime dependencies and runs:
  ./pp build --variant release --unsigned
Generated manifests are committed to this fork when needed; the final packaging
pass is repeated so the exact source revision matches the delivered build.
The same source and notice exporters used by the project produce matching files.

The resulting IPA, source, notices, checksums and AltStore installation instructions
are saved as a draft release, visible to this repository's owner/collaborators.
Nothing is automatically published. GitHub Actions artifacts and caches are unused.
Standard runner compute for a public repository is free; larger runners are never
selected. A cold build may encounter GitHub's disk or six-hour job limit; a failure
is not a successful build and no playable-game claim is made.

Signing and device testing happen after downloading the IPA. Use the existing
AltStore account and upgrade in place to preserve the installed game and saves.
