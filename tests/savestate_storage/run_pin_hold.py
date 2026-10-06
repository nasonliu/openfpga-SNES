#!/usr/bin/env python3
"""Verify active SRAM pin recovery and exact historical negative controls.

The generated candidate lives only under build/. Production RTL is untouched.
This is a bounded timing-design model, not board or post-fit qualification.
"""
import hashlib,json,subprocess,sys
from pathlib import Path
R=Path(__file__).resolve().parents[2];sys.path.insert(0,str(R/'tests'))
from tool_environment import tool_environment
from pinned_source import reconstruct
O=R/'build/sram-pin-hold';O.mkdir(parents=True,exist_ok=True);env=tool_environment()
fixture=R/'tests/savestate_storage/fixtures/sram-before-pin-recovery.json'
source=O/'sram-before-pin-recovery.sv';source.write_bytes(reconstruct(R,json.loads(fixture.read_text())))
active=R/'target/pocket/sram.sv';tb=R/'tests/savestate_storage/tb_sram_pin_hold.sv'
original=source.read_text();candidate=original
candidate=candidate.replace('  reg state = 0;', '  localparam HOLD_STATE = 2;\n  localparam RECOVER_STATE = 3;\n  reg [1:0] state = 0;')
needle='            state <= INIT_STATE;\n            // End every access before'
assert candidate.count(needle)==1
candidate=candidate.replace(needle,'            state <= HOLD_STATE;\n            // End every access before')
needle="            use_write <= 1'b0;\n\n            if (~use_write)"
assert candidate.count(needle)==1
candidate=candidate.replace(needle,'            // Hold the last write byte through the complete next clock.\n\n            if (~use_write)')
needle='      endcase';assert candidate.count(needle)==1
candidate=candidate.replace(needle,"""        HOLD_STATE: begin
          use_write <= 1'b0;
          state <= RECOVER_STATE;
        end
        RECOVER_STATE: begin
          state <= INIT_STATE;
        end
      endcase""")
candidate_path=O/'sram-common-recovery-candidate.sv'
if candidate_path.exists():assert candidate_path.read_text()==candidate,'Candidate changed during other validation'
candidate_path.write_text(candidate)
needle="""          end else if (rd) begin
            state <= WAIT_STATE;
            wait_counter <= CYCLES_PER_OP;"""
assert candidate.count(needle)==1
read7=candidate.replace(needle,"""          end else if (rd) begin
            state <= WAIT_STATE;
            // One extra read clock covers routed byte-enable and DQ setup.
            wait_counter <= CYCLES_PER_OP + 1;""")
read7_path=O/'sram-common-read7-candidate.sv'
if read7_path.exists():assert read7_path.read_text()==read7,'Read7 candidate changed during other validation'
read7_path.write_text(read7)
setup=read7.replace('  reg [1:0] state = 0;', '  localparam WRITE_SETUP_STATE = 4;\n  reg [1:0] pending_mask = 0;\n  reg [2:0] state = 0;')
setup=setup.replace('      wait_counter <= 0;', '      wait_counter <= 0;\n      pending_mask <= 0;')
setup=setup.replace('          if (wr) begin\n            state <= WAIT_STATE;', '          if (wr) begin\n            state <= WRITE_SETUP_STATE;')
needle="""            sram_oe_n <= 1'b1;
            sram_we_n <= 1'b0;
            {sram_ub_n, sram_lb_n} <= ~mask;""";assert setup.count(needle)==1
setup=setup.replace(needle,"""            // Establish address/data while every write-opening control is high.
            sram_oe_n <= 1'b1;
            pending_mask <= mask;""")
setup=setup.replace('        HOLD_STATE: begin',"""        WRITE_SETUP_STATE: begin
          sram_we_n <= 1'b0;
          {sram_ub_n, sram_lb_n} <= ~pending_mask;
          wait_counter <= CYCLES_PER_OP;
          state <= WAIT_STATE;
        end
        HOLD_STATE: begin""")
