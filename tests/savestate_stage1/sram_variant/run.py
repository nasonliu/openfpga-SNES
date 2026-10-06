#!/usr/bin/env python3
"""Targeted ordinary SRAM inclusion: real CPU mappings and state RAM_SIZE contract.
Separate fixtures/benches; frozen core and physical-path evidence stay unchanged.
"""
from pathlib import Path
import argparse,gzip,hashlib,importlib.util,json,re,subprocess,sys,tarfile,time
HERE=Path(__file__).resolve().parent;BASE=HERE.parent;ROOT=BASE.parents[1]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def module(name,path):
 s=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m

def sram_bench(text,physical):
 s=text
 def change(a,b):
  nonlocal s
  if s.count(a)!=1:raise ValueError('Unique SRAM bench anchor missing '+a[:70])
  s=s.replace(a,b)
 old='tb_pins' if physical else 'tb_roundtrip';name='tb_sram_pins'if physical else'tb_sram_main'
 change('module '+old+';', 'module '+name+';')
 change(' integer stage=0;', ' integer stage=0;integer engine_ram_size=1;integer sram_mutations=0;')
 change(".RAM_SIZE(4'h1)",'.RAM_SIZE(engine_ram_size[3:0])')
 change('  if(!$value$plusargs("rom=%s",rom_file))', '  n=$value$plusargs("engine_ram_size=%d",engine_ram_size);\n  if(!$value$plusargs("rom=%s",rom_file))')
 change('  stage=2;', '''  for(i=0;i<64;i=i+1)if(bsram[i]!==8'(((i*53)^'hc3)&255))$fatal(1,"SRAM_FIXTURE_A_MISMATCH byte=%0d got=%h",i,bsram[i]);
  $display("SRAM_INITIALIZED mapper=%0d declared_header_ram_kib=2 engine_ram_size=%0d bytes=64",hirom,engine_ram_size);
  stage=2;''')
 change('for(i=0;i<2048;i=i+1)bsram_saved[i]=bsram[i];', '''for(i=0;i<2048;i=i+1)bsram_saved[i]=bsram[i];
  for(i=0;i<64;i=i+1)if(bsram[i]!==8'(((i*53)^'hc3)&255))$fatal(1,"SRAM_SAVE_CORRUPTED_CHECKPOINT byte=%0d",i);''')
 change('  $display("MUTATION_COMPLETE' , '''  sram_mutations=0;
  for(i=0;i<64;i=i+1)begin
   if(bsram[i]!=bsram_saved[i])sram_mutations=sram_mutations+1;
   if(bsram[i]!==8'((((i*53)^'hc3)&255)^255))$fatal(1,"SRAM_FIXTURE_B_MISMATCH byte=%0d got=%h",i,bsram[i]);
  end
  if(sram_mutations!=64)$fatal(1,"SRAM_MUTATION_NOT_EXECUTED count=%0d",sram_mutations);
  $display("SRAM_MUTATION_COMPLETE bytes=%0d",sram_mutations);
  $display("MUTATION_COMPLETE''')
 change('  bad=0;', '''  for(i=0;i<64;i=i+1)if(bsram[i]!==bsram_saved[i] || bsram[i]!==8'(((i*53)^'hc3)&255))$fatal(1,"SRAM_RESTORE_MISMATCH byte=%0d got=%h expected=%h engine_ram_size=%0d",i,bsram[i],bsram_saved[i],engine_ram_size);
  $display("SRAM_RESTORED bytes=64");
  bad=0;''')
 change('  $display("RESUME_B_CONFIRMED', '''  for(i=0;i<64;i=i+1)if(bsram[i]!==8'((((i*53)^'hc3)&255)^255))$fatal(1,"RESUMED_CPU_DID_NOT_MUTATE_SRAM byte=%0d",i);
  $display("SRAM_RESUME_CONFIRMED bytes=64");
  $display("RESUME_B_CONFIRMED''')
 change('PASS REAL_SNES_PHYSICAL_STATE_ROUNDTRIP'if physical else'PASS REAL_SNES_SAVESTATE_ROUNDTRIP', 'PASS SRAM_PHYSICAL_ROUNDTRIP'if physical else'PASS SRAM_MAIN_ROUNDTRIP')
 return name,s

# Support module for ../final_aram_variant/run.py; no standalone runner.
