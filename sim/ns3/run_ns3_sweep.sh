#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NS3_DIR="${NS3_DIR:-$ROOT/ns-3.47}"
SCRATCH_SRC="$ROOT/sim/ns3/aaa_distance_sweep.cc"
SCRATCH_DST="$NS3_DIR/scratch/aaa_distance_sweep.cc"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/sim/output/ns3}"
TMP_ROOT="$ROOT/tmp/system"
DISTANCES="${DISTANCES:-10,15,20,25,30,35,40,45,50,55,60,65,70,75,80,85,90}"
BOB_DISTANCE="${BOB_DISTANCE:-18}"
NUM_PACKETS="${NUM_PACKETS:-400}"
INTERVAL_MS="${INTERVAL_MS:-10}"
PACKET_SIZE="${PACKET_SIZE:-512}"
TX_POWER_DBM="${TX_POWER_DBM:--3}"
PATH_LOSS_EXPONENT="${PATH_LOSS_EXPONENT:-2.35}"
REFERENCE_LOSS="${REFERENCE_LOSS:-40.0893182554}"
RNG_SEED="${RNG_SEED:-7}"

mkdir -p "$OUTPUT_DIR" "$TMP_ROOT"
export TMPDIR="$TMP_ROOT"

if [[ ! -d "$NS3_DIR" ]]; then
  echo "ns-3 directory not found at $NS3_DIR" >&2
  exit 1
fi

install -m 0644 "$SCRATCH_SRC" "$SCRATCH_DST"

cd "$NS3_DIR"
./ns3 configure --build-profile=optimized --disable-werror >/dev/null

IFS=',' read -r -a distance_array <<< "$DISTANCES"
for idx in "${!distance_array[@]}"; do
  distance="$(echo "${distance_array[$idx]}" | xargs)"
  if [[ -z "$distance" ]]; then
    continue
  fi
  output_csv="$OUTPUT_DIR/ns3_rounds_eve_${distance//./_}m.csv"
  ./ns3 run "scratch/aaa_distance_sweep --bobDistance=$BOB_DISTANCE --eveDistance=$distance --numPackets=$NUM_PACKETS --intervalMs=$INTERVAL_MS --packetSize=$PACKET_SIZE --txPowerDbm=$TX_POWER_DBM --pathLossExponent=$PATH_LOSS_EXPONENT --referenceLoss=$REFERENCE_LOSS --seed=$RNG_SEED --run=$((idx + 1)) --outputCsv=$output_csv" >/dev/null
  echo "wrote $output_csv"
done
