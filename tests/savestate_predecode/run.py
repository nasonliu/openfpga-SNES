#!/usr/bin/env python3
"""Source-bound PA_ARAM combinational proof; no timing or full-core signoff."""
import argparse, hashlib, json, re, subprocess, sys
from pathlib import Path
R=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(R/'tests'))
from pinned_source import reconstruct
BASE_DIR=R/'tests/fixtures/savestate_predecode'
BASE_MANIFEST=json.loads((BASE_DIR/'manifest.json').read_text())
BASE=BASE_MANIFEST['source_revision']
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--out',default='build/savestate-predecode');a=p.parse_args()
O=(R/a.out).resolve();O.mkdir(parents=True,exist_ok=True)
files=['rtl/upstream/CPU.vhd','rtl/upstream/SNES.vhd','rtl/upstream/main.v','rtl/upstream/savestates.sv']
src={n:(R/n).read_text() for n in files}
def old(n):
 entry=next(f for f in BASE_MANIFEST['files'] if f['path']==n)
 data=reconstruct(R,entry)
 assert len(data)==entry['bytes'], 'Baseline size mismatch: '+n
 assert hashlib.sha256(data).hexdigest()==entry['sha256'], 'Baseline SHA-256 mismatch: '+n
 assert hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()==entry['git_blob_sha'], 'Baseline Git blob mismatch: '+n
 return data.decode()
def run(cmd,log):
 q=subprocess.run(cmd,cwd=O,text=True,capture_output=True);(O/log).write_text(q.stdout+q.stderr);q.check_returncode();return q.stdout
