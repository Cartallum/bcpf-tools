#!/usr/bin/env bash
set -ex

unameOut="$(uname -s)"
case "${unameOut}" in
    Darwin*)
        EXE_SUFFIX=
        HOST_TRIPLE=x86_64-apple-darwin
        ARTIFACT=cbe-bpf-tools-osx.tar.bz2;;
    MINGW*)
        EXE_SUFFIX=.exe
        HOST_TRIPLE=x86_64-pc-windows-msvc
        ARTIFACT=cbe-bpf-tools-windows.tar.bz2;;
    Linux* | *)
        EXE_SUFFIX=
        HOST_TRIPLE=x86_64-unknown-linux-gnu
        ARTIFACT=cbe-bpf-tools-linux.tar.bz2
esac

cd "$(dirname "$0")"
OUT_DIR=$(realpath "${1:-out}")

rm -rf "${OUT_DIR}"
mkdir -p "${OUT_DIR}"
pushd "${OUT_DIR}"

git clone --single-branch --branch sbf-tools-v1.32 https://github.com/Cartallum/rust.git
echo "$( cd rust && git rev-parse HEAD )  https://github.com/Cartallum/rust.git" >> version.md

git clone --single-branch --branch sbf-tools-v1.32 https://github.com/Cartallum/cargo.git
echo "$( cd cargo && git rev-parse HEAD )  https://github.com/Cartallum/cargo.git" >> version.md

pushd rust
./build.sh
popd

pushd cargo
if [[ "${HOST_TRIPLE}" == "x86_64-unknown-linux-gnu" ]] ; then
    OPENSSL_STATIC=1 OPENSSL_LIB_DIR=/usr/lib/x86_64-linux-gnu OPENSSL_INCLUDE_DIR=/usr/include/openssl cargo build --release
else
    OPENSSL_STATIC=1 cargo build --release
fi
popd

if [[ "${HOST_TRIPLE}" != "x86_64-pc-windows-msvc" ]] ; then
    git clone --single-branch --branch sbf-tools-v1.32 https://github.com/Cartallum/msvclib.git
    echo "$( cd msvclib && git rev-parse HEAD )  https://github.com/Cartallum/msvclib.git" >> version.md
    mkdir -p msvclib_build
    mkdir -p msvclib_install
    pushd msvclib_build
    CC="${OUT_DIR}/rust/build/${HOST_TRIPLE}/llvm/bin/clang" \
      AR="${OUT_DIR}/rust/build/${HOST_TRIPLE}/llvm/bin/llvm-ar" \
      RANLIB="${OUT_DIR}/rust/build/${HOST_TRIPLE}/llvm/bin/llvm-ranlib" \
      ../msvclib/msvclib/configure --target=sbf-Cartallum-cbe --host=sbf-cbe --build="${HOST_TRIPLE}" --prefix="${OUT_DIR}/msvclib_install"
    make install
    popd
fi

# Copy rust build products
mkdir -p deploy/rust
cp version.md deploy/
cp -R "rust/build/${HOST_TRIPLE}/stage1/bin" deploy/rust/
cp -R "cargo/target/release/cargo${EXE_SUFFIX}" deploy/rust/bin/
mkdir -p deploy/rust/lib/rustlib/
cp -R "rust/build/${HOST_TRIPLE}/stage1/lib/rustlib/${HOST_TRIPLE}" deploy/rust/lib/rustlib/
cp -R "rust/build/${HOST_TRIPLE}/stage1/lib/rustlib/bpfel-unknown-unknown" deploy/rust/lib/rustlib/
find . -maxdepth 6 -type f -path "./rust/build/${HOST_TRIPLE}/stage1/lib/*" -exec cp {} deploy/rust/lib \;
mkdir -p deploy/rust/lib/rustlib/src/rust
cp "rust/build/${HOST_TRIPLE}/stage1/lib/rustlib/src/rust/Cargo.lock" deploy/rust/lib/rustlib/src/rust
cp -R "rust/build/${HOST_TRIPLE}/stage1/lib/rustlib/src/rust/library" deploy/rust/lib/rustlib/src/rust

# Copy llvm build products
mkdir -p deploy/llvm/{bin,lib}
while IFS= read -r f
do
    bin_file="rust/build/${HOST_TRIPLE}/llvm/build/bin/${f}${EXE_SUFFIX}"
    if [[ -f "$bin_file" ]] ; then
        cp -R "$bin_file" deploy/llvm/bin/
    fi
done < <(cat <<EOF
clang
clang++
clang-cl
clang-cpp
clang-15
ld.lld
ld64.lld
llc
lld
lld-link
llvm-ar
llvm-objcopy
llvm-objdump
llvm-readelf
llvm-readobj
EOF
         )
cp -R "rust/build/${HOST_TRIPLE}/llvm/build/lib/clang" deploy/llvm/lib/
if [[ "${HOST_TRIPLE}" != "x86_64-pc-windows-msvc" ]] ; then
    cp -R msvclib_install/sbf-cbe/lib/lib{c,m}.a deploy/llvm/lib/
    cp -R msvclib_install/sbf-cbe/include deploy/llvm/
fi

# Check the Rust binaries
while IFS= read -r f
do
    "./deploy/rust/bin/${f}${EXE_SUFFIX}" --version
done < <(cat <<EOF
cargo
rustc
rustdoc
EOF
         )
# Check the LLVM binaries
while IFS= read -r f
do
    "./deploy/llvm/bin/${f}${EXE_SUFFIX}" --version
done < <(cat <<EOF
clang
clang++
clang-cl
clang-cpp
ld.lld
llc
lld-link
llvm-ar
llvm-objcopy
llvm-objdump
llvm-readelf
llvm-readobj
EOF
         )

tar -C deploy -jcf ${ARTIFACT} .

rm -rf deploy/rust/lib/rustlib/bpfel-unknown-unknown
cp -R "rust/build/${HOST_TRIPLE}/stage1/lib/rustlib/sbf-Cartallum-cbe" deploy/rust/lib/rustlib/
tar -C deploy -jcf ${ARTIFACT/bpf/sbf} .

popd

mv "${OUT_DIR}/${ARTIFACT}" "${OUT_DIR}/${ARTIFACT/bpf/sbf}" .

# Build linux binaries on macOS in docker
if [[ "$(uname)" == "Darwin" ]] && [[ $# == 1 ]] && [[ "$1" == "--docker" ]] ; then
    docker system prune -a -f
    docker build -t Cartallum/bpf-tools .
    id=$(docker create Cartallum/bpf-tools /build.sh "${OUT_DIR}")
    docker cp build.sh "${id}:/"
    docker start -a "${id}"
    docker cp "${id}:${OUT_DIR}/cbe-bpf-tools-linux.tar.bz2" "${OUT_DIR}"
fi
