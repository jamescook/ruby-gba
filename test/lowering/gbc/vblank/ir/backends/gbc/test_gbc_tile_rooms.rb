# frozen_string_literal: true

require "test_helper"
require "many_tiles"

# A Game Boy Color holds 512 background tiles at once. A game whose screens between them need more
# still builds, each screen bringing its own tiles in as it comes up (GBC::Art::Room). The Color
# holds eight lists of background colours at once, and each screen brings its own lists in the same
# way. What one screen cannot hold, it cannot, and the build says which screen. Whether the screens
# then show the interpreter's pictures is the scene and area tests'
# (test/all/vblank/builder/test_scene_backgrounds.rb, test/all/vblank/builder/test_background_tile_sets.rb),
# on every lowering.
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

  # A SCENE'S OWN COLOURS ARE COUNTED THE SAME WAY: one scene drawing from nine lists of four is more
  # than the Color's eight at one time, whatever the other scene draws from, and the build names it.
  # Lists of four colours, place 0 see-through, numbered from +first+: no two alike, black in each.
  private def lists_from(first, count)
    (first...(first + count)).map { |n| [:transparent, VBlank::Graphics::Color.rgb(31, n, n), 31 << 5, 31 << 10, 0] }
  end

  def test_one_screen_with_more_lists_than_the_color_holds_is_refused_naming_it
    lists = { vast: lists_from(0, 9), hut: lists_from(9, 2) }
    program = color_program do
      screen :tiled
      lists.each do |name, colored|
        row = ManyTiles.declare_listed(self, :"#{name}_set", colored)
        scene(name) { background name, tiles: :"#{name}_set", map: [row] }
      end
      var :state, 0
      game_loop do
        case_var(:state) do
          when_val 0, :vast
          when_val 1, :hut
        end
      end
    end
    error = assert_raises(GBC::LoweringError) { GBC.new.build(program) }

    assert_match(/the scene :vast/, error.message)
    assert_match(/lists of colours/, error.message)
  end

  # ONE BACKGROUND WALKING BETWEEN TWO AREAS OF SIX LISTS OF COLOURS EACH: twelve between them, and
  # each area's lists come in with its tiles as a map of that area is shown. The run checks the
  # cartridge against the interpreter after every pass.
  def test_a_walking_background_whose_areas_have_their_own_colours_plays_as_the_interpreter_does
    lists = { shrine: lists_from(0, 6), clearing: lists_from(6, 6) }
    program = color_program do
      screen :tiled
      rows = lists.to_h { |name, colored| [name, ManyTiles.declare_listed(self, name, colored)] }
      tick = var :tick, 0
      where = var :room, 0
      ground = background :ground, tiles: { shrine: :shrine, clearing: :clearing },
                                   map: { shrine: { hall: [rows[:shrine]] }, clearing: { glade: [rows[:clearing]] } }
      game_loop do
        tick.add! 1
        (tick == 3).then { where.set! 1 }
        (tick == 7).then { where.set! 0 }
        ground.show_map where
      end
    end

    assert_equal VBlank::Graphics::Color.rgb(31, 0, 0), game_player.run(program, frames: 12).screen.pixel(0, 0)
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
  # tiles (test/all/vblank/builder/test_background_tile_sets.rb); this is the Color's rooms for it. The run
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
