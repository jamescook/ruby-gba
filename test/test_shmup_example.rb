# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require_relative "../lib/ruby_gba"
require_relative "test_helper"
require_relative "../examples/shmup"

# The Shmup example: a whole game split across files — examples/shmup/player.rb,
# enemies.rb, hud.rb — each a plain Ruby object that takes the build and calls the DSL
# verbs on it. This proves the multi-file pattern end-to-end: the parts declare their
# own sprites, run their own per-frame logic, and collaborate (an enemy touching the
# ship calls the HUD's hit) — all producing one working ROM, on the interpreter oracle
# and on real hardware.
class TestShmupExample < Minitest::Test
  include GembaSupport

  Ruby = RubyGBA::IR::Backends::Ruby
  Color = RubyGBA::Color

  CYAN = Color.resolve(:cyan)   # the ship (player.rb)
  RED = Color.resolve(:red)     # an enemy (enemies.rb)
  WHITE = Color.resolve(:white) # the HUD text (hud.rb)

  STEPS = 3_000 # a fixed budget so the deterministic run is reproducible

  def red_somewhere?(screen)
    (0...160).any? { |y| (0...240).any? { |x| screen.pixel(x, y) == RED } }
  end

  def test_the_example_builds_clean
    rom = Shmup.build_rom(out: StringIO.new, err: StringIO.new)
    assert_operator rom.size, :>, 0, "the split-across-files game still builds one ROM"
  end

  # Each file's part draws: the ship, the HUD, and the enemies all appear.
  def test_every_part_renders_on_the_interpreter
    s = Ruby.new.run(Shmup.program, max_steps: STEPS).screen
    assert_equal CYAN, s.pixel(119, 132), "the ship (player.rb) renders"
    assert_equal WHITE, s.pixel(9, 4), "the HUD SCORE text (hud.rb) renders"
    assert red_somewhere?(s), "an enemy (enemies.rb) renders"
  end

  # Player#update runs its input logic from its own file: holding right walks the ship
  # to the right edge, where at rest it never is.
  def test_holding_right_drives_the_ship_from_its_own_file
    still = Ruby.new.run(Shmup.program, max_steps: STEPS).screen
    right = Ruby.new.hold(:right).run(Shmup.program, max_steps: STEPS).screen
    refute_equal CYAN, still.pixel(231, 133), "at rest the ship isn't at the right edge"
    assert_equal CYAN, right.pixel(231, 133), "holding right, the ship moved there"
  end

  # The parts collaborate across files: an enemy that drifts into the ship calls the
  # HUD's `hit`, so a life is lost. (Per-pixel collision, between two files' sprites.)
  def test_parts_collaborate_across_files
    i = Ruby.new.run(Shmup.program, max_steps: STEPS)
    assert_operator i[:lives], :<, 3, "an enemy reached the ship — enemies.rb called hud.hit"
  end

  # The whole thing runs on the console.
  def test_it_renders_on_the_console
    v = assert_gemba_loads_rom(Shmup.build_rom(out: StringIO.new, err: StringIO.new), frames: 3)
    assert v.pixel_is?(119, 132, :cyan), "the ship, got 0x#{format('%04X', v.pixel_gba(119, 132))}"
    assert v.white?(9, 4), "the HUD text, got 0x#{format('%04X', v.pixel_gba(9, 4))}"
  end
end
