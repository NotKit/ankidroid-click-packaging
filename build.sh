#!/bin/bash
# Build the atlas (Android Translation Layer) runtime plus AnkiDroid and
# assemble the click package tree.
#
# Modeled on the flathub packaging of ATL:
#   https://github.com/flathub/io.gitlab.android_translation_layer.BaseApp
#   https://github.com/flathub/net.newpipe.NewPipe
#
# Runs inside a NATIVE arm64 clickable container (art_standalone cannot be
# cross-compiled). On an x86_64 host docker runs the container via
# qemu-user/binfmt_misc — slow (the first build takes many hours, most of it
# WPE WebKit) but fully unattended. All stages are stamped and cached in
# ${ROOT}/build, so subsequent builds only redo what changed.
set -euo pipefail

APP_ID="ankidroid.nekit"
APP_HOOK="ankidroid"

# click maintains a version-independent 'current' symlink to the active
# package version. Baking it into the meson prefix makes compiled-in paths
# (rpath, INSTALL_DATADIR, AOT dex locations) valid at runtime regardless of
# the installed package version.
CLICK_BASE="/opt/click.ubuntu.com/${APP_ID}/current"
CLICK_PREFIX="${CLICK_BASE}/usr"

# --- pinned sources -----------------------------------------------------

ANKIDROID_VERSION="2.24.0"

GLFW_VERSION="3.4"
GLFW_SHA256="b5ec004b2712fd08e8861dc271428f048775200a2df719ccf575143ba749a3e9"

LIBWPE_VERSION="1.16.2"
LIBWPE_SHA256="960bdd11c3f2cf5bd91569603ed6d2aa42fd4000ed7cac930a804eac367888d7"

WPEBACKEND_FDO_VERSION="1.16.1"
WPEBACKEND_FDO_SHA256="544ae14012f8e7e426b8cb522eb0aaaac831ad7c35601d1cf31d37670e0ebb3b"

WPEWEBKIT_VERSION="2.46.7"
WPEWEBKIT_SHA256="cf3e47638595d86de96abdb94db69a836c8aa509fc063be714f52c5a24bb5cd5"

VIXL_VERSION="8.0.0"
VIXL_SHA256="6aebbebcd9b66686ea246b450af529e1fc50fe25209522cc9ab42beae2377d38"

LIBUNWIND_VERSION="1.8.2"
LIBUNWIND_SHA256="7f262f1a1224f437ede0f96a6932b582c8f5421ff207c04e3d9504dfa04c8b82"

# --- environment from clickable's custom builder ------------------------

ROOT="${ROOT:?not run through clickable}"
BUILD_DIR="${BUILD_DIR:?}"
INSTALL_DIR="${INSTALL_DIR:?}"
ARCH="${ARCH:-arm64}"
JOBS="${NUM_PROCS:-$(nproc)}"

case "${ARCH}" in
    arm64) ART_ARCH="arm64";  APK_ABI="arm64-v8a"
           APK_URL="https://github.com/ankidroid/Anki-Android/releases/download/v${ANKIDROID_VERSION}/AnkiDroid-${ANKIDROID_VERSION}-arm64-v8a.apk"
           APK_SHA256="7f498e77b372344ec3f2da98590be1c476c40e706b88d27cac0a45bd734489f8" ;;
    amd64) ART_ARCH="x86_64"; APK_ABI="x86_64"
           APK_URL="https://github.com/ankidroid/Anki-Android/releases/download/v${ANKIDROID_VERSION}/variant-abi-AnkiDroid-${ANKIDROID_VERSION}-x86_64.apk"
           APK_SHA256="" ;; # untested; fill in when enabling amd64
    *) echo "unsupported arch: ${ARCH}" >&2; exit 1 ;;
esac

STAGE="${BUILD_DIR}/stage"          # build-time sysroot for the whole chain
PREFIX="${STAGE}/usr"
DL="${BUILD_DIR}/downloads"
STAMPS="${BUILD_DIR}/stamps"
mkdir -p "${PREFIX}" "${DL}" "${STAMPS}"

export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig:${PREFIX}/share/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"
export PATH="${PREFIX}/bin:${PATH}"
export LD_LIBRARY_PATH="${PREFIX}/lib:${PREFIX}/lib/art${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
export LIBRARY_PATH="${PREFIX}/lib"
# include/vixl is needed because art includes vixl headers as e.g.
# "aarch64/disasm-aarch64.h" without the vixl/ prefix
export CPATH="${PREFIX}/include:${PREFIX}/include/vixl"
export CMAKE_PREFIX_PATH="${PREFIX}"
JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")"
export JAVA_HOME

