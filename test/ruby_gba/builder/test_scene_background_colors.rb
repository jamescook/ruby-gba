# frozen_string_literal: true

require "test_helper"
require "differential"

# EACH SCENE'S BACKGROUND COLOURS ARE ITS OWN. The console holds one table of background
# colours, in sixteen groups of sixteen, and two scenes are never on screen together — so a
# title screen and a room each get the whole table beside what every scene shows, the way a
# scene's tile pictures already take turns with the other scenes'.
class TestSceneBackgroundColors < Minitest::Test
  include Differential

  OWN = %i[transparent red green].freeze
  SHIMMER = %i[transparent yellow white].freeze
  BAR = Array.new(64) { |i| (i % 8) < 4 ? :red : :green }.freeze

  # Fifteen colours of a tile all its own, so every tile of the room fills a group of sixteen.
  def self.inks(tile) = Array.new(15) { |k| RubyGBA::Graphics::Color.rgb(tile, k * 2, 9) }

  ROOM_TILES = 16

  def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  # A title whose light rays shimmer — a layer drawn with other colours keeps a group to
  # itself — then, from the sixth pass, a room whose sixteen tiles fill all sixteen groups.
  # Together they need seventeen groups; one screen at a time, neither needs more than sixteen.
  def title_then_room(switch_at: 6, tint: nil)
    klass = self.class
    program do
      screen :tiled
      image :bar, width: 8, height: 8, data: BAR, colors: OWN
      colors :shimmer, SHIMMER
      tiles :light, "#" => :bar
      keys = {}
      ROOM_TILES.times do |t|
        ink = klass.inks(t)
        image :"stone#{t}", width: 8, height: 8, data: Array.new(64) { |i| ink[i % 15] }
        keys[("a".ord + t).chr] = :"stone#{t}"
      end
      tiles :stones, **keys
      room_map = Array.new(20) { |r| Array.new(30) { |c| ("a".ord + ((r + c) % ROOM_TILES)).chr }.join }

      var :mode, 0
      pass = var :pass, 0
      scene(:title) do
        rays = background :rays, tiles: :light, map: Array.new(20) { "#" * 30 }
        rays.draw_with [:shimmer], showing: (pass >> 3) & 1
      end
      scene(:room) { background :ground, tiles: :stones, map: room_map }
      tint(*tint) if tint
      game_loop do
        pass.add! 1
        (pass == switch_at).then { set! :mode, 1 }
        case_var(:mode) do
          when_val 0, :title
          when_val 1, :room
        end
      end
    end
  end

  def test_a_title_and_a_room_that_fill_the_table_between_them_build
    assert_kind_of String, GBA.new.lower(title_then_room)
  end

  def test_the_rays_shimmer_on_the_title
    [3, 10].each { |frames| assert_backends_agree(title_then_room(switch_at: 99), frames: frames, name: "SBGT") }
  end

  # The room shows its own colours from the frame it takes over.
  def test_the_room_shows_its_own_colors
    [6, 7, 9].each { |frames| assert_backends_agree(title_then_room, frames: frames, name: "SBGR") }
  end

  # A room taken over under a tint arrives tinted, not at full colour.
  def test_the_rooms_colors_arrive_through_a_tint
    [7, 9].each { |frames| assert_backends_agree(title_then_room(tint: [:red, 50]), frames: frames, name: "SBGN") }
  end

  # One scene that needs more groups than there are is still an error, and it names the scene.
  def test_a_scene_whose_colors_do_not_fit_is_named
    klass = self.class
    prog = program do
      screen :tiled
      keys = {}
      18.times do |t|
        ink = klass.inks(t)
        image :"stone#{t}", width: 8, height: 8, data: Array.new(64) { |i| ink[i % 15] }
        keys[("a".ord + t).chr] = :"stone#{t}"
      end
      tiles :stones, **keys
      image :bar, width: 8, height: 8, data: BAR, colors: OWN
      colors :shimmer, SHIMMER
      tiles :light, "#" => :bar
      var :mode, 0
      scene(:crowded) do
        background :ground, tiles: :stones, map: Array.new(20) { |r| Array.new(30) { |c| ("a".ord + ((r + c) % 18)).chr }.join }
        background(:rays, tiles: :light, map: ["#"]).draw_with :shimmer
      end
      game_loop { case_var(:mode) { when_val 0, :crowded } }
    end
    error = assert_raises(GBA::LoweringError) { GBA.new.lower(prog) }
    assert_includes error.message, ":crowded"
  end

  # The rays told to shimmer from inside the room, every pass, while the room is up: the
  # room's colours stay its own, and the title shimmers again when it comes back.
  def rays_told_from_outside
    klass = self.class
    program do
      screen :tiled
      image :bar, width: 8, height: 8, data: BAR, colors: OWN
      colors :shimmer, SHIMMER
      tiles :light, "#" => :bar
      keys = {}
      ROOM_TILES.times do |t|
        ink = klass.inks(t)
        image :"stone#{t}", width: 8, height: 8, data: Array.new(64) { |i| ink[i % 15] }
        keys[("a".ord + t).chr] = :"stone#{t}"
      end
      tiles :stones, **keys
      room_map = Array.new(20) { |r| Array.new(30) { |c| ("a".ord + ((r + c) % ROOM_TILES)).chr }.join }
      var :mode, 0
      pass = var :pass, 0
      rays = nil
      scene(:title) { rays = background :rays, tiles: :light, map: Array.new(20) { "#" * 30 } }
      scene(:room) do
        background :ground, tiles: :stones, map: room_map
        rays.draw_with [:shimmer], showing: (pass >> 2) & 1
      end
      game_loop do
        pass.add! 1
        (pass == 4).then { set! :mode, 1 }
        (pass == 12).then { set! :mode, 0 }
        case_var(:mode) do
          when_val 0, :title
          when_val 1, :room
        end
      end
    end
  end

  def test_rays_told_from_outside_their_scene_leave_the_room_alone
    [6, 10, 14, 18].each { |frames| assert_backends_agree(rays_told_from_outside, frames: frames, name: "SBGO") }
  end

  # Backgrounds every scene shows that walk between areas, beside a scene with a background of
  # its own: the area's colours and the scene's own both stay right as the ground walks into
  # the second area and the scene takes over.
  def walking_everywhere_beside_a_scene
    program do
      screen :tiled
      image(:shrine_floor, "#" => :red, "." => :blue) { (["#.#.#.#."] * 8).join("\n") }
      image(:clearing_grass, "#" => :green, "." => :yellow) { (["#..##..#"] * 8).join("\n") }
      image(:sign, "#" => :white, "." => :transparent) { (["##....##"] * 8).join("\n") }
      tiles :shrine, "#" => :shrine_floor
      tiles :clearing, "#" => :clearing_grass
      tiles :signs, "#" => :sign
      grid = (0...20).map { "#" * 30 }
      ground = background :ground, tiles: { shrine: :shrine, clearing: :clearing },
                                   map: { shrine: { hall: grid }, clearing: { glade: grid } }
      var :mode, 0
      pass = var :pass, 0
      room = var :room, 0
      scene(:plain) { nil }
      scene(:signed) { background :board, tiles: :signs, map: ["#" * 30] * 4 }
      game_loop do
        pass.add! 1
        (pass == 3).then { room.set! 1 }
        (pass == 5).then { set! :mode, 1 }
        ground.show_map room
        case_var(:mode) do
          when_val 0, :plain
          when_val 1, :signed
        end
      end
    end
  end

  def test_backgrounds_every_scene_shows_keep_walking_beside_a_scenes_own
    [4, 6, 8].each { |frames| assert_backends_agree(walking_everywhere_beside_a_scene, frames: frames, name: "SBGW") }
  end

  # Fifteen tiles and the backdrop fill the sixteen groups on the one screen, so the rays
  # beside them get no group of their own — said as that, not as the rays having too many
  # colours.
  def test_rays_crowded_out_on_their_own_screen_say_so
    klass = self.class
    prog = program do
      screen :tiled
      keys = {}
      15.times do |t|
        ink = klass.inks(t)
        image :"stone#{t}", width: 8, height: 8, data: Array.new(64) { |i| ink[i % 15] }
        keys[("a".ord + t).chr] = :"stone#{t}"
      end
      tiles :stones, **keys
      image :bar, width: 8, height: 8, data: BAR, colors: OWN
      colors :shimmer, SHIMMER
      tiles :light, "#" => :bar
      var :mode, 0
      scene(:both) do
        background :ground, tiles: :stones, map: Array.new(20) { |r| Array.new(30) { |c| ("a".ord + ((r + c) % 15)).chr }.join }
        background(:rays, tiles: :light, map: ["#"]).draw_with :shimmer
      end
      game_loop { case_var(:mode) { when_val 0, :both } }
    end
    error = assert_raises(GBA::LoweringError) { GBA.new.lower(prog) }
    assert_includes error.message, "no group is left"
    assert_includes error.message, ":both"
  end
end
