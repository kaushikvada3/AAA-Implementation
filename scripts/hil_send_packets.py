#!/usr/bin/env python3
"""
Hardware-in-the-Loop driver for the AAA engine running on the Arty A7-100T.

Replays every Bob-received round from the 400-round reference run over UART
and verifies the FPGA's per-round key matches the C-reference snapshot.

The vectors directory is produced by tools/gen_rtl_vectors and must exist
before this script runs:

    make -C tools run
    python scripts/hil_send_packets.py --port COM5 \
        --vectors tb/vectors

Wire protocol per packet (host -> FPGA):
    [0xAA][eve_received_byte][512 payload bytes]
And the FPGA replies with:
    [16 key bytes][1 status byte = {7'b0, key_secure}]
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

try:
    import serial
except ImportError:
    print("ERROR: pyserial not installed.  pip install pyserial", file=sys.stderr)
    sys.exit(2)


PAYLOAD_BYTES = 512
KEY_BYTES = 16
SYNC_BYTE = 0xAA


def read_hex_bytes(path: Path, expected: int | None = None) -> bytes:
    """Read $readmemh-format file: one hex byte per line, optional comments."""
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


def load_bob_rounds(vectors_dir: Path) -> list[tuple[int, int]]:
    rows: list[tuple[int, int]] = []
    with (vectors_dir / "bob_rounds.txt").open("r") as f:
        for line in f:
            parts = line.split()
            if len(parts) >= 2:
                rows.append((int(parts[0]), int(parts[1])))
    return rows


def transact(port: serial.Serial, payload: bytes, eve_rx: int) -> tuple[bytes, int]:
    """Send one packet, return (key_bytes, status_byte)."""
    frame = bytes([SYNC_BYTE, eve_rx & 0x01]) + payload
    port.reset_input_buffer()
    port.write(frame)
    port.flush()

    expected = KEY_BYTES + 1
    rx = port.read(expected)
    if len(rx) != expected:
        raise TimeoutError(
            f"Expected {expected} reply bytes from FPGA, got {len(rx)}"
        )
    return rx[:KEY_BYTES], rx[KEY_BYTES]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--port", required=True,
                    help="Serial port (e.g. COM5 on Windows, /dev/ttyUSB1 on Linux)")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--vectors", type=Path, default=Path("tb/vectors"),
                    help="Vector directory produced by tools/gen_rtl_vectors")
    ap.add_argument("--max-rounds", type=int, default=0,
                    help="Stop after N rounds (0 = all)")
    ap.add_argument("--inter-packet-ms", type=int, default=5,
                    help="Idle time between packets to let the FPGA's TX drain")
    args = ap.parse_args()

    vectors = args.vectors.resolve()
    if not (vectors / "bob_rounds.txt").exists():
        print(f"ERROR: {vectors}/bob_rounds.txt not found.  "
              "Run `make -C tools run` first.", file=sys.stderr)
        return 2

    bob_rounds = load_bob_rounds(vectors)
    if args.max_rounds:
        bob_rounds = bob_rounds[:args.max_rounds]

    print(f"[HIL] Opening {args.port} @ {args.baud} baud")
    port = serial.Serial(args.port, args.baud, timeout=2.0, write_timeout=2.0)
    # Toggle DTR to assert/release reset on the board (Arty's CK_RST is wired
    # through the FT2232 bridge; on most setups DTR will reset).
    port.dtr = False
    time.sleep(0.05)
    port.dtr = True
    time.sleep(0.05)

    mismatches = 0
    first_secure_round_obs = 0

    for idx, (rnd, eve_rx) in enumerate(bob_rounds):
        payload_path = vectors / f"payload_{rnd:04d}.hex"
        key_path     = vectors / f"key_{rnd:04d}.hex"
        payload = read_hex_bytes(payload_path, PAYLOAD_BYTES)
        expected_key = read_hex_bytes(key_path, KEY_BYTES)

        try:
            got_key, status = transact(port, payload, eve_rx)
        except TimeoutError as e:
            print(f"[HIL] Round {rnd}: {e}", file=sys.stderr)
            mismatches += 1
            break

        match = (got_key == expected_key)
        secure_bit = status & 0x01
        if secure_bit and not first_secure_round_obs:
            first_secure_round_obs = rnd

        if not match:
            mismatches += 1
            print(f"[HIL] Round {rnd}  MISMATCH")
            print(f"      got      {got_key.hex().upper()}")
            print(f"      expected {expected_key.hex().upper()}")
            if mismatches > 3:
                print("[HIL] Too many mismatches — aborting.")
                break
        else:
            if idx % 20 == 0:
                print(f"[HIL] Round {rnd:4d}  OK  key={got_key.hex().upper()}  "
                      f"secure={secure_bit}")

        if args.inter_packet_ms > 0:
            time.sleep(args.inter_packet_ms / 1000.0)

    port.close()
    total = len(bob_rounds)
    print(f"\n[HIL] Done.  total={total}  mismatches={mismatches}  "
          f"first_secure_round={first_secure_round_obs or 'never'}")
    return 0 if mismatches == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