log()   { echo -e "\033[1;34m[build.sh]\033[0m $*"; }
stamp() { [ -f "${STAMPS}/$1.done" ]; }
done_stamp() { touch "${STAMPS}/$1.done"; }

# Stamp names carry the pinned version (or submodule commit) so a stale
# build/CI cache can never mask a version bump: the renamed stamp simply
# doesn't exist and the stage rebuilds. Completed stages also delete their
# build trees — only stage/ is needed afterwards, and CI runners are
# disk-constrained.
WOLFSSL_REV="$(git -C "${ROOT}/wolfssl" rev-parse --short HEAD 2>/dev/null || echo unknown)"
BIONIC_REV="$(git -C "${ROOT}/bionic_translation" rev-parse --short HEAD 2>/dev/null || echo unknown)"
# the stage carries our patch, so its stamp must change when the patch does
BIONIC_REV="${BIONIC_REV}-$(sha256sum "${ROOT}/patches/bionic_translation-ut.patch" | cut -c1-8)"
ART_REV="$(git -C "${ROOT}/art_standalone" rev-parse --short HEAD 2>/dev/null || echo unknown)"

fetch() { # fetch <url> <sha256> <outfile>
    local url="$1" sha="$2" out="${DL}/$3"
    if [ -f "${out}" ] && echo "${sha}  ${out}" | sha256sum -c - >/dev/null 2>&1; then
        return 0
    fi
    log "downloading $3"
    curl -Lf --retry 3 -o "${out}.tmp" "${url}"
    echo "${sha}  ${out}.tmp" | sha256sum -c -
    mv "${out}.tmp" "${out}"
}

# --- 1. GLFW 3.4 (noble ships 3.3, atlas needs the libdecor init hint) ---

if ! stamp "glfw-${GLFW_VERSION}"; then
    log "building GLFW ${GLFW_VERSION}"
    fetch "https://github.com/glfw/glfw/releases/download/${GLFW_VERSION}/glfw-${GLFW_VERSION}.zip" \
          "${GLFW_SHA256}" "glfw-${GLFW_VERSION}.zip"
    rm -rf "${BUILD_DIR}/glfw"
    unzip -q "${DL}/glfw-${GLFW_VERSION}.zip" -d "${BUILD_DIR}"
    mv "${BUILD_DIR}/glfw-${GLFW_VERSION}" "${BUILD_DIR}/glfw"
    cmake -S "${BUILD_DIR}/glfw" -B "${BUILD_DIR}/glfw/build" -GNinja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DBUILD_SHARED_LIBS=ON \
        -DGLFW_BUILD_WAYLAND=ON \
        -DGLFW_BUILD_X11=OFF \
        -DGLFW_BUILD_EXAMPLES=OFF -DGLFW_BUILD_TESTS=OFF -DGLFW_BUILD_DOCS=OFF
    ninja -C "${BUILD_DIR}/glfw/build" -j"${JOBS}" install
    done_stamp "glfw-${GLFW_VERSION}"
    rm -rf "${BUILD_DIR}/glfw"
fi

# --- 2. WPE WebKit stack (absent from noble; atlas links wpe-webkit-2.0) -

if ! stamp "libwpe-${LIBWPE_VERSION}"; then
    log "building libwpe ${LIBWPE_VERSION}"
    fetch "https://wpewebkit.org/releases/libwpe-${LIBWPE_VERSION}.tar.xz" \
          "${LIBWPE_SHA256}" "libwpe-${LIBWPE_VERSION}.tar.xz"
    rm -rf "${BUILD_DIR}/libwpe"
    tar -xf "${DL}/libwpe-${LIBWPE_VERSION}.tar.xz" -C "${BUILD_DIR}"
    mv "${BUILD_DIR}/libwpe-${LIBWPE_VERSION}" "${BUILD_DIR}/libwpe"
    meson setup "${BUILD_DIR}/libwpe/build" "${BUILD_DIR}/libwpe" \
        --prefix="${PREFIX}" --libdir=lib --buildtype=release
    ninja -C "${BUILD_DIR}/libwpe/build" -j"${JOBS}" install
    done_stamp "libwpe-${LIBWPE_VERSION}"
    rm -rf "${BUILD_DIR}/libwpe"
