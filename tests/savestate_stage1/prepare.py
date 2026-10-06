#!/usr/bin/env python3
"""Source-bound simulation normalization, not a substitute state serializer."""
from pathlib import Path
import re
ROOT=Path(__file__).resolve().parents[2]
HEADER='library ieee;use ieee.std_logic_1164.all;use ieee.numeric_std.all;\n'
def entity(text,name):
 m=re.search(r'\bentity\s+'+name+r'\s+is\b.*?\bend\s+(?:entity(?:\s+'+name+r')?|'+name+r')\s*;',text,re.I|re.S)
 if not m: raise ValueError('Missing entity '+name)
 return HEADER+m[0]+'\n'
def prepare(out):
 out=Path(out);out.mkdir(parents=True,exist_ok=True)
 bram=(ROOT/'rtl/upstream/bram.vhd').read_text()
 # Registered-address, unregistered-output, write-through behavioral FPGA RAM.
 # This substitutes only the vendor primitive. Actual CPU/PPU/SMP/DSP RTL stays.
 assert all(x in bram for x in ['power_up_uninitialized => "FALSE"','outdata_reg_a => "UNREGISTERED"','read_during_write_mode_port_a => "NEW_DATA_NO_NBE_READ"'])
 models=entity(bram,'spram')+'''architecture simulation of spram is
 type memory_t is array(0 to 2**addr_width-1) of std_logic_vector(data_width-1 downto 0);
 signal mem:memory_t := (others=>(others=>'0'));
 signal a:unsigned(addr_width-1 downto 0):=(others=>'0');
 begin
 process(clock) begin if rising_edge(clock) then if enable='1' then
 a<=unsigned(address);if wren='1' and cs='1' then mem(to_integer(unsigned(address)))<=data;end if;
 end if;end if;end process;
 q<=mem(to_integer(a)) when cs='1' else (others=>'1');
end;\n'''
 models+=entity(bram,'dpram')+'''architecture simulation of dpram is
 type memory_t is array(0 to 2**addr_width-1) of std_logic_vector(data_width-1 downto 0);
 signal mem:memory_t := (others=>(others=>'0'));
 signal aa,ab:unsigned(addr_width-1 downto 0):=(others=>'0');
 begin
 process(clock) begin if rising_edge(clock) then
 if enable_a='1' then aa<=unsigned(address_a);if wren_a='1' and cs_a='1' then mem(to_integer(unsigned(address_a)))<=data_a;end if;end if;
 if enable_b='1' then ab<=unsigned(address_b);if wren_b='1' and cs_b='1' then mem(to_integer(unsigned(address_b)))<=data_b;end if;end if;
 end if;end process;
 q_a<=mem(to_integer(aa)) when cs_a='1' else (others=>'1');
 q_b<=mem(to_integer(ab)) when cs_b='1' else (others=>'1');
end;\n'''
 models+=entity(bram,'dpram_dif')+'''architecture simulation of dpram_dif is
 function imin(a,b:integer) return integer is begin if a<b then return a;else return b;end if;end;
 constant unit_width:integer:=imin(data_width_a,data_width_b);
 constant ratio_a:integer:=data_width_a/unit_width;
 constant ratio_b:integer:=data_width_b/unit_width;
 type memory_t is array(0 to 2**addr_width_a*ratio_a-1) of std_logic_vector(unit_width-1 downto 0);
 signal mem:memory_t := (others=>(others=>'0'));
 signal aa:unsigned(addr_width_a-1 downto 0):=(others=>'0');
 signal ab:unsigned(addr_width_b-1 downto 0):=(others=>'0');
 begin
 assert data_width_a mod unit_width=0 and data_width_b mod unit_width=0 severity failure;
 assert 2**addr_width_a*data_width_a=2**addr_width_b*data_width_b severity failure;
 process(clock) begin if rising_edge(clock) then
 if enable_a='1' then aa<=unsigned(address_a);if wren_a='1' and cs_a='1' then
 for i in 0 to ratio_a-1 loop mem(to_integer(unsigned(address_a))*ratio_a+i)<=data_a((i+1)*unit_width-1 downto i*unit_width);end loop;end if;end if;
 if enable_b='1' then ab<=unsigned(address_b);if wren_b='1' and cs_b='1' then
 for i in 0 to ratio_b-1 loop mem(to_integer(unsigned(address_b))*ratio_b+i)<=data_b((i+1)*unit_width-1 downto i*unit_width);end loop;end if;end if;
 end if;end process;
 ga:for i in 0 to ratio_a-1 generate q_a((i+1)*unit_width-1 downto i*unit_width)<=mem(to_integer(aa)*ratio_a+i) when cs_a='1' else (others=>'1');end generate;
 gb:for i in 0 to ratio_b-1 generate q_b((i+1)*unit_width-1 downto i*unit_width)<=mem(to_integer(ab)*ratio_b+i) when cs_b='1' else (others=>'1');end generate;
end;\n'''
 mlab=(ROOT/'rtl/upstream/mlab.vhd').read_text()
 models+=entity(mlab,'mlab')+'''architecture simulation of mlab is
 type memory_t is array(0 to 2**addr_width-1) of std_logic_vector(data_width-1 downto 0);
 signal mem:memory_t := (others=>(others=>'0'));
 begin
 process(clock) begin if rising_edge(clock) then if wren='1' then mem(to_integer(unsigned(wraddress)))<=data;end if;end if;end process;
 q<=mem(to_integer(unsigned(rdaddress))) when cs='1' else (others=>'1');
end;\n'''
 (out/'primitives.vhd').write_text(models)
 # Same two simulation-only tool accommodations as tests/aram_timing/run.py.
 smp=(ROOT/'rtl/upstream/SMP.vhd').read_text();assert 'SPC700: entity work.SPC700' in smp
 (out/'SMP-normalized.vhd').write_text(smp.replace('SPC700: entity work.SPC700','CPUcore: entity work.SPC700'))
 dsp=(ROOT/'rtl/upstream/DSP.vhd').read_text();start=dsp.index('process(CLK, RST_N, RS, BRR_VOICE');end=dsp.index('end process;',start)
 chunk=dsp[start:end].replace('variable LR: integer range 0 to 1;', 'variable LR: integer range 0 to 1;\n variable LR_SEQ: integer range 0 to 1;')
 k=chunk.index("if RST_N = '0' then");chunk=chunk[:k]+re.sub(r'\bLR\b','LR_SEQ',chunk[k:])
 (out/'DSP-normalized.vhd').write_text(dsp[:start]+chunk+dsp[end:])
 # Instance-label only normalization avoids GHDL case-folded net collisions.
 snes_original=(ROOT/'rtl/upstream/SNES.vhd').read_text()
 snes_fixed=snes_original
 for label in ['CPU','WRAM','PPU','SMP','DSP']:
  snes_fixed=re.sub(r'\b'+label+r'(\s*:\s*entity work\.)', 'CORE'+label+r'\1',snes_fixed)
 (out/'SNES-normalized.vhd').write_text(snes_fixed)
 ppu=(ROOT/'rtl/upstream/PPU.vhd').read_text()
 (out/'PPU-normalized.vhd').write_text(re.sub(r'\bHOAM(\s*:\s*entity work\.)',r'COREHOAM\1',ppu))
 # Disabled Game Genie only. This fixture never writes codes and holds reset.
 snes=(ROOT/'rtl/upstream/SNES.vhd').read_text()
 codes=re.search(r'component CODES is(.*?)end component;',snes,re.S)[1]
 (out/'codes_disabled.vhd').write_text(HEADER+'entity CODES is'+codes+'end;\narchitecture disabled of CODES is begin available<=\'0\';genie_ovr<=\'0\';genie_data<=(others=>\'0\');end;\n')
 # Analyze just the entity for the unselected DSPn branch; it is never elaborated.
 (out/'DSPn-disabled.vhd').write_text(entity((ROOT/'rtl/upstream/chip/DSP/DSPn.vhd').read_text(),'DSPn')+'architecture disabled of DSPn is begin assert false report "DSPn is outside test scope" severity failure; end;\n')
 cpu=[ROOT/'rtl/upstream/65C816'/(n+'.vhd') for n in ['P65816_pkg','AddrGen','BCDAdder','AddSubBCD','ALU','MCode','P65C816']]
 spc=[ROOT/'rtl/upstream/SPC700'/(n+'.vhd') for n in ['SPC700_pkg','AddrGen','AddSub','BCDAdj','ALU','MCode','MulDiv','SPC700']]
 snes_sources=[out/'primitives.vhd',out/'codes_disabled.vhd',*cpu,*spc,ROOT/'rtl/upstream/CPU.vhd',ROOT/'rtl/upstream/SWRAM.vhd',ROOT/'rtl/upstream/PPU_PKG.vhd',out/'PPU-normalized.vhd',ROOT/'rtl/upstream/DSP_PKG.vhd',ROOT/'rtl/upstream/CEGen.vhd',out/'DSP-normalized.vhd',out/'SMP-normalized.vhd',out/'SNES-normalized.vhd']
 mapper=(ROOT/'rtl/upstream/chip/DSP/DSP_LHRomMap.vhd').read_text()
 for label in ['OBC1','SRTC']:
  mapper=re.sub(r'\b'+label+r'(\s*:\s*entity work\.)','CORE'+label+r'\1',mapper)
 (out/'DSP_LHRomMap-normalized.vhd').write_text(mapper)
 map_sources=[out/'DSPn-disabled.vhd',ROOT/'rtl/upstream/CEGen.vhd',ROOT/'rtl/upstream/chip/DSP/OBC1.vhd',ROOT/'rtl/upstream/chip/SRTC.vhd',out/'DSP_LHRomMap-normalized.vhd']
 return snes_sources,map_sources
if __name__=='__main__':
 import sys
 for group in prepare(sys.argv[1]):print(' '.join(map(str,group)))
