# frozen_string_literal: true

require "test_helper"
require "many_tiles"

# A Game Boy Color holds 512 background tiles at once. A game whose screens between them need more
# still builds, each screen bringing its own tiles in as it comes up (GBC::Art::Room); what one
# screen cannot hold, it cannot, and the build says which screen. Whether the screens then show
# the interpreter's pictures is the scene and area tests' (test/vblank/builder/test_scene_backgrounds.rb,
# test/vblank/builder/test_background_tile_sets.rb), on every lowering.
class TestGBCTileRooms < Minitest::Test
  GBC = VBlank::IR::Backends::GBC

  private def color_program(&block)
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  def test_one_screen_with_more_tiles_than_the_color_holds_is_refused_naming_it
    program = color_program do
      screen :tiled
      big = ManyTiles.declare(self, :big_tiles, 520, :red)
      small = ManyTiles.declare(self, :small_tiles, 10, :blue, from: 520)
      scene(:vast) { background :vast, tiles: :big_tiles, map: big.first(26) }
      scene(:hut) { background :hut, tiles: :small_tiles, map: small }
      state = var :state, 0
      game_loop do
        case_var(:state) do
          when_val 0, :vast
          when_val 1, :hut
        end
      end
    end
    error = assert_raises(GBC::LoweringError) { GBC.new.build(program) }

    assert_match(/the backgrounds of the scene :vast need \d+ different tiles/, error.message)
    assert_match(/room for 512/, error.message)
  end

  # A screen counts the tiles its maps show, not every tile of its tileset: a tileset of 600 whose
  # map shows 300 fits beside a scene of 400, each scene bringing its own in.
  def test_a_scene_counts_the_tiles_its_map_shows_not_its_whole_tileset
    program = color_program do
      screen :tiled
      first = ManyTiles.declare(self, :first_tiles, 600, :red)
      second = ManyTiles.declare(self, :second_tiles, 400, :blue, from: 600)
      scene(:one) { background :one, tiles: :first_tiles, map: first.first(15) }
      scene(:two) { background :two, tiles: :second_tiles, map: second }
      state = var :state, 0
      game_loop do
        case_var(:state) do
          when_val 0, :one
          when_val 1, :two
        end
      end
    end

    refute_empty GBC.new.build(program).bytes
  end

  # ONE BACKGROUND WALKING BETWEEN TWO AREAS OF 300 TILES, declared in each of two scenes that show
  # it: each scene's areas have rooms of their own, and the second scene arrives in its first area
  # after the first scene walked into its second. Every lowering plays one such background with few
  # tiles (test/vblank/builder/test_background_tile_sets.rb); this is the Color's rooms for it. The run
  # checks the cartridge against the interpreter after every pass.
  def test_one_walking_background_of_many_tiles_in_two_scenes_plays_as_the_interpreter_does
    program = color_program do
      screen :tiled
      shrine = ManyTiles.declare(self, :shrine, 300, :red)
      clearing = ManyTiles.declare(self, :clearing, 300, :blue, from: 300)
      state = var :state, 0
      tick = var :tick, 0
      where = var :room, 0
      %i[one two].each do |name|
        scene(name) do
          ground = background :ground, tiles: { shrine: :shrine, clearing: :clearing },
                                       map: { shrine: { hall: shrine }, clearing: { glade: clearing } }
          ground.show_map where
        end
      end
      game_loop do
        tick.add! 1
        (tick == 3).then { where.set! 1 }
        (tick == 7).then { state.set! 1 }
        case_var(:state) do
          when_val 0, :one
          when_val 1, :two
        end
      end
    end

    assert_equal VBlank::Graphics::Color.resolve(:blue), game_player.run(program, frames: 12).screen.pixel(8, 0)
  end
end
