# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "../examples/pacman"
require_relative "test_helper"

# The Pac-Man example: steer him and he turns to face the way he goes, using the
# sprite `facing:` poses + directional `move`. Asserts he appears, moves, and turns
# to face his heading (via the framework's facing variable, and on the screen), on
# the interpreter and on gemba.
class TestPacmanExample < Minitest::Test
  include GembaSupport
  include RubyGBA::Constants

  Ruby = RubyGBA::IR::Backends::Ruby
  GBA = RubyGBA::IR::Backends::GBA
  ROM = RubyGBA::ROM
  Color = RubyGBA::Color

  START_X = (Pacman::SCREEN_W - Pacman::SIZE) / 2
  START_Y = (Pacman::SCREEN_H - Pacman::SIZE) / 2
  # facing map order is right, left, up, down -> pose indices 0..3
  FACE = { right: 0, left: 1, up: 2, down: 3 }.freeze

  def yellow_on?(screen)
    (0...Pacman::SCREEN_H).any? { |y| (0...Pacman::SCREEN_W).any? { |x| screen.pixel(x, y) == Color.resolve(:yellow) } }
  end

  def test_pac_appears_facing_right
    i = Ruby.new.run(Pacman.program, max_steps: 300)
    assert yellow_on?(i.screen), "Pac-Man should be on screen"
    assert_equal FACE[:right], i[:__spr1_face], "he should start facing right (the first pose)"
  end

  def test_steering_moves_and_turns_him
    left = Ruby.new.input_each_frame { |_f| [:left] }.run(Pacman.program, max_steps: 3000)
    assert_operator left[:__spr1_x], :<, START_X, "holding left should move him left"
    assert_equal FACE[:left], left[:__spr1_face], "moving left should turn him to face left"

    up = Ruby.new.input_each_frame { |_f| [:up] }.run(Pacman.program, max_steps: 3000)
    assert_operator up[:__spr1_y], :<, START_Y, "holding up should move him up"
    assert_equal FACE[:up], up[:__spr1_face], "moving up should turn him to face up"
  end

  def test_running_into_the_pellet_eats_it
    # The pellet starts just to Pac-Man's right, so holding right walks him into it;
    # overlaps? fires and the eaten count climbs. Both are sprites — no boxes.
    r = Ruby.new.input_each_frame { |_f| [:right] }.run(Pacman.program, max_steps: 3000)
    assert_operator r[:eaten], :>=, 1, "running into the pellet should eat it"
  end

  def test_it_builds_a_rom
    assert Pacman.build_rom.size.positive?
  end

  def test_it_renders_and_steers_on_hardware
    rom = ROM.assemble(GBA.new.lower(Pacman.program), title: "PACMAN", code: "BPAC", maker: "01")
    v = assert_gemba_loads_rom(rom, frames: 10, keys: KEY_LEFT)
    # he's moved left of centre and is drawn there in yellow
    moved = (10...START_X).any? { |x| (START_Y...START_Y + Pacman::SIZE).any? { |y| v.pixel_is?(x, y, :yellow) } }
    assert moved, "Pac-Man should be found in yellow to the left of centre on hardware"
  end
end