fi

if ! stamp "wpebackend-fdo-${WPEBACKEND_FDO_VERSION}"; then
    log "building wpebackend-fdo ${WPEBACKEND_FDO_VERSION}"
    fetch "https://wpewebkit.org/releases/wpebackend-fdo-${WPEBACKEND_FDO_VERSION}.tar.xz" \
          "${WPEBACKEND_FDO_SHA256}" "wpebackend-fdo-${WPEBACKEND_FDO_VERSION}.tar.xz"
    rm -rf "${BUILD_DIR}/wpebackend-fdo"
    tar -xf "${DL}/wpebackend-fdo-${WPEBACKEND_FDO_VERSION}.tar.xz" -C "${BUILD_DIR}"
    mv "${BUILD_DIR}/wpebackend-fdo-${WPEBACKEND_FDO_VERSION}" "${BUILD_DIR}/wpebackend-fdo"
    meson setup "${BUILD_DIR}/wpebackend-fdo/build" "${BUILD_DIR}/wpebackend-fdo" \
        --prefix="${PREFIX}" --libdir=lib --buildtype=release
    ninja -C "${BUILD_DIR}/wpebackend-fdo/build" -j"${JOBS}" install
    done_stamp "wpebackend-fdo-${WPEBACKEND_FDO_VERSION}"
    rm -rf "${BUILD_DIR}/wpebackend-fdo"
fi

if ! stamp "wpewebkit-${WPEWEBKIT_VERSION}"; then
    log "building WPE WebKit ${WPEWEBKIT_VERSION} (this is the big one)"
    fetch "https://wpewebkit.org/releases/wpewebkit-${WPEWEBKIT_VERSION}.tar.xz" \
          "${WPEWEBKIT_SHA256}" "wpewebkit-${WPEWEBKIT_VERSION}.tar.xz"
    if [ ! -d "${BUILD_DIR}/wpewebkit" ]; then
        tar -xf "${DL}/wpewebkit-${WPEWEBKIT_VERSION}.tar.xz" -C "${BUILD_DIR}"
        mv "${BUILD_DIR}/wpewebkit-${WPEWEBKIT_VERSION}" "${BUILD_DIR}/wpewebkit"
    fi
    cmake -S "${BUILD_DIR}/wpewebkit" -B "${BUILD_DIR}/wpewebkit/build" -GNinja \
        -DPORT=WPE \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_EXE_LINKER_FLAGS="-fuse-ld=lld" \
        -DCMAKE_SHARED_LINKER_FLAGS="-fuse-ld=lld" \
        -DCMAKE_MODULE_LINKER_FLAGS="-fuse-ld=lld" \
        -DENABLE_2022_GLIB_API=ON \
        -DUSE_ATK=OFF \
        -DUSE_LIBBACKTRACE=OFF \
        -DUSE_GSTREAMER_TRANSCODER=OFF \
        -DENABLE_DOCUMENTATION=OFF \
        -DENABLE_INTROSPECTION=OFF \
        -DENABLE_BUBBLEWRAP_SANDBOX=OFF \
        -DENABLE_GAMEPAD=OFF \
        -DENABLE_SPEECH_SYNTHESIS=OFF \
        -DENABLE_JOURNALD_LOG=OFF \
        -DENABLE_MINIBROWSER=OFF \
        -DUSE_JPEGXL=OFF
    ninja -C "${BUILD_DIR}/wpewebkit/build" -j"${JOBS}" install
    done_stamp "wpewebkit-${WPEWEBKIT_VERSION}"
    rm -rf "${BUILD_DIR}/wpewebkit"
fi

# --- 3. wolfSSL with JNI (distro package has JNI disabled) ---------------

if ! stamp "wolfssl-${WOLFSSL_REV}"; then
    log "building wolfSSL"
    rsync -a --delete --exclude=.git "${ROOT}/wolfssl/" "${BUILD_DIR}/wolfssl/"
    (
        cd "${BUILD_DIR}/wolfssl"
        autoreconf -i
        ./configure --prefix="${PREFIX}" \
            --enable-shared --disable-opensslall --disable-opensslextra \
            --enable-aescbc-length-checks --enable-curve25519 --enable-ed25519 \
            --enable-ed25519-stream --enable-oldtls --enable-base64encode \
            --enable-tlsx --enable-scrypt --disable-examples --enable-crl \
            --enable-jni --enable-sessioncerts
        make -j"${JOBS}"
        make install
    )
    done_stamp "wolfssl-${WOLFSSL_REV}"
    rm -rf "${BUILD_DIR}/wolfssl"
