// Capture the complete ARAM request after the SMP/DSP address decode settles.
// All fields, including the byte lane in address[0], belong to the same sys
// falling edge. The 4x SRAM controller may accept this level-held packet more
// than once, just as it did the original request.
//
// The caller must include memory_write | memory_read in its quiescence test,
// in addition to the physical controller's busy output: a stopped upstream
// request can still be queued here until the next falling edge.
module aram_request_stage (
    input wire clk_sys,
    input wire reset_n,
    input wire write_en,
    input wire read_en,
    input wire [15:0] address,
    input wire [7:0] data,
    output reg memory_write = 0,
    output reg memory_read = 0,
    output reg [15:0] memory_address = 0,
    output reg [7:0] memory_data = 0
);
  always @(negedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
      memory_write <= 0;
      memory_read <= 0;
      memory_address <= 0;
      memory_data <= 0;
    end else begin
      memory_write <= write_en;
      memory_read <= read_en;
      memory_address <= address;
      memory_data <= data;
    end
  end
endmodule