setup_path=O/'sram-read7-write-setup-candidate.sv'
if setup_path.exists():assert setup_path.read_text()==setup,'Write-setup candidate changed during other validation'
setup_path.write_text(setup)
wrapper=R/'target/pocket/sram_ctrl.sv'
hashes={str(p.relative_to(R)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [source,active,wrapper,tb,Path(__file__)]};records=[]
cases=[]
for mode in [0,1]:cases.append(('before_recovery',source,mode,0,5.82,'DQ_RELEASE_BEFORE_WRITE_END' if mode==0 else 'SRAM_BUS_CONTENTION'))
for name,sv,modes in [('common_read6',candidate_path,[0,1]),('common_read7',read7_path,[0,1,2]),('read7_write_setup',setup_path,[0,1,2,3])]:
 for mode in modes:
  for pal,half in [(0,5.82),(1,5.875)]:cases.append((name,sv,mode,pal,half,None))
if active.read_text()!=original:
 for mode in [0,1,2,3]:
  for pal,half in [(0,5.82),(1,5.875)]:cases.append(('active',active,mode,pal,half,None))
cases.append(('common_read6',candidate_path,2,0,5.82,'READBACK_MISMATCH'))
cases.append(('common_read7',read7_path,3,0,5.82,'WRITE_ADDRESS_SETUP_VIOLATION'))
# Exact newer53 slow85 common-root terms. PCB flight is explicitly assumed.
# 6T - (12.001 + 55 + 6.620 - 3.514) - .120 = -.387 ns.
# Adding .250ns assumed PCB flight yields -.637ns (6T), +11.003ns (7T).
read_model={'address_root_to_pad_max_ns':12.001,'tAA_ns':55.0,'DQ0_pin_to_capture_reference_ns':6.620,'capture_reference_min_ns':3.514,'uncertainty_ns':0.120,'assumed_PCB_flight_ns':0.250,'six_cycle_zero_PCB_margin_ns':-0.387,'six_cycle_assumed_PCB_margin_ns':-0.637,'seven_cycle_assumed_PCB_margin_ns':11.003,'fitted_snapshot':'53a7b51, slow85, zero pF load assumption'}
write_model={'address_root_to_pad_max_ns':12.001,'WE_launch_reference_min_ns':3.516,'WE_reference_to_pad_min_ns':6.724,'UB_launch_reference_min_ns':3.521,'UB_reference_to_pad_min_ns':6.547,'earliest_upper_write_open_ns':10.240,'unprepared_address_setup_margin_ns':-1.761,'setup_clock_improvement_ns':11.640,'fitted_snapshot':'53a7b51, slow85, before extra uncertainty'}
for name,sv,mode,pal,half,expected in cases:
 label=f'{name}-mode{mode}-pal{pal}';exe=O/label
 params=[f'-Ptb_sram_pin_hold.MODE={mode}',f'-Ptb_sram_pin_hold.MEM_HALF={half}']
 if mode==2:params+=['-Ptb_sram_pin_hold.ADDRESS_PAD=8.487','-Ptb_sram_pin_hold.READ_RETURN_BUDGET=6.990']
 if mode==3:params+=['-Ptb_sram_pin_hold.ADDRESS_PAD=12.001','-Ptb_sram_pin_hold.WE_PAD=10.240','-Ptb_sram_pin_hold.BE_PAD=10.068']
 subprocess.run(['iverilog','-g2012','-s','tb_sram_pin_hold',*params,'-o',str(exe),str(tb),str(sv)],env=env,check=True)
 r=subprocess.run(['vvp',str(exe)],env=env,capture_output=True,text=True,timeout=30);(O/(label+'.log')).write_text(r.stdout+r.stderr)
 if expected:assert r.returncode and expected in r.stdout,r.stdout+r.stderr
 else:assert not r.returncode and 'PASS SRAM_PIN_HOLD' in r.stdout,r.stdout+r.stderr
 records.append({'name':label,'expected_failure':bool(expected),'parameters':params,'output':r.stdout})
 print(label+': '+('PASS expected physical-gap detection' if expected else r.stdout.strip()),flush=True)
assert hashes=={str(p.relative_to(R)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [source,active,wrapper,tb,Path(__file__)]}
(O/'summary.json').write_text(json.dumps({'status':('active matches negative fixture; candidates simulation only' if active.read_text()==original else 'active controller also checked against all positive pin modes'),'sources_sha256':hashes,'read_access_model':read_model,'write_start_model':write_model,'candidate_read6_sha256':hashlib.sha256(candidate_path.read_bytes()).hexdigest(),'candidate_read7_sha256':hashlib.sha256(read7_path.read_bytes()).hexdigest(),'candidate_write_setup_sha256':hashlib.sha256(setup_path.read_bytes()).hexdigest(),'checks':records},indent=2)+'\n')
