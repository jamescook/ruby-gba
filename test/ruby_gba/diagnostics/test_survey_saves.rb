# frozen_string_literal: true

require "test_helper"

require "stringio"

# A MEASURED BUILD PLAYS A SAVE on each screen that saves. Nobody plays the game while it is
# measured, so nobody saves, and the routines that write a save a piece a pass measured as
# nothing: a game wanting them in the quick memory had to insist with `fast: true`, which put them
# ahead of what every screen runs every frame. So each screen whose code saves is measured again
# with a save of its record started as its frames begin, and the save's routines are weighed by
# what they really cost, on the screens they cost it on.
#
# The screen as it plays without a save is still what the build's warnings are read from: a save
# is a few passes now and then, and a screen that keeps up between them is not a slow screen.
class TestSurveySaves < Minitest::Test
  Profiler = RubyGBA::Diagnostics::Profiler
  STEP = RubyGBA::Messages::MadeNames.make(:save_record, record: :file, piece: :step)

  # A title screen that never saves, and play, which saves when A is pressed — which, measured
  # with nobody at the controls, it never is.
  private def rom
    game = RubyGBA.game "SAVES" do
      screen :bitmap
      score = var :score, 0
      files = save_data :file, copies: 1 do
        keep score
      end
      var :where, 0
      scene(:title) { clear_screen :black }
      scene(:play) do
        score.add! 1
        pressed(:a).then { files[0].save }
      end
      game_loop do
        case_var(:where) do
          when_val 0, :title
          when_val 1, :play
        end
      end
    end
    game.build_rom(out: StringIO.new, err: StringIO.new, profile: false)
  end

  def setup
    require_emulator!
    @survey = Profiler.survey_scenes(rom, frames: 20)
  end

  def test_the_screen_that_saves_is_weighed_with_a_save_running
    assert_operator Profiler.work_in(@survey.saving.fetch(:play)).fetch(STEP, 0), :>, 0, "play is measured writing a save"
    assert_operator @survey.work.fetch(STEP, 0), :>, 0, "...and that is what the build weighs"
    refute @survey.saving.key?(:title), "the title screen never saves, so it is measured once"
  end

  def test_what_the_build_warns_from_is_the_screen_without_a_save
    assert_equal 0, Profiler.work_in(@survey.scenes.fetch(:play)).fetch(STEP, 0)
  end
end
