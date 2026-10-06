// SPDX-License-Identifier: GPL-3.0-or-later
// Experimental Pocket stage-1 APF Memories controller.
// Protocol sequencing informed by agg23/AnaloguePocket-SNES PR #113's
// target/pocket/savestate_controller.sv. This implementation adds a versioned
// envelope, complete pre-A4 staging validation, transaction mailboxes and
// timeout quarantine. It is intentionally distinct from save_state_controller.
//
// Wire format: eight little-endian 32-bit header words, then PAYLOAD bytes.
//   0: 0x31535350 ("PSS1"), 1: version=1, 2: payload length,
//   3: ROM identity, 4: sum of every normalized payload u32 (mod 2^32),
//   5: flags=1 (additive checksum), 6,7: zero (reserved).
// The sum detects accidental corruption; it is NOT authentication.
// APF writes the WHOLE blob before A4. No live-core load request is emitted
// before metadata, coverage, checksum AND committed-storage count validate.
//
// CDC contract: payload_size / rom_identity are stable for the session.
// saved_payload_checksum is held after engine_drained until next ss_save.
// stage_complete is a clk_mem LEVEL proving every expected byte was committed,
// not a pulse or merely an empty queue. This covers data_loader's FIFO tail.
// core_reset must be the actual serializer reset, not an availability flag.
// A post-trigger timeout quarantines until core_reset; it never rearms an
// engine whose save_en/load_en latch might still be waiting for an interrupt.
module savestate_controller #(
    parameter [3:0] SS_REGION = 4'h4,
    parameter [31:0] MAX_PAYLOAD_SIZE = 32'h00064000,
    parameter [31:0] TIMEOUT_TRIGGER = 32'd215000000,
    parameter [31:0] TIMEOUT_WALK = 32'd128000000,
    parameter [31:0] TIMEOUT_DRAIN = 32'd21500000,
    parameter [31:0] TIMEOUT_STAGE = 32'd742500000,
    parameter [31:0] TIMEOUT_READBACK = 32'd891000000,
    parameter [31:0] TIMEOUT_COMMAND = 32'd2000000000,
    parameter integer SETTLE_CYCLES = 64
) (
    input wire clk_74a,
    input wire clk_sys_21_48,
    input wire core_reset,                     // clk_sys, active high
    input wire bridge_rd,
    input wire bridge_wr,
    input wire bridge_endian_little,
    input wire [31:0] bridge_addr,
    input wire [31:0] bridge_wr_data,
    input wire [31:0] payload_size,
    input wire [31:0] rom_identity,

    input wire savestate_load,
    output reg savestate_load_ack_s = 0,
    output reg savestate_load_busy_s = 0,
    output reg savestate_load_ok_s = 0,
    output reg savestate_load_err_s = 0,
    input wire savestate_start,
    output reg savestate_start_ack_s = 0,
    output reg savestate_start_busy_s = 0,
    output reg savestate_start_ok_s = 0,
    output reg savestate_start_err_s = 0,

    input wire ss_admit,                       // clk_sys: admit NEW ownership only
    input wire ss_allow,                       // clk_sys: ongoing safety, not queued backup
    input wire ss_busy,                        // clk_sys, actual walk
    input wire storage_fault,                 // clk_sys, sticky
    input wire stage_lost,                    // clk_mem, sticky to clear
    input wire stage_drained,                 // clk_mem
    input wire stage_complete,                // clk_mem: committed count exact
    input wire engine_drained,                // clk_mem: no outstanding work
    input wire save_complete,                 // clk_mem: real payload + final header committed
    input wire [31:0] saved_payload_checksum,  // clk_mem bundled stable data

    output reg ss_save = 0,                    // clk_sys, one-cycle trigger
    output reg ss_load = 0,                    // clk_sys, one-cycle trigger
    output wire ss_idle,                       // clk_sys
    output wire ss_lock,                       // clk_sys, includes pre-A4 blob
    output wire ss_lock_host,                  // clk74, immediate host ownership
    output wire ss_abort,                      // clk_sys, quarantined until reset
    output reg stage_clear = 0,                // clk_sys, fresh transfer pulse
    output reg stage_clear_toggle74 = 0,       // clk74, optional CDC observation

    output wire stage_accept,                 // clk74, accepted payload wr pulse
    output wire header_select,
    output wire [31:0] header_rd_data,
    output wire blob_read_enable,             // clk74, gate unloader bridge_rd
    output wire [31:0] blob_size,
    output reg [7:0] protocol_error = 0         // clk74, debug; APF sees ERR bit
);
    localparam [31:0] MAGIC = 32'h31535350;
    localparam [31:0] FORMAT_VERSION = 32'd1;
    localparam [31:0] HEADER_SIZE = 32'd32;
    localparam [7:0] E_NONE=0, E_UNAVAILABLE=1, E_BUSY=2, E_FORMAT=3,
        E_COVERAGE=4, E_CHECKSUM=5, E_STORAGE=6, E_TIMEOUT=7, E_RESET=8;

    function automatic [31:0] swap32(input [31:0] v);
        swap32 = {v[7:0],v[15:8],v[23:16],v[31:24]};
    endfunction
    wire [31:0] wr_word = bridge_endian_little ? bridge_wr_data : swap32(bridge_wr_data);
    wire in_region = bridge_addr[31:28] == SS_REGION;
    wire [31:0] offset = {4'd0,bridge_addr[27:0]};
    wire size_valid = payload_size >= 32'd16 && payload_size <= MAX_PAYLOAD_SIZE && payload_size[2:0] == 0;
    assign blob_size = payload_size + HEADER_SIZE;

    // Named, preserved level synchronizers. Mailbox data is held until the
    // response toggle returns; no independently synchronized multibit buses.
    (* ASYNC_REG="TRUE", preserve, dont_merge *) reg [2:0] allow74=0, admit74=0, reset74=0, lost74=0, drained74=0, complete74=0;
    always @(posedge clk_74a) begin
        allow74 <= {allow74[1:0],ss_allow};
        admit74 <= {admit74[1:0],ss_admit};
        reset74 <= {reset74[1:0],core_reset};
        lost74 <= {lost74[1:0],stage_lost};
        drained74 <= {drained74[1:0],stage_drained};
        complete74 <= {complete74[1:0],stage_complete};
    end

    localparam [2:0] P_IDLE=0, P_LOAD_DRAIN=1, P_ENGINE=2, P_SAVE_READY=3, P_QUARANTINE=4, P_READ_DRAIN=5;
    reg [2:0] pstate = P_IDLE;
    reg prev_wr=0, prev_rd=0, prev_start=0, prev_load=0;
    wire wr_event = bridge_wr && !prev_wr && in_region;
    wire rd_event = bridge_rd && !prev_rd && in_region;
    wire start_event = savestate_start && !prev_start;
    wire load_event = savestate_load && !prev_load;
    wire receive_allowed = pstate == P_IDLE || pstate == P_SAVE_READY;
    reg preload_active=0, preload_bad=0;
    reg [31:0] next_offset=0, preload_size=0, preload_identity=0;
    reg [31:0] declared_checksum=0, incoming_checksum=0;
    reg [31:0] preload_age=0;
    reg discard_preload=0;
    reg [31:0] timer74=0, read_next=0;
    reg [31:0] saved_size=0, saved_identity=0, saved_checksum=0;
    reg read_bad=0;
    reg operation_load=0;
    reg command_toggle=0;
    reg abort_toggle=0;
    reg seen_done=0;
    reg saw_reset=0;

    assign stage_accept = wr_event && receive_allowed && preload_active &&
        !preload_bad && !reset74[2] && offset == next_offset &&
        offset >= HEADER_SIZE && offset < preload_size + HEADER_SIZE;
    assign header_select = in_region && offset < HEADER_SIZE;
    wire readable = pstate == P_SAVE_READY && savestate_start_ok_s;
    assign blob_read_enable = bridge_rd && readable && in_region &&
        offset >= HEADER_SIZE && offset < saved_size + HEADER_SIZE && offset[1:0] == 0;
    reg [31:0] header_word;
    always @* begin
        header_word = 0;
        if (readable) case (offset[4:2])
            0: header_word = MAGIC;
            1: header_word = FORMAT_VERSION;
            2: header_word = saved_size;
            3: header_word = saved_identity;
            4: header_word = saved_checksum;
            5: header_word = 32'd1;
            default: header_word = 0;
        endcase
    end
    assign header_rd_data = bridge_endian_little ? header_word : swap32(header_word);

    // Parser lifetime begins at header word zero, NOT at A4 or seq-idle.
    // An offset-zero write explicitly replaces an abandoned/previous blob.
    always @(posedge clk_74a) begin
        if (discard_preload || reset74[2]) begin
            preload_active <= 0;
            preload_bad <= 0;
            next_offset <= 0;
            preload_age <= 0;
        end else if (wr_event && receive_allowed) begin
            preload_age <= 0;
            if (offset == 0) begin
                preload_active <= size_valid && allow74[2] && admit74[2];
                preload_bad <= !size_valid || wr_word != MAGIC || !allow74[2] || !admit74[2];
                preload_size <= payload_size;
                preload_identity <= rom_identity;
                next_offset <= 4;
                incoming_checksum <= 0;
                declared_checksum <= 0;
                stage_clear_toggle74 <= ~stage_clear_toggle74;
            end else if (!preload_active || offset != next_offset || offset[1:0] != 0 ||
                         offset >= preload_size + HEADER_SIZE) begin
                preload_bad <= 1;
            end else begin
                next_offset <= next_offset + 4;
                case (offset)
                    4: if (wr_word != FORMAT_VERSION) preload_bad <= 1;
                    8: if (wr_word != preload_size) preload_bad <= 1;
                    12: if (wr_word != preload_identity) preload_bad <= 1;
                    16: declared_checksum <= wr_word;
                    20: if (wr_word != 1) preload_bad <= 1;
                    24,28: if (wr_word != 0) preload_bad <= 1;
                    default: incoming_checksum <= incoming_checksum + wr_word;
                endcase
            end
        end else if (preload_active && receive_allowed) begin
            if (preload_age >= TIMEOUT_STAGE) begin
                preload_active <= 0;
                preload_bad <= 1;
            end else preload_age <= preload_age + 1'b1;
        end
    end

    // Sys-clock transaction machine. Request direction is a bundled mailbox
    // field held from command_toggle until the completion toggle returns.
    localparam [2:0] S_IDLE=0, S_WAIT_BUSY=1, S_WALK=2, S_DRAIN=3, S_QUARANTINE=4;
    reg [2:0] sstate=S_IDLE;
    (* ASYNC_REG="TRUE", preserve, dont_merge *) reg [2:0] command_sys=0, clear_sys=0, abort_sys=0, lock_sys=0, drain_sys=0, save_complete_sys=0;
    reg seen_command=0, seen_clear=0, seen_abort=0;
    reg owner_active=0, owner_admitted=0;
    reg save_clear_seen=0;
    // Host admission is advisory until ownership reaches the sys domain. If
    // a backup won that initial CDC race, fail before triggering the engine.
    // Once admitted, a newly QUEUED backup cannot revoke this session.
    wire owner_allowed = owner_active ? owner_admitted : ss_admit;
    reg [31:0] timer_sys=0, settle_count=0;
    reg done_toggle=0, done_error=0, done_quarantine=0;
    reg [7:0] done_code=0;
    reg [31:0] checksum_mailbox=0;
    wire active74 = pstate != P_IDLE || preload_active;
    assign ss_lock_host = active74;
    always @(posedge clk_sys_21_48) begin
        command_sys <= {command_sys[1:0],command_toggle};
        clear_sys <= {clear_sys[1:0],stage_clear_toggle74};
        abort_sys <= {abort_sys[1:0],abort_toggle};
        lock_sys <= {lock_sys[1:0],active74};
        drain_sys <= {drain_sys[1:0],engine_drained};
        save_complete_sys <= {save_complete_sys[1:0],save_complete};
    end
    assign ss_lock = lock_sys[2] || sstate != S_IDLE;
    assign ss_idle = !ss_lock;
    assign ss_abort = sstate == S_QUARANTINE;

    task automatic finish_sys(input error, input quarantine, input [7:0] code);
        begin
            done_error <= error;
            done_quarantine <= quarantine;
            done_code <= code;
            done_toggle <= ~done_toggle;
            sstate <= quarantine ? S_QUARANTINE : S_IDLE;
            timer_sys <= 0;
        end
    endtask

    always @(posedge clk_sys_21_48) begin
        ss_save <= 0;
        ss_load <= 0;
        stage_clear <= 0;
        if (sstate != S_IDLE && !save_complete_sys[2]) save_clear_seen <= 1;
        if (clear_sys[2] != seen_clear) begin
            seen_clear <= clear_sys[2];
            stage_clear <= 1;
        end
        if (core_reset) begin owner_active <= 0; owner_admitted <= 0; end
        else if (!lock_sys[2] && sstate == S_IDLE) begin owner_active <= 0; owner_admitted <= 0; end
        else if (!owner_active && lock_sys[2]) begin owner_active <= 1; owner_admitted <= ss_admit; end
        if (!ss_allow || core_reset) settle_count <= 0;
        else if (settle_count < SETTLE_CYCLES) settle_count <= settle_count + 1'b1;
        if (timer_sys != 32'hffffffff) timer_sys <= timer_sys + 1'b1;

        if (core_reset) begin
            // Keep mailbox toggle history across reset. A reset must not replay
            // a completed command or synthesize a phantom completion.
            if (command_sys[2] != seen_command) begin
                seen_command <= command_sys[2];
                finish_sys(1,0,E_RESET);
            end else if (sstate != S_IDLE && sstate != S_QUARANTINE)
                finish_sys(1,0,E_RESET);
            else sstate <= S_IDLE;
            seen_abort <= abort_sys[2];
        end else if (abort_sys[2] != seen_abort) begin
            seen_abort <= abort_sys[2];
            if (sstate != S_IDLE && sstate != S_QUARANTINE)
                finish_sys(1,1,E_TIMEOUT);
            else sstate <= S_QUARANTINE;
        end else case (sstate)
            S_IDLE: begin
                timer_sys <= 0;
                if (command_sys[2] != seen_command) begin
                    seen_command <= command_sys[2];
                    if (!owner_allowed || !ss_allow || ss_busy || storage_fault || settle_count < SETTLE_CYCLES)
                        finish_sys(1,0,E_UNAVAILABLE);
                    else begin
                        ss_save <= !operation_load;
                        save_clear_seen <= 0;
                        ss_load <= operation_load;
                        sstate <= S_WAIT_BUSY;
                    end
                end
            end
            S_WAIT_BUSY: begin
                if (storage_fault || !ss_allow) finish_sys(1,1,E_STORAGE);
                else if (ss_busy) begin sstate <= S_WALK; timer_sys <= 0; end
                else if (timer_sys >= TIMEOUT_TRIGGER) finish_sys(1,1,E_TIMEOUT);
            end
            S_WALK: begin
                if (storage_fault || !ss_allow) finish_sys(1,1,E_STORAGE);
                else if (!ss_busy) begin sstate <= S_DRAIN; timer_sys <= 0; end
                else if (timer_sys >= TIMEOUT_WALK) finish_sys(1,1,E_TIMEOUT);
            end
            S_DRAIN: begin
                if (storage_fault || !ss_allow || ss_busy) finish_sys(1,1,E_STORAGE);
                else if (drain_sys[2] && !operation_load && (!save_clear_seen || !save_complete_sys[2])) finish_sys(1,1,E_STORAGE);
                else if (drain_sys[2]) begin
                    checksum_mailbox <= saved_payload_checksum;
                    finish_sys(0,0,E_NONE);
                end else if (timer_sys >= TIMEOUT_DRAIN) finish_sys(1,1,E_TIMEOUT);
            end
            S_QUARANTINE: begin
                // Only the serializer's actual reset cancels a latched request.
                seen_command <= command_sys[2];
            end
            default: sstate <= S_QUARANTINE;
        endcase
    end

    (* ASYNC_REG="TRUE", preserve, dont_merge *) reg [2:0] done74=0, idle74=0;
    always @(posedge clk_74a) begin
        done74 <= {done74[1:0],done_toggle};
        idle74 <= {idle74[1:0],engine_drained};
    end

    task automatic reject_start(input [7:0] code);
        begin
            savestate_start_busy_s <= (pstate == P_ENGINE && !operation_load);
            savestate_start_ok_s <= 0;
            savestate_start_err_s <= 1;
            protocol_error <= code;
        end
    endtask
    task automatic reject_load(input [7:0] code);
        begin
            savestate_load_busy_s <= (pstate == P_ENGINE && operation_load) || pstate == P_LOAD_DRAIN;
            savestate_load_ok_s <= 0;
            savestate_load_err_s <= 1;
            protocol_error <= code;
        end
    endtask

    always @(posedge clk_74a) begin
        prev_wr <= bridge_wr;
        prev_rd <= bridge_rd;
        prev_start <= savestate_start;
        prev_load <= savestate_load;
        discard_preload <= 0;
        if (!savestate_start) savestate_start_ack_s <= 0;
        if (!savestate_load) savestate_load_ack_s <= 0;
        if (timer74 != 32'hffffffff) timer74 <= timer74 + 1'b1;
        if (reset74[2]) saw_reset <= 1;
        else if (pstate != P_QUARANTINE) saw_reset <= 0;

        // Ack and flags originate in clk74 together. core_bridge_cmd observes
        // the new flags on the cycle after ack, without independent CDC skew.
        if (start_event) begin
            savestate_start_ack_s <= 1;
            if (pstate != P_IDLE || preload_active || load_event || !drained74[2] || !idle74[2]) reject_start(E_BUSY);
            else if (!admit74[2] || !allow74[2] || reset74[2] || !size_valid) reject_start(E_UNAVAILABLE);
            else begin
                savestate_start_busy_s <= 1;
                savestate_start_ok_s <= 0;
                savestate_start_err_s <= 0;
                protocol_error <= E_NONE;
                saved_size <= payload_size;
                saved_identity <= rom_identity;
                operation_load <= 0;
                command_toggle <= ~command_toggle;
                discard_preload <= 1;
                timer74 <= 0;
                pstate <= P_ENGINE;
            end
        end
        if (load_event) begin
            savestate_load_ack_s <= 1;
            if (!receive_allowed || start_event) reject_load(E_BUSY);
            else if (!allow74[2] || reset74[2] || !size_valid) reject_load(E_UNAVAILABLE);
            else if (!preload_active || next_offset != preload_size + HEADER_SIZE)
                reject_load(E_COVERAGE);
            else if (preload_bad || payload_size != preload_size || rom_identity != preload_identity)
                reject_load(E_FORMAT);
            else if (incoming_checksum != declared_checksum) reject_load(E_CHECKSUM);
            else begin
                savestate_load_busy_s <= 1;
                savestate_load_ok_s <= 0;
                savestate_load_err_s <= 0;
                protocol_error <= E_NONE;
                operation_load <= 1;
                timer74 <= 0;
                pstate <= P_LOAD_DRAIN;
            end
        end

        case (pstate)
            P_IDLE: begin
                if (!start_event && !load_event) timer74 <= 0;
            end
            P_LOAD_DRAIN: begin
                if (reset74[2] || !allow74[2]) begin
                    reject_load(E_RESET); savestate_load_busy_s <= 0; pstate <= P_IDLE; discard_preload <= 1;
                end else if (lost74[2] || wr_event) begin
                    reject_load(E_STORAGE); savestate_load_busy_s <= 0; pstate <= P_IDLE; discard_preload <= 1;
                end else if (drained74[2] && complete74[2]) begin
                    command_toggle <= ~command_toggle;
                    timer74 <= 0;
                    pstate <= P_ENGINE;
                end else if (timer74 >= TIMEOUT_STAGE) begin
                    reject_load(E_TIMEOUT); savestate_load_busy_s <= 0; pstate <= P_IDLE; discard_preload <= 1;
                end
            end
            P_ENGINE: begin
                if (done74[2] != seen_done) begin
                    seen_done <= done74[2];
                    discard_preload <= 1;
                    timer74 <= 0;
                    protocol_error <= done_code;
                    if (operation_load) begin
                        savestate_load_busy_s <= 0;
                        savestate_load_ok_s <= !done_error;
                        savestate_load_err_s <= done_error;
                        pstate <= done_quarantine ? P_QUARANTINE : P_IDLE;
                    end else begin
                        savestate_start_busy_s <= 0;
                        savestate_start_ok_s <= !done_error;
                        savestate_start_err_s <= done_error;
                        saved_checksum <= checksum_mailbox;
                        read_next <= 0;
                        read_bad <= 0;
                        pstate <= done_error ? (done_quarantine ? P_QUARANTINE : P_IDLE) : P_SAVE_READY;
                    end
                end else if (timer74 >= TIMEOUT_COMMAND) begin
                    if (operation_load) begin reject_load(E_TIMEOUT); savestate_load_busy_s <= 0; end
                    else begin reject_start(E_TIMEOUT); savestate_start_busy_s <= 0; end
                    abort_toggle <= ~abort_toggle;
                    discard_preload <= 1;
                    pstate <= P_QUARANTINE;
                end
            end
            P_SAVE_READY: begin
                // Busy ends when snapshot is complete, before firmware reads.
                // Keep snapshot locked while firmware reads exact byte count.
                if (!start_event && !load_event && !wr_event) begin
                    if (reset74[2] || !allow74[2]) begin
                        reject_start(E_RESET); pstate <= P_IDLE;
                    end else if (rd_event) begin
                        timer74 <= 0;
                        if (offset != read_next || offset[1:0] != 0 || offset >= saved_size + HEADER_SIZE) begin
                            read_bad <= 1;
                            reject_start(E_COVERAGE);
                        end else begin
                            read_next <= read_next + 4;
                            if (offset + 4 == saved_size + HEADER_SIZE) begin
                                pstate <= P_READ_DRAIN;
                                timer74 <= 0;
                                if (read_bad) reject_start(E_COVERAGE);
                            end
                        end
                    end else if (timer74 >= TIMEOUT_READBACK) begin
                        reject_start(E_TIMEOUT); pstate <= P_IDLE;
                    end
                end
                // Beginning a new staged load invalidates the prior snapshot,
                // so no read can race a payload write to the same PSRAM region.
                if (wr_event && !start_event && !load_event) begin
                    savestate_start_ok_s <= 0;
                    pstate <= P_IDLE;
                end
            end
            P_READ_DRAIN: begin
                // APF has accepted the final address, but data_unloader still
                // has a crossing FIFO and response pipeline. Retain the lock
                // for a conservative >=256 clk74 cycles AND transport idle.
                // The stage-1 loader/unloader timing is bounded below 256;
                // a future variable-latency ingress must export completion.
                if (reset74[2]) begin reject_start(E_RESET); pstate <= P_IDLE; end
                else if (timer74 >= 256 && idle74[2]) pstate <= P_IDLE;
                else if (timer74 >= TIMEOUT_READBACK) begin reject_start(E_TIMEOUT); pstate <= P_IDLE; end
            end
            P_QUARANTINE: begin
                seen_done <= done74[2];
                if (saw_reset && !reset74[2]) begin
                    pstate <= P_IDLE;
                    discard_preload <= 1;
                    saw_reset <= 0;
                end
            end
            default: pstate <= P_QUARANTINE;
        endcase
    end
endmodule
