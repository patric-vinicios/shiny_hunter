"""
Runs FireRed (USA) v1.0's own wild Pokémon creation code under an ARM CPU
emulator and prints what it produced, so the Elixir port can be checked
against the game itself.

Usage: emulate_wild.py ROM < cases
Each input line is "state tid sid area": the RNG state at gRngValue, the
player's trainer IDs and the encounter kind (0 land, 1 water, 2 Rock Smash,
10 old rod, 11 good rod, 12 super rod). Each output line is
"slot species level pid ot_id hp atk def spe spa spd state_after".

The emulator runs the game's encounter routine for the area, 0x8082AEC
(land, water, Rock Smash) or 0x8082B64 (fishing), over a synthetic encounter
table whose slot i holds species TABLE_SPECIES + i with levels
table_levels(i). The call into 0x80829FC (create wild mon) is observed for
the slot, species and level the game chose. Calls to
0x80404D0 (set box mon data) are intercepted: the field id and value are
recorded and the call returns at once, which skips the struct encryption the
game would apply. Emulation stops once the last IV field is written.
"""

import struct
import sys

from unicorn import UC_ARCH_ARM, UC_MODE_THUMB, Uc, UcError
from unicorn.arm_const import (
    UC_ARM_REG_LR,
    UC_ARM_REG_PC,
    UC_ARM_REG_R0,
    UC_ARM_REG_R1,
    UC_ARM_REG_R2,
    UC_ARM_REG_SP,
)

ROM_BASE = 0x08000000
RNG_VALUE = 0x03005000          # DAT_08044EDC, the seed Random() updates
CREATE_WILD_MON = 0x080829FC    # FUN_080829FC
TRY_GENERATE_WILD_MON = 0x08082AEC  # FUN_08082AEC (info, area, check_repel)
GENERATE_FISHING_MON = 0x08082B64   # FUN_08082B64 (info, rod)
INFO = 0x02031000               # encounter info: +4 points at the table
TABLE = 0x02031100              # 12 entries of {min level, max level, species}
TABLE_SPECIES = 100
SET_BOX_MON_DATA = 0x080404D0   # FUN_080404D0
SAVE_BLOCK2_PTR_LITERAL = 0x0803DCBC  # DAT_0803DCBC, read by CreateBoxMon for the OT id
SAVE_BLOCK2 = 0x02030000        # a buffer in EWRAM we point the save block at
STOP = 0x08000100               # return address; never reached in practice

FIELD_PERSONALITY, FIELD_OT_ID = 0x00, 0x01
IV_FIELDS = [0x27, 0x28, 0x29, 0x2A, 0x2B, 0x2C]  # HP, Atk, Def, Spe, SpA, SpD


def table_levels(i):
    """Distinct level ranges per slot; some have min == max."""
    low = i + 2
    return low, low + (i % 4) * 3


def make_emulator(rom):
    uc = Uc(UC_ARCH_ARM, UC_MODE_THUMB)
    uc.mem_map(0x00000000, 0x4000)          # BIOS
    uc.mem_map(0x02000000, 0x40000)         # EWRAM
    uc.mem_map(0x03000000, 0x8000)          # IWRAM
    uc.mem_map(0x04000000, 0x1000)          # I/O registers
    uc.mem_map(0x05000000, 0x3000000)       # palette, VRAM, OAM
    uc.mem_map(ROM_BASE, 0x2000000)
    uc.mem_write(ROM_BASE, rom)
    return uc


def run_case(uc, rom, state, tid, sid, area):
    # Fresh RAM for every case.
    uc.mem_write(0x02000000, b"\0" * 0x40000)
    uc.mem_write(0x03000000, b"\0" * 0x8000)

    ptr_addr = struct.unpack_from("<I", rom, SAVE_BLOCK2_PTR_LITERAL - ROM_BASE)[0]
    uc.mem_write(ptr_addr, struct.pack("<I", SAVE_BLOCK2))
    uc.mem_write(SAVE_BLOCK2 + 10, struct.pack("<HH", tid, sid))
    uc.mem_write(RNG_VALUE, struct.pack("<I", state))
    uc.mem_write(INFO + 4, struct.pack("<I", TABLE))
    for i in range(12):
        low, high = table_levels(i)
        uc.mem_write(TABLE + 4 * i, struct.pack("<BBH", low, high, TABLE_SPECIES + i))

    fields = {}
    created = {}

    def on_create_wild_mon(uc, address, size, _):
        created["species"] = uc.reg_read(UC_ARM_REG_R0)
        created["level"] = uc.reg_read(UC_ARM_REG_R1) & 0xFF
        created["slot"] = uc.reg_read(UC_ARM_REG_R2) & 0xFF

    def on_set_box_mon_data(uc, address, size, _):
        field = uc.reg_read(UC_ARM_REG_R1)
        value_ptr = uc.reg_read(UC_ARM_REG_R2)
        fields[field] = struct.unpack("<I", uc.mem_read(value_ptr, 4))[0]
        if field == IV_FIELDS[-1]:
            uc.emu_stop()
        else:
            uc.reg_write(UC_ARM_REG_PC, uc.reg_read(UC_ARM_REG_LR))

    hooks = [
        uc.hook_add(1 << 2, on_set_box_mon_data, begin=SET_BOX_MON_DATA, end=SET_BOX_MON_DATA),  # UC_HOOK_CODE
        uc.hook_add(1 << 2, on_create_wild_mon, begin=CREATE_WILD_MON, end=CREATE_WILD_MON),
    ]
    uc.reg_write(UC_ARM_REG_SP, 0x03007E00)
    uc.reg_write(UC_ARM_REG_LR, STOP | 1)
    uc.reg_write(UC_ARM_REG_R0, INFO)
    if area >= 10:
        entry = GENERATE_FISHING_MON
        uc.reg_write(UC_ARM_REG_R1, area - 10)
    else:
        entry = TRY_GENERATE_WILD_MON
        uc.reg_write(UC_ARM_REG_R1, area)
        uc.reg_write(UC_ARM_REG_R2, 0)  # no Repel check
    try:
        uc.emu_start(entry | 1, STOP, count=50_000_000)
    finally:
        for hook in hooks:
            uc.hook_del(hook)

    missing = [f for f in [FIELD_PERSONALITY, FIELD_OT_ID, *IV_FIELDS] if f not in fields]
    if missing or len(created) != 3:
        raise RuntimeError(f"fields not written: {missing}")

    state_after = struct.unpack("<I", uc.mem_read(RNG_VALUE, 4))[0]
    ivs = [fields[f] & 0xFF for f in IV_FIELDS]
    head = [created["slot"], created["species"], created["level"]]
    return [*head, fields[FIELD_PERSONALITY], fields[FIELD_OT_ID], *ivs, state_after]


def main():
    rom = open(sys.argv[1], "rb").read()
    uc = make_emulator(rom)
    for line in sys.stdin:
        if not line.strip():
            continue
        state, tid, sid, area = (int(x) for x in line.split())
        try:
            print(" ".join(str(v) for v in run_case(uc, rom, state, tid, sid, area)))
        except (UcError, RuntimeError) as error:
            pc = uc.reg_read(UC_ARM_REG_PC)
            print(f"error {error} pc=0x{pc:08x}", file=sys.stderr)
            sys.exit(1)


if __name__ == "__main__":
    main()
