# frozen_string_literal: true

require "test_helper"
require "differential"

# WHERE A SEE-THROUGH LAYER'S WORKED-OUT AMOUNTS ARE TURNED INTO WHAT THE DISPLAY IS TOLD.
#
# The display is told the two amounts in the gap after each frame, so the whole of the next
# picture is mixed at one pair. Turning a pair of percentages into the display's sixteenths
# is a multiply, a divide and a clamp for each, and that work used to be written straight
# into the game loop's own body — the routine the framework keeps in the console's quick
# memory first, for every scene. So a title screen kept out of that memory on purpose still
# spent it, and a game whose playing scene had a little room to spare lost its place.
class TestSeeThroughAmountsPlacement < Minitest::Test
  include Differential

  FRAME = RubyGBA::Cartridge::BuildRecord::FRAME_ROUTINE
  RAYS = RubyGBA::Messages::MadeNames.make(:see_through_amounts, layer: :rays)

  private def built(&block)
    builder = Builder.new
    builder.instance_eval(&block)
    builder.emit_pending_functions
    builder.program
  end

  # A title whose light rays step through their two amounts, kept out of the quick memory,
  # and a playing scene. The game walks between them on its own: the title until frame 6,
  # play until frame 12, the title again. +amounts+ gives the pair from the step.
  private def title_and_play(amounts)
    tile = SOLID_TILE
    built do
      screen :tiled
      image(:forest, "#" => rgb(20, 4, 30)) { tile }
      image(:ray, "#" => rgb(16, 8, 2)) { tile }
      image(:field, "#" => :green) { tile }
      tiles :forests, "#" => :forest
      tiles :rays, "#" => :ray
      tiles :fields, "#" => :field
      full = Array.new(20) { "#" * 30 }
      t = var :t, 0
      step = var :step, 0
      where = var :where, 0
      shows, behind = amounts.call(step)
      layers :back, :rays
      scene :title, fast: false do
        layer(:back) { background :forest, tiles: :forests, map: full }
        layer(:rays, shows: shows, shows_behind: behind) { background :ray, tiles: :rays, map: full }
        step.set! (step + 1) % 4
      end
      scene(:playing) { layer(:back) { background :field, tiles: :fields, map: full } }
      game_loop do
        t.add! 1
        (t == 6).then { where.set! 1 }
        (t == 12).then { where.set! 0 }
        case_var(:where) do
          when_val 0, :title
          when_val 1, :playing
        end
      end
    end
  end

  SIMPLE = ->(step) { [57 - (step * 6), 57 + (step * 6)] }
  # The same kind of pair worked out the long way round, the way a game reading a table of
  # its own would.
  INVOLVED = ->(step) { [((114 - (step * 12)) / 2) + (step % 3), ((114 + (step * 12)) / 2) - (step % 3)] }
  FIXED = ->(_step) { [57, 57] }

  private def placement_of(program, **opts)
    backend = GBA.new(**opts)
    backend.lower(program)
    backend.iwram_report
  end

  private def frame_size(amounts) = placement_of(title_and_play(amounts)).sizes[FRAME]

  # THE ONE THAT MATTERS. However the title works its amounts out, the game loop's body is
  # the same size: the working out is code of its own.
  def test_how_the_title_works_out_its_amounts_does_not_grow_the_game_loop
    assert_equal frame_size(SIMPLE), frame_size(INVOLVED)
  end

  # ...and what the game loop does keep for them is a call. A call from the quick memory to
  # a routine left in the cartridge cannot be one jump, because the cartridge is too far
  # away, so it is a few instructions: eight at most.
  def test_worked_out_amounts_cost_the_game_loop_a_call_at_most
    assert_operator frame_size(SIMPLE) - frame_size(FIXED), :<=, 32
  end

  # A title kept out of the quick memory keeps its amounts out with it, with play there.
  def test_a_title_kept_out_of_quick_memory_keeps_its_amounts_out_too
    funcs = placement_of(title_and_play(INVOLVED)).funcs

    refute_includes funcs, RAYS
    assert_includes funcs, :_scene_playing
  end

  # The chooser is charged for the calls the game loop makes to the routine, so nothing it
  # moves comes out bigger than it counted on.
  def test_the_game_loop_is_charged_for_its_call_to_the_amounts
    backend = GBA.new
    backend.lower(title_and_play(INVOLVED))
    short = backend.charged_against_emitted.select { |_name, (charged, emitted)| charged < emitted }

    assert_empty short, "came out bigger than charged: #{short}"
  end

  # THE PICTURE DOES NOT CHANGE, frame by frame: the step moves every frame on the title, so
  # any frame of lag in the pair would show, and the title comes back after play.
  def test_the_console_mixes_each_frame_at_that_frames_pair
    [2, 3, 4, 5, 8, 13, 14, 15].each { |f| assert_backends_agree(title_and_play(INVOLVED), frames: f) }
  end
end