fi

# --- 4. vixl (ARM codegen backend for the art compiler; not in noble) ----

if [ "${ARCH}" = "arm64" ] && ! stamp "vixl-${VIXL_VERSION}"; then
    log "building vixl ${VIXL_VERSION}"
    fetch "https://github.com/Linaro/vixl/archive/refs/tags/${VIXL_VERSION}.tar.gz" \
          "${VIXL_SHA256}" "vixl-${VIXL_VERSION}.tar.gz"
    rm -rf "${BUILD_DIR}/vixl"
    tar -xf "${DL}/vixl-${VIXL_VERSION}.tar.gz" -C "${BUILD_DIR}"
    mv "${BUILD_DIR}/vixl-${VIXL_VERSION}" "${BUILD_DIR}/vixl"
    patch -d "${BUILD_DIR}/vixl" -p1 < "${ROOT}/patches/vixl_meson_support.patch"
    meson setup "${BUILD_DIR}/vixl/build" "${BUILD_DIR}/vixl" \
        --prefix="${PREFIX}" --libdir=lib --buildtype=release -Dsimulator=none
    ninja -C "${BUILD_DIR}/vixl/build" -j"${JOBS}" install
    done_stamp "vixl-${VIXL_VERSION}"
    rm -rf "${BUILD_DIR}/vixl"
fi

# --- 4b. libunwind >= 1.8 (bionic_translation requires it; noble has 1.6) --

if ! stamp "libunwind-${LIBUNWIND_VERSION}"; then
    log "building libunwind ${LIBUNWIND_VERSION}"
    fetch "https://github.com/libunwind/libunwind/releases/download/v${LIBUNWIND_VERSION}/libunwind-${LIBUNWIND_VERSION}.tar.gz" \
          "${LIBUNWIND_SHA256}" "libunwind-${LIBUNWIND_VERSION}.tar.gz"
    rm -rf "${BUILD_DIR}/libunwind"
    tar -xf "${DL}/libunwind-${LIBUNWIND_VERSION}.tar.gz" -C "${BUILD_DIR}"
    mv "${BUILD_DIR}/libunwind-${LIBUNWIND_VERSION}" "${BUILD_DIR}/libunwind"
    (
        cd "${BUILD_DIR}/libunwind"
        ./configure --prefix="${PREFIX}" --disable-tests --disable-documentation
        make -j"${JOBS}"
        make install
    )
    done_stamp "libunwind-${LIBUNWIND_VERSION}"
    rm -rf "${BUILD_DIR}/libunwind"
fi

# --- 5. bionic_translation ------------------------------------------------

if ! stamp "bionic_translation-${BIONIC_REV}"; then
    log "building bionic_translation"
    rsync -a --delete --exclude=.git "${ROOT}/bionic_translation/" "${BUILD_DIR}/bionic_translation/"
    patch -d "${BUILD_DIR}/bionic_translation" -p1 < "${ROOT}/patches/bionic_translation-ut.patch"
    meson setup "${BUILD_DIR}/bionic_translation/build" "${BUILD_DIR}/bionic_translation" \
        --prefix="${PREFIX}" --libdir=lib --buildtype=release
    ninja -C "${BUILD_DIR}/bionic_translation/build" -j"${JOBS}" install
    done_stamp "bionic_translation-${BIONIC_REV}"
    rm -rf "${BUILD_DIR}/bionic_translation"
fi

# --- 6. art_standalone (ART runtime, dex2oat, dx, boot classpath) ---------

if ! stamp "art_standalone-${ART_REV}"; then
    log "building art_standalone (self-hosted AOSP frankenbuild)"
    rsync -a --delete --exclude=.git "${ROOT}/art_standalone/" "${BUILD_DIR}/art_standalone/"
    # clickable exports ARCH=arm64, but art's envsetup.mk expects uname-style
    # values (aarch64) and maps 'arm64' to 32-bit arm — override explicitly
    make -C "${BUILD_DIR}/art_standalone" -j"${JOBS}" \
        ARCH="$(uname -m)" ____PREFIX="${PREFIX}" ____LIBDIR=lib
    make -C "${BUILD_DIR}/art_standalone" \
        ARCH="$(uname -m)" ____PREFIX="${PREFIX}" ____LIBDIR=lib install
    done_stamp "art_standalone-${ART_REV}"
    rm -rf "${BUILD_DIR}/art_standalone"
