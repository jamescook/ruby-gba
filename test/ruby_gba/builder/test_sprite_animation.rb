# frozen_string_literal: true

require "test_helper"

# Flipbook animation: `sprite ..., frames: [...], rate: N` cycles a sprite through a
# set of same-size pictures, one every N frames, with the timer hidden and managed.
# It works the same on a software sprite (screen :bitmap) and a hardware sprite
# (screen :tiled), and composes with everything else. These prove the picture
# actually changes over time — on the interpreter oracle and on real hardware — by
# reading the sprite's color a few frames apart.
class TestSpriteAnimation < Minitest::Test
  include RubyGBA::Console::Hardware

  # A blinker at (40, 40) that flips between a red frame and a blue frame every 4
  # frames, over a white field. It halts after +run+ frames so what's on screen is
  # deterministic: it shows red for the first 4 frames, then blue for the next 4.
  #
  # +in_scene+ declares the blinker inside a scene instead of above the game loop. A scene's
  # body is built after the loop that runs it, which is the order that once left such a
  # sprite on its first picture for ever.
  def blinker(mode:, run:, rate: 4, in_scene: false)
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

  def spot(program)
    Reference.new.run(program).screen.pixel(44, 44)
  end

  def test_a_software_sprite_flipbook_cycles
    assert_equal Color.resolve(:red),  spot(blinker(mode: :bitmap, run: 4)), "it starts on the first frame"
    assert_equal Color.resolve(:blue), spot(blinker(mode: :bitmap, run: 6)), "a few frames on it has flipped"
  end

  def test_a_hardware_sprite_flipbook_cycles
    assert_equal Color.resolve(:red),  spot(blinker(mode: :tiled, run: 4)), "it starts on the first frame"
    assert_equal Color.resolve(:blue), spot(blinker(mode: :tiled, run: 6)), "a few frames on it has flipped"
  end

  # Read two frames in rather than four: a software sprite declared inside a scene is painted
  # by the scene's own code, after the frame's step, so it shows each picture a frame sooner
  # than one painted at the frame boundary.
  def test_a_software_sprite_declared_inside_a_scene_cycles
    assert_equal Color.resolve(:red),  spot(blinker(mode: :bitmap, run: 2, in_scene: true))
    assert_equal Color.resolve(:blue), spot(blinker(mode: :bitmap, run: 6, in_scene: true)), "it has flipped"
  end

  def test_a_hardware_sprite_declared_inside_a_scene_cycles
    assert_equal Color.resolve(:red),  spot(blinker(mode: :tiled, run: 4, in_scene: true))
    assert_equal Color.resolve(:blue), spot(blinker(mode: :tiled, run: 6, in_scene: true)), "it has flipped"
  end

  def test_a_flipbook_declared_inside_a_scene_cycles_on_the_console
    { tiled: 4, bitmap: 2 }.each do |mode, early|
      red = assert_emulator_loads_rom(rom_for(blinker(mode: mode, run: early, in_scene: true)), frames: early + 2)
      assert red.red?(44, 44), "#{mode}: the first frame renders red, got 0x#{format('%04X', red.pixel_gba(44, 44))}"
      blue = assert_emulator_loads_rom(rom_for(blinker(mode: mode, run: 6, in_scene: true)), frames: 8)
      assert blue.blue?(44, 44), "#{mode}: it has flipped to blue, got 0x#{format('%04X', blue.pixel_gba(44, 44))}"
    end
  end

  def rom_for(program)
    ROM.assemble(GBA.new.lower(program), title: "ANIM", code: "BANM", maker: "01")
  end

  def test_a_hardware_flipbook_cycles_on_the_console
    red  = assert_emulator_loads_rom(rom_for(blinker(mode: :tiled, run: 4)), frames: 6)
    assert red.red?(44, 44), "the first frame renders red, got 0x#{format('%04X', red.pixel_gba(44, 44))}"
    blue = assert_emulator_loads_rom(rom_for(blinker(mode: :tiled, run: 6)), frames: 8)
    assert blue.blue?(44, 44), "it has flipped to blue, got 0x#{format('%04X', blue.pixel_gba(44, 44))}"
  end

  def test_a_software_flipbook_cycles_on_the_console
    red  = assert_emulator_loads_rom(rom_for(blinker(mode: :bitmap, run: 4)), frames: 6)
    assert red.red?(44, 44), "the first frame renders red, got 0x#{format('%04X', red.pixel_gba(44, 44))}"
    blue = assert_emulator_loads_rom(rom_for(blinker(mode: :bitmap, run: 6)), frames: 8)
    assert blue.blue?(44, 44), "it has flipped to blue, got 0x#{format('%04X', blue.pixel_gba(44, 44))}"
  end

  # --- friendly guardrails ---

  def build_with(&block)
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
