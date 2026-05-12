# AAA Engine — FPGA Hardware Implementation Plan

**Project:** AAA Secret-Key Generation Engine  
**Goal:** Implement the 7-block AAA hardware architecture in synthesizable RTL, verify it against the existing C/simulation reference, and produce FPGA and ASIC-oriented synthesis reports.  
**Date started:** March 31, 2026

---

## 1. Hardware to Purchase

| Item | Model | Where | Cost | Priority |
|---|---|---|---|---|
| FPGA Development Board | **Digilent Arty A7-100T (xc7a100tcsg324-1)** — locked in as target | Digilent.com | ~$249 | Owned |
| Radio modules (optional, for live demo) | HiLetgo 4pcs nRF24L01+ | Amazon | ~$8 | After Weeks 8–9 |

**Do not buy:** Jetson Nano, Jetson Orin, or any GPU board. The AAA engine has no GPU-parallelizable workload.

**Why Arty A7-100T (the variant we're using):**
- Xilinx Artix-7 FPGA — fully supported by Vivado ML Standard free tier (no license needed)
- 63,400 LUTs, 126,800 FFs, 135 BRAM tiles, 240 DSP48 slices — design will use <1%
- Built-in USB-UART bridge (FT2232HQ) — no external programmer needed
- Same package as the A7-35T, only the die changes; XDC is board-specific (`constraints/arty_a7_100t.xdc`)

---

## 2. Software and Tools to Install

Install these before the board arrives.

### 2.1 Vivado ML Edition (Free)

Download from AMD/Xilinx. Choose **Vivado ML Standard** (free, no license).  
During install, select only: **Artix-7** device support (reduces install size from 100GB to ~35GB).

```
https://www.xilinx.com/support/download.html
```

Set up the cable driver after install (required to program the board over USB):
```bash
# Linux
cd /tools/Xilinx/Vivado/2024.x/data/xicom/cable_drivers/lin64/install_script/install_drivers
sudo ./install_drivers

# Windows: installer does this automatically
```

### 2.2 Language: SystemVerilog

Write all RTL in **SystemVerilog** (`.sv` files). It is a superset of Verilog, supported natively by Vivado, and closer to C syntax. Do not use VHDL.

### 2.3 Serial Terminal (for UART HIL testing)

```bash
pip install pyserial        # Python UART library for HIL test scripts
brew install minicom        # or use screen/PuTTY for manual inspection
```

### 2.4 GTKWave (Waveform Viewer)

For inspecting simulation waveforms outside of Vivado's built-in xsim.

```bash
brew install gtkwave        # macOS
sudo apt install gtkwave    # Linux
```

---

## 3. Repository Structure (RTL additions)

Add the following directory tree to the existing repo:

```
AAA-Implementation/
├── rtl/                        # All synthesizable RTL
│   ├── xorshift32.sv           # Block 3: Public Selector PRNG
│   ├── payload_buffer.sv       # Block 2: Payload Staging Buffer
│   ├── bit_select_fold.sv      # Block 4: Bit-Select & Fold Network
│   ├── key_accumulator.sv      # Block 5: XOR Key Accumulator
│   ├── secrecy_monitor.sv      # Block 6: Secrecy Monitor & Counters
│   ├── key_export.sv           # Block 7: Key Export & Crypto Interface
│   └── aaa_engine_top.sv       # Top-level: wires all 7 blocks together
├── tb/                         # Testbenches (not synthesized)
│   ├── tb_xorshift32.sv
│   ├── tb_bit_select_fold.sv
│   ├── tb_key_accumulator.sv
│   └── tb_aaa_engine_top.sv    # Full integration testbench (HIL replay)
├── scripts/
│   ├── hil_send_packets.py     # PC-side HIL: streams packets over UART
│   └── hil_verify.py          # Compares FPGA key output vs C reference
├── constraints/
│   └── arty_a7.xdc             # Pin assignments for Arty A7-35T
└── HARDWARE_PLAN.md            # This file
```

---

## 4. The 7-Block RTL Implementation

Build and verify blocks in this order — smallest/simplest first, integration last.

### Block 3: Public Selector PRNG (`xorshift32.sv`)

**What it does:** Generates the pseudo-random byte indices used to select payload bytes.  
**State:** 32-bit register. Advances on `advance` pulse.  
**Key constraint:** Must be bit-exact with the C `xorshift32()` function in `aaa_key_engine.c`.

```systemverilog
// NOTE: three sequential non-blocking assigns to the same register
// only keep the LAST assignment — they all evaluate the OLD `state`.
// The xorshift chain MUST be computed combinationally (or with blocking
// assigns inside a single statement). The corrected form is:

module xorshift32 #(parameter logic [31:0] SEED_DEFAULT = 32'hABCD_1234) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        advance,
    input  logic [31:0] seed,
    output logic [31:0] rnd_out
);
    logic [31:0] state, x0, x1, x2;
    always_comb begin
        x0 = state ^ (state << 13);
        x1 = x0    ^ (x0    >> 17);
        x2 = x1    ^ (x1    <<  5);
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)         state <= (seed != 0) ? seed : SEED_DEFAULT;
        else if (advance)   state <= x2;
    end
    assign rnd_out = state;
endmodule
```

**Unit test:** Feed it 10 known seeds from `reference_run.csv`, verify output matches C engine values exactly.

---

### Block 5: XOR Key Accumulator (`key_accumulator.sv`)

**What it does:** XORs a new 128-bit selected word into the running key register on every accepted packet.  
**State:** 128-bit key register (or 256-bit for the wide variant).  
**Key constraint:** Single-cycle update. No multi-cycle paths here.

```systemverilog
module key_accumulator #(parameter KEY_BYTES = 16) (
    input  logic                    clk,
    input  logic                    rst_n,
    input  logic                    update,
    input  logic [KEY_BYTES*8-1:0]  selected_in,
    output logic [KEY_BYTES*8-1:0]  key_out
);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)    key_out <= '0;
        else if (update) key_out <= key_out ^ selected_in;
    end
endmodule
```

**Unit test:** Replay the first 10 rounds from `reference_run.csv`. Verify `key_out` after each XOR update matches what the C engine holds at the same round.

---

### Block 4: Bit-Select & Fold Network (`bit_select_fold.sv`)

**What it does:** Uses PRNG indices to read two bytes from the payload buffer and XOR-fold them into the key-width output word. This is the main combinational hotspot.  
**Key constraint:** Must be purely combinational (no registered state). Timing closure here is the critical path.

Architecture:
- 16 parallel byte selectors (one per key byte for 128-bit key)
- Each selector reads `payload[rnd_idx_a % payload_len]` XOR `payload[rnd_idx_b % payload_len]`
- Output is a 128-bit word fed directly to the accumulator

**Unit test:** Use a known payload (all `0xAA` bytes), known PRNG outputs, verify the fold output is bit-exact with the C engine's `_selected[]` buffer after one round.

---

### Block 2: Payload Staging Buffer (`payload_buffer.sv`)

**What it does:** Accepts a packet byte-by-byte from the ingress interface and holds it in BRAM until the selector has finished reading.  
**State:** 512 bytes (one BRAM tile on Artix-7).  
**Interface:** Write port (from ingress), read port (from bit-select/fold network).

Use Vivado's BRAM IP or infer it with a `logic [7:0] mem [0:511]` array — Vivado will map it to BRAM automatically.

---

### Block 6: Secrecy Monitor (`secrecy_monitor.sv`)

**What it does:** Tracks `packets_total`, `packets_missed_by_eve`, `first_secure_round`, and drives the sticky `key_secure` bit.  
**Key constraint:** `key_secure` must latch high on the first Bob-only round and never clear (except on hard reset). This is a safety-critical latch — get it right.

```systemverilog
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        key_secure <= 1'b0;
    else if (bob_received && !eve_received)
        key_secure <= 1'b1;   // sticky — never clears
end
```

---

### Block 7: Key Export (`key_export.sv`)

**What it does:** Exposes the key register over a simple register bus (read-only from host). Includes a `zeroize` input that clears the key register on demand.  
**For the UART HIL setup:** This is the block that the UART controller reads to send the key back to the PC after each packet.

---

### Top Level (`aaa_engine_top.sv`)

Wires all 7 blocks together. Also includes:
- A simple FSM to sequence: `IDLE → INGRESS → SELECT → FOLD → ACCUMULATE → EXPORT`
- UART RX controller (receives packets from PC during HIL testing)
- UART TX controller (sends 16-byte key register back to PC)

**Do not include the UART controllers in the synthesis critical path** — keep them outside the `aaa_engine` boundary so synthesis reports reflect only the AAA datapath.

---

## 5. Verification Strategy

### Phase 1: Unit Tests (Vivado xsim)

Each block gets its own testbench in `tb/`. Run with:
```bash
# In Vivado Tcl console
launch_simulation
run all
```

Each testbench must:
1. Load known inputs derived from `sim/output/reference_run.csv`
2. Assert expected outputs cycle-by-cycle
3. Pass with zero assertion failures before moving to the next block

### Phase 2: Integration Testbench (`tb_aaa_engine_top.sv`)

Replay all 400 rounds from `reference_run.csv` (Eve at 45m) through the full top-level RTL.  
Check after every packet:
- `key_out` matches C engine key register
- `key_secure` latches at round 5 (first Bob-only round at 45m)
- `packets_total` and `cumulative_secure_rounds` counters are correct

This is the single most important test. If this passes, your RTL is correct.

### Phase 3: Hardware-in-the-Loop (HIL) over UART

After the integration testbench passes, program the Arty A7 and run the Python HIL scripts.

```
PC (Python)                         Arty A7 (RTL)
-----------                         -------------
hil_send_packets.py                 aaa_engine_top.sv
  |                                   |
  | -- [0xAA][len_hi][len_lo]        UART RX
  |    [512 payload bytes] -------->  |
  |                                   | AAA engine processes packet
  | <-- [16 key bytes] -----------   UART TX
  |                                   |
  | compare vs C reference            |
```

`hil_send_packets.py` uses your existing `sim/output/reference_run.csv` to drive which packets Bob received. For each `bob_received=1` row, it sends the payload and verifies the returned key.

If HIL passes bit-exact: **RTL is hardware-verified.**

---

## 6. Synthesis and Reporting

After RTL is verified, run synthesis to generate the results your report needs.

### Step 1: FPGA Synthesis (Weeks 10–11)

In Vivado, with `aaa_engine_top.sv` as top (excluding UART wrappers):

```tcl
synth_design -top aaa_engine -part xc7a100tcsg324-1
opt_design
place_design
route_design
report_timing_summary -file timing_128bit.rpt
report_utilization -file utilization_128bit.rpt
report_power -file power_128bit.rpt
```

Run twice: once with `KEY_BYTES=16` (128-bit), once with `KEY_BYTES=32` (256-bit).

**Expected results for your report:**
- LUT count: ~200–400 (out of 20,800)
- FF count: ~200 (out of 41,600)
- BRAM: 1–2 tiles
- Max frequency: well above 100 MHz (your design is tiny)
- Dynamic power: sub-milliwatt range

### Step 2: ASIC-Oriented Synthesis (Weeks 12–13)

Use **Yosys** (open-source) with a standard cell library (e.g., SkyWater 130nm via OpenLane) or if you have university access, Synopsys Design Compiler with a PDK.

**Yosys path (free, accessible now):**
```bash
pip install openlane          # OpenLane2 wraps Yosys + OpenROAD
openlane --pdk sky130A flow.json
```

Report: area (µm²), critical path delay (ns), estimated power at 100 MHz.  
Compare 128-bit vs 256-bit variants. This is your Table 7 / Table 8 in the final paper.

---

## 7. Timeline

Aligned with the Spring 2026 milestone schedule from the report (Table 6).

| Week | Dates (approx.) | Track | Deliverable | Done? |
|---|---|---|---|---|
| 1–2 | Mar 31 – Apr 13 | ns-3 | Linux build notes, Docker/VM recipe, one-click rerun | |
| 3–4 | Apr 14 – Apr 27 | ns-3 | Full Linux sweep + validation memo vs fallback | |
| 5–6 | Apr 28 – May 11 | RTL | `xorshift32.sv`, `key_accumulator.sv`, `bit_select_fold.sv` with passing unit tests | |
| 7 | May 12 – May 18 | RTL | `payload_buffer.sv`, `secrecy_monitor.sv`, `key_export.sv` with unit tests | |
| 8–9 | May 19 – Jun 1 | RTL | `aaa_engine_top.sv` integrated — integration testbench passes all 400 reference rounds | |
| 9 | Jun 1 – Jun 7 | HIL | Program Arty A7, run `hil_send_packets.py`, confirm bit-exact match on hardware | |
| 10–11 | Jun 8 – Jun 21 | Synthesis | FPGA synthesis reports: 128-bit and 256-bit variants (timing, utilization, power) | |
| 12–13 | Jun 22 – Jul 5 | Synthesis | ASIC synthesis via Yosys/OpenLane: area, delay, power for both key widths | |

**Order the Arty A7-35T by April 28 at the latest** (start of RTL weeks). It ships in 1–3 days from Digilent.

---

## 8. Block Build Order (Strict)

Follow this exact sequence. Each block must have a passing unit test before starting the next.

```
1. xorshift32.sv            ← simplest, no dependencies, validates PRNG first
2. key_accumulator.sv       ← trivial XOR register, validates accumulation logic
3. bit_select_fold.sv       ← depends on PRNG indices; combinational only
4. payload_buffer.sv        ← BRAM instantiation; verify read/write ports
5. secrecy_monitor.sv       ← FSM and sticky latch; verify key_secure behavior
6. key_export.sv            ← register bus; verify zeroize and read path
7. aaa_engine_top.sv        ← integration only after all above pass unit tests
```

Do not skip ahead. An integration bug is 10x harder to debug than a unit-level bug.

---

## 9. Final Deliverables Checklist

These are what you need to complete the research paper's hardware section.

### RTL Artifacts
- [ ] All 7 `.sv` source files synthesize cleanly with zero errors in Vivado
- [ ] All unit testbenches pass (zero assertion failures)
- [ ] Integration testbench passes all 400 reference run rounds bit-exact
- [ ] HIL test passes on physical Arty A7 hardware

### Synthesis Reports (FPGA)
- [ ] `timing_128bit.rpt` — worst negative slack, max frequency
- [ ] `utilization_128bit.rpt` — LUT, FF, BRAM, DSP counts
- [ ] `power_128bit.rpt` — static and dynamic power at operating frequency
- [ ] Same three reports for 256-bit key width variant

### Synthesis Reports (ASIC)
- [ ] Area estimate (µm²) for 128-bit and 256-bit via Yosys/OpenLane
- [ ] Critical path delay (ns) — determines max clock frequency
- [ ] Power estimate at 100 MHz operating point

### Paper Additions (Section 5 / new Section 6)
- [ ] Updated Table 5 with actual synthesis numbers filled in
- [ ] Comparison table: 128-bit vs 256-bit area/power tradeoff
- [ ] Waveform screenshot from integration testbench showing `key_secure` latch at round 5

---

## 10. Key Reference Points

| Reference | Location |
|---|---|
| C engine (ground truth for RTL verification) | `aaa_key_engine.c`, `aaa_key_engine.h` |
| Reference run CSV (400 rounds at 45m) | `sim/output/reference_run.csv` |
| Distance sweep CSV | `sim/output/sweep_results.csv` |
| Hardware architecture diagram | `output/pdf/aaa_secret_key_report.pdf`, Figure 2 |
| Hua's paper (theoretical basis) | `A_Remark_on_the_AAA_Method_for_Secret-Key_Generation_in_Mobile_Networks.pdf` |
| Arty A7 board schematic and XDC file | Digilent Resource Center (download with board) |

---

## 11. Quick Reference: Critical Design Constraints

1. **Bit-exact with C engine.** Every RTL block must produce outputs identical to the C reference. The testbench is not a random test — it replays actual simulation data.

2. **`key_secure` is a sticky latch.** Once high, it never clears except on hard reset. This is the security invariant of the design.

3. **No floating-point in RTL.** The equivocation metric stays in software. Only the integer datapath (XOR, counters, PRNG) goes into RTL.

4. **UART wrappers are not part of the synthesis boundary.** Keep them in a separate wrapper module so synthesis reports reflect only the AAA engine area and power.

5. **Parameterize key width.** Use `parameter KEY_BYTES = 16` throughout so you can run both 128-bit and 256-bit synthesis with a single parameter change — no code duplication.
