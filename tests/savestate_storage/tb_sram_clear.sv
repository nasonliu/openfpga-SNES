`timescale 1ns/1ps
module tb_sram_clear #(parameter real SYS_HALF=23.28, MEM_HALF=5.82, MEM_PHASE=0.0, parameter REQUEST_STAGE=0);
 reg sys_clk=0,mem_clk=0,reset_n=0,image_begin=0;
 always #(SYS_HALF)sys_clk=~sys_clk;
 initial begin #(MEM_PHASE);forever #(MEM_HALF)mem_clk=~mem_clk;end
 wire clearing,clear_busy,sram_busy,credit;wire memory_write,memory_read;wire[16:0]clear_addr;
 ram_clear_frontier frontier(.clk_sys(sys_clk),.hard_reset_n(reset_n),.image_begin(image_begin),
 .quiescent(!sram_busy&&(!REQUEST_STAGE||(!memory_write&&!memory_read))),.save_byte_addr(17'b0),.active(clearing),.busy(clear_busy),.clear_addr(clear_addr),.save_credit(credit));
 reg[15:0]client_addr=0;reg[7:0]client_data=0;reg client_write=0,client_read=0;
 wire[15:0]byte_addr=clearing?clear_addr[15:0]:client_addr;
 wire[7:0]fill_data=(clear_addr[8]^clear_addr[2])?8'h66:8'h99;
 wire[7:0]data_byte=clearing?fill_data:client_data;
 wire[15:0]memory_address;wire[7:0]memory_data;
 if(REQUEST_STAGE)begin: request_pipe
 aram_request_stage request_stage(.clk_sys(sys_clk),.reset_n(reset_n),
 .write_en(clearing?1'b1:clear_busy?1'b0:client_write),.read_en(clear_busy?1'b0:client_read),
 .address(byte_addr),.data(data_byte),.memory_write(memory_write),.memory_read(memory_read),
 .memory_address(memory_address),.memory_data(memory_data));
 end else begin: request_direct
 assign memory_write=clearing?1'b1:clear_busy?1'b0:client_write;
 assign memory_read=clear_busy?1'b0:client_read;
 assign memory_address=byte_addr;assign memory_data=data_byte;
 end
 wire[15:0]write_data=memory_address[0]?{memory_data,8'h0}:{8'h0,memory_data};
 wire[15:0]q;wire[16:0]a;tri[15:0]dq;wire oe,we,ub,lb;
 sram_ctrl dut(.clk(mem_clk),.reset_n(reset_n),.addr(memory_address[15:1]),
 .write_en(memory_write),.read_en(memory_read),
 .data_in(write_data),.write_high_byte(memory_address[0]),.write_low_byte(!memory_address[0]),
 .data_out(q),.busy(sram_busy),.sram_a(a),.sram_dq(dq),.sram_oe_n(oe),.sram_we_n(we),.sram_ub_n(ub),.sram_lb_n(lb));
 reg[15:0]ram[0:32767];wire[15:0]delayed;
 assign #55 delayed=ram[a[14:0]];
 assign dq=(!oe&&we)?delayed:16'hzzzz;
 reg[14:0]wa;reg[15:0]wd;reg[1:0]wm;reg valid_write=0;integer writes=0;
 always @(negedge mem_clk)if(!we)begin wa=a[14:0];wd=dq;wm={~ub,~lb};valid_write=1;end
 always @(posedge we)if(valid_write)begin
  if(wm[0])ram[wa][7:0]=wd[7:0];if(wm[1])ram[wa][15:8]=wd[15:8];writes++;valid_write=0;
 end
 task tick(input integer n);repeat(n)@(negedge sys_clk);endtask
 task write_byte(input[15:0]addr,input[7:0]data);
  begin tick(1);client_addr=addr;client_data=data;client_write=1;tick(4);client_write=0;tick(3);end
 endtask
 task read_byte(input[15:0]addr,input[7:0]data);
  reg[7:0]got;
  begin tick(1);client_addr=addr;client_read=1;tick(4);got=addr[0]?q[15:8]:q[7:0];
  if(got!==data)$fatal(1,"SRAM byte read addr=%h got=%h expected=%h",addr,got,data);
  client_read=0;tick(3);end
 endtask
 task begin_clear;begin tick(1);image_begin=1;tick(1);image_begin=0;end endtask
 // The physical engine can be idle while the request stage still holds the
 // final clear beat. Releasing clients in that gap violates the clear fence.
 always @(negedge clear_busy)if(reset_n&&REQUEST_STAGE&&$time>1000)begin
  if(sram_busy||memory_write||memory_read)$fatal(1,"CLEAR_RELEASE_BEFORE_STAGE_DRAIN");
 end
 realtime we_start=0,we_end=0;integer pin_writes=0;
 always @(negedge we) if(reset_n)begin
  if(we_end>0 && $realtime-we_end<2*MEM_HALF-0.001)$fatal(1,"WE turnaround shorter than one memory clock");
  we_start=$realtime;
 end
 always @(posedge we)if(reset_n&&we_start>0)begin
  if($realtime-we_start<55)$fatal(1,"WE pulse shorter than assumed55ns minimum");
  we_end=$realtime;pin_writes++;
 end
 always @(dq)if(reset_n&&!we&&$time>1000&&(^dq===1'bx))
  $fatal(1,"WRITE_DQ_INVALID_WHILE_WE_LOW");
 integer i;reg[7:0]lo,hi;
 initial begin
  for(i=0;i<32768;i++)ram[i]=16'hdead;
  tick(5);reset_n=1;tick(8);
  write_byte(0,8'h11);write_byte(1,8'h22);write_byte(16'hffff,8'h77);
  read_byte(0,8'h11);read_byte(1,8'h22);read_byte(16'hffff,8'h77);
  // BEGIN drains an already accepted live operation before clear writes.
  client_addr=7;client_data=8'ha5;client_write=1;
  wait(sram_busy);begin_clear();client_write=0;
  wait(clear_addr>=17'd128);reset_n=0;tick(2);
  if(clear_busy||clearing||!we||!oe)$fatal(1,"reset did not park SRAM/frontier");
  reset_n=1;tick(8);begin_clear();wait(clearing);wait(!clear_busy);tick(4);
  for(i=0;i<32768;i++)begin
   lo=(((i*2)>>8)^((i*2)>>2))&1?8'h66:8'h99;
   hi=(((i*2+1)>>8)^((i*2+1)>>2))&1?8'h66:8'h99;
   if(ram[i]!=={hi,lo})$fatal(1,"CLEAR mismatch word=%h got=%h expected=%h",i,ram[i],{hi,lo});
  end
  read_byte(0,8'h99);read_byte(1,8'h99);read_byte(4,8'h66);
  write_byte(0,8'hc1);write_byte(1,8'h2d);read_byte(0,8'hc1);read_byte(1,8'h2d);
  if(sram_busy||writes<131072||pin_writes<131072)$fatal(1,"missing clear coverage writes=%0d",writes);
  $display("PASS SRAM_CLEAR request_stage=%0d writes=%0d full128KiB clear, coherent packet and byte lanes, BEGIN/final drain, midclear reset,55ns read model",REQUEST_STAGE,writes);$finish;
 end
 initial begin #50000000;$fatal(1,"timeout");end
endmodule
