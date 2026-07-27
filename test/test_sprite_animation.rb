# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# Flipbook animation: `sprite ..., frames: [...], rate: N` cycles a sprite through a
# set of same-size pictures, one every N frames, with the timer hidden and managed.
# It works the same on a software sprite (screen :bitmap) and a hardware sprite
# (screen :tiled), and composes with everything else. These prove the picture
# actually changes over time — on the interpreter oracle and on real hardware — by
# reading the sprite's color a few frames apart.
class TestSpriteAnimation < Minitest::Test
  include RubyGBA::Constants
  include GembaSupport

  Builder = RubyGBA::Builder
  Ruby = RubyGBA::IR::Backends::Ruby
  GBA = RubyGBA::IR::Backends::GBA
  ROM = RubyGBA::ROM
  Color = RubyGBA::Color

  SOLID8 = (["########"] * 8).join("\n")

  # A blinker at (40, 40) that flips between a red frame and a blue frame every 4
  # frames, over a white field. It halts after +run+ frames so what's on screen is
  # deterministic: it shows red for the first 4 frames, then blue for the next 4.
  def blinker(mode:, run:, rate: 4)
    builder = Builder.new
    builder.instance_eval do
      screen mode
      if mode == :tiled
        image(:field, "#" => :white) { SOLID8 }
        tiles :ground, "#" => :field
        background :bg, tiles: :ground, map: Array.new(20, "#" * 30)
      else
        clear_screen :white
      end
      image(:on,  "#" => :red)  { SOLID8 }
      image(:off, "#" => :blue) { SOLID8 }
      sprite :blink, at: [40, 40], frames: %i[on off], rate: rate
      f = var :f, 0
      game_loop do
        wait_vblank
        f.add 1
        (f >= run).then { halt }
      end
    end
    builder.emit_pending_functions
    builder.program
  end

  def spot(program)
    Ruby.new.run(program).screen.pixel(44, 44)
  end

  def test_a_software_sprite_flipbook_cycles
    assert_equal Color.resolve(:red),  spot(blinker(mode: :bitmap, run: 4)), "it starts on the first frame"
    assert_equal Color.resolve(:blue), spot(blinker(mode: :bitmap, run: 6)), "a few frames on it has flipped"
  end

  def test_a_hardware_sprite_flipbook_cycles
    assert_equal Color.resolve(:red),  spot(blinker(mode: :tiled, run: 4)), "it starts on the first frame"
    assert_equal Color.resolve(:blue), spot(blinker(mode: :tiled, run: 6)), "a few frames on it has flipped"
  end

  def rom_for(program)
    ROM.assemble(GBA.new.lower(program), title: "ANIM", code: "BANM", maker: "01")
  end

  def test_a_hardware_flipbook_cycles_on_the_console
    red  = assert_gemba_loads_rom(rom_for(blinker(mode: :tiled, run: 4)), frames: 6)
    assert red.red?(44, 44), "the first frame renders red, got 0x#{format('%04X', red.pixel_gba(44, 44))}"
    blue = assert_gemba_loads_rom(rom_for(blinker(mode: :tiled, run: 6)), frames: 8)
    assert blue.blue?(44, 44), "it has flipped to blue, got 0x#{format('%04X', blue.pixel_gba(44, 44))}"
  end

  def test_a_software_flipbook_cycles_on_the_console
    red  = assert_gemba_loads_rom(rom_for(blinker(mode: :bitmap, run: 4)), frames: 6)
    assert red.red?(44, 44), "the first frame renders red, got 0x#{format('%04X', red.pixel_gba(44, 44))}"
    blue = assert_gemba_loads_rom(rom_for(blinker(mode: :bitmap, run: 6)), frames: 8)
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
        image(:only, "#" => :red) { SOLID8 }
        sprite :s, at: [0, 0], frames: [:only], rate: 4
      end
    end
    assert_match(/at least two/, err.message)
  end

  def test_frames_needs_a_positive_rate
    err = assert_raises(ArgumentError) do
      build_with do
        screen :bitmap
        image(:a, "#" => :red)  { SOLID8 }
        image(:b, "#" => :blue) { SOLID8 }
        sprite :s, at: [0, 0], frames: %i[a b], rate: 0
      end
    end
    assert_match(/rate/, err.message)
  end

  def test_facing_and_frames_are_mutually_exclusive
    err = assert_raises(ArgumentError) do
      build_with do
        screen :bitmap
        image(:a, "#" => :red)  { SOLID8 }
        image(:b, "#" => :blue) { SOLID8 }
        sprite :s, at: [0, 0], facing: { left: :a, right: :b }, frames: %i[a b], rate: 4
      end
    end
    assert_match(/not both/, err.message)
  end

  def test_an_undefined_animation_frame_is_a_friendly_error
    err = assert_raises(ArgumentError) do
      build_with do
        screen :bitmap
        image(:a, "#" => :red) { SOLID8 }
        sprite :s, at: [0, 0], frames: %i[a nope], rate: 4
      end
    end
    assert_match(/not defined/, err.message)
  end
end
