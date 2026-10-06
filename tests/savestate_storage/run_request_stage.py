#!/usr/bin/env python3
"""Verify the complete ARAM falling-edge packet and two broken alternatives."""
import hashlib,json,subprocess,sys
from pathlib import Path
R=Path(__file__).resolve().parents[2];sys.path.insert(0,str(R/'tests'))
from tool_environment import tool_environment
O=R/'build/aram-request-stage';O.mkdir(parents=True,exist_ok=True);env=tool_environment()
files=[R/'tests/savestate_storage/tb_aram_request_stage.sv',R/'target/pocket/aram_request_stage.sv',R/'target/pocket/sram.sv',R/'target/pocket/sram_ctrl.sv']
hashes={str(f.relative_to(R)):hashlib.sha256(f.read_bytes()).hexdigest() for f in [*files,Path(__file__)]}
records=[]
for pal,sy in [(0,23.28),(1,23.5)]:
 for phase in range(4):
  for mutation in ([0,1,2] if not pal and phase==0 else [0]):
   name=f'pal{pal}-phase{phase}-mutation{mutation}';exe=O/name
   subprocess.run(['iverilog','-g2012','-s','tb_aram_request_stage',f'-Ptb_aram_request_stage.SYS_HALF={sy}',f'-Ptb_aram_request_stage.MEM_HALF={sy/4}',f'-Ptb_aram_request_stage.MEM_PHASE={phase*sy/8}',f'-Ptb_aram_request_stage.MUTATION={mutation}','-o',str(exe),*map(str,files)],env=env,check=True)
   r=subprocess.run(['vvp',str(exe)],env=env,capture_output=True,text=True,timeout=30)
   (O/(name+'.log')).write_text(r.stdout+r.stderr)
   if mutation:assert r.returncode and 'REQUEST_PACKET_MISMATCH' in r.stdout,r.stdout+r.stderr
   else:assert not r.returncode and 'PASS ARAM_REQUEST_STAGE' in r.stdout,r.stdout+r.stderr
   records.append({'name':name,'negative_control':bool(mutation),'output':r.stdout})
   print(name+': '+('PASS expected negative control' if mutation else r.stdout.strip()),flush=True)
assert hashes=={str(f.relative_to(R)):hashlib.sha256(f.read_bytes()).hexdigest() for f in [*files,Path(__file__)]}
(O/'summary.json').write_text(json.dumps({'checks':records,'sources_sha256':hashes},indent=2)+'\n')
