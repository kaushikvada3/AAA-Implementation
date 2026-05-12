#!/usr/bin/env python3
"""
Offline post-mortem diff: take a UART transcript captured from the FPGA
(17 bytes per Bob-received round = 16 key bytes + 1 status byte) and
verify each round against the C-reference snapshot.

Use when hil_send_packets reported failures and you want to inspect the
raw bytes without re-running the board.

    python scripts/hil_verify.py --transcript run.bin --vectors tb/vectors
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

KEY_BYTES = 16
RECORD_SIZE = KEY_BYTES + 1


def read_hex_bytes(path: Path, expected: int | None = None) -> bytes:
    out = bytearray()
    with path.open("r") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith(("//", "#")):
                continue
            out.append(int(line, 16) & 0xFF)
    if expected is not None and len(out) != expected:
        raise ValueError(f"{path}: expected {expected} bytes, got {len(out)}")
    return bytes(out)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--transcript", type=Path, required=True,
                    help="Raw binary capture from the FPGA UART (one 17-byte "
                         "record per Bob-received round, in order)")
    ap.add_argument("--vectors", type=Path, default=Path("tb/vectors"))
    args = ap.parse_args()

    bob_rounds: list[tuple[int, int]] = []
    with (args.vectors / "bob_rounds.txt").open() as f:
        for line in f:
            parts = line.split()
            if len(parts) >= 2:
                bob_rounds.append((int(parts[0]), int(parts[1])))

    raw = args.transcript.read_bytes()
    n_records = len(raw) // RECORD_SIZE
    if n_records < len(bob_rounds):
        print(f"WARNING: transcript has only {n_records} records, "
              f"reference has {len(bob_rounds)} rounds")

    errors = 0
    first_secure = 0

    for i, (rnd, _eve_rx) in enumerate(bob_rounds[:n_records]):
        rec = raw[i * RECORD_SIZE:(i + 1) * RECORD_SIZE]
        got_key = rec[:KEY_BYTES]
        status  = rec[KEY_BYTES]
        expected = read_hex_bytes(args.vectors / f"key_{rnd:04d}.hex", KEY_BYTES)

        if status & 0x01 and not first_secure:
            first_secure = rnd

        if got_key != expected:
            errors += 1
            print(f"Round {rnd}  MISMATCH")
            print(f"  got      {got_key.hex().upper()}")
            print(f"  expected {expected.hex().upper()}")

    print(f"\nrounds_checked={min(n_records, len(bob_rounds))}  "
          f"errors={errors}  first_secure_round={first_secure or 'never'}")
    return 0 if errors == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
