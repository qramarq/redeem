#!/usr/bin/env bash
# Build three CPU llama-server binaries from the pinned llama.cpp tag.
# AVX2, AVX (no AVX2), and SSE4.2 (no AVX). No ARM64 build in this tree.
# Binaries are linked with libgcc and libstdc++ static, OpenMP and curl off,
# so a SystemRescue live system does not need a matching toolchain.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$here/lib.sh"
load_versions

root=$(redeem_root)
src=$root/build/src/llama.cpp
out=$root/build/cache/bin
work=$root/build/work
mkdir -p "$out" "$work" "$(dirname "$src")"

if [[ ! -d $src/.git ]]; then
  rtk_err git clone --depth 1 --branch "$LLAMA_CPP_VERSION" "$LLAMA_CPP_URL" "$src"
fi

build_one() {
  local name=$1
  shift
  local bdir=$work/llama-$name
  printf 'configure llama-server-%s\n' "$name"
  rtk_err cmake -S "$src" -B "$bdir" -G Ninja \
    -DCMAKE_C_COMPILER=gcc \
    -DCMAKE_CXX_COMPILER=g++ \
    -DCMAKE_BUILD_TYPE=Release \
    -DGGML_NATIVE=OFF \
    -DGGML_BACKEND_DL=OFF \
    -DGGML_OPENMP=OFF \
    -DLLAMA_OPENSSL=OFF \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_EXAMPLES=ON \
    -DLLAMA_BUILD_SERVER=ON \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_EXE_LINKER_FLAGS="-static-libgcc -static-libstdc++" \
    "$@"
  printf 'build llama-server-%s\n' "$name"
  rtk_err cmake --build "$bdir" --target llama-server -j "$(nproc)"
  local built
  built=$(find "$bdir" -type f -name llama-server -perm -u+x | head -n 1)
  [[ -n $built ]] || die "llama-server binary not produced for $name"
  cp "$built" "$out/llama-server-$name"
  chmod +x "$out/llama-server-$name"
  "$out/llama-server-$name" --version >"$out/llama-server-$name.version" 2>&1 || true
  if command -v ldd >/dev/null 2>&1; then
    ldd "$out/llama-server-$name" >"$out/llama-server-$name.ldd" 2>&1 || true
  fi
}

# Explicit ISA flags. GGML_NATIVE=OFF still defaults the AVX switches ON,
# so each variant sets the ones it must not use.
build_one avx2 \
  -DGGML_SSE42=ON -DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON -DGGML_BMI2=ON \
  -DGGML_AVX512=OFF -DGGML_AVX512_VBMI=OFF -DGGML_AVX512_VNNI=OFF -DGGML_AVX512_BF16=OFF \
  -DGGML_AVX_VNNI=OFF

build_one avx \
  -DGGML_SSE42=ON -DGGML_AVX=ON -DGGML_AVX2=OFF -DGGML_FMA=ON -DGGML_F16C=ON -DGGML_BMI2=OFF \
  -DGGML_AVX512=OFF -DGGML_AVX512_VBMI=OFF -DGGML_AVX512_VNNI=OFF -DGGML_AVX512_BF16=OFF \
  -DGGML_AVX_VNNI=OFF

build_one sse4 \
  -DGGML_SSE42=ON -DGGML_AVX=OFF -DGGML_AVX2=OFF -DGGML_FMA=OFF -DGGML_F16C=OFF -DGGML_BMI2=OFF \
  -DGGML_AVX512=OFF -DGGML_AVX512_VBMI=OFF -DGGML_AVX512_VNNI=OFF -DGGML_AVX512_BF16=OFF \
  -DGGML_AVX_VNNI=OFF

# objdump is stopped at the first hit, so the pipeline can die with SIGPIPE.
# The assignment keeps the captured line; `|| true` keeps set -e from aborting.
isa_hit() {
  local bin=$1 pattern=$2
  objdump -d "$bin" | awk -v pat="$pattern" '$0 ~ pat { print; exit }' || true
}
sse_hit=$(isa_hit "$out/llama-server-sse4" "v(movaps|movdqu|addps|mulps|xorps)")
if [[ -n $sse_hit ]]; then
  die "llama-server-sse4 contains AVX instructions: $sse_hit"
fi
avx_hit=$(isa_hit "$out/llama-server-avx2" "v(movaps|movdqu|addps|mulps)")
if [[ -z $avx_hit ]]; then
  die "llama-server-avx2 does not look like it contains AVX instructions"
fi

printf 'built:\n'
ls -l "$out"/llama-server-avx2 "$out"/llama-server-avx "$out"/llama-server-sse4
