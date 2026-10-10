# frozen_string_literal: true

require "test_helper"

# A TEST WRITES A save_var's NUMBER INTO SAVE MEMORY, so a game starts with a high score it
# chose rather than being played until it reaches one. The game's own code writes it, so the
# game reads it back as its own.
class TestSaveVarsInto < Minitest::Test
  # A best score and a count of games played, both kept through power-off. A raises the best
  # to 50.
  private def scores_game(save_memory: nil)
    block = proc do
      screen :bitmap
      best = save_var :best, 10
      save_var :played, 0
      game_loop { pressed(:a).then { best.set! 50 } }
    end
    save_memory ? RubyGBA.game("SAVEVARS", save_memory: save_memory, &block) : RubyGBA.game("SAVEVARS", &block)
  end

  private def scores(save_memory: nil) = scores_game(save_memory: save_memory).program

  private def boot(program, image, pressing: {}, frames: 3)
    Reference.new(save: image).input_each_frame { |f| Array(pressing[f]) }.run(program, frames: frames)
  end

  def test_the_game_starts_with_a_written_save_var
    image = Reference.save_vars_into(SaveImage.new, scores, best: 9999)
    run = boot(scores, image)

    assert_equal 9999, run[:best]
    assert_equal 0, run[:played], "a save_var the test leaves out starts at its default"
  end

  # On flash the save_vars are kept together and saved a pass after one changes; the written
  # number is in save memory when the call returns all the same.
  def test_flash_takes_a_written_save_var
    image = Reference.save_vars_into(SaveImage.new, scores(save_memory: 64), best: 9999, played: 4)
    run = boot(scores(save_memory: 64), image)

    assert_equal 9999, run[:best]
    assert_equal 4, run[:played]
  end

  # The game saves over a written number as it would over its own: A raises the best, and
  # the next power-on starts with that.
  def test_the_game_saves_over_a_written_save_var
    [nil, 64].each do |memory|
      program = scores(save_memory: memory)
      image = Reference.save_vars_into(SaveImage.new, program, best: 9999)
      boot(program, image, pressing: { 1 => :a }, frames: 400)

      assert_equal 50, boot(program, image)[:best], "save memory #{memory || 32}K"
    end
  end

  # --- the console starts from a written save_var too ---

  private def console_best(save_memory: nil)
    game = scores_game(save_memory: save_memory)
    rom = game.build_rom(out: nil, err: nil, profile: false)
    [1234, 9999].map do |best|
      image = Reference.save_vars_into(SaveImage.new, game.program, best: best, played: 7)
      v = assert_emulator_loads_rom(rom, frames: 6, save: image, vars: rom.var_addresses)
      [v.var(:best), v.var(:played)]
    end
  end

  def test_the_console_starts_from_a_written_save_var
    assert_equal [[1234, 7], [9999, 7]], console_best
  end

  def test_the_console_starts_from_a_written_save_var_on_flash
    assert_equal [[1234, 7], [9999, 7]], console_best(save_memory: 64)
  end

  # --- what a test cannot write ---

  def test_a_name_that_is_not_a_save_var
    [nil, 64].each do |memory|
      err = assert_raises(ArgumentError) { Reference.save_vars_into(SaveImage.new, scores(save_memory: memory), bset: 5) }
      assert_match(/:bset/, err.message)
      assert_match(/are :best, :played\./, err.message, "save memory #{memory || 32}K")
    end
  end

  def test_a_program_with_no_save_var
    program = RubyGBA.game("NOSAVES") { screen :bitmap; var :best, 0; game_loop { wait_vblank } }.program
    err = assert_raises(ArgumentError) { Reference.save_vars_into(SaveImage.new, program, best: 5) }
    assert_match(/no save_var/, err.message)
  end

  def test_a_save_var_holds_a_whole_number
    err = assert_raises(ArgumentError) { Reference.save_vars_into(SaveImage.new, scores, best: 9.5) }
    assert_match(/whole number/, err.message)
  end
end
