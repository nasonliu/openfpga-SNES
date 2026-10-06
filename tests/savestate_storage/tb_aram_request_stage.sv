`timescale 1ns/1ps
// Deliberately let CPU-like address/data decode settle late in the high half
// cycle. Only the coherent falling-edge packet may reach the SRAM controller.
module tb_aram_request_stage #(
 parameter real SYS_HALF=23.28, MEM_HALF=5.82, MEM_PHASE=0.0,
 parameter MUTATION=0
);
 reg sys_clk=0,mem_clk=0,reset_n=0;
 always #(SYS_HALF)sys_clk=~sys_clk;
 initial begin #(MEM_PHASE);forever #(MEM_HALF)mem_clk=~mem_clk;end
 reg write_en=0,read_en=0;reg[15:0]address=0;reg[7:0]data=0;
 wire pipe_write,pipe_read;wire[15:0]pipe_address;wire[7:0]pipe_data;
 aram_request_stage stage(.clk_sys(sys_clk),.reset_n(reset_n),
 .write_en(write_en),.read_en(read_en),.address(address),.data(data),
 .memory_write(pipe_write),.memory_read(pipe_read),
 .memory_address(pipe_address),.memory_data(pipe_data));
 wire memory_write=MUTATION==1?write_en:pipe_write;
 wire memory_read=MUTATION==1?read_en:pipe_read;
 wire[15:0]memory_address=MUTATION!=0?address:pipe_address;
 wire[7:0]memory_data=MUTATION==1?data:pipe_data;
 reg expected_write=0,expected_read=0;
 reg[15:0]expected_address=0;reg[7:0]expected_data=0;
 always @(negedge sys_clk or negedge reset_n)begin
  if(!reset_n)begin expected_write<=0;expected_read<=0;expected_address<=0;expected_data<=0;end
  else begin expected_write<=write_en;expected_read<=read_en;expected_address<=address;expected_data<=data;end
 end
 wire busy;wire[15:0]q;wire[16:0]a;tri[15:0]dq;wire oe,we,ub,lb;
 sram_ctrl dut(.clk(mem_clk),.reset_n(reset_n),.addr(memory_address[15:1]),
 .write_en(memory_write),.read_en(memory_read),
 .data_in(memory_address[0]?{memory_data,8'h0}:{8'h0,memory_data}),
 .write_high_byte(memory_address[0]),.write_low_byte(!memory_address[0]),
 .data_out(q),.busy(busy),.sram_a(a),.sram_dq(dq),
 .sram_oe_n(oe),.sram_we_n(we),.sram_ub_n(ub),.sram_lb_n(lb));
 wire quiescent=!busy&&!memory_write&&!memory_read;
 wire[15:0]payload={8'(a[7:0]^8'hb7),8'(a[7:0]^8'h4c)};
 wire[15:0]delayed;assign #55 delayed=payload;
 assign dq=(!oe&&we)?delayed:16'hzzzz;
 integer checks=0,writes=0,reads=0,high_writes=0,low_writes=0,drains=0;
 reg accepted_write;reg[15:0]accepted_address;reg[7:0]accepted_data;
 always @(posedge mem_clk)if(reset_n)begin
  if({memory_write,memory_read}!=={expected_write,expected_read} ||
     ((expected_write||expected_read) &&
      {memory_address,memory_data}!=={expected_address,expected_data}))
   $fatal(1,"REQUEST_PACKET_MISMATCH mutation=%0d got=%h/%h/%b%b expected=%h/%h/%b%b",MUTATION,
    memory_address,memory_data,memory_write,memory_read,
    expected_address,expected_data,expected_write,expected_read);
  checks++;
  if(!busy&&(memory_write||memory_read))begin
   accepted_write=expected_write;accepted_address=expected_address;accepted_data=expected_data;
   #0.001;
   if(a!=={2'b0,accepted_address[15:1]})$fatal(1,"PIN_ADDRESS_MISMATCH");
   if(accepted_write)begin
    if(we||!oe||{!ub,!lb}!==(accepted_address[0]?2'b10:2'b01))$fatal(1,"PIN_LANE_MISMATCH");
    if((accepted_address[0]?dq[15:8]:dq[7:0])!==accepted_data)$fatal(1,"PIN_DATA_MISMATCH");
    writes++;if(accepted_address[0])high_writes++;else low_writes++;
   end else begin
    if(!we||oe||ub||lb)$fatal(1,"PIN_READ_MISMATCH");reads++;
   end
  end
 end
 task packet(input integer n);
  @(posedge sys_clk);#1;
  // Address/data may transiently describe a different request until decode
  // settles; control is already asserted, matching the vulnerable old cone.
  write_en=(n%3)!=0;read_en=(n%3)==0;address=16'hdead;data=8'hbe;
  #(SYS_HALF-7);address=16'(n*173+((n/3)&1));data=8'(n*59+7);
 endtask
 initial begin
  repeat(4)@(negedge sys_clk);#1;reset_n=1;
  for(integer n=0;n<120;n++)packet(n);
  // Removing the input request does not make a queued stage quiescent.
  wait(!busy&&(memory_write||memory_read));#0.001;
  write_en=0;read_en=0;
  if(quiescent)$fatal(1,"QUEUED_REQUEST_LOST_FROM_QUIESCENCE");drains++;
  wait(quiescent);#0.001;
  if(!we||!oe)$fatal(1,"DRAIN_DID_NOT_PARK_PINS");
  packet(121);wait(busy);#1;reset_n=0;write_en=0;read_en=0;
  repeat(3)@(negedge sys_clk);#0.001;
  if(memory_write||memory_read||busy||!we||!oe)$fatal(1,"RESET_DID_NOT_PARK_STAGE");
  #1;reset_n=1;for(integer n=122;n<190;n++)packet(n);
  @(posedge sys_clk);#1;write_en=0;read_en=0;wait(quiescent);
  if(checks<500||writes<30||reads<10||high_writes<10||low_writes<10||drains!=1)$fatal(1,"COVERAGE");
  $display("PASS ARAM_REQUEST_STAGE checks=%0d writes=%0d reads=%0d lanes=%0d/%0d reset_and_drain=%0d",checks,writes,reads,low_writes,high_writes,drains);$finish;
 end
 initial begin #1000000;$fatal(1,"TIMEOUT");end
endmodule
