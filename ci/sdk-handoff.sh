#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Apple SDK bytes cross runners encrypted to a private key that stays on Linux.
# Temporary draft release assets avoid metered Actions artifacts/caches.
set -euo pipefail
[[ ${GITHUB_ACTIONS:-} == true && ${GITHUB_REPOSITORY:-} == Pustoy-inside/playport ]] || {
    echo 'This helper runs only inside the personal fork workflow.' >&2; exit 1;
}
cd "$GITHUB_WORKSPACE"
handoff="$PWD/.work/ci-sdk"
mkdir -p "$handoff"
case ${1:-} in
receive-init)
    [[ ${RUNNER_OS:-} == Linux ]] || exit 1
    sudo apt-get update -qq
    sudo apt-get install -y --no-install-recommends age jq
    age-keygen -o "$handoff/identity.age"
    chmod 600 "$handoff/identity.age"
    age-keygen -y "$handoff/identity.age" > "$handoff/recipient.txt"
    gh release create "$TRANSFER_TAG" --repo "$GITHUB_REPOSITORY" --target "$GITHUB_SHA" \
        --draft --title "Temporary encrypted SDK: $GITHUB_RUN_ID" \
        --notes 'Ephemeral build input. The decryption key exists only on the Linux runner.'
    gh release upload "$TRANSFER_TAG" "$handoff/recipient.txt" --repo "$GITHUB_REPOSITORY"
    ;;
send)
    [[ ${RUNNER_OS:-} == macOS ]] || exit 1
    brew install age
    for attempt in $(seq 1 80); do
        if gh release download "$TRANSFER_TAG" --repo "$GITHUB_REPOSITORY" \
            --pattern recipient.txt --dir "$handoff" --clobber 2>/dev/null; then break; fi
        sleep 15
    done
    test -s "$handoff/recipient.txt"
    curl --fail --location --retry 3 -o "$handoff/xtool.zip" \
        https://github.com/xtool-org/xtool/releases/download/1.20.1/xtool.app.zip
    echo "39123efc283528b119fa3567dc1123059d6690aab76c80e6003470d17c333ca2  $handoff/xtool.zip" | shasum -a 256 -c -
    ditto -xk "$handoff/xtool.zip" "$handoff"
    test -d /Applications/Xcode_26.6.app
    XTL_CLI=1 "$handoff/xtool.app/Contents/MacOS/xtool" sdk build \
        /Applications/Xcode_26.6.app "$handoff/output" --arch x86_64
    tar -C "$handoff/output" -czf - darwin.xtoolsdk | \
        age -r "$(cat "$handoff/recipient.txt")" -o "$handoff/sdk.tar.gz.age"
    # A release asset may be at most 2 GiB. The receiver concatenates parts by name.
    split -b 1500m -a 3 "$handoff/sdk.tar.gz.age" "$handoff/sdk.age.part-"
    gh release upload "$TRANSFER_TAG" "$handoff"/sdk.age.part-* --repo "$GITHUB_REPOSITORY"
    shasum -a 256 "$handoff/sdk.tar.gz.age" | awk '{print $1}' > "$handoff/sdk.ready"
    gh release upload "$TRANSFER_TAG" "$handoff/sdk.ready" --repo "$GITHUB_REPOSITORY"
    ;;
receive)
    [[ ${RUNNER_OS:-} == Linux ]] || exit 1
    for attempt in $(seq 1 240); do
        if gh release download "$TRANSFER_TAG" --repo "$GITHUB_REPOSITORY" \
            --pattern sdk.ready --dir "$handoff" --clobber 2>/dev/null; then break; fi
        sleep 15
    done
    test -s "$handoff/sdk.ready"
    gh release download "$TRANSFER_TAG" --repo "$GITHUB_REPOSITORY" \
        --pattern 'sdk.age.part-*' --dir "$handoff"
    cat "$handoff"/sdk.age.part-* > "$handoff/sdk.tar.gz.age"
    echo "$(cat "$handoff/sdk.ready")  $handoff/sdk.tar.gz.age" | sha256sum -c -
    mkdir -p "$handoff/extracted"
    age -d -i "$handoff/identity.age" "$handoff/sdk.tar.gz.age" | \
        tar --warning=no-unknown-keyword -xzf - -C "$handoff/extracted"
    # xtool copies its prebuilt SDK and adds this Linux host's clang resources.
    "$PLAYPORT_BUILD/inputs/xtool-src/.build/release/xtool" sdk install \
        "$handoff/extracted/darwin.xtoolsdk"
    sdk="$XDG_CONFIG_HOME/swiftpm/swift-sdks/darwin.artifactbundle"
    test -d "$sdk/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.5.sdk"
    test -d "$sdk/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk"
    echo "DARWIN_SDK=$sdk" >> "$GITHUB_ENV"
    rm -rf "$handoff/extracted" "$handoff"/sdk.age.part-* "$handoff/sdk.tar.gz.age" "$handoff/identity.age"
    ;;
*) echo 'Expected receive-init, send, or receive.' >&2; exit 2 ;;
esac
