#!/bin/bash
#
# 编译 16 KB 页对齐的 32 位 libc++_shared.so（armeabi-v7a / x86）。
#
# 背景
#   NDK r27c 只为 64 位 ABI 提供 16 KB 对齐的 libc++_shared.so；32 位预编译版
#   仍是 4 KB（p_align 0x1000），而且它是从 NDK 直接复制进 AAR 的，没有任何
#   链接器参数能作用到它。本脚本用 NDK 的 clang 重新编译这两个 ABI，链接时
#   显式指定 16 KB 页大小，产物由 android.sh 在 ndk-build 之后替换进
#   android/libs/<abi>/libc++_shared.so。
#
# 用法（在仓库任意位置调用均可）
#   ANDROID_NDK_ROOT=/path/to/ndk ./tools/build-libcxx-16kb.sh
#   ./tools/build-libcxx-16kb.sh --abis "armeabi-v7a x86" --api 16
#
# 依赖
#   git、cmake >= 3.20、ninja，以及可访问 github.com 的网络。CI 的
#   ubuntu-24.04 runner 已具备；Windows 本机（无 WSL）无法运行。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# 与 NDK r27c 的 clang 18 对齐（libc++ 的 ABI 在 18.x 内稳定）
LLVM_TAG="llvmorg-18.1.8"
ABIS="armeabi-v7a x86"
API=16
OUT_DIR="${REPO_DIR}/android-8.1-lts/prebuilt/libcxx-16kb"
WORK_DIR="${TMPDIR:-/tmp}/ffmpeg-kit-libcxx-16kb"
FORCE=0
JOBS=""

display_usage() {
  cat <<'EOF'
Build 16 KB page-aligned 32-bit libc++_shared.so.

Options:
  --abis "<a> <b>"   32-bit ABIs to build (default: armeabi-v7a x86)
  --api <n>          Android API level (default: 16)
  --llvm-tag <tag>   llvm-project tag (default: llvmorg-18.1.8)
  --out <dir>        output dir (default: android-8.1-lts/prebuilt/libcxx-16kb)
  --work <dir>       clone/build dir (default: $TMPDIR/ffmpeg-kit-libcxx-16kb)
  --jobs <n>         parallel build jobs (default: ninja's own default)
  --force            rebuild even when the output already exists
  -h, --help         show this help

Requires: ANDROID_NDK_ROOT (r27c+), git, cmake, ninja.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  --abis)
    ABIS="${2:?missing value for --abis}"
    shift 2
    ;;
  --api)
    API="${2:?missing value for --api}"
    shift 2
    ;;
  --llvm-tag)
    LLVM_TAG="${2:?missing value for --llvm-tag}"
    shift 2
    ;;
  --out)
    OUT_DIR="${2:?missing value for --out}"
    shift 2
    ;;
  --work)
    WORK_DIR="${2:?missing value for --work}"
    shift 2
    ;;
  --jobs)
    JOBS="${2:?missing value for --jobs}"
    shift 2
    ;;
  --force)
    FORCE=1
    shift
    ;;
  -h | --help)
    display_usage
    exit 0
    ;;
  *)
    echo "ERROR: unknown option: $1" >&2
    display_usage >&2
    exit 1
    ;;
  esac
done

# ---------------------------------------------------------------------------
# 环境检查
# ---------------------------------------------------------------------------

if [[ -z "${ANDROID_NDK_ROOT:-}" ]]; then
  echo "ERROR: ANDROID_NDK_ROOT is not set" >&2
  exit 1
fi

for required_tool in git cmake ninja; do
  if ! command -v "${required_tool}" >/dev/null 2>&1; then
    echo "ERROR: ${required_tool} not found in PATH" >&2
    exit 1
  fi
done

NDK_LLVM_DIR="${ANDROID_NDK_ROOT}/toolchains/llvm/prebuilt"
if [[ ! -d "${NDK_LLVM_DIR}" ]]; then
  echo "ERROR: ${NDK_LLVM_DIR} not found" >&2
  exit 1
fi

HOST_TOOLCHAIN_DIR="$(find "${NDK_LLVM_DIR}" -mindepth 1 -maxdepth 1 -type d -print -quit)"
READELF="${HOST_TOOLCHAIN_DIR}/bin/llvm-readelf"
if [[ ! -x "${READELF}" ]]; then
  echo "ERROR: ${READELF} not found" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 工具函数
# ---------------------------------------------------------------------------

