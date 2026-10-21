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
    [3 * ONE, 0, 16],                  # divided by nought: a bare 1 or -1, not held at an end
    [-3 * ONE, 0, 16],
    [0, 0, 16],
    [160, 0, 32],
    [-160, 0, 32],
    [-7, 0, 0],
  ].freeze

  # One program that works out every case twice: once with both sides worked out as it
  # runs, and once with the numerator written into the program (which the build may widen
  # for itself). Both have to give the same answer.
  private def sweep_program
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
    v = assert_emulator_loads_rom(rom, frames: 4, vars: backend.var_addresses)

    CASES.each_with_index do |(a, b, bits), i|
      want = Int32.div_fix(a, b, bits)

      assert_equal want, Int32.wrap(v.var(:"run#{i}")), "(#{a} << #{bits}) / #{b} on the console"
      assert_equal want, Int32.wrap(v.var(:"fixed#{i}")),
                   "(#{a} << #{bits}) / #{b} on the console, numerator written down"
    end
  end

  # THE ROUTINE SKIPS STEPS IT CAN PROVE GIVE NOTHING, so every size of answer goes through a
  # different way in: answers just either side of each place it can skip to, numerators and
  # divisors of every width, and the two numbers whose sizes do not fit a signed number. Drawn
  # from a fixed seed, so a failure names a case that fails again.
  private def sweep_cases
    random = Random.new(1985)
    signed_of_width = ->(bits) { random.rand(1 << bits) * (random.rand(2).zero? ? 1 : -1) }
    drawn = Array.new(160) do
      [signed_of_width.call(random.rand(1..31)), signed_of_width.call(random.rand(1..31)),
       [0, 8, 16, 32].sample(random: random)]
    end
    edges = [8, 16, 24].flat_map do |answer_bits|
      [-1, 0, 1].map { |nudge| [((1 << answer_bits) + nudge) * 3, 3 << 16, 16] }
    end
    edges += [-1, 0, 1].map { |nudge| [ONE / 2 + nudge, ONE / 2, 16] } # a divisor below one, answers about one
    drawn + edges + [[Int32::MIN, Int32::MIN, 16], [Int32::MAX, Int32::MIN, 16], [1, Int32::MIN, 32],
                     [Int32::MIN, 3, 0], [Int32::MAX, Int32::MAX, 31], [0x7FFF_0000, 0x7FFF_0001, 32]]
  end

  def test_the_console_agrees_on_every_size_of_answer
    cases = sweep_cases
    program = Build.program(*cases.each_with_index.flat_map do |(a, b, bits), i|
      [Build.set(:a, Build.int(a)), Build.set(:b, Build.int(b)),
       Build.set(:"q#{i}", Build.div_fix(Build.var_ref(:a), Build.var_ref(:b), bits))]
    end, Build.halt)
    backend = GBA.new
    rom = ROM.assemble(backend.lower(program), title: "DIVSWEEP")
    v = assert_emulator_loads_rom(rom, frames: 4, vars: backend.var_addresses)

    cases.each_with_index do |(a, b, bits), i|
      assert_equal Int32.div_fix(a, b, bits), Int32.wrap(v.var(:"q#{i}")), "(#{a} << #{bits}) / #{b} on the console"
    end
  end

  # WHAT ONE FRACTION DIVIDE COSTS, in instructions the console ran: the same divide written
  # forty times a pass against twenty, and the difference shared out over the twenty added.
  # That counts reading the two numbers and keeping the answer as well as the routine.
  private def instructions_per_divide(numerator, divisor, title)
    per_frame = [20, 40].map do |count|
      program = program_for do
        screen :bitmap
        a = var :a, numerator
        b = var :b, divisor
        out = var :out, 0.0
        game_loop { count.times { out.set! a / b } }
      end
      backend = GBA.new
      rom = ROM.assemble(backend.lower(program), title: "#{title}#{count}", built: backend.build_record(program))
      result = RubyGBA::Diagnostics::Profiler.run(rom, frames: 20, picture: false)
      refute result.dropping_frames?, "forty divides ran over a frame, so the count means nothing"
      result.samples_per_frame
    end
    (per_frame.last - per_frame.first) / 20
  end

  # A STEP OF THE LONG DIVISION IS THREE INSTRUCTIONS, AND STEPS THAT CAN ONLY GIVE NOUGHT ARE
  # NOT RUN. An answer whose whole part needs fifteen bits runs every step, and the whole
  # divide, reading and keeping included, comes to under 140. An answer a little over a
  # hundred has nothing in its top eight bits and one below one nothing in its top sixteen, so
  # they skip eight steps and sixteen, three instructions each — whatever size the divisor is.
  def test_a_fraction_divide_runs_three_instructions_a_step_and_skips_what_gives_nothing
    require_emulator!
    every_step = instructions_per_divide(30_000.0, 1.0, "DIVALL")

    assert_operator every_step, :<=, 140
    assert_in_delta every_step - (8 * 3), instructions_per_divide(301.5, 3.0, "DIVBIG"), 1
    assert_in_delta every_step - (16 * 3), instructions_per_divide(1.0, 3.0, "DIVSMALL"), 1
    assert_in_delta every_step - (16 * 3), instructions_per_divide(0.25, 0.5, "DIVHALF"), 1,
                    "a divisor below one skips as much as any other"
  end

  # An answer too big to hold is held at the end of the range. 1.0 divided by the
  # smallest fraction there is wants sixty-five thousand times what a variable holds, and
  # of the two wrong answers available this is the one that still looks like a number.
  def test_an_answer_with_no_room_is_held_at_the_end_of_the_range
    assert_equal Int32::MAX, Int32.div_fix(ONE, 1, 16)
    assert_equal Int32::MIN, Int32.div_fix(-ONE, 1, 16)
    assert_equal Int32::MAX, Int32.div_fix(Int32::MIN, -1, 0), "the one overflow a plain divide has"
  end

  # Dividing by nought is NOT held at the end of the range the way dividing by nearly
  # nought is. It gives a bare 1 or -1 following the numerator, the same as a plain divide,
  # which a number holding a fraction reads as the smallest fraction there is. The sweep
  # above checks the console gives the same; a game that can reach this gives its divisor
  # a floor instead.
  def test_dividing_by_zero_gives_a_bare_one_rather_than_the_end_of_the_range
    assert_equal 1, Int32.div_fix(3 * ONE, 0, 16)
    assert_equal(-1, Int32.div_fix(-3 * ONE, 0, 16))
    refute_equal Int32::MAX, Int32.div_fix(ONE, 0, 16)
  end

  # ...AND WHAT BEING HELD THERE DOES NOT SURVIVE, which is the trap and is worth pinning because
  # a real game fell into it.
  #
  # Holding the answer at the end of the range is the safe half: a distance near nothing gives
  # the biggest number rather than a negative one. But the number is now AT the end of the range,
  # and one more step in the same direction has nowhere to go — an add wraps, because that is
  # what a signed 32-bit add does, and the answer comes back very negative.
  #
  # Where it bit: a first-person view sizes a wall column as one number over the distance and
  # rounds it to the nearest pixel — `(scale / seen + 0.5).to_i`. Stand near enough to a wall and
  # the divide saturates, the half tips it over, and the height goes negative. A negative height
  # draws nothing, so the wall vanishes and you see through it.
  #
  # Both backends do the same thing to the bit, which is what makes an oracle test of a game that
  # relies on this trustworthy.
  def test_rounding_an_answer_that_is_already_at_the_end_of_the_range_wraps_it
    half = ONE / 2

    assert_equal Int32::MAX, Int32.div_fix(ONE, 1, 16), "the divide is held at the top..."
    assert_operator Int32.add(Int32.div_fix(ONE, 1, 16), half), :<, 0,
                    "...and adding a half to the top of the range wraps it negative"
  end

  def test_the_console_wraps_it_the_same_way
    program = program_for do
      screen :bitmap
      tiny = var :tiny, 0.0
      rounded = var :rounded, 0
      game_loop do
        tiny.set! 0.001
        rounded.set!((227.9 / tiny + 0.5).to_i)
        halt
      end
    end
    backend = GBA.new
    rom = ROM.assemble(backend.lower(program), title: "SATRND", code: "ZSAT", maker: "01")
    console = RubyGBA::Diagnostics::Verifier.new(rom, frames: 4, vars: backend.var_addresses)

    assert_operator Reference.new.run(program)[:rounded], :<, 0, "the oracle wraps it negative"
    assert_equal Reference.new.run(program)[:rounded], Int32.wrap(console.var(:rounded)),
                 "and the console gives the same bits, so the oracle can speak for it"
  end

  # --- the surface ---------------------------------------------------------------

  private def program_for(&block)
    builder = RubyGBA::Builder.new
    builder.instance_eval(&block)
    builder.finalize_program
    builder.program
  end

  private def interpret(&block)
    Reference.new.run(program_for(&block))
  end

  def test_a_whole_number_can_be_divided_by_one_holding_a_fraction
    state = interpret do
      screen :bitmap
      dist = var :dist, 2.5
      var(:height, 0).set!((160 / dist).to_i)
      halt
    end

    assert_equal 64, state[:height]
  end

  def test_the_answer_of_a_whole_over_a_fraction_still_holds_a_fraction
    state = interpret do
      screen :bitmap
      dist = var :dist, 2.0
      var(:tenths, 0).set!(((90 / dist) * 10).to_i) # 45.0 -> 450
      halt
    end

    assert_equal 450, state[:tenths]
  end

  # --- the shortcut for a numerator written into the program ----------------------

  private def emitted_bytes(&block)
    GBA.new.lower(program_for(&block)).bytesize
  end

  # The widening routine is several hundred bytes of written-out division steps, and a
  # program that never divides one fraction by another must not carry it.
  def test_a_program_that_never_divides_a_fraction_does_not_carry_the_routine
    without = emitted_bytes do
      screen :bitmap
      dist = var :dist, 2.5
      var(:height, 0).set!((dist * 4).to_i)
      halt
    end
    with = emitted_bytes do
      screen :bitmap
      dist = var :dist, 2.5
      var(:height, 0).set!((160 / dist).to_i)
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
    small = routines_carried(Build.div_fix(Build.int(1000), Build.var_ref(:dist), 16))
    big = routines_carried(Build.div_fix(Build.int(160 * ONE), Build.var_ref(:dist), 16))

    # Both carry a routine — the folded one still divides by a value the game works out —
    # but only the one too big to widen while building carries the widening one.
    assert_includes small, GBA::Divide::ROUTINE
    refute_includes small, GBA::Divide::FIX_ROUTINE
    assert_includes big, GBA::Divide::FIX_ROUTINE
  end

  private def routines_carried(divide)
    backend = GBA.new
    backend.lower(Build.program(Build.set(:dist, Build.int(5 * ONE / 2)), Build.set(:out, divide), Build.halt))
    backend.routine_addresses.keys
  end
end
