# frozen_string_literal: true

require "test_helper"

# A SCENE THAT RUNS LATE ON THE FRAME THE GAME HANDS OVER TO IT, said by `rom.profile`.
#
# The play scene here does enough work each pass to fill most of a frame, and holds most of the
# 32K the console keeps sprite pictures in. The work alone fits a frame; the work and the copy
# of the pictures, on the pass the scene takes over, do not. That is a measured window, so the
# work is a number taken from a run, with room either side of it.
class TestHandOvers < Minitest::Test
  def setup = require_emulator!

  HEAVY = 14 # pictures, 64 by 64 in sixteen colours, two thousand bytes each
  LIGHT = 1
  WORK = 10_000 # trips round a loop each pass: inside a frame alone, past it with the heavy copy

  # +work_in+ is where the work is done each pass: in the play scene, or in the game loop
  # outside it, where it runs on the pass that copies the pictures too.
  private def game(pictures:, loads_first: false, work_in: :scene, **build)
    RubyGBA.build("HANDOVER", out: nil, err: nil, **build) do
      screen :tiled
      random = Random.new(7)
      colors = Array.new(16) { |n| Color.rgb(n * 2, 31 - (n * 2), (n * 5) % 32) }
      pictures.times do |n|
        image(:"art#{n}", width: 64, height: 64, colors: colors, places: Array.new(64 * 64) { random.rand(16) })
      end
      var :state, 0
      sum = var :sum, 0
      scene(:title) {}
      scene(:play, loads_first: loads_first) do
        pictures.times { |n| sprite :"art#{n}", at: [(n % 4) * 60, (n / 4) * 40] }
        repeat(WORK) { |i| sum.set! sum + (i * 3) } if work_in == :scene
      end
      game_loop do
        case_var(:state) do
          when_val 0, :title
          when_val 1, :play
        end
        repeat(WORK) { |i| sum.set! sum + (i * 3) } if work_in == :loop
      end
    end
  end

  private def profile_of(rom)
    out = StringIO.new
    rom.profile(out: out, frames: 10, settle: 2)
    out.string
  end

  def test_a_scene_late_on_its_hand_over_is_named_with_loads_first
    said = profile_of(game(pictures: HEAVY))

    assert_match(/When the game changes to the :play scene, that frame runs past its end/, said)
    assert_match(/scene :play, loads_first: true/, said)
  end

  def test_a_scene_that_loads_first_is_not_named
    refute_match(/:play scene/, profile_of(game(pictures: HEAVY, loads_first: true)))
  end

  # Loading first moves the scene's own work off the copying pass, and not the game loop's.
  def test_a_scene_that_loads_first_is_named_when_its_copy_and_the_loop_do_not_fit
    said = profile_of(game(pictures: HEAVY, loads_first: true, work_in: :loop))

    assert_match(/The :play scene loads first, but the frame that puts its pictures up still runs past its end/, said)
  end

  # A build that measures the game plays each scene already, and says it as it finishes.
  def test_a_build_that_measures_names_a_scene_late_on_its_hand_over
    err = StringIO.new
    game(pictures: HEAVY, profile: true, err: err)

    assert_match(/When the game changes to the :play scene, that frame runs past its end/, err.string)
  end

  def test_a_scene_whose_hand_over_fits_is_not_named
    refute_match(/:play scene/, profile_of(game(pictures: LIGHT)))
  end
end
