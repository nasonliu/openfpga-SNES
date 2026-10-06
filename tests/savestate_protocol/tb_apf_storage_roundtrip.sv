`timescale 1ns/1ps
// Production APF controller + data loader/unloader + Intel dcfifo simulation
// model + state transport + PSRAM controller. Only the SNES engine transactions
// and off-chip PSRAM array are modeled. No full-console or board timing claim.
module tb_apf_storage_roundtrip #(
    parameter real SYS_HALF=500.0/21.477270,
    parameter real MEM_HALF=500.0/85.909080,
    parameter real MEM_PHASE=0.0,
    parameter integer LITTLE=1,
    parameter integer PAYLOAD_BYTES=64,
    parameter integer CORRUPT_CASE=1
);
    localparam WORDS=PAYLOAD_BYTES/4;
    localparam TOTAL_WORDS=WORDS+8;
    localparam ACTUAL_QWORDS=PAYLOAD_BYTES/8-3;
    localparam RAM_WORDS=PAYLOAD_BYTES/2;
    reg clk74=0,clksys=0,clkmem=0;
    always #(500.0/74.25) clk74=~clk74;
    always #(SYS_HALF) clksys=~clksys;
    initial begin #(MEM_PHASE);forever #(MEM_HALF)clkmem=~clkmem;end
    reg reset_n=0,allow=0,admit=1,bridge_rd=0,bridge_wr=0,start=0,load=0;
    reg [31:0] addr=0,data=0;
    reg busy=0;
    wire start_ack,start_busy,start_ok,start_err,load_ack,load_busy,load_ok,load_err;
    wire ss_save,ss_load,ss_idle,ss_lock,ss_abort,stage_clear,stage_accept,header_select,blob_read_enable;
    wire [31:0] header_data,blob_data,checksum;
    wire [7:0] error;
    wire stage_lost,stage_idle,stage_complete,save_complete,transport_idle,fault;
    wire [19:0] committed;
    wire stage_wr,blob_rd;
    wire [19:0] stage_addr,blob_addr;
    wire [15:0] stage_data,blob_q;
    wire [31:0] payload_addr={4'h4,addr[27:0]-28'd32};
    wire [31:0] result=header_select?header_data:blob_data;
    reg [63:0] engine_data=0;
    reg [21:3] engine_addr=0;
    reg engine_we=0,engine_req=0;
    wire [63:0] engine_q;
    wire engine_ack;
    wire [21:16] cram_a;
    wire [15:0] cram_dq;
    wire cram_clk,cram_adv_n,cram_cre,cram_ce0_n,cram_ce1_n,cram_oe_n,cram_we_n,cram_ub_n,cram_lb_n;
    savestate_controller #(.MAX_PAYLOAD_SIZE(PAYLOAD_BYTES),.SETTLE_CYCLES(4),
        .TIMEOUT_TRIGGER(2000),.TIMEOUT_WALK(PAYLOAD_BYTES*16+30000),.TIMEOUT_DRAIN(2000),
        .TIMEOUT_STAGE(10000),.TIMEOUT_READBACK(10000),.TIMEOUT_COMMAND(PAYLOAD_BYTES*200+200000)) ctrl (
        .clk_74a(clk74),.clk_sys_21_48(clksys),.core_reset(!reset_n),
        .bridge_rd(bridge_rd),.bridge_wr(bridge_wr),.bridge_endian_little(LITTLE!=0),
        .bridge_addr(addr),.bridge_wr_data(data),.payload_size(PAYLOAD_BYTES),.rom_identity(32'hfeed6701),
        .savestate_start(start),.savestate_start_ack_s(start_ack),.savestate_start_busy_s(start_busy),
        .savestate_start_ok_s(start_ok),.savestate_start_err_s(start_err),
        .savestate_load(load),.savestate_load_ack_s(load_ack),.savestate_load_busy_s(load_busy),
        .savestate_load_ok_s(load_ok),.savestate_load_err_s(load_err),
        .ss_admit(admit),.ss_allow(allow),.ss_busy(busy),.storage_fault(fault),.stage_lost(stage_lost),
        .stage_drained(stage_idle),.stage_complete(stage_complete),.engine_drained(transport_idle),
        .save_complete(save_complete),.saved_payload_checksum(checksum),.ss_save(ss_save),.ss_load(ss_load),.ss_idle(ss_idle),.ss_lock(ss_lock),
        .ss_abort(ss_abort),.stage_clear(stage_clear),.stage_clear_toggle74(),.stage_accept(stage_accept),
        .header_select(header_select),.header_rd_data(header_data),.blob_read_enable(blob_read_enable),
        .blob_size(),.protocol_error(error));
    data_loader #(.ADDRESS_MASK_UPPER_4(4'h4),.ADDRESS_SIZE(20),
        .WRITE_MEM_CLOCK_DELAY(16),.OUTPUT_WORD_SIZE(2)) loader (
        .clk_74a(clk74),.clk_memory(clkmem),.bridge_wr(stage_accept),.bridge_endian_little(LITTLE!=0),
        .bridge_addr(payload_addr),.bridge_wr_data(data),.write_en(stage_wr),.write_addr(stage_addr),.write_data(stage_data));
    data_unloader #(.ADDRESS_MASK_UPPER_4(4'h4),.ADDRESS_SIZE(20),
        .READ_MEM_CLOCK_DELAY(24),.INPUT_WORD_SIZE(2),.SAFE_RESPONSE_HANDSHAKE(1)) unloader (
        .clk_74a(clk74),.clk_memory(clkmem),.reset_n(reset_n),.bridge_rd(blob_read_enable),
        .bridge_endian_little(LITTLE!=0),.bridge_addr(payload_addr),.bridge_rd_data(blob_data),
        .read_en(blob_rd),.read_addr(blob_addr),.read_data(blob_q));
    savestate storage (
        .clk_sys(clksys),.clk_mem(clkmem),.reset_n(reset_n),.abort(ss_abort),.save_begin(ss_save),
        .stage_clear(stage_clear),.stage_expected_bytes(20'(PAYLOAD_BYTES)),.fault(fault),.stage_idle(stage_idle),
        .stage_complete(stage_complete),.transport_idle(transport_idle),.stage_bytes_committed(committed),
        .save_complete(save_complete),.saved_payload_checksum(checksum),.ss_ddr_do(engine_data),.ss_ddr_addr(engine_addr),
        .ss_ddr_be(8'hff),.ss_ddr_we(engine_we),.ss_ddr_req(engine_req),.ss_ddr_di(engine_q),
        .ss_ddr_ack(engine_ack),.ss_busy(busy),.blocked(1'b0),.ctrl_idle(ss_idle),.stage_lost(stage_lost),
        .stage_wr(stage_wr),.stage_addr(stage_addr),.stage_data(stage_data),.blob_rd(blob_rd),
        .blob_addr(blob_addr),.blob_q(blob_q),.cram_a(cram_a),.cram_dq(cram_dq),.cram_wait(1'b0),
        .cram_clk(cram_clk),.cram_adv_n(cram_adv_n),.cram_cre(cram_cre),.cram_ce0_n(cram_ce0_n),
        .cram_ce1_n(cram_ce1_n),.cram_oe_n(cram_oe_n),.cram_we_n(cram_we_n),.cram_ub_n(cram_ub_n),.cram_lb_n(cram_lb_n));
    reg [15:0] ram[0:RAM_WORDS-1];
    reg [21:0] ram_addr=0;
    always @(posedge cram_adv_n)if(!cram_ce0_n)ram_addr={cram_a,cram_dq};
    always @(negedge clkmem)if(!cram_ce0_n&&!cram_we_n&&cram_adv_n)begin
        if(!cram_lb_n)ram[ram_addr][7:0]=cram_dq[7:0];
        if(!cram_ub_n)ram[ram_addr][15:8]=cram_dq[15:8];
    end
    assign cram_dq=(!cram_ce0_n&&!cram_oe_n&&cram_we_n)?ram[ram_addr]:16'hzzzz;
    function automatic [31:0] swap(input [31:0] word);swap={word[7:0],word[15:8],word[23:16],word[31:24]};endfunction
    function automatic [31:0] normalized(input [31:0] word);normalized=LITTLE?word:swap(word);endfunction
    function automatic [31:0] payload_word(input integer n);
        if(n==0)payload_word=5;
        else if(n==1)payload_word=ACTUAL_QWORDS*2;
        else if(n==2)payload_word=32'h53454e53;
        else if(n<ACTUAL_QWORDS*2)payload_word=32'h12007800+n*32'h010203;
        else payload_word=0;
    endfunction
    function automatic [63:0] payload_qword(input integer n);payload_qword={payload_word(n*2+1),payload_word(n*2)};endfunction
    task automatic tick(input integer n);repeat(n)@(negedge clk74);endtask
    task automatic sys_tick(input integer n);repeat(n)@(negedge clksys);endtask
    task automatic request_command(input bit isload);
        integer n;
        begin
            @(negedge clk74);if(isload)load=1;else start=1;
            n=0;while(!(isload?load_ack:start_ack)&&n<100)begin tick(1);n=n+1;end
            if(n==100)$fatal(1,"APF ack timeout");
            tick(2);if(isload)load=0;else start=0;
        end
    endtask
    task automatic engine_request(input bit wr,input integer qword,input [63:0] value);
        integer n;
        begin
            @(negedge clksys);engine_we=wr;engine_addr=qword;engine_data=value;engine_req=~engine_req;
            sys_tick(1);engine_we=0;engine_addr=0;engine_data=0;
            n=0;while(engine_ack!==engine_req&&n<500)begin sys_tick(1);n=n+1;end
            if(n==500)$fatal(1,"Engine storage ack timeout qword=%0d fault=%b",qword,fault);
        end
    endtask
    reg [31:0] image_words[0:TOTAL_WORDS-1];
    integer source_cycle=0, last_read_cycle=0, last_write_cycle=0;
    always @(posedge clk74)source_cycle<=source_cycle+1;
    task automatic host_read(input integer n,input [31:0] wanted);
        begin
            @(negedge clk74);
            if(n!=0 && source_cycle-last_read_cycle!=75)$fatal(1,"Host read pacing is not exactly 75 cycles");
            last_read_cycle=source_cycle;
            addr=32'h40000000+n*4;bridge_rd=1;
            tick(1);bridge_rd=0;
            // Match the existing save_reader APF early-latch oracle: response
            // must exist two source clocks before the next 75-clock request.
            tick(72);@(posedge clk74);
            if(result!==normalized(wanted))$fatal(1,"APF_READ_DEADLINE word=%0d got=%h wanted=%h blobq=%h",n,result,normalized(wanted),blob_q);
            image_words[n]=result;
            tick(1);
        end
    endtask
    task automatic host_write(input integer n,input [31:0] word,input bit wait_tail);
        begin
            @(negedge clk74);
            if(n!=0 && source_cycle-last_write_cycle!=75)$fatal(1,"Host write pacing is not exactly 75 cycles");
            last_write_cycle=source_cycle;
            addr=32'h40000000+n*4;data=word;bridge_wr=1;
            tick(1);bridge_wr=0;
            if(wait_tail)tick(73);
        end
    endtask
    integer load_pulses=0,save_pulses=0;
    always @(posedge clksys)begin
        if(ss_save)save_pulses<=save_pulses+1;
        if(ss_load)begin
            load_pulses<=load_pulses+1;
            if(!stage_complete||!stage_idle||committed!=PAYLOAD_BYTES||stage_lost)$fatal(1,"Live restore preceded committed APF stage");
        end
    end
    integer i,n,base_load;
    reg [31:0] sum;
    initial begin
        for(i=0;i<RAM_WORDS;i=i+1)ram[i]=16'hdead;
        sum=0;for(i=0;i<WORDS;i=i+1)sum=sum+payload_word(i);
        tick(15);reset_n=1;allow=1;tick(60);
        request_command(0);while(!ss_save)@(negedge clksys);
        busy=1;sys_tick(6);
        for(i=1;i<ACTUAL_QWORDS;i=i+1)begin
            engine_request(1,i,payload_qword(i));
            if(PAYLOAD_BYTES>64 && i%8192==0)begin $display("PROGRESS engine save %0d/%0d",i,ACTUAL_QWORDS);$fflush();end
        end
        engine_request(1,0,payload_qword(0));busy=0;
        n=0;while(!start_ok&&n<500)begin tick(1);n=n+1;end
        if(!start_ok||start_err||checksum!==sum||fault)$fatal(1,"Snapshot failed err=%0d checksum=%h wanted=%h",error,checksum,sum);
        host_read(0,32'h31535350);host_read(1,1);host_read(2,PAYLOAD_BYTES);host_read(3,32'hfeed6701);
        host_read(4,sum);host_read(5,1);host_read(6,0);host_read(7,0);
        for(i=0;i<WORDS;i=i+1)begin
            host_read(i+8,payload_word(i));
            if(PAYLOAD_BYTES>64 && i%16384==0)begin $display("PROGRESS host read %0d/%0d",i,WORDS);$fflush();end
        end
        tick(270);if(ss_lock)$fatal(1,"Readback lock held after complete pipeline");
        for(i=0;i<RAM_WORDS;i=i+1)ram[i]=16'hbad0+i;
        // Complete APF upload BEFORE A4, except the final word is still in the
        // real loader/FIFO when the command arrives. Controller must wait.
        for(i=0;i<TOTAL_WORDS;i=i+1)begin
            host_write(i,image_words[i],i!=TOTAL_WORDS-1);
            if(PAYLOAD_BYTES>64 && i%16384==0)begin $display("PROGRESS host write %0d/%0d",i,TOTAL_WORDS);$fflush();end
        end
        if(stage_complete)$fatal(1,"Fixture did not exercise final loader tail");
        request_command(1);while(!ss_load)@(negedge clksys);
        busy=1;sys_tick(6);
        for(i=0;i<PAYLOAD_BYTES/8;i=i+1)begin
            engine_request(0,i,0);
            if(PAYLOAD_BYTES>64 && i%8192==0)begin $display("PROGRESS engine restore %0d/%0d",i,PAYLOAD_BYTES/8);$fflush();end
            if(engine_q!==payload_qword(i))$fatal(1,"RESTORE_MISMATCH qword=%0d got=%h wanted=%h",i,engine_q,payload_qword(i));
        end
        busy=0;n=0;while(!load_ok&&n<500)begin tick(1);n=n+1;end
        if(!load_ok||load_err||fault)$fatal(1,"Restore did not finish err=%0d",error);
        tick(40);
        // A single changed payload bit with unchanged envelope checksum must
        // never reach the mock live engine, even though staging fully commits.
        if(CORRUPT_CASE)begin
        base_load=load_pulses;
        for(i=0;i<TOTAL_WORDS;i=i+1)host_write(i,image_words[i]^(i==10?32'h1:32'h0),1);
        request_command(1);tick(50);
        if(!load_err||load_busy||load_pulses!=base_load||error!=5)$fatal(1,"Corrupt blob reached live engine error=%0d",error);
        end
        $display("PASS APF_STORAGE_ROUNDTRIP little=%0d mem_phase=%0.3f sys_half=%0.3f bytes=%0d saves=%0d loads=%0d checksum=%h",LITTLE,MEM_PHASE,SYS_HALF,PAYLOAD_BYTES+32,save_pulses,load_pulses,sum);
        $finish;
    end
    initial begin #(3000000.0+PAYLOAD_BYTES*3000.0);$fatal(1,"Integration global timeout");end
endmodule
