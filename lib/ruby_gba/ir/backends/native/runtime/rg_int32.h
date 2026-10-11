/*
 * The game's arithmetic, in C, giving exactly the answers lib/ruby_gba/ir/int32.rb gives.
 *
 * Every number a game keeps is a signed 32-bit whole number that wraps round at the ends, the
 * way the console's registers do. C has the same kind of number (int32_t) but not the same
 * promise about it: when a sum runs off the end, C does not say "it wraps", it says the
 * program is broken, and an optimising compiler is allowed to assume that never happens and
 * rearrange the code on that assumption. A game that wraps on purpose (an angle, a counter)
 * would then come out differently depending on how hard the compiler optimised.
 *
 * So nothing here does arithmetic on a signed number where it could run off the end. Sums,
 * differences and products are worked out on the unsigned kind (uint32_t), which C does
 * promise wraps, and turned back into the signed kind with rg_i32, which is written so that
 * it too means one thing everywhere. Division, remainders and shifts each test the cases C
 * leaves undefined before doing anything.
 *
 * The generated C never writes +, -, <, / or any other operator on a game's number; it calls
 * one of these. That one rule is what keeps it correct, and also why operator precedence and
 * C's habit of skipping the right side of && never come up.
 *
 * The arithmetic ones answer for a function of Int32 each (rg_add for add, rg_and for bit_and,
 * rg_shl for shift_left, ...); the comparisons, the joining of two conditions and the narrow
 * list slots answer for what the interpreter does with Int32's numbers, since Int32 has no
 * function for those. test_int32_helpers.rb runs every one of them against its answer key
 * over the awkward values and a spread of random ones.
 */
#ifndef RG_INT32_H
#define RG_INT32_H

#include <stdint.h>

/* A uint32_t's bits read as a signed number: the low 31 bits as they are, the top bit as the
 * sign. A plain cast would do the same on every compiler this is built with, but C calls that
 * cast "implementation-defined", and this way it is defined everywhere and compiles to
 * nothing. */
static inline int32_t rg_i32(uint32_t u) {
  return u <= (uint32_t)INT32_MAX ? (int32_t)u : (int32_t)(u - 0x80000000u) + INT32_MIN;
}

/* The same, for the low 32 bits of a 64-bit number. */
static inline int32_t rg_i32_of_64(int64_t n) {
  return rg_i32((uint32_t)(uint64_t)n);
}

/* Dividing by a power of two, rounding DOWN: what moving the bits of a negative number down
 * does on the console. C only promises that for numbers that are not negative, so a negative
 * one is turned round first (every bit flipped, which makes it non-negative), moved, and turned
 * back. The trick is zig.h's (zig_shr_i32). */
static inline int64_t rg_floor_shift_64(int64_t n, int bits) {
  int64_t sign = n < 0 ? -1 : 0;
  return ((n ^ sign) >> bits) ^ sign;
}

static inline int32_t rg_add(int32_t a, int32_t b) { return rg_i32((uint32_t)a + (uint32_t)b); }
static inline int32_t rg_sub(int32_t a, int32_t b) { return rg_i32((uint32_t)a - (uint32_t)b); }
static inline int32_t rg_mul(int32_t a, int32_t b) { return rg_i32((uint32_t)a * (uint32_t)b); }
static inline int32_t rg_neg(int32_t a) { return rg_i32(0u - (uint32_t)a); }

/* How far from nought: the lowest number has no positive partner, so it stays itself, as on
 * the console. */
static inline int32_t rg_abs(int32_t a) { return a < 0 ? rg_neg(a) : a; }

/* Held at the floor first and the ceiling second, so a floor above its ceiling gives the
 * ceiling (Reference's clamp_value). */
static inline int32_t rg_clamp(int32_t a, int32_t min, int32_t max) {
  int32_t floored = a < min ? min : a;
  return floored > max ? max : floored;
}

/* --- division ---
 *
 * Dividing by zero has no answer, and a game that does it has a fault in it. What it gets is
 * what the console's own divide routine gives (backends/gba/divide.rb, emit_divide_by_zero),
 * so a game behaves the same on the desktop as on the cartridge: 1 or -1 following the
 * numerator's sign, and the numerator itself left over. The lowest number divided by -1 has
 * no room for its answer and wraps back to itself, as Int32.div does; C calls that undefined,
 * so it is tested for too. */
static inline int32_t rg_div(int32_t a, int32_t b) {
  if (b == 0) return a < 0 ? -1 : 1;
  if (a == INT32_MIN && b == -1) return INT32_MIN;
  return a / b; /* C's / truncates toward zero, which is what Int32.div wants */
}

/* What is left over, with Ruby's meaning: it takes the sign of the divisor, so -1 % 64 is 63.
 * C's % takes the sign of the numerator, so a remainder whose sign disagrees with the divisor
 * has the divisor added back. */
