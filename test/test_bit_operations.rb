# frozen_string_literal: true

require "test_helper"

# Reading and writing the bits of a number: `& | ^ ~ << >>` on a Value.
#
# What these are FOR is packed data — a background map cell, a row of a collision
# shape, a word of state flags — so the tests are written as that: a real packed
# format taken apart and put back together, checked against a plain-Ruby model of
# the same thing. A test that restated the operator ("x & 3 is x & 3") would pass
# on a backend that had them all subtly wrong together.
#
# Every program here runs on BOTH backends and both must agree with Ruby's answer.
# The two could differ in exactly the places the model can't see — a mask too big to
# ride inside an instruction, a shift count worked out as the game runs, a count past
# the end of the number — so those are what the programs are built out of.
class TestBitOperations < Minitest::Test
  Int32 = RubyGBA::IR::Int32
  B = RubyGBA::IR::Build

  # A 16x16 solidity shape: one bit per pixel, sixteen 16-bit rows, the top bit of a
  # row being its leftmost pixel. This is how a real console keeps per-pixel collision,
  # and the shape is a staircase so that a test notices bits read in the wrong order.
  SHAPE = (0..15).map { |y| (0xFFFF << y) & 0xFFFF }.freeze

  # A background map cell as the hardware packs one: the tile number in the low ten
  # bits, then flip-across and flip-down, then which group of colours it draws from.
  CELL = (3 << 12) | (1 << 11) | (0 << 10) | 0x123

  # ---------------------------------------------------------------------------
  # what a program COMPUTES, on both backends
  # ---------------------------------------------------------------------------

  # Walk every pixel of a collision shape and ask whether it is solid — the thing a
  # game does four times per moving thing per frame, and the reason this feature
  # exists. Counting the solid ones catches a wrong mask; adding up where they are
  # catches bits read in the wrong order, which a count alone would not.
  def test_reading_one_bit_per_pixel_out_of_a_collision_shape
    want_solid = 0
    want_where = 0
    256.times do |i|
      next unless SHAPE[i >> 4][15 - (i & 15)] == 1

      want_solid += 1
      want_where += i
    end

    assert_both_backends_compute(solid: want_solid, where: want_where) do
      screen :bitmap
      shape = table :shape, SHAPE, width: :half
      solid = var :solid, 0
      where = var :where, 0
      repeat(256) do |i|
        row = shape[i >> 4]                      # which row of the shape — a shift by 4
        bit = (row >> (15 - (i & 15))) & 1       # ...and one pixel out of that row
        (bit == 1).then do
          solid.add 1
          where.add i
        end
      end
      halt
    end
  end

  # Take a packed map cell apart into its four fields and build the same cell back up
  # from them. Every field but the first needs a shift AND a mask, and the tile number
  # needs a mask too big to ride inside an instruction — so this is the one that would
  # catch a backend that only handled small masks.
  def test_a_packed_map_cell_comes_apart_and_goes_back_together
    expected = {
      tile: CELL & 0x3FF, across: (CELL >> 10) & 1, down: (CELL >> 11) & 1,
      bank: (CELL >> 12) & 15, rebuilt: CELL,
    }

    assert_both_backends_compute(expected) do
      screen :bitmap
      cell = var :cell, CELL
      tile = var :tile, 0
      across = var :across, 0
      down = var :down, 0
      bank = var :bank, 0
      rebuilt = var :rebuilt, 0

      tile.set cell & 0x3FF
      across.set((cell >> 10) & 1)
      down.set((cell >> 11) & 1)
      bank.set((cell >> 12) & 15)
      rebuilt.set((bank << 12) | (down << 11) | (across << 10) | tile)
      halt
    end
  end

  # Flags packed into one word: set one, clear one, turn one over, and test two that
  # are not next to each other. That last is the case with no arithmetic form at all —
  # no amount of dividing and wrapping can ask about bits 2 and 7 in one go.
  def test_setting_clearing_and_testing_flags_in_one_word
    hurt = 0x04
    armed = 0x80
    packed = hurt | armed | 0x01

    expected = { flags: (packed & ~hurt) ^ 0x01, both: hurt | armed, cleared: packed & ~hurt }

    assert_both_backends_compute(expected) do
      screen :bitmap
      flags = var :flags, 0
      both = var :both, 0
      cleared = var :cleared, 0
      mask = var :mask, hurt

      flags.set flags | hurt          # set a flag
      flags.set flags | armed         # and another
      flags.set flags | 0x01
      both.set(flags & (hurt | armed)) # two flags at once, not next to each other
      cleared.set(flags & ~mask)       # clear one through a mask the game works out
      flags.set flags & ~hurt          # clear it, the mask written down
      flags.set flags ^ 0x01           # turn one over
      halt
    end
  end

  # The ends of the range, where the chip and Ruby have different instincts and the
  # two backends could quietly disagree. A count of 32 or more empties the number, and
  # so does a negative count — it does NOT turn round and shift the other way, which is
  # what Ruby itself would do with one.
  def test_a_shift_past_the_end_of_the_number_empties_it
    expected = {
      up_far: 0, down_far: -1, up_back: 0, down_back: 0,
      down_negative: -4, up_round: 0, down_round: -1,
    }

    assert_both_backends_compute(expected) do
      screen :bitmap
      far = var :far, 40
      back = var :back, -1
      round = var :round, 256
      one = var :one, 1
      low = var :low, -256

      var :up_far, 0
      var :down_far, 0
      var :up_back, 0
      var :down_back, 0
      var :down_negative, 0
      var :up_round, 0
      var :down_round, 0

      set :up_far, one << far            # a count worked out, past the end
      set :down_far, back >> far         # -1 shifted down stays -1: the sign fills in
      set :up_back, one << back          # a negative count: off the end, not the other way
      set :down_back, one >> back
      set :down_negative, low >> 6       # -256 down six places is -4, keeping its sign
      # A count of 256 is the one the chip would get wrong on its own: it reads only
      # the low byte of a count, and 256's low byte is zero, so left alone it would
      # shift by nothing at all instead of emptying the number.
      set :up_round, one << round
      set :down_round, low >> round
      halt
    end
  end

  # The same rule with the count WRITTEN DOWN. The DSL turns that away (a count nobody
  # can have meant — see below), so this goes through the IR directly: a backend has to
  # honour the contract for any tree it is handed, whatever the surface happens to
  # allow, and the build settles a written-down count instead of emitting a shift.
  def test_a_written_down_count_past_the_end_is_settled_by_the_build
    program = B.program(
      B.screen(:bitmap),
      B.set(:up, B.binop(:<<, B.int(1), B.int(40))),            # 0 — off the top end
      B.set(:down, B.binop(:>>, B.int(-1), B.int(40))),         # -1 — the sign fills in
      B.set(:down_positive, B.binop(:>>, B.int(255), B.int(-1))), # 0 — a negative count
      B.halt,
    )
    expected = { up: 0, down: -1, down_positive: 0 }

    interpreter = Reference.new.run(program)
    expected.each { |name, want| assert_equal want, interpreter[name], "the interpreter's #{name}" }

    backend = GBA.new
    rom = ROM.assemble(backend.lower(program), title: "BITEDGE", code: "BBTE", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 3, vars: backend.var_addresses)
    expected.each { |name, want| assert_equal want, Int32.wrap(v.var(name)), "the console's #{name}" }
  end

  # A count written into the program that throws the whole number away is a mistake the
  # build can see, so it says so at the line rather than quietly giving 0.
  def test_a_written_down_count_past_the_end_is_a_friendly_error
    err = assert_raises(ArgumentError) do
      build_program do
        screen :bitmap
        flags = var :flags, 1
        set :out, flags << 40
      end
    end

    assert_match(/off the end/, err.message)
    assert_match(/0 to 31/, err.message)
  end

  def test_a_written_down_negative_count_is_a_friendly_error_naming_the_other_way
    err = assert_raises(ArgumentError) do
      build_program do
        screen :bitmap
        flags = var :flags, 1
        set :out, flags >> -2
      end
    end

    assert_match(/cannot go below 0/, err.message)
    assert_match(/`<<`/, err.message)
  end

  # ---------------------------------------------------------------------------
  # the surface: what a person is allowed to write
  # ---------------------------------------------------------------------------

  def test_a_number_written_in_the_program_can_stand_on_the_left
    assert_computes(masked: 0x0F & 0x3C, ored: 0xF0 | 0x0C, xored: 0xFF ^ 0x3C) do
      screen :bitmap
      value = var :value, 0x3C
      set :masked, 0x0F & value
      set :ored, 0xF0 | value
      set :xored, 0xFF ^ value
      halt
    end
  end

  # ...and costs the same either way round, which it would not if the build put both
  # sides through the stack just because the number was written first.
  def test_a_number_on_the_left_costs_what_it_costs_on_the_right
    left = emitted { |value| set :masked, 0x0F & value }
    right = emitted { |value| set :masked, value & 0x0F }

    assert_equal right, left, "a mask written on the left emitted more code than the same mask on the right"
  end

  # Ruby routes `& | ^` through #coerce and does not route `<< >>` that way, so the
  # shape a person reaches for first — one bit at a place the game works out — stops
  # with a message naming a class they never wrote. Say what to write instead.
  def test_a_number_on_the_left_of_a_shift_is_a_friendly_error
    err = assert_raises(ArgumentError) do
      build_program do
        screen :bitmap
        col = var :col, 3
        set :bit, 0x8000 >> col
      end
    end

    assert_match(/worked out as the game runs/, err.message)
    assert_match(/on the left/, err.message)
  end

  # A flag test in C is `if (flags & MASK)`, so `(flags & MASK).then { ... }` is what a
  # person writes here first. Ruby gives every object a `then` of its own, which would
  # run the block while the program is being built and record its body with no test
  # around it — the body running every frame, and nothing said.
  def test_branching_straight_off_a_number_is_a_friendly_error
    opened = false
    err = assert_raises(ArgumentError) do
      build_program do
        screen :bitmap
        flags = var :flags, 0
        (flags & 4).then { opened = true }
      end
    end

    refute opened, "the block ran, so the body would have been recorded with no test around it"
    assert_match(/not a yes/, err.message)
    assert_match(/!= 0/, err.message)
  end

  def test_a_bit_operation_on_a_number_holding_a_fraction_is_a_friendly_error
    err = assert_raises(ArgumentError) do
      build_program do
        screen :bitmap
        px = var :px, 3.5
        set :low, px & 15
      end
    end

    assert_match(/whole numbers/, err.message)
    assert_match(/\.to_i/, err.message)
  end

  def test_a_fraction_on_the_right_of_a_bit_operation_is_a_friendly_error
    err = assert_raises(ArgumentError) do
      build_program do
        screen :bitmap
        flags = var :flags, 0
        speed = var :speed, 1.5
        set :low, flags & speed
      end
    end

    assert_match(/the number on the right/, err.message)
  end

  # ---------------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------------

  private

  # How many bytes of code one expression came out as. The block is handed a variable
  # to work on, so only the expression differs between two of these.
  def emitted(&shape)
    program = build_program do
      screen :bitmap
      value = var :value, 0x3C
      var :masked, 0
      instance_exec(value, &shape)
      halt
    end
    GBA.new.lower(program).bytesize
  end

  def build_program(&block)
    builder = Builder.new
    builder.instance_eval(&block)
    builder.emit_pending_functions
    builder.program
  end

  # Run one program through the reference interpreter and assert each named variable.
  def assert_computes(expected, &block)
    interpreter = Reference.new.run(build_program(&block))
    expected.each do |name, want|
      assert_equal want, interpreter[name], "the interpreter's #{name}"
    end
    interpreter
  end

  # ...and then through the real console, which is where a lowering that took a
  # shortcut shows up. The console hands a variable back as a plain 32 bits, so it is
  # read as a signed number before the two are compared.
  def assert_both_backends_compute(expected, &block)
    assert_computes(expected, &block)

    program = build_program(&block)
    backend = GBA.new
    rom = ROM.assemble(backend.lower(program), title: "BITOPS", code: "BBIT", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 3, vars: backend.var_addresses)
    expected.each do |name, want|
      assert_equal want, Int32.wrap(v.var(name)), "the console's #{name}"
    end
  end
end
