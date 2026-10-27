# frozen_string_literal: true

require "test_helper"
require "vblank/live"

# A game played by the interpreter a pass at a time through a device: the session hands it
# each pass's picture, asks it which buttons are held and whether to stop, and keeps the
# game's time by its clock. These play through the headless device, whose clock moves only
# when the test says a pass took so long, so nothing here waits for real time to pass.
class TestSession < Minitest::Test
  Session = VBlank::Live::Session
  Headless = VBlank::Live::Headless

  private def game(&block)
    builder = Builder.new
    builder.instance_eval(&block)
    builder.finalize_program
    builder.program
  end

  def test_the_device_is_shown_every_pass_the_game_draws
    device = Headless.new(frames: 3)
    Session.new(game { game_loop { pixel 2, 1, :red } }, device: device).play

    assert_equal 3, device.pictures.size
    picture = device.pictures.last
    assert_equal Color.resolve(:red), picture.pixels[(1 * picture.width) + 2]
  end

  # The buttons held on a frame are read as it ends, for the pass that starts then: so A held
  # on the second and third frames is seen by the third and fourth passes, as on the console.
  def test_buttons_held_on_a_frame_reach_the_pass_after_it
    device = Headless.new(frames: 5, buttons: { 2 => [:a], 3 => [:a] })
    Session.new(game { game_loop { held(:a).then { pixel 0, 0, :red }.else { pixel 0, 0, :blue } } },
                device: device).play

    seen = device.pictures.map { |picture| Color.resolve(:red) == picture.pixels[0] ? :a : :none }
    assert_equal %i[none none a a none], seen
  end

  # A machine too slow to keep up: every pass takes two of the console's frames. The game is
  # told so, and its count of frames moves on by two a pass, as it would on a console that
  # missed every other frame. (The first picture is the frame the game sets itself up in,
  # before its loop first runs, so it has no mark.)
  def test_a_pass_that_takes_two_frames_moves_the_game_on_two
    program = counting_game
    device = Headless.new(frames: 4, pass_seconds: 2 * frame_seconds(program))
    Session.new(program, device: device).play

    assert_equal [nil, 2, 4, 6], device.pictures.map { |picture| marked_frame(picture) }
  end

  # A machine faster than the console waits for each frame to end, so a pass is one frame,
  # the fourth picture is not shown before the fourth frame has ended, and the play went at
  # exactly the console's speed.
  def test_a_pass_quicker_than_a_frame_waits_for_the_frame_to_end
    program = counting_game
    frame = frame_seconds(program)
    device = Headless.new(frames: 4, pass_seconds: frame / 4)
    rate = Session.new(program, device: device).play

    assert_equal [nil, 1, 2, 3], device.pictures.map { |picture| marked_frame(picture) }
    assert_operator device.now, :>=, 4 * frame
    assert_in_delta 1 / frame, rate.passes_per_second, 0.001
  end

  # The play says how fast it went, by the device's clock: four pictures, each pass two
  # frames, is eight of the console's frames in eight frames' time — the game at full speed,
  # its picture at half.
  def test_the_play_says_how_many_passes_and_frames_a_second_it_reached
    program = counting_game
    frame = frame_seconds(program)
    rate = Session.new(program, device: Headless.new(frames: 4, pass_seconds: 2 * frame)).play

    assert_equal [4, 8], [rate.passes, rate.frames]
    assert_equal 8 * frame, rate.seconds
    assert_in_delta 1 / frame, rate.frames_per_second, 0.001
    assert_in_delta 1 / (2 * frame), rate.passes_per_second, 0.001
  end

  # A game that ends by itself ends the play, and says how far it got.
  def test_a_game_that_halts_ends_the_play
    device = Headless.new(frames: 100)
    rate = Session.new(game { repeat(3) { wait_vblank } }, device: device).play

    assert_equal 3, device.pictures.size
    assert_equal 3, rate.passes
  end

  # A game that marks how many frames it has seen: one red pixel on the top row, that many
  # pixels in.
  private def counting_game
    game do
      game_loop do
        clear_screen :black
        draw_rect_at frames_since_power_on, 0, 1, 1, :red
      end
    end
  end

  # How long one of the program's console's frames lasts, a little more than a sixtieth.
  private def frame_seconds(program) = program.described_console.frame_seconds

  private def marked_frame(picture)
    picture.pixels.first(picture.width).index(Color.resolve(:red))
  end
end
