# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# The sprite-mover example in miniature: a transparent ASCII heart steered by
# holding a direction. Proves image (ASCII art + transparency) + blit +
# held-input move a sprite, on both backends.
class TestSpriteMover < Minitest::Test
  include RubyGBA::Constants
  include GembaSupport

  Builder = RubyGBA::Builder
  Ruby = RubyGBA::IR::Backends::Ruby
  Color = RubyGBA::Color

  # A heart that starts at (100, 60), slides right while :right is held, and halts
  # after +frames+ steps so its final resting place is deterministic. Holding
  # right for 4 frames leaves it at x = 108.
  def sprite_program(frames:)
    builder = Builder.new
    builder.instance_eval do
      display :bitmap
      image :heart, "." => :transparent, "#" => :red do
        <<~ART
          .#.#.
          #####
          #####
          .###.
          ..#..
        ART
      end
      x = var :x, 100
      var :y, 60
      f = var :f, 0
      game_loop do
        wait_vblank
        clear_screen :white
        held(:right).then { x.add 2 }
        x.clamp 0, 235
        blit :heart, :x, :y
        f.add 1
        (f >= frames).then { halt }
      end
    end
    builder.emit_pending_functions
    builder.program
  end

  def test_interpreter_moves_the_sprite_and_keeps_transparency
    screen = Ruby.new.input_each_frame { [:right] }.run(sprite_program(frames: 4)).screen

    # Ended at x = 108. The heart's top-left is a transparent ".", so the white
    # field shows through; the "#" next to it is red.
    assert_equal Color.resolve(:white), screen.pixel(108, 60), "transparent corner shows the background"
    assert_equal Color.resolve(:red),   screen.pixel(109, 60), "the heart's body is drawn"
    # It actually moved: the screen is cleared each frame, so the earlier columns
    # hold no heart.
    assert_equal Color.resolve(:white), screen.pixel(100, 61), "it moved off the start column"
  end

  def test_runs_on_hardware
    machine_code = RubyGBA::IR::Backends::GBA.new.lower(sprite_program(frames: 4))
    rom = RubyGBA::ROM.assemble(machine_code, title: "SPRITEMV", code: "BSPM", maker: "01")

    v = assert_gemba_loads_rom(rom, frames: 6, keys: KEY_RIGHT)
    assert v.red?(109, 60),   "the heart is drawn after moving right"
    assert v.white?(108, 60), "its transparent corner shows the white field"
  end
end
