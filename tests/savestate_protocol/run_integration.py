#!/usr/bin/env python3
"""Exercise production APF-to-PSRAM RTL across clock phases and endianness.

The only functional substitutes are engine transactions and off-chip PSRAM.
Requires Intel's actual altera_mf.v simulation library for dcfifo.
"""
from pathlib import Path
import argparse, hashlib, json, subprocess, sys, time
R=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(R/'tests'))
from tool_environment import tool_environment
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--vendor-sim-dir',type=Path,required=True,help='Your licensed Quartus eda/sim_lib directory; models are not distributed here')
p.add_argument('--output',type=Path,default=R/'build/savestate-protocol-integration')
p.add_argument('--skip-mutations',action='store_true')
p.add_argument('--full-only',action='store_true',help='Run a full 0x64000-byte payload at production host pacing')
a=p.parse_args();vendor=a.vendor_sim_dir/'altera_mf.v'
if not vendor.is_file():p.error('Intel altera_mf.v is required; provide --vendor-sim-dir')
o=a.output.resolve();o.mkdir(parents=True,exist_ok=True)
files=[R/x for x in ('tests/savestate_protocol/tb_apf_storage_roundtrip.sv',
    'target/pocket/savestate_controller.sv','target/pocket/data_loader.sv',
    'target/pocket/data_unloader.sv','rtl/mister_top/savestate.sv',
    'rtl/mister_top/psram_blob.sv','target/pocket/psram.sv')]
env=tool_environment();checks=[]
def hashes():return {str(f.relative_to(R)):hashlib.sha256(f.read_bytes()).hexdigest() for f in files}
before=hashes()
def run(name,cmd,expected=None,reject=False):
    started=time.monotonic()
    if a.full_only:
        with (o/(name+'.log')).open('w') as log:
            r=subprocess.run(list(map(str,cmd)),cwd=R,env=env,stdout=log,stderr=subprocess.STDOUT,text=True,timeout=2400)
        output=(o/(name+'.log')).read_text()
    else:
        r=subprocess.run(list(map(str,cmd)),cwd=R,env=env,capture_output=True,text=True,timeout=90)
        output=r.stdout+r.stderr;(o/(name+'.log')).write_text(output)
    passed=(r.returncode!=0 if reject else r.returncode==0) and (expected is None or expected in output)
    checks.append(dict(name=name,passed=passed,returncode=r.returncode,seconds=round(time.monotonic()-started,3),command=list(map(str,cmd))))
    if not passed:raise RuntimeError(name+' failed:\n'+output[-5000:])
    if expected and not reject: print(next(line for line in output.splitlines() if expected in line))

def compile_case(name,pal,little,phase,controller=None,payload=64):
    sy=500/(21.281370 if pal else 21.477270);me=sy/4
    top='tb_apf_storage_roundtrip';exe=o/(name+'.vvp')
    src=[controller if f.name=='savestate_controller.sv' and controller else f for f in files]
    run(name+'-compile',['iverilog','-g2012','-s',top,f'-P{top}.SYS_HALF={sy}',f'-P{top}.MEM_HALF={me}',
        f'-P{top}.MEM_PHASE={phase}',f'-P{top}.LITTLE={little}',f'-P{top}.PAYLOAD_BYTES={payload}',f'-P{top}.CORRUPT_CASE={0 if a.full_only else 1}','-o',exe,*src,vendor])
    return exe
completed=False
try:
    if a.full_only:
        exe=compile_case('full-0x64000',0,1,1.7,payload=0x64000)
        run('full-0x64000',['vvp',exe],'PASS APF_STORAGE_ROUNDTRIP')
    for pal in (() if a.full_only else (0,1)):
        for little in (0,1):
            for phase in (0,1.7,5.2,9.8):
                name=f'pal{pal}-little{little}-phase{phase}'
                exe=compile_case(name,pal,little,phase)
                run(name,['vvp',exe],'PASS APF_STORAGE_ROUNDTRIP')
    if not a.skip_mutations and not a.full_only:
        source=files[1].read_text()
        mutations={
            'missing-committed-count':('drained74[2] && complete74[2]','drained74[2]'),
            'missing-payload-checksum':('incoming_checksum != declared_checksum','1\'b0'),
        }
        for name,(old,new) in mutations.items():
            if source.count(old)!=1:raise RuntimeError('mutation target not unique: '+name)
            f=o/(name+'.sv');f.write_text(source.replace(old,new))
            exe=compile_case(name,0,1,0,f)
            # In either mutation, an invalid/unfinished upload reaches the
            # mock engine, or fails with a later timeout rather than validation.
            expected='Live restore preceded committed APF stage' if name=='missing-committed-count' else 'Corrupt blob reached live engine'
            run(name,['vvp',exe],expected,reject=True)
    completed=True
finally:
    stable=before==hashes()
    result=dict(passed=completed and stable and all(x['passed'] for x in checks),source_stable=stable,
        source_sha256=before,vendor_sha256=hashlib.sha256(vendor.read_bytes()).hexdigest(),checks=checks,
        limits=['SNES engine mocked; not a full-console round trip','Off-chip PSRAM functional pin model, not board timing signoff',
                'APF strobes/deadline oracle, not full io_bridge_peripheral serial front end','No metastability/physical CDC or place-and-route proof'])
    (o/'summary.json').write_text(json.dumps(result,indent=2)+'\n')
if not result['passed']:raise SystemExit(1)
print(f'PASS APF storage integration: {len(checks)} compile/simulation checks')
