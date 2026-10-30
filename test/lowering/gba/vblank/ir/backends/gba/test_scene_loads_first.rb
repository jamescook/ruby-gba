# frozen_string_literal: true

require "test_helper"

# A scene that LOADS FIRST, on the console. A scene copies its pictures into video memory as it
# takes over, and on the pass it shares with the scene's first pass of game the two together
# can run past the end of the frame — so whether a hand-over costs a frame depends on how much
# art the scene holds, and changes as a game adds rooms. `loads_first: true` gives the copy a
# pass of its own and starts the work on the next, so a hand-over costs the same however much
# art there is.
#
# The play scene does enough work each pass to fill most of a frame: the work alone fits, and
# the work with the copy of most of the 32K the console keeps sprite pictures in does not. That
# is a measured window, so the work is a number taken from a run, with room either side of it.
class TestSceneLoadsFirst < Minitest::Test
  HEAVY = 14 # pictures, 64 by 64 in sixteen colours, two thousand bytes each
  LIGHT = 1
  WORK = 10_000 # trips round a loop each pass: inside a frame alone, past it with the heavy copy
  FRAMES = 30

  private def hand_over(pictures:, loads_first:)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      random = Random.new(7)
      colors = Array.new(16) { |n| Color.rgb(n * 2, 31 - (n * 2), (n * 5) % 32) }
      pictures.times do |n|
        image(:"art#{n}", width: 64, height: 64, colors: colors, places: Array.new(64 * 64) { random.rand(16) })
      end
      state = var :state, 0
      step = var :step, 0
      sum = var :sum, 0
      scene(:title) { (step == 4).then { state.set! 1 } }
      scene(:play, loads_first: loads_first) do
        pictures.times { |n| sprite :"art#{n}", at: [(n % 4) * 60, (n / 4) * 40] }
        repeat(WORK) { |i| sum.set! sum + (i * 3) }
      end
      game_loop do
        case_var(:state) do
          when_val 0, :title
          when_val 1, :play
        end
        step.add! 1
      end
    end
    builder.finalize_program
    builder.program
  end

  # How many passes of the game loop the console finished in FRAMES frames: one fewer than
  # another build means one of its passes ran into a second frame.
  private def passes_finished(pictures:, loads_first:)
    rom = assemble_rom(hand_over(pictures: pictures, loads_first: loads_first), name: "LOADFRST")
    assert_emulator_loads_rom(rom, frames: FRAMES, count_passes: true).passes
  end

  def test_a_hand_over_costs_a_frame_more_for_more_art
    light = passes_finished(pictures: LIGHT, loads_first: false)

    assert_equal light - 1, passes_finished(pictures: HEAVY, loads_first: false),
                 "with the copy on the same pass as the work, the heavy scene's first pass ran into the next frame"
  end

  def test_a_scene_that_loads_first_costs_the_same_however_much_art_it_holds
    light = passes_finished(pictures: LIGHT, loads_first: true)

    assert_equal light, passes_finished(pictures: HEAVY, loads_first: true),
                 "the heavy copy had its own pass, and still ran into the next frame"
  end
end
