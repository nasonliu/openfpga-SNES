#!/usr/bin/env python3
"""Real core/helper/engine roundtrip with behavioral external memory boundaries.
Not a Pocket/APF/pin-level hardware qualification. No downloads or installs.
"""
from __future__ import annotations
import argparse, hashlib, json, os, pathlib, re, shutil, subprocess, time
from prepare import prepare
HERE=pathlib.Path(__file__).resolve().parent; ROOT=HERE.parents[1]
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def source_hashes():
 # Only the actual elaborated dependency graph, including each original behind
 # a simulation-normalized copy. Unrelated APF/storage work cannot stale this.
 names=[*['rtl/upstream/65C816/'+n+'.vhd' for n in ['P65816_pkg','AddrGen','BCDAdder','AddSubBCD','ALU','MCode','P65C816']],
        *['rtl/upstream/SPC700/'+n+'.vhd' for n in ['SPC700_pkg','AddrGen','AddSub','BCDAdj','ALU','MCode','MulDiv','SPC700']],
        *['rtl/upstream/'+n+'.vhd' for n in ['CPU','SWRAM','PPU_PKG','PPU','DSP_PKG','DSP','CEGen','SMP','SNES','bram','mlab']],
        *['rtl/upstream/chip/DSP/'+n+'.vhd' for n in ['DSPn','OBC1','DSP_LHRomMap']],
        'rtl/upstream/chip/SRTC.vhd','rtl/upstream/main.v','rtl/memory_ready/snes_rom_client.sv',
        'rtl/mister_top/boot1_rom.sv','rtl/mister_top/boot1.mif','rtl/upstream/releases/boot1.rom',
        *['rtl/upstream/'+n+'.sv' for n in ['savestates','savestates_map','savestates_regs','savestates_sa1']]]
 files=[ROOT/n for n in names]+[p for p in HERE.glob('*') if p.is_file() and p.suffix in ('.py','.sv')]
 return {str(p.relative_to(ROOT)):sha(p) for p in sorted(files)}
def read_helper_mif(path):
 text=path.read_text()
 for key,value in [('WIDTH','16'),('DEPTH','2048'),('ADDRESS_RADIX','HEX'),('DATA_RADIX','HEX')]:
  if not re.search(r'\b'+key+r'\s*=\s*'+value+r'\s*;',text,re.I):raise ValueError('Unexpected helper MIF '+key)
 pairs=re.findall(r'^\s*([0-9a-fA-F]+)\s*:\s*([0-9a-fA-F]+)\s*;',text,re.M)
 words={int(a,16):int(v,16)for a,v in pairs}
 if len(pairs)!=2048 or set(words)!=set(range(2048)) or any(v>65535 for v in words.values()):raise ValueError('Helper MIF must enumerate exactly2048 words')
 return b''.join(words[i].to_bytes(2,'little')for i in range(2048))
def command(out,name,args,timeout=600):
 start=time.monotonic();r=subprocess.run(list(map(str,args)),cwd=out,capture_output=True,text=True,timeout=timeout)
 (out/(name+'.log')).write_text(r.stdout+r.stderr)
 print(name,r.returncode,round(time.monotonic()-start,2),flush=True)
 if r.returncode:raise RuntimeError(name+'\n'+(r.stdout+r.stderr)[-9000:])
 return r.stdout

def bind_names(verilog,entity,ports,parameters):
 # VHDL is case-insensitive; named Verilog instance ports are case-sensitive.
 start=verilog.index('module '+entity+'\n');chunk=verilog[start:]
 header=chunk[:chunk.index(');')]
 names=re.findall(r'(?:input|output)\s+(?:\[[^]]+\]\s*)?(\w+)',header)
 for name in names:
  match=next((p for p in ports if p.lower()==name.lower()),name)
  if match!=name:chunk=re.sub(r'\b'+re.escape(name)+r'\b',match,chunk)
 chunk=chunk.replace('module '+entity+'\n','module '+entity+' #('+parameters+')\n',1)
 return verilog[:start]+chunk

