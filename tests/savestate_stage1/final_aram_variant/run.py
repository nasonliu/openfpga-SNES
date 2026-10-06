#!/usr/bin/env python3
"""Final staged ARAM/write-setup/read7/hold/recovery joint core qualification.
Extracts selected production wrapper bindings instead of re-authoring them.
"""
from pathlib import Path
import argparse,hashlib,importlib.util,json,re,subprocess,sys,time
HERE=Path(__file__).resolve().parent;BASE=HERE.parent;ROOT=BASE.parents[1]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def mod(name,path):
 spec=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m

def wrapper_boundary(wrapper):
 start=wrapper.index('  generate if(USE_SS) begin: g_state_aram_sram')
 end=wrapper.index('  end else begin: g_original_aram_psram',start)
 body=wrapper[start+len('  generate if(USE_SS) begin: g_state_aram_sram'):end]
 compact=lambda s:re.sub(r'\s+','',s)
 required=['aram_request_stage request_stage(','.clk_sys(clk_sys),.reset_n(pll_locked)',
 '.write_en(clearing_ram ? 1\'b1 : (block_ram_clients || !RESET_N) ? 1\'b0 : ~ARAM_CE_N & ~ARAM_WE_N)',
 '.read_en((block_ram_clients || !RESET_N) ? 1\'b0 : ~ARAM_CE_N & ~ARAM_OE_N)',
 '.address(psram_aram_addr),.data(aram_data)',
 '.memory_write(stage_write),.memory_read(stage_read),.memory_address(stage_addr),.memory_data(stage_data)',
 'assign aram_psram_busy = physical_busy || stage_write || stage_read;',
 '.addr(stage_addr[15:1])','.write_en(stage_write),.read_en(stage_read)',
 ".data_in(stage_addr[0] ? {stage_data,8'b0} : {8'b0,stage_data})",
 '.write_high_byte(stage_addr[0]),.write_low_byte(~stage_addr[0])','.busy(physical_busy)']
 for fragment in required:
  if compact(fragment)not in compact(body):raise RuntimeError('Production ARAM binding changed: '+fragment)
 return_mux=re.search(r'assign ARAM_Q\s*=\s*psram_aram_addr\[0\].*?;',wrapper,re.S)[0]
 if compact(return_mux)!='assignARAM_Q=psram_aram_addr[0]?aram_16_out[15:8]:aram_16_out[7:0];':raise RuntimeError('Unexpected ARAM return-byte mux')
 prefix='''
 // Signal aliases for the selected production wrapper block. The PLL is up
 // before CPU reset releases, exposing the real !RESET_N request masking.
 reg aram_hard_reset_n=0;
 initial begin repeat(50)@(negedge clk);aram_hard_reset_n=1;end
 wire clk_sys=clk,clk_mem_85_9=clk_mem,pll_locked=aram_hard_reset_n;
 wire RESET_N=reset_n,clearing_ram=1'b0,block_ram_clients=1'b0;
 wire ARAM_CE_N=ac,ARAM_WE_N=aw,ARAM_OE_N=ao;
 wire [15:0] psram_aram_addr=aa;
 wire [7:0] aram_data=ad;
 wire [15:0] aram_16_out;
 wire [7:0] ARAM_Q;
 wire aram_psram_busy;
 wire [16:0] sram_a;
 wire [15:0] sram_dq;
 wire sram_oe_n,sram_we_n,sram_ub_n,sram_lb_n;
 generate if(1)begin:g_extracted_aram
'''
 suffix='''
 end endgenerate
 pin_sram_model aram_pins(.clk_mem(clk_mem),.reset_n(pll_locked),
 .sram_a(sram_a),.sram_dq(sram_dq),.sram_oe_n(sram_oe_n),.sram_we_n(sram_we_n),.sram_ub_n(sram_ub_n),.sram_lb_n(sram_lb_n));
 assign aq=ARAM_Q;
 integer reset_gate_checks=0,reset_gate_raw_active=0,queued_busy_cycles=0;
 always @(negedge clk_mem)if(pll_locked)begin
  if(!RESET_N)begin
   reset_gate_checks++;
   if(!ac&&(!ao||!aw))reset_gate_raw_active++;
   if(g_extracted_aram.stage_read || g_extracted_aram.stage_write || !sram_oe_n || !sram_we_n)$fatal(1,"ARAM_RESET_GATE_FAILED");
  end
  if((g_extracted_aram.stage_read || g_extracted_aram.stage_write) && !g_extracted_aram.physical_busy)begin
   queued_busy_cycles++;
   if(!aram_psram_busy)$fatal(1,"ARAM_QUEUED_REQUEST_NOT_BUSY");
  end
 end
'''
 old_boundary=(BASE/'aram_pin_variant/aram_boundary.svh').read_text()
 monitors=old_boundary[old_boundary.index(' integer helper_aram_reads='):]
 return prefix+body+suffix+return_mux+'\n'+monitors,body

