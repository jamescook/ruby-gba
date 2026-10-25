# frozen_string_literal: true

require "test_helper"

require "stringio"

# THE CARTRIDGE READS ITS CLOCK CHIP. A cartridge that carries a clock has a small chip with a
# watch battery of its own, reached through three of four pins the cartridge brings out: the
# console clocks a command into it a bit at a time and clocks the date and time back out the same
# way. The cartridge reads it after each wait for the screen, and the game reads that copy.
#
# The emulator gives a cartridge a clock only when told (RubyGBAEmulator::Probe#clock_at), pinned
# to a moment and moved on a console frame each frame, so what these read is the same every run —
# and the same as the interpreter reads, started at the same moment.
class TestClockChip < Minitest::Test
  include EmulatorSupport

  READINGS = (RubyGBA::IR::Clock::TIME + RubyGBA::IR::Clock::QUESTIONS).freeze
  THURSDAY = Time.new(2026, 10, 22, 21, 7, 5)

  def setup
    require_emulator!
  end

  # A game that keeps every reading of the clock in a variable of the same name, every pass.
  private def rom
    RubyGBA.build("CLOCK", out: StringIO.new, err: StringIO.new, profile: false) do
      screen :bitmap
      now = clock
      kept = READINGS.to_h { |name| [name, var(name, -1)] }
      game_loop do
        kept.each do |name, reading|
          case name
          when :present then reading.set! 0; now.present?.then { reading.set! 1 }
          when :set then reading.set! 0; now.set?.then { reading.set! 1 }
          else reading.set! now.public_send(name)
          end
        end
      end
    end
  end

  private def console_readings(verifier) = READINGS.to_h { |name| [name, verifier.var(name)] }

  private def console_of(**how)
    built = rom
    RubyGBA::Diagnostics::Verifier.new(built, vars: built.built.var_addresses, **how)
  end

  def test_the_cartridge_reads_the_clock_chip
    v = console_of(frames: 10, clock: THURSDAY)

    assert_equal({ hour: 21, minute: 7, second: 5, year: 2026, month: 10, day: 22, weekday: 4, present: 1, set: 1 },
                 console_readings(v))
  end

  # A CHIP WHOSE BATTERY RAN OUT: there, never set, and every reading 0. It starts counting the
  # hours 1 to 12, as such a chip does, so this is also where the cartridge telling it to count in
  # 24 hours is held to working — the chip says it is there only once that has been done.
  def test_a_chip_whose_battery_ran_out_is_there_and_not_set
    v = console_of(frames: 10, clock: THURSDAY, clock_set: false)

    assert_equal READINGS.to_h { |name| [name, name == :present ? 1 : 0] }, console_readings(v)
  end

  def test_a_cartridge_with_no_clock_chip_is_told_so
    v = console_of(frames: 10)

    assert_equal READINGS.to_h { |name| [name, 0] }, console_readings(v)
  end

  # FRAME BY FRAME THE SAME AS THE INTERPRETER, through midnight on new year's eve: the cartridge's
  # readings pass after pass are the interpreter's, from the pass where the console's start-up
  # frames have gone by. Started half a second before the second turns, so neither run reads a
  # second turn over within the frames the console spends starting up.
  def test_the_cartridge_reads_what_the_interpreter_reads_into_the_new_year
    start = Time.new(2026, 12, 31, 23, 59, Rational(585, 10))
    interpreted = []
    player = Reference.new.clock_at(start)
    player.each_vblank { interpreted << READINGS.to_h { |name| [name, player[name]] } }
    player.run(rom.built.source_program, frames: 150)

    v = console_of(frames: 1, clock: start)
    console = [console_readings(v)] + Array.new(152) { console_readings(v.step) }
    # The chip and the console's frames both start counting at power-on, and so do the interpreter's
    # clock and its frames, so the two line up with no frames between them.
    same = console.first(interpreted.size) == interpreted

    assert same, "the cartridge's readings, pass by pass, are the interpreter's: " \
                 "#{console.map { |r| r.values_at(:minute, :second) }.uniq.inspect} against " \
                 "#{interpreted.map { |r| r.values_at(:minute, :second) }.uniq.inspect}"
    assert_equal 2027, interpreted.last[:year], "the run reaches the new year"
  end

  # A GAME THAT SETS THE CLOCK, on its third pass: the cartridge keeps the time set from the chip's
  # count, as Pokemon Emerald does, and never writes the chip. On a chip that was set and on one
  # whose battery ran out, it reads what the interpreter reads.
  private def setting_rom
    RubyGBA.build("CLOCKSET", out: StringIO.new, err: StringIO.new, profile: false) do
      screen :bitmap
      now = clock
      passes = var :passes, 0
      kept = READINGS.to_h { |name| [name, var(name, -1)] }
      game_loop do
        passes.add! 1
        (passes == 3).then { now.set!(year: 2030, month: 6, day: 15, hour: 12, minute: 30, second: 0) }
        kept.each do |name, reading|
          case name
          when :present then reading.set! 0; now.present?.then { reading.set! 1 }
          when :set then reading.set! 0; now.set?.then { reading.set! 1 }
          else reading.set! now.public_send(name)
          end
        end
      end
    end
  end

  def test_a_game_that_sets_the_clock_reads_on_the_cartridge_what_the_interpreter_reads
    built = setting_rom
    [true, false].each do |chip_set|
      player = Reference.new.clock_at(THURSDAY, set: chip_set)
      player.run(built.built.source_program, frames: 10)
      v = RubyGBA::Diagnostics::Verifier.new(built, vars: built.built.var_addresses, frames: 10, clock: THURSDAY,
                                                    clock_set: chip_set)

      assert_equal READINGS.to_h { |name| [name, player[name]] }, console_readings(v), "the chip set: #{chip_set}"
      assert_equal 2030, v.var(:year), "the time set is read (chip set: #{chip_set})"
    end
  end

  # WHAT READING THE CHIP COSTS A PASS: a command of eight bits out, seven bytes of eight back,
  # each bit a few writes to the pins and a read, and each byte's two digits made a number. That
  # comes to about a thousand instructions, a few of a frame's lines run from the cartridge — and
  # once a pass however many readings the game makes.
  MOST_A_PASS = 1200

  def test_reading_the_chip_costs_about_a_thousand_instructions_a_pass
    result = RubyGBA::Diagnostics::Profiler.run(rom, frames: 30, picture: false, clock: THURSDAY)
    chip = %i[each_pass send receive].sum do |part|
      RubyGBA::Diagnostics::Profiler.work_in(result).fetch(:"__clock_chip_#{part}", 0)
    end

    assert_operator chip, :>, 0, "the chip is read"
    assert_operator chip, :<, MOST_A_PASS, "reading the chip costs #{chip} instructions a pass"
  end
end