# 校验产物：必须是 ELF32，且所有 LOAD 段 p_align 为 16 KB
verify_elf32_16kb() {
  local so="$1"
  local abi="$2"
  local elf_class bad_align

  elf_class="$("${READELF}" -h "${so}" | awk -F: '/Class:/ {gsub(/ /, "", $2); print $2}')"
  if [[ "${elf_class}" != "ELF32" ]]; then
    echo "ERROR: ${abi}: expected ELF32, got '${elf_class}'" >&2
    return 1
  fi

  bad_align="$("${READELF}" -l "${so}" | awk '$1 == "LOAD" {print $NF}' | grep -v '^0x4000$' || true)"
  if [[ -n "${bad_align}" ]]; then
    echo "ERROR: ${abi}: LOAD segments not 16 KB aligned: ${bad_align}" >&2
    return 1
  fi
}

# 校验产物能直接顶替 NDK 的 libc++_shared.so：
#   * SONAME 必须是 libc++_shared.so，否则 App 的 DT_NEEDED 会写成别的名字，
#     运行时找不到文件；
#   * 不能依赖单独的 libc++abi.so / libunwind.so（AAR 只替换这一个文件，
#     NDK 也不提供这些库），c++abi 必须是静态并进 libc++_shared.so；
#   * 必须导出 __ndk1 命名空间的符号，NDK 头文件用的是 __ndk1 而不是 __1。
verify_libcxx_layout() {
  local so="$1"
  local abi="$2"
  local soname needed

  soname="$("${READELF}" -d "${so}" | sed -n 's/.*(SONAME).*\[\(.*\)\].*/\1/p')"
  if [[ "${soname}" != "libc++_shared.so" ]]; then
    echo "ERROR: ${abi}: unexpected SONAME '${soname}' (want libc++_shared.so)" >&2
    return 1
  fi

  needed="$("${READELF}" -d "${so}" | sed -n 's/.*(NEEDED).*\[\(.*\)\].*/\1/p' |
    grep -E '^(libc\+\+_shared|libc\+\+abi|libunwind|libstdc\+\+)\.so' || true)"
  if [[ -n "${needed}" ]]; then
    echo "ERROR: ${abi}: depends on ${needed}, which the AAR does not ship" >&2
    return 1
  fi

  if ! "${READELF}" --dyn-syms --wide "${so}" |
    awk '/__ndk1/ && $7 != "UND" {found = 1} END {exit !found}'; then
    echo "ERROR: ${abi}: no __ndk1 symbols; built with the wrong ABI namespace" >&2
    return 1
  fi

  if ! "${READELF}" --dyn-syms --wide "${so}" |
    awk '$8 == "__cxa_throw" && $7 != "UND" {found = 1} END {exit !found}'; then
    echo "ERROR: ${abi}: __cxa_throw is not defined; libc++abi was not linked in statically" >&2
    return 1
  fi
}

# HEAD 是否正好落在 LLVM_TAG 上（浅克隆 + annotated tag 也能判断）
llvm_checkout_matches_tag() {
  local llvm_src="$1"
  local head_tag
  head_tag="$(git -C "${llvm_src}" describe --tags --exact-match HEAD 2>/dev/null || true)"
  [[ "${head_tag}" == "${LLVM_TAG}" ]]
}

# 稀疏克隆 llvm-project，只取 libc++ 构建需要的目录
prepare_llvm_sources() {
  local llvm_src="${WORK_DIR}/llvm-project"

  if [[ -d "${llvm_src}" ]] && llvm_checkout_matches_tag "${llvm_src}"; then
    echo "Reusing existing llvm-project checkout at ${llvm_src}"
    return 0
  fi

  echo "Cloning llvm-project ${LLVM_TAG} (sparse checkout)..."
  mkdir -p "${WORK_DIR}"
  rm -rf "${llvm_src}"
  # annotated tag + --depth 1 时 git 会打印
  #   warning: refs/tags/llvmorg-... is not a commit!
  # 这只是浅克隆解析 tag 对象时的噪声，不代表检出的版本不对；克隆后用
  # llvm_checkout_matches_tag 确认 HEAD 确实在该 tag 上，避免误用别的提交。
  git clone --filter=blob:none --no-checkout --depth 1 --branch "${LLVM_TAG}" \
    https://github.com/llvm/llvm-project.git "${llvm_src}"
  git -C "${llvm_src}" sparse-checkout init --cone
  git -C "${llvm_src}" sparse-checkout set cmake libcxx libcxxabi libunwind runtimes llvm/cmake
  git -C "${llvm_src}" checkout

  if ! llvm_checkout_matches_tag "${llvm_src}"; then
    echo "ERROR: ${llvm_src} is not at ${LLVM_TAG}; refusing to build a mismatched libc++" >&2
    exit 1
  fi
}

