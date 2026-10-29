# frozen_string_literal: true

require "test_helper"
require "many_tiles"

# What a Game Boy Color cannot do at all is refused when a cartridge is made for it, in the words
# the Color's answers have (Console::ColorAnswers, through Guardrails::Checks::ConsoleAnswers) — by
# the lowering itself, so a program handed straight to it, as every test's is, hears the same
# refusal a game's build does rather than playing on without what it asked for. So is what it
# cannot hold: more lists of colours than it has, more colours than a tile holds.
class TestGBCRefusals < Minitest::Test
  GBC = VBlank::IR::Backends::GBC

  def test_a_layer_seen_through_by_a_fixed_amount_is_refused_in_plain_words
    error = assert_raises(GBC::LoweringError) { GBC.new.build(ghost_program { 40 }) }

    assert_match(/`transparency:`/, error.message)
    assert_match(/cannot show one layer through another/, error.message)
  end

  def test_a_layer_seen_through_by_an_amount_worked_out_as_it_runs_is_refused_the_same_way
    error = assert_raises(GBC::LoweringError) { GBC.new.build(ghost_program { var(:see, 40) }) }

    assert_match(/cannot show one layer through another/, error.message)
  end

  def test_a_shoulder_button_is_refused_in_plain_words
    error = assert_raises(GBC::LoweringError) do
      GBC.new.build(color_program do
        count = var :count, 0
        game_loop { pressed(:l).then { count.add! 1 } }
      end)
    end

    assert_match(/:l button/, error.message)
    assert_match(/no shoulder buttons/, error.message)
  end

  # A program that names no console is still made for the Color here, so it is asked about as one.
  def test_a_turning_sprite_in_a_program_naming_no_console_is_refused
    program = color_program do
      screen :tiled
      image(:ship, "#" => :white) { "########\n" * 8 }
      ship = sprite :ship, at: [40, 40]
      game_loop { ship.turn 4 }
    end
    program.console = nil
    error = assert_raises(GBC::LoweringError) { GBC.new.build(program) }

    assert_match(/cannot turn or resize a sprite/, error.message)
  end

  # NINE LISTS OF THE SAME COLOURS IN NINE ORDERS, each drawing a tile and each drawn with a list
  # of its own: the Color draws them from nine palettes, one more than it holds, and the refusal
  # names that.
  def test_nine_lists_drawn_with_other_colours_are_refused_naming_the_eight
    orders = [0, 0x7C00, 0x03E0, 0x001F].permutation.first(9)
    error = assert_raises(GBC::LoweringError) do
      GBC.new.build(color_program do
        screen :tiled
        orders.each_with_index do |order, n|
          colors :"list#{n}", [:transparent, *order]
          colors :"dusk#{n}", [:transparent, n, n + 1, n + 2, n + 3]
          image :"tile#{n}", width: 8, height: 8, colors: :"list#{n}", places: ManyTiles::QUARTERS
        end
        tiles :set, orders.each_index.to_h { |n| [n.to_s, :"tile#{n}"] }
        board = background :board, tiles: :set, map: [orders.each_index.map(&:to_s).join]
        game_loop { board.draw_with(orders.each_index.to_h { |n| [:"list#{n}", :"dusk#{n}"] }) }
      end)
    end

    assert_match(/8 lists of colours/, error.message)
  end

  # A TILE WITH SEE-THROUGH PIXELS THAT DRAWS FOUR PLACES, two of them one colour: three colours
  # and the backdrop fit a Color tile, but drawn with another list the four places are four
  # colours, and the refusal names the three a tile holds.
  def test_a_see_through_tile_of_four_places_drawn_with_other_colours_is_refused_naming_the_three
    error = assert_raises(GBC::LoweringError) do
      GBC.new.build(color_program do
        screen :tiled
        places = Array.new(64) { |i| (i % 8) / 2 + (i < 8 ? 0 : 1) }.map { |place| [place, 4].min }
        colors :pale, [:transparent, 0x7FFF, 0x7FFF, 0x001F, 0x03E0]
        colors :dusk, [:transparent, 0x7C00, 0x03E0, 0x001F, 0x7FFF]
        image :tile, width: 8, height: 8, colors: :pale, places: places
        tiles :set, "0" => :tile
        board = background :board, tiles: :set, map: ["0"]
        game_loop { board.draw_with :dusk }
      end)
    end

    assert_match(/:tile/, error.message)
    assert_match(/holds 3 colours and the backdrop/, error.message)
  end

  private

  def ghost_program(&amount)
    color_program do
      screen :tiled
      image(:ghost, "#" => :white) { "########\n" * 8 }
      layers :world, :ghosts
      layer(:ghosts, transparency: instance_eval(&amount)) { sprite :ghost, at: [40, 40] }
      game_loop { wait_vblank }
    end
  end

  # A picture made of pieces is drawn from them, and the Color shows forty at once.
  def test_a_picture_of_more_pieces_than_the_color_shows_is_refused
    pieces = Array.new(41) { |n| [(n % 20) * 8, (n / 20) * 8, Array.new(64, 1)] }
    error = assert_raises(GBC::LoweringError) do
      GBC.new.build(color_program do
        screen :tiled
        image :crowd, colors: %i[transparent red], pieces: pieces
        sprite :crowd, at: [0, 0]
        game_loop {}
      end)
    end

    assert_match(/made of 41 pieces/, error.message)
    assert_match(/make it of fewer pieces/, error.message)
  end

  # Bigger than the mask a test of pixels walks, a picture of pieces is tested by its box.
  def test_a_big_picture_of_pieces_tested_pixel_by_pixel_is_refused
    error = assert_raises(GBC::LoweringError) do
      GBC.new.build(color_program do
        screen :tiled
        image :wide, colors: %i[transparent red], pieces: [[0, 0, Array.new(64, 1)], [72, 0, Array.new(64, 1)]]
        image(:dot, "#" => :red) { "#" }
        wide = sprite :wide, at: [0, 0]
        dot = sprite :dot, at: [4, 4]
        hits = var :hits, 0
        game_loop { wide.overlaps?(dot).then { hits.add! 1 } }
      end)
    end

    assert_match(/tested pixel by pixel/, error.message)
    assert_match(/give the sprite a hitbox:/, error.message)
  end

  def color_program(&game)
    builder = Builder.new
    builder.instance_eval(&game)
    builder.finalize_program
    program = builder.program
    program.console = :gbc
    program
  end
end
