# frozen_string_literal: true

require "test_helper"

# Dividing and wrapping by a number written into the program, where that number is not
# a power of two — `score / 10`, `frames / 60`, `hp * 100 / max`. The console has no
# divide instruction, so these used to trap into a BIOS routine every time; now the
# build works out a reciprocal and the console multiplies instead.
#
# Nothing about the DSL changes, so what these tests care about is that the ANSWERS are
# still exactly right — the whole trick rests on a rounded reciprocal being close enough
# for every numerator there is — and that the shortcut is really being taken.
class TestConstantDivision < Minitest::Test
  Reciprocal = RubyGBA::IR::Backends::GBA::Reciprocal
  Int32 = RubyGBA::IR::Int32

  # --- the reciprocal itself ---------------------------------------------------

  # The emitted sequence, instruction for instruction, in Ruby: multiply and keep the
  # high word, add the numerator back for the divisors that need it, shift, then nudge a
  # negative answer up to truncate toward zero.
  def apply(recipe, numerator)
    multiplier = Int32.wrap(recipe.multiplier)
    high = (multiplier * numerator) >> 32
    high = Int32.wrap(high + numerator) if recipe.add_numerator
    quotient = high >> recipe.shift
    Int32.wrap(quotient + ((quotient & 0xFFFF_FFFF) >> 31))
  end

  # Numerators worth trying for one divisor: the ends of the range, and both sides of
  # enough exact multiples that an off-by-one in the rounding cannot hide.
  def numerators(divisor)
    edges = [0, 1, -1, Int32::MIN, Int32::MAX, Int32::MIN + 1, Int32::MAX - 1]
    boundaries = (1..30).flat_map { |k| [(k * divisor) - 1, k * divisor, (k * divisor) + 1] }
    spread = Random.new(divisor).then { |r| Array.new(60) { r.rand(Int32::MIN..Int32::MAX) } }
    (edges + boundaries + boundaries.map(&:-@) + spread).uniq.select do |n|
      n.between?(Int32::MIN, Int32::MAX)
    end
  end

  # The claim the whole feature rests on: the reciprocal is not an approximation that is
  # usually right, it is exactly right for every numerator.
  def test_the_reciprocal_divides_exactly_for_every_numerator
    divisors = (2..120).to_a + [200, 1000, 3600, 60_000, 100_000, 1 << 30, Int32::MAX]
    checked = 0
    divisors.each do |divisor|
      recipe = Reciprocal.for(divisor)
      numerators(divisor).each do |n|
        checked += 1
        want = (n.abs / divisor) * (n.negative? ? -1 : 1) # truncating toward zero

        assert_equal want, apply(recipe, n), "#{n} / #{divisor}"
      end
    end
    assert_operator checked, :>, 20_000, "the sweep should be wide enough to mean something"
  end

  def test_a_divisor_below_two_has_no_reciprocal_to_find
    assert_raises(ArgumentError) { Reciprocal.for(1) }
    assert_raises(ArgumentError) { Reciprocal.for(0) }
    assert_raises(ArgumentError) { Reciprocal.for(-10) }
  end

  # --- the answers, on both backends -------------------------------------------

  DIVIDE_CASES = [
    [7, 3], [-7, 3], [7, -3], [-7, -3],          # every combination of signs
    [100, 10], [-100, 10], [99, 10], [-99, 10],  # the digit case
    [3599, 60], [-1, 60],                        # 60 needs the numerator added back
    [12_345, 1000], [Int32::MAX, 1_000_000], [Int32::MIN, 3],
    [50, 100], [-50, 100], [0, 7],               # answers of zero, both signs
    [7, -4], [-7, -4], [8, -4],                  # a negative power of two: shift, then flip
  ].freeze

  WRAP_CASES = [
    [7, 3], [-7, 3], [7, -3], [-7, -3], [9, 3], [-9, 3],
    [1234, 10], [-1234, 10], [61, 60], [-1, 60], [0, 7],
    [7, -4], [-7, -4], [8, -4], [-8, -4],        # a negative power of two: mask, then flip
  ].freeze

  # One program that works out every case, so the console runs them all in one boot.
  def sweep_program
    builder = Builder.new
    builder.instance_eval do
      screen :bitmap
      DIVIDE_CASES.each_with_index do |(n, d), i|
        var(:"q#{i}", 0).set(var(:"qn#{i}", n) / d)
      end
      WRAP_CASES.each_with_index do |(n, d), i|
        var(:"w#{i}", 0).set(var(:"wn#{i}", n) % d)
      end
      halt
    end
    builder.emit_pending_functions
    builder.program
  end

  def test_the_interpreter_gives_ruby_answers
    interpreter = Reference.new.run(sweep_program)
    DIVIDE_CASES.each_with_index do |(n, d), i|
      assert_equal (n.abs / d.abs) * ((n.negative? ^ d.negative?) ? -1 : 1),
                   interpreter[:"q#{i}"], "#{n} / #{d}"
    end
    WRAP_CASES.each_with_index do |(n, d), i|
      assert_equal n % d, interpreter[:"w#{i}"], "#{n} % #{d}"
    end
  end

  # The same program on the console, read back out of the memory the variables live in.
  # This is what proves the reciprocal survives contact with the real multiply — a wrong
  # rounding correction shows up here as one case out of thirty.
  def test_the_console_agrees_with_the_interpreter
    program = sweep_program
    backend = GBA.new
    rom = ROM.assemble(backend.lower(program), title: "RECIP", code: "BRCP", maker: "01")
    v = assert_gemba_loads_rom(rom, frames: 3, vars: backend.var_addresses)
    interpreter = Reference.new.run(program)

    DIVIDE_CASES.each_with_index do |(n, d), i|
      assert_equal interpreter[:"q#{i}"], console_var(v, :"q#{i}"), "#{n} / #{d} on the console"
    end
    WRAP_CASES.each_with_index do |(n, d), i|
      assert_equal interpreter[:"w#{i}"], console_var(v, :"w#{i}"), "#{n} % #{d} on the console"
    end
  end

  # --- the shortcut is actually taken ------------------------------------------

  # A variable read off the console, as a signed number. The bus hands back the raw
  # 32 bits, so a negative answer arrives as its unsigned pattern.
  def console_var(verifier, name)
    Int32.wrap(verifier.var(name))
  end

  def program_for(&block)
    builder = Builder.new
    builder.instance_eval(&block)
    builder.emit_pending_functions
    builder.program
  end

  def emitted_bytes(&block)
    RubyGBA::IR::Backends::GBA.new.lower(program_for(&block)).bytesize
  end

  # If the reduction silently stopped, every answer above would still be right, because
  # the BIOS routine computes the same thing. This is what notices.
  def test_a_constant_divisor_emits_less_than_one_the_game_works_out
    fixed = emitted_bytes do
      screen :bitmap
      n = var :n, 1000
      var(:out, 0).set(n / 100)
      halt
    end
    computed = emitted_bytes do
      screen :bitmap
      n = var :n, 1000
      d = var :d, 100
      var(:out, 0).set(n / d)
      halt
    end

    assert_operator fixed, :<, computed,
                    "a divide by a fixed number should multiply, not call the divide routine"
  end

  def test_a_constant_wrap_emits_less_than_one_the_game_works_out
    fixed = emitted_bytes do
      screen :bitmap
      n = var :n, 1000
      var(:out, 0).set(n % 100)
      halt
    end
    computed = emitted_bytes do
      screen :bitmap
      n = var :n, 1000
      d = var :d, 100
      var(:out, 0).set(n % d)
      halt
    end

    assert_operator fixed, :<, computed
  end

  # A divisor the game works out has no reciprocal to precompute, so it must still go to
  # the console's own routine — and that routine must still be reachable.
  def test_a_divisor_the_game_works_out_still_divides
    program = program_for do
      screen :bitmap
      d = var :d, 7
      var(:out, 0).set(var(:n, -100) / d)
      var(:left, 0).set(var(:m, -100) % d)
      halt
    end

    assert_equal(-14, Reference.new.run(program)[:out])
    assert_equal 5, Reference.new.run(program)[:left]

    backend = GBA.new
    rom = ROM.assemble(backend.lower(program), title: "RUNDIV", code: "BRDV", maker: "01")
    v = assert_gemba_loads_rom(rom, frames: 3, vars: backend.var_addresses)

    assert_equal(-14, console_var(v, :out))
    assert_equal 5, console_var(v, :left)
  end

  # Dividing by one has no reciprocal and nothing to gain, so it is left alone — and
  # left alone has to still mean right.
  def test_dividing_by_one_is_left_alone_and_still_correct
    program = program_for do
      screen :bitmap
      var(:out, 0).set(var(:n, -100) / 1)
      var(:back, 0).set(var(:m, -100) / -1)
      halt
    end
    interpreter = Reference.new.run(program)

    assert_equal(-100, interpreter[:out])
    assert_equal 100, interpreter[:back]

    backend = GBA.new
    rom = ROM.assemble(backend.lower(program), title: "DIVONE", code: "BDV1", maker: "01")
    v = assert_gemba_loads_rom(rom, frames: 3, vars: backend.var_addresses)

    assert_equal(-100, console_var(v, :out))
    assert_equal 100, console_var(v, :back)
  end
end
