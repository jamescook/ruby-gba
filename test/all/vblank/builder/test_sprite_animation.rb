# frozen_string_literal: true

require "test_helper"

# The game these tests play, shared with the Advance cartridge's own tests of the same flipbook
# (test/lowering/gba/vblank/builder/test_sprite_animation_cartridge.rb).
module SpriteAnimationGames
  include SharedConstants

  # A blinker at (40, 40) that flips between a red frame and a blue frame every 4
  # frames, over a white field. It halts after +run+ frames so what's on screen is
  # deterministic: it shows red for the first 4 frames, then blue for the next 4.
  #
  # +in_scene+ declares the blinker inside a scene instead of above the game loop. A scene's
  # body is built after the loop that runs it, which is the order that once left such a
  # sprite on its first picture for ever.
  private def blinker(mode:, run:, rate: 4, in_scene: false)
    builder = Builder.new
    builder.instance_eval do
      screen mode
      if mode == :tiled
        image(:field, "#" => :white) { SOLID_TILE }
        tiles :ground, "#" => :field
        background :bg, tiles: :ground, map: Array.new(20, "#" * 30)
      else
        clear_screen :white
      end
      image(:on,  "#" => :red)  { SOLID_TILE }
      image(:off, "#" => :blue) { SOLID_TILE }
      f = var :f, 0
      declare = -> { sprite :blink, at: [40, 40], frames: %i[on off], rate: rate }
      count = lambda do
        f.add! 1
        (f >= run).then { halt }
      end
      if in_scene
        var :state, 0
        scene :play do
          declare.call
          count.call
        end
        game_loop { case_var(:state) { when_val 0, :play } }
      else
        declare.call
        game_loop do
          wait_vblank
          count.call
        end
      end
    end
    builder.finalize_program
    builder.program
  end
end

# Flipbook animation: `sprite ..., frames: [...], rate: N` cycles a sprite through a
# set of same-size pictures, one every N frames, with the timer hidden and managed.
# It works the same on a software sprite (screen :bitmap) and a hardware sprite
# (screen :tiled), and composes with everything else. These prove the picture
# actually changes over time, by reading the sprite's color a few frames apart; the
# same on the Advance's cartridge is in
# test/lowering/gba/vblank/builder/test_sprite_animation_cartridge.rb.
class TestSpriteAnimation < Minitest::Test
  include VBlank::Console::Hardware
  include SpriteAnimationGames

  private def spot(program)
    game_player.run(program).screen.pixel(44, 44)
  end

  def test_a_software_sprite_flipbook_cycles
    assert_equal Color.resolve(:red),  spot(blinker(mode: :bitmap, run: 4)), "it starts on the first frame"
    assert_equal Color.resolve(:blue), spot(blinker(mode: :bitmap, run: 6)), "a few frames on it has flipped"
  end

  # A hardware sprite's pose is placed as far behind as the framework draws, which a game that
  # halts shows (Testing#framework_drawing_lag).
  def test_a_hardware_sprite_flipbook_cycles
    assert_equal Color.resolve(:red),  spot(blinker(mode: :tiled, run: 3 + framework_drawing_lag)), "it starts on the first frame"
    assert_equal Color.resolve(:blue), spot(blinker(mode: :tiled, run: 5 + framework_drawing_lag)), "a few frames on it has flipped"
  end

  def test_a_software_sprite_declared_inside_a_scene_cycles
    assert_equal Color.resolve(:red),  spot(blinker(mode: :bitmap, run: 4, in_scene: true))
    assert_equal Color.resolve(:blue), spot(blinker(mode: :bitmap, run: 6, in_scene: true)), "it has flipped"
  end

  def test_a_hardware_sprite_declared_inside_a_scene_cycles
    assert_equal Color.resolve(:red),  spot(blinker(mode: :tiled, run: 3 + framework_drawing_lag, in_scene: true))
    assert_equal Color.resolve(:blue), spot(blinker(mode: :tiled, run: 5 + framework_drawing_lag, in_scene: true)), "it has flipped"
  end

  # --- friendly guardrails ---

  private def build_with(&block)
    b = Builder.new
    b.instance_eval(&block)
    b
  end

  def test_frames_needs_at_least_two_images
    err = assert_raises(ArgumentError) do
      build_with do
        screen :bitmap
        image(:only, "#" => :red) { SOLID_TILE }
        sprite :s, at: [0, 0], frames: [:only], rate: 4
      end
    end
    assert_match(/at least two/, err.message)
  end

  def test_frames_needs_a_positive_rate
    err = assert_raises(ArgumentError) do
      build_with do
        screen :bitmap
        image(:a, "#" => :red)  { SOLID_TILE }
        image(:b, "#" => :blue) { SOLID_TILE }
        sprite :s, at: [0, 0], frames: %i[a b], rate: 0
      end
    end
    assert_match(/rate/, err.message)
  end

  def test_facing_and_frames_are_mutually_exclusive
    err = assert_raises(ArgumentError) do
      build_with do
        screen :bitmap
        image(:a, "#" => :red)  { SOLID_TILE }
        image(:b, "#" => :blue) { SOLID_TILE }
        sprite :s, at: [0, 0], facing: { left: :a, right: :b }, frames: %i[a b], rate: 4
      end
    end
    assert_match(/Use only one/, err.message)
  end

  def test_an_undefined_animation_frame_is_a_friendly_error
    err = assert_raises(ArgumentError) do
      build_with do
        screen :bitmap
        image(:a, "#" => :red) { SOLID_TILE }
        sprite :s, at: [0, 0], frames: %i[a nope], rate: 4
      end
    end
    assert_match(/not defined/, err.message)
  end
end