build_abi() {
  local abi="$1"
  local llvm_src="${WORK_DIR}/llvm-project"
  local build_dir="${WORK_DIR}/build-${abi}"
  local so

  rm -rf "${build_dir}"

  echo "Configuring libc++ for ${abi} (API ${API})..."
  # 选项以 llvm-project 自带的 libcxx/cmake/caches/AndroidNDK.cmake 为准：
  #   * benchmarks 依赖 third-party/benchmark 子模块，稀疏克隆里是空目录，
  #     configure 阶段 ExternalProject_Add 会直接报 "No download info given"，
  #     所以 LIBCXX_INCLUDE_BENCHMARKS 必须关掉（测试/docs 同理，runner 上没有
  #     lit 需要的 llvm/utils/llvm-lit）。
  #   * LIBCXX_SHARED_OUTPUT_NAME 不设的话产物叫 libc++.so，脚本找不到
  #     libc++_shared.so。
  #   * LIBCXX_ABI_NAMESPACE 必须是 __ndk1：NDK 头文件用的就是 __ndk1，
  #     libc++ 默认的 __1 会让 App 链接时符号全部对不上。
  #   * Android 上 CMAKE_PLATFORM_NO_VERSIONED_SONAME 生效，若再开 ABI linker
  #     script，生成的脚本会覆盖同名 .so，必须关掉。
  cmake -G Ninja \
    -S "${llvm_src}/runtimes" \
    -B "${build_dir}" \
    -DCMAKE_TOOLCHAIN_FILE="${ANDROID_NDK_ROOT}/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI="${abi}" \
    -DANDROID_PLATFORM="android-${API}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLVM_ENABLE_RUNTIMES="libcxx;libcxxabi;libunwind" \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_INCLUDE_DOCS=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DLIBCXX_INCLUDE_TESTS=OFF \
    -DLIBCXX_INCLUDE_DOCS=OFF \
    -DLIBCXX_INCLUDE_BENCHMARKS=OFF \
    -DLIBCXXABI_INCLUDE_TESTS=OFF \
    -DLIBUNWIND_INCLUDE_TESTS=OFF \
    -DLIBCXX_ENABLE_SHARED=ON \
    -DLIBCXX_ENABLE_STATIC=OFF \
    -DLIBCXX_SHARED_OUTPUT_NAME=c++_shared \
    -DLIBCXX_ABI_VERSION=1 \
    -DLIBCXX_ABI_NAMESPACE=__ndk1 \
    -DLIBCXX_ENABLE_STATIC_ABI_LIBRARY=ON \
    -DLIBCXX_ENABLE_ABI_LINKER_SCRIPT=OFF \
    -DLIBCXXABI_ENABLE_SHARED=OFF \
    -DLIBCXXABI_ENABLE_STATIC=OFF \
    -DLIBCXXABI_USE_LLVM_UNWINDER=ON \
    -DLIBCXXABI_ENABLE_STATIC_UNWINDER=ON \
    -DLIBUNWIND_ENABLE_SHARED=OFF \
    -DLIBUNWIND_ENABLE_STATIC=ON \
    -DCMAKE_SHARED_LINKER_FLAGS="-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384"

  echo "Building libc++ for ${abi}..."
  if [[ -n "${JOBS}" ]]; then
    ninja -C "${build_dir}" -j "${JOBS}"
  else
    ninja -C "${build_dir}"
  fi

  so="$(find "${build_dir}" -type f -name 'libc++_shared.so' -print -quit)"
  if [[ -z "${so}" ]]; then
    echo "ERROR: libc++_shared.so was not produced for ${abi}" >&2
    return 1
  fi

  verify_elf32_16kb "${so}" "${abi}"
  verify_libcxx_layout "${so}" "${abi}"

  mkdir -p "${OUT_DIR}/${abi}"
  cp -f "${so}" "${OUT_DIR}/${abi}/libc++_shared.so"
  echo "OK: ${OUT_DIR}/${abi}/libc++_shared.so"
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

if [[ ${FORCE} -eq 0 ]]; then
  # shellcheck disable=SC2086
  all_present=1
  for abi in ${ABIS}; do
    if [[ ! -f "${OUT_DIR}/${abi}/libc++_shared.so" ]]; then
      all_present=0
      break
    fi
  done

  if [[ ${all_present} -eq 1 ]]; then
    echo "Found existing 16 KB libc++_shared.so under ${OUT_DIR}; verifying."
    # shellcheck disable=SC2086
    for abi in ${ABIS}; do
      verify_elf32_16kb "${OUT_DIR}/${abi}/libc++_shared.so" "${abi}"
      verify_libcxx_layout "${OUT_DIR}/${abi}/libc++_shared.so" "${abi}"
    done
    echo "Nothing to do. Use --force to rebuild."
    exit 0
  fi
fi

prepare_llvm_sources

# shellcheck disable=SC2086
for abi in ${ABIS}; do
  build_abi "${abi}"
done

echo
echo "Done. 16 KB aligned libc++_shared.so:"
# shellcheck disable=SC2086
for abi in ${ABIS}; do
  echo "  ${OUT_DIR}/${abi}/libc++_shared.so"
done