fi

# --- 7. atlas ---------------------------------------------------------------

# Always rsync so source changes in the submodule are picked up; the skia
# subproject clone (fetched by meson wrap on first setup) is preserved.
log "building atlas"
rsync -a --delete \
    --exclude=.git --exclude=/builddir --exclude=/subprojects/skia \
    "${ROOT}/atl-touch/" "${BUILD_DIR}/atlas-src/"
if [ ! -f "${BUILD_DIR}/atlas-build/build.ninja" ]; then
    meson setup "${BUILD_DIR}/atlas-build" "${BUILD_DIR}/atlas-src" \
        --prefix="${CLICK_PREFIX}" --libdir=lib --buildtype=release
fi
ninja -C "${BUILD_DIR}/atlas-build" -j"${JOBS}"
rm -rf "${BUILD_DIR}/atlas-dest"
DESTDIR="${BUILD_DIR}/atlas-dest" ninja -C "${BUILD_DIR}/atlas-build" install

# --- 8. AnkiDroid APK -------------------------------------------------------

fetch "${APK_URL}" "${APK_SHA256}" "AnkiDroid-${ANKIDROID_VERSION}-${APK_ABI}.apk"

# --- 9. assemble the click package tree -------------------------------------

log "assembling click tree in ${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}/usr"

# atlas (built with the click runtime prefix)
cp -a "${BUILD_DIR}/atlas-dest${CLICK_PREFIX}/." "${INSTALL_DIR}/usr/"

# staged runtime: art, boot classpath, wolfssl, glfw, wpe, bionic libs, ...
rsync -a \
    --exclude='pkgconfig' --exclude='cmake' \
    --exclude='*.a' --exclude='*.la' \
    "${PREFIX}/lib/" "${INSTALL_DIR}/usr/lib/"
if [ -d "${PREFIX}/libexec" ]; then
    rsync -a "${PREFIX}/libexec/" "${INSTALL_DIR}/usr/libexec/"
fi
if [ -d "${PREFIX}/share/bionic_translation" ]; then
    rsync -a "${PREFIX}/share/bionic_translation" "${INSTALL_DIR}/usr/share/"
fi

# WPE bakes ${PREFIX} into libWPEWebKit (pkglibexecdir etc.) and only honors
# WEBKIT_EXEC_PATH with DEVELOPER_MODE builds; rewrite it to the click prefix
python3 "${ROOT}/scripts/patch-baked-paths.py" "${PREFIX}" "${CLICK_PREFIX}" \
    "${INSTALL_DIR}"/usr/lib/libWPEWebKit-2.0.so.*.*.*
# dex2oat so the device can AOT-compile if our prebuilt oat files are unusable
install -D "${PREFIX}/bin/dex2oat" "${INSTALL_DIR}/usr/bin/dex2oat"
# not needed at runtime
rm -f "${INSTALL_DIR}/usr/lib/java/dx.jar"

# Java trust store for TLS (wolfssljni looks in $JAVA_HOME/lib/security)
install -D /etc/ssl/certs/java/cacerts \
    "${INSTALL_DIR}/usr/share/java_home/lib/security/cacerts"

# the app itself
install -D "${DL}/AnkiDroid-${ANKIDROID_VERSION}-${APK_ABI}.apk" \
    "${INSTALL_DIR}/usr/share/ankidroid/AnkiDroid.apk"

# bundle every shared-library dependency that is not part of the UT rootfs
"${ROOT}/scripts/copy-runtime-libs.sh" "${INSTALL_DIR}"

# strip (before AOT so we never touch the generated oat files)
find "${INSTALL_DIR}/usr" -type f \( -name '*.so' -o -name '*.so.*' \) \
    -exec strip --strip-unneeded {} + 2>/dev/null || true
strip --strip-unneeded "${INSTALL_DIR}/usr/bin/android-translation-layer" \
    "${INSTALL_DIR}/usr/bin/dex2oat" 2>/dev/null || true

