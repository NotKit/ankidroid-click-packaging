#!/bin/bash
# Copy every shared-library dependency of the packaged binaries into the
# click tree, except libraries guaranteed to exist on the Ubuntu Touch
# rootfs (glibc, GL/EGL drivers, wayland, audio, udev, dbus, systemd).
# Both the build container and the UT 24.04 rootfs are noble-based, so
# shipping a duplicate of a library the device also has is harmless; a
# missing one is fatal — when in doubt we ship it.
set -euo pipefail

INSTALL_DIR="${1:?usage: copy-runtime-libs.sh <install-dir>}"
LIBDIR="${INSTALL_DIR}/usr/lib"

# never ship: loader/libc, GPU/driver stacks, device-specific plumbing, and
# Qt (the whole point of the Qt WebView backend is using the system Qt;
# small transitive Qt deps may still be bundled — harmless duplicates)
BLOCKLIST='^(ld-linux|libc\.so|libm\.so|libdl\.so|libpthread\.so|librt\.so|libresolv\.so|libutil\.so|libgcc_s|libstdc\+\+|libEGL|libGL\.so|libGLX|libGLES|libGLdispatch|libOpenGL|libgbm|libglapi|libdrm|libhybris|libwayland-|libX|libxcb|libxshmfence|libasound|libpulse|libsystemd|libudev\.so|libdbus-1|libapparmor|libselinux|libQt6)'

seen="$(mktemp)"
trap 'rm -f "${seen}"' EXIT

collect() { # collect <elf-file>
    ldd "$1" 2>/dev/null | awk '/=> \//{print $3}' || true
}

# iterate to a fixed point: copied libs can pull in further deps
for _pass in 1 2 3 4 5; do
    changed=0
    while IFS= read -r -d '' elf; do
        for dep in $(collect "${elf}"); do
            base="$(basename "${dep}")"
            grep -qxF "${base}" "${seen}" && continue
            echo "${base}" >> "${seen}"
            [[ "${base}" =~ ${BLOCKLIST} ]] && continue
            # already inside the package?
            [ -e "${LIBDIR}/${base}" ] && continue
            [[ "${dep}" == "${INSTALL_DIR}"/* ]] && continue
            cp -L "${dep}" "${LIBDIR}/${base}"
            echo "  bundled ${base}"
            changed=1
        done
    done < <(find "${INSTALL_DIR}/usr" -type f \
                \( -name '*.so' -o -name '*.so.*' -o -path '*/bin/*' -o -path '*/libexec/*' \) \
                -print0)
    [ "${changed}" = "0" ] && break
    : > "${seen}"   # re-check everything against the grown package
done
