// Savestate blob bridge: clk_sys engine requests, clk_mem APF/PSRAM traffic.

module savestate (
    input wire clk_sys,
    input wire clk_mem,
    // Coordinated with the engine reset. Abort quarantines until this reset.
    input wire reset_n,
    input wire abort,
    input wire save_begin,
    input wire stage_clear,
    input wire [19:0] stage_expected_bytes,
    output reg fault = 0,
    output wire stage_idle,
    output wire stage_complete,
    output wire transport_idle,
    output reg save_complete = 0,
    output reg [19:0] stage_bytes_committed = 0,
    output reg [31:0] saved_payload_checksum = 0,

    // Savestate engine, clk_sys domain (toggle handshake, see savestates.sv)
    input wire [63:0] ss_ddr_do,
    input wire [21:3] ss_ddr_addr,
    input wire [7:0] ss_ddr_be,
    input wire ss_ddr_we,
    input wire ss_ddr_req,
    output reg [63:0] ss_ddr_di = 0,
    output reg ss_ddr_ack = 0,

    input wire ss_busy,  // engine walk active (clk_sys)

    input wire blocked,    // cart download active (clk_sys), holds blob ops off
    input wire ctrl_idle,  // command sequencer idle (clk_sys)
    output reg stage_lost = 0,  // staging dropped a word, blob incomplete (clk_mem)

    // Blob staging stream from data_loader, clk_mem domain
    input wire stage_wr,
    input wire [19:0] stage_addr,
    input wire [15:0] stage_data,

    // Blob readback stream to data_unloader, clk_mem domain
    input wire blob_rd,
    input wire [19:0] blob_addr,
    output reg [15:0] blob_q = 0,

    // Blob PSRAM pins (cram1 die), clk_mem domain
    output wire [21:16] cram_a,
    inout wire [15:0] cram_dq,
    input wire cram_wait,
    output wire cram_clk,
    output wire cram_adv_n,
    output wire cram_cre,
    output wire cram_ce0_n,
    output wire cram_ce1_n,
    output wire cram_oe_n,
    output wire cram_we_n,
    output wire cram_ub_n,
    output wire cram_lb_n
);

  reg req = 0;
  reg we = 0;
  reg [21:0] addr = 0;
  reg [15:0] din = 0;
  reg ub = 1;
  reg lb = 1;
  wire [15:0] dout;
  wire done;
  wire ram_idle;

  reg [2:0] reset_mem_pipe = 0;
  always @(posedge clk_mem or negedge reset_n) begin
    if (!reset_n) reset_mem_pipe <= 0;
    else reset_mem_pipe <= {reset_mem_pipe[1:0], 1'b1};
  end
  wire reset_mem_n = reset_mem_pipe[2];

  reg save_toggle = 0;
  reg clear_toggle = 0;
  always @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
      save_toggle <= 0;
      clear_toggle <= 0;
    end else begin
      if (save_begin) save_toggle <= ~save_toggle;
      if (stage_clear) clear_toggle <= ~clear_toggle;
    end
  end

  // clock domain: clk_sys
  reg [16:0] cmd_qaddr = 0;  // qword index within the blob
  reg [63:0] cmd_data = 0;
  reg [7:0] cmd_be = 8'hFF;
  reg cmd_we = 0;
  reg cmd_req_toggle = 0;
  wire cmd_done_s;

  reg [63:0] rsp_data = 0;  // written by clk_mem side, read after done toggles
  reg cmd_done = 0;  // toggle, clk_mem side

  // The engine consumes the load stream at DMA pace without waiting: the next
  // qword is due ~8 clk_sys after its fetch, under the ~21 clk_sys round trip
  reg [63:0] pf_data = 0;
  reg [16:0] pf_qaddr = 0;
  reg pf_valid = 0;
  reg [7:0] cache_epoch = 0;
  reg [7:0] pf_epoch = 0;

  reg prev_req = 0;
  reg prev_done = 0;
  reg prev_busy = 0;
  reg req_pending = 0;

  // The engine drives we/address/data for one cycle around the request
  // toggle; a toggle landing while a fetch is in flight is captured here
  reg [16:0] req_qaddr_r = 0;
  reg [63:0] req_data_r = 0;
  reg [7:0] req_be_r = 8'hFF;
  reg req_we_r = 0;

  reg [2:0] done_sync = 0;
  reg [2:0] fault_sync = 0;
  reg fault_mem = 0;
  assign cmd_done_s = done_sync[2];
  always @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
      done_sync <= 0;
      fault_sync <= 0;
    end else begin
      done_sync <= {done_sync[1:0], cmd_done};
      fault_sync <= {fault_sync[1:0], fault_mem};
    end
  end

  localparam ENG_IDLE = 2'd0;
  localparam ENG_WAIT_DIRECT = 2'd1;
  localparam ENG_WAIT_PF = 2'd2;

  reg [1:0] eng_state = ENG_IDLE;

  // Bits [21:20] are the save slot; dropped since SS_SLOT is tied to 0
  wire [16:0] req_qaddr = ss_ddr_addr[19:3];

  wire req_toggled = ss_ddr_req != prev_req && !fault && !abort;

  // Serve an idle toggle from the live inputs, a buffered one from the capture
  wire dispatch_we = req_toggled ? ss_ddr_we : req_we_r;
  wire [16:0] dispatch_qaddr = req_toggled ? req_qaddr : req_qaddr_r;
  wire [63:0] dispatch_data = req_toggled ? ss_ddr_do : req_data_r;
  wire [7:0] dispatch_be = req_toggled ? ss_ddr_be : req_be_r;

  always @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
      prev_req <= 0;
      prev_busy <= 0;
      prev_done <= 0;
      req_pending <= 0;
      req_qaddr_r <= 0;
      req_data_r <= 0;
      req_be_r <= 8'hFF;
      req_we_r <= 0;
      cmd_qaddr <= 0;
      cmd_data <= 0;
      cmd_be <= 8'hFF;
      cmd_we <= 0;
      cmd_req_toggle <= 0;
      ss_ddr_di <= 0;
      ss_ddr_ack <= 0;
      pf_valid <= 0;
      pf_qaddr <= 0;
      pf_data <= 0;
      cache_epoch <= 0;
      pf_epoch <= 0;
      eng_state <= ENG_IDLE;
      fault <= 0;
    end else begin
    if (abort || fault_sync[2]) fault <= 1;
    prev_req  <= ss_ddr_req;
    prev_busy <= ss_busy;
    prev_done <= cmd_done_s;

    // Drop prefetch on a walk boundary so it can't return stale data
    if (ss_busy != prev_busy) begin
      pf_valid <= 0;
    end

    if (req_toggled) begin
      req_qaddr_r <= req_qaddr;
      req_data_r <= ss_ddr_do;
      req_be_r <= ss_ddr_be;
      req_we_r <= ss_ddr_we;
      if (eng_state != ENG_IDLE) begin
        if (req_pending) fault <= 1;
        req_pending <= 1;
      end
    end

    case (eng_state)
      ENG_IDLE: begin
        if (req_toggled || req_pending) begin
          req_pending <= 0;

          if (dispatch_we) begin
            cmd_qaddr <= dispatch_qaddr;
            cmd_data <= dispatch_data;
            cmd_be <= dispatch_be;
            cmd_we <= 1;
            cmd_req_toggle <= ~cmd_req_toggle;
            eng_state <= ENG_WAIT_DIRECT;
          end else if (pf_valid && pf_qaddr == dispatch_qaddr) begin
            ss_ddr_di <= pf_data;
            ss_ddr_ack <= ~ss_ddr_ack;
            pf_valid <= 0;
            cmd_qaddr <= dispatch_qaddr + 1'd1;
            cmd_we <= 0;
            cmd_req_toggle <= ~cmd_req_toggle;
            pf_epoch <= cache_epoch;
            eng_state <= ENG_WAIT_PF;
          end else begin
            cmd_qaddr <= dispatch_qaddr;
            cmd_we <= 0;
            cmd_req_toggle <= ~cmd_req_toggle;
            eng_state <= ENG_WAIT_DIRECT;
          end
        end
      end

      ENG_WAIT_DIRECT: begin
        if (cmd_done_s != prev_done) begin
          if (~cmd_we) begin
            ss_ddr_di <= rsp_data;
          end
          ss_ddr_ack <= ~ss_ddr_ack;

          if (~cmd_we && !fault && !abort && !fault_sync[2]) begin
            // Chain the prefetch of the next sequential qword
            cmd_qaddr <= cmd_qaddr + 1'd1;
            cmd_req_toggle <= ~cmd_req_toggle;
            pf_epoch <= cache_epoch;
            eng_state <= ENG_WAIT_PF;
          end else begin
            eng_state <= ENG_IDLE;
          end
        end
      end

      ENG_WAIT_PF: begin
        if (cmd_done_s != prev_done) begin
          pf_data <= rsp_data;
          pf_qaddr <= cmd_qaddr;
          pf_valid <= pf_epoch == cache_epoch;
          eng_state <= ENG_IDLE;
        end
      end

      default: eng_state <= ENG_IDLE;
    endcase
    if (ss_busy != prev_busy || save_begin || stage_clear || fault || abort) begin
      pf_valid <= 0;
    end
    if (ss_busy != prev_busy || save_begin || stage_clear) begin
      cache_epoch <= cache_epoch + 1'b1;
    end
    end
  end

  // clock domain: clk_mem
  wire cmd_req_toggle_m;
  wire blocked_m;
  wire ctrl_idle_m;

  reg [2:0] req_sync = 0;
  reg [2:0] save_sync = 0;
  reg [2:0] clear_sync = 0;
  reg [2:0] fault_to_mem = 0;
  reg [2:0] engine_idle_sync = 0;
  reg [2:0] blocked_sync = 0;
  reg [2:0] ctrl_idle_sync = 0;
  reg prev_save_m = 0;
  reg prev_clear_m = 0;
  wire engine_idle = eng_state == ENG_IDLE && !req_pending && !req_toggled &&
                     ss_ddr_req == ss_ddr_ack;
  wire save_begin_m = save_sync[2] != prev_save_m;
  wire stage_clear_m = clear_sync[2] != prev_clear_m;
  assign cmd_req_toggle_m = req_sync[2];
  assign blocked_m = blocked_sync[2];
  assign ctrl_idle_m = ctrl_idle_sync[2];
  always @(posedge clk_mem or negedge reset_mem_n) begin
    if (!reset_mem_n) begin
      req_sync <= 0;
      save_sync <= 0;
      clear_sync <= 0;
      fault_to_mem <= 0;
      engine_idle_sync <= 0;
      blocked_sync <= 0;
      ctrl_idle_sync <= 0;
      prev_save_m <= 0;
      prev_clear_m <= 0;
    end else begin
      req_sync <= {req_sync[1:0], cmd_req_toggle};
      save_sync <= {save_sync[1:0], save_toggle};
      clear_sync <= {clear_sync[1:0], clear_toggle};
      fault_to_mem <= {fault_to_mem[1:0], fault};
      engine_idle_sync <= {engine_idle_sync[1:0], engine_idle};
      blocked_sync <= {blocked_sync[1:0], blocked};
      ctrl_idle_sync <= {ctrl_idle_sync[1:0], ctrl_idle};
      prev_save_m <= save_sync[2];
      prev_clear_m <= clear_sync[2];
    end
  end

  reg prev_req_toggle_m = 0;
  reg cmd_pending = 0;

  // One-entry stage: the drain (15 clk_mem) beats the loader floor (16 clk_mem
  // per word, ~43 sustained) and APF slots never overlap; stage_lost rejects
  // the load on a drop
  reg [35:0] stage_q = 0;
  reg stage_pending = 0;
  reg stage_rdreq = 0;

  wire stage_pop = stage_rdreq && stage_pending;

  always @(posedge clk_mem or negedge reset_mem_n) begin
    if (!reset_mem_n) begin
      stage_q <= 0;
      stage_pending <= 0;
      stage_lost <= 0;
    end else begin
      if (stage_clear_m) stage_lost <= 0;
      if (stage_wr && !fault_to_mem[2] && (~stage_pending || stage_pop)) begin
        stage_q <= {stage_addr, stage_data};
        stage_pending <= 1;
      end else if (stage_pop) begin
        stage_pending <= 0;
      end
      if (stage_wr && (fault_to_mem[2] || (stage_pending && !stage_pop))) begin
        stage_lost <= 1;
      end
      if (arb_state == ARB_STAGE && acc_state == ACC_WAIT_DONE && done &&
          stage_q[35:16] != stage_bytes_committed) stage_lost <= 1;
    end
  end

  reg blob_pending = 0;
  reg prev_blob_rd = 0;
  reg [19:0] blob_addr_r = 0;

  localparam ARB_IDLE = 2'd0;
  localparam ARB_CMD = 2'd1;
  localparam ARB_STAGE = 2'd2;
  localparam ARB_BLOB = 2'd3;

  localparam ACC_SETUP = 2'd0;
  localparam ACC_WAIT_DONE = 2'd1;
  localparam ACC_GAP = 2'd2;

  reg [1:0] arb_state = ARB_IDLE;
  reg [1:0] acc_state = ACC_SETUP;
  reg [1:0] beat = 0;

  reg [19:0] saved_extent = 0;
  reg save_tracking = 0;
  reg saved_magic = 0;
  reg saved_padding = 0;
  reg [16:0] expected_save_qaddr = 1;
  wire [33:0] declared_save_bytes = {cmd_data[63:32], 2'b00};
  wire [15:0] write_halfword = cmd_data[{3'b000, beat, 4'b0000}+:16];
  assign stage_idle = reset_mem_n && !stage_wr && !stage_pending &&
                      arb_state != ARB_STAGE;
  assign stage_complete = stage_idle && !stage_lost &&
                          stage_expected_bytes != 0 &&
                          stage_bytes_committed == stage_expected_bytes;
  assign transport_idle = reset_mem_n && stage_idle && !blob_pending &&
                          !cmd_pending && arb_state == ARB_IDLE && ram_idle &&
                          engine_idle_sync[2] && cmd_req_toggle_m == prev_req_toggle_m;

  always @(posedge clk_mem or negedge reset_mem_n) begin
    if (!reset_mem_n) begin
      prev_req_toggle_m <= 0;
      cmd_pending <= 0;
      req <= 0;
      we <= 0;
      addr <= 0;
      din <= 0;
      ub <= 1;
      lb <= 1;
      stage_rdreq <= 0;
      blob_pending <= 0;
      prev_blob_rd <= 0;
      blob_addr_r <= 0;
      blob_q <= 0;
      arb_state <= ARB_IDLE;
      acc_state <= ACC_SETUP;
      beat <= 0;
      rsp_data <= 0;
      cmd_done <= 0;
      stage_bytes_committed <= 0;
      saved_extent <= 0;
      save_tracking <= 0;
      saved_magic <= 0;
      save_complete <= 0;
      saved_padding <= 0;
      expected_save_qaddr <= 1;
      saved_payload_checksum <= 0;
      fault_mem <= 0;
    end else begin
      if (stage_clear_m) begin
        stage_bytes_committed <= 0;
        saved_padding <= 0;
        save_complete <= 0;
        if (stage_pending || arb_state != ARB_IDLE) fault_mem <= 1;
      end
      if (save_begin_m) begin
        saved_payload_checksum <= 0;
        saved_extent <= 0;
        save_tracking <= 1;
        saved_magic <= 0;
        save_complete <= 0;
        saved_padding <= 0;
        expected_save_qaddr <= 1;
        if (stage_pending || arb_state != ARB_IDLE) fault_mem <= 1;
      end
    prev_req_toggle_m <= cmd_req_toggle_m;
    if (cmd_req_toggle_m != prev_req_toggle_m) begin
      cmd_pending <= 1;
    end

    req <= 0;
    stage_rdreq <= 0;

    // Edge-trigger the blob read: data_unloader holds read_en for the whole
    // READ_MEM_CLOCK_DELAY window, so one read per assertion, held until sampled
    prev_blob_rd <= blob_rd;
    if (blob_rd && ~prev_blob_rd && !fault_to_mem[2]) begin
      blob_addr_r  <= blob_addr;
      blob_pending <= 1;
    end

    case (arb_state)
      ARB_IDLE: begin
        acc_state <= ACC_SETUP;
        beat <= 0;

        // Priority: unloader read, staging, engine. The unloader samples at a
        // fixed delay and can't wait; staging outranks the engine so a load's
        // header read never sees still-queued words as stale
        if (blob_pending && ~blocked_m) begin
          arb_state <= ARB_BLOB;
        end else if (stage_pending && ~blocked_m) begin
          arb_state <= ARB_STAGE;
        end else if (cmd_pending && ~blocked_m) begin
          cmd_pending <= 0;
          if (cmd_we && (!save_tracking || cmd_be != 8'hFF ||
              (cmd_qaddr != expected_save_qaddr && cmd_qaddr != 0) ||
              (cmd_qaddr == 0 && expected_save_qaddr == 1) ||
              ({1'b0, cmd_qaddr, 3'b000} + 21'd8 > {1'b0, stage_expected_bytes}))) begin
            fault_mem <= 1;
          end
          arb_state <= ARB_CMD;
        end
      end

      ARB_CMD: begin
        case (acc_state)
          ACC_SETUP: begin
            if (cmd_we && cmd_be[{beat, 1'b0}+:2] == 2'b00) begin
              // Byte enables skip this half word (8'hF0 header write keeps count)
              acc_state <= ACC_GAP;
            end else begin
              addr <= {3'b000, cmd_qaddr, beat};
              din <= cmd_data[{3'b000, beat, 4'b0000}+:16];
              ub <= ~cmd_we | cmd_be[{beat, 1'b0}+1];
              lb <= ~cmd_we | cmd_be[{beat, 1'b0}];
              we <= cmd_we;
              req <= 1;
              acc_state <= ACC_WAIT_DONE;
            end
          end
          ACC_WAIT_DONE: begin
            if (done) begin
              if (~cmd_we) begin
                rsp_data[{3'b000, beat, 4'b0000}+:16] <= dout;
              end else begin
                saved_payload_checksum <= saved_payload_checksum +
                    (beat[0] ? {write_halfword, 16'd0} : {16'd0, write_halfword});
              end
              acc_state <= ACC_GAP;
            end
          end
          ACC_GAP: begin
            acc_state <= ACC_SETUP;
            beat <= beat + 1'd1;
            if (beat == 2'd3) begin
              cmd_done <= ~cmd_done;
              if (cmd_we) begin
                if (cmd_qaddr == 0) begin
                  save_tracking <= 0;
                  if (saved_magic && !fault_mem && !fault_to_mem[2] &&
                      declared_save_bytes >= 34'd8 &&
                      declared_save_bytes <= {14'd0, saved_extent} &&
                      declared_save_bytes + 34'd8 >= {14'd0, saved_extent} &&
                      {14'd0, saved_extent} <= {14'd0, stage_expected_bytes}) begin
                    saved_padding <= 1;
                    save_complete <= 1;
                  end else begin
                    save_complete <= 0;
                    fault_mem <= 1;
                  end
                end else begin
                  expected_save_qaddr <= cmd_qaddr + 1'b1;
                  saved_extent <= {cmd_qaddr, 3'b000} + 20'd8;
                  if (cmd_qaddr == 1) begin
                    saved_magic <= cmd_data[31:0] == 32'h53454e53;
                    if (cmd_data[31:0] != 32'h53454e53) fault_mem <= 1;
                  end
                end
              end
              arb_state <= ARB_IDLE;
            end
          end
          default: acc_state <= ACC_SETUP;
        endcase
      end

      ARB_STAGE: begin
        case (acc_state)
          ACC_SETUP: begin
            addr <= {3'b000, stage_q[35:17]};
            din <= stage_q[15:0];
            ub <= 1;
            lb <= 1;
            we <= 1;
            req <= 1;
            acc_state <= ACC_WAIT_DONE;
          end
          ACC_WAIT_DONE: begin
            // Pop here, not in ACC_GAP, so empty has settled by ARB_IDLE
            if (done) begin
              stage_rdreq <= 1;
              stage_bytes_committed <= stage_bytes_committed + 20'd2;
              acc_state <= ACC_GAP;
            end
          end
          ACC_GAP: begin
            arb_state <= ARB_IDLE;
          end
          default: acc_state <= ACC_SETUP;
        endcase
      end

      ARB_BLOB: begin
        case (acc_state)
          ACC_SETUP: begin
            addr <= {3'b000, blob_addr_r[19:1]};
            ub <= 1;
            lb <= 1;
            we <= 0;
            if (saved_padding && blob_addr_r >= saved_extent) begin
              blob_q <= 0;
              acc_state <= ACC_GAP;
            end else begin
              req <= 1;
              acc_state <= ACC_WAIT_DONE;
            end
          end
          ACC_WAIT_DONE: begin
            if (done) begin
              blob_q <= dout;
              acc_state <= ACC_GAP;
            end
          end
          ACC_GAP: begin
            blob_pending <= 0;
            arb_state <= ARB_IDLE;
          end
          default: acc_state <= ACC_SETUP;
        endcase
      end

      default: arb_state <= ARB_IDLE;
    endcase
    end
  end

  psram_blob ss_psram (
      .clk(clk_mem),
      .reset_n(reset_mem_n),
      .idle(ram_idle),

      .req (req),
      .we  (we),
      .addr(addr),
      .din (din),
      .ub  (ub),
      .lb  (lb),
      .dout(dout),
      .done(done),

      .cram_a(cram_a),
      .cram_dq(cram_dq),
      .cram_wait(cram_wait),
      .cram_clk(cram_clk),
      .cram_adv_n(cram_adv_n),
      .cram_cre(cram_cre),
      .cram_ce0_n(cram_ce0_n),
      .cram_ce1_n(cram_ce1_n),
      .cram_oe_n(cram_oe_n),
      .cram_we_n(cram_we_n),
      .cram_ub_n(cram_ub_n),
      .cram_lb_n(cram_lb_n)
  );

endmodule
