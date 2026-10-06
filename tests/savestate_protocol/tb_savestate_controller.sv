`timescale 1ns/1ps
module tb_savestate_controller;
    reg clk74=0, clksys=0;
    always #7 clk74=~clk74;
    always #23 clksys=~clksys;
    reg core_reset=1, bridge_rd=0, bridge_wr=0, endian=1;
    reg [31:0] addr=0, data=0, payload_size=16, rom_identity=32'hcafe0123;
    reg start=0, load=0, allow=0, admit=1, busy=0, fault=0;
    reg save_complete=1, auto_seal=1, seal_pending=0;
    integer seal_delay=0;
    reg lost=0, stage_drained=1, stage_complete=0, engine_drained=1;
    reg [31:0] checksum=32'h99aabbcc;
    wire start_ack,start_busy,start_ok,start_err,load_ack,load_busy,load_ok,load_err;
    wire ss_save,ss_load,ss_idle,ss_lock,ss_abort,clear,clear_toggle,accept,header_sel,blob_rd;
    wire [31:0] header,blob_size;
    wire [7:0] error;
    integer saves=0, loads=0, accepted=0, cases=0;
    localparam [31:0] SUM=32'h11111111+32'h22334455+32'habcdef01+32'h98765432;
    savestate_controller #(
        .MAX_PAYLOAD_SIZE(64),.TIMEOUT_TRIGGER(40),.TIMEOUT_WALK(80),
        .TIMEOUT_DRAIN(40),.TIMEOUT_STAGE(600),.TIMEOUT_READBACK(600),
        .TIMEOUT_COMMAND(1400),.SETTLE_CYCLES(4)
    ) dut (
        .clk_74a(clk74),.clk_sys_21_48(clksys),.core_reset(core_reset),
        .bridge_rd(bridge_rd),.bridge_wr(bridge_wr),.bridge_endian_little(endian),
        .bridge_addr(addr),.bridge_wr_data(data),.payload_size(payload_size),.rom_identity(rom_identity),
        .savestate_start(start),.savestate_start_ack_s(start_ack),.savestate_start_busy_s(start_busy),
        .savestate_start_ok_s(start_ok),.savestate_start_err_s(start_err),
        .savestate_load(load),.savestate_load_ack_s(load_ack),.savestate_load_busy_s(load_busy),
        .savestate_load_ok_s(load_ok),.savestate_load_err_s(load_err),
        .ss_admit(admit),.ss_allow(allow),.ss_busy(busy),.storage_fault(fault),.stage_lost(lost),
        .stage_drained(stage_drained),.stage_complete(stage_complete),.engine_drained(engine_drained),
        .save_complete(save_complete),.saved_payload_checksum(checksum),.ss_save(ss_save),.ss_load(ss_load),.ss_idle(ss_idle),
        .ss_lock(ss_lock),.ss_abort(ss_abort),.stage_clear(clear),.stage_clear_toggle74(clear_toggle),
        .stage_accept(accept),.header_select(header_sel),.header_rd_data(header),
        .blob_read_enable(blob_rd),.blob_size(blob_size),.protocol_error(error)
    );
    always @(posedge clksys) begin
        if(ss_save)begin
            saves<=saves+1;
            if(auto_seal)begin save_complete<=0;seal_pending<=1;seal_delay<=0;end
        end else if(seal_pending)begin
            if(seal_delay==8)begin save_complete<=1;seal_pending<=0;end
            else seal_delay<=seal_delay+1;
        end
        if(ss_load) begin
            loads<=loads+1;
            if(!stage_drained || !stage_complete || lost) $fatal(1,"Live load without committed stage");
        end
    end
    always @(posedge clk74) if(accept) accepted<=accepted+1;
    task automatic tick(input integer count); repeat(count) @(negedge clk74); endtask
    function automatic [31:0] swap(input [31:0] word);
        swap={word[7:0],word[15:8],word[23:16],word[31:24]};
    endfunction
    task automatic write_word(input [31:0] off, input [31:0] word);
        begin
            @(negedge clk74); addr=32'h40000000+off;data=endian?word:swap(word);bridge_wr=1;
            tick(2);bridge_wr=0;tick(4);
        end
    endtask
    task automatic read_word(input [31:0] off);
        begin
            @(negedge clk74);addr=32'h40000000+off;bridge_rd=1;
            tick(2);bridge_rd=0;tick(4);
        end
    endtask
    task automatic request(input bit isload);
        integer n;
        begin
            @(negedge clk74);if(isload) load=1;else start=1;
            n=0;
            while(!(isload?load_ack:start_ack) && n<100) begin tick(1);n=n+1;end
            if(n==100) $fatal(1,"APF command was not acknowledged");
            tick(2);if(isload)load=0;else start=0;tick(6);
        end
    endtask
    task automatic reset_core;
        begin
            @(negedge clk74);core_reset=1;allow=0;busy=0;fault=0;lost=0;
            admit=1;save_complete=1;auto_seal=1;seal_pending=0;stage_drained=1;stage_complete=0;engine_drained=1;bridge_wr=0;bridge_rd=0;start=0;load=0;
            tick(30);core_reset=0;allow=1;tick(50);
            if(ss_abort) $fatal(1,"Reset did not clear quarantine");
        end
    endtask
    // kind: 1 magic,2 version,3 size,4 identity,5 checksum,6 flags,
    // 7 reserved,8 short,9 gap,10 duplicate,11 out-of-range,12 trailing word.
    task automatic send_blob(input integer kind);
        integer i;
        reg [31:0] w;
        begin
            for(i=0;i<(kind==8?11:12);i=i+1) begin
                case(i)
                    0:w=32'h31535350;1:w=1;2:w=16;3:w=rom_identity;
                    4:w=SUM;5:w=1;6,7:w=0;8:w=32'h11111111;
                    9:w=32'h22334455;10:w=32'habcdef01;11:w=32'h98765432;
                endcase
                if(kind>=1 && kind<=7 && i==kind-1) w=w^32'h100;
                if(!(kind==9 && i==9)) write_word(i*4,w);
                if(kind==10 && i==9) write_word(i*4,w);
            end
            if(kind==11) write_word(32'h100000,1);
            if(kind==12) write_word(48,0);
        end
    endtask
    task automatic complete_walk(input bit isload);
        integer n;
        begin
            n=0;
            while((isload?loads:saves)==base_count && n<100) begin tick(1);n=n+1;end
            if(n==100)$fatal(1,"No engine trigger");
            tick(8);
            if(isload?load_ok:start_ok)$fatal(1,"Success before ss_busy entered");
            @(negedge clksys);busy=1;engine_drained=0;
            repeat(8) @(negedge clksys);
            busy=0;tick(30);
            if(isload?load_ok:start_ok)$fatal(1,"Success before storage drained");
            engine_drained=1;
            n=0;
            while(!(isload?load_ok:start_ok) && n<100)begin tick(1);n=n+1;end
            if(n==100)$fatal(1,"Walk completion not reported err=%0d",error);
            if(isload?load_busy:start_busy)$fatal(1,"Busy held after completed walk");
        end
    endtask
    integer base_count, before_count, k;
    initial begin
        #2000000;$fatal(1,"Global simulation timeout");
    end
    initial begin
        reset_core();
        // Unsupported / cart not ready must still be acknowledged.
        allow=0;tick(10);before_count=saves;request(0);
        if(!start_err || start_busy || saves!=before_count)$fatal(1,"Unsupported request accepted");
        cases=cases+1;reset_core();

        // The host transfer happens entirely before A4; an empty staging queue
        // alone is insufficient while data_loader's final words are in flight.
        before_count=accepted;send_blob(0);tick(20);base_count=loads;request(1);tick(20);
        if(!load_busy || loads!=base_count || accepted-before_count!=4)$fatal(1,"Pre-A4 capture/count failed");
        if(!ss_lock)$fatal(1,"Preload/restore lock missing");
        stage_complete=1;stage_drained=0;tick(20);
        if(loads!=base_count)$fatal(1,"Restore began before staging drain");
        stage_drained=1;complete_walk(1);cases=cases+1;reset_core();

        // All malformed formats remain isolated in PSRAM; no live-core pulse.
        for(k=1;k<=12;k=k+1)begin
            send_blob(k);stage_complete=1;tick(20);before_count=loads;request(1);tick(20);
            if(!load_err || load_busy || loads!=before_count)$fatal(1,"Malformed blob %0d reached core (%0d)",k,error);
            cases=cases+1;reset_core();
        end
        // Checksum input really is compared, independently of payload contents.
        send_blob(0);write_word(36,0);stage_complete=1;before_count=loads;request(1);
        if(!load_err||loads!=before_count)$fatal(1,"Duplicate payload write accepted");
        cases=cases+1;reset_core();

        // Big-endian APF word transport uses exactly data_loader normalization.
        endian=0;send_blob(0);stage_complete=1;base_count=loads;request(1);complete_walk(1);
        endian=1;cases=cases+1;reset_core();

        send_blob(0);stage_complete=1;lost=1;tick(20);before_count=loads;request(1);tick(20);
        if(!load_err||loads!=before_count)$fatal(1,"Lost storage beat accepted");
        cases=cases+1;reset_core();

        // Reject mid-transfer A4, but a completely new offset-zero blob works.
        write_word(0,32'h31535350);request(1);
        if(!load_err)$fatal(1,"Partial header accepted");
        send_blob(0);stage_complete=1;base_count=loads;request(1);complete_walk(1);
        cases=cases+1;reset_core();

        // A0 completes only on real engine entry, exit, and final memory drain.
        base_count=saves;request(0);complete_walk(0);
        addr=32'h40000000;#1;if(header!=32'h31535350)$fatal(1,"Save header magic");
        addr=32'h40000010;#1;if(header!=checksum)$fatal(1,"Saved checksum mailbox");
        endian=0;#1;if(header!=swap(checksum))$fatal(1,"Header endian transform");endian=1;
        for(k=0;k<12;k=k+1)read_word(k*4);
        tick(270);if(ss_lock)$fatal(1,"Completed readback did not release lock");
        cases=cases+1;reset_core();

        // First/last word alone must not count as a full readback.
        base_count=saves;request(0);complete_walk(0);read_word(44);
        if(!start_err || error!=4)$fatal(1,"Partial readback did not flag coverage");
        cases=cases+1;reset_core();

        // Trigger timeout preserves an abort lock until actual console reset.
        base_count=saves;request(0);tick(180);
        if(!start_err||start_busy||!ss_abort)$fatal(1,"Missing trigger timeout quarantine");
        before_count=saves;request(0);tick(20);
        if(saves!=before_count||!start_err)$fatal(1,"Quarantined engine rearmed");
        cases=cases+1;reset_core();

        // Simultaneous contradictory requests both ack/error without trigger.
        before_count=saves+loads;@(negedge clk74);start=1;load=1;tick(4);
        if(!start_ack||!load_ack||!start_err||!load_err)$fatal(1,"Simultaneous command response");
        start=0;load=0;tick(20);if(saves+loads!=before_count)$fatal(1,"Simultaneous request dispatched");
        cases=cases+1;reset_core();

        // Queue ownership remains with the active operation on duplicate A0.
        base_count=saves;request(0);tick(20);before_count=saves;request(0);
        if(!start_busy||!start_err||saves!=before_count)$fatal(1,"Duplicate A0 lost active ownership");
        complete_walk(0);cases=cases+1;reset_core();

        // A save cannot overwrite an already staged restore.
        send_blob(0);before_count=saves;request(0);
        if(!start_err||saves!=before_count)$fatal(1,"Save raced preloaded restore");
        cases=cases+1;reset_core();

        // Uncommitted tail never reaches live state, even after stage timeout.
        send_blob(0);before_count=loads;request(1);tick(620);
        if(!load_err||load_busy||loads!=before_count||ss_abort)$fatal(1,"Stage timeout handling");
        cases=cases+1;reset_core();

        // An abandoned pre-A4 transfer expires without any engine operation.
        write_word(0,32'h31535350);tick(630);before_count=loads;request(1);
        if(!load_err||loads!=before_count)$fatal(1,"Expired preload accepted");
        cases=cases+1;reset_core();

        // A walk which never exits is quarantined, with APF busy deasserted.
        base_count=saves;request(0);while(saves==base_count)tick(1);@(negedge clksys);busy=1;engine_drained=0;tick(300);
        if(!start_err||start_busy||!ss_abort)$fatal(1,"Walk timeout did not quarantine");
        cases=cases+1;reset_core();

        // Falling ss_busy is insufficient if a last storage write never drains.
        base_count=saves;request(0);while(saves==base_count)tick(1);@(negedge clksys);busy=1;engine_drained=0;
        repeat(8)@(negedge clksys);busy=0;tick(170);
        if(!start_err||start_busy||!ss_abort)$fatal(1,"Drain timeout did not quarantine");
        cases=cases+1;reset_core();

        // Physical storage fault immediately fails and quarantines the walk.
        base_count=saves;request(0);while(saves==base_count)tick(1);@(negedge clksys);busy=1;fault=1;tick(30);
        if(!start_err||start_busy||!ss_abort)$fatal(1,"Storage fault did not quarantine");
        cases=cases+1;reset_core();

        // Core reset while a real walk is active must never become success.
        base_count=saves;request(0);while(saves==base_count)tick(1);@(negedge clksys);busy=1;
        repeat(8)@(negedge clksys);core_reset=1;allow=0;busy=0;tick(40);
        if(!start_err||start_ok||start_busy)$fatal(1,"Reset mistaken for walk completion");
        core_reset=0;allow=1;tick(50);cases=cases+1;reset_core();

        // Readback abandonment returns an error instead of releasing silently.
        base_count=saves;request(0);complete_walk(0);read_word(0);tick(620);
        if(!start_err||start_ok||error!=7)$fatal(1,"Readback timeout not reported");
        cases=cases+1;reset_core();

        // Existing backup ownership denies a NEW savestate before trigger.
        admit=0;tick(20);before_count=saves;request(0);
        if(!start_err||start_busy||saves!=before_count)$fatal(1,"New save entered existing backup");
        cases=cases+1;reset_core();

        // Pending backup AFTER ownership acquisition waits for the walk.
        base_count=saves;request(0);tick(20);admit=0;complete_walk(0);
        if(ss_abort||start_err)$fatal(1,"Queued backup revoked running save");
        cases=cases+1;reset_core();

        // Pre-A4 staged ownership also survives a newly queued backup.
        send_blob(0);tick(30);admit=0;stage_complete=1;base_count=loads;
        request(1);complete_walk(1);
        if(ss_abort||load_err)$fatal(1,"Queued backup revoked preloaded restore");
        cases=cases+1;reset_core();

        // If a backup wins before the host command crosses, reject safely.
        before_count=saves;@(negedge clk74);start=1;tick(2);admit=0;
        tick(30);start=0;tick(20);
        if(!start_err||start_busy||saves!=before_count||ss_abort)$fatal(1,"Admission CDC race did not reject safely");
        cases=cases+1;reset_core();

        // A missing serializer helper can fake a busy cycle with no writes.
        // Engine exit is not a successful snapshot without a committed header.
        save_complete=0;auto_seal=0;base_count=saves;request(0);while(saves==base_count)tick(1);
        @(negedge clksys);busy=1;repeat(8)@(negedge clksys);
        busy=0;tick(40);
        if(!start_err||start_ok||start_busy||!ss_abort)$fatal(1,"Empty fake walk became successful snapshot");
        cases=cases+1;reset_core();

        // Previous save_complete cannot authenticate a later empty walk while
        // save_begin is still crossing to memory. A fresh low/high is required.
        save_complete=1;auto_seal=0;base_count=saves;request(0);while(saves==base_count)tick(1);
        @(negedge clksys);busy=1;repeat(2)@(negedge clksys);busy=0;tick(40);
        if(!start_err||start_ok||start_busy||!ss_abort)$fatal(1,"Stale save seal accepted as current snapshot");
        cases=cases+1;reset_core();

        // No live request may emerge from a command cancelled during reset CDC.
        before_count=saves;@(negedge clk74);start=1;tick(2);core_reset=1;allow=0;tick(20);
        start=0;tick(10);core_reset=0;allow=1;tick(60);
        if(saves!=before_count)$fatal(1,"Reset replayed pending save command");
        cases=cases+1;
        $display("PASS: savestate controller %0d scenarios; saves=%0d loads=%0d",cases,saves,loads);
        $finish;
    end
endmodule
