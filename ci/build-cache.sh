#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Private release assets, never Actions artifact/cache storage. No SDK or keys.
set -euo pipefail
[[ $GITHUB_ACTIONS == true && $RUNNER_OS == Linux && $GITHUB_REPOSITORY == nVoxel/playport ]] || exit 1
cd "$GITHUB_WORKSPACE"
script="$GITHUB_WORKSPACE/ci/validate-cache-tar.py"

pack() {
    local archive=$1 p
    shift
    set --
    for p in .work/run .work/cache .work/inputs/apple-linker/prefix .work/inputs/rust app/Staged build/generated; do
        [ ! -d "$p" ] || set -- "$@" "$p"
    done
    [ "$#" -gt 0 ] || return 1
    # App resources are recreated from the cached roots. Do not restore stamps
    # that could skip staging into the fresh checkout's app/Sources/Runtime.
    COPYFILE_DISABLE=1 tar --exclude=app/Staged/.stamps -cf - "$@" | zstd -T2 -3 -o "$archive"
}
unpack() {
    local extract p
    zstd -dc "$1" | python3 "$script" "$GITHUB_WORKSPACE"
    mkdir -p .work/ci-build-cache
    extract=$(mktemp -d "$GITHUB_WORKSPACE/.work/ci-build-cache/extract.XXXXXX")
    zstd -dc "$1" | tar --no-same-owner -xf - -C "$extract"
    # Install no stamp or output until the entire archive extracted successfully.
    for p in .work/run .work/cache .work/inputs/apple-linker/prefix .work/inputs/rust app/Staged build/generated; do
        if [ -d "$extract/$p" ]; then
            mkdir -p "$(dirname "$p")"
            rm -rf "$p"
            mv "$extract/$p" "$p"
        fi
    done
    rm -rf "$extract"
}
signature() {
    git show HEAD:pins.lock
    clang --version | head -1
    "$LLVM_MINGW/bin/clang" --version | head -1
    swift --version | head -1
    pkg-config --modversion SPIRV-Tools
    local platform settings
    for platform in iPhoneOS MacOSX; do
        settings="$DARWIN_SDK/Developer/Platforms/$platform.platform/Developer/SDKs/$platform""26.5.sdk/SDKSettings.json"
        if [ -f "$settings" ]; then sha256sum "$settings"; else echo "$settings"; fi
    done
}
available() {
    gh api "repos/$GITHUB_REPOSITORY/releases?per_page=100" |
        jq -r --arg p "$prefix-" 'sort_by(.created_at) | reverse | .[] |
            select(.draft and (.tag_name | startswith($p))) |
            select(any(.assets[]; .name == "cache.ready")) | .tag_name'
}

case "$1" in
pack) pack "$2"; exit ;;
unpack) unpack "$2"; exit ;;
restore|save) mode=$1 ;;
*) exit 2 ;;
esac
# A failed setup has no cache to save.
[ -n "$(printenv DARWIN_SDK)" ] && [ -d "$DARWIN_SDK" ] || exit 0
key=$(signature | sha256sum | cut -c1-20)
prefix="ci-build-cache-v1-$key"
scratch="$GITHUB_WORKSPACE/.work/ci-build-cache"
mkdir -p "$scratch"
cleanup() {
    local status=$?
    trap - EXIT
    if [ "$status" != 0 ] && [ "$mode" = restore ]; then
        # An interrupted restore must never leave stamps that skip missing data.
        rm -rf .work/run/stamps app/Staged/.stamps
    fi
    rm -rf "$scratch"
    exit "$status"
}
trap cleanup EXIT
if [ "$mode" = restore ]; then
    tag=$(available | head -1)
    [ -n "$tag" ] || { echo 'No compatible private build cache yet.'; exit 0; }
    gh release download "$tag" --repo "$GITHUB_REPOSITORY" \
        --pattern 'cache.part.*' --pattern cache.ready --dir "$scratch" --clobber
    cat "$scratch"/cache.part.* > "$scratch/cache.tar.zst"
    echo "$(cat "$scratch/cache.ready")  $scratch/cache.tar.zst" | sha256sum -c -
    unpack "$scratch/cache.tar.zst"
    rm -f "$scratch"/cache.part.* "$scratch/cache.tar.zst" "$scratch/cache.ready"
    echo "Restored incremental build state from $tag."
else
    [ -d .work/run ] || exit 0
    pack "$scratch/cache.tar.zst"
    sha256sum "$scratch/cache.tar.zst" | cut -d' ' -f1 > "$scratch/cache.ready"
    split -b 1500m -a 3 "$scratch/cache.tar.zst" "$scratch/cache.part."
    tag="$prefix-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"
    gh release create "$tag" --repo "$GITHUB_REPOSITORY" --target "$GITHUB_SHA" --draft \
        --title "Private incremental build cache $GITHUB_RUN_ID" \
        --notes 'Hosted-runner build state only. Excludes the Apple SDK, handoff keys and signing credentials. Not an installable IPA.'
    gh release upload "$tag" "$scratch"/cache.part.* --repo "$GITHUB_REPOSITORY"
    gh release upload "$tag" "$scratch/cache.ready" --repo "$GITHUB_REPOSITORY"
    # Only superseded caches created by this script, after the new one is ready.
    while IFS= read -r old; do
        [ "$old" = "$tag" ] || gh release delete "$old" --repo "$GITHUB_REPOSITORY" --cleanup-tag --yes
    done < <(available)
    rm -f "$scratch"/cache.part.* "$scratch/cache.tar.zst" "$scratch/cache.ready"
    echo "Saved private incremental build state to $tag."
fi
