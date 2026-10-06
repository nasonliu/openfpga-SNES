// CRC32 identity of the accepted cartridge bytes and its loader configuration.
// This is accidental-mismatch detection, not a cryptographic authentication tag.
module savestate_rom_identity(
    input wire clk_sys, clk_host, reset_n,
    input wire image_begin, image_complete, image_fault,
    input wire write_en,
    input wire [24:0] write_addr,
    input wire [15:0] write_data,
    input wire [16:0] image_config,
    output reg [31:0] identity_host = 0,
    output reg [16:0] image_config_host = 0,
    output wire ready_host,
    output wire ready_sys
);
    function automatic [31:0] crc_word(input [31:0] c, input [15:0] d);
        reg [31:0] v;
        integer i;
        begin
            v=c;
            for(i=0;i<16;i=i+1) v=(v>>1)^((v[0]^d[i]) ? 32'hedb88320 : 32'b0);
            crc_word=v;
        end
    endfunction
    reg [31:0] crc=32'hffffffff, identity=0;
    reg [16:0] mounted_config=0;
    reg [24:0] next_addr=0;
    reg active=0, have_data=0, bad=0, ready=0;
    wire [31:0] crc_next=crc_word(image_begin || !have_data ? 32'hffffffff : crc,write_data);
    wire bad_address=write_en && write_addr!=(image_begin ? 25'b0 : next_addr);
    always @(posedge clk_sys or negedge reset_n) begin
        if(!reset_n) begin
            crc<=32'hffffffff; identity<=0; mounted_config<=0; next_addr<=0; active<=0; have_data<=0; bad<=0; ready<=0;
        end else begin
            if(image_begin) begin
                // Chip32 also emits an empty ROM-download cycle for battery
                // saves. Preserve the mounted identity until actual ROM bytes.
                crc<=32'hffffffff; next_addr<=0; active<=1; have_data<=0; bad<=0;
            end
            if(write_en && (active || image_begin)) begin
                crc<=crc_next;
                have_data<=1;
                ready<=0;
                next_addr<=write_addr+25'd2;
                if(bad_address) bad<=1;
            end
            if(image_fault) begin bad<=1; ready<=0; end
            if(image_complete && active) begin
                if(have_data || write_en) begin
                    identity<=~crc_word(crc_word(write_en ? crc_next : crc,image_config[15:0]),{15'b0,image_config[16]});
                    mounted_config<=image_config;
                    ready<=!bad && !bad_address && !image_fault && (next_addr!=0 || write_en);
                end
                active<=0;
            end
        end
    end
    (* async_reg="true", preserve, dont_merge, altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *) reg [2:0] ready_sync=0;
    always @(posedge clk_host or negedge reset_n) begin
        if(!reset_n) begin ready_sync<=0; identity_host<=0; image_config_host<=0; end
        else begin
            ready_sync<={ready_sync[1:0],ready};
            // Bundled data is held for the whole mounted-cartridge lifetime.
            if(ready_sync[1]) begin identity_host<=identity; image_config_host<=mounted_config; end
        end
    end
    assign ready_host=ready_sync[2];
    assign ready_sys=ready;
endmodule