# click metadata + launcher
install -m 0644 "${ROOT}/manifest.json"       "${INSTALL_DIR}/manifest.json"
install -m 0644 "${ROOT}/${APP_HOOK}.apparmor" "${INSTALL_DIR}/"
install -m 0644 "${ROOT}/${APP_HOOK}.desktop"  "${INSTALL_DIR}/"
install -m 0644 "${ROOT}/${APP_HOOK}.png"      "${INSTALL_DIR}/"
install -m 0755 "${ROOT}/${APP_HOOK}.sh"       "${INSTALL_DIR}/"

# --- 10. AOT-compile boot classpath, api-impl and the APK (best effort) -----
# Mirrors the flathub BaseApp/NewPipe run-dex2oat modules. dex locations use
# the version-independent 'current' click path so they stay valid on device.
# If anything here fails (e.g. dex2oat unhappy under qemu) the package still
# works: ART falls back to JIT/interpreter and on-device dex2oat.

if [ "${ATLAS_CLICK_SKIP_AOT:-0}" != "1" ]; then
    log "AOT compiling (dex2oat) — best effort"
    ARTLIB="${INSTALL_DIR}/usr/lib/java/dex/art"
    ATLLIB="${INSTALL_DIR}/usr/lib/java/dex/android_translation_layer"
    (
        set -e
        export LD_LIBRARY_PATH="${PREFIX}/lib/art:${PREFIX}/lib"
        BOOT_JARS=(core-oj-hostdex apachehttp-hostdex apache-xml-hostdex \
                   bouncycastle-hostdex core-junit-hostdex core-libart-hostdex \
                   hamcrest-hostdex junit-runner-hostdex okhttp-hostdex \
                   wolfssljni-hostdex)
        DEX_ARGS=()
        for jar in "${BOOT_JARS[@]}"; do
            DEX_ARGS+=(--dex-file="${ARTLIB}/${jar}.jar" \
                       --dex-location="${CLICK_PREFIX}/lib/java/dex/art/${jar}.jar")
        done
        mkdir -p "${ARTLIB}/oat/${ART_ARCH}" "${ATLLIB}/oat/${ART_ARCH}" \
                 "${INSTALL_DIR}/usr/share/ankidroid/oat/${ART_ARCH}"
        "${PREFIX}/bin/dex2oat" -j1 \
            --image="${ARTLIB}/oat/${ART_ARCH}/boot.art" \
            "${DEX_ARGS[@]}" \
            --oat-file="${ARTLIB}/oat/${ART_ARCH}/boot.oat" \
            --base=0x60cf8000 --host
        chmod +x "${ARTLIB}/oat/${ART_ARCH}/"*.oat
        "${PREFIX}/bin/dex2oat" -j"${JOBS}" \
            --boot-image="${ARTLIB}/oat/${ART_ARCH}/boot.art" \
            --dex-file="${ATLLIB}/api-impl.jar" \
            --dex-location="${CLICK_PREFIX}/lib/java/dex/android_translation_layer/api-impl.jar" \
            --oat-file="${ATLLIB}/oat/${ART_ARCH}/api-impl.odex" \
            --host
        "${PREFIX}/bin/dex2oat" -j"${JOBS}" \
            --boot-image="${ARTLIB}/oat/${ART_ARCH}/boot.art" \
            --dex-file="${INSTALL_DIR}/usr/share/ankidroid/AnkiDroid.apk" \
            --dex-location="${CLICK_PREFIX}/share/ankidroid/AnkiDroid.apk" \
            --oat-file="${INSTALL_DIR}/usr/share/ankidroid/oat/${ART_ARCH}/AnkiDroid.odex" \
            --host
        chmod +x "${ATLLIB}/oat/${ART_ARCH}/"*.odex \
                 "${INSTALL_DIR}/usr/share/ankidroid/oat/${ART_ARCH}/"*.odex
    ) || {
        log "WARNING: dex2oat AOT pass failed — shipping without prebuilt oat files"
        rm -rf "${INSTALL_DIR}/usr/lib/java/dex/art/oat" \
               "${INSTALL_DIR}/usr/lib/java/dex/android_translation_layer/oat" \
               "${INSTALL_DIR}/usr/share/ankidroid/oat"
    }
fi

log "done — $(du -sh "${INSTALL_DIR}" | cut -f1) in ${INSTALL_DIR}"
