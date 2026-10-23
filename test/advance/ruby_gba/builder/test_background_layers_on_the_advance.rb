# frozen_string_literal: true

require "test_helper"

# The tests of test_background_layers.rb whose games show a second background while another is
# showing, or turn a background, and a Game Boy Color's hardware cannot, so they play on the
# Advance's runs alone.
class TestBackgroundLayersOnTheAdvance < Minitest::Test
  include RubyGBA::Console::Hardware

  # A FAR layer (backmost): a blue field with a GREEN landmark tile at cell (5,5) ->
  # px (40,40). A NEAR layer (front): transparent everywhere (spaces) except a RED
  # landmark tile at cell (10,5) -> px (80,40). Where near is transparent, far shows.
  # Each layer is scrolled to its own offset, so they can move at different speeds.
  private def two_layers(far_x, near_x)
    far_map  = Array.new(32) { |r| (0...32).map { |c| r == 5 && c == 5  ? "G" : "B" }.join }
    near_map = Array.new(32) { |r| (0...32).map { |c| r == 5 && c == 10 ? "R" : " " }.join }
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image(:blue_t,  "#" => :blue)  { SOLID_TILE }
      image(:green_t, "#" => :green) { SOLID_TILE }
      image(:red_t,   "#" => :red)   { SOLID_TILE }
      tiles :far_set,  "B" => :blue_t, "G" => :green_t
      tiles :near_set, "R" => :red_t
      far  = background :far,  tiles: :far_set,  map: far_map   # declared first -> backmost
      near = background :near, tiles: :near_set, map: near_map  # declared second -> in front
      far.scroll_to far_x, 0
      near.scroll_to near_x, 0
      game_loop do
        wait_vblank
        halt
      end
    end
    builder.finalize_program
    builder.program
  end

  private def rom_for(program)
    ROM.assemble(GBA.new.lower(program), title: "LAYERS", code: "BLYR", maker: "01")
  end

  # At rest the two landmarks sit apart (green at x44, red at x84), and where the near
  # layer is empty its blue backdrop layer shows through.
  def test_layers_compose_with_the_front_transparent_where_empty
    s = game_player.run(two_layers(0, 0)).screen
    assert_equal Color.resolve(:green), s.pixel(44, 44), "the far layer's green landmark shows through the empty near layer"
    assert_equal Color.resolve(:red),   s.pixel(84, 44), "the near layer's red landmark sits in front"
    assert_equal Color.resolve(:blue),  s.pixel(100, 100), "elsewhere the near layer is see-through, so the far layer shows"
  end

  # Scroll far by 20 and near by 40 (near twice as fast): the green landmark slides to
  # x24 while the red slides to x44 — they were 40px apart, now 20px apart. That change
  # in relative spacing *is* parallax (the near layer moved more than the far one).
  def test_layers_scroll_at_independent_speeds_parallax
    s = game_player.run(two_layers(20, 40)).screen
    assert_equal Color.resolve(:green), s.pixel(24, 44), "the far layer slid 20px (its landmark to x24)"
    assert_equal Color.resolve(:red),   s.pixel(44, 44), "the near layer slid 40px (its landmark to x44) — twice as far"
  end

  # A front layer drawn in pure black over a red one. Black is a colour like any other: it
  # is see-through only where the picture says see-through, never because its number is 0.
  RED = Color.rgb(31, 0, 0)

  private def black_over_red(&front)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image :red, width: 8, height: 8, colors: [:transparent, RED], places: [1] * 64
      tiles :reds, "#" => :red
      background :behind, tiles: :reds, map: Array.new(20) { "#" * 30 }
      instance_eval(&front)
      game_loop {}
    end
    builder.finalize_program
    builder.program
  end

  private def black_by_place
    black_over_red do
      colors :inks, [:transparent, RED, 0x0000]
      image :black, width: 8, height: 8, places: [2] * 64, colors: :inks
      tiles :blacks, "b" => :black
      background :front, tiles: :blacks, map: ["b"]
    end
  end

  private def black_drawn_in_characters
    black_over_red do
      image(:black, "#" => :black) { SOLID_TILE }
      tiles :blacks, "b" => :black
      background :front, tiles: :blacks, map: ["b"]
    end
  end

  # A background that turns reads the whole colour table rather than a group of sixteen,
  # which is the other way a tile is stored: black at a place has to keep a slot there.
  private def black_by_place_turning
    black_over_red do
      colors :inks, [:transparent, RED, 0x0000]
      image :black, width: 8, height: 8, places: [2] * 64, colors: :inks
      tiles :blacks, "b" => :black
      angle = var :angle, 0
      background(:front, tiles: :blacks, map: Array.new(16) { "b" * 16 }).rotate(angle)
    end
  end

  def test_black_at_a_place_covers_on_a_turning_background
    assert_equal 0x0000, game_player.run(black_by_place_turning, frames: 3).screen.pixel(2, 2)
    assert_equal 0x0000, assert_emulator_loads_rom(rom_for(black_by_place_turning), frames: 3).pixel_gba(2, 2)
  end

  # Art given as place numbers says where it is see-through itself (place 0), so black at
  # any other place is solid. Art drawn in colours has only the backdrop colour to say
  # "nothing here", so black drawn that way lets the layer behind through.
  def test_black_at_a_place_covers_and_black_drawn_as_a_colour_shows_through
    assert_equal 0x0000, game_player.run(black_by_place, frames: 3).screen.pixel(2, 2)
    assert_equal 0x0000, assert_emulator_loads_rom(rom_for(black_by_place), frames: 3).pixel_gba(2, 2)
    assert_equal RED, game_player.run(black_drawn_in_characters, frames: 3).screen.pixel(2, 2)
    assert_equal RED, assert_emulator_loads_rom(rom_for(black_drawn_in_characters), frames: 3).pixel_gba(2, 2)
  end
end
