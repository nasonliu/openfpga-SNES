# Staged ARAM / guarded SRAM core regression

This separate variant tests the active final integration without overwriting the
historical direct-ARAM or earlier controller evidence. It combines:

- Actual original LoROM/HiROM SRAM-mutating 65816 and SPC700 fixtures
- Actual SNES core, mapper, helper and savestate engine
- Production state-blob PSRAM adapter/controller and external pin model
- The selected production ARAM wrapper block, extracted directly from
  rtl/mister_top/SNES.sv, including request stage, reset gating and busy logic
- Production falling-system-edge aram_request_stage
- Active SRAM controller with WRITE_SETUP, seven-clock read wait, HOLD and RECOVER
- External 55ns functional SRAM pin model

From the repository root, with Python, GHDL, Verilator and a C++ compiler on PATH:

    python3 tests/savestate_stage1/run.py --build-only
    python3 tests/savestate_stage1/final_aram_variant/run.py

The first command generates ignored helper initialization, translates the source
and creates fresh source-bound compilation snapshots. No archived build or prior
Git history is needed. Helper-generation functions in the neighboring variant
modules are support code only; their obsolete archive-based runners are omitted.

--base-build DIR selects the fresh GHDL core snapshots; --out DIR isolates
results. --skip-build rejects source/input/binary drift. Both mappings and the
RAM_SIZE=0 omission negative run by default.

The wrapper block is checked for the exact address, data, byte-lane, write/read,
reset gating, busy aggregation and QIP binding before compilation. The memory
controller leaves reset before the CPU, so active raw requests during CPU reset
exercise the production !RESET_N mask. Actual queued requests must keep the
combined busy indication high, even while the physical controller is idle.
Clear/download signals remain inactive; their lifecycle is covered separately.
This is extraction of the selected memory boundary, not elaboration of the
entire outer wrapper or APF platform.

Every helper ARAM read-consume and normal DSP/SMP read-consume compares actual
controller return data with physical memory contents. The original strict state,
independent SRAM formula, restored heartbeat and renewed CPU/SPC execution checks
remain. Neither state-memory nor ARAM read data comes from the observer scoreboards.

These are ideal functional pin-envelope checks. They are not loaded-I/O timing,
output-pad-skew, SRAM setup/hold/tDH, vendor PVT, board or hardware qualification.
The independent same-placement conditional SRAM audit passed for the current
source; see [its scope and assumptions](../../../docs/SAVESTATE-STAGE1.md#native-build-and-conditional-sram-budget).
Zero ideal-model violations alone do not establish that result. Generated source
hashes and run results are written to the selected output directory. The latest
host-ACK matrix remains incomplete, and no real-board qualification is claimed.
