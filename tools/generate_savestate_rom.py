#!/usr/bin/env python3
"""Convert the pinned MiSTer helper ROM without changing its bytes."""
from pathlib import Path
import hashlib
ROOT = Path(__file__).resolve().parents[1]
p = ROOT/'rtl/upstream/releases/boot1.rom'
data = p.read_bytes()
EXPECTED = '109b065d87989fae5d010040acfa6147160b8c8d3df50ab8cdabe7776e153001'
if len(data) != 3558 or hashlib.sha256(data).hexdigest() != EXPECTED:
    raise SystemExit('Unexpected helper ROM: provenance must be reviewed before regeneration')
data += bytes(4096-len(data))
words = [int.from_bytes(data[i:i+2], 'little') for i in range(0,4096,2)]
(ROOT/'rtl/mister_top/boot1.mif').write_text('WIDTH=16;\nDEPTH=2048;\nADDRESS_RADIX=HEX;\nDATA_RADIX=HEX;\nCONTENT BEGIN\n'+''.join(f'{i:03X} : {w:04X};\n' for i,w in enumerate(words))+'END;\n')
(ROOT/'rtl/mister_top/boot1.hex').write_text(''.join(f'{w:04x}\n' for w in words))
print('Verified helper ROM; generated 2048 little-endian words')
