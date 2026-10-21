# frozen_string_literal: true

require "test_helper"
require "differential"

# THE TESTS OF ruby_gba/effects/packs/test_screen_pixelate.rb THAT ONLY THE GAME BOY ADVANCE CAN PLAY, kept apart so that the
# Game Boy Color's run never loads them (TestSuites::ADVANCE_DIR); the rest are in that file.
#
# The pixelate that walks — `pixelate_out`, `pixelate_in`, and the size a game can read to
# sequence a scene change.
#
# `pixelate` on its own sets a size where it is called; this pack walks that size over
# frames. Nothing is redrawn, so what a test looks at is the same drawing showing in
# bigger blocks as the frames pass, and as it was drawn again once the walk comes back.
class TestScreenPixelateOnTheAdvance < Minitest::Test
  include Differential

  WIDTH = 240
  HEIGHT = 160
  LARGEST = 16

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

  private def picture_at(program, frames) = rows_of(game_player.run(program, frames: frames).screen)

  private def rows_of(screen) = Array.new(HEIGHT) { |y| Array.new(WIDTH) { |x| screen.pixel(x, y) } }

  # The size of block each of the first +frames+ frames shows: found by putting the picture
  # as drawn into blocks of every size and seeing which one the frame is. Every frame is read
  # from ONE run as it settles, rather than the game played again for each, which costs the
  # square of the frames. The first look comes at the boundary before the first pass, so the
  # run plays one frame more and that look is dropped.
  private def sizes_shown(program, frames)
    drawn = picture_at(painted_game { |_frame| nil }, 2)
    by_size = (1..LARGEST).to_h do |size|
      [Array.new(HEIGHT) { |y| Array.new(WIDTH) { |x| drawn[y - (y % size)][x - (x % size)] } }, size]
    end
    seen = []
    run = game_player
    run.each_vblank { seen << rows_of(run.screen) }
    run.run(program, frames: frames + 1)
    seen.drop(1).first(frames).map { |picture| by_size.fetch(picture) }
  end

  # --- out and back in ---

  def test_pixelating_out_grows_the_blocks_to_the_biggest_and_holds_there
    seen = sizes_shown(painted_game { |frame| (frame == 2).then { pixelate_out frames: 8 } }, 30)

    assert_equal 1, seen.first, "before it starts the picture is as drawn"
    assert_equal LARGEST, seen.last, "it arrives at the biggest block and stays"
    assert_equal seen, seen.sort, "and the blocks only ever grow on the way"
    assert_operator seen.uniq.size, :>, 4, "through sizes in between, not in one jump"
  end

  def test_a_bare_pixelate_in_comes_back_at_the_same_speed
    there_and_back = painted_game do |frame|
      (frame == 2).then { pixelate_out frames: 6 }
      (frame == 20).then { pixelate_in }
    end
    seen = sizes_shown(there_and_back, 40)
    out = seen.index(LARGEST) - seen.index { |size| size > 1 }
    back = seen.rindex { |size| size > 1 } - seen.rindex(LARGEST)

    assert_equal LARGEST, seen[15]
    assert_equal 1, seen.last, "the picture is as drawn again"
    assert_equal out, back, "and it took as long to come back as to go"
  end

  # `frames:` is how long the walk takes, asserted as a relationship rather than a frame
  # number, which would break on any change to where in a frame the effect runs.
  def test_a_longer_walk_takes_proportionally_longer
    arrives = ->(frames) { sizes_shown(painted_game { |frame| (frame == 2).then { pixelate_out frames: frames } }, 60).index(LARGEST) }

    assert_in_delta 2.0, arrives.call(16).to_f / arrives.call(8), 0.5
  end

  def test_a_duration_in_seconds_is_the_frames_it_works_out_to
    arrives = lambda do |**length|
      sizes_shown(painted_game { |frame| (frame == 2).then { pixelate_out(**length) } }, 50).index(LARGEST)
    end

    assert_equal arrives.call(frames: 30), arrives.call(duration: 0.5)
    assert_equal arrives.call(frames: 30), arrives.call, "and half a second is what it takes with nothing said"
  end

  # --- on the console ---

  # --- what it refuses and warns about ---

  private def findings_for(program)
    RubyGBA::IR::Guardrails::Validator.new.run(program, autofix: false).warnings.map(&:check)
  end

end
