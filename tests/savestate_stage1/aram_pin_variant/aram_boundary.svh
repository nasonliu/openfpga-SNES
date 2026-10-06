// ARAM SRAM boundary: production controller, optional production packet stage.
// No behavioral array can supply main.ARAM_Q directly.
 wire aram_memory_write,aram_memory_read;
 wire [15:0] aram_memory_address;
 wire [7:0] aram_memory_data;
 wire [15:0] aram_word_q;
 wire aram_physical_busy;
 wire [16:0] aram_sram_a;
 wire [15:0] aram_sram_dq;
 wire aram_sram_oe_n,aram_sram_we_n,aram_sram_ub_n,aram_sram_lb_n;
 generate if(TEST_ARAM_STAGE)begin: staged_aram
  aram_request_stage request_stage(.clk_sys(clk),.reset_n(reset_n),
   .write_en(!ac&&!aw),.read_en(!ac&&!ao),.address(aa),.data(ad),
   .memory_write(aram_memory_write),.memory_read(aram_memory_read),
   .memory_address(aram_memory_address),.memory_data(aram_memory_data));
 end else begin: direct_aram
  assign aram_memory_write=!ac&&!aw;
  assign aram_memory_read=!ac&&!ao;
  assign aram_memory_address=aa;
  assign aram_memory_data=ad;
 end endgenerate
 sram_ctrl aram_controller(.clk(clk_mem),.reset_n(reset_n),
  .addr(aram_memory_address[15:1]),.write_en(aram_memory_write),.read_en(aram_memory_read),
  .data_in(aram_memory_address[0]?{aram_memory_data,8'b0}:{8'b0,aram_memory_data}),
  .write_high_byte(aram_memory_address[0]),.write_low_byte(!aram_memory_address[0]),
  .data_out(aram_word_q),.busy(aram_physical_busy),.sram_a(aram_sram_a),.sram_dq(aram_sram_dq),
  .sram_oe_n(aram_sram_oe_n),.sram_we_n(aram_sram_we_n),.sram_ub_n(aram_sram_ub_n),.sram_lb_n(aram_sram_lb_n));
 pin_sram_model aram_pins(.clk_mem(clk_mem),.reset_n(reset_n),
  .sram_a(aram_sram_a),.sram_dq(aram_sram_dq),.sram_oe_n(aram_sram_oe_n),
  .sram_we_n(aram_sram_we_n),.sram_ub_n(aram_sram_ub_n),.sram_lb_n(aram_sram_lb_n));
 // The production wrapper deliberately selects the current byte lane on return;
 // the staged packet's byte lane belongs to the outgoing transaction only.
 assign aq=aa[0]?aram_word_q[15:8]:aram_word_q[7:0];
 integer helper_aram_reads=0,helper_aram_writes=0,normal_aram_reads=0;
 always @(posedge clk)if(reset_n)begin
  if(busy && dut.SYSCLKF_CE && dut.SS_ARAM_SEL && !dut.PARD_N)begin
   helper_aram_reads<=helper_aram_reads+1;
   if(aq!==aram_pins.bytes[aa])$fatal(1,"HELPER_ARAM_READ_DEADLINE byte=%h got=%h expected=%h",aa,aq,aram_pins.bytes[aa]);
  end
  if(busy && dut.SYSCLKF_CE && dut.SS_ARAM_SEL && !dut.PAWR_N)helper_aram_writes<=helper_aram_writes+1;
  if(!busy && dut.SNES.coredsp.ce && !ac && !ao)begin
   normal_aram_reads<=normal_aram_reads+1;
   if(dut.SNES.coredsp.ram_di!==aram_pins.bytes[aa])$fatal(1,"NORMAL_ARAM_READ_DEADLINE byte=%h got=%h expected=%h",aa,dut.SNES.coredsp.ram_di,aram_pins.bytes[aa]);
  end
 end
