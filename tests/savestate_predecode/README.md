# Latency-free savestate ARAM predecode

Run with Git, GHDL, Yosys and Icarus on PATH:

```
python3 tests/savestate_predecode/run.py
```

The candidate adds the parallel SCPU `PA_ARAM` output, routes it through SNES,
and uses it only when both `USE_SS` and `USE_STANDARD_SDRAM` are enabled.
Every other instantiation retains `ss_busy & (pa == 8'h84)` with the new
parameter defaulting to zero. No request stage, register, clock, strobe, bus
phase or timing constraint is added.

## What is proved

The runner extracts both the **actual current** `PA_ARAM` assignment and the
unchanged PA ownership process from `rtl/upstream/CPU.vhd`. GHDL translates
this source-bound combinational model; Yosys SAT proves:

```
PA_ARAM == (PA == 8'h84)
```

for every binary value of the complete 24-bit CPU address, the eight-bit DMA
B-bus address, P65 enable, global enable, HDMA/DMA ownership and all associated
read/write controls. There are no reachability assumptions. This is stronger
than the requested reachable-active-binary equivalence. The two DMA owners
select the same DMA_B address, but their existing HDMA-before-DMA strobe
priority is untouched.

A negative control suppresses the predicate under DMA ownership and must
produce a SAT counterexample. It checks that a real selected DMA request is
observable to this proof.

The source contract removes only the enumerated added ports, routing,
parameter and predicate from the four edited RTL files, then compares every
remaining byte against the fitted `9e1fb498fa6ee75f5e88e3d63085c3f813f161c2`
source via [four hash-bound test-only baselines](../fixtures/savestate_predecode/README.md),
without requiring the historical Git object. This binds the absence of other functional or cycle changes. Summary
hashes identify the exact current production sources and generated model.

## Four-state boundary and fallback checks

Icarus executes the GHDL-translated predicate/PA logic and the actual
savestates selector in default and enabled modes. Checks include:

- Every one of the 256 PA byte values in default mode, with the new sideband X
- Enabled selector consumes the sideband, while `ss_busy=0` masks an X sideband
- Unknown unselected DMA address during a known CPU access
- Unknown CPU address while CPU is disabled, or while DMA/HDMA owns the bus
- Selected DMA address with a possible-match X bit: both translated cones are X
- A known mismatching CPU address bit masks an unrelated X address bit
- Matching, nonmatching and bank-qualified CPU addresses; both DMA owners

For Icarus alone, a generated copy changes the existing procedural `rom_addr`
output declaration from implicit wire to reg. The production file is not
modified by the runner, and no equation is normalized. The parent actual-core
regression handles the full mixed-language implementation separately.

**No arbitrary-X ownership/control equivalence is claimed.** Native VHDL
boolean equality treats nonmatching meta-values as false, whereas synthesized
Verilog gates and conditional operators may propagate X. Binary SAT does not
model that distinction. The tests establish masking and selected-data-X
boundaries under known ownership/qualification; they do not reinterpret an
unknown active owner as valid hardware state or treat X as an asserted request.
The unchanged `ss_busy` gate and legacy fallback are explicitly checked.

## Limits

This is a combinational functionality proof, not a proof of analog glitches,
setup/hold, placement/routing improvement, or whole-console state restoration.
Actual CPU/DSP/helper roundtrips and the current source's native fit are
independent checks; the completed fit and conditional SRAM audit are summarized
in [the experiment guide](../../docs/SAVESTATE-STAGE1.md#native-build-and-conditional-sram-budget).
This combinational proof alone establishes none of those timing or board results.
