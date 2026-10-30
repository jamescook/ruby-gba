# frozen_string_literal: true

require "test_helper"
require "differential"

# THE TESTS OF vblank/effects/packs/test_screen_pixelate.rb THAT ONLY THE GAME BOY ADVANCE CAN PLAY, kept apart so that the
# Game Boy Color's run never loads them (test/console/gba); the rest are in that file.
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

  # What makes a scene change writable: the swap waits for the picture to be unreadable.
  def test_the_size_can_be_read_to_swap_scenes_while_nobody_can_read_the_screen
    swapping = program do
      screen :bitmap
      frame = var :frame, 0
      shade = var :shade, 0
      game_loop do
        (shade == 0).then { clear_screen :red }.else { clear_screen :blue }
        frame.add! 1
        (frame == 2).then { pixelate_out frames: 6 }
        ((pixelate_size == 16) & (shade == 0)).then do
          shade.set! 1
          pixelate_in frames: 6
        end
      end
    end
    late = game_player.run(swapping, frames: 40)

    assert_equal Color.resolve(:red), game_player.run(swapping, frames: 5).screen.pixel(120, 80),
                 "not before the blocks were at their biggest"
    assert_equal Color.resolve(:blue), late.screen.pixel(120, 80), "the scene changed once they were"
  end

  # The size a game reads is the size the screen is showing on that frame, not the one it
  # will show on the next. That is what makes "swap when it reads 16" a swap nobody sees:
  # the frame the game acts on is already in the biggest blocks.
  def test_the_size_read_is_the_size_the_screen_is_showing
    watching = painted_game do |frame|
      reached = var :reached, 0
      (frame == 2).then { pixelate_out frames: 8 }
      ((pixelate_size == 16) & (reached == 0)).then { reached.set! frame }
    end
    reached = game_player.run(watching, frames: 30)[:reached]

    assert_operator reached, :>, 2
    assert_equal LARGEST, sizes_shown(watching, reached).last, "on the frame the game first read 16"
  end

  # A scene swapped on the frame the size reads 16 is hidden on both sides: that frame is
  # in the biggest blocks, and so is the next, the first of the walk back.
  def test_the_frame_after_the_walk_turns_round_is_still_in_the_biggest_blocks
    turning = painted_game do |frame|
      turned = var :turned, 0
      (frame == 2).then { pixelate_out frames: 8 }
      ((pixelate_size == 16) & (turned == 0)).then do
        turned.set! frame
        pixelate_in
      end
    end
    turned = game_player.run(turning, frames: 40)[:turned]
    seen = sizes_shown(turning, turned + 3)

    assert_equal [LARGEST, LARGEST], seen[(turned - 1)..turned], "the frame it turned on, and the one after"
    assert_operator seen[turned + 1], :<, LARGEST, "and then it comes back"
  end

  # --- on the console ---

  def test_the_console_walks_the_same_sizes_on_the_same_frames
    walking = program do
      screen :tiled
      layers :world, :ui
      image(:slope, "#" => :red, "." => :blue) { (0...8).map { |r| (0...8).map { |c| c > r ? "#" : "." }.join }.join("\n") }
      image(:dot, "." => :transparent, "#" => :white) { (0...8).map { |r| (0...8).map { |c| (r + c).even? ? "#" : "." }.join }.join("\n") }
      tiles :set, "a" => :slope
      room = nil
      layer(:world) { room = background :room, tiles: :set, map: ["a" * 32] * 32 }
      layer(:ui) { sprite :dot, at: [100, 60] }
      frame = var :frame, 0
      game_loop do
        frame.add! 1
        room.scroll_by 1, 0
        (frame == 2).then { pixelate_out frames: 6, under: :ui }
        (frame == 12).then { pixelate_in }
      end
    end

    [3, 5, 8, 11, 14, 17, 22].each { |frames| assert_backends_agree(walking, frames: frames, name: "WALK#{frames}") }
  end

  # --- what it refuses and warns about ---

  private def findings_for(program)
    VBlank::IR::Guardrails::Validator.new.run(program, autofix: false).warnings.map(&:check)
  end

end