static inline int32_t rg_mod(int32_t a, int32_t b) {
  if (b == 0) return a;
  if (b == -1) return 0; /* also the case C leaves undefined (the lowest number % -1) */
  int32_t rem = a % b;
  return (rem != 0 && (rem < 0) != (b < 0)) ? rem + b : rem;
}

/* --- numbers that hold a fraction ---
 *
 * Such a number is kept multiplied up by 2**bits, and +bits+ is 0 to 32: the lowering refuses
 * any other, since the shifts below would mean nothing past that. Multiplying two of them
 * multiplies up twice, so the product is worked out at 64 bits (the lowest number squared needs
 * 63 and a sign) and brought back down by rounding down, then wrapped like any other result. */
static inline int32_t rg_mul_fix(int32_t a, int32_t b, int bits) {
  return rg_i32_of_64(rg_floor_shift_64((int64_t)a * (int64_t)b, bits));
}

/* Dividing two of them divides the multiplying-up straight back out, so the numerator is
 * multiplied up once more first, at 64 bits. The answer truncates toward zero, and one too big
 * to hold is held at the end of the range rather than wrapped (see Int32.div_fix for why).
 * Dividing by zero gives the console's answer again: a raw 1 or -1, the smallest fraction,
 * because its fraction divide falls into the same code as its whole-number one. */
static inline int32_t rg_div_fix(int32_t a, int32_t b, int bits) {
  if (b == 0) return a < 0 ? -1 : 1;
  /* The numerator's size, moved up. Done unsigned because moving a negative number's bits up
   * is undefined in C; at most 2**31 moved 32 places, which fits. */
  uint64_t num = (uint64_t)(a < 0 ? -(int64_t)a : (int64_t)a) << bits;
  uint64_t den = (uint64_t)(b < 0 ? -(int64_t)b : (int64_t)b);
  uint64_t q = num / den;
  int negative = (a < 0) != (b < 0) && num != 0;
  if (negative) return q >= 0x80000000u ? INT32_MIN : -(int32_t)q;
  return q > (uint64_t)INT32_MAX ? INT32_MAX : (int32_t)q;
}

/* --- the bits themselves --- */

static inline int32_t rg_and(int32_t a, int32_t b) { return rg_i32((uint32_t)a & (uint32_t)b); }
static inline int32_t rg_or(int32_t a, int32_t b) { return rg_i32((uint32_t)a | (uint32_t)b); }
static inline int32_t rg_xor(int32_t a, int32_t b) { return rg_i32((uint32_t)a ^ (uint32_t)b); }
static inline int32_t rg_not(int32_t a) { return rg_i32(~(uint32_t)a); }

/* A shift count outside 0..31 pushes every bit off the end, so the number is emptied: 0 going
 * left, and going right whatever fills in behind (0, or -1 for a negative number). A negative
 * count empties it too rather than shifting the other way. No other compiler that targets C
 * does this (they keep the count's low five bits), which is why it is spelt out here. */
static inline int32_t rg_shl(int32_t a, int32_t count) {
  if (count < 0 || count >= 32) return 0;
  return rg_i32((uint32_t)a << count);
}

static inline int32_t rg_shr(int32_t a, int32_t count) {
  if (count < 0 || count >= 32) return a < 0 ? -1 : 0;
  return (int32_t)rg_floor_shift_64(a, count);
}

/* --- comparisons and conditions ---
 *
 * A comparison is a number: 1 when it holds and 0 when it does not, so a condition is simply
 * "not nought". Joining two conditions works both of them out, the way the interpreter does;
 * C's && would skip the second, which matters the day the second one does something. */

static inline int32_t rg_lt(int32_t a, int32_t b) { return a < b; }
static inline int32_t rg_le(int32_t a, int32_t b) { return a <= b; }
static inline int32_t rg_gt(int32_t a, int32_t b) { return a > b; }
static inline int32_t rg_ge(int32_t a, int32_t b) { return a >= b; }
static inline int32_t rg_eq(int32_t a, int32_t b) { return a == b; }
static inline int32_t rg_ne(int32_t a, int32_t b) { return a != b; }
static inline int32_t rg_both(int32_t a, int32_t b) { return (a != 0) & (b != 0); }
static inline int32_t rg_either(int32_t a, int32_t b) { return (a != 0) | (b != 0); }

/* --- keeping a number in a narrow slot ---
 *
 * A list can keep its items in a byte or a half-word. A number too big for the slot keeps its
 * low bits, read back with the slot's top bit as the sign: 200 in a byte reads back as -56,
 * as on the console. Worked out with arithmetic rather than a cast, so it is defined. */
static inline int8_t rg_to_byte(int32_t a) {
  /* The low eight bits with the top one flipped is 0..255; taking 128 away reads that top bit
   * as the sign, giving -128..127, which an int8_t holds exactly. */
  return (int8_t)(rg_i32(((uint32_t)a & 0xFFu) ^ 0x80u) - 0x80);
}

static inline int16_t rg_to_half(int32_t a) {
  return (int16_t)(rg_i32(((uint32_t)a & 0xFFFFu) ^ 0x8000u) - 0x8000);
}

#endif
