# Plain-cartridge savestate experiment

This is an experimental source candidate for the owner’s fork, based on public
`msu1-standard-experimental` commit `44442443508356dbc362c6c34304a51cc5b5ba16`.
It is not a release. The native fit and conditional SRAM timing audit passed
for the current reviewed source. The latest host-ACK regression is incomplete,
and no Pocket hardware savestate qualification is claimed.

## Scope

Build profile: `savestate_standard_ntsc`. Only ordinary NTSC LoROM/HiROM, no MSU, no enhancement chips, cartridge RAM at most 128 KiB, ROM at most 4 MiB. `sleep_supported` remains false. This is not a release or hardware qualification.

The existing MiSTer engine and matching 65816 helper execute the snapshot through the real SNES CPU at an interrupt boundary. The implementation does **not** halt the CPU clock during that walk. The helper has its own addressed response through the standard owner/tag/epoch ROM client, rather than relying on the unused legacy ROM output.

The experimental profile places ARAM on the Pocket's asynchronous SRAM and uses dedicated cram1 PSRAM for a state image, adapting the reviewed PR113 transport. Stable profiles retain the previous ARAM/PSRAM arrangement. In this profile,
the complete ARAM request is captured on the system falling edge; queued and
physical requests both participate in the clear/battery-save barrier. The SRAM
controller establishes write address/data before opening WE, uses seven memory
clocks for read capture at the nominal clock, and retains explicit post-access
hold/recovery intervals. The build assigns 6 pF input and 8 pF I/O device loads
on all 37 SRAM signals through a savestate-owned Board Model Far C setting.
These published device limits do not constitute a measured PCB model. The
same-placement conditional SRAM budget is summarized below. No clock or timing
exception is changed. See [source provenance](savestate-source-provenance.md) and its manifest for immutable source references and license notices.

## Blob format and validation

The APF bridge exposes an envelope at `0x40000000`, with eight 32-bit little-endian words followed by the MiSTer payload:

1. `0x31535350` (`PSS1`)
2. Format version 1
3. Payload byte count
4. Cartridge CRC32 identity
5. Additive-32 payload checksum
6. Flags, currently 1 (checksum present)
7. Reserved, zero
8. Reserved, zero

Format version 1 is specific to this plain-NTSC codec and the pinned helper ROM. Any incompatible helper, memory layout, special-chip or MSU extension must bump the format version; cross-revision compatibility is not assumed.

The fixed advertised payload capacity is `0x44000 + cartridge RAM bytes`. Unwritten trailing save padding reads as zero. The identity includes every accepted ROM byte and loader configuration; it detects accidental mismatches, not malicious cryptographic substitution. A different ROM, format, size, checksum, malformed sequence or incomplete committed upload is rejected before starting the live restore engine.

Loading is two phase: receive/validate the complete image first, then trigger the 65816 restore. Saving does not report completion until the helper has returned, all backing-memory traffic has drained, and storage has sealed the SNES signature, sequential payload and final size header for this new save. A stale completion flag from the previous save is not sufficient. A failure after arming the engine quarantines additional state commands until an explicit core reset, because a pending NMI/IRQ hook cannot safely be withdrawn by merely resetting the APF sequencer.

Ordinary SRAM upload/backup remains a separate protocol. The state transaction holds an interlock so queued battery-save operations cannot reset the running serializer or read partly restored state. Host boot/ROM replacement still resets the experiment.

An acknowledged battery-save session blocks new state admission until the host
sends `008F` (all complete), including across a core reset. Conversely, an
existing state owner delays a registered slot-10 upload ACK until ownership
ends. This prevents the host from filling the finite queue while state owns RAM;
a later queued backup does not revoke the ongoing state safety signal.

Validation is incomplete: the retained 14-case admission regression covers the
earlier admission gate only. The latest host ACK, state-first `0082` upload,
128 KiB/overflow negative and slot-ID matrix have not completed verification.
See [the admission test scope](../tests/savestate_backup_session/README.md).
This source must not be described as ready for hardware delivery.


## Native build and conditional SRAM budget

The current reviewed source completed Quartus Lite 21.1.1 Build 850 fitting for
Cyclone V 5CEBA4F23C8, using 13,129 of 18,480 ALMs and 213 of 308 RAM blocks.
All 132 internal all-corner summary checks are nonnegative; minimum setup is
+0.778 ns and hold is +0.084 ns.

An independent audit of that same placement passed the four-corner conditional
SRAM budgets: read setup +12.796 ns, read hold +3.256 ns, write address setup
+9.274 ns, post-write data hold +11.820 ns and read-to-write turnaround +15.056 ns.
The native panels confirm all 37 device loads, with 6 pF address/control and
8 pF data pins. These budgets assume zero PCB flight time and retain a 0.120 ns
reserve. They are not measured PCB results, a general PSRAM timing qualification,
or real-Pocket validation.

The outstanding release blocker remains the latest host-ACK/session regression
above. A successful fit and conditional memory budget do not complete that
functional matrix.

## Verification commands

Put Python, Icarus Verilog, GHDL, Yosys and Verilator on PATH as needed.
Native builds require your installed Quartus toolchain. Tests never download
software or bundle proprietary vendor models.

- `python3 tools/generate_savestate_rom.py`
- `python3 tests/savestate_identity/run.py`
- `python3 tests/savestate_predecode/run.py`
- `bash tests/savestate_protocol/run.sh`
- `python3 tests/savestate_storage/run.py`
- `python3 tests/savestate_storage/run_request_stage.py`
- `python3 tests/savestate_storage/run_pin_hold.py`
- `python3 tests/savestate_storage/run_sram_clear.py --request-stage`
- `python3 tests/savestate_storage/run_aram.py --request-stage`
- `tclsh tests/savestate_storage/test_sram_load_policy.tcl`
- `python3 tests/savestate_stage1/run.py --build-only`
- `python3 tests/savestate_stage1/final_aram_variant/run.py` (LoROM/HiROM SRAM roundtrips and the RAM_SIZE=0 negative control)
- `MSU1_BUILD_JOBS=1 bash tools/build_msu1.sh savestate_standard_ntsc`

Component simulations and an RTL build are not a successful complete-console state roundtrip. Each source-bound summary distinguishes its tested boundary and failures. A behavioral external memory model is not a vendor timing model or board measurement. Resource fitting and internal timing do not prove external SRAM/PSRAM electrical timing. The native fit and conditional SRAM budget above are separate evidence; the incomplete host-ACK matrix and board validation remain explicit limits.

## Excluded claims

No MSU stream restoration, PAL, enhancement-chip savestates, Sleep/Wake, Memories UI hardware validation, cross-core/version state compatibility, or commercial-game compatibility is established by this first phase. Existing SRAM save support and the previously tested MSU build remain separate deliverables.
