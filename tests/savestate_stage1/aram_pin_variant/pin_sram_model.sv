`timescale 1ns/1ps
// Physical-pin functional/timing envelope for the Pocket 64 KiB ARAM SRAM.
// This is deliberately independent of the controller's state and ready signal.
module pin_sram_model #(
    parameter realtime ACCESS_NS = 55.0,
    parameter realtime OUTPUT_RELEASE_NS = 2.0,
    parameter realtime INITIAL_CLOCK_PERIOD_NS = 11.64,
    parameter bit FATAL_ON_ERROR = 1'b1
) (
    input wire clk_mem,
    input wire reset_n,
    input wire [16:0] sram_a,
    inout wire [15:0] sram_dq,
    input wire sram_oe_n,
    input wire sram_we_n,
    input wire sram_ub_n,
    input wire sram_lb_n
);
    reg [7:0] bytes [0:65535];
    integer read_count = 0;
    integer write_count = 0;
    integer early_read_failures = 0;
    integer address_faults = 0;
    integer write_timing_failures = 0;
    integer turnaround_failures = 0;
    integer protocol_failures = 0;
    // Zero means that no completed operation of this type has been observed.
    realtime min_read_duration_ns = 0.0;
    realtime min_we_duration_ns = 0.0;
    realtime memory_clock_period_ns = INITIAL_CLOCK_PERIOD_NS;

    localparam realtime TOLERANCE_NS = 0.001;
    bit read_open = 0;
    bit write_open = 0;
    bit have_idle_start = 0;
    bit have_clock_edge = 0;
    realtime idle_start = 0.0;
    realtime last_clock_edge = 0.0;
    realtime read_stable_start = 0.0;
    realtime write_start = 0.0;
    reg [16:0] read_address = 0;
    reg [1:0] read_mask = 0;
    reg [16:0] write_address = 0;
    reg [1:0] write_mask = 0;
    bit write_address_good = 0;
    bit have_write_sample = 0;
    reg [16:0] sampled_address = 0;
    reg [15:0] sampled_data = 0;
    reg [1:0] sampled_mask = 0;
    bit output_valid = 0;
    reg [15:0] output_data = 0;
    reg [1:0] output_mask = 0;

    // Delay a changing request identity, NOT a RAM payload. Every new read and
    // every address/lane change therefore incurs the full access delay, even
    // when two accesses return identical bytes. A superseded identity cannot
    // enable stale data. Verilator's two-state invalid bus is not an oracle;
    // read termination below separately checks the physical timing interval.
    reg [63:0] read_generation = 0;
    wire [63:0] delayed_read_generation;
    assign #(ACCESS_NS) delayed_read_generation = read_generation;
    reg [63:0] release_generation = 0;
    wire [63:0] delayed_release_generation;
    assign #(OUTPUT_RELEASE_NS) delayed_release_generation = release_generation;

    assign sram_dq[7:0] = output_valid && output_mask[0] ? output_data[7:0] : 8'hzz;
    assign sram_dq[15:8] = output_valid && output_mask[1] ? output_data[15:8] : 8'hzz;

    task automatic fault(input string description);
        if (FATAL_ON_ERROR) $fatal(1, "PIN_SRAM: %s", description);
        else $display("PIN_SRAM expected/recorded fault: %s", description);
    endtask

    task automatic check_idle;
        if (have_idle_start &&
            $realtime - idle_start + TOLERANCE_NS < memory_clock_period_ns) begin
            turnaround_failures++;
            fault($sformatf("idle turnaround %0.3f ns is shorter than one memory clock (%0.3f ns)",
                            $realtime - idle_start, memory_clock_period_ns));
        end
    endtask

    task automatic check_address(input logic [16:0] address);
        // Check all seventeen physical bits before indexing. Never mask aliases.
        if (address >= 17'd32768) begin
            address_faults++;
            fault($sformatf("physical word address %05h is outside 64 KiB ARAM", address));
        end
    endtask

    initial begin
        for (integer i = 0; i < 65536; i++) bytes[i] = 8'h00;
    end

    always @(posedge clk_mem) begin
        if (have_clock_edge) memory_clock_period_ns = $realtime - last_clock_edge;
        last_clock_edge = $realtime;
        have_clock_edge = 1;
    end

    always @(delayed_read_generation) begin
        if (reset_n && read_open && !sram_oe_n && sram_we_n &&
            delayed_read_generation == read_generation && sram_a < 17'd32768 &&
            $realtime - read_stable_start + TOLERANCE_NS >= ACCESS_NS) begin
            output_data = {bytes[2 * int'(sram_a) + 1], bytes[2 * int'(sram_a)]};
            output_mask = {~sram_ub_n, ~sram_lb_n};
            output_valid = 1;
        end
    end

    always @(delayed_release_generation) begin
        if (delayed_release_generation == release_generation && !read_open)
            output_valid = 0;
    end

    // Capture while WE is solidly active, half a controller cycle away from
    // the WE rising edge. Commit this retained sample at WE release below;
    // sampling the resolved DQ at release would race the controller's tri-state.
    always @(negedge clk_mem) begin
        if (reset_n && write_open && !sram_we_n) begin
            if (have_write_sample &&
                (sampled_address != sram_a || sampled_mask != {~sram_ub_n, ~sram_lb_n} ||
                 (sampled_mask[0] && sampled_data[7:0] !== sram_dq[7:0]) ||
                 (sampled_mask[1] && sampled_data[15:8] !== sram_dq[15:8]))) begin
                protocol_failures++;
                fault("write address, enabled data, or byte mask changed during WE");
            end
            sampled_address = sram_a;
            sampled_data = sram_dq;
            sampled_mask = {~sram_ub_n, ~sram_lb_n};
            have_write_sample = 1;
        end
    end

    always @(reset_n or sram_a or sram_oe_n or sram_we_n or sram_ub_n or sram_lb_n) begin : observe_pins
        bit reading;
        bit writing;
        realtime elapsed;
        reading = reset_n && !sram_oe_n && sram_we_n;
        writing = reset_n && !sram_we_n;
        if (!reset_n) begin
            // Reset aborts in-flight cycles without committing a partial write.
            // Memory and diagnostics deliberately survive controller reset.
            read_open = 0;
            write_open = 0;
            have_write_sample = 0;
            have_idle_start = 0;
            output_valid = 0;
            read_generation++;
        end else begin
            if (read_open && !reading) begin
                elapsed = $realtime - read_stable_start;
                read_count++;
                if (read_count == 1 || elapsed < min_read_duration_ns)
                    min_read_duration_ns = elapsed;
                if (elapsed + TOLERANCE_NS < ACCESS_NS) begin
                    early_read_failures++;
                    fault($sformatf("read terminated after only %0.3f ns of stable OE/address", elapsed));
                end
                read_open = 0;
                read_generation++;
                release_generation++;
                idle_start = $realtime;
                have_idle_start = 1;
            end
            if (write_open && !writing) begin
                elapsed = $realtime - write_start;
                write_count++;
                if (write_count == 1 || elapsed < min_we_duration_ns)
                    min_we_duration_ns = elapsed;
                if (elapsed + TOLERANCE_NS < ACCESS_NS) begin
                    write_timing_failures++;
                    fault($sformatf("WE pulse was only %0.3f ns", elapsed));
                end
                if (!have_write_sample) begin
                    protocol_failures++;
                    fault("WE ended without a stable falling-clock write sample");
                end else if (write_address_good && sampled_address < 17'd32768 &&
                             elapsed + TOLERANCE_NS >= ACCESS_NS) begin
                    if (sampled_mask[0]) bytes[2 * int'(sampled_address)] = sampled_data[7:0];
                    if (sampled_mask[1]) bytes[2 * int'(sampled_address) + 1] = sampled_data[15:8];
                end
                write_open = 0;
                have_write_sample = 0;
                idle_start = $realtime;
                have_idle_start = 1;
            end
            if (reading && (!read_open || sram_a != read_address ||
                            {~sram_ub_n, ~sram_lb_n} != read_mask)) begin
                if (!read_open) check_idle();
                check_address(sram_a);
                read_open = 1;
                read_address = sram_a;
                read_mask = {~sram_ub_n, ~sram_lb_n};
                read_stable_start = $realtime;
                read_generation++;
                output_valid = 0;
            end
            if (writing && !write_open) begin
                check_idle();
                check_address(sram_a);
                if (!sram_oe_n) begin
                    protocol_failures++;
                    fault("OE and WE are simultaneously active");
                end
                write_open = 1;
                write_start = $realtime;
                write_address = sram_a;
                write_mask = {~sram_ub_n, ~sram_lb_n};
                write_address_good = sram_a < 17'd32768;
                have_write_sample = 0;
            end else if (writing && (sram_a != write_address ||
                                   {~sram_ub_n, ~sram_lb_n} != write_mask)) begin
                if (sram_a != write_address) check_address(sram_a);
                protocol_failures++;
                fault("write address or byte mask changed while WE remained active");
                write_address_good = 0;
            end
        end
    end
endmodule
