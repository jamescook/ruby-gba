# frozen_string_literal: true

require_relative "test_helper"

# The wiring: a game living outside the framework can require ruby-gba, build a program, run it
# on the interpreter, and lower it to a real cartridge. Everything after this assumes that works.
class TestWolf3DBuilds < Minitest::Test
  include Wolf3DTest

  # The console reads a cartridge's name out of a fixed place in the header, which is stamped
  # last — so reading it back also proves the build ran to completion. True whether or not a
  # copy of the game is here to build from.
  def test_the_game_lowers_to_a_valid_cartridge
    rom = Wolf3D.build_rom(out: StringIO.new, err: StringIO.new)
    stamped = rom.buffer[RubyGBA::ROM::HEADER_TITLE, RubyGBA::ROM::TITLE_LENGTH].delete("\x00")

    assert_predicate rom.size, :positive?
    assert_equal Wolf3D::TITLE, stamped
  end
end

# The holding screen on its own, in a program of its own. It used to be tested through the whole
# game, which quietly stopped working the moment the game had data to draw instead.
class TestTitleScreen < Minitest::Test
  include Wolf3DTest

  def program
    RubyGBA.game("TITLE", code: "ATTL", maker: "01") do
      screen :bitmap
      screen_title = Wolf3D::Title.new(self)
      game_loop { screen_title.update }
    end.program
  end

  def test_it_draws_its_lettering
    run = Reference.new.run(program, frames: 2)

    lit = (0...240).sum { |x| (40...80).count { |y| run.screen.pixel(x, y) != run.screen.pixel(0, 0) } }
    assert_operator lit, :>, 100, "expected the title lettering to be drawn"
  end

  # A blinking prompt means the frame loop is running, not that the screen was painted once.
  def test_the_prompt_blinks
    interpreter = Reference.new
    early = prompt_pixels(interpreter.run(program, frames: 2))
    later = prompt_pixels(interpreter.run(program, frames: 70))

    assert_operator early, :>, 0, "expected the prompt to be showing early in the cycle"
    assert_equal 0, later, "expected the prompt to be dark later in the cycle"
  end

  private

  def prompt_pixels(run)
    background = run.screen.pixel(0, 0)
    (0...240).sum { |x| (100...112).count { |y| run.screen.pixel(x, y) != background } }
  end
end
