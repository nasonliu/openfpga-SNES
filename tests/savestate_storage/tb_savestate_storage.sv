`timescale 1ns/1ps
// Transaction regression using production bridge, shim and PSRAM controller.
// The external PSRAM array is a functional pin model, not a timing signoff model.
module tb_savestate_storage #(parameter real SYS_HALF=23.28, MEM_HALF=5.82, MEM_PHASE=0.0);
  reg clk_sys=0, clk_mem=0;
  always #(SYS_HALF) clk_sys=~clk_sys;
  initial begin #(MEM_PHASE); forever #(MEM_HALF) clk_mem=~clk_mem; end
  reg reset_n=0, abort=0, save_begin=0, stage_clear=0;
  reg [19:0] stage_expected_bytes=64;
  wire fault, stage_idle, stage_complete, transport_idle, save_complete;
  wire [19:0] stage_bytes_committed;
  wire [31:0] saved_payload_checksum;
  reg [63:0] ss_ddr_do=0;
  reg [21:3] ss_ddr_addr=0;
  reg [7:0] ss_ddr_be=8'hff;
  reg ss_ddr_we=0,ss_ddr_req=0,ss_busy=0,blocked=0,ctrl_idle=1;
  wire [63:0] ss_ddr_di;
  wire ss_ddr_ack,stage_lost;
  reg stage_wr=0;
  reg [19:0] stage_addr=0;
  reg [15:0] stage_data=0;
  reg blob_rd=0;
  reg [19:0] blob_addr=0;
  wire [15:0] blob_q;
  wire [21:16] cram_a;
  wire [15:0] cram_dq;
  wire cram_wait=0;
  wire cram_clk,cram_adv_n,cram_cre,cram_ce0_n,cram_ce1_n;
  wire cram_oe_n,cram_we_n,cram_ub_n,cram_lb_n;
  savestate dut(.*);
  reg [15:0] ram[0:2047];
  reg [21:0] ram_addr=0;
  always @(posedge cram_adv_n) if (!cram_ce0_n) ram_addr={cram_a,cram_dq};
  always @(negedge clk_mem) if (!cram_ce0_n && !cram_we_n && cram_adv_n) begin
    if (!cram_lb_n) ram[ram_addr[10:0]][7:0]=cram_dq[7:0];
    if (!cram_ub_n) ram[ram_addr[10:0]][15:8]=cram_dq[15:8];
  end
  assign cram_dq=(!cram_ce0_n && !cram_oe_n && cram_we_n) ? ram[ram_addr[10:0]] : 16'hzzzz;
  task tick_sys(input integer n); repeat(n) @(negedge clk_sys); endtask
  task drain;
    integer n;
    begin n=0; tick_sys(6); while(!transport_idle && n<1000) begin tick_sys(1);n++;end
      if(!transport_idle)$fatal(1,"drain timeout");
    end
  endtask
  task reset;
    begin reset_n=0;ss_ddr_req=0;ss_ddr_we=0;ss_busy=0;abort=0;stage_wr=0;blob_rd=0;
      tick_sys(5);reset_n=1;tick_sys(12);if(fault)$fatal(1,"fault after reset");end
  endtask
  task start_save;
    begin drain();save_begin=1;tick_sys(1);save_begin=0;ss_busy=1;tick_sys(6);end
  endtask
  task request(input bit wr,input integer qword,input [63:0] data);
    integer n;
    begin
      @(negedge clk_sys);ss_ddr_we=wr;ss_ddr_addr=qword;ss_ddr_do=data;ss_ddr_req=~ss_ddr_req;
      tick_sys(1);ss_ddr_we=0;ss_ddr_addr=0;ss_ddr_do=0;
      n=0;while(ss_ddr_ack!==ss_ddr_req && n<1000) begin tick_sys(1);n++;end
      if(n==1000)$fatal(1,"request timeout");
    end
  endtask
  task read_blob(input integer a,input [15:0] expected);
    begin @(negedge clk_mem);blob_addr=a;blob_rd=1;repeat(30)@(negedge clk_mem);
      if(blob_q!==expected)$fatal(1,"blob mismatch addr=%0d q=%h expected=%h",a,blob_q,expected);
      blob_rd=0;repeat(4)@(negedge clk_mem);end
  endtask
  task clear_stage;
    begin drain();stage_clear=1;tick_sys(1);stage_clear=0;tick_sys(6);end
  endtask
  task stage(input integer a,input [15:0] data);
    begin @(negedge clk_mem);stage_addr=a;stage_data=data;stage_wr=1;
      @(negedge clk_mem);stage_wr=0;repeat(15)@(negedge clk_mem);end
  endtask
  integer i;reg [31:0] expected;
  initial begin
    for(i=0;i<2048;i++)ram[i]=16'hdead;
    reset();start_save();ss_busy=0;drain();
    if(save_complete)$fatal(1,"busy-only fake save accepted");
    start_save();
    request(1,1,64'h0706050453454e53);
    request(1,2,64'h1716151413121110);
    request(1,0,64'h0000000600000001);
    ss_busy=0;drain();
    expected=32'h53454e53+32'h07060504+32'h13121110+32'h17161514+32'd6+32'd1;
    if(saved_payload_checksum!==expected)$fatal(1,"checksum %h != %h",saved_payload_checksum,expected);
    if(fault||!save_complete)$fatal(1,"valid save not sealed");
    read_blob(8,16'h4e53);read_blob(10,16'h5345);read_blob(22,16'h1716);read_blob(24,0);read_blob(300,0);
    // Two sequential reads exercise prefetch and the pending request slot.
    ss_busy=1;request(0,1,0);if(ss_ddr_di!==64'h0706050453454e53)$fatal(1,"direct read got=%h ram=%h %h %h %h",ss_ddr_di,ram[4],ram[5],ram[6],ram[7]);
    request(0,2,0);if(ss_ddr_di!==64'h1716151413121110)$fatal(1,"prefetched read");
    ss_busy=0;drain();
    // A prefetch completed after a walk boundary must not regain validity.
    ss_busy=1;request(0,1,0);ss_busy=0;tick_sys(1);drain();
    ram[8]=16'hbabe;request(0,2,0);
    if(ss_ddr_di[15:0]!==16'hbabe)$fatal(1,"stale prefetch crossed walk boundary");
    drain();
    stage_expected_bytes=16;clear_stage();
    if(save_complete)$fatal(1,"load stage retained old save seal");
    for(i=0;i<7;i++)stage(i*2,16'h1000+i);
    if(stage_complete)$fatal(1,"stage complete before last committed word");
    stage(14,16'h1007);drain();
    if(!stage_complete||stage_bytes_committed!=16||stage_lost)$fatal(1,"stage commit accounting");
    // An out-of-order address is rejected even though no queue overflow occurs.
    clear_stage();stage(2,16'h1111);drain();
    if(!stage_lost||stage_complete)$fatal(1,"missing stage order failure");
    // Clearing explicitly recovers a rejected upload, not an engine fault.
    clear_stage();if(stage_lost)$fatal(1,"stage clear");
    blocked=1;tick_sys(5);
    @(negedge clk_mem);stage_wr=1;stage_addr=0;stage_data=1;
    @(negedge clk_mem);stage_wr=0;
    @(negedge clk_mem);stage_wr=1;stage_addr=2;stage_data=2;
    @(negedge clk_mem);stage_wr=0;
    tick_sys(5);if(!stage_lost)$fatal(1,"missing overflow failure");
    blocked=0;drain();
    stage_expected_bytes=64;reset();start_save();
    // Abort after request acceptance lets the physical operation finish.
    ss_ddr_we=1;ss_ddr_addr=1;ss_ddr_do=64'h1122334453454e53;ss_ddr_req=1;
    tick_sys(1);ss_ddr_we=0;tick_sys(3);abort=1;tick_sys(1);abort=0;
    tick_sys(80);if(!fault||ss_ddr_ack!=1)$fatal(1,"abort failed to drain accepted request");
    reset();start_save();ss_ddr_be=8'h0f;
    request(1,1,64'h12345678);tick_sys(10);if(!fault)$fatal(1,"partial byte enables not rejected");
    ss_ddr_be=8'hff;
    reset();start_save();request(1,1,64'h0706050453454e53);
    request(1,0,64'h0001000000000001);tick_sys(10);
    if(!fault||save_complete)$fatal(1,"invalid final header accepted");
    reset();start_save();
    ss_ddr_we=1;ss_ddr_addr=1;ss_ddr_do=64'habcd;ss_ddr_req=1;tick_sys(4);reset();
    start_save();request(1,1,64'h9988776653454e53);request(1,0,64'h0000000400000002);ss_busy=0;drain();
    if(fault)$fatal(1,"reset recovery");read_blob(8,16'h4e53);
    $display("PASS storage: checksum, padding, prefetch, staging drain/order/overflow, abort, reset, byte enables");
    $finish;
  end
  initial begin #1000000;$fatal(1,"global timeout");end
endmodule
