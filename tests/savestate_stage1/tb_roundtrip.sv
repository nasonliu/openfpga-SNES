`timescale 1ns/1ps
// Actual production main + SNES + helper + serializer. Only external memory,
// vendor primitives, and the controller input are testbench models.
module tb_roundtrip;
 reg clk=0; always #5 clk=~clk;
 reg reset_n=0;
 reg [1:0] joy=0;
 reg save=0,load=0;
 wire busy,avail;
 integer hirom=0,missing_helper=0,stale_word=0,failed_restore=0;
 string rom_file,output_prefix;
 reg [7:0] rom[0:65535];
 reg [7:0] wram[0:131071],wram_saved[0:131071];
 reg [7:0] vram1[0:32767],vram2[0:32767],vram1_saved[0:32767],vram2_saved[0:32767];
 reg [7:0] aram[0:65535],aram_saved[0:65535];
 reg [7:0] bsram[0:2047],bsram_saved[0:2047];
 reg [63:0] blob[0:131071];
 wire [16:0] wa;wire[7:0] wd,wq;wire wc,wo,ww;
 wire[15:0] va,vb;wire[7:0] vda,vdb,vqa,vqb;wire vwa,vwb,vo;
 reg[14:0] va_r=0,vb_r=0;
 wire[15:0] aa;wire[7:0] ad,aq;wire ac,ao,aw;
 wire[19:0] ba;wire[7:0] bd,bq;wire bc,bo,bw;
 wire[63:0] ddro;reg[63:0] ddri=0;wire[18:0] ddra;wire[7:0] ddrbe;wire ddrwe,ddrreq;reg ddrack=0;
 wire req_valid;wire req_ready;wire[23:0] req_addr;wire req_write,req_drain;wire[15:0] req_wdata;wire[1:0] req_wstrb;wire[4:0] req_owner;wire[7:0] req_tag,req_epoch;
 reg rsp_valid=0;wire rsp_ready;reg[15:0] rsp_data=0;reg[4:0] rsp_owner=0;reg[7:0] rsp_tag=0,rsp_epoch=0;
 wire mem_fault,flush_ack;
 wire[15:0] audio_l,audio_r;wire[7:0] red,green,blue;wire dotclk,hde,vde;
 integer cycles=0,rom_reads=0,helper_reads=0,ddr_reads=0,ddr_writes=0;
 integer last_ddr_write=-1,save_words=0,load_words=0;
 integer response_delay=0;reg[23:0] captured_addr;
 integer ddr_delay=0;reg[18:0] captured_ddra;reg captured_ddrreq,captured_ddrwe;reg[63:0] captured_ddro;reg[7:0] captured_ddrbe;
 integer stage=0;
 assign req_ready=!rsp_valid && response_delay==0;
 assign wq=wram[wa];assign aq=aram[aa];assign bq=bsram[ba[10:0]];
 assign vqa=vram1[va_r];assign vqb=vram2[vb_r];
 main #(.USE_STANDARD_SDRAM(1),.USE_SS(1),.USE_CX4(0),.USE_SDD1(0),.USE_GSU(0),.USE_SA1(0),.USE_DSPn(0),.USE_SPC7110(0),.USE_BSX(0),.USE_MSU(0),.USE_SUFAMI(0)) dut(
 .RESET_N(reset_n),.MEM_HARD_RESET_N(reset_n),.MEM_FLUSH(1'b0),.MEM_EPOCH(8'h01),.MEM_FLUSH_ACK(flush_ack),.MEM_FAULT(mem_fault),
 .MEM_REQ_VALID(req_valid),.MEM_REQ_READY(req_ready),.MEM_REQ_ADDR(req_addr),.MEM_REQ_WRITE(req_write),.MEM_REQ_DRAIN(req_drain),.MEM_REQ_WDATA(req_wdata),.MEM_REQ_WSTRB(req_wstrb),.MEM_REQ_OWNER(req_owner),.MEM_REQ_TAG(req_tag),.MEM_REQ_EPOCH(req_epoch),
 .MEM_RSP_VALID(rsp_valid),.MEM_RSP_READY(rsp_ready),.MEM_RSP_DATA(rsp_data),.MEM_RSP_ERROR(1'b0),.MEM_RSP_WRITE(1'b0),.MEM_RSP_OWNER(rsp_owner),.MEM_RSP_TAG(rsp_tag),.MEM_RSP_EPOCH(rsp_epoch),
 .MCLK(clk),.ACLK(clk),.ROM_TYPE(hirom?8'h01:8'h00),.ROM_MASK(hirom?24'h00ffff:24'h007fff),.RAM_MASK(24'h0007ff),.RAM_SIZE(4'h1),.ROM_Q(16'b0),
 .WRAM_ADDR(wa),.WRAM_D(wd),.WRAM_Q(wq),.WRAM_CE_N(wc),.WRAM_OE_N(wo),.WRAM_WE_N(ww),
 .VRAM1_ADDR(va),.VRAM1_DI(vqa),.VRAM1_DO(vda),.VRAM1_WE_N(vwa),.VRAM2_ADDR(vb),.VRAM2_DI(vqb),.VRAM2_DO(vdb),.VRAM2_WE_N(vwb),.VRAM_OE_N(vo),
 .ARAM_ADDR(aa),.ARAM_D(ad),.ARAM_Q(aq),.ARAM_CE_N(ac),.ARAM_OE_N(ao),.ARAM_WE_N(aw),
 .BSRAM_ADDR(ba),.BSRAM_D(bd),.BSRAM_Q(bq),.BSRAM_CE_N(bc),.BSRAM_OE_N(bo),.BSRAM_WE_N(bw),
 .GSU_TURBO(1'b0),.GSU_FASTROM(1'b0),.SUFAMI_SWAP(1'b0),.CC_DIP(8'b0),.BLEND(1'b0),.PAL(1'b0),.JOY1_DI(joy),.JOY2_DI(2'b00),.JOY2_P6_in(1'b1),.EXT_RTC(65'b0),
 .GG_EN(1'b0),.GG_CODE(129'b0),.GG_RESET(1'b1),.SPC_MODE(1'b0),.IO_ADDR(17'b0),.IO_DAT(16'b0),.IO_WR(1'b0),.DBG_BG_EN(5'b11111),.DBG_CPU_EN(1'b1),.TURBO(1'b0),.DSP_FREQ(1'b0),
 .MSU_TRACK_MOUNTING(1'b0),.MSU_TRACK_MISSING(1'b0),.MSU_AUDIO_STOP(1'b0),.MSU_AUDIO_SECTOR(22'b0),.MSU_AUDIO_LOOP_INDEX(32'b0),.MSU_DATA(8'b0),.MSU_DATA_ACK(1'b0),.MSU_DATA_BUSY(1'b0),.MSU_ENABLE(1'b0),
 .SS_SAVE(save),.SS_TOSD(1'b1),.SS_LOAD(load),.SS_SLOT(2'b0),.SS_AVAIL(avail),.SS_BUSY(busy),.SS_DDR_DI(ddri),.SS_DDR_ACK(ddrack),.SS_DDR_DO(ddro),.SS_DDR_ADDR(ddra),.SS_DDR_WE(ddrwe),.SS_DDR_BE(ddrbe),.SS_DDR_REQ(ddrreq),
 .AUDIO_L(audio_l),.AUDIO_R(audio_r),.R(red),.G(green),.B(blue),.DOTCLK(dotclk),.HBLANKn(hde),.VBLANKn(vde));
 always @(posedge clk) begin
  cycles<=cycles+1;
  if(cycles>50000000) $fatal(1,"GLOBAL_EXECUTION_TIMEOUT stage=%0d ca=%h marker=%h busy=%b",stage,dut.CA,wram[7938],busy);
  if(stage>=2 && !busy && !dut.CPURD_N && (dut.CA==24'h00fffc || (dut.CA>=24'h008000 && dut.CA<24'h008100)))$fatal(1,"UNEXPECTED_RESET_OR_INITIALIZATION ca=%h",dut.CA);
  if(reset_n && mem_fault) $fatal(1,"STANDARD_MEMORY_CLIENT_FAULT ca=%h",dut.CA);
  va_r<=va[14:0];vb_r<=vb[14:0];
  if(!ww && !wc) wram[wa]<=wd;
  if(!vwa) vram1[va[14:0]]<=vda;
  if(!vwb) vram2[vb[14:0]]<=vdb;
  if(!aw && !ac) aram[aa]<=ad;
  if(!bw && !bc) bsram[ba[10:0]]<=bd;
  if(req_valid && req_ready) begin
   if(req_addr>(hirom?24'h00ffff:24'h007fff))$fatal(1,"EXTERNAL_ROM_ADDRESS_OUT_OF_RANGE %h",req_addr);
   if(req_write || req_addr[23:16]==8'hff) $fatal(1,"BAD_EXTERNAL_ROM_REQUEST %h",req_addr);
   captured_addr<=req_addr;response_delay<=3+(rom_reads%3);rsp_owner<=req_owner;rsp_tag<=req_tag;rsp_epoch<=req_epoch;rom_reads<=rom_reads+1;
  end
  if(response_delay!=0) begin
   response_delay<=response_delay-1;
   if(response_delay==1) begin rsp_valid<=1;rsp_data<={rom[{captured_addr[15:1],1'b1}],rom[{captured_addr[15:1],1'b0}]};end
  end
  if(rsp_valid && rsp_ready) rsp_valid<=0;
  if(dut.passive_memory_ready.passive_req && dut.passive_memory_ready.passive_ready && dut.passive_memory_ready.helper_offer) helper_reads<=helper_reads+1;
  // Explicit RAM service to the genuine engine, including req/ack toggle and
  // byte enables. This is a storage device model, not a state serializer.
  if(ddr_delay==0 && ddrreq!=ddrack) begin
   if(ddra[18:17]!=0)$fatal(1,"UNEXPECTED_SAVESTATE_SLOT %h",ddra);
   captured_ddra<=ddra;captured_ddrreq<=ddrreq;captured_ddrwe<=ddrwe;captured_ddro<=ddro;captured_ddrbe<=ddrbe;ddr_delay<=2;
  end
  if(ddr_delay!=0) begin
   ddr_delay<=ddr_delay-1;
   if(ddr_delay==1) begin
    if(!(failed_restore && stage==4)) begin
     if(captured_ddrwe) begin
      for(integer k=0;k<8;k=k+1) if(captured_ddrbe[k]) blob[captured_ddra][8*k+:8]<=captured_ddro[8*k+:8];
      ddr_writes<=ddr_writes+1;last_ddr_write<=captured_ddra;
     end else begin ddri<=blob[captured_ddra];ddr_reads<=ddr_reads+1;end
     ddrack<=captured_ddrreq;
    end
   end
  end
 end
 task tick(input integer n);repeat(n) @(negedge clk);endtask
 task await_busy(input bit value,input integer limit,input string signature);
  integer n;begin n=0;while(busy!==value && n<limit) begin tick(1);n=n+1;end
  if(busy!==value)$fatal(1,"%s stage=%0d ca=%h helper=%0d writes=%0d reads=%0d",signature,stage,dut.CA,helper_reads,ddr_writes,ddr_reads);end
 endtask
 task await_marker(input integer value,input integer limit);
  integer n;begin n=0;while(wram[7938]!=value && n<limit)begin tick(1);n=n+1;end
  if(wram[7938]!=value)$fatal(1,"FIXTURE_EXECUTION_TIMEOUT wanted=%0d marker=%h ca=%h reads=%0d",value,wram[7938],dut.CA,rom_reads);end
 endtask
 reg[15:0] cpu_a,cpu_x,cpu_y,cpu_d;reg[7:0] cpu_db;reg[14:0] saved_palette;reg[7:0] saved_volume;
 integer i,n,bad,changes,vchanges,achanges,mutation_index,fd;bit pattern_match;reg[7:0] heartbeat;reg[15:0] saved_heartbeat;
 initial begin
  if(!$value$plusargs("rom=%s",rom_file))$fatal(1,"ROM_REQUIRED");
  if(!$value$plusargs("output=%s",output_prefix))output_prefix="roundtrip";
  n=$value$plusargs("hirom=%d",hirom);n=$value$plusargs("missing_helper=%d",missing_helper);n=$value$plusargs("stale_word=%d",stale_word);n=$value$plusargs("failed_restore=%d",failed_restore);
  for(i=0;i<65536;i=i+1)begin rom[i]=8'hea;aram[i]=0;end
  for(i=0;i<131072;i=i+1)begin wram[i]=0;blob[i]=0;end
  for(i=0;i<32768;i=i+1)begin vram1[i]=0;vram2[i]=0;end
  for(i=0;i<2048;i=i+1)bsram[i]=0;
  $readmemh(rom_file,rom);tick(300);reset_n=1;stage=1;
  await_marker(161,4000000);tick(1000);
  n=0;while({wram[7937],wram[7936]}<3 && n<2000000)begin tick(1);n=n+1;end
  if(n==2000000)$fatal(1,"FIXTURE_DID_NOT_RUN_BEFORE_SAVE");
  // Observe the actual P65 registers at a WAI checkpoint, not a software model.
  n=0;while(!dut.SNES.corecpu.p65c816.waiexec && n<800000)begin tick(1);n=n+1;end
  if(n==800000)$fatal(1,"FIXTURE_NO_WAI_CHECKPOINT");
  cpu_a=dut.SNES.corecpu.p65c816.a;cpu_x=dut.SNES.corecpu.p65c816.x;cpu_y=dut.SNES.corecpu.p65c816.y;cpu_d=dut.SNES.corecpu.p65c816.d;cpu_db=dut.SNES.corecpu.p65c816.dbr;
  saved_palette=dut.SNES.coreppu.cgram.mem[0];saved_volume=dut.SNES.coredsp.regram.mem[12];
  $display("CHECKPOINT A cycle=%0d A=%h X=%h Y=%h color=%h volume=%h",cycles,cpu_a,cpu_x,cpu_y,saved_palette,saved_volume);
  if(cpu_a!==16'ha15a || cpu_x!==16'h1357 || cpu_y!==16'h2468 || saved_palette!==15'h03e0 || saved_volume!==8'h19 || dut.SNES.coredsp.regram.mem[28]!==8'h29)$fatal(1,"FIXTURE_INITIAL_STATE_MISMATCH");
  for(i=0;i<1024;i=i+1)if(wram[8192+i]!==8'(((i*73)^(i>>8)^'ha7)&255))$fatal(1,"FIXTURE_WRAM_PATTERN_MISMATCH %0d",i);
  for(i=0;i<256;i=i+1)if((i%2?vram2[i/2]:vram1[i/2])!==8'(((i*29)^(i>>2)^'h3c)&255))$fatal(1,"FIXTURE_VRAM_PATTERN_MISMATCH %0d",i);
  for(i=0;i<64;i=i+1)if(aram[1024+i]!==8'(i^'ha5))$fatal(1,"FIXTURE_ARAM_PATTERN_MISMATCH %0d",i);
  stage=2;save=1;tick(2);save=0;await_busy(1,1600000,"SAVE_EXECUTION_TIMEOUT");await_busy(0,16000000,"SAVE_EXECUTION_TIMEOUT");
  if(helper_reads<100 || ddr_writes<30000 || blob[1][31:0]!=32'h53454e53 || last_ddr_write!=0)$fatal(1,"INVALID_REAL_STATE_SAVE words=%0d helper=%0d header=%h last=%0d",ddr_writes,helper_reads,blob[1],last_ddr_write);
  for(i=0;i<131072;i=i+1)wram_saved[i]=wram[i];
  for(i=0;i<32768;i=i+1)begin vram1_saved[i]=vram1[i];vram2_saved[i]=vram2[i];end
  for(i=0;i<65536;i=i+1)aram_saved[i]=aram[i];
  for(i=0;i<2048;i=i+1)bsram_saved[i]=bsram[i];
  save_words=ddr_writes;saved_heartbeat={wram[7937],wram[7936]};
  $display("SAVE_COMPLETE cycle=%0d words=%0d payload_count=%0d",cycles,save_words,blob[0][63:32]);
  // Persist bytes produced by the actual engine for independent hashing.
  fd=$fopen({output_prefix,"-state.hex"},"w");for(i=0;i<((blob[0][63:32]+1)/2);i=i+1)$fdisplay(fd,"%016h",blob[i]);$fclose(fd);
  stage=3;joy=1;await_marker(178,2000000);tick(1000);joy=0;
  changes=0;for(i=8192;i<9216;i=i+1)if(wram[i]!=wram_saved[i])changes=changes+1;
  vchanges=0;for(i=0;i<128;i=i+1)begin if(vram1[i]!=vram1_saved[i])vchanges=vchanges+1;if(vram2[i]!=vram2_saved[i])vchanges=vchanges+1;end
  achanges=0;for(i=1024;i<1088;i=i+1)if(aram[i]!=aram_saved[i])achanges=achanges+1;
  if(changes!=1024 || vchanges!=256 || achanges!=64 || dut.SNES.coredsp.regram.mem[12]!==8'h67 || dut.SNES.coredsp.regram.mem[28]!==8'h57 || dut.SNES.coreppu.cgram.mem[0]!==15'h001f)$fatal(1,"MUTATION_NOT_EXECUTED changes=%0d",changes);
  $display("MUTATION_COMPLETE WRAM_changed=%0d VRAM_changed=%0d ARAM_changed=%0d color=%h MVOLL=%h MVOLR=%h",changes,vchanges,achanges,dut.SNES.coreppu.cgram.mem[0],dut.SNES.coredsp.regram.mem[12],dut.SNES.coredsp.regram.mem[28]);
  if(stale_word) begin
   // Corrupt a known actual serialized run from the WRAM sentinel. Locate by
   // bytes instead of baking a serializer-layout assumption into the oracle.
   mutation_index=-1;
   for(i=16;i<save_words*8-8;i=i+1)begin
    pattern_match=1;
    for(integer k=0;k<8;k=k+1)if(blob[(i+k)>>3][((i+k)&7)*8+:8]!==wram_saved[8192+k])pattern_match=0;
    if(pattern_match)mutation_index=i+3;
   end
   if(mutation_index<0)$fatal(1,"NEGATIVE_CONTROL_SENTINEL_NOT_IN_BLOB");
   blob[mutation_index>>3][(mutation_index&7)*8+:8]=blob[mutation_index>>3][(mutation_index&7)*8+:8]^8'h80;
   $display("INJECT_STALE_WORD qword=%0d byte_lane=%0d",mutation_index>>3,mutation_index&7);
  end
  stage=4;load=1;tick(2);load=0;
  await_busy(1,1600000,"RESTORE_EXECUTION_TIMEOUT");await_busy(0,16000000,"RESTORE_EXECUTION_TIMEOUT");
  load_words=ddr_reads;
  if({wram[7937],wram[7936]}!==saved_heartbeat)$fatal(1,"RESTORE_CHECKPOINT_HEARTBEAT_MISMATCH saved=%0d actual=%0d",saved_heartbeat,{wram[7937],wram[7936]});
  bad=0;
  // Stack and heartbeat belong to an interrupt/resume boundary and are checked
  // through CPU registers/resume below. All other WRAM bytes compare directly.
  for(i=0;i<131072;i=i+1)if(!(i>=7936&&i<7938) && !(i>=8064&&i<8192) && wram[i]!==wram_saved[i])begin if(bad<8)$display("WRAM_BAD addr=%h got=%h expected=%h",i,wram[i],wram_saved[i]);bad=bad+1;end
  for(i=0;i<32768;i=i+1)begin
   if(vram1[i]!==vram1_saved[i])begin if(bad<8)$display("VRAM1_BAD addr=%h got=%h expected=%h",i,vram1[i],vram1_saved[i]);bad=bad+1;end
   if(vram2[i]!==vram2_saved[i])begin if(bad<8)$display("VRAM2_BAD addr=%h got=%h expected=%h",i,vram2[i],vram2_saved[i]);bad=bad+1;end
  end
  for(i=0;i<65536;i=i+1)if(aram[i]!==aram_saved[i])begin if(bad<8)$display("ARAM_BAD addr=%h got=%h expected=%h",i,aram[i],aram_saved[i]);bad=bad+1;end
  for(i=0;i<2048;i=i+1)if(bsram[i]!==bsram_saved[i])bad=bad+1;
  if(bad)$fatal(1,"RESTORE_RAM_MISMATCH count=%0d",bad);
  if(dut.SNES.coreppu.cgram.mem[0]!==saved_palette)$fatal(1,"RESTORE_PALETTE_MISMATCH");
  if(dut.SNES.coredsp.regram.mem[12]!==saved_volume || dut.SNES.coredsp.regram.mem[28]!==8'h29)$fatal(1,"RESTORE_DSP_REGISTER_MISMATCH");
  tick(1000);n=0;while(!dut.SNES.corecpu.p65c816.waiexec&&n<800000)begin tick(1);n=n+1;end
  if(n==800000)$fatal(1,"RESTORE_NO_RESUME_CHECKPOINT");
  if(dut.SNES.corecpu.p65c816.a!==cpu_a || dut.SNES.corecpu.p65c816.x!==cpu_x || dut.SNES.corecpu.p65c816.y!==cpu_y || dut.SNES.corecpu.p65c816.d!==cpu_d || dut.SNES.corecpu.p65c816.dbr!==cpu_db)$fatal(1,"RESTORE_CPU_REGISTER_MISMATCH A=%h X=%h Y=%h",dut.SNES.corecpu.p65c816.a,dut.SNES.corecpu.p65c816.x,dut.SNES.corecpu.p65c816.y);
  heartbeat=wram[7936];n=0;while(wram[7936]==heartbeat&&n<800000)begin tick(1);n=n+1;end
  if(n==800000)$fatal(1,"RESTORE_DID_NOT_RESUME");
  if(wram[7938]!=161)$fatal(1,"RESTORE_WRONG_EXECUTION_PHASE");
  // The original SPC payload latches B forever. A fresh B acknowledgement
  // proves the restored SPC A wait-loop executed again, not just its RAM.
  stage=5;joy=1;await_marker(178,2000000);tick(1000);joy=0;
  for(i=0;i<1024;i=i+1)if(wram[8192+i]!==8'((((i*73)^(i>>8)^'ha7)&255)^255))$fatal(1,"RESUMED_CPU_DID_NOT_MUTATE %0d",i);
  for(i=0;i<256;i=i+1)if((i%2?vram2[i/2]:vram1[i/2])!==8'((((i*29)^(i>>2)^'h3c)&255)^255))$fatal(1,"RESUMED_VIDEO_DID_NOT_MUTATE %0d",i);
  for(i=0;i<64;i=i+1)if(aram[1024+i]!==8'(i^'h5a))$fatal(1,"RESUMED_SPC_DID_NOT_MUTATE %0d",i);
  if(dut.SNES.coredsp.regram.mem[12]!==8'h67 || dut.SNES.coredsp.regram.mem[28]!==8'h57)$fatal(1,"RESUMED_DSP_REGISTER_MISMATCH");
  $display("RESUME_B_CONFIRMED cpu=1 spc700=1 WRAM=1024 VRAM=256 ARAM=64 DSP_MVOL_LR=1 saved_heartbeat=%0d",saved_heartbeat);
  $display("PASS REAL_SNES_SAVESTATE_ROUNDTRIP mapping=%0d cycles=%0d save_qwords=%0d load_qwords=%0d helper_reads=%0d WRAM_compare=130942 VRAM_compare=65536 ARAM_compare=65536 BSRAM_compare=2048 CPU_AXY_D_DB=1 CGRAM0=1 DSP_MVOL_LR=1 resume=1",hirom,cycles,save_words,load_words,helper_reads);
  $finish;
 end
endmodule
