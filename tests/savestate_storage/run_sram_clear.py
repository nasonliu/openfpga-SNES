#!/usr/bin/env python3
"""Exercise production RAM-clear frontier and SRAM pins with assumed55ns array."""
from pathlib import Path
import argparse,hashlib,json,subprocess,sys
R=Path(__file__).resolve().parents[2];sys.path.insert(0,str(R/'tests'))
from tool_environment import tool_environment
p=argparse.ArgumentParser();p.add_argument('--request-stage',action='store_true');p.add_argument('--sram-source',type=Path,default=R/'target/pocket/sram.sv');p.add_argument('--sram-ctrl-source',type=Path,default=R/'target/pocket/sram_ctrl.sv');p.add_argument('--out',type=Path);a=p.parse_args();a.sram_source=a.sram_source.resolve();a.sram_ctrl_source=a.sram_ctrl_source.resolve()
O=(a.out or R/('build/savestate-storage-request' if a.request_stage else 'build/savestate-storage')).resolve();O.mkdir(parents=True,exist_ok=True);env=tool_environment()
files=[R/'tests/savestate_storage/tb_sram_clear.sv',a.sram_source,a.sram_ctrl_source,R/'target/pocket/ram_clear_frontier.sv',R/'target/pocket/aram_request_stage.sv']
sources=[*files,Path(__file__)];hashes={str(f.relative_to(R)):hashlib.sha256(f.read_bytes()).hexdigest() for f in sources};records=[]
for name,sy,me,phase in [('ntsc',23.28,5.82,0),('offset',23.28,5.82,2.7),('pal',23.5,5.875,1.8)]:
 out=O/('clear-'+name)
 subprocess.run(['iverilog','-g2012','-s','tb_sram_clear',f'-Ptb_sram_clear.REQUEST_STAGE={int(a.request_stage)}',f'-Ptb_sram_clear.SYS_HALF={sy}',f'-Ptb_sram_clear.MEM_HALF={me}',f'-Ptb_sram_clear.MEM_PHASE={phase}','-o',str(out),*map(str,files)],env=env,check=True)
 r=subprocess.run(['vvp',str(out)],env=env,capture_output=True,text=True,timeout=90)
 (O/('clear-'+name+'.log')).write_text(r.stdout+r.stderr)
 if r.returncode or 'PASS SRAM_CLEAR' not in r.stdout:raise RuntimeError(name+': '+r.stdout+r.stderr)
 records.append({'name':name,'output':r.stdout})
 print(name+': '+next(x for x in r.stdout.splitlines() if x.startswith('PASS SRAM_CLEAR')),flush=True)
# Removing the physical access-termination fix must fail the pin monitor.
s=a.sram_source.read_text();start=s.index('            // End every access before');end=s.index('            if (~use_write)',start)
mutant=O/'sram-no-turnaround-mutant.sv';mutant.write_text(s[:start]+s[end:]);exe=O/'clear-mutant'
subprocess.run(['iverilog','-g2012','-s','tb_sram_clear',f'-Ptb_sram_clear.REQUEST_STAGE={int(a.request_stage)}','-o',str(exe),*map(str,[files[0],mutant,*files[2:]])],env=env,check=True)
r=subprocess.run(['vvp',str(exe)],env=env,capture_output=True,text=True,timeout=90)
(O/'clear-mutant.log').write_text(r.stdout+r.stderr)
assert r.returncode and any(marker in r.stdout for marker in ['WE turnaround shorter than one memory clock','WRITE_DQ_INVALID_WHILE_WE_LOW']),r.stdout+r.stderr
print('PASS negative control: missing physical WE turnaround is detected')
records.append({'name':'missing_we_turnaround','negative_control':True,'output':r.stdout})
assert hashes=={str(f.relative_to(R)):hashlib.sha256(f.read_bytes()).hexdigest() for f in sources},'Sources changed during execution'
(O/'clear-summary.json').write_text(json.dumps({'request_stage':a.request_stage,'checks':records,'sources_sha256':hashes},indent=2)+'\n')
