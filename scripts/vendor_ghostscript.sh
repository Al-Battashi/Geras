#!/usr/bin/env bash
set -euo pipefail

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew not found. Install from https://brew.sh first." >&2
  exit 1
fi

if ! command -v install_name_tool >/dev/null 2>&1; then
  echo "install_name_tool not found. Install Xcode Command Line Tools (or finish Xcode install)." >&2
  exit 1
fi

brew install ghostscript

GS_PREFIX="$(brew --prefix ghostscript)"
GS_BIN="$GS_PREFIX/bin/gs"
GS_LIB_DIR="$GS_PREFIX/lib"
GS_SHARE_DIR="$GS_PREFIX/share/ghostscript"

if [ ! -f "$GS_BIN" ]; then
  echo "ghostscript binary not found at $GS_BIN" >&2
  exit 1
fi

DEST_ROOT="$PWD/Vendor/ghostscript"
DEST_BIN="$DEST_ROOT/gs"
DEST_LIB="$DEST_ROOT/lib"
DEST_SHARE="$DEST_ROOT/share"

mkdir -p "$DEST_LIB" "$DEST_SHARE"
rm -f "$DEST_BIN"
rm -rf "$DEST_SHARE/ghostscript"
rm -f "$DEST_LIB"/*.dylib

cp "$GS_BIN" "$DEST_BIN"
chmod +x "$DEST_BIN"
cp -a "$GS_SHARE_DIR" "$DEST_SHARE/"

for lib in "$GS_LIB_DIR"/libgs*.dylib; do
  if [ -f "$lib" ]; then
    base=$(basename "$lib")
    cp -aL "$lib" "$DEST_LIB/$base"
  fi
done

queue=("$DEST_BIN")
while [ "${#queue[@]}" -gt 0 ]; do
  file="${queue[0]}"
  queue=("${queue[@]:1}")

  deps=$(otool -L "$file" | tail -n +2 | awk '{print $1}')
  for dep in $deps; do
    base=$(basename "$dep")

    if [[ "$dep" == /opt/homebrew/* ]]; then
      if [ ! -f "$DEST_LIB/$base" ]; then
        cp -aL "$dep" "$DEST_LIB/$base"
        queue+=("$DEST_LIB/$base")
      fi
      if [ "$file" = "$DEST_BIN" ]; then
        install_name_tool -change "$dep" "@loader_path/lib/$base" "$file" || true
      else
        install_name_tool -change "$dep" "@loader_path/$base" "$file" || true
      fi
    elif [[ "$dep" == @rpath/* ]]; then
      if [ ! -f "$DEST_LIB/$base" ] && [ -f "/opt/homebrew/lib/$base" ]; then
        cp -aL "/opt/homebrew/lib/$base" "$DEST_LIB/$base"
        queue+=("$DEST_LIB/$base")
      fi
      if [ -f "$DEST_LIB/$base" ]; then
        if [ "$file" = "$DEST_BIN" ]; then
          install_name_tool -change "$dep" "@loader_path/lib/$base" "$file" || true
        else
          install_name_tool -change "$dep" "@loader_path/$base" "$file" || true
        fi
      fi
    fi
  done
done

for lib in "$DEST_LIB"/*.dylib; do
  if [ -f "$lib" ]; then
    install_name_tool -id "@loader_path/$(basename "$lib")" "$lib"
    libdeps=$(otool -L "$lib" | tail -n +2 | awk '{print $1}')
    for libdep in $libdeps; do
      base=$(basename "$libdep")
      if [[ "$libdep" == /opt/homebrew/* ]]; then
        install_name_tool -change "$libdep" "@loader_path/$base" "$lib" || true
      fi
      if [[ "$libdep" == @rpath/* ]]; then
        if [ ! -f "$DEST_LIB/$base" ] && [ -f "/opt/homebrew/lib/$base" ]; then
          cp -aL "/opt/homebrew/lib/$base" "$DEST_LIB/$base"
        fi
        if [ -f "$DEST_LIB/$base" ]; then
          install_name_tool -change "$libdep" "@loader_path/$base" "$lib" || true
        fi
      fi
    done
  fi
done

if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - "$DEST_BIN"
  for lib in "$DEST_LIB"/*.dylib; do
    if [ -f "$lib" ]; then
      codesign --force --sign - "$lib"
    fi
  done
fi

echo "Vendored ghostscript to $DEST_ROOT"
