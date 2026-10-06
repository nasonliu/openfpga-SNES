#!/usr/bin/env python3
"""Full-size two-state integration, complementary to four-state Icarus cases.

Uses the SAME production RTL and Intel dcfifo source; no FIFO substitution.
Verilator's two-state semantics do not replace the four-state phase sweeps.
"""
from pathlib import Path
import argparse, hashlib, json, subprocess, sys, time
R=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(R/'tests'))
from tool_environment import tool_environment
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--vendor-sim-dir',type=Path,required=True,help='Your licensed Quartus eda/sim_lib directory; models are not distributed here')
p.add_argument('--output',type=Path,default=R/'build/savestate-protocol-verilator-full')
a=p.parse_args();vendor=a.vendor_sim_dir/'altera_mf.v'
if not vendor.is_file():p.error('Intel altera_mf.v required')
o=a.output.resolve();o.mkdir(parents=True,exist_ok=True)
files=[R/x for x in ('tests/savestate_protocol/tb_apf_storage_roundtrip.sv','target/pocket/savestate_controller.sv',
    'target/pocket/data_loader.sv','target/pocket/data_unloader.sv','rtl/mister_top/savestate.sv',
    'rtl/mister_top/psram_blob.sv','target/pocket/psram.sv')]
def hashes():return {str(f.relative_to(R)):hashlib.sha256(f.read_bytes()).hexdigest() for f in files}
before=hashes();checks=[];completed=False;env=tool_environment()
def run(name,cmd,expected=None):
    started=time.monotonic()
    with (o/(name+'.log')).open('w') as log:
        r=subprocess.run(list(map(str,cmd)),cwd=R,env=env,stdout=log,stderr=subprocess.STDOUT,text=True,timeout=600)
    output=(o/(name+'.log')).read_text()
    passed=r.returncode==0 and (expected is None or expected in output)
    checks.append(dict(name=name,passed=passed,returncode=r.returncode,seconds=round(time.monotonic()-started,3),command=list(map(str,cmd))))
    if not passed:raise RuntimeError(name+' failed:\n'+output[-5000:])
    if expected:print(next(x for x in output.splitlines() if expected in x))
try:
    for name,payload,corrupt in [('short-96bytes',64,1),('full-409632bytes',0x64000,0)]:
        obj=o/(name+'-obj');top='tb_apf_storage_roundtrip'
        run(name+'-build',['verilator','--binary','--timing','-Wno-fatal','-j','1','--Mdir',obj,
            '--top-module',top,f'-GPAYLOAD_BYTES={payload}',f'-GCORRUPT_CASE={corrupt}',
            '-GMEM_PHASE=1.7',*files,vendor])
        run(name,[obj/('V'+top)],'PASS APF_STORAGE_ROUNDTRIP')
    completed=True
finally:
    stable=before==hashes()
    result=dict(passed=completed and stable and all(x['passed'] for x in checks),source_stable=stable,
        simulation_semantics='Verilator two-state; complements four-state Icarus short phase/endian matrix',
        source_sha256=before,vendor_sha256=hashlib.sha256(vendor.read_bytes()).hexdigest(),checks=checks,
        limits=['SNES engine transactions mocked; not a whole-console round trip','Real vendor FIFO source with two-state compiled simulation semantics',
            'Functional off-chip PSRAM pin model, not physical timing','APF direct strobe and early capture deadline, not serial frontend'])
    (o/'summary.json').write_text(json.dumps(result,indent=2)+'\n')
if not result['passed']:raise SystemExit(1)
print('PASS: short and full-size Verilator integration (two-state)')
