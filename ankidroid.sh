#!/bin/sh
# Launcher: run AnkiDroid through the bundled atlas runtime.

APP_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
PKG_NAME=ankidroid.nekit

# Prefer the version-independent 'current' click path: compiled-in rpaths
# and the AOT dex locations point there. Fall back to our own directory
# (e.g. when running from an unpacked tree on a desktop).
PKG_ROOT="/opt/click.ubuntu.com/${PKG_NAME}/current"
[ -x "${PKG_ROOT}/usr/bin/android-translation-layer" ] || PKG_ROOT="${APP_DIR}"

export LD_LIBRARY_PATH="${PKG_ROOT}/usr/lib/art:${PKG_ROOT}/usr/lib:${PKG_ROOT}/usr/lib/java/dex/android_translation_layer/natives${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
export PATH="${PKG_ROOT}/usr/bin:${PATH}"

# TLS trust store for wolfssljni ($JAVA_HOME/lib/security/cacerts)
export JAVA_HOME="${PKG_ROOT}/usr/share/java_home"

# WPE WebKit is bundled inside the click
export WEBKIT_EXEC_PATH="${PKG_ROOT}/usr/libexec/wpe-webkit-2.0"
export WEBKIT_INJECTED_BUNDLE_PATH="${PKG_ROOT}/usr/lib/wpe-webkit-2.0/injected-bundle"

# AnkiDroid renders cards in a WebView
export ATL_UGLY_ENABLE_WEBVIEW=1

# Keep app data in one dedicated place
export ANDROID_APP_DATA_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/${PKG_NAME}"
mkdir -p "${ANDROID_APP_DATA_DIR}"

exec "${PKG_ROOT}/usr/bin/android-translation-layer" \
    --gapplication-app-id=${PKG_NAME}_ankidroid \
    "${PKG_ROOT}/usr/share/ankidroid/AnkiDroid.apk" "$@"
