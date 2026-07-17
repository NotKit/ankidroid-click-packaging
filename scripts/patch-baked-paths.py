#!/usr/bin/env python3
"""Rewrite an absolute path prefix baked into a binary.

WPE WebKit compiles its install prefix into libWPEWebKit (pkglibexecdir,
injected-bundle dir, localedir) and ignores WEBKIT_EXEC_PATH unless built
with DEVELOPER_MODE. Rather than rebuild, rewrite the stage prefix to the
click runtime prefix in place. The new prefix must not be longer than the
old one: strings are NUL-padded so no offsets change.

Usage: patch-baked-paths.py <old-prefix> <new-prefix> <file>...
"""
import sys

old, new = sys.argv[1].encode(), sys.argv[2].encode()
if len(new) > len(old):
    sys.exit(f"new prefix is longer than old ({len(new)} > {len(old)})")

for path in sys.argv[3:]:
    with open(path, "rb") as f:
        data = bytearray(f.read())
    count = 0
    i = 0
    while True:
        i = data.find(old, i)
        if i < 0:
            break
        end = data.find(b"\0", i)
        old_str = bytes(data[i:end])
        new_str = new + old_str[len(old):]
        data[i:end] = new_str + b"\0" * (len(old_str) - len(new_str))
        count += 1
        i = end
    if count:
        with open(path, "wb") as f:
            f.write(data)
    print(f"{path}: {count} strings patched")
