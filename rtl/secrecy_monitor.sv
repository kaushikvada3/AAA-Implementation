// secrecy_monitor.sv
//
// Block 6: Secrecy Monitor & Counters.
//
// Tracks packets_total, packets_missed_by_eve, cumulative_secure_rounds,
// and drives the sticky key_secure latch. The latch goes high on the
// first packet where bob_received=1 AND eve_received=0, and clears
// ONLY on a hard reset. This is the design's security invariant.

`default_nettype none

module secrecy_monitor (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        round_tick,        // pulses once per accepted packet
    input  wire        bob_received,      // captured by the round_tick
    input  wire        eve_received,      // captured by the round_tick
    output logic       key_secure,
    output logic [31:0] packets_total,
    output logic [31:0] packets_missed_by_eve,
    output logic [31:0] cumulative_secure_rounds
);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key_secure               <= 1'b0;
            packets_total            <= '0;
            packets_missed_by_eve    <= '0;
            cumulative_secure_rounds <= '0;
        end else if (round_tick) begin
            packets_total <= packets_total + 32'd1;
            if (bob_received && !eve_received) begin
                key_secure            <= 1'b1;
                packets_missed_by_eve <= packets_missed_by_eve + 32'd1;
            end
            if (key_secure || (bob_received && !eve_received)) begin
                cumulative_secure_rounds <= cumulative_secure_rounds + 32'd1;
            end
        end
    end

endmodule

`default_nettype wire
