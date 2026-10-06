// SPDX-License-Identifier: MIT
// GATE_SESSION=1 matches production;0 removes the ACK-to-allcomplete gate.
`timescale 1ns/1ps
module tb_backup_session #(parameter GATE_SESSION=0, LOAD=0, WRITE_SESSION=0, SCENARIO=0, ENGINE_WALK=400);
reg clk74=0,sys=0,pll=0,wr=0,rd=0;
always #6.734 clk74=~clk74;
always #23.28 sys=~sys;
reg [31:0] addr=0,data=0;
wire host_reset_n,requestread,requestwrite,allcomplete;
wire [15:0] requestread_id;
wire queue_source_ready,queue_save_read_ready,queue_save_busy;
reg queue_save_read_request=0,read_fence_issued=0,read_fence_saw_clear=0;
wire requestread_ack=requestread&&(requestread_id!=16'd10||(read_fence_issued&&read_fence_saw_clear&&queue_save_read_ready));
always @(posedge clk74 or negedge pll) begin
 if(!pll)begin queue_save_read_request<=0;read_fence_issued<=0;read_fence_saw_clear<=0;end
 else begin
 queue_save_read_request<=0;
 if(!requestread)begin read_fence_issued<=0;read_fence_saw_clear<=0;end
 else if(requestread_id==16'd10)begin
 if(!read_fence_issued&&queue_source_ready)begin queue_save_read_request<=1;read_fence_issued<=1;read_fence_saw_clear<=0;end
 else if(read_fence_issued&&!queue_save_read_request&&!queue_save_read_ready)read_fence_saw_clear<=1;
 end end
end
// Exact production lifetime latch (core_top.sv:567-578).
reg save_download=0,allcomplete_prev=0;
always @(posedge clk74)begin
 allcomplete_prev<=allcomplete;
 if(requestread||requestwrite)save_download<=1;
 else if(allcomplete&&!allcomplete_prev)save_download<=0;
end
wire save_download_s;
synch_3 save_s(save_download,save_download_s,sys,,);
wire ss_lock,ss_save,ss_load,ss_idle,ss_abort,ss_start,ss_load_cmd;
wire start_ack,start_busy,start_ok,start_err,load_ack,load_busy,load_ok,load_err;
wire qfault,image_busy,image_begin;
// Existing mounted plain NTSC cartridge, no memory traffic at the fence.
rom_download_queue queue(.clk_74a(clk74),.clk_memory(sys),.hard_reset_n(pll),
 .bridge_wr(wr),.bridge_endian_little(1'b1),.bridge_addr(addr),.bridge_wr_data(data),
 .download_active(1'b0),.config_in(17'h00100),.write_ready(1'b1),
 .save_ready(!ss_lock),.save_busy(queue_save_busy),.source_ready(queue_source_ready),
 .save_read_request(queue_save_read_request),.save_read_ready(queue_save_read_ready),
 .save_read_quiescent(!ss_lock),.image_busy(image_busy),.image_begin(image_begin),.fault(qfault));
wire host_reset_s;
host_reset_guard guard(.clk_sys(sys),.pll_locked(pll),.host_reset_n(host_reset_n),.reset_hold(host_reset_s));
// Production reset term and four-cycle serializer reset boundary. Other reset
// causes and physical memory busy signals are inactive for this mounted cart.
reg RESET_N=0;reg[1:0]div=0;
wire reset=host_reset_s || (queue_save_busy&&!ss_lock);
always @(posedge sys)begin div<=div+1'b1;if(div==2)RESET_N<=!reset;end
wire ss_core_reset=!RESET_N;
reg busy=0,engine_drained=1,stage_complete=0,save_complete=0;
integer engine_timer=0,triggers=0;
always @(posedge sys)begin
 if(ss_core_reset)begin busy<=0;engine_drained<=1;engine_timer<=0;save_complete<=0;end
 else if(ss_save||ss_load)begin
  triggers=triggers+1;busy<=1;engine_drained<=0;save_complete<=0;engine_timer<=1;
  $display("TRIGGER load=%b backup_session=%b allcomplete=%b queue_busy=%b lock=%b t=%0t",ss_load,save_download_s,allcomplete,queue_save_busy,ss_lock,$time);
 end else if(engine_timer!=0)begin
  engine_timer<=engine_timer+1;
  if(engine_timer==ENGINE_WALK)begin busy<=0;save_complete<=1;end
  if(engine_timer==ENGINE_WALK+20)begin engine_drained<=1;engine_timer<=0;end
 end
end
savestate_controller controller(.clk_74a(clk74),.clk_sys_21_48(sys),.core_reset(ss_core_reset),
 .bridge_rd(rd),.bridge_wr(wr),.bridge_endian_little(1'b1),.bridge_addr(addr),.bridge_wr_data(data),
 .payload_size(32'd16),.rom_identity(32'hcafe0123),
 .savestate_load(ss_load_cmd),.savestate_load_ack_s(load_ack),.savestate_load_busy_s(load_busy),.savestate_load_ok_s(load_ok),.savestate_load_err_s(load_err),
 .savestate_start(ss_start),.savestate_start_ack_s(start_ack),.savestate_start_busy_s(start_busy),.savestate_start_ok_s(start_ok),.savestate_start_err_s(start_err),
 .ss_admit(!ss_core_reset&&!queue_save_busy&&(!GATE_SESSION||!save_download_s)),.ss_allow(!ss_core_reset),.ss_busy(busy),.storage_fault(1'b0),
 .stage_lost(1'b0),.stage_drained(1'b1),.stage_complete(stage_complete),.engine_drained(engine_drained),.save_complete(save_complete),.saved_payload_checksum(32'b0),
 .ss_save(ss_save),.ss_load(ss_load),.ss_idle(ss_idle),.ss_lock(ss_lock),.ss_abort(ss_abort));
core_bridge_cmd cb(.clk(clk74),.reset_n(host_reset_n),.bridge_endian_little(1'b1),.bridge_addr(addr),.bridge_rd(rd),.bridge_wr(wr),.bridge_wr_data(data),
 .status_boot_done(pll),.status_setup_done(1'b0),.status_running(host_reset_n),
 .dataslot_requestread(requestread),.dataslot_requestread_id(requestread_id),.dataslot_requestread_ack(requestread_ack),.dataslot_requestread_ok(1'b1),
 .dataslot_requestwrite(requestwrite),.dataslot_requestwrite_ack(1'b1),.dataslot_requestwrite_ok(1'b1),.dataslot_allcomplete(allcomplete),
 .savestate_supported(1'b1),.savestate_addr(32'h40000000),.savestate_size(32'd48),.savestate_maxloadsize(32'd48),
 .savestate_start(ss_start),.savestate_start_ack(start_ack),.savestate_start_busy(start_busy),.savestate_start_ok(start_ok),.savestate_start_err(start_err),
 .savestate_load(ss_load_cmd),.savestate_load_ack(load_ack),.savestate_load_busy(load_busy),.savestate_load_ok(load_ok),.savestate_load_err(load_err),
 .target_dataslot_read(1'b0),.target_dataslot_write(1'b0),.target_dataslot_getfile(1'b0),.target_dataslot_openfile(1'b0),
 .target_dataslot_id(16'd0),.target_dataslot_slotoffset(32'd0),.target_dataslot_bridgeaddr(32'd0),.target_dataslot_length(32'd0),
 .target_buffer_param_struct(32'd0),.target_buffer_resp_struct(32'd0),.datatable_addr(10'd0),.datatable_wren(1'b0),.datatable_data(32'd0));
// Explicit FPGA zero initialization of otherwise uninitialized APF FSM regs.
initial begin cb.hstate=0;cb.tstate=0;cb.host_cmd_start=0;end
function automatic[31:0]swap(input[31:0]x);swap={x[7:0],x[15:8],x[23:16],x[31:24]};endfunction
task packet(input[31:0]a,input[31:0]d);
 begin @(negedge clk74);addr=a;data=d;wr=1;@(negedge clk74);wr=0;repeat(73)@(negedge clk74);end
endtask
task command(input[15:0]c,input[31:0]parameter_word);
 integer n;
 begin
 packet(32'hf8000020,swap(parameter_word));packet(32'hf8000000,swap({16'h434d,c}));
 n=0;while(cb.host_0[31:16]!==16'h4f4b&&n<100000)begin @(negedge clk74);n=n+1;end
 if(n==100000)$fatal(1,"COMMAND_TIMEOUT %h",c);
 $display("CMD %h result=%h save_download=%b queue_busy=%b core_reset=%b time=%0t",c,cb.host_0,save_download_s,queue_save_busy,ss_core_reset,$time);
 end
endtask

task upload_blob;
 reg[31:0]word_value;
 begin
 stage_complete=0;
 for(integer i=0;i<12;i=i+1)begin
  case(i)
   0:word_value=32'h31535350;1:word_value=1;2:word_value=16;3:word_value=32'hcafe0123;
   4:word_value=10;5:word_value=1;6,7:word_value=0;default:word_value=i-7;
  endcase
  packet(32'h40000000+i*4,word_value);
 end
 stage_complete=1;repeat(12)@(negedge sys);
 end
endtask
task request_state;
 begin if(LOAD)upload_blob();command(LOAD?16'h00a4:16'h00a0,1);end
endtask
task complete_state;
 integer n;
 begin
 n=0;while(!(LOAD?load_ok:start_ok)&&n<3000)begin @(negedge sys);n=n+1;end
 if(n==3000||ss_abort||(LOAD?load_err:start_err))$fatal(1,"STATE_FAILED load=%0d",LOAD);
 if(!LOAD)begin
  for(integer i=0;i<12;i=i+1)begin
   @(negedge clk74);addr=32'h40000000+i*4;rd=1;
   @(negedge clk74);rd=0;repeat(73)@(negedge clk74);
  end
 end
 repeat(300)@(negedge clk74);
 if(ss_lock)$fatal(1,"STATE_LOCK_NOT_RELEASED");
 end
endtask
integer before_count=0;
initial begin
 repeat(15)@(negedge clk74);pll=1;repeat(30)@(negedge clk74);
 command(16'h0011,0);repeat(150)@(negedge sys);
 if(SCENARIO==3)begin
  request_state();
  if(triggers!=1||!ss_lock)$fatal(1,"STATE_FIRST_PRECONDITION");
  command(16'h0082,10);
  if(!ss_lock)$fatal(1,"Owner ended before upload");
  for(integer i=0;i<520;i=i+1)packet(32'h20000000+i*4,32'h12345678+i);
  repeat(12)@(negedge sys);
  if(!qfault||!ss_lock)$fatal(1,"Expected upload overflow did not happen");
  $display("PASS REPRO_WRITE_OVERFLOW: valid75-cycle slot10 upload overflowed512-word queue during admitted state; qfault=%b",qfault);
 end else if(SCENARIO==2)begin
  // State owns the engine before a new backup request reaches its read fence.
  request_state();
  if(triggers!=1||!ss_lock)$fatal(1,"STATE_FIRST_PRECONDITION");
  fork
   command(16'h0080,10);
   begin
    wait(cb.host_cmd==16'h0080 && cb.hstate==4'd1);
    wait(save_download_s);
    if(!ss_lock||ss_core_reset)$fatal(1,"QUEUED_BACKUP_REVOKED_OWNER");
    complete_state();
   end
  join
  if(triggers!=1||ss_abort||!save_download_s||queue_save_busy)$fatal(1,"STATE_FIRST_OWNERSHIP");
  command(16'h008f,0);repeat(12)@(negedge sys);
  if(save_download_s)$fatal(1,"SESSION_DID_NOT_CLEAR");
  $display("PASS STATE_FIRST load=%0d gate=%0d: queued0080 deferred, state completed, backup ACKed",LOAD,GATE_SESSION);
 end else begin
  command(WRITE_SESSION?16'h0082:16'h0080,10);repeat(150)@(negedge sys);
  if(!save_download_s||allcomplete||queue_save_busy||ss_core_reset||qfault)$fatal(1,"Backup-session preconditions");
  if(SCENARIO==1)begin
   command(16'h0010,0);repeat(30)@(negedge sys);
   command(16'h0011,0);repeat(150)@(negedge sys);
   if(!save_download_s)$fatal(1,"Unexpected session-clear on core reset");
  end
  request_state();repeat(30)@(negedge sys);
  if(GATE_SESSION)begin
   if(triggers||!(LOAD?load_err:start_err))$fatal(1,"SESSION_GATE_MISSED");
   $display("PASS REJECT_OPEN_SESSION load=%0d write=%0d after_reset=%0d",LOAD,WRITE_SESSION,SCENARIO==1);
  end else begin
   if(triggers!=1||!save_download_s||allcomplete)$fatal(1,"Expected premature admission did not happen");
   complete_state();
   $display("PASS REPRO: state admitted after real session ACK and before008F load=%0d write=%0d",LOAD,WRITE_SESSION);
  end
  before_count=triggers;
  command(16'h008f,0);repeat(150)@(negedge sys);
  if(save_download_s)$fatal(1,"Session latch did not clear after008F");
  request_state();complete_state();
  if(triggers!=before_count+1)$fatal(1,"STATE_DID_NOT_REARM_AFTER008F");
  $display("PASS POST008F_RECOVERY load=%0d write=%0d gate=%0d after_reset=%0d",LOAD,WRITE_SESSION,GATE_SESSION,SCENARIO==1);
 end
 $finish;
end
initial begin #10000000;$fatal(1,"GLOBAL_TIMEOUT");end
endmodule
