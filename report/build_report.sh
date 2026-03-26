#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/report/build"
FINAL_DIR="$ROOT/output/pdf"
FINAL_PDF="$FINAL_DIR/aaa_secret_key_report.pdf"
RENDER_PREFIX="$ROOT/tmp/pdfs/aaa_secret_key_report"
TMP_ROOT="$ROOT/tmp/system"

mkdir -p "$BUILD_DIR" "$FINAL_DIR" "$ROOT/tmp/pdfs" "$TMP_ROOT"
export TMPDIR="$TMP_ROOT"

cd "$ROOT/report"
latexmk -pdf -interaction=nonstopmode -halt-on-error -file-line-error -outdir="$BUILD_DIR" main.tex
cp "$BUILD_DIR/main.pdf" "$FINAL_PDF"
pdftoppm -png "$FINAL_PDF" "$RENDER_PREFIX" >/dev/null

echo "wrote $FINAL_PDF"
