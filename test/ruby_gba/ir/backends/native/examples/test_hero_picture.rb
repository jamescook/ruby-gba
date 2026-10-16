# frozen_string_literal: true

require "test_helper"
require "native_comparison"
require RubyGBA.root.join("examples/hero").to_s

# examples/hero.rb built for the desktop shows the interpreter's picture pixel for pixel, frame
# by frame, over a recorded walk: the file screen, a new game in file 1, east past the pond and
# north into the mist, the signpost read with A while its words type in, the walk saved with
# START, and SELECT back to the file screen with the map of the walk in its corner. Its
# variables and which sprites it draws match on every frame too.
#
# That one walk goes through most of what the game is made of: a camera that follows a sprite
# over a world bigger than the screen, a layer in front of the hero seen through by an amount
# worked out each frame, a canvas the game letters and dots as it runs, one painted picture
# shown on two screens, and three files in save memory.
class TestHeroPicture < Minitest::Test
  include NativeComparison

  # A on the file screen picks file 1 and A again starts a new game; then the walk.
  RUN = Ractor.make_shareable(
    NativeComparison.held_for([1..1, :a], [3..3, :a], [6..6, :a], [20..45, :right], [46..70, :up],
                              [75..75, :start], [84..84, :select])
  )
  FRAMES = 96

  private def program = Native.new.checked_program(Hero::GAME, err: nil)

  def test_hero_matches_the_interpreter_through_a_recorded_walk
    moments = reference_snapshots(program, frames: FRAMES, buttons: RUN)

    assert_native_matches_reference(program, frames: FRAMES, buttons: RUN, played: moments)

    walked = moments[72]

    assert_operator walked.variables[:steps], :>, 20, "the hero should have walked"
    assert_operator walked.variables[:mist], :>, 0, "north, into the mist"
    assert_operator moments.map(&:picture).uniq.length, :>, 40, "and the picture moved with the walk"
    refute_equal walked.picture, moments.last.picture, "SELECT should have gone back to the file screen"
  end

  # The same walk saved, the console switched off and on, and the file continued: the hero is
  # back where the save left them, out of the bytes the game as C wrote.
  def test_a_walk_saved_as_c_continues_where_it_was_saved
    store = SaveImage.new
    saved = CheckedPlayer.new(save: store).input_each_frame { |frame| RUN.fetch(frame, []) }.run(program, frames: 82)

    continued = CheckedPlayer.new(save: store).input_each_frame { |frame| [1, 3].include?(frame) ? [:a] : [] }
                                .run(program, frames: 8)

    assert_operator saved[:steps], :>, 20
    assert_equal [saved[:px], saved[:py], saved[:steps]], [continued[:px], continued[:py], continued[:steps]]
  end
end