cpu=src[files[0]]
predicate=re.search(r'    PA_ARAM <=.*?;',cpu,re.S)[0]
branch=re.search(r'\tprocess\(P65_A, EN, CPU_RD.*?\n\tbegin\n(.*?)\n\t\tend if;',cpu,re.S)[1]+'\n\t\tend if;'
# Remove only the exact permitted edits and compare every remaining byte with
# the fitted original: this binds unchanged registers, strobes and bus phases.
s=cpu.replace("        -- Parallel $2184 predicate; used only by the standard savestate profile.\n        PA_ARAM         : out std_logic := '0';\n",'')
s=s.replace('    -- Same PA ownership/qualification as below, decoded before the byte mux.\n    -- Pure combinational factorization: no extra state, strobe or bus phase.\n'+predicate+'\n\n','')
assert s==old(files[0]),'CPU changed outside predecode insertion'
s=src[files[1]].replace("        PA_ARAM     : out std_logic := '0';\n",'').replace('        PA_ARAM     => PA_ARAM,\n','')
assert s==old(files[1]),'SNES changed outside port chain'
s=src[files[2]].replace('wire        PA_ARAM;\n','').replace('    .pa_aram(PA_ARAM),\n','').replace('savestates #(\n    .USE_ARAM_PREDECODE(USE_SS && USE_STANDARD_SDRAM)\n) ss','savestates ss')
assert s==old(files[2]),'main changed outside port chain and opt-in guard'
s=src[files[3]].replace("module savestates #(\n    parameter USE_ARAM_PREDECODE = 1'b0\n)",'module savestates').replace('    input             pa_aram,\n','').replace("// Keep the original selector in every legacy/non-standard instantiation.\nassign aram_sel = ss_busy & (USE_ARAM_PREDECODE ? pa_aram : (pa == 8'h84));","assign aram_sel = ss_busy & (pa == 8'h84);")
assert s==old(files[3]),'savestates changed outside parameter/input/selector'
assert src[files[2]].count('.pa_aram(PA_ARAM)')==2
assert 'PA_ARAM     => PA_ARAM' in src[files[1]]
assert '.USE_ARAM_PREDECODE(USE_SS && USE_STANDARD_SDRAM)' in src[files[2]]
model='''library ieee; use ieee.std_logic_1164.all;
entity selector_model is port (
 P65_A: in std_logic_vector(23 downto 0); DMA_B: in std_logic_vector(7 downto 0);
 EN, P65_EN, HDMA_BUS_ACTIVE, DMA_TRANSFER: in std_logic;
 CPU_RD, CPU_WR, HDMA_B_RD, HDMA_B_WR, DMA_B_RD, DMA_B_WR: in std_logic;
 PA: out std_logic_vector(7 downto 0); PA_ARAM, PARD_N, PAWR_N: out std_logic);
end; architecture rtl of selector_model is begin
'''+predicate+'\nprocess(all) begin\n'+branch+'\nend process; end;\n'
(O/'selector_model.vhd').write_text(model)
q=subprocess.run(['ghdl','--synth','--std=08','--out=verilog','selector_model.vhd','-e','selector_model'],cwd=O,text=True,capture_output=True);(O/'ghdl.log').write_text(q.stderr);q.check_returncode();(O/'selector_model.v').write_text(q.stdout)
miter='''module miter(input [23:0] p65_a,input [7:0] dma_b,
 input en,p65_en,hdma_bus_active,dma_transfer,cpu_rd,cpu_wr,hdma_b_rd,hdma_b_wr,dma_b_rd,dma_b_wr,
 output equivalent,output mutant_equivalent);
 wire [7:0] pa; wire pa_aram,pard_n,pawr_n;
 selector_model dut(.P65_A(p65_a),.DMA_B(dma_b),.EN(en),.P65_EN(p65_en),.HDMA_BUS_ACTIVE(hdma_bus_active),.DMA_TRANSFER(dma_transfer),.CPU_RD(cpu_rd),.CPU_WR(cpu_wr),.HDMA_B_RD(hdma_b_rd),.HDMA_B_WR(hdma_b_wr),.DMA_B_RD(dma_b_rd),.DMA_B_WR(dma_b_wr),.PA(pa),.PA_ARAM(pa_aram),.PARD_N(pard_n),.PAWR_N(pawr_n));
 assign equivalent=(pa_aram == (pa==8'h84));
 // Negative control: suppressing an active DMA request is observably wrong.
 assign mutant_equivalent=((pa_aram && !dma_transfer) == (pa==8'h84));
endmodule
'''
(O/'miter.sv').write_text(miter)
prelude='read_verilog -sv selector_model.v miter.sv\nprep -top miter -flatten\n'
for name,cmd,mark in [('binary-proof','sat -prove equivalent 1 -verify','SAT proof finished - no model found: SUCCESS!'),('dma-negative','sat -prove mutant_equivalent 1 -falsify -show-inputs -show-outputs','SAT proof finished - model found: FAIL!')]:
 (O/(name+'.ys')).write_text(prelude+cmd+'\n');log=run(['yosys','-Q','-s',name+'.ys'],name+'.log');assert mark in log
 print('PASS '+name,flush=True)
