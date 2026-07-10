# AnkiDroid for Ubuntu Touch (via atlas)

Clickable packaging that runs the stock [AnkiDroid](https://github.com/ankidroid/Anki-Android)
Android APK on Ubuntu Touch through **atlas**, a fork of
[android_translation_layer](https://gitlab.com/android_translation_layer/android_translation_layer)
(ATL) ported to run without GTK on Lomiri/Mir.

The structure mirrors how NewPipe was packaged for flatpak
([net.newpipe.NewPipe](https://github.com/flathub/net.newpipe.NewPipe) on top of
[io.gitlab.android_translation_layer.BaseApp](https://github.com/flathub/io.gitlab.android_translation_layer.BaseApp)),
except that the whole runtime chain is built here, inside the clickable
container, and shipped in one click package:

| component | origin | role |
|---|---|---|
| `atl-touch/` (submodule) | fork of ATL | the translation layer itself |
| `art_standalone/` (submodule) | upstream ATL project | ART runtime, `dex2oat`, `dx`, boot classpath |
| `bionic_translation/` (submodule) | upstream ATL project | bionic→glibc linker/libc shims |
| `wolfssl/` (submodule) | upstream wolfSSL | TLS with JNI enabled (distro build has it off) |
| GLFW 3.4 | tarball (pinned in `build.sh`) | windowing; noble only ships 3.3 |
| libwpe / wpebackend-fdo / WPE WebKit | tarballs (pinned) | WebView backend; not packaged in noble at all |
| vixl 8.0.0 | tarball + flathub meson patch | ARM codegen for the art compiler |
| AnkiDroid APK | GitHub release (pinned) | the app |

## Prerequisites

* [clickable](https://clickable-ut.dev/) ≥ 8 and docker.
* **The build runs in a native arm64 container.** `art_standalone` only
  supports self-hosted builds (no cross-compilation), so `clickable.yaml`
  pins `docker_image: clickable/arm64-ut24.04-1.x-arm64`. On an x86_64 host
  you need qemu-user binfmt support:

  ```sh
  sudo apt install qemu-user-static binfmt-support   # Debian/Ubuntu hosts
  ls /proc/sys/fs/binfmt_misc/ | grep qemu-aarch64   # must show up
  ```

* Disk: ~40 GB of build tree (WPE WebKit dominates). RAM: ≥16 GB recommended.

## Building

```sh
git clone --recurse-submodules <this repo>
cd ankidroid-click-packaging
clickable build --arch arm64
```

Be prepared for the **first build to take many hours** on an x86_64 host —
WPE WebKit, ART and skia all compile under qemu emulation. Every stage is
stamped and cached under `build/`, so iterating on atlas or the packaging
afterwards is cheap (only atlas rebuilds).

Useful knobs:

* `ATLAS_CLICK_SKIP_AOT=1 clickable build ...` — skip the (qemu-slow)
  `dex2oat` ahead-of-time pass; the device then JIT/AOT-compiles on first
  launch instead.
* `clickable build --verbose` for the full log.

Install on the device with `clickable install` (or copy the `.click` from
`build/` and `pkcon install-local --allow-untrusted <pkg>.click`).

## How the pieces fit

* Everything is staged into `build/.../stage/usr` during the build, then
  copied into the click under `usr/`. `scripts/copy-runtime-libs.sh` walks
  `ldd` over all shipped binaries and bundles every dependency that is not
  guaranteed on the UT rootfs (glibc, GL/wayland/audio stacks are excluded).
* atlas itself is configured with
  `--prefix=/opt/click.ubuntu.com/ankidroid.nekit/current/usr` — click keeps
  a version-independent `current` symlink, so compiled-in paths (rpath,
  fonts.xml data dir) resolve on the device across package upgrades.
* At runtime `ankidroid.sh` sets `LD_LIBRARY_PATH`, `JAVA_HOME` (TLS trust
  store for wolfssljni), `WEBKIT_EXEC_PATH`/`WEBKIT_INJECTED_BUNDLE_PATH`
  (bundled WPE) and launches
  `android-translation-layer .../AnkiDroid.apk`. ART finds the boot
  classpath relative to wherever `libart.so` was loaded from.
* Like the flathub NewPipe package, `build.sh` ends with a best-effort
  `dex2oat` pass that AOT-compiles the boot classpath, `api-impl.jar` and
  the APK with dex locations pointing at the `current` click path.

## Updating AnkiDroid

Bump `ANKIDROID_VERSION` + `APK_SHA256` in `build.sh` and `version` in
`manifest.json`.

## Known caveats / TODO

* **The `atl-touch` submodule URL (`https://github.com/NotKit/atl-touch.git`) is a
  placeholder** — the local atlas (atl-touch) working tree has commits that
  exist nowhere public yet. Push the fork and adjust `.gitmodules` if the
  URL differs.
* amd64 builds are plumbed (APK variant mapping, no vixl) but untested and
  currently disabled (`restrict_arch: arm64`); the amd64 APK sha256 is not
  filled in either.
* atlas creates its window through GLFW and does not set a Wayland `app_id`
  matching the click hook (`ankidroid.nekit_ankidroid_...`), which Lomiri
  uses to associate windows with launchers. If the window doesn't appear or
  shows as an unknown app, atlas needs a small patch to set
  `GLFW_WAYLAND_APP_ID` (GLFW 3.4 supports it; we already build 3.4).
* Media playback in cards relies on the device's GStreamer plugin set.
* First launch without the AOT pass is slow (on-device dex2oat).
* `libopensles-standalone` is not bundled (AnkiDroid doesn't seem to need
  OpenSL ES; add it as another submodule if some app does).
