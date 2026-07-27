# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require_relative "../lib/ruby_gba"
require_relative "test_helper"
require_relative "../examples/hero"

# The Hero example (examples/hero.rb): a follow-you camera — a hardware sprite
# pinned to the center of the screen while a world bigger than the screen scrolls
# under it as you walk. Proves the two features compose: the hero composites over
# the moving background, stays centered no matter how far you walk, and the world
# really slides (a pond landmark moves out from under its resting spot). Asserted on
# the interpreter oracle and on real hardware. The player never touches object
# memory, tile numbers, or a scroll register.
class TestHeroExample < Minitest::Test
  include RubyGBA::Constants
  include GembaSupport

  Ruby = RubyGBA::IR::Backends::Ruby
  Color = RubyGBA::Color

  CENTER = [120, 80].freeze # the middle of the screen, where the hero's body always sits

  # True if any pixel in the box reads blue, by whatever "is it blue here?" test the
  # caller supplies (interpreter framebuffer or gemba). Scanning a box (not one pixel)
  # keeps the "did the pond move?" checks robust to a frame of hardware timing slack.
  def blue_in?(xs, ys)
    xs.any? { |x| ys.any? { |y| yield(x, y) } }
  end

  def test_the_example_builds_clean
    rom = Hero.build_rom(err: StringIO.new)
    assert_operator rom.size, :>, 0, "the built ROM should be non-empty"
  end

  # At rest the camera sits at scroll (4, 4), so the pond (world px 80..) shows just
  # up-left of the centered hero. Walk right for 30 frames and the camera follows to
  # scroll (64, 4): the hero is STILL dead center, and the pond has slid ~60px left —
  # out of its old spot and onto the hero's left. The world moved, not the hero.
  def test_the_hero_stays_centered_while_the_world_scrolls
    blue = Color.resolve(:blue)
    red  = Color.resolve(:red)

    rest = Ruby.new.run(Hero.program, max_steps: 200).screen
    assert_equal red,  rest.pixel(*CENTER), "the hero sits centered on screen"
    assert_equal blue, rest.pixel(78, 78),  "at rest the pond landmark is just up-left of the hero"

    walked = Ruby.new.input_each_frame { |f| f <= 30 ? [:right] : [] }.run(Hero.program, max_steps: 600).screen
    assert_equal red,     walked.pixel(*CENTER), "the hero is STILL centered after walking — the world moved, not the hero"
    assert_equal blue,    walked.pixel(18, 78),  "the pond has slid left with the scrolling world"
    refute_equal blue,    walked.pixel(78, 78),  "and it left its old spot behind (no smear)"
  end

  # --- Hardware (gemba): the follow-cam really renders and scrolls ---

  def test_the_follow_cam_renders_on_the_console
    v = assert_gemba_loads_rom(Hero.build_rom(err: StringIO.new), frames: 6)
    assert v.red?(*CENTER),
           "the hero renders centered on hardware, got 0x#{format('%04X', v.pixel_gba(*CENTER))}"
    assert blue_in?(70..105, 72..92) { |x, y| v.blue?(x, y) },
           "the pond renders near the hero at rest"
  end

  def test_the_world_scrolls_under_the_hero_on_the_console
    v = assert_gemba_loads_rom(Hero.build_rom(err: StringIO.new), frames: 45,
                               keys: ->(f) { f <= 30 ? KEY_RIGHT : 0 })
    assert v.red?(*CENTER),
           "the hero is still centered after walking, got 0x#{format('%04X', v.pixel_gba(*CENTER))}"
    assert blue_in?(8..46, 72..92) { |x, y| v.blue?(x, y) },
           "the pond has scrolled to the hero's left as the world moved under it"
    refute blue_in?(70..105, 72..92) { |x, y| v.blue?(x, y) },
           "the pond has left its resting spot — the world really scrolled"
  end
end
