# frozen_string_literal: true

require "test_helper"

# Dividing numbers that hold a fraction — the perspective divide, a scale factor, a
# ratio. Two numbers multiplied up by the same amount divide that amount straight back
# out, so the numerator is widened before anything is divided (see IR::Int32.div_fix).
#
# What these tests care about: the answers keep their fraction and are exactly right on
# both backends, an answer with no room left is held at the end of the range rather than
# wrapped, and a numerator written into the program takes the cheap path without changing
# any of that.
class TestFractionDivision < Minitest::Test
  Int32 = RubyGBA::IR::Int32
  Build = RubyGBA::IR::Build

  ONE = 1 << 16

  CASES = [
    [3 * ONE, 3 * ONE / 2, 16],        # 3.0 / 1.5 = 2.0
    [3 * ONE, 2 * ONE, 16],            # 3.0 / 2.0 = 1.5 — the fraction has to survive
    [-3 * ONE, 3 * ONE / 2, 16],       # every combination of signs
    [3 * ONE, -3 * ONE / 2, 16],
    [-3 * ONE, -3 * ONE / 2, 16],
    [ONE, 4 * ONE, 16],                # an answer below one
    [ONE / 4, ONE / 2, 16],            # both sides below one
    [100 * ONE, 3 * ONE, 16],          # an answer that does not come out even
    [ONE, 1, 16],                      # divided by the smallest fraction there is
    [-ONE, 1, 16],                     # ...and the same going the other way
    [Int32::MAX, 2 * ONE, 16],
    [Int32::MIN, 2 * ONE, 16],
    [160, 5 * ONE / 2, 32],            # a whole number over a fraction: 160 / 2.5
    [-160, 5 * ONE / 2, 32],
    [7, 3, 0],                         # no widening at all is an ordinary division
    [-7, 3, 0],
  ].freeze

  # One program that works out every case twice: once with both sides worked out as it
  # runs, and once with the numerator written into the program (which the build may widen
  # for itself). Both have to give the same answer.
  def sweep_program
    statements = CASES.each_with_index.flat_map do |(a, b, bits), i|
      [Build.set(:a, Build.int(a)), Build.set(:b, Build.int(b)),
       Build.set(:"run#{i}", Build.div_fix(Build.var_ref(:a), Build.var_ref(:b), bits)),
       Build.set(:"fixed#{i}", Build.div_fix(Build.int(a), Build.var_ref(:b), bits))]
    end
    Build.program(*statements, Build.halt)
  end

  def test_the_interpreter_gives_the_defined_answers
    interpreter = Reference.new.run(sweep_program)
    CASES.each_with_index do |(a, b, bits), i|
      want = Int32.div_fix(a, b, bits)

      assert_equal want, interpreter[:"run#{i}"], "(#{a} << #{bits}) / #{b}"
      assert_equal want, interpreter[:"fixed#{i}"], "(#{a} << #{bits}) / #{b}, numerator written down"
    end
  end

  def test_the_console_agrees_with_the_interpreter
    program = sweep_program
    backend = GBA.new
    rom = ROM.assemble(backend.lower(program), title: "DIVFIX", code: "BDFX", maker: "01")
    v = assert_gemba_loads_rom(rom, frames: 4, vars: backend.var_addresses)

    CASES.each_with_index do |(a, b, bits), i|
      want = Int32.div_fix(a, b, bits)

      assert_equal want, Int32.wrap(v.var(:"run#{i}")), "(#{a} << #{bits}) / #{b} on the console"
      assert_equal want, Int32.wrap(v.var(:"fixed#{i}")),
                   "(#{a} << #{bits}) / #{b} on the console, numerator written down"
    end
  end

  # An answer too big to hold is held at the end of the range. 1.0 divided by the
  # smallest fraction there is wants sixty-five thousand times what a variable holds, and
  # of the two wrong answers available this is the one that still looks like a number.
  def test_an_answer_with_no_room_is_held_at_the_end_of_the_range
    assert_equal Int32::MAX, Int32.div_fix(ONE, 1, 16)
    assert_equal Int32::MIN, Int32.div_fix(-ONE, 1, 16)
    assert_equal Int32::MAX, Int32.div_fix(Int32::MIN, -1, 0), "the one overflow a plain divide has"
  end

  # --- the surface ---------------------------------------------------------------

  def program_for(&block)
    builder = RubyGBA::Builder.new
    builder.instance_eval(&block)
    builder.emit_pending_functions
    builder.program
  end

  def interpret(&block)
    Reference.new.run(program_for(&block))
  end

  def test_a_whole_number_can_be_divided_by_one_holding_a_fraction
    state = interpret do
      screen :bitmap
      dist = var :dist, 2.5
      var(:height, 0).set((160 / dist).to_i)
      halt
    end

    assert_equal 64, state[:height]
  end

  def test_the_answer_of_a_whole_over_a_fraction_still_holds_a_fraction
    state = interpret do
      screen :bitmap
      dist = var :dist, 2.0
      var(:tenths, 0).set(((90 / dist) * 10).to_i) # 45.0 -> 450
      halt
    end

    assert_equal 450, state[:tenths]
  end

  # --- the shortcut for a numerator written into the program ----------------------

  def emitted_bytes(&block)
    GBA.new.lower(program_for(&block)).bytesize
  end

  # The widening routine is several hundred bytes of written-out division steps, and a
  # program that never divides one fraction by another must not carry it.
  def test_a_program_that_never_divides_a_fraction_does_not_carry_the_routine
    without = emitted_bytes do
      screen :bitmap
      dist = var :dist, 2.5
      var(:height, 0).set((dist * 4).to_i)
      halt
    end
    with = emitted_bytes do
      screen :bitmap
      dist = var :dist, 2.5
      var(:height, 0).set((160 / dist).to_i)
      halt
    end

    assert_operator with - without, :>, 512,
                    "the widening routine should only be emitted when something needs it"
  end

  # A numerator small enough to widen while building takes the ordinary division path
  # instead. That is a narrow window — widening by sixteen places only leaves room for a
  # numerator under 32768, which in sixteen fraction bits is a value below one half — so
  # this is the exception rather than the shape to design around.
  def test_a_small_enough_numerator_written_down_skips_the_routine
    small = GBA.new.lower(Build.program(
                            Build.set(:dist, Build.int(5 * ONE / 2)),
                            Build.set(:out, Build.div_fix(Build.int(1000), Build.var_ref(:dist), 16)),
                            Build.halt,
                          )).bytesize
    big = GBA.new.lower(Build.program(
                          Build.set(:dist, Build.int(5 * ONE / 2)),
                          Build.set(:out, Build.div_fix(Build.int(160 * ONE), Build.var_ref(:dist), 16)),
                          Build.halt,
                        )).bytesize

    # Both carry a routine — the folded one still divides by a value the game works out —
    # but the widening one is the bigger of the two by a few hundred bytes.
    assert_operator big - small, :>, 256
  end
end
