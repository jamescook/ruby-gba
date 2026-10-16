# frozen_string_literal: true

require "test_helper"

# WHEN THE WINDOW WRITES ITS SAVE FILE (runtime/rg_save.c, rg_save_file_is_due). A game saves a
# piece each frame over several frames, and a file written after every piece would be written
# several times for one save — and sixty times a second for a game that keeps a clock in a
# `save_var`. So the window asks at the end of every frame whether the file is due, and it is due
# once a frame has gone by with nothing saved. A game that never stops saving gets its file
# about once a second all the same, so a crash never costs more than that.
#
# The rule is plain counting, so it is asked directly, through a small C program, with no window.
class TestNativeSaveFile < Minitest::Test
  Zig = RubyGBA::IR::Backends::Native::Zig
  HARNESS = Ractor.make_shareable(File.expand_path("save_harness.c", __dir__))

  def test_a_game_that_saves_nothing_has_no_file_due
    assert_equal [[], false], due_over(frames: 200, saving: 0)
  end

  # A save written over five frames: nothing is due while it is going on, nor at the end of its
  # last frame, and the file is due at the end of the first frame with nothing saved.
  def test_the_file_is_due_once_the_first_frame_after_a_save_has_gone_by
    assert_equal [[6], false], due_over(frames: 200, saving: 5)
  end

  # A game saving on every frame is never quiet, and is due every sixty frames.
  def test_a_game_that_never_stops_saving_has_its_file_due_about_once_a_second
    assert_equal [[60, 120, 180], true], due_over(frames: 200, saving: 200)
  end

  # A file that could not be written stays owed, and is tried again once a second rather than
  # on every frame.
  def test_a_file_that_could_not_be_written_is_due_again_a_second_later
    assert_equal [[2, 62, 122, 182], true], due_over(frames: 200, saving: 1, writes: false)
  end

  private

  # The frames the file was due at the end of, and whether something is still owed to a file
  # after the last — at both of the settings the backend is built at, which have to agree.
  def due_over(frames:, saving:, writes: true)
    checked, fast = %i[checked fast].map do |mode|
      exe = Zig.compile_without_sdl([HARNESS, File.join(Zig::RUNTIME_DIR, "rg_save.c")], mode: mode)
      Zig.run_program(exe, input: "play #{frames} #{saving} #{writes ? 1 : 0}\n")
    end
    assert_equal checked, fast, "the checked and the optimised build should answer alike"
    due, owed = checked.split("unwritten")
    [due.split.map(&:to_i), owed.to_i == 1]
  end
end
