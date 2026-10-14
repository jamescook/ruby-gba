# frozen_string_literal: true

require "test_helper"
require "differential"

# The pixelate that walks — `pixelate_out`, `pixelate_in`, and the size a game can read to
# sequence a scene change.
#
# `pixelate` on its own sets a size where it is called; this pack walks that size over
# frames. Nothing is redrawn, so what a test looks at is the same drawing showing in
# bigger blocks as the frames pass, and as it was drawn again once the walk comes back.
class TestScreenPixelate < Minitest::Test
  include Differential

  WIDTH = 240
  HEIGHT = 160
  LARGEST = 16

  def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  # A painted screen with nothing on a grid, so every size of block is a different
  # picture. +timeline+ is run each frame with the frame's number.
  def painted_game(&timeline)
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

  def picture_at(program, frames)
    screen = Reference.new.run(program, frames: frames).screen
    Array.new(HEIGHT) { |y| Array.new(WIDTH) { |x| screen.pixel(x, y) } }
  end

  # The size of block each of the first +frames+ frames shows: found by putting the picture
  # as drawn into blocks of every size and seeing which one the frame is.
  def sizes_shown(program, frames)
    drawn = picture_at(painted_game { |_frame| nil }, 2)
    by_size = (1..LARGEST).to_h do |size|
      [Array.new(HEIGHT) { |y| Array.new(WIDTH) { |x| drawn[y - (y % size)][x - (x % size)] } }, size]
    end
    (1..frames).map { |n| by_size.fetch(picture_at(program, n)) }
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
    late = Reference.new.run(swapping, frames: 40)

    assert_equal Color.resolve(:red), Reference.new.run(swapping, frames: 5).screen.pixel(120, 80),
                 "not before the blocks were at their biggest"
    assert_equal Color.resolve(:blue), late.screen.pixel(120, 80), "the scene changed once they were"
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

  def test_a_length_that_is_not_a_positive_whole_number_of_frames_is_refused
    error = assert_raises(ArgumentError) { painted_game { |_frame| pixelate_out frames: 0 } }

    assert_match(/positive whole number of frames/, error.message)
    assert_raises(ArgumentError) { painted_game { |_frame| pixelate_out frames: 4, duration: 1 } }
  end

  def findings_for(program)
    RubyGBA::IR::Guardrails::Validator.new.run(program, autofix: false).warnings.map(&:check)
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
