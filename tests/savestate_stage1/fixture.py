#!/usr/bin/env python3
"""Original, assembler-free ROM fixtures for the real SNES savestate RTL.

SPDX-License-Identifier: GPL-3.0-or-later

No game, BIOS/IPL, music, or other third-party asset is embedded.  The optional
SPC700 payload is uploaded through the console's existing IPL, not a copied IPL.
The generated ROMs are test assets, not a claim of validation on physical SNES
or Analogue Pocket hardware.  See fixture_spec() for the complete harness ABI.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import struct


FORMAT = "pocket-savestate-stage1-fixture-v1"
CPU_ORIGIN = 0x8000
WRAM_START = 0x7E2000
WRAM_SIZE = 0x400
VRAM_START = 0
VRAM_SIZE = 0x100
HEARTBEAT = 0x7E1F00       # 16-bit little-endian native NMI count
READY = 0x7E1F02           # 00 initializing, A1 phase A, B2 phase B, EE SPC error
SPC_ERROR = 0x7E1F03       # 00 normally, 01 if an optional upload/ack timed out
PHASE_A = 0xA1
PHASE_B = 0xB2
SPC_ORIGIN = 0x0200
ARAM_START = 0x0400
ARAM_SIZE = 0x40
REGISTERS = {
    "A": {"a": 0xA15A, "x": 0x1357, "y": 0x2468},
    "B": {"a": 0xB26B, "x": 0x3579, "y": 0x468A},
}
COLORS = {"A": 0x03E0, "B": 0x001F}
DSP_VOLUMES = {"A": {0x0C: 0x19, 0x1C: 0x29},
               "B": {0x0C: 0x67, 0x1C: 0x57}}


def _phase(phase: str) -> str:
    phase = phase.upper()
    if phase not in ("A", "B"):
        raise ValueError("phase must be A or B")
    return phase


def wram_pattern(phase: str) -> bytes:
    """Every byte differs between phases; pages have distinct signatures."""
    flip = 0 if _phase(phase) == "A" else 0xFF
    return bytes((((i * 73) ^ (i >> 8) ^ 0xA7) & 0xFF) ^ flip
                 for i in range(WRAM_SIZE))


def vram_pattern(phase: str) -> bytes:
    flip = 0 if _phase(phase) == "A" else 0xFF
    return bytes((((i * 29) ^ (i >> 2) ^ 0x3C) & 0xFF) ^ flip
                 for i in range(VRAM_SIZE))


def aram_pattern(phase: str) -> bytes:
    seed = 0xA5 if _phase(phase) == "A" else 0x5A
    return bytes(i ^ seed for i in range(ARAM_SIZE))


class Emitter:
    """Tiny explicit-width emitter; all labels are CPU addresses in bank zero."""

    def __init__(self, origin: int = CPU_ORIGIN):
        self.origin = origin
        self.code = bytearray()
        self.labels: dict[str, int] = {}
        self.fixups: list[tuple[int, str, str]] = []

    def label(self, name: str) -> None:
        if name in self.labels:
            raise ValueError(f"duplicate label: {name}")
        self.labels[name] = self.origin + len(self.code)

    def emit(self, *data: int) -> None:
        self.code.extend(data)

    def imm16(self, opcode: int, value: int) -> None:
        self.emit(opcode, value & 0xFF, (value >> 8) & 0xFF)

    def absolute(self, opcode: int, target: int | str) -> None:
        self.emit(opcode)
        if isinstance(target, str):
            self.fixups.append((len(self.code), "absolute", target))
            self.emit(0, 0)
        else:
            self.emit(target & 0xFF, (target >> 8) & 0xFF)

    def long(self, opcode: int, target: int) -> None:
        self.emit(opcode, target & 0xFF, (target >> 8) & 0xFF,
                  (target >> 16) & 0xFF)

    def branch(self, opcode: int, target: str) -> None:
        self.emit(opcode)
        self.fixups.append((len(self.code), "relative", target))
        self.emit(0)

    def resolve(self) -> bytes:
        data = bytearray(self.code)
        for offset, kind, name in self.fixups:
            target = self.labels[name]
            if kind == "absolute":
                struct.pack_into("<H", data, offset, target)
            else:
                displacement = target - (self.origin + offset + 1)
                if not -128 <= displacement <= 127:
                    raise ValueError(f"branch out of range: {name}")
                data[offset] = displacement & 0xFF
        return bytes(data)


def spc_program() -> tuple[bytes, dict[str, int]]:
    """Original two-phase SPC700 code: ARAM pattern, DSP volumes, port ack.

    P=0, timers off, echo writes disabled, muted, all voices key-off.  Phase A
    writes $F4=A1 and waits for host $F5=B2.  Phase B writes $F4=B2 and loops
    permanently, so clearing the host command cannot reconstruct phase A.
    """
    s = Emitter(SPC_ORIGIN)

    def direct(address: int, value: int) -> None:
        s.emit(0x8F, value, address)           # MOV dp,#imm

    def dsp(address: int, value: int) -> None:
        direct(0xF2, address)
        direct(0xF3, value)

    def phase_body(phase: str) -> None:
        s.label("phase_" + phase.lower())
        for address, value in DSP_VOLUMES[phase].items():
            dsp(address, value)
        s.emit(0xCD, 0)                       # MOV X,#0
        s.label("aram_" + phase.lower())
        s.emit(0x7D)                          # MOV A,X
        s.emit(0x48, 0xA5 if phase == "A" else 0x5A)  # EOR A,#seed
        s.absolute(0xD5, ARAM_START)          # MOV abs+X,A
        s.emit(0x3D, 0xC8, ARAM_SIZE)         # INC X; CMP X,#$40
        s.branch(0xD0, "aram_" + phase.lower())
        direct(0xF4, PHASE_A if phase == "A" else PHASE_B)

    s.label("start")
    s.emit(0x20)                              # CLRP (direct page zero)
    direct(0xF1, 0)                          # timers off, IPL unmapped
    dsp(0x6C, 0x60)                          # FLG: mute and echo-write disable
    dsp(0x5C, 0xFF)                          # KOFF: all voices
    dsp(0x4C, 0)                             # KON: no new voices
    phase_body("A")
    s.label("idle_a")
    s.emit(0xE4, 0xF5, 0x68, PHASE_B)        # MOV A,$F5; CMP A,#B2
    s.branch(0xD0, "idle_a")
    phase_body("B")
    s.label("idle_b")
    s.branch(0x2F, "idle_b")                 # BRA forever
    program = s.resolve()
    if len(program) >= 0xFE or len(program) + 1 in (PHASE_A, PHASE_B):
        raise ValueError("SPC payload must fit one non-wrapping IPL transfer")
    return program, s.labels


def _cpu_program(with_spc: bool) -> tuple[bytes, dict[str, int]]:
    a = Emitter()

    def write(address: int, value: int) -> None:
        a.emit(0xA9, value)                   # LDA #imm8
        a.absolute(0x8D, address)            # STA abs

    def jump(target: str) -> None:
        a.absolute(0x4C, target)

    def spc_wait(value: int, name: str, address: int = 0x2140) -> None:
        # No silent fallback: a missing/broken APU produces a visible error.
        a.imm16(0xA2, 0xFFFF)
        a.label(name)
        a.absolute(0xAD, address)
        a.emit(0xC9, value)
        a.branch(0xF0, name + "_ok")
        a.emit(0xCA)                         # DEX
        a.branch(0xD0, name)
        jump("spc_failure")
        a.label(name + "_ok")

    def phase_body(phase: str) -> None:
        name = phase.lower()
        a.label("phase_" + name)
        a.emit(0xE2, 0x20)                   # A8, X/Y remain 16-bit
        write(0x2100, 0x80)                  # force blank for all VRAM writes
        a.imm16(0xA2, 0)
        a.label("copy_wram_" + name)
        a.absolute(0xBD, "wram_" + name)     # LDA abs,X (bank zero ROM)
        a.long(0x9F, WRAM_START)             # STA long,X
        a.emit(0xE8)
        a.imm16(0xE0, WRAM_SIZE)
        a.branch(0xD0, "copy_wram_" + name)

        write(0x2115, 0x80)                  # increment word on high-byte write
        a.absolute(0x9C, 0x2116)
        a.absolute(0x9C, 0x2117)
        a.imm16(0xA2, 0)
        a.label("copy_vram_" + name)
        a.absolute(0xBD, "vram_" + name)
        a.absolute(0x8D, 0x2118)
        a.emit(0xE8)
        a.absolute(0xBD, "vram_" + name)
        a.absolute(0x8D, 0x2119)
        a.emit(0xE8)
        a.imm16(0xE0, VRAM_SIZE)
        a.branch(0xD0, "copy_vram_" + name)

        a.absolute(0x9C, 0x2121)             # CGRAM color zero, low then high
        write(0x2122, COLORS[phase] & 0xFF)
        write(0x2122, COLORS[phase] >> 8)
        if phase == "B" and with_spc:
            write(0x2141, PHASE_B)
            spc_wait(PHASE_B, "spc_phase_b_ack")
        write(0x2100, 0x0F)                  # full brightness, backdrop only
        write(READY & 0xFFFF, PHASE_A if phase == "A" else PHASE_B)
        a.emit(0xC2, 0x30)                   # A/X/Y 16-bit marker state
        a.imm16(0xA2, REGISTERS[phase]["x"])
        a.imm16(0xA0, REGISTERS[phase]["y"])
        a.imm16(0xA9, REGISTERS[phase]["a"])
        jump("idle_" + name)

    a.label("reset")
    a.emit(0x78, 0xD8, 0x18, 0xFB)           # SEI CLD CLC XCE (native)
    a.emit(0xC2, 0x30)                       # A/X/Y 16-bit
    a.imm16(0xA2, 0x1FFF)
    a.emit(0x9A)                             # TXS; native WRAM stack
    a.imm16(0xA9, 0)
    a.emit(0x5B)                             # TCD; direct page = zero
    a.emit(0xE2, 0x20, 0x48, 0xAB)           # A8; PHA PLB; DB = zero
    for address in (0x4200, 0x420B, 0x420C, HEARTBEAT & 0xFFFF,
                    (HEARTBEAT + 1) & 0xFFFF, READY & 0xFFFF,
                    SPC_ERROR & 0xFFFF):
        a.absolute(0x9C, address)
    write(0x2100, 0x80)
    # Deterministic backdrop-only rendering.  Writes to VRAM/CGRAM ports here
    # are harmless because phase A explicitly resets and overwrites them.
    for address in range(0x2101, 0x2134):
        a.absolute(0x9C, address)
    if with_spc:
        program, _ = spc_program()
        spc_wait(0xAA, "spc_boot_aa")
        spc_wait(0xBB, "spc_boot_bb", 0x2141)
        write(0x2142, SPC_ORIGIN & 0xFF)
        write(0x2143, SPC_ORIGIN >> 8)
        write(0x2141, 1)
        write(0x2140, 0xCC)
        spc_wait(0xCC, "spc_transfer_ack")
        for index, value in enumerate(program):
            write(0x2141, value)
            write(0x2140, index)
            spc_wait(index, "spc_byte_" + str(index))
        write(0x2141, 0)                     # execute, and phase command = 0
        write(0x2142, SPC_ORIGIN & 0xFF)
        write(0x2143, SPC_ORIGIN >> 8)
        write(0x2140, len(program) + 1)       # previous counter + 2
        # Wait for our payload's ack, not the IPL's fleeting execution ack.
        spc_wait(PHASE_A, "spc_phase_a_ack")
    a.absolute(0xAD, 0x4210)                 # clear any stale NMI flag
    write(0x4200, 0x80)                      # normal native NMI, no autojoy/IRQ
    phase_body("A")

    a.label("idle_a")
    a.emit(0xCB)                             # WAI; NMI observes fixed markers
    a.emit(0x48, 0xE2, 0x20)                 # PHA (16-bit); switch A to 8-bit
    a.absolute(0xAD, 0x4016)
    a.emit(0x29, 1)                          # RTL returns NOT JOY1_DI(0)
    a.branch(0xD0, "keep_phase_a")           # raw JOY=0 -> remain A
    a.emit(0xC2, 0x20, 0x68)                 # restore 16-bit marker A
    jump("phase_b")
    a.label("keep_phase_a")
    a.emit(0xC2, 0x20, 0x68)
    a.branch(0x80, "idle_a")

    phase_body("B")
    a.label("idle_b")
    a.emit(0xCB)                             # never reread joy/reinitialize A
    a.branch(0x80, "idle_b")

    if with_spc:
        a.label("spc_failure")
        a.emit(0xE2, 0x20)
        write(SPC_ERROR & 0xFFFF, 1)
        write(READY & 0xFFFF, 0xEE)
        a.label("spc_failure_idle")
        jump("spc_failure_idle")

    a.label("nmi")
    # Interrupt entry already saved P.  Save full registers even if NMI struck
    # an A8 copy loop; RTI restores the interrupted widths and status flags.
    a.emit(0xC2, 0x30, 0x48, 0xDA, 0x5A)     # REP #30; PHA PHX PHY
    a.emit(0xE2, 0x20)
    a.absolute(0xAD, 0x4210)                 # acknowledge RDNMI
    a.emit(0xC2, 0x20)
    a.absolute(0xEE, HEARTBEAT & 0xFFFF)      # INC 16-bit heartbeat
    a.emit(0x7A, 0xFA, 0x68, 0x40)           # PLY PLX PLA RTI
    a.label("interrupt")
    a.emit(0x40)                             # unused native/emulation vectors
    for phase in ("A", "B"):
        a.label("wram_" + phase.lower())
        a.code.extend(wram_pattern(phase))
        a.label("vram_" + phase.lower())
        a.code.extend(vram_pattern(phase))
    return a.resolve(), a.labels


def validate_rom(rom: bytes, mapping: str = "lorom") -> dict:
    """Validate power-of-two image/header/checksum/reset-vector invariants."""
    mapping = mapping.lower()
    if mapping not in ("lorom", "hirom"):
        raise ValueError("mapping must be lorom or hirom")
    size, header, mode, exponent = ((0x8000, 0x7FC0, 0x20, 5)
                                     if mapping == "lorom" else
                                     (0x10000, 0xFFC0, 0x21, 6))
    if len(rom) != size:
        raise ValueError(f"expected {size} ROM bytes")
    if rom[header + 0x15:header + 0x19] != bytes((mode, 0, exponent, 0)):
        raise ValueError("unexpected mapper/type/ROM-size/SRAM-size header")
    complement, checksum = struct.unpack_from("<HH", rom, header + 0x1C)
    if complement ^ checksum != 0xFFFF or sum(rom) & 0xFFFF != checksum:
        raise ValueError("invalid checksum/complement")
    if struct.unpack_from("<H", rom, header + 0x3C)[0] != CPU_ORIGIN:
        raise ValueError("invalid reset vector")
    return {"mapping": mapping, "bytes": size, "header_offset": header,
            "map_mode": mode, "checksum": checksum,
            "sha256": hashlib.sha256(rom).hexdigest()}


def fixture_spec(mapping: str = "lorom", with_spc: bool = False,
                 symbols: dict[str, int] | None = None) -> dict:
    """Return a JSON-safe, address-explicit test-harness contract."""
    mapping = mapping.lower()
    if mapping not in ("lorom", "hirom"):
        raise ValueError("mapping must be lorom or hirom")
    if symbols is None:
        _, symbols = _cpu_program(with_spc)
    phases = {}
    for phase in ("A", "B"):
        phases[phase] = {
            "ready": PHASE_A if phase == "A" else PHASE_B,
            "cpu_idle_registers": {**REGISTERS[phase], "d": 0, "db": 0,
                                   "pb": 0, "sp": 0x1FFF, "e": 0,
                                   "m": 0, "index_width": 16},
            "wram_hex": wram_pattern(phase).hex(),
            "vram_hex": vram_pattern(phase).hex(),
            "cgram_color0_bgr555": COLORS[phase],
            "cgram_color0_hex": struct.pack("<H", COLORS[phase]).hex(),
        }
        if with_spc:
            phases[phase]["aram_hex"] = aram_pattern(phase).hex()
            phases[phase]["dsp_registers"] = {
                f"0x{reg:02x}": val for reg, val in DSP_VOLUMES[phase].items()}
    result = {
        "format": FORMAT, "original_assets_only": True,
        "hardware_verified": False, "mapping": mapping,
        "rom_bytes": 0x8000 if mapping == "lorom" else 0x10000,
        "code_file_offset": 0 if mapping == "lorom" else 0x8000,
        "symbols": dict(symbols), "with_spc": with_spc,
        "wram": {"cpu_address": WRAM_START, "physical_offset": 0x2000,
                 "length": WRAM_SIZE},
        "vram": {"byte_offset": VRAM_START, "word_address": 0,
                 "length_bytes": VRAM_SIZE, "byte_order": "low,high per word"},
        "cgram": {"color_index": 0, "length_bytes": 2},
        "heartbeat": {"cpu_address": HEARTBEAT, "physical_offset": 0x1F00,
                      "length": 2, "byte_order": "little", "increment": "each NMI"},
        "ready": {"cpu_address": READY, "physical_offset": 0x1F02,
                  "initializing": 0, "spc_failure": 0xEE},
        "spc_error": {"cpu_address": SPC_ERROR, "physical_offset": 0x1F03},
        "phases": phases,
        "stimulus": {
            "initial_JOY1_DI_bit0": 0,
            "phase_b_JOY1_DI_bit0": 1,
            "cpu_4016_bit0": "logical NOT of raw JOY1_DI bit 0 in this RTL",
            "restore": "Release raw JOY1_DI bit0 to 0 before requesting LOAD",
            "phase_b_is_latched": True,
        },
        "comparison_notes": [
            "Wait for ready byte and a subsequent completed native NMI before SAVE",
            "Idle markers apply at WAI, not inside NMI, joy polling, or SS firmware",
            "NMI entry has pushed 4 bytes; SP there is 0x1FFB, idle SP is 0x1FFF",
            "Exclude heartbeat and active stack from running full-WRAM equality",
            "Strict WRAM sentinel, first 256 VRAM bytes, color0 are stable in idle",
            "Releasing the controller in phase B cannot initialize phase A",
            "Reset restarts phase A and clears heartbeat; compare restored CPU state too",
        ],
    }
    if with_spc:
        program, spc_symbols = spc_program()
        result["spc"] = {
            "program_address": SPC_ORIGIN, "program_bytes": len(program),
            "program_hex": program.hex(), "symbols": spc_symbols,
            "aram_address": ARAM_START, "aram_length": ARAM_SIZE,
            "host_command_register": 0x2141, "host_ack_register": 0x2140,
            "dsp_flags": {"0x6c": 0x60, "0x5c": 0xFF, "0x4c": 0},
            "audio_expectation": "Muted; validates ARAM/DSP state, not audible audio",
            "upload_failure": "ready=EE and spc_error=01; no silent CPU-only fallback",
        }
    return result


def build_fixture(mapping: str = "lorom", with_spc: bool = False) -> tuple[bytes, dict]:
    """Build a deterministic headerless .sfc and its JSON-safe spec.

    LoROM is 32 KiB, code at file $0000 mapped to CPU $00:8000.  HiROM is
    64 KiB, code at file $8000 mapped to the same CPU address.  Both images
    have correct native/emulation vectors, mapper bytes, and SNES checksums.
    """
    mapping = mapping.lower()
    if mapping not in ("lorom", "hirom"):
        raise ValueError("mapping must be lorom or hirom")
    code, symbols = _cpu_program(with_spc)
    if len(code) > 0x7FC0:
        raise ValueError("fixture program overlaps SNES header")
    size, offset, header, mode, exponent = ((0x8000, 0, 0x7FC0, 0x20, 5)
        if mapping == "lorom" else (0x10000, 0x8000, 0xFFC0, 0x21, 6))
    rom = bytearray([0xEA] * size)
    rom[offset:offset + len(code)] = code
    rom[header:header + 21] = b"POCKET STATE ROUNDTRP"
    rom[header + 0x15:header + 0x1C] = bytes((mode, 0, exponent, 0, 1, 0, 0))
    rom[header + 0x20:header + 0x40] = bytes(32)
    for vector in (0x24, 0x26, 0x28, 0x2E, 0x34, 0x38, 0x3E):
        struct.pack_into("<H", rom, header + vector, symbols["interrupt"])
    for vector in (0x2A, 0x3A):
        struct.pack_into("<H", rom, header + vector, symbols["nmi"])
    struct.pack_into("<H", rom, header + 0x3C, symbols["reset"])
    struct.pack_into("<HH", rom, header + 0x1C, 0xFFFF, 0)
    checksum = sum(rom) & 0xFFFF
    struct.pack_into("<HH", rom, header + 0x1C, checksum ^ 0xFFFF, checksum)
    spec = fixture_spec(mapping, with_spc, symbols)
    spec["rom"] = validate_rom(bytes(rom), mapping)
    return bytes(rom), spec


def build_rom(mapping: str = "lorom", with_spc: bool = False) -> tuple[bytes, dict[str, int]]:
    """Convenience interface matching tools/standard_save_testrom.py."""
    rom, spec = build_fixture(mapping, with_spc)
    return rom, spec["symbols"]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True, type=Path,
                        help="new output directory (never overwrites an existing directory)")
    parser.add_argument("--mapping", choices=("lorom", "hirom", "both"), default="both")
    parser.add_argument("--with-spc", action="store_true",
                        help="upload original two-phase SPC700/DSP/ARAM payload")
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=False)
    mappings = ("lorom", "hirom") if args.mapping == "both" else (args.mapping,)
    for mapping in mappings:
        rom, spec = build_fixture(mapping, args.with_spc)
        stem = "savestate-stage1-" + mapping + ("-spc" if args.with_spc else "")
        (args.out / (stem + ".sfc")).write_bytes(rom)
        # readmemh-friendly ROM bytes are useful to both Verilog and C++ harnesses.
        (args.out / (stem + ".hex")).write_text("".join(f"{b:02x}\n" for b in rom))
        (args.out / (stem + ".json")).write_text(json.dumps(spec, indent=2) + "\n")
        print(json.dumps({"file": stem + ".sfc", **spec["rom"]}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