def build(out):
 original_hashes=source_hashes()
 ss,mp=prepare(out)
 main=(ROOT/'rtl/upstream/main.v').read_text()
 for ent,sources,generics,params in [('SNES',ss,['-gWRAM_PREDECODE=true','-gARAM_RETURN_STAGE=true'],'parameter WRAM_PREDECODE="TRUE", ARAM_RETURN_STAGE="TRUE"'),('DSP_LHRomMap',mp,["-gUSE_DSPn='0'"],'parameter USE_DSPn=0')]:
  text=command(out,'synth-'+ent,['ghdl','--synth','--std=08','-fsynopsys','--latches','--out=verilog',*generics,*sources,'-e',ent])
  inst=re.search(r'\b'+ent+r'\s*#\(.*?\)\s*'+ent+r'\s*\((.*?)\n\);',main,re.S)
  if not inst:raise RuntimeError('Cannot locate production instance '+ent)
  ports=re.findall(r'\.(\w+)\s*\(',inst[1]);text=bind_names(text,ent,ports,params)
  if ent=='DSP_LHRomMap':
   for n in re.findall(r'^module (\w+)',text,re.M):
    if n!=ent:text=re.sub(r'\b'+n+r'\b','mapper_'+n,text)
  (out/(ent+'.v')).write_text(text)
 sv=[out/'SNES.v',out/'DSP_LHRomMap.v',ROOT/'rtl/upstream/main.v',ROOT/'rtl/memory_ready/snes_rom_client.sv',ROOT/'rtl/mister_top/boot1_rom.sv',*[ROOT/'rtl/upstream'/(n+'.sv') for n in ['savestates','savestates_map','savestates_regs','savestates_sa1']],HERE/'sim_spram.sv',HERE/'tb_roundtrip.sv']
 snapshot=out/'source_snapshot';snapshot.mkdir(exist_ok=True)
 snapshot_sources=[]
 for source in sv:
  target=snapshot/source.name;target.write_bytes(source.read_bytes());snapshot_sources.append(target)
 command(out,'verilate' ,['verilator','+1364-2005ext+v','--binary','--timing','--assert','-Wno-fatal','--top-module','tb_roundtrip','--Mdir',out/'obj','-j','2','-O1',*snapshot_sources],timeout=1200)
 if source_hashes()!=original_hashes:raise RuntimeError('Source changed during compilation')
 manifest={'sources_sha256':original_hashes,'compile_inputs_sha256':{str(p.relative_to(out)):sha(p) for p in snapshot_sources},'simulation_normalizations_sha256':{str(p.relative_to(out)):sha(p) for p in ss+mp if p.is_relative_to(out)},'binary_sha256':sha(out/'obj/Vtb_roundtrip'),'tools':{name:subprocess.check_output([name,'--version'],text=True).splitlines()[0] for name in ['ghdl','verilator']}}
 (out/'build-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
 return manifest

def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--out',type=pathlib.Path,default=HERE/'build');p.add_argument('--build-only',action='store_true');p.add_argument('--skip-build',action='store_true');p.add_argument('--case',default='all',choices=['all','lorom','hirom','missing-helper','stale-word','failed-restore']);a=p.parse_args();out=a.out.resolve();out.mkdir(parents=True,exist_ok=True)
 for tool in ['ghdl','verilator']:
  if not shutil.which(tool):raise SystemExit('NOT RUN: '+tool+' unavailable; source approved tool environment')
 subprocess.run(['python3',str(ROOT/'tools/generate_savestate_rom.py')],check=True,cwd=ROOT)
 hashes=source_hashes()
 summary={'status':'in_progress','hardware_verified':False,'apf_transport_verified':False,'full_console_verified':False,'core_rtl_roundtrip_verified':False,'scope':'production SNES CPU/PPU/SMP/SPC700/DSP/SWRAM, production mapper/main/savestate engine/helper; modeled external RAM and cartridge transaction responder; vendor primitive behavioral RAM','sources_sha256':hashes,'checks':[]}
 try:
  from fixture import build_fixture
  for mapping in ['lorom','hirom']:
   rom,spec=build_fixture(mapping, with_spc=True)
   (out/(mapping+'.hex')).write_text(''.join(f'{x:02x}\n' for x in rom));(out/(mapping+'.json')).write_text(json.dumps(spec,indent=2)+'\n')
  helper=read_helper_mif(ROOT/'rtl/mister_top/boot1.mif')
  if helper!=(ROOT/'rtl/upstream/releases/boot1.rom').read_bytes().ljust(4096,b'\0'):raise ValueError('Production boot1.mif does not match padded pinned helper ROM')
  if len(helper)!=4096:raise ValueError('helper exceeds 4 KiB')
  (out/'helper.hex').write_text(''.join(f'{int.from_bytes(helper[i:i+2],"little"):04x}\n'for i in range(0,4096,2)))
  if not a.skip_build:build_manifest=build(out)
  else:
   build_manifest=json.loads((out/'build-manifest.json').read_text())
   if build_manifest['sources_sha256']!=hashes:raise RuntimeError('Stale build: sources differ from build manifest; rerun without --skip-build')
   if build_manifest['binary_sha256']!=sha(out/'obj/Vtb_roundtrip'):raise RuntimeError('Stale or altered compiled binary')
   for name,digest in build_manifest['compile_inputs_sha256'].items():
    if sha(out/name)!=digest:raise RuntimeError('Altered compiled-source snapshot: '+name)
  summary['build']=build_manifest
  summary['rom_fixtures']={mapping:json.loads((out/(mapping+'.json')).read_text()) for mapping in ['lorom','hirom']}
  summary['helper_rom_sha256']=sha(ROOT/'rtl/upstream/releases/boot1.rom')
  if a.build_only:summary['status']='built_not_run';return
  cases=['lorom','hirom','missing-helper','stale-word','failed-restore'] if a.case=='all' else [a.case]
  for case in cases:
   mapping='hirom'if case=='hirom'else'lorom';args=[out/'obj/Vtb_roundtrip',f'+rom={out/(mapping+".hex")}',f'+helper={out/"helper.hex"}',f'+hirom={int(mapping=="hirom")}',f'+output={out/case}']
   negative=case not in ['lorom','hirom'];markers={'missing-helper':'INVALID_REAL_STATE_SAVE','stale-word':'RESTORE_RAM_MISMATCH','failed-restore':'RESTORE_EXECUTION_TIMEOUT'}
   if negative:args += ['+'+case.replace('-','_')+'=1']
   t=time.monotonic();r=subprocess.run(list(map(str,args)),cwd=out,capture_output=True,text=True,timeout=1200);log=r.stdout+r.stderr;(out/(case+'.log')).write_text(log)
   expected=markers[case]if negative else'PASS REAL_SNES_SAVESTATE_ROUNDTRIP';ok=(r.returncode!=0 if negative else r.returncode==0)and expected in log
   state=out/(case+'-state.hex')
   summary['checks'].append({'case':case,'passed':ok,'negative_control':negative,'returncode':r.returncode,'expected_signature':expected,'seconds':round(time.monotonic()-t,2),'log':case+'.log','state_dump_sha256':sha(state) if state.exists() else None,'observations':[line for line in log.splitlines() if line.startswith(('CHECKPOINT','SAVE_COMPLETE','MUTATION_COMPLETE','RESUME_B_CONFIRMED','PASS REAL_','INJECT_','WRAM_BAD','ARAM_BAD','VRAM'))]})
   print(case,'PASS'if ok else'FAIL',flush=True)
   if not ok:raise RuntimeError(log[-8000:])
  changed=[name for name,h in hashes.items()if sha(ROOT/name)!=h]
  if changed:raise RuntimeError('Source changed during run: '+','.join(changed))
  summary['status']='passed';summary['core_rtl_roundtrip_verified']=not a.build_only and all(any(c['case']==name and c['passed']for c in summary['checks'])for name in ['lorom','hirom'])
 except Exception as e:summary['status']='failed';summary['error']=str(e);raise
 finally:(out/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
if __name__=='__main__':main()
