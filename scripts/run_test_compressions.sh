#!/usr/bin/env bash
set -euo pipefail

ROOT="$PWD"
INPUT="$ROOT/Chemistry - Steve Owen - Third Edition - Cambridge 2023.pdf"
QPDF="$ROOT/Vendor/qpdf/qpdf"
OUT_DIR="$ROOT/_test_outputs"

if [ ! -f "$INPUT" ]; then
  echo "Input PDF not found: $INPUT" >&2
  exit 1
fi

if [ ! -x "$QPDF" ]; then
  echo "qpdf not found at $QPDF. Run scripts/vendor_qpdf.sh first." >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

base_size=$(stat -f%z "$INPUT")
base_label=$(python3 - "$base_size" <<'PY'
import sys
size=int(sys.argv[1])
for unit in ['B','KB','MB','GB','TB']:
    if size < 1024:
        print(f"{size:.1f} {unit}")
        break
    size/=1024
PY
)

echo "Input: $INPUT"
echo "Size : $base_label"

run_case() {
  name="$1"
  shift
  out="$OUT_DIR/${name}.pdf"
  echo "\n== $name =="
  "$QPDF" "$@" -- "$INPUT" "$out"
  out_size=$(stat -f%z "$out")
  ratio=$(python3 - "$base_size" "$out_size" <<'PY'
import sys
inp=float(sys.argv[1])
out=float(sys.argv[2])
ratio=(1.0 - out/inp)*100.0
print(f"{ratio:.1f}")
PY
)
  out_label=$(python3 - "$out_size" <<'PY'
import sys
size=int(sys.argv[1])
for unit in ['B','KB','MB','GB','TB']:
    if size < 1024:
        print(f"{size:.1f} {unit}")
        break
    size/=1024
PY
)
  echo "Output: $out_label (saved ${ratio}%)"
}

run_case "fast" \
  --stream-data=compress \
  --compression-level=3 \
  --object-streams=generate

run_case "balanced" \
  --stream-data=compress \
  --recompress-flate \
  --compression-level=7 \
  --object-streams=generate

run_case "max" \
  --stream-data=compress \
  --recompress-flate \
  --compression-level=9 \
  --object-streams=generate \
  --optimize-images

echo "\nOutputs saved to $OUT_DIR"
