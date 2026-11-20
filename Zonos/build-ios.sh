#!/bin/bash
# Builds the ZONOS3-Mini runtime and our bridge for the iPhone and merges everything into one
# static library the app links: build-ios.sh <ZONOS3-Mini checkout> <output folder>
set -euo pipefail
SRC=$(cd "$1" && pwd)
OUT=$2
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$OUT"

# The server's text preparation is a Rust library that the model's build compiles for the machine
# it runs on. For the phone it has to be compiled for iOS instead: add the target to the cargo
# command and point the build at the iOS output. (The checkout is pinned, so the lines are known.)
CM="$SRC/servers/ggml/CMakeLists.txt"
rustup target add aarch64-apple-ios
if ! grep -q 'aarch64-apple-ios' "$CM"; then
  sed -i.bak \
    -e 's|--features capi --crate-type staticlib|--features capi --crate-type staticlib --target aarch64-apple-ios|' \
    -e 's|${TEXTNORM_TARGET_DIR}/release/libzyphra_textnorm.a|${TEXTNORM_TARGET_DIR}/aarch64-apple-ios/release/libzyphra_textnorm.a|' \
    "$CM"
fi
grep -q -- '--crate-type staticlib --target aarch64-apple-ios' "$CM"
grep -q 'aarch64-apple-ios/release/libzyphra_textnorm.a' "$CM"
export IPHONEOS_DEPLOYMENT_TARGET=18.0

cmake -S "$HERE" -B "$OUT/build" -DCMAKE_BUILD_TYPE=Release -DZONOS_SRC="$SRC" \
  -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_SYSTEM_PROCESSOR=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=18.0 \
  -DBUILD_SHARED_LIBS=OFF -DCMAKE_MACOSX_BUNDLE=OFF -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
  -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF
cmake --build "$OUT/build" --target zb -j 4
# cargo keeps a second copy of its library under deps/; one is enough.
LIBS=$(find "$OUT/build" -name '*.a' -not -path '*/deps/*')
echo "$LIBS"
libtool -static -o "$OUT/libzonos_all.a" $LIBS
ls -l "$OUT/libzonos_all.a"
