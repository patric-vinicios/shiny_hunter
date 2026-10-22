/*
 * Reference built from the Ghidra pseudocode REA returned for Pokémon FireRed
 * (USA) v1.0 (ROM sha256 3d0c79f1...a8ac). Each function keeps the shape of
 * the decompiled routine it stands for, so the Elixir port can be checked
 * against it rather than against itself.
 *
 * Reads "seed advance" lines on stdin, prints "slot level_roll pid iv1 iv2"
 * lines for a land encounter.
 */
#include <stdint.h>
#include <stdio.h>

static uint32_t gRngValue; /* DAT_08044edc -> 0x03005000 */

/* FUN_08044ec8 */
static uint32_t Random(void) {
  uint32_t v = gRngValue * 0x41c64e6du + 0x6073u;
  gRngValue = v;
  return v >> 0x10;
}

/* FUN_08042eb4: FUN_081e4684(pid, 0x19) & 0xff */
static uint8_t GetNature(uint32_t pid) { return (uint8_t)(pid % 0x19); }

static uint32_t out_pid, out_iv1, out_iv2;

/* FUN_0803dac4, the PID and IV part with a fixed personality */
static void CreateBoxMon(uint32_t personality) {
  out_pid = personality;
  out_iv1 = Random() & 0xffff;
  out_iv2 = Random() & 0xffff;
}

/* FUN_0803dd98 */
static void CreateMonWithNature(uint8_t nature) {
  uint32_t pid;
  do {
    uint32_t lo = Random();
    uint32_t hi = Random();
    pid = (lo & 0xffff) | hi << 0x10;
  } while (nature != GetNature(pid));
  CreateBoxMon(pid);
}

/* FUN_0808274c: FUN_081e4684(Random(), 100) */
static uint8_t ChooseWildMonIndex_Land(void) {
  uint8_t b = (uint8_t)((uint16_t)Random() % 100);
  if (b < 0x14) return 0;
  if ((uint8_t)(b - 0x14) < 0x14) return 1;
  if ((uint8_t)(b - 0x28) < 10) return 2;
  if ((uint8_t)(b - 0x32) < 10) return 3;
  if ((uint8_t)(b - 0x3c) < 10) return 4;
  if ((uint8_t)(b + 0xba) < 10) return 5;
  if ((uint8_t)(b + 0xb0) < 5) return 6;
  if ((uint8_t)(b + 0xab) < 5) return 7;
  if ((uint8_t)(b + 0xa6) < 4) return 8;
  if ((uint8_t)(b + 0xa2) < 4) return 9;
  if (b == 0x62) return 10;
  return 11;
}

/* FUN_080829fc, non-Unown branch */
static void CreateWildMon(void) {
  uint16_t r = (uint16_t)Random();
  CreateMonWithNature((uint8_t)(r % 0x19));
}

int main(void) {
  unsigned long seed, advance;
  while (scanf("%lu %lu", &seed, &advance) == 2) {
    gRngValue = (uint32_t)seed;
    for (unsigned long i = 0; i < advance; i++) Random();
    /* FUN_08082aec, land: slot, then FUN_080828f8's level draw, then the mon */
    uint8_t slot = ChooseWildMonIndex_Land();
    uint16_t level_roll = (uint16_t)Random();
    CreateWildMon();
    printf("%u %u %u %u %u\n", slot, level_roll, out_pid, out_iv1, out_iv2);
  }
  return 0;
}
