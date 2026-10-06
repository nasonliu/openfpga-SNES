#!/usr/bin/env python3
"""Candidate full-core helper with actual state PSRAM and55ns ARAM SRAM pins.
Fresh base GHDL build required; prior archived results are never overwritten.
"""
from pathlib import Path
import argparse,hashlib,importlib.util,json,re,subprocess,sys,time
HERE=Path(__file__).resolve().parent;BASE=HERE.parent;ROOT=BASE.parents[1]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def mod(name,path):
 spec=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m

def generate(source,staged):
 pin=mod('pin_generator',BASE/'pin_variant/run.py');sram=mod('sram_generator',BASE/'sram_variant/run.py')
 _,s=sram.sram_bench(pin.generate_bench(source),True)
 def change(old,new):
  nonlocal s
  if s.count(old)!=1:raise ValueError('Expected ARAM anchor '+old[:80])
  s=s.replace(old,new)
 change('module tb_sram_pins;',f'module tb_aram_joint;localparam TEST_ARAM_STAGE={int(staged)};')
 change('reg [7:0] aram[0:65535],aram_saved[0:65535];','reg [7:0] aram_saved[0:65535];')
 change('assign aq=aram[aa];','')
 change('  if(!aw && !ac) aram[aa]<=ad;','')
 change("begin rom[i]=8'hea;aram[i]=0;end","begin rom[i]=8'hea;end")
 s=re.sub(r'\baram\[','aram_pins.bytes[',s)
 change(' integer stage=0;',' integer stage=0;\n'+(HERE/'aram_boundary.svh').read_text())
 change('  $display("PASS SRAM_PHYSICAL_ROUNDTRIP', '''  if(helper_aram_reads!=65536 || helper_aram_writes!=65536 || normal_aram_reads<1000)$fatal(1,"ARAM_PIN_COVERAGE helper_reads=%0d helper_writes=%0d normal=%0d",helper_aram_reads,helper_aram_writes,normal_aram_reads);
  $display("ARAM_PIN_COUNTS request_stage=%0d helper_read_bytes=%0d helper_write_bytes=%0d normal_consume_reads=%0d physical_reads=%0d physical_writes=%0d read_min_ns=%0.3f WE_min_ns=%0.3f early_read_failures=%0d address_faults=%0d write_timing_failures=%0d turnaround_failures=%0d",TEST_ARAM_STAGE,helper_aram_reads,helper_aram_writes,normal_aram_reads,aram_pins.read_count,aram_pins.write_count,aram_pins.min_read_duration_ns,aram_pins.min_we_duration_ns,aram_pins.early_read_failures,aram_pins.address_faults,aram_pins.write_timing_failures,aram_pins.turnaround_failures);
  $display("PASS REAL_CORE_DUAL_MEMORY_PINS''')
 return s

# Support module for ../final_aram_variant/run.py; no standalone runner.