# Four-state boundary checks use the actual synthesized source expression and
# actual savestates parameter selection, including an unconnected/X sideband
# in fallback mode. Unknown active qualification is not claimed equivalent.
tb='''`timescale 1ns/1ps
module tb;
reg [23:0] p65_a=0;reg [7:0] dma_b=0;
reg en=1,p65_en=1,hdma_bus_active=0,dma_transfer=0;
reg cpu_rd=0,cpu_wr=0,hdma_b_rd=0,hdma_b_wr=0,dma_b_rd=0,dma_b_wr=0;
wire [7:0] pa;wire pa_aram,pard_n,pawr_n;
selector_model dut(.P65_A(p65_a),.DMA_B(dma_b),.EN(en),.P65_EN(p65_en),.HDMA_BUS_ACTIVE(hdma_bus_active),.DMA_TRANSFER(dma_transfer),.CPU_RD(cpu_rd),.CPU_WR(cpu_wr),.HDMA_B_RD(hdma_b_rd),.HDMA_B_WR(hdma_b_wr),.DMA_B_RD(dma_b_rd),.DMA_B_WR(dma_b_wr),.PA(pa),.PA_ARAM(pa_aram),.PARD_N(pard_n),.PAWR_N(pawr_n));
reg [7:0] pa_test=0;reg sideband=1'bx;
wire original_sel,optimized_sel;
savestates legacy(.pa(pa_test),.pa_aram(sideband),.aram_sel(original_sel));
savestates #(.USE_ARAM_PREDECODE(1)) candidate(.pa(pa_test),.pa_aram(sideband),.aram_sel(optimized_sel));
integer i,edges=0;
task check(input expected);begin #1;if(pa_aram!==expected || (pa==8'h84)!==expected)$fatal(1,"boundary mismatch pa=%h new=%b expected=%b",pa,pa_aram,expected);edges=edges+1;end endtask
initial begin
force legacy.ss_busy=1'b1;force candidate.ss_busy=1'b1;
for(i=0;i<256;i=i+1)begin pa_test=i;sideband=1'bx;#1;if(original_sel!==(pa_test==8'h84))$fatal(1,"legacy depends on new sideband");end
pa_test=8'h00;sideband=1;#1;if(optimized_sel!==1)$fatal(1,"candidate sideband ignored");
force candidate.ss_busy=0;sideband=1'bx;#1;if(optimized_sel!==0)$fatal(1,"idle engine leaks unknown select");
p65_a=24'h002184;dma_b=8'hxx;check(1);
p65_a=24'h402184;check(0);
p65_a=24'h002185;check(0);
p65_a=24'hxxxxxx;p65_en=0;check(0);
hdma_bus_active=1;dma_b=8'h84;check(1);
dma_b=8'h85;check(0);
hdma_bus_active=0;dma_transfer=1;dma_b=8'h84;check(1);
dma_b=8'hff;check(0);
// Selected unknown data stays unknown through both 4-state translated cones.
dma_b=8'b1000x100;check(1'bx);
// CPU select and nonmatching known low bit mask an unrelated unknown bit.
dma_transfer=0;p65_en=1;p65_a=24'h002184;p65_a[0]=1;p65_a[3]=1'bx;check(0);
$display("PASS four-state masking, inactive engine, all 256 legacy bytes, selected-X boundary; %0d decoder boundaries",edges);$finish;
end
endmodule
'''
(O/'tb.sv').write_text(tb)
# Existing upstream procedural output uses implicit wire; Icarus needs reg.
# This declaration-only simulation copy is not written into production RTL.
assert src[files[3]].count('output     [23:0] rom_addr,')==1
(O/'savestates_sim.sv').write_text(src[files[3]].replace('output     [23:0] rom_addr,','output reg [23:0] rom_addr,'))
run(['iverilog','-g2012','-s','tb','-o','sim','selector_model.v','savestates_sim.sv',str(R/'rtl/upstream/savestates_regs.sv'),str(R/'rtl/upstream/savestates_map.sv'),str(R/'rtl/upstream/savestates_sa1.sv'),'tb.sv'],'iverilog.log')
log=run(['vvp','sim'],'four-state.log');assert 'PASS four-state' in log;print(log.strip(),flush=True)
summary={'passed':True,'baseline_commit':BASE,'source_sha256':{n:hashlib.sha256((R/n).read_bytes()).hexdigest() for n in files},'test_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),'source_preservation':'All other bytes in all four edited RTL files equal fitted 9e1fb49 source after removing only enumerated combinational/port/parameter edits.','proof_scope':'Unconditional combinational equivalence for all binary values of the complete 24-bit CPU address, DMA byte, ownership, enables and read/write controls. Stronger than reachable active binary cases.','checks':['source-and-profile-contract','binary-SAT-equivalence','DMA-negative-rejected','4-state-selected-data-and-inactive-mask','256-byte-default-fallback-independence'],'limits':['No equivalence claim for arbitrary unknown active ownership/qualification: VHDL boolean tests, synthesis and SV X propagation may differ.','No delay/glitch, placement, timing closure, sequential full-core or hardware proof.'],'generated_model_sha256':hashlib.sha256(model.encode()).hexdigest()}
(O/'summary.json').write_text(json.dumps(summary,indent=2)+'\n');print('PASS source-bound latency-free candidate; '+str(O/'summary.json'))
