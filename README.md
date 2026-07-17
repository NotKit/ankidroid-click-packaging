# AnkiDroid for Ubuntu Touch (via atl-touch)

Clickable packaging that runs the stock [AnkiDroid](https://github.com/ankidroid/Anki-Android)
Android APK on Ubuntu Touch through **atl-touch**, a fork of
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
| Qt 6.10 WebEngine | system packages (24.04-2.x archive) | WebView backend (`libatl_webview_qt.so`, built by atlas' meson) |
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

* Disk: ~15 GB of build tree. RAM: ≥16 GB recommended.

## Building

```sh
git clone --recurse-submodules <this repo>
cd ankidroid-click-packaging
clickable build --arch arm64
```

Be prepared for the **first build to take a few hours** on an x86_64 host —
ART and skia compile under qemu emulation. Every stage is
stamped and cached under `build/`, so iterating on atl-touch or the packaging
afterwards is cheap (only atl-touch rebuilds).

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
* atl-touch itself is configured with
  `--prefix=/opt/click.ubuntu.com/ankidroid.nekit/current/usr` — click keeps
  a version-independent `current` symlink, so compiled-in paths (rpath,
  fonts.xml data dir) resolve on the device across package upgrades.
* At runtime `ankidroid.sh` sets `LD_LIBRARY_PATH`, `JAVA_HOME` (TLS trust
  store for wolfssljni), `ATL_WEBVIEW_MODULE=qt` (system Qt WebEngine
  WebView backend, with the bundled xdg-shell QPA plugin on `QT_PLUGIN_PATH`)
  and launches
  `android-translation-layer .../AnkiDroid.apk`. ART finds the boot
  classpath relative to wherever `libart.so` was loaded from.
* Like the flathub NewPipe package, `build.sh` ends with a best-effort
  `dex2oat` pass that AOT-compiles the boot classpath, `api-impl.jar` and
  the APK with dex locations pointing at the `current` click path.

## CI

`.github/workflows/build.yml` builds the click on GitHub's native
`ubuntu-24.04-arm` runners (no qemu) and uploads the `.click` as an
artifact. The staged toolchain (`stage/`, `stamps/`, `downloads/`, the skia
checkout) is carried between runs with `actions/cache`, saved even on
failure/timeout, so an interrupted first build resumes instead of starting
over. Stage stamps are suffixed with the pinned version (or submodule
commit), so bumping a version in `build.sh` invalidates exactly that stage.

Note: CI can only work once the `atl-touch` submodule URL in `.gitmodules`
points at a published repository.

## Updating AnkiDroid

Bump `ANKIDROID_VERSION` + `APK_SHA256` in `build.sh` and `version` in
`manifest.json`.

## Known caveats / TODO

* **The `atl-touch` submodule URL (`https://github.com/NotKit/atl-touch.git`) is a
  placeholder** — the local atl-touch working tree has commits that
  exist nowhere public yet. Push the fork and adjust `.gitmodules` if the
  URL differs.
* amd64 builds are plumbed (APK variant mapping, no vixl) but untested and
  currently disabled (`restrict_arch: arm64`); the amd64 APK sha256 is not
  filled in either.
* Device status (2026-07-11, UT 24.04/arm64, tested on two devices):
  **AnkiDroid runs interactively** — boots to the UI at the correct scale,
  touch input works, and text entry works through the on-screen keyboard
  (soft keyboard with predictive/composing text, auto-hide on focus loss).
  First launch spends ~15 s in on-device dex2oat (then cached). All the
  device enablement now lives in the `atl-touch` submodule (GLES context +
  ES2 blit, wl_touch input, GRID_UNIT_PX density, Maliit soft keyboard) and
  in `patches/bionic_translation-ut.patch` (reject wrong-arch ELFs so the
  linker doesn't parse the Halium container's 32-bit `/system/lib` libs).
  The launcher supplies `XDG_DATA_DIRS` (cfg.d overrides) and `$APP_ID`.
  Untested yet: WebView card rendering, content-hub import, multi-touch.
* The soft keyboard uses the Maliit D-Bus interface (Lomiri/SailfishOS
  drive the keyboard that way, not over a wayland text-input protocol);
  atl-touch's input-method backend is pluggable, so a `zwp_text_input_v3`
  backend can be added for desktop wayland shells. `libmaliit-glib-dev` is
  a build dependency; `ATL_IM_MODULE=none` disables the keyboard.
* The shipped AOT files (`oat/arm64/*.oat`) are not picked up by this art
  revision because dex2oat in the container refuses to write the `boot.art`
  image ("image compilation disabled"); the device regenerates everything
  into `~/.cache/art` on first launch instead. Harmless, ~30 MB dead weight.
* Media playback in cards relies on the device's GStreamer plugin set.
* First launch without the AOT pass is slow (on-device dex2oat).
* `libopensles-standalone` is not bundled (AnkiDroid doesn't seem to need
  OpenSL ES; add it as another submodule if some app does).
