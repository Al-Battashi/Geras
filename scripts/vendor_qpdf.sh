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

brew install qpdf

QPDF_PREFIX="$(brew --prefix qpdf)"
QPDF_BIN="$QPDF_PREFIX/bin/qpdf"
QPDF_LIB_DIR="$QPDF_PREFIX/lib"
JPEG_PREFIX="$(brew --prefix jpeg-turbo)"
JPEG_LIB_DIR="$JPEG_PREFIX/lib"

if [ ! -f "$QPDF_BIN" ]; then
  echo "qpdf binary not found at $QPDF_BIN" >&2
  exit 1
fi

DEST_ROOT="$PWD/Vendor/qpdf"
DEST_BIN="$DEST_ROOT/qpdf"
DEST_LIB="$DEST_ROOT/lib"

mkdir -p "$DEST_LIB"
rm -f "$DEST_BIN"
rm -f "$DEST_LIB"/libqpdf*.dylib
cp "$QPDF_BIN" "$DEST_BIN"
chmod +x "$DEST_BIN"

if [ -f "$QPDF_LIB_DIR/libqpdf.30.dylib" ]; then
  cp -a "$QPDF_LIB_DIR/libqpdf.30.dylib" "$DEST_LIB/"
fi
if [ -f "$QPDF_LIB_DIR/libqpdf.30.3.2.dylib" ]; then
  cp -a "$QPDF_LIB_DIR/libqpdf.30.3.2.dylib" "$DEST_LIB/"
fi
jpeg_real=$(ls "$JPEG_LIB_DIR"/libjpeg.8*.dylib 2>/dev/null | head -n 1 || true)
if [ -n "$jpeg_real" ] && [ -f "$jpeg_real" ]; then
  jpeg_base=$(basename "$jpeg_real")
  cp -a "$jpeg_real" "$DEST_LIB/"
  ln -sf "$jpeg_base" "$DEST_LIB/libjpeg.8.dylib"
fi

deps=$(otool -L "$QPDF_BIN" | tail -n +2 | awk '{print $1}')

for dep in $deps; do
  if [[ "$dep" == /opt/homebrew/* ]]; then
    cp -a "$dep" "$DEST_LIB/"
  fi
done

for lib in "$DEST_LIB"/*; do
  if [ -f "$lib" ]; then
    install_name_tool -id "@loader_path/$(basename "$lib")" "$lib"
  fi
done

for dep in $deps; do
  base=$(basename "$dep")
  if [[ "$dep" == /opt/homebrew/* ]]; then
    install_name_tool -change "$dep" "@loader_path/lib/$base" "$DEST_BIN"
  fi
  if [[ "$dep" == @rpath/* ]] && [ -f "$DEST_LIB/$base" ]; then
    install_name_tool -change "$dep" "@loader_path/lib/$base" "$DEST_BIN"
  fi
done

for lib in "$DEST_LIB"/*; do
  if [ -f "$lib" ]; then
    libdeps=$(otool -L "$lib" | tail -n +2 | awk '{print $1}')
    for libdep in $libdeps; do
      if [[ "$libdep" == /opt/homebrew/* ]]; then
        base=$(basename "$libdep")
        if [ ! -f "$DEST_LIB/$base" ]; then
          cp -a "$libdep" "$DEST_LIB/"
        fi
        install_name_tool -change "$libdep" "@loader_path/$base" "$lib"
      fi
      if [[ "$libdep" == @rpath/* ]]; then
        base=$(basename "$libdep")
        if [ -f "$DEST_LIB/$base" ]; then
          install_name_tool -change "$libdep" "@loader_path/$base" "$lib"
        fi
      fi
    done
  fi
done

for lib in "$DEST_LIB"/*; do
  if [ -f "$lib" ]; then
    install_name_tool -id "@loader_path/$(basename "$lib")" "$lib"
    libdeps=$(otool -L "$lib" | tail -n +2 | awk '{print $1}')
    for libdep in $libdeps; do
      base=$(basename "$libdep")
      if [[ "$libdep" == /opt/homebrew/* ]]; then
        install_name_tool -change "$libdep" "@loader_path/$base" "$lib"
      fi
      if [[ "$libdep" == @rpath/* ]] && [ -f "$DEST_LIB/$base" ]; then
        install_name_tool -change "$libdep" "@loader_path/$base" "$lib"
      fi
    done
  fi
done

if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - "$DEST_BIN"
  for lib in "$DEST_LIB"/*; do
    if [ -f "$lib" ]; then
      codesign --force --sign - "$lib"
    fi
  done
fi

echo "Vendored qpdf to $DEST_ROOT"
