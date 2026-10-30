# frozen_string_literal: true

require "test_helper"
require "differential"

# The tests of test_big_maps.rb whose games show a second background while another is showing, and
# a Game Boy Color's hardware cannot, so they play on the Advance's runs alone.
class TestBigMapsOnTheAdvance < Minitest::Test
  include Differential

  KEYS = %w[r g b w].freeze

  private def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  # A map with no pattern that repeats every 32 or 64 cells, so a column or row left over
  # from another part of the map, or copied to the wrong place, shows as the wrong colour.
  # With +holes+ two cells in three are empty, for a layer the one behind shows through.
  def scrambled(cols, rows, seed: 7, holes: false)
    random = Random.new(seed)
    Array.new(rows) do
      Array.new(cols) { holes && random.rand(3).positive? ? " " : KEYS[random.rand(KEYS.size)] }.join
    end
  end

  def tileset(builder)
    builder.instance_eval do
      image(:r, "#" => :red) { (["#" * 8] * 8).join("\n") }
      image(:g, "#" => :green) { (["#" * 8] * 8).join("\n") }
      image(:b, "#" => :blue) { (["#" * 8] * 8).join("\n") }
      image(:w, "#" => :white, "." => :red) { (["####...."] * 4 + ["#" * 8] * 4).join("\n") }
      tiles :ground, "r" => :r, "g" => :g, "b" => :b, "w" => :w
    end
  end

  # A ground and scenery over it, both with big rooms in two areas, the view moving every
  # pass, walked into the second area on pass 5 and back on pass 12, each time to a far part
  # of the map. Every tile of an area is a different picture from the tile of the same key in
  # the other. With +scene+, both layers belong to a scene given those words, which a title
  # hands over to on pass 3.
  private def two_layers_between_areas(tinted: false, scene: nil)
    test = self
    program do
      screen :tiled
      test.tileset(self)
      image(:moss, "#" => :green, "." => :blue) { (["#.#.#.#."] * 8).join("\n") }
      image(:sand, "#" => :yellow) { (["#" * 8] * 8).join("\n") }
      image(:arch, "#" => :gray, "." => :transparent) { (["##....##"] * 8).join("\n") }
      image(:post, "#" => :white, "." => :transparent) { (["...##..."] * 8).join("\n") }
      image(:bush, "#" => :black, "." => :transparent) { ((["........"] * 4) + (["########"] * 4)).join("\n") }
      image(:vine, "#" => :blue, "." => :transparent) { ((["########"] * 2) + (["........"] * 6)).join("\n") }
      tiles :wilds, "r" => :moss, "g" => :sand, "b" => :b, "w" => :w
      tiles :arches, "r" => :arch, "g" => :post, "b" => :arch, "w" => :post
      tiles :trees, "r" => :bush, "g" => :vine, "b" => :bush, "w" => :vine
      pass = var :pass, 0
      room = var :room, 0
      x = var :view_x, 16
      y = var :view_y, 8
      tint :blue, 20 if tinted
      declare = lambda do
        [background(:ground, tiles: { shrine: :ground, wilds: :wilds },
                             map: { shrine: { hall: test.scrambled(100, 80, seed: 5) },
                                    wilds: { woods: test.scrambled(100, 80, seed: 9) } }),
         background(:scenery, tiles: { shrine: :arches, wilds: :trees },
                              map: { shrine: { hall_arch: test.scrambled(100, 80, seed: 11, holes: true) },
                                     wilds: { glade_trees: test.scrambled(100, 80, seed: 13, holes: true) } })]
      end
      play = lambda do |ground, scenery|
        (pass == 5).then { room.set! 1; x.set! 400; y.set! 300 }
        (pass == 12).then { room.set! 0; x.set! 90; y.set! 50 }
        x.add! 3
        y.add! 1
        ground.show_map room
        scenery.show_map room
        ground.scroll_to x, y
        scenery.scroll_to x, y
      end
      if scene
        state = var :state, 0
        scene(:title) { (pass == 3).then { state.set! 1 } }
        scene(:playing, **scene) { play.call(*declare.call) }
        game_loop do
          pass.add! 1
          case_var(:state) do
            when_val 0, :title
            when_val 1, :playing
          end
        end
      else
        layers = declare.call
        game_loop do
          pass.add! 1
          play.call(*layers)
        end
      end
    end
  end

  # The frames before, on and after each of those two walks.
  AROUND_EACH_WALK = [5, 6, 7, 8, 12, 13, 14, 15].freeze

  # The frame an area arrives is the one that could show part of it: its tiles, both maps and
  # the whole view of each go in with the layers off, and the layers come back on when all of
  # it is there. Both backends show the whole of the new area on that frame.
  def test_the_frame_an_area_arrives_shows_all_of_both_layers
    [false, true].each do |tinted|
      prog = two_layers_between_areas(tinted: tinted)
      AROUND_EACH_WALK.each { |frames| assert_backends_agree(prog, frames: frames, name: "BIG2") }
    end
  end

  def test_those_walks_change_the_whole_picture
    prog = two_layers_between_areas
    before, after = [4, 6].map { |frames| game_player.run(prog, frames: frames).screen.shown }

    assert_operator before.zip(after).count { |was, is| was != is }, :>, 30_000
  end

  # A scene kept out of the quick memory keeps its own code out. Bringing the view of its
  # big rooms along is the frame's work, not the scene's, so the area still arrives whole.
  def test_an_area_arrives_whole_in_a_scene_kept_out_of_the_quick_memory
    prog = two_layers_between_areas(scene: { fast: false })
    AROUND_EACH_WALK.each { |frames| assert_backends_agree(prog, frames: frames, name: "BIG2S") }
  end
end
