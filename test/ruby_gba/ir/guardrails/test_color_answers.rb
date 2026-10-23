# frozen_string_literal: true

require "test_helper"

# A game built for a Game Boy Color hears, while it builds, what the Color does with what it asks
# for (Console::GBCFeatures): an error for what its hardware cannot do, and a warning for a row
# with more sprites than it draws. A game built for the Advance
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

  # A layer seen through by an amount written in the program is told to the console once, at boot,
  # so there is no step of the game's for it: only the layers' declaration says it.
  GHOST = RubyGBA.game("GHOST", consoles: %i[gba gbc]) do
    screen :tiled
    image(:ghost, "#" => :white) { "########\n" * 8 }
    layers :world, :ghosts
    layer(:ghosts, transparency: 40) { sprite :ghost, at: [40, 40] }
    game_loop { wait_vblank }
  end

  # Two backgrounds up together: the sky every screen shows, and the town in the scene that runs.
  # A second scene with a background of its own takes turns with the town, and is not refused.
  TWO_UP = RubyGBA.game("TWOUP", consoles: %i[gba gbc]) do
    screen :tiled
    image(:dark, "#" => :black) { "########\n" * 8 }
    tiles :floor, "#" => :dark
    background :sky, tiles: :floor, map: ["#" * 4] * 4
    var :state, 0
    scene(:town) { background :town, tiles: :floor, map: ["#" * 4] * 4 }
    game_loop { case_var(:state) { when_val 0, :town } }
  end

  TURNS = RubyGBA.game("TURNS", consoles: %i[gba gbc]) do
    screen :tiled
    image(:dark, "#" => :black) { "########\n" * 8 }
    tiles :floor, "#" => :dark
    state = var :state, 0
    scene(:town) { background :town, tiles: :floor, map: ["#" * 4] * 4 }
    scene(:cave) { background :cave, tiles: :floor, map: ["#" * 4] * 4 }
    game_loop do
      case_var :state do
        when_val 0, :town
        when_val 1, :cave
      end
      state.set! 1 - state
    end
  end

  private def findings(game, console) = CHECK.detect(game.program(console: console))

  def test_a_second_background_showing_at_once_is_refused_at_its_line
    found = findings(TWO_UP, :gbc)

    assert_equal [:error], found.map(&:severity)
    assert_match(/second background/, found.first.message)
    assert_equal :town, found.first.node.name
  end

  def test_backgrounds_that_take_turns_scene_by_scene_are_not_refused
    assert_empty findings(TURNS, :gbc)
    assert_empty findings(TWO_UP, :gba)
  end

  def test_a_layer_seen_through_by_a_fixed_amount_is_refused_in_plain_words
    found = findings(GHOST, :gbc)

    assert_equal [:error], found.map(&:severity)
    assert_match(/`transparency:`/, found.first.message)
  end

  # Nothing is shown differently on the Color: a turning screen, and the line that turns its
  # background, are each refused.
  def test_a_turning_screen_and_a_turned_background_are_refused
    found = findings(TURNING, :gbc)

    assert_equal %i[error error], found.map(&:severity)
    assert(found.any? { |finding| finding.message.include?("cannot turn or resize a background") })
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
    [TURNING, SHOULDERS, CROWDED, GHOST].each { |game| assert_empty findings(game, :gba) }
  end

  def test_a_color_build_stops_on_a_refusal
    error = assert_raises(RubyGBA::ROMError) do
      SHOULDERS.build_rom(console: :gbc, out: StringIO.new, err: StringIO.new, profile: false)
    end

    assert_match(/stopped/, error.message)
  end
end
