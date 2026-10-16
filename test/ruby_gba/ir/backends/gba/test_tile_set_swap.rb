# frozen_string_literal: true

require "test_helper"
require "stringio"

# WHAT A SECOND SET OF TILES COSTS THE GAME LOOP, and where the work went instead.
#
# A background that walks between areas brings an area's tiles in as it arrives: the tiles,
# the colours they are drawn in, the map, and for a big map the cells around the view, all
# with the layers switched off. That is a lot of code, and it runs a handful of times an hour.
# The game loop is the code every frame of every screen passes through, and the first thing
# kept in the console's quick memory, so what the loop holds of this should be the question
# "is the set changing?" and a call — not the work itself, once for every background.
#
# What the two backends DRAW as an area arrives is in test/ruby_gba/builder/test_big_maps.rb.
class TestTileSetSwap < Minitest::Test
  FRAME_ROUTINE = RubyGBA::Cartridge::BuildRecord::FRAME_ROUTINE

  # A ground and a layer of scenery over it, each with two maps bigger than the console's
  # grid, walked from one to the other with A and back with B. With +areas+ 2 each map is of
  # an area of its own, drawn from that area's set of tiles; with 1 both are of one area and
  # one set. +busywork+ adds a routine called every pass that does a little more work than
  # bringing a still view along does. +measured+ builds the way a game is built: placed by
  # what a run of it measured.
  private def walk(areas:, tinted: false, busywork: false, measured: false)
    RubyGBA.build("WALK#{areas}#{tinted ? 'T' : 'P'}", profile: measured, out: StringIO.new, err: StringIO.new) do
      screen :tiled
      image(:shrine_floor, "#" => :red) { (["#" * 8] * 8).join("\n") }
      image(:clearing_grass, "#" => :green) { (["#" * 8] * 8).join("\n") }
      image(:shrine_arch, "#" => :blue, "." => :transparent) { (["####...."] * 8).join("\n") }
      image(:clearing_tree, "#" => :white) { (["#" * 8] * 8).join("\n") }
      tiles :shrine, "#" => :shrine_floor
      tiles :clearing, "#" => :clearing_grass
      tiles :arches, "#" => :shrine_arch
      tiles :trees, "#" => :clearing_tree
      ground_map = (0...80).map { "#" * 100 }
      scenery_map = (0...80).map { ("#" * 50) + (" " * 50) }
      if areas == 2
        ground = background :ground, tiles: { shrine: :shrine, clearing: :clearing },
                                     map: { shrine: { hall: ground_map }, clearing: { glade: ground_map } }
        scenery = background :scenery, tiles: { shrine: :arches, clearing: :trees },
                                       map: { shrine: { hall_arch: scenery_map }, clearing: { glade_trees: scenery_map } }
      else
        ground = background :ground, tiles: :shrine, map: { hall: ground_map, glade: ground_map }
        scenery = background :scenery, tiles: :arches, map: { hall_arch: scenery_map, glade_trees: scenery_map }
      end
      where = var :room, 0
      busy = var :busy, 0
      func(:busywork) { 16.times { busy.add! 1 } } if busywork
      tint :blue, 20 if tinted
      game_loop do
        held(:a).then { where.set! 1 }
        held(:b).then { where.set! 0 }
        call :busywork if busywork
        ground.show_map where
        scenery.show_map where
        ground.scroll_to 16, 8
        scenery.scroll_to 16, 8
      end
    end
  end

  private def game_loop_bytes(rom) = rom.built.routines.fetch(FRAME_ROUTINE).size

  private def words(name) = RubyGBA::Messages::MadeNames.words_for_made_name(name)

  # Asking whether the set is changing, and the call, for the two backgrounds together.
  A_QUESTION_AND_A_CALL_FOR_BOTH = 160

  def test_a_second_set_of_tiles_costs_the_game_loop_a_question_and_a_call
    [false, true].each do |tinted|
      grown = game_loop_bytes(walk(areas: 2, tinted: tinted)) - game_loop_bytes(walk(areas: 1, tinted: tinted))

      assert_operator grown, :<=, A_QUESTION_AND_A_CALL_FOR_BOTH,
                      "two sets of tiles made the game loop #{grown} bytes bigger#{' in a game that tints' if tinted}"
    end
  end

  # The work has not gone: it is in a routine of each background's own, which a report of
  # the finished cartridge can name.
  def test_bringing_a_set_in_is_a_routine_of_each_backgrounds_own
    routines = walk(areas: 2).built.routines.keys.map { |name| words(name) }

    assert_includes routines, "bringing background :ground another set of tiles"
    assert_includes routines, "bringing background :scenery another set of tiles"
  end

  VIEWS = ["bringing the view of background :ground along its map",
           "bringing the view of background :scenery along its map"].freeze

  # The two routines kept in the quick memory straight after the game loop are the views'.
  private def assert_views_right_behind_the_loop(kept)
    behind = kept.drop(kept.index(FRAME_ROUTINE) + 1).first(2).map { |name| words(name) || name.to_s }

    assert VIEWS == behind, "kept behind the game loop: #{behind.inspect}, of #{kept.inspect}"
  end

  # The view of a big map is brought along by a routine of the background's own, which the
  # scroll write and an area coming in both call. It is the game loop's own work, so it is
  # kept in the quick memory right behind the loop.
  def test_the_view_routines_are_kept_right_behind_the_game_loop
    assert_views_right_behind_the_loop(walk(areas: 2).built.placement.funcs)
  end

  # A build that measures its game weighs a routine by what a frame was measured to spend in
  # it, and the measuring is done with nobody playing: the view stands still, and bringing it
  # along is a few dozen instructions. Its real work is on the frame a whole view is filled.
  # So a routine that measured busier than the still view, and less busy than the loop, does
  # not go between the two, and cannot take the room the view had as part of the loop.
  def test_a_measured_build_keeps_them_there_ahead_of_a_routine_that_measured_busier
    rom = walk(areas: 2, busywork: true, measured: true)
    work = RubyGBA::Diagnostics::Profiler.survey_scenes(rom).work
    views = work.select { |name, _| VIEWS.include?(words(name)) }

    assert_equal 2, views.size
    views.each_value { |spent| assert_operator work.fetch(:busywork), :>, spent }
    assert_operator work.fetch(:busywork), :<, work.fetch(FRAME_ROUTINE)

    assert_views_right_behind_the_loop(rom.built.placement.funcs)
  end
end
