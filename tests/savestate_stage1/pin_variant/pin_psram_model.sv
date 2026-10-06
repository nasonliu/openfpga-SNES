`timescale 1ns/1ps
// Test-only asynchronous, multiplexed-address PSRAM pin model.
//
// Scope: bank 0, ordinary array accesses, 1 MiB state storage. An out-of-range
// physical address is fatal; no masked address bits can alias another word.
// The model is intentionally not a manufacturer timing/signoff model. The
// checked minima come from target/pocket/psram.sv's declared timing envelope.
// Read data arrives no earlier than 70 ns after ADV falls and 20 ns after OE
// falls (the latter is the controller's commented OE-to-data allowance).
// The 2 ns output-release interval is a declared simulation envelope, not a
// claimed device specification. It exercises read/address-bus turnaround.
//
// clk_mem is only an observation clock: retain stable write data at negedge
// before the controller simultaneously raises WE/CE and releases its DQ bus.
// All transaction detection, address capture, access delay and termination
// come from physical pins. No request, completion, or controller state is used.
// Array ram is public only for bench checkpoint verification/fault injection.
module pin_psram_model #(
    parameter integer WORDS = 524288,
    parameter logic [15:0] INITIAL_WORD = 16'hdead,
    parameter realtime ACCESS_NS = 70.0,
    parameter realtime OE_ACCESS_NS = 20.0,
    parameter realtime OUTPUT_RELEASE_NS = 2.0,
    parameter realtime MIN_ADV_LOW_NS = 5.0,
    parameter realtime MIN_CE_BEFORE_ADV_NS = 7.0,
    parameter realtime MIN_ADDRESS_SETUP_NS = 5.0,
    parameter realtime MIN_ADDRESS_HOLD_NS = 2.0,
    parameter realtime MIN_WE_LOW_NS = 45.0,
    parameter realtime MIN_WRITE_CYCLE_NS = 70.0,
    parameter realtime MIN_DATA_SETUP_NS = 20.0
) (
    input wire clk_mem,
    input wire [21:16] cram_a,
    inout wire [15:0] cram_dq,
    output wire cram_wait,
    input wire cram_clk,
    input wire cram_adv_n,
    input wire cram_cre,
    input wire cram_ce0_n,
    input wire cram_ce1_n,
    input wire cram_oe_n,
    input wire cram_we_n,
    input wire cram_ub_n,
    input wire cram_lb_n
);
    localparam realtime EPSILON_NS = 0.001;
    localparam realtime UNMEASURED_NS = 1.0e12;
    logic [15:0] ram [0:WORDS-1];
    logic [21:0] latched_addr = 0;
    logic [15:0] write_sample = 0, read_sample = 0;
    bit cycle_active = 0, address_valid = 0, cycle_write = 0;
    bit cycle_completed = 0, write_sample_valid = 0, read_active = 0;
    bit write_ub = 0, write_lb = 0, read_ub = 0, read_lb = 0;
    bit data_ready = 0, driving_read = 0;
    integer transaction_id = 0;

    // Exposed coverage/measurements. Minima remain UNMEASURED_NS until used.
    longint unsigned address_count = 0, read_count = 0, write_count = 0;
    longint unsigned low_byte_write_count = 0, high_byte_write_count = 0;
    longint unsigned address_guard_failures = 0, early_read_failures = 0;
    logic [21:0] highest_address = 0;
    realtime min_adv_low_ns = UNMEASURED_NS;
    realtime min_ce_before_adv_ns = UNMEASURED_NS;
    realtime min_ce_low_ns = UNMEASURED_NS;
    realtime min_we_low_ns = UNMEASURED_NS;
    realtime min_write_cycle_ns = UNMEASURED_NS;
    realtime min_data_setup_ns = UNMEASURED_NS;
    realtime min_read_cycle_ns = UNMEASURED_NS;
    realtime min_oe_low_ns = UNMEASURED_NS;
    realtime min_address_setup_ns = UNMEASURED_NS;
    realtime min_address_hold_ns = UNMEASURED_NS;

    realtime cycle_start_ns = 0, ce_start_ns = 0, we_start_ns = 0;
    realtime adv_high_ns = 0, oe_start_ns = 0;
    realtime address_change_ns = 0, data_change_ns = 0;
    bit check_address_hold = 0;

    assign cram_wait = 1'b0; // Async fixed-latency operation does not use WAIT.
    assign cram_dq[7:0] = (driving_read && read_lb) ? read_sample[7:0] : 8'hzz;
    assign cram_dq[15:8] = (driving_read && read_ub) ? read_sample[15:8] : 8'hzz;

    initial begin
        if (WORDS < 524288 || WORDS > 4194304)
            $fatal(1, "PIN_PSRAM_CAPACITY: require 1 MiB through full 4M-word address space");
        for (integer i = 0; i < WORDS; i = i + 1) ram[i] = INITIAL_WORD;
    end

    task automatic require_min(input realtime measured, input realtime required_ns,
                               input string label_text);
        if (measured + EPSILON_NS < required_ns)
            $fatal(1, "PIN_PSRAM_TIMING %s: measured=%0.3f ns required=%0.3f ns addr=%h",
                   label_text, measured, required_ns, latched_addr);
    endtask

    task automatic enable_read_after(input integer id, input realtime delay_ns);
        #(delay_ns);
        if (cycle_active && read_active && transaction_id == id &&
            !cram_ce0_n && !cram_oe_n && cram_we_n && cram_adv_n) begin
            read_sample = ram[latched_addr];
            data_ready = 1;
            driving_read = 1;
        end
    endtask

    task automatic release_read_after(input integer id);
        #(OUTPUT_RELEASE_NS);
        if (transaction_id == id) driving_read = 0;
    endtask

    task automatic finish_read;
        realtime age_ns, oe_age_ns;
        if (read_active) begin
            age_ns = $realtime - cycle_start_ns;
            oe_age_ns = $realtime - oe_start_ns;
            // CE/OE release is also the production controller's sampling edge.
            // This explicitly catches premature capture even in Verilator's
            // two-state simulation, where an undriven DQ need not become X.
            if (!data_ready || age_ns + EPSILON_NS < ACCESS_NS ||
                oe_age_ns + EPSILON_NS < OE_ACCESS_NS) begin
                early_read_failures = early_read_failures + 1;
                $fatal(1, "PIN_PSRAM_EARLY_READ: age=%0.3f oe_age=%0.3f ready=%b addr=%h",
                       age_ns, oe_age_ns, data_ready, latched_addr);
            end
            if (age_ns < min_read_cycle_ns) min_read_cycle_ns = age_ns;
            if (oe_age_ns < min_oe_low_ns) min_oe_low_ns = oe_age_ns;
            read_count = read_count + 1;
            read_active = 0;
            data_ready = 0;
            cycle_completed = 1;
            fork release_read_after(transaction_id); join_none
        end
    endtask

    task automatic finish_write;
        realtime pulse_ns, cycle_ns, setup_ns;
        if (cycle_active && cycle_write && !cycle_completed) begin
            if (!address_valid || !write_sample_valid)
                $fatal(1, "PIN_PSRAM_WRITE_WITHOUT_ADDRESS_OR_DATA");
            pulse_ns = $realtime - we_start_ns;
            cycle_ns = $realtime - cycle_start_ns;
            setup_ns = $realtime - data_change_ns;
            require_min(pulse_ns, MIN_WE_LOW_NS, "WE-low");
            require_min(cycle_ns, MIN_WRITE_CYCLE_NS, "write-cycle");
            require_min(setup_ns, MIN_DATA_SETUP_NS, "write-data-setup");
            if (pulse_ns < min_we_low_ns) min_we_low_ns = pulse_ns;
            if (cycle_ns < min_write_cycle_ns) min_write_cycle_ns = cycle_ns;
            if (setup_ns < min_data_setup_ns) min_data_setup_ns = setup_ns;
            if (write_lb) begin
                ram[latched_addr][7:0] = write_sample[7:0];
                low_byte_write_count = low_byte_write_count + 1;
            end
            if (write_ub) begin
                ram[latched_addr][15:8] = write_sample[15:8];
                high_byte_write_count = high_byte_write_count + 1;
            end
            write_count = write_count + 1;
            cycle_completed = 1;
        end
    endtask

    always @(negedge cram_ce0_n) begin
        ce_start_ns = $realtime;
        if (cram_cre || cram_clk || !cram_ce1_n)
            $fatal(1, "PIN_PSRAM_UNSUPPORTED_MODE: require async array bank 0");
    end
    always @(negedge cram_ce1_n)
        $fatal(1, "PIN_PSRAM_UNSUPPORTED_BANK: bank 1 selected");
    always @(negedge cram_we_n) begin
        we_start_ns = $realtime;
        if (driving_read) $fatal(1, "PIN_PSRAM_TURNAROUND: write while read bus driven");
    end

    always @(negedge cram_adv_n) begin
        if (cram_ce0_n || !cram_ce1_n || cycle_active || driving_read)
            $fatal(1, "PIN_PSRAM_ADDRESS_PHASE: invalid select/overlap/turnaround");
        cycle_active = 1;
        cycle_completed = 0;
        address_valid = 0;
        write_sample_valid = 0;
        cycle_write = !cram_we_n;
        cycle_start_ns = $realtime;
        address_change_ns = $realtime;
        data_change_ns = $realtime;
        check_address_hold = 0;
        data_ready = 0;
        transaction_id = transaction_id + 1;
    end

    always @(cram_a or cram_dq) begin
        if (cycle_active && !cram_adv_n) address_change_ns = $realtime;
        if (cycle_active && cram_adv_n && check_address_hold) begin
            require_min($realtime - adv_high_ns, MIN_ADDRESS_HOLD_NS, "address-hold");
            if ($realtime - adv_high_ns < min_address_hold_ns)
                min_address_hold_ns = $realtime - adv_high_ns;
            check_address_hold = 0;
        end
        if (cycle_active && cycle_write && cram_adv_n && !cram_we_n && !cram_ce0_n)
            data_change_ns = $realtime;
    end

    always @(posedge cram_adv_n) begin
        if (cycle_active) begin
            require_min($realtime - cycle_start_ns, MIN_ADV_LOW_NS, "ADV-low");
            require_min($realtime - ce_start_ns, MIN_CE_BEFORE_ADV_NS, "CE-before-ADV");
            require_min($realtime - address_change_ns, MIN_ADDRESS_SETUP_NS, "address-setup");
            if ($realtime - cycle_start_ns < min_adv_low_ns)
                min_adv_low_ns = $realtime - cycle_start_ns;
            if ($realtime - ce_start_ns < min_ce_before_adv_ns)
                min_ce_before_adv_ns = $realtime - ce_start_ns;
            if ($realtime - address_change_ns < min_address_setup_ns)
                min_address_setup_ns = $realtime - address_change_ns;
            latched_addr = {cram_a, cram_dq};
            if ($isunknown(latched_addr) || int'(latched_addr) >= WORDS) begin
                address_guard_failures = address_guard_failures + 1;
                $fatal(1, "PIN_PSRAM_ADDRESS_RANGE: addr=%h words=%0d", latched_addr, WORDS);
            end
            if (latched_addr > highest_address) highest_address = latched_addr;
            address_count = address_count + 1;
            address_valid = 1;
            adv_high_ns = $realtime;
            check_address_hold = 1;
            write_ub = !cram_ub_n;
            write_lb = !cram_lb_n;
        end
    end

    always @(negedge clk_mem) begin
        if (cycle_active && cycle_write && address_valid && cram_adv_n &&
            !cram_ce0_n && !cram_we_n) begin
            if ($isunknown(cram_dq))
                write_sample_valid = 0;
            else begin
                write_sample = cram_dq;
                write_sample_valid = 1;
            end
            if (write_ub != !cram_ub_n || write_lb != !cram_lb_n)
                $fatal(1, "PIN_PSRAM_BYTE_MASK_CHANGED_DURING_WRITE");
        end
    end

    always @(negedge cram_oe_n) begin
        if (!cycle_active || !address_valid || cycle_write || !cram_we_n ||
            !cram_adv_n || cram_ce0_n || driving_read)
            $fatal(1, "PIN_PSRAM_READ_PHASE: invalid select/address/direction");
        read_active = 1;
        oe_start_ns = $realtime;
        read_ub = !cram_ub_n;
        read_lb = !cram_lb_n;
        fork
            enable_read_after(transaction_id,
                ((cycle_start_ns + ACCESS_NS - $realtime) > OE_ACCESS_NS)
                    ? cycle_start_ns + ACCESS_NS - $realtime : OE_ACCESS_NS);
        join_none
    end

    always @(posedge cram_oe_n) finish_read();
    always @(posedge cram_we_n) finish_write();
    always @(posedge cram_ce0_n) begin
        if (cycle_active) begin
            if (cycle_write) finish_write(); else finish_read();
            if (!cycle_completed) $fatal(1, "PIN_PSRAM_INCOMPLETE_CYCLE");
            if ($realtime - ce_start_ns < min_ce_low_ns)
                min_ce_low_ns = $realtime - ce_start_ns;
            cycle_active = 0;
            address_valid = 0;
            check_address_hold = 0;
        end
    end
endmodule
