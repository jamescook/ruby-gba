# frozen_string_literal: true

require "test_helper"

# SAVING ON A SUPER NINTENDO CARTRIDGE. Its battery-backed RAM holds the same bytes the
# interpreter's IR::SaveImage holds, so a save made by either starts the game on the other, and a
# save survives the console going off: two runs handed the same image are a power cycle.
class TestSNESSaves < Minitest::Test
  SNES = VBlank::IR::Backends::SNES

  COUNTING_UP = VBlank.game("COUNT", consoles: %i[gba snes]) do
    best = save_var :best, 5
    game_loop { best.add! 2 }
  end

  # A record in save memory, written, read back and summed by the game itself.
  RECORDS = VBlank.game("RECORDS", consoles: %i[gba snes]) do
    score = var :score, 0
    loaded = var :loaded, 0
    files = save_data(:files) { keep score }
    game_loop do
      score.add! 3
      (score == 9).then { files[0].save }
      (score == 15).then do
        score.set! 0
        files[0].load
        loaded.set! score
      end
    end
  end

  # A saved number only read, so what it holds after a pass is what it started with.
  READING = VBlank.game("READING", consoles: %i[gba snes]) do
    best = save_var :best, 5
    seen = var :seen, 0
    game_loop { seen.set! best }
  end

  private def counting_up = COUNTING_UP.program(console: :snes)

  def test_a_game_started_with_empty_save_memory_reads_the_defaults
    run = SNES::CheckedRun.new(save: SaveImage.new).run(READING.program(console: :snes), frames: 1)

    assert_equal 5, run[:seen]
  end

  def test_a_save_var_comes_back_after_the_power_goes_off
    store = SaveImage.new
    SNES::CheckedRun.new(save: store).run(counting_up, frames: 3)

    again = SNES::CheckedRun.new(save: store).run(counting_up, frames: 2)

    assert_equal 15, again[:best], "three frames took it to 11, and two more from there"
  end

  def test_the_save_memory_a_run_leaves_is_the_interpreters_byte_for_byte
    interpreters = SaveImage.new
    Reference.new(save: interpreters).run(counting_up, frames: 3)

    cartridges = SaveImage.new
    SNES::HeadlessRun.new(save: cartridges).run(counting_up, frames: 3)

    assert_equal 11, cartridges.word(VBlank::IR::SaveLayout.save_var_at(0))
    assert_equal interpreters.to_sav, cartridges.to_sav
  end

  def test_a_save_the_interpreter_made_starts_the_cartridge
    store = SaveImage.new
    Reference.new(save: store).run(counting_up, frames: 3)

    assert_equal 13, SNES::HeadlessRun.new(save: store).run(counting_up, frames: 1)[:best]
  end

  def test_a_save_record_is_written_and_read_back_as_the_interpreter_does
    run = SNES::CheckedRun.new(save: SaveImage.new).run(RECORDS.program(console: :snes), frames: 8)

    assert_equal 9, run[:loaded]
  end

  def test_the_header_says_32k_of_battery_backed_ram
    rom = SNES.new.build(counting_up)

    assert_equal 0x02, rom.bytes.getbyte(0x7FD6), "ROM, RAM and a battery"
    assert_equal 5, rom.bytes.getbyte(0x7FD8), "2^5 kilobytes"
  end

  # The last word of the 32K is inside, a word one byte later is not, and neither is a place below
  # nought: the cartridge stops where the interpreter stops, in its words.
  def test_a_place_outside_the_32k_stops_the_game_as_the_interpreter_does
    build = VBlank::IR::Build
    inside = build.program(build.save_write(build.int(0x7FFC), build.int(7)),
                           build.set(:read, build.save_read(build.int(0x7FFC))), build.halt)
    assert_equal 7, SNES::CheckedRun.new.run(inside, frames: 1)[:read]

    [build.save_write(build.int(0x7FFD), build.int(7)), build.set(:read, build.save_read(build.int(-1)))].each do |step|
      outside = build.program(step, build.halt)
      expected = assert_raises(VBlank::IR::ProgramError) { Reference.new.run(outside, frames: 1) }
      error = assert_raises(VBlank::IR::ProgramError) { SNES::HeadlessRun.new.run(outside, frames: 1) }

      assert_equal expected.message, error.message
    end
  end

  def test_a_sum_of_save_memory_is_the_interpreters_checksum
    build = VBlank::IR::Build
    sums = build.program(build.save_write(build.int(0x7FFC), build.int(0x0102_03FF)),
                         build.set(:whole, build.save_sum(build.int(0x7FFC), build.int(4))),
                         build.set(:none, build.save_sum(build.int(0x7FFC), build.int(-5))),
                         # From far past the 32K, back to its end: no bytes, so nothing to stop for.
                         build.set(:from_far, build.save_sum(build.int(0x10000), build.int(-0x8000))), build.halt)

    run = SNES::CheckedRun.new.run(sums, frames: 1)

    assert_equal VBlank::IR::SaveLayout.checksum([0xFF, 0x03, 0x02, 0x01]), run[:whole]
    assert_equal 0, run[:none]
    assert_equal 0, run[:from_far]
  end

  def test_save_memory_other_than_32k_of_battery_is_refused_in_plain_words
    game = VBlank.game("FLASHY", consoles: %i[gba snes], save_memory: 128) do
      best = save_var :best, 5
      game_loop { best.add! 1 }
    end

    error = assert_raises(SNES::LoweringError) { SNES.new.build(game.program(console: :snes)) }

    assert_match(/32K of battery-backed RAM/, error.message)
  end

  # A Super FX cartridge's RAM is the chip's, and the painted screen takes most of it: a save there
  # is refused until the build keeps one beside it.
  def test_a_save_on_a_super_fx_cartridge_is_refused_in_plain_words
    game = VBlank.game("FXSAVE", consoles: %i[gba snes], variants: { snes: :superfx }) do
      best = save_var :best, 5
      game_loop { best.add! 1 }
    end

    error = assert_raises(SNES::LoweringError) { SNES.new.build(game.program(console: :snes)) }

    assert_match(/chip on its cartridge/, error.message)
  end
end
