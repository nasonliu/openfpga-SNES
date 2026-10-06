# Experimental APF savestate protocol

This is a cloud-simulation prototype for plain LoROM/HiROM cartridges. It does
not qualify a distributable core, Sleep, enhancement chips, whole-console state
completeness, or hardware timing.

## Run

`tests/savestate_protocol/run.sh` runs the focused controller suite with Icarus.

For the production transport integration:

```
python3 tests/savestate_protocol/run_integration.py \
  --vendor-sim-dir /path/to/quartus/eda/sim_lib
```

A full-size case uses the same production paths, address range and sender pace:

```
python3 tests/savestate_protocol/run_integration.py --full-only \
  --output build/savestate-protocol-full
```

That case transfers a 0x64000-byte payload (32-byte envelope extra), crossing all
16 KiB boundaries through the last word. It takes substantially longer under
the vendor event-driven simulation model. A complementary two-state full-size
run, using the same unmodified vendor FIFO source, is available with
`python3 tests/savestate_protocol/run_verilator.py`. The two-state result does
not replace four-state phase/endian checks. It skips the extra corrupt re-upload;
that rejection is covered by every short phase/endian case.

The integration uses the original Intel `altera_mf.v` `dcfifo` model, production
`data_loader`, `data_unloader`, `savestate`, `psram_blob` and `psram` modules.
Only the SNES engine transactions and off-chip PSRAM array are modeled. Results,
source hashes, commands and logs go under `build/savestate-protocol-integration`.
The current APF model explicitly asserts exact 75 source-clock read and write spacing and verifies the read response
before the next request using the existing save-reader early-latch deadline.
It is not the complete serial `io_bridge_peripheral` frontend.

## Format and lifecycle

The APF advertised length is a fixed, cartridge-dependent payload length plus a
32-byte envelope. Each header word is normalized exactly like `data_loader`:

| Byte offset | Value |
| --- | --- |
| 0 | `0x31535350` (`PSS1` bytes in little-endian payload order) |
| 4 | format version `1` |
| 8 | exact payload bytes |
| 12 | current ROM identity |
| 16 | modulo-2^32 sum of all normalized payload 32-bit words |
| 20 | flags `1` (checksum present) |
| 24, 28 | reserved, must be zero |

APF writes **all** envelope and payload words in ascending order before A4.
Offset zero begins/replaces a preload and sends an explicit storage-clear event.
The controller retains this state while otherwise idle. Last-word detection
alone is insufficient: every offset, length, field and checksum must match.
Missing, duplicated, unaligned, out-of-range and trailing words fail closed.

The payload alone is sent through `data_loader` at bridge address minus 32.
Metadata and rejected writes never enter the PSRAM stage. Before issuing
`ss_load`, the controller also waits for `stage_complete` (exact bytes physically
committed) and `stage_drained`; this covers the real data-loader FIFO tail after
the bridge has already accepted its final word. The core is not mutated while
validating a malformed blob.

The serializer writes contiguous qwords beginning at byte 8 and its internal
header at byte 0 last. Storage sums committed halfword beats, validates that
sequence and returns virtual zeros above the actual saved extent. Thus the
fixed-length APF padding is deterministic and included in the checksum without
clearing all PSRAM first. The additive checksum detects accidental corruption;
it is not authentication or cryptographic integrity.

A0/A4 completion requires a real `ss_busy` rising edge, its subsequent falling
edge, and drained storage. A0 also requires `save_complete`: the storage layer
must have committed a valid SNES payload signature, contiguous body, and final
internal count/length header. A busy-only cycle with no real serialization fails
and quarantines instead of publishing a bogus snapshot. The controller requires
a fresh low/high `save_complete` transition after each save trigger, so a prior
snapshot seal cannot authenticate a later short/no-op walk. A successful A0 exposes the envelope plus the saved
payload for readback. Readback requires exact ascending coverage; abandonment
or invalid offsets produce an error. The final read holds the session lock for
256 bridge clocks and transport idle to cover the bounded loader/unloader
pipeline before SRAM-backup work can resume.

New admission (`ss_admit`) is separate from ongoing safety (`ss_allow`). A
sys-domain ownership latch resolves a backup-versus-host initial CDC race before
triggering the engine. Once a preload/save owns the session, a newly queued SRAM
backup waits; it does not revoke the savestate and cause a circular wait.

APF ACK/BUSY/OK/ERR registers live directly in `clk_74a`. Requests and completions
cross as toggle mailboxes with stable bundled data. Availability, stage status,
and storage-idle levels use explicit synchronizers. The serializer continues
using its ordinary CPU clock enables; the controller does not freeze CPU clocks.
A timeout or storage error after triggering a serializer request quarantines it
until the **actual console/serializer reset**. Merely going idle does not cancel
the engine's internally armed interrupt request.

## Coverage and limitations

The focused suite exercises 38 scenarios, including preload-before-A4,
metadata/identity/length/checksum rejection, exact transfer coverage, big-endian
bridge normalization, lost staging, missing trigger/walk/drain timeouts,
readback timeout, duplicate and conflicting commands, reset cancellation,
quarantine/recovery, and no success before actual busy exit plus storage drain.

The integration round trip covers NTSC and PAL clock ratios, four memory-clock
phases, both endian settings, virtual-zero padding, the real FIFO tail before
A4, engine readback through physical PSRAM pins, and a corrupt payload rejected
before live-engine load. Negative mutations remove committed-count or checksum
validation to confirm the test detects those missing guards. The focused runner
also removes each save-seal guard and verifies that busy-only/stale-seal cases
fail. Archived baseline full four-state evidence used 76-clock read spacing
with the same early read-data deadline; the accompanying pacing correction and
exact-75 reruns distinguish those results.

This is not proof that every SNES register/RAM section is captured/restored, nor
metastability analysis, physical CDC timing, place-and-route signoff, or a Pocket
hardware test. A payload identity/hash is a compatibility guard, not security.
