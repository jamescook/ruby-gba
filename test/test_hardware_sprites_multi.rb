# frozen_string_literal: true

require "test_helper"

# Multiple hardware sprites at once (OAM slice 2): several sprites keep their own
# colors, stack in a stable front-to-back order (the thing software save-under
# sprites can't do reliably), and can be hidden and shown. Asserted on the
# interpreter oracle and on real hardware. Still no OAM, tile indices, or palette
# banks in the game code.
class TestHardwareSpritesMulti < Minitest::Test
  include RubyGBA::Constants

  SOLID8 = (["########"] * 8).join("\n") # a solid 8x8 tile of one color
  FLOOR_MAP = Array.new(20, "#" * 30).freeze # a white floor filling the screen

  def rom_for(program)
    ROM.assemble(GBA.new.lower(program), title: "MULTISPR", code: "BMSP", maker: "01")
  end

  # Two overlapping sprites: a red one declared first, a blue one declared second,
  # each a different color (so this also proves they share one palette without
  # clobbering each other). They overlap in 44..47 x 44..47.
  def overlapping_pair
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image(:floor, "#" => :white) { SOLID8 }
      image(:red_guy,  "#" => :red)  { SOLID8 }
      image(:blue_guy, "#" => :blue) { SOLID8 }
      tiles :ground, "#" => :floor
      background :field, tiles: :ground, map: FLOOR_MAP
      sprite :red_guy,  at: [40, 40] # declared first  -> behind
      sprite :blue_guy, at: [44, 44] # declared second -> in front
      game_loop do
        wait_vblank
        halt # a static scene — one frame is enough
      end
    end
    builder.emit_pending_functions
    builder.program
  end

  def test_later_declared_sprite_draws_in_front_and_colors_do_not_clobber
    screen = Reference.new.run(overlapping_pair).screen
    assert_equal Color.resolve(:red),  screen.pixel(41, 41), "the red sprite keeps its own color"
    assert_equal Color.resolve(:blue), screen.pixel(50, 50), "the blue sprite keeps its own color"
    assert_equal Color.resolve(:blue), screen.pixel(46, 46), "the later sprite sits in front in the overlap"
  end

  def test_layering_and_shared_palette_on_the_console
    v = assert_gemba_loads_rom(rom_for(overlapping_pair), frames: 3)
    assert v.red?(41, 41),  "red renders, got 0x#{format('%04X', v.pixel_gba(41, 41))}"
    assert v.blue?(50, 50), "blue renders, got 0x#{format('%04X', v.pixel_gba(50, 50))}"
    assert v.blue?(46, 46), "the later sprite is in front, got 0x#{format('%04X', v.pixel_gba(46, 46))}"
  end

  # One red sprite over a white floor that flips visibility once, on frame 1. A
  # sprite that starts +shown+ hides itself; one that starts hidden shows itself. So
  # the observable result at the sprite's spot (44, 44) inverts between a 1-frame run
  # (before the flip) and a longer run (after it).
  def visibility_program(shown:, frames:)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image(:floor, "#" => :white) { SOLID8 }
      image(:guy,   "#" => :red)   { SOLID8 }
      tiles :ground, "#" => :floor
      background :field, tiles: :ground, map: FLOOR_MAP
      guy = sprite :guy, at: [40, 40], shown: shown
      f = var :f, 0
      game_loop do
        wait_vblank
        (f == 1).then { shown ? guy.hide : guy.show }
        f.add 1
        (f >= frames).then { halt }
      end
    end
    builder.emit_pending_functions
    builder.program
  end

  def spot_color(program)
    Reference.new.run(program).screen.pixel(44, 44)
  end

  def test_a_shown_sprite_can_be_hidden
    assert_equal Color.resolve(:red),   spot_color(visibility_program(shown: true, frames: 1)),
                 "before the flip the sprite is visible"
    assert_equal Color.resolve(:white), spot_color(visibility_program(shown: true, frames: 4)),
                 "after hide, its spot shows the floor again"
  end

  def test_a_hidden_sprite_can_be_shown
    assert_equal Color.resolve(:white), spot_color(visibility_program(shown: false, frames: 1)),
                 "a shown: false sprite starts invisible"
    assert_equal Color.resolve(:red),   spot_color(visibility_program(shown: false, frames: 4)),
                 "after show, the sprite appears"
  end

  def test_hide_and_show_on_the_console
    hidden = assert_gemba_loads_rom(rom_for(visibility_program(shown: true, frames: 4)), frames: 6)
    assert hidden.white?(44, 44), "a hidden sprite shows the floor, got 0x#{format('%04X', hidden.pixel_gba(44, 44))}"

    shown = assert_gemba_loads_rom(rom_for(visibility_program(shown: false, frames: 4)), frames: 6)
    assert shown.red?(44, 44), "a shown sprite appears, got 0x#{format('%04X', shown.pixel_gba(44, 44))}"
  end
end
