// Async SRAM controller, copied from agg23's openfpga-litex.
// MIT License. Copyright (c) 2023 Adam Gastineau.

module sram #(
    parameter CLOCK_SPEED_MHZ = 74.25,  // Clock speed in megahertz
    parameter MIN_OP_CYCLE_TIME_NANO_SEC = 55
) (
    input wire clk,

    input wire reset,

    input wire [1:0] mask,
    input wire wr,
    input wire rd,

    input  wire [16:0] addr,
    input  wire [15:0] data,
    output reg  [15:0] q = 0,

    output wire ready,

    // SRAM Interface
    output reg  [16:0] sram_a = 0,
    inout  wire [15:0] sram_dq,
    output reg         sram_oe_n = 1,
    output reg         sram_we_n = 1,
    output reg         sram_ub_n = 1,
    output reg         sram_lb_n = 1
);
  function integer rtoi(input integer x);
    return x;
  endfunction

  `define CEIL(x) ((rtoi(x) > x) ? rtoi(x) : rtoi(x) + 1)

  localparam CLOCK_PERIOD_NANO_SEC = 1000.0 / CLOCK_SPEED_MHZ;  // In nanoseconds

  localparam CYCLES_PER_OP =
  `CEIL(MIN_OP_CYCLE_TIME_NANO_SEC / CLOCK_PERIOD_NANO_SEC);

  reg use_write = 0;
  reg [15:0] current_write_data = 0;

  reg [3:0] wait_counter = 0;

  assign sram_dq = use_write ? current_write_data : 16'hZZZZ;

  localparam INIT_STATE = 0;
  localparam WAIT_STATE = 1;

  localparam HOLD_STATE = 2;
  localparam RECOVER_STATE = 3;
  localparam WRITE_SETUP_STATE = 4;
  reg [1:0] pending_mask = 0;
  reg [2:0] state = 0;

  assign ready = state == INIT_STATE;

  always @(posedge clk) begin
    if (reset) begin
      q <= 16'h0;
      state <= INIT_STATE;
      wait_counter <= 0;
      pending_mask <= 0;
      use_write <= 0;

      sram_a <= 17'h0;
      sram_oe_n <= 1'b1;
      sram_we_n <= 1'b1;
      sram_ub_n <= 1'b1;
      sram_lb_n <= 1'b1;
    end else begin
      case (state)
        INIT_STATE: begin
          // Disable both bytes. Standby
          use_write <= 0;
          sram_we_n <= 1;
          sram_oe_n <= 1;
          sram_ub_n <= 1'b1;
          sram_lb_n <= 1'b1;

          if (wr) begin
            state <= WRITE_SETUP_STATE;
            wait_counter <= CYCLES_PER_OP;

            sram_a <= addr;
            current_write_data <= data;
            use_write <= 1'b1;

            // Establish address/data while every write-opening control is high.
            sram_oe_n <= 1'b1;
            pending_mask <= mask;
          end else if (rd) begin
            state <= WAIT_STATE;
            // One extra read clock covers routed byte-enable and DQ setup.
            wait_counter <= CYCLES_PER_OP + 1;

            sram_a <= addr;
            use_write <= 1'b0;

            sram_oe_n <= 1'b0;
            sram_we_n <= 1'b1;
            {sram_ub_n, sram_lb_n} <= ~mask;
          end
        end
        WAIT_STATE: begin
          if (wait_counter > 0) begin
            wait_counter <= wait_counter - 4'h1;
          end else begin
            state <= HOLD_STATE;
            // End every access before the next address can be accepted.
            // Level-held writes must still have a full idle clock between WE pulses.
            sram_we_n <= 1'b1;
            sram_oe_n <= 1'b1;
            sram_ub_n <= 1'b1;
            sram_lb_n <= 1'b1;
            // Hold the last write byte through the complete next clock.

            if (~use_write) begin
              // Completed read, grab data
              q <= sram_dq;
            end
          end
        end
        WRITE_SETUP_STATE: begin
          sram_we_n <= 1'b0;
          {sram_ub_n, sram_lb_n} <= ~pending_mask;
          wait_counter <= CYCLES_PER_OP;
          state <= WAIT_STATE;
        end
        HOLD_STATE: begin
          use_write <= 1'b0;
          state <= RECOVER_STATE;
        end
        RECOVER_STATE: begin
          state <= INIT_STATE;
        end
      endcase
    end
  end

endmodule
