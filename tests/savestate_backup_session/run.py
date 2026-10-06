#!/usr/bin/env python3
"""Read-only production admission review; GATE_SESSION=1 matches production;0 is the old-admission mutation."""
import argparse,hashlib,json,pathlib,subprocess,sys,tempfile,time
ROOT=pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tests'))
from tool_environment import tool_environment
p=argparse.ArgumentParser();p.add_argument('--vendor-sim-dir',type=pathlib.Path,required=True);p.add_argument('--output',type=pathlib.Path,default=ROOT/'build/savestate-backup-session');a=p.parse_args()
out=a.output.resolve();out.mkdir(parents=True,exist_ok=True)
files=[pathlib.Path(__file__).with_name('tb_backup_session.sv'),ROOT/'target/pocket/savestate_controller.sv',ROOT/'rtl/memory_ready/rom_download_queue.sv',ROOT/'target/pocket/host_reset_guard.sv',ROOT/'target/pocket/core_bridge_cmd.v',ROOT/'platform/pocket/common.v',ROOT/'platform/pocket/mf_datatable.v']
bound=files+[ROOT/'target/pocket/core_top.sv',ROOT/'rtl/mister_top/SNES.sv',pathlib.Path(__file__)]
hashes={str(f.relative_to(ROOT)):hashlib.sha256(f.read_bytes()).hexdigest()for f in bound}
# Source-checked simplified mounted-cartridge boundary: only the backup/state
# lifecycle is active. All unrelated clients, faults, ROM loading and memory
# busy signals are idle. Real APF command parser and FIFO remain unmodified.
top=(ROOT/'target/pocket/core_top.sv').read_text();main=(ROOT/'rtl/mister_top/SNES.sv').read_text()
assert '.ss_admit(ss_avail && !ss_core_reset && !queue_save_busy && !save_download_s && ss_identity_ready_s)'in top
assert '.ss_allow(ss_avail && !ss_core_reset && ss_identity_ready_s)'in top
assert 'if (dataslot_requestread || dataslot_requestwrite) save_download <= 1;'in top
assert 'else if (dataslot_allcomplete && ~dataslot_allcomplete_prev) save_download <= 0;'in top
assert '(USE_STANDARD_SDRAM && save_busy && !(USE_SS && ss_lock))'in main
assert 'if (div == 2) RESET_N <= ~reset;'in main
vendor=a.vendor_sim_dir.resolve()/'altera_mf.v';env=tool_environment();records=[]
# Four actual-code witnesses (A0/A4 x backup read/upload), eight gated cases
# including missing008F across core reset, and two owner-first queued backups.
cases=[(0,l,w,0)for l in (0,1)for w in (0,1)]+[(1,l,w,s)for l in (0,1)for w in (0,1)for s in (0,1)]+[(1,l,0,2)for l in (0,1)]
with tempfile.TemporaryDirectory(prefix='pocket-backup-session-')as tmp:
 tmp=pathlib.Path(tmp)
 (tmp/'build_id.mif').write_text('WIDTH=32;\nDEPTH=256;\nADDRESS_RADIX=HEX;\nDATA_RADIX=HEX;\nCONTENT BEGIN\n[00..FF] : 00000000;\nEND;\n')
 (tmp/'build_id.ver').write_text('@0\n'+'00000000\n'*256)
 for gate,load,write,scenario in cases:
  name=f'gate{gate}-load{load}-write{write}-scenario{scenario}';exe=tmp/(name+'.vvp')
  cmd=['iverilog','-g2012','-s','tb_backup_session',f'-Ptb_backup_session.GATE_SESSION={gate}',f'-Ptb_backup_session.LOAD={load}',f'-Ptb_backup_session.WRITE_SESSION={write}',f'-Ptb_backup_session.SCENARIO={scenario}','-o',str(exe),*map(str,files),str(vendor)]
  r=subprocess.run(cmd,cwd=tmp,env=env,capture_output=True,text=True,timeout=30)
  (out/(name+'-compile.log')).write_text(r.stdout+r.stderr)
  if r.returncode:raise SystemExit('Compile failed: '+name)
  before=time.time();r=subprocess.run(['vvp',str(exe)],cwd=tmp,env=env,capture_output=True,text=True,timeout=30)
  output=r.stdout+r.stderr;(out/(name+'.log')).write_text(output)
  passed=r.returncode==0 and ('PASS STATE_FIRST'if scenario==2 else 'PASS POST008F_RECOVERY')in output and 'ERROR:'not in output
  records.append(dict(name=name,passed=passed,returncode=r.returncode,seconds=round(time.time()-before,3),observations=output.splitlines()))
  print(name, 'PASS'if passed else 'FAIL',flush=True)
  if not passed:print(output);break
stable=hashes=={str(f.relative_to(ROOT)):hashlib.sha256(f.read_bytes()).hexdigest()for f in bound}
summary=dict(passed=len(records)==len(cases)and all(c['passed']for c in records),source_stable=stable,sources_sha256=hashes,vendor_sha256=hashlib.sha256(vendor.read_bytes()).hexdigest(),checks=records,scope='Production core_bridge_cmd, queue, controller, host_reset_guard and Intel FIFO; mounted-cartridge reduced wrapper, synthetic engine and stage-commit levels. GATE_SESSION=1 matches the production session gate;0 is the old-admission mutation. No production source altered by this runner.',limits=['No actual BSRAM or helper execution in this admission bench','Does not prove shipping firmware interleaves open backup sessions with A0/A4','Missing008F remains conservatively blocked across core reset with production gate; tested008F recovery'])
(out/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
if not summary['passed']or not stable:raise SystemExit(1)
