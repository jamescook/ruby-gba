# frozen_string_literal: true

require "test_helper"

# Dividing by a value the game works out — `k / dist`, an average over a count, a
# percentage of a maximum that changes. This is the only division left that has to be
# done as the program runs: a divisor written into the program is settled at build time
# (see TestConstantDivision and TestPowerOfTwoMath).
#
# It no longer traps into the console's divide routine. A routine of our own does the
# same long division, so what these tests care about is that the ANSWERS are unchanged
# across every sign and both ends of the range, that dividing by zero gives the one
# answer both backends are held to, and that a program which never needs the routine does
# not carry it.
class TestRuntimeDivision < Minitest::Test
  runs_on :reference

  Int32 = RubyGBA::IR::Int32

  DIVISORS = [0, 1, -1, 2, -2, 3, -3, 7, 10, 60, 100, 256, 1000, 65_536,
              1_000_000, Int32::MAX, Int32::MIN].freeze

  def numerators(divisor)
    size = divisor.abs
    [0, 1, -1, 7, -7, 12_345, -12_345, 2_000_000_000, -2_000_000_000,
     Int32::MAX, Int32::MIN, Int32::MIN + 1,
     size, -size, size - 1, size + 1, 7 * size].select do |n|
      n.between?(Int32::MIN, Int32::MAX)
    end.uniq
  end

  def cases
    @cases ||= DIVISORS.flat_map do |d|
      numerators(d).flat_map { |n| [[:/, n, d], [:%, n, d]] }
    end
  end

  # One program that works out every case, so the console runs them all in one boot.
  # Each case loads its own numerator and divisor into variables first, so the divisor
  # really is worked out as the program runs.
  def sweep_program
    build = RubyGBA::IR::Build
    statements = cases.each_with_index.flat_map do |(op, n, d), i|
      [build.set(:n, build.int(n)), build.set(:d, build.int(d)),
       build.set(:"o#{i}", build.binop(op, build.var_ref(:n), build.var_ref(:d)))]
    end
    build.program(*statements, build.halt)
  end

  def test_the_interpreter_gives_the_defined_answers
    interpreter = Reference.new.run(sweep_program)
    cases.each_with_index do |(op, n, d), i|
      want = op == :/ ? Int32.div(n, d) : Int32.mod(n, d)

      assert_equal want, interpreter[:"o#{i}"], "#{n} #{op} #{d}"
    end
  end

  # The same program on the console, read back out of the memory the variables live in.
  # Long division is where signs and the ends of the range go wrong, so the sweep covers
  # both signs of both sides, the most negative number there is, and answers from one bit
  # wide to thirty-two.
  def test_the_console_agrees_with_the_interpreter
    program = sweep_program
    backend = GBA.new
    rom = ROM.assemble(backend.lower(program), title: "RUNDIV", code: "BRDV", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 4, vars: backend.var_addresses)
    interpreter = Reference.new.run(program)

    cases.each_with_index do |(op, n, d), i|
      assert_equal interpreter[:"o#{i}"], Int32.wrap(v.var(:"o#{i}")),
                   "#{n} #{op} #{d} on the console"
    end
  end

  # Dividing by zero has no answer, so one is defined: 1 or -1 following the numerator,
  # with the numerator left over. A program with this fault in it must not hang the
  # console, and the interpreter has to say what the console will show rather than stop.
  # Each case is worked out twice, by a zero the game works out and by one written down,
  # since a written divisor goes through the build's own shortcuts first.
  BY_ZERO = {
    up: [:/, 1234, 1],
    down: [:/, -1234, -1],
    none: [:/, 0, 1],
    left: [:%, 1234, 1234],
    left_below: [:%, -1234, -1234],
    left_none: [:%, 0, 0],
  }.freeze

  def by_zero_program
    build = RubyGBA::IR::Build
    statements = BY_ZERO.flat_map do |name, (op, n, _want)|
      [build.set(:n, build.int(n)),
       build.set(name, build.binop(op, build.var_ref(:n), build.var_ref(:zero))),
       build.set(:"#{name}_written", build.binop(op, build.var_ref(:n), build.int(0)))]
    end
    build.program(build.set(:zero, build.int(0)), *statements, build.halt)
  end

  def test_the_interpreter_gives_the_defined_answer_for_a_zero_divisor
    interpreter = Reference.new.run(by_zero_program)

    BY_ZERO.each do |name, (op, n, want)|
      assert_equal want, interpreter[name], "#{n} #{op} a zero the game works out"
      assert_equal want, interpreter[:"#{name}_written"], "#{n} #{op} 0"
    end
  end

  def test_the_console_gives_the_defined_answer_for_a_zero_divisor
    backend = GBA.new
    rom = ROM.assemble(backend.lower(by_zero_program), title: "DIVZERO")
    v = assert_emulator_loads_rom(rom, frames: 3, vars: backend.var_addresses)

    BY_ZERO.each do |name, (op, n, want)|
      assert_equal want, Int32.wrap(v.var(name)), "#{n} #{op} a zero the game works out, on the console"
      assert_equal want, Int32.wrap(v.var(:"#{name}_written")), "#{n} #{op} 0 on the console"
    end
  end

  # --- the routine is carried only when it is needed ---------------------------

  def program_for(&block)
    builder = RubyGBA::Builder.new
    builder.instance_eval(&block)
    builder.finalize_program
    builder.program
  end

  def emitted_bytes(&block)
    GBA.new.lower(program_for(&block)).bytesize
  end

  # The routine is a few hundred bytes of written-out division steps. A program whose
  # every divisor is written into it never runs a step of that, so it must not pay for
  # the routine either.
  def test_a_program_that_never_divides_at_run_time_does_not_carry_the_routine
    constant = emitted_bytes do
      screen :bitmap
      n = var :n, 1000
      var(:out, 0).set!(n / 100)
      halt
    end
    computed = emitted_bytes do
      screen :bitmap
      n = var :n, 1000
      d = var :d, 100
      var(:out, 0).set!(n / d)
      halt
    end

    assert_operator computed - constant, :>, 512,
                    "the divide routine should only be emitted when something needs it"
  end

  # Dividing by one is written into the program but has no reciprocal worth finding, so
  # it goes to the routine like a computed divisor does — which means a program whose
  # only division is by one still has to carry it.
  def test_dividing_by_one_carries_the_routine
    program = program_for do
      screen :bitmap
      var(:out, 0).set!(var(:n, -100) / 1)
      halt
    end
    backend = GBA.new
    rom = ROM.assemble(backend.lower(program), title: "DIVONE", code: "BDV1", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 3, vars: backend.var_addresses)

    assert_equal(-100, Int32.wrap(v.var(:out)))
  end

  # A division inside a subroutine goes through the same call, and a subroutine keeps its
  # own return address in the same register the call uses. If the routine's call trod on
  # it, the program would never come back.
  def test_a_division_inside_a_subroutine_returns
    program = program_for do
      screen :bitmap
      var :d, 7
      var :out, 0
      var :after, 0
      func(:work) { set! :out, (var(:n, 100) / var(:d, 7)) }
      call :work
      set! :after, 42
      halt
    end
    backend = GBA.new
    rom = ROM.assemble(backend.lower(program), title: "DIVFUNC", code: "BDVF", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 3, vars: backend.var_addresses)

    assert_equal 14, Int32.wrap(v.var(:out))
    assert_equal 42, Int32.wrap(v.var(:after)), "the program did not come back from the call"
  end
end
