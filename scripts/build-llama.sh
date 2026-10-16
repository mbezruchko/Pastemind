#!/bin/bash
# Builds llama.cpp (MIT) with Metal as one static library, Vendor/llama/lib/libllamacpp.a, plus its headers in
# Vendor/llama/include (all out of git): the text model, and mtmd for EmbeddingGemma 2's image encoder.
# Pinned to one tag (the first tags with EmbeddingGemma 2 are b11452+), with two small patches: one stops an embedding
# context from reserving logits, the other lets mtmd load the image or the audio encoder without the other. Does nothing when that build is already there; build.sh runs it every time.
set -euo pipefail
cd "$(dirname "$0")/.."
TAG=b11461
COMMIT=4d756bc72bf00a4aacf410ae15a2d315f3db400d   # TAG's commit: a tag can be moved, a commit can't
PATCHES=(scripts/llama.cpp-no-logits.patch scripts/llama.cpp-one-encoder.patch)
SOURCE=Vendor/llama.cpp
BUILD=Vendor/llama-build
OUT=Vendor/llama
STAMP="$TAG $(cat "${PATCHES[@]}" | shasum -a 256 | cut -c1-12) metal mtmd"
if [[ -f "$OUT/lib/libllamacpp.a" && "$(cat "$OUT/BUILD" 2>/dev/null)" == "$STAMP" ]]; then
  exit 0
fi
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

if [[ ! -d "$SOURCE" ]]; then
  git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$TAG" https://github.com/ggml-org/llama.cpp "$SOURCE"
fi
if [[ "$(git -C "$SOURCE" rev-parse HEAD)" != "$COMMIT" ]]; then
  echo "llama.cpp's $TAG isn't commit $COMMIT here: not building it" >&2
  exit 1
fi
# Without the first, every input token costs 1 MiB of logits an embedding model never produces (262k vocabulary).
for PATCH in "${PATCHES[@]}"; do
  if git -C "$SOURCE" apply --check "../../$PATCH" 2>/dev/null; then
    git -C "$SOURCE" apply "../../$PATCH"
  fi
done

GENERATOR=$(command -v ninja > /dev/null && echo Ninja || echo "Unix Makefiles")
cmake -S "$SOURCE" -B "$BUILD" -G "$GENERATOR" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_NATIVE=OFF -DLLAMA_BUILD_MTMD=ON \
  -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
  -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_APP=OFF -DLLAMA_BUILD_UI=OFF -DLLAMA_OPENSSL=OFF > /dev/null
cmake --build "$BUILD" --config Release -j "$(sysctl -n hw.ncpu)" --target llama mtmd > /dev/null

mkdir -p "$OUT/lib" "$OUT/include"
B="$BUILD"
LIBS=($B/src/libllama.a $B/tools/mtmd/libmtmd.a $B/ggml/src/libggml.a $B/ggml/src/libggml-base.a $B/ggml/src/libggml-cpu.a
      $B/ggml/src/ggml-metal/libggml-metal.a $B/ggml/src/ggml-blas/libggml-blas.a)
[[ -f $B/vendor/hash/libvendor-hash.a ]] && LIBS+=($B/vendor/hash/libvendor-hash.a)
xcrun libtool -static -no_warning_for_no_symbols -o "$OUT/lib/libllamacpp.a" "${LIBS[@]}"
cp "$SOURCE/include/llama.h" "$SOURCE"/ggml/include/*.h "$SOURCE/tools/mtmd/mtmd.h" "$SOURCE/tools/mtmd/mtmd-helper.h" \
  "$OUT/include/"
echo "$STAMP" > "$OUT/BUILD"
echo "Built llama.cpp $TAG (patched, metal) into $OUT"
