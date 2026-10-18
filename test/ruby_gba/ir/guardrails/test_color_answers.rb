# frozen_string_literal: true

require "test_helper"

# A game built for a Game Boy Color hears, while it builds, what the Color does with what it asks
# for (Console::GBCFeatures): a warning for what is shown differently there, an error for what it
# cannot do, and a warning for a row with more sprites than it draws. A game built for the Advance
# hears none of it.
class TestColorAnswers < Minitest::Test
  CHECK = RubyGBA::IR::Guardrails::Checks::ColorAnswers.new

  TURNING = RubyGBA.game("TURNING", consoles: %i[gba gbc]) do
    screen :rotozoom
    image(:dark, "#" => :black) { "########\n" * 8 }
    tiles :floor, "#" => :dark
    board = background :board, tiles: :floor, map: ["#" * 4] * 4
    game_loop { board.rotate 30 }
  end

  SHOULDERS = RubyGBA.game("SHOULDERS", consoles: %i[gba gbc]) do
    count = var :count, 0
    game_loop { held(:l).then { count.add! 1 } }
  end

  CROWDED = RubyGBA.game("CROWDED", consoles: %i[gba gbc]) do
    screen :tiled
    draw_text "ABCDEFGHIJKL", 4, 20, :white
    game_loop { wait_vblank }
  end

  private def findings(game, console) = CHECK.detect(game.program(console: console))

  def test_a_turning_screen_and_background_are_warned_of_once_each
    found = findings(TURNING, :gbc)

    assert_equal %i[warning warning], found.map(&:severity)
    assert(found.any? { |finding| finding.message.include?("shown as it was drawn") })
  end

  def test_a_shoulder_button_is_refused_in_plain_words
    found = findings(SHOULDERS, :gbc)

    assert_equal [:error], found.map(&:severity)
    assert_match(/:l button/, found.first.message)
    assert_match(/no shoulder buttons/, found.first.message)
  end

  def test_a_row_of_more_than_ten_sprites_is_named
    found = findings(CROWDED, :gbc)

    assert_equal [:warning], found.map(&:severity)
    assert_match(/row 20/, found.first.message)
    assert_match(/ten on any one row/, found.first.message)
  end

  def test_the_advances_build_hears_nothing
    [TURNING, SHOULDERS, CROWDED].each { |game| assert_empty findings(game, :gba) }
  end

  def test_a_color_build_stops_on_a_refusal
    error = assert_raises(RubyGBA::ROMError) do
      SHOULDERS.build_rom(console: :gbc, out: StringIO.new, err: StringIO.new, profile: false)
    end

    assert_match(/stopped/, error.message)
  end
end
