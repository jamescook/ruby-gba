# frozen_string_literal: true

require "test_helper"

# THE COLOR'S CLOCK CHIP, as only its cartridge can be asked: one that has counted hundreds of
# days, or holds a time no clock can say, is nothing the interpreter has a word for.
#
# The chip counts 511 days, then sets a carry bit and starts again from nought. A game that sets
# the clock keeps how far its time is from the chip's count in its save, so once the chip has
# counted 256 days the cartridge moves them out of the chip and into that offset — the chip
# written back by the protocol a real one wants — and the time the game reads does not move.
class TestGBCClock < Minitest::Test
  HeadlessRun = RubyGBA::IR::Backends::GBC::HeadlessRun
  CHIP = Time.new(2026, 10, 22, 21, 7, 5)
  DATE = %i[year month day hour minute].freeze

  # A game that sets the clock to noon on the 15th of June 2030 on a pass that A is pressed on,
  # and keeps the date it reads and its two answers.
  private def program
    b = Builder.new
    b.instance_eval do
      now = clock
      readings = DATE.to_h { |name| [name, var(name, -1)] }
      present = var :present, -1
      set = var :set, -1
      game_loop do
        pressed(:a).then { now.set_to(year: 2030, month: 6, day: 15, hour: 12, minute: 0, second: 0) }
        readings.each { |name, reading| reading.set! now.public_send(name) }
        present.set! 0
        now.present?.then { present.set! 1 }
        set.set! 0
        now.set?.then { set.set! 1 }
      end
    end
    b.finalize_program
    b.program
  end

  private def played(save, days: 0, press: nil, counters: nil)
    run = HeadlessRun.new(save: save).clock_at(CHIP, days: days, counters: counters)
    run.input_each_frame { |frame| frame == press ? [:a] : [] }
    run.run(program, frames: 3)
  end

  def test_a_chip_past_256_days_is_folded_into_the_time_the_game_keeps
    save = RubyGBA::IR::SaveImage.new
    set = played(save, press: 1)
    folded = played(save, days: 300)
    after = played(save, days: 44)

    assert_equal [2030, 6, 15, 12, 0], DATE.map { |name| set[name] }
    assert_equal [2031, 4, 11, 12, 0], DATE.map { |name| folded[name] }, "300 days on, read through the fold"
    assert_equal set[:__clock_offset_days] + 256, folded[:__clock_offset_days]
    assert_equal [2031, 4, 11, 12, 0], DATE.map { |name| after[name] }, "a chip at 44 days reads as the folded one did"
  end

  # A real chip whose battery ran out and was put back can hold a second and an hour no clock can
  # say. It is there all the same, started again halted, so it reads as not set; the game can set
  # it, and it counts from there.
  def test_a_chip_holding_a_time_no_clock_can_say_is_started_again_and_can_be_set
    junk = [62, 5, 30, 0x10, 0] # 62 seconds, 30 hours, 16 days
    before = played(RubyGBA::IR::SaveImage.new, counters: junk)
    after = played(RubyGBA::IR::SaveImage.new, counters: junk, press: 1)

    assert_equal [1, 0, 0], [before[:present], before[:set], before[:year]]
    assert_equal [1, 1], [after[:present], after[:set]]
    assert_equal [2030, 6, 15, 12, 0], DATE.map { |name| after[name] }
  end

  # A chip that counts and was never set by the game has no date to give: it reads as not set.
  def test_a_counting_chip_the_game_never_set_reads_as_not_set
    run = played(RubyGBA::IR::SaveImage.new)

    assert_equal [1, 0, 0], [run[:present], run[:set], run[:hour]]
  end
end
