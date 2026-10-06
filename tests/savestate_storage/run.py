#!/usr/bin/env python3
"""Protocol regressions; external PSRAM model is not hardware timing signoff."""
from pathlib import Path
import subprocess, sys
R=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(R/'tests'))
from tool_environment import tool_environment
O=R/'build/savestate-storage';O.mkdir(parents=True,exist_ok=True)
files=[R/'tests/savestate_storage/tb_savestate_storage.sv', R/'rtl/mister_top/savestate.sv',R/'rtl/mister_top/psram_blob.sv',R/'target/pocket/psram.sv']
env=tool_environment()
for name,sy,me,phase in [('ntsc',23.28,5.82,0),('offset',23.28,5.82,2.7),('pal',23.5,5.875,1.8)]:
 out=O/name
 cmd=['iverilog','-g2012','-s','tb_savestate_storage',f'-Ptb_savestate_storage.SYS_HALF={sy}',f'-Ptb_savestate_storage.MEM_HALF={me}',f'-Ptb_savestate_storage.MEM_PHASE={phase}','-o',str(out),*map(str,files)]
 subprocess.run(cmd,env=env,check=True,cwd=R)
 r=subprocess.run(['vvp',str(out)],env=env,capture_output=True,text=True,timeout=30)
 (O/(name+'.log')).write_text(r.stdout+r.stderr)
 if r.returncode or 'PASS storage:' not in r.stdout: raise RuntimeError(name+': '+r.stdout+r.stderr)
 print(name+': '+next(x for x in r.stdout.splitlines() if x.startswith('PASS storage:')))
