# Original roundtrip ROM fixture

`fixture.py` emits original, headerless SNES ROMs with no external assembler or
borrowed game assets. It does not embed the SNES IPL. The optional original
86-byte SPC700 program uses the IPL already present in the real RTL.

## Python interface

```python
from fixture import build_fixture
rom, spec = build_fixture("lorom", with_spc=True)
rom, spec = build_fixture("hirom", with_spc=True)
```

The second result is JSON-safe. It includes CPU-address labels, memory ranges,
full expected sentinel bytes for both phases, idle registers, controller polarity,
SPC program/labels, and ROM SHA-256/checksum metadata. `build_rom()` instead
returns `(rom, symbols)` for callers using the older ROM-generator convention.

To create both mapping variants in a **new** directory:

```sh
python3 tests/savestate_stage1/fixture.py --out build/new-roundtrip-fixtures --with-spc
```

Each variant has a `.sfc`, one-byte-per-line `.hex`, and `.json` contract.
Omit `--with-spc` to isolate CPU/PPU/WRAM debugging. There is no silent fallback
when SPC mode is selected: a failed upload or phase acknowledgement sets the
error markers and cannot report phase A/B ready.

## Harness contract

Addresses below are physical byte offsets unless a CPU bank is stated.

| Observable | Phase A | Phase B |
|---|---|---|
| WRAM `$1F02` readiness | `$A1` | `$B2` |
| WRAM `$2000–$23FF` | `((i*73) XOR (i>>8) XOR $A7) AND $FF` | Complement of A |
| VRAM bytes `$0000–$00FF` | `((i*29) XOR (i>>2) XOR $3C) AND $FF` | Complement of A |
| CGRAM color 0 (BGR555) | `$03E0`, green | `$001F`, red |
| CPU A/X/Y in idle WAI | `$A15A/$1357/$2468` | `$B26B/$3579/$468A` |
| Optional ARAM `$0400–$043F` | `i XOR $A5` | `i XOR $5A` |
| Optional DSP MVOLL `$0C` | `$19` | `$67` |
| Optional DSP MVOLR `$1C` | `$29` | `$57` |

The sentinel WRAM CPU address is `$7E:2000`; low WRAM is mirrored in bank zero.
Heartbeat is the little-endian 16-bit WRAM word at `$1F00`, incremented once per
native NMI. WRAM `$1F03` is zero normally or `$01` on SPC timeout; readiness is
`$EE` on that error. Readiness is zero during startup.

The CPU is native, A/X/Y are 16-bit at idle, D/DB/PB are zero, and the idle stack
pointer is `$1FFF`. A native NMI entry has pushed four bytes, giving SP `$1FFB`
before the normal handler or savestate interception. The NMI handler saves and
restores all 16 bits of A/X/Y even when it interrupts an 8-bit setup/copy loop.

Start with raw `JOY1_DI(0)=0`. Set it to `1` after SAVE to request phase B.
The real CPU RTL inverts this line at `$4016`, so the program transitions when
CPU `$4016` bit zero is **zero**. Phase B is permanently latched in control flow.
Setting the raw line back to zero cannot reinitialize phase A. Release it before
LOAD, so a restored phase-A program does not immediately transition to B again.

Wait for readiness and a subsequent completed NMI before capturing state. The
markers are stable at WAI; they are not the expected values inside the NMI
handler, transient joy poll, or savestate firmware. Observe instruction/state
boundaries rather than assuming readiness alone means the CPU is already idle.

For running full-WRAM comparisons account for the heartbeat and active native
stack, which can change on interrupt/resume. The sentinel region, tested VRAM,
and color 0 are stable in both idle loops. A reset would reconstruct phase A,
but also clear the heartbeat and reset the CPU path: assert restored state and
resumption rather than relying on the picture alone.

SPC phase A acknowledges `$A1` through CPU `$2140` and waits for command `$B2`
through CPU `$2141`. Phase B acknowledges `$B2` and loops forever. The CPU waits
for the matching APU acknowledgement before announcing phase readiness. DSP
flags `$6C=$60` mute audio and disable echo writes; all voices are key-off.
Consequently silent audio equality is **not** an audio-continuity test. The
optional mode provides nontrivial ARAM and DSP-register roundtrip assertions.

## Mapping and validation

- LoROM: 32 KiB, header `$7FC0`, map mode `$20`, code at file `$0000`
- HiROM: 64 KiB, header `$FFC0`, map mode `$21`, code at file `$8000`
- Both execute from CPU `$00:8000`, use normal native NMI, have no SRAM, and
  contain valid size, reset/NMI vectors, checksum, and checksum-complement fields
- `validate_rom()` checks structural invariants; deterministic regeneration can
  check exact original identity
- Generator/structural checks are not a substitute for real-RTL roundtrip tests
  or physical hardware validation
