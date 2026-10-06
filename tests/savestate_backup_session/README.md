# Savestate and battery-save session admission

## Incomplete validation: historical admission-gate scope only

The retained 14-case results were obtained for the earlier complete-session
admission gate. They do not validate the latest host-domain upload-ACK interlock.
This source export has not executed the expanded session matrix. Current
state-first `0082` uploads, the complete 128 KiB upload/overflow negative control,
and stale/registered slot-ID ACK behavior remain unverified.

This bench still connects `dataslot_requestwrite_ack` to a constant one. Thus
its admission checks cannot establish the current `ss_lock_host` ACK behavior,
even if this older matrix reports PASS. Do not treat it as a release or hardware
acceptance test. The core, physical timing and firmware/hardware gates remain
separate. No generated historical logs are included.


Historical read-only admission integration regression for ordinary NTSC cartridge state
ownership. The unmodified production APF command parser, ROM/Save queue,
controller, host reset guard and Intel FIFO run together. The reduced wrapper
models an already mounted legal cartridge with other physical clients idle.
The serializer walk and committed staging levels are synthetic; this is an
admission/lifecycle test, not a complete-console roundtrip.

Run from the repository root with Icarus on PATH:

```sh
python3 tests/savestate_backup_session/run.py \
  --vendor-sim-dir /path/to/quartus/eda/sim_lib
```

The default output is `build/savestate-backup-session`. No generated compiler
binary or vendor source is published. The summary records current source and
vendor hashes and verifies sources remained stable during execution.

The historical 14-case admission matrix covers:

- A0 and A4 during an ACKed slot-10 read (`0080`) or upload (`0082`) session
- `GATE_SESSION=1` reproduces the production admission gate; `0` is the old-code
  mutation which must demonstrate premature state admission
- Rejection while a session is open, followed by successful fresh state work
  after `008F` (Data Slot Access All Complete)
- Core `0010`/`0011` reset with no `008F`: the session remains open, admission
  remains conservatively blocked, and subsequent `008F` permits recovery
- A0/A4 owning the state before a later `0080` read fence; the queued backup
  cannot revoke ongoing state safety and ACKs after the state releases ownership

`save_download` is the existing host-domain transaction lifetime latch, crossing
through the existing three-stage `save_s` synchronizer. It is set by a registered
read/write request and cleared by the rising all-complete indication. It is not
cleared by an emulator/core reset; this suite intentionally does not claim that
reset alone releases an abandoned host session.

The test provides actual command-level witnesses, not proof that shipping Pocket
firmware interleaves these sessions. It does not inspect physical BSRAM contents,
run the 65816 helper, or establish board timing. Independent helper/console and
physical-memory checks remain necessary.
