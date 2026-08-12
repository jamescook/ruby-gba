# frozen_string_literal: true

require "test_helper"

require "stringio"
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

    rest = Reference.new.run(Hero.program, max_steps: 200).screen
    assert_equal red,  rest.pixel(*CENTER), "the hero sits centered on screen"
    assert_equal blue, rest.pixel(78, 78),  "at rest the pond landmark is just up-left of the hero"

    walked = Reference.new.input_each_frame { |f| f <= 30 ? [:right] : [] }.run(Hero.program, max_steps: 600).screen
    assert_equal red,     walked.pixel(*CENTER), "the hero is STILL centered after walking — the world moved, not the hero"
    assert_equal blue,    walked.pixel(18, 78),  "the pond has slid left with the scrolling world"
    refute_equal blue,    walked.pixel(78, 78),  "and it left its old spot behind (no smear)"
  end

  # --- The weather: mist that thickens as you walk north ---
  #
  # Two things at once, and the second is what makes the first mean anything. The mist is
  # a background declared IN FRONT of the hero, so it washes out the hero as well as the
  # world — the one arrangement a picture cannot fall into by accident. And how see-
  # through it is, is not a number in the program: it is `100 - mist`, worked out afresh
  # every frame from how far north the player has walked.

  # Walk one way for a while, then read the pixel the hero's body sits on.
  def after_walking(direction, frames)
    Reference.new
             .input_each_frame { |f| f <= frames ? [direction] : [] }
             .run(Hero.program, frames: frames + 1).screen.pixel(*CENTER)
  end

  # Mixing red toward white raises every channel, so a whiter pixel is a bigger number —
  # which makes "thicker than" something the test can say without naming a blend.
  def test_walking_north_draws_the_mist_over_the_hero
    assert_equal Color.resolve(:red), after_walking(:right, 12), "walking east, the air stays clear"

    a_little = after_walking(:up, 6)
    a_lot = after_walking(:up, 24)

    assert_operator a_little, :>, Color.resolve(:red), "walking north left the hero unmisted"
    assert_operator a_lot, :>, a_little, "the mist stopped thickening as the hero walked on"
  end

  # ...and it thins again on the way back, which is what says the amount is read every
  # frame rather than set once when something happened.
  def test_walking_south_again_clears_the_mist
    there_and_back = Reference.new
                              .input_each_frame { |f| f <= 24 ? [:up] : [:down] }
                              .run(Hero.program, frames: 55).screen

    assert_equal Color.resolve(:red), there_and_back.pixel(*CENTER),
                 "the mist never cleared on the walk back south"
  end

  # --- Hardware (gemba): the follow-cam really renders and scrolls ---

  def test_the_follow_cam_renders_on_the_console
    v = assert_gemba_loads_rom(Hero.build_rom(err: StringIO.new), frames: 6)
    assert v.red?(*CENTER),
           "the hero renders centered on hardware, got 0x#{format('%04X', v.pixel_gba(*CENTER))}"
    assert blue_in?(70..105, 72..92) { |x, y| v.blue?(x, y) },
           "the pond renders near the hero at rest"
  end

  # The console draws the mist over the hero too, and works the amount out as it goes.
  def test_the_mist_thickens_over_the_hero_on_the_console
    rom = Hero.build_rom(err: StringIO.new)
    clear = assert_gemba_loads_rom(rom, frames: 30).pixel_gba(*CENTER)
    misted = assert_gemba_loads_rom(rom, frames: 30, keys: KEY_UP).pixel_gba(*CENTER)

    assert_equal Color.resolve(:red), clear, "the air is clear until the hero walks north"
    assert_operator misted, :>, clear,
                    "the console left the hero unmisted, got 0x#{format('%04X', misted)}"
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