def generate(source,wrapper):
 old=mod('old_joint',BASE/'aram_pin_variant/run.py');s=old.generate(source,True)
 old_boundary=(BASE/'aram_pin_variant/aram_boundary.svh').read_text();boundary,extract=wrapper_boundary(wrapper)
 if s.count(old_boundary)!=1:raise RuntimeError('Old boundary not uniquely identified')
 s=s.replace(old_boundary,boundary).replace('module tb_aram_joint;','module tb_final_aram;')
 old_marker='  $display("PASS REAL_CORE_DUAL_MEMORY_PINS'
 if s.count(old_marker)!=1:raise RuntimeError('Completion anchor missing')
 s=s.replace(old_marker,'''  if(reset_gate_checks<100 || queued_busy_cycles<100)$fatal(1,"ARAM_WRAPPER_GUARD_COVERAGE");
  $display("ARAM_WRAPPER_GUARDS reset_gate_checks=%0d blocked_raw_requests=%0d queued_busy_cycles=%0d",reset_gate_checks,reset_gate_raw_active,queued_busy_cycles);
  $display("PASS FINAL_STAGED_ARAM_ROUNDTRIP''')
 return s,extract

def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--base-build',type=Path,default=BASE/'build');p.add_argument('--out',type=Path,default=HERE/'build');p.add_argument('--skip-build',action='store_true');p.add_argument('--mapping',choices=['lorom','hirom','both'],default='both');p.add_argument('--skip-negative',action='store_true');a=p.parse_args();base=a.base_build.resolve();out=a.out.resolve();out.mkdir(parents=True,exist_ok=True)
 bm=json.loads((base/'build-manifest.json').read_text());hashes=bm['sources_sha256'].copy()
 for path,digest in hashes.items():
  if sha(ROOT/path)!=digest:raise RuntimeError('Stale base core '+path)
 production=[ROOT/'rtl/mister_top/savestate.sv',ROOT/'rtl/mister_top/psram_blob.sv',ROOT/'target/pocket/psram.sv',ROOT/'target/pocket/sram.sv',ROOT/'target/pocket/sram_ctrl.sv',ROOT/'target/pocket/aram_request_stage.sv']
 extra=[*production,ROOT/'rtl/mister_top/SNES.sv',ROOT/'target/pocket/core.qip',HERE/'run.py',BASE/'aram_pin_variant/run.py',BASE/'aram_pin_variant/aram_boundary.svh',BASE/'aram_pin_variant/pin_sram_model.sv',BASE/'pin_variant/run.py',BASE/'pin_variant/storage_boundary.svh',BASE/'pin_variant/pin_psram_model.sv',BASE/'sram_variant/run.py',BASE/'sram_variant/fixture.py']
 hashes.update({str(path.relative_to(ROOT)):sha(path)for path in extra})
 if 'aram_request_stage.sv'not in (ROOT/'target/pocket/core.qip').read_text():raise RuntimeError('ARAM stage missing from production QIP')
 summary={'status':'in_progress','hardware_verified':False,'loaded_io_timing_verified':False,'apf_verified':False,'scope':'actual core/helper/statePSRAM with source-extracted stagedARAM wrapper and read7/writeSetup/HOLD/RECOVER SRAM controller;55ns ideal pin envelope; both ordinary SRAM mappings','sources_sha256':hashes,'checks':[]}
 (out/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
 try:
  snap=out/'source_snapshot';snap.mkdir(exist_ok=True)
  for name,digest in bm['compile_inputs_sha256'].items():
   src=base/name
   if sha(src)!=digest:raise RuntimeError('Altered base artifact '+name)
   (snap/src.name).write_bytes(src.read_bytes())
  bench,extract=generate((snap/'tb_roundtrip.sv').read_text(),(ROOT/'rtl/mister_top/SNES.sv').read_text());(snap/'tb_final_aram.sv').write_text(bench);(out/'wrapper-extract.sv').write_text(extract)
  for path in production+[BASE/'aram_pin_variant/pin_sram_model.sv',BASE/'pin_variant/pin_psram_model.sv']:(snap/path.name).write_bytes(path.read_bytes())
  sys.path.insert(0,str(BASE));base_run=mod('core_base',BASE/'run.py');fixture=mod('sram_fixture',BASE/'sram_variant/fixture.py')
  helper=base_run.read_helper_mif(ROOT/'rtl/mister_top/boot1.mif');assert helper==(ROOT/'rtl/upstream/releases/boot1.rom').read_bytes().ljust(4096,b'\0')
  (out/'helper.hex').write_text(''.join(f'{int.from_bytes(helper[i:i+2],"little"):04x}\n'for i in range(0,4096,2)))
  for mapping in ['lorom','hirom']:
   rom,spec=fixture.build_fixture(mapping,with_spc=True);(out/(mapping+'.hex')).write_text(''.join(f'{x:02x}\n'for x in rom));(out/(mapping+'.json')).write_text(json.dumps(spec,indent=2)+'\n')
  names=['SNES.v','DSP_LHRomMap.v','main.v','snes_rom_client.sv','boot1_rom.sv','savestates.sv','savestates_map.sv','savestates_regs.sv','savestates_sa1.sv','sim_spram.sv','savestate.sv','psram_blob.sv','psram.sv','sram.sv','sram_ctrl.sv','aram_request_stage.sv','pin_psram_model.sv','pin_sram_model.sv','tb_final_aram.sv'];files=[snap/n for n in names]
  summary['wrapper_extract_sha256']=sha(out/'wrapper-extract.sv');summary['compile_inputs_sha256']={str(p.relative_to(out)):sha(p)for p in files};exe=out/'obj/Vtb_final_aram';bind=out/'build-binding.json'
  if not a.skip_build:
   cmd=['verilator','+1364-2005ext+v','--binary','--timing','--assert','-Wno-fatal','--top-module','tb_final_aram','--Mdir',str(out/'obj'),'-j','2','-O1',*map(str,files)]
   start=time.monotonic();r=subprocess.run(cmd,cwd=out,capture_output=True,text=True,timeout=1200);(out/'verilate.log').write_text(r.stdout+r.stderr)
   if r.returncode:raise RuntimeError('Compile failed\n'+(r.stdout+r.stderr)[-8500:])
   print('compiled',round(time.monotonic()-start,2),flush=True);bind.write_text(json.dumps({'sources_sha256':hashes,'compile_inputs_sha256':summary['compile_inputs_sha256'],'binary_sha256':sha(exe)},indent=2)+'\n')
  old=json.loads(bind.read_text())
  if old['sources_sha256']!=hashes or old['compile_inputs_sha256']!=summary['compile_inputs_sha256'] or old['binary_sha256']!=sha(exe):raise RuntimeError('Stale final joint binary')
  summary['binary_sha256']=sha(exe)
  cases=[(m,m,1,False)for m in (['lorom','hirom']if a.mapping=='both'else[a.mapping])]+([]if a.skip_negative else[('ram-size-zero','lorom',0,True)])
  for name,mapping,ram,negative in cases:
   cmd=[str(exe),f'+rom={out/(mapping+".hex")}',f'+helper={out/"helper.hex"}',f'+hirom={int(mapping=="hirom")}',f'+engine_ram_size={ram}',f'+output={out/name}']
   start=time.monotonic();r=subprocess.run(cmd,cwd=out,capture_output=True,text=True,timeout=1800);log=r.stdout+r.stderr;(out/(name+'.log')).write_text(log)
   signature='SRAM_RESTORE_MISMATCH'if negative else'PASS FINAL_STAGED_ARAM_ROUNDTRIP';passed=(r.returncode!=0 if negative else r.returncode==0)and signature in log
   summary['checks'].append({'case':name,'passed':passed,'negative_control':negative,'expected_signature':signature,'returncode':r.returncode,'seconds':round(time.monotonic()-start,2),'observations':[line for line in log.splitlines()if line.startswith(('CHECKPOINT','SAVE_','SRAM_','PHYSICAL_','MUTATION_','RESUME_','PIN_','ARAM_','PASS '))or'SRAM_RESTORE_MISMATCH'in line]});print(name,'PASS'if passed else'FAIL',flush=True)
   if not passed:raise RuntimeError(log[-10000:])
  for path,digest in hashes.items():
   if sha(ROOT/path)!=digest:raise RuntimeError('Source changed during execution '+path)
  summary['status']='passed'
 except Exception as exc:summary['status']='failed';summary['error']=str(exc);raise
 finally:(out/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
if __name__=='__main__':main()
