/*
 * The game's arithmetic, in JavaScript, giving exactly the answers lib/vblank/ir/int32.rb gives
 * (the native runtime's rg_int32.h, function for function).
 *
 * Every number a game keeps is a signed 32-bit whole number that wraps round at the ends, the way
 * the console's registers do. JavaScript keeps every number as a 64-bit float instead, which
 * holds any 32-bit number exactly but does not wrap: 2147483647 + 1 is 2147483648 there, a number
 * no game can hold. So every answer here is brought back to 32 bits — `| 0` for a sum, Math.imul
 * for a product, whose float would lose its low bits — and the cases IR::Int32 spells out
 * (dividing by nought, shifting by 32 or more) are each tested for.
 *
 * The game never writes +, <, / or any other operator on one of its numbers; it calls one of
 * these. A comparison is a number, 1 or 0, the way the game's conditions are.
 */

const RG_INT32_MIN = -2147483648;
const RG_INT32_MAX = 2147483647;
const RG_TWO_TO_32 = 4294967296;

function rg_add(a, b) { return (a + b) | 0; }
function rg_sub(a, b) { return (a - b) | 0; }
function rg_mul(a, b) { return Math.imul(a, b); }
function rg_neg(a) { return (-a) | 0; }

/* How far from nought: the lowest number has no positive partner, so it stays itself. */
function rg_abs(a) { return a < 0 ? (-a) | 0 : a; }

/* Held at the floor first and the ceiling second, so a floor above its ceiling gives the ceiling. */
function rg_clamp(a, min, max) {
  const floored = a < min ? min : a;
  return floored > max ? max : floored;
}

/* Dividing by nought gives what the console's divide routine gives: 1 or -1 following the
 * numerator's sign. The lowest number divided by -1 wraps back to itself. A quotient of two 32-bit
 * numbers is never close enough to a whole number for the float division to land on the wrong
 * side of it, so truncating the float is the whole-number answer. */
function rg_div(a, b) {
  if (b === 0) return a < 0 ? -1 : 1;
  if (a === RG_INT32_MIN && b === -1) return RG_INT32_MIN;
  return Math.trunc(a / b) | 0;
}

/* What is left over, with Ruby's meaning: it takes the sign of the divisor. JavaScript's % takes
 * the numerator's, as C's does, so a remainder of the other sign has the divisor added back. */
function rg_mod(a, b) {
  if (b === 0) return a;
  if (b === -1) return 0;
  const rem = a % b;
  return rem !== 0 && (rem < 0) !== (b < 0) ? (rem + b) | 0 : rem | 0;
}

/* The low 32 bits of a whole number, signed. +n+ may be past 32 bits; a float holds it exactly up
 * to 2**53, and ToInt32 (what `| 0` does) takes the low bits of any such number. */
function rg_wrap(n) { return n | 0; }

const RG_SAFE = 9007199254740992; /* 2**53: below it, a float holds every whole number */

/* --- numbers that hold a fraction ---
 *
 * Such a number is kept multiplied up by 2**bits, +bits+ 0 to 32. A product of two is worked out
 * whole and brought back down by rounding down. The float holds the product exactly whenever it is
 * under 2**53, which is nearly always; the rare bigger one is done in BigInt. */
function rg_mul_fix(a, b, bits) {
  const product = a * b;
  if (product < RG_SAFE && product > -RG_SAFE) return rg_wrap(Math.floor(product / 2 ** bits));
  return Number(BigInt.asIntN(32, (BigInt(a) * BigInt(b)) >> BigInt(bits)));
}

/* Dividing two of them: the numerator moved up once more first, the answer truncated toward
 * nought and held at the ends of the range rather than wrapped (Int32.div_fix). Dividing by nought
 * gives a raw 1 or -1. */
function rg_div_fix(a, b, bits) {
  if (b === 0) return a < 0 ? -1 : 1;
  const den = Math.abs(b);
  let q;
  const num = Math.abs(a) * 2 ** bits;
  if (num < RG_SAFE / 2) {
    q = Math.floor(num / den);
    if (q * den > num) q--;
    else if ((q + 1) * den <= num) q++;
  } else {
    q = Number((BigInt(Math.abs(a)) << BigInt(bits)) / BigInt(den));
  }
  const negative = (a < 0) !== (b < 0) && num !== 0;
  if (negative) return q >= 2147483648 ? RG_INT32_MIN : -q | 0;
  return q > RG_INT32_MAX ? RG_INT32_MAX : q;
}

/* --- the bits themselves --- */

function rg_and(a, b) { return a & b; }
function rg_or(a, b) { return a | b; }
function rg_xor(a, b) { return a ^ b; }
function rg_not(a) { return ~a; }

/* A shift count outside 0..31 pushes every bit off the end, so the number is emptied: 0 going
 * left, and going right whatever fills in behind. JavaScript's own shifts keep the count's low
 * five bits instead, which is why it is spelt out. */
function rg_shl(a, count) {
  if (count < 0 || count >= 32) return 0;
  return a << count;
}

function rg_shr(a, count) {
  if (count < 0 || count >= 32) return a < 0 ? -1 : 0;
  return a >> count;
}

/* --- comparisons and conditions --- */

function rg_lt(a, b) { return a < b ? 1 : 0; }
function rg_le(a, b) { return a <= b ? 1 : 0; }
function rg_gt(a, b) { return a > b ? 1 : 0; }
function rg_ge(a, b) { return a >= b ? 1 : 0; }
function rg_eq(a, b) { return a === b ? 1 : 0; }
function rg_ne(a, b) { return a !== b ? 1 : 0; }
/* Both sides were worked out before the call, as the interpreter works them out: JavaScript's &&
 * would skip the second. */
function rg_both(a, b) { return a !== 0 && b !== 0 ? 1 : 0; }
function rg_either(a, b) { return a !== 0 || b !== 0 ? 1 : 0; }

/* --- keeping a number in a narrow slot: its low bits, read back with the slot's top bit as the
 * sign, so 200 in a byte reads back as -56 --- */

function rg_to_byte(a) { return (a << 24) >> 24; }
function rg_to_half(a) { return (a << 16) >> 16; }
