#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
[[ ${GITHUB_ACTIONS:-} == true && ${RUNNER_OS:-} == Linux && ${GITHUB_REPOSITORY:-} == Pustoy-inside/playport ]] || {
    echo 'This setup is restricted to a disposable GitHub-hosted personal build runner.' >&2; exit 1;
}
cd "$GITHUB_WORKSPACE"
export PLAYPORT_BUILD="$PWD/.work"
mkdir -p "$PLAYPORT_BUILD/inputs"
# Delete only unused software on this disposable hosted runner, before downloads.
sudo rm -rf /usr/local/lib/android /usr/share/dotnet /opt/ghc /usr/local/share/boost
df -h .
free_kb=$(df -Pk . | awk 'NR==2 {print $4}')
(( free_kb >= 55 * 1024 * 1024 )) || {
    echo 'A full cold build needs at least 55 GiB free. No paid runner will be selected.' >&2; exit 1;
}
sudo apt-get update -qq
sudo apt-get install -y --no-install-recommends \
    build-essential autoconf automake libtool-bin bison flex gettext cmake ninja-build \
    python3 python3-venv python3-pip python3-dev pkg-config curl ca-certificates gnupg \
    xz-utils unzip zip p7zip-full rsync xxd patch git zstd age jq \
    libssl-dev libcurl4-openssl-dev libxml2-dev liblzma-dev zlib1g-dev \
    libffi-dev libncurses-dev libedit-dev libsqlite3-dev libzstd-dev libdrm-dev libexpat1-dev \
    glslang-tools
curl --fail --location --retry 3 -o "$PLAYPORT_BUILD/inputs/llvm.sh" https://apt.llvm.org/llvm.sh
sudo bash "$PLAYPORT_BUILD/inputs/llvm.sh" 22
sudo apt-get install -y --no-install-recommends llvm-22-dev clang-tools-22 libclang-22-dev \
    libclc-22 libclc-22-dev
host_bin="$PLAYPORT_BUILD/inputs/host-bin"
mkdir -p "$host_bin"
for name in clang clang++ ld64.lld llvm-ar llvm-nm llvm-objdump llvm-objcopy llvm-lipo llvm-config llvm-strip llvm-readobj llvm-ranlib llvm-libtool-darwin llvm-install-name-tool; do
    source_bin="/usr/lib/llvm-22/bin/$name"
    test -x "$source_bin"
    sudo ln -sf "$source_bin" "/usr/bin/$name"
    ln -sf "$source_bin" "$host_bin/$name"
done
python3 -m venv "$PLAYPORT_BUILD/inputs/python"
"$PLAYPORT_BUILD/inputs/python/bin/pip" install meson==1.10.0 pefile PyYAML mako packaging
export PATH="$PLAYPORT_BUILD/inputs/python/bin:$PATH"
echo "$PLAYPORT_BUILD/inputs/python/bin" >> "$GITHUB_PATH"

# apt.llvm.org does not package the matching SPIR-V translator. Build its
# LLVM 22 release rather than mixing Ubuntu's LLVM 18 translator with LLVM 22.
translator="$PLAYPORT_BUILD/inputs/spirv-translator"
git init -q "$translator"
git -C "$translator" fetch --depth 1 https://github.com/KhronosGroup/SPIRV-LLVM-Translator.git \
    567786558a00e8b7ec0457f1706504784e229150
git -C "$translator" checkout -q FETCH_HEAD
translator_prefix="$PLAYPORT_BUILD/inputs/spirv-tools"
cmake -S "$translator" -B "$translator/build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=/usr/bin/clang -DCMAKE_CXX_COMPILER=/usr/bin/clang++ \
    -DCMAKE_INSTALL_PREFIX="$translator_prefix" -DCMAKE_INSTALL_RPATH="$translator_prefix/lib;/usr/lib/llvm-22/lib" \
    -DLLVM_DIR=/usr/lib/llvm-22/lib/cmake/llvm -DLLVM_SPIRV_INCLUDE_TESTS=OFF \
    -DLLVM_SPIRV_ENABLE_LIBSPIRV_DIS=OFF -DBUILD_SHARED_LIBS=ON -DLLVM_LINK_LLVM_DYLIB=ON
cmake --build "$translator/build" --parallel "$JOBS"
cmake --install "$translator/build"
ln -s "$translator_prefix/bin/llvm-spirv" "$host_bin/llvm-spirv"

# Mesa requires SPIRV-Tools >= 2024.1; Noble's 2023 package is too old.
# v2026.4 and the exact SPIRV-Headers revision its DEPS file records.
spirv="$PLAYPORT_BUILD/inputs/spirv-native"
headers="$PLAYPORT_BUILD/inputs/spirv-headers"
git init -q "$spirv"
git -C "$spirv" fetch --depth 1 https://github.com/KhronosGroup/SPIRV-Tools.git \
    ef96ed763b43b59b33b31b362f09a02b729fa1c9
git -C "$spirv" checkout -q FETCH_HEAD
git init -q "$headers"
git -C "$headers" fetch --depth 1 https://github.com/KhronosGroup/SPIRV-Headers.git \
    496543121ce6419f23d6fa5d7194ba66c36212d2
