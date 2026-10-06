// Included in the generated combined bench. No state data is provided by the
// scoreboard: engine DI and ACK are driven solely by production storage RTL.
 reg clk_mem=0;always #5.82 clk_mem=~clk_mem;
 reg storage_save_begin=0;
 wire storage_fault,storage_stage_idle,storage_stage_complete,storage_idle,storage_saved,storage_stage_lost;
 wire [19:0] storage_committed;
 wire [31:0] storage_checksum;
 wire [21:16] cram_a;
 wire [15:0] cram_dq;
 wire cram_wait,cram_clk,cram_adv_n,cram_cre,cram_ce0_n,cram_ce1_n,cram_oe_n,cram_we_n,cram_ub_n,cram_lb_n;
 savestate storage(
 .clk_sys(clk),.clk_mem(clk_mem),.reset_n(reset_n),.abort(1'b0),.save_begin(storage_save_begin),.stage_clear(1'b0),.stage_expected_bytes(20'h80000),
 .fault(storage_fault),.stage_idle(storage_stage_idle),.stage_complete(storage_stage_complete),.transport_idle(storage_idle),.save_complete(storage_saved),.stage_bytes_committed(storage_committed),.saved_payload_checksum(storage_checksum),
 .ss_ddr_do(ddro),.ss_ddr_addr(ddra),.ss_ddr_be(ddrbe),.ss_ddr_we(ddrwe),.ss_ddr_req(ddrreq),.ss_ddr_di(ddri),.ss_ddr_ack(ddrack),
 .ss_busy(busy),.blocked(1'b0),.ctrl_idle(!save&&!load&&!busy),.stage_lost(storage_stage_lost),.stage_wr(1'b0),.stage_addr(20'b0),.stage_data(16'b0),.blob_rd(1'b0),.blob_addr(20'b0),.blob_q(),
 .cram_a(cram_a),.cram_dq(cram_dq),.cram_wait(cram_wait),.cram_clk(cram_clk),.cram_adv_n(cram_adv_n),.cram_cre(cram_cre),.cram_ce0_n(cram_ce0_n),.cram_ce1_n(cram_ce1_n),.cram_oe_n(cram_oe_n),.cram_we_n(cram_we_n),.cram_ub_n(cram_ub_n),.cram_lb_n(cram_lb_n));
 pin_psram_model pinram(.clk_mem(clk_mem),.cram_a(cram_a),.cram_dq(cram_dq),.cram_wait(cram_wait),.cram_clk(cram_clk),.cram_adv_n(cram_adv_n),.cram_cre(cram_cre),.cram_ce0_n(cram_ce0_n),.cram_ce1_n(cram_ce1_n),.cram_oe_n(cram_oe_n),.cram_we_n(cram_we_n),.cram_ub_n(cram_ub_n),.cram_lb_n(cram_lb_n));
 reg request_seen=0,request_active=0;
 integer request_start_cycle=0,read_ack_max=0,read_ack_min=1000000,write_ack_max=0,read_acks=0,write_acks=0;
 integer load_byte_reads=0,unacknowledged_byte_reads=0;
 reg [31:0] independent_checksum;
 reg [63:0] physical_qword;
 // This is a passive transaction oracle. The functional pin model above is
 // the only path that can produce a successful state-memory read response.
 always @(posedge clk) begin
  if(reset_n && (storage_fault || storage_stage_lost))$fatal(1,"REAL_STORAGE_FAULT cycle=%0d stage=%0d",cycles,stage);
  if(reset_n && ddrreq!=request_seen)begin
   if(request_active)$fatal(1,"ENGINE_OVERLAPPED_REQUEST");
   if(ddra[18:17]!=0)$fatal(1,"UNEXPECTED_SAVESTATE_SLOT %h",ddra);
   request_seen<=ddrreq;request_active<=1;request_start_cycle<=cycles;
   captured_ddra<=ddra;captured_ddrreq<=ddrreq;captured_ddrwe<=ddrwe;captured_ddro<=ddro;captured_ddrbe<=ddrbe;
   if(ddrwe)begin
    for(integer k=0;k<8;k=k+1)if(ddrbe[k])blob[ddra][8*k+:8]<=ddro[8*k+:8];
    ddr_writes<=ddr_writes+1;last_ddr_write<=ddra;
   end else ddr_reads<=ddr_reads+1;
  end
  if(request_active && ddrack==captured_ddrreq)begin
   request_active<=0;
   if(captured_ddrwe)begin
    write_acks<=write_acks+1;
    if(cycles-request_start_cycle>write_ack_max)write_ack_max<=cycles-request_start_cycle;
    for(integer k=0;k<4;k=k+1)if(pinram.ram[captured_ddra*4+k]!==captured_ddro[16*k+:16])$fatal(1,"PIN_COMMIT_MISMATCH qword=%0d beat=%0d",captured_ddra,k);
   end else begin
    read_acks<=read_acks+1;
    if(ddri!==blob[captured_ddra])$fatal(1,"PIN_RETURN_MISMATCH qword=%0d got=%h expected=%h",captured_ddra,ddri,blob[captured_ddra]);
    if(cycles-request_start_cycle>read_ack_max)read_ack_max<=cycles-request_start_cycle;
    if(cycles-request_start_cycle<read_ack_min)read_ack_min<=cycles-request_start_cycle;
   end
  end
  // The real helper's DMA path cannot wait for its next qword. Check at the
  // actual A-bus data-consume edge, not merely eventual request completion.
  if(stage==4 && busy && dut.SYSCLKF_CE && !dut.CPURD_N && dut.CA==24'hc06000)begin
   load_byte_reads<=load_byte_reads+1;
   if(ddrreq!=ddrack)begin
    unacknowledged_byte_reads<=unacknowledged_byte_reads+1;
    $fatal(1,"RESTORE_DATA_DEADLINE_MISS cycle=%0d qword=%0d pending_cycles=%0d",cycles,ddra,cycles-request_start_cycle);
   end
  end
 end
 task verify_physical_save;
  integer j,guard;
  begin
   tick(12);guard=0;while(!storage_idle && guard<2000)begin tick(1);guard++;end
   if(!storage_idle || !storage_saved)$fatal(1,"REAL_STORAGE_SAVE_NOT_SEALED");
   independent_checksum=0;
   for(j=0;j<save_words;j=j+1)begin
    physical_qword={pinram.ram[j*4+3],pinram.ram[j*4+2],pinram.ram[j*4+1],pinram.ram[j*4]};
    if(physical_qword!==blob[j])$fatal(1,"PHYSICAL_SAVE_BYTES_MISMATCH qword=%0d got=%h expected=%h",j,physical_qword,blob[j]);
    independent_checksum=independent_checksum+physical_qword[31:0]+physical_qword[63:32];
   end
   if(independent_checksum!==storage_checksum)$fatal(1,"PHYSICAL_SAVE_CHECKSUM_MISMATCH actual=%h expected=%h",storage_checksum,independent_checksum);
   $display("PHYSICAL_SAVE_COMPLETE qwords=%0d bytes=%0d checksum=%h write_ack_max_sys_cycles=%0d",save_words,save_words*8,independent_checksum,write_ack_max);
  end
 endtask
