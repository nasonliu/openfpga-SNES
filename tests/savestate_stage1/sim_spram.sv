// FPGA primitive model for the production boot1_rom wrapper only.
// Synchronous address, unregistered output, zero fill beyond actual helper.
module spram #(parameter addr_width=8,data_width=8,mem_init_file=" ",mem_name="MEM")(
 input clock,input [addr_width-1:0] address,output [data_width-1:0] q);
 reg [data_width-1:0] memory[0:(1<<addr_width)-1];
 reg [addr_width-1:0] address_r=0;
 string helper_file;
 integer i,missing_helper;
 initial begin
   if(mem_init_file!="rtl/mister_top/boot1.mif") $fatal(1,"UNEXPECTED_BOOT_MIF");
   if(addr_width!=11 || data_width!=16) $fatal(1,"UNEXPECTED_BOOT_PRIMITIVE");
   for(i=0;i<(1<<addr_width);i=i+1) memory[i]=0;
   if(!$value$plusargs("helper=%s",helper_file)) $fatal(1,"HELPER_FILE_REQUIRED");
   $readmemh(helper_file,memory);
   missing_helper=0;
   if($value$plusargs("missing_helper=%d",missing_helper) && missing_helper)
     for(i=0;i<(1<<addr_width);i=i+1) memory[i]=16'heaea;
 end
 always @(posedge clock) address_r<=address;
 assign q=memory[address_r];
endmodule
