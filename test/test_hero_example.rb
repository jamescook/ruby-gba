# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require_relative "../lib/ruby_gba"
require_relative "test_helper"
require_relative "../examples/hero"

# The Hero example (examples/hero.rb): a hardware sprite you walk around a tiled
# room with the d-pad — the "character on a background" that most console games
# are. Proves the sprite composites over the room, moves under input, and leaves no
# trail — on the interpreter oracle and on real hardware. The player never touches
# object memory, tile numbers, or the sprite table.
class TestHeroExample < Minitest::Test
  include RubyGBA::Constants
  include GembaSupport

  Ruby = RubyGBA::IR::Backends::Ruby
  Color = RubyGBA::Color

  START = [116, 76].freeze # where the hero begins (its body covers 116..123 x 76..83)
  FLOOR = Color.rgb(4, 4, 7) # the floor tile's color at the start cell

  # Once the hero walks into the bottom-right corner it clamps at (224, 144), so its
  # resting spot is deterministic no matter where the headless run is cut off — a
  # solid red body pixel lands at (228, 147).
  CORNER_BODY = [228, 147].freeze

  def test_the_example_builds_clean
    rom = Hero.build_rom(err: StringIO.new)
    assert_operator rom.size, :>, 0, "the built ROM should be non-empty"
  end

  # Hold right+down and the hero walks to the corner and stays. The corner shows the
  # hero; the start cell shows floor again — the moving sprite left no trail.
  def test_the_hero_walks_and_leaves_no_trail
    screen = Ruby.new.input_each_frame { %i[right down] }.run(Hero.program, max_steps: 40_000).screen
    assert_equal Color.resolve(:red), screen.pixel(*CORNER_BODY), "the hero rests where it walked"
    assert_equal FLOOR, screen.pixel(*START), "the start cell shows floor again — no trail"
  end

  # --- Hardware (gemba): it really renders and moves ---

  def test_the_hero_renders_and_walks_on_the_console
    v = assert_gemba_loads_rom(Hero.build_rom(err: StringIO.new), frames: 64, keys: KEY_RIGHT | KEY_DOWN)
    assert v.red?(*CORNER_BODY),
           "the hero should walk to the corner, got 0x#{format('%04X', v.pixel_gba(*CORNER_BODY))}"
    assert v.pixel_is?(*START, FLOOR),
           "the start cell should show floor, got 0x#{format('%04X', v.pixel_gba(*START))}"
  end
end
