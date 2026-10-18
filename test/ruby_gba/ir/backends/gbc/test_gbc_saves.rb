# frozen_string_literal: true

require "test_helper"

# SAVING ON A GAME BOY COLOR CARTRIDGE. Its battery-backed memory holds the same bytes the
# interpreter's IR::SaveImage holds, so a save made by either starts the game on the other, and a
# save survives the console going off: two runs handed the same image are a power cycle.
class TestGBCSaves < Minitest::Test
  GBC = RubyGBA::IR::Backends::GBC

  COUNTING_UP = RubyGBA.game("COUNT", consoles: %i[gba gbc]) do
    best = save_var :best, 5
    game_loop { best.add! 2 }
  end

  # A record in save memory, written, read back and summed by the game itself.
  RECORDS = RubyGBA.game("RECORDS", consoles: %i[gba gbc]) do
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

  private def counting_up = COUNTING_UP.program(console: :gbc)

  def test_a_save_var_comes_back_after_the_power_goes_off
    store = SaveImage.new
    GBC::CheckedRun.new(save: store).run(counting_up, frames: 3)

    again = GBC::CheckedRun.new(save: store).run(counting_up, frames: 2)

    assert_equal 15, again[:best], "three frames took it to 11, and two more from there"
  end

  def test_the_save_memory_a_run_leaves_is_the_interpreters_byte_for_byte
    interpreters = SaveImage.new
    Reference.new(save: interpreters).run(counting_up, frames: 3)

    cartridges = SaveImage.new
    GBC::HeadlessRun.new(save: cartridges).run(counting_up, frames: 3)

    assert_equal 11, cartridges.word(RubyGBA::IR::SaveLayout.save_var_at(0))
    assert_equal interpreters.to_sav, cartridges.to_sav
  end

  def test_a_save_the_interpreter_made_starts_the_cartridge
    store = SaveImage.new
    Reference.new(save: store).run(counting_up, frames: 3)

    assert_equal 13, GBC::HeadlessRun.new(save: store).run(counting_up, frames: 1)[:best]
  end

  def test_a_save_record_is_written_and_read_back_as_the_interpreter_does
    run = GBC::CheckedRun.new(save: SaveImage.new).run(RECORDS.program(console: :gbc), frames: 8)

    assert_equal 9, run[:loaded]
  end

  def test_save_memory_other_than_32k_of_battery_is_refused_in_plain_words
    game = RubyGBA.game("FLASHY", consoles: %i[gba gbc], save_memory: 128) do
      best = save_var :best, 5
      game_loop { best.add! 1 }
    end

    error = assert_raises(GBC::LoweringError) { GBC.new.build(game.program(console: :gbc)) }

    assert_match(/32K of battery-backed memory/, error.message)
  end
end
