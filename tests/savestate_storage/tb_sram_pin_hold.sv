`timescale 1ns/1ps
// Timing-design model, not extracted FPGA/board delays. The selected SRAM is
// AS6C2016-55BIN. Adversarial pad delays intentionally make DQ turn off before
// WE/byte-enable rise when all three are launched on the same FPGA clock.
module tb_sram_pin_hold #(
 parameter real MEM_HALF=5.82,
 parameter real WE_PAD=2.5, BE_PAD=2.0, OE_PAD=1.0,
 parameter real DQ_ENABLE_PAD=0.5, DQ_DISABLE_PAD=0.5,
 parameter real ADDRESS_PAD=1.0,
 parameter real READ_RETURN_BUDGET=0.0,
 parameter integer MODE=0
);
 reg clk=0,reset=1,wr=0,rd=0;always #(MEM_HALF)clk=~clk;
 reg[16:0]addr=0;reg[15:0]data=0;reg[1:0]mask=3;
 wire ready;wire[15:0]q;wire[16:0]a;tri[15:0]fpga_dq;
 wire oe,we,ub,lb;
 sram #(.CLOCK_SPEED_MHZ(85.9),.MIN_OP_CYCLE_TIME_NANO_SEC(55)) dut(
 .clk(clk),.reset(reset),.mask(mask),.wr(wr),.rd(rd),.addr(addr),.data(data),
 .q(q),.ready(ready),.sram_a(a),.sram_dq(fpga_dq),
 .sram_oe_n(oe),.sram_we_n(we),.sram_ub_n(ub),.sram_lb_n(lb));
 wire we_pin,oe_pin,ub_pin,lb_pin;
 wire[16:0]address_pin;wire[15:0]data_pin;
 wire fpga_drive;
 assign #(WE_PAD)we_pin=we;assign #(OE_PAD)oe_pin=oe;
 assign #(BE_PAD)ub_pin=ub;assign #(BE_PAD)lb_pin=lb;
 assign #(ADDRESS_PAD) address_pin=a;assign #0.75 data_pin=dut.current_write_data;
 assign #(DQ_ENABLE_PAD,DQ_DISABLE_PAD)fpga_drive=dut.use_write;
 // Separate the FPGA output-driver path and input-return path so independent
 // I/O-enable and control-pad skew is modeled without an ideal bidirectional
 // connection silently forcing their delays equal.
 tri[15:0]chip_dq;
 assign chip_dq=fpga_drive?data_pin:16'hzzzz;
 wire[15:0]fpga_input;assign #(READ_RETURN_BUDGET)fpga_input=chip_dq;
 assign fpga_dq=!dut.use_write?fpga_input:16'hzzzz;
 reg[15:0]mem[0:131071];
 wire chip_drive_requested=!oe_pin&&we_pin&&(!ub_pin||!lb_pin);
 // Include byte-enable access (tBA), not just address access. Mode2 uses the
 // measured post-fit UB flight plus DQ input/setup budget to expose the old
 // six-clock capture's negative margin, even with zero PCB flight.
 wire[15:0]read_word;
 assign #55 read_word=chip_drive_requested?mem[address_pin]:16'hxxxx;
 wire chip_drive;
 // Data-sheet tOHZ max=20ns. The read output persists after OE is disabled;
 // a new FPGA write must not drive DQ until this release has completed.
 // Use 25ns turn-on: this also respects the data-sheet same-PVT note that
 // output disable is faster than output enable. Turn-off remains worst20ns.
 assign #(25.0,20.0)chip_drive=chip_drive_requested;
 assign chip_dq=chip_drive?read_word:16'hzzzz;
 integer reads=0,writes=0,hold_checks=0,turn_checks=0;
 bit checking=0,write_armed=0;reg[16:0]write_address;reg[1:0]write_mask;
 realtime write_start=0,we_rose=0,fpga_released=0,oe_rose=0,min_hold=1e9,min_turn=1e9;
 wire write_window=!we_pin&&(!ub_pin||!lb_pin);
 always @(posedge write_window)if(checking)begin
  if(address_pin!==a)$fatal(1,"WRITE_ADDRESS_SETUP_VIOLATION pin_address=%h intended=%h",address_pin,a);
  write_armed=1;write_start=$realtime;write_address=address_pin;write_mask={!ub_pin,!lb_pin};
 end
 always @(address_pin)if(checking&&write_window)
  $fatal(1,"ADDRESS_CHANGED_DURING_WRITE");
 always @(negedge write_window)if(checking&&write_armed)begin
  if($realtime-write_start<45)$fatal(1,"WRITE_PULSE_TOO_SHORT");
  if((write_mask[0]&&(^chip_dq[7:0]===1'bx)) ||
     (write_mask[1]&&(^chip_dq[15:8]===1'bx)))
   $fatal(1,"WRITE_HOLD_VIOLATION DQ=%h at write end=%0t",chip_dq,$realtime);
  if(write_mask[0])mem[write_address][7:0]=chip_dq[7:0];
  if(write_mask[1])mem[write_address][15:8]=chip_dq[15:8];
  writes++;write_armed=0;
 end
 always @(posedge we_pin)if(checking)we_rose=$realtime;
 always @(posedge oe_pin)if(checking)oe_rose=$realtime;
 always @(negedge fpga_drive)if(checking)begin
  if(write_window)$fatal(1,"DQ_RELEASE_BEFORE_WRITE_END release=%0t WE=%b UB=%b LB=%b",$realtime,we_pin,ub_pin,lb_pin);
  if(we_rose>0)begin
   if($realtime-we_rose<min_hold)min_hold=$realtime-we_rose;
   if($realtime-we_rose<=0)$fatal(1,"NO_POSITIVE_WRITE_HOLD");hold_checks++;
  end
  fpga_released=$realtime;
 end
 always @(negedge oe_pin)if(checking)begin
  reads++;
  if(fpga_released>0&&$realtime-fpga_released<=0)$fatal(1,"NO_WRITE_TO_READ_DEAD_BAND");
 end
 always @(posedge fpga_drive)if(checking&&oe_rose>0)begin
  if($realtime-oe_rose<min_turn)min_turn=$realtime-oe_rose;
  turn_checks++;
 end
 always @(fpga_drive,chip_drive)if(checking&&fpga_drive&&chip_drive)
  $fatal(1,"SRAM_BUS_CONTENTION t=%0t OE=%b WE=%b",$realtime,oe_pin,we_pin);
 task issue_write(input[16:0]wa,input[15:0]wd,input[1:0]wm);
  @(negedge clk);addr=wa;data=wd;mask=wm;wr=1;rd=0;
  @(negedge clk);wr=0;
  wait(ready);@(negedge clk);
 endtask
 task issue_read(input[16:0]ra,input[15:0]expected);
  @(negedge clk);addr=ra;mask=3;wr=0;rd=1;
  @(negedge clk);rd=0;
  wait(ready);#0.01;
  if(q!==expected)$fatal(1,"READBACK_MISMATCH address=%h actual=%h expected=%h",ra,q,expected);
 endtask
 initial begin
  for(integer i=0;i<131072;i++)mem[i]=16'h7bc9;
  // Make an address-limited access observably different from the old address.
  mem[0]=16'h1234;
  repeat(5)@(negedge clk);reset=0;checking=1;
  if(MODE==2)begin
   issue_read(17'h1739,16'h7bc9);
   repeat(5)@(negedge clk);
   $display("PASS SRAM_PIN_HOLD mode=2 coherent_read_setup_budget address_offset=%0.3f return_budget=%0.3f",ADDRESS_PAD,READ_RETURN_BUDGET);$finish;
  end
  if(MODE==0||MODE==3)begin
   issue_write(17'h1327,16'h42a6,2'b01);
   issue_read(17'h1327,16'h7ba6);
  end else if(MODE==1)begin
   // Leave a write queued during the read so acceptance happens on the
   // earliest possible ready edge, exposing a missing bus-release guard.
   @(negedge clk);addr=17'h2255;rd=1;
   @(negedge clk);rd=0;addr=17'h2256;data=16'h193e;mask=3;wr=1;
   wait(!oe);wait(oe);wait(!we);@(negedge clk);wr=0;wait(ready);
   issue_read(17'h2256,16'h193e);
  end
  issue_write(17'h1327,16'hd017,2'b10);issue_read(17'h1327,(MODE==0||MODE==3)?16'hd0a6:16'hd0c9);
  repeat(5)@(negedge clk);
  if(writes<2||reads<2||hold_checks<2)$fatal(1,"COVERAGE");
  $display("PASS SRAM_PIN_HOLD mode=%0d writes=%0d reads=%0d hold_checks=%0d turn_checks=%0d min_DQ_hold_after_WE_ns=%0.3f min_read_disable_to_FPGA_drive_ns=%0.3f",MODE,writes,reads,hold_checks,turn_checks,min_hold,min_turn);$finish;
 end
 initial begin #100000;$fatal(1,"TIMEOUT");end
endmodule
