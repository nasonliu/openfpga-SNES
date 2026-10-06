#!/usr/bin/env python3
"""Combined real SNES/helper/engine + production state PSRAM path at NTSC clocks.
Reuses exact source-bound GHDL artifacts from the completed five-case suite.
"""
from pathlib import Path
import argparse,gzip,hashlib,importlib.util,json,os,re,shutil,subprocess,sys,tarfile,time
HERE=Path(__file__).resolve().parent;BASE=HERE.parent;ROOT=BASE.parents[1]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def generate_bench(source):
 s=source
 def change(old,new):
  nonlocal s
  if s.count(old)!=1:raise ValueError('Expected unique bench anchor: '+old[:80])
  s=s.replace(old,new)
 change('module tb_roundtrip;','module tb_pins;')
 change('reg clk=0; always #5 clk=~clk;','reg clk=0; always #23.28 clk=~clk;')
 change('wire[63:0] ddro;reg[63:0] ddri=0;wire[18:0] ddra;wire[7:0] ddrbe;wire ddrwe,ddrreq;reg ddrack=0;', 'wire[63:0] ddro;wire[63:0] ddri;wire[18:0] ddra;wire[7:0] ddrbe;wire ddrwe,ddrreq;wire ddrack;')
 start=s.index('  // Explicit RAM service to the genuine engine,');end=s.index('\n end\n task tick',start)
 s=s[:start]+s[end:]
 change(' integer stage=0;', ' integer stage=0;\n'+(HERE/'storage_boundary.svh').read_text())
 change('stage=2;save=1;tick(2);save=0;','stage=2;storage_save_begin=1;tick(1);storage_save_begin=0;tick(2);save=1;tick(2);save=0;')
 change('save_words=ddr_writes;saved_heartbeat={wram[7937],wram[7936]};','save_words=ddr_writes;saved_heartbeat={wram[7937],wram[7936]};\n  verify_physical_save();')
 start=s.index('  if(stale_word) begin');end=s.index('  stage=4;',start);s=s[:start]+s[end:]
 change('  $display("PASS REAL_SNES_SAVESTATE_ROUNDTRIP', '''  if(load_byte_reads<260000 || read_acks<30000 || write_acks!=save_words || unacknowledged_byte_reads!=0)$fatal(1,"PIN_PATH_COVERAGE_MISSING");
  $display("PIN_DEVICE_METRICS reads=%0d writes=%0d highest_word=%0d address_failures=%0d early_read_failures=%0d min_adv_ns=%0.3f min_we_ns=%0.3f min_write_setup_ns=%0.3f min_read_cycle_ns=%0.3f min_oe_ns=%0.3f",pinram.read_count,pinram.write_count,pinram.highest_address,pinram.address_guard_failures,pinram.early_read_failures,pinram.min_adv_low_ns,pinram.min_we_low_ns,pinram.min_data_setup_ns,pinram.min_read_cycle_ns,pinram.min_oe_low_ns);
  $display("PIN_TIMING_COUNTS sys_period_ns=46.56 mem_period_ns=11.64 read_ack_min_sys_cycles=%0d read_ack_max_sys_cycles=%0d write_ack_max_sys_cycles=%0d engine_read_acks=%0d engine_write_acks=%0d consumed_load_bytes=%0d late_load_bytes=%0d",read_ack_min,read_ack_max,write_ack_max,read_acks,write_acks,load_byte_reads,unacknowledged_byte_reads);
  $display("PASS REAL_SNES_PHYSICAL_STATE_ROUNDTRIP''')
 return s

# Support module for ../final_aram_variant/run.py; no standalone runner.
