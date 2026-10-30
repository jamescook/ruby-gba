# frozen_string_literal: true

require "test_helper"

# The pixelate that walks — `pixelate_out`, `pixelate_in`, and the size a game can read to
# sequence a scene change.
#
# `pixelate` on its own sets a size where it is called; this pack walks that size over
# frames. Nothing is redrawn, so what a test looks at is the same drawing showing in
# bigger blocks as the frames pass, and as it was drawn again once the walk comes back.
class TestScreenPixelate < Minitest::Test
  private def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  # A painted screen with nothing on a grid, so every size of block is a different
  # picture. +timeline+ is run each frame with the frame's number.
  private def painted_game(&timeline)
    program do
      screen :bitmap
      frame = var :frame, 0
      game_loop do
        clear_screen :black
        9.times { |i| fill_rect 3 + (i * 25), 5 + (i * 13), 14, 9, %i[red green blue][i % 3] }
        12.times { |i| pixel 7 + (i * 19), 150 - (i * 11), :white }
        frame.add! 1
        instance_exec(frame, &timeline)
      end
    end
  end

  # --- what it refuses and warns about ---

  def test_a_length_that_is_not_a_positive_whole_number_of_frames_is_refused
    error = assert_raises(ArgumentError) { painted_game { |_frame| pixelate_out frames: 0 } }

    assert_match(/positive whole number of frames/, error.message)
    assert_raises(ArgumentError) { painted_game { |_frame| pixelate_out frames: 4, duration: 1 } }
  end

  private def findings_for(program)
    VBlank::IR::Guardrails::Validator.new.run(program, autofix: false).warnings.map(&:check)
  end

  def test_pixelating_out_and_never_in_is_a_warning
    stuck = painted_game { |frame| (frame == 2).then { pixelate_out } }
    back = painted_game do |frame|
      (frame == 2).then { pixelate_out }
      (frame == 50).then { pixelate_in }
    end

    assert_includes findings_for(stuck), :pixelated_out_never_in
    refute_includes findings_for(back), :pixelated_out_never_in
  end

  def test_a_walk_with_no_game_loop_is_a_warning
    no_frames = program do
      screen :bitmap
      clear_screen :red
      pixelate_out
      pixelate_in
      halt
    end

    assert_includes findings_for(no_frames), :pixelate_needs_game_loop
  end
end
