#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_ROOT="$ROOT/tmp/system"

mkdir -p "$TMP_ROOT"
export TMPDIR="$TMP_ROOT"

if [[ -d "$ROOT/ns-3.47" && "${SKIP_NS3:-0}" != "1" ]]; then
  "$ROOT/sim/ns3/run_ns3_sweep.sh"
fi

"$ROOT/sim/aaa_sweep.py"
"$ROOT/report/build_report.sh"