git -C "$headers" checkout -q FETCH_HEAD
cmake -S "$spirv" -B "$spirv/build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=/usr/bin/clang -DCMAKE_CXX_COMPILER=/usr/bin/clang++ \
    -DCMAKE_INSTALL_PREFIX="$translator_prefix" -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DSPIRV-Headers_SOURCE_DIR="$headers" -DSPIRV_SKIP_TESTS=ON -DSPIRV_WERROR=OFF \
    -DSPIRV_TOOLS_USE_MIMALLOC=OFF -DBUILD_SHARED_LIBS=OFF
cmake --build "$spirv/build" --parallel "$JOBS"
cmake --install "$spirv/build"
for name in spirv-as spirv-dis spirv-opt spirv-val; do
    ln -s "$translator_prefix/bin/$name" "$host_bin/$name"
done

# xtool's Linux system-library targets need newer mobile-device libraries
# than Ubuntu 24.04 supplies. These are the release versions in xtool's
# own Docker recipe, with libimobiledevice pinned to its 1.4.0 release.
mobile_prefix="$PLAYPORT_BUILD/inputs/mobiledevice"
export PKG_CONFIG_PATH="$mobile_prefix/lib/pkgconfig:$translator_prefix/lib/pkgconfig"
export LD_LIBRARY_PATH="$mobile_prefix/lib:$translator_prefix/lib:/usr/lib/llvm-22/lib"
for spec in libplist:2.6.0 libimobiledevice-glue:1.3.1 libusbmuxd:2.1.0 libtatsu:1.0.4 libimobiledevice:1.4.0; do
    name=${spec%%:*}; version=${spec#*:}
    tree="$PLAYPORT_BUILD/inputs/$name"
    git clone --depth 1 --branch "$version" "https://github.com/libimobiledevice/$name.git" "$tree"
    (
        cd "$tree"
        ./autogen.sh --prefix="$mobile_prefix" --without-cython
        make -j"$JOBS"
        make install
    )
done
echo "PKG_CONFIG_PATH=$PKG_CONFIG_PATH" >> "$GITHUB_ENV"
echo "LD_LIBRARY_PATH=$LD_LIBRARY_PATH" >> "$GITHUB_ENV"

swift_root="$PLAYPORT_BUILD/inputs/swift"
mkdir -p "$swift_root"
curl --fail --location --retry 3 \
    https://download.swift.org/swift-6.3.2-release/ubuntu2404/swift-6.3.2-RELEASE/swift-6.3.2-RELEASE-ubuntu24.04.tar.gz \
    | tar -xz --strip-components=2 -C "$swift_root"
test -x "$swift_root/bin/swift"
export PATH="$swift_root/bin:$PATH"
echo "$swift_root/bin" >> "$GITHUB_PATH"
sudo rm -rf /usr/lib/swift
sudo ln -s "$swift_root" /usr/lib/swift
swift --version

mingw_archive="$PLAYPORT_BUILD/inputs/llvm-mingw.tar.xz"
curl --fail --location --retry 3 -o "$mingw_archive" \
    https://github.com/mstorsjo/llvm-mingw/releases/download/20260922/llvm-mingw-20260922-ucrt-ubuntu-22.04-x86_64.tar.xz
echo "bb7bb7654b33d5aa8712acb837c963b2e0c56352560c76105270a3268c665c21  $mingw_archive" | sha256sum -c -
tar -xf "$mingw_archive" -C "$PLAYPORT_BUILD/inputs"
rm "$mingw_archive"
export LLVM_MINGW="$PLAYPORT_BUILD/inputs/llvm-mingw-20260922-ucrt-ubuntu-22.04-x86_64"
crt="$PLAYPORT_BUILD/inputs/mingw-crt"
git init -q "$crt"
git -C "$crt" fetch --depth 1 https://github.com/mingw-w64/mingw-w64.git 57b595039040eaa15bece85b7cc71d952281b269
git -C "$crt" checkout -q FETCH_HEAD
export PATH="$LLVM_MINGW/bin:$PATH"
mkdir "$crt/build"
(
    cd "$crt/build"
    ../mingw-w64-crt/configure --prefix="$LLVM_MINGW" --host=aarch64-w64-mingw32 \
        --disable-lib32 --disable-lib64 --enable-libarm64 --enable-arm64x \
        --with-default-msvcrt=ucrt --enable-cfguard --enable-silent-rules
    make -j"$JOBS"
    make install
)
builtins=$(find "$LLVM_MINGW/lib/clang" -name libclang_rt.builtins-aarch64.a -print -quit)
test -s "$builtins"
for name in libgcc.a libgcc_eh.a libgcc_s.a; do cp "$builtins" "$LLVM_MINGW/aarch64-w64-mingw32/lib/$name"; done
# Host clang must remain LLVM 22, while MinGW is addressed by its absolute path.
export PATH="$host_bin:$swift_root/bin:$PLAYPORT_BUILD/inputs/python/bin:/usr/bin:/bin:/usr/local/bin"
echo "$host_bin" >> "$GITHUB_PATH"
export XDG_CONFIG_HOME="$PLAYPORT_BUILD/config"
mkdir -p "$XDG_CONFIG_HOME"
{
    echo "PLAYPORT_BUILD=$PLAYPORT_BUILD"
    echo "LLVM_MINGW=$LLVM_MINGW"
    echo "XDG_CONFIG_HOME=$XDG_CONFIG_HOME"
} >> "$GITHUB_ENV"
bash build/toolchain/xtool.sh
