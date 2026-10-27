# The game's arithmetic, giving exactly the answers lib/vblank/ir/int32.rb gives.
#
# Every number a game keeps is a signed 32-bit whole number that wraps round at the ends, the way
# the console's registers do. A Ruby Integer never wraps: 2147483647 + 1 is 2147483648, a number
# no game can hold, and it goes on growing. So every answer that can leave the range is brought
# back into it (rg_i32), and the cases IR::Int32 spells out are each tested for: dividing by
# nought, Ruby's / rounding down where the game's rounds toward nought, a shift of 32 or more
# emptying the number where Ruby's would grow it.
#
# The game never writes +, <, / or any other operator on one of its numbers; it calls one of
# these. A comparison is a number, 1 or 0, the way the game's conditions are.
#
# These are the body of the game's class (see Ruby::Printer), so each is a method of the game.

RG_INT32_MIN = -2147483648
RG_INT32_MAX = 2147483647

# The low 32 bits of a whole number, read as a signed one.
def rg_i32(n)
  n &= 0xFFFFFFFF
  n >= 0x80000000 ? n - 0x100000000 : n
end

def rg_add(a, b) = rg_i32(a + b)
def rg_sub(a, b) = rg_i32(a - b)
def rg_mul(a, b) = rg_i32(a * b)
def rg_neg(a) = rg_i32(-a)

# How far from nought: the lowest number has no positive partner, so it stays itself.
def rg_abs(a) = a < 0 ? rg_i32(-a) : a

# Held at the floor first and the ceiling second, so a floor above its ceiling gives the ceiling.
def rg_clamp(a, min, max)
  floored = a < min ? min : a
  floored > max ? max : floored
end

# Dividing by nought gives what the console's divide routine gives: 1 or -1 following the
# numerator's sign. Ruby's / rounds down, and the game's rounds toward nought, so the sizes are
# divided and the sign put back. The lowest number divided by -1 wraps back to itself.
def rg_div(a, b)
  return a < 0 ? -1 : 1 if b == 0

  quotient = a.abs / b.abs
  rg_i32((a < 0) != (b < 0) ? -quotient : quotient)
end

# What is left over, with Ruby's meaning: it takes the sign of the divisor, which is what Ruby's
# own % does, so only nought needs saying.
def rg_mod(a, b)
  return a if b == 0

  a % b
end

# --- numbers that hold a fraction ---
#
# Such a number is kept multiplied up by 2**bits, +bits+ 0 to 32. A product of two is worked out
# whole and brought back down by rounding down, which is what Ruby's >> does on a negative.
def rg_mul_fix(a, b, bits) = rg_i32((a * b) >> bits)

# Dividing two of them: the numerator moved up once more first, the answer truncated toward
# nought and held at the ends of the range rather than wrapped (Int32.div_fix). Dividing by nought
# gives a raw 1 or -1.
def rg_div_fix(a, b, bits)
  return a < 0 ? -1 : 1 if b == 0

  num = a.abs << bits
  quotient = num / b.abs
  if (a < 0) != (b < 0) && num != 0
    quotient >= 0x80000000 ? RG_INT32_MIN : -quotient
  else
    quotient > RG_INT32_MAX ? RG_INT32_MAX : quotient
  end
end

# --- the bits themselves: Ruby keeps a negative number's bits as two's complement already, so
# these never leave the range ---

def rg_and(a, b) = a & b
def rg_or(a, b) = a | b
def rg_xor(a, b) = a ^ b
def rg_not(a) = ~a

# A shift count outside 0..31 pushes every bit off the end, so the number is emptied: 0 going
# left, and going right whatever fills in behind. Ruby's << would grow the number instead, and a
# negative count would turn round and shift the other way.
def rg_shl(a, count)
  return 0 if count < 0 || count >= 32

  rg_i32(a << count)
end

def rg_shr(a, count)
  return a < 0 ? -1 : 0 if count < 0 || count >= 32

  a >> count
end

# --- comparisons and conditions ---

def rg_lt(a, b) = a < b ? 1 : 0
def rg_le(a, b) = a <= b ? 1 : 0
def rg_gt(a, b) = a > b ? 1 : 0
def rg_ge(a, b) = a >= b ? 1 : 0
def rg_eq(a, b) = a == b ? 1 : 0
def rg_ne(a, b) = a != b ? 1 : 0
# Both sides were worked out before the call, as the interpreter works them out: Ruby's && would
# skip the second.
def rg_both(a, b) = a != 0 && b != 0 ? 1 : 0
def rg_either(a, b) = a != 0 || b != 0 ? 1 : 0

# --- keeping a number in a narrow slot: its low bits, read back with the slot's top bit as the
# sign, so 200 in a byte reads back as -56 ---

def rg_to_byte(a) = ((a & 0xFF) ^ 0x80) - 0x80
def rg_to_half(a) = ((a & 0xFFFF) ^ 0x8000) - 0x8000
