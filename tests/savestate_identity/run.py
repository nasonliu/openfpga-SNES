#!/usr/bin/env python3
"""Actual ROM identity RTL, host CDC and negative-order tests."""
from pathlib import Path
import subprocess,zlib,json,hashlib,os
R=Path(__file__).resolve().parents[2]; O=R/'build/savestate-identity'; O.mkdir(parents=True,exist_ok=True)
payload=bytes(range(64)); config=0x12345
expected=zlib.crc32(payload+config.to_bytes(4,'little'))
body='''`timescale 1ns/1ps
module tb;
reg s=0,h=0,r=0,b=0,c=0,f=0,w=0;
reg[24:0] a=0;reg[15:0] d=0;reg[16:0] cfg_in=17'h12345;wire[31:0] id;wire[16:0] cfg;wire rh,rs;
always #5 s=~s;always #7 h=~h;
savestate_rom_identity dut(s,h,r,b,c,f,w,a,d,cfg_in,id,cfg,rh,rs);
task start;begin @(negedge s);b=1;@(negedge s);b=0;end endtask
task word(input[24:0] addr,input[15:0] data);begin @(negedge s);w=1;a=addr;d=data;@(negedge s);w=0;end endtask
task finish;begin @(negedge s);c=1;@(negedge s);c=0;repeat(10)@(negedge h);end endtask
integer i;
initial begin #20;r=1;start();
for(i=0;i<64;i=i+2)word(i,((i+1)<<8)|i);
finish();
'''+f'if(!rh||id!==32\'h{expected:08x}||cfg!==17\'h12345)$fatal(1,"CRC mismatch id=%h ready=%b",id,rh);\n'+f'cfg_in=17\'h0abcd;start();finish();if(!rh||id!==32\'h{expected:08x}||cfg!==17\'h12345)$fatal(1,"empty battery-save or raw config change destroyed mounted identity");\n'+'''
start();word(2,16'h1234);finish();if(rh)$fatal(1,"out-of-order image accepted");
start();word(0,16'h0123);f=1;finish();if(rh)$fatal(1,"faulted image accepted");f=0;
start();word(0,16'h0123);finish();if(!rh)$fatal(1,"new image did not recover");
r=0;#3;if(rh)$fatal(1,"reset did not clear host ready");
$display("PASS actual CRC32 identity, empty battery-save preservation, mounted config isolation, host CDC, order fault, image fault, reset and recovery");$finish;end
endmodule
'''
(O/'tb.sv').write_text(body)
rtl=R/'target/pocket/savestate_rom_identity.sv'
cmd=['iverilog','-g2012','-s','tb','-o',str(O/'sim'),str(rtl),str(O/'tb.sv')]
p=subprocess.run(cmd,text=True,capture_output=True);(O/'compile.log').write_text(p.stdout+p.stderr);p.check_returncode()
p=subprocess.run(['vvp',str(O/'sim')],text=True,capture_output=True);(O/'run.log').write_text(p.stdout+p.stderr);p.check_returncode();assert 'PASS' in p.stdout;print(p.stdout,end='')
(O/'summary.json').write_text(json.dumps({'passed':True,'scope':'ROM identity RTL only','expected_crc32':f'{expected:08x}','rtl_sha256':hashlib.sha256(rtl.read_bytes()).hexdigest(),'test_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),'generated_bench_sha256':hashlib.sha256((O/'tb.sv').read_bytes()).hexdigest()},indent=2)+'\n')
