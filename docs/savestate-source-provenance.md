# Experimental Pocket savestate source provenance

## Source pins

The Pocket transport and memory modules were imported from [agg23/openfpga-SNES PR 113](https://github.com/agg23/openfpga-SNES/pull/113), head `drizzt/openfpga-SNES@9d76821c0d8330b7e6929f49a69faa7fa763a963`. Every imported file was checked against the Git blob SHA supplied by GitHub. Exact paths, immutable URLs and source SHA-256 values are recorded in `savestate-source-manifest.json`.

The PR stores its blob on dedicated **cram1 PSRAM** and moves ARAM to the Pocket's asynchronous SRAM. It does not store the blob in SRAM. The experiment adopts this routing only for its explicit experimental profile; stable profiles retain their existing memory arrangement.

The adopted helper is [MiSTer SNES boot1.rom at 23026830](https://github.com/MiSTer-devel/SNES_MiSTer/blob/23026830ff8108fda0f32c0616296845f586b8ce/releases/boot1.rom), matching the recovered upstream engine generation:

- Size: 3558 bytes
- Git blob SHA: `097050f1421bea2d4f51ca234e2088317ed91bb7`
- SHA-256: `109b065d87989fae5d010040acfa6147160b8c8d3df50ab8cdabe7776e153001`
- Corresponding source: `rtl/upstream/src/savestates.asm` and all four
  `savestates_{sa1,dspn,gsu,cx4}.asm` includes, unchanged from the same commit
- Source SHA-256: `5824ca2a5b937562246e2af26051b31ce640d5cfbc2fffe38a3eb277bdbdd97d`

The 3558-byte GPL helper is the only newly added binary. It is firmware
for the core, not a commercial game ROM. The two text initialization forms
are deterministically generated, not tracked. They are byte-equivalent, with
zero padding to 4096 bytes. The generator checks
the pinned binary before converting; it does not claim to assemble the source.
All include files have verified Git blob and SHA-256 entries in the manifest.
Their presence does not enable the excluded enhancement-chip profiles.

PR 113's older 3107-byte helper was inspected but is **not shipped** by this experiment. That older binary matches MiSTer commit `19d95419fdf98b2382fc36912ba3ea4c2b002d4c`, Git blob `d899af9bcd3bfd8c51fe5ba5dc5d71c858063d54`, SHA-256 `d292cb38abf3faa8b95ef04afc805f0860070e39df6810d3ec36b620939098df`.

## Licenses

The upstream repositories carry GPL version 3 in their root LICENSE files. Preserve this repository's LICENSE and source when distributing derivatives. The imported asynchronous `target/pocket/sram.sv` separately identifies Adam Gastineau's openfpga-litex MIT implementation. Its full MIT notice is retained in `docs/licenses/openfpga-litex-MIT.txt`, fetched from [openfpga-litex commit c21570d8](https://github.com/agg23/openfpga-litex/blob/c21570d85260856c10f7b11c9e4d233c0fe65748/LICENSE). Original attribution in the RTL is preserved.

## Local transport changes

- Reset both clock domains coherently with the savestate engine; complete an already accepted physical PSRAM operation before reusing its shim
- Latch abort and protocol faults until coordinated reset, while draining accepted storage commands
- Export staged commit count, staging completion and complete transport-drain levels
- Keep staging loss sticky until an explicit new-transfer clear; reject gaps, duplicates and queue overflow
- Check that save writes are sequential full-byte qwords within payload capacity; seal save_complete only after SNES magic and the final header commit with valid declared length
- Sum committed writes for the payload checksum, and return zero for unwritten trailing payload padding
- Track prefetch epochs so a fetch completed after a walk boundary cannot become valid for a new walk
- Expose asynchronous ARAM SRAM busy state for the standard memory quiescence barrier, initialize inactive SRAM pins, and terminate each access with a full inactive WE/OE interval before accepting another address

`save_begin` and `stage_clear` are single-cycle pulses in clk_sys. `stage_expected_bytes` is a stable payload byte count for a transfer. `stage_idle`, `stage_complete`, `transport_idle`, `save_complete`, `stage_bytes_committed`, and `saved_payload_checksum` are clk_mem-domain results; consumers must synchronize the levels and sample bundled data only after the corresponding drain/completion level has settled. `fault` is clk_sys-domain and remains set until reset. `reset_n` must also reset the upstream engine's request toggle to zero.

`stage_complete` requires every payload byte to have committed to PSRAM. `stage_idle` alone does not prove that the last APF word has left the data loader. Abort does not silently cancel an armed CPU helper or reset the live game; the caller must quarantine new operations until an explicit reset.

## Verification limits

`python tests/savestate_storage/run.py` runs production storage RTL with a functional external PSRAM pin-array model. It covers checksum and padding, direct/prefetched reads, stale prefetch rejection, exact staged commit accounting, missing/out-of-order/overflow data, mid-transfer abort/reset and partial byte-enable rejection, with NTSC, phase-offset and PAL clock variants.

These simulations are protocol regressions, not PSRAM electrical/timing signoff, Quartus timing closure, or Pocket hardware qualification. PR 113's final pinned tree contains no savestate RTL testbench. Its broad PR body claims more chip support than the checked-in README and guards support; this experiment makes no special-chip compatibility claim.

The staged ARAM path captures the complete address/data/control packet on the
system falling edge. Queued requests contribute to the busy barrier; the SRAM
controller enforces write setup, seven-clock reads, hold and recovery intervals.
`run_request_stage.py`, `run_pin_hold.py`, `run_sram_clear.py --request-stage`
and `run_aram.py --request-stage` under `tests/savestate_storage/` exercise those
boundaries and deliberate broken alternatives. The pin-skew harness reproduces
selected earlier routed-delay conditions as regression stimuli, not final-fit data.

The [official Alliance Memory AS6C2016 datasheet](https://www.alliancememory.com/wp-content/uploads/AllianceMemory_2M_LPSRAM_AS6C201620May202021_v1.1_May2021.pdf)
identifies AS6C2016-55BIN as the 55 ns TFBGA device and lists 6 pF input and 8 pF
I/O capacitance maxima. The profile applies those device loads to 21 address/control
and 16 data signals; `test_sram_load_policy.tcl` checks ownership, idempotence and
profile cleanup. The datasheet capacitances are characterized at 25 degrees C,
1 MHz, and are not production-tested values. The load model does not include
measured PCB flight, trace capacitance or board-specific voltage/temperature proof.

The final core regression is `tests/savestate_stage1/final_aram_variant/run.py`.
It extracts the selected production wrapper and combines real core/helper/state
storage with the actual staged ARAM/SRAM path, original LoROM/HiROM SRAM-mutating
fixtures and a RAM_SIZE=0 omission negative. Authored functional pin models are
included; proprietary vendor models and generated evidence are not distributed.
This simulation does not qualify the APF platform or real Pocket hardware.
The independent same-placement native fit and conditional SRAM budget passed
for the current source; their device-load, zero-PCB-flight and reserve assumptions
are recorded in [the experiment guide](SAVESTATE-STAGE1.md#native-build-and-conditional-sram-budget).
Use each fresh run's source-bound summary; historical component-case counts are
not a final qualification total. No PR-derived SDC multicycle exception was imported.
